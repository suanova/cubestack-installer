#!/bin/bash
# ============================================================
# test-devlab-tar-select.sh — dev_lab 精确 tag tar 选择回归(离线)
# 背景(2026-10-30):
#   release.env 的 DEV_LAB_*_TAG 已是**完整不可变 tag**(如
#   `3.9.0.12-py310-torch2.4-v2.0.0`), 发布树 tar 内 RepoTag 与之一一对应。
#   模块删除旧的"后缀兼容/前缀猜测", 只做精确匹配。
# 判据:
#   ① 精确 tag 的 tar 命中;
#   ② 只有非精确后缀(-old/-hotfix)tar 时 → 不命中(绝不猜);
#   ③ 请求基础 tag(无 release 后缀)而只有带后缀 tar → 不命中;
#   ④ .tar.gz 文件名精确后缀命中(大件压缩存储)。
# 机制: 从 lib-common **原样抽取** find_offline_tar, 用文件名旁的 .tag 桩回放 RepoTag。
# 用法: bash deployments/scripts/tools/tests/test-devlab-tar-select.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIB="${REPO_ROOT}/deployments/scripts/lib-common.sh"
MOD="${MODULE_UNDER_TEST:-${REPO_ROOT}/deployments/scripts/modules/03_addon/36_dev_lab.sh}"
[ -f "${LIB}" ] || { echo "找不到 ${LIB}"; exit 1; }
[ -f "${MOD}" ] || { echo "找不到被测模块: ${MOD}"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }

{
    sed -n '/^tar_first_image_tag() {/,/^}/p' "${LIB}"
    sed -n '/^find_offline_tar() {/,/^}/p' "${LIB}"
} > "${TMP}/fn.sh"
command grep -q '^find_offline_tar() {' "${TMP}/fn.sh" \
    && command grep -q '^tar_first_image_tag() {' "${TMP}/fn.sh" \
    || { echo "FAIL 从 lib-common 抽取函数失败"; exit 1; }

IMG=cpu-pytorch
TAG=py310-torch2.4-v2.0.0
mk_tar() {  # <dir> <文件名> <RepoTag>
    : > "$1/$2"
    printf '%s\n' "$3" > "$1/$2.tag"
}
run_find() {  # <dir> <ref> → stdout 命中路径; rc=0 命中 / 1 未命中
    local dir="$1" ref="$2"
    bash -c 'source "$1"
             warn() { :; }
             tar_first_image_tag() { command cat "${1}.tag" 2>/dev/null || true; }
             find_offline_tar "$2" "*.tar" "$3"' \
        _ "${TMP}/fn.sh" "${ref}" "${dir}"
}

echo "== ① 精确 tag 命中 =="
mkdir -p "${TMP}/s1"
mk_tar "${TMP}/s1" exact.tar "harbor.isuanova.com/suanova/${IMG}:${TAG}"
out="$(run_find "${TMP}/s1" "${IMG}:${TAG}")"; rc=$?
chk "退出码" "0" "${rc}"
chk "命中 exact.tar" "exact.tar" "$(basename "${out:-}")"

echo "== ② 非精确后缀(-old / -hotfix)不得冒充 =="
mkdir -p "${TMP}/s2"
mk_tar "${TMP}/s2" old.tar "harbor.isuanova.com/suanova/${IMG}:${TAG}-old"
mk_tar "${TMP}/s2" hotfix.tar "harbor.isuanova.com/suanova/${IMG}:${TAG}-hotfix"
run_find "${TMP}/s2" "${IMG}:${TAG}" >/dev/null; rc=$?
chk "非精确后缀 → 未命中" "1" "${rc}"

echo "== ③ 基础 tag 不匹配带 release 后缀的 tar =="
mkdir -p "${TMP}/s3"
mk_tar "${TMP}/s3" rel.tar "harbor.isuanova.com/suanova/${IMG}:${TAG}"
run_find "${TMP}/s3" "${IMG}:py310-torch2.4" >/dev/null; rc=$?
chk "基础 tag → 未命中" "1" "${rc}"

echo "== ④ .tar.gz 文件名精确后缀命中 =="
mkdir -p "${TMP}/s4"
: > "${TMP}/s4/harbor.isuanova.com_suanova_${IMG}_${TAG}.tar.gz"
out="$(run_find "${TMP}/s4" "${IMG}:${TAG}")"; rc=$?
chk "退出码" "0" "${rc}"
chk "命中 .tar.gz" "harbor.isuanova.com_suanova_${IMG}_${TAG}.tar.gz" "$(basename "${out:-}")"

echo "== ⑤ 模块不再保留旧后缀兼容代码 =="
if command grep -qE '_devlab_find_legacy_tar|DEV_LAB_LEGACY_TAG_SUFFIXES' "${MOD}"; then
    echo "  FAIL 模块仍含旧后缀兼容逻辑"; fail=1
else
    echo "  ok 模块仅精确匹配"
fi

echo "---------------------------------------------"
if [ "${fail}" = "0" ]; then echo "✅ test-devlab-tar-select: 全部通过"; else echo "❌ test-devlab-tar-select: 有失败"; fi
exit "${fail}"
