# startrhacm
Deploy Red Hat Advanced Cluster Management (RHACM) via ClusterPool

```bash
./startrhacm.sh
```



## Prerequisites
Export paths to the following repos:

```bash
export LIFEGUARD_PATH= # Path to local Lifeguard repo
export RHACM_PIPELINE_PATH= # Path to local Pipeline repo
export RHACM_DEPLOY_PATH= # Path to local Deploy repo
```

- [Lifeguard](https://github.com/open-cluster-management/lifeguard) - Collection of scripts to claim from ClusterPools
- [Deploy](https://github.com/open-cluster-management/deploy) - Installation scripts for RHACM
- [Pipeline](https://github.com/open-cluster-management/pipeline/) - Collection of available RHACM snapshots (private repo)

These exports can also included (along with other configurations) in a `utils/config.sh` script. To set up `config.sh` for your own use, customize [`utils/config.sh.template`](./utils/config.sh.template) as desired and rename it to `utils/config.sh`.

### Squad-specific `config.sh` Templates
- GRC - [`config.sh.template-grc`](./utils/config.sh.template-grc)