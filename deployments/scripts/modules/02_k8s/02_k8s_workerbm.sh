#!/bin/bash
# ============================================================
# MODULE: k8s_workerbm
# DESC: 已停用(2026-11-23): 不再自动安装 worker OS 包; 仅保留开关兼容
# PHASE: k8s
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: WORKER_PKGS_ENABLED
# REQUIRES: k8s_passwordless pre_install_check
# 说明:
#   · **2026-11-23 停用**: WORKER_PKGS_ENABLED 不再触发任何安装。worker 节点 OS 包
#     由 OS 黄金镜像/运维预装; pre_install_check 只做存在性检查。
#   · 如需手动安装: `tools/node/install-worker-packages.sh <IP> [user]`
#     (fresh 节点清理需显式 --fresh-node / CUBESTACK_FRESH_NODE=1)。
#   · 保留本模块与 TOGGLE 仅为兼容旧 cluster.conf 及 --steps/--enable 调用; 执行本模块
#     只打印提示并 exit 0, 不做连通性检查、不改动节点。
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

case "$(printf '%s' "${WORKER_PKGS_ENABLED:-false}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on)
        say "WORKER_PKGS_ENABLED=true 已停用: worker 连通性检查/离线装包不再由 deploy-cluster 执行"
        say "  worker OS 包请用 OS 镜像预装, 或手动运行: tools/node/install-worker-packages.sh <IP> [user]"
        exit 0
        ;;
    *)
        say "WORKER_PKGS_ENABLED=false, 跳过 worker 离线装包(改为 OS 预装/手动工具)"
        exit 0
        ;;
esac
