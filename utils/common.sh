#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Mac base64 encoding compatability
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
BASE64="base64 -w 0"
if [ "${OS}" == "darwin" ]; then
  BASE64="base64"
fi

# Formats and outputs logs
function printlog() {
  local prefix fd=1
  case ${1} in
  title)
    prefix="\n##### "
    ;;
  info)
    prefix="* "
    ;;
  error)
    prefix="^^^^^ "
    fd=2
    ;;
  *)
    printlog error "Unexpected error in printlog function. Invalid input given: ${1}"
    exit 1
    ;;
  esac
  printf "%b%b\n" "${prefix}" "${2}" >&"${fd}"
}

# Gets QUAY_TOKEN from utils/.docker/config.json
function get_quay_token_from_file() {
  local docker_config_path
  docker_config_path="${SCRIPT_DIR}/utils/.docker/config.json"
  if [[ -f "${docker_config_path}" ]]; then
    cat "${docker_config_path}" | ${BASE64}
  else
    printlog error "${docker_config_path} does not exist"
    exit 1
  fi
}

# Sets up secret for quay.io:443
function setup_pull_secret() {
  local quay_token="${1}"

  if [[ -z "${quay_token}" ]]; then
    printlog error "QUAY_TOKEN must be provided to setup_pull_secret"
    return 1
  fi

  printlog info "Updating Openshift pull-secret in namespace openshift-config with a token for quay.io:443"
  QUAY443_TOKEN=$(echo "${quay_token}" | base64 --decode | sed 's/"quay\.io"/"quay\.io:443"/g')
  OPENSHIFT_PULL_SECRET=$(oc get -n openshift-config secret pull-secret -o jsonpath='{.data.\.dockerconfigjson}' | base64 --decode)
  FULL_TOKEN="${QUAY443_TOKEN}${OPENSHIFT_PULL_SECRET}"
  oc set data secret/pull-secret -n openshift-config --from-literal=.dockerconfigjson="$(jq -s '.[1] * .[0]' <<<"${FULL_TOKEN}")"
}

# Applies ImageDigestMirrorSet for quay.io:443/acm-d
function setup_image_mirrors() {
  local acmd_mirror=""
  if [[ "${INCLUDE_ACMD:-false}" == "true" ]]; then
    acmd_mirror="\"quay.io:443/acm-d\", "
  fi

  printlog info "Applying ImageDigestMirrorSet"
  oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: image-mirror-custom
spec:
  imageDigestMirrors:
    - mirrors: [${acmd_mirror}"registry.stage.redhat.io/rhacm2"]
      source: registry.redhat.io/rhacm2
    - mirrors: [${acmd_mirror}"registry.stage.redhat.io/multicluster-engine"]
      source: registry.redhat.io/multicluster-engine
    - mirrors: [${acmd_mirror}"registry.stage.redhat.io/openshift4"]
      source: registry.redhat.io/openshift4
    - mirrors: [${acmd_mirror}"registry.stage.redhat.io/openshift5"]
      source: registry.redhat.io/openshift5
    - mirrors: ["registry.stage.redhat.io/gatekeeper"]
      source: registry.redhat.io/gatekeeper
EOF
}

function create_catalog_sources() {
  if [[ -z "${ACM_CATALOG_IMAGE}" ]]; then
    printlog error "ACM_CATALOG_IMAGE must be provided to create_catalog_sources"
    return 1
  fi

  if [[ -z "${ACM_CATALOG_TAG}" ]]; then
    printlog error "ACM_CATALOG_TAG must be provided to create_catalog_sources"
    return 1
  fi

  if [[ -z "${MCE_CATALOG_IMAGE}" ]]; then
    printlog error "MCE_CATALOG_IMAGE must be provided to create_catalog_sources"
    return 1
  fi

  if [[ -z "${MCE_CATALOG_TAG}" ]]; then
    printlog error "MCE_CATALOG_TAG must be provided to create_catalog_sources"
    return 1
  fi

  printlog info "Creating CatalogSources using ACM_CATALOG_TAG=${ACM_CATALOG_TAG} and MCE_CATALOG_TAG=${MCE_CATALOG_TAG}"
  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: acm-dev-catalog
  namespace: openshift-marketplace
  labels:
    startrhacm: "true"
spec:
  displayName: "acm-dev-catalog:${ACM_CATALOG_TAG}"
  image: "${ACM_CATALOG_IMAGE}:${ACM_CATALOG_TAG}"
  publisher: grpc
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 10m
---
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: mce-dev-catalog
  namespace: openshift-marketplace
spec:
  displayName: "mce-dev-catalog:${MCE_CATALOG_TAG}"
  image: "${MCE_CATALOG_IMAGE}:${MCE_CATALOG_TAG}"
  publisher: grpc
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 10m
EOF

  printlog info "Waiting up to 10 minutes each for the CatalogSources to become available"
  oc wait --for=jsonpath='.status.connectionState.lastObservedState'=READY catalogsource.operators acm-dev-catalog -n openshift-marketplace --timeout=600s
  oc wait --for=jsonpath='.status.connectionState.lastObservedState'=READY catalogsource.operators mce-dev-catalog -n openshift-marketplace --timeout=600s
}

function install_acm_operator() {
  if [[ -z "${ACM_CHANNEL}" ]]; then
    printlog error "ACM_CHANNEL must be provided to install_acm_operator"
    return 1
  fi

  if [[ -z "${TARGET_NAMESPACE}" ]]; then
    printlog error "TARGET_NAMESPACE must be provided to install_acm_operator"
    return 1
  fi

  printlog info "Installing the ACM Operator with TARGET_NAMESPACE=${TARGET_NAMESPACE} and ACM_CHANNEL=${ACM_CHANNEL}"
  oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${TARGET_NAMESPACE}"
EOF

  sleep 5
  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: default
  namespace: "${TARGET_NAMESPACE}"
spec:
  targetNamespaces:
  - "${TARGET_NAMESPACE}"
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: acm-operator-subscription
  namespace: "${TARGET_NAMESPACE}"
spec:
  channel: "${ACM_CHANNEL}"
  installPlanApproval: Automatic
  name: advanced-cluster-management
  source: acm-dev-catalog
  sourceNamespace: openshift-marketplace
EOF

  printlog info "Waiting up to 10 minutes for the Subscription to succeed"
  oc wait --for=jsonpath='.status.state'=AtLatestKnown subscription.operators acm-operator-subscription -n "${TARGET_NAMESPACE}" --timeout=600s
}

function create_multiclusterhub() {
  if [[ -z "${LOCAL_CLUSTER_NAME}" ]]; then
    printlog error "LOCAL_CLUSTER_NAME must be provided to create_multiclusterhub"
    return 1
  fi

  if [[ -z "${TARGET_NAMESPACE}" ]]; then
    printlog error "TARGET_NAMESPACE must be provided to create_multiclusterhub"
    return 1
  fi

  printlog info "Creating the MultiClusterHub with LOCAL_CLUSTER_NAME=${LOCAL_CLUSTER_NAME} and TARGET_NAMESPACE=${TARGET_NAMESPACE}"
  sleep 30
  oc apply -f - <<EOF
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: "${TARGET_NAMESPACE}"
spec:
  localClusterName: "${LOCAL_CLUSTER_NAME}"
EOF

  printlog info "Waiting up to 15 minutes for the MultiClusterHub to become Running"
  oc wait --for=jsonpath='.status.phase'=Running multiclusterhub multiclusterhub -n "${TARGET_NAMESPACE}" --timeout=900s
}
