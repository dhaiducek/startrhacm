#!/bin/bash

set -e

script_dir="$(dirname "${BASH_SOURCE[0]}")"

source "${script_dir}/utils/common.sh"

export ACM_CHANNEL

printlog title "Configured with ACM_CATALOG_TAG=${ACM_CATALOG_TAG}"

ocp_version=$(oc version -o json | jq -r '.openshiftVersion // ""') || ocp_version=""
if [[ -z "${ocp_version}" ]]; then
  printlog info "Warning: Failed to get OCP version from 'oc version' command."
else
  ocp_y_stream="v${ocp_version%.*}"
fi

if [[ "${ACM_CATALOG_TAG}" =~ ^[0-9]+\.[0-9]+$ ]]; then
  printlog info "Detected ACM_CATALOG_TAG in the format X.Y. Constructing catalog image tag."
  if ! [[ "${ocp_y_stream}" =~ ^v[0-9]+\.[0-9]+$ ]]; then
    printlog error "error: Unexpected OCP y-stream format from 'oc version'. Got: ${ocp_y_stream}. Exiting."
    exit 1
  fi
  ACM_CATALOG_TAG="acm-${ACM_CATALOG_TAG}__${ocp_y_stream}__multiclusterhub-rhel9"
fi

if ! [[ ${ACM_CATALOG_TAG} =~ ^acm-([0-9]+\.[0-9]+)__(v[0-9]+\.[0-9]+)__(multiclusterhub-rhel[0-9]+)$ ]]; then
  printlog info "Warning: Expected ACM_CATALOG_TAG to be in the format acm-X.Y__vX.Y__multiclusterhub-rhelX. This might not work."
fi

tag_acm_version="${BASH_REMATCH[1]}"
tag_ocp_version="${BASH_REMATCH[2]}"
tag_mch_image="${BASH_REMATCH[3]}"

if ! [[ "${ocp_y_stream}" =~ ^v[0-9]+\.[0-9]+$ ]]; then
  printlog info "Warning: Unexpected OCP y-stream format from 'oc version'. Got: ${ocp_y_stream}"
elif [[ ${ocp_y_stream} != "${tag_ocp_version}" ]]; then
  printlog info "Warning: OCP version mismatch. Got: ${ocp_y_stream}, Parsed from catalog tag: ${tag_ocp_version}"
fi

printlog info "Parsed values: ACM_VERSION=${tag_acm_version}, OCP_VERSION=${tag_ocp_version}, MCH_IMAGE=${tag_mch_image}"

if [[ -z "${MCE_CATALOG_TAG}" ]]; then
  export MCE_CATALOG_TAG
  MCE_CATALOG_TAG="${ACM_CATALOG_TAG//acm/mce}"
  MCE_CATALOG_TAG="${MCE_CATALOG_TAG//multiclusterhub/backplane}-operator"
  printlog info "Found empty MCE_CATALOG_TAG. Setting to equivalent value from ACM_CATALOG_TAG: ${MCE_CATALOG_TAG:-<empty>}"
fi

if [[ -z "${ACM_CHANNEL}" ]]; then
  : "${tag_acm_version:?"Cannot derive ACM_CHANNEL. Check ACM_CATALOG_TAG or explicitly set ACM_CHANNEL."}"
  if [[ "${tag_acm_version%.*}" -ge "5" ]]; then
    ACM_CHANNEL="stable-${tag_acm_version}"
  else
    ACM_CHANNEL="release-${tag_acm_version}"
  fi
  printlog info "using ACM_CHANNEL=${ACM_CHANNEL}"
fi

export ACM_CATALOG_IMAGE="quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc"
export MCE_CATALOG_IMAGE="quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc"
export INCLUDE_ACMD=false

"${script_dir}/start-acm.sh"
