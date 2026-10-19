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

token_file="$(dirname "${BASH_SOURCE[0]}")/utils/.docker/config.json"
created_token_file=false

if ! [[ -f "${token_file}" ]]; then
  created_token_file=true
  mkdir -p "$(dirname "${token_file}")"
  if [[ ${ACM_CATALOG_IMAGE} =~ ^quay\.io:443/ ]]; then
    echo "${QUAY_TOKEN}" | base64 -d | sed "s/quay\.io/quay\.io:443/g" >"${token_file}"
  else
    echo "${QUAY_TOKEN}" | base64 -d >"${token_file}"
  fi
fi

if ! skopeo inspect --raw --authfile "${token_file}" "docker://${ACM_CATALOG_IMAGE}:${ACM_CATALOG_TAG}" 1>/dev/null; then
  printlog error "error: ACM catalog image ${ACM_CATALOG_IMAGE}:${ACM_CATALOG_TAG} not found. Exiting."
  exit 1
fi

if ! skopeo inspect --raw --authfile "${token_file}" "docker://${MCE_CATALOG_IMAGE}:${MCE_CATALOG_TAG}" 1>/dev/null; then
  printlog error "error: MCE catalog image ${MCE_CATALOG_IMAGE}:${MCE_CATALOG_TAG} not found. Exiting."
  exit 1
fi

if ${created_token_file}; then
  rm -f "${token_file}"
fi

setup_pull_secret "${QUAY_TOKEN}"

setup_image_mirrors

create_catalog_sources

install_acm_operator

create_multiclusterhub
