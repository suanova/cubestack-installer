#!/bin/bash
# ============================================================
# MODULE: gpu_operator
# DESC: 安装沐曦 Muxi GPU Operator
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: GPU_OPERATOR_ENABLED
# 说明:
#   【P1-5 规划模块·伪代码占位】沐曦 GPU Operator:
#   · 完成 GPU 驱动部署、硬件识别、集群 GPU 资源调度, 配套 MetaX 指标采集
#   · 接入方法: 将下方 STEPS 伪代码替换为真实命令(kubectl apply / helm / 离线 manifest),
#     或设置 ADDON_STUB_EXEC=1 试执行
# 数据源: cluster.conf (GPU_OPERATOR_ENABLED / NODES)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

if [ "${GPU_OPERATOR_ENABLED:-false}" != "true" ]; then
    say "跳过沐曦 GPU Operator(配置 GPU_OPERATOR_ENABLED=true 可启用)"
    exit 0
fi

FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
SSH="ssh -i ${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${FIRST_MASTER}"
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

# ── 伪代码步骤(占位): 替换为真实实现 ──
GPU_OPERATOR_STEPS=(
  "定位沐曦 GPU 节点|${SSH} \"${K} get nodes -l muxi.com/gpu=true --no-headers 2>/dev/null || true\""
  "创建 muxi-gpu-operator 命名空间|${SSH} \"${K} create ns muxi-gpu-operator 2>/dev/null || true\""
  "应用 GPU Operator manifest(离线)|${SSH} \"${K} apply -f /opt/cubestack/addons/muxi-gpu-operator.yaml 2>/dev/null || true\""
  "等待 operator ready|${SSH} \"${K} -n muxi-gpu-operator rollout status deploy/muxi-gpu-operator --timeout=5m 2>/dev/null || true\""
  "验证 GPU 设备插件 DaemonSet|${SSH} \"${K} -n muxi-gpu-operator get ds -o wide 2>/dev/null || true\""
  "部署 MetaX 指标采集(Exporter)|${SSH} \"${K} apply -f /opt/cubestack/addons/metax-exporter.yaml 2>/dev/null || true\""
)
addon_stub "gpu_operator" GPU_OPERATOR_STEPS
