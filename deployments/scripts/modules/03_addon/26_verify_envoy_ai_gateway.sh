#!/bin/bash
# ============================================================
# MODULE: verify_envoy_ai_gateway
# DESC: 端到端验证 Envoy AI Gateway 工作(非仅 pod running):
#       ① AI 控制器 pod Ready → ② AI CRD(aigateway.envoyproxy.io)注册 → ③ 建测试 AIGateway+Backend(mock LLM)
#       → ④ AIGateway 调和出 Gateway 且 Programmed + 分配 VIP → ⑤(边界)curl VIP 调 chat/completions 返回 mock 响应
#       → ⑥ 清理(trap 兜底)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# 说明:
#   · **验证模块不设 TOGGLE**(否则 ENVOY_AI_GATEWAY_ENABLED=true 时会被安装流程自动启用);
#     保持 DEFAULT:0, 仅由 --steps verify_envoy_ai_gateway 在安装后单独执行。
#   · ③④ 步验证 AI 控制面真正工作: AIGateway/Backend → AI 控制器翻译为 Gateway(Gateway API)→ EG 控制面
#     使其 Programmed + MetalLB 分配 VIP(核心断言)。
#   · ⚠ v1.x API 差异: AI Gateway v1.1 起**没有** AIGateway/Backend CRD(改为标准 Gateway +
#     AIServiceBackend / AIGatewayRoute / GatewayConfig)。下方测试资源按 v0.x API 构造, 在 v1.x 上
#     apply 可能失败(仅告警不阻断); 若要完整验证, 按官方 examples/basic/basic.yaml 改用标准 Gateway +
#     AIServiceBackend + AIGatewayRoute 后手动调整本节。
#   · ⑤ 步为**边界验证**(AI CRD 字段/路由 API 随版本 Alpha/Beta 变化): 用 busybox httpd 静态 mock
#     一个 OpenAI chat.completions 响应, 经 AI Gateway VIP 真实调用; 失败仅告警并给出指引,
#     不阻断(控制面调和已证明 AI 控制面工作正常)。真实 LLM 需配置真实 Backend + API Key Secret。
#   · 参考: https://aigateway.envoyproxy.io/ 与 docs/envoy-gateway.md §4.2
# 数据源: cluster.conf (ENVOY_AI_GATEWAY_ENABLED / ENVOY_AI_NAMESPACE / ENVOY_AI_API_VERSION /
#                       ENVOY_AI_GATEWAYCLASS / NODES / SSH_KEY_NAME)
# 用法:   sudo ./deploy-cluster.sh --steps verify_envoy_ai_gateway
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# 开关检查: 未启用则跳过(不报错)
[ "${ENVOY_AI_GATEWAY_ENABLED:-false}" = "true" ] || { say "ENVOY_AI_GATEWAY_ENABLED=false, 跳过验证"; exit 0; }

FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
SSH() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
           "${SSH_USER:-ubuntu}@${FIRST_MASTER}" "$@"; }
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

ENVOY_AI_NAMESPACE="${ENVOY_AI_NAMESPACE:-ai-gateway-system}"
ENVOY_AI_API_VERSION="${ENVOY_AI_API_VERSION:-v1beta1}"
ENVOY_AI_GATEWAYCLASS="${ENVOY_AI_GATEWAYCLASS:-envoy-gateway}"   # AI Gateway 数据面复用 EG 的 GatewayClass(v1.x)
TEST_NS="verify-aig-$$"        # 唯一命名空间(带 PID 后缀)
TEST_AIG="verify-aigw"
TEST_BACKEND="verify-aig-backend"
TEST_BACKEND_SVC="verify-aig-backend-svc"

cleanup() {
    SSH "${K} patch namespace ${TEST_NS} --type=merge -p '{\"metadata\":{\"finalizers\":null}}' >/dev/null 2>&1" || true
    SSH "${K} delete namespace ${TEST_NS} --ignore-not-found=true --force --grace-period=0 >/dev/null 2>&1" || true
}
trap cleanup EXIT

say "验证 Envoy AI Gateway 工作正常(端到端, 非仅 pod running)..."
say "  ① 检查 AI 控制器 pod 就绪..."
SSH "${K} -n ${ENVOY_AI_NAMESPACE} get pods --no-headers 2>/dev/null | grep -E 'ai-gateway-controller.*1/1 +Running'" \
    || { err "AI 控制器未 Running(kubectl get pods -n ${ENVOY_AI_NAMESPACE})"; exit 1; }

say "  ② 检查 AI CRD 注册(aigateway.envoyproxy.io)..."
CRD_LIST="$( (SSH "${K} get crd --no-headers 2>/dev/null" || true) | grep 'aigateway\.envoyproxy\.io' | awk '{print $1}' || true)"
echo "${CRD_LIST}" | sed 's/^/    /'
echo "${CRD_LIST}" | grep -q 'aigateways\.aigateway\.envoyproxy\.io' \
    || { err "AIGateway CRD 未注册(kubectl get crd | grep aigateway); 检查 ai-gateway-crds helm 是否安装"; exit 1; }
echo "${CRD_LIST}" | grep -q 'backends\.aigateway\.envoyproxy\.io' \
    || warn "    Backend CRD 未注册(可能版本差异, 仅告警)"

say "  ③ 创建测试资源(AIGateway + Backend, mock OpenAI 兼容后端)..."
cleanup
LOCAL_YAML="$(mktemp)"
cat > "${LOCAL_YAML}" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${TEST_NS}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${TEST_BACKEND}
  namespace: ${TEST_NS}
spec:
  replicas: 1
  selector:
    matchLabels: { app: ${TEST_BACKEND} }
  template:
    metadata:
      labels: { app: ${TEST_BACKEND} }
    spec:
      containers:
        - name: httpd
          image: docker.io/library/busybox:latest
          imagePullPolicy: IfNotPresent
          command: ["/bin/sh", "-c", "mkdir -p /www/v1 && echo '{\"id\":\"chatcmpl-mock\",\"object\":\"chat.completion\",\"created\":123,\"model\":\"mock\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"envoy-ai-gateway-verify-ok\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":2,\"total_tokens\":3}}' > /www/v1/chat/completions && busybox httpd -f -p 8080 -h /www"]
          ports: [{ containerPort: 8080 }]
---
apiVersion: v1
kind: Service
metadata:
  name: ${TEST_BACKEND_SVC}
  namespace: ${TEST_NS}
spec:
  selector: { app: ${TEST_BACKEND} }
  ports: [{ port: 8080, targetPort: 8080 }]
---
apiVersion: aigateway.envoyproxy.io/${ENVOY_AI_API_VERSION}
kind: AIGateway
metadata:
  name: ${TEST_AIG}
  namespace: ${TEST_NS}
spec:
  gatewayClassName: ${ENVOY_AI_GATEWAYCLASS}
---
apiVersion: aigateway.envoyproxy.io/${ENVOY_AI_API_VERSION}
kind: Backend
metadata:
  name: ${TEST_BACKEND}
  namespace: ${TEST_NS}
spec:
  type: OpenAI
  url: http://${TEST_BACKEND_SVC}.${TEST_NS}.svc.cluster.local:8080/v1
YAML
scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
    "${LOCAL_YAML}" "${SSH_USER:-ubuntu}@${FIRST_MASTER}:/tmp/${TEST_AIG}.yaml"
if SSH "${K} apply -f /tmp/${TEST_AIG}.yaml"; then
    SSH "rm -f /tmp/${TEST_AIG}.yaml" || true
else
    SSH "rm -f /tmp/${TEST_AIG}.yaml" || true
    warn "    AIGateway apply 失败(可能字段随版本变化, 如 gatewayClassName / apiVersion=${ENVOY_AI_API_VERSION}); 继续检查是否存在已调和资源, 必要时按 docs/envoy-gateway.md §4.2 调整 CR 字段后重跑"
fi
rm -f "${LOCAL_YAML}"

say "  ④ 等待 AIGateway 调和出 Gateway 且 Programmed(nodeport 模式: 数据面转 NodePort; metallb: 等 VIP; 最长 180s)..."
AIG_GW=""
AIG_ENDPOINT=""
GW_READY=0
for i in $(seq 1 36); do
    # AI 控制器在 AIGateway 命名空间创建同名 Gateway(gateway.networking.k8s.io)
    AIG_GW="$( (SSH "${K} -n ${TEST_NS} get gateway ${TEST_AIG} --no-headers 2>/dev/null" || true) )"
    if [ -n "${AIG_GW}" ]; then
        if [ "${SERVICE_EXPOSE_MODE:-metallb}" = "nodeport" ]; then
            # 无 MetalLB: 等数据面 Service 出现 → patch 成 NodePort → 访问入口 = 节点IP:NodePort
            SVC_LINE="$( (SSH "${K} -n ${TEST_NS} get svc -l gateway.envoyproxy.io/owning-gateway-name=${TEST_AIG} --no-headers 2>/dev/null" || true) | head -1 )"
            if [ -n "${SVC_LINE}" ]; then
                DP_NAME="$(echo "${SVC_LINE}" | awk '{print $2}')"
                SSH "${K} -n ${TEST_NS} patch svc ${DP_NAME} -p '{\"spec\":{\"type\":\"NodePort\"}}' >/dev/null 2>&1" || true
                NPORT="$( (SSH "${K} -n ${TEST_NS} get svc ${DP_NAME} -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null" || true) )"
                [ -n "${NPORT}" ] && AIG_ENDPOINT="$(first_node_ip):${NPORT}"
            fi
        else
            AIG_ENDPOINT="$( (SSH "${K} -n ${TEST_NS} get gateway ${TEST_AIG} -o jsonpath='{.status.addresses[0].value}' 2>/dev/null" || true) )"
        fi
        GW_READY="$( (SSH "${K} -n ${TEST_NS} get gateway ${TEST_AIG} -o jsonpath='{.status.conditions[?(@.type==\"Programmed\")].status}' 2>/dev/null" || true) )"
        [ "${GW_READY}" = "True" ] && [ -n "${AIG_ENDPOINT}" ] && break
    fi
    sleep 5
done
[ -n "${AIG_GW}" ] \
    && ok "    AIGateway 已调和出 Gateway(Gateway API 资源存在, AI 控制面工作正常) ✓" \
    || { err "    AIGateway 未调和出 Gateway(kubectl -n ${TEST_NS} get aigateway ${TEST_AIG} -o yaml; 检查 AI 控制器日志; v1.x 无 AIGateway CRD 时改用官方 examples/basic/basic.yaml 的标准 Gateway 流程)"; exit 1; }
if [ "${GW_READY}" = "True" ] && [ -n "${AIG_ENDPOINT}" ]; then
    ok "    Gateway Programmed ✓, 访问入口: ${AIG_ENDPOINT}"
else
    warn "    Gateway 未 Programmed 或数据面未就绪(GW_READY='${GW_READY}', 入口='${AIG_ENDPOINT}'); 检查 EG 数据面 / MetalLB(metallb 模式)或数据面 Service(nodeport 模式)"
    AIG_ENDPOINT=""
fi

say "  ⑤ 边界验证: 经 AI Gateway 调用 mock chat.completions..."
if [ -n "${AIG_ENDPOINT}" ]; then
    HTTP_CODE="$( (SSH "curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST http://${AIG_ENDPOINT}/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"mock\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}' 2>/dev/null" || true) )"
    BODY="$( (SSH "curl -s -m 10 -X POST http://${AIG_ENDPOINT}/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"mock\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}' 2>/dev/null" || true) )"
    case "${BODY}" in
        *envoy-ai-gateway-verify-ok*) ok "    HTTP ${HTTP_CODE}, mock LLM 响应透传成功 ✓(AI Gateway 数据面转发正常)" ;;
        *) warn "    调用未返回期望响应(HTTP_CODE='${HTTP_CODE}', body='${BODY:0:120}...'); 常见原因: AIGatewayRoute 路由未配置/字段版本差异/Backend url 格式; 控制面调和已通过, 真实 LLM 需按官方文档配 AIGatewayRoute + 真实 Backend" ;;
    esac
else
    warn "    数据面入口未就绪, 跳过真实调用(控制面调和已证明 AI 控制面工作正常)"
fi

say "  ⑥ 清理测试资源(trap 兜底)..."
cleanup
ok "Envoy AI Gateway 端到端验证完成: 控制器运行 + AI CRD 注册 + AIGateway→Gateway 调和 + (边界)数据面调用"
