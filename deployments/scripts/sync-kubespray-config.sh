#!/bin/bash
# ============================================================
# 将 config/cluster.conf 中的网络/IP 配置同步到 kubespray group_vars
# 避免在 kubespray 配置文件中硬编码环境 IP
# 用法: ./sync-kubespray-config.sh
# 数据源: config/cluster.conf (HOST_PHYS_IP / NODES / VM_SUBNET / KUBESPRAY_INV_DIR)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-common.sh"
load_config

INV_DIR="${KUBESPRAY_INV_DIR:-${REPO_ROOT}/deployments/kubespray/inventory/cubestack-cluster}"
[ -d "${INV_DIR}" ] || { err "Inventory 目录不存在: ${INV_DIR}, 请先运行 gen-inventory.sh"; exit 1; }

# ---------------- 从 cluster.conf 解析 IP ----------------
# API Server 地址: 优先 APISERVER_ADDRESS(NAT 模式=第一个 master IP), 回退 HOST_PHYS_IP(桥接模式)
HOST_IP="${APISERVER_ADDRESS:-${HOST_PHYS_IP:-10.66.3.37}}"
# API Server 域名(跨网段统一入口), 默认 k8s-api.nova.local
APISERVER_DOMAIN="${APISERVER_DOMAIN:-k8s-api.nova.local}"
MASTER_IPS=()    # master 节点 IP
WORKER_IPS=()    # worker 节点 IP
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    IFS=, read -r role hostname ip mac mem cpu disk user pw <<<"${line}"
    case "${role}" in
        master) MASTER_IPS+=("${ip}") ;;
        worker) WORKER_IPS+=("${ip}") ;;
    esac
done

[ "${#MASTER_IPS[@]}" -gt 0 ] || { err "cluster.conf 中无 master 节点"; exit 1; }

# 第一个 worker IP(用于 Calico can-reach 探测),无 worker 时回退到宿主机 IP
FIRST_WORKER="${WORKER_IPS[0]:-${HOST_IP}}"

say "宿主机 IP: ${HOST_IP}"
say "API 域名: ${APISERVER_DOMAIN}"
say "Master IPs: ${MASTER_IPS[*]}"
say "Worker IPs: ${WORKER_IPS[*]:-<无>}"

# ---------------- 1. 更新 all.yml ----------------
ALL_YML="${INV_DIR}/group_vars/all/all.yml"
if [ -f "${ALL_YML}" ]; then
    say "更新 ${ALL_YML} ..."
    # loadbalancer_apiserver.address → 宿主机物理 IP
    sed -i -E "s/^(\s+address:)\s+[0-9.]+(\s*#.*)?\$/\1 ${HOST_IP}\2/" "${ALL_YML}"

    # apiserver_loadbalancer_domain_name → 集群 API 域名
    sed -i -E "s/^apiserver_loadbalancer_domain_name:.*/apiserver_loadbalancer_domain_name: \"${APISERVER_DOMAIN}\"/" "${ALL_YML}"

    # supplementary_addresses_in_ssl_keys → API 域名 + 宿主机 IP + 所有 master IP
    awk -v host="${HOST_IP}" -v domain="${APISERVER_DOMAIN}" -v masters="${MASTER_IPS[*]}" '
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
        sed -i -E "s/^(\s+advertise-address:)\s+\"[0-9.]+\"/\1 \"${HOST_IP}\"/" "${CLUSTER_YML}"
    else
        # 在 kube_apiserver_extra_args 下追加 advertise-address
        sed -i -E "/^kube_apiserver_extra_args:/a\  advertise-address: \"${HOST_IP}\"" "${CLUSTER_YML}"
    fi
    ok "已同步 kube_apiserver_extra_args.advertise-address → ${HOST_IP}"
else
    warn "未找到 ${CLUSTER_YML},跳过"
fi

echo "---------------------------------------------"
ok "kubespray 配置已从 cluster.conf 同步完成"
echo "  宿主机 API 地址: ${HOST_IP}:6443"
echo "  Master IPs: ${MASTER_IPS[*]}"
echo "  Calico can-reach: ${FIRST_WORKER}"