#!/bin/bash
# ============================================================
# MODULE: vm_sshkey
# DESC: 生成集群 SSH 密钥对(幂等)
# PHASE: env
# DEFAULT: 1
# REPEAT: 0
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

say "生成 SSH 密钥对(幂等) ..."
bash "${SCRIPT_DIR}/tools/node/gen-ssh-key.sh"
ok "SSH 密钥就绪"
