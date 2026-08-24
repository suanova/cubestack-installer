#!/bin/bash
# ============================================================
# MODULE: k8s_deploy
# DESC: 部署 kubespray 集群(离线)
# PHASE: k8s
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: K8S_ENABLED
# 说明: 调用 cubestack-offline.sh install; 透传 cluster.conf 中 PRELOAD_IMAGE_PATTERNS
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# 部署前强制重新生成 inventory(hosts.yml + group_vars 均由当前 cluster.conf 派生):
# 即使本次未执行 inventory 模块(--skip inventory / --steps k8s), 也保证 kubespray
# 始终按当前 cluster.conf 的节点部署, 不因断点续跑跳过而使用过期的 hosts.yml
say "重新生成 inventory(依据当前 ${CLUSTER_CONF})..."
bash "${SCRIPT_DIR}/tools/k8s/gen-inventory.sh"

OFFLINE_SCRIPT="${REPO_ROOT}/deployments/kubespray/cubestack-offline.sh"
[ -f "${OFFLINE_SCRIPT}" ] || { err "未找到 ${OFFLINE_SCRIPT}"; exit 1; }

say "执行 kubespray 离线部署 (via cubestack-offline.sh) ..."
# 透传 cluster.conf 的预加载镜像集合; 仅当显式定义了该变量(含空串=全量同步)才传递,
# 否则由 cubestack-offline.sh 回退内置默认最小集合
# 离线文件路径: OFFLINE_FILES_DIR(全局切换根目录) + CUBESTACK_LOCAL_REPO_DIR(完整路径, 最高优先)
OFFLINE_ENV=(
    "CUBESTACK_KUBESPRAY_DIR=${KUBESPRAY_DIR}"
    "CUBESTACK_INVENTORY_DIR=${KUBESPRAY_INV_DIR}"
    "OFFLINE_FILES_DIR=${OFFLINE_FILES_DIR}"
    "CUBESTACK_LOCAL_REPO_DIR=${LOCAL_REPO_DIR}"
)
[ -n "${PRELOAD_IMAGE_PATTERNS+x}" ] && \
    OFFLINE_ENV+=("CUBESTACK_PRELOAD_IMAGE_PATTERNS=${PRELOAD_IMAGE_PATTERNS}")
env "${OFFLINE_ENV[@]}" bash "${OFFLINE_SCRIPT}" install
ok "kubespray 集群部署完成"
