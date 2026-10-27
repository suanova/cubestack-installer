#!/bin/bash
# ============================================================
# test-node-net-guard.sh — 节点源策略路由 / Calico rpfilter 冲突预检回归
#
# 背景(2026-10-27 实机 worker05/08, 带 IB 的 g1 机器):
#   主机镜像 netplan 自带 `routing-policy: from <IB> lookup <table>`; Calico 给本地 Pod 的
#   设备路由没有 preferred source, 内核按接口枚举顺序选到 IB 地址作源。Pod 回包到达宿主机
#   cali 网卡后, Calico raw 表 rpfilter 反向校验用回包目的地址(IB)查路由 → 命中 IB 表 →
#   出接口(IB)≠入接口(cali) → DROP; 表现为 kubelet 探针 context deadline exceeded、
#   coredns/metallb/metrics-server 0/1 无限重启。
#
# 覆盖:
#   ① 风险节点(IB 源策略路由 + 反向路径分歧)被识别; 安全节点不误报
#   ② 原生修复开启(CALICO_USE_DEFAULT_ROUTE_SRC_IPADDR=true)时只告警、不写主机规则
#   ③ 原生修复关闭时 --check 硬失败并给指引
#   ④ --apply-rule: 幂等加 pref/to <KUBE_PODS_SUBNET> lookup main + systemd 持久化;
#      不写 service CIDR; 重复执行不重复; 网段变化时清理旧规则
#   ⑤ --remove 清理规则/unit/conf; SSH 不可达时点名失败节点
#   ⑥ CIDR 从 KUBE_PODS_SUBNET 动态读取(夹具用 10.244.0.0/16 反证不硬编码 10.233)
#
# 隔离: 假 ssh 把远端载荷在本机执行; 假 ip 按节点夹具返回路由查询结果;
#       绝对路径(/etc/cubestack, /usr/local/sbin, /etc/systemd/system)重写到临时根。
# 用法: bash deployments/scripts/tools/tests/test-node-net-guard.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TOOL="${REPO_ROOT}/deployments/scripts/tools/node/node-net-guard.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if [[ "$3" == *"$2"* ]]; then echo "  ok  $1"; else echo "  FAIL $1: 未包含 [$2]"; fail=1; fi; }
chk_not_contains() { if [[ "$3" != *"$2"* ]]; then echo "  ok  $1"; else echo "  FAIL $1: 不应包含 [$2]"; fail=1; fi; }

mkdir -p "${TMP}/bin" "${TMP}/keys" "${TMP}/ip" "${TMP}/root/etc/cubestack" \
         "${TMP}/root/usr/local/sbin" "${TMP}/root/etc/systemd/system" "${TMP}/offline"
: > "${TMP}/keys/fake_key"
: > "${TMP}/ip/state"
: > "${TMP}/ip/log"
: > "${TMP}/systemctl.log"

# ---------------- 假 ssh: 读 stdin 载荷 → 路径重写到临时根 → 本地执行 ----------------
cat > "${TMP}/bin/ssh" <<'FAKE'
#!/bin/bash
ip=""
for a in "$@"; do case "$a" in *@*) ip="${a#*@}" ;; esac; done
[ -n "${FAKE_FAIL_IP:-}" ] && [ "$ip" = "${FAKE_FAIL_IP}" ] && exit 255
tmp="$(mktemp)"
cat > "${tmp}"
sed -e "s#/etc/cubestack#${FAKE_ROOT}/etc/cubestack#g" \
    -e "s#/usr/local/sbin#${FAKE_ROOT}/usr/local/sbin#g" \
    -e "s#/etc/systemd/system#${FAKE_ROOT}/etc/systemd/system#g" \
    "${tmp}" > "${tmp}.run"
FAKE_CURRENT_NODE_IP="${ip}" PATH="${FAKE_BIN}:${PATH}" /bin/bash "${tmp}.run"
rc=$?
rm -f "${tmp}" "${tmp}.run"
exit "${rc}"
FAKE
chmod +x "${TMP}/bin/ssh"

# ---------------- 假 ip: 夹具驱动 route get / addr show / rule add|del|show ----------------
cat > "${TMP}/bin/ip" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "${FAKE_IP_LOG:?}"
node="${FAKE_CURRENT_NODE_IP:?}"
want=""
for a in "$@"; do
    case "$a" in
        addr|rule|route) want="$a"; break ;;
    esac
done
case "${want}" in
    addr)
        cat "${FAKE_IP_DIR}/${node}.addrs" 2>/dev/null || true
        exit 0 ;;
    rule)
        shift_add=0
        for a in "$@"; do [ "$a" = "add" ] && shift_add=1; done
        state="${FAKE_IP_STATE:?}.${node}"
        [ -f "${state}" ] || : > "${state}"
        if [ "${shift_add}" = "1" ]; then
            pref="" to="" table=""
            args=("$@")
            for ((i=0;i<${#args[@]};i++)); do
                case "${args[$i]}" in
                    pref) pref="${args[$((i+1))]}" ;;
                    to)   to="${args[$((i+1))]}" ;;
                    lookup) table="${args[$((i+1))]}" ;;
                esac
            done
            echo "RULE_ADD|${pref}|${to}|${table}" >> "${FAKE_IP_LOG}"
            if [ "${FAKE_RULE_ADD_FAIL:-0}" = "1" ]; then
                echo "RULE_ADD_FAIL|${pref}|${to}|${table}" >> "${FAKE_IP_LOG}"
                exit 1
            fi
            if ! command grep -qxF "${pref}|${to}|${table}" "${state}" 2>/dev/null; then
                echo "${pref}|${to}|${table}" >> "${state}"
            fi
            exit 0
        fi
        for a in "$@"; do
            if [ "$a" = "del" ]; then
                pref="" to="" table=""
                args=("$@")
                for ((i=0;i<${#args[@]};i++)); do
                    case "${args[$i]}" in
                        pref) pref="${args[$((i+1))]}" ;;
                        to)   to="${args[$((i+1))]}" ;;
                        lookup) table="${args[$((i+1))]}" ;;
                    esac
                done
                echo "RULE_DEL|${pref}|${to}|${table}" >> "${FAKE_IP_LOG}"
                command grep -vxF "${pref}|${to}|${table}" "${state}" > "${state}.tmp" 2>/dev/null || true
                mv "${state}.tmp" "${state}"
                exit 0
            fi
        done
        # show: 基础规则 + 节点夹具的源策略路由 + 本节点已加的规则
        echo "0:	from all lookup local"
        cat "${FAKE_IP_DIR}/${node}.rules" 2>/dev/null || true
        echo "32766:	from all lookup main"
        echo "32767:	from all lookup default"
        if [ -s "${state}" ]; then
            while IFS='|' read -r p t tab; do
                [ -n "${p}" ] || continue
                echo "${p}:	from all to ${t} lookup ${tab}"
            done < "${state}"
        fi
        exit 0 ;;
    route)
        from="*"
        args=("$@")
        for ((i=0;i<${#args[@]};i++)); do
            [ "${args[$i]}" = "from" ] && from="${args[$((i+1))]}"
        done
        line="$(command grep -F "${from}|" "${FAKE_IP_DIR}/${node}.routes" 2>/dev/null | head -1 || true)"
        if [ -z "${line}" ]; then
            line="$(command grep -F '*|' "${FAKE_IP_DIR}/${node}.routes" 2>/dev/null | head -1 || true)"
        fi
        [ -n "${line}" ] || exit 1
        rc="${line#*|}"; rc="${rc%%|*}"
        out="${line#*|*|}"
        printf '%s\n' "${out}"
        exit "${rc}" ;;
esac
exit 0
FAKE
chmod +x "${TMP}/bin/ip"

# ---------------- 假 systemctl: 只记录, 恒成功(真实 systemd 行为不在本夹具范围) ----------------
cat > "${TMP}/bin/systemctl" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "${FAKE_SYSTEMCTL_LOG:?}"
exit 0
FAKE
chmod +x "${TMP}/bin/systemctl"

# ---------------- 节点夹具 ----------------
# 10.0.0.1 = 风险节点(IB 先枚举 + from IB 策略路由); 10.0.0.2 = 安全节点
cat > "${TMP}/ip/10.0.0.1.addrs" <<'EOF'
2: ens1np0    inet 172.16.1.104/24 brd 172.16.1.255 scope global ens1np0
3: eno1       inet 10.0.0.1/24 brd 10.0.0.255 scope global eno1
EOF
cat > "${TMP}/ip/10.0.0.2.addrs" <<'EOF'
2: eno1       inet 10.0.0.2/24 brd 10.0.0.255 scope global eno1
EOF
cat > "${TMP}/ip/10.0.0.1.routes" <<'EOF'
10.0.0.1|0|10.233.64.1 from 10.0.0.1 dev cali src 10.0.0.1
172.16.1.104|0|10.233.64.1 from 172.16.1.104 via 172.16.1.1 dev ens1np0 table 150
*|0|10.233.64.1 dev cali src 10.0.0.1
EOF
cat > "${TMP}/ip/10.0.0.2.routes" <<'EOF'
10.0.0.2|0|10.233.64.1 from 10.0.0.2 dev cali src 10.0.0.2
*|0|10.233.64.1 dev cali src 10.0.0.2
EOF
# 安全节点上仍保留一条源策略路由(模拟"临时 ip rule 把分歧掩盖掉"或规则本身不覆盖 Pod 网段):
# 反向路径探测无分歧, 但 preflight 应通过源策略路由指纹给出告警而不是完全沉默。
cat > "${TMP}/ip/10.0.0.2.rules" <<'EOF'
32761:	from 172.16.1.104 lookup 150
EOF

# 测试用 cluster.conf / defaults
cat > "${TMP}/cluster.conf" <<'EOF'
NODES=(
    "master,m1,10.0.0.1,root,-"
    "worker,w1,10.0.0.2,root,-"
)
SSH_USER="root"
SSH_DEFAULT_PASSWORD=""
EOF
: > "${TMP}/defaults.conf"

# 每个用例重置 host-rule 状态
_reset_rule_state() {
    rm -f "${TMP}/ip"/state.*
    : > "${TMP}/ip/log"
    : > "${TMP}/systemctl.log"
    rm -rf "${TMP}/root/etc/cubestack" "${TMP}/root/usr/local/sbin" "${TMP}/root/etc/systemd/system"
    mkdir -p "${TMP}/root/etc/cubestack" "${TMP}/root/usr/local/sbin" "${TMP}/root/etc/systemd/system"
}
_node_state() { cat "${TMP}/ip/state.${1:-10.0.0.1}" 2>/dev/null || true; }

_run() {   # _run <env...> -- <tool args...>
    local envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    (
        export PATH="${TMP}/bin:${PATH}"
        export CLUSTER_CONF="${TMP}/cluster.conf"
        export CLUSTER_DEFAULTS_CONF="${TMP}/defaults.conf"
        export OFFLINE_FILES_ROOT="${TMP}/offline"
        export CUBESTACK_RELEASE_AUTO=false
        export SSH_KEY_DIR="${TMP}/keys"
        export SSH_KEY_NAME="fake_key"
        export FAKE_ROOT="${TMP}/root"
        export FAKE_BIN="${TMP}/bin"
        export FAKE_IP_DIR="${TMP}/ip"
        export FAKE_IP_STATE="${TMP}/ip/state"
        export FAKE_IP_LOG="${TMP}/ip/log"
        export FAKE_SYSTEMCTL_LOG="${TMP}/systemctl.log"
        export KUBE_PODS_SUBNET="${KUBE_PODS_SUBNET:-10.233.64.0/18}"
        export CALICO_USE_DEFAULT_ROUTE_SRC_IPADDR="${CALICO_USE_DEFAULT_ROUTE_SRC_IPADDR:-true}"
        env "${envs[@]}" bash "${TOOL}" "$@"
    ) 2>&1
}

echo "== ① 风险节点识别 + 安全节点不误报 =="
_reset_rule_state
out="$(_run -- --check)"
rc=$?
chk "退出码 0(原生修复开启只告警)" "0" "${rc}"
chk_contains "点名风险节点" "[m1](10.0.0.1)" "${out}"
chk_contains "点名 IB 地址" "172.16.1.104" "${out}"
chk_contains "说明原生修复" "原生修复已启用" "${out}"
chk_not_contains "不写主机规则" "RULE_ADD" "$(cat "${TMP}/ip/log")"
chk_contains "安全节点不误报" "[w1](10.0.0.2)" "${out}"
chk_not_contains "安全节点无冲突" "[w1](10.0.0.2) 检测到源策略路由冲突" "${out}"
chk_contains "源策略路由指纹告警(防临时规则掩盖)" "可能已被临时 ip rule 掩盖" "${out}"

echo "== ② 原生修复关闭: --check 硬失败并给指引 =="
_reset_rule_state
out="$(_run CALICO_USE_DEFAULT_ROUTE_SRC_IPADDR=false -- --check)"
rc=$?
chk "退出码 1" "1" "${rc}"
chk_contains "点名原生修复未启用" "原生修复未启用" "${out}"
chk_contains "给出 rule 兜底指引" "NODE_NET_GUARD_ACTION=rule" "${out}"
chk_not_contains "仍不写主机规则" "RULE_ADD" "$(cat "${TMP}/ip/log")"

echo "== ③ --apply-rule: 幂等、只加 Pod 网段、systemd 持久化 =="
_reset_rule_state
out="$(_run -- --apply-rule)"
rc=$?
chk "退出码 0" "0" "${rc}"
chk_contains "写入 ip rule" "已写入 ip rule" "${out}"
_log="$(cat "${TMP}/ip/log")"
chk_contains "规则用 Pod 网段" "RULE_ADD|30000|10.233.64.0/18|main" "${_log}"
chk_not_contains "不写 service 网段" "10.233.0.0/18" "${_log}"
chk "unit 已创建" "yes" "$([ -f "${TMP}/root/etc/systemd/system/cubestack-pod-net-routing.service" ] && echo yes || echo no)"
chk "guard 脚本已创建" "yes" "$([ -x "${TMP}/root/usr/local/sbin/cubestack-pod-net-routing" ] && echo yes || echo no)"
chk_contains "conf 含 Pod 网段" "POD_CIDR='10.233.64.0/18'" "$(cat "${TMP}/root/etc/cubestack/pod-net-routing.conf")"
chk "state 恰好 1 条" "1" "$(command grep -c . <<< "$(_node_state)" || true)"

# 重复执行: 不应产生第二条规则
out="$(_run -- --apply-rule)"
chk "重复执行退出码 0" "0" "$?"
chk "state 仍恰好 1 条" "1" "$(command grep -c . <<< "$(_node_state)" || true)"
chk "重复执行 RULE_ADD 出现 2 次(kernel 幂等 File exists 语义)" "2" "$(command grep -c 'RULE_ADD|30000|10.233.64.0/18|main' "${TMP}/ip/log" || true)"

echo "== ④ 网段变化: 动态读取 KUBE_PODS_SUBNET 并清理旧规则 =="
out="$(_run KUBE_PODS_SUBNET=10.244.0.0/16 -- --apply-rule)"
chk "改网段退出码 0" "0" "$?"
_log="$(cat "${TMP}/ip/log")"
chk_contains "新网段规则" "RULE_ADD|30000|10.244.0.0/16|main" "${_log}"
chk_contains "旧网段被删除" "RULE_DEL|30000|10.233.64.0/18|main" "${_log}"
chk "state 只保留新网段" "30000|10.244.0.0/16|main" "$(_node_state)"
chk_contains "conf 更新为新网段" "POD_CIDR='10.244.0.0/16'" "$(cat "${TMP}/root/etc/cubestack/pod-net-routing.conf")"

echo "== ⑤ --remove: 清理规则/unit/conf =="
out="$(_run -- --remove)"
chk "remove 退出码 0" "0" "$?"
chk "state 已清空" "0" "$(command grep -c . <<< "$(_node_state)" || true)"
chk "unit 已删除" "no" "$([ -f "${TMP}/root/etc/systemd/system/cubestack-pod-net-routing.service" ] && echo yes || echo no)"
chk "guard 脚本已删除" "no" "$([ -f "${TMP}/root/usr/local/sbin/cubestack-pod-net-routing" ] && echo yes || echo no)"
chk "conf 已删除" "no" "$([ -f "${TMP}/root/etc/cubestack/pod-net-routing.conf" ] && echo yes || echo no)"

echo "== ⑥ SSH 不可达: 非 0 + 点名节点 =="
_reset_rule_state
out="$(FAKE_FAIL_IP=10.0.0.2 _run CALICO_USE_DEFAULT_ROUTE_SRC_IPADDR=true -- --check)"
rc=$?
chk "退出码 1" "1" "${rc}"
chk_contains "点名失败节点" "w1(10.0.0.2)" "${out}"
chk_contains "提示 SSH 失败" "SSH" "${out}"

echo "== ⑦ 规则写入失败: 工具必须失败而不是假成功 =="
_reset_rule_state
out="$(FAKE_RULE_ADD_FAIL=1 _run -- --apply-rule)"
rc=$?
chk "退出码 1" "1" "${rc}"
chk_contains "点名写入失败" "兜底规则写入失败" "${out}"

echo ""
if [ "${fail}" = "0" ]; then
    echo "✅ test-node-net-guard: 全部通过"
else
    echo "❌ test-node-net-guard: 存在失败项"
fi
exit "${fail}"
