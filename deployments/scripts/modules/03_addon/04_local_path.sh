#!/bin/bash
# ============================================================
# MODULE: local_path
# DESC: 确保 local-path-provisioner 默认 StorageClass 就绪
#       作为 registry 等依赖本地 PVC 组件的前置检查, 排在 registry 之前。
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: LOCAL_PATH_ENABLED
# 说明:
#   · local-path-provisioner 由 kubespray addon(external_provisioner)安装;
#     本模块仅做**就绪校验**(幂等), 不重复安装。
#   · 依赖顺序: metallb → local-path(本模块)→ registry —— registry 的 PVC 用 local-path SC。
#   · 校验: storageclass.local-path 存在且为默认。
# 用法:   sudo ./deploy-cluster.sh --with-k8s(TOGGLE 自动启用) 或 --enable local_path
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# 开关: 未启用 local-path 则跳过(不报错)
[ "${LOCAL_PATH_ENABLED:-true}" = "true" ] || { say "LOCAL_PATH_ENABLED=false, 跳过 local-path 就绪检查"; exit 0; }

FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
SSH() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
           "${SSH_USER:-ubuntu}@${FIRST_MASTER}" "$@"; }
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

say "检查 local-path-provisioner 就绪(registry 等本地 PVC 组件的前置依赖)..."
SC="$(SSH "${K} get sc 2>/dev/null" || true)"
if ! grep -q '^local-path ' <<<"${SC}"; then
    err "未找到 StorageClass local-path。检查 addons.yml local_path_provisioner_enabled=true 且 kubespray 已部署 local-path-provisioner addon"
    exit 1
fi
if ! grep '^local-path ' <<<"${SC}" | grep -q 'default'; then
    warn "local-path SC 存在但非默认(default); 若 registry 的 PVC 显式指定 storageClass=local-path 则无碍, 否则请设为默认"
fi
ok "local-path StorageClass 就绪: $(grep '^local-path ' <<<"${SC}" | awk '{print $1, $2}')"