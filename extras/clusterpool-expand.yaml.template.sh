#! /bin/bash

set -e

# Patches all ClusterPools to grow to CLUSTERPOOL_MAX (default: 1) at 6 AM EST (11 AM UTC) Monday - Friday

CLUSTERPOOL_MAX=${CLUSTERPOOL_MAX:-1}

echo "Using exports (if there's no output, please set these variables and try again):"
echo "* SERVICE_ACCOUNT_NAME: ${SERVICE_ACCOUNT_NAME:-<enter-service-account>}"
echo "* CLUSTERPOOL_TARGET_NAMESPACE: ${CLUSTERPOOL_TARGET_NAMESPACE:-<enter-namespace>}"
echo "* CLUSTERPOOL_MIN: ${CLUSTERPOOL_MIN}"

cat >clusterpool-expand.yaml <<EOF
apiVersion: batch/v1beta1
kind: CronJob
metadata:
  name: clusterpool-expand
spec:
#            ┌───────────── minute (0 - 59)
#            │ ┌───────────── hour (0 - 23) (Time in UTC)
#            │ │  ┌───────────── day of the month (1 - 31)
#            │ │  │ ┌───────────── month (1 - 12)
#            │ │  │ │ ┌───────────── day of the week (0 - 6) (Sunday to Saturday)
#            │ │  │ │ │
  schedule: "0 11 * * 1-5"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: ${SERVICE_ACCOUNT_NAME}
          containers:
          - name: clusterpool-expand
            image: quay.io/openshift/origin-cli:latest
            imagePullPolicy: IfNotPresent
            command: 
            - /bin/sh
            args:
            - -c
            - date; oc scale clusterpool -n ${CLUSTERPOOL_TARGET_NAMESPACE} --all --replicas=${CLUSTERPOOL_MAX}
          restartPolicy: Never
EOF

echo ""
echo "CronJob YAML created! "
echo "* To apply to the ClusterPool cluster:"
echo "oc apply -n ${CLUSTERPOOL_TARGET_NAMESPACE} -f clusterpool-expand.yaml"
