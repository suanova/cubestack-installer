#!/bin/bash
# ============================================================
# test-ceph-data-disks.sh — 显式 CEPH_DATA_DISKS/CEPH_NODES 校验回归(离线)
# 背景(2026-10-26 实机): CEPH_DATA_DISKS 节点之间误用逗号:
#   node0:/dev/vdb,node1:/dev/vdb,node2:/dev/vdb
# 解析器把后两个 "nodeN:/dev/vdb" 当成 node0 的盘, 确认屏显示三块盘全在第一个节点,
# 另外两台 <未检测到>。本夹具钉住: 这种写法必须在解析前明确失败;
# 合法写法(分号/全局单盘)通过。
# 用法: bash deployments/scripts/tools/tests/test-ceph-data-disks.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIB="${REPO_ROOT}/deployments/scripts/lib-common.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if [[ "$3" == *"$2"* ]]; then echo "  ok  $1"; else echo "  FAIL $1: 未包含 [$2]"; fail=1; fi; }

make_conf() {  # <file> <ceph_nodes> <data_disks>
    local f="$1" nodes="$2" disks="$3"
    cat > "$f" <<EOF
NODES=(
  "master,node0,10.0.0.1,root,-"
  "master,node1,10.0.0.2,root,-"
  "master,node2,10.0.0.3,root,-"
)
SSH_USER="root"
KUBESPRAY_PROFILE="none"
CEPH_ENABLED="true"
CEPH_CSI_ENABLED="true"
CEPH_MODE="internal"
CEPH_NODES="${nodes}"
CEPH_DATA_DISK_POLICY="explicit"
CEPH_DATA_DISKS="${disks}"
EOF
}

run_validate() {  # <conf> → stdout+stderr; rc
    CLUSTER_CONF="$1" bash -c 'source "$1"; load_config; ceph_validate_explicit_config' _ "${LIB}" 2>&1
}

echo "== ① 合法: 分号分隔节点 =="
c="${TMP}/ok.conf"; make_conf "$c" "node0,node1,node2" "node0:/dev/vdb;node1:/dev/vdb;node2:/dev/vdb"
out="$(run_validate "$c")"; rc=$?
chk "分号写法退出码" "0" "${rc}"

echo "== ② 合法: 全节点同盘(无 hostname) =="
c="${TMP}/global.conf"; make_conf "$c" "node0,node1,node2" "/dev/vdb"
out="$(run_validate "$c")"; rc=$?
chk "全局单盘退出码" "0" "${rc}"

echo "== ③ 非法: 节点之间用逗号(本次实机) =="
c="${TMP}/bad.conf"; make_conf "$c" "node0,node1,node2" "node0:/dev/vdb,node1:/dev/vdb,node2:/dev/vdb"
out="$(run_validate "$c")"; rc=$?
chk "逗号写法退出码非 0" "1" "${rc}"
chk_contains "明确提示分号" "分号" "${out}"
chk_contains "给出问题项" "node0:/dev/vdb,node1:/dev/vdb" "${out}"

echo "== ④ 非法: 未知节点名 =="
c="${TMP}/unknown.conf"; make_conf "$c" "node0,node1,node2" "foo:/dev/vdb;node1:/dev/vdb"
out="$(run_validate "$c")"; rc=$?
chk "未知节点退出码非 0" "1" "${rc}"
chk_contains "提示未知节点" "未知节点" "${out}"

echo "== ⑤ 非法: CEPH_NODES 带角色前缀 =="
c="${TMP}/roles.conf"; make_conf "$c" "master,node0,master,node1" "node0:/dev/vdb;node1:/dev/vdb"
out="$(run_validate "$c")"; rc=$?
chk "CEPH_NODES 角色前缀退出码非 0" "1" "${rc}"
chk_contains "提示 CEPH_NODES 未知节点" "CEPH_NODES" "${out}"

echo "== ⑥ 合法: CEPH_NODES 裸 hostname =="
c="${TMP}/nodes-ok.conf"; make_conf "$c" "node0,node1,node2" "/dev/vdb"
out="$(run_validate "$c")"; rc=$?
chk "裸 hostname 退出码" "0" "${rc}"

echo "---------------------------------------------"
if [ "${fail}" = "0" ]; then echo "✅ test-ceph-data-disks: 全部通过"; else echo "❌ test-ceph-data-disks: 有失败"; fi
exit "${fail}"
