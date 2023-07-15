# PV-migrate

This bash script suite allows you :

* to make an inventory of the PCVs, their PV and the associated pods (StatefulSet or Deployment) of the same namespace,
* to copy the data between two PVCs of the same namespace and to migrate the PVCs and therefore their associated PV,
* to roll back, i.e., to link the old PV in the original PVC.

The data copy relies on the [pv-migrate](https://github.com/utkuozdemir/pv-migrate) utility.

## Requirements

You need the following commands in your PATH :

* `git`,
* `kubectl`,
* `pv-migrate`,
* `jq`,
* and obviously the coreutils (`awk`, `tr`, `mkdir`, `mv`...).

If these binaries are located in a custom path, you need to export the corresponding variable to your environment :

```shell
export GIT_BIN=/my/absolute/path/to/git
export JQ_BIN=/my/absolute/path/to/jq
export KUBECTL_BIN=/my/absolute/path/to/kubectl
export PV_MIGRATE_BIN=/my/absolute/path/to/pv-migrate
```

## pv-inventory.sh

### Usage

```shell
./pv-inventory.sh
```

```shell
No argument supplied.
>>> Example : ./pv-inventory.sh prd mt-prd-bookinfo
>>> First argument supplied is environment name
>>> Second argument supplied is namespace name
```

## pv-migrate.sh

### Usage

```shell
./pv-migrate.sh
```

```shell
No argument supplied.
>>> Example : ./pv-migrate.sh presync prd mt-prd-bookinfo bookinfo-pvc
>>> Example : ./pv-migrate.sh migrate prd mt-prd-bookinfo bookinfo-pvc
>>> First argument supplied is presync or migrate
>>> Second argument supplied is environment name
>>> Third argument supplied is namespace name
>>> Fourth argument supplied is source PVC name
```

## pv-restore.sh

### Usage

```shell
./pv-restore.sh
```

```shell
No argument supplied.
>>> Example : ./pv-restore.sh prd mt-prd-bookinfo bookinfo-pvc bookinfo-pv gold
>>> First argument supplied is environment name
>>> Second argument supplied is namespace name
>>> Third argument supplied is source PVC name
>>> Fourth argument supplied is source PV name
>>> Fifth argument supplied is source StorageClass name
```

## TODO

* Migrate between two Kubernetes clusters
* Rewrite in Go
