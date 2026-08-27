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
# API_IP / API_DOMAIN 由 lib-common load_config 统一提供:
#   API_IP     = APISERVER_ADDRESS(NAT 模式=第一个 master IP / HAProxy IP), 回退 HOST_PHYS_IP(桥接=宿主机物理 IP)
#   API_DOMAIN = 跨网段统一入口域名(默认 k8s-api.nova.local)
# 注意: 实际写入配置的 API 入口地址为 API_ADDR(本脚本计算)——全裸金属集群取第一个 master IP
#       (宿主机不在集群网络, 无法作为 API 入口); 含 VM 集群沿用 API_IP(跨网段 worker 经宿主机 DNAT 访问)
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

# 第一个 worker IP(用于 Calico can-reach 探测),无 worker 时回退到宿主机 IP
FIRST_WORKER="${WORKER_IPS[0]:-${API_IP}}"

# 全裸金属检测: cluster.conf 不再区分 vm/bm, 以 VM 配置文件(tools/vm/vm-nodes.conf)是否有节点判定
#   → 无 VM 定义 = 全裸金属: 宿主机(部署机)不在集群网络, API 入口不能用宿主机物理 IP, 取第一个 master IP
ALL_BM=1
vm_conf_has_nodes && ALL_BM=0

# API 入口地址: 全裸金属 → 第一个 master IP; 含 VM(跨网段 worker 经宿主机 DNAT 访问)→ 宿主机物理 IP
if [ "${ALL_BM}" = "1" ]; then
    API_ADDR="${MASTER_IPS[0]}"
else
    API_ADDR="${API_IP}"
fi

if [ "${ALL_BM}" = "1" ]; then
    say "节点类型: 全裸金属 → API 入口=第一个 master(${API_ADDR})"
else
    say "节点类型: 含 VM → API 入口=宿主机物理 IP(${API_ADDR})"
fi
say "宿主机 IP: ${API_IP}"
say "API 域名: ${API_DOMAIN}"
say "Master IPs: ${MASTER_IPS[*]}"
say "Worker IPs: ${WORKER_IPS[*]:-<无>}"

# ---------------- 1. 更新 all.yml ----------------
ALL_YML="${INV_DIR}/group_vars/all/all.yml"
if [ -f "${ALL_YML}" ]; then
    say "更新 ${ALL_YML} ..."
    # loadbalancer_apiserver.address → API 入口地址(全裸金属=第一个 master / 含 VM=宿主机物理 IP)
    sed -i -E "s/^(\s+address:)\s+[0-9.]+(\s*#.*)?\$/\1 ${API_ADDR}\2/" "${ALL_YML}"

    # apiserver_loadbalancer_domain_name → 集群 API 域名
    sed -i -E "s/^apiserver_loadbalancer_domain_name:.*/apiserver_loadbalancer_domain_name: \"${API_DOMAIN}\"/" "${ALL_YML}"

    # supplementary_addresses_in_ssl_keys → API 域名 + [宿主机 IP(仅含 VM 时)] + 所有 master IP
    # 全裸金属时 API 入口即第一个 master, 已在 masters 中, 不再单独加宿主机 IP
    awk -v host="${API_ADDR}" -v domain="${API_DOMAIN}" -v masters="${MASTER_IPS[*]}" -v is_bm="${ALL_BM}" '
        /^supplementary_addresses_in_ssl_keys:/ { in_sec=1; print; next }
        in_sec && /^[[:space:]]*-/ {
            # 跳过旧的域名/IP 条目(保留 k8s-api.nova.local)
            if ($0 ~ /nova\.local|lb\.k8s\.local/) { next }
            next
        }
        in_sec && !/^[[:space:]]*-/ {
            # 区块结束,输出 API 域名 + [宿主机(仅含 VM)] + masters 条目
            print "  - " domain
            if (is_bm != "1") print "  - " host "           # 宿主机物理 IP(worker 通过此地址访问 API Server)"
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
    if grep -q "advertise-address" "${CLUSTER_YML}"; then
        sed -i -E "s/^(\s+advertise-address:)\s+\"[0-9.]+\"/\1 \"${API_ADDR}\"/" "${CLUSTER_YML}"
    else
        # 在 kube_apiserver_extra_args 下追加 advertise-address
        sed -i -E "/^kube_apiserver_extra_args:/a\  advertise-address: \"${API_ADDR}\"" "${CLUSTER_YML}"
    fi
    ok "已同步 kube_apiserver_extra_args.advertise-address → ${API_ADDR}"
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

# REGISTRY_IP 自动派生统一在 lib-common.sh load_config 中完成(first_pool_addr):
#   留空 → 从 METALLB_POOL 取池内首地址(换环境只改池, 不用手改 VIP)

# ---------------- 4.1 更新 addons.yml (Registry Service 暴露方式) ----------------
# 依据 REGISTRY_SERVICE_TYPE 同步 registry Service 的 type 与对外端口:
#   loadbalancer → LoadBalancer + 固定 VIP(REGISTRY_IP), 避免 MetalLB auto-assign 分到网段边界地址
#   nodeport     → NodePort + 固定 REGISTRY_NODEPORT(不依赖 MetalLB)
# 集群内节点 /etc/hosts + containerd 引用的是 REGISTRY_DOMAIN, 与 Service type 无关
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
            ok "已同步 registry Service → LoadBalancer:${REGISTRY_IP}"
            ;;
    esac
fi

# ---------------- 6. 更新 containerd.yml (含内置 registry 的 HTTP 信任配置) ----------------
# kubespray 的 containerd_registries_mirrors 变量生成 config_path=certs.d/<host>/hosts.toml,
# 让集群内节点 containerd 能直接拉取无 TLS 的 registry。用 python 幂等替换(去旧块再追加)。
CONTAINERD_YML="${INV_DIR}/group_vars/all/containerd.yml"
if [ -f "${CONTAINERD_YML}" ]; then
    say "更新 ${CONTAINERD_YML} (containerd 信任 registry) ..."
    python3 - "${CONTAINERD_YML}" "${REGISTRY_ENABLED:-0}" "${REGISTRY_DOMAIN:-registry.local}" "${REGISTRY_IP:-10.244.2.100}" "${REGISTRY_PORT:-5000}" << 'PYEOF'
import re, sys
path, enabled, d, ip, port = sys.argv[1:6]
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
    out.append('containerd_registries_mirrors:')
    out.append(f'  - prefix: "{d}:{port}"')
    out.append(f'    server: "http://{d}:{port}"')
    out.append('    mirrors:')
    out.append(f'      - host: "http://{d}:{port}"')
    out.append('        capabilities: ["pull", "resolve"]')
    out.append('        skip_verify: true')
else:
    # 幂等: 先清掉历史重复累积的注释行, 再追加一条(否则每次运行都会多一条)
    marker = '# containerd_registries_mirrors:'
    out = [l for l in out if not l.startswith(marker)]
    out.append('# containerd_registries_mirrors:  # (REGISTRY_ENABLED=0, 未配置)')
open(path, 'w').write('\n'.join(out) + '\n')
PYEOF
    ok "已同步 containerd registry 信任 → ${REGISTRY_DOMAIN:-registry.local}:${REGISTRY_PORT:-5000}"
else
    warn "未找到 ${CONTAINERD_YML},跳过 containerd registry 配置"
fi

# ---------------- 7. 生成 registry.yml(供 patch-playbooks/cubestack-registry.yml 读取) ----------------
REGISTRY_YML="${INV_DIR}/group_vars/all/registry.yml"
{
    echo "# Generated by sync-kubespray-config.sh — 供 patch-playbooks/cubestack-registry.yml 读取, 请勿手工编辑"
    echo "registry_domain: \"${REGISTRY_DOMAIN:-registry.local}\""
    echo "registry_ip: \"${REGISTRY_IP:-10.244.2.100}\""
    echo "registry_port: \"${REGISTRY_PORT:-5000}\""
} > "${REGISTRY_YML}"
ok "已生成 ${REGISTRY_YML}: ${REGISTRY_DOMAIN:-registry.local} → ${REGISTRY_IP:-10.244.2.100}:${REGISTRY_PORT:-5000}"

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