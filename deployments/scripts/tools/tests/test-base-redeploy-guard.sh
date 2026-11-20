#!/bin/bash
# ============================================================
# test-base-redeploy-guard.sh — 已有集群上重装基座必须显式 --fresh(issue #205)
# 覆盖:
#   ① 无集群 → 不拦
#   ② k8s_deploy 已完成 → 不拦(断点续跑不会执行基座)
#   ③ 集群存在 + 基座未完成 + --fresh → 放行
#   ④ 集群存在 + 基座未完成 + 无 --fresh → 拦停(--yes 不授权 reset)
# 隔离: 纯函数 + 桩 get_state/cluster_exists; 不连集群
# 用法: bash deployments/scripts/tools/tests/test-base-redeploy-guard.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
DEPLOY="${REPO_ROOT}/deployments/scripts/deploy-cluster.sh"
OFFLINE="${REPO_ROOT}/deployments/kubespray/cubestack-offline.sh"
LIB="${REPO_ROOT}/deployments/scripts/lib-module.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if [[ "$3" == *"$2"* ]]; then echo "  ok  $1"; else echo "  FAIL $1: 未包含 [$2]"; fail=1; fi; }

# 在子 shell 中 source 两个库, 再覆盖探测函数
run_guard() {  # run_guard <state> <cluster 0|1> <fresh 0|1>
    local _state="$1" _cluster="$2" _fresh="$3"
    (
        set +u
        # shellcheck source=../../lib-common.sh
        source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
        # shellcheck source=../../lib-module.sh
        source "${REPO_ROOT}/deployments/scripts/lib-module.sh" >/dev/null 2>&1
        get_state() { printf '%s' "${_state}"; }
        cluster_exists() { [ "${_cluster}" = "1" ]; }
        FRESH="${_fresh}"
        RUN_STEPS=(k8s_deploy)
        base_redeploy_needs_fresh
        echo $?
    )
}

# --steps <组件> 的计划不含 k8s_deploy: 即便集群存在也不能拦
run_step_only() {
    (
        set +u
        source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
        source "${REPO_ROOT}/deployments/scripts/lib-module.sh" >/dev/null 2>&1
        get_state() { printf 'pending'; }
        cluster_exists() { return 0; }
        FRESH=0
        RUN_STEPS=(ceph ceph_csi)
        base_redeploy_needs_fresh
        echo $?
    )
}

# 守卫探测失败、teardown 探测成功: 无 --fresh 时必须拒绝且不调用 teardown 脚本
run_teardown_probe() {
    (
        set +u
        source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
        source "${REPO_ROOT}/deployments/scripts/lib-module.sh" >/dev/null 2>&1
        SCRIPT_DIR="${TMP}"
        mkdir -p "${TMP}/tools/k8s"
        cat > "${TMP}/tools/k8s/cluster-teardown.sh" <<'EOS'
#!/bin/bash
echo called > "${FAKE_TEARDOWN_LOG}"
EOS
        chmod +x "${TMP}/tools/k8s/cluster-teardown.sh"
        export FAKE_TEARDOWN_LOG="${TMP}/teardown-called.log"
        rm -f "${FAKE_TEARDOWN_LOG}"
        get_state() { printf 'pending'; }
        _calls=0
        cluster_exists() { _calls=$((_calls + 1)); [ "${_calls}" -ge 2 ]; }
        FRESH=0
        RUN_STEPS=(k8s_deploy)
        base_redeploy_needs_fresh || true   # 第一次探测失败 → 入口放行
        teardown_before_overwrite           # 第二次探测成功 → 必须拒绝
    )
}

# run_module: 入口探测失败、notify 探测成功 → 必须中止且不执行模块脚本
run_module_probe() {
    (
        set +u
        source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
        source "${REPO_ROOT}/deployments/scripts/lib-module.sh" >/dev/null 2>&1
        SCRIPT_DIR="${TMP}"
        mkdir -p "${TMP}/mods" "${TMP}/tools/k8s"
        cat > "${TMP}/mods/fake.sh" <<'EOS'
#!/bin/bash
echo called > "${FAKE_MODULE_LOG}"
EOS
        chmod +x "${TMP}/mods/fake.sh"
        cat > "${TMP}/tools/k8s/cluster-teardown.sh" <<'EOS'
#!/bin/bash
echo called > "${FAKE_TEARDOWN_LOG}"
EOS
        chmod +x "${TMP}/tools/k8s/cluster-teardown.sh"
        export FAKE_MODULE_LOG="${TMP}/module-called.log"
        export FAKE_TEARDOWN_LOG="${TMP}/teardown-called2.log"
        rm -f "${FAKE_MODULE_LOG}" "${FAKE_TEARDOWN_LOG}"
        MODULES_DIR="${TMP}/mods"
        MODULE_KEY=(k8s_deploy)
        MODULE_DESC=("fake")
        MODULE_SCRIPT=(fake.sh)
        MODULE_DEFAULT=(0)
        MODULE_REPEAT=(0)
        MODULE_PHASE=(k8s)
        MODULE_TOGGLE=("")
        MODULE_REQUIRES=("")
        get_state() { printf 'pending'; }
        _calls=0
        cluster_exists() { _calls=$((_calls + 1)); [ "${_calls}" -ge 2 ]; }
        FRESH=0
        RUN_STEPS=(k8s_deploy)
        run_module k8s_deploy
    )
}

echo "== ① 无集群 =="
chk "首次部署不拦" "1" "$(run_guard '' 0 0)"

echo "== ② k8s_deploy 已完成 =="
chk "断点续跑不拦" "1" "$(run_guard done 1 0)"

echo "== ③ 显式 --fresh =="
chk "已有集群 + 未完成 + --fresh 放行" "1" "$(run_guard pending 1 1)"

echo "== ④ 无 --fresh =="
chk "已有集群 + 未完成 + 仅 --yes 拦停" "0" "$(run_guard pending 1 0)"
chk "无 state 文件的新容器同样拦停" "0" "$(run_guard '' 1 0)"
chk "只装组件的计划不含基座 → 不拦" "1" "$(run_step_only)"

echo "== ⑤ deploy-cluster 接线 =="
deploy_txt="$(cat "${DEPLOY}" 2>/dev/null)"
chk_contains "调用 base_redeploy_needs_fresh" "base_redeploy_needs_fresh" "${deploy_txt}"
chk_contains "错误提示指向 --fresh" "加 --fresh 重跑" "${deploy_txt}"
chk_contains "错误提示指向 --steps" "--steps <组件>" "${deploy_txt}"
chk_contains "导出 reset 守卫" "CUBESTACK_RESET_GUARD=1" "${deploy_txt}"
chk_contains "--fresh 导出 reset 授权" "CUBESTACK_ALLOW_K8S_RESET=1" "${deploy_txt}"
offline_txt="$(cat "${OFFLINE}" 2>/dev/null)"
chk_contains "kubespray reset 检查授权" "CUBESTACK_ALLOW_K8S_RESET" "${offline_txt}"
chk_contains "无授权时提示 --fresh" "没有显式 --fresh 授权 reset" "${offline_txt}"
chk_contains "scale 新节点清理不受守卫" '[ "${scope}" != "new" ]' "${offline_txt}"
chk "kubespray reset 不豁免交互 TTY" "0" "$(printf '%s\n' "${offline_txt}" | grep -A3 'CUBESTACK_RESET_GUARD:-0' | grep -c '\[ ! -t 0 \]')"
chk_contains "cmd_reset 也检查授权" "reset 被 deploy-cluster 的重置守卫拒绝" "${offline_txt}"
lib_txt="$(cat "${LIB}" 2>/dev/null)"
chk_contains "run_module 执行点拦停" 'if [ "${key}" = "k8s_deploy" ] && base_redeploy_needs_fresh' "${lib_txt}"
chk_contains "run_module 处理 notify 失败" 'if [ "${key}" = "k8s_deploy" ] && ! notify_base_redeploy' "${lib_txt}"
chk_contains "优雅卸载前检查 --fresh" "拒绝覆盖卸载" "${deploy_txt}"
chk_contains "teardown 钩子检查 --fresh" "拒绝优雅卸载" "${lib_txt}"

echo "== ⑥ cmd_reset 入口守卫 =="
cat > "${TMP}/cluster.conf.reset" <<'EOF'
NODES=("master,m1,10.0.0.1,root,-")
CLUSTER_NAME="dummy"
EOF
# 伪造 kubespray 树 + 可用 venv: 守卫若回归, ensure_venv 会激活它并跑到 stub ansible
mkdir -p "${TMP}/kubespray/.venv/bin"
cat > "${TMP}/kubespray/.venv/bin/activate" <<EOS
export PATH="${TMP}/kubespray/.venv/bin:\${PATH}"
EOS
printf '#!/bin/bash\nexit 0\n' > "${TMP}/kubespray/.venv/bin/python"
cat > "${TMP}/kubespray/.venv/bin/ansible-playbook" <<'EOS'
#!/bin/bash
echo called > "${FAKE_ANSIBLE_LOG}"
EOS
chmod +x "${TMP}/kubespray/.venv/bin/python" "${TMP}/kubespray/.venv/bin/ansible-playbook"
rm -f "${TMP}/ansible-called.log"
set +e
_reset_out="$(env -u CUBESTACK_ALLOW_K8S_RESET -u CUBESTACK_ASSUME_YES \
    CLUSTER_CONF="${TMP}/cluster.conf.reset" CUBESTACK_RESET_GUARD=1 \
    CUBESTACK_KUBESPRAY_DIR="${TMP}/kubespray" \
    FAKE_ANSIBLE_LOG="${TMP}/ansible-called.log" \
    timeout 30 bash "${OFFLINE}" reset dummy --yes 2>&1)"
_reset_rc=$?
set -e
chk "无授权的 reset 退出码" "1" "${_reset_rc}"
chk_contains "reset 被守卫拒绝" "重置守卫拒绝" "${_reset_out}"
chk "reset.yml 未执行" "0" "$([ -f "${TMP}/ansible-called.log" ] && echo 1 || echo 0)"

echo "== ⑦ 守卫探测失败后 teardown 探测成功 =="
set +e
_td_out="$(run_teardown_probe 2>&1)"
_td_rc=$?
set -e
chk "teardown 探测成功但无 --fresh 时退出非 0" "1" "${_td_rc}"
chk_contains "拒绝优雅卸载" "拒绝优雅卸载" "${_td_out}"
chk "未调用 teardown 脚本" "0" "$([ -f "${TMP}/teardown-called.log" ] && echo 1 || echo 0)"

echo "== ⑧ run_module: 探测失败后 notify 成功 =="
set +e
_rm_out="$(run_module_probe 2>&1)"
_rm_rc=$?
set -e
chk "run_module 中止(非 0)" "1" "${_rm_rc}"
chk_contains "notify 拒绝重装" "没有 --fresh 授权" "${_rm_out}"
chk "未执行 k8s_deploy 模块脚本" "0" "$([ -f "${TMP}/module-called.log" ] && echo 1 || echo 0)"

[ "${fail}" = "0" ] && echo "✅ test-base-redeploy-guard: 全部通过" || { echo "❌ 有失败项"; exit 1; }
