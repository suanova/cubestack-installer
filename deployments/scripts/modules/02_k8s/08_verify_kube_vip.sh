#!/bin/bash
# ============================================================
# MODULE: verify_kube_vip
# DESC: 端到端验证 API Server VIP 高可用(kube-vip 静态 Pod)真正工作:
#       ① 各 master 上 kube-vip 静态 Pod 存在且 Running
#       → ② VIP 恰好绑在一台 master 上(防脑裂: 两个 leader 同时持 VIP)
#       → ③ curl -k https://<VIP>:6443/healthz 端到端可达
#       → ④ VIP 所在网卡 == 承载该节点主 IP 的网卡(把"自动检测选错网卡"从静默变可检测)
#       → ⑤ kubernetes Service 的 EndpointSlice 非单点(advertise-address 单点修复)
#       → ⑥ 漂移演练: 移走 leader 的 manifest → 等租约过期 → 断言 VIP 漂移 + 输出实测耗时 → 恢复
# PHASE: k8s
# DEFAULT: 0
# REPEAT: 1
# REQUIRES: k8s_deploy
# 说明:
#   · **验证模块不设 TOGGLE**(否则 KUBE_VIP_ENABLED=true 时被安装流程自动启用);
#     保持 DEFAULT:0, 仅由 --steps verify_kube_vip 在部署后单个执行。
#   · 放在 02_k8s/ 而非 03_addon/ —— 它验的是集群基座(API 入口), 不是 addon。
#     模块发现机制按 [0-9][0-9]_*/[0-9][0-9]_*.sh 通配, 任意阶段目录均可。
#   · ⑥ 是**破坏性演练**(主动拿掉 leader 的 kube-vip), 默认执行 —— 漂移能力是本方案唯一的核心价值,
#     不实测等于没验证。要求 ≥3 master; 演练前备份 manifest, trap 兜底自动恢复。
#     例行巡检想跳过: VERIFY_KUBE_VIP_DRILL=false
# 数据源: cluster.conf (KUBE_VIP_ENABLED / K8S_API_VIP / NODES / SSH_KEY_NAME)
# 用法: sudo ./deploy-cluster.sh --steps verify_kube_vip
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

init_remote_kubectl || exit 1

MANIFEST="/etc/kubernetes/manifests/kube-vip.yml"
DRILL="${VERIFY_KUBE_VIP_DRILL:-true}"
SSH_KEY_PATH="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
SSH_USER_NAME="${SSH_USER:-ubuntu}"

# ---- 门禁: 以实际部署为准(静态 Pod 是否落盘), 不看配置开关 ----
_host_ssh() {   # _host_ssh <host> <command...>
    local h="$1"; shift
    ssh -i "${SSH_KEY_PATH}" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${SSH_USER_NAME}@${h}" "$@" 2>/dev/null
}

MASTERS=($(master_hosts))
[ "${#MASTERS[@]}" -gt 0 ] || { err "cluster.conf 中无 master 节点"; exit 1; }

_HAVE_MANIFEST=0
for _h in "${MASTERS[@]}"; do
    _host_ssh "${_h}" "test -f ${MANIFEST}" && { _HAVE_MANIFEST=1; break; }
done
if [ "${_HAVE_MANIFEST}" = "0" ] && ! bool_is_true "${KUBE_VIP_ENABLED:-false}"; then
    say "kube-vip 未部署(各 master 上无 ${MANIFEST} 且 KUBE_VIP_ENABLED≠true), 跳过验证"
    exit 0
fi

_VIP="${K8S_API_VIP:-}"
if [ -z "${_VIP}" ]; then
    _VIP="$(kube_vip_derive 2>/dev/null || true)"
fi
[ -n "${_VIP}" ] || { err "无法确定 VIP(K8S_API_VIP 为空且推导失败)"; exit 1; }

say "Verify kube-vip: 静态 Pod → VIP 唯一绑定 → healthz → 网卡正确性 → EndpointSlice → 漂移演练"
say "  目标 VIP: ${_VIP}"

# ---------------- ① 各 master 上 kube-vip 静态 Pod Running ----------------
say "  ① 检查各 master 上 kube-vip 静态 Pod..."
# 静态 Pod 名形如 kube-vip-<节点名>; 标签是 k8s-app=kube-vip(见 kubespray 的 kube-vip.manifest.j2)
_NRUN="$( (SSH "${K}" -n kube-system get pods -l k8s-app=kube-vip --no-headers 2>/dev/null \
    || SSH "${K}" -n kube-system get pods --no-headers 2>/dev/null | grep 'kube-vip' || true) \
    | awk '$3=="Running"{n++} END{print n+0}' )"
_NTOT="$( (SSH "${K}" -n kube-system get pods --no-headers 2>/dev/null | grep -c 'kube-vip' || true) )"
[ "${_NRUN:-0}" -ge 1 ] || {
    err "kube-vip 无 Running Pod(${_NRUN}/${_NTOT})"
    err "排查: SSH 到 master 执行 ${K} -n kube-system describe pod -l k8s-app=kube-vip"
    err "常见原因: 镜像未预加载(见 docs/kube-vip-api-ha.md 第 8 节)/ cp_enable 未开 / strict_arp 未设"
    exit 1
}
ok "  kube-vip Pod Running: ${_NRUN}/${_NTOT}"

# ---------------- ② VIP 恰好绑在一台 master 上(防脑裂) ----------------
say "  ② 检查 VIP 绑定唯一性(防脑裂)..."
_HOLDERS=()
for _h in "${MASTERS[@]}"; do
    if _host_ssh "${_h}" "ip route get '${_VIP}' 2>/dev/null | grep -q 'local ${_VIP} '"; then
        _HOLDERS+=("${_h}")
    fi
done
case "${#_HOLDERS[@]}" in
    1) ok "  VIP ${_VIP} 绑定在: ${_HOLDERS[0]}(唯一)" ;;
    0) err "  VIP ${_VIP} 未绑定在任何 master 上 —— API 入口指向了一个不存在的地址, 集群可能已失联"
       err "  排查: 各 master 执行 crictl ps | grep kube-vip; 查 ${MANIFEST} 是否存在"
       exit 1 ;;
    *) err "  VIP ${_VIP} 同时绑定在 ${#_HOLDERS[@]} 台 master 上(${_HOLDERS[*]}) —— **脑裂**"
       err "  两台同时持有 VIP 会被交换机 MAC 表来回翻转, 导致 API 大面积不可达"
       err "  处置: 保留一台, 在其余 master 上停掉 kube-vip 静态 Pod 后重跑本验证"
       exit 1 ;;
esac
_LEADER="${_HOLDERS[0]}"

# ---------------- ③ healthz 端到端 ----------------
say "  ③ 经 VIP 访问 API(https://${_VIP}:6443/healthz)..."
# 从 leader 本机 curl, 避免部署机到节点网段无路由(见 docs 7.2 的同类坑)
_HZ="$(_host_ssh "${_LEADER}" "curl -sk --max-time 8 https://${_VIP}:6443/healthz" || true)"
if [ "${_HZ}" = "ok" ]; then
    ok "  healthz 通过(VIP 上的 apiserver 真实可用)"
else
    err "  healthz 失败(返回: '${_HZ}')—— VIP 已绑定但 apiserver 不可达"
    err "  排查: 该节点 apiserver 进程状态; 6443 是否监听; 防火墙是否拦截"
    exit 1
fi

# ---------------- ④ VIP 所在网卡 == 承载节点主 IP 的网卡 ----------------
say "  ④ 检查 VIP 落在正确的网卡上..."
_VIP_IF="$(_host_ssh "${_LEADER}" "ip -o addr show | awk -v v='${_VIP}' '\$4 ~ \"^\" v \"/\" {print \$2; exit}'" || true)"
_NODE_IP="$(awk -v h="${_LEADER}" '
    /^kube_control_plane:/ {cp=1; next}
    /^[A-Za-z0-9_]+:/ {if (cp) cp=0}
    cp && /^[[:space:]]*'"${_LEADER}"':/ {f=1; next}
    f && /^[[:space:]]*access_ip:[[:space:]]*[0-9.]+/ {print $2; exit}
    f && /^[[:space:]]*ip:[[:space:]]*[0-9.]+/ {print $2; exit}
' "${KUBESPRAY_INV_DIR:-${REPO_ROOT}/deployments/kubespray/inventory/cubestack-cluster}/hosts.yml" 2>/dev/null || true)"
_NODE_IF=""
[ -n "${_NODE_IP}" ] && _NODE_IF="$(_host_ssh "${_LEADER}" "ip -o addr show | awk -v v='${_NODE_IP}' '\$4 ~ \"^\" v \"/\" {print \$2; exit}'" || true)"
if [ -n "${_VIP_IF}" ] && [ -n "${_NODE_IF}" ] && [ "${_VIP_IF}" = "${_NODE_IF}" ]; then
    ok "  VIP 网卡 = 节点主 IP 网卡(${_VIP_IF})"
elif [ -z "${_VIP_IF}" ]; then
    warn "  未能识别 VIP 所在网卡(ip addr 解析失败), 跳过该项"
else
    warn "  ⚠ VIP 在 ${_VIP_IF}, 而节点主 IP ${_NODE_IP:-<未识别>} 在 ${_NODE_IF:-<未识别>} —— 网卡可能选错"
    warn "  影响: VIP 与节点主 IP 不在同一网卡时, 跨网段客户端可能访问不到"
    warn "  处置: 在 cluster.conf 显式指定 KUBE_VIP_INTERFACE=<正确网卡> 后重跑 k8s_deploy"
fi

# ---------------- ⑤ kubernetes Service EndpointSlice 非单点 ----------------
say "  ⑤ 检查 kubernetes Service 的 EndpointSlice(advertise-address 单点修复)..."
_EPS="$(SSH "${K}" get endpointslice -n default -l kubernetes.io/service-name=kubernetes \
    -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\n"}{end}' 2>/dev/null || true)"
_EPN="$(printf '%s\n' "${_EPS}" | grep -c . || true)"
if [ "${_EPN:-0}" -ge 2 ]; then
    ok "  EndpointSlice 含 ${_EPN} 个地址(非单点): $(printf '%s' "${_EPS}" | tr '\n' ' ')"
elif [ "${_EPN:-0}" -eq 1 ]; then
    warn "  EndpointSlice 只有 1 个地址(${_EPS})—— 集群内经 Service 访问 API 仍是单点"
    warn "  原因: kube_apiserver_extra_args.advertise-address 未按节点取值"
    warn "  处置: 重跑 --steps k8s_deploy(sync 会自动修正为 {{ kube_apiserver_address }})"
else
    warn "  未取到 EndpointSlice 地址(查询失败或未就绪), 跳过该项"
fi

# ---------------- ⑥ 漂移演练 ----------------
if ! bool_is_true "${DRILL}"; then
    say "  ⑥ 漂移演练: 已按 VERIFY_KUBE_VIP_DRILL=${DRILL} 跳过"
    say "kube-vip 验证完成(未做漂移演练, 故障切换能力未被验证)"
    exit 0
fi

if [ "${#MASTERS[@]}" -lt 3 ]; then
    warn "  ⑥ 漂移演练: 仅 ${#MASTERS[@]} 台 master, 跳过(移走一台后无第三台可接管)"
    say "kube-vip 验证完成"
    exit 0
fi

echo ""
echo -e "\033[41m\033[97m ⚠  即将执行 VIP 漂移演练(破坏性) \033[0m"
echo -e "\033[41m\033[97m   将移走 leader(${_LEADER})的 kube-vip manifest, 等待租约过期后 VIP 应漂到另一台 master。\033[0m"
echo -e "\033[41m\033[97m   期间 API 会有约 5-15 秒抖动, 演练结束自动恢复。\033[0m"

# 先备份 manifest —— 即使脚本被中断也留可手工恢复的副本
_BAK="/tmp/kube-vip.yml.verify-bak.$$"
_host_ssh "${_LEADER}" "sudo cp ${MANIFEST} ${_BAK}" || { err "无法备份 manifest, 演练中止"; exit 1; }

restore_leader() {
    _host_ssh "${_LEADER}" "sudo test -f ${_BAK} && sudo mv ${_BAK} ${MANIFEST}; sudo test -f ${MANIFEST} || true" || true
    echo -e "\033[36m→  已恢复 ${_LEADER} 的 kube-vip manifest(${MANIFEST})\033[0m"
}
trap restore_leader EXIT

say "  ⑥ 漂移演练: 移走 ${_LEADER} 的 manifest, 测量 VIP 漂移耗时..."
_host_ssh "${_LEADER}" "sudo rm -f ${MANIFEST}" || { err "移除 manifest 失败, 演练中止"; exit 1; }

_DRILL_TIMEOUT="${VERIFY_KUBE_VIP_TIMEOUT:-60}"
_START="$(date +%s)"
_NEW_LEADER=""
while [ "$(( $(date +%s) - _START ))" -lt "${_DRILL_TIMEOUT}" ]; do
    sleep 1
    for _h in "${MASTERS[@]}"; do
        [ "${_h}" = "${_LEADER}" ] && continue
        if _host_ssh "${_h}" "ip route get '${_VIP}' 2>/dev/null | grep -q 'local ${_VIP} '"; then
            _NEW_LEADER="${_h}"; break
        fi
    done
    [ -n "${_NEW_LEADER}" ] && break
done
_ELAPSED=$(( $(date +%s) - _START ))

if [ -n "${_NEW_LEADER}" ]; then
    # API 是否在漂移后仍可用(从新 leader 本机验证, 回避路由问题)
    _HZ2="$(_host_ssh "${_NEW_LEADER}" "curl -sk --max-time 8 https://${_VIP}:6443/healthz" || true)"
    if [ "${_HZ2}" = "ok" ]; then
        ok "  ⑥ 漂移成功: ${_LEADER} → ${_NEW_LEADER}, 实测耗时 ${_ELAPSED}s, healthz 通过"
    else
        err "  ⑥ VIP 漂移到了 ${_NEW_LEADER}(耗时 ${_ELAPSED}s), 但 healthz 失败(返回 '${_HZ2}')"
        err "  说明 VIP 绑上了但 apiserver 不可用 —— 检查新 leader 的 apiserver 状态"
        exit 1
    fi
else
    err "  ⑥ 漂移失败: ${_ELAPSED}s 内(上限 ${_DRILL_TIMEOUT}s)VIP 未漂到其他 master"
    err "  排查: 新节点 kube-vip 是否 Running; 租约是否能在 API 中正常选举"
    err "  注意: 本演练已自动恢复 ${_LEADER} 的 manifest, 但这个失败意味着**切换能力不成立**"
    exit 1
fi

say "  ℹ️ 实测切换耗时 ${_ELAPSED}s(基线; 租约参数 leaseduration=5/renewDeadline=3/retryPeriod=1)"
say "     若该数字明显偏大且节点存活仅 apiserver 进程异常, 再评估 kube_vip_cp_detect=true(见 docs 2.4)"
say "kube-vip 验证完成(六项全过)"
