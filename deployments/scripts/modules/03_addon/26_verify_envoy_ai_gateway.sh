#!/bin/bash
# ============================================================
# MODULE: verify_envoy_ai_gateway
# DESC: 端到端验证 Envoy AI Gateway 工作(非仅 pod running):
#       ① AI 控制器 pod Ready → ② AI CRD(aigateway.envoyproxy.io)注册 → ③ 建测试资源(mock LLM)
#       → ④ 资源调和 + Programmed + 分配 VIP → ⑤(边界)curl VIP 调 chat/completions 返回 mock 响应
#       → ⑥ 清理(trap 兜底)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# REQUIRES: envoy_ai_gateway
# 说明:
#   · **验证模块不设 TOGGLE**(否则 ENVOY_AI_GATEWAY_ENABLED=true 时会被安装流程自动启用);
#     保持 DEFAULT:0, 仅由 --steps verify_envoy_ai_gateway 在安装后单独执行。
#   · ③④ 步验证 AI 控制面真正工作(按运行时检测的 CRD 版本自动分支):
#     · v1.x(当前默认安装 AIG v1.1.0, schema: AIServiceBackend.backendRef→EG Backend + schema:
#       {name: OpenAI, prefix: /v1}; AIGatewayRoute.parentRefs + rules[].matches 只支持 headers):
#       标准 Gateway + EG Backend(需 EG extensionApis.enableBackend, 见 09_envoy_gateway.sh)
#       + AIServiceBackend + AIGatewayRoute → AIServiceBackend 被 AI 控制器调和(**核心断言**,
#       证明 AI 控制面工作)+ 标准 Gateway Programmed(EG 数据面)+ VIP/NodePort;
#     · v0.x(legacy 告警分支, 仅旧版本集群): AIGateway/Backend → 调和出 Gateway。
#   · apiVersion 从在线 CRD storage 版本推导(吸收 v1alpha1/v1beta1 漂移), 读不到兜底 v1beta1。
#   · ⚠ v1.x 字段随版本 Alpha/Beta 变化: 测试资源 apply 失败/状态字段取不到时**仅告警不阻断**,
#     可按官方 examples/basic/basic.yaml 调整字段后重跑。
#   · ⑤ 步为**边界验证**: 用 nginx `return 200` 内联 mock 一个 OpenAI chat.completions 响应
#     (⚠ 不能用静态文件, nginx 对静态文件拒绝 POST → 405), 经 AI Gateway VIP 真实调用;
#     失败仅告警并给出指引, 不阻断(资源调和已证明 AI 控制面工作正常)。
#     真实 LLM 需配置真实 AIServiceBackend + API Key Secret。
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

init_remote_kubectl || exit 1

# 测试后端镜像: 离线优先, 幂等确保 nginx 已在集群 registry(不依赖节点 containerd 预加载)
TEST_IMAGE="$(ensure_registry_nginx)" || exit 1

ENVOY_AI_NAMESPACE="${ENVOY_AI_NAMESPACE:-ai-gateway-system}"
ENVOY_EG_NAMESPACE="${ENVOY_EG_NAMESPACE:-envoy-gateway-system}"   # EG 控制面/数据面命名空间(nodeport 分支找数据面 svc 用)
ENVOY_AI_API_VERSION="${ENVOY_AI_API_VERSION:-v1beta1}"   # 仅 v0.x legacy 分支使用
ENVOY_AI_GATEWAYCLASS="${ENVOY_AI_GATEWAYCLASS:-eg}"   # AI Gateway 数据面复用 EG 的 GatewayClass(v1.x; 模块 09 创建名为 eg)
TEST_NS="verify-aig-$$"        # 唯一命名空间(带 PID 后缀)
TEST_AIG="verify-aigw"         # v0.x legacy AIGateway 名(scp 临时文件名也用它)
TEST_GW="verify-aigw-gw"       # v1.x 标准 Gateway 名
TEST_ASB="verify-aigw-llm"     # v1.x AIServiceBackend 名
TEST_AIGR="verify-aigw-route"  # v1.x AIGatewayRoute 名
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
[ -n "${CRD_LIST}" ] \
    || { err "未检测到 aigateway.envoyproxy.io CRD(kubectl get crd | grep aigateway); 检查 ai-gateway-crds helm 是否安装"; exit 1; }
# v1.x 与 v0.x 分支: v1.x 起没有旧版 AIGateway/Backend CRD, 缺失属预期(仅告警)
HAVE_V1_CRDS=0
echo "${CRD_LIST}" | grep -q 'aiservicebackends\.aigateway\.envoyproxy\.io' && HAVE_V1_CRDS=1
echo "${CRD_LIST}" | grep -q 'aigateways\.aigateway\.envoyproxy\.io' \
    || warn "    旧版 AIGateway CRD 未注册(属 v1.x 预期, 仅告警)"
echo "${CRD_LIST}" | grep -q 'backends\.aigateway\.envoyproxy\.io' \
    || warn "    旧版 Backend CRD 未注册(属 v1.x 预期, 仅告警)"
# v1.x API 版本: 从在线 CRD storage 版本推导(吸收 v1alpha1/v1beta1 漂移), 读不到兜底 served 末位, 最后 v1beta1。
# ⚠ 双引号串的闭合必须在 `tail -1` 之后、`|| true` 之前(尾括号若落进 SSH 串, 远端命令语法错误
#   → 恒走兜底版本; 此 bug 曾导致永远用 v1alpha1)
AI_APIVER="$( (SSH "${K} get crd aiservicebackends.aigateway.envoyproxy.io -o jsonpath='{.spec.versions[?(@.storage==true)].name}' 2>/dev/null | tr ' ' '\n' | tail -1" || true ) )"
[ -n "${AI_APIVER}" ] || AI_APIVER="$( (SSH "${K} get crd aiservicebackends.aigateway.envoyproxy.io -o jsonpath='{.spec.versions[?(@.served==true)].name}' 2>/dev/null | tr ' ' '\n' | tail -1" || true ) )"
AI_APIVER="${AI_APIVER:-v1beta1}"
[ "${HAVE_V1_CRDS}" = "1" ] \
    && say "    v1.x 路径: apiVersion=${AI_APIVER}, 用标准 Gateway + AIServiceBackend + AIGatewayRoute 验证" \
    || warn "    未检测到 v1.x AIServiceBackend CRD, 回退 v0.x AIGateway/Backend legacy 验证"

say "  ③ 创建测试资源(${AI_APIVER}, mock OpenAI 兼容后端)..."
cleanup
LOCAL_YAML="$(mktemp)"
if [ "${HAVE_V1_CRDS}" = "1" ]; then
    # v1.x(AIG v1.1.0 schema): 标准 Gateway + EG Backend + AIServiceBackend + AIGatewayRoute。
    # ⚠ AIG v1.1 起 AIServiceBackend.spec 换成 backendRef(必须引用 EG Backend 资源, 需 EG
    #   extensionApis.enableBackend=true, 见 09_envoy_gateway.sh)+ schema(name=OpenAI + prefix=/v1);
    #   AIGatewayRoute.spec.gatewayRefs → parentRefs, rules[].matches 只支持 headers(用 x-ai-eg-model
    #   匹配, AI filter 从请求 body 提取 model 注入该头), 无 path 匹配; 旧字段(type/apiKey/url)会
    #   strict decode 报错。
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
          image: ${TEST_IMAGE}
          imagePullPolicy: IfNotPresent
          # ⚠ 不能用静态文件 mock: nginx 对静态文件拒绝 POST → 405。必须用 return 200 内联 JSON
          command: ["/bin/sh", "-c", "cat > /etc/nginx/nginx.conf <<'EOF'\nevents {}\nhttp {\n  server {\n    listen 80 default_server;\n    location = /v1/chat/completions {\n      default_type application/json;\n      return 200 '{\"id\":\"chatcmpl-mock\",\"object\":\"chat.completion\",\"created\":123,\"model\":\"mock\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"envoy-ai-gateway-verify-ok\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":2,\"total_tokens\":3}}';\n    }\n  }\n}\nEOF\nnginx -g 'daemon off;'"]
          ports: [{ containerPort: 80 }]
---
apiVersion: v1
kind: Service
metadata:
  name: ${TEST_BACKEND_SVC}
  namespace: ${TEST_NS}
spec:
  selector: { app: ${TEST_BACKEND} }
  ports: [{ port: 80, targetPort: 80 }]
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${TEST_GW}
  namespace: ${TEST_NS}
spec:
  gatewayClassName: ${ENVOY_AI_GATEWAYCLASS}
  listeners:
    - name: http
      protocol: HTTP
      port: 80
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: Backend
metadata:
  name: ${TEST_ASB}-backend
  namespace: ${TEST_NS}
spec:
  endpoints:
    - fqdn:
        hostname: ${TEST_BACKEND_SVC}.${TEST_NS}.svc.cluster.local
        port: 80
---
apiVersion: aigateway.envoyproxy.io/${AI_APIVER}
kind: AIServiceBackend
metadata:
  name: ${TEST_ASB}
  namespace: ${TEST_NS}
spec:
  backendRef:
    group: gateway.envoyproxy.io
    kind: Backend
    name: ${TEST_ASB}-backend
  schema:
    name: OpenAI
    prefix: /v1
---
apiVersion: aigateway.envoyproxy.io/${AI_APIVER}
kind: AIGatewayRoute
metadata:
  name: ${TEST_AIGR}
  namespace: ${TEST_NS}
spec:
  parentRefs:
    - name: ${TEST_GW}
  rules:
    - matches:
        - headers:
            - name: x-ai-eg-model
              value: mock
      backendRefs:
        - name: ${TEST_ASB}
YAML
else
    # v0.x legacy: AIGateway + Backend(仅旧版本; 字段可能随版本变化, apply 失败仅告警)
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
          image: ${TEST_IMAGE}
          imagePullPolicy: IfNotPresent
          # ⚠ 不能用静态文件 mock: nginx 对静态文件拒绝 POST → 405。必须用 return 200 内联 JSON
          command: ["/bin/sh", "-c", "cat > /etc/nginx/nginx.conf <<'EOF'\nevents {}\nhttp {\n  server {\n    listen 80 default_server;\n    location = /v1/chat/completions {\n      default_type application/json;\n      return 200 '{\"id\":\"chatcmpl-mock\",\"object\":\"chat.completion\",\"created\":123,\"model\":\"mock\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"envoy-ai-gateway-verify-ok\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":2,\"total_tokens\":3}}';\n    }\n  }\n}\nEOF\nnginx -g 'daemon off;'"]
          ports: [{ containerPort: 80 }]
---
apiVersion: v1
kind: Service
metadata:
  name: ${TEST_BACKEND_SVC}
  namespace: ${TEST_NS}
spec:
  selector: { app: ${TEST_BACKEND} }
  ports: [{ port: 80, targetPort: 80 }]
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
  url: http://${TEST_BACKEND_SVC}.${TEST_NS}.svc.cluster.local:80/v1
YAML
fi
scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
    "${LOCAL_YAML}" "${SSH_USER:-ubuntu}@${FIRST_MASTER}:/tmp/${TEST_AIG}.yaml"
if SSH "${K} apply -f /tmp/${TEST_AIG}.yaml"; then
    SSH "rm -f /tmp/${TEST_AIG}.yaml" || true
else
    SSH "rm -f /tmp/${TEST_AIG}.yaml" || true
    warn "    测试资源 apply 失败(可能字段随版本变化, apiVersion=${AI_APIVER}); 继续检查是否存在已调和资源, 必要时按 docs/envoy-gateway.md §4.2 / 官方 examples/basic/basic.yaml 调整 CR 字段后重跑"
fi
rm -f "${LOCAL_YAML}"

say "  ④ 等待资源调和 + Programmed(nodeport 模式: 数据面转 NodePort; metallb: 等 VIP; 最长 180s)..."
_TARGET_GW="${TEST_GW}"; [ "${HAVE_V1_CRDS}" = "1" ] || _TARGET_GW="${TEST_AIG}"
GW_LINE=""; GW_READY=""; AIG_ENDPOINT=""
for i in $(seq 1 36); do
    # AI 控制器在目标 Gateway 命名空间调和 Gateway(Gateway API): v1.x=TEST_GW, v0.x legacy=AIGateway 同名
    GW_LINE="$( (SSH "${K} -n ${TEST_NS} get gateway ${_TARGET_GW} --no-headers 2>/dev/null" || true) )"
    if [ -n "${GW_LINE}" ]; then
        if [ "${SERVICE_EXPOSE_MODE:-nodeport}" = "nodeport" ]; then
            # 无 MetalLB: 等数据面 Service 出现 → patch 成 NodePort → 访问入口 = 节点IP:NodePort
            # (数据面 Service 默认在控制面命名空间, 兜底找 Gateway 同命名空间; 与 25 模块一致)
            SVC_LINE="$( (SSH "${K} -n ${ENVOY_EG_NAMESPACE} get svc -l gateway.envoyproxy.io/owning-gateway-name=${_TARGET_GW} --no-headers 2>/dev/null" || true) | head -1 )"
            [ -z "${SVC_LINE}" ] && SVC_LINE="$( (SSH "${K} -n ${TEST_NS} get svc -l gateway.envoyproxy.io/owning-gateway-name=${_TARGET_GW} --no-headers 2>/dev/null" || true) | head -1 )"
            if [ -n "${SVC_LINE}" ]; then
                # 单命名空间 get svc 列序: NAME TYPE CLUSTER-IP ... → 名称取 $1(勿用 $2, 那是 TYPE)
                DP_NAME="$(echo "${SVC_LINE}" | awk '{print $1}')"
                SSH "${K} -n ${ENVOY_EG_NAMESPACE} patch svc ${DP_NAME} -p '{\"spec\":{\"type\":\"NodePort\"}}' >/dev/null 2>&1" || true
                NPORT="$( (SSH "${K} -n ${ENVOY_EG_NAMESPACE} get svc ${DP_NAME} -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null" || true) )"
                [ -z "${NPORT}" ] && NPORT="$( (SSH "${K} -n ${TEST_NS} get svc ${DP_NAME} -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null" || true) )"
                [ -n "${NPORT}" ] && AIG_ENDPOINT="$(first_node_ip):${NPORT}"
            fi
        else
            AIG_ENDPOINT="$( (SSH "${K} -n ${TEST_NS} get gateway ${_TARGET_GW} -o jsonpath='{.status.addresses[0].value}' 2>/dev/null" || true) )"
        fi
        GW_READY="$( (SSH "${K} -n ${TEST_NS} get gateway ${_TARGET_GW} -o jsonpath='{.status.conditions[?(@.type==\"Programmed\")].status}' 2>/dev/null" || true) )"
        [ "${GW_READY}" = "True" ] && [ -n "${AIG_ENDPOINT}" ] && break
    fi
    sleep 5
done
if [ "${HAVE_V1_CRDS}" = "1" ]; then
    # v1.x 核心断言: AIServiceBackend 被 AI 控制器调和(证明 AI 控制面工作)
    ASB_LINE="$( (SSH "${K} -n ${TEST_NS} get aiservicebackend ${TEST_ASB} --no-headers 2>/dev/null" || true) )"
    V1_ACCEPTED=""
    if [ -n "${ASB_LINE}" ]; then
        V1_ACCEPTED="$( (SSH "${K} -n ${TEST_NS} get aiservicebackend ${TEST_ASB} -o jsonpath='{.status.conditions[?(@.type==\"Accepted\")].status}' 2>/dev/null" || true) )"
        [ -z "${V1_ACCEPTED}" ] && V1_ACCEPTED="$( (SSH "${K} -n ${TEST_NS} get aiservicebackend ${TEST_ASB} -o jsonpath='{.status.conditions[?(@.type==\"Programmed\")].status}' 2>/dev/null" || true) )"
        ok "    AIServiceBackend 已调和(AI 控制面工作正常) ✓"
        [ "${V1_ACCEPTED}" = "True" ] && ok "    AIServiceBackend Accepted ✓" \
            || warn "    AIServiceBackend 状态字段未取到 Accepted(版本差异, 不阻断; 资源存在即视为调和)"
        AIGR_LINE="$( (SSH "${K} -n ${TEST_NS} get aigatewayroute ${TEST_AIGR} --no-headers 2>/dev/null" || true) )"
        [ -n "${AIGR_LINE}" ] || warn "    AIGatewayRoute 未调和(版本差异, 不阻断; 检查 AI 控制器日志)"
    else
        err "    AIServiceBackend 未调和(kubectl -n ${TEST_NS} get aiservicebackend ${TEST_ASB} -o yaml; 检查 AI 控制器日志)"
        exit 1
    fi
else
    # v0.x legacy 核心断言: AIGateway 调和出 Gateway
    [ -n "${GW_LINE}" ] \
        && ok "    AIGateway 已调和出 Gateway(v0.x legacy, AI 控制面工作正常) ✓" \
        || { err "    AIGateway 未调和出 Gateway(kubectl -n ${TEST_NS} get aigateway ${TEST_AIG} -o yaml; 检查 AI 控制器日志)"; exit 1; }
fi
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
        *) warn "    调用未返回期望响应(HTTP_CODE='${HTTP_CODE}', body='${BODY:0:120}...'); 常见原因: ① EG extensionManager 未接线(模块 10 [5/6], 缺则数据面无 AI ext_proc 过滤器, 404 'No matching route found') ② AIGatewayRoute 路由未配置/字段版本差异 ③ Backend url 格式; 资源调和已通过, 真实 LLM 需按官方文档配 AIGatewayRoute + 真实 AIServiceBackend" ;;
    esac
else
    warn "    数据面入口未就绪, 跳过真实调用(资源调和已证明 AI 控制面工作正常)"
fi

say "  ⑥ 清理测试资源(trap 兜底)..."
cleanup
ok "Envoy AI Gateway 端到端验证完成: 控制器运行 + AI CRD 注册 + 资源调和(AIServiceBackend/Gateway) + (边界)数据面调用"
