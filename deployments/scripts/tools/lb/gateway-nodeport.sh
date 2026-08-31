#!/bin/bash
# ============================================================
# 把 Gateway/AIGateway 的数据面 Service 转成 NodePort(测试环境/无 MetalLB 时暴露)
#
# 背景: Envoy Gateway 的数据面(Envoy Proxy)Service 由控制器动态创建, 默认 type=LoadBalancer
#        (依赖 MetalLB 分配 VIP)。SERVICE_EXPOSE_MODE=nodeport(测试环境, 无 MetalLB)下
#        需把该 Service 转成 NodePort, 外部用 <节点IP>:<NodePort> 访问。
#       · 更持久做法: 创建 Gateway 时加注解 gateway.envoyproxy.io/service-type: NodePort;
#         本脚本用于**已创建、未带注解**的 Gateway/AIGateway 一键转换(幂等)。
# 用法: sudo ./gateway-nodeport.sh <gateway名> [namespace]
#   <gateway名>: Gateway 或 AIGateway 名称(数据面 Service 按 owning-gateway-name 标签匹配)
#   [namespace]: 省略 = 全命名空间按标签搜索(标签唯一, 一般直接省略)
# 输出: 访问地址 = 首个节点 IP:NodePort(任一节点 IP:NodePort 均可)
# 数据源: config/cluster.conf (NODES / SSH_KEY_NAME)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

GW="${1:-}"; NS="${2:-}"
[ -n "${GW}" ] || { err "用法: $0 <gateway名> [namespace]"; exit 1; }

FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
SSH() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
           "${SSH_USER:-ubuntu}@${FIRST_MASTER}" "$@"; }
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

# 定位数据面 Service: EG 对 Gateway 所属资源统一打标签 gateway.envoyproxy.io/owning-gateway-name=<名>
SVCSEL="-l gateway.envoyproxy.io/owning-gateway-name=${GW}"
[ -n "${NS}" ] && SVCSEL="-n ${NS} ${SVCSEL}"
SVC="$( (SSH "${K} get svc ${SVCSEL} --no-headers 2>/dev/null" || true) | head -1 )"
[ -n "${SVC}" ] || { err "未找到数据面 Service(owning-gateway-name=${GW}); 先确认 Gateway/AIGateway 已调和: kubectl get gateway -A / kubectl get aigateway -A"; exit 1; }
SVC_NS="$(echo "${SVC}" | awk '{print $1}')"
SVC_NAME="$(echo "${SVC}" | awk '{print $2}')"

say "转换数据面 Service ${SVC_NS}/${SVC_NAME} → NodePort(幂等)..."
if ! SSH "${K} -n ${SVC_NS} patch svc ${SVC_NAME} -p '{\"spec\":{\"type\":\"NodePort\"}}' >/dev/null 2>&1"; then
    err "patch 数据面 Service 失败(kubectl -n ${SVC_NS} get svc ${SVC_NAME})"
    exit 1
fi
NODE_PORT="$( (SSH "${K} -n ${SVC_NS} get svc ${SVC_NAME} -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null" || true) )"
[ -n "${NODE_PORT}" ] || { err "未取到 nodePort(kubectl -n ${SVC_NS} get svc ${SVC_NAME} -o yaml)"; exit 1; }
NODE_IP="$(first_node_ip)" || { err "未找到节点 IP(NODES)"; exit 1; }

ok "数据面已暴露为 NodePort: http://${NODE_IP}:${NODE_PORT}/  (任一节点 IP:${NODE_PORT} 均可)"
say "提示: 更持久做法是在 Gateway 上注解 gateway.envoyproxy.io/service-type: NodePort(创建时即生效, 无需每次转换)"
