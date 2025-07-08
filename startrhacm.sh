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

printlog title "Displaying startrhacm variables"
printlog info "LIFEGUARD_PATH=${LIFEGUARD_PATH}"
printlog info "DISABLE_CLUSTER_CHECK=${DISABLE_CLUSTER_CHECK}"
printlog info "KUBECONFIG=${KUBECONFIG}"
printlog info "CLUSTERPOOL_MIN_SIZE=${CLUSTERPOOL_MIN_SIZE}"
printlog info "CLUSTERPOOL_NAME=${CLUSTERPOOL_NAME}"
printlog info "CLUSTERPOOL_TARGET_NAMESPACE=${CLUSTERPOOL_TARGET_NAMESPACE}"
printlog info "CLUSTERPOOL_POST_DEPLOY_SIZE=${CLUSTERPOOL_POST_DEPLOY_SIZE}"
printlog info "CLUSTERCLAIM_NAME=${CLUSTERCLAIM_NAME}"
printlog info "CLUSTERCLAIM_END_TIME=${CLUSTERCLAIM_END_TIME}"
printlog info "ACM_CATALOG_TAG=${ACM_CATALOG_TAG}"
printlog info "TARGET_NAMESPACE=${TARGET_NAMESPACE}"

if [[ -z "${LIFEGUARD_PATH}" ]]; then
  printlog error "LIFEGUARD_PATH not defined. Please set LIFEGUARD_PATH to the local path of the Lifeguard repo."
  exit 1
else
  if (! ls "${LIFEGUARD_PATH}" &>/dev/null); then
    printlog error "Error getting to Lifeguard repo. Is LIFEGUARD_PATH set properly? Currently it's set to: ${LIFEGUARD_PATH}"
    exit 1
  fi
fi

# Load configuration
printlog title "Loading configuration from utils/config.sh"
SCRIPT_FULLPATH=$(realpath "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(dirname "${SCRIPT_FULLPATH}")
if ls "${SCRIPT_DIR}"/utils/config.sh &>/dev/null; then
  if (! "${SCRIPT_DIR}"/utils/config.sh); then
    printlog error "Error running configuration script. Is the script executable? If not, run: chmod +x ${SCRIPT_DIR}/utils/config.sh"
    exit 1
  else
    source "${SCRIPT_DIR}"/utils/config.sh
  fi
else
  printlog info "config.sh script not found"
  printlog info "(Location checked for script: ${SCRIPT_DIR}/utils/config.sh)"
fi

# Verify we're pointed to the collective cluster
if [[ "${DISABLE_CLUSTER_CHECK}" != "true" ]]; then
  CLUSTER=$(oc config get-contexts | awk '/^\052/ {print $3}' | awk '{gsub("^api-",""); gsub("(\\/|-red-chesterfield).*",""); print}')
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
else
  printlog info "Cluster check has been disabled. Verifying login."
  if (! oc status &>/dev/null); then
    printlog error "Error verifying cluster login. Please make sure you're logged in to a ClusterPool cluster."
    exit 1
  fi
fi

# Check to see whether the ClusterPool meets the minimum size
if [[ -n "${CLUSTERPOOL_MIN_SIZE}" ]] && [[ -n "${CLUSTERPOOL_NAME}" ]] && [[ -n "${CLUSTERPOOL_TARGET_NAMESPACE}" ]]; then
  # If a ClusterClaim name was specified and it already exists, we'll continue on without checking pool size since it'll patch it
  if [[ -z "${CLUSTERCLAIM_NAME}" ]] || ( [[ -n "${CLUSTERCLAIM_NAME}" ]] && (! oc get clusterclaim.hive -n "${CLUSTERPOOL_TARGET_NAMESPACE}" "${CLUSTERCLAIM_NAME}" &>/dev/null) ); then
    printlog title "Checking for pool size for ClusterPool ${CLUSTERPOOL_NAME}"
    POOL_SIZE=$(oc get clusterpool.hive -n "${CLUSTERPOOL_TARGET_NAMESPACE}" "${CLUSTERPOOL_NAME}" -o jsonpath={.spec.size})
    if (( POOL_SIZE < CLUSTERPOOL_MIN_SIZE )); then
      printlog info "The ClusterPool size ${POOL_SIZE} does not meet the minimum of ${CLUSTERPOOL_MIN_SIZE}. Patching the ClusterPool to increase the size of the pool."
      oc scale clusterpool.hive "${CLUSTERPOOL_NAME}" -n "${CLUSTERPOOL_TARGET_NAMESPACE}" --replicas="${CLUSTERPOOL_MIN_SIZE}"
    fi
  fi
fi

# Claim cluster from ClusterPool
printlog title "Creating ClusterClaim from ClusterPool ${CLUSTERPOOL_NAME}"
CLAIM_DIR=${LIFEGUARD_PATH}/clusterclaims
cd "${CLAIM_DIR}"
printlog info "Switching to main branch and updating repo (if this exits, check the state of the local Lifeguard repo)"
git checkout main &>/dev/null
git pull &>/dev/null
# Set lifetime of claim to end of work day
if [[ -n "${CLUSTERCLAIM_END_TIME}" ]]; then
  printlog info "Setting CLUSTERCLAIM_LIFETIME to end at hour ${CLUSTERCLAIM_END_TIME} of a 24 hour clock"
  if [[ -n "${CLUSTERCLAIM_NAME}" ]] && (oc get clusterclaim.hive "${CLUSTERCLAIM_NAME}" -n "${CLUSTERPOOL_TARGET_NAMESPACE}" &>/dev/null); then
    printlog error "Found existing claim with name ${CLUSTERCLAIM_NAME}, so its lifetime (which is based on its creation time) will not be recalculated."
    export CLUSTERCLAIM_LIFETIME=$(oc get clusterclaim.hive "${CLUSTERCLAIM_NAME}" -n "${CLUSTERPOOL_TARGET_NAMESPACE}" -o jsonpath='{.spec.lifetime}')
    printlog error "Using claim's existing lifetime of ${CLUSTERCLAIM_LIFETIME}. If a different lifetime is desired, please manually edit the claim."
  else
    export CLUSTERCLAIM_LIFETIME="$((${CLUSTERCLAIM_END_TIME}-$(date "+%-H")-1))h$((60-$(date "+%-M")))m"
  fi
fi
./apply.sh

printlog title "Setting KUBECONFIG and checking cluster access"
# Save the current KUBECONFIG in case we need it
PREVIOUS_KUBECONFIG=${KUBECONFIG}
# If we have a ClusterClaim name, use that to get the kubeconfig, otherwise just get the most recently modified (which is most likely the one we need)
if [[ -n "${CLUSTERCLAIM_NAME}" ]]; then
  export KUBECONFIG=$(ls "${CLAIM_DIR}"/"${CLUSTERCLAIM_NAME}"/kubeconfig)
else
  export KUBECONFIG=$(ls -dt1 "${CLAIM_DIR}"/*/kubeconfig | head -n 1)
fi
# Set namespace context in case it wasn't set or we're inside a pod specifying a different namespace in env
oc config set-context --current --namespace=default
# Verify cluster access
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

if [[ -n "${ACM_CATALOG_TAG}" ]]; then
  printlog title "Installing Konflux build"
  "${SCRIPT_DIR}"/start-konflux.sh
else
  printlog title "Installing using deploy repo"
  "${SCRIPT_DIR}"/start-deploy.sh
fi

if (( $? != 0 )); then
  printlog error "An error occurred while installing"
fi

# Set CLI to point to RHACM namespace
printlog title "Setting oc CLI context to ${TARGET_NAMESPACE} namespace"
oc config set-context --current --namespace="${TARGET_NAMESPACE}"

printlog title "Information for claimed RHACM cluster (Note: RHACM may be completing final installation steps):"
printlog info "Set KUBECONFIG:\n  export KUBECONFIG=${KUBECONFIG}"
printlog info "Lifeguard ClusterClaim directory (containing cluster details and more):\n  cd $(echo "${KUBECONFIG}" | sed 's/kubeconfig//')"

# Set ClusterPool to target size post-deployment
if [[ -n "${CLUSTERPOOL_POST_DEPLOY_SIZE}" ]]; then
  printlog info "Scaling ClusterPool ${CLUSTERPOOL_NAME} to ${CLUSTERPOOL_POST_DEPLOY_SIZE}"
  export KUBECONFIG=${PREVIOUS_KUBECONFIG}
  oc scale clusterpool.hive "${CLUSTERPOOL_NAME}" -n "${CLUSTERPOOL_TARGET_NAMESPACE}" --replicas="${CLUSTERPOOL_POST_DEPLOY_SIZE}"
fi
