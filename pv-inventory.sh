#!/usr/bin/env bash

#set -x # debug mode
#set -e # exit on error
set -o pipefail # trace ERR through pipes
set -o errtrace # trace ERR through 'time command' and other functions
#set -o errexit # exit the script if any statement returns a non-true return value

K8S_ENV="$1"
NAMESPACE="$2"
DATE=$(date '+%Y-%m-%d-%H-%M-%S')
SCRIPT_DIR=$(cd -P -- "$(dirname -- "$(dirname $0)")" && pwd -P)
GIT_BIN="${GIT_BIN:-git}"
JQ_BIN="${JQ_BIN:-jq}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"

# usage
usage() {
    echo ">>> Example : ./pv-inventory.sh prd mt-prd-bookinfo"
    echo ">>> First argument supplied is environment name"
    echo ">>> Second argument supplied is namespace name"
}

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

# create inventory dir
inventory_dir() {
    echo ">>> Creating inventory dir ${SCRIPT_DIR}/${K8S_ENV}/inventory/${NAMESPACE}/${DATE}"
    mkdir -p ${SCRIPT_DIR}/${K8S_ENV}/inventory/${NAMESPACE}/${DATE} || die "Inventory dir creation failed"
}

# create inventory
inventory() {
    cd ${SCRIPT_DIR}/${K8S_ENV}/inventory/${NAMESPACE}/${DATE}
    echo ">>> Building PVC list from namespace ${NAMESPACE}"
    PVCLIST=$(${KUBECTL_BIN} get pvc -n ${NAMESPACE} -o=json | ${JQ_BIN} -c '.items[] | {name: .metadata.name, volumename: .spec.volumeName}')
    local i
    for i in $(echo ${PVCLIST}) ; do
      echo ">>> Building Pod list linked to PVC ${i}"
      PODLIST=$(${KUBECTL_BIN} get pods -n ${NAMESPACE} -o=json | ${JQ_BIN} --arg pvc $(echo ${i} | ${JQ_BIN} -r '.name') -c '.items[] | {name: .metadata.name, namespace: .metadata.namespace, claimName: .spec |  select( has ("volumes") ).volumes[] | select( has ("persistentVolumeClaim") ).persistentVolumeClaim | select(.claimName == $pvc) }')
      echo ">>> Writing the result in the inventory file ${SCRIPT_DIR}/${K8S_ENV}/inventory/${NAMESPACE}/${DATE}/${i}-inventory.json"
      echo ${PODLIST} > ./$(echo ${i} | ${JQ_BIN} -r '.name')-inventory.json
      echo "$(echo ${i} | ${JQ_BIN} -r '.volumename')" >> ./$(echo ${i} | ${JQ_BIN} -r '.name')-inventory.json
    done
}

# adding inventory files and push
git_push() {
    echo ">>> Adding restoration files to git and pushing"
    cd ${SCRIPT_DIR}
    ${GIT_BIN} add ${K8S_ENV}/inventory/${NAMESPACE}
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
        fi
    fi
    bin_check
    inventory_dir
    inventory
    git_push
}

main "${@}"
