#!/bin/bash
# ============================================================
# net-tune.sh — 优化宿主 TCP 网络参数(大镜像/大 blob 推送稳定性)
# 用途: 5.5GB 级镜像 push 到集群 registry 时偶发 "connection reset by peer"
#       (对端/fabric 对高吞吐长连接重置)。调大 TCP 缓冲/窗口 + 保活参数, 缓解。
# 生效: 立即(sysctl -w) + 持久化(/etc/sysctl.d/99-cubestack-net-tune.conf)
# 幂等: 可重复执行; 仅调大缓冲(不改小), keepalive 固定值。
# 用法: sudo ./net-tune.sh [--reset]
#       --reset = 恢复默认值并从 sysctl.d 移除(可选)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

[ "$(id -u)" -eq 0 ] || { err "需要 root(sudo sysctl), 请 sudo 执行"; exit 1; }

CONF="/etc/sysctl.d/99-cubestack-net-tune.conf"

# ① TCP 缓冲/窗口(大吞吐稳定)
RMEM=16777216; WMEM=16777216
# ② TCP keepalive(防中间设备按时长/空闲回收长连接)
KA_TIME=60; KA_INTVL=10; KA_PROBES=9

if [ "${1:-}" = "--reset" ]; then
    say "恢复 TCP 参数默认值并移除 ${CONF} ..."
    sysctl -w net.core.rmem_max=212992 net.core.wmem_max=212992 >/dev/null
    sysctl -w net.ipv4.tcp_rmem='4096 131072 6291456' >/dev/null
    sysctl -w net.ipv4.tcp_wmem='4096 16384 4194304' >/dev/null
    sysctl -w net.ipv4.tcp_keepalive_time=7200 net.ipv4.tcp_keepalive_intvl=75 net.ipv4.tcp_keepalive_probes=9 >/dev/null
    rm -f "${CONF}"
    ok "已恢复默认(TCP keepalive_time=7200, 缓冲默认)"
    exit 0
fi

say "优化宿主 TCP 网络参数(大 blob 推送稳定) ..."

# 立即生效 + 写入持久化配置
cat > "${CONF}" << EOF
# CubeStack 大镜像推送网络调优(自动生成, 可删; net-tune.sh --reset 恢复)
net.core.rmem_max = ${RMEM}
net.core.wmem_max = ${WMEM}
net.ipv4.tcp_rmem = 4096 87380 ${RMEM}
net.ipv4.tcp_wmem = 4096 65536 ${WMEM}
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_keepalive_time = ${KA_TIME}
net.ipv4.tcp_keepalive_intvl = ${KA_INTVL}
net.ipv4.tcp_keepalive_probes = ${KA_PROBES}
EOF

sysctl -w net.core.rmem_max=${RMEM} >/dev/null
sysctl -w net.core.wmem_max=${WMEM} >/dev/null
sysctl -w net.ipv4.tcp_rmem="4096 87380 ${RMEM}" >/dev/null
sysctl -w net.ipv4.tcp_wmem="4096 65536 ${WMEM}" >/dev/null
sysctl -w net.ipv4.tcp_window_scaling=1 >/dev/null
sysctl -w net.ipv4.tcp_sack=1 >/dev/null
sysctl -w net.ipv4.tcp_keepalive_time=${KA_TIME} net.ipv4.tcp_keepalive_intvl=${KA_INTVL} net.ipv4.tcp_keepalive_probes=${KA_PROBES} >/dev/null

# 验证
say "当前生效值:"
for k in net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
         net.ipv4.tcp_window_scaling net.ipv4.tcp_sack \
         net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes; do
    printf "  %-42s = %s\n" "$k" "$(sysctl -n "$k" 2>/dev/null)"
done
ok "TCP 网络调优已生效并持久化(${CONF})"
echo "  说明: 若仍 push 被 reset, 可再试降低吞吐(tc qdisc ... rate)或检查 fabric/VIP 节点对端"
