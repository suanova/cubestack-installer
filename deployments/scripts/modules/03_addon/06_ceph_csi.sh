#!/bin/bash
# ============================================================
# MODULE: ceph_csi
# DESC: Ceph CSI(RBD/RGW/CephFS)驱动(存储卷供给, P1 刚需)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: CEPH_CSI_ENABLED
# 说明:
#   【P1-7 规划模块·伪代码占位】Ceph CSI 驱动:
#   · 部署 ceph-csi(rbd/rgw/cephfs), 对接 Ceph 集群(依赖 ceph 模块 P1-6)
#   · 实现三类存储卷创建/挂载/读写, StorageReady 状态置位
#   · 接入方法: 将下方 STEPS 伪代码替换为真实命令, 或 ADDON_STUB_EXEC=1 试执行
# 数据源: cluster.conf (CEPH_CSI_ENABLED / NODES)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

if [ "${CEPH_CSI_ENABLED:-false}" != "true" ]; then
    say "跳过 Ceph CSI(配置 CEPH_CSI_ENABLED=true 可启用)"
    exit 0
fi

FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
SSH="ssh -i ${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${FIRST_MASTER}"
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

# ── 伪代码步骤(占位): 替换为真实实现 ──
CEPH_CSI_STEPS=(
  "部署 ceph-csi rbd 组件(离线 manifest)|${SSH} \"${K} apply -f /opt/cubestack/addons/ceph-csi/rbd.yaml 2>/dev/null || true\""
  "部署 ceph-csi cephfs 组件|${SSH} \"${K} apply -f /opt/cubestack/addons/ceph-csi/cephfs.yaml 2>/dev/null || true\""
  "创建 Ceph 密钥(admin + CSI 专用)|${SSH} \"${K} apply -f /opt/cubestack/addons/ceph-csi/secret.yaml 2>/dev/null || true\""
  "创建 Ceph CSI StorageClass(rbd/cephfs/rgw)|${SSH} \"${K} apply -f /opt/cubestack/addons/ceph-csi/storageclass.yaml 2>/dev/null || true\""
  "验证 CSI 插件 Pod 就绪|${SSH} \"${K} -n rook-ceph get pods -l app=csi-rbdplugin -o wide 2>/dev/null || true\""
  "创建测试 PVC 并挂载读写校验|${SSH} \"${K} apply -f /opt/cubestack/addons/ceph-csi/smoke-pvc.yaml 2>/dev/null || true\""
  "确认 StorageReady 状态置位|${SSH} \"${K} get pvc -A -o wide 2>/dev/null || true\""
)
addon_stub "ceph_csi" CEPH_CSI_STEPS
