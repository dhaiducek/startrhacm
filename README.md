# startrhacm

Deploy Red Hat Advanced Cluster Management (RHACM) via ClusterPool

```bash
./startrhacm.sh
```

## Features

- Claims an OpenShift cluster from a ClusterPool and deploys Upstream or Downstream RHACM of any available branch (x.x), version (x.x.x), or snapshot
- (optional) Automatically resizes a specified pool if the pool isn't large enough
- (optional) Patch the cluster to accept connections from localhost paths for development
- `startrhacm.sh` can be aliased and run from anywhere on your computer:
  ```bash
  alias startrhacm="${PATH_TO_STARTRHACM}/startrhacm.sh"
  ```

## Prerequisites

### Clone the following repos:

- [Lifeguard](https://github.com/stolostron/lifeguard) - Collection of scripts to claim from ClusterPools
- [Deploy](https://github.com/stolostron/deploy) - Installation scripts for RHACM
  - _Be sure to set up your pull secret for Deploy ([see Deploy documentation](https://github.com/stolostron/deploy#prepare-to-deploy-open-cluster-management-instance-only-do-once))_
- [Pipeline](https://github.com/stolostron/pipeline/) - Collection of available RHACM snapshots (private repo)
  - _Exception: Pipeline is not necessary if the full snapshot is provided via RHACM_SNAPSHOT_

### Setup config scripts

Exports are contained in a `config.sh` script (but they can also be exported outside of the script if desired). To set up `config.sh` for your own use, customize [`utils/config.sh.template`](./utils/config.sh.template) or your squad-specific template below as desired and rename it to `utils/config.sh`.

- **Required**: Set paths to cloned repos
  ```bash
  export LIFEGUARD_PATH= # Path to local Lifeguard repo
  export RHACM_DEPLOY_PATH= # Path to local Deploy repo
  export RHACM_PIPELINE_PATH= # Path to local Pipeline repo (optional only if deploying downstream or RHACM_SNAPSHOT is specified directly)
  ```
- Optionally configure other variables as indicated in the comments in [`utils/config.sh.template`](./utils/config.sh.template) (if optional variables are not provided, the `startrhacm.sh` script will prompt you for ClusterClaim options and will deploy the latest upstream RHACM snapshot)
- Set up file permissions for the config script to be executable
  ```bash
  chmod +x ./utils/config.sh
  ```

### Configure `oc` CLI to point to the Collective cluster

You'll need to be logged in to the Collective cluster that hosts ClusterPools. If you're not, `startrhacm.sh` will detect this and provide you with the [link to the login command](https://oauth-openshift.apps.collective.aws.red-chesterfield.com/oauth/token/request). (If you're using a different ClusterPool cluster, you can disable this check by setting `export DISABLE_CLUSTER_CHECK="true"`)

### Squad-specific `config.sh` Templates

- GRC - [`config.sh.template-grc`](./utils/config.sh.template-grc)

## Extras

- Shrink and/or expand ALL ClusterPool sizes on a schedule using a CronJob. By default, schedules are set to shrink to 1 at 8 PM EST (1 AM UTC) every day and expand to 2 at 6 AM EST (11 AM UTC) Monday - Friday
  ```bash
  cd extras
  export CLUSTERPOOL_TARGET_NAMESPACE=<namespace>
  export SERVICE_ACCOUNT_NAME=<service-account-name>
  ./clusterpool-shrink.yaml.template.sh
  ./clusterpool-expand.yaml.template.sh
  oc apply -f .
  ```
