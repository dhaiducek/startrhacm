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

- [Lifeguard](https://github.com/open-cluster-management/lifeguard) - Collection of scripts to claim from ClusterPools
- [Deploy](https://github.com/open-cluster-management/deploy) - Installation scripts for RHACM
  -  **Setup pull secret (see the link for instructions on setting up the pull secret that it uses)**
- [Pipeline](https://github.com/open-cluster-management/pipeline/) - Collection of available RHACM snapshots (private repo)


### Setup config scripts

To set up `config.sh` for your own use, customize [`utils/config.sh.template`](./utils/config.sh.template) or your squad-specific template below as desired and rename it to `utils/config.sh`.

- Set path to cloned repos
```bash
export LIFEGUARD_PATH= # Path to local Lifeguard repo
export RHACM_DEPLOY_PATH= # Path to local Deploy repo
export RHACM_PIPELINE_PATH= # Path to local Pipeline repo
```
- Optionally configure other variables as indicated in the comments

- (on Mac) May need to setup file permissions for the config scripts
```bash
chmod +x ./utils/config.sh
```

### Configure oc cli to the collective cluster
[Link to Collective cluster login command](https://oauth-openshift.apps.collective.aws.red-chesterfield.com/oauth/token/request)

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
