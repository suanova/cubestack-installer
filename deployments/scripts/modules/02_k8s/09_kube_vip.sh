#!/bin/bash
# ============================================================
# MODULE: kube_vip
# DESC: API Server VIP 高可用 — 在各 master 部署 kube-vip 静态 Pod
#       (双向收敛: 开关开=安装/修复, 开关关=清理干净)
# PHASE: k8s
# DEFAULT: 1
# REPEAT: 1
# TOGGLE: KUBE_VIP_ENABLED
# REQUIRES: k8s_deploy
# 说明:
#   · **REQUIRES: k8s_deploy 是为了定序, 不是为了拉依赖**: 本模块必须在 k8s_deploy **之后**跑 ——
#     ① 前置自检要求集群已存在(is_cluster_live);
#     ② 关闭态清理要求 API 入口已由 k8s_deploy 退回 master01(否则护栏会拦停, 见 kube_vip_cleanup)。
#     ⚠ 没有这条声明时, 拓扑排序把本模块排在 k8s_deploy **之前**(模块文件序号 09 > 06 不足以定序)。
#       后果是**全新集群上整个部署会在 k8s_deploy 之前中断**: 本模块因"集群不可达"exit 1,
#       而 deploy-cluster.sh:611 是 `run_module "${key}" || { FAILED=1; break; }` —— 一失败即整体中止。
#     ⚠ 本行历史上**故意缺席**, 理由是"写了 REQUIRES 会让 --steps kube_vip 连带拉起整套 kubespray"。
#       该顾虑现已不成立(两条规则共同保证, 实测 --steps kube_vip 只跑本模块):
#         a) --steps 精确模式下, 依赖已完成(REPEAT≠1 且 state=done)时不拉入执行;
#         b) 基座模块(k8s_deploy 在 BASE_MODULES 内)未被显式命名时会被剔除。
#   · 本模块**不依赖 kubespray 的 inventory 状态机**: 四项前置条件靠 SSH 自己探测。
#   · **DEFAULT: 1(与其它 operator 不同, 是刻意的)**: 本模块必须**每轮都跑到**, 否则关掉开关时
#     没有任何东西去删残留的 manifest。带 TOGGLE 的模块默认只在开关为 true 时进 RUN_STEPS,
#     开关一变 false 就彻底不被调度 —— 于是 `KUBE_VIP_ENABLED=false` 重跑只会打印一行"跳过",
#     静态 Pod 照跑、VIP 照被持有、还继续参与选举(与"幂等"正好相反)。
#     DEFAULT: 1 让本模块成为全量运行的常驻项, 由脚本内部按开关分派到"安装"或"清理"分支。
#     ⚠ 配套改动: deploy-cluster.sh 的"为 RUN_STEPS 中的 TOGGLE 模块导出开关=true"那个循环
#       加了 `! module_default_on` 前置条件 —— 否则它会无条件把 KUBE_VIP_ENABLED 冲成 true,
#       用户的 false 永远到不了这里。显式 `--enable kube_vip` 不受影响(那条路径写回 cluster.conf)。
#   · **单一写入者**: /etc/kubernetes/manifests/kube-vip.yml 由本模块独占。
#     addons.yml 里恒写 kube_vip_enabled: false, 让 kubespray 不要插手。
#     原因: 两边渲染结果**必然不同** —— kubespray 对**首台** master 会把 hostPath 渲染成
#     super-admin.conf(roles/kubernetes/node/tasks/loadbalancer/kube-vip.yml:26-31 的 set_fact),
#     我们的渲染器恒用 admin.conf → 每次全量运行该文件被改写两次 → kube-vip pod 重启两次。
#     详见 lib-common.sh#update_kube_vip_addons_yml 与 docs/kube-vip-api-ha.md 第 18 节。
#   · **等幂等**: 目标状态 = 「每台 master 上都有 m/ kube-vip 静态 Pod, 且 VIP 恰好绑在其中一台」。
#     基于该状态收敛, 而不是"装过就跳过" —— 支持修复被手工改坏的 manifest。
#     内容一致时按 sha256 比对跳过(不碰文件 → 不重启 kube-vip → 零抖动)。
#   · **两种 VIP 来源**(K8S_API_VIP):
#       显式值 → 直接用, 不探测
#       留空   → 自动推导: 在各 master 上逐地址探测(ICMP 无应答 且 6443 不可达 = 空闲),
#                排除节点 IP 与 METALLB_POOL, 起点 K8S_API_VIP_START(默认 210)
#   · **离线**: 镜像来自 offline-files(见第 8 节), 节点无需外网/私服凭据。
#     ⚠ 该镜像必须在 PRELOAD_IMAGE_PATTERNS 内, 否则预加载会把它裁掉 → 本模块的前置自检
#       会以"以下 master 上缺少 kube-vip 镜像"硬失败。
#       (注: 早期版本的说明是"否则首装 kubeadm init 会失败" —— 那是 kubespray 还在 init 之前
#        写 manifest 时的说法。现在静态 Pod 只由本模块在集群起来之后落位, 该依赖已不存在。)
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

MANIFEST_PATH="/etc/kubernetes/manifests/kube-vip.yml"

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

# ============================================================
# 关闭态: 强制清理(目标状态 = 各 master 上无 kube-vip 静态 Pod, 且 VIP 已释放)
# ============================================================
# 这是 docs/kube-vip-api-ha.md §7.4 早已承诺过的行为("KUBE_VIP_ENABLED=false 重跑 →
# 删 static pod manifest, 控制平面零影响")。原实现只打印一行"跳过"就退出 —— 承诺没兑现,
# 结果是"以为关了, 其实 kube-vip 照跑、VIP 照被持有、还继续参与选举"。
#
# ⚠ 清理**绝不能**在 API 入口仍指向 VIP 时做 —— 那会让全集群 API 立刻失联,
#   这个"幂等"功能会变成一个自毁按钮。
#   正常全量路径下入口已经先退回 master01(kube_vip_resolve_target 在开关关闭时返回第一个
#   master, 由 06_k8s_deploy 在本模块之前跑完), 但本模块也可被 `--steps kube_vip` 单独调用,
#   那时 all.yml 可能还停在 VIP 上 —— 所以下面这道护栏不是冗余, 是单跑路径上唯一的保险。
kube_vip_cleanup() {
    say "kube-vip 已关闭(KUBE_VIP_ENABLED=false) → 检查各 master 上的静态 Pod manifest"

    # ---- 0. 一次探活: 既判断可达性, 也判断是否真有 manifest ----
    # 先全量探活再动手 —— "半清理"(清了两台漏了一台)比不清理更难排查。
    # 顺带先看清"有没有东西可清", 因为这决定了后面那道护栏要不要生效(见第 2 步)。
    local i _bad=() _present=()
    for i in "${!_MIP[@]}"; do
        if _ssh "${_MIP[${i}]}" "sudo test -f ${MANIFEST_PATH}"; then
            _present+=("${i}")
        elif ! _ssh "${_MIP[${i}]}" "true"; then
            _bad+=("${_MIP[${i}]}(${_MHOST[${i}]})")
        fi
    done
    if [ "${#_bad[@]}" -gt 0 ]; then
        err "以下 master SSH 不可达: ${_bad[*]}"
        err "已中止, **未做任何删除**; 请先恢复连通再重跑(避免半清理)"
        return 1
    fi

    # ---- 1. 本来就没有 manifest → 已经是目标状态, 直接收敛 ----
    if [ "${#_present[@]}" -eq 0 ]; then
        ok "kube-vip 已清除: ${#_MIP[@]} 台 master 上都没有 ${MANIFEST_PATH}(已是干净状态)"
        say ""
        say "ℹ️ 重新启用: KUBE_VIP_ENABLED=true 后重跑本模块(证书 SAN 仍在, 不必重签)"
        return 0
    fi

    # ---- 2. 阶段护栏: 确有东西要删时才生效(fail-closed) ----
    # ⚠ 清理**绝不能**在 API 入口仍指向 VIP 时做 —— 那会让全集群 API 立刻失联,
    #   这个"幂等"功能会变成一个自毁按钮。
    #
    # 判据刻意做成 fail-closed: **只有能证明入口不是 VIP 才放行**, 而不是"等于记录的 VIP 才拦"。
    # 后者的漏洞很实际: 记录的 VIP 可能读不到(addons.yml 的 kube_vip_address 被旧版 sync 删过键,
    # 而 K8S_API_VIP 又留空)—— 此时"不等于记录值"根本不能证明安全。宁可拦停, 不能自毁。
    #   · 入口为空(无 inventory / 从未部署)      → 放行(没有入口可失联)
    #   · 入口 = 某个节点 IP(阶段一直连 master) → 放行(与 kube-vip 无关)
    #   · 其它一切(等于 VIP / 记录缺失 / 是别的地址) → 拒绝
    local cur recorded _safe=0 _ip
    cur="$(kube_vip_current_entry)"
    recorded="$(kube_vip_recorded_address)"
    [ -n "${recorded}" ] || recorded="${K8S_API_VIP:-}"

    if [ -z "${cur}" ]; then
        _safe=1
    else
        for _ip in $(all_node_ips); do
            [ "${_ip}" = "${cur}" ] && { _safe=1; break; }
        done
    fi
    if [ "${_safe}" = "0" ]; then
        err "拒绝清理: API 入口 loadbalancer_apiserver.address=${cur} 既不是空的、也不是任何节点 IP,"
        err "  无法证明它不是 kube-vip 的 VIP —— 此时删 kube-vip 有可能让全集群 API 立刻失联。"
        if [ -n "${recorded}" ]; then
            err "  (记录的 kube-vip VIP = ${recorded})"
        else
            err "  (且未取到记录的 VIP: addons.yml 无 kube_vip_address, K8S_API_VIP 也为空)"
        fi
        err "正确顺序(两步, 反了就是自毁):"
        err "  ① 先把入口退回 master01: 跑一次全量, 或 --steps k8s_deploy"
        err "  ② 确认入口已回退后, 再关开关清理: --steps kube_vip"
        return 1
    fi
    vlog "阶段护栏通过: API 入口=${cur:-<空>}(非 VIP)"

    # ---- 3. 删除 ----
    # 必须**全删**(而不是只删这里列出的): 只删当前持有 VIP 的那台, 下次选举另一台又会把 VIP 绑回去
    for i in "${!_present[@]}"; do
        if _ssh "${_MIP[${i}]}" "sudo rm -f ${MANIFEST_PATH}"; then
            say "  ${_MIP[${i}]}(${_MHOST[${i}]}): 已删除 ${MANIFEST_PATH}"
        else
            err "  ${_MIP[${i}]}(${_MHOST[${i}]}): 删除 ${MANIFEST_PATH} 失败"
            return 1
        fi
    done

    # ---- 4. 校验: 只删掉文件不等于地址释放了 ----
    # kube-vip 收到 SIGTERM 时会主动 DeleteIP 释放 VIP(clusterLeaderElection.go), 所以网卡上的
    # 地址不用我们额外清 —— 但要**验证它真的释放了**, 而不是删了个文件就当成功。
    say "等待 kube-vip 退出并释放 VIP(15s)..."
    sleep 15

    local _run=() _held=()
    for i in "${!_MIP[@]}"; do
        if _ssh "${_MIP[${i}]}" "sudo crictl ps 2>/dev/null | grep -q kube-vip"; then
            _run+=("${_MIP[${i}]}(${_MHOST[${i}]})")
        fi
        if [ -n "${recorded}" ]; then
            if _ssh "${_MIP[${i}]}" "ip -4 -o addr show 2>/dev/null | grep -q '${recorded}/'"; then
                _held+=("${_MIP[${i}]}(${_MHOST[${i}]})")
            fi
        fi
    done

    if [ "${#_run[@]}" -gt 0 ]; then
        err "仍有 kube-vip 容器在运行: ${_run[*]}"
        err "排查: 各节点 sudo crictl ps -a | grep kube-vip; 确认 ${MANIFEST_PATH} 确已删除"
        return 1
    fi
    if [ "${#_held[@]}" -gt 0 ]; then
        err "VIP ${recorded} 仍绑定在: ${_held[*]} —— 静态 Pod 已删但地址没释放"
        err "处置: 在该节点 sudo crictl rm -f \$(sudo crictl ps -a --name kube-vip -q); 或重启该节点"
        return 1
    fi

    if [ -n "${recorded}" ]; then
        ok "kube-vip 已清除: ${#_present[@]}/${#_MIP[@]} 台有 manifest 的 master 已清理, VIP ${recorded} 已从网卡释放"
    else
        ok "kube-vip 已清除: ${#_present[@]}/${#_MIP[@]} 台有 manifest 的 master 已清理"
        warn "未取到记录的 VIP(addons.yml 无 kube_vip_address 且 K8S_API_VIP 为空), 已跳过 VIP 释放校验"
    fi
    say ""
    say "ℹ️ 重新启用: KUBE_VIP_ENABLED=true 后重跑本模块(证书 SAN 仍在, 不必重签)"
    return 0
}

if ! bool_is_true "${KUBE_VIP_ENABLED:-false}"; then
    kube_vip_cleanup
    exit $?
fi

# ============================================================
# 开启态: 收敛安装
# ============================================================
kube_vip_validate_config || exit 1
init_remote_kubectl || exit 1

TEMPLATE="${KUBESPRAY_DIR:-${REPO_ROOT}/deployments/kubespray/kubespray}/roles/kubernetes/node/templates/manifests/kube-vip.manifest.j2"
RENDERER="${SCRIPT_DIR}/tools/k8s/render-kube-vip-manifest.py"
[ -f "${TEMPLATE}" ] || { err "未找到 kubespray manifest 模板: ${TEMPLATE}"; exit 1; }
[ -f "${RENDERER}" ] || { err "未找到渲染器: ${RENDERER}"; exit 1; }
command -v python3 >/dev/null 2>&1 || { err "需要 python3(渲染 kubespray 模板)"; exit 1; }

# ---- VIP: 显式优先(all.yml 显式值也算), 否则自动推导 ----
# ⚠ 只推导一次: kube_vip_derive 会对每台 master 做逐地址探测(SSH + ICMP + TCP), 很贵,
#   且两次调用之间集群状态若变化还可能给出不同答案。
VIP="$(kube_vip_derive)" || exit 1
[ -n "${VIP}" ] || { err "无法确定 VIP"; exit 1; }

# ---- 前置条件自检(用自检替代 REQUIRES, 避免 --steps kube_vip 连带拉起整套 kubespray) ----
if ! is_cluster_live; then
    err "集群不可达或尚未部署(首个 master 上列不出 Node)"
    err "kube-vip 需要一个已存在的集群; 请先跑 --steps k8s_deploy"
    exit 1
fi

# 镜像必须已在各节点 —— 离线方案的硬前提
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
    if _ssh "${IP}" "sudo crictl ps 2>/dev/null | grep -q kube-vip"; then
        _NRUN=$((_NRUN + 1))
    fi
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
