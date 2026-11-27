#!/bin/bash
# ============================================================
# test-deploy-enable-deploy.sh — --enable 启用+立即部署 / --list-steps 组件清单
#
# 背景(2026-11-27 用户定案):
#   ① --enable k1,k2 不再"只写 cluster.conf 不部署", 而是**启用并加入本次部署计划**
#      (同时保留持久化); --skip 仍只管本次排除, 冲突时 skip 优先。
#   ② GPU Operator 模块统一 <vendor>_gpu 命名: gpu_operator → metax_gpu,
#      nvidia_gpu_operator → nvidia_gpu; 旧名保留为别名。
#   ③ --list-steps 列出全部组件(开关变量/当前值/别名/伪代码占位标记)。
#
# 隔离: 纯 --list / --list-steps 只读路径 + 临时 cluster.conf; 不连集群、不需要 root。
# 用法: bash deployments/scripts/tools/tests/test-deploy-enable-deploy.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
DEPLOY="${REPO_ROOT}/deployments/scripts/deploy-cluster.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$3] 实际[$2]"; fail=1; fi; }
chk_contains() { if [[ "$3" == *"$2"* ]]; then echo "  ok  $1"; else echo "  FAIL $1: 未包含 [$2]"; fail=1; fi; }
chk_not_contains() { if [[ "$3" != *"$2"* ]]; then echo "  ok  $1"; else echo "  FAIL $1: 不应包含 [$2]"; fail=1; fi; }
# 计划行里的模块按空格分词精确匹配(避免 nvidia_gpu 命中 nvidia_gpu_operator)
chk_plan_module() {  # chk_plan_module <desc> <output> <key> [expect=1]
    local desc="$1" out="$2" key="$3" expect="${4:-1}" hit=0
    printf '%s\n' "${out}" | sed -n 's/^.*本次执行模块: //p' | tr ' ' '\n' | grep -qx "${key}" && hit=1
    if [ "${hit}" = "${expect}" ]; then echo "  ok  ${desc}"; else echo "  FAIL ${desc}: 计划(${expect}=期望)未匹配 ${key}"; fail=1; fi
}
# --list-steps 模块行(行首两空格 + key + 空白)
chk_list_module() {  # chk_list_module <desc> <output> <key>
    if printf '%s\n' "$2" | grep -qE "^  $3([[:space:]]|$)"; then echo "  ok  $1"; else echo "  FAIL $1: 列表无模块行 ${3}"; fail=1; fi
}

# 最小配置: 旧开关名 GPU_OPERATOR_ENABLED=true(验证兼容映射), NVIDIA/MULTUS 关闭
CONF="${TMP}/cluster.conf"
cat > "${CONF}" <<'EOF'
NODES=("master,m1,10.0.0.1,root,-")
SSH_DEFAULT_PASSWORD="dummy"
CLUSTER_NAME="unit-test"
CEPH_MODE=none
GPU_OPERATOR_ENABLED=true
NVIDIA_GPU_OPERATOR_ENABLED=false
MULTUS_ENABLED=false
NETSHOOT_ENABLED=false
EOF

run_deploy() {  # run_deploy <args...>
    CLUSTER_CONF="${CONF}" bash "${DEPLOY}" "$@" 2>&1
}

echo "== ① --enable 参与本次部署计划(--list 预览, 只读) =="
before="$(sha256sum "${CONF}" | awk '{print $1}')"
out="$(run_deploy --enable nvidia_gpu --list)"
after="$(sha256sum "${CONF}" | awk '{print $1}')"
chk "预览不写 cluster.conf" "${before}" "${after}"
chk_plan_module "--enable nvidia_gpu 加入计划" "${out}" "nvidia_gpu"
chk_contains "输出不再是'只写配置'提示" "本次执行模块" "${out}"

echo "== ② --steps + --enable 合并(精确模式不再丢弃 enable) =="
out="$(run_deploy --steps ceph --enable metax_gpu --list)"
chk_plan_module "计划含显式 --steps ceph" "${out}" "ceph"
chk_plan_module "计划含 --enable metax_gpu" "${out}" "metax_gpu"

echo "== ③ --skip 优先于 --enable(并告警) =="
out="$(run_deploy --enable nvidia_gpu --skip nvidia_gpu --list)"
chk_plan_module "冲突时计划不含 nvidia_gpu" "${out}" "nvidia_gpu" 0
chk_contains "冲突有告警" "skip" "${out}"

echo "== ④ GPU 模块新命名 + 旧别名 =="
out="$(run_deploy --steps gpu_operator --list)"
chk_plan_module "旧别名 gpu_operator → metax_gpu" "${out}" "metax_gpu"
chk_plan_module "计划不再出现旧 key" "${out}" "gpu_operator" 0
out="$(run_deploy --steps nvidia_gpu_operator --list)"
chk_plan_module "旧别名 nvidia_gpu_operator → nvidia_gpu" "${out}" "nvidia_gpu"
chk_plan_module "计划不再出现旧 key(nvidia)" "${out}" "nvidia_gpu_operator" 0
out="$(run_deploy --list)"
chk_plan_module "旧开关 GPU_OPERATOR_ENABLED=true 仍调度 metax_gpu" "${out}" "metax_gpu"

echo "== ⑤ 无开关模块不触发部署 =="
out="$(run_deploy --enable verify_metallb)"
chk_not_contains "verify 模块不产生部署计划" "本次执行模块" "${out}"
chk_contains "提示无法持久化/改用 --steps" "--steps" "${out}"

echo "== ⑥ --list-steps 完整组件清单 =="
out="$(run_deploy --list-steps)"
chk_list_module "列出 metax_gpu" "${out}" "metax_gpu"
chk_list_module "列出 nvidia_gpu" "${out}" "nvidia_gpu"
chk_contains "标注旧别名" "别名:gpu_operator" "${out}"
chk_contains "紧凑状态显示 toggle(on/off)" "toggle(" "${out}"
chk_contains "有可启用组件汇总段" "[可启用组件]" "${out}"
chk_contains "汇总含运维类仅 --steps 组件" "ceph_backup" "${out}"
if printf '%s\n' "${out}" | grep -qE '^  keycloak .*\*'; then echo "  ok  伪代码占位有标记"; else echo "  FAIL 伪代码占位有标记(keycloak 行无 *)"; fail=1; fi
out="$(run_deploy --list-steps --verbose)"
chk_contains "verbose 显示新开关名" "METAX_GPU_ENABLED" "${out}"
chk_contains "verbose 显示旧开关名(兼容声明)" "GPU_OPERATOR_ENABLED" "${out}"

echo "== ⑦ --skip 未知模块必须报错(防拼写错误静默不生效) =="
out="$(run_deploy --skip no_such_component --list)"
rc=$?
chk "未知 --skip 退出码非0" "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)" "1"
chk_contains "提示未知模块" "未知模块" "${out}"

echo "== ⑧ 旧 state 键迁移(gpu_operator → metax_gpu) =="
mkdir -p "${TMP}/state"
cat > "${TMP}/state/.deploy.state" <<'EOF'
gpu_operator=done
nvidia_gpu_operator=done
EOF
out="$(
    set +u
    source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
    source "${REPO_ROOT}/deployments/scripts/lib-module.sh" >/dev/null 2>&1
    STATE_FILE="${TMP}/state/.deploy.state"
    printf 'metax_gpu=%s\nnvidia_gpu=%s\n' "$(module_get_state metax_gpu)" "$(module_get_state nvidia_gpu)"
)"
chk_contains "旧 gpu_operator 状态可读" "metax_gpu=done" "${out}"
chk_contains "旧 nvidia_gpu_operator 状态可读" "nvidia_gpu=done" "${out}"

[ "${fail}" = "0" ] && echo "✅ test-deploy-enable-deploy: 全部通过" || { echo "❌ 有失败项"; exit 1; }
