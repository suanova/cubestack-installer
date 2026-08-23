#!/bin/bash
# ============================================================
# MODULE: kubevirt
# DESC: KubeVirt 虚拟机能力(VM 形态业务交付, P2 能力增强)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: KUBEVIRT_ENABLED
# 说明:
#   【P2-3 规划模块·伪代码占位(DEV-35)】KubeVirt:
#   · 部署 KubeVirt 虚拟化组件, 完善集群虚拟化适配
#   · 支持虚拟机创建、启动、启停、管理, 补齐 VM 形态业务交付
#   · 接入方法: 将下方 STEPS 伪代码替换为真实命令, 或 ADDON_STUB_EXEC=1 试执行
# 数据源: cluster.conf (KUBEVIRT_ENABLED / NODES)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

if [ "${KUBEVIRT_ENABLED:-false}" != "true" ]; then
    say "跳过 KubeVirt(配置 KUBEVIRT_ENABLED=true 可启用)"
    exit 0
fi

FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
SSH="ssh -i ${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${FIRST_MASTER}"
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

# ── 伪代码步骤(占位): 替换为真实实现 ──
KUBEVIRT_STEPS=(
  "部署 KubeVirt operator(离线 manifest)|${SSH} \"${K} apply -f /opt/cubestack/addons/kubevirt-operator.yaml 2>/dev/null || true\""
  "创建 KubeVirt CR(启用虚拟化)|${SSH} \"${K} apply -f /opt/cubestack/addons/kubevirt-cr.yaml 2>/dev/null || true\""
  "等待 virt-controller/virt-api 就绪|${SSH} \"${K} -n kubevirt rollout status deploy/virt-controller --timeout=5m 2>/dev/null || true\""
  "创建测试虚拟机(VM CR)|${SSH} \"${K} apply -f /opt/cubestack/addons/kubevirt-smoke-vm.yaml 2>/dev/null || true\""
  "验证虚拟机创建/启动|${SSH} \"${K} get vmi -o wide 2>/dev/null || true\""
)
addon_stub "kubevirt" KUBEVIRT_STEPS
