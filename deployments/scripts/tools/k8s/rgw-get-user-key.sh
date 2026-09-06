#!/bin/bash
# ============================================================
# TOOL: rgw-get-user-key
# DESC: 经 toolbox 创建 RGW 测试用户并输出 AK/SK(两行: access_key\nsecret_key), 用完即删
# 用法: ./rgw-get-user-key.sh <uid>   → stdout 输出两行(AK / SK)
# 方案: toolbox 直接跑 radosgw-admin --format json(纯 JSON 到 stdout)
#       → 部署机本地 python 解析 AK/SK → toolbox 删用户。stdout 只输出两行凭据。
# 数据源: cluster.conf (NODES / SSH_USER / SSH_KEY_NAME / CEPH_NAMESPACE)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
# ★ load_config/init_remote_kubectl 的 say/warn 走 stdout 会污染凭据输出 —— 全部导到 stderr
# 注意: 不能 exec 1>&2(会把整个脚本 stdout 永久改走 stderr, 凭据输出丢失);
# 只在 load_config/init 时局部重定向。
{ load_config; } >&2 2>&1 || true
init_remote_kubectl >&2 || exit 1

CEPH_NAMESPACE="${CEPH_NAMESPACE:-rook-ceph}"
UID_NAME="${1:-verify-rgw-$(date +%s)}"

# ① 创建用户, 纯 JSON(仅 stdout, 不带 stderr)
RGW_JSON="$(SSH "${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph-tools -- \
    radosgw-admin user create --uid=${UID_NAME} --display-name=verify --format json --rgw-zone=my-store" 2>/dev/null || true)"

# ② 部署机本地 python 解析 AK/SK, stdout 只输出两行凭据
if [ -n "${RGW_JSON}" ]; then
    python3 -c 'import sys,json
try:
    d=json.loads(sys.stdin.read())
    print(d["keys"][0]["access_key"])
    print(d["keys"][0]["secret_key"])
except Exception:
    pass' <<< "${RGW_JSON}" | grep -E '^[A-Za-z0-9+/=]{16,}$' | head -2
    # ③ 删用户
    SSH "${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph-tools -- \
        radosgw-admin user rm --uid=${UID_NAME} >/dev/null 2>&1" || true
    exit 0
fi
exit 1
