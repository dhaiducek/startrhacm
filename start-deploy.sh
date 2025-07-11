#!/bin/bash

set -e

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
BASE64="base64 -w 0"
if [ "${OS}" == "darwin" ]; then
  BASE64="base64"
fi

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

printlog title "Displaying start-deploy variables"
printlog info "RHACM_PIPELINE_PATH=${RHACM_PIPELINE_PATH}"
printlog info "RHACM_DEPLOY_PATH=${RHACM_DEPLOY_PATH}"
printlog info "RHACM_VERSION=${RHACM_VERSION}"
printlog info "DOWNSTREAM=${DOWNSTREAM}"
printlog info "PIPELINE_PHASE=${PIPELINE_PHASE}"

if [[ -z "${RHACM_PIPELINE_PATH}" ]]; then
  printlog error "RHACM_PIPELINE_PATH not defined. Please set RHACM_PIPELINE_PATH to the local path of the Pipeline repo."
  exit 1
else
  if (! ls "${RHACM_PIPELINE_PATH}" &>/dev/null); then
    printlog error "Error getting to Pipeline repo. Is RHACM_PIPELINE_PATH set properly? Currently it's set to: ${RHACM_PIPELINE_PATH}"
    exit 1
  fi
fi

if [[ -z "${RHACM_DEPLOY_PATH}" ]]; then
  printlog error "RHACM_DEPLOY_PATH not defined. Please set RHACM_DEPLOY_PATH to the local path of the Deploy repo."
  exit 1
else
  if (! ls "${RHACM_DEPLOY_PATH}" &>/dev/null); then
    printlog error "Error getting to Deploy repo. Is RHACM_DEPLOY_PATH set properly? Currently it's set to: ${RHACM_DEPLOY_PATH}"
    exit 1
  fi
fi

# Helper function to query Quay for snapshot tags
function queryquay() {
  QUAY_ORGANIZATION=${1}
  printlog info "Searching Quay for tag ${RHACM_SNAPSHOT}"

  # Store user-specified snapshot for logging
  if [[ -n "${RHACM_SNAPSHOT}" ]]; then
    USER_SNAPSHOT="${RHACM_SNAPSHOT}"
    RHACM_SNAPSHOT=""
  fi

  # Iterate over the all the pages of the repo
  HAS_ADDITIONAL="true"
  i=0
  while [[ "${HAS_ADDITIONAL}" == "true" ]] && [[ -z "${RHACM_SNAPSHOT}" ]]; do
    ((i = i + 1))
    HAS_ADDITIONAL=$(curl -s "https://quay.io/api/v1/repository/${QUAY_ORGANIZATION}/acm-custom-registry/tag/?onlyActiveTags=true&page=${i}" | jq -r '.has_additional')
    SNAPSHOT_TAGS=$(curl -s "https://quay.io/api/v1/repository/${QUAY_ORGANIZATION}/acm-custom-registry/tag/?onlyActiveTags=true&page=${i}&specificTag=${USER_SNAPSHOT}" | jq -r '.tags[].name')

    if [[ -z "${SNAPSHOT_TAGS}" ]]; then
      break
    fi

    if [[ -n "${USER_SNAPSHOT}" ]]; then
      RHACM_SNAPSHOT=$(echo "${SNAPSHOT_TAGS}" | head -n 1)
    else
      RHACM_SNAPSHOT=$(echo "${SNAPSHOT_TAGS}" | grep -v "^v\|nonesuch\|-$" | sort -r --version-sort | grep -F "${RHACM_VERSION}" | grep -F "${RHACM_BRANCH}." | head -n 1)
    fi
  done

  if [[ -z "${RHACM_SNAPSHOT}" ]]; then
    printlog error "Error querying snapshot list--nothing was returned. Please check https://quay.io/api/v1/repository/${QUAY_ORGANIZATION}/acm-custom-registry/tag/, your network connection, and any conflicts in your exports:"
    printlog error "Query used: RHACM_SNAPSHOT: '${USER_SNAPSHOT}' RHACM_VERSION: '${RHACM_VERSION}' RHACM_BRANCH '${RHACM_BRANCH}'"
    return 1
  fi
}

# Get snapshot
printlog title "Getting snapshot for RHACM (defaults to latest version -- override version with RHACM_VERSION)"
RHACM_BRANCH=${RHACM_BRANCH:-$(echo "${RHACM_VERSION}" | grep -o "[[:digit:]]\+\.[[:digit:]]\+" || true)} # Create Pipeline branch from version, if specified

# Get latest downstream snapshot from Quay if DOWNSTREAM is set to "true"
if [[ "${DOWNSTREAM}" == "true" ]]; then
  printlog info "Getting downstream snapshot"
  queryquay "acm-d"

# If DOWNSTREAM is not "true", get snapshot from pipeline repo (defaults to latest edge version)
else
  if [[ -z "${RHACM_SNAPSHOT}" ]]; then
    printlog info "Getting upstream snapshot"
    cd "${RHACM_PIPELINE_PATH}"
    stolostron_remote=$(git remote -v | awk '/stolostron/ {print $1}' | head -n 1)
    git fetch "${stolostron_remote}" &>/dev/null
    RHACM_BRANCH=${RHACM_BRANCH:-$(git remote show "${stolostron_remote}" | grep -o " [0-8]\+\.[0-9]\+-" | sort -uV | tail -1 | grep -o "[0-9]\+\.[0-9]\+")}
    VERSION_NUM=${RHACM_VERSION:=""}
    PIPELINE_PHASE=${PIPELINE_PHASE:-"dev"}
    # Handle older pipeline phases
    if [[ "${RHACM_BRANCH}" == "2."[0-4] ]]; then
      case "${PIPELINE_PHASE}" in
      dev | nightly)
        PIPELINE_PHASE="edge"
        ;;
      preview)
        PIPELINE_PHASE="stable"
        ;;
      esac
    fi
    printlog info "Updating repo and switching to the ${RHACM_BRANCH}-${PIPELINE_PHASE} branch (if this exits, check the state of the local Pipeline repo)"
    git checkout "${RHACM_BRANCH}-${PIPELINE_PHASE}" &>/dev/null
    git pull &>/dev/null
    if (! ls "${RHACM_PIPELINE_PATH}"/snapshots/manifest-* &>/dev/null); then
      printlog error "The branch, ${RHACM_BRANCH}-${PIPELINE_PHASE}, doesn't appear to have any snapshots/manifest-* files to parse a snapshot from."
      if [[ -z "${RHACM_BRANCH}" ]]; then
        RHACM_BRANCH=$(git remote show "${stolostron_remote}" | grep -o " [0-8]\+\.[0-9]\+-" | sort -uV | tail -2 | head -1 | grep -o "[0-9]\+\.[0-9]\+")
        printlog info "RHACM_BRANCH was not set. Using an older branch: ${RHACM_BRANCH}-${PIPELINE_PHASE}"
        git checkout "${RHACM_BRANCH}-${PIPELINE_PHASE}" &>/dev/null
        git pull &>/dev/null
      else
        printlog error "Please double check the Pipeline repo and set RHACM_BRANCH as needed."
        exit 1
      fi
    fi
    # Query Pipeline for snapshots--if the latest is not in Quay, try progressively older snapshots
    ATTEMPTS=0
    MAX_ATTEMPTS=5
    FOUND="false"
    while [[ "${FOUND}" == "false" ]] && ((ATTEMPTS != MAX_ATTEMPTS)); do
      ((ATTEMPTS = ATTEMPTS + 1))
      MANIFEST_TAG=$(ls "${RHACM_PIPELINE_PATH}"/snapshots/manifest-* | grep -F "${VERSION_NUM}" | tail -n ${ATTEMPTS} | head -n 1 | grep -o "[[:digit:]]\{4\}\(-[[:digit:]]\{2\}\)\{5\}.*")
      SNAPSHOT_TAG=$(echo "${MANIFEST_TAG}" | grep -o "[[:digit:]]\{4\}\(-[[:digit:]]\{2\}\)\{5\}")
      VERSION_NUM=$(echo "${MANIFEST_TAG}" | grep -o "\([[:digit:]]\+\.\)\{2\}[[:digit:]]\+")
      if [[ -n "${RHACM_VERSION}" && "${RHACM_VERSION}" != "${VERSION_NUM}" ]]; then
        printlog error "There's an unexpected mismatch between the version provided, ${RHACM_VERSION}, and the version found, ${VERSION_NUM}. Please double check the Pipeline repo before continuing."
        exit 1
      fi
      RHACM_SNAPSHOT="${VERSION_NUM}-SNAPSHOT-${SNAPSHOT_TAG}"

      # Query Quay for snapshot parsed from Pipeline
      if ! queryquay "stolostron"; then
        printlog error "The pipeline snapshot was not found in Quay. Trying an older snapshot."
      else
        FOUND="true"
      fi
    done
  elif ! queryquay "stolostron"; then
    # Fail if manually provided snapshot is not present in Quay
    printlog error "The provided snapshot ${RHACM_SNAPSHOT} was not found in Quay."
    exit 1
  fi
fi

printlog info "Using RHACM snapshot: ${RHACM_SNAPSHOT}"

# Deploy RHACM using retrieved snapshot
printlog title "Deploying Red Hat Advanced Cluster Management"
cd "${RHACM_DEPLOY_PATH}"
printlog info "Updating repo and switching to the master branch (if this exits, check the state of the local Deploy repo)"
git checkout master &>/dev/null
git pull &>/dev/null
echo "${RHACM_SNAPSHOT}" >"${RHACM_DEPLOY_PATH}"/snapshot.ver
if (! ls "${RHACM_DEPLOY_PATH}"/prereqs/pull-secret.yaml &>/dev/null) && [[ -z "${QUAY_TOKEN}" ]]; then
  printlog error "Error finding pull secret in deploy repo. Please consult https://github.com/stolostron/deploy on how to set it up."
  exit 1
fi
# Deploy necessary downstream resources if required
if [[ "${DOWNSTREAM}" == "true" ]] || [[ "${INSTALL_ICSP}" == "true" ]]; then
  if [[ -z "${QUAY_TOKEN}" ]]; then
    DOWNSTREAM_QUAY_TOKEN=$(grep "\.dockerconfigjson" "${RHACM_DEPLOY_PATH}/prereqs/pull-secret.yaml" | sed 's/.*\.dockerconfigjson: //')
  else
    DOWNSTREAM_QUAY_TOKEN=${QUAY_TOKEN}
  fi
  DOWNSTREAM_QUAY_TOKEN=$(echo "${DOWNSTREAM_QUAY_TOKEN}" | base64 --decode | sed "s/quay\.io/quay\.io:443/g")
  OPENSHIFT_PULL_SECRET=$(oc get -n openshift-config secret pull-secret -o jsonpath='{.data.\.dockerconfigjson}' | base64 --decode)
  FULL_TOKEN="${DOWNSTREAM_QUAY_TOKEN}${OPENSHIFT_PULL_SECRET}"
  if [[ "${DOWNSTREAM}" == "true" ]]; then
    printlog info "Setting up for downstream deployment"
    export COMPOSITE_BUNDLE CUSTOM_REGISTRY_REPO QUAY_TOKEN
    COMPOSITE_BUNDLE=true
    CUSTOM_REGISTRY_REPO="quay.io:443/acm-d"
    QUAY_TOKEN=$(echo "${DOWNSTREAM_QUAY_TOKEN}" | ${BASE64})
  else
    printlog info "Installing ICSP"
  fi
  printlog info "Updating Openshift pull-secret in namespace openshift-config with a token for quay.io:433"
  oc set data secret/pull-secret -n openshift-config --from-literal=.dockerconfigjson="$(jq -s '.[0] * .[1]' <<<"${FULL_TOKEN}")"
  printlog info "Applying downstream resources (including ImageContentSourcePolicy to point to downstream repo)"
  oc apply -k "${RHACM_DEPLOY_PATH}"/addons/downstream
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
  # Wait for cluster node to update with ICSP--if not all the nodes are up after this, we'll continue anyway
  printlog info "Waiting up to 10 minutes for cluster nodes to update with ImageContentSourcePolicy change"
  READY="false"
  ATTEMPTS=0
  MAX_ATTEMPTS=10
  INTERVAL=60
  while [[ "${READY}" == "false" ]] && ((ATTEMPTS != MAX_ATTEMPTS)); do
    NODES=$(oc get nodes | grep "NotReady\|SchedulingDisabled" || true)
    if [[ -n "${NODES}" ]]; then
      echo "${NODES}"
      printlog error "Waiting another ${INTERVAL}s for node update (Retry $((++ATTEMPTS))/${MAX_ATTEMPTS})"
      sleep ${INTERVAL}
    else
      READY="true"
    fi
  done
fi
# Attempt the RHACM deploy twice in case of an unexpected failure or timeout
ATTEMPTS=0
MAX_ATTEMPTS=1
INTERVAL=30
FAILED="false"
export TARGET_NAMESPACE=${TARGET_NAMESPACE:-"open-cluster-management"}
while (! ./start.sh --silent) && FAILED="true" && ((ATTEMPTS != MAX_ATTEMPTS)); do
  printlog error "RHACM deployment failed. Trying again in ${INTERVAL}s (Retry $((++ATTEMPTS))/${MAX_ATTEMPTS})"
  sleep ${INTERVAL}
  FAILED="false"
done
if [[ "${FAILED}" == "true" ]]; then
  printlog error "RHACM deployment failed. If it appears to be intermittent, re-run the startrhacm script against the same claim to try the RHACM deployment again."
  printlog error "Otherwise, either manually uninstall RHACM or delete the claim, and then try again."
  exit 1
fi
