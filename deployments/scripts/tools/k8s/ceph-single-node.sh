#!/bin/bash
# ============================================================
# ceph-single-node.sh — 单节点 Rook-Ceph 独立部署入口(CEPH_MODE=internal + 拓扑 single)
#
# 定位(2026-11-20):
#   · 由 02_ceph.sh 在 CEPH_MODE=internal 且存储节点恰好 1 台时自动 exec;
#   · 也可单独执行: sudo bash deployments/scripts/tools/k8s/ceph-single-node.sh;
#   · **复用同一套 Rook 部署引擎**(02_ceph.sh 的 ceph_engine_main), 单/多节点差异
#     只体现在 profile 参数(mon/mgr/副本/最小副本/故障域), 不存在两份会漂移的部署逻辑。
#
# 单节点 profile(可用 cluster.conf 显式覆盖, 见 ceph_apply_effective_spec):
#   mon=1, mgr=1, pool size=1, min_size=1, failureDomain=osd,
#   CephFS activeCount=1/无热备, RGW instances=1(后三项由 ceph_csi 按拓扑渲染)。
# 单节点是降级拓扑: 无跨主机冗余; size>1 仅在本机多盘且 failureDomain=osd 时有意义。
#
# 数据源: cluster.conf CEPH_MODE / CEPH_TOPOLOGY / CEPH_* / NODES / SSH_*
# 卸载:   CUBESTACK_MODULE_ACTION=uninstall(与多节点共用 live-state 安全序)
# ============================================================
set -euo pipefail

# ⚠ 先捕获本脚本目录: lib-common.sh 会把 SCRIPT_DIR 重写成 deployments/scripts,
#   之后再拼 ../../modules 会指向错误位置。
SINGLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib-common.sh
source "${SINGLE_DIR}/../../lib-common.sh"

# 引擎只定义函数, 不执行模块入口逻辑(卸载/门禁/分发)。
# ⚠ 不要在此先 load_config: 02_ceph.sh 会调用一次; 重复调用会让 defaults 已填充的
#   CEPH_MON_COUNT/CEPH_POOL_REPLICAS 被误判为"用户显式覆盖"(CEPH_EXPLICIT_*=1),
#   单节点 profile 就不会生效。
export CUBESTACK_CEPH_ENGINE_ONLY=1
# shellcheck source=../../modules/03_addon/02_ceph.sh
source "${SINGLE_DIR}/../../modules/03_addon/02_ceph.sh"

# ---- 卸载: 与多节点共用 live-state 安全序 ----
if [ "${CUBESTACK_MODULE_ACTION:-install}" = "uninstall" ]; then
    ceph_engine_uninstall
    exit $?
fi

# ---- 模式门禁 ----
case "${CEPH_MODE:-none}" in
    none)      say "CEPH_MODE=none, 跳过单节点 Ceph"; exit 0 ;;
    external)  say "CEPH_MODE=external → 不创建集群内 CephCluster(本脚本只负责单节点 internal)"; exit 0 ;;
    internal)  : ;;
    *)         err "CEPH_MODE 非法: '${CEPH_MODE}'"; exit 1 ;;
esac

# ---- 拓扑校验: 恰好 1 台存储节点 ----
case "$(ceph_norm_lower "${CEPH_TOPOLOGY:-auto}")" in
    auto|single) : ;;
    multi) err "CEPH_TOPOLOGY=multi 但当前只有 1 台存储节点; 请调整 CEPH_NODES 或改回 auto/single"; exit 1 ;;
    *)     err "CEPH_TOPOLOGY 非法: '${CEPH_TOPOLOGY}'"; exit 1 ;;
esac
CEPH_NODE_HOSTS=()
while IFS= read -r _h; do
    [ -n "${_h}" ] && CEPH_NODE_HOSTS+=("${_h}")
done < <(ceph_storage_hosts)
unset _h
if [ "${#CEPH_NODE_HOSTS[@]}" -ne 1 ]; then
    err "单节点 Ceph 要求存储节点恰好 1 台(当前 ${#CEPH_NODE_HOSTS[@]} 台)"
    err "  可选: ① CEPH_NODES 只保留 1 台; ② CEPH_TOPOLOGY=multi(>=3 台)走多节点; ③ CEPH_MODE=external"
    exit 1
fi

# ---- 单节点 profile(尊重显式覆盖; 校验 size <= 本机磁盘数由引擎在选盘后执行) ----
ceph_apply_effective_spec single || exit 1
if [ "${CEPH_EXPLICIT_MON:-0}" = "1" ] && [ "${CEPH_MON_COUNT:-1}" != "1" ]; then
    warn "单节点拓扑固定 mon=1(已忽略 CEPH_MON_COUNT=${CEPH_MON_COUNT})"
fi
export CEPH_MIN_NODES=1
export CEPH_MON_COUNT="${CEPH_EFF_MON_COUNT}"
export CEPH_MGR_COUNT="${CEPH_EFF_MGR_COUNT}"
export CEPH_POOL_REPLICAS="${CEPH_EFF_POOL_REPLICAS}"
export CEPH_POOL_MIN_SIZE="${CEPH_EFF_POOL_MIN_SIZE}"

say "单节点 Ceph profile: 存储节点=${CEPH_NODE_HOSTS[0]} mon=${CEPH_MON_COUNT} mgr=${CEPH_MGR_COUNT}"
say "  副本 size=${CEPH_POOL_REPLICAS} min_size=${CEPH_POOL_MIN_SIZE} 故障域=${CEPH_EFF_FAILURE_DOMAIN}"
say "  (单节点为降级拓扑: 无跨主机冗余; CephFS/RGW 数量由 ceph_csi 按拓扑渲染)"

# ---- 复用多节点引擎执行完整部署 ----
ceph_engine_main
