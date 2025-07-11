#!/bin/bash

set -e

# Helper function to format logs
function printlog() {
  case ${1} in
  title)
    printf "\n##### "
    ;;
  info)
    printf "* "
    ;;
  error)
    printf "^^^^^ "
    ;;
  *)
    printlog error "Unexpected error in printlog function. Invalid input given: ${1}"
    exit 1
    ;;
  esac
  printf "%s\n" "${2}"
}

printlog title "Displaying start-konflux variables"
printlog info "ACM_CATALOG_TAG=${ACM_CATALOG_TAG}"
printlog info "MCE_CATALOG_TAG=${MCE_CATALOG_TAG}"
printlog info "QUAY_TOKEN= (hidden ${#QUAY_TOKEN} characters)"
printlog info "ACM_CHANNEL=${ACM_CHANNEL}"
printlog info "TARGET_NAMESPACE=${TARGET_NAMESPACE}"
printlog info "LOCAL_CLUSTER_NAME=${LOCAL_CLUSTER_NAME}"

if [[ -z "${ACM_CATALOG_TAG}" ]]; then
  printlog error "ACM_CATALOG_TAG not defined. Please set ACM_CATALOG_TAG to the desired ACM version."
  exit 1
fi

if [[ -z "${MCE_CATALOG_TAG}" ]]; then
  printlog error "MCE_CATALOG_TAG not defined. Please set MCE_CATALOG_TAG to correspond to your ACM_CATALOG_TAG."
  exit 1
fi

if [[ -z "${QUAY_TOKEN}" ]]; then
  printlog error "QUAY_TOKEN must be set"
  exit 1
fi

if [[ -z "${ACM_CHANNEL}" ]]; then
  if [[ "${ACM_CATALOG_TAG:0:7}" == "latest-" ]]; then
    ACM_CHANNEL=${ACM_CHANNEL:-"release-${ACM_CATALOG_TAG:7:4}"}
    # For example: ACM_CATALOG_TAG=latest-2.15 gives ACM_CHANNEL=release-2.15
    printlog info "using ACM_CHANNEL=${ACM_CHANNEL}"
  else
    printlog error "ACM_CHANNEL must be set if it can not be inferred from ACM_CATALOG_TAG"
    exit 1
  fi
fi

printlog info "Updating Openshift pull-secret in namespace openshift-config with a token for quay.io:433"
QUAY443_TOKEN=$(echo "${QUAY_TOKEN}" | base64 --decode | sed "s/quay\.io/quay\.io:443/g")
OPENSHIFT_PULL_SECRET=$(oc get -n openshift-config secret pull-secret -o jsonpath='{.data.\.dockerconfigjson}' | base64 --decode)
FULL_TOKEN="${QUAY443_TOKEN}${OPENSHIFT_PULL_SECRET}"
oc set data secret/pull-secret -n openshift-config --from-literal=.dockerconfigjson="$(jq -s '.[0] * .[1]' <<<"${FULL_TOKEN}")"

printlog info "Applying ImageDigestMirrorSet"
oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: image-mirror-custom
spec:
  imageDigestMirrors:
    - mirrors:
        - quay.io:443/acm-d
        - registry.stage.redhat.io/rhacm2
        - brew.registry.redhat.io/rh-osbs/rhacm2
      source: registry.redhat.io/rhacm2
    - mirrors:
        - quay.io:443/acm-d
        - registry.stage.redhat.io/multicluster-engine
        - brew.registry.redhat.io/rh-osbs/multicluster-engine
      source: registry.redhat.io/multicluster-engine
    - mirrors:
        - quay.io:443/acm-d
        - registry.stage.redhat.io/openshift4
      source: registry.redhat.io/openshift4
    - mirrors:
        - registry.stage.redhat.io/gatekeeper
      source: registry.redhat.io/gatekeeper
EOF

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
  displayName: acm-dev-catalog:${ACM_CATALOG_TAG}
  image: quay.io:443/acm-d/acm-dev-catalog:${ACM_CATALOG_TAG}
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
  displayName: mce-dev-catalog:${MCE_CATALOG_TAG}
  image: quay.io:443/acm-d/mce-dev-catalog:${MCE_CATALOG_TAG}
  publisher: grpc
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 10m
EOF

printlog info "Waiting up to 5 minutes each for the CatalogSources to become available"
oc wait --for=jsonpath='.status.connectionState.lastObservedState'=READY catalogsource.operators acm-dev-catalog -n openshift-marketplace --timeout=300s
oc wait --for=jsonpath='.status.connectionState.lastObservedState'=READY catalogsource.operators mce-dev-catalog -n openshift-marketplace --timeout=300s

TARGET_NAMESPACE=${TARGET_NAMESPACE:-"open-cluster-management"}
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

LOCAL_CLUSTER_NAME=${LOCAL_CLUSTER_NAME:-"local-cluster"}
sleep 30
printlog info "Creating the MultiClusterHub with LOCAL_CLUSTER_NAME=${LOCAL_CLUSTER_NAME}"
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
