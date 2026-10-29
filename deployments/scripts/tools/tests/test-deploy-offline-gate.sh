#!/bin/bash
# ============================================================
# test-deploy-offline-gate.sh — 部署前完整性门禁/release.env 预校验
# 覆盖: sealed full/auto/off、损坏阻断、未 seal 严格/宽松、release.env 绑定
# 用法: bash deployments/scripts/tools/tests/test-deploy-offline-gate.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIB="${REPO_ROOT}/deployments/scripts/lib-common.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if [[ "$3" == *"$2"* ]]; then echo "  ok  $1"; else echo "  FAIL $1: 未包含 [$2]"; fail=1; fi; }

mk_manifests() {   # <dir>
    (
        cd "$1" || exit 1
        find . -type f ! -name SHA256SUMS ! -name SIZES ! -name _SUCCESS \
             ! -name '.cubestack-*' -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
        find . -type f ! -name SHA256SUMS ! -name SIZES ! -name _SUCCESS \
             ! -name '.cubestack-*' -printf '%s  %p\n' | sort -k2 > SIZES
    )
}

gate() {   # <root> <mode> [strict]
    OFFLINE_FILES_ROOT="$1" OFFLINE_VERIFY_MODE="$2" \
    OFFLINE_VERIFY_STRICT_DEV="${3:-true}" OFFLINE_VERIFY_STAMP=true \
    OFFLINE_VERIFY_ONLINE_INSTALL=never \
    env -u CUBESTACK_RELEASE -u CUBESTACK_RELEASE_LAYOUT -u CUBESTACK_RELEASE_ROOT \
        bash -c 'source "$1"; verify_offline_gate' _ "${LIB}" \
        >"${TMP}/out" 2>"${TMP}/err"
    echo $?
}

precheck() {   # <offline-files-root>
    bash -c 'source "$1"; verify_release_env_precheck "$2"' _ "${LIB}" "$1" \
        >"${TMP}/out" 2>"${TMP}/err"
    echo $?
}

echo "== ① sealed-dev: full/auto/off =="
mkdir -p "${TMP}/sealed"
printf 'aaaa' > "${TMP}/sealed/a.bin"
mk_manifests "${TMP}/sealed"
chk "full 通过" "0" "$(gate "${TMP}/sealed" full)"
chk "写校验戳" "1" "$([ -f "${TMP}/sealed/.cubestack-verified.json" ] && echo 1 || echo 0)"
chk "auto 走戳通过" "0" "$(gate "${TMP}/sealed" auto)"
printf 'bbbb' > "${TMP}/sealed/a.bin"
chk "损坏 full 失败" "1" "$(gate "${TMP}/sealed" full)"
chk "损坏 auto 失败" "1" "$(gate "${TMP}/sealed" auto)"
chk "off 跳过" "0" "$(gate "${TMP}/sealed" off)"
chk_contains "off 横幅" "跳过" "$(cat "${TMP}/out")"

echo "== ② 未 seal 开发树: 严格/宽松 =="
mkdir -p "${TMP}/dev"
printf 'x' > "${TMP}/dev/a.bin"
tar -C "${TMP}/dev" -cf "${TMP}/dev/bad.tar" . 2>/dev/null || true
head -c 1024 "${TMP}/dev/bad.tar" > "${TMP}/dev/bad.tmp" && mv -f "${TMP}/dev/bad.tmp" "${TMP}/dev/bad.tar"
chk "严格模式损坏阻断" "1" "$(gate "${TMP}/dev" quick true)"
chk "宽松模式仅警告" "0" "$(gate "${TMP}/dev" quick false)"
chk_contains "宽松提示" "仅警告" "$(cat "${TMP}/out")"

echo "== ③ release.env source 前校验 =="
mkdir -p "${TMP}/rel/offline-files"
printf 'RELEASE_VERSION=9.9.9\nKUBESPRAY_VERSION=v9.9.9\n' > "${TMP}/rel/offline-files/release.env"
(
    cd "${TMP}/rel/offline-files"
    sha256sum ./release.env > SHA256SUMS
    printf 'release=9.9.9\nsha256sums=%s\n' "$(sha256sum SHA256SUMS | awk '{print $1}')" > _SUCCESS
)
chk "一致通过" "0" "$(precheck "${TMP}/rel/offline-files")"
printf 'RELEASE_VERSION=9.9.9\nKUBESPRAY_VERSION=v0.0.0\n' > "${TMP}/rel/offline-files/release.env"
chk "损坏拒绝" "1" "$(precheck "${TMP}/rel/offline-files")"
chk_contains "拒绝原因" "校验失败" "$(cat "${TMP}/err")"
mkdir -p "${TMP}/noeval"
printf 'RELEASE_VERSION=9.9.9\n' > "${TMP}/noeval/release.env"
chk "无清单只警告" "0" "$(precheck "${TMP}/noeval")"
chk_contains "警告提示" "跳过 release.env 预校验" "$(cat "${TMP}/err")"

echo "== ④ _SUCCESS 绑定错误 =="
printf 'RELEASE_VERSION=9.9.9\nKUBESPRAY_VERSION=v9.9.9\n' > "${TMP}/rel/offline-files/release.env"
(
    cd "${TMP}/rel/offline-files"
    sha256sum ./release.env > SHA256SUMS
    printf 'release=9.9.9\nsha256sums=%064d\n' 0 > _SUCCESS
)
chk "绑定错误拒绝" "1" "$(precheck "${TMP}/rel/offline-files")"
chk_contains "绑定原因" "sha256sums" "$(cat "${TMP}/err")"

echo "== ⑤ 缺失文件: 门禁仍严格 =="
mkdir -p "${TMP}/miss"
printf 'x' > "${TMP}/miss/a.bin"
mk_manifests "${TMP}/miss"
rm -f "${TMP}/miss/a.bin"
chk "gate 缺失文件失败" "1" "$(gate "${TMP}/miss" full)"
chk_contains "gate 提示文件不存在" "文件不存在或已被删除" "$(cat "${TMP}/out")"

echo "---------------------------------------------"
if [ "${fail}" = "0" ]; then
    echo "✅ 部署门禁回归通过"
    exit 0
else
    echo "❌ 回归失败"
    exit 1
fi
