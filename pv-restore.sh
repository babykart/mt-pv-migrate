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

# Die function to exit 1 for any error
die() {
    echo $1
    exit 1
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

# First you need to scale down your application that use the pvc
scale_down() {
    echo ">>> Building Pod list linked to PVC ${SOURCEPVC}"
    PODLIST=$(${KUBECTL_BIN} get pods --all-namespaces -o=json | ${JQ_BIN} --arg sourcepvc ${SOURCEPVC} -c '.items[] | {name: .metadata.name, namespace: .metadata.namespace, claimName: .spec |  select( has ("volumes") ).volumes[] | select( has ("persistentVolumeClaim") ).persistentVolumeClaim | select(.claimName == $sourcepvc) }')
    local i
    for i in $(echo ${PODLIST} | ${JQ_BIN} -r '.name'); do
      TYPE=$(${KUBECTL_BIN} get po $i -n ${NAMESPACE} -ojson | ${JQ_BIN} -r '.metadata.ownerReferences[].kind' | tr ‘[A-Z]’ ‘[a-z]’)
      TYPENAME=$(${KUBECTL_BIN} get po $i -n ${NAMESPACE} -ojson | ${JQ_BIN} -r '.metadata.ownerReferences[].name')
      if [[ ${TYPE} == "replicaset" ]]; then
        TYPE=$(${KUBECTL_BIN} get replicaset -n ${NAMESPACE} ${TYPENAME} -ojson | ${JQ_BIN} -r '.metadata.ownerReferences[].kind' | tr ‘[A-Z]’ ‘[a-z]’)
        TYPENAME=$(${KUBECTL_BIN} get replicaset -n ${NAMESPACE} ${TYPENAME} -ojson | ${JQ_BIN} -r '.metadata.ownerReferences[].name')
      fi
      REPLICAS=$(${KUBECTL_BIN} get ${TYPE} ${TYPENAME} -n ${NAMESPACE} -ojson | ${JQ_BIN} -r '.spec.replicas' ) #comment récupérer le replica par déploimenet ?
      podreplicas+=( ["${TYPE}/${TYPENAME}"]=${REPLICAS} )
      echo ">>> Scaling down ${TYPE}/${TYPENAME} ..."
      ${KUBECTL_BIN} scale ${TYPE} ${TYPENAME} -n ${NAMESPACE} --replicas=0 || die "Scale down failed"
      until [[ $(${KUBECTL_BIN} get ${TYPE} ${TYPENAME} -n ${NAMESPACE} --no-headers | awk '{print $2}') == "0/0" ]]; do
        echo ">>> Waiting 1 sec for the ${TYPENAME} ${TYPE} to be scaled down"
        sleep 1
      done
    done
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


# scale up the replicasets
scale_up() {
    for type in ${!podreplicas[@]}; do
      echo ">>> Scaling up ${type} with ${podreplicas[${type}]} replicas"
      ${KUBECTL_BIN} scale ${type} -n ${NAMESPACE} --replicas=${podreplicas[${type}]} || die "Scale up failed"
      until [[ $(${KUBECTL_BIN} get ${type} -n ${NAMESPACE} --no-headers | awk '{print $2}') == "${podreplicas[${type}]}/${podreplicas[${type}]}" ]]; do
        echo ">>> Waiting 10 sec for the ${type} to be scaled up"
        sleep 10
      done
    done
    unset podreplicas
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
    bin_check
    sc_check
    restore_dir
    scale_down
    delete_migrated_pvc
    restore_source_pvc
    patch_pv
    scale_up
    pv_policy_patch
    git_push
}

main
