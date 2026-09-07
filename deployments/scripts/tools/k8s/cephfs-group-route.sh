#!/bin/bash
# ============================================================
# TOOL: cephfs-group-route
# DESC: 把 CephFS 动态 SC 路由到指定 subvolume group(§7.7/§7.8/§21.2-3)
# 背景: CephFS CSI 动态创建的 subvolume 默认落在 csi group; 要让工作区 PVC 落进
#   ephemeral group / 平台共享落进 durable group(§9.1), 需把 SC parameters.clusterID
#   改为该 group 的 status.info.clusterID。
# 用法(部署机/容器内):
#   bash cephfs-group-route.sh apply             # 取 ephemeral/durable group clusterID → patch SC
#   bash cephfs-group-route.sh show              # 只显示两个 group 的 clusterID
# 数据源: cluster.conf (CEPH_NAMESPACE) + kubectl(master 或本地 kubeconfig)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config
init_remote_kubectl || { err "init_remote_kubectl 失败"; exit 1; }

CEPH_NAMESPACE="${CEPH_NAMESPACE:-rook-ceph}"
ACTION="${1:-show}"

# 取 group clusterID: <group> → stdout clusterID(空=group 不存在)
group_clusterid() {
    local g="$1"
    ( SSH "${K} -n ${CEPH_NAMESPACE} get cephfilesystemsubvolumegroup ${g} -o jsonpath={.status.info.clusterID} 2>/dev/null" || true )
}

if [ "${ACTION}" = "show" ]; then
    echo "==== CephFS subvolume group clusterID(${CEPH_NAMESPACE}) ===="
    for g in ephemeral durable; do
        cid="$(group_clusterid "${g}")"
        [ -n "${cid}" ] && echo "  ${g}: ${cid}" || echo "  ${g}: <未创建>(先 apply cephfs/03-subvolumegroups.yaml)"
    done
    echo "  路由方法: 把 SC parameters.clusterID 改为对应 group 的 clusterID(§7.7/§7.8)"
    exit 0
fi

if [ "${ACTION}" = "apply" ]; then
    # 映射: SC name → group
    declare -A SC_GROUP=( [cephfs-ephemeral]=ephemeral [cephfs-durable]=durable )
    for sc in "${!SC_GROUP[@]}"; do
        g="${SC_GROUP[$sc]}"
        cid="$(group_clusterid "${g}")"
        if [ -z "${cid}" ]; then
            warn "  group ${g} 未创建(clusterID 空), 跳过 ${sc}(先 apply subvolumegroups.yaml)"
            continue
        fi
        if SSH "${K} -n ${CEPH_NAMESPACE} get sc ${sc} >/dev/null 2>&1"; then
            SSH "${K} -n ${CEPH_NAMESPACE} patch sc ${sc} --type merge -p '{\"parameters\":{\"clusterID\":\"${cid}\"}}' >/dev/null 2>&1" \
                && ok "  SC ${sc} → clusterID=${cid}(group ${g})" \
                || warn "  SC ${sc} patch 失败"
        else
            warn "  SC ${sc} 不存在, 跳过(先 apply cephfs/02-storageclass-cephfs.yaml)"
        fi
    done
    ok "CephFS SC group 路由完成(§7.7/§7.8); 同 clusterID 需同步到 SnapshotClass(§21.2-3)"
    exit 0
fi

err "用法: cephfs-group-route.sh {show|apply}"
exit 1
