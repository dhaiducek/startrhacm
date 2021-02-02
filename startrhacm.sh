#! /bin/bash

set -e

# Helper function to format logs
function printlog() {
  case ${1} in
    title)  printf "\n##### " 
            ;;
    info)   printf "* "
            ;;
    error)  printf "^^^^^ "
            ;;
    *)      printlog error "Unexpected error in printlog function. Invalid input given: ${1}"
            exit 1
            ;;
  esac
  printf "${2}\n"
}

# Helper function to check exports
function checkexports() {
  if [[ -z "${LIFEGUARD_PATH}" ]]; then
    printlog error "LIFEGUARD_PATH not defined. Please set LIFEGUARD_PATH to the local path of the Lifeguard repo."
    exit 1
  else
    if (! ls ${LIFEGUARD_PATH} &>/dev/null); then
      printlog error "Error getting to Lifeguard repo. Is LIFEGUARD_PATH set properly? Currently it's set to: ${LIFEGUARD_PATH}"
      exit 1
    fi
  fi
  if [[ -z "${RHACM_PIPELINE_PATH}" ]]; then
    printlog error "RHACM_PIPELINE_PATH not defined. Please set RHACM_PIPELINE_PATH to the local path of the Pipeline repo."
    exit 1
  else
    if (! ls ${RHACM_PIPELINE_PATH} &>/dev/null); then
      printlog error "Error getting to Pipeline repo. Is RHACM_PIPELINE_PATH set properly? Currently it's set to: ${RHACM_PIPELINE_PATH}"
      exit 1
    fi
  fi
  if [[ -z "${RHACM_DEPLOY_PATH}" ]]; then
    printlog error "RHACM_DEPLOY_PATH not defined. Please set RHACM_DEPLOY_PATH to the local path of the Deploy repo."
    exit 1
  else
    if (! ls ${RHACM_DEPLOY_PATH} &>/dev/null); then
      printlog error "Error getting to Deploy repo. Is RHACM_DEPLOY_PATH set properly? Currently it's set to: ${RHACM_DEPLOY_PATH}"
      exit 1
    fi
  fi
}

# Load configuration
printlog title "Loading configuration from utils/config.sh"
SCRIPT_DIR=$(dirname "${BASH_SOURCE[0]}")
if ls ${SCRIPT_DIR}/utils/config.sh &>/dev/null; then
  if (! ${SCRIPT_DIR}/utils/config.sh); then
    printlog error "Error running configuration script. Is the script executable? If not, run: chmod +x ${SCRIPT_DIR}/utils/config.sh"
    exit 1
  else
    source ${SCRIPT_DIR}/utils/config.sh
    checkexports
  fi
else
  printlog info "config.sh script not found--checking exports for LIFEGUARD_PATH, RHACM_PIPELINE_PATH, and RHACM_DEPLOY_PATH"
  checkexports
fi

# Verify we're pointed to the collective cluster
CLUSTER=$(oc config get-contexts | awk '/^\052/ {print $3}' | awk '{gsub("^api-",""); gsub("(\/|-red-chesterfield).*",""); print}')
if [[ "${KUBECONFIG}" == */lifeguard/clusterclaims/*/kubeconfig ]]; then
  printlog error "KUBECONFIG is set to an existing claim's configuration file. Please unset before continuing: unset KUBECONFIG"
  exit 1
elif [[ "${CLUSTER}" != "collective-aws" ]] || (! oc status &>/dev/null); then
  printlog info "The oc CLI is not currently logged in to the collective cluster. Please configure the CLI and try again."
  printlog info "KUBECONFIG is currently set: $(test -n "${KUBECONFIG}" && echo "true" || echo "false")"
  printlog info "Current cluster: ${CLUSTER}"
  printlog info "Link to Collective cluster login command: https://oauth-openshift.apps.collective.aws.red-chesterfield.com/oauth/token/request"
  exit 1
fi

# Claim cluster from ClusterPool
printlog title "Creating ClusterClaim from ClusterPool ${CLUSTERPOOL_NAME}"
CLAIM_DIR=${LIFEGUARD_PATH}/clusterclaims
cd ${CLAIM_DIR}
printlog info "Switching to main branch and updating repo (if this exits, check the state of the local Lifeguard repo)"
git checkout main &>/dev/null
git pull &>/dev/null
# Set lifetime of claim to end of work day
if [[ -n "${CLUSTERCLAIM_END_TIME}" ]]; then
  export CLUSTERCLAIM_LIFETIME="$((${CLUSTERCLAIM_END_TIME}-$(date "+%-H")-1))h$((60-$(date "+%-M")))m"
fi
./apply.sh
printlog title "Setting KUBECONFIG and checking cluster access"
# If we have a ClusterClaim name, use that to get the kubeconfig, otherwise just get the most recently modified (which is most likely the one we need)
if [[ -n "${CLUSTERCLAIM_NAME}" ]]; then
  export KUBECONFIG=$(ls ${CLAIM_DIR}/${CLUSTERCLAIM_NAME}/kubeconfig)
else
  export KUBECONFIG=$(ls -dt1 ${CLAIM_DIR}/*/kubeconfig | head -n 1)
fi
ATTEMPTS=0
MAX_ATTEMPTS=15
INTERVAL=20
FAILED="false"
while (! oc status) && FAILED="true" && (( ATTEMPTS != MAX_ATTEMPTS )); do
  printlog error "Error logging in to cluster. Trying again in ${INTERVAL}s (Retry $((++ATTEMPTS))/${MAX_ATTEMPTS})"
  sleep ${INTERVAL}
  FAILED="false"
done
if [[ "${FAILED}" == "true" ]]; then
  printlog error "Failed to login to cluster. Exiting."
  exit 1
fi

# Get snapshot
printlog title "Getting snapshot for RHACM (defaults to latest version -- override version with RHACM_VERSION)"
cd ${RHACM_PIPELINE_PATH}
git pull &>/dev/null
RHACM_BRANCH=${RHACM_BRANCH:-$(echo "${RHACM_VERSION}" | grep -o "[[:digit:]]\+\.[[:digit:]]\+" || true)} # Create Pipeline branch from version, if specified
BRANCH=${RHACM_BRANCH:-$(git remote show origin | grep -o " [0-9]\+\.[0-9]\+-" | sort -uV | tail -1 | grep -o "[0-9]\+\.[0-9]\+")}

# Get latest downstream snapshot from Quay if DOWNSTREAM is set to "true"
if [[ ${DOWNSTREAM} == "true" ]]; then
  printlog info "Getting downstream snapshot"
  # Store user-specified snapshot for logging
  if [[ -n "${RHACM_SNAPSHOT}" ]]; then
    USER_SNAPSHOT="${RHACM_SNAPSHOT}"
  fi
  RHACM_SNAPSHOT=$(curl -s https://quay.io/api/v1/repository/acm-d/acm-custom-registry/tag/ | jq -r '.tags[].name' | grep -v "nonesuch\|-$" | grep "${USER_SNAPSHOT}" | grep -F "${RHACM_VERSION}" | grep -F "${BRANCH}."| head -n 1)
  if [[ -z "${RHACM_SNAPSHOT}" ]]; then
    printlog error "Error querying snapshot list--nothing was returned. Please check https://quay.io/api/v1/repository/acm-d/acm-custom-registry/tag/, your network connection, and any conflicts in your exports:"
    printlog error "Query used: RHACM_SNAPSHOT: '${USER_SNAPSHOT}' RHACM_VERSION: '${RHACM_VERSION}' RHACM_BRANCH '${RHACM_BRANCH}'"
    exit 1
  fi

# If DOWNSTREAM is not "true", get snapshot from pipeline repo (defaults to latest edge version)
else
  if [[ -z "${RHACM_SNAPSHOT}" ]]; then
    printlog info "Getting upstream snapshot"
    cd ${RHACM_PIPELINE_PATH}
    VERSION_NUM=${RHACM_VERSION:=""}
    PIPELINE_PHASE=${PIPELINE_PHASE:-"edge"}
    printlog info "Updating repo and switching to the ${BRANCH}-${PIPELINE_PHASE} branch (if this exits, check the state of the local Pipeline repo)"
    git checkout ${BRANCH}-${PIPELINE_PHASE} &>/dev/null
    git pull &>/dev/null
    MANIFEST_TAG=$(ls ${RHACM_PIPELINE_PATH}/snapshots/manifest-* | grep -F "${VERSION_NUM}" | tail -n 1 | grep -o "[[:digit:]]\{4\}\(-[[:digit:]]\{2\}\)\{5\}.*")
    SNAPSHOT_TAG=$(echo ${MANIFEST_TAG} | grep -o "[[:digit:]]\{4\}\(-[[:digit:]]\{2\}\)\{5\}")
    VERSION_NUM=$(echo ${MANIFEST_TAG} | grep -o "\([[:digit:]]\+\.\)\{2\}[[:digit:]]\+")
    if [[ -n "${RHACM_VERSION}" && "${RHACM_VERSION}" != "${VERSION_NUM}" ]]; then
      printlog error "There's an unexpected mismatch between the version provided, ${RHACM_VERSION}, and the version found, ${VERSION_NUM}. Please double check the Pipeline repo before continuing."
      exit 1
    fi
    RHACM_SNAPSHOT="${VERSION_NUM}-SNAPSHOT-${SNAPSHOT_TAG}"
  fi
fi
printlog info "Using RHACM snapshot: ${RHACM_SNAPSHOT}"

# Deploy RHACM using retrieved snapshot
printlog title "Deploying Red Hat Advanced Cluster Management"
cd ${RHACM_DEPLOY_PATH}
printlog info "Updating repo and switching to the master branch (if this exits, check the state of the local Deploy repo)"
git checkout master &>/dev/null
git pull &>/dev/null
echo "${RHACM_SNAPSHOT}" > ${RHACM_DEPLOY_PATH}/snapshot.ver
if (! ls ${RHACM_DEPLOY_PATH}/prereqs/pull-secret.yaml &>/dev/null); then
  printlog error "Error finding pull secret in deploy repo. Please consult https://github.com/open-cluster-management/deploy on how to set it up."
  exit 1
fi
# Deploy necessary downstream resources if required
if [[ "${DOWNSTREAM}" == "true" ]]; then
  printlog info "Setting up for downstream deployment"
  export COMPOSITE_BUNDLE=true
  export CUSTOM_REGISTRY_REPO="quay.io:443/acm-d"
  export QUAY_TOKEN=$(cat ${RHACM_DEPLOY_PATH}/prereqs/pull-secret.yaml | grep "\.dockerconfigjson" | sed 's/.*\.dockerconfigjson: //' | base64 --decode | sed "s/quay\.io/quay\.io:443/g")
  OPENSHIFT_PULL_SECRET=$(oc get -n openshift-config secret pull-secret -o jsonpath='{.data.\.dockerconfigjson}' | base64 --decode)
  FULL_TOKEN="${QUAY_TOKEN}${OPENSHIFT_PULL_SECRET}"
  printlog info "Updating Openshift pull-secret in namespace openshift-config with a token for quay.io:433"
  oc set data secret/pull-secret -n openshift-config --from-literal=.dockerconfigjson="$(jq -s '.[0] * .[1]' <<<${FULL_TOKEN})"
  printlog info "Applying downstream resources (including ImageContentSourcePolicy to point to downstream repo)"
  oc apply -k ${RHACM_DEPLOY_PATH}/addons/downstream
  # Wait for cluster node to update with ICSP--if not all the nodes are up after this, we'll continue anyway
  printlog info "Waiting up to 10 minutes for cluster nodes to update with ImageContentSourcePolicy change"
  READY="false"
  ATTEMPTS=0
  MAX_ATTEMPTS=10
  INTERVAL=60
  while [[ "${READY}" == "false" ]] && (( ATTEMPTS != MAX_ATTEMPTS )); do
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
while (! ./start.sh --silent) && FAILED="true" && (( ATTEMPTS != MAX_ATTEMPTS )); do
  printlog error "RHACM deployment failed. Trying again in ${INTERVAL}s (Retry $((++ATTEMPTS))/${MAX_ATTEMPTS})"
  sleep ${INTERVAL}
  FAILED="false"
done
if [[ "${FAILED}" == "true" ]]; then
  printlog error "RHACM deployment failed. If it appears to be intermittent, re-run the startrhacm script against the same claim to try the RHACM deployment again."
  printlog error "Otherwise, either manually uninstall RHACM or delete the claim, and then try again."
  exit 1
fi

# Set CLI to point to RHACM namespace
printlog title "Setting oc CLI context to open-cluster-management namespace"
oc config set-context --current --namespace=open-cluster-management

# Configure auth to allow requests from localhost
if [[ -n "${AUTH_REDIRECT_PATHS}" ]]; then
  printlog title "Waiting for ingress to be running to configure localhost connections"
  ATTEMPTS=0
  MAX_ATTEMPTS=15
  INTERVAL=20
  FAILED="false"
  while (! oc get oauthclient multicloudingress) && FAILED="true" && (( ATTEMPTS != MAX_ATTEMPTS )); do
    printlog error "Error finding ingress. Trying again in ${INTERVAL}s (Retry $((++ATTEMPTS))/${MAX_ATTEMPTS})"
    sleep ${INTERVAL}
    FAILED="false"
  done
  if [[ "${FAILED}" == "true" ]]; then
    printlog error "Ingress not patched. Please check your RHACM deployment."
  else
    REDIRECT_PATH_LIST=""
    REDIRECT_START="https://localhost:3000/multicloud"
    REDIRECT_END="auth/callback"
    for i in ${!AUTH_REDIRECT_PATHS[@]}; do
      REDIRECT_PATH_LIST+='"'"${REDIRECT_START}${AUTH_REDIRECT_PATHS[${i}]}${REDIRECT_END}"'"'
      if (( i != ${#AUTH_REDIRECT_PATHS[@]}-1 )); then
        REDIRECT_PATH_LIST+=', '
      fi
    done
    oc patch oauthclient multicloudingress --patch "{\"redirectURIs\":[${REDIRECT_PATH_LIST}]}"
    printlog info "Ingress patched with: ${REDIRECT_PATH_LIST}"
  fi
fi

printlog title "Information for claimed RHACM cluster (Note: RHACM may be completing final installation steps):"
printlog info "Set KUBECONFIG:\n  export KUBECONFIG=$(echo ${KUBECONFIG})"
printlog info "Lifeguard ClusterClaim directory (containing cluster details and more):\n  cd $(echo ${KUBECONFIG} | sed 's/kubeconfig//')"
