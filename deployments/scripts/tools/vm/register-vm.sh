#!/bin/bash
# ============================================================
# 将已存在的 VM 注册到 config/cluster.conf 的 NODES 数组(新5字段格式)
# 用法: ./register-vm.sh <role> <hostname> <ip> [user] [password]
#   默认: user=ubuntu password=-(用默认 SSH_DEFAULT_PASSWORD)
#   示例: ./register-vm.sh worker cubestack-k8s-worker01 10.244.2.11 ubuntu -
# 数据源: config/cluster.conf (路径自动探测)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

[ $# -ge 3 ] || { echo "用法: $0 <role> <hostname> <ip> [user] [password]"; exit 1; }

ROLE="$1"; HOSTNAME="$2"; IP="$3"
USER="${4:-ubuntu}"
PW="${5:--}"

register_node_to_conf "${ROLE}" "${HOSTNAME}" "${IP}" "${USER}" "${PW}"
