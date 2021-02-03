#! /bin/bash

set -e

echo "Using exports (if there's no output, please set these variables and try again):"
echo "* SERVICE_ACCOUNT_NAME: ${SERVICE_ACCOUNT_NAME}"
echo "* CLUSTERPOOL_TARGET_NAMESPACE: ${CLUSTERPOOL_TARGET_NAMESPACE}"

cat >clusterpool-shrink.yaml <<EOF
apiVersion: batch/v1beta1
kind: CronJob
metadata:
  name: clusterpool-shrink
spec:
#            ┌────────────── minute (0 - 59)
#            │ ┌────────────── hour (0 - 23)
#            │ │  ┌───────────── day of the month (1 - 31)
#            │ │  │ ┌───────────── month (1 - 12)
#            │ │  │ │ ┌───────────── day of the week (0 - 6) (Sunday to Saturday;
#            │ │  │ │ │                                   7 is also Sunday on some systems)
#            │ │  │ │ │
#            │ │  │ │ │
  schedule: "* 20 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: ${SERVICE_ACCOUNT_NAME}
          containers:
          - name: clusterpool-shrink
            image: bitnami/kubectl:latest
            imagePullPolicy: IfNotPresent
            command: 
            - /bin/sh
            args:
            - -c
            - date; for pool in \$(kubectl get clusterpool -n ${CLUSTERPOOL_TARGET_NAMESPACE} -o name); do kubectl patch \${pool} -n ${CLUSTERPOOL_TARGET_NAMESPACE} --type merge --patch '{"spec":{"size":"1"}}'; done
          restartPolicy: OnFailure
EOF

echo ""
echo "CronJob YAML created!"
echo "* To apply to the cluster:"
echo "oc apply -f clusterpool-shrink.yaml"