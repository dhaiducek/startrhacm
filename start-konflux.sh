#!/bin/bash

set -e

script_dir="$(dirname "${BASH_SOURCE[0]}")"

source "${script_dir}/utils/common.sh"

export ACM_CHANNEL

if [[ -z "${ACM_CHANNEL}" ]]; then
  if [[ "${ACM_CATALOG_TAG}" =~ ^latest-([0-9]+\.[0-9]+) ]]; then
    ACM_CHANNEL=${ACM_CHANNEL:-"release-${BASH_REMATCH[1]}"}
    # For example: ACM_CATALOG_TAG=latest-2.15 gives ACM_CHANNEL=release-2.15
    printlog info "using ACM_CHANNEL=${ACM_CHANNEL}"
  else
    printlog error "ACM_CHANNEL must be set if it can not be inferred from ACM_CATALOG_TAG"
    exit 1
  fi
fi

export ACM_CATALOG_IMAGE="quay.io:443/acm-d/acm-dev-catalog"
export MCE_CATALOG_IMAGE="quay.io:443/acm-d/mce-dev-catalog"
export INCLUDE_ACMD=true

"${script_dir}/start-acm.sh"
