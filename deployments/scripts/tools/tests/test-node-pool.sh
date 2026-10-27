#!/bin/bash
# ============================================================
# test-node-pool.sh — node_pool 基础工具(master 标签 + 可选 cordon)回归
#
# 背景(2026-10-27): 需要 master 保持 Unschedulable=True(SchedulingDisabled), 但
#   Ceph/operator 等平台 Pod 通过 nodeSelector + special toleration
#   (node.kubernetes.io/unschedulable:NoSchedule)仍能调度到 master。
#   本工具只负责节点侧标签/cordon 的幂等 apply/check/remove, 不 patch 工作负载。
#
# 覆盖:
#   ① apply: master 打 node-pool=control-plane + cordon + 标记 annotation; worker 不动
#   ② 幂等: 重复 apply 不重复改/不报错
#   ③ check: 期望态通过; 标签缺失/cordon 丢失 → 非 0
#   ④ remove: 只移除本工具打的标签/本工具创建的 cordon(annotation 判定)
#   ⑤ 预存 cordon(无 annotation): apply 不抢 ownership; remove 不 uncordon
#   ⑥ --only 只处理指定节点; NODE_POOL_MASTER_CORDON=false 只打标签不 cordon
#   ⑦ 无 master → 非 0
#
# 隔离: 假 ssh 执行假 kubectl, 节点标签/cordon/annotation 落临时状态目录。
# 用法: bash deployments/scripts/tools/tests/test-node-pool.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TOOL="${REPO_ROOT}/deployments/scripts/tools/node/node-pool.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if [[ "$3" == *"$2"* ]]; then echo "  ok  $1"; else echo "  FAIL $1: 未包含 [$2]"; fail=1; fi; }
chk_not_contains() { if [[ "$3" != *"$2"* ]]; then echo "  ok  $1"; else echo "  FAIL $1: 不应包含 [$2]"; fail=1; fi; }

mkdir -p "${TMP}/bin" "${TMP}/state" "${TMP}/keys" "${TMP}/offline"
: > "${TMP}/keys/fake_key"
: > "${TMP}/defaults.conf"
: > "${TMP}/kubectl.log"

# ---------------- 假 ssh: 取最后一个参数作为远端命令, 本地执行(假 kubectl 在 PATH 前) ----------------
cat > "${TMP}/bin/ssh" <<'FAKE'
#!/bin/bash
# 找到 user@host 参数; 之后的参数按空格拼接成远端命令(与真实 ssh 行为一致)
seen=0; cmd=""
for a in "$@"; do
    if [ "${seen}" = "0" ]; then
        case "$a" in *@*) seen=1 ;; esac
    else
        cmd="${cmd}${cmd:+ }${a}"
    fi
done
PATH="${FAKE_BIN}:${PATH}" /bin/bash -c "${cmd}"
FAKE
chmod +x "${TMP}/bin/ssh"

# ---------------- 假 sudo: 透传(不真正提权) ----------------
cat > "${TMP}/bin/sudo" <<'FAKE'
#!/bin/bash
exec "$@"
FAKE
chmod +x "${TMP}/bin/sudo"

# ---------------- 假 kubectl: 用 state 目录模拟 node label/cordon/annotation ----------------
cat > "${TMP}/bin/kubectl" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "${FAKE_KUBECTL_LOG:?}"
args=()
for a in "$@"; do
    case "$a" in
        --kubeconfig=*|--overwrite|-*) ;;
        *) args+=("$a") ;;
    esac
done
cmd="${args[0]:-}"
st="${FAKE_STATE:?}"
_set_label() { local h="$1" kv="$2"; local f="${st}/${h}.labels"; touch "$f"; if [[ "$kv" == *- ]]; then local k="${kv%-}"; grep -v "^${k}=" "$f" > "${f}.tmp" || true; mv "${f}.tmp" "$f"; else local k="${kv%%=*}"; local v="${kv#*=}"; grep -v "^${k}=" "$f" > "${f}.tmp" || true; echo "${k}=${v}" >> "${f}.tmp"; mv "${f}.tmp" "$f"; fi; }
_set_ann() { local h="$1" kv="$2"; local f="${st}/${h}.annotations"; touch "$f"; if [[ "$kv" == *- ]]; then local k="${kv%-}"; grep -v "^${k}=" "$f" > "${f}.tmp" || true; mv "${f}.tmp" "$f"; else local k="${kv%%=*}"; local v="${kv#*=}"; grep -v "^${k}=" "$f" > "${f}.tmp" || true; echo "${k}=${v}" >> "${f}.tmp"; mv "${f}.tmp" "$f"; fi; }
case "$cmd" in
    get)
        h="${args[2]:-}"
        if [[ "$*" == *"--show-labels"* ]]; then
            labs="kubernetes.io/hostname=${h}"
            if [ -s "${st}/${h}.labels" ]; then labs="${labs},$(paste -sd, "${st}/${h}.labels")"; fi
            echo "${h} Ready control-plane 1m v1.35.8 ${labs}"
        elif [[ "$*" == *".spec.unschedulable"* ]]; then
            cat "${st}/${h}.unschedulable" 2>/dev/null || true
        elif [[ "$*" == *".metadata.annotations"* ]]; then
            ann=""; [ -s "${st}/${h}.annotations" ] && ann="$(sed 's/^/"/; s/=/":"/; s/$/"/' "${st}/${h}.annotations" | paste -sd, -)"
            echo "{${ann}}"
        fi
        ;;
    label)
        h="${args[2]:-}"; kv="${args[3]:-}"; _set_label "$h" "$kv"; echo "node/${h} labeled" ;;
    annotate)
        h="${args[2]:-}"; kv="${args[3]:-}"; _set_ann "$h" "$kv"; echo "node/${h} annotated" ;;
    cordon)
        h="${args[1]:-}"; echo true > "${st}/${h}.unschedulable"; echo "node/${h} cordoned" ;;
    uncordon)
        h="${args[1]:-}"; echo false > "${st}/${h}.unschedulable"; echo "node/${h} uncordoned" ;;
    *) : ;;
esac
exit 0
FAKE
chmod +x "${TMP}/bin/kubectl"

cat > "${TMP}/cluster.conf" <<'EOF'
NODES=(
  "master,m1,10.0.0.1,root,-"
  "master,m2,10.0.0.2,root,-"
  "worker,w1,10.0.0.3,root,-"
)
SSH_USER="root"
KUBESPRAY_PROFILE="none"
EOF
cat > "${TMP}/cluster.conf.nomaster" <<'EOF'
NODES=(
  "worker,w1,10.0.0.3,root,-"
)
SSH_USER="root"
KUBESPRAY_PROFILE="none"
EOF

_reset() {
    rm -f "${TMP}/state"/*
    : > "${TMP}/kubectl.log"
}
_run() {   # _run <env...> -- <tool args...>
    local envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    (
        export PATH="${TMP}/bin:${PATH}"
        export CLUSTER_CONF="${CLUSTER_CONF:-${TMP}/cluster.conf}"
        export CLUSTER_DEFAULTS_CONF="${TMP}/defaults.conf"
        export OFFLINE_FILES_ROOT="${TMP}/offline"
        export CUBESTACK_RELEASE_AUTO=false
        export SSH_KEY_DIR="${TMP}/keys"
        export SSH_KEY_NAME="fake_key"
        export FAKE_BIN="${TMP}/bin"
        export FAKE_STATE="${TMP}/state"
        export FAKE_KUBECTL_LOG="${TMP}/kubectl.log"
        export NODE_POOL_MASTER_CORDON="${NODE_POOL_MASTER_CORDON:-true}"
        export NODE_POOL_MASTER_LABEL="${NODE_POOL_MASTER_LABEL:-node-pool=control-plane}"
        env "${envs[@]}" bash "${TOOL}" "$@"
    ) 2>&1
}
_label() { cat "${TMP}/state/$1.labels" 2>/dev/null || true; }
_unsched() { cat "${TMP}/state/$1.unschedulable" 2>/dev/null || true; }
_ann() { cat "${TMP}/state/$1.annotations" 2>/dev/null || true; }

echo "== ① apply: master 标签 + cordon + annotation; worker 不动 =="
_reset
out="$(_run -- --apply)"
chk "退出码 0" "0" "$?"
chk_contains "m1 标签" "node-pool=control-plane" "$(_label m1)"
chk "m1 cordon" "true" "$(_unsched m1)"
chk_contains "m1 ownership annotation" "cubestack.io/node-pool-cordoned-by-installer=true" "$(_ann m1)"
chk_contains "m2 标签" "node-pool=control-plane" "$(_label m2)"
chk "w1 未打标签" "" "$(_label w1)"
chk "w1 未 cordon" "" "$(_unsched w1)"
chk_contains "汇总" "2 台 master" "${out}"

echo "== ② 幂等 =="
: > "${TMP}/kubectl.log"
out="$(_run -- --apply)"
chk "退出码 0" "0" "$?"
chk_not_contains "重复 apply 不重新 cordon" "cordon m1" "$(cat "${TMP}/kubectl.log")"

echo "== ③ check: 期望态通过 / 漂移失败 =="
out="$(_run -- --check)"
chk "check 通过" "0" "$?"
# 去掉 m1 标签 + uncordon m2
rm -f "${TMP}/state/m1.labels"; echo false > "${TMP}/state/m2.unschedulable"
out="$(_run -- --check)"
chk "check 漂移非 0" "1" "$?"
chk_contains "点名 m1 标签" "m1" "${out}"

echo "== ④ remove: 移除本工具标签/未 cordon =="
_reset
_run -- --apply >/dev/null
out="$(_run -- --remove)"
chk "remove 退出码 0" "0" "$?"
chk "m1 标签已删" "" "$(_label m1)"
chk_contains "m1 标签删除命令" "node-pool-" "$(cat "${TMP}/kubectl.log")"
chk "m1 已 uncordon" "false" "$(_unsched m1)"
chk "m1 annotation 已删" "" "$(_ann m1)"

echo "== ⑤ 预存 cordon(无 annotation): 不抢 ownership, remove 不 uncordon =="
_reset
echo true > "${TMP}/state/m1.unschedulable"
out="$(_run -- --apply)"
chk "apply 退出码 0" "0" "$?"
chk "预存 cordon 无 annotation" "" "$(_ann m1)"
chk_contains "提示非本工具 cordon" "非本工具" "${out}"
out="$(_run -- --remove)"
chk "remove 退出码 0" "0" "$?"
chk "预存 cordon 保持 true" "true" "$(_unsched m1)"
chk_contains "提示不 uncordon" "不 uncordon" "${out}"

echo "== ⑥ --only / 不 cordon 模式 =="
_reset
out="$(_run -- --apply --only m1)"
chk "--only 退出码 0" "0" "$?"
chk_contains "m1 标签" "node-pool=control-plane" "$(_label m1)"
chk "m2 未动" "" "$(_label m2)"
_reset
out="$(_run NODE_POOL_MASTER_CORDON=false -- --apply)"
chk "不 cordon 退出码 0" "0" "$?"
chk_contains "m1 标签仍在" "node-pool=control-plane" "$(_label m1)"
chk "m1 未 cordon" "" "$(_unsched m1)"

echo "== ⑦ 无 master → 非 0 =="
_reset
out="$(CLUSTER_CONF="${TMP}/cluster.conf.nomaster" _run -- --apply)"
chk "无 master 非 0" "1" "$?"
chk_contains "明确报错" "master" "${out}"

echo ""
if [ "${fail}" = "0" ]; then
    echo "✅ test-node-pool: 全部通过"
else
    echo "❌ test-node-pool: 存在失败项"
fi
exit "${fail}"
