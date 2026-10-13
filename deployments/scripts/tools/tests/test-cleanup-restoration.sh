#!/bin/bash
# Offline regressions: real cleanup scripts, synthetic kubectl/SSH responses.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
FIXTURE="${TMP}/scripts"
mkdir -p "${FIXTURE}/tools/k8s" "${FIXTURE}/modules/03_addon" "${TMP}/bin" "${TMP}/replicas"
cp "${REPO_ROOT}/deployments/scripts/tools/k8s/"ceph-{cleanup,consumer-state,rbd-cleanup}.sh "${FIXTURE}/tools/k8s/"
cp "${REPO_ROOT}/deployments/scripts/modules/03_addon/25_cubestack_operator.sh" "${FIXTURE}/modules/03_addon/"
export FAKE_LOG="${TMP}/calls" FAKE_REPLICAS="${TMP}/replicas"
export PATH="${TMP}/bin:${PATH}"
cat > "${TMP}/bin/sleep" <<'STUB'
#!/bin/bash
exit 0
STUB
cat > "${TMP}/bin/helm" <<'STUB'
#!/bin/bash
printf 'helm %s\n' "$*" >> "${FAKE_LOG}"
STUB
cat > "${TMP}/bin/ssh" <<'STUB'
#!/bin/bash
printf 'ssh %s\n' "$*" >> "${FAKE_LOG}"
case "$*" in
    *'for d in /sys/bus/rbd/devices/'*)
        [ "${FAKE_MODE}" != "rbd-list-fail" ] || exit 255
        [ "${FAKE_MODE}" != "rbd-list-empty" ] || exit 0
        echo '1 old-image old-pool' ;;
    *'wc -l'*)
        case "${FAKE_MODE}" in
            rbd-empty|rbd-list-empty) exit 0 ;;
            rbd-fail) echo 0; exit 255 ;;
            rbd-invalid) echo 'error 0'; exit 0 ;;
            rbd-left) echo 2 ;;
            *) echo 0 ;;
        esac ;;
    *'mount |'*) echo no ;;
esac
STUB
chmod +x "${TMP}/bin/"*
cat > "${FIXTURE}/lib-common.sh" <<'STUB'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
load_config() { :; }
init_remote_kubectl() {
    K=kubectl; SSH_KEY=/synthetic/key
    NODES=('worker,w1,192.0.2.1,synthetic,p')
}
node_parse() { NODE_IP=192.0.2.1; }
sync_kubeconfig() { return 0; }
say() { echo "$*"; }
ok() { echo "OK $*"; }
warn() { echo "WARN $*"; }
err() { echo "ERR $*"; }
SSH() {
    local ns='' name='' args="$*"
    printf '%s\n' "${args}" >> "${FAKE_LOG}"
    if [[ "${args}" =~ -n[[:space:]]+([^[:space:]]+) ]]; then ns="${BASH_REMATCH[1]}"; fi
    if [[ "${args}" =~ (get|scale)[[:space:]]+deploy[[:space:]]+([^[:space:]]+) ]]; then
        name="${BASH_REMATCH[2]}"
        case "${args}" in
            *'get deploy'*'jsonpath'*)
                [ "${name}" != missing ] || return 1
                cat "${FAKE_REPLICAS}/${ns}.${name}" ;;
            *'scale deploy'*)
                [ "${name}" != failed ] || return 1
                if [[ "${args}" =~ --replicas=([0-9]+) ]]; then
                    echo "${BASH_REMATCH[1]}" > "${FAKE_REPLICAS}/${ns}.${name}"
                fi ;;
        esac
        return 0
    fi
    case "${args}" in
        *'get csc -o name'*)
            [ "${FAKE_MODE:-}" != csc-query-fail ] || return 1
            if [ "${FAKE_MODE:-}" = csc-pending ] || ! [ -f "${FAKE_REPLICAS}/csc-deleted" ]; then
                echo 'cubestackcluster.platform.cubestack.io/platform'
            fi ;;
        *'wait --for=delete csc'*)
            [ "${FAKE_MODE:-}" != csc-pending ] || return 1
            touch "${FAKE_REPLICAS}/csc-deleted" ;;
        *'get cephcluster'*) echo 'rook-ceph' ;;
        *'get pvc -A -o json'*) echo '{"items":[{"metadata":{"namespace":"apps","name":"data"},"spec":{"storageClassName":"ceph-block"},"status":{"phase":"Bound"}}]}' ;;
        *'get pods -A -o json'*)
            if [ "$(cat "${FAKE_REPLICAS}/apps.app")" = 0 ]; then echo '{"items":[]}'
            else echo '{"items":[{"metadata":{"namespace":"apps","name":"app-pod","ownerReferences":[{"kind":"Deployment","name":"app"}]},"spec":{"volumes":[{"persistentVolumeClaim":{"claimName":"data"}}]}}]}'
            fi ;;
        *'get rs -A -o json'*|*'get sts -A -o json'*) echo '{"items":[]}' ;;
    esac
}
STUB
source "${FIXTURE}/lib-common.sh"
init_remote_kubectl
source "${FIXTURE}/tools/k8s/ceph-consumer-state.sh"
reset_case() {
    : > "${FAKE_LOG}"
    rm -f "${FAKE_REPLICAS}/csc-deleted"
    echo 3 > "${FAKE_REPLICAS}/cubestack-system.cubestack-operator"
    echo 0 > "${FAKE_REPLICAS}/kube-system.registry"
    echo 4 > "${FAKE_REPLICAS}/apps.app"
    echo 7 > "${FAKE_REPLICAS}/apps.failed"
    unset CEPH_CONSUMER_STATE_FILE _CEPH_CONSUMER_STATE_OWNED
}
check() { "$@" || { echo "FAIL: $*"; exit 1; }; }

reset_case
ceph_consumers_stop_deployment apps failed
ceph_consumers_stop_deployment apps missing
check test ! -s "${CEPH_CONSUMER_STATE_FILE}"
ceph_consumers_stop_deployment apps app
ceph_consumers_stop_deployment apps app
check test "$(cat "${CEPH_CONSUMER_STATE_FILE}")" = $'apps\tapp\t4'
state="${CEPH_CONSUMER_STATE_FILE}"
ceph_consumers_finish 1
check test "$(cat "${FAKE_REPLICAS}/apps.app")" = 4
check test "$(cat "${FAKE_REPLICAS}/apps.failed")" = 7
check test ! -e "${state}"
echo 'PASS: markers only for successful scales; repeat stop preserves original count'

reset_case
export CEPH_CONSUMER_STATE_FILE="${TMP}/shared-state"
: > "${CEPH_CONSUMER_STATE_FILE}"
bash "${FIXTURE}/tools/k8s/ceph-cleanup.sh" --stop-consumers --keep-pvcs > "${TMP}/result"
check test "$(wc -l < "${CEPH_CONSUMER_STATE_FILE}")" = 3
# Execute the real deployment success restoration block against the shared markers.
source <(sed -n '/^# .*7.9)/,/^# .*8) /p' "${REPO_ROOT}/deployments/scripts/modules/03_addon/02_ceph.sh")
check test "$(cat "${FAKE_REPLICAS}/cubestack-system.cubestack-operator")" = 3
check test "$(cat "${FAKE_REPLICAS}/kube-system.registry")" = 0
check test "$(cat "${FAKE_REPLICAS}/apps.app")" = 0
check test "$(cat "${CEPH_CONSUMER_STATE_FILE}")" = $'apps\tapp\t4'
# A later deployment failure restores only the remaining recorded consumer.
ceph_consumers_finish 1
check test "$(cat "${FAKE_REPLICAS}/apps.app")" = 4
check test ! -e "${CEPH_CONSUMER_STATE_FILE}"
echo 'PASS: shared success restores operator/registry originals; later failure restores remaining consumers'

reset_case
export CEPH_CONSUMER_STATE_FILE="${TMP}/cleanup-failure"
: > "${CEPH_CONSUMER_STATE_FILE}"
if bash "${FIXTURE}/tools/k8s/ceph-cleanup.sh" --delete-cluster > "${TMP}/result"; then
    echo 'FAIL: expected cleanup timeout'; exit 1
fi
check test "$(cat "${FAKE_REPLICAS}/cubestack-system.cubestack-operator")" = 3
check test "$(cat "${FAKE_REPLICAS}/apps.app")" = 4
check test ! -e "${CEPH_CONSUMER_STATE_FILE}"
# A tolerated cleanup failure may be followed by another cleanup in the same flow.
bash "${FIXTURE}/tools/k8s/ceph-cleanup.sh" --stop-consumers --keep-pvcs > "${TMP}/result"
check test -s "${CEPH_CONSUMER_STATE_FILE}"
ceph_consumers_finish 1
echo 'PASS: actual cleanup failure restores recorded deployments and removes state'

reset_case
export FAKE_ENTRYPOINT="${REPO_ROOT}/deployments/scripts/deploy-cluster.sh" FAKE_FIXTURE="${FIXTURE}"
if bash -c '
    set -euo pipefail
    source "${FAKE_FIXTURE}/lib-common.sh"
    init_remote_kubectl
    source <(sed -n "/^# Per-run Ceph/,/^# ★ 优雅覆盖/p" "${FAKE_ENTRYPOINT}")
    printf "%s" "${CEPH_CONSUMER_STATE_FILE}" > "${FAKE_REPLICAS}/flow-state-path"
    bash "${FAKE_FIXTURE}/tools/k8s/ceph-cleanup.sh" --stop-consumers --keep-pvcs
    exit 7
' > "${TMP}/result"; then status=0; else status=$?; fi
check test "${status}" = 7
check test "$(cat "${FAKE_REPLICAS}/cubestack-system.cubestack-operator")" = 3
check test "$(cat "${FAKE_REPLICAS}/apps.app")" = 4
check test ! -e "$(cat "${FAKE_REPLICAS}/flow-state-path")"
echo 'PASS: deployment EXIT trap restores shared consumers and preserves failure status'

reset_case
mkdir -p "${TMP}/standalone-state"
TMPDIR="${TMP}/standalone-state" bash "${FIXTURE}/tools/k8s/ceph-cleanup.sh" --stop-consumers --keep-pvcs > "${TMP}/result"
check test -z "$(ls -A "${TMP}/standalone-state")"
check test "$(cat "${FAKE_REPLICAS}/cubestack-system.cubestack-operator")" = 0
check test "$(cat "${FAKE_REPLICAS}/apps.app")" = 0
# No marker => deployment success must leave unrelated replicas alone.
source <(sed -n '/^# .*7.9)/,/^# .*8) /p' "${REPO_ROOT}/deployments/scripts/modules/03_addon/02_ceph.sh")
check test "$(cat "${FAKE_REPLICAS}/cubestack-system.cubestack-operator")" = 0
echo 'PASS: standalone cleanup keeps successful stop behavior; no markers means no restoration'

for mode in csc-pending csc-query-fail csc-gone; do
    reset_case
    export FAKE_MODE="${mode}" CUBESTACK_MODULE_ACTION=uninstall
    if bash "${FIXTURE}/modules/03_addon/25_cubestack_operator.sh" > "${TMP}/result"; then status=0; else status=$?; fi
    check rg -q 'wait --for=delete csc --all --timeout=120s' "${FAKE_LOG}"
    if [ "${mode}" = csc-gone ]; then
        check test "${status}" = 0
        check rg -q 'helm uninstall' "${FAKE_LOG}"
        check rg -q 'patch ns' "${FAKE_LOG}"
        check rg -q 'delete ns' "${FAKE_LOG}"
        wait_line="$(rg -n 'wait --for=delete csc' "${FAKE_LOG}" | cut -d: -f1)"
        helm_line="$(rg -n 'helm uninstall' "${FAKE_LOG}" | cut -d: -f1)"
        check test "${wait_line}" -lt "${helm_line}"
    else
        check test "${status}" = 1
        if rg -q 'helm uninstall|patch ns|delete ns|delete crd| get pods' "${FAKE_LOG}"; then echo 'FAIL: unsafe CSC cleanup'; exit 1; fi
    fi
    echo "PASS: ${mode} guards operator/namespace cleanup"
done
unset CUBESTACK_MODULE_ACTION

for mode in rbd-empty rbd-fail rbd-invalid rbd-list-fail rbd-list-empty rbd-zero rbd-left; do
    reset_case
    export FAKE_MODE="${mode}"
    bash "${FIXTURE}/tools/k8s/ceph-rbd-cleanup.sh" > "${TMP}/result"
    case "${mode}" in
        rbd-zero) check rg -q '全部节点.*已清零' "${TMP}/result" ;;
        rbd-left) check rg -q '仍有 2 个内核' "${TMP}/result" ;;
        *) check rg -q '洁净度未知' "${TMP}/result"
           if rg -q '全部节点.*已清零|modprobe -r' "${TMP}/result" "${FAKE_LOG}"; then echo 'FAIL: unknown node reported clean'; exit 1; fi ;;
    esac
    echo "PASS: ${mode} RBD summary"
done
