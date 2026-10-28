#!/bin/bash
# ============================================================
# test-ceph-placement.sh — Ceph/Rook/CSI 在 cordon master 上的 placement 回归
#
# 背景(2026-10-27 节点池): master 会保持 Unschedulable=True; Ceph mon/osd/mgr/mds/rgw
#   以及 Rook operator / ceph-csi controller 必须容忍
#   node.kubernetes.io/unschedulable:NoSchedule, 否则重启/漂移会 Pending。
#   nodeplugin 必须仍能在所有节点(含 cordon master)运行。
#
# 覆盖:
#   ① 02_ceph.sh 的 _emit_placement: control-plane + unschedulable + ceph-storage nodeAffinity
#   ② CephFilesystem / CephObjectStore manifest 的 placement 含 unschedulable
#   ③ Rook operator patch 函数: deploy/rook-ceph-operator 加两类 toleration + master nodeSelector
#   ④ CSI Driver patch 函数: controllerPlugin 加两类 toleration + master nodeSelector;
#      nodePlugin 加 Exists toleration(全节点)
#
# 隔离: 从模块原样抽取函数, 用假 SSH 捕获命令; 不连集群。
# 用法: bash deployments/scripts/tools/tests/test-ceph-placement.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CEPH_MOD="${REPO_ROOT}/deployments/scripts/modules/03_addon/02_ceph.sh"
CSI_MOD="${REPO_ROOT}/deployments/scripts/modules/03_addon/03_ceph_csi.sh"
CEPHFS_MANIFEST="${REPO_ROOT}/deployments/cubestack-addon/rook/cephfs/01-cephfilesystem.yaml"
RGW_MANIFEST="${REPO_ROOT}/deployments/cubestack-addon/rook/rgw/01-cephobjectstore-s3-store.yaml"
EXT_CEPHFS_MANIFEST="${REPO_ROOT}/deployments/cubestack-addon/rook/external/03-cephfilesystem-external.yaml"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if [[ "$3" == *"$2"* ]]; then echo "  ok  $1"; else echo "  FAIL $1: 未包含 [$2]"; fail=1; fi; }

echo "== ① _emit_placement: control-plane + unschedulable + storage affinity =="
sed -n '/^    _emit_placement() {/,/^    }$/p' "${CEPH_MOD}" > "${TMP}/emit.sh"
if [ -s "${TMP}/emit.sh" ]; then
    out="$( ( set -u; LABEL_KEY=ceph-storage; CEPH_NODE_LABEL=ceph-storage=rook-ceph; . "${TMP}/emit.sh"; _emit_placement mon ) 2>&1 )"
    chk_contains "control-plane toleration" "node-role.kubernetes.io/control-plane" "${out}"
    chk_contains "unschedulable toleration" "node.kubernetes.io/unschedulable" "${out}"
    chk_contains "ceph-storage nodeAffinity" "key: ceph-storage" "${out}"
    chk_contains "storage label value" "- rook-ceph" "${out}"
else
    echo "  FAIL 无法抽取 _emit_placement"; fail=1
fi

echo "== ② CephFilesystem / CephObjectStore manifest =="
chk_contains "CephFilesystem unschedulable" "node.kubernetes.io/unschedulable" "$(cat "${CEPHFS_MANIFEST}")"
chk_contains "CephObjectStore unschedulable" "node.kubernetes.io/unschedulable" "$(cat "${RGW_MANIFEST}")"
chk_contains "external CephFilesystem unschedulable" "node.kubernetes.io/unschedulable" "$(cat "${EXT_CEPHFS_MANIFEST}")"

echo "== ③ Rook operator placement patch =="
if grep -q '^_patch_rook_operator_placement()' "${CEPH_MOD}"; then
    sed -n '/^_patch_rook_operator_placement() {/,/^}/p' "${CEPH_MOD}" > "${TMP}/rook_op.sh"
    : > "${TMP}/ssh-rook.log"
    ( set -u
        CEPH_NAMESPACE=rook-ceph K="kubectl --kubeconfig=/etc/kubernetes/admin.conf"
        FAKE_SSH_LOG="${TMP}/ssh-rook.log"
        warn() { echo "WARN $*"; }
        ok() { echo "OK $*"; }
        say() { echo "$*"; }
        SSH() { printf '%s\n' "$*" >> "${FAKE_SSH_LOG}"; return 0; }
        . "${TMP}/rook_op.sh"
        _patch_rook_operator_placement
    ) >/dev/null 2>&1
    log="$(cat "${TMP}/ssh-rook.log")"
    chk_contains "patch deploy rook-ceph-operator" "patch deploy rook-ceph-operator" "${log}"
    chk_contains "operator control-plane toleration" "node-role.kubernetes.io/control-plane" "${log}"
    chk_contains "operator unschedulable toleration" "node.kubernetes.io/unschedulable" "${log}"
    chk_contains "operator master nodeSelector" 'nodeSelector' "${log}"
else
    echo "  FAIL 缺少 _patch_rook_operator_placement"; fail=1
fi

echo "== ④ CSI Driver placement patch =="
if grep -q '^_patch_csi_driver_placement()' "${CSI_MOD}"; then
    sed -n '/^_patch_csi_driver_placement() {/,/^}/p' "${CSI_MOD}" > "${TMP}/csi_drv.sh"
    : > "${TMP}/ssh-csi.log"
    ( set -u
        CEPH_NAMESPACE=rook-ceph K="kubectl --kubeconfig=/etc/kubernetes/admin.conf"
        FAKE_SSH_LOG="${TMP}/ssh-csi.log"
        warn() { echo "WARN $*"; }
        ok() { echo "OK $*"; }
        say() { echo "$*"; }
        SSH() { printf '%s\n' "$*" >> "${FAKE_SSH_LOG}"; return 0; }
        . "${TMP}/csi_drv.sh"
        _patch_csi_driver_placement
    ) >/dev/null 2>&1
    log="$(cat "${TMP}/ssh-csi.log")"
    chk_contains "ceph-csi-controller-manager patch" "ceph-csi-controller-manager" "${log}"
    chk_contains "patch rbd driver" "rook-ceph.rbd.csi.ceph.com" "${log}"
    chk_contains "patch cephfs driver" "rook-ceph.cephfs.csi.ceph.com" "${log}"
    chk_contains "controllerPlugin" "controllerPlugin" "${log}"
    chk_contains "controller nodeAffinity" "nodeAffinity" "${log}"
    chk_contains "nodePlugin" "nodePlugin" "${log}"
    chk_contains "controller control-plane toleration" "node-role.kubernetes.io/control-plane" "${log}"
    chk_contains "controller unschedulable toleration" "node.kubernetes.io/unschedulable" "${log}"
    chk_contains "nodeplugin Exists toleration" '"operator":"Exists"' "${log}"
else
    echo "  FAIL 缺少 _patch_csi_driver_placement"; fail=1
fi

echo "== ⑤ 存量 daemon Deployment 补丁(mon/mgr/osd + mds/rgw) =="
if grep -q '^_patch_ceph_daemon_placement()' "${CEPH_MOD}"; then
    chk_contains "补 mon/mgr/osd" "rook-ceph-(mon|mgr|osd)" "$(cat "${CEPH_MOD}")"
    chk_contains "daemon unschedulable" "node.kubernetes.io/unschedulable" "$(sed -n '/^_patch_ceph_daemon_placement() {/,/^}/p' "${CEPH_MOD}")"
else
    echo "  FAIL 缺少 _patch_ceph_daemon_placement"; fail=1
fi
if grep -q '^_patch_cephfs_rgw_placement()' "${CSI_MOD}"; then
    chk_contains "补 mds/rgw" "rook-ceph-(mds|rgw)" "$(cat "${CSI_MOD}")"
    chk_contains "mds/rgw unschedulable" "node.kubernetes.io/unschedulable" "$(sed -n '/^_patch_cephfs_rgw_placement() {/,/^}/p' "${CSI_MOD}")"
else
    echo "  FAIL 缺少 _patch_cephfs_rgw_placement"; fail=1
fi

echo ""
if [ "${fail}" = "0" ]; then
    echo "✅ test-ceph-placement: 全部通过"
else
    echo "❌ test-ceph-placement: 存在失败项"
fi
exit "${fail}"
