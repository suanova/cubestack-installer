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
#   ⑥ check 精确校验 nodeSelector(toleration 不得假阳性)
#   ⑦ remove patch 失败/存在性查询失败 → 非 0(不得降级为 warning)
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
    for w in envoy-gateway ai-gateway-controller lws-controller-manager cuberouter kube-prometheus-kube-prome-operator perses-operator-controller-manager cubestack-docs; do
        chk_contains "workload ${w}" "${w}" "${src}"
    done
    for w in prometheuses.monitoring.coreos.com alertmanagers.monitoring.coreos.com perses.perses.dev redisreplications.redis.redis.opstreelabs.in clusters.postgresql.cnpg.io; do
        chk_contains "CR workload ${w}" "${w}" "${src}"
    done
    chk_contains "CNPG affinity list" "_CB_CRS_AFFINITY" "${src}"
    chk_contains "Redis sentinel list" "_CB_CRS_SENTINEL" "${src}"
    chk_contains "Sentinel nodeSelector path" "spec.sentinel.nodeSelector" "${src}"

    echo "== ③ placement =="
    chk_contains "control-plane selector" "node-role.kubernetes.io/control-plane" "${src}"
    chk_contains "unschedulable toleration" "node.kubernetes.io/unschedulable" "${src}"
    chk_contains "patch 前先给 RWO Deployment 设 Recreate" 'ensure_rwo_deployments_recreate' "${src}"
    chk_contains "local-path PVC 守护" "placement_pvc_worker_bound" "${src}"
    chk_contains "apply/check 查询失败按失败处理" "_require_exists" "${src}"
    chk_contains "unpatch 只删 installer key(CR)" '"nodeSelector":{"node-role.kubernetes.io/control-plane":null}' "${src}"
    chk_contains "unpatch 只删 installer key(CNPG affinity)" '"affinity":{"nodeSelector":{"node-role.kubernetes.io/control-plane":null}}' "${src}"
    chk_contains "unpatch 只删 installer key(sentinel)" '"sentinel":{"nodeSelector":{"node-role.kubernetes.io/control-plane":null}}' "${src}"
    chk_contains "sentinel 复用 PVC 守护" "_pvc_guard_prefix" "${src}"
    chk_contains "CR 组件 values 回滚" "_cb_clear_cr_component_placement" "${src}"
    chk_contains "组件 values 覆盖 cubepilot" '("cubepilot", "values", "operator", "nodeSelector")' "${src}"
    chk_contains "组件 values 覆盖 kube-state-metrics" '("prometheus", "values", "kube-state-metrics", "nodeSelector")' "${src}"
    chk_contains "CR patch 合并现有 tolerations" "_patch_cr_placement" "${src}"
    chk_not_contains "不再使用静态 CR patch" "_CR_PATCH=" "${src}"

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
# CR 多副本 PVC 前缀查询: 必须返回合法 JSON(空列表), 否则按"查询失败"保守跳过。
case "${cmd}" in
    *"get pvc -o json"*) echo '{"items":[]}' ;;
    *" -o json"*) echo '{"spec":{}}' ;;
esac
exit 0
FAKE
chmod +x "${TMP}/bin/ssh"
# RWO 守卫在查不到目标时会 sleep 5 重试; 测试里不需要真实等待。
printf '#!/bin/bash\nexit 0\n' > "${TMP}/bin/sleep"; chmod +x "${TMP}/bin/sleep"
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
    for w in cubestack-operator cubestack-controller-manager cubepilot-api cubepilot-operator cubestack-portal envoy-gateway ai-gateway-controller lws-controller-manager cuberouter kube-prometheus-kube-prome-operator perses-operator-controller-manager cubestack-docs; do
        chk_contains "apply patch ${w}" "patch deploy ${w}" "${log}"
    done
    chk_contains "apply patch prometheus CR" "patch prometheuses.monitoring.coreos.com" "${log}"
    chk_contains "apply patch alertmanager CR" "patch alertmanagers.monitoring.coreos.com" "${log}"
    chk_contains "apply patch perses CR" "patch perses.perses.dev" "${log}"
    chk_contains "apply patch redis replication CR" "patch redisreplications.redis.redis.opstreelabs.in" "${log}"
    chk_contains "apply patch CNPG cluster" "patch clusters.postgresql.cnpg.io" "${log}"
    chk_contains "CNPG use affinity patch" "affinity" "${log}"
    chk_contains "Redis sentinel patch" "sentinel" "${log}"
    chk_contains "CR use merge patch" "--type=merge" "${log}"
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
    *"perses.perses.dev"*|*"prometheuses.monitoring.coreos.com"*|*"alertmanagers.monitoring.coreos.com"*|*"redisreplications.redis.redis.opstreelabs.in"*|*"clusters.postgresql.cnpg.io"*)
        echo "Error from server (NotFound): custom resource not found" >&2; exit 1 ;;
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

echo "== ⑦ remove patch 失败 → 非 0(不得降级为 warning) =="
mkdir -p "${TMP}/bin-rmfail"
cat > "${TMP}/bin-rmfail/ssh" <<'FAKE'
#!/bin/bash
case "$*" in
    *" patch "*) exit 1 ;;
esac
exit 0
FAKE
chmod +x "${TMP}/bin-rmfail/ssh"
out="$(
    (
        export PATH="${TMP}/bin-rmfail:${PATH}"
        export CLUSTER_CONF="${TMP}/cluster.conf" CLUSTER_DEFAULTS_CONF="${TMP}/defaults.conf"
        export OFFLINE_FILES_ROOT="${TMP}/offline" CUBESTACK_RELEASE_AUTO=false
        export SSH_KEY_DIR="${TMP}/keys" SSH_KEY_NAME="fake_key"
        bash "${TOOL}" --remove
    ) 2>&1
)"; rc=$?
chk "⑦ remove patch 失败退出码" "1" "${rc}"
chk_contains "⑦ 报 remove patch 失败" "remove patch 失败" "${out}"
chk_not_contains "⑦ 不再标注不阻断" "remove patch 失败(不阻断)" "${out}"

# 存在性查询失败(API/RBAC/SSH)必须非 0, 不能当"不存在"跳过
mkdir -p "${TMP}/bin-getfail"
cat > "${TMP}/bin-getfail/ssh" <<'FAKE'
#!/bin/bash
case "$*" in
    *" get "*) echo "Error from server: connection refused" >&2; exit 1 ;;
esac
exit 0
FAKE
chmod +x "${TMP}/bin-getfail/ssh"
printf '#!/bin/bash\nexit 0\n' > "${TMP}/bin-getfail/sleep"; chmod +x "${TMP}/bin-getfail/sleep"
out="$(
    (
        export PATH="${TMP}/bin-getfail:${PATH}"
        export CLUSTER_CONF="${TMP}/cluster.conf" CLUSTER_DEFAULTS_CONF="${TMP}/defaults.conf"
        export OFFLINE_FILES_ROOT="${TMP}/offline" CUBESTACK_RELEASE_AUTO=false
        export SSH_KEY_DIR="${TMP}/keys" SSH_KEY_NAME="fake_key"
        bash "${TOOL}" --remove
    ) 2>&1
)"; rc=$?
chk "⑦ 存在性查询失败退出码" "1" "${rc}"
chk_contains "⑦ 报 remove 查询失败" "remove 查询失败" "${out}"

echo "== ⑧ apply 查询失败不得当成'不存在' =="
# API/RBAC 抖动时 _exists 返回 2; 旧实现 `if ! _exists` 会静默跳过 patch 并退出 0。
out="$(
    (
        export PATH="${TMP}/bin-getfail:${PATH}"
        export CLUSTER_CONF="${TMP}/cluster.conf" CLUSTER_DEFAULTS_CONF="${TMP}/defaults.conf"
        export OFFLINE_FILES_ROOT="${TMP}/offline" CUBESTACK_RELEASE_AUTO=false
        export SSH_KEY_DIR="${TMP}/keys" SSH_KEY_NAME="fake_key"
        bash "${TOOL}" --apply
    ) 2>&1
)"; rc=$?
chk "⑧ apply 存在性查询失败退出码" "1" "${rc}"
chk_contains "⑧ 报 apply 查询失败" "apply 查询失败" "${out}"

echo "== ⑨ PVC 绑定查询失败 → 不当作'无绑定'放行 =="
mkdir -p "${TMP}/bin-pvcfail"
cat > "${TMP}/bin-pvcfail/ssh" <<'FAKE'
#!/bin/bash
cmd="$*"
case "${cmd}" in
    *"get pvc"*) echo "Error from server: connection refused" >&2; exit 1 ;;
    *"get deploy cubestack-operator -o json"*)
        echo '{"kind":"Deployment","spec":{"template":{"spec":{"volumes":[{"persistentVolumeClaim":{"claimName":"data-pvc"}}]}}}}' ;;
    *" -o json"*) echo '{"spec":{"template":{"spec":{}}}}' ;;
esac
exit 0
FAKE
chmod +x "${TMP}/bin-pvcfail/ssh"
printf '#!/bin/bash\nexit 0\n' > "${TMP}/bin-pvcfail/sleep"; chmod +x "${TMP}/bin-pvcfail/sleep"
out="$(
    (
        export PATH="${TMP}/bin-pvcfail:${PATH}"
        export CLUSTER_CONF="${TMP}/cluster.conf" CLUSTER_DEFAULTS_CONF="${TMP}/defaults.conf"
        export OFFLINE_FILES_ROOT="${TMP}/offline" CUBESTACK_RELEASE_AUTO=false
        export SSH_KEY_DIR="${TMP}/keys" SSH_KEY_NAME="fake_key"
        bash "${TOOL}" --apply
    ) 2>&1
)"; rc=$?
chk "⑨ PVC 绑定查询失败退出码" "1" "${rc}"
chk_contains "⑨ 报无法确认 PVC 绑定" "无法确认 PVC 绑定" "${out}"

echo "== ⑩ Redis 卷绑 worker → sentinel 同步跳过 =="
mkdir -p "${TMP}/bin-redisbind"
: > "${TMP}/redisbind.log"
cat > "${TMP}/bin-redisbind/ssh" <<'FAKE'
#!/bin/bash
cmd="$*"
case "${cmd}" in
    *"get pvc -o json"*) echo '{"items":[{"metadata":{"name":"cuberouter-redis-0"}}]}' ;;
    *"get pvc cuberouter-redis-0 -o jsonpath"*) echo "pv-redis" ;;
    *"get pv pv-redis -o json"*) echo '{"spec":{"nodeAffinity":{"required":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"kubernetes.io/hostname","values":["w1"]}]}]}}}}' ;;
    *"get node w1 -o json"*) echo '{"metadata":{"labels":{"kubernetes.io/hostname":"w1"}}}' ;;
    *" get pod "*" -o json"*) echo '{"kind":"Pod","metadata":{"name":"x"},"spec":{"volumes":[]}}' ;;
    *" patch "*) printf '%s\n' "${cmd}" >> "${FAKE_SSH_LOG:?}" ;;
    *" -o json"*) echo '{"spec":{"template":{"spec":{}}}}' ;;
esac
exit 0
FAKE
chmod +x "${TMP}/bin-redisbind/ssh"
printf '#!/bin/bash\nexit 0\n' > "${TMP}/bin-redisbind/sleep"; chmod +x "${TMP}/bin-redisbind/sleep"
out="$(
    (
        export PATH="${TMP}/bin-redisbind:${PATH}"
        export CLUSTER_CONF="${TMP}/cluster.conf" CLUSTER_DEFAULTS_CONF="${TMP}/defaults.conf"
        export OFFLINE_FILES_ROOT="${TMP}/offline" CUBESTACK_RELEASE_AUTO=false
        export SSH_KEY_DIR="${TMP}/keys" SSH_KEY_NAME="fake_key"
        export FAKE_SSH_LOG="${TMP}/redisbind.log"
        bash "${TOOL}" --apply
    ) 2>&1
)"; rc=$?
log="$(cat "${TMP}/redisbind.log")"
chk "⑩ worker-bound 跳过不阻断" "0" "${rc}"
chk_not_contains "⑩ Redis 数据副本不 patch" "patch redisreplications.redis.redis.opstreelabs.in" "${log}"
chk_contains "⑩ sentinel 同步跳过" "cuberouter-redis sentinel] PVC cuberouter-redis-0@w1" "${out}"

echo "== ⑪ remove 清理 CubeStackCluster 内持久化的组件 placement =="
mkdir -p "${TMP}/bin-csc"
: > "${TMP}/csc-patch.json"
cat > "${TMP}/bin-csc/ssh" <<'FAKE'
#!/bin/bash
cmd="$*"
case "${cmd}" in
    *"get csc -o json"*)
        echo '{"items":[{"metadata":{"name":"cubestack"},"spec":{"global":{"nodeSelector":{"node-role.kubernetes.io/control-plane":"","user-global":"keep"},"tolerations":[{"key":"user-global","operator":"Exists","effect":"NoSchedule"},{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},{"key":"node.kubernetes.io/unschedulable","operator":"Exists","effect":"NoSchedule"}]},"components":{"cubepilot":{"values":{"operator":{"nodeSelector":{"node-role.kubernetes.io/control-plane":"","user-selector":"keep"}}}},"prometheus":{"values":{"grafana":{"nodeSelector":{"node-role.kubernetes.io/control-plane":""}}}}}}}]}' ;;
    *"patch csc "*) cat > "${FAKE_PATCH_STDIN:?}"; exit 0 ;;
    *" -o json"*) echo '{"spec":{}}' ;;
esac
exit 0
FAKE
chmod +x "${TMP}/bin-csc/ssh"
out="$(
    (
        export PATH="${TMP}/bin-csc:${PATH}"
        export CLUSTER_CONF="${TMP}/cluster.conf" CLUSTER_DEFAULTS_CONF="${TMP}/defaults.conf"
        export OFFLINE_FILES_ROOT="${TMP}/offline" CUBESTACK_RELEASE_AUTO=false
        export SSH_KEY_DIR="${TMP}/keys" SSH_KEY_NAME="fake_key"
        export FAKE_PATCH_STDIN="${TMP}/csc-patch.json"
        bash "${TOOL}" --remove
    ) 2>&1
)"; rc=$?
patch_json="$(cat "${TMP}/csc-patch.json")"
chk "⑪ remove 退出码 0" "0" "${rc}"
chk_contains "⑪ 已清理 CR 组件 placement" "已移除 CR 内组件 master nodeSelector" "${out}"
chk_contains "⑪ patch 只删 control-plane key" '"node-role.kubernetes.io/control-plane":null' "${patch_json}"
chk_contains "⑪ patch 覆盖 cubepilot" '"cubepilot"' "${patch_json}"
chk_contains "⑪ patch 覆盖 grafana" '"grafana"' "${patch_json}"
chk_not_contains "⑪ 不动用户自定义 selector" 'user-selector' "${patch_json}"
chk_contains "⑪ patch 清理 global selector key" '"global":{"nodeSelector":{"node-role.kubernetes.io/control-plane":null}' "${patch_json}"
chk_contains "⑪ global 保留用户 toleration" '"key":"user-global"' "${patch_json}"
chk_not_contains "⑪ global 移除 installer toleration" '"key":"node.kubernetes.io/unschedulable"' "${patch_json}"

echo "== ⑫ apply 合并现有 tolerations(不得整体替换) =="
mkdir -p "${TMP}/bin-tol"
: > "${TMP}/tol.log"
cat > "${TMP}/bin-tol/ssh" <<'FAKE'
#!/bin/bash
cmd="$*"
case "${cmd}" in
    *"get pvc -o json"*) echo '{"items":[]}' ;;
    *" patch "*) printf '%s\n' "${cmd}" >> "${FAKE_SSH_LOG:?}" ;;
    *" -o json"*) echo '{"spec":{"nodeSelector":{"user-selector":"keep"},"tolerations":[{"key":"dedicated","operator":"Equal","value":"gpu","effect":"NoSchedule"}]}}' ;;
esac
exit 0
FAKE
chmod +x "${TMP}/bin-tol/ssh"
printf '#!/bin/bash\nexit 0\n' > "${TMP}/bin-tol/sleep"; chmod +x "${TMP}/bin-tol/sleep"
out="$(
    (
        export PATH="${TMP}/bin-tol:${PATH}"
        export CLUSTER_CONF="${TMP}/cluster.conf" CLUSTER_DEFAULTS_CONF="${TMP}/defaults.conf"
        export OFFLINE_FILES_ROOT="${TMP}/offline" CUBESTACK_RELEASE_AUTO=false
        export SSH_KEY_DIR="${TMP}/keys" SSH_KEY_NAME="fake_key"
        export FAKE_SSH_LOG="${TMP}/tol.log"
        bash "${TOOL}" --apply
    ) 2>&1
)"; rc=$?
cr_patch="$(grep -m1 'patch prometheuses.monitoring.coreos.com' "${TMP}/tol.log" || true)"
chk "⑫ apply 退出码 0" "0" "${rc}"
chk_contains "⑫ CR patch 保留已有 toleration" '"key":"dedicated"' "${cr_patch}"
chk_contains "⑫ CR patch 含 control-plane toleration" '"key":"node-role.kubernetes.io/control-plane"' "${cr_patch}"
chk_contains "⑫ CR patch 含 unschedulable toleration" '"key":"node.kubernetes.io/unschedulable"' "${cr_patch}"
chk_not_contains "⑫ CR patch 不再整体替换 tolerations" '"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},{"key":"node.kubernetes.io/unschedulable","operator":"Exists","effect":"NoSchedule"}]' "${cr_patch}"

echo "== ⑬ remove 只删 installer 的 selector key(保留用户自定义) =="
mkdir -p "${TMP}/bin-unpatch"
: > "${TMP}/unpatch.log"
cat > "${TMP}/bin-unpatch/ssh" <<'FAKE'
#!/bin/bash
cmd="$*"
case "${cmd}" in
    *" patch "*) printf '%s\n' "${cmd}" >> "${FAKE_SSH_LOG:?}" ;;
    *"get prometheuses.monitoring.coreos.com"*" -o json"*)
        echo '{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":"","user-selector":"keep"},"tolerations":[{"key":"user-taint","operator":"Exists","effect":"NoSchedule"}]}}' ;;
    *"get clusters.postgresql.cnpg.io"*" -o json"*)
        echo '{"spec":{"affinity":{"nodeSelector":{"node-role.kubernetes.io/control-plane":"","gpu-pool":"keep"}}}}' ;;
    *"get redisreplications"*" -o json"*)
        echo '{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":"","redis-user":"keep"},"sentinel":{"nodeSelector":{"node-role.kubernetes.io/control-plane":"","sent-user":"keep"}}}}' ;;
    *" -o json"*) echo '{"spec":{}}' ;;
esac
exit 0
FAKE
chmod +x "${TMP}/bin-unpatch/ssh"
out="$(
    (
        export PATH="${TMP}/bin-unpatch:${PATH}"
        export CLUSTER_CONF="${TMP}/cluster.conf" CLUSTER_DEFAULTS_CONF="${TMP}/defaults.conf"
        export OFFLINE_FILES_ROOT="${TMP}/offline" CUBESTACK_RELEASE_AUTO=false
        export SSH_KEY_DIR="${TMP}/keys" SSH_KEY_NAME="fake_key"
        export FAKE_SSH_LOG="${TMP}/unpatch.log"
        bash "${TOOL}" --remove
    ) 2>&1
)"; rc=$?
log="$(cat "${TMP}/unpatch.log")"
prom_rm="$(printf '%s\n' "${log}" | grep -m1 'patch prometheuses.monitoring.coreos.com' || true)"
cnpg_rm="$(printf '%s\n' "${log}" | grep -m1 'patch clusters.postgresql.cnpg.io' || true)"
sent_rm="$(printf '%s\n' "${log}" | grep 'patch redisreplications' | tail -1 || true)"
chk "⑬ remove 退出码 0" "0" "${rc}"
chk_contains "⑬ CR unpatch 只删 control-plane key" '{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":null}}}' "${prom_rm}"
chk_not_contains "⑬ CR unpatch 不含用户 selector" 'user-selector' "${prom_rm}"
chk_contains "⑬ CNPG unpatch 只删 control-plane key" '{"spec":{"affinity":{"nodeSelector":{"node-role.kubernetes.io/control-plane":null}}}}' "${cnpg_rm}"
chk_not_contains "⑬ CNPG unpatch 不含用户 selector" 'gpu-pool' "${cnpg_rm}"
chk_contains "⑬ sentinel unpatch 只删 control-plane key" '{"spec":{"sentinel":{"nodeSelector":{"node-role.kubernetes.io/control-plane":null}}}}' "${sent_rm}"
chk_not_contains "⑬ sentinel unpatch 不含用户 selector" 'sent-user' "${sent_rm}"

echo "== ⑭ check 查询失败不得当成'不存在' =="
mkdir -p "${TMP}/bin-checkfail"
cat > "${TMP}/bin-checkfail/ssh" <<'FAKE'
#!/bin/bash
cmd="$*"
case "${cmd}" in
    *"get deploy cubestack-operator"*) echo "Error from server: connection refused" >&2; exit 1 ;;
    *" -o json"*) echo '{"spec":{}}' ;;
esac
exit 0
FAKE
chmod +x "${TMP}/bin-checkfail/ssh"
out="$(
    (
        export PATH="${TMP}/bin-checkfail:${PATH}"
        export CLUSTER_CONF="${TMP}/cluster.conf" CLUSTER_DEFAULTS_CONF="${TMP}/defaults.conf"
        export OFFLINE_FILES_ROOT="${TMP}/offline" CUBESTACK_RELEASE_AUTO=false
        export SSH_KEY_DIR="${TMP}/keys" SSH_KEY_NAME="fake_key"
        bash "${TOOL}" --check
    ) 2>&1
)"; rc=$?
chk "⑭ check 存在性查询失败退出码" "1" "${rc}"
chk_contains "⑭ 报 check 查询失败" "check 查询失败" "${out}"

echo "== ⑮ 工作负载 JSON 读取失败 → 跳过并失败 =="
mkdir -p "${TMP}/bin-objfail"
cat > "${TMP}/bin-objfail/ssh" <<'FAKE'
#!/bin/bash
cmd="$*"
case "${cmd}" in
    *"get deploy cubestack-operator -o json"*) echo "Error from server: connection refused" >&2; exit 1 ;;
    *"get pvc -o json"*) echo '{"items":[]}' ;;
    *" -o json"*) echo '{"spec":{}}' ;;
esac
exit 0
FAKE
chmod +x "${TMP}/bin-objfail/ssh"
out="$(
    (
        export PATH="${TMP}/bin-objfail:${PATH}"
        export CLUSTER_CONF="${TMP}/cluster.conf" CLUSTER_DEFAULTS_CONF="${TMP}/defaults.conf"
        export OFFLINE_FILES_ROOT="${TMP}/offline" CUBESTACK_RELEASE_AUTO=false
        export SSH_KEY_DIR="${TMP}/keys" SSH_KEY_NAME="fake_key"
        bash "${TOOL}" --apply
    ) 2>&1
)"; rc=$?
chk "⑮ 对象 JSON 读取失败退出码" "1" "${rc}"
chk_contains "⑮ 报读取对象失败" "读取对象失败" "${out}"

echo "== ⑯ Pod 不存在但 PVC 仍绑 worker → 跳过 =="
mkdir -p "${TMP}/bin-podgone"
: > "${TMP}/podgone.log"
cat > "${TMP}/bin-podgone/ssh" <<'FAKE'
#!/bin/bash
cmd="$*"
case "${cmd}" in
    *"get pod prometheus-kube-prometheus-kube-prome-prometheus-0 -o json"*)
        echo 'Error from server (NotFound): pods "prometheus-kube-prometheus-kube-prome-prometheus-0" not found' >&2; exit 1 ;;
    *"get pvc -o json"*) echo '{"items":[{"metadata":{"name":"prometheus-kube-prometheus-kube-prome-prometheus-db-0"}}]}' ;;
    *"get pvc prometheus-kube-prometheus-kube-prome-prometheus-db-0 -o jsonpath"*) echo "pv-prom" ;;
    *"get pv pv-prom -o json"*) echo '{"spec":{"nodeAffinity":{"required":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"kubernetes.io/hostname","values":["w1"]}]}]}}}}' ;;
    *"get node w1 -o json"*) echo '{"metadata":{"labels":{"kubernetes.io/hostname":"w1"}}}' ;;
    *" patch "*) printf '%s\n' "${cmd}" >> "${FAKE_SSH_LOG:?}" ;;
    *" -o json"*) echo '{"spec":{}}' ;;
esac
exit 0
FAKE
chmod +x "${TMP}/bin-podgone/ssh"
out="$(
    (
        export PATH="${TMP}/bin-podgone:${PATH}"
        export CLUSTER_CONF="${TMP}/cluster.conf" CLUSTER_DEFAULTS_CONF="${TMP}/defaults.conf"
        export OFFLINE_FILES_ROOT="${TMP}/offline" CUBESTACK_RELEASE_AUTO=false
        export SSH_KEY_DIR="${TMP}/keys" SSH_KEY_NAME="fake_key"
        export FAKE_SSH_LOG="${TMP}/podgone.log"
        bash "${TOOL}" --apply
    ) 2>&1
)"; rc=$?
pod_log="$(cat "${TMP}/podgone.log")"
chk "⑯ Pod 不存在 + worker PVC 跳过不阻断" "0" "${rc}"
chk_contains "⑯ 告警点名 worker 绑定" "绑定在 worker" "${out}"
chk_not_contains "⑯ Prometheus 不被 patch" "patch prometheuses.monitoring.coreos.com" "${pod_log}"

echo ""
if [ "${fail}" = "0" ]; then
    echo "✅ test-cubestack-placement: 全部通过"
else
    echo "❌ test-cubestack-placement: 存在失败项"
fi
exit "${fail}"
