#!/bin/bash
# ============================================================
# 部署模块: 07-inventory — 生成 kubespray inventory + 同步配置
# 调用 gen-inventory.sh(内部含 sync-kubespray-config.sh)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib-common.sh"
load_config

say "生成 kubespray 兼容 inventory + 同步配置 ..."
bash "${SCRIPT_DIR}/gen-inventory.sh"
ok "inventory 就绪"
