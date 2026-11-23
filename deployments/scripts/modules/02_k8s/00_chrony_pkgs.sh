#!/bin/bash
# ============================================================
# MODULE: chrony_pkgs
# DESC: 已停用(2026-11-23): 不再自动安装 chrony; 仅保留开关兼容
# PHASE: k8s
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: CHRONY_PKGS_ENABLED
# REQUIRES: k8s_passwordless
# 说明:
#   · **2026-11-23 停用**: CHRONY_PKGS_ENABLED 不再触发任何安装。chrony 由节点
#     OS 黄金镜像/运维预装; pre_install_check 只检查存在性。
#   · 如需手动安装: `tools/manual/install-os-packages.sh`(默认含 chrony 专用集;
#     也可单独运行旧工具 `tools/node/install-chrony-packages.sh`)。
#   · 保留本模块与 TOGGLE 仅为兼容旧 cluster.conf 及 --steps/--enable 调用; 执行本模块
#     只打印提示并 exit 0, 不改动节点。
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

case "$(printf '%s' "${CHRONY_PKGS_ENABLED:-false}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on)
        say "CHRONY_PKGS_ENABLED=true 已停用: chrony 不再由 deploy-cluster 自动安装"
        say "  请用 OS 镜像预装, 或运行: tools/manual/install-os-packages.sh(默认含 chrony)"
        say "  旧工具仍可单独执行: tools/node/install-chrony-packages.sh"
        exit 0
        ;;
    *)
        say "CHRONY_PKGS_ENABLED=false, 跳过 chrony 离线装包(默认假设节点镜像已预装 chrony; 需要时用手动脚本)"
        exit 0
        ;;
esac
