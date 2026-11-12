#!/bin/bash
# ============================================================
# test-devlab-tar-name.sh — dev_lab tar 选择回归(离线)
# 背景: release 树用中性名 <img>.tar; 开发树仍可能是 <img>-<tag>.tar。
#   运行时 tag 由 release 覆盖成 <axes>-v<release>, 不能再拿来查 tar。
# 机制: 从模块原样抽取 _devlab_find_tar, 直接断言选择结果。
# 用法: bash deployments/scripts/tools/tests/test-devlab-tar-name.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
MOD="${MODULE_UNDER_TEST:-${REPO_ROOT}/deployments/scripts/modules/03_addon/36_dev_lab.sh}"
[ -f "${MOD}" ] || { echo "找不到被测模块: ${MOD}"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }

sed -n '/^_devlab_find_tar() {/,/^}/p' "${MOD}" > "${TMP}/fn.sh"
[ -s "${TMP}/fn.sh" ] || { echo "FAIL 抽取 _devlab_find_tar 失败"; exit 1; }

run_sel() {  # <dir> <img> <tag>
    bash -c 'source "$1"
             find_offline_tar() { local d="$3"; [ -f "${d}/legacy.tar" ] && printf "%s\n" "${d}/legacy.tar"; }
             _devlab_find_tar "$3" "$4" "$2"' \
        _ "${TMP}/fn.sh" "$1" "$2" "$3"
}

TAG=py310-torch2.4-v2.1.0
echo "== ① 中性名优先 =="
mkdir -p "${TMP}/s1"
: > "${TMP}/s1/cpu-pytorch.tar"
out="$(run_sel "${TMP}/s1" cpu-pytorch "${TAG}")"
chk "选中中性 tar" "cpu-pytorch.tar" "$(basename "${out}")"

echo "== ② 中性名不存在时回退 <img>-<tag>.tar =="
mkdir -p "${TMP}/s2"
: > "${TMP}/s2/cpu-pytorch-${TAG}.tar"
out="$(run_sel "${TMP}/s2" cpu-pytorch "${TAG}")"
chk "选中带 tag tar" "cpu-pytorch-${TAG}.tar" "$(basename "${out}")"

echo "== ③ 都没有时交给 find_offline_tar =="
mkdir -p "${TMP}/s3"
: > "${TMP}/s3/legacy.tar"
out="$(run_sel "${TMP}/s3" cpu-pytorch "${TAG}")"
chk "legacy 兜底" "legacy.tar" "$(basename "${out}")"

echo "== ④ 空目录返回空 =="
mkdir -p "${TMP}/s4"
out="$(run_sel "${TMP}/s4" cpu-pytorch "${TAG}")"
chk "无 tar" "" "${out}"

echo "---------------------------------------------"
if [ "${fail}" = "0" ]; then echo "✅ test-devlab-tar-name: 全部通过"; else echo "❌ test-devlab-tar-name: 有失败"; fi
exit "${fail}"
