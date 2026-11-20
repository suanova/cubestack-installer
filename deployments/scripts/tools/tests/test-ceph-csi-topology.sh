#!/bin/bash
# ============================================================
# test-ceph-csi-topology.sh — CSI 供给层按拓扑渲染
#
# 覆盖:
#   ① 单节点: rbd-pool failureDomain=osd / requireSafeReplicaSize=false
#   ② 单节点: CephFilesystem activeCount=1 / activeStandby=false / size=1
#   ③ 单节点: CephObjectStore instances=1 / failureDomain=osd
#   ④ 多节点: host / true / activeCount=2 / activeStandby=true / instances=2
#   ⑤ SC 名称与默认标记不变(ceph-rbd-ephemeral 默认)
#   ⑥ 渲染结果无未替换占位符
#
# 用法: bash deployments/scripts/tools/tests/test-ceph-csi-topology.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CSI_MOD="${REPO_ROOT}/deployments/scripts/modules/03_addon/03_ceph_csi.sh"
ROOK_DIR="${REPO_ROOT}/deployments/cubestack-addon/rook"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk_contains() { if [[ "$3" == *"$2"* ]]; then echo "  ok  $1"; else echo "  FAIL $1: 未包含 [$2]"; fail=1; fi; }
chk_not_contains() { if [[ "$3" != *"$2"* ]]; then echo "  ok  $1"; else echo "  FAIL $1: 不应包含 [$2]"; fail=1; fi; }

sed -n '/^_ceph_yaml_file() {/,/^}$/p' "${CSI_MOD}" > "${TMP}/yaml.sh"
[ -s "${TMP}/yaml.sh" ] || { echo "  FAIL 无法抽取 _ceph_yaml_file"; exit 1; }

render() {  # render <replicas> <min> <fd> <safe> <mds> <std> <rgw> <files...>
    local r="$1" m="$2" fd="$3" safe="$4" mds="$5" std="$6" rgw="$7"; shift 7
    ( set +u
      err() { echo "ERR $*" >&2; }
      CEPH_ROOK_MANIFEST_DIR="${ROOK_DIR}" CEPH_NAMESPACE=rook-ceph
      CEPH_POOL_REPLICAS="${r}" CEPH_POOL_MIN_SIZE="${m}"
      CEPH_EFF_FAILURE_DOMAIN="${fd}" CEPH_EFF_REQUIRE_SAFE_REPLICA_SIZE="${safe}"
      CEPH_EFF_MDS_ACTIVE_COUNT="${mds}" CEPH_EFF_MDS_ACTIVE_STANDBY="${std}"
      CEPH_EFF_RGW_INSTANCES="${rgw}"
      _CEPH_SL_KEY=ceph-storage _CEPH_SL_VAL=rook-ceph
      . "${TMP}/yaml.sh"
      _ceph_yaml_file "$@" )
}

echo "== ① 单节点 RBD pool =="
out="$(render 1 1 osd false 1 false 1 rbd/01-cephblockpool-rbd-pool.yaml)"
chk_contains "failureDomain osd" "failureDomain: osd" "${out}"
chk_contains "requireSafe false" "requireSafeReplicaSize: false" "${out}"
chk_contains "size 1" "size: 1" "${out}"

echo "== ② 单节点 CephFS =="
out="$(render 1 1 osd false 1 false 1 cephfs/01-cephfilesystem.yaml)"
chk_contains "activeCount 1" "activeCount: 1" "${out}"
chk_contains "activeStandby false" "activeStandby: false" "${out}"
chk_contains "failureDomain osd" "failureDomain: osd" "${out}"

echo "== ③ 单节点 RGW =="
out="$(render 1 1 osd false 1 false 1 rgw/01-cephobjectstore-s3-store.yaml)"
chk_contains "instances 1" "instances: 1" "${out}"
chk_contains "failureDomain osd" "failureDomain: osd" "${out}"

echo "== ④ 多节点保持原参数 =="
out="$(render 3 2 host true 2 true 2 rbd/01-cephblockpool-rbd-pool.yaml cephfs/01-cephfilesystem.yaml rgw/01-cephobjectstore-s3-store.yaml)"
chk_contains "failureDomain host" "failureDomain: host" "${out}"
chk_contains "requireSafe true" "requireSafeReplicaSize: true" "${out}"
chk_contains "activeCount 2" "activeCount: 2" "${out}"
chk_contains "activeStandby true" "activeStandby: true" "${out}"
chk_contains "instances 2" "instances: 2" "${out}"

echo "== ⑤ SC 名称/默认标记不变 =="
sc="$(cat "${ROOK_DIR}/rbd/02-storageclass-rbd.yaml" "${ROOK_DIR}/rbd/03-storageclass-ceph-block-alias.yaml")"
chk_contains "ceph-rbd-ephemeral" "name: ceph-rbd-ephemeral" "${sc}"
chk_contains "默认 SC 标记" "storageclass.kubernetes.io/is-default-class" "${sc}"
chk_contains "ceph-block" "name: ceph-block" "${sc}"

echo "== ⑥ 无未替换占位符 =="
chk_not_contains "无双下划线占位" "__REPLICAS__" "${out}"
chk_not_contains "无故障域占位" "__FAILURE_DOMAIN__" "${out}"
chk_not_contains "无 MDS 占位" "__MDS_ACTIVE_COUNT__" "${out}"
chk_not_contains "无 RGW 占位" "__RGW_INSTANCES__" "${out}"

echo "== ⑦ 单节点外部池使用 osd 故障域 CRUSH 规则 =="
EXPOSE="${REPO_ROOT}/deployments/scripts/tools/k8s/ceph-expose-external.sh"
chk_contains "按 EFF 故障域选择规则" 'CEPH_EFF_FAILURE_DOMAIN:-host}" = "osd"' "$(cat "${EXPOSE}")"
chk_contains "创建 osd 规则" 'osd crush rule create-replicated "${_ext_rule}" default osd' "$(cat "${EXPOSE}")"
chk_contains "RBD 池创建带规则" 'osd pool create "${EXT_RBD_POOL}" "${EXT_RBD_PG}" replicated "${_ext_rule}"' "$(cat "${EXPOSE}")"
chk_contains "已有 FS 池纠正规则" 'osd pool set "${_fp_pool}" crush_rule "${_ext_rule}"' "$(cat "${EXPOSE}")"

echo "== ⑧ 单节点默认池(.mgr)使用 osd 故障域规则 =="
CEPH_MOD="${REPO_ROOT}/deployments/scripts/modules/03_addon/02_ceph.sh"
chk_contains "按 EFF 故障域触发" 'CEPH_EFF_FAILURE_DOMAIN:-host}" = "osd"' "$(cat "${CEPH_MOD}")"
chk_contains "创建 cubestack-osd 规则" 'ceph osd crush rule create-replicated cubestack-osd default osd' "$(cat "${CEPH_MOD}")"
chk_contains "设置默认 CRUSH 规则" 'osd_pool_default_crush_rule' "$(cat "${CEPH_MOD}")"
chk_contains ".mgr 池纠正(按规则名)" 'ceph osd pool set .mgr crush_rule cubestack-osd' "$(cat "${CEPH_MOD}")"

echo "== ⑨ verify_ceph 覆盖实际 SC 名与 host-network RGW =="
VERIFY="${REPO_ROOT}/deployments/scripts/modules/03_addon/27_verify_ceph.sh"
chk_contains "CephFS SC 回退列表" 'for _fsc in cephfs-ephemeral cephfs-durable cephfs' "$(cat "${VERIFY}")"
chk_contains "PVC 使用选中的 SC" 'storageClassName: ${SC_FS}' "$(cat "${VERIFY}")"
chk_contains "host-network RGW 端点" 'RGW host-network 端点' "$(cat "${VERIFY}")"

echo "== ⑩ 单节点 PG 上限(多池小集群 HEALTH_WARN 防回归) =="
chk_contains "单节点 PG 上限函数" 'mon_max_pg_per_osd' "$(cat "${CEPH_MOD}")"
chk_contains "可配置上限" 'CEPH_SINGLE_MAX_PG_PER_OSD' "$(cat "${CEPH_MOD}")"
chk_contains "默认值声明" 'CEPH_SINGLE_MAX_PG_PER_OSD="${CEPH_SINGLE_MAX_PG_PER_OSD:-500}"' \
    "$(cat "${REPO_ROOT}/deployments/config/cluster.defaults.conf")"

echo "== ⑪ mon_list 解析 Rook v1.21 无前缀 CM(a=IP) =="
sed -n '/^mon_list() {/,/^}$/p' "${EXPOSE}" > "${TMP}/mon_list.sh"
out="$( ( set +u
    SSH() { printf 'a=10.66.3.165:6789\n'; }
    K=kubectl CEPH_NAMESPACE=rook-ceph
    . "${TMP}/mon_list.sh"
    mon_list | tr -d ' '
) )"
chk_contains "单节点解析为 a" "a" "${out}"
chk_not_contains "不误回退 a b c" "b" "${out}"
chk_contains "status host-network 直连判定" 'host-network 直连' "$(cat "${EXPOSE}")"

echo "== ⑫ 磁盘探测 stdout 纯净(防预检误回退) =="
DETECT="${REPO_ROOT}/deployments/scripts/tools/k8s/ceph-detect-disks.sh"
chk_contains "load_config 输出走 stderr" '{ load_config; } >&2' "$(cat "${DETECT}")"
chk_contains "预检只解析本节点机器行" 'grep -E "^${_hn}:"' "$(cat "${REPO_ROOT}/deployments/scripts/lib-common.sh")"

exit "${fail}"
