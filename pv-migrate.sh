#!/usr/bin/env bash

#set -x # debug mode
#set -e # exit on error
set -o pipefail # trace ERR through pipes
set -o errtrace # trace ERR through 'time command' and other functions
#set -o errexit # exit the script if any statement returns a non-true return value

MODE="$1"
K8S_ENV="$2"
NAMESPACE="$3"
SOURCEPVC="$4"
NEWSCNAME="$5"
DESTPVC="${SOURCEPVC}-pvmigrate"
DATE=$(date '+%Y-%m-%d-%H-%M')
SCRIPT_DIR=$(cd -P -- "$(dirname -- "$(dirname $0)")" && pwd -P)
GIT_BIN="${GIT_BIN:-git}"
JQ_BIN="${JQ_BIN:-jq}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
PV_MIGRATE_BIN="${PV_MIGRATE_BIN:-pv-migrate}"
declare -A podreplicas

# usage
usage() {
    echo ">>> Example : ./pv-migrate.sh presync prd mt-prd-bookinfo bookinfo-pvc gold-mcc"
    echo ">>> Example : ./pv-migrate.sh migrate prd mt-prd-bookinfo bookinfo-pvc gold-mcc"
    echo ">>> First argument supplied is presync or migrate"
    echo ">>> Second argument supplied is environment name"
    echo ">>> Third argument supplied is namespace name"
    echo ">>> Fourth argument supplied is source PVC name"
    echo ">>> Fifth argument supplied is new StorageClass name"
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
    command -v ${PV_MIGRATE_BIN} >/dev/null 2>&1 || die "The pv-migrate binary is not in your PATH"
}

# create backup dir with all the manifests
backup_dir() {
    migrateOrPresync=${1}
    echo ">>> Creating the migration dir ${SCRIPT_DIR}/${K8S_ENV}/${migrateOrPresync}/${NAMESPACE}/${SOURCEPVC}/${DATE}"
    mkdir -p ${SCRIPT_DIR}/${K8S_ENV}/${migrateOrPresync}/${NAMESPACE}/${SOURCEPVC}/${DATE}
    cd ${SCRIPT_DIR}/${K8S_ENV}/${migrateOrPresync}/${NAMESPACE}/${SOURCEPVC}/${DATE}
    ${KUBECTL_BIN} get pvc ${SOURCEPVC} -n ${NAMESPACE} -oyaml | kubectl-neat > ./${SOURCEPVC}-backup.yaml
}

# create a new pvc with retain policy and immediate in the ns
create_new_pvc() {
    migrateOrPresync=${1}
    DESTPVC_PRESENCE=$(${KUBECTL_BIN} get pvc -n ${NAMESPACE} ${DESTPVC} --no-headers=true | awk '{print $1}')

    echo ">>> The New Storage class is ${NEWSCNAME}"

    if [[ -z ${DESTPVC_PRESENCE} ]]; then
      cd ${SCRIPT_DIR}/${K8S_ENV}/${migrateOrPresync}/${NAMESPACE}/${SOURCEPVC}/${DATE}
      cp ./${SOURCEPVC}-backup.yaml ./${DESTPVC}-backup.yaml
      sed -i -e 's/  name: .*$/  name: '${DESTPVC}'/g' ./${DESTPVC}-backup.yaml
      sed -i -e 's/storageClassName: .*$/storageClassName: '${NEWSCNAME}'/g' ./${DESTPVC}-backup.yaml
      sed -i '/volumeName/d' ./${DESTPVC}-backup.yaml
      sed -i -e '/pv\.kubernetes\.io.*/d' ./${DESTPVC}-backup.yaml
      sed -i -e '/volume\..*/d' ./${DESTPVC}-backup.yaml
      echo "${DESTPVC} PVC creation ..." 
      ${KUBECTL_BIN} apply -f ./${DESTPVC}-backup.yaml || die "PVC Destination creation failed"
      echo ">>> Waiting 5 secs for the PVC ${DESTPVC} to be created"
      sleep 5
    else
      echo ">>> PVC ${DESTPVC} already present, skipping PVC creation ..."
    fi
}

get_pod_location() {
    echo ">>> Generating the POD list linked to PVC ${SOURCEPVC}"
    PODLIST=$(${KUBECTL_BIN} get pods -n ${NAMESPACE} -o=json | ${JQ_BIN} --arg sourcepvc ${SOURCEPVC} -c '.items[] | {name: .metadata.name, namespace: .metadata.namespace, claimName: .spec |  select( has ("volumes") ).volumes[] | select( has ("persistentVolumeClaim") ).persistentVolumeClaim | select(.claimName == $sourcepvc), nodeName: .spec.nodeName'})
}

# Now we can use the pv-migrate to copy the data
pv_migrate() {
    i=$(echo ${PODLIST} | ${JQ_BIN} -r '.nodeName' | head -n 1)
    [[ -z ${i} ]] && die "Unable to determine the nodeName of the Pod"
    TOPOLOGY=$(${KUBECTL_BIN} get no ${i} -ojson | jq -r '.metadata.labels' | grep -we '"topology.kubernetes.io/zone": ".*"' | sed -e 's/,//g')
    MKVALUETMP=$(mktemp)
    cat ${SCRIPT_DIR}/templates/values.yaml | sed -e 's#    TOREPLACE#  '"${TOPOLOGY}"'#g' > ${MKVALUETMP}
    case ${MODE} in
      "presync")
      echo "Starting presync @ $(date)" > ${SCRIPT_DIR}/${K8S_ENV}/presync/${NAMESPACE}/${SOURCEPVC}/${DATE}/presync.log
      ${PV_MIGRATE_BIN} migrate ${SOURCEPVC} ${DESTPVC} -s svc --ignore-mounted --helm-values ${MKVALUETMP} --source-namespace ${NAMESPACE} --dest-namespace ${NAMESPACE} || die "SVC PVC migration failed"
      echo "End of presync @ $(date)" >> ${SCRIPT_DIR}/${K8S_ENV}/presync/${NAMESPACE}/${SOURCEPVC}/${DATE}/presync.log
      ;;

      "migrate")
      echo "Starting migrate @ $(date)" > ${SCRIPT_DIR}/${K8S_ENV}/migrate/${NAMESPACE}/${SOURCEPVC}/${DATE}/migrate.log
      ${PV_MIGRATE_BIN} migrate ${SOURCEPVC} ${DESTPVC} -s mnt2 --ignore-mounted --helm-values ${MKVALUETMP} --source-namespace ${NAMESPACE} --dest-namespace ${NAMESPACE} || die "MNT2 PVC migration failed"
      echo "End of migrate @ $(date)" >> ${SCRIPT_DIR}/${K8S_ENV}/migrate/${NAMESPACE}/${SOURCEPVC}/${DATE}/migrate.log
      ;;

      *)
      die "No migration strategy defined"
      ;;
    esac
    rm -f ${MKVALUETMP}
    unset i
}

# patch PV with Reclaim Policy Retain
patch_pv() {
    local i
    for i in $(${KUBECTL_BIN} get pvc -n ${NAMESPACE} ${SOURCEPVC} -ojson | ${JQ_BIN} -r '.spec.volumeName' ); do   
      echo ">>> Patching Source PV $i for Retain Reclaim Policy"
      ${KUBECTL_BIN} patch pv $i -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' || die "Source PV patch failed"
    done
    local j
    for j in $(${KUBECTL_BIN} get pvc -n ${NAMESPACE} ${DESTPVC} -ojson | ${JQ_BIN} -r '.spec.volumeName' ); do
      echo ">>> Patching Destination PV $j for Retain Reclaim Policy"
      ${KUBECTL_BIN} patch pv $j -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' || die "Destination PV patch failed"
    done
}

# get the new pv id
pv_id() {
    echo ">>> Collection Source and Destination PV ID"
    SOURCEPVID=$(${KUBECTL_BIN} get pvc -n ${NAMESPACE} ${SOURCEPVC} -ojson | ${JQ_BIN} -r '.spec.volumeName')
    DESTPVID=$(${KUBECTL_BIN} get pvc -n ${NAMESPACE} ${DESTPVC} -ojson | ${JQ_BIN} -r '.spec.volumeName')
}

# delete the destination pvc
delete_dest_and_source_pvc() {
    # fetch old pvc storage and storage class name
    SOURCESCNAME=$(${KUBECTL_BIN} get pvc -n ${NAMESPACE} ${SOURCEPVC} -ojson | ${JQ_BIN} -r '.spec.storageClassName')

    echo ">>> Deleting PVC ${DESTPVC} and ${SOURCEPVC} to clean old resources"
    ${KUBECTL_BIN} delete pvc -n ${NAMESPACE} ${DESTPVC} || die "New PVC deletion Failed" || die "Source PVC deletion failed"
    ${KUBECTL_BIN} delete pvc -n ${NAMESPACE} ${SOURCEPVC} || die "Old PVC deletion Failed" || die "Destination PVC deletion failed"
}

# free the PV Source from PVC
free_source_pv() {
    echo ">>> Patching Generated PV ${SOURCEPVID} to be freed from its PVC"
    ${KUBECTL_BIN} patch pv ${SOURCEPVID} --type=json -p='[{"op": "remove", "path": "/spec/claimRef"}]'
    ${KUBECTL_BIN} patch pv ${SOURCEPVID} -p '{"spec":{"storageClassName":"'${DESTPVID}'-backup-'${SOURCESCNAME}'"}}'
}

# Create a new PVC with the source name and the new storage class
recreate_source_pvc() {
    cd ${SCRIPT_DIR}/${K8S_ENV}/migrate/${NAMESPACE}/${SOURCEPVC}/${DATE}
    cp ./${SOURCEPVC}-backup.yaml ./${SOURCEPVC}-recreation.yaml
    sed -i -e 's/storageClassName: .*$/storageClassName: '${NEWSCNAME}'/g' ./${SOURCEPVC}-recreation.yaml
    sed -i -e 's/volumeName: .*$/volumeName: '${DESTPVID}'/g' ./${SOURCEPVC}-recreation.yaml
    sed -i -e '/pv\.kubernetes\.io.*/d' ./${SOURCEPVC}-recreation.yaml
    sed -i -e '/volume\..*/d' ./${SOURCEPVC}-recreation.yaml
    echo ">>> Recreating Source PVC ${SOURCEPVC} with the migrated PV ${DESTPVID} as volume name"
    ${KUBECTL_BIN} apply -f ./${SOURCEPVC}-recreation.yaml || die "Source PVC recreation failed"
}

# patch the pvc source to point to the new destination pv
pv_dest_claim_patch() {
    echo ">>> Patching migrated PV ${DESTPVID} with recreated Source PVC ${SOURCEPVC} as Claim Reference"
    ${KUBECTL_BIN} patch pv ${DESTPVID} -p '{"spec":{"claimRef":{"name":"'${SOURCEPVC}'"}}}' || die "Destination PV ClaimRef patch Failed"
    ${KUBECTL_BIN} patch pv ${DESTPVID} --type=json -p='[{"op": "remove", "path": "/spec/claimRef/uid"}]' || die "Destination PV ClaimReF UID patch Failed"
}

pv_dest_policy_patch() {
    echo ">>> Patching migrated PV ${DESTPVID} with Delete Reclaim Policy"
    ${KUBECTL_BIN} patch pv ${DESTPVID} -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}' || die "Destination PV ReclaimPolicy patch Failed"
}

# adding migration files and push
git_push() {
    echo ">>> Adding restoration files to git and pushing"
    cd ${SCRIPT_DIR}
    ${GIT_BIN} add ${K8S_ENV}/migrate/${NAMESPACE}
    ${GIT_BIN} commit -a -m "PVC ${SOURCEPVC} migration at ${DATE}"
    ${GIT_BIN} push
}


main_presync() {
    bin_check
    backup_dir presync
    create_new_pvc presync
    get_pod_location
    pv_migrate
}

main_migrate() {
    bin_check
    backup_dir migrate
    create_new_pvc migrate
    get_pod_location
    pause_scale down
    pv_migrate
    patch_pv
    pv_id
    delete_dest_and_source_pvc
    free_source_pv
    recreate_source_pvc
    pv_dest_claim_patch
    pause_scale up
    pv_dest_policy_patch
    git_push
}

if [ $# -eq 0 ]; then
    echo "No argument supplied."
    usage
    exit 1
else
    if  [ -z "$1" ]; then
        echo "First argument supplied is invalid, need presync or migrate"
        exit 1
    elif [ -z "$2" ]; then
        echo "Second argument supplied is invalid, need namespace name"
        exit 1
    elif [ -z "$3" ]; then
        echo "Third argument supplied is invalid, need namespace name"
        exit 1
    elif [ -z "$4" ]; then
        echo "Fourth argument supplied is invalid, need Source PVC name"
        exit 1
    elif [ -z "$5" ]; then
        echo "Fifth argument supplied is invalid, need New StorageClass name"
        exit 1
    fi
fi

case ${MODE} in
    "migrate")
      main_migrate
      ;;

    "presync")
      main_presync
      ;;

    *)
      die "You must specify migrate or presync"
      ;;
esac
