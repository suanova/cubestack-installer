#!/bin/bash
# ============================================================
# test-netshoot-tar-select.sh — netshoot tar 选择回归(离线)
# 背景: release 树用中性名 netshoot-rdma.tar; 开发树可能仍是
#   netshoot-rdma-<tag>.tar。两种命名都必须能选中, 且内容 tag 要匹配。
# 机制: 从模块原样抽取 _netshoot_find_tar, 用 .tag 桩回放 RepoTag。
# 用法: bash deployments/scripts/tools/tests/test-netshoot-tar-select.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
MOD="${MODULE_UNDER_TEST:-${REPO_ROOT}/deployments/scripts/modules/03_addon/35_netshoot.sh}"
[ -f "${MOD}" ] || { echo "找不到被测模块: ${MOD}"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }

sed -n '/^_netshoot_find_tar() {/,/^}/p' "${MOD}" > "${TMP}/fn.sh"
[ -s "${TMP}/fn.sh" ] || { echo "FAIL 抽取 _netshoot_find_tar 失败"; exit 1; }

mk_tar() {  # <dir> <文件名> <RepoTag>
    : > "$1/$2"
    printf '%s\n' "$3" > "$1/$2.tag"
}
run_sel() {  # <dir> <tag>
    bash -c 'source "$1"
             tar_first_image_tag() { command cat "${1}.tag" 2>/dev/null || true; }
             find_offline_tar() { local d="$3"; [ -f "${d}/legacy.tar" ] && printf "%s\n" "${d}/legacy.tar"; }
             _netshoot_find_tar "$2" "$3"' \
        _ "${TMP}/fn.sh" "$1" "$2"
}

TAG=sha-abc1234
echo "== ① 中性名 + 内容 tag 匹配 =="
mkdir -p "${TMP}/s1"
mk_tar "${TMP}/s1" netshoot-rdma.tar "harbor.isuanova.com/suanova/netshoot-rdma:${TAG}"
out="$(run_sel "${TMP}/s1" "${TAG}")"
chk "选中中性 tar" "netshoot-rdma.tar" "$(basename "${out}")"

echo "== ② 中性名内容不匹配, 回退带 tag 文件 =="
mkdir -p "${TMP}/s2"
mk_tar "${TMP}/s2" netshoot-rdma.tar "harbor.isuanova.com/suanova/netshoot-rdma:2.1-latest"
mk_tar "${TMP}/s2" "netshoot-rdma-${TAG}.tar" "harbor.isuanova.com/suanova/netshoot-rdma:${TAG}"
out="$(run_sel "${TMP}/s2" "${TAG}")"
chk "选中带 tag tar" "netshoot-rdma-${TAG}.tar" "$(basename "${out}")"

echo "== ③ 只有 legacy 文件时交给 find_offline_tar =="
mkdir -p "${TMP}/s3"
mk_tar "${TMP}/s3" legacy.tar "harbor.isuanova.com/suanova/netshoot-rdma:${TAG}"
out="$(run_sel "${TMP}/s3" "${TAG}")"
chk "legacy 兜底" "legacy.tar" "$(basename "${out}")"

echo "== ④ 空目录返回空 =="
mkdir -p "${TMP}/s4"
out="$(run_sel "${TMP}/s4" "${TAG}")"
chk "无 tar" "" "${out}"

echo "---------------------------------------------"
if [ "${fail}" = "0" ]; then echo "✅ test-netshoot-tar-select: 全部通过"; else echo "❌ test-netshoot-tar-select: 有失败"; fi
exit "${fail}"
