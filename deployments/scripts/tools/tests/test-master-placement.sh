#!/bin/bash
# ============================================================
# test-master-placement.sh — 系统组件 master placement 工具回归
#
# 背景(2026-10-27 节点池): master cordon 后, CoreDNS/metrics-server/dns-autoscaler/
#   calico-kube-controllers/registry/MetalLB controller 等 Deployment/ReplicaSet 必须
#   带 node-role.kubernetes.io/control-plane nodeSelector + control-plane/unschedulable
#   tolerations; MetalLB speaker 是 DaemonSet, 只需 toleration(全节点)。
#
# 覆盖:
#   ① 工具存在且声明 apply/check/remove
#   ② 覆盖预期 workload 名称
#   ③ patch 含 master nodeSelector + 两个 toleration key
#   ④ speaker 只加 toleration(不加 master nodeSelector)
#   ⑤ apply 对每个 workload 发出 patch 命令(假 ssh)
#   ⑥ check 精确校验 nodeSelector + 双 toleration(control-plane/unschedulable)
#   ⑦ remove 只处理确实带 master selector 的对象(未应用过时不 patch/不重建 registry Pod);
#      remove patch 失败 → 非 0(不得降级为 warning)
#   ⑧ apply/remove 的 registry Pod 删除失败 → 非 0(不得误报"已删除")
#
# 隔离: 假 ssh 记录远端命令; 不连集群。
# 用法: bash deployments/scripts/tools/tests/test-master-placement.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TOOL="${REPO_ROOT}/deployments/scripts/tools/k8s/master-placement.sh"
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
    for w in coredns metrics-server dns-autoscaler calico-kube-controllers registry; do
        chk_contains "workload ${w}" "${w}" "${src}"
    done
    chk_contains "metallb controller" "metallb-system" "${src}"
    chk_contains "metallb speaker" "speaker" "${src}"

    echo "== ③ master nodeSelector + tolerations =="
    chk_contains "control-plane selector key" "node-role.kubernetes.io/control-plane" "${src}"
    chk_contains "unschedulable toleration key" "node.kubernetes.io/unschedulable" "${src}"

    echo "== ④ speaker 只加 toleration =="
    # speaker patch 变量不应包含 nodeSelector 的 control-plane 键
    if grep -q '_DS_PATCH=' "${TOOL}"; then
        ds_line="$(grep '_DS_PATCH=' "${TOOL}" | head -1)"
        chk_contains "speaker patch toleration" "node.kubernetes.io/unschedulable" "${ds_line}"
        if [[ "${ds_line}" == *nodeSelector* ]]; then
            echo "  FAIL speaker patch 不应带 nodeSelector"; fail=1
        else
            echo "  ok  speaker patch 无 nodeSelector"
        fi
    else
        echo "  FAIL 缺少 _DS_PATCH"; fail=1
    fi
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
case "${cmd}" in
    *"delete pod"*) [ "${FAKE_DELETE_FAIL:-0}" = "1" ] && exit 1 ;;
esac
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
    for w in coredns metrics-server dns-autoscaler calico-kube-controllers; do
        chk_contains "apply patch ${w}" "patch deploy ${w}" "${log}" || true
    done
    chk_contains "apply patch registry" "patch rs registry" "${log}"
    chk_contains "registry pod recreate" "delete pod -l k8s-app=registry" "${log}"
    chk_contains "apply patch metallb controller" "patch deploy controller" "${log}"
    chk_contains "apply patch metallb speaker" "patch ds speaker" "${log}"
    chk_contains "apply toleration" "node.kubernetes.io/unschedulable" "${log}"
else
    echo "  FAIL 无法执行 apply(tool missing)"; fail=1
fi

echo "== ⑥ check 精确校验 nodeSelector(不得被 toleration 假阳性) =="
# 2026-10-27 容器 c 实测: 只有 tolerations、没有 nodeSelector 时旧 --check 仍报 OK。
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
{"spec":{"template":{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":""},"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},{"key":"node.kubernetes.io/unschedulable","operator":"Exists","effect":"NoSchedule"}]}}}}
EOF
# 缺 control-plane toleration(只有 unschedulable): master 的 control-plane taint 仍会挡住 Pod
cat > "${TMP}/dep-miss-cp.json" <<'EOF'
{"spec":{"template":{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":""},"tolerations":[{"key":"node.kubernetes.io/unschedulable","operator":"Exists","effect":"NoSchedule"}]}}}}
EOF
out="$(run_check "${TMP}/dep-no-sel.json" 2>&1)"; rc=$?
chk "⑥ 仅 toleration 无 nodeSelector → check 失败" "1" "${rc}"
chk_contains "⑥ 报 placement 不完整" "placement 不完整" "${out}"
out="$(run_check "${TMP}/dep-ok.json" 2>&1)"; rc=$?
chk "⑥ selector+双 toleration → check 通过" "0" "${rc}"
out="$(run_check "${TMP}/dep-miss-cp.json" 2>&1)"; rc=$?
chk "⑥ 缺 control-plane toleration → check 失败" "1" "${rc}"

echo "== ⑦ remove: 只处理确实带 master selector 的对象(registry 不白重启) =="
mkdir -p "${TMP}/bin-remove" "${TMP}/json-none" "${TMP}/json-sel"
cat > "${TMP}/bin-remove/ssh" <<'FAKE'
#!/bin/bash
cmd="$*"
printf '%s\n' "${cmd}" >> "${FAKE_SSH_LOG:?}"
case "${cmd}" in
    *" patch "*) [ "${FAKE_PATCH_FAIL:-0}" = "1" ] && exit 1 ;;
    *" delete pod"*) [ "${FAKE_DELETE_FAIL:-0}" = "1" ] && exit 1 ;;
    *" -o json"*)
        name="$(printf '%s\n' "${cmd}" | awk '{for(i=1;i<=NF;i++) if($i=="get"){print $(i+2); exit}}')"
        f="${FAKE_JSON_DIR}/${name}.json"
        [ -f "$f" ] && cat "$f"
        ;;
esac
exit 0
FAKE
chmod +x "${TMP}/bin-remove/ssh"
cat > "${TMP}/json-sel/coredns.json" <<'EOF'
{"spec":{"template":{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":""}}}}}
EOF
cat > "${TMP}/json-sel/registry.json" <<'EOF'
{"spec":{"template":{"spec":{}}}}
EOF
run_remove() {   # <json dir> → 输出; ssh 日志在 $TMP/ssh-remove.log
    : > "${TMP}/ssh-remove.log"
    (
        export PATH="${TMP}/bin-remove:${PATH}"
        export CLUSTER_CONF="${TMP}/cluster.conf" CLUSTER_DEFAULTS_CONF="${TMP}/defaults.conf"
        export OFFLINE_FILES_ROOT="${TMP}/offline" CUBESTACK_RELEASE_AUTO=false
        export SSH_KEY_DIR="${TMP}/keys" SSH_KEY_NAME="fake_key"
        export FAKE_SSH_LOG="${TMP}/ssh-remove.log"
        export FAKE_JSON_DIR="$1"
        bash "${TOOL}" --remove
    ) 2>&1
}
out="$(run_remove "${TMP}/json-sel")"; rc=$?
chk "⑦ remove 退出码" "0" "${rc}"
chk_contains "⑦ 带 selector 的 coredns 被移除" "patch deploy coredns" "$(cat "${TMP}/ssh-remove.log")"
chk_not_contains "⑦ 无 selector 的 registry 不 patch" "patch rs registry" "$(cat "${TMP}/ssh-remove.log")"
chk_not_contains "⑦ 无 selector 时不重建 registry Pod" "delete pod" "$(cat "${TMP}/ssh-remove.log")"
out="$(run_remove "${TMP}/json-none")"; rc=$?
chk "⑦ 全无 selector 退出码" "0" "${rc}"
chk_not_contains "⑦ 全无 selector 时不发 patch" "patch " "$(cat "${TMP}/ssh-remove.log")"
cat > "${TMP}/json-sel/registry.json" <<'EOF'
{"spec":{"template":{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":""}}}}}
EOF
out="$(run_remove "${TMP}/json-sel")"; rc=$?
chk "⑦ registry 带 selector 退出码" "0" "${rc}"
chk_contains "⑦ registry 带 selector 时移除" "patch rs registry" "$(cat "${TMP}/ssh-remove.log")"
chk_contains "⑦ registry 带 selector 时重建 Pod" "delete pod -l k8s-app=registry" "$(cat "${TMP}/ssh-remove.log")"
export FAKE_PATCH_FAIL=1
out="$(run_remove "${TMP}/json-sel")"; rc=$?
unset FAKE_PATCH_FAIL
chk "⑦ remove patch 失败退出码非 0" "1" "${rc}"
chk_contains "⑦ 报 remove patch 失败" "remove patch 失败" "${out}"
export FAKE_DELETE_FAIL=1
out="$(run_remove "${TMP}/json-sel")"; rc=$?
unset FAKE_DELETE_FAIL
chk "⑦ remove 删 Pod 失败退出码非 0" "1" "${rc}"
chk_contains "⑦ remove 报删除旧 Pod 失败" "删除旧 Pod 失败" "${out}"

echo "== ⑧ apply: registry Pod 删除失败 → 非 0(不得误报已删除) =="
out="$(
    (
        export PATH="${TMP}/bin:${PATH}"
        export CLUSTER_CONF="${TMP}/cluster.conf" CLUSTER_DEFAULTS_CONF="${TMP}/defaults.conf"
        export OFFLINE_FILES_ROOT="${TMP}/offline" CUBESTACK_RELEASE_AUTO=false
        export SSH_KEY_DIR="${TMP}/keys" SSH_KEY_NAME="fake_key"
        export FAKE_SSH_LOG="${TMP}/ssh.log"
        export FAKE_DELETE_FAIL=1
        bash "${TOOL}" --apply
    ) 2>&1
)"; rc=$?
chk "⑧ delete Pod 失败退出码非 0" "1" "${rc}"
chk_contains "⑧ 报删除旧 Pod 失败" "删除旧 Pod 失败" "${out}"
chk_not_contains "⑧ 不误报已删除" "已删除旧 Pod" "${out}"

echo ""
if [ "${fail}" = "0" ]; then
    echo "✅ test-master-placement: 全部通过"
else
    echo "❌ test-master-placement: 存在失败项"
fi
exit "${fail}"
