#!/bin/bash
# ============================================================
# 把 Gateway/AIGateway 的数据面 Service 暴露为固定名(双模式: nodeport / metallb)
#
# 背景: Envoy Gateway 的数据面(Envoy Proxy)Service 由控制器动态创建, 默认 type=LoadBalancer
#        (依赖 MetalLB 分配 VIP)。SERVICE_EXPOSE_MODE=nodeport(测试环境, 无 MetalLB)下
#        需把该 Service 转成 NodePort, 外部用 <节点IP>:<NodePort> 访问。
#       · 更持久做法: 创建 Gateway 时加注解 gateway.envoyproxy.io/service-type: NodePort;
#         本脚本用于**已创建、未带注解**的 Gateway/AIGateway 一键转换(幂等)。
#       · ★ 本脚本同时兼容 metallb 场景: 数据面 Service 保持 LoadBalancer(MetalLB 分配 VIP),
#         不 patch。
#
# ★ 固定名别名 Service(对外入口稳定, 双模式一致):
#   数据面 Service 名 <envoy>-<ns>-<gw>-<hash> 由控制器生成且带 hash, 控制器拥有命名权,
#   用户无法改其名。本脚本自动创建固定名别名 Service <gw>-external(与数据面 pod 同命名空间,
#   selector 按 gateway.envoyproxy.io/owning-gateway-name 匹配):
#     · nodeport 模式 → 别名 type=NodePort, 数据面端口 → 固定 NodePort(GATEWAY_EXTERNAL_NODEPORT 默认 30880)
#     · metallb 模式  → 别名 type=LoadBalancer, 由 MetalLB 分配固定 VIP
#   两种模式下固定别名名一致(<gw>-external), 对外访问一律用固定名, 不依赖 hash 名。
#
# 用法: sudo ./gateway-nodeport.sh <gateway名> [namespace]
#   <gateway名>: Gateway 或 AIGateway 名称(数据面 Service 按 owning-gateway-name 标签匹配)
#   [namespace]: 省略 = 全命名空间按标签搜索(标签唯一, 一般直接省略)
# 输出:
#   nodeport → 访问地址 = 首个节点 IP:固定 NodePort(任一节点 IP 均可)
#   metallb  → 访问地址 = MetalLB VIP:数据面端口
# 数据源: config/cluster.conf (NODES / SSH_KEY_NAME / SERVICE_EXPOSE_MODE / GATEWAY_EXTERNAL_NODEPORT)
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
# ⚠ 列序敏感: 指定命名空间时 get svc 输出 NAME TYPE CLUSTER-IP...(名称=$1);
#   用 -A 全命名空间时输出 NAMESPACE NAME TYPE...(ns=$1, 名称=$2)。两者取列不同, 勿混用。
# ⚠⚠ -A 必须放在动词**之后**(kubectl get svc -A): kubectl v1.32 下 `-A` 非全局 flag,
#   写成 `kubectl -A get svc` 会报 "flags cannot be placed before plugin name" 并返回空 ——
#   未显式传 namespace 的调用方(如 16_envoy_ai_gateway.sh)会因此一直"找不到数据面 Service"。
#   (2026-09-16 实测 kubectl v1.32.5; 传了 namespace 的调用方不受影响。)
if [ -n "${NS}" ]; then
    SVC="$( (SSH "${K} -n ${NS} get svc -l gateway.envoyproxy.io/owning-gateway-name=${GW} --no-headers 2>/dev/null" || true) | head -1 )"
    [ -n "${SVC}" ] || { err "未找到数据面 Service(owning-gateway-name=${GW}, ns=${NS}); 先确认 Gateway/AIGateway 已调和: kubectl get gateway -A / kubectl get aigateway -A"; exit 1; }
    SVC_NS="${NS}"
    SVC_NAME="$(echo "${SVC}" | awk '{print $1}')"
else
    SVC="$( (SSH "${K} get svc -A -l gateway.envoyproxy.io/owning-gateway-name=${GW} --no-headers 2>/dev/null" || true) | head -1 )"
    [ -n "${SVC}" ] || { err "未找到数据面 Service(owning-gateway-name=${GW}); 先确认 Gateway/AIGateway 已调和: kubectl get gateway -A / kubectl get aigateway -A"; exit 1; }
    SVC_NS="$(echo "${SVC}" | awk '{print $1}')"
    SVC_NAME="$(echo "${SVC}" | awk '{print $2}')"
fi

# ---- 数据面端口(两种模式都用) ----
# ★ 别名 Service 的 targetPort 必须取**数据面的 targetPort**, 不能用 port —— 数据面 svc 的
#   port 与 targetPort 常常不同: EG 为 Gateway listener(port 80)生成的数据面 svc 是
#   port:80 → targetPort:10080(envoy 容器实际监听端口), 别名若照抄成 targetPort:80 则
#   Endpoints 指向 pod 上没监听的端口 → 节点 IP:固定 NodePort 直接 Connection refused
#   (2026-09-16 实测: 别名 targetPort=80 连接被拒, 而数据面自身 NodePort 31197 正常 302)。
#   AI 示例网关(port 8080 == targetPort 8080)掩盖了该缺陷, listener 非 8080 时必现。
EXT_PORT="$( (SSH "${K} -n ${SVC_NS} get svc ${SVC_NAME} -o jsonpath='{.spec.ports[0].port}' 2>/dev/null" || true) )"
[ -n "${EXT_PORT}" ] || EXT_PORT="8080"
EXT_TARGET_PORT="$( (SSH "${K} -n ${SVC_NS} get svc ${SVC_NAME} -o jsonpath='{.spec.ports[0].targetPort}' 2>/dev/null" || true) )"
# 数据面未显式声明 targetPort 时 K8s 默认 = port; 具名端口(targetPort 为字符串)原样透传也可正常解析
[ -n "${EXT_TARGET_PORT}" ] || EXT_TARGET_PORT="${EXT_PORT}"

# ---- nodeport / metallb 分支 ----
GATEWAY_EXTERNAL_NODEPORT="${GATEWAY_EXTERNAL_NODEPORT:-30880}"
EXT_SVC_NAME="${GW}-external"

if [ "${SERVICE_EXPOSE_MODE:-nodeport}" = "nodeport" ]; then
    # ── nodeport 模式: 数据面 svc patch 成 NodePort; 固定别名 NodePort ──
    say "数据面 Service ${SVC_NS}/${SVC_NAME} → NodePort(幂等)..."
    if ! SSH "${K} -n ${SVC_NS} patch svc ${SVC_NAME} -p '{\"spec\":{\"type\":\"NodePort\"}}' >/dev/null 2>&1"; then
        err "patch 数据面 Service 失败(kubectl -n ${SVC_NS} get svc ${SVC_NAME})"
        exit 1
    fi
    NODE_PORT="$( (SSH "${K} -n ${SVC_NS} get svc ${SVC_NAME} -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null" || true) )"
    [ -n "${NODE_PORT}" ] || { err "未取到 nodePort(kubectl -n ${SVC_NS} get svc ${SVC_NAME} -o yaml)"; exit 1; }
    NODE_IP="$(first_node_ip)" || { err "未找到节点 IP(NODES)"; exit 1; }
    EXT_TYPE="NodePort"
else
    # ── metallb 模式: 数据面保持 LoadBalancer(MetalLB 分配 VIP), 不 patch ──
    say "metallb 模式: 数据面 Service ${SVC_NS}/${SVC_NAME} 保持 LoadBalancer(不 patch)"
    EXT_TYPE="LoadBalancer"
fi

say "  创建固定名别名 Service ${SVC_NS}/${EXT_SVC_NAME}(type=${EXT_TYPE}, 数据面端口 ${EXT_PORT})..."
SSH "${K} -n ${SVC_NS} delete svc ${EXT_SVC_NAME} --ignore-not-found=true >/dev/null 2>&1" || true
_EXT_YAML="$(mktemp)"
# nodeport 模式别名固定 NodePort(GATEWAY_EXTERNAL_NODEPORT); metallb 模式不写 nodePort(由 MetalLB 分配 VIP)
_EXT_NODEPORT_LINE=""
[ "${EXT_TYPE}" = "NodePort" ] && _EXT_NODEPORT_LINE="      nodePort: ${GATEWAY_EXTERNAL_NODEPORT}"
cat > "${_EXT_YAML}" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${EXT_SVC_NAME}
  namespace: ${SVC_NS}
  labels:
    app.kubernetes.io/name: ${EXT_SVC_NAME}
    gateway.envoyproxy.io/external-alias: "${GW}"
spec:
  type: ${EXT_TYPE}
  selector:
    gateway.envoyproxy.io/owning-gateway-name: "${GW}"
  ports:
    - port: ${EXT_PORT}
      targetPort: ${EXT_TARGET_PORT}
${_EXT_NODEPORT_LINE}
      protocol: TCP
EOF
if SSH "${K} -n ${SVC_NS} apply -f -" < "${_EXT_YAML}" >/dev/null 2>&1; then
    if [ "${EXT_TYPE}" = "NodePort" ]; then
        ok "  固定入口: http://${NODE_IP}:${GATEWAY_EXTERNAL_NODEPORT}/  (固定名 ${SVC_NS}/${EXT_SVC_NAME})"
    else
        EXT_VIP=""
        for _i in $(seq 1 30); do
            EXT_VIP="$( (SSH "${K} -n ${SVC_NS} get svc ${EXT_SVC_NAME} -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null" || true) )"
            [ -n "${EXT_VIP}" ] && break
            sleep 2
        done
        if [ -n "${EXT_VIP}" ]; then
            ok "  固定入口可用: http://${EXT_VIP}:${EXT_PORT}/  (固定名 ${SVC_NS}/${EXT_SVC_NAME}, MetalLB VIP)"
        else
            warn "  固定别名已创建但 MetalLB 60s 内未分配 VIP(kubectl -n ${SVC_NS} get svc ${EXT_SVC_NAME} -o yaml 复查; 检查 METALLB_POOL 是否有空闲地址)"
        fi
    fi
else
    warn "  固定名别名 Service 创建失败(可稍后重跑本脚本); 数据面原 Service 仍可访问"
fi
rm -f "${_EXT_YAML}"

if [ "${EXT_TYPE}" = "NodePort" ]; then
    ok "数据面已暴露为 NodePort: http://${NODE_IP}:${NODE_PORT}/  (任一节点 IP:${NODE_PORT} 均可)"
    say "提示: 更持久做法是在 Gateway 上注解 gateway.envoyproxy.io/service-type: NodePort(创建时即生效, 无需每次转换)"
else
    ok "metallb 模式完成: 数据面 + 固定别名均 LoadBalancer(MetalLB 分配 VIP)"
fi
say "提示: 对外入口固定用 ${SVC_NS}/${EXT_SVC_NAME}; 控制器生成的 envoy-<ns>-<gw>-<hash> 名仅供内部"
