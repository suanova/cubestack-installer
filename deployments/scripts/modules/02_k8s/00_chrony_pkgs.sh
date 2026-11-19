#!/bin/bash
# ============================================================
# MODULE: chrony_pkgs
# DESC: 节点 chrony 离线装包(可选; 默认关, CHRONY_PKGS_ENABLED=true 启用)
# PHASE: k8s
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: CHRONY_PKGS_ENABLED
# REQUIRES: k8s_passwordless
# 说明:
#   · **与 NTP 同步解耦**(2026-11-19 用户口径): 本模块只从
#     offline-files/os/packages/chrony 安装 chrony 包, 不写 chrony.conf、不启停 NTP 服务;
#     同步/权威/客户端配置由 k8s_ntp(setup-ntp.sh)负责, 且 NTP 同步是**必选**步骤。
#   · **默认关**: NTP 同步假设节点黄金镜像/运维已预装 chrony; 需要 installer 装包时
#     启用本模块(启用三选一: cluster.conf CHRONY_PKGS_ENABLED=true / --enable chrony_pkgs /
#     --steps chrony_pkgs)。
#   · 全量部署时在"安装前 NTP 阶段"之前执行(deploy-cluster.sh), 扩容时由 k8s_scale 先调用;
#     逻辑全在 tools/node/install-chrony-packages.sh(可单独跑: bash <tool> [--ip <IP>])。
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# 开关自检(k8s_scale 直接调用本脚本时同样受控)
case "$(printf '%s' "${CHRONY_PKGS_ENABLED:-false}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on) ;;
    *) say "CHRONY_PKGS_ENABLED=false, 跳过 chrony 离线装包(默认假设节点镜像已预装 chrony; 需要时置 true 或 --steps chrony_pkgs)"; exit 0 ;;
esac

say "节点 chrony 离线装包(可选步骤; 只装包, 不配置 NTP 服务)..."
bash "${SCRIPT_DIR}/tools/node/install-chrony-packages.sh"
ok "节点 chrony 离线装包完成(后续 NTP 同步由 k8s_ntp 负责)"
