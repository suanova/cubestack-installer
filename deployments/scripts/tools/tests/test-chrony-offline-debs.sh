#!/bin/bash
# ============================================================
# test-chrony-offline-debs.sh — chrony 离线 deb 依赖闭包工具回归(离线)
# 覆盖:
#   ① 闭包完整 → --check 通过
#   ② 缺依赖 → --check 非 0, 输出缺失包名; --list 只输出包名
#   ③ Provides 虚拟包 → 依赖被满足
#   ④ 空目录/不存在目录 → 明确失败
# 用法: bash deployments/scripts/tools/tests/test-chrony-offline-debs.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TOOL="${REPO_ROOT}/deployments/scripts/tools/node/chrony-offline-debs.py"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if printf '%s' "$3" | command grep -qF -- "$2"; then echo "  ok  $1"; else echo "  FAIL $1: 未包含 [$2]"; fail=1; fi; }

make_deb() {  # <name> [depends] [provides]
    local name="$1" dep="${2:-}" prov="${3:-}"
    local d="${TMP}/pkg-${name}"
    rm -rf "${d}"; mkdir -p "${d}/DEBIAN"
    {
        echo "Package: ${name}"
        echo "Version: 1.0"
        echo "Architecture: all"
        echo "Maintainer: test"
        echo "Description: test fixture"
        [ -n "${dep}" ] && echo "Depends: ${dep}"
        [ -n "${prov}" ] && echo "Provides: ${prov}"
    } > "${d}/DEBIAN/control"
    mkdir -p "${TMP}/debs"
    dpkg-deb --build --root-owner-group "${d}" "${TMP}/debs/${name}.deb" >/dev/null
}

make_deb libb
make_deb liba "libb"
make_deb provider "" "virt-x"
make_deb consumer "virt-x"

echo "== ① 完整闭包 =="
out="$(python3 -I "${TOOL}" --check "${TMP}/debs" 2>&1)"; rc=$?
chk "完整闭包退出码" "0" "${rc}"
chk_contains "完整闭包提示" "依赖闭包完整" "${out}"

echo "== ② 缺依赖 =="
rm -f "${TMP}/debs/libb.deb"
out="$(python3 -I "${TOOL}" --check "${TMP}/debs" 2>&1)"; rc=$?
chk "缺依赖退出码非 0" "1" "${rc}"
chk_contains "缺依赖列出 libb" "libb" "${out}"
chk_contains "缺依赖给出补齐命令" "--fetch" "${out}"
out="$(python3 -I "${TOOL}" --check --list "${TMP}/debs" 2>&1)"; rc=$?
chk "list 模式退出码非 0" "1" "${rc}"
chk "list 只输出包名" "libb" "${out}"

echo "== ③ Provides 虚拟包 =="
make_deb libb
out="$(python3 -I "${TOOL}" --check "${TMP}/debs" 2>&1)"; rc=$?
chk "Provides 满足后退出码" "0" "${rc}"
chk_contains "Provides 满足提示" "依赖闭包完整" "${out}"

echo "== ④ 空目录/不存在目录 =="
mkdir -p "${TMP}/empty"
python3 -I "${TOOL}" --check "${TMP}/empty" >/dev/null 2>&1
chk "空目录退出码非 0" "1" "$?"
python3 -I "${TOOL}" --check "${TMP}/missing" >/dev/null 2>&1
chk "不存在目录退出码非 0" "1" "$?"

echo "---------------------------------------------"
if [ "${fail}" = "0" ]; then echo "✅ test-chrony-offline-debs: 全部通过"; else echo "❌ test-chrony-offline-debs: 有失败"; fi
exit "${fail}"
