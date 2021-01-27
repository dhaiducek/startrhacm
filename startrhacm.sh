#! /bin/bash

set -e

# Helper function to check exports
function checkexports() {
	if [[ -z ${LIFEGUARD_PATH} ]]; then
		echo "^^^^^ LIFEGUARD_PATH not defined. Please set LIFEGUARD_PATH to the local path of the Lifeguard repo."
		exit 1
	else
		if (! ls ${LIFEGUARD_PATH} &>/dev/null); then
			echo "^^^^^ Error getting to Lifeguard repo. Is LIFEGUARD_PATH set properly? Currently it's set to: ${LIFEGUARD_PATH}"
			exit 1
		fi
	fi
	if [[ -z ${RHACM_PIPELINE_PATH} ]]; then
		echo "^^^^^ RHACM_PIPELINE_PATH not defined. Please set RHACM_PIPELINE_PATH to the local path of the Pipeline repo."
		exit 1
	else
		if (! ls ${RHACM_PIPELINE_PATH} &>/dev/null); then
			echo "^^^^^ Error getting to Pipeline repo. Is RHACM_PIPELINE_PATH set properly? Currently it's set to: ${RHACM_PIPELINE_PATH}"
			exit 1
		fi
	fi
	if [[ -z ${RHACM_DEPLOY_PATH} ]]; then
		echo "^^^^^ RHACM_DEPLOY_PATH not defined. Please set RHACM_DEPLOY_PATH to the local path of the Deploy repo."
		exit 1
	else
		if (! ls ${RHACM_DEPLOY_PATH} &>/dev/null); then
			echo "^^^^^ Error getting to Deploy repo. Is RHACM_DEPLOY_PATH set properly? Currently it's set to: ${RHACM_DEPLOY_PATH}"
			exit 1
		fi
	fi
}

# Load configuration
echo "##### Loading configuration from utils/config.sh ..."
SCRIPT_DIR=$(dirname "${BASH_SOURCE[0]}")
if ls ${SCRIPT_DIR}/utils/config.sh &>/dev/null; then
	if (! ${SCRIPT_DIR}/utils/config.sh); then
		echo "^^^^^ Error running configuration script. Is the script executable? If not, run: chmod +x ${SCRIPT_DIR}/utils/config.sh"
		exit 1
	else
		source ${SCRIPT_DIR}/utils/config.sh
		checkexports
	fi
else
	echo "* config.sh script not found--checking exports for LIFEGUARD_PATH, RHACM_PIPELINE_PATH, and RHACM_DEPLOY_PATH"
	checkexports
fi

# Verify we're pointed to the collective cluster
CLUSTER=$(oc config get-contexts | awk '/^\052/ {print $3}' | awk '{gsub("^api-",""); gsub("(\/|-red-chesterfield).*",""); print}')
if [[ "${CLUSTER}" != "collective-aws" ]] || (! oc status &>/dev/null); then
        echo "The oc CLI is not currently logged in to the collective cluster. Please configure the CLI and try again."
	echo "Current cluster: ${CLUSTER}"
	echo "Link to Collective cluster login command: https://oauth-openshift.apps.collective.aws.red-chesterfield.com/oauth/token/request"
	exit 1
fi

# Claim cluster from ClusterPool
echo "##### Creating ClusterClaim from ClusterPool ${CLUSTERPOOL_NAME} ..."
export CLAIM_DIR=${LIFEGUARD_PATH}/clusterclaims
cd ${CLAIM_DIR}
git pull &>/dev/null
# Set lifetime of claim to end of work day
if [[ -n ${CLUSTERCLAIM_END_TIME} ]]; then
	export CLUSTERCLAIM_LIFETIME="$((${CLUSTERCLAIM_END_TIME}-$(date "+%-H")-1))h$((60-$(date "+%-M")))m"
fi
./apply.sh
echo "##### Setting KUBECONFIG and checking cluster access ..."
export KUBECONFIG=$(ls -dt1 ${CLAIM_DIR}/*/kubeconfig | head -n 1)
ATTEMPTS=0
MAX_ATTEMPTS=15
while (! oc status) && (( ${ATTEMPTS} < ${MAX_ATTEMPTS} )); do
  echo "^^^^^ Error logging in to cluster. Trying again...(Attempt $((++ATTEMPTS))/${MAX_ATTEMPTS})"
  sleep 20
done
if (( ${ATTEMPTS} == 15 )); then
  echo "^^^^^ Failed to login to cluster. Exiting."
  exit 1
fi

# Get snapshot (defaults to latest edge version)
echo "##### Getting snapshot for RHACM (defaults to latest edge version -- override version with RHACM_VERSION) ..."
cd ${RHACM_PIPELINE_PATH}
git pull &>/dev/null
RHACM_BRANCH=${RHACM_BRANCH:-$(echo "${RHACM_VERSION}" | grep -o "[[:digit:]]\+\.[[:digit:]]\+" || true)} # Create Pipeline branch from version, if specified
BRANCH=${RHACM_BRANCH:-$(git remote show origin | grep -o " [0-9]\.[0-9]-" | sort -uV | tail -1 | grep -o "[0-9]\.[0-9]")}
VERSION_NUM=${RHACM_VERSION:=""}
PIPELINE_PHASE=${PIPELINE_PHASE:-"edge"}
echo "* Updating repo and switching to the ${BRANCH}-${PIPELINE_PHASE} branch (if this exits, check the state of the local Pipeline repo)"
git checkout ${BRANCH}-${PIPELINE_PHASE} &>/dev/null
git pull &>/dev/null
MANIFEST_TAG=$(ls ${RHACM_PIPELINE_PATH}/snapshots/manifest-* | grep "${VERSION_NUM}" | tail -n 1 | grep -o "[[:digit:]]\{4\}\(-[[:digit:]]\{2\}\)\{5\}.*")
SNAPSHOT_TAG=$(echo ${MANIFEST_TAG} | grep -o "[[:digit:]]\{4\}\(-[[:digit:]]\{2\}\)\{5\}")
VERSION_NUM=$(echo ${MANIFEST_TAG} | grep -o "\([[:digit:]]\+\.\)\{2\}[[:digit:]]\+")
if [[ -n ${RHACM_VERSION} && "${RHACM_VERSION}" != "${VERSION_NUM}" ]]; then
	echo "^^^^^ There's an unexpected mismatch between the version provided, ${RHACM_VERSION}, and the version found, ${VERSION_NUM}. Please double check the Pipeline repo before continuing."
	exit 1
fi
echo "* Using RHACM snapshot: ${VERSION_NUM}-SNAPSHOT-${SNAPSHOT_TAG}"

# Deploy RHACM (defaults to latest edge snapshot)
echo "##### Deploying Red Hat Advanced Cluster Management ..."
cd ${RHACM_DEPLOY_PATH}
echo "* Updating repo and switching to the master branch (if this exits, check the state of the local Deploy repo)"
git checkout master &>/dev/null
git pull &>/dev/null
echo "${VERSION_NUM}-SNAPSHOT-${SNAPSHOT_TAG}" > ${RHACM_DEPLOY_PATH}/snapshot.ver
./start.sh --silent

# Set CLI to point to RHACM namespace
echo "##### Setting oc CLI context to open-cluster-management namespace ..."
oc config set-context --current --namespace=open-cluster-management

# Configure auth to allow requests from localhost
if [[ -n ${AUTH_REDIRECT_PATHS} ]]; then
	echo "##### Waiting for ingress to be running to configure localhost connections ..."
	ATTEMPTS=0
	MAX_ATTEMPTS=15
	while (! oc get oauthclient multicloudingress); do
		echo "^^^^^ Error finding ingress. Trying again...(Attempt $((++ATTEMPTS))/${MAX_ATTEMPTS})"
		sleep 20
	done
	if (( ${ATTEMPTS} == 15 )); then
		echo "^^^^^ Ingress not patched. Please check your RHACM deployment."
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
		echo "* Ingress patched with: "${REDIRECT_PATH_LIST}
	fi
fi

echo "##### KUBECONFIG for claimed cluster:"
echo "export KUBECONFIG=$(echo ${KUBECONFIG})"
