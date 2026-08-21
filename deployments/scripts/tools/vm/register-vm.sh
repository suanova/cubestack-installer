#!/bin/bash
# ============================================================
# 将已存在的 VM 注册到 config/cluster.conf 的 NODES 数组
# 用法: ./register-vm.sh <role> <hostname> <ip> <mac> <mem> <cpu> <disk> [user] [password]
#   默认: user=ubuntu password=-
# 数据源: config/cluster.conf (路径自动探测)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

[ $# -ge 7 ] || { echo "用法: $0 <role> <hostname> <ip> <mac> <mem> <cpu> <disk> [user] [password]"; exit 1; }

ROLE="$1"; HOSTNAME="$2"; IP="$3"; MAC="$4"; MEM="$5"; CPU="$6"; DISK="$7"
USER="${8:-ubuntu}"
PW="${9:--}"

register_node_to_conf "${ROLE}" "${HOSTNAME}" "${IP}" "${MAC}" "${MEM}" "${CPU}" "${DISK}" "${USER}" "${PW}"