#!/bin/bash
# ============================================================
# 从 cluster.conf 自动生成宿主机 HAProxy 配置(K8s API 四层负载均衡)
# 宿主机 10.66.3.37:6443 → 负载均衡所有 master apiserver
# 用法: sudo ./sync-haproxy.sh
# 数据源: deployments/config/cluster-${CLUSTER_NAME}.conf (APISERVER_ADDRESS / NODES)
# 生成: /etc/haproxy/haproxy.cfg (备份到 .bak)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-common.sh"
load_config

[ "$(id -u)" -eq 0 ] || { err "需要 root: sudo $0"; exit 1; }

# 解析 master 节点(hostname + ip)
MASTER_IPS=()
MASTER_NAMES=()
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    IFS=, read -r role hostname ip mac mem cpu disk user pw <<<"${line}"
    [ "${role}" = "master" ] || continue
    MASTER_NAMES+=("${hostname}")
    MASTER_IPS+=("${ip}")
done
[ "${#MASTER_IPS[@]}" -gt 0 ] || { err "cluster.conf 中无 master 节点"; exit 1; }

API_IP="${APISERVER_ADDRESS:-${HOST_PHYS_IP:-10.66.3.37}}"
PORT=6443

say "API 入口: ${API_IP}:${PORT}"
say "后端 master: ${#MASTER_IPS[@]} 台"

# 备份并生成配置
[ -f /etc/haproxy/haproxy.cfg ] && cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak-$(date +%Y%m%d%H%M%S) 2>/dev/null || true

cat > /etc/haproxy/haproxy.cfg << EOF
global
  log         127.0.0.1 local2
  pidfile     /var/run/haproxy.pid
  maxconn     4000
  daemon

defaults
  mode                    tcp
  log                     global
  option                  dontlognull
  option                  redispatch
  retries                 3
  timeout connect         10s
  timeout client          1m
  timeout server          1m
  timeout check           10s
  maxconn                 3000

# K8s API Server 四层负载均衡(全局唯一入口)
listen api-server-${PORT}
  bind ${API_IP}:${PORT}
  mode tcp
  option tcp-check
  balance roundrobin
  default-server inter 10s fall 2 rise 3
EOF

# 追加 master 后端
for i in "${!MASTER_IPS[@]}"; do
    echo "  server ${MASTER_NAMES[$i]} ${MASTER_IPS[$i]}:${PORT} check" >> /etc/haproxy/haproxy.cfg
done

# 校验并重启
haproxy -c -f /etc/haproxy/haproxy.cfg || { err "HAProxy 配置校验失败"; exit 1; }
systemctl restart haproxy
systemctl enable haproxy >/dev/null 2>&1 || true

ok "HAProxy 已更新: ${API_IP}:${PORT} → ${#MASTER_IPS[@]} 台 master"
ss -tlnp 2>/dev/null | grep "${PORT}" || true