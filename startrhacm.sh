#! /bin/bash

set -e

# Path to Git directories
GIT_DIR=${GIT_DIR:-${HOME}}
LIFEGUARD_PATH=${LIFEGUARD_PATH:-${GIT_DIR}/lifeguard}
RHACM_PIPELINE_PATH=${RHACM_PIPELINE_PATH:-${GIT_DIR}/pipeline}
RHACM_DEPLOY_PATH=${RHACM_DEPLOY_PATH:-${GIT_DIR}/deploy}

# User exports
CLUSTERPOOL_USER=${CLUSTERPOOL_USER:-"$(id -un)"} # User for labeling
GROUP_NAME=${CLUSTERCLAIM_GROUP_NAME:-${CLUSTERPOOL_USER}} # RBAC group in cluster (also used for labeling)
AUTH_REDIRECT_PATHS=("" "policies/" "header/" "topology/" "applications/" "clusters/" "overview/" "bare-metal-assets/" "search/")

# ClusterClaim exports
export OCP_VERSION=${OCP_VERSION:-"4.6.8"}
export CLUSTERPOOL_TARGET_NAMESPACE=${CLUSTERPOOL_TARGET_NAMESPACE:-""}
export CLUSTERPOOL_NAME=${CLUSTERPOOL_NAME:-"${GROUP_NAME}-cp-v$(echo ${OCP_VERSION} | sed 's/\.//g')"}
export CLUSTERCLAIM_NAME=${CLUSTERCLAIM_NAME:-"${CLUSTERPOOL_USER}-${CLUSTERPOOL_NAME}"}
export CLUSTERCLAIM_GROUP_NAME=${CLUSTERCLAIM_GROUP_NAME:-""}
CLUSTERCLAIM_END_TIME=${CLUSTERCLAIM_END_TIME:-18} # Integer hour in 24h clock at which to expire the cluster

# RHACM configuration
RHACM_VERSION=${RHACM_VERSION:-""} # Override version--must be three-digit version like 1.2.3

# Verify we're pointed to the collective cluster
CLUSTER=$(oc config get-contexts | awk '/^\052/ {print $3}' | awk '{gsub("^api-",""); gsub("(\/|-red-chesterfield).*",""); print}')
if [[ "${CLUSTER}" != "collective-aws" ]] || (! oc status &>/dev/null); then
        echo "The oc CLI is not currently logged in to the collective cluster. Please configure the CLI and try again."
	echo "Current cluster: ${CLUSTER}"
	echo "Link to Collective cluster login command: https://oauth-openshift.apps.collective.aws.red-chesterfield.com/oauth/token/request"
	exit 1
fi

# Create cluster from ClusterPool
echo "##### Creating ClusterClaim from ClusterPool ${CLUSTERPOOL_NAME}..."
cd ${LIFEGUARD_PATH}/clusterclaims
# Set lifetime to end of work day
export CLUSTERCLAIM_LIFETIME="$((${CLUSTERCLAIM_END_TIME}-$(date "+%-H")-1))h$((60-$(date "+%-M")))m"
./apply.sh
CLAIM_DIR="$(pwd)/${CLUSTERCLAIM_NAME}"
echo "##### Logging in to created cluster..."
chmod +x ${CLUSTERCLAIM_NAME}/oc-login.sh
while (! $(pwd)/${CLUSTERCLAIM_NAME}/oc-login.sh); do
        sleep 20
done

# Get snapshot (default is latest)
echo "##### Getting latest snapshot for latest version of RHACM (override version with RHACM_VERSION)..."
cd ${RHACM_PIPELINE_PATH}
git pull &>/dev/null
RHACM_BRANCH=$(echo ${RHACM_VERSION} | grep -o "[[:digit:]]\+\.[[:digit:]]\+" || true) # Create Pipeline branch from version, if specified
BRANCH=${RHACM_BRANCH:-$(git remote show origin | grep -o " [0-9]\.[0-9]-" | sort -u | tail -1 | grep -o "[0-9]\.[0-9]")}
VERSION_NUM=${RHACM_VERSION:="${BRANCH}.0"}
git checkout ${BRANCH}-edge &>/dev/null
SNAPSHOT_TAG=$(ls ${RHACM_PIPELINE_PATH}/snapshots/manifest-* | grep ${VERSION_NUM} | tail -n 1 | grep -o "[[:digit:]]\{4\}\(-[[:digit:]]\{2\}\)\{5\}")

# Deploy RHACM (defaults to latest snapshot)
cd ${RHACM_DEPLOY_PATH}
echo "${VERSION_NUM}-SNAPSHOT-${SNAPSHOT_TAG}" > snapshot.ver
./start.sh --silent

# Set CLI to point to RHACM namespace
echo "##### Setting oc CLI context to open-cluster-management namespace..."
oc config set-context --current --namespace=open-cluster-management

# Configure auth to allow requests from localhost
echo "##### Waiting for ingress to be running to configure localhost connections..."
while (! oc get oauthclient multicloudingress); do
	sleep 20
done
REDIRECT_PATH_LIST=""
REDIRECT_START="https://localhost:3000/multicloud/"
REDIRECT_END="auth/callback"
for i in ${!AUTH_REDIRECT_PATHS[@]}; do
	REDIRECT_PATH_LIST+='"'"${REDIRECT_START}${AUTH_REDIRECT_PATHS[${i}]}${REDIRECT_END}"'"'
	if (( i != ${#AUTH_REDIRECT_PATHS[@]}-1 )); then
		REDIRECT_PATH_LIST+=', '
	fi
done
oc patch oauthclient multicloudingress --patch "{\"redirectURIs\":[${REDIRECT_PATH_LIST}]}"

echo "##### Path to ClusterClaim directory:"
echo "cd ${CLAIM_DIR}"
