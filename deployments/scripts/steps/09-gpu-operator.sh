#!/bin/bash
# ============================================================
# 部署模块: 09-gpu-operator — 安装沐曦 Muxi GPU Operator
# 【占位模块】默认关闭; 由 deploy-cluster.sh --enable gpu_operator 或 --steps 启用
# 接入方法: 在此实现 operator 安装逻辑(kubectl apply / helm / 离线 manifest),
#           集群 ready 后可经第一个 master 的 kubectl 执行
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib-common.sh"
load_config

say "安装沐曦 Muxi GPU Operator ..."

# 定位第一个 master(执行 kubectl 的入口)
FIRST_MASTER_IP=""
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    IFS=, read -r role hostname ip mac mem cpu disk user pw node_type <<<"${line}"
    if [ "${role}" = "master" ]; then FIRST_MASTER_IP="${ip}"; break; fi
done
[ -n "${FIRST_MASTER_IP}" ] || { err "未找到 master 节点"; exit 1; }

# TODO(沐曦 GPU Operator): 填入实际安装步骤, 示例:
#   K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"
#   SSH="ssh -i ${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s} -o StrictHostKeyChecking=no ubuntu@${FIRST_MASTER_IP}"
#   $SSH "$K apply -f <operator-manifest.yaml>" 2>/dev/null
#   $SSH "$K -n muxi-gpu-operator rollout status deploy/..." 2>/dev/null
warn "模块 [gpu_operator] 尚未实现具体逻辑, 请编辑 steps/09-gpu-operator.sh 接入沐曦 GPU Operator 安装"
