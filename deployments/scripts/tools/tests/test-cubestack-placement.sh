#!/bin/bash
# ============================================================
# test-cubestack-placement.sh — CubeStack operator/平台组件 master placement 回归
#
# 覆盖:
#   ① 工具存在且声明 apply/check/remove
#   ② 覆盖 cubestack-operator/controller-manager/cubepilot/portal/envoy 控制器/
#      ai-gateway/lws/cuberouter/monitoring 平台 Deployment
#   ③ patch 含 master nodeSelector + control-plane/unschedulable tolerations
#   ④ 明确不碰 Envoy 数据面 proxy / sglang / vllm / model 推理负载
#   ⑤ apply 假 ssh 对每个平台 Deployment 发 patch
#
# 隔离: 假 ssh 记录命令; 不连集群。
# 用法: bash deployments/scripts/tools/tests/test-cubestack-placement.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TOOL="${REPO_ROOT}/deployments/scripts/tools/k8s/cubestack-placement.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if [[ "$3" == *"$2"* ]]; then echo "  ok  $1"; else echo "  FAIL $1: 未包含 [$2]"; fail=1; fi; }
chk_not_contains() { if [[ "$3" != *"$2"* ]]; then echo "  ok  $1"; else echo "  FAIL $1: 不应包含 [$2]"; fail=1; fi; }

[ -f "${TOOL}" ] && echo "  ok  tool exists" || { echo "  FAIL tool missing: ${TOOL}"; fail=1; }

if [ -f "${TOOL}" ]; then
    src="$(cat "${TOOL}")"
    echo "== ① 模式 =="
    chk_contains "apply" "--apply" "${src}"
    chk_contains "check" "--check" "${src}"
    chk_contains "remove" "--remove" "${src}"

    echo "== ② workload 覆盖 =="
    for w in cubestack-operator cubestack-controller-manager cubepilot-api cubepilot-operator cubestack-portal; do
        chk_contains "workload ${w}" "${w}" "${src}"
    done
    for w in envoy-gateway ai-gateway-controller lws-controller-manager cuberouter kube-prometheus-kube-prome-operator perses-operator-controller-manager; do
        chk_contains "workload ${w}" "${w}" "${src}"
    done

    echo "== ③ placement =="
    chk_contains "control-plane selector" "node-role.kubernetes.io/control-plane" "${src}"
    chk_contains "unschedulable toleration" "node.kubernetes.io/unschedulable" "${src}"

    echo "== ④ 不碰数据面/推理 =="
    # workload 列表不应包含 envoy-envoy-gateway-system- / sglang / vllm / model
    chk_not_contains "no data-plane proxy" "envoy-envoy-gateway-system-" "$(grep -A30 '^_CB_WORKLOADS=' "${TOOL}" | grep 'deploy|' || true)"
    chk_not_contains "no sglang" "sglang" "$(grep -A30 '^_CB_WORKLOADS=' "${TOOL}" | grep 'deploy|' || true)"
    chk_not_contains "no vllm" "vllm" "$(grep -A30 '^_CB_WORKLOADS=' "${TOOL}" | grep 'deploy|' || true)"
    chk_not_contains "no model inference" "model" "$(grep -A30 '^_CB_WORKLOADS=' "${TOOL}" | grep 'deploy|' || true)"
fi

echo "== ⑤ apply 假 ssh 执行 =="
mkdir -p "${TMP}/bin" "${TMP}/keys" "${TMP}/offline"
: > "${TMP}/keys/fake_key"; : > "${TMP}/defaults.conf"; : > "${TMP}/ssh.log"
cat > "${TMP}/bin/ssh" <<'FAKE'
#!/bin/bash
seen=0; cmd=""
for a in "$@"; do
    if [ "${seen}" = "0" ]; then case "$a" in *@*) seen=1 ;; esac; else cmd="${cmd}${cmd:+ }${a}"; fi
done
printf '%s\n' "${cmd}" >> "${FAKE_SSH_LOG:?}"
exit 0
FAKE
chmod +x "${TMP}/bin/ssh"
cat > "${TMP}/cluster.conf" <<'EOF'
NODES=(
  "master,m1,10.0.0.1,root,-"
)
SSH_USER="root"
KUBESPRAY_PROFILE="none"
EOF
if [ -f "${TOOL}" ]; then
    (
        export PATH="${TMP}/bin:${PATH}"
        export CLUSTER_CONF="${TMP}/cluster.conf" CLUSTER_DEFAULTS_CONF="${TMP}/defaults.conf"
        export OFFLINE_FILES_ROOT="${TMP}/offline" CUBESTACK_RELEASE_AUTO=false
        export SSH_KEY_DIR="${TMP}/keys" SSH_KEY_NAME="fake_key"
        export FAKE_SSH_LOG="${TMP}/ssh.log"
        bash "${TOOL}" --apply
    ) >/dev/null 2>&1
    log="$(cat "${TMP}/ssh.log")"
    for w in cubestack-operator cubestack-controller-manager cubepilot-api cubepilot-operator cubestack-portal envoy-gateway ai-gateway-controller lws-controller-manager cuberouter kube-prometheus-kube-prome-operator perses-operator-controller-manager; do
        chk_contains "apply patch ${w}" "patch deploy ${w}" "${log}"
    done
    chk_contains "apply toleration" "node.kubernetes.io/unschedulable" "${log}"
    chk_not_contains "no data-plane proxy patch" "patch deploy envoy-envoy-gateway-system-" "${log}"
else
    echo "  FAIL 无法执行 apply(tool missing)"; fail=1
fi

echo "== ⑥ check 精确校验 nodeSelector(不得被 toleration 假阳性) =="
# 2026-10-27 容器 c 实测: Deployment 只有 tolerations、没有 nodeSelector 时旧 --check 仍报 OK,
# 因为 grep 整个 JSON 会命中 toleration 里的 control-plane 字符串 → 必须按字段解析。
mkdir -p "${TMP}/bin-check"
cat > "${TMP}/bin-check/ssh" <<'FAKE'
#!/bin/bash
cmd="$*"
case "${cmd}" in
    *" -o json"*) cat "${FAKE_DEPLOY_JSON:?}" ;;
esac
exit 0
FAKE
chmod +x "${TMP}/bin-check/ssh"
run_check() {   # <deploy json>
    (
        export PATH="${TMP}/bin-check:${PATH}"
        export CLUSTER_CONF="${TMP}/cluster.conf" CLUSTER_DEFAULTS_CONF="${TMP}/defaults.conf"
        export OFFLINE_FILES_ROOT="${TMP}/offline" CUBESTACK_RELEASE_AUTO=false
        export SSH_KEY_DIR="${TMP}/keys" SSH_KEY_NAME="fake_key"
        export FAKE_DEPLOY_JSON="$1"
        bash "${TOOL}" --check
    )
}
cat > "${TMP}/dep-no-sel.json" <<'EOF'
{"spec":{"template":{"spec":{"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},{"key":"node.kubernetes.io/unschedulable","operator":"Exists","effect":"NoSchedule"}]}}}}
EOF
cat > "${TMP}/dep-ok.json" <<'EOF'
{"spec":{"template":{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":""},"tolerations":[{"key":"node.kubernetes.io/unschedulable","operator":"Exists","effect":"NoSchedule"}]}}}}
EOF
out="$(run_check "${TMP}/dep-no-sel.json" 2>&1)"; rc=$?
chk "⑥ 仅 toleration 无 nodeSelector → check 失败" "1" "${rc}"
chk_contains "⑥ 报 placement 不完整" "placement 不完整" "${out}"
out="$(run_check "${TMP}/dep-ok.json" 2>&1)"; rc=$?
chk "⑥ selector+toleration → check 通过" "0" "${rc}"

echo ""
if [ "${fail}" = "0" ]; then
    echo "✅ test-cubestack-placement: 全部通过"
else
    echo "❌ test-cubestack-placement: 存在失败项"
fi
exit "${fail}"
