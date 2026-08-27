#!/bin/bash
# ============================================================
# MODULE: verify_envoy_gateway
# DESC: 端到端验证 Envoy Gateway 真正工作(非仅 pod running):
#       ① 控制面 pod Ready → ② GatewayClass eg Accepted → ③ 建测试 Gateway+HTTPRoute+busybox httpd 后端
#       → ④ 等 MetalLB 分配 VIP / 后端 Ready → ⑤ curl VIP 真实转发 HTTP 200 → ⑥ 清理(trap 兜底)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# 说明:
#   · **验证模块不设 TOGGLE**(否则 ENVOY_GATEWAY_ENABLED=true 时会被安装流程自动启用);
#     保持 DEFAULT:0, 仅由 --steps verify_envoy_gateway 在安装后单独执行。
#   · ③④⑤ 步用离线预加载的 busybox 镜像做 HTTP 后端, 验证 EG 数据面真实转发
#     (Gateway → MetalLB VIP → Envoy 数据面 → 后端 pod)。
#   · 参考: https://gateway.envoyproxy.io/ 与 docs/envoy-gateway.md §4.1
# 数据源: cluster.conf (ENVOY_GATEWAY_ENABLED / ENVOY_EG_NAMESPACE / NODES / SSH_KEY_NAME / METALLB_POOL)
# 用法:   sudo ./deploy-cluster.sh --steps verify_envoy_gateway
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# 开关检查: 未启用 Envoy Gateway 则跳过(不报错)
[ "${ENVOY_GATEWAY_ENABLED:-false}" = "true" ] || { say "ENVOY_GATEWAY_ENABLED=false, 跳过验证"; exit 0; }

FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
SSH() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
           "${SSH_USER:-ubuntu}@${FIRST_MASTER}" "$@"; }
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

ENVOY_EG_NAMESPACE="${ENVOY_EG_NAMESPACE:-envoy-gateway-system}"
TEST_NS="verify-eg-$$"   # 唯一命名空间(带 PID 后缀)
TEST_GW="verify-eg-gw"
TEST_HTTPROUTE="verify-eg-route"
TEST_BACKEND="verify-eg-backend"

cleanup() {
    SSH "${K} patch namespace ${TEST_NS} --type=merge -p '{\"metadata\":{\"finalizers\":null}}' >/dev/null 2>&1" || true
    SSH "${K} delete namespace ${TEST_NS} --ignore-not-found=true --force --grace-period=0 >/dev/null 2>&1" || true
}
trap cleanup EXIT

say "验证 Envoy Gateway 工作正常(端到端, 非仅 pod running)..."
say "  ① 检查 EG 控制面 pod 就绪..."
SSH "${K} -n ${ENVOY_EG_NAMESPACE} get pods --no-headers 2>/dev/null | grep -E 'eg-.*1/1 +Running|envoy-gateway-.*1/1 +Running'" \
    || { err "Envoy Gateway 控制面未 Running(kubectl get pods -n ${ENVOY_EG_NAMESPACE})"; exit 1; }

say "  ② 检查 GatewayClass eg 是否 Accepted..."
GC_STATUS="$(SSH "${K} get gatewayclass eg -o jsonpath='{.status.conditions[?(@.type==\"Accepted\")].status}' 2>/dev/null" || true)"
[ "${GC_STATUS}" = "True" ] \
    && ok "    GatewayClass eg Accepted ✓" \
    || { err "GatewayClass eg 未 Accepted(当前='${GC_STATUS}'); 检查控制面日志 kubectl -n ${ENVOY_EG_NAMESPACE} logs deploy/eg"; exit 1; }

say "  ③ 创建测试资源(Gateway + HTTPRoute + busybox httpd 后端)..."
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
          command: ["/bin/sh", "-c", "mkdir -p /www && echo 'envoy-gateway-verify-ok' > /www/index.html && busybox httpd -f -p 8080 -h /www"]
          ports: [{ containerPort: 8080 }]
---
apiVersion: v1
kind: Service
metadata:
  name: ${TEST_BACKEND}
  namespace: ${TEST_NS}
spec:
  selector: { app: ${TEST_BACKEND} }
  ports: [{ port: 8080, targetPort: 8080 }]
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${TEST_GW}
  namespace: ${TEST_NS}
spec:
  gatewayClassName: eg
  listeners:
    - name: http
      protocol: HTTP
      port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${TEST_HTTPROUTE}
  namespace: ${TEST_NS}
spec:
  parentRefs:
    - name: ${TEST_GW}
  rules:
    - matches:
        - path: { type: PathPrefix, value: / }
      backendRefs:
        - name: ${TEST_BACKEND}
          port: 8080
YAML
scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
    "${LOCAL_YAML}" "${SSH_USER:-ubuntu}@${FIRST_MASTER}:/tmp/${TEST_GW}.yaml" \
    && SSH "${K} apply -f /tmp/${TEST_GW}.yaml" \
    && SSH "rm -f /tmp/${TEST_GW}.yaml"
rm -f "${LOCAL_YAML}"

say "  ④ 等待 Gateway 分配 VIP(MetalLB)且后端 Ready(最长 150s)..."
GW_VIP=""
BACKEND_READY=0
for i in $(seq 1 30); do
    GW_VIP="$( (SSH "${K} -n ${TEST_NS} get gateway ${TEST_GW} -o jsonpath='{.status.addresses[0].value}' 2>/dev/null" || true) )"
    BACKEND_READY="$( (SSH "${K} -n ${TEST_NS} get pods --no-headers 2>/dev/null" || true) | awk '$2=="1/1" && $3=="Running"{n++} END{print n+0}' )"
    [ -n "${GW_VIP}" ] && [ "${BACKEND_READY:-0}" -ge 1 ] && break
    sleep 5
done
[ -n "${GW_VIP}" ] || { err "Gateway 未分配到 VIP(kubectl -n ${TEST_NS} get gateway ${TEST_GW}; 检查 MetalLB 池与 EG 数据面)"; exit 1; }
[ "${BACKEND_READY:-0}" -ge 1 ] || { err "测试后端未 Ready(kubectl -n ${TEST_NS} get pods; 检查 busybox 镜像是否预加载)"; exit 1; }
ok "    Gateway 已分配 VIP: ${GW_VIP}; 后端 Ready ✓"

# 确认数据面镜像来自集群内置 registry(离线关键点)
DP_IMG="$( (SSH "${K} -n ${TEST_NS} get deploy -l gateway.envoyproxy.io/owning-gateway-name=${TEST_GW} -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null" || true) )"
[ -z "${DP_IMG}" ] \
    && DP_IMG="$( (SSH "${K} -n ${ENVOY_EG_NAMESPACE} get deploy -l gateway.envoyproxy.io/owning-gateway-name=${TEST_GW} -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null" || true) )"
if [ -n "${DP_IMG}" ]; then
    echo "    数据面镜像: ${DP_IMG}"
    case "${DP_IMG}" in
        *"${REGISTRY_DOMAIN}"*) ok "    数据面镜像来自集群内置 registry ✓" ;;
        *) warn "    数据面镜像不是内置 registry(${DP_IMG}); 离线集群可能 ImagePullBackOff, 检查 chart values envoyGateway.image.*" ;;
    esac
else
    warn "    未找到数据面 Deployment(检查 Gateway 状态: kubectl -n ${TEST_NS} describe gateway ${TEST_GW})"
fi

say "  ⑤ 真实功能验证: curl http://${GW_VIP}/ 应返回后端内容..."
HTTP_CODE="$( (SSH "curl -s -o /dev/null -w '%{http_code}' -m 10 http://${GW_VIP}/ 2>/dev/null" || true) )"
BODY="$( (SSH "curl -s -m 10 http://${GW_VIP}/ 2>/dev/null" || true) )"
[ "${HTTP_CODE}" = "200" ] && [ -n "${BODY}" ] \
    && ok "    HTTP ${HTTP_CODE}, 响应: ${BODY} ✓" \
    || { err "    转发失败(HTTP_CODE='${HTTP_CODE}', body='${BODY}'); 检查数据面/HTTPRoute/后端"; exit 1; }

say "  ⑥ 清理测试资源(trap 兜底)..."
cleanup
ok "Envoy Gateway 端到端验证通过: 控制面运行 + GatewayClass Accepted + MetalLB VIP + 真实 HTTP 转发 200"
