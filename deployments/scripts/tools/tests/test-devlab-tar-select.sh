#!/bin/bash
# ============================================================
# test-devlab-tar-select.sh — dev_lab 旧后缀 tar 选择回归(离线)
# 背景(2026-10-26 CodeRabbit):
#   旧实现找不到精确 tag 的 tar 时, 按 "<tag>-" 任意前缀匹配 ——
#   `cpu-pytorch:py310-torch2.4-v2.0.0-rc2-hotfix` 会被当成 `py310-torch2.4`
#   推送, 静默绕过发布 tag 钉版。
# 判据:
#   ① 只接受定义过的旧后缀(默认 -${CUBESTACK_OPERATOR_IMAGE_TAG}, 或
#      DEV_LAB_LEGACY_TAG_SUFFIXES 显式列表);
#   ② *-hotfix 之类未定义后缀 → none;
#   ③ 多个文件命中同一旧后缀 → ambig(不猜);
#   ④ 没有任何后缀定义 → none。
# 机制: 从模块**原样抽取** _devlab_find_legacy_tar, 用文件名旁的 .tag 桩回放 RepoTag。
# 用法: bash deployments/scripts/tools/tests/test-devlab-tar-select.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
MOD="${MODULE_UNDER_TEST:-${REPO_ROOT}/deployments/scripts/modules/03_addon/36_dev_lab.sh}"
[ -f "${MOD}" ] || { echo "找不到被测模块: ${MOD}"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }

sed -n '/^_devlab_find_legacy_tar() {/,/^}/p' "${MOD}" > "${TMP}/fn.sh"
[ -s "${TMP}/fn.sh" ] || { echo "FAIL 抽取 _devlab_find_legacy_tar 失败"; exit 1; }

IMG=cpu-pytorch
TAG=py310-torch2.4
mk_tar() {  # <dir> <文件名> <RepoTag>
    : > "$1/$2"
    printf '%s\n' "$3" > "$1/$2.tag"
}
run_sel() {  # <dir> [env 赋值…] → 三态输出
    local dir="$1"; shift
    env -u DEV_LAB_LEGACY_TAG_SUFFIXES -u CUBESTACK_OPERATOR_IMAGE_TAG "$@" \
        bash -c 'source "$1"
                 tar_first_image_tag() { command cat "${1}.tag" 2>/dev/null || true; }
                 _devlab_find_legacy_tar "$2" "$3" "$4"' \
        _ "${TMP}/fn.sh" "${IMG}" "${TAG}" "${dir}"
}
status_of() { printf '%s' "${1%%$'\t'*}"; }

echo "== ① 默认后缀 = -<operator image tag>, 唯一命中 =="
mkdir -p "${TMP}/s1"
mk_tar "${TMP}/s1" a.tar "harbor.isuanova.com/suanova/cpu-pytorch:py310-torch2.4-v2.0.0-rc2"
out="$(run_sel "${TMP}/s1" CUBESTACK_OPERATOR_IMAGE_TAG=v2.0.0-rc2)"
chk "状态 ok" "ok" "$(status_of "${out}")"
chk "命中 a.tar" "a.tar" "$(basename "${out#*$'\t'}")"

echo "== ② 未定义后缀(-hotfix)不得冒充 =="
mkdir -p "${TMP}/s2"
mk_tar "${TMP}/s2" b.tar "harbor.isuanova.com/suanova/cpu-pytorch:py310-torch2.4-v2.0.0-rc2-hotfix"
out="$(run_sel "${TMP}/s2" CUBESTACK_OPERATOR_IMAGE_TAG=v2.0.0-rc2)"
chk "*-hotfix → none" "none" "$(status_of "${out}")"

echo "== ③ 显式后缀列表覆盖默认 =="
mkdir -p "${TMP}/s3"
mk_tar "${TMP}/s3" c.tar "harbor.isuanova.com/suanova/cpu-pytorch:py310-torch2.4-v9.9.9"
out="$(run_sel "${TMP}/s3" DEV_LAB_LEGACY_TAG_SUFFIXES=-v9.9.9 CUBESTACK_OPERATOR_IMAGE_TAG=v2.0.0-rc2)"
chk "显式后缀命中" "ok" "$(status_of "${out}")"
# 显式列表存在时, operator tag 派生的后缀不再生效
mkdir -p "${TMP}/s3b"
mk_tar "${TMP}/s3b" d.tar "harbor.isuanova.com/suanova/cpu-pytorch:py310-torch2.4-v2.0.0-rc2"
out="$(run_sel "${TMP}/s3b" DEV_LAB_LEGACY_TAG_SUFFIXES=-v9.9.9 CUBESTACK_OPERATOR_IMAGE_TAG=v2.0.0-rc2)"
chk "不在显式列表 → none" "none" "$(status_of "${out}")"
# 多后缀列表: 任一命中即可
mkdir -p "${TMP}/s3c"
mk_tar "${TMP}/s3c" e.tar "harbor.isuanova.com/suanova/cpu-pytorch:py310-torch2.4-v2.0.0-rc2"
out="$(run_sel "${TMP}/s3c" DEV_LAB_LEGACY_TAG_SUFFIXES=-v9.9.9,-v2.0.0-rc2)"
chk "多后缀列表命中" "ok" "$(status_of "${out}")"

echo "== ④ 多个文件命中同一旧后缀 → ambig(不猜) =="
mkdir -p "${TMP}/s4"
mk_tar "${TMP}/s4" f1.tar "harbor.isuanova.com/suanova/cpu-pytorch:py310-torch2.4-v2.0.0-rc2"
mk_tar "${TMP}/s4" f2.tar "other.registry/suanova/cpu-pytorch:py310-torch2.4-v2.0.0-rc2"
out="$(run_sel "${TMP}/s4" CUBESTACK_OPERATOR_IMAGE_TAG=v2.0.0-rc2)"
chk "状态 ambig" "ambig" "$(status_of "${out}")"
chk "列出两个文件" "2" "$(printf '%s' "${out#*$'\t'}" | tr ' ' '\n' | command grep -c . || true)"

echo "== ⑤ 没有任何后缀定义 → none =="
mkdir -p "${TMP}/s5"
mk_tar "${TMP}/s5" g.tar "harbor.isuanova.com/suanova/cpu-pytorch:py310-torch2.4-v2.0.0-rc2"
out="$(run_sel "${TMP}/s5")"
chk "无定义 → none" "none" "$(status_of "${out}")"

echo "== ⑥ 精确 tag(无后缀)不由本函数处理 =="
mkdir -p "${TMP}/s6"
mk_tar "${TMP}/s6" h.tar "harbor.isuanova.com/suanova/cpu-pytorch:py310-torch2.4"
out="$(run_sel "${TMP}/s6" CUBESTACK_OPERATOR_IMAGE_TAG=v2.0.0-rc2)"
chk "精确 tag → none(交给 find_offline_tar)" "none" "$(status_of "${out}")"

echo "---------------------------------------------"
if [ "${fail}" = "0" ]; then echo "✅ test-devlab-tar-select: 全部通过"; else echo "❌ test-devlab-tar-select: 有失败"; fi
exit "${fail}"
