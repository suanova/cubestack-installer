#!/bin/bash
# ============================================================
# test-ceph-cluster-detect.sh — 02_ceph 的 internal 集群存活判定(离线)
# 背景(2026-10-26 CodeRabbit):
#   external CephCluster(rook-ceph-external, spec.external.enable=true) 与 internal
#   rook-ceph **同命名空间并存**时, 旧逻辑"只要存在 external CR 就清空 _HAS_CC_NOW"
#   → 后续 7a 会在 internal 集群仍运行时物理清盘(磁盘数据销毁)。
# 判据:
#   ① 存活判定只认 internal 名 rook-ceph(不能把"存在 external CR"当成"没有 internal 集群");
#   ② 只有 rook-ceph 自身 spec.external.enable=true 才视为 external, 跳过销毁/幂等清理。
# 机制: 从模块**原样抽取**判定块, 用假 SSH 回放 kubectl 输出(不连集群、不碰真机)。
# 用法: bash deployments/scripts/tools/tests/test-ceph-cluster-detect.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
MOD="${MODULE_UNDER_TEST:-${REPO_ROOT}/deployments/scripts/modules/03_addon/02_ceph.sh}"
[ -f "${MOD}" ] || { echo "找不到被测模块: ${MOD}"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }

# 抽取 _HAS_CC_NOW 判定块(到块尾的 ^fi$ 为止)
sed -n '/^_HAS_CC_NOW="\$( (SSH/,/^fi$/p' "${MOD}" > "${TMP}/detect.sh"
[ -s "${TMP}/detect.sh" ] || { echo "FAIL 抽取判定块失败"; exit 1; }

cat > "${TMP}/stub.sh" <<'SH'
set -u
say() { :; }
FAKE_HAS_INTERNAL="${FAKE_HAS_INTERNAL:-1}"
FAKE_HAS_EXTERNAL="${FAKE_HAS_EXTERNAL:-1}"
FAKE_EXT="${FAKE_EXT:-false}"
SSH() {
    case "$*" in
        *custom-columns*)
            # 旧逻辑: 列出所有 CR 的 NAME/EXT
            [ "${FAKE_HAS_INTERNAL}" = "1" ] && printf 'rook-ceph   false\n'
            [ "${FAKE_HAS_EXTERNAL}" = "1" ] && printf 'rook-ceph-external   true\n'
            true ;;
        *jsonpath*external.enable*)
            # 新逻辑: 只看 rook-ceph 自身的 spec.external.enable
            [ "${FAKE_HAS_INTERNAL}" = "1" ] && printf '%s' "${FAKE_EXT}"
            true ;;
        *"get cephcluster rook-ceph --no-headers"*)
            [ "${FAKE_HAS_INTERNAL}" = "1" ] && printf 'rook-ceph   2026-10-26T00:00:00Z\n'
            true ;;
        *"get cephcluster --no-headers"*)
            [ "${FAKE_HAS_INTERNAL}" = "1" ] && printf 'rook-ceph   2026-10-26T00:00:00Z\n'
            [ "${FAKE_HAS_EXTERNAL}" = "1" ] && printf 'rook-ceph-external   2026-10-26T00:00:00Z\n'
            true ;;
        *) : ;;
    esac
}
SH
run_detect() {  # run_detect <has_internal> <has_external> <rook_ceph_ext> → 输出 _HAS_CC_NOW
    { cat "${TMP}/stub.sh"; cat "${TMP}/detect.sh"; echo 'printf "%s" "${_HAS_CC_NOW}"'; } > "${TMP}/run.sh"
    env CEPH_NAMESPACE=rook-ceph K=kubectl \
        FAKE_HAS_INTERNAL="$1" FAKE_HAS_EXTERNAL="$2" FAKE_EXT="$3" \
        bash "${TMP}/run.sh"
}
cnt() { printf '%s\n' "$1" | command grep -c . || true; }

echo "== ① internal + external 并存: internal 必须仍被视为存在 =="
out="$(run_detect 1 1 false)"
chk "并存放: _HAS_CC_NOW 非空" "1" "$(cnt "${out}")"
chk "并存放: 记录的是 rook-ceph" "1" "$(command grep -c '^rook-ceph ' <<< "${out}" || true)"

echo "== ② 只有 external(无 internal): 存活判定为空 =="
out="$(run_detect 0 1 true)"
chk "仅 external: _HAS_CC_NOW 为空" "0" "$(cnt "${out}")"

echo "== ③ rook-ceph 自身是 external: 清空存活判定(跳过销毁/幂等) =="
out="$(run_detect 1 1 true)"
chk "rook-ceph 为 external: _HAS_CC_NOW 为空" "0" "$(cnt "${out}")"

echo "---------------------------------------------"
if [ "${fail}" = "0" ]; then echo "✅ test-ceph-cluster-detect: 全部通过"; else echo "❌ test-ceph-cluster-detect: 有失败"; fi
exit "${fail}"
