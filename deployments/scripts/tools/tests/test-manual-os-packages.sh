#!/bin/bash
# ============================================================
# test-manual-os-packages.sh — 手动 OS 包安装器的逐目标版本/旧布局/离线根回归
#
# 背景(2026-11-23 CodeRabbit PR #215):
#   · 未显式 OS_PACKAGES_VERSION 时, 旧实现把 versions/base.yaml 的基线导出给子工具,
#     把 24.04 的包装到 22.04 节点; 混合版本集群也会全用首节点版本。
#   · 版本目录不存在时未回退旧布局 os/packages。
#   · --offline-root 只校验不传给子安装器。
#
# 覆盖(假 ssh/假 bash, 纯离线):
#   ① 混合版本: 22.04/24.04 按目标分组, 各自带 --ip 与正确 OS_PACKAGES_VERSION
#   ② 显式 --os-version: 强制单版本, 所有目标同组
#   ③ 探测失败: 回退基线版本并告警
#   ④ --layout: 版本目录不存在时显示旧布局本地目标
#   ⑤ 离线根: 子安装器收到 OFFLINE_FILES_ROOT 与 --offline-root
#
# 用法: bash deployments/scripts/tools/tests/test-manual-os-packages.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TOOL="${REPO_ROOT}/deployments/scripts/tools/manual/install-os-packages.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if [[ "$3" == *"$2"* ]]; then echo "  ok  $1"; else echo "  FAIL $1: 未包含 [$2]"; fail=1; fi; }

mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/ssh" <<'FAKE'
#!/bin/bash
while [ $# -gt 0 ]; do
    case "$1" in -i|-o|-p|-l) shift 2 ;; -*) shift ;; *) break ;; esac
done
host="$1"; shift
case "$host" in
    *10.0.0.1) echo 22.04 ;;
    *10.0.0.2) [ "${FAKE_DETECT_FAIL:-0}" = "1" ] && exit 0 || echo 24.04 ;;
    *) echo 24.04 ;;
esac
FAKE
cat > "${TMP}/bin/bash" <<'FAKE'
#!/bin/bash
case "$*" in
    *install-chrony-packages.sh*|*reconcile-node-packages.sh*)
        printf 'CALL %s\nENV OS=%s ROOT=%s\n' "$*" "${OS_PACKAGES_VERSION:-}" "${OFFLINE_FILES_ROOT:-}" >> "${FAKE_LOG:?}"
        exit 0 ;;
esac
exec /bin/bash "$@"
FAKE
chmod +x "${TMP}/bin/ssh" "${TMP}/bin/bash"

mkdir -p "${TMP}/offline/os/packages/ubuntu-22.04/chrony" \
         "${TMP}/offline/os/packages/ubuntu-24.04/chrony"
: > "${TMP}/offline/os/packages/ubuntu-22.04/dummy.deb"
: > "${TMP}/offline/os/packages/ubuntu-22.04/chrony/chrony.deb"
: > "${TMP}/offline/os/packages/ubuntu-24.04/dummy.deb"
: > "${TMP}/offline/os/packages/ubuntu-24.04/chrony/chrony.deb"
mkdir -p "${TMP}/legacy/os/packages/chrony"
: > "${TMP}/legacy/os/packages/dummy.deb"
: > "${TMP}/legacy/os/packages/chrony/chrony.deb"

cat > "${TMP}/mixed.conf" <<'EOF'
NODES=("master,m1,10.0.0.1,root,-" "worker,w2,10.0.0.2,root,-")
SSH_USER="root"
KUBESPRAY_PROFILE="none"
EOF
cat > "${TMP}/single.conf" <<'EOF'
NODES=("master,m1,10.0.0.1,root,-")
SSH_USER="root"
KUBESPRAY_PROFILE="none"
EOF
cat > "${TMP}/empty.conf" <<'EOF'
NODES=()
SSH_USER="root"
KUBESPRAY_PROFILE="none"
EOF

run_tool() {  # <conf> <offline> <log> [args...]
    local conf="$1" off="$2" log="$3"; shift 3
    : > "${log}"
    PATH="${TMP}/bin:${PATH}" CLUSTER_CONF="${conf}" OFFLINE_FILES_ROOT="${off}" \
        FAKE_LOG="${log}" bash "${TOOL}" "$@" > "${TMP}/out" 2>&1
    echo $?
}

echo "== ① 混合版本: 逐目标分组 =="
rc="$(run_tool "${TMP}/mixed.conf" "${TMP}/offline" "${TMP}/mixed.log" --install)"
chk "退出码" "0" "${rc}"
chk_contains "22.04 chrony 只带 .1" "install-chrony-packages.sh --ip 10.0.0.1" "$(cat "${TMP}/mixed.log")"
chk_contains "24.04 chrony 只带 .2" "install-chrony-packages.sh --ip 10.0.0.2" "$(cat "${TMP}/mixed.log")"
chk_contains "22.04 general 只带 .1" "--scope general --offline-root ${TMP}/offline --ip 10.0.0.1" "$(cat "${TMP}/mixed.log")"
chk_contains "24.04 general 只带 .2" "--scope general --offline-root ${TMP}/offline --ip 10.0.0.2" "$(cat "${TMP}/mixed.log")"
chk "22.04 调用数(chrony+general)" "2" "$(grep -c '^ENV OS=22.04' "${TMP}/mixed.log" || true)"
chk "24.04 调用数(chrony+general)" "2" "$(grep -c '^ENV OS=24.04' "${TMP}/mixed.log" || true)"

echo "== ② 显式 --os-version 强制单版本 =="
rc="$(run_tool "${TMP}/mixed.conf" "${TMP}/offline" "${TMP}/forced.log" --install --os-version 22.04)"
chk "退出码" "0" "${rc}"
chk_contains "所有目标同组" "--ip 10.0.0.1 --ip 10.0.0.2" "$(cat "${TMP}/forced.log")"
chk "只有 22.04 组(chrony+general)" "2" "$(grep -c '^ENV OS=22.04' "${TMP}/forced.log" || true)"
chk "没有 24.04 组" "0" "$(grep -c '^ENV OS=24.04' "${TMP}/forced.log" || true)"

echo "== ③ 探测失败回退基线(24.04) =="
export FAKE_DETECT_FAIL=1
rc="$(run_tool "${TMP}/mixed.conf" "${TMP}/offline" "${TMP}/fallback.log" --install)"
unset FAKE_DETECT_FAIL
chk "退出码" "0" "${rc}"
chk_contains "提示回退基线" "回退基线 24.04" "$(cat "${TMP}/out")"
chk_contains "失败目标归入 24.04" "install-chrony-packages.sh --ip 10.0.0.2" "$(cat "${TMP}/fallback.log")"
chk "24.04 组数(两目标)" "2" "$(grep -c '^ENV OS=24.04' "${TMP}/fallback.log" || true)"

echo "== ④ 版本目录缺失 → 旧布局 =="
rc="$(run_tool "${TMP}/single.conf" "${TMP}/legacy" "${TMP}/legacy.log" --layout --os-version 24.04)"
chk "layout 退出码" "0" "${rc}"
chk_contains "显示旧布局本地目标" "本地目标:  ${TMP}/legacy/os/packages/" "$(cat "${TMP}/out")"
rc="$(run_tool "${TMP}/single.conf" "${TMP}/legacy" "${TMP}/legacy-install.log" --install --os-version 24.04)"
chk "legacy install 退出码" "0" "${rc}"
chk_contains "安装使用旧布局目录" "目录=${TMP}/legacy/os/packages" "$(cat "${TMP}/out")"

echo "== ⑤ 离线根传给子安装器 =="
chk_contains "chrony 收到 --offline-root" "--offline-root ${TMP}/offline" "$(grep 'install-chrony-packages.sh' "${TMP}/mixed.log")"
chk_contains "general 收到 --offline-root" "--offline-root ${TMP}/offline" "$(grep 'reconcile-node-packages.sh' "${TMP}/mixed.log")"
chk_contains "chrony 环境根" "ENV OS=22.04 ROOT=${TMP}/offline" "$(cat "${TMP}/mixed.log")"

echo "---------------------------------------------"
if [ "${fail}" = "0" ]; then echo "✅ test-manual-os-packages: 全部通过"; else echo "❌ test-manual-os-packages: 有失败"; fi
exit "${fail}"
