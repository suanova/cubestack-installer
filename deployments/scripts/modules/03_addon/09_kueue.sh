#!/bin/bash
# ============================================================
# MODULE: kueue
# DESC: Kueue 队列治理(任务队列/配额/调度策略, P2 能力增强)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: KUEUE_ENABLED
# 说明:
#   【P2-2 规划模块·伪代码占位(DEV-29)】Kueue:
#   · 部署 Kueue, 配置任务队列规则、资源配额与调度策略
#   · 实现集群任务排队、资源抢占管控、算力资源合理分配
#   · 接入方法: 将下方 STEPS 伪代码替换为真实命令, 或 ADDON_STUB_EXEC=1 试执行
# 数据源: cluster.conf (KUEUE_ENABLED / NODES)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

if [ "${KUEUE_ENABLED:-false}" != "true" ]; then
    say "跳过 Kueue(配置 KUEUE_ENABLED=true 可启用)"
    exit 0
fi

FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
SSH="ssh -i ${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${FIRST_MASTER}"
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

# ── 伪代码步骤(占位): 替换为真实实现 ──
KUEUE_STEPS=(
  "应用 Kueue operator(离线 manifest)|${SSH} \"${K} apply -f /opt/cubestack/addons/kueue.yaml 2>/dev/null || true\""
  "等待 Kueue 控制器就绪|${SSH} \"${K} -n kueue-system rollout status deploy/kueue-controller-manager --timeout=3m 2>/dev/null || true\""
  "创建 ClusterQueue(算力资源池/配额)|${SSH} \"${K} apply -f /opt/cubestack/addons/kueue-clusterqueue.yaml 2>/dev/null || true\""
  "创建 LocalQueue(任务队列)|${SSH} \"${K} apply -f /opt/cubestack/addons/kueue-localqueue.yaml 2>/dev/null || true\""
  "创建 ResourceFlavor(资源标签/抢占策略)|${SSH} \"${K} apply -f /opt/cubestack/addons/kueue-resourceflavor.yaml 2>/dev/null || true\""
  "验证队列与配额生效|${SSH} \"${K} get clusterqueue,localqueue -A 2>/dev/null || true\""
)
addon_stub "kueue" KUEUE_STEPS
