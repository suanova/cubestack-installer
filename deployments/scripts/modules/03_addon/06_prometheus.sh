#!/bin/bash
# ============================================================
# MODULE: prometheus
# DESC: Prometheus + Prometheus Operator + 监控附属组件(P1 刚需)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: PROMETHEUS_ENABLED
# 说明:
#   【P1-2/P1-3 规划模块·伪代码占位】监控底座:
#   · Prometheus + Prometheus Operator(kube-prometheus-stack)
#   · kube-state-metrics + Perses 可视化
#   · 采集: node-exporter(节点) / kubelet/cAdvisor(容器) / DCGM(NVIDIA GPU)
#     / MetaX(沐曦 GPU) / RDMA / Ceph exporter
#   · 接入方法: 将下方 STEPS 伪代码替换为真实命令, 或 ADDON_STUB_EXEC=1 试执行
# 数据源: cluster.conf (PROMETHEUS_ENABLED / NODES)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

if [ "${PROMETHEUS_ENABLED:-false}" != "true" ]; then
    say "跳过 Prometheus 监控(配置 PROMETHEUS_ENABLED=true 可启用)"
    exit 0
fi

FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
SSH="ssh -i ${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${FIRST_MASTER}"
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

# ── 伪代码步骤(占位): 替换为真实实现 ──
PROMETHEUS_STEPS=(
  "创建 monitoring 命名空间|${SSH} \"${K} create ns monitoring 2>/dev/null || true\""
  "部署 kube-prometheus-stack(离线 helm)|${SSH} \"helm install prometheus /opt/cubestack/addons/kube-prometheus-stack -n monitoring 2>/dev/null || true\""
  "部署 node-exporter(节点指标)|${SSH} \"${K} apply -f /opt/cubestack/addons/node-exporter.yaml 2>/dev/null || true\""
  "部署 kube-state-metrics(集群指标)|${SSH} \"${K} apply -f /opt/cubestack/addons/kube-state-metrics.yaml 2>/dev/null || true\""
  "部署 Perses 可视化|${SSH} \"${K} apply -f /opt/cubestack/addons/perses.yaml 2>/dev/null || true\""
  "部署 DCGM Exporter(NVIDIA GPU)|${SSH} \"${K} apply -f /opt/cubestack/addons/dcgm-exporter.yaml 2>/dev/null || true\""
  "部署 MetaX Exporter(沐曦 GPU)|${SSH} \"${K} apply -f /opt/cubestack/addons/metax-exporter.yaml 2>/dev/null || true\""
  "部署 RDMA Exporter|${SSH} \"${K} apply -f /opt/cubestack/addons/rdma-exporter.yaml 2>/dev/null || true\""
  "部署 Ceph Exporter|${SSH} \"${K} apply -f /opt/cubestack/addons/ceph-exporter.yaml 2>/dev/null || true\""
  "等待监控底座就绪并验证|${SSH} \"${K} -n monitoring get pods -o wide 2>/dev/null || true\""
)
addon_stub "prometheus" PROMETHEUS_STEPS
