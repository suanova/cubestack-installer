#!/bin/bash
# ============================================================
# MODULE: node_pkgs
# DESC: 已停用(2026-11-23): 不再自动安装节点 OS 包/helm/nodejs; 仅保留开关兼容
# PHASE: k8s
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: NODE_PKGS_ENABLED
# REQUIRES: k8s_passwordless pre_install_check
# 说明:
#   · **2026-11-23 停用**: NODE_PKGS_ENABLED 不再触发任何安装。通用 OS 包由 OS 镜像
#     提供, pre_install_check 只做存在性检查; 缺失时运行
#     tools/manual/install-os-packages.sh 手动安装。
#   · 节点 helm 为可选项: tools/manual/install-os-packages.sh --with-helm
#     (离线包 os/helm/; 旧 os/helm-nodejs/ 兼容); nodejs 已移除, 不再安装。
#   · 保留本模块与 TOGGLE 仅为兼容旧 cluster.conf 及 --steps/--enable 调用; 执行本模块
#     只打印提示并 exit 0, 不改动节点。
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

case "$(printf '%s' "${NODE_PKGS_ENABLED:-false}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on)
        say "NODE_PKGS_ENABLED=true 已停用: 节点 OS 包/helm 不再由 deploy-cluster 安装"
        say "  通用 OS 包/可选 helm 请运行: tools/manual/install-os-packages.sh [--with-helm]"
        say "  nodejs 已移除, 不再安装"
        exit 0
        ;;
    *)
        say "NODE_PKGS_ENABLED=false, 跳过节点 OS 包(通用 OS 包/可选 helm 均为手动安装)"
        exit 0
        ;;
esac
