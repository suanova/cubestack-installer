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

echo "== ⑥ 部分部署(--steps)默认 quick(模式解析) =="
mode() { bash -c 'source "$1"; offline_verify_effective_mode "$2" "$3" "$4" "$5"' _ "${LIB}" "$@"; }
chk "全量 auto 保持 auto" "auto" "$(mode auto "" 0 "")"
_out="$(mode auto "--steps cubestack_operator" 0 "")"
chk "--steps + auto → quick" "quick" "$(printf '%s\n' "${_out}" | sed -n '1p')"
chk "--steps + auto 标记 downgraded" "downgraded" "$(printf '%s\n' "${_out}" | sed -n '2p')"
chk "--steps + full 保持 full" "full" "$(mode full "--steps cubestack_operator" 0 "")"
chk "--verify-offline full 显式优先" "full" "$(mode auto "--steps cubestack_operator" 0 full)"
chk "--verify-offline quick 显式优先" "quick" "$(mode auto "" 0 quick)"
chk "--no-verify-offline → off" "off" "$(mode auto "--steps x" 1 "")"
bash -c 'source "$1"; offline_verify_effective_mode auto "--steps x" 0 bogus' _ "${LIB}" >/dev/null 2>&1
chk "非法 --verify-offline 返回 1" "1" "$?"

echo "== ⑦ Kubespray 封装继承 OFFLINE_VERIFY_MODE =="
# 2026-10-30: cubestack-offline.sh 的 cmd_check 曾硬编码 --level auto, 顶层
#   --verify-offline=quick 时仍会整树 full+deep 重复校验; 现继承 OFFLINE_VERIFY_MODE。
OFFLINE_SH="${REPO_ROOT}/deployments/kubespray/cubestack-offline.sh"
chk_contains "lib-common export 含 OFFLINE_VERIFY_MODE" 'OFFLINE_VERIFY_MODE OFFLINE_VERIFY_JOBS' "$(cat "${LIB}")"
chk_contains "cubestack-offline 继承 OFFLINE_VERIFY_MODE" '_vlevel="${OFFLINE_VERIFY_MODE:-auto}"' "$(cat "${OFFLINE_SH}")"
chk "cubestack-offline 不再硬编码 --level auto" "0" "$(grep -c -- '--level auto' "${OFFLINE_SH}" || true)"
chk_contains "cubestack-offline off 分支" 'OFFLINE_VERIFY_MODE=off' "$(cat "${OFFLINE_SH}")"
# off 必须在查找校验器之前判定: 否则 --no-verify-offline 仍可能因校验器不可用/有清单而失败
_off_ln="$(command grep -F -n 'off|Off|OFF)' "${OFFLINE_SH}" | head -1 | cut -d: -f1)"
_ens_ln="$(command grep -F -n 'ensure_offline_verify_tool' "${OFFLINE_SH}" | head -1 | cut -d: -f1)"
chk "cubestack-offline off 判定先于校验器查找" "1" \
    "$([ -n "${_off_ln}" ] && [ -n "${_ens_ln}" ] && [ "${_off_ln}" -lt "${_ens_ln}" ] && echo 1 || echo 0)"

echo "== ⑧ 默认安装门禁 quick =="
# 2026-10-30 用户口径: 安装过程默认 quick(全量/--steps 一致); auto/full 改为显式 opt-in。
DEF="${REPO_ROOT}/deployments/config/cluster.defaults.conf"
chk_contains "cluster.defaults 默认 quick" 'OFFLINE_VERIFY_MODE="${OFFLINE_VERIFY_MODE:-quick}"' "$(cat "${DEF}")"
chk_contains "deploy-cluster 帮助默认 quick" '默认 quick' "$(cat "${REPO_ROOT}/deployments/scripts/deploy-cluster.sh")"

echo "---------------------------------------------"
if [ "${fail}" = "0" ]; then
    echo "✅ 部署门禁回归通过"
    exit 0
else
    echo "❌ 回归失败"
    exit 1
fi
