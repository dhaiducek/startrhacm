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
        - 'quay.io:443/acm-d'
        - registry.stage.redhat.io/openshift5
      source: registry.redhat.io/openshift5
    - mirrors:
        - registry.stage.redhat.io/gatekeeper
      source: registry.redhat.io/gatekeeper
EOF
}
