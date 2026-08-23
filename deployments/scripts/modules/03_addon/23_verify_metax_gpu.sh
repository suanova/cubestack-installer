#!/bin/bash
# ============================================================
# MODULE: verify_metax_gpu
# DESC: 验证集群节点是否识别沐曦 GPU(metax-tech.com/gpu allocatable + 节点清单)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# 说明:
#   · 验证模块不设 TOGGLE, 由 --steps verify_metax_gpu 或 --steps verify(自动纳入)显式执行。
#   · 复用 tools/k8s/verify-metax-gpu.sh: 列出每节点 GPU capacity/allocatable/label/可调度,
#     汇总 GPU 识别节点数与总 GPU 数, 提示 gpu.installed=true 但 allocatable 为空的异常。
#   · 部署时 master 检测到 GPU 会自动解除不可调度(见 04_gpu_operator.sh 第 5 步)。
# 用法: sudo ./deploy-cluster.sh --steps verify_metax_gpu
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

bash "${SCRIPT_DIR}/tools/k8s/verify-metax-gpu.sh"
