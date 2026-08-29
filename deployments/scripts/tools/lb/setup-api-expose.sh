#!/bin/bash
# ============================================================
# setup-api-expose.sh — 宿主机 K8s API 入口 DNAT(6443 → 第一个 master)
# ------------------------------------------------------------
# 用途: kubespray 生成的 admin.conf 证书 SAN 通常含 API_DOMAIN(如 k8s-api.nova.local)
#       但不含 master 直连 IP(如 10.66.1.232 / 10.244.1.11)。宿主侧要让 kubectl/helm 能经
#       API_DOMAIN 访问集群, 需要:
#         1) /etc/hosts: API_DOMAIN → API_IP(统一=第一个 master IP, VM/裸金属均不使用宿主机物理 IP)
#         2) DNAT: 仅当 API_IP != 第一个 master 时才需要(本脚本默认直连 master, 无需 DNAT)
#   本脚本幂等写入 /etc/hosts 并校验 API 可达(重复执行安全), 顺带清理历史遗留的 6443 DNAT。
# 用法: sudo ./setup-api-expose.sh [--delete]
# 数据源: config/cluster.conf (API_DOMAIN / API_IP / NODES)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

[ "$(id -u)" -eq 0 ] || { err "需要 root: sudo $0"; exit 1; }

MODE="${1:-add}"
PORT=6443

# 解析第一个 master
FIRST_MASTER=""
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    node_parse "${line}"
    [ "${NODE_ROLE}" = "master" ] || continue
    FIRST_MASTER="${NODE_IP}"; break
done
[ -n "${FIRST_MASTER}" ] || { err "cluster.conf 中无 master 节点"; exit 1; }

[ -n "${API_IP}" ] || { err "API_IP 未派生(需 load_config 提供)"; exit 1; }
[ -n "${API_DOMAIN}" ] || API_DOMAIN="k8s-api.nova.local"

# /etc/hosts 确保 API_DOMAIN → API_IP
# ★ 关键: 无论目标 IP 是否已匹配, 都先删除该域名的【所有旧行】(换环境时旧 IP 残留会
#   让 getent hosts 命中旧 IP → kubectl 打到旧集群 → 误报失败), 再写当前 API_IP 一行。
#   复用 lib-common 的 ensure_hosts_entry(先删旧行再写, 无 grep 守卫 → 多集群不残留旧 IP)。
ensure_hosts_entry "${API_IP}" "${API_DOMAIN}"
ok "/etc/hosts 写入 ${API_DOMAIN} → ${API_IP}(先删旧 IP 残留, 确保只有一行)"

# ---------------- DNAT 管理(仅当 API_IP ≠ 第一个 master 时需要) ----------------
# 默认 API_IP = 第一个 master IP(VM/裸金属统一), 宿主机直连 master:6443, 无需 DNAT。
# 仅显式把 API_IP 指向宿主机/其他地址(如旧配置)时才需要 DNAT, 保留该能力但不默认使用。
# ★ 无论是否直连, 都先清理旧 IP 残留: 安装环境 IP 会变, 删除所有旧 dport 6443 的 DNAT(不管旧目标),
#   避免旧 IP 规则残留劫持流量(PREROUTING + OUTPUT 都清)。
dnat_purge_old() {   # <chain> 删除该链上所有 6443 DNAT
    local chain="$1" h
    while read -r h; do
        [ -n "${h}" ] || continue
        iptables -t nat -D "${chain}" ${h} 2>/dev/null && warn "已删除旧 ${chain} DNAT: ${h}"
    done < <(iptables -t nat -L "${chain}" -n --line-numbers 2>/dev/null \
                | grep -E "dpt:${PORT}.*to:.*:${PORT}" \
                | sed -E 's/^[0-9]+[[:space:]]+//')
}

dnat_add() {   # <chain> 幂等添加 DNAT
    local chain="$1"
    if iptables -t nat -L "${chain}" -n 2>/dev/null | grep -qE "dpt:${PORT}.*to:${FIRST_MASTER}:${PORT}"; then
        ok "  ${chain} DNAT 已存在: ${API_IP}:${PORT} → ${FIRST_MASTER}:${PORT}"
        return
    fi
    iptables -t nat -A "${chain}" -d "${API_IP}/32" -p tcp --dport "${PORT}" -j DNAT --to-destination "${FIRST_MASTER}:${PORT}"
    ok "已添加 ${chain} DNAT: ${API_IP}:${PORT} → ${FIRST_MASTER}:${PORT}"
}

if [ "${MODE}" = "delete" ]; then
    for c in PREROUTING OUTPUT; do
        if iptables -t nat -L "${c}" -n 2>/dev/null | grep -qE "dport ${PORT}.*to:${FIRST_MASTER}:${PORT}"; then
            iptables -t nat -D "${c}" -d "${API_IP}/32" -p tcp --dport "${PORT}" -j DNAT --to-destination "${FIRST_MASTER}:${PORT}"
            ok "已删除 ${c} DNAT: ${API_IP}:${PORT} → ${FIRST_MASTER}:${PORT}"
        else
            ok "无 ${c} 的该 DNAT, 跳过"
        fi
    done
    exit 0
fi

# add: 先清旧 IP 残留(无论直连与否都清), 再按需添加 DNAT
dnat_purge_old PREROUTING
dnat_purge_old OUTPUT
if [ "${API_IP}" = "${FIRST_MASTER}" ]; then
    say "API 入口=第一个 master(${API_IP}), 宿主机直连, 无需 DNAT(已清理历史遗留规则)"
else
    dnat_add PREROUTING
    dnat_add OUTPUT
fi

# 校验: 经 API_DOMAIN(宿主机 DNAT)访问 API 应 200
say "校验 https://${API_DOMAIN}:${PORT}/version ..."
READY=0
for _t in $(seq 1 10); do
    if curl -sk -m 8 -o /dev/null -w "%{http_code}" "https://${API_DOMAIN}:${PORT}/version" 2>/dev/null | grep -qE "200"; then
        READY=1; break
    fi
    sleep 2
done
if [ "${READY}" = "1" ]; then
    ok "API 可达: https://${API_DOMAIN}:${PORT}/version (经宿主机 DNAT → ${FIRST_MASTER})"
else
    warn "API 经 ${API_DOMAIN}:${PORT} 暂不可达(可稍后重试; 检查 DNAT 与 master apiserver 状态)"
fi
