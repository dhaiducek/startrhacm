#!/bin/bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/utils/common.sh"

ART_ACM_CATALOG_IMAGE=${ART_ACM_CATALOG_IMAGE:-}
ART_MCE_CATALOG_IMAGE=${ART_MCE_CATALOG_IMAGE:-}
ART_PULL_SECRET=${ART_PULL_SECRET:-${QUAY_TOKEN:-}}
ACM_CHANNEL=${ACM_CHANNEL:-release-5.0}
TARGET_NAMESPACE=${TARGET_NAMESPACE:-open-cluster-management}
LOCAL_CLUSTER_NAME=${LOCAL_CLUSTER_NAME:-local-cluster}

printlog title "Displaying start-art variables"
printlog info "ART_ACM_CATALOG_IMAGE=${ART_ACM_CATALOG_IMAGE}"
printlog info "ART_MCE_CATALOG_IMAGE=${ART_MCE_CATALOG_IMAGE}"
printlog info "ART_PULL_SECRET= (hidden ${#ART_PULL_SECRET} characters)"
printlog info "ACM_CHANNEL=${ACM_CHANNEL}"
printlog info "TARGET_NAMESPACE=${TARGET_NAMESPACE}"
printlog info "LOCAL_CLUSTER_NAME=${LOCAL_CLUSTER_NAME}"

if [[ -z "${ART_ACM_CATALOG_IMAGE}" ]]; then
  printlog error "ART_ACM_CATALOG_IMAGE must be set to the ART ACM catalog image"
  exit 1
fi

if [[ -z "${ART_MCE_CATALOG_IMAGE}" ]]; then
  printlog error "ART_MCE_CATALOG_IMAGE must be set to the ART MCE catalog image"
  exit 1
fi

if [[ -z "${ART_PULL_SECRET}" ]]; then
  printlog error "ART_PULL_SECRET or QUAY_TOKEN must be set for the ART registry"
  exit 1
fi

if printf '%s' "${ART_PULL_SECRET}" | jq -e . >/dev/null 2>&1; then
  ART_PULL_SECRET=$(printf '%s' "${ART_PULL_SECRET}" | base64 | tr -d '\n')
fi

setup_art_image_mirrors() {
  printlog info "Applying ART ImageDigestMirrorSet"

  oc apply -f - <<'EOF'
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: image-mirror-custom
spec:
  imageDigestMirrors:
    - source: registry.redhat.io/rhacm2
      mirrors:
        - registry.stage.redhat.io/rhacm2
    - source: registry.redhat.io/multicluster-engine
      mirrors:
        - registry.stage.redhat.io/multicluster-engine
    - source: registry.redhat.io/openshift4/ose-aws-cluster-api-controllers-rhel9
      mirrors:
        - registry.stage.redhat.io/openshift4/ose-aws-cluster-api-controllers-rhel9
    - source: registry.redhat.io/openshift4/ose-cluster-api-rhel9
      mirrors:
        - registry.stage.redhat.io/openshift4/ose-cluster-api-rhel9
    - source: registry.redhat.io/openshift4/ose-baremetal-cluster-api-controllers-rhel9
      mirrors:
        - registry.stage.redhat.io/openshift4/ose-baremetal-cluster-api-controllers-rhel9
    - source: registry.access.redhat.com/openshift4/ose-oauth-proxy
      mirrors:
        - registry.stage.redhat.io/openshift4/ose-oauth-proxy
EOF
}

OPENSHIFT_PULL_SECRET=$(oc get -n openshift-config secret pull-secret -o jsonpath='{.data.\.dockerconfigjson}' | base64 --decode)
oc set data secret/pull-secret -n openshift-config --from-literal=.dockerconfigjson="$(jq -s '.[0] * .[1]' \
  <(echo "${OPENSHIFT_PULL_SECRET}") <(echo "${ART_PULL_SECRET}" | base64 --decode))"

setup_art_image_mirrors
printlog info "Allowing the ImageDigestMirrorSet rollout to start"
sleep 60

printlog info "Creating ART CatalogSources"
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: acm-art-catalog
  namespace: openshift-marketplace
  labels:
    startrhacm: "true"
spec:
  displayName: ACM ART catalog
  image: ${ART_ACM_CATALOG_IMAGE}
  publisher: ART
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 10m
---
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: mce-art-catalog
  namespace: openshift-marketplace
  labels:
    startrhacm: "true"
spec:
  displayName: MCE ART catalog
  image: ${ART_MCE_CATALOG_IMAGE}
  publisher: ART
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 10m
EOF

printlog info "Waiting up to 10 minutes for the ART CatalogSources"
oc wait --for=jsonpath='.status.connectionState.lastObservedState'=READY catalogsource.operators acm-art-catalog -n openshift-marketplace --timeout=600s
oc wait --for=jsonpath='.status.connectionState.lastObservedState'=READY catalogsource.operators mce-art-catalog -n openshift-marketplace --timeout=600s

printlog info "Installing the ACM Operator with TARGET_NAMESPACE=${TARGET_NAMESPACE} and ACM_CHANNEL=${ACM_CHANNEL}"
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${TARGET_NAMESPACE}"
---
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
  source: acm-art-catalog
  sourceNamespace: openshift-marketplace
EOF

printlog info "Waiting up to 10 minutes for the ACM Subscription"
oc wait --for=jsonpath='.status.state'=AtLatestKnown subscription.operators acm-operator-subscription -n "${TARGET_NAMESPACE}" --timeout=600s

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

printlog info "Waiting up to 15 minutes for the MultiClusterHub"
oc wait --for=jsonpath='.status.phase'=Running multiclusterhub multiclusterhub -n "${TARGET_NAMESPACE}" --timeout=900s
