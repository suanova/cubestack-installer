#!/bin/bash
# ============================================================
# test-nvidia-host-driver.sh — 宿主 NVIDIA 驱动探测 / 预编译门禁跳过回归
# 背景(2026-10-22 实机): 节点已有可用宿主驱动 580.178.04, operator 会自动打
#   nvidia.com/gpu.deploy.driver=pre-installed 并跳过 595 驱动 DaemonSet;
#   但安装器旧门禁仍按预编译内核白名单拦截(内核 198 无镜像 → 误判必须降内核)。
# 覆盖:
#   ① nvidia-smi -L 成功 → yes
#   ② 无驱动 → no
#   ③ SSH 失败 → unknown(保守, 不当作 yes)
#   ④ 模块: 宿主驱动可用时跳过预编译内核门禁, 只为需要的节点内核准备驱动镜像
# 隔离: 假 ssh(纯离线)
# 用法: bash deployments/scripts/tools/tests/test-nvidia-host-driver.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIB="${REPO_ROOT}/deployments/scripts/lib-common.sh"
MOD="${REPO_ROOT}/deployments/scripts/modules/03_addon/08_nvidia_gpu_operator.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  ok  $1"; else echo "  FAIL $1: [$3] 未包含 [$2]"; fail=1; fi; }

cat > "${TMP}/cluster.conf" <<'EOF'
NODES=("master,m1,10.0.0.1,root,-")
SSH_USER="root"
EOF
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/ssh" <<'FAKE'
#!/bin/bash
[ "${FAKE_SSH_FAIL:-0}" = "1" ] && exit 255
printf '%s\n' "${FAKE_HOST_DRV:-no}"
FAKE
chmod +x "${TMP}/bin/ssh"

_probe() {   # _probe <yes|no> [ssh-fail]
    (
        export PATH="${TMP}/bin:${PATH}"
        export CLUSTER_CONF="${TMP}/cluster.conf"
        export SSH_KEY="${TMP}/fake-key"
        export FAKE_HOST_DRV="$1"
        export FAKE_SSH_FAIL="${2:-0}"
        set +u
        # shellcheck disable=SC1090
        source "${LIB}" >/dev/null 2>&1
        node_host_nvidia_driver_works 10.0.0.1 root
    )
}

echo "== ① 宿主驱动可用 → yes =="
chk "探测结果" "yes" "$(_probe yes)"

echo "== ② 无宿主驱动 → no =="
chk "探测结果" "no" "$(_probe no)"

echo "== ③ SSH 失败 → unknown(不当作可用) =="
chk "探测结果" "unknown" "$(_probe yes 1)"

echo "== ④ 模块门禁逻辑 =="
chk_contains "lib-common 探测函数" 'node_host_nvidia_driver_works()' "${LIB}"
chk_contains "模块调用宿主驱动探测" 'node_host_nvidia_driver_works "${NODE_IP}"' "${MOD}"
chk_contains "宿主驱动可用时跳过预编译门禁" 'pre-installed) → 跳过预编译内核门禁' "${MOD}"
chk_contains "只为需要的内核准备驱动镜像" 'KERNELS_NEEDED' "${MOD}"
chk_contains "所有节点都有宿主驱动时不再准备驱动镜像" '无需预编译驱动镜像/内核门禁' "${MOD}"

echo ""
if [ "${fail}" = "0" ]; then
    echo "✅ test-nvidia-host-driver: 全部通过"
else
    echo "❌ test-nvidia-host-driver: 存在失败项"
fi
exit "${fail}"
