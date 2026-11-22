#!/bin/bash
# ============================================================
# MODULE: node_pkgs
# DESC: 节点系统包对账(离线 .deb 安装; 默认关, NODE_PKGS_ENABLED=true 启用)
# PHASE: k8s
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: NODE_PKGS_ENABLED
# REQUIRES: k8s_passwordless pre_install_check
# 说明:
#   · **默认关闭(2026-11-18)**: 节点前置包由 OS 黄金镜像/运维预装, 默认流程
#     只由 pre_install_check 做 warn-only 存在性检查, installer 不安装 OS 包。
#   · 启用三选一: cluster.conf 置 NODE_PKGS_ENABLED=true / --enable node_pkgs /
#     --steps node_pkgs。启用后从 offline-files/os/packages/ubuntu-<VERSION_ID> 取 .deb 做 apt 对账。
#   · **必须在 k8s_deploy 之前**(见 06_k8s_deploy.sh 的 REQUIRES 显式声明本模块): kubespray 的
#     bootstrap_os → system_packages 一旦遇到 apt 依赖图破损就**直接失败**, 且报错只提表象包。
#     实测 2026-09-28: 离线 .deb 集把 libudev1 升到 3.22 而 udev 仍 3.12(严格依赖 `= 3.12`)
#     ⇒ 节点上任何 apt 操作都报 `E: Unmet dependencies` ⇒ 部署死在 "Manage packages"。
#     ⚠ 定序**不能只靠文件序号**(12 > 06 会排在 k8s_deploy 之后) —— 与 kube_vip 当年
#     "序号不足以定序, 补 REQUIRES" 同一手法。
#   · **模块化**: 本文件只是壳, 逻辑全在 tools/node/reconcile-node-packages.sh(可单独跑:
#     `bash tools/node/reconcile-node-packages.sh --ip <IP> [--dry-run]`)。
#   · **不引入新问题**: 只碰"我们离线目录里带的包"; 改前先出计划; 收尾用 `apt-get check` 复核,
#     不健康即非零退出(挡在 6 分钟的 kubespray 之前, 而不是让它跑到一半再炸)。
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# 开关自检: k8s_scale 会直接调用本脚本, 也必须受同一开关控制。
case "$(printf '%s' "${NODE_PKGS_ENABLED:-false}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on) ;;
    *) say "NODE_PKGS_ENABLED=false, 跳过节点系统包对账(需要时置 true 或 --steps node_pkgs)"; exit 0 ;;
esac

say "节点系统包对账(离线 .deb; 旧版本先摘后装; 修复破损的 apt 依赖图)..."
bash "${SCRIPT_DIR}/tools/node/reconcile-node-packages.sh" ${RECONCILE_ARGS:-}
ok "节点系统包已对账"
