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
MASTER_IPS=()    # master 节点 IP
WORKER_IPS=()    # worker 节点 IP
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    IFS=, read -r role hostname ip mac mem cpu disk user pw node_type <<<"${line}"
    case "${role}" in
        master) MASTER_IPS+=("${ip}") ;;
        worker) WORKER_IPS+=("${ip}") ;;
    esac
done

[ "${#MASTER_IPS[@]}" -gt 0 ] || { err "cluster.conf 中无 master 节点"; exit 1; }

# 第一个 worker IP(用于 Calico can-reach 探测),无 worker 时回退到宿主机 IP
FIRST_WORKER="${WORKER_IPS[0]:-${API_IP}}"

say "宿主机 IP: ${API_IP}"
say "API 域名: ${API_DOMAIN}"
say "Master IPs: ${MASTER_IPS[*]}"
say "Worker IPs: ${WORKER_IPS[*]:-<无>}"

# ---------------- 1. 更新 all.yml ----------------
ALL_YML="${INV_DIR}/group_vars/all/all.yml"
if [ -f "${ALL_YML}" ]; then
    say "更新 ${ALL_YML} ..."
    # loadbalancer_apiserver.address → 宿主机物理 IP
    sed -i -E "s/^(\s+address:)\s+[0-9.]+(\s*#.*)?\$/\1 ${API_IP}\2/" "${ALL_YML}"

    # apiserver_loadbalancer_domain_name → 集群 API 域名
    sed -i -E "s/^apiserver_loadbalancer_domain_name:.*/apiserver_loadbalancer_domain_name: \"${API_DOMAIN}\"/" "${ALL_YML}"

    # supplementary_addresses_in_ssl_keys → API 域名 + 宿主机 IP + 所有 master IP
    awk -v host="${API_IP}" -v domain="${API_DOMAIN}" -v masters="${MASTER_IPS[*]}" '
        /^supplementary_addresses_in_ssl_keys:/ { in_sec=1; print; next }
        in_sec && /^[[:space:]]*-/ {
            # 跳过旧的域名/IP 条目(保留 k8s-api.nova.local)
            if ($0 ~ /nova\.local|lb\.k8s\.local/) { next }
            next
        }
        in_sec && !/^[[:space:]]*-/ {
            # 区块结束,输出 API 域名 + 宿主机 + masters 条目
            print "  - " domain
            print "  - " host "           # 宿主机物理 IP(worker 通过此地址访问 API Server)"
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
        sed -i -E "s/^(\s+advertise-address:)\s+\"[0-9.]+\"/\1 \"${API_IP}\"/" "${CLUSTER_YML}"
    else
        # 在 kube_apiserver_extra_args 下追加 advertise-address
        sed -i -E "/^kube_apiserver_extra_args:/a\  advertise-address: \"${API_IP}\"" "${CLUSTER_YML}"
    fi
    ok "已同步 kube_apiserver_extra_args.advertise-address → ${API_IP}"
    # 集群内部网络 CIDR(从 cluster.conf 读取, 不硬编码在 group_vars 中)
    sed -i -E "s|^kube_service_addresses:[[:space:]]*[0-9.]+/[0-9]+|kube_service_addresses: ${KUBE_SERVICE_ADDRESSES:-10.233.0.0/18}|" "${CLUSTER_YML}"
    sed -i -E "s|^kube_pods_subnet:[[:space:]]*[0-9.]+/[0-9]+|kube_pods_subnet: ${KUBE_PODS_SUBNET:-10.233.64.0/18}|" "${CLUSTER_YML}"
    sed -i -E "s|^nodelocaldns_ip:[[:space:]]*[0-9.]+|nodelocaldns_ip: ${NODELOCAL_DNS_IP:-169.254.25.10}|" "${CLUSTER_YML}"
    ok "已同步集群内部 CIDR: kube_service_addresses=${KUBE_SERVICE_ADDRESSES:-10.233.0.0/18} / kube_pods_subnet=${KUBE_PODS_SUBNET:-10.233.64.0/18} / nodelocaldns_ip=${NODELOCAL_DNS_IP:-169.254.25.10}"
else
    warn "集群内部 CIDR 未同步(未找到 ${CLUSTER_YML})"
fi

# ---------------- 4. 更新 addons.yml (MetalLB 地址池) ----------------
ADDONS_YML="${INV_DIR}/group_vars/k8s_cluster/addons.yml"
METALLB_POOL="${METALLB_POOL:-10.244.2.0/24}"
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

# ---------------- 4.1 更新 addons.yml (Registry Service 暴露方式) ----------------
# 依据 REGISTRY_SERVICE_TYPE 同步 registry Service 的 type 与对外端口:
#   loadbalancer → LoadBalancer + 固定 VIP(REGISTRY_IP), 避免 MetalLB auto-assign 分到网段边界地址
#   nodeport     → NodePort + 固定 REGISTRY_NODEPORT(不依赖 MetalLB)
# 集群内节点 /etc/hosts + containerd 引用的是 REGISTRY_DOMAIN, 与 Service type 无关
if [ -f "${ADDONS_YML}" ] && [ "${REGISTRY_ENABLED:-0}" = "1" ]; then
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
echo "  宿主机 API 地址: ${API_IP}:6443"
echo "  Master IPs: ${MASTER_IPS[*]}"
echo "  Calico can-reach: ${FIRST_WORKER}"
echo "  MetalLB 地址池: ${METALLB_POOL}"