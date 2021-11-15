#! /bin/bash

set -e

# Patches all ClusterClaims (except those matching the pipe-separated filter) to hibernate at
#  8 PM EST (1 AM UTC) every day

echo "Using exports (if there's no output, please set these variables and try again):"
echo "* SERVICE_ACCOUNT_NAME: ${SERVICE_ACCOUNT_NAME:-<enter-service-account>}"
echo "* CLUSTERPOOL_TARGET_NAMESPACE: ${CLUSTERPOOL_TARGET_NAMESPACE:-<enter-namespace>}"
echo "* EXCLUSION_FILTER: ${EXCLUSION_FILTER}"

cat >clusterclaim-hibernate.yaml <<EOF
apiVersion: batch/v1beta1
kind: CronJob
metadata:
  name: clusterclaim-hibernate
spec:
#            ┌────────────── minute (0 - 59)
#            │ ┌────────────── hour (0 - 23) (Time in UTC)
#            │ │ ┌───────────── day of the month (1 - 31)
#            │ │ │ ┌───────────── month (1 - 12)
#            │ │ │ │ ┌───────────── day of the week (0 - 6) (Sunday to Saturday)
#            │ │ │ │ │
  schedule: "0 1 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: ${SERVICE_ACCOUNT_NAME}
          containers:
          - name: clusterclaim-hibernate
            image: quay.io/openshift/origin-cli:latest
            imagePullPolicy: IfNotPresent
            command: 
            - /bin/sh
            args:
            - -c
            - "date; for DEPLOYMENT in \$(oc get clusterclaims.hive -n $CLUSTERPOOL_TARGET_NAMESPACE --no-headers -o custom-columns=NAME:metadata.name,DEPLOYMENT:spec.namespace | awk '!/('\$EXCLUSION_FILTER')/ {print \$2}'); do oc patch clusterdeployment \$DEPLOYMENT -n \$DEPLOYMENT --type='merge' -p $'spec:\\\n powerState: Hibernating'; done"
            env:
            - name: EXCLUSION_FILTER
              value: "${EXCLUSION_FILTER}"
          restartPolicy: Never
EOF

echo ""
echo "CronJob YAML created! "
echo "* To apply to the ClusterPool cluster:"
echo "oc apply -n ${CLUSTERPOOL_TARGET_NAMESPACE} -f clusterclaim-hibernate.yaml"
