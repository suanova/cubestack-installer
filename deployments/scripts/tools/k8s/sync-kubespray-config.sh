#!/bin/bash
# ============================================================
# 将 config/cluster.conf 中的网络/IP 配置同步到 kubespray group_vars
# 避免在 kubespray 配置文件中硬编码环境 IP
# 用法: ./sync-kubespray-config.sh
# 数据源: config/cluster.conf (HOST_PHYS_IP / NODES / VM_SUBNET / KUBESPRAY_INV_DIR)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

INV_DIR="${KUBESPRAY_INV_DIR:-${REPO_ROOT}/deployments/kubespray/inventory/cubestack-cluster}"
[ -d "${INV_DIR}" ] || { err "Inventory 目录不存在: ${INV_DIR}, 请先运行 gen-inventory.sh"; exit 1; }

# ---------------- 从 cluster.conf 派生全局变量 ----------------
# bool 归一化: cluster.conf 可写 1/true/yes/on, 而 deploy-cluster.sh 的 TOGGLE 导出
# 会把模块开关 export 成字符串 "true" —— 统一归一化避免 `= "1"` 严格比较被跳过
# (曾致 4.1 节 registry 暴露方式/containerd 信任配置在 TOGGLE 导出场景下整体不执行,
#  addons.yml 残留 loadbalancer_ip 行 → nodeport 模式预检失败中断部署)。
_bool() { case "${1:-0}" in 1|true|yes|on) echo 1;; *) echo 0;; esac; }
REGISTRY_ENABLED="$(_bool "${REGISTRY_ENABLED:-0}")"
# API_IP / API_DOMAIN 由 lib-common load_config 统一提供:
#   API_IP     = APISERVER_ADDRESS(默认第一个 master IP, VM 与裸金属一致; 显式设置时保留)
#   API_DOMAIN = 跨网段统一入口域名(默认 k8s-api.cubestack.io, cluster.conf 可改)
# 注意: 实际写入配置的 API 入口地址统一为 API_ADDR = API_IP(第一个 master), 不使用宿主机物理 IP
MASTER_IPS=()    # master 节点 IP
WORKER_IPS=()    # worker 节点 IP
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    node_parse "${line}"
    case "${NODE_ROLE}" in
        master) MASTER_IPS+=("${NODE_IP}"); [ -z "${FIRST_MASTER_HOST:-}" ] && FIRST_MASTER_HOST="${NODE_HOSTNAME}" ;;
        worker) WORKER_IPS+=("${NODE_IP}") ;;
    esac
done

[ "${#MASTER_IPS[@]}" -gt 0 ] || { err "cluster.conf 中无 master 节点"; exit 1; }

# 第一个 worker IP(用于 Calico can-reach 探测),无 worker 时回退到 API 入口(第一个 master)
FIRST_WORKER="${WORKER_IPS[0]:-${API_IP}}"

# ---------------- kube-vip: API 入口地址(两阶段, 见 docs/kube-vip-api-ha.md 第 7 节) ----------------
# 静态校验先行(互斥 / MetalLB 池隔离 / 与节点 IP 冲突) —— 配置错就早失败, 不要等到 kubespray 跑一半
kube_vip_validate_config || exit 1

# 阶段判定: VIP 已绑=阶段二(切入口), 未绑=阶段一(写 master01, 本轮只让 VIP 就位)
_KV_VIP="$(kube_vip_derive)" || exit 1
_KV_OLD_ADDR="$(kube_vip_current_entry)"

# 阶段二的切换门(确认动作在**调用方**完成, 本脚本只执行)。
# ⚠ 本脚本的 stdout 会被 06_k8s_deploy.sh 重定向到 /dev/null(见该模块第 70 行), 所以
#   任何倒计时/确认提示放在这里用户都看不见, 还会白等。故约定:
#     · 调用方(06_k8s_deploy.sh)负责判阶段 + 提示 + 倒计时, 确认后 export KUBE_VIP_SWITCH_CONFIRMED=1
#     · 本脚本见到该标志才做切换; 未见则一律按阶段一(写 master01)—— fail-closed, 绝不自行切换
#     · 直接手工运行本脚本时若尚未确认, 会明确提示需要什么才能切换
if [ "${API_ENTRY_PHASE:-0}" = "2" ] && [ "${KUBE_VIP_SWITCH_CONFIRMED:-0}" != "1" ]; then
    warn "VIP ${_KV_VIP} 已就位, 但尚未获得切换确认 → 本次仍按阶段一处理(入口保持 ${_KV_OLD_ADDR})"
    warn "如需切换: 走 06_k8s_deploy.sh(会给出倒计时确认); 或 export KUBE_VIP_SWITCH_CONFIRMED=1 后重跑本脚本"
    API_ENTRY_PHASE=1
fi

_KV_NEW_ADDR="$(kube_vip_resolve_target)" || exit 1

# API 入口地址统一 = 本次运行的判定结果(阶段一=第一个 master / 阶段二=VIP)
API_ADDR="${_KV_NEW_ADDR}"
if [ "${API_ENTRY_PHASE:-0}" = "2" ]; then
    say "节点类型: kube-vip 阶段二 — API 入口=VIP(${API_ADDR})"
else
    say "节点类型: API 入口=第一个 master(${API_ADDR})"
fi
say "API 域名: ${API_DOMAIN}"
say "Master IPs: ${MASTER_IPS[*]}"
say "Worker IPs: ${WORKER_IPS[*]:-<无>}"

# ---------------- 1. 更新 all.yml ----------------
ALL_YML="${INV_DIR}/group_vars/all/all.yml"
if [ -f "${ALL_YML}" ]; then
    say "更新 ${ALL_YML} ..."
    # 防线: 入口地址一旦是"非数值字面量"(如手工填的 VIP 或 Jinja 表达式), 绝不能被我方的
    # sed 覆盖 —— 那会静默改掉真正生效的 API 入口。宁可停下让人确认。
    _prot="$(nonnumeric_entry "${ALL_YML}")"
    if [ -n "${_prot}" ] && [ "${_prot}" != "${API_ADDR}" ]; then
        err "all.yml 的 API 入口已是非数值地址 '${_prot}', 与本次要写入的 '${API_ADDR}' 不同:"
        err "  ${ALL_YML}"
        err "如确认要改成 ${API_ADDR}, 请手工修改该行后重跑(此保护避免自动覆盖手工/外部设置的入口)"
        exit 1
    fi
    unset _prot

    # loadbalancer_apiserver.address → 本次运行的 API 入口(阶段一=第一个 master / 阶段二=VIP)
    sed -i -E "s/^(\s+address:)\s+[0-9.]+(\s*#.*)?\$/\1 ${API_ADDR}\2/" "${ALL_YML}"

    # apiserver_loadbalancer_domain_name → 集群 API 域名
    sed -i -E "s/^apiserver_loadbalancer_domain_name:.*/apiserver_loadbalancer_domain_name: \"${API_DOMAIN}\"/" "${ALL_YML}"

    # supplementary_addresses_in_ssl_keys → API 域名 + 所有 master IP(不使用宿主机物理 IP)
    awk -v domain="${API_DOMAIN}" -v masters="${MASTER_IPS[*]}" '
        /^supplementary_addresses_in_ssl_keys:/ { in_sec=1; print; next }
        in_sec && /^[[:space:]]*-/ {
            # 跳过旧的域名/IP 条目(保留 k8s-api.cubestack.io / nova.local / lb.k8s.local 等历史域名)
            if ($0 ~ /nova\.local|lb\.k8s\.local/) { next }
            next
        }
        in_sec && !/^[[:space:]]*-/ {
            # 区块结束,输出 API 域名 + masters 条目
            print "  - " domain
            split(masters, arr, " ")
            for (i in arr) print "  - " arr[i]
            in_sec=0
            print
            next
        }
        { print }
    ' "${ALL_YML}" > "${ALL_YML}.tmp" && mv "${ALL_YML}.tmp" "${ALL_YML}"
    ok "已同步 loadbalancer_apiserver / apiserver_loadbalancer_domain_name / supplementary_addresses_in_ssl_keys"
else
    warn "未找到 ${ALL_YML},跳过"
fi

# ---------------- 2. 更新 k8s-net-calico.yml ----------------
CALICO_YML="${INV_DIR}/group_vars/k8s_cluster/k8s-net-calico.yml"
if [ -f "${CALICO_YML}" ]; then
    say "更新 ${CALICO_YML} ..."
    if grep -q "calico_ip_auto_method" "${CALICO_YML}"; then
        sed -i -E "s/^calico_ip_auto_method:.*/calico_ip_auto_method: \"can-reach=${FIRST_WORKER}\"/" "${CALICO_YML}"
    else
        echo "calico_ip_auto_method: \"can-reach=${FIRST_WORKER}\"" >> "${CALICO_YML}"
    fi
    ok "已同步 calico_ip_auto_method → can-reach=${FIRST_WORKER}"
else
    warn "未找到 ${CALICO_YML},跳过"
fi

# ---------------- 3. 更新 k8s-cluster.yml ----------------
CLUSTER_YML="${INV_DIR}/group_vars/k8s_cluster/k8s-cluster.yml"
if [ -f "${CLUSTER_YML}" ]; then
    say "更新 ${CLUSTER_YML} ..."

    # advertising address: **按节点各写各的**(kubespray 惯用法, 见 kubespray-defaults main.yml:628
    # 的 kube_apiserver_address)。曾统一写死第一个 master IP, 导致三个 apiserver 都对外宣告同一个
    # 地址 → kubernetes Service 的 EndpointSlice 只有一条 → 集群内经 Service 访问 API 也是单点。
    # ⚠ 这是 Jinja 表达式而非数值字面量, 因此**不再随主机 IP 变化而"同步"**, 只做幂等修复。
    update_advertise_address_yml "${CLUSTER_YML}" || exit 1
    ok "已同步 kube_apiserver_extra_args.advertise-address → 按节点各写各的(kube_apiserver_address)"

    # 集群内部网络 CIDR(从 cluster.conf 读取, 不硬编码在 group_vars 中)
    sed -i -E "s|^kube_service_addresses:[[:space:]]*[0-9.]+/[0-9]+|kube_service_addresses: ${KUBE_SERVICE_ADDRESSES:-10.233.0.0/18}|" "${CLUSTER_YML}"
    sed -i -E "s|^kube_pods_subnet:[[:space:]]*[0-9.]+/[0-9]+|kube_pods_subnet: ${KUBE_PODS_SUBNET:-10.233.64.0/18}|" "${CLUSTER_YML}"
    sed -i -E "s|^nodelocaldns_ip:[[:space:]]*[0-9.]+|nodelocaldns_ip: ${NODELOCAL_DNS_IP:-169.254.25.10}|" "${CLUSTER_YML}"
    # CNI 网络插件(默认 calico, 可选 cilium): 同步到 kube_network_plugin
    sed -i -E "s|^kube_network_plugin:[[:space:]]*[a-z]+|kube_network_plugin: ${KUBE_NETWORK_PLUGIN:-calico}|" "${CLUSTER_YML}"
    ok "已同步集群内部 CIDR: kube_service_addresses=${KUBE_SERVICE_ADDRESSES:-10.233.0.0/18} / kube_pods_subnet=${KUBE_PODS_SUBNET:-10.233.64.0/18} / nodelocaldns_ip=${NODELOCAL_DNS_IP:-169.254.25.10} / CNI=${KUBE_NETWORK_PLUGIN:-calico}"
else
    warn "集群内部 CIDR 未同步(未找到 ${CLUSTER_YML})"
fi

# ---------------- 3.1 更新 k8s-net-*.yml (CNI 数据面模式) ----------------
# 依据 cluster.conf 同步两个 CNI 的 group_vars, 支持同一套脚本选 calico 或 cilium:
#   · calico: CALICO_DATA_PATH=vxlan  → VXLAN overlay(VM/bridge 默认, mtu 1450=物理-50)
#             CALICO_DATA_PATH=direct → 无封装直连路由(裸金属物理网段, 避开 VXLAN 4789 被拦; mtu=物理 1500)
#   · cilium: CILIUM_TUNNEL_MODE=disabled → native routing(无隧道, 节点需同 L2, 自动直连路由 pod 网段)
#             CILIUM_TUNNEL_MODE=vxlan    → Cilium VXLAN overlay
# 默认值与既有部署一致(calico vxlan / cilium 未启用), 不影响已有功能。
CALICO_YML="${INV_DIR}/group_vars/k8s_cluster/k8s-net-calico.yml"
if [ -f "${CALICO_YML}" ]; then
    # calico 数据面固定为 IPIP 封装(默认方案, 已验证):
    #   本集群网络是 proxy-ARP/按 IP 转发的虚拟化 fabric: 丢 UDP 4789(VXLAN 端口)、不路由 pod CIDR,
    #   但放行 IPIP(proto4) → direct(无封装)与 VXLAN-4789 均不可行; IPIP 外层=节点 IP, 是唯一可靠路线。
    #   (限制与原理见 docs/cluster-architecture.md)
    # 注意: calico_network_backend 必须与数据面一致(漏配时 kubespray 默认 vxlan, 但 vxlan 又禁用
    #       → 无任何数据面 → 跨节点 pod 全断 → webhook 超时)
    sed -i -E "s/^calico_network_backend:.*/calico_network_backend: bird/" "${CALICO_YML}"
    sed -i -E "s/^calico_ipip_mode:.*/calico_ipip_mode: 'Always'/" "${CALICO_YML}"
    sed -i -E "s/^calico_vxlan_mode:.*/calico_vxlan_mode: 'Never'/" "${CALICO_YML}"
    sed -i -E "s/^calico_mtu:.*/calico_mtu: 1480/" "${CALICO_YML}"
    ok "已同步 ${CALICO_YML} → calico+IPIP(backend=bird, ipip_mode=Always, vxlan_mode=Never, mtu=1480)"
else
    warn "未找到 ${CALICO_YML}, 跳过 calico 数据面同步"
fi

CILIUM_YML="${INV_DIR}/group_vars/k8s_cluster/k8s-net-cilium.yml"
if [ -f "${CILIUM_YML}" ]; then
    _cilium_tunnel="${CILIUM_TUNNEL_MODE:-disabled}"
    # MTU: 显式 CILIUM_MTU 优先; 否则按模式默认(vxlan overlay=物理-50=1450, disabled=物理 1500)
    if [ -n "${CILIUM_MTU:-}" ]; then
        _cilium_mtu="${CILIUM_MTU}"
    elif [ "${_cilium_tunnel}" = "vxlan" ]; then
        _cilium_mtu=1450
    else
        _cilium_mtu=1500
    fi
    sed -i -E "s/^cilium_tunnel_mode:.*/cilium_tunnel_mode: ${_cilium_tunnel}/" "${CILIUM_YML}"
    sed -i -E "s/^cilium_mtu:.*/cilium_mtu: ${_cilium_mtu}/" "${CILIUM_YML}"
    if [ "${_cilium_tunnel}" = "disabled" ]; then
        # native routing(无隧道, 节点需同 L2): 自动直连路由 pod 网段
        sed -i -E "s/^cilium_auto_direct_node_routes:.*/cilium_auto_direct_node_routes: true/" "${CILIUM_YML}"
        sed -i -E "s|^cilium_native_routing_cidr:.*|cilium_native_routing_cidr: ${KUBE_PODS_SUBNET:-10.233.64.0/18}|" "${CILIUM_YML}"
        ok "已同步 ${CILIUM_YML} 数据面 → tunnel_mode=${_cilium_tunnel}(native routing), mtu=${_cilium_mtu}, native_cidr=${KUBE_PODS_SUBNET:-10.233.64.0/18}"
    else
        # overlay(vxlan): 不设 native routing CIDR(否则 Cilium 误以为 pod 网段可原生路由, 破坏隧道)
        sed -i -E "s/^cilium_auto_direct_node_routes:.*/cilium_auto_direct_node_routes: false/" "${CILIUM_YML}"
        sed -i -E 's|^cilium_native_routing_cidr:.*|cilium_native_routing_cidr: ""|' "${CILIUM_YML}"
        ok "已同步 ${CILIUM_YML} 数据面 → tunnel_mode=${_cilium_tunnel}(overlay), mtu=${_cilium_mtu}, native_cidr=\"\""
    fi
else
    warn "未找到 ${CILIUM_YML}, 跳过 cilium 数据面同步"
fi

# ---------------- 4. 更新 addons.yml (MetalLB 地址池) ----------------
ADDONS_YML="${INV_DIR}/group_vars/k8s_cluster/addons.yml"
METALLB_POOL="${METALLB_POOL:-10.244.2.1-10.244.2.254}"   # ⚠ 用区间排除 .0/.255(网络/广播地址), 勿用 10.244.2.0/24 这类 CIDR
if [ -f "${ADDONS_YML}" ]; then
    say "更新 ${ADDONS_YML} (MetalLB 地址池) ..."
    # 替换 address_pools.primary.ip_range 下的条目(首个 "- <CIDR>" 行), 幂等
    if grep -q "metallb_config:" "${ADDONS_YML}" && grep -q "ip_range:" "${ADDONS_YML}"; then
        # 先删除 ip_range 块内所有旧条目(块结束 = 下一行缩进小于 ip_range 的 - 行)
        # 注意: ip_range: 键行必须保留(print), 否则 addons.yml 变成非法 YAML(primary 下直接挂列表), 导致 ansible-inventory/部署失败
        awk -v pool="${METALLB_POOL}" '
            in_range == 0 && /^[[:space:]]*ip_range:/ { in_range=1; indent=match($0, /[^ ]/) - 1; print; next }
            in_range && NF == 0 { print; next }
            in_range && /^[[:space:]]*-/ && (match($0, /[^ ]/) - 1) > indent { next }
            in_range && (match($0, /[^ ]/) - 1) <= indent {
                printf "%*s- %s\n", indent + 2, "", pool
                in_range=0
            }
            { print }
            END { if (in_range) printf "%*s- %s\n", indent + 2, "", pool }
        ' "${ADDONS_YML}" > "${ADDONS_YML}.tmp" && mv "${ADDONS_YML}.tmp" "${ADDONS_YML}"
    else
        warn "addons.yml 中未找到 metallb_config/ip_range 区块, 跳过地址池同步"
    fi
    ok "已同步 MetalLB 地址池 → ${METALLB_POOL}"
else
    warn "未找到 ${ADDONS_YML},跳过 MetalLB 地址池同步"
fi

# ---------------- 5. 更新 addons.yml (kube-vip 控制平面 VIP) ----------------
# 落点是 addons.yml 而非 k8s-cluster.yml —— 仓库里原本就有 kubespray 自带的 kube-vip 注释块,
# 照它的键名写即可。重写逻辑在 lib-common.sh 的 update_kube_vip_addons_yml(它与 kubespray
# 入口脚本共用同一份, 避免两边写不同步导致互相覆盖)。
# ⚠ kube_vip_address 恒为 VIP(静态 Pod 的 args.address), 与 loadbalancer_apiserver.address
#   **不是同一个值** —— 后者按阶段在 master01 / VIP 之间切换(见本脚本开头的阶段判定)。
if [ -f "${ADDONS_YML}" ]; then
    say "更新 ${ADDONS_YML} (kube-vip 控制平面 VIP) ..."
    update_kube_vip_addons_yml "${ADDONS_YML}" "${_KV_VIP}" || exit 1
    if bool_is_true "${KUBE_VIP_ENABLED:-true}"; then
        ok "已同步 kube-vip → VIP=${_KV_VIP}, interface=${KUBE_VIP_INTERFACE:-<自动检测>}, 阶段=${API_ENTRY_PHASE:-1}"
    else
        ok "已同步 kube-vip → 关闭(kube_vip_enabled: false)"
    fi
fi

# REGISTRY_IP 自动派生统一在 lib-common.sh load_config 中完成(first_pool_addr):
#   留空 → 从 METALLB_POOL 取池内首地址(换环境只改池, 不用手改 VIP)

# ---------------- 4.1 更新 addons.yml (Registry Service 暴露方式) ----------------
# 依据 REGISTRY_SERVICE_TYPE 同步 registry Service 的 type 与对外端口:
#   loadbalancer → LoadBalancer + 固定 VIP(REGISTRY_IP), 避免 MetalLB auto-assign 分到网段边界地址
#   nodeport     → NodePort + 固定 REGISTRY_NODEPORT(不依赖 MetalLB)
# 集群内节点 /etc/hosts + containerd 引用的是 REGISTRY_DOMAIN, 与 Service type 无关
#
# 写/清 addons.yml 的 registry_service_annotations(共用 MetalLB VIP 的 sharing key, 见 lib-common.sh
# 顶部约定)。**必须写进 manifest 而不是事后 kubectl annotate**: kubespray 每次重跑都会重新
# apply 这个 Service, 手工补的注解会被冲掉; 写进模板变量才能跟着 manifest 长期存在。
# 注解本身只是"允许他人与本 Service 共用同一 VIP"的许可, 没人请求该 IP 时无任何作用 →
# loadbalancer 模式下无条件写入; 离开该模式时清理掉, 免留跨模式残留。
# 用法: _sync_registry_annotations <注解键> <值>   (键为空 = 只清理不写入)
_sync_registry_annotations() {
    python3 - "${ADDONS_YML}" "${1:-}" "${2:-}" <<'PYEOF'
import re, sys
path, ann, val = sys.argv[1:4]
lines = open(path).read().split('\n')
out, i = [], 0
# ① 先摘掉旧的 registry_service_annotations 块(键行 + 其后所有缩进更深的行)
while i < len(lines):
    if re.match(r'^registry_service_annotations:', lines[i]):
        i += 1
        while i < len(lines) and (lines[i].strip() == '' or lines[i].startswith((' ', '\t'))):
            i += 1
        continue
    out.append(lines[i]); i += 1
# ② 需要写入时插到 registry_service_type 行之后(该项已由上面的分支写定)
if ann:
    res = []
    for l in out:
        res.append(l)
        if re.match(r'^[ \t]*registry_service_type:', l):
            res.append('registry_service_annotations:')
            res.append('  %s: %s' % (ann, val))
    out = res
open(path, 'w').write('\n'.join(out) + '\n')
PYEOF
}

if [ -f "${ADDONS_YML}" ] && [ "${REGISTRY_ENABLED:-0}" = "1" ]; then
    # REGISTRY_IP 自动派生: 留空则从 METALLB_POOL 取首地址(换环境只改池, 不用手改 VIP)
    # load_config 已派生, 此处仅兜底(防单独直接运行本脚本时未走 load_config 派生分支)
    if [ -z "${REGISTRY_IP:-}" ]; then
        REGISTRY_IP="$(first_pool_addr "${METALLB_POOL:-}")"
        [ -n "${REGISTRY_IP}" ] || REGISTRY_IP="10.244.2.100"
        say "  REGISTRY_IP 留空, 自动取 METALLB_POOL=${METALLB_POOL} 首地址 → ${REGISTRY_IP}(需固定可显式设 REGISTRY_IP)"
    fi
    case "${REGISTRY_SERVICE_TYPE:-loadbalancer}" in
        nodeport)
            say "更新 ${ADDONS_YML} (registry Service → NodePort ${REGISTRY_NODEPORT:-31148}) ..."
            sed -i -E "s|^([[:space:]]*)registry_service_type:.*|\1registry_service_type: NodePort|" "${ADDONS_YML}"
            if grep -qE '^[[:space:]]*#?[[:space:]]*registry_service_nodeport:' "${ADDONS_YML}"; then
                sed -i -E "s|^([[:space:]]*)#?[[:space:]]*registry_service_nodeport:.*|\1registry_service_nodeport: \"${REGISTRY_NODEPORT:-31148}\"|" "${ADDONS_YML}"
            else
                sed -i -E "s|^([[:space:]]*)registry_service_type:.*|&\n\1registry_service_nodeport: \"${REGISTRY_NODEPORT:-31148}\"|" "${ADDONS_YML}"
            fi
            # NodePort 模式下残留的 loadbalancer_ip 行会让 kubespray 校验失败(定义了 VIP 但 type != LoadBalancer), 统一注释掉
            sed -i -E "s|^([[:space:]]*)(#?)[[:space:]]*registry_service_loadbalancer_ip:.*|\1# registry_service_loadbalancer_ip: 已由 sync 脚本禁用(nodeport 模式)|" "${ADDONS_YML}"
            _sync_registry_annotations "" ""   # 离开 loadbalancer 模式 → 清掉共用 VIP 注解(免留残留)
            ok "已同步 registry Service → NodePort:${REGISTRY_NODEPORT:-31148}"
            ;;
        *)  # loadbalancer(默认)
            say "更新 ${ADDONS_YML} (registry Service → LoadBalancer ${REGISTRY_IP}) ..."
            sed -i -E "s|^([[:space:]]*)registry_service_type:.*|\1registry_service_type: LoadBalancer|" "${ADDONS_YML}"
            if grep -qE '^[[:space:]]*#?[[:space:]]*registry_service_loadbalancer_ip:' "${ADDONS_YML}"; then
                sed -i -E "s|^([[:space:]]*)#?[[:space:]]*registry_service_loadbalancer_ip:.*|\1registry_service_loadbalancer_ip: ${REGISTRY_IP}|" "${ADDONS_YML}"
            else
                sed -i -E "s|^([[:space:]]*)registry_service_type:.*|&\n\1registry_service_loadbalancer_ip: ${REGISTRY_IP}|" "${ADDONS_YML}"
            fi
            # LoadBalancer 模式下残留的 nodeport 行会让 kubespray 校验对不上(registry_service_nodeport is defined → fail), 且未加引号的 int 会触发 | length 崩溃, 统一注释掉
            sed -i -E "s|^([[:space:]]*)#?[[:space:]]*registry_service_nodeport:.*|\1# registry_service_nodeport: 残留值已由 sync 脚本禁用|" "${ADDONS_YML}"
            # ★ 2026-09-06 修复: 若 addons.yml 是 nodeport 残留版(registry_service_nodeport 未注释/无
            #   loadbalancer_ip 行), 上面注释 nodeport 后还要**确保 loadbalancer_ip 行存在**,
            #   否则 kubespray 校验缺 loadbalancer_ip 也 fail。同时 LoadBalancer 模式下 registry_service_nodeport
            #   必须为注释状态(曾因模板残留 nodeport 行 + 无 loadbalancer_ip → k8s_deploy 预检报
            #   "registry_service_nodeport(metallb 模式须注释)" 中断部署)。
            if ! grep -qE '^[[:space:]]*registry_service_loadbalancer_ip:' "${ADDONS_YML}"; then
                sed -i -E "s|^([[:space:]]*)registry_service_type:.*|&\n\1registry_service_loadbalancer_ip: ${REGISTRY_IP}|" "${ADDONS_YML}"
            fi
            # 共用 VIP 许可(见上方 _sync_registry_annotations 说明): 允许 registry 与
            # 其它 Service 共用一个 MetalLB VIP、以端口区分(registry 占 5000)。
            _sync_registry_annotations "${SHARED_VIP_ANNOTATION}" "${SHARED_VIP_KEY}"
            ok "已同步 registry Service → LoadBalancer:${REGISTRY_IP}(允许共用 VIP: ${SHARED_VIP_ANNOTATION}=${SHARED_VIP_KEY})"
            ;;
    esac
fi

# ---------------- 6. 更新 containerd.yml (含内置 registry 的 HTTP 信任配置) ----------------
# kubespray 的 containerd_registries_mirrors 变量生成 config_path=certs.d/<host>/hosts.toml,
# 让集群内节点 containerd 能直接拉取无 TLS 的 registry。用 python 幂等替换(去旧块再追加)。
CONTAINERD_YML="${INV_DIR}/group_vars/all/containerd.yml"
if [ -f "${CONTAINERD_YML}" ]; then
    say "更新 ${CONTAINERD_YML} (containerd 信任 registry) ..."
    # 镜像 host 按暴露模式二选一:
    #   nodeport(默认) → http://<首个 master IP>:${REGISTRY_NODEPORT} —— 节点 containerd 客户端侧
    #     直连 NodePort 拉取, 不依赖 /etc/hosts 解析与节点 iptables(kube-proxy 会重置节点规则);
    #   metallb         → http://registry.cubestack.io:PORT(经 /etc/hosts → VIP)。
    _EXPOSE="$(echo "${SERVICE_EXPOSE_MODE:-nodeport}" | tr '[:upper:]' '[:lower:]')"
    if [ "${_EXPOSE}" = "nodeport" ]; then
        _MIRROR_HOST="http://${REGISTRY_IP}:${REGISTRY_NODEPORT:-31148}"
    else
        _MIRROR_HOST="http://${REGISTRY_DOMAIN:-registry.cubestack.io}:${REGISTRY_PORT:-5000}"
    fi
    unset _EXPOSE
    python3 - "${CONTAINERD_YML}" "${REGISTRY_ENABLED:-0}" "${REGISTRY_DOMAIN:-registry.cubestack.io}" "${REGISTRY_IP:-10.244.2.100}" "${REGISTRY_PORT:-5000}" "${_MIRROR_HOST}" << 'PYEOF'
import re, sys
path, enabled, d, ip, port, mhost = sys.argv[1:7]
lines = open(path).read().split('\n')
out, i = [], 0
while i < len(lines):
    line = lines[i]
    if re.match(r'^containerd_registries_mirrors:', line):
        i += 1   # 整块(含后续更缩进/注释行)删除
        while i < len(lines):
            l = lines[i]
            if l.strip() == '' or l.startswith((' ', '\t')) or re.match(r'^[-#]', l):
                i += 1
            else:
                break
        continue
    out.append(line); i += 1
if enabled == "1":
    # 幂等: 先清掉历史 else 分支残留的注释行(REGISTRY_ENABLED=0 场景写的), 再写真实配置
    marker = '# containerd_registries_mirrors:'
    out = [l for l in out if not l.startswith(marker)]
    out.append('containerd_registries_mirrors:')
    out.append(f'  - prefix: "{d}:{port}"')
    out.append(f'    server: "http://{d}:{port}"')
    out.append('    mirrors:')
    out.append(f'      - host: "{mhost}"')
    out.append('        capabilities: ["pull", "resolve"]')
    out.append('        skip_verify: true')
else:
    # 幂等: 先清掉历史重复累积的注释行, 再追加一条(否则每次运行都会多一条)
    marker = '# containerd_registries_mirrors:'
    out = [l for l in out if not l.startswith(marker)]
    out.append('# containerd_registries_mirrors:  # (REGISTRY_ENABLED=0, 未配置)')
open(path, 'w').write('\n'.join(out) + '\n')
PYEOF
    ok "已同步 containerd registry 信任 → ${REGISTRY_DOMAIN:-registry.cubestack.io}:${REGISTRY_PORT:-5000}(镜像 host: ${_MIRROR_HOST})"
else
    warn "未找到 ${CONTAINERD_YML},跳过 containerd registry 配置"
fi

# ---------------- 7. 生成 registry.yml(供 patch-playbooks/cubestack-registry.yml 读取) ----------------
REGISTRY_YML="${INV_DIR}/group_vars/all/registry.yml"
{
    echo "# Generated by sync-kubespray-config.sh — 供 patch-playbooks/cubestack-registry.yml 读取, 请勿手工编辑"
    echo "registry_domain: \"${REGISTRY_DOMAIN:-registry.cubestack.io}\""
    echo "registry_ip: \"${REGISTRY_IP:-10.244.2.100}\""
    echo "registry_port: \"${REGISTRY_PORT:-5000}\""
} > "${REGISTRY_YML}"
ok "已生成 ${REGISTRY_YML}: ${REGISTRY_DOMAIN:-registry.cubestack.io} → ${REGISTRY_IP:-10.244.2.100}:${REGISTRY_PORT:-5000}"

# ---------------- 5. 更新 addons.yml (组件启用开关, 数据源: cluster.conf) ----------------
# REGISTRY_ENABLED / METALLB_ENABLED / LOCAL_PATH_ENABLED / METRICS_SERVER_ENABLED
# HELM_ENABLED / INGRESS_NGINX_ENABLED / DASHBOARD_ENABLED / CERT_MANAGER_ENABLED
bash "${SCRIPT_DIR}/tools/k8s/sync-addons-config.sh"

echo "---------------------------------------------"
ok "kubespray 配置已从 cluster.conf 同步完成"
echo "  API 入口地址: ${API_ADDR}:6443"
echo "  Master IPs: ${MASTER_IPS[*]}"
echo "  Calico can-reach: ${FIRST_WORKER}"
echo "  MetalLB 地址池: ${METALLB_POOL}"