#!/bin/bash
# ============================================================
# test-verify-tool-install.sh — 校验器自举/在线安装回归(假 curl)
# 覆盖: 3 次重试成功/全失败/sha 不符/pin 缺失/发布树引导校验
# 用法: bash deployments/scripts/tools/tests/test-verify-tool-install.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIB_SRC="${REPO_ROOT}/deployments/scripts/tools/offline/lib-offline-verify.sh"
TOOL="${REPO_ROOT}/deployments/scripts/tools/offline/verify-offline-files.sh"
PYZ="${REPO_ROOT}/deployments/scripts/tools/offline/verify-offline-files.pyz"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }

# 把库复制到临时目录: 隔离"仓库副本", 让查找流程走到在线安装/发布树分支
mkdir -p "${TMP}/lib" "${TMP}/bin"
cp "${LIB_SRC}" "${TMP}/lib/lib-offline-verify.sh"
LIB="${TMP}/lib/lib-offline-verify.sh"

cat > "${TMP}/bin/curl" <<'EOF'
#!/bin/bash
n=$(cat "${FAKE_COUNT}" 2>/dev/null || echo 0); n=$((n+1)); echo "${n}" > "${FAKE_COUNT}"
mode="${FAKE_MODE:-success}"
case "${mode}" in
    fail2) [ "${n}" -lt 3 ] && exit 7 ;;
    alwaysfail) exit 7 ;;
esac
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done
[ -n "${out}" ] || exit 8
cp "${FAKE_TOOL}" "${out}"
EOF
chmod +x "${TMP}/bin/curl"
export PATH="${TMP}/bin:/usr/bin:/bin"
export FAKE_TOOL="${PYZ}"

# 软链入口(CLI 镜像 /usr/local/bin/cubestack-verify-offline)必须能找到 pyz
ln -sf "${TOOL}" "${TMP}/bin/cubestack-verify-offline"
chk "软链入口 --version" "0" "$("${TMP}/bin/cubestack-verify-offline" --version >/dev/null 2>&1; echo $?)"
rm -f "${TMP}/bin/cubestack-verify-offline"   # 不污染后续 PATH 查找

echo "== ① 前两次失败第三次成功 =="
export FAKE_COUNT="${TMP}/count1" FAKE_MODE=fail2
out="$(env -u OFFLINE_FILES_ROOT -u CUBESTACK_VERIFY_TOOL \
    OFFLINE_VERIFY_TOOL_URL="https://example.invalid/tool" \
    OFFLINE_VERIFY_TOOL_SHA256="$(sha256sum "${PYZ}" | awk '{print $1}')" \
    XDG_CACHE_HOME="${TMP}/cache1" \
    bash -c 'source "$1"; ensure_offline_verify_tool' _ "${LIB}" 2>/dev/null)"
chk "返回路径存在" "1" "$([ -n "${out}" ] && [ -x "${out}" ] && echo 1 || echo 0)"
chk "wrapper 可执行" "0" "$("${out}" --version >/dev/null 2>&1; echo $?)"
chk "3 次尝试" "3" "$(cat "${FAKE_COUNT}")"

echo "== ② 3 次全失败 =="
export FAKE_COUNT="${TMP}/count2" FAKE_MODE=alwaysfail
rc=0
env -u OFFLINE_FILES_ROOT -u CUBESTACK_VERIFY_TOOL \
    OFFLINE_VERIFY_TOOL_URL="https://example.invalid/tool" \
    OFFLINE_VERIFY_TOOL_SHA256="$(sha256sum "${PYZ}" | awk '{print $1}')" \
    XDG_CACHE_HOME="${TMP}/cache2" \
    bash -c 'source "$1"; ensure_offline_verify_tool' _ "${LIB}" >/dev/null 2>&1 || rc=$?
chk "失败退出码 1" "1" "${rc}"
chk "共 3 次" "3" "$(cat "${FAKE_COUNT}")"

echo "== ③ sha 不符拒绝 =="
export FAKE_COUNT="${TMP}/count3" FAKE_MODE=success
rc=0
env -u OFFLINE_FILES_ROOT -u CUBESTACK_VERIFY_TOOL \
    OFFLINE_VERIFY_TOOL_URL="https://example.invalid/tool" \
    OFFLINE_VERIFY_TOOL_SHA256="$(printf '0%.0s' {1..64})" \
    XDG_CACHE_HOME="${TMP}/cache3" \
    bash -c 'source "$1"; ensure_offline_verify_tool' _ "${LIB}" >/dev/null 2>&1 || rc=$?
chk "sha 不符失败" "1" "${rc}"
chk "未落位" "0" "$([ -e "${TMP}/cache3/cubestack/verify/verify-offline-files.sh" ] && echo 1 || echo 0)"

echo "== ④ pin 缺失 fail-closed =="
export FAKE_COUNT="${TMP}/count4" FAKE_MODE=success
rc=0
env -u OFFLINE_FILES_ROOT -u CUBESTACK_VERIFY_TOOL \
    OFFLINE_VERIFY_TOOL_URL="https://example.invalid/tool" \
    OFFLINE_VERIFY_TOOL_SHA256="" \
    XDG_CACHE_HOME="${TMP}/cache4" \
    bash -c 'source "$1"; ensure_offline_verify_tool' _ "${LIB}" >/dev/null 2>&1 || rc=$?
chk "pin 缺失失败" "1" "${rc}"
chk "未尝试下载" "0" "$([ -e "${TMP}/count4" ] && echo 1 || echo 0)"

echo "== ⑤ 发布树副本引导校验 =="
mkdir -p "${TMP}/tree/tools"
cp "${TOOL}" "${TMP}/tree/tools/verify-offline-files.sh"
cp "${PYZ}" "${TMP}/tree/tools/verify-offline-files.pyz"
{
    printf '%s  ./tools/verify-offline-files.sh\n' "$(sha256sum "${TOOL}" | awk '{print $1}')"
    printf '%s  ./tools/verify-offline-files.pyz\n' "$(sha256sum "${PYZ}" | awk '{print $1}')"
} > "${TMP}/tree/SHA256SUMS"
out="$(env -u CUBESTACK_VERIFY_TOOL OFFLINE_FILES_ROOT="${TMP}/tree" \
    OFFLINE_VERIFY_ONLINE_INSTALL=never \
    bash -c 'source "$1"; ensure_offline_verify_tool' _ "${LIB}" 2>/dev/null)"
chk "引导校验通过" "1" "$([ "${out}" = "${TMP}/tree/tools/verify-offline-files.sh" ] && echo 1 || echo 0)"
printf '%s  ./tools/verify-offline-files.sh\n' "0000000000000000000000000000000000000000000000000000000000000000" \
    > "${TMP}/tree/SHA256SUMS"
rc=0
env -u CUBESTACK_VERIFY_TOOL OFFLINE_FILES_ROOT="${TMP}/tree" \
    OFFLINE_VERIFY_ONLINE_INSTALL=never \
    bash -c 'source "$1"; ensure_offline_verify_tool' _ "${LIB}" >/dev/null 2>&1 || rc=$?
chk "引导校验失败拒绝" "1" "${rc}"

echo "== ⑥ OFFLINE_VERIFY_ONLINE_INSTALL=never =="
rc=0
env -u OFFLINE_FILES_ROOT -u CUBESTACK_VERIFY_TOOL \
    OFFLINE_VERIFY_ONLINE_INSTALL=never \
    bash -c 'source "$1"; ensure_offline_verify_tool' _ "${LIB}" >/dev/null 2>&1 || rc=$?
chk "never 失败" "1" "${rc}"

echo "---------------------------------------------"
if [ "${fail}" = "0" ]; then
    echo "✅ 工具自举回归通过"
    exit 0
else
    echo "❌ 回归失败"
    exit 1
fi
