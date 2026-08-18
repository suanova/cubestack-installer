#!/bin/bash
# ============================================================
# 部署模块: 08-k8s — 部署 kubespray 集群(离线)
# 调用 cubestack-offline.sh install(含预加载镜像/同步文件/ansible-playbook cluster.yml)
# 透传 cluster.conf 中 PRELOAD_IMAGE_PATTERNS 等配置
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib-common.sh"
load_config

OFFLINE_SCRIPT="${REPO_ROOT}/deployments/kubespray/cubestack-offline.sh"
[ -f "${OFFLINE_SCRIPT}" ] || { err "未找到 ${OFFLINE_SCRIPT}"; exit 1; }

say "执行 kubespray 离线部署 (via cubestack-offline.sh) ..."
# 透传 cluster.conf 的预加载镜像集合; 仅当显式定义了该变量(含空串=全量同步)才传递,
# 否则由 cubestack-offline.sh 回退内置默认最小集合
OFFLINE_ENV=(
    "CUBESTACK_CLUSTER=${CLUSTER_NAME}"
    "CUBESTACK_KUBESPRAY_DIR=${KUBESPRAY_DIR}"
    "CUBESTACK_INVENTORY_DIR=${KUBESPRAY_INV_DIR}"
    "CUBESTACK_LOCAL_REPO_DIR=${LOCAL_REPO_DIR}"
)
[ -n "${PRELOAD_IMAGE_PATTERNS+x}" ] && \
    OFFLINE_ENV+=("CUBESTACK_PRELOAD_IMAGE_PATTERNS=${PRELOAD_IMAGE_PATTERNS}")
env "${OFFLINE_ENV[@]}" bash "${OFFLINE_SCRIPT}" install
ok "kubespray 集群部署完成"
