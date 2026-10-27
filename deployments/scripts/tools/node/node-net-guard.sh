#!/bin/bash
# ============================================================
# node-net-guard.sh — 节点源策略路由 / Calico rpfilter 冲突预检与兜底
# ------------------------------------------------------------
# 背景(2026-10-27 实机 worker05/08, 带 IB 的 g1 机器):
#   主机镜像 netplan 自带 `routing-policy: from <IB> lookup <table>`; Calico 给本地 Pod 的
#   设备路由没有 preferred source, 内核按接口枚举顺序选到 IB 地址作源。Pod 回包到达宿主机
#   cali 网卡后, Calico raw 表 rpfilter 反向校验用回包目的地址(IB)查路由 → 命中 IB 表 →
#   出接口(IB)≠入接口(cali) → DROP; 表现为 kubelet 探针 context deadline exceeded、
#   coredns/metallb/metrics-server 0/1 无限重启。
#
# 根治(默认, 由 k8s_deploy 的 sync-kubespray-config.sh 落地):
#   calico_use_default_route_src_ipaddr=true → FELIX_DEVICEROUTESOURCEADDRESS=status.hostIP
#   → Felix 给每 Pod 设备路由写 src=<节点 IP>, host→本地 Pod 流量不再选 IB 源。
#
# 本工具的职责:
#   ① 预检: 逐节点比较 `ip route get <pod_probe> from <节点IP>` 与每个本地地址
#      `from <addr>` 的路由, 发现“反向路径分歧”(即 rpfilter 会丢包的条件);
#   ② --check: 只检测。原生修复开启 → 告警不阻断; 关闭 → 硬失败并给指引;
#   ③ --apply-rule: 可选兜底。幂等加 `pref <N> to <KUBE_PODS_SUBNET> lookup main`
#      + systemd oneshot 持久化(只加 Pod 网段; ClusterIP 是 local 路由, 不需要 service 网段);
#   ④ --remove: 清理兜底规则/unit/conf(非风险节点在 --apply-rule 时也会自动清理)。
#
# 用法:
#   sudo ./node-net-guard.sh --check
#   sudo ./node-net-guard.sh --apply-rule
#   sudo ./node-net-guard.sh --remove
#   sudo ./node-net-guard.sh --check --only worker05
#   ./node-net-guard.sh --remote-probe --node-ip <IP> --pod-probe <IP> \
#        --pod-cidr <CIDR> --pref <N>     # 内部/测试用: 在本机执行探测载荷
#
# 数据源: cluster.conf NODES / KUBE_PODS_SUBNET / CALICO_USE_DEFAULT_ROUTE_SRC_IPADDR /
#         NODE_NET_GUARD_ACTION / NODE_NET_GUARD_RULE_PREF
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------- 内部模式: 远端探测载荷(不 source lib-common, 节点上没有仓库) ----------------
_remote_probe_script() {   # <node_ip> <pod_probe> <pod_cidr> <pref>
    local node_ip="$1" pod_probe="$2" pod_cidr="$3" pref="$4"
    cat <<'EOS'
#!/bin/bash
set -uo pipefail
EOS
    printf 'NODE_IP=%q\n' "${node_ip}"
    printf 'POD_PROBE=%q\n' "${pod_probe}"
    printf 'POD_CIDR=%q\n' "${pod_cidr}"
    printf 'PREF=%q\n' "${pref}"
    cat <<'EOS'

_dev() { awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' <<< "$1"; }
_table() { awk '{for(i=1;i<=NF;i++) if($i=="table"){print $(i+1); exit}}' <<< "$1"; }

base_out="$(ip route get "$POD_PROBE" from "$NODE_IP" 2>&1)"; base_rc=$?
base_dev="$(_dev "$base_out")"; base_tab="$(_table "$base_out")"
printf 'BASE|%s|%s|%s|%s\n' "$base_rc" "$base_dev" "$base_tab" "$POD_PROBE"

# 本地地址(scope global); 跳过 loopback/link-local/节点 IP, 以及 kube-ipvs0/CNI 虚拟接口
# (kube-ipvs0 上挂着全部 ClusterIP, 逐个查会白跑几百次; cali/tunl/vxlan 没有宿主地址)。
# 注意: 不能只解析 ip rule 的 from 项 —— 规则可能是 CIDR/由其他组件写入,
# 直接对每个宿主地址做反向路径查询才能覆盖实际 rpfilter 行为。
while read -r iface cidr; do
    [ -n "$cidr" ] || continue
    case "$iface" in
        lo|kube-ipvs0|nodelocaldns|dummy*|cali*|tunl*|vxlan*) continue ;;
    esac
    addr="${cidr%/*}"
    case "$addr" in
        127.*|169.254.*) continue ;;
    esac
    [ "$addr" = "$NODE_IP" ] && continue
    out="$(ip route get "$POD_PROBE" from "$addr" 2>&1)"; rc=$?
    dev="$(_dev "$out")"; tab="$(_table "$out")"
    risk=0
    if [ "$rc" -ne 0 ] && [ "$base_rc" -eq 0 ]; then risk=1; fi
    if [ "$rc" -eq 0 ] && [ "$base_rc" -ne 0 ]; then risk=1; fi
    if [ "$rc" -eq 0 ] && [ "$base_rc" -eq 0 ] && [ "$dev" != "$base_dev" ]; then risk=1; fi
    printf 'ADDR|%s|%s|%s|%s|%s\n' "$addr" "$dev" "$rc" "$tab" "$risk"
done < <(ip -o -4 addr show scope global 2>/dev/null | awk '{print $2, $4}')

# 源策略路由指纹: 用于识别“当前反向路径已被临时 ip rule 掩盖”的节点。
# 只看 ADDR 会漏报 —— 临时 `to <pod> lookup main` 规则会让反向查询暂时回到 main,
# 但 reboot/删规则后问题复现。这里把 from <非 all> lookup <非 main/local/default> 打出来,
# 由调用方决定告警/阻断(不直接判风险, 因为规则可能不覆盖 Pod 网段)。
ip -4 rule show 2>/dev/null | awk '
    {
        from=""; tab=""
        for (i=1; i<=NF; i++) {
            if ($i == "from") from = $(i+1)
            if ($i == "lookup" || $i == "table") tab = $(i+1)
        }
        if (from != "" && from != "all" && tab != "" && tab != "main" && tab != "local" && tab != "default")
            printf "SRC_RULE|%s|%s\n", from, tab
    }'

guard=0
if ip -4 rule show 2>/dev/null | grep -F "to $POD_CIDR lookup main" >/dev/null 2>&1; then guard=1; fi
printf 'GUARD|%s\n' "$guard"
EOS
}

# ---------------- 内部模式: 远端兜底规则载荷 ------------------------------------------------
_remote_apply_script() {   # <pod_cidr> <pref> <apply|remove>
    local pod_cidr="$1" pref="$2" action="$3"
    cat <<'EOS'
#!/bin/bash
set -uo pipefail
EOS
    printf 'POD_CIDR=%q\n' "${pod_cidr}"
    printf 'PREF=%q\n' "${pref}"
    printf 'ACTION=%q\n' "${action}"
    cat <<'EOS'

CONF=/etc/cubestack/pod-net-routing.conf
APPLIED=/etc/cubestack/pod-net-routing.applied
SCRIPT=/usr/local/sbin/cubestack-pod-net-routing
UNIT=/etc/systemd/system/cubestack-pod-net-routing.service

if [ "$ACTION" = "remove" ]; then
    # 先读 conf(其中记录实际写入时的 PREF/POD_CIDR), 再按它清理 APPLIED 里的旧网段;
    # conf 不存在时退回调用方传入的 PREF/POD_CIDR。
    if [ -f "$CONF" ]; then . "$CONF"; fi
    if [ -f "$APPLIED" ]; then
        while IFS= read -r old; do
            [ -n "$old" ] || continue
            ip rule del pref "$PREF" to "$old" lookup main 2>/dev/null || true
        done < "$APPLIED"
    fi
    if [ -n "${POD_CIDR:-}" ]; then
        ip rule del pref "$PREF" to "$POD_CIDR" lookup main 2>/dev/null || true
    fi
    systemctl disable --now cubestack-pod-net-routing.service 2>/dev/null || true
    rm -f "$UNIT" "$SCRIPT" "$CONF" "$APPLIED"
    if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload 2>/dev/null || true; fi
    printf 'REMOVED|%s|%s\n' "$PREF" "${POD_CIDR:-}"
    exit 0
fi

mkdir -p /etc/cubestack
cat > "$CONF" <<CONF_EOF
# Generated by CubeStack installer; do not edit.
POD_CIDR='$POD_CIDR'
PREF='$PREF'
CONF_EOF
cat > "$SCRIPT" <<'SCRIPT_EOF'
#!/bin/bash
set -euo pipefail
CONF=/etc/cubestack/pod-net-routing.conf
APPLIED=/etc/cubestack/pod-net-routing.applied
[ -r "$CONF" ] || exit 0
. "$CONF"
[ -n "${POD_CIDR:-}" ] || exit 0
PREF="${PREF:-30000}"
# 清理上一次配置遗留的网段(改网段/缩网段时不残留)
if [ -f "$APPLIED" ]; then
    while IFS= read -r old; do
        [ -n "$old" ] || continue
        [ "$old" = "$POD_CIDR" ] && continue
        ip rule del pref "$PREF" to "$old" lookup main 2>/dev/null || true
    done < "$APPLIED"
fi
ip rule add pref "$PREF" to "$POD_CIDR" lookup main 2>/dev/null || true
printf '%s\n' "$POD_CIDR" > "$APPLIED"
ip -4 rule show 2>/dev/null | grep -F "to $POD_CIDR lookup main" >/dev/null
SCRIPT_EOF
chmod 0755 "$SCRIPT"

cat > "$UNIT" <<UNIT_EOF
[Unit]
Description=CubeStack pod routing guard (policy-routing bypass)
After=network-online.target
Wants=network-online.target
Before=kubelet.service

[Service]
Type=oneshot
ExecStart=$SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT_EOF
chmod 0644 "$CONF" "$UNIT"

# 立即生效(不依赖 systemd reload 成功); 随后 enable 保证 reboot 后仍在。
# 若规则没真正装上, 必须把失败传回调用方, 不能靠后续 systemctl 的 0 掩盖。
if ! "$SCRIPT"; then
    printf 'APPLY_FAILED|%s|%s\n' "$PREF" "$POD_CIDR"
    exit 1
fi
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable cubestack-pod-net-routing.service 2>/dev/null || true
    systemctl restart cubestack-pod-net-routing.service 2>/dev/null || true
fi
printf 'APPLIED|%s|%s|%s|%s|%s\n' "$PREF" "$POD_CIDR" "$UNIT" "$SCRIPT" "$CONF"
EOS
}

# ---------------- 参数解析 ----------------------------------------------------------------
ACTION=""
ONLY=""
REMOTE_PROBE=0
NODE_IP_ARG=""; POD_PROBE_ARG=""; POD_CIDR_ARG=""; PREF_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --check)       ACTION="check"; shift ;;
        --apply-rule)  ACTION="rule"; shift ;;
        --remove)      ACTION="remove"; shift ;;
        --only)        ONLY="${2:?--only 需要一个 hostname}"; shift 2 ;;
        --remote-probe) REMOTE_PROBE=1; shift ;;
        --node-ip)     NODE_IP_ARG="${2:?}"; shift 2 ;;
        --pod-probe)   POD_PROBE_ARG="${2:?}"; shift 2 ;;
        --pod-cidr)    POD_CIDR_ARG="${2:?}"; shift 2 ;;
        --pref)        PREF_ARG="${2:?}"; shift 2 ;;
        -h|--help)     sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数: $1(可用 --check/--apply-rule/--remove/--only/--remote-probe)" >&2; exit 2 ;;
    esac
done

if [ "${REMOTE_PROBE}" = "1" ]; then
    [ -n "${NODE_IP_ARG}" ] && [ -n "${POD_PROBE_ARG}" ] && [ -n "${POD_CIDR_ARG}" ] || {
        echo "--remote-probe 需要 --node-ip/--pod-probe/--pod-cidr" >&2; exit 2; }
    _remote_probe_script "${NODE_IP_ARG}" "${POD_PROBE_ARG}" "${POD_CIDR_ARG}" "${PREF_ARG:-30000}" | bash -s
    exit $?
fi

# shellcheck source=lib-common.sh
source "${SCRIPT_DIR}/../../lib-common.sh"
load_config

ACTION="${ACTION:-${NODE_NET_GUARD_ACTION:-check}}"
PREF="${NODE_NET_GUARD_RULE_PREF:-30000}"
POD_CIDR="${KUBE_PODS_SUBNET:-10.233.64.0/18}"
NATIVE_FIX="${CALICO_USE_DEFAULT_ROUTE_SRC_IPADDR:-true}"
CNI="${KUBE_NETWORK_PLUGIN:-calico}"
SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"

case "${ACTION}" in
    check|rule|remove|off) : ;;
    *) err "NODE_NET_GUARD_ACTION=${ACTION} 非法(可用 check|rule|remove|off)"; exit 1 ;;
esac
if [ "${ACTION}" = "off" ]; then
    say "NODE_NET_GUARD_ACTION=off, 跳过节点源策略路由预检"
    exit 0
fi

_is_true() { case "${1,,}" in true|1|yes|on) return 0 ;; *) return 1 ;; esac; }
_native_fix_active() { [ "${CNI}" = "calico" ] && _is_true "${NATIVE_FIX}"; }

# IPv4 CIDR 的第一个主机地址(探测用; 不依赖 python/ipcalc)
_cidr_first_host() {
    local cidr="$1" ip prefix o1 o2 o3 o4 ipnum mask net first
    [[ "${cidr}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]] || return 1
    ip="${cidr%/*}"; prefix="${cidr#*/}"
    [ "${prefix}" -le 32 ] || return 1
    IFS=. read -r o1 o2 o3 o4 <<< "${ip}"
    ipnum=$(( (o1<<24) + (o2<<16) + (o3<<8) + o4 ))
    if [ "${prefix}" -eq 0 ]; then
        mask=0
    else
        mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
    fi
    net=$(( ipnum & mask ))
    first=$(( net + 1 ))
    [ "${prefix}" -ge 31 ] && first="${net}"
    printf '%d.%d.%d.%d\n' \
        $(( (first >> 24) & 255 )) $(( (first >> 16) & 255 )) \
        $(( (first >> 8) & 255 )) $(( first & 255 ))
}

# 在节点上执行载荷(密钥优先, 密码回退); stdout 为载荷输出
_run_on_node() {   # <ip> <user> <pw> <script-file>
    local ip="$1" user="$2" pw="$3" file="$4" rcmd
    rcmd="sudo bash -s"; [ "${user}" = "root" ] && rcmd="bash -s"
    if [ -f "${SSH_KEY}" ] && ssh -i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
            "${user}@${ip}" "${rcmd}" < "${file}" 2>/dev/null; then
        return 0
    fi
    if [ -n "${pw}" ] && command -v sshpass >/dev/null 2>&1; then
        env SSHPASS="${pw}" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=8 -o PreferredAuthentications=password -o PubkeyAuthentication=no \
            "${user}@${ip}" "${rcmd}" < "${file}" 2>/dev/null
        return $?
    fi
    return 1
}

_probe_node() {   # <ip> <user> <pw> → stdout(载荷输出), rc
    local ip="$1" user="$2" pw="$3" probe tmp
    probe="$(_cidr_first_host "${POD_CIDR}")" || { err "KUBE_PODS_SUBNET 非法: ${POD_CIDR}"; return 1; }
    tmp="$(mktemp)"
    _remote_probe_script "${ip}" "${probe}" "${POD_CIDR}" "${PREF}" > "${tmp}"
    local out rc=0
    out="$(_run_on_node "${ip}" "${user}" "${pw}" "${tmp}")" || rc=$?
    rm -f "${tmp}"
    [ "${rc}" -eq 0 ] || return 1
    printf '%s\n' "${out}"
}

_apply_node() {   # <ip> <user> <pw> <apply|remove>
    local ip="$1" user="$2" pw="$3" how="$4" tmp out rc=0
    tmp="$(mktemp)"
    _remote_apply_script "${POD_CIDR}" "${PREF}" "${how}" > "${tmp}"
    out="$(_run_on_node "${ip}" "${user}" "${pw}" "${tmp}")" || rc=$?
    rm -f "${tmp}"
    [ "${rc}" -eq 0 ] || return 1
    printf '%s\n' "${out}"
}

# ---------------- 主流程 -------------------------------------------------------------------
case "${ACTION}" in
    check)  say "节点源策略路由/Calico rpfilter 冲突预检(动作=check, pod 网段=${POD_CIDR})..." ;;
    rule)   say "节点源策略路由/Calico rpfilter 冲突预检 + 兜底规则(动作=rule, pod 网段=${POD_CIDR}, pref=${PREF})..." ;;
    remove) say "清理节点侧兜底规则(动作=remove, pref=${PREF})..." ;;
esac

NODES_CNT=0
RISKY_CNT=0
FIXED_CNT=0
FAILED=0
FAILED_NODES=""

for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    node_parse "${line}"
    [ -n "${NODE_IP}" ] && [ -n "${NODE_HOSTNAME}" ] || continue
    [ -n "${ONLY}" ] && [ "${NODE_HOSTNAME}" != "${ONLY}" ] && continue
    NODES_CNT=$((NODES_CNT + 1))

    # remove: 不探测, 直接清理(所有节点幂等)
    if [ "${ACTION}" = "remove" ]; then
        if _apply_node "${NODE_IP}" "${NODE_USER}" "${NODE_PW}" remove >/dev/null 2>&1; then
            ok "  [${NODE_HOSTNAME}](${NODE_IP}) 已清理兜底规则"
        else
            err "  [${NODE_HOSTNAME}](${NODE_IP}) 清理失败(SSH 不可达或无权限)"
            FAILED=1; FAILED_NODES="${FAILED_NODES} ${NODE_HOSTNAME}(${NODE_IP})"
        fi
        continue
    fi

    if ! probe_out="$(_probe_node "${NODE_IP}" "${NODE_USER}" "${NODE_PW}")"; then
        err "  [${NODE_HOSTNAME}](${NODE_IP}) SSH 探测失败(密钥/密码均不可达)"
        FAILED=1; FAILED_NODES="${FAILED_NODES} ${NODE_HOSTNAME}(${NODE_IP})"
        continue
    fi

    # 解析 ADDR|addr|dev|rc|table|risk
    risks="$(awk -F'|' '$1=="ADDR" && $6=="1" {printf "%s|%s|%s\n", $2, $3, $5}' <<< "${probe_out}")"
    guard_present="$(awk -F'|' '$1=="GUARD" {print $2}' <<< "${probe_out}")"
    base_rc="$(awk -F'|' '$1=="BASE" {print $2}' <<< "${probe_out}")"
    base_probe="$(awk -F'|' '$1=="BASE" {print $5}' <<< "${probe_out}")"
    if [ -n "${base_rc}" ] && [ "${base_rc}" != "0" ]; then
        warn "  [${NODE_HOSTNAME}](${NODE_IP}) 基准查询失败(ip route get ${base_probe:-<probe>} from ${NODE_IP}, rc=${base_rc}); 预检结果可能不完整"
    fi

    if [ -n "${risks}" ]; then
        RISKY_CNT=$((RISKY_CNT + 1))
        warn "  [${NODE_HOSTNAME}](${NODE_IP}) 检测到源策略路由冲突:"
        while IFS='|' read -r addr dev tab; do
            [ -n "${addr}" ] || continue
            warn "    ${addr} → dev ${dev:-?}${tab:+ (table ${tab})}; 反向查询与节点 IP ${NODE_IP} 的路径不一致"
        done <<< "${risks}"

        case "${ACTION}" in
            check)
                if _native_fix_active; then
                    warn "    Calico 原生修复已启用(calico_use_default_route_src_ipaddr=true):"
                    warn "    k8s_deploy 会给每 Pod 设备路由写 src=${NODE_IP}, 部署后探针应恢复"
                    warn "    若本次不跑 k8s_deploy, 用 NODE_NET_GUARD_ACTION=rule 立即兜底(或 --apply-rule)"
                    warn "    验证: ip route get <本地 Pod IP>  # src 应为 ${NODE_IP}"
                else
                    err "    Calico 原生修复未启用(或 KUBE_NETWORK_PLUGIN!=calico): 设置 CALICO_USE_DEFAULT_ROUTE_SRC_IPADDR=true 且使用 calico 后重跑 k8s_deploy;"
                    err "    或 NODE_NET_GUARD_ACTION=rule 立即加 ip rule 兜底"
                    FAILED=1; FAILED_NODES="${FAILED_NODES} ${NODE_HOSTNAME}(${NODE_IP})"
                fi
                ;;
            rule)
                if _native_fix_active; then
                    warn "    原生修复已启用; 本次仍按 NODE_NET_GUARD_ACTION=rule 加兜底(可随时 --remove 清理)"
                fi
                if applied_out="$(_apply_node "${NODE_IP}" "${NODE_USER}" "${NODE_PW}" apply)"; then
                    ok "    [${NODE_HOSTNAME}] 已写入 ip rule: pref ${PREF} to ${POD_CIDR} lookup main"
                    ok "    [${NODE_HOSTNAME}] 已持久化: /etc/systemd/system/cubestack-pod-net-routing.service (systemd enabled)"
                    FIXED_CNT=$((FIXED_CNT + 1))
                else
                    err "    [${NODE_HOSTNAME}] 兜底规则写入失败"
                    FAILED=1; FAILED_NODES="${FAILED_NODES} ${NODE_HOSTNAME}(${NODE_IP})"
                fi
                ;;
        esac
    else
        # 无反向路径分歧 ≠ 没有问题: 临时 `to <pod> lookup main` 规则会把分歧掩盖掉,
        # reboot/删规则后复发。这里用源策略路由指纹补一条明确告警。
        src_rules="$(awk -F'|' '$1=="SRC_RULE" {printf "%s|%s\n", $2, $3}' <<< "${probe_out}")"
        ok "  [${NODE_HOSTNAME}](${NODE_IP}) 未发现源策略路由冲突"
        if [ -n "${src_rules}" ]; then
            warn "  [${NODE_HOSTNAME}](${NODE_IP}) 检测到源策略路由规则(当前反向路径未分歧, 可能已被临时 ip rule 掩盖):"
            while IFS='|' read -r src tab; do
                [ -n "${src}" ] || continue
                warn "    from ${src} lookup ${tab}"
            done <<< "${src_rules}"
            if _native_fix_active; then
                warn "    原生修复已启用: k8s_deploy 后每 Pod 路由源=节点 IP; 随后可删除临时 ip rule"
            else
                warn "    原生修复未启用: 临时 ip rule 在 reboot 后丢失会复发; 建议 CALICO_USE_DEFAULT_ROUTE_SRC_IPADDR=true 或 NODE_NET_GUARD_ACTION=rule"
            fi
        fi
        if [ "${ACTION}" = "rule" ] && [ "${guard_present}" = "1" ]; then
            if _apply_node "${NODE_IP}" "${NODE_USER}" "${NODE_PW}" remove >/dev/null 2>&1; then
                ok "    [${NODE_HOSTNAME}] 已清理历史兜底规则"
            fi
        fi
    fi
done

if [ "${NODES_CNT}" -eq 0 ]; then
    err "未处理任何节点(NODES 为空或 --only 未命中)"
    exit 1
fi

if [ "${FAILED}" -ne 0 ]; then
    err "预检失败: ${NODES_CNT} 台节点, ${RISKY_CNT} 台命中, ${FIXED_CNT} 台已加兜底; 失败节点:${FAILED_NODES}"
    exit 1
fi
if [ "${ACTION}" = "rule" ]; then
    ok "预检完成: ${NODES_CNT} 台节点, ${RISKY_CNT} 台命中, ${FIXED_CNT} 台已加兜底规则"
else
    ok "预检完成: ${NODES_CNT} 台节点, ${RISKY_CNT} 台命中(原生修复已启用, 不阻断)"
fi
