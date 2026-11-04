#!/bin/bash
# ============================================================
# MODULE: k8s_asset_prefetch
# DESC: 在线安装：预取 kubespray 二进制/文件（不拉镜像）
# PHASE: k8s
# DEFAULT: 1
# REPEAT: 1
# REQUIRES: k8s_inventory
# 说明:
#   · 仅在线模式（CUBESTACK_ONLINE=1）执行；离线/商业版本树直接跳过。
#   · 镜像由 mirror catalog 物化，本模块只准备 kubelet/kubeadm/kubectl/crictl/CNI 等
#     kubespray files.list 里的二进制/文件，并写入 download_cache_dir。
#   · 必须在 k8s_inventory 之后：files.list 的 URL 依赖 k8s-versions.yml 里的版本钉子。
#   · 06_k8s_deploy.sh 的 REQUIRES 显式声明本模块，保证在 kubespray 之前执行。
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

if [ "${CUBESTACK_ONLINE:-0}" != "1" ]; then
    say "非在线模式，跳过 k8s 二进制/文件预取"
    exit 0
fi

OFFLINE_SCRIPT="${REPO_ROOT}/deployments/kubespray/cubestack-offline.sh"
say "在线模式：预取 k8s 二进制/文件（不拉镜像）..."
env \
    "CUBESTACK_KUBESPRAY_DIR=${KUBESPRAY_DIR}" \
    "CUBESTACK_INVENTORY_DIR=${KUBESPRAY_INV_DIR}" \
    "CUBESTACK_BASE_DIR=${KUBESPRAY_BASE_DIR:-${REPO_ROOT}/deployments/kubespray}" \
    "OFFLINE_FILES_DIR=${OFFLINE_FILES_DIR}" \
    "CUBESTACK_LOCAL_REPO_DIR=${LOCAL_REPO_DIR}" \
    "CUBESTACK_REMOTE_USER=${SSH_USER}" \
    bash "${OFFLINE_SCRIPT}" download-files
ok "k8s 二进制/文件就绪"
