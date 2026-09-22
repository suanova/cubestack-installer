#!/bin/bash
# ============================================================
# MODULE: kube_vip
# DESC: API Server VIP 高可用 — 在各 master 部署 kube-vip 静态 Pod
#       (kubespray 原生方案的等幂等实现, 不依赖 ansible/inventory 状态机)
# PHASE: k8s
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: KUBE_VIP_ENABLED
# 说明:
#   · **不声明 REQUIRES**: 本模块只依赖"集群已存在"(通过 SSH 探测四个前置条件自己判定),
#     不依赖 kubespray 的 inventory 状态机。若写 REQUIRES: k8s_deploy, 则 `--steps kube_vip`
#     会连带拉起整套 kubespray 部署 —— 而这正是本模块要避免的(它就是为了只动 VIP 而存在)。
#   · **等幂等**: 目标状态 = 「每台 master 上都有 m/ kube-vip 静态 Pod, 且 VIP 恰好绑在其中一台」。
#     基于该状态收敛, 而不是"装过就跳过" —— 支持修复被手工改坏的 manifest。
#   · **两种 VIP 来源**(K8S_API_VIP):
#       显式值 → 直接用, 不探测
#       留空   → 自动推导: 在各 master 上逐地址探测(ICMP 无应答 且 6443 不可达 = 空闲),
#                排除节点 IP 与 METALLB_POOL, 起点 K8S_API_VIP_START(默认 210)
#   · **离线**: 镜像来自 offline-files(见第 8 节), 节点无需外网/私服凭据。
#     ⚠ 该镜像必须在 PRELOAD_IMAGE_PATTERNS 内, 否则首装时 kube-vip 起不来 →
#       kubeadm init 失败(它要在 init 之前绑上 VIP)。
#   · ⚠ **vip_nodename 陷阱**: 渲染时必须按节点传各自的 hostname。若所有节点渲染成
#     同一个值, 多台 kube-vip 会抢同一租约 → **三台同时绑 VIP(脑裂)**。
#     本模块通过 render-kube-vip-manifest.py --nodename 逐个渲染来规避。
# 数据源: cluster.conf (KUBE_VIP_ENABLED / K8S_API_VIP / KUBE_VIP_INTERFACE / NODES / SSH_KEY_NAME)
# 用法: sudo ./deploy-cluster.sh --steps kube_vip
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

if ! bool_is_true "${KUBE_VIP_ENABLED:-false}"; then
    say "跳过 kube-vip(配置 KUBE_VIP_ENABLED=true 可启用)"
    exit 0
fi

kube_vip_validate_config || exit 1
init_remote_kubectl || exit 1

MANIFEST_PATH="/etc/kubernetes/manifests/kube-vip.yml"
TEMPLATE="${KUBESPRAY_DIR:-${REPO_ROOT}/deployments/kubespray/kubespray}/roles/kubernetes/node/templates/manifests/kube-vip.manifest.j2"
RENDERER="${SCRIPT_DIR}/tools/k8s/render-kube-vip-manifest.py"
[ -f "${TEMPLATE}" ] || { err "未找到 kubespray manifest 模板: ${TEMPLATE}"; exit 1; }
[ -f "${RENDERER}" ] || { err "未找到渲染器: ${RENDERER}"; exit 1; }
command -v python3 >/dev/null 2>&1 || { err "需要 python3(渲染 kubespray 模板)"; exit 1; }

# ---- VIP: 显式优先, 否则自动推导 ----
VIP="$(kube_vip_derive)" || exit 1
[ -n "${VIP}" ] || { err "无法确定 VIP"; exit 1; }
if [ -n "${K8S_API_VIP:-}" ]; then
    say "kube-vip: VIP=${VIP}(cluster.conf 显式指定)"
else
    say "kube-vip: VIP=${VIP}(自动推导)"
fi

MASTERS=($(master_hosts))
[ "${#MASTERS[@]}" -gt 0 ] || { err "cluster.conf NODES 中无 master"; exit 1; }

SSH_KEY_PATH="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
# ⚠ 一律用 **IP** 做 SSH, 不用主机名: 部署容器里通常没有节点名的 /etc/hosts 解析,
#   用主机名会静默连不上(stderr 被丢弃时极难排查)。主机名只用于 vip_nodename。
_ssh() {   # _ssh <ip> <cmd>
    ssh -i "${SSH_KEY_PATH}" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${SSH_USER:-ubuntu}@${1}" "$2" 2>/dev/null
}
_scp() {   # _scp <local> <ip> <remote>
    scp -q -i "${SSH_KEY_PATH}" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null "${1}" "${SSH_USER:-ubuntu}@${2}:${3}"
}

# 并行数组: _MHOST[i] = 主机名(vip_nodename), _MIP[i] = IP(SSH 目标)
_MHOST=(); _MIP=()
for _h in "${MASTERS[@]}"; do
    _ip="$(node_ip_by_hostname "${_h}")" || { err "无法解析节点 ${_h} 的 IP"; exit 1; }
    _MHOST+=("${_h}"); _MIP+=("${_ip}")
done

# ---- 前置条件自检(用自检替代 REQUIRES, 避免 --steps kube_vip 连带拉起整套 kubespray) ----
if ! is_cluster_live; then
    err "集群不可达或尚未部署(首个 master 上列不出 Node)"
    err "kube-vip 需要一个已存在的集群; 请先跑 --steps k8s_deploy"
    exit 1
fi

# 镜像必须已在各节点 —— 离线方案的硬前提(kube-vip 要在 kubeadm init 之前就能起来)
_KV_IMAGE="${KUBE_VIP_IMAGE_REPO:-ghcr.io/kube-vip/kube-vip}:${KUBE_VIP_VERSION:-v0.8.9}"
_MISSING=()
for _ip in "${_MIP[@]}"; do
    _ssh "${_ip}" "sudo ctr -n k8s.io i ls -q 2>/dev/null | grep -qF '${_KV_IMAGE}'" || _MISSING+=("${_ip}")
done
if [ "${#_MISSING[@]}" -gt 0 ]; then
    err "以下 master 上缺少 kube-vip 镜像 ${_KV_IMAGE}: ${_MISSING[*]}"
    err "离线方案: 该镜像应在 offline-files/kubespray/images/ 内, 由预加载流程推入节点"
    err "  · 取镜像(联网机): tools/images/harbor-save-images.sh --group k8s-base"
    err "  · 务必已在 PRELOAD_IMAGE_PATTERNS 内, 否则预加载会把它裁掉"
    exit 1
fi

# ---- VIP: 显式优先(all.yml 显式值也是), 否则自动推导 ----
VIP="$(kube_vip_derive)" || exit 1
[ -n "${VIP}" ] || { err "无法确定 VIP"; exit 1; }
if [ -n "${K8S_API_VIP:-}" ]; then
    ok "前置检查通过(集群可达, 镜像已在 ${#_MIP[@]} 台 master); VIP=${VIP}(显式指定)"
else
    ok "前置检查通过(集群可达, 镜像已在 ${#_MIP[@]} 台 master); VIP=${VIP}(自动推导)"
fi

# ---- 逐台渲染(必须各用各的 hostname, 否则脑裂) ----
_TMPDIR="$(mktemp -d)"
trap 'rm -rf "${_TMPDIR}"' EXIT

say "渲染 kube-vip manifest(每台 master 各自 hostname)..."
_i=0
while [ "${_i}" -lt "${#_MHOST[@]}" ]; do
    H="${_MHOST[${_i}]}"
    python3 "${RENDERER}" \
        --nodename "${H}" \
        --vip "${VIP}" \
        --interface "${KUBE_VIP_INTERFACE:-}" \
        --template "${TEMPLATE}" \
        --image-repo "${KUBE_VIP_IMAGE_REPO:-ghcr.io/kube-vip/kube-vip}" \
        --image-tag "${KUBE_VIP_VERSION:-v0.8.9}" \
        --cp-detect "$(bool_is_true "${KUBE_VIP_CP_DETECT:-true}" && echo true || echo false)" \
        > "${_TMPDIR}/${H}.yml" || { err "渲染失败: ${H}"; exit 1; }
    # 渲染后立即断言 —— vip_nodename 是脑裂唯一致命点, 宁可早失败
    _rendered="$(awk '/name: vip_nodename/{getline; print $2; exit}' "${_TMPDIR}/${H}.yml")"
    [ "${_rendered}" = "${H}" ] || { err "渲染出的 vip_nodename='${_rendered}' 与节点 '${H}' 不符 —— 会脑裂, 中止"; exit 1; }
    _addr="$(awk '/name: address/{getline; print $2; exit}' "${_TMPDIR}/${H}.yml")"
    [ "${_addr}" = "\"${VIP}\"" ] || { err "渲染出的 address=${_addr} 与 VIP=${VIP} 不符, 中止"; exit 1; }
    _i=$((_i + 1))
done
ok "manifest 渲染完成(${#_MHOST[@]} 台, vip_nodename 已逐台核对)"

say "分发并落位静态 Pod manifest..."
_i=0
while [ "${_i}" -lt "${#_MHOST[@]}" ]; do
    H="${_MHOST[${_i}]}"; IP="${_MIP[${_i}]}"
    # 与目标状态比对, 一致则跳过(等幂等)
    # ⚠ 远程命令里不能用 `cut -d' '` —— 那对单引号会提前闭合外层的单引号字符串,
    #   导致远端命令语法错乱、返回空值, 于是每次都误判为"有变化"(实测踩到)。
    _cur_hash="$(_ssh "${IP}" "sudo sha256sum ${MANIFEST_PATH} 2>/dev/null | cut -d\" \" -f1" || true)"
    _new_hash="$(sha256sum "${_TMPDIR}/${H}.yml" | cut -d' ' -f1)"
    if [ "${_cur_hash}" = "${_new_hash}" ]; then
        vlog "  ${IP}(${H}): manifest 已是最新, 跳过"
        _i=$((_i + 1)); continue
    fi
    _scp "${_TMPDIR}/${H}.yml" "${IP}" "/tmp/kube-vip.yml" || { err "  ${IP}: 分发失败"; exit 1; }
    _ssh "${IP}" "sudo cp /tmp/kube-vip.yml ${MANIFEST_PATH} && sudo chmod 640 ${MANIFEST_PATH} && rm -f /tmp/kube-vip.yml" \
        || { err "  ${IP}: 落位失败"; exit 1; }
    say "  ${IP}(${H}): manifest 已更新"
    _i=$((_i + 1))
done

# ---- 等待收敛并校验 ----
say "等待 kube-vip 选举收敛(20s)..."
sleep 20

_NRUN=0
for IP in "${_MIP[@]}"; do
    _ssh "${IP}" "sudo crictl ps 2>/dev/null | grep -q kube-vip" && _NRUN=$((_NRUN + 1))
done
[ "${_NRUN}" -ge 1 ] || {
    err "kube-vip 无一在运行(${_NRUN}/${#_MIP[@]})"
    err "排查: 镜像是否已预加载(见 docs/kube-vip-api-ha.md 第 8 节); 节点上 crictl ps -a | grep kube-vip"
    exit 1
}

# VIP 唯一性(脑裂检测): 必须恰好 1 台持有
_HOLDERS=()
for IP in "${_MIP[@]}"; do
    if _ssh "${IP}" "ip -4 -o addr show | grep -q '${VIP}/'"; then
        _HOLDERS+=("${IP}")
    fi
done
case "${#_HOLDERS[@]}" in
    1) ok "kube-vip 就位: ${_NRUN}/${#_MIP[@]} 在跑, VIP ${VIP} 唯一绑定于 ${_HOLDERS[0]}" ;;
    0) err "VIP ${VIP} 未绑定在任何 master 上 —— kube-vip 可能未完成选举"
       err "排查: 各 master 执行 crictl logs \$(crictl ps --name kube-vip -q) 看租约报错"
       exit 1 ;;
    *) err "VIP ${VIP} 同时绑定在 ${#_HOLDERS[@]} 台 master 上(${_HOLDERS[*]}) —— **脑裂**"
       err "常见原因: manifest 被批量分发成了同一个 vip_nodename(见模块头说明)"
       err "处置: 用本模块重跑(会按节点逐个渲染), 或临时摘除多余节点的 ${MANIFEST_PATH}"
       exit 1 ;;
esac

# ---- 经 VIP 的端到端可达性(从持有者本机验证, 避免部署机路由问题) ----
_HZ="$(_ssh "${_HOLDERS[0]}" "curl -sk --max-time 8 https://${VIP}:6443/healthz" || true)"
[ "${_HZ}" = "ok" ] && ok "经 VIP 访问 API 正常(https://${VIP}:6443/healthz)" \
    || { err "VIP 已绑定但 API 不可达(healthz 返回 '${_HZ}')"; exit 1; }

say ""
say "ℹ️ 后续(切换入口到 VIP)需另行确认: 见 docs/kube-vip-api-ha.md 第 7 节两阶段流程"
say "   验证: --steps verify_kube_vip"
