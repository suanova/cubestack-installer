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
#   ⑧ 无 worker(单节点): 默认 CORDON=true 自动跳过 cordon; check 期望可调度
#   ⑨ 无 worker: 本工具遗留 cordon 在 apply 时自动回滚(annotation 清除)
#   ⑩ 无 worker + 非本工具 cordon: check 报漂移(非 0)
#   ⑪ 模块 remove: placement 回滚不受当前开关门控; 失败时非 0(不降级为告警)
#   ⑫ CORDON=false 时 --apply 会 uncordon 本工具创建的 cordon(annotation 判定), 外部 cordon 不动
#   ⑬ ownership 标记删除失败: 重新 cordon 保持一致 + 非 0; 重试可收敛(apply/remove)
#   ⑭ ownership 标记写入失败: 回滚 cordon(不留下"已 cordon 但无所有权"的状态)+ 非 0
#   ⑮ annotate 已生效但返回非 0: 确认性重读后视为完成, 不创建无标记 cordon
#   ⑯ 配置了 worker 但 NotReady/已 cordon/读取失败: 视为无可用 worker, 跳过 master cordon
#   ⑰ ownership 判定锚定 key 左边界: 相似 key(example.cubestack.io/...)不算本工具标记
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
            if [ "${FAKE_UNSCHED_READ_FAIL:-0}" = "1" ] && [ "${h}" = "w1" ]; then exit 1; fi
            cat "${st}/${h}.unschedulable" 2>/dev/null || true
        elif [[ "$*" == *".metadata.annotations"* ]]; then
            ann=""; [ -s "${st}/${h}.annotations" ] && ann="$(sed 's/^/"/; s/=/":"/; s/$/"/' "${st}/${h}.annotations" | paste -sd, -)"
            echo "{${ann}}"
        elif [[ "$*" == *"--no-headers"* ]]; then
            if [ "${FAKE_WORKER_NOTREADY:-0}" = "1" ] && [ "${h}" = "w1" ]; then
                echo "${h} NotReady <none> 1m v1.35.8"
            else
                echo "${h} Ready <none> 1m v1.35.8"
            fi
        fi
        ;;
    label)
        h="${args[2]:-}"; kv="${args[3]:-}"; _set_label "$h" "$kv"; echo "node/${h} labeled" ;;
    annotate)
        h="${args[2]:-}"; kv="${args[3]:-}"
        if [[ "$kv" == *- && "${FAKE_ANNOTATE_DEL_FAIL:-0}" = "1" ]]; then exit 1; fi
        if [[ "$kv" != *- && "${FAKE_ANNOTATE_SET_FAIL:-0}" = "1" ]]; then exit 1; fi
        # 模拟"远端已删除成功, 但 SSH/命令返回非 0"(连接中断等)
        if [[ "$kv" == *- && "${FAKE_ANNOTATE_DEL_FAIL_AFTER:-0}" = "1" ]]; then
            _set_ann "$h" "$kv"; exit 1
        fi
        _set_ann "$h" "$kv"; echo "node/${h} annotated" ;;
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
cat > "${TMP}/cluster.conf.single" <<'EOF'
NODES=(
  "master,m1,10.0.0.1,root,-"
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

echo "== ④b remove 不看当前 CORDON 配置: annotation 在就 uncordon =="
_reset
_run -- --apply >/dev/null
out="$(_run NODE_POOL_MASTER_CORDON=false -- --remove)"
chk "remove(false) 退出码 0" "0" "$?"
chk "m1 已 uncordon(当前配置 false 也回滚)" "false" "$(_unsched m1)"
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

echo "== ⑧ 无 worker(单节点): 默认 CORDON=true 自动跳过 cordon =="
_reset
out="$(CLUSTER_CONF="${TMP}/cluster.conf.single" _run -- --apply)"
chk "退出码 0" "0" "$?"
chk_contains "m1 标签" "node-pool=control-plane" "$(_label m1)"
chk "m1 未 cordon" "" "$(_unsched m1)"
chk_contains "提示无 worker 跳过" "跳过 cordon" "${out}"
chk_contains "汇总 0 台 worker" "0 台 worker" "${out}"
out="$(CLUSTER_CONF="${TMP}/cluster.conf.single" _run -- --check)"
chk "check 通过(期望可调度)" "0" "$?"

echo "== ⑨ 无 worker: 本工具遗留 cordon 在 apply 时自动回滚 =="
_reset
echo true > "${TMP}/state/m1.unschedulable"
echo "cubestack.io/node-pool-cordoned-by-installer=true" > "${TMP}/state/m1.annotations"
out="$(CLUSTER_CONF="${TMP}/cluster.conf.single" _run -- --apply)"
chk "退出码 0" "0" "$?"
chk "m1 已 uncordon" "false" "$(_unsched m1)"
chk "annotation 已清" "" "$(_ann m1)"
chk_contains "提示回滚" "回滚本工具" "${out}"

echo "== ⑩ 无 worker + 非本工具 cordon: check 报漂移 =="
_reset
CLUSTER_CONF="${TMP}/cluster.conf.single" _run -- --apply >/dev/null
echo true > "${TMP}/state/m1.unschedulable"   # 模拟外部 cordon(无 annotation)
out="$(CLUSTER_CONF="${TMP}/cluster.conf.single" _run -- --check)"
chk "check 非 0" "1" "$?"
chk_contains "点名 m1" "m1" "${out}"
chk_contains "说明被 cordon" "cordon" "${out}"

echo "== ⑪ 模块 remove 分支: placement 回滚不受当前开关影响 =="
MODULE53="${REPO_ROOT}/deployments/scripts/modules/03_addon/53_node_pool.sh"
_rm_block="$(sed -n '/^if \[ "\${_ACTION}" = "remove" \]; then$/,/^    exit 0$/p' "${MODULE53}")"
[ -n "${_rm_block}" ] && echo "  ok  remove 分支已提取" || { echo "  FAIL 未提取到 remove 分支"; fail=1; }
chk_contains "调用 cubestack-placement --remove" 'cubestack-placement.sh" --remove' "${_rm_block}"
chk_contains "调用 master-placement --remove" 'master-placement.sh" --remove' "${_rm_block}"
chk_not_contains "不受 CUBESTACK_PLACEMENT 开关门控" "NODE_POOL_CUBESTACK_PLACEMENT" "${_rm_block}"
chk_not_contains "不受 PLATFORM_PLACEMENT 开关门控" "NODE_POOL_PLATFORM_PLACEMENT" "${_rm_block}"
chk_contains "记录 placement 回滚失败" "_rm_failed=1" "${_rm_block}"
chk_contains "失败时非 0 退出" "placement 移除存在失败项" "${_rm_block}"
chk_not_contains "placement 失败不降级为告警" "placement 回滚失败(不阻断)" "${_rm_block}"

echo "== ⑫ CORDON=false 时 --apply 回滚本工具创建的 cordon(不动外部 cordon) =="
_reset
_run -- --apply >/dev/null                       # 默认 true: m1/m2 cordon + annotation
chk "前置: m1 已 cordon" "true" "$(_unsched m1)"
out="$(_run NODE_POOL_MASTER_CORDON=false -- --apply)"
chk "CORDON=false 退出码 0" "0" "$?"
chk "m1 已 uncordon" "false" "$(_unsched m1)"
chk "m1 annotation 已清" "" "$(_ann m1)"
chk "m2 已 uncordon" "false" "$(_unsched m2)"
chk_contains "提示按 CORDON=false 回滚" "CORDON=false" "${out}"

_reset
echo true > "${TMP}/state/m1.unschedulable"      # 外部 cordon(无 annotation)
out="$(_run NODE_POOL_MASTER_CORDON=false -- --apply)"
chk "外部 cordon 保持不动" "true" "$(_unsched m1)"
chk_contains "外部 cordon 只告警" "非本工具创建" "${out}"

echo "== ⑬ ownership 标记删除失败: 重新 cordon 保持一致, 重试可收敛 =="
_reset
_run -- --apply >/dev/null                       # 默认 true: m1/m2 cordon + annotation
out="$(FAKE_ANNOTATE_DEL_FAIL=1 _run NODE_POOL_MASTER_CORDON=false -- --apply)"
chk "标记删除失败退出码非 0" "1" "$?"
chk "m1 重新 cordon(保持一致)" "true" "$(_unsched m1)"
chk_contains "标记仍在" "cubestack.io/node-pool-cordoned-by-installer=true" "$(_ann m1)"
chk_contains "报标记仍在" "ownership 标记仍在" "${out}"
chk_contains "说明已重新 cordon" "重新 cordon" "${out}"
out="$(_run NODE_POOL_MASTER_CORDON=false -- --apply)"
chk "重试退出码 0" "0" "$?"
chk "重试后 m1 已 uncordon" "false" "$(_unsched m1)"
chk "重试后标记已清" "" "$(_ann m1)"

# remove 路径同样: 标记删不掉 → 重新 cordon + 非 0; 重试可收敛
_reset
_run -- --apply >/dev/null
out="$(FAKE_ANNOTATE_DEL_FAIL=1 _run -- --remove)"
chk "remove 标记删除失败退出码非 0" "1" "$?"
chk "remove 失败后节点重新 cordon" "true" "$(_unsched m1)"
out="$(_run -- --remove)"
chk "remove 重试退出码 0" "0" "$?"
chk "remove 重试后已 uncordon" "false" "$(_unsched m1)"
chk "remove 重试后标记已清" "" "$(_ann m1)"

echo "== ⑭ ownership 标记写入失败: 回滚 cordon(不留'已 cordon 但无所有权'状态) =="
_reset
out="$(FAKE_ANNOTATE_SET_FAIL=1 _run -- --apply)"
chk "标记写入失败退出码非 0" "1" "$?"
chk "m1 已回滚 uncordon" "false" "$(_unsched m1)"
chk "无 ownership 标记" "" "$(_ann m1)"
chk_contains "报标记写入失败" "标记写入失败" "${out}"

echo "== ⑮ annotate 已生效但返回非 0: 复核确认后视为完成(不产生无标记 cordon) =="
_reset
_run -- --apply >/dev/null                       # 先 cordon + annotation
out="$(FAKE_ANNOTATE_DEL_FAIL_AFTER=1 _run NODE_POOL_MASTER_CORDON=false -- --apply)"
chk "⑮ 退出码 0(复核确认标记已清)" "0" "$?"
chk "⑮ m1 已 uncordon" "false" "$(_unsched m1)"
chk "⑮ 标记已清" "" "$(_ann m1)"
chk_contains "⑮ 提示复核确认生效" "复核确认生效" "${out}"

echo "== ⑯ 配置了 worker 但不可用(NotReady/已 cordon): 同样跳过 master cordon =="
_reset
out="$(FAKE_WORKER_NOTREADY=1 _run -- --apply)"
chk "⑯ NotReady 退出码 0" "0" "$?"
chk "⑯ NotReady 时 m1 未 cordon" "" "$(_unsched m1)"
chk_contains "⑯ 点名 worker 不可用" "worker w1 不可用" "${out}"
chk_contains "⑯ 说明跳过 cordon" "跳过 cordon" "${out}"

_reset
echo true > "${TMP}/state/w1.unschedulable"      # worker 被 cordon
out="$(_run -- --apply)"
chk "⑯ worker cordon 退出码 0" "0" "$?"
chk "⑯ worker cordon 时 m1 未 cordon" "" "$(_unsched m1)"
chk_contains "⑯ 提示 worker 已 cordon" "已 cordon" "${out}"

# spec.unschedulable 读取失败: 空输出 ≠ 未 cordon, 必须按不可用处理(否则可能 cordon 掉
# 最后一个可调度节点, 击穿 CoreDNS 护栏)
_reset
out="$(FAKE_UNSCHED_READ_FAIL=1 _run -- --apply)"
chk "⑯ 读取失败退出码 0" "0" "$?"
chk "⑯ 读取失败时 m1 未 cordon" "" "$(_unsched m1)"
chk_contains "⑯ 点名读取失败" "spec.unschedulable 读取失败" "${out}"

echo "== ⑰ ownership 判定锚定 key 左边界: 相似 key 不算本工具标记 =="
# 端到端: 节点被 cordon, annotation 只有相似 key(example.cubestack.io/...), --remove 不得 uncordon
_reset
echo true > "${TMP}/state/m1.unschedulable"
echo "example.cubestack.io/node-pool-cordoned-by-installer=true" > "${TMP}/state/m1.annotations"
out="$(_run -- --remove)"
chk "⑰ 退出码 0" "0" "$?"
chk "⑰ 相似 key 不触发 uncordon" "true" "$(_unsched m1)"
chk_contains "⑰ 告警非本工具" "非本工具创建" "${out}"
chk_contains "⑰ 相似 key 保留" "example.cubestack.io/node-pool-cordoned-by-installer=true" "$(_ann m1)"
# 函数级: map[...](旧/test 形态)与 JSON(当前 kubectl 形态)两种输出都要锚定左边界
eval "$(sed -n '/^_np_owned() {/,/^}/p' "${TOOL}")"
_owned_rc() { if _np_owned "$1"; then echo 0; else echo 1; fi; }
chk "⑰ map 形态: 首项本工具 key" "0" "$(_owned_rc 'map[cubestack.io/node-pool-cordoned-by-installer:true]')"
chk "⑰ map 形态: 非首项本工具 key" "0" "$(_owned_rc 'map[a:b cubestack.io/node-pool-cordoned-by-installer:true]')"
chk "⑰ map 形态: 相似 key" "1" "$(_owned_rc 'map[example.cubestack.io/node-pool-cordoned-by-installer:true]')"
chk "⑰ map 形态: 非首项相似 key" "1" "$(_owned_rc 'map[a:b example.cubestack.io/node-pool-cordoned-by-installer:true]')"
chk "⑰ JSON 形态: 本工具 key" "0" "$(_owned_rc '{"cubestack.io/node-pool-cordoned-by-installer":"true"}')"
chk "⑰ JSON 形态: 相似 key" "1" "$(_owned_rc '{"example.cubestack.io/node-pool-cordoned-by-installer":"true"}')"

echo ""
if [ "${fail}" = "0" ]; then
    echo "✅ test-node-pool: 全部通过"
else
    echo "❌ test-node-pool: 存在失败项"
fi
exit "${fail}"
