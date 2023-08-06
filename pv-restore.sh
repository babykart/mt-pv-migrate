#!/usr/bin/env bash

#set -x # debug mode
#set -e # exit on error
set -o pipefail # trace ERR through pipes
set -o errtrace # trace ERR through 'time command' and other functions
#set -o errexit # exit the script if any statement returns a non-true return value

K8S_ENV="$1"
NAMESPACE="$2"
SOURCEPVC="$3"
SOURCEPV="$4"
SOURCESC="$5"
DATE=$(date '+%Y-%m-%d-%H-%M')
SCRIPT_DIR=$(cd -P -- "$(dirname -- "$(dirname $0)")" && pwd -P)
GIT_BIN="${GIT_BIN:-git}"
JQ_BIN="${JQ_BIN:-jq}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
declare -A podreplicas

# usage
usage() {
    echo ">>> Example : ./pv-restore.sh prd mt-prd-bookinfo bookinfo-pvc bookinfo-pv gold"
    echo ">>> First argument supplied is environment name"
    echo ">>> Second argument supplied is namespace name"
    echo ">>> Third argument supplied is source PVC name"
    echo ">>> Fourth argument supplied is source PV name"
    echo ">>> Fifth argument supplied is source StorageClass name"
}

# Die function to exit 1 for any error
die() {
    echo $1
    exit 1
}

# Asking for user to continue or not
pause_scale() {
    UPORDOWN=${1}
    while true; do
      read -p "Scale ${UPORDOWN} your application and press y/Y to continue (Y/N): " confirm
      case ${confirm} in
      y|Y)
        return 0
        ;;

      n|N)
        die "Operation interrupted by user"
        ;;

      *)
        echo "Wrong argument, please use yY or nN"
        continue
        ;;
      esac
      break
    done
}

# Check if required binaries are in the PATH
bin_check() {
    command -v ${GIT_BIN} >/dev/null 2>&1 || die "The git binary is not in your PATH"
    command -v ${JQ_BIN} >/dev/null 2>&1 || die "The jq binary is not in your PATH"
    command -v ${KUBECTL_BIN} >/dev/null 2>&1 || die "The kubectl binary is not in your PATH"
}

# checking storage classes
sc_check() {
    OLDSCNAME=$(${KUBECTL_BIN} get pv ${SOURCEPV} -ojson | ${JQ_BIN} -r '.spec.storageClassName' | awk -F'backup-' '{print $2}')
    if [[ ${OLDSCNAME} != ${SOURCESC} ]]; then
      die "Storage Class given ${SOURCESC} and Storage Classe collected from Old PV ${OLDSCNAME} don't match"
    fi
}

# create backup dir with all the manifests
restore_dir() {
    echo ">>> Creating restore dir ${SCRIPT_DIR}/${K8S_ENV}/restore/${NAMESPACE}/${SOURCEPVC}/${DATE}"
    mkdir -p ${SCRIPT_DIR}/${K8S_ENV}/restore/${NAMESPACE}/${SOURCEPVC}/${DATE}
    cd ${SCRIPT_DIR}/${K8S_ENV}/restore/${NAMESPACE}/${SOURCEPVC}/${DATE}
    ${KUBECTL_BIN} get pvc ${SOURCEPVC} -n ${NAMESPACE} -oyaml | kubectl-neat > ./${SOURCEPVC}-restore.yaml
}

# Delete Migrated PVC
delete_migrated_pvc() {
    echo ">>> Deleting Migrated PVC ${SOURCEPVC} and its bounded PV"
    ${KUBECTL_BIN} delete pvc ${SOURCEPVC} -n ${NAMESPACE}
}

# restore the source PVC
restore_source_pvc() {
    cd ${SCRIPT_DIR}/${K8S_ENV}/restore/${NAMESPACE}/${SOURCEPVC}/${DATE}
    cp ./${SOURCEPVC}-restore.yaml ./${SOURCEPVC}-apply.yaml
    sed -i -e 's/storageClassName: .*$/storageClassName: '${SOURCESC}'/g' ./${SOURCEPVC}-apply.yaml
    sed -i -e 's/volumeName: .*/volumeName: '${SOURCEPV}'/g' ./${SOURCEPVC}-apply.yaml
    sed -i -e '/pv\.kubernetes\.io.*/d' ./${SOURCEPVC}-apply.yaml
    sed -i -e '/volume\..*/d' ./${SOURCEPVC}-apply.yaml
    echo ">>> ${DESTPVC} PVC creation ..." 
    ${KUBECTL_BIN} apply -f ./${SOURCEPVC}-apply.yaml || die "PVC Destination creation failed"
    echo ">>> Waiting 5 secs for the PVC ${SOURCEPVC} to be created"
    sleep 5
}

# patch PV with Reclaim Policy Retain
patch_pv() {
    echo ">>> Patching Source PV ${SOURCEPV} for StorageClass"
    ${KUBECTL_BIN} patch pv ${SOURCEPV} -p '{"spec":{"storageClassName":"'${SOURCESC}'"}}' || die "Source PV patch failed"
}

# Patching PV to Delete Reclaim Policy
pv_policy_patch() {
    echo ">>> Patching Source PV ${SOURCEPV} with Delete Reclaim Policy"
    ${KUBECTL_BIN} patch pv ${SOURCEPV} -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}' || die "Source PV ReclaimPolicy patch Failed"
}

# adding restoration files and push
git_push() {
    echo ">>> Adding restoration files to git and pushing"
    cd ${SCRIPT_DIR}
    ${GIT_BIN} add ./${K8S_ENV}/restore/${NAMESPACE}
    ${GIT_BIN} commit -a -m "PVC ${SOURCEPVC} restoration at ${DATE}"
    ${GIT_BIN} push
}

main() {
    if [ $# -eq 0 ]; then
        echo "No argument supplied."
        usage
        exit 1
    else
        if  [ -z "$1" ]; then
            echo "First argument supplied is invalid, need environment name"
            exit 1
        elif [ -z "$2" ]; then
            echo "Second argument supplied is invalid, need namespace name"
            exit 1
        elif [ -z "$3" ]; then
            echo "Third argument supplied is invalid, need Source PVC name"
            exit 1
        elif [ -z "$4" ]; then
            echo "Fourth argument supplied is invalid, need Source PV name"
            exit 1
        elif [ -z "$5" ]; then
            echo "Fifth argument supplied is invalid, need Source StorageClass name"
            exit 1
        fi
    fi
    bin_check
    sc_check
    restore_dir
    pause_scale down
    delete_migrated_pvc
    restore_source_pvc
    patch_pv
    pause_scale up
    pv_policy_patch
    git_push
}

main "${@}"
