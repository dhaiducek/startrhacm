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
Clone and export paths to the following local repos:

```bash
export LIFEGUARD_PATH= # Path to local Lifeguard repo
export RHACM_DEPLOY_PATH= # Path to local Deploy repo
export RHACM_PIPELINE_PATH= # Path to local Pipeline repo
```

- [Lifeguard](https://github.com/open-cluster-management/lifeguard) - Collection of scripts to claim from ClusterPools
- [Deploy](https://github.com/open-cluster-management/deploy) - Installation scripts for RHACM (see the link for instructions on setting up the pull secret that it uses)
- [Pipeline](https://github.com/open-cluster-management/pipeline/) - Collection of available RHACM snapshots (private repo)

These exports are also included (along with other configurations) in a `utils/config.sh` script. To set up `config.sh` for your own use, customize [`utils/config.sh.template`](./utils/config.sh.template) or your squad-specific template below as desired and rename it to `utils/config.sh`.

### Squad-specific `config.sh` Templates
- GRC - [`config.sh.template-grc`](./utils/config.sh.template-grc)
