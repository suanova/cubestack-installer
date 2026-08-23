#!/bin/bash
# ============================================================
# MODULE: gpu_lws
# DESC: 安装 LeaderWorkerSet (LWS)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: LWS_ENABLED
# 说明:
#   【P1-8 规划模块·伪代码占位】LeaderWorkerSet:
#   · 完成 LWS 组件部署、集群适配与基础校验, 保障集群轻量调度
#   · 接入方法: 将下方 STEPS 伪代码替换为真实命令(kubectl apply 官方 manifest / 离线 yaml),
#     或设置 ADDON_STUB_EXEC=1 试执行
# 数据源: cluster.conf (LWS_ENABLED / NODES)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

if [ "${LWS_ENABLED:-false}" != "true" ]; then
    say "跳过 LeaderWorkerSet(配置 LWS_ENABLED=true 可启用)"
    exit 0
fi

FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
SSH="ssh -i ${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${FIRST_MASTER}"
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

# ── 伪代码步骤(占位): 替换为真实实现 ──
LWS_STEPS=(
  "应用 LWS CRD(离线 manifest)|${SSH} \"${K} apply -f /opt/cubestack/addons/lws.yaml 2>/dev/null || true\""
  "等待 LWS webhook 就绪|${SSH} \"${K} rollout status deploy/lws-controller-manager -n lws-system --timeout=3m 2>/dev/null || true\""
  "验证 LWS CRD 注册|${SSH} \"${K} get crd leaderworkloadsets.lws.k8s.io 2>/dev/null || true\""
  "部署测试 LeaderWorkerSet 校验|${SSH} \"${K} apply -f /opt/cubestack/addons/lws-smoke.yaml 2>/dev/null || true\""
)
addon_stub "gpu_lws" LWS_STEPS
