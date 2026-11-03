#!/bin/bash
# ============================================================
# test-nodeport-leak-preflight.sh — nodeport-leak-preflight.sh 离线回归
# 用假 ssh 模拟 kubectl 的三种结果(端口被持有 / 泄漏后 repair / 其他错误),
# 覆盖: 集群不存在跳过 / 被持有跳过 / 泄漏等待后成功 / 非泄漏错误快速放行 / 超时放行。
# 用法: bash deployments/scripts/tools/tests/test-nodeport-leak-preflight.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TOOL="${REPO_ROOT}/deployments/scripts/tools/k8s/nodeport-leak-preflight.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if [[ "$3" == *"$2"* ]]; then echo "  ok  $1"; else echo "  FAIL $1: 未包含 [$2]"; fail=1; fi; }

mkdir -p "${TMP}/bin"
cat > "${TMP}/cluster.conf" <<'EOF'
SSH_USER="ubuntu"
NODES=(
"master,cubestack-k8s-master01,10.0.0.1,-,-"
)
REGISTRY_NODEPORT="31148"
EOF

cat > "${TMP}/bin/ssh" <<'FAKE'
#!/bin/bash
set -u
cmd="${!#}"                         # ssh 的最后一个参数 = 远端命令
STATE="${FAKE_STATE:?}"
case "${cmd}" in
    *"get nodes --no-headers"*)
        [ -f "${STATE}/no_cluster" ] && exit 255
        echo "cubestack-k8s-master01"; exit 0 ;;
    *"get svc -A -o json"*)
        if [ -f "${STATE}/held" ]; then
            printf '{"items":[{"metadata":{"name":"registry"},"spec":{"ports":[{"nodePort":31148}]}}]}\n'
        else
            printf '{"items":[]}\n'
        fi
        exit 0 ;;
    *"apply --dry-run=server"*)
        cat >/dev/null                 # 消费 stdin 里的 Service manifest
        n="$(cat "${STATE}/probes" 2>/dev/null || echo 0)"; n=$((n + 1))
        echo "${n}" > "${STATE}/probes"
        if [ -f "${STATE}/other_error" ]; then
            echo "error: some unrelated failure" >&2; exit 1
        fi
        if [ "${n}" -le "${FAIL_PROBES:-0}" ]; then
            echo 'The Service "x" is invalid: spec.ports[0].nodePort: Invalid value: 31148: provided port is already allocated' >&2
            exit 1
        fi
        echo "service/x created (server dry run)"; exit 0 ;;
    *)
        echo "fake ssh: unsupported remote cmd: ${cmd}" >&2; exit 1 ;;
esac
FAKE
chmod +x "${TMP}/bin/ssh"

# run_case <state-subdir> [FAIL_PROBES] [额外 env...] → 设置 out/err/rc
run_case() {
    local st="$1"; shift
    rm -rf "${TMP}/state"; mkdir -p "${TMP}/state"
    [ -d "${TMP}/states/${st}" ] && cp -a "${TMP}/states/${st}/." "${TMP}/state/" 2>/dev/null || true
    out="$(PATH="${TMP}/bin:${PATH}" FAKE_STATE="${TMP}/state" CLUSTER_CONF="${TMP}/cluster.conf" \
        NODEPORT_LEAK_WAIT_SECONDS="${WAIT_S:-3}" NODEPORT_LEAK_WAIT_INTERVAL=1 \
        env "$@" bash "${TOOL}" --port 31148 2>&1)"
    rc=$?
    probes="$(cat "${TMP}/state/probes" 2>/dev/null || echo 0)"
}

echo "== ① 集群尚不存在 → 跳过 =="
mkdir -p "${TMP}/states/no_cluster"; : > "${TMP}/states/no_cluster/no_cluster"
run_case no_cluster
chk "退出码 0(fail-open)" "0" "${rc}"
chk_contains "提示跳过" "跳过 NodePort 泄漏预检" "${out}"
chk "未发起 dry-run" "0" "${probes}"

echo "== ② 端口已被 Service 持有 → 跳过 =="
mkdir -p "${TMP}/states/held"; : > "${TMP}/states/held/held"
run_case held
chk "退出码 0" "0" "${rc}"
chk_contains "提示已被持有" "已被现有 Service 持有" "${out}"
chk "未发起 dry-run" "0" "${probes}"

echo "== ③ 泄漏分配 → 等待 repair 后成功 =="
run_case clean FAIL_PROBES=2
chk "退出码 0" "0" "${rc}"
chk_contains "提示泄漏等待" "泄漏分配" "${out}"
chk_contains "提示最终可分配" "可分配" "${out}"
chk "探测次数(2 次失败 + 1 次成功)" "3" "${probes}"

echo "== ④ 非泄漏错误 → 快速放行 =="
mkdir -p "${TMP}/states/other"; : > "${TMP}/states/other/other_error"
run_case other
chk "退出码 0" "0" "${rc}"
chk_contains "提示非泄漏错误" "非泄漏错误" "${out}"
chk "只探测一次" "1" "${probes}"

echo "== ⑤ 等待超时 → 放行(交由 role 补丁/apply) =="
WAIT_S=1
run_case timeout FAIL_PROBES=99
unset WAIT_S
chk "退出码 0" "0" "${rc}"
chk_contains "提示等待超时" "等待超时" "${out}"

echo "---------------------------------------------"
if [ "${fail}" = "0" ]; then
    echo "✅ nodeport-leak-preflight 回归通过"
else
    echo "❌ nodeport-leak-preflight 回归失败"
    exit 1
fi
