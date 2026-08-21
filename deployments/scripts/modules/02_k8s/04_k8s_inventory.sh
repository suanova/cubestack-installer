#!/bin/bash
# ============================================================
# MODULE: k8s_inventory
# DESC: 生成 kubespray inventory + 同步配置
# PHASE: k8s
# DEFAULT: 1
# REPEAT: 1
# 说明: 调用 gen-inventory.sh(内部含 sync-kubespray-config.sh + sync-addons-config.sh)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

say "生成 kubespray 兼容 inventory + 同步配置 ..."
bash "${SCRIPT_DIR}/tools/k8s/gen-inventory.sh"
ok "inventory 就绪"
