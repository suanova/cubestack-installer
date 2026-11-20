#!/bin/bash
# ============================================================
# test-ceph-topology.sh — CEPH_TOPOLOGY 解析 + 单/多节点有效参数
#
# 覆盖:
#   ① auto: 1→single, >=3→multi, 0/2→ineligible
#   ② 显式 single/multi 的节点数校验
#   ③ 单节点有效参数: mon1/mgr1/size1/min1/osd/requireSafe=false/MDS1/false/RGW1
#   ④ 多节点有效参数保持 3/2/3/2/host/true/2/true/2
#   ⑤ 显式覆盖: size2 → requireSafe=false; size3 → true; min>size 失败
#
# 用法: bash deployments/scripts/tools/tests/test-ceph-topology.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$3] 实际[$2]"; fail=1; fi; }

run() {  # run <shell-code>
    ( set +u
      source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
      eval "$1" )
}

echo "== ① auto 拓扑 =="
chk "1 节点"  "$(run 'ceph_topology_resolve auto 1 3')" "single"
chk "3 节点"  "$(run 'ceph_topology_resolve auto 3 3')" "multi"
chk "5 节点"  "$(run 'ceph_topology_resolve auto 5 3')" "multi"
chk "0 节点"  "$(run 'if ceph_topology_resolve auto 0 3 >/dev/null; then echo ok; else echo bad; fi')" "bad"
chk "2 节点"  "$(run 'if ceph_topology_resolve auto 2 3 >/dev/null; then echo ok; else echo bad; fi')" "bad"
chk "大小写"  "$(run 'ceph_topology_resolve AUTO 1 3')" "single"

echo "== ② 显式拓扑 =="
chk "single 1"  "$(run 'ceph_topology_resolve Single 1 3')" "single"
chk "single 2"  "$(run 'if ceph_topology_resolve single 2 3 >/dev/null; then echo ok; else echo bad; fi')" "bad"
chk "multi 2"   "$(run 'if ceph_topology_resolve multi 2 3 >/dev/null; then echo ok; else echo bad; fi')" "bad"
chk "multi 3"   "$(run 'ceph_topology_resolve multi 3 3')" "multi"
chk "非法值"    "$(run 'if ceph_topology_resolve bogus 3 3 >/dev/null; then echo ok; else echo bad; fi')" "bad"

echo "== ③ 单节点默认参数 =="
out="$(run '
    CEPH_EXPLICIT_MGR=0 CEPH_EXPLICIT_REPLICAS=0 CEPH_EXPLICIT_MIN_SIZE=0
    CEPH_EXPLICIT_FAILURE_DOMAIN=0 CEPH_EXPLICIT_MDS=0 CEPH_EXPLICIT_MDS_STANDBY=0 CEPH_EXPLICIT_RGW=0
    ceph_apply_effective_spec single >/dev/null 2>&1
    printf "%s/%s/%s/%s/%s/%s/%s/%s/%s\n" "$CEPH_EFF_MON_COUNT" "$CEPH_EFF_MGR_COUNT" \
      "$CEPH_EFF_POOL_REPLICAS" "$CEPH_EFF_POOL_MIN_SIZE" "$CEPH_EFF_FAILURE_DOMAIN" \
      "$CEPH_EFF_REQUIRE_SAFE_REPLICA_SIZE" "$CEPH_EFF_MDS_ACTIVE_COUNT" \
      "$CEPH_EFF_MDS_ACTIVE_STANDBY" "$CEPH_EFF_RGW_INSTANCES"')"
chk "single profile" "${out}" "1/1/1/1/osd/false/1/false/1"

echo "== ④ 多节点默认参数 =="
out="$(run '
    CEPH_EXPLICIT_MGR=0 CEPH_EXPLICIT_REPLICAS=0 CEPH_EXPLICIT_MIN_SIZE=0
    CEPH_EXPLICIT_FAILURE_DOMAIN=0 CEPH_EXPLICIT_MDS=0 CEPH_EXPLICIT_MDS_STANDBY=0 CEPH_EXPLICIT_RGW=0
    CEPH_MON_COUNT=3 CEPH_MGR_COUNT=2 CEPH_POOL_REPLICAS=3 CEPH_POOL_MIN_SIZE=2
    ceph_apply_effective_spec multi >/dev/null 2>&1
    printf "%s/%s/%s/%s/%s/%s/%s/%s/%s\n" "$CEPH_EFF_MON_COUNT" "$CEPH_EFF_MGR_COUNT" \
      "$CEPH_EFF_POOL_REPLICAS" "$CEPH_EFF_POOL_MIN_SIZE" "$CEPH_EFF_FAILURE_DOMAIN" \
      "$CEPH_EFF_REQUIRE_SAFE_REPLICA_SIZE" "$CEPH_EFF_MDS_ACTIVE_COUNT" \
      "$CEPH_EFF_MDS_ACTIVE_STANDBY" "$CEPH_EFF_RGW_INSTANCES"')"
chk "multi profile" "${out}" "3/2/3/2/host/true/2/true/2"

echo "== ⑤ 显式覆盖 =="
chk "single size2 → require false" "$(run '
    CEPH_EXPLICIT_REPLICAS=1 CEPH_POOL_REPLICAS=2 CEPH_EXPLICIT_MIN_SIZE=1 CEPH_POOL_MIN_SIZE=1
    CEPH_EXPLICIT_MGR=0 CEPH_EXPLICIT_FAILURE_DOMAIN=0 CEPH_EXPLICIT_MDS=0 CEPH_EXPLICIT_MDS_STANDBY=0 CEPH_EXPLICIT_RGW=0
    ceph_apply_effective_spec single >/dev/null 2>&1
    printf "%s/%s\n" "$CEPH_EFF_POOL_REPLICAS" "$CEPH_EFF_REQUIRE_SAFE_REPLICA_SIZE"')" "2/false"
chk "size3 → require true" "$(run '
    CEPH_EXPLICIT_REPLICAS=1 CEPH_POOL_REPLICAS=3 CEPH_EXPLICIT_MIN_SIZE=1 CEPH_POOL_MIN_SIZE=2
    CEPH_EXPLICIT_MGR=0 CEPH_EXPLICIT_FAILURE_DOMAIN=0 CEPH_EXPLICIT_MDS=0 CEPH_EXPLICIT_MDS_STANDBY=0 CEPH_EXPLICIT_RGW=0
    ceph_apply_effective_spec multi >/dev/null 2>&1
    printf "%s/%s\n" "$CEPH_EFF_POOL_REPLICAS" "$CEPH_EFF_REQUIRE_SAFE_REPLICA_SIZE"')" "3/true"
chk "min>size 失败" "$(run '
    CEPH_EXPLICIT_REPLICAS=1 CEPH_POOL_REPLICAS=1 CEPH_EXPLICIT_MIN_SIZE=1 CEPH_POOL_MIN_SIZE=2
    CEPH_EXPLICIT_MGR=0 CEPH_EXPLICIT_FAILURE_DOMAIN=0 CEPH_EXPLICIT_MDS=0 CEPH_EXPLICIT_MDS_STANDBY=0 CEPH_EXPLICIT_RGW=0
    if ceph_apply_effective_spec single >/dev/null 2>&1; then echo ok; else echo bad; fi')" "bad"

exit "${fail}"
