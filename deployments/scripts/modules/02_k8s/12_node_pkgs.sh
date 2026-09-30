#!/bin/bash
# ============================================================
# MODULE: node_pkgs
# DESC: 节点系统包对账(离线 .deb 装到位; 旧版本由 apt 先摘后装; 修复被打破的 dpkg 依赖图)
# PHASE: k8s
# DEFAULT: 1
# REPEAT: 1
# REQUIRES: k8s_passwordless
# 说明:
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

say "节点系统包对账(离线 .deb; 旧版本先摘后装; 修复破损的 apt 依赖图)..."
bash "${SCRIPT_DIR}/tools/node/reconcile-node-packages.sh" ${RECONCILE_ARGS:-}
ok "节点系统包已对账"
