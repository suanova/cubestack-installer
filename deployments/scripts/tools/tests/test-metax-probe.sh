#!/bin/bash
# ============================================================
# test-metax-probe.sh — MetaX 非 root 权限探针的镜像拉取失败处理
#
# 背景(2026-11-23 CodeRabbit PR #219):
#   · 无 skopeo 时无法预检镜像, Pod 会一直 Pending 到 600s 超时;
#     镜像拉取失败(Pending/ImagePullBackOff)不会自行恢复, 必须提前结束等待。
#   · 探针是可选的: 未设 METAX_REQUIRE_PERM_PROBE=true 时应告警跳过并 exit 0,
#     不能把"镜像不可用"误报成 GPU 权限失败; 显式要求时仍 exit 1。
#
# 覆盖(假 ssh/skopeo, 纯离线):
#   ① 可选探针镜像拉取失败 → 快速 exit 0 + 告警
#   ② METAX_REQUIRE_PERM_PROBE=true → 快速 exit 1 + 明确报错
#   ③ 失败等待不应拖到 METAX_PERM_PROBE_TIMEOUT_SECONDS
#
# 用法: bash deployments/scripts/tools/tests/test-metax-probe.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
VERIFY="${REPO_ROOT}/deployments/scripts/tools/k8s/verify-metax-gpu.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if [[ "$3" == *"$2"* ]]; then echo "  ok  $1"; else echo "  FAIL $1: 未包含 [$2]"; fail=1; fi; }

mkdir -p "${TMP}/bin"
cat > "${TMP}/nodes.json" <<'EOF'
{"items":[{"metadata":{"name":"m1","labels":{"metax-tech.com/gpu.installed":"true"}},"spec":{},"status":{"capacity":{"metax-tech.com/gpu":"1"},"allocatable":{"metax-tech.com/gpu":"1"}}}]}
EOF
cat > "${TMP}/bin/ssh" <<'FAKE'
#!/bin/bash
# 消费 stdin(apply -f - 的 heredoc), 其余命令按参数返回夹具
if [ ! -t 0 ]; then cat >/dev/null; fi
cmd="$*"
case "${cmd}" in
    *"get nodes -o json"*) cat "${NODES_JSON:?}" ;;
    *"get pod"*"status.phase"*) echo Pending ;;
    *"get pod"*"waiting.reason"*) echo ImagePullBackOff ;;
    *"logs"*) : ;;
    *"describe"*) : ;;
    *) : ;;
esac
exit 0
FAKE
cat > "${TMP}/bin/skopeo" <<'FAKE'
#!/bin/bash
exit 0
FAKE
chmod +x "${TMP}/bin/ssh" "${TMP}/bin/skopeo"
cat > "${TMP}/cluster.conf" <<'EOF'
NODES=("master,m1,10.0.0.1,root,-")
SSH_USER="root"
KUBESPRAY_PROFILE="none"
EOF

run_verify() {  # <require true|false> → sets OUT/RC/ELAPSED
    local req="$1"
    SECONDS=0
    PATH="${TMP}/bin:${PATH}" CLUSTER_CONF="${TMP}/cluster.conf" \
        CLUSTER_DEFAULTS_CONF="${REPO_ROOT}/deployments/config/cluster.defaults.conf" \
        NODES_JSON="${TMP}/nodes.json" METAX_REQUIRE_PERM_PROBE="${req}" \
        METAX_PERM_PROBE_TIMEOUT_SECONDS=600 \
        timeout 30 bash "${VERIFY}" > "${TMP}/out" 2>&1
    RC=$?
    ELAPSED=$SECONDS
    OUT="$(cat "${TMP}/out")"
}

echo "== ① 可选探针: 镜像拉取失败快速跳过 =="
run_verify false
chk "退出码 0" "0" "${RC}"
chk_contains "告警镜像不可用" "权限探针镜像不可用" "${OUT}"
chk_contains "说明跳过原因" "ImagePullBackOff" "${OUT}"
chk "未等待满超时(<15s)" "1" "$([ "${ELAPSED}" -lt 15 ] && echo 1 || echo 0)"

echo "== ② 强制要求探针: 镜像拉取失败仍硬失败 =="
run_verify true
chk "退出码 1" "1" "${RC}"
chk_contains "明确报镜像拉取失败" "权限探针镜像拉取失败" "${OUT}"
chk_contains "给出推送/覆盖指引" "METAX_PERM_PROBE_IMAGE" "${OUT}"
chk "未等待满超时(<15s)" "1" "$([ "${ELAPSED}" -lt 15 ] && echo 1 || echo 0)"

echo "---------------------------------------------"
if [ "${fail}" = "0" ]; then echo "✅ test-metax-probe: 全部通过"; else echo "❌ test-metax-probe: 有失败"; fi
exit "${fail}"
