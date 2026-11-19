#!/bin/bash
# ============================================================
# test-ceph-csi-cluster-kind.sh — ceph_csi 拓扑判定回归(issue #194)
# 背景: external Ceph 接入后集群里有 CephCluster rook-ceph-external(无 rook-ceph)。
#   旧逻辑用 `get cephcluster --no-headers` 判"是否有内部集群", 任何 CR 都算命中 →
#   重跑时进入内部等待分支, 却固定查询不存在的 rook-ceph, 600s 后失败。
# 判据:
#   ① 只有 internal 名 rook-ceph 才算内部集群;
#   ② rook-ceph 自身 spec.external.enable=true → external;
#   ③ 无 rook-ceph + CEPH_MODE=external → external(重试幂等; external CR 不算内部);
#   ④ 无 rook-ceph + CEPH_MODE!=external → none;
#   ⑤ name+external 列表查询失败 → 返回 2(不误判 internal/external)。
# 机制: 从模块**原样抽取** _ceph_cluster_kind, 用假 SSH 回放 kubectl 输出(不连集群)。
# 用法: bash deployments/scripts/tools/tests/test-ceph-csi-cluster-kind.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
MOD="${MODULE_UNDER_TEST:-${REPO_ROOT}/deployments/scripts/modules/03_addon/03_ceph_csi.sh}"
[ -f "${MOD}" ] || { echo "找不到被测模块: ${MOD}"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }

sed -n '/^_ceph_cluster_kind() {/,/^}$/p' "${MOD}" > "${TMP}/detect.sh"
[ -s "${TMP}/detect.sh" ] || { echo "FAIL 抽取 _ceph_cluster_kind 失败"; exit 1; }

cat > "${TMP}/stub.sh" <<'SH'
set -u
CEPH_NAMESPACE=rook-ceph
K=kubectl
err() { echo "ERR $*" >&2; }
sleep() { :; }
SSH() {
    case "$*" in
        *custom-columns*)
            [ "${FAKE_LIST_FAIL:-0}" = "1" ] && return 1
            if [ "${FAKE_INTERNAL}" = "1" ]; then
                if [ "${FAKE_EXT}" = "true" ]; then
                    printf 'rook-ceph   true\n'
                else
                    printf 'rook-ceph   <none>\n'
                fi
            fi
            [ "${FAKE_EXTERNAL_CR:-0}" = "1" ] && printf 'rook-ceph-external   true\n'
            true ;;
        *) true ;;
    esac
}
SH

run_kind() {  # run_kind <internal 0|1> <rook_ceph_ext false|true> <ceph_mode> [list_query_fail 0|1]
    { cat "${TMP}/stub.sh"; cat "${TMP}/detect.sh"; echo '_ceph_cluster_kind'; } > "${TMP}/run.sh"
    env FAKE_INTERNAL="$1" FAKE_EXT="$2" CEPH_MODE="$3" FAKE_LIST_FAIL="${4:-0}" \
        FAKE_EXTERNAL_CR="${5:-0}" bash "${TMP}/run.sh"
}

echo "== ① internal rook-ceph → internal =="
chk "internal CR 视为集群内" "internal" "$(run_kind 1 false internal)"
chk "CEPH_MODE=external 但 internal CR 在 → 仍 internal(内部优先)" "internal" "$(run_kind 1 false external)"

echo "== ② rook-ceph 自身 external.enable=true → external =="
chk "external CR 复用内部名 → external" "external" "$(run_kind 1 true internal)"

echo "== ③ 无 rook-ceph + CEPH_MODE=external → external(重试幂等) =="
chk "只剩 rook-ceph-external 时不进内部等待" "external" "$(run_kind 0 false external 0 1)"
chk "完全没有 CephCluster 时按配置走 external" "external" "$(run_kind 0 false external)"

echo "== ④ 无 rook-ceph + CEPH_MODE!=external → none =="
chk "internal 模式无集群 → none(报错分支)" "none" "$(run_kind 0 false internal)"

echo "== ⑤ 分类查询失败: 不误判, 显式失败 =="
out="$(run_kind 1 false internal 1 2>/dev/null)"; rc=$?
chk "退出码 2(查询失败)" "2" "${rc}"
chk "不输出 internal/external(否则会走错分支)" "" "${out}"

echo ""
if [ "${fail}" = "0" ]; then
    echo "✅ test-ceph-csi-cluster-kind: 全部通过"
else
    echo "❌ test-ceph-csi-cluster-kind: 存在失败项"
fi
exit "${fail}"
