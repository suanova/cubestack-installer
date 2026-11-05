#!/bin/bash
# ============================================================
# MODULE: node_pkgs
# DESC: 节点前置包检查(只校验存在性; 不安装、不修复 OS 包)
# PHASE: k8s
# DEFAULT: 1
# REPEAT: 1
# REQUIRES: k8s_passwordless
# 说明:
#   · 节点前置包由 OS 黄金镜像/运维预装; installer 只做只读检查。
#   · 2.1 默认 warn-only; 缺包时列出清单并继续, 由后续模块按自身硬依赖决定是否失败。
#   · 包检查在 kubespray 之前执行, 让缺包尽早暴露。
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

if [ "${CUBESTACK_OS_CHECK_DONE:-0}" = "1" ]; then
    say "节点前置包已由在线安装预检，跳过复检"
    exit 0
fi

hosts=()
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    node_parse "${line}"
    node_matches "${NODE_HOSTNAME}" || continue
    hosts+=("${NODE_USER}@${NODE_IP}")
done
if [ "${#hosts[@]}" -eq 0 ]; then
    say "没有需要检查的节点"
    exit 0
fi

HOSTS_CSV="$(IFS=,; echo "${hosts[*]}")"
SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
check_args=(--baseline "${REPO_ROOT}/versions/base.yaml" --hosts "${HOSTS_CSV}"
    --key "${SSH_KEY}" --warn-only)
if [ -n "${SSH_DEFAULT_PASSWORD:-}" ]; then
    check_args+=(--password "${SSH_DEFAULT_PASSWORD}")
fi

say "节点前置包检查(warn-only; installer 不安装 OS 包)..."
bash "${SCRIPT_DIR}/tools/online/check-os-packages.sh" "${check_args[@]}"
ok "节点前置包检查完成"
