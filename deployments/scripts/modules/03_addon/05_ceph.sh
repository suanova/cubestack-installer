#!/bin/bash
# ============================================================
# MODULE: ceph
# DESC: Ceph 存储集群(底层存储底座, P1 刚需)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: CEPH_ENABLED
# 说明:
#   【P1-6 规划模块·伪代码占位】Ceph 分布式存储:
#   · 部署 Ceph 底层存储集群、健康自检、存储池初始化
#   · 为上层 Ceph CSI(RBD/RGW/CephFS)提供稳定存储底座
#   · 裸金属环境推荐 Rook-Ceph 或独立 Ceph 节点(需要裸盘)
#   · 接入方法: 将下方 STEPS 伪代码替换为真实命令, 或 ADDON_STUB_EXEC=1 试执行
# 数据源: cluster.conf (CEPH_ENABLED / NODES)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

if [ "${CEPH_ENABLED:-false}" != "true" ]; then
    say "跳过 Ceph(配置 CEPH_ENABLED=true 可启用)"
    exit 0
fi

FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
SSH="ssh -i ${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${FIRST_MASTER}"
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

# ── 伪代码步骤(占位): 替换为真实实现 ──
CEPH_STEPS=(
  "创建 rook-ceph 命名空间|${SSH} \"${K} create ns rook-ceph 2>/dev/null || true\""
  "部署 Rook-Ceph operator(离线 manifest)|${SSH} \"${K} apply -f /opt/cubestack/addons/rook-ceph/operator.yaml 2>/dev/null || true\""
  "等待 operator 就绪|${SSH} \"${K} -n rook-ceph rollout status deploy/rook-ceph-operator --timeout=5m 2>/dev/null || true\""
  "应用 Ceph 集群 CR(指定裸盘节点/存储类)|${SSH} \"${K} apply -f /opt/cubestack/addons/rook-ceph/cluster.yaml 2>/dev/null || true\""
  "等待 Ceph 集群健康(HEALTH_OK)|${SSH} \"${K} -n rook-ceph exec deploy/rook-ceph-tools -- ceph status 2>/dev/null || true\""
  "创建存储池(replicapool / cephfs-metadata / cephfs-data / rgw)|${SSH} \"${K} apply -f /opt/cubestack/addons/rook-ceph/storageclass-rbd.yaml 2>/dev/null || true\""
  "创建 StorageClass(rook-ceph-block / cephfs / rgw)|${SSH} \"${K} apply -f /opt/cubestack/addons/rook-ceph/storageclass.yaml 2>/dev/null || true\""
)
addon_stub "ceph" CEPH_STEPS
