#!/bin/bash
# ============================================================
# test-cubestack-component-steps.sh — 平台组件级 step 的离线回归
# 目标(2026-10-19 用户口径):
#   · 默认全量部署仍由 cubestack_operator 负责全部组件;
#   · 集群/operator 就绪后, --steps lws / --steps cube-pilot 只更新指定组件,
#     **不重跑 cubestack_operator**。
# 覆盖:
#   ① 13 个组件模块存在且元数据正确(DEFAULT:0 / REPEAT:1 / 无 TOGGLE / 不 REQUIRES operator)
#   ② 组件工具只推该组件 + patch CR + 滚动组件; 不含 helm upgrade / 不调用 operator 模块
#   ③ --steps lws / --steps cube-pilot 的调度计划只有该组件(基座/operator 不执行)
#   ④ 连字符别名(cube-pilot/envoy-gateway/...)生效
# 用法: bash deployments/scripts/tools/tests/test-cubestack-component-steps.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
MODDIR="${REPO_ROOT}/deployments/scripts/modules/03_addon"
TOOL="${REPO_ROOT}/deployments/scripts/tools/k8s/cubestack-component-update.sh"
LIBM="${REPO_ROOT}/deployments/scripts/lib-module.sh"
DEPLOY="${REPO_ROOT}/deployments/scripts/deploy-cluster.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  ok  $1"; else echo "  FAIL $1: [$3] 未包含 [$2]"; fail=1; fi; }
chk_not_contains() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  FAIL $1: [$3] 不应包含 [$2]"; fail=1; else echo "  ok  $1"; fi; }

# 期望: step 文件名|MODULE key|工具参数
EXPECT=(
  "40_cubestack_lws.sh|lws|lws"
  "41_cubestack_envoy_gateway.sh|envoy_gateway|envoy_gateway"
  "42_cubestack_ai_gateway.sh|ai_gateway|ai_gateway"
  "43_cubestack_controller_manager.sh|cubestack_controller_manager|cubestack_controller_manager"
  "44_cubestack_model_bundles.sh|model_bundles|model_bundles"
  "45_cubestack_prometheus.sh|prometheus|prometheus"
  "46_cubestack_perses.sh|perses|perses"
  "47_cubestack_bmc.sh|bmc|bmc"
  "48_cubestack_metax.sh|metax|metax"
  "49_cubestack_cuberouter.sh|cuberouter|cuberouter"
  "50_cubestack_cubepilot.sh|cubepilot|cubepilot"
  "51_cubestack_portal.sh|cubestack_portal|cubestack_portal"
  "52_cubestack_observability.sh|observability|observability"
)

echo "== ① 13 个组件模块 =="
for row in "${EXPECT[@]}"; do
    IFS='|' read -r f key arg <<< "${row}"
    p="${MODDIR}/${f}"
    if [ ! -f "${p}" ]; then echo "  FAIL 缺少模块 ${f}"; fail=1; continue; fi
    chk_contains "${key}: MODULE 头" "# MODULE: ${key}" "${p}"
    chk_contains "${key}: DEFAULT:0" "# DEFAULT: 0" "${p}"
    chk_contains "${key}: REPEAT:1" "# REPEAT: 1" "${p}"
    chk_not_contains "${key}: 无 TOGGLE 元数据" "# TOGGLE:" "${p}"
    if grep -qE '^#[[:space:]]*REQUIRES:.*cubestack_operator' "${p}"; then
        echo "  FAIL ${key}: 不应 REQUIRES cubestack_operator(会重跑整个 operator)"; fail=1
    else
        echo "  ok  ${key}: 不依赖 cubestack_operator 模块"
    fi
    chk_contains "${key}: 调用共享工具" "cubestack-component-update.sh\" \"${arg}\"" "${p}"
done

echo "== ② 共享工具静态围栏 =="
[ -f "${TOOL}" ] && echo "  ok  工具存在" || { echo "  FAIL 工具不存在"; fail=1; }
chk_contains "组件映射 envoyGateway" '_cr="envoyGateway"' "${TOOL}"
chk_contains "组件映射 cubestackPortal" '_cr="cubestackPortal"' "${TOOL}"
chk_contains "config digest 幂等" "image_config_digest_raw" "${TOOL}"
chk_contains "IMAGE_PUSH 参数" "image_push_args_init" "${TOOL}"
chk_contains "CR patch stdin" "--patch-file=/dev/stdin" "${TOOL}"
chk_contains "组件标签" "cubestack.io/component=" "${TOOL}"
chk_contains "组件滚动" "rollout restart" "${TOOL}"
chk_contains "Deployment 列表用 --no-headers" 'get deploy -A -l cubestack.io/component=${_catalog} --no-headers' "${TOOL}"
chk_not_contains "不用远端 jsonpath(引号会被远端 shell 吃掉)" "jsonpath='{range .items[*]}" "${TOOL}"
chk_contains "rollout restart 不吞 while stdin" 'rollout restart deploy/${_dn}" </dev/null' "${TOOL}"
chk_contains "RWO 单卷策略守护" 'ensure_rwo_deployments_recreate "${NS}" "cubestack.io/component=${_catalog}"' "${TOOL}"
chk_contains "enabled 覆盖" "CUBESTACK_COMPONENT_ENABLED" "${TOOL}"
chk_contains "model-bundles 列表覆盖" "CUBESTACK_COMPONENT_BUNDLES" "${TOOL}"
# 非注释行不得出现 helm upgrade / 调用 operator 模块
if grep -vE '^[[:space:]]*#' "${TOOL}" | grep -qE '(^|[[:space:]])helm[[:space:]]+upgrade|25_cubestack_operator\.sh'; then
    echo "  FAIL 工具不得执行 helm upgrade 或调用 25_cubestack_operator.sh"; fail=1
else
    echo "  ok  工具不执行 helm upgrade / 不调用 operator 模块"
fi

echo "== ③ 调度计划: --steps lws / --steps cube-pilot =="
cat > "${TMP}/cluster.conf" <<'EOF'
NODES=("master,m1,10.0.0.1,root,-")
SSH_USER="root"
KUBESPRAY_PROFILE="none"
CUBESTACK_OPERATOR_ENABLED="true"
EOF
_run_plan() {  # <step> → 本次执行模块 行
    CLUSTER_CONF="${TMP}/cluster.conf" bash "${DEPLOY}" --steps "$1" --list 2>&1 \
        | sed -n 's/^[[:space:]]*本次执行模块:[[:space:]]*//p' | head -1
}
chk "lws 计划" "lws" "$(_run_plan lws)"
chk "cube-pilot 别名计划" "cubepilot" "$(_run_plan cube-pilot)"
chk "envoy-gateway 别名计划" "envoy_gateway" "$(_run_plan envoy-gateway)"

echo "== ④ 别名表 =="
chk_contains "cube-pilot 别名" "[cube-pilot]=cubepilot" "${LIBM}"
chk_contains "envoy-gateway 别名" "[envoy-gateway]=envoy_gateway" "${LIBM}"
chk_contains "cubestack-portal 别名" "[cubestack-portal]=cubestack_portal" "${LIBM}"

echo "== ⑤ RWO 单卷策略守护逻辑(stub) =="
_LIB="${REPO_ROOT}/deployments/scripts/lib-common.sh"
chk_contains "RWO patch 走 --patch-file=/dev/stdin(避免远端 shell 吞 JSON)" '--patch-file=/dev/stdin' "${_LIB}"
sed -n '/^ensure_rwo_deployments_recreate()/,/^}/p' "${_LIB}" > "${TMP}/helper.sh"
if [ -s "${TMP}/helper.sh" ]; then
    cat > "${TMP}/run-helper.sh" <<'EOS'
say(){ echo "SAY:$*"; }; ok(){ echo "OK:$*"; }; warn(){ echo "WARN:$*"; }
K="kubectl"
JSON='{"items":[
 {"kind":"Deployment","metadata":{"namespace":"ns","name":"app"},"spec":{"strategy":{"type":"RollingUpdate"},"template":{"spec":{"volumes":[{"persistentVolumeClaim":{"claimName":"data"}}]}}}},
 {"kind":"PersistentVolumeClaim","metadata":{"namespace":"ns","name":"data"},"spec":{"accessModes":["ReadWriteOnce"]}},
 {"kind":"Deployment","metadata":{"namespace":"ns","name":"app2"},"spec":{"strategy":{"type":"RollingUpdate"},"template":{"spec":{"volumes":[{"persistentVolumeClaim":{"claimName":"data2"}}]}}}},
 {"kind":"PersistentVolumeClaim","metadata":{"namespace":"ns","name":"data2"},"spec":{"accessModes":["ReadWriteOnce"]}},
 {"kind":"Deployment","metadata":{"namespace":"ns","name":"rwx"},"spec":{"strategy":{"type":"RollingUpdate"},"template":{"spec":{"volumes":[{"persistentVolumeClaim":{"claimName":"shared"}}]}}}},
 {"kind":"PersistentVolumeClaim","metadata":{"namespace":"ns","name":"shared"},"spec":{"accessModes":["ReadWriteMany"]}},
 {"kind":"Deployment","metadata":{"namespace":"ns","name":"done"},"spec":{"strategy":{"type":"Recreate"},"template":{"spec":{"volumes":[{"persistentVolumeClaim":{"claimName":"data"}}]}}}}
]}'
# patch 分支故意读 stdin: 若实现没加 </dev/null, 会吞掉 while 的 here-string,
# 第二个 RWO Deployment 就不会被处理(2026-10-19 实测 bug)。
SSH(){ case "$*" in *" get "*) printf '%s' "$JSON";; *" patch "*) cat >/dev/null; return 0;; esac; }
source "$1"
ensure_rwo_deployments_recreate ns 'cubestack.io/managed-by=cubestack-operator' 0
EOS
    _out="$(bash "${TMP}/run-helper.sh" "${TMP}/helper.sh" 2>&1 || true)"
    case "${_out}" in *"ns/app"*) echo "  ok  RWO Deployment 被纠正";; *) echo "  FAIL RWO Deployment 未纠正: ${_out}"; fail=1;; esac
    case "${_out}" in *"ns/app2"*) echo "  ok  第二个 RWO Deployment 也被纠正(ssh 未吞 stdin)";; *) echo "  FAIL 第二个 RWO Deployment 未纠正(ssh 吞了 while stdin?)"; fail=1;; esac
    case "${_out}" in *"ns/rwx"*) echo "  FAIL RWX Deployment 不应被纠正"; fail=1;; *) echo "  ok  RWX Deployment 不动";; esac
    case "${_out}" in *"ns/done"*) echo "  FAIL 已是 Recreate 的 Deployment 不应重复 patch"; fail=1;; *) echo "  ok  已是 Recreate 的重跑幂等";; esac
else
    echo "  FAIL 未能从 lib-common.sh 提取 ensure_rwo_deployments_recreate"; fail=1
fi

echo ""
if [ "${fail}" = "0" ]; then
    echo "✅ test-cubestack-component-steps: 全部通过"
else
    echo "❌ test-cubestack-component-steps: 存在失败项"
fi
exit "${fail}"
