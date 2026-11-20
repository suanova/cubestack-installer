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

exit "${fail}"
