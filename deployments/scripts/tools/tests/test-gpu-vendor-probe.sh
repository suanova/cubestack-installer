#!/bin/bash
# ============================================================
# test-gpu-vendor-probe.sh — GPU 厂商探测 / "纯 CPU"判定离线回归
# 背景(2026-10-22 用户口径): 只有 NVIDIA 与沐曦 GPU **都未检测到** 才允许提示
#   "纯 CPU 环境"; 任一厂商有卡都不能称为纯 CPU。
# 覆盖:
#   ① NVIDIA only(2 0)      → 非纯 CPU
#   ② 沐曦 only(0 2)        → 非纯 CPU
#   ③ 两厂商都有(2 2)       → 非纯 CPU
#   ④ 两厂商都无(0 0)       → 纯 CPU
#   ⑤ mx-smi 不可用(0 unknown) → 不判定为纯 CPU
#   ⑥ SSH 失败               → "0 unknown", 不判定为纯 CPU
# 隔离: 假 ssh(纯离线, 不连集群)
# 用法: bash deployments/scripts/tools/tests/test-gpu-vendor-probe.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIB="${REPO_ROOT}/deployments/scripts/lib-common.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_rc() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望退出码[$2] 实际[$3]"; fail=1; fi; }

cat > "${TMP}/cluster.conf" <<'EOF'
NODES=("master,m1,10.0.0.1,root,-")
SSH_USER="root"
EOF
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/ssh" <<'FAKE'
#!/bin/bash
[ "${FAKE_SSH_FAIL:-0}" = "1" ] && exit 255
printf '%s\n' "${FAKE_GPU_PROBE:-0 unknown}"
FAKE
chmod +x "${TMP}/bin/ssh"

_probe() {   # _probe <gpu-probe fixture> [ssh-fail]
    (
        export PATH="${TMP}/bin:${PATH}"
        export CLUSTER_CONF="${TMP}/cluster.conf"
        export SSH_KEY="${TMP}/fake-key"
        export FAKE_GPU_PROBE="$1"
        export FAKE_SSH_FAIL="${2:-0}"
        set +u
        # shellcheck disable=SC1090
        source "${LIB}" >/dev/null 2>&1
        node_gpu_probe 10.0.0.1 root
    )
}
_pure() {    # _pure <nv> <mx> → 0=纯 CPU / 1=非纯 CPU
    (
        set +u
        # shellcheck disable=SC1090
        source "${LIB}" >/dev/null 2>&1
        node_gpu_is_pure_cpu "$1" "$2"
    )
}

echo "== ① NVIDIA only: 非纯 CPU =="
chk "探测输出" "2 0" "$(_probe '2 0')"
_pure 2 0; chk_rc "纯 CPU 判定" "1" "$?"

echo "== ② 沐曦 only: 非纯 CPU =="
chk "探测输出" "0 2" "$(_probe '0 2')"
_pure 0 2; chk_rc "纯 CPU 判定" "1" "$?"

echo "== ③ 两厂商都有: 非纯 CPU =="
chk "探测输出" "2 2" "$(_probe '2 2')"
_pure 2 2; chk_rc "纯 CPU 判定" "1" "$?"

echo "== ④ 两厂商都无: 纯 CPU =="
chk "探测输出" "0 0" "$(_probe '0 0')"
_pure 0 0; chk_rc "纯 CPU 判定" "0" "$?"

echo "== ⑤ mx-smi 不可用: 不判定纯 CPU =="
chk "探测输出" "0 unknown" "$(_probe '0 unknown')"
_pure 0 unknown; chk_rc "纯 CPU 判定" "1" "$?"

echo "== ⑥ SSH 失败: 不判定纯 CPU =="
chk "探测输出" "0 unknown" "$(_probe '0 0' 1)"
_pure 0 unknown; chk_rc "纯 CPU 判定" "1" "$?"

echo ""
if [ "${fail}" = "0" ]; then
    echo "✅ test-gpu-vendor-probe: 全部通过"
else
    echo "❌ test-gpu-vendor-probe: 存在失败项"
fi
exit "${fail}"
