#!/bin/bash

set -e

source "$(dirname "${BASH_SOURCE[0]}")/utils/common.sh"

if [[ -z "${QUAY_TOKEN}" ]]; then
  printlog info "QUAY_TOKEN not set, fetching from file utils/.docker/config.json"
  QUAY_TOKEN=$(get_quay_token_from_file)
fi

: "${ACM_CATALOG_IMAGE:?"ACM_CATALOG_IMAGE must be set"}"
: "${MCE_CATALOG_IMAGE:?"MCE_CATALOG_IMAGE must be set"}"
: "${ACM_CATALOG_TAG:?"ACM_CATALOG_TAG must be set to the desired ACM version"}"
: "${MCE_CATALOG_TAG:?"MCE_CATALOG_TAG must be set to correspond with your ACM_CATALOG_TAG"}"
: "${ACM_CHANNEL:?"ACM_CHANNEL must be set"}"
: "${QUAY_TOKEN:?"QUAY_TOKEN must be set"}"

export TARGET_NAMESPACE=${TARGET_NAMESPACE:-"open-cluster-management"}
export LOCAL_CLUSTER_NAME=${LOCAL_CLUSTER_NAME:-"local-cluster"}
export INCLUDE_ACMD=${INCLUDE_ACMD:-false}

printlog title "Displaying deployment variables"
printlog info "ACM_CATALOG_IMAGE=${ACM_CATALOG_IMAGE}"
printlog info "ACM_CATALOG_TAG=${ACM_CATALOG_TAG}"
printlog info "MCE_CATALOG_IMAGE=${MCE_CATALOG_IMAGE}"
printlog info "MCE_CATALOG_TAG=${MCE_CATALOG_TAG}"
printlog info "QUAY_TOKEN= (hidden ${#QUAY_TOKEN} characters)"
printlog info "ACM_CHANNEL=${ACM_CHANNEL}"
printlog info "TARGET_NAMESPACE=${TARGET_NAMESPACE}"
printlog info "LOCAL_CLUSTER_NAME=${LOCAL_CLUSTER_NAME}"

setup_pull_secret "${QUAY_TOKEN}"

setup_image_mirrors

create_catalog_sources

install_acm_operator

create_multiclusterhub
