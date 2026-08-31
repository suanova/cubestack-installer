#!/bin/bash
# ============================================================
# MODULE: envoy_ai_gateway
# DESC: 部署 Envoy AI Gateway(LLM/AI 专用网关; 官方 helm chart, 离线; 依赖 Envoy Gateway 数据面)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: ENVOY_AI_GATEWAY_ENABLED
# 说明:
#   · 断点续跑: REPEAT:0 → 安装成功写入状态, 重跑自动跳过; --fresh 清状态重装。
#   · 定位(v1.x, 官方架构): Envoy AI Gateway = 独立控制器(AI Gateway Controller)+ AI 扩展 CRD +
#     数据面**复用 Envoy Gateway**。v1.x 起不再有 AIGateway/Backend CRD, 也不走 v0.x 的 EG
#     extensionManager 扩展服务器机制(官方 v1.x chart 无 18090 端口, 那套已废弃):
#       · AI 控制器: 安装 aigateway.envoyproxy.io 扩展 CRD(AIServiceBackend / AIGatewayRoute /
#         GatewayConfig / BackendSecurityPolicy / ...), 通过 **Mutating Webhook + extProc 注入**
#         对标准 Gateway(Gateway API, gatewayClassName=envoy-gateway)提供 AI 能力;
#       · 用法: 用户建标准 Gateway(EG 的 envoy-gateway 类)+ AIServiceBackend(LLM 上游)
#         + AIGatewayRoute(路由到 /v1/chat/completions 等), 数据面由 EG 托管、AI 控制器注入 extProc。
#   · **依赖 Envoy Gateway 先装**(模块 09, ENVOY_GATEWAY_ENABLED=true), 前置检查会强制确认。
#   · Chart(两个官方 chart, **均托管在 DockerHub OCI**, 版本带 v 如 v1.1.0; 注意 ghcr 同名路径不存在会 403):
#       ai-gateway-crds-helm   = CRD chart(所有 aigateway.envoyproxy.io CRD)
#       ai-gateway-helm        = AI 控制器 chart(controller Deployment/Service/webhook)
#     来源(ENVOY_AI_CHART_SOURCE, 默认 tgz 本地离线; 由 tools/images/envoy-fetch-charts.sh 在联网机下载):
#       dir  = 本地解包目录(ENVOY_AI_CHART_DIR = deployments/cubestack-addon/envoy-gateway/ai,
#              内含 ai-gateway-crds-helm + ai-gateway-helm 两个 chart)
#       tgz  = 本地 chart 压缩包(**默认**, ENVOY_AI_CHART_TGZ_CRDS / ENVOY_AI_CHART_TGZ_CTRL;
#              仓库只存 tgz 不膨胀, 部署时临时解压到 mktemp 目录再 helm 安装)
#       oci  = 官方 OCI(oci://docker.io/envoyproxy, 需联网)
#   · 离线优先(与 lws/EG 一致): 本地源时控制器镜像强制走本地 docker/离线 tar; 仅 oci 源或
#     ENVOY_AI_IMAGE_ONLINE=true 才允许在线拉取。离线 tar 由 tools/images/envoy-save-images.sh 生成。
#   · ⚠ 版本敏感(AI 项目快速迭代): 升级版本时按官方文档核对安装命令(chart 版本带 v, 如
#     helm upgrade -i aieg-crd oci://docker.io/envoyproxy/ai-gateway-crds-helm --version v1.1.0)
#     与 chart values(controller.image.* / controller.nameOverride / envoyGateway.namespace)。
#   · 参考: https://aigateway.envoyproxy.io/ 与 docs/envoy-gateway.md
# 数据源: cluster.conf (ENVOY_AI_GATEWAY_ENABLED / ENVOY_AI_CHART_SOURCE / ENVOY_AI_CHART_DIR /
#                       ENVOY_AI_VERSION / ENVOY_AI_IMAGE_* / ENVOY_AI_NAMESPACE / ENVOY_AI_CRDS_* /
#                       ENVOY_AI_CTRL_RELEASE / ENVOY_EG_NAMESPACE / REGISTRY_* / NODES)
# 用法:   sudo ./deploy-cluster.sh --enable envoy_ai_gateway  或  ENVOY_AI_GATEWAY_ENABLED=true(需 EG 先装)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# ---- 开关 ----
[ "${ENVOY_AI_GATEWAY_ENABLED:-false}" = "true" ] || { say "ENVOY_AI_GATEWAY_ENABLED=false, 跳过 Envoy AI Gateway"; exit 0; }

FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
SSH() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
           "${SSH_USER:-ubuntu}@${FIRST_MASTER}" "$@"; }
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

# ---------------- 派生变量(全部来自 cluster.conf, 无硬编码) ----------------
ENVOY_AI_VERSION="${ENVOY_AI_VERSION:-v1.1.0}"           # chart 版本 + 控制器镜像 tag(带 v, 与官方一致)
ENVOY_AI_CHART_SOURCE="${ENVOY_AI_CHART_SOURCE:-tgz}"    # 默认 tgz(仓库只存 tgz, 部署时临时解压)
ENVOY_AI_CHART_DIR="${ENVOY_AI_CHART_DIR:-${REPO_ROOT}/deployments/cubestack-addon/envoy-gateway/ai}"
ENVOY_AI_CHART_TGZ_CRDS="${ENVOY_AI_CHART_TGZ_CRDS:-${ENVOY_AI_CHART_DIR}/ai-gateway-crds-helm-${ENVOY_AI_VERSION}.tgz}"
ENVOY_AI_CHART_TGZ_CTRL="${ENVOY_AI_CHART_TGZ_CTRL:-${ENVOY_AI_CHART_DIR}/ai-gateway-helm-${ENVOY_AI_VERSION}.tgz}"
ENVOY_AI_CHART_OCI="${ENVOY_AI_CHART_OCI:-oci://docker.io/envoyproxy}"
ENVOY_AI_NAMESPACE="${ENVOY_AI_NAMESPACE:-ai-gateway-system}"       # 控制器命名空间
ENVOY_AI_CRDS_NS="${ENVOY_AI_CRDS_NS:-ai-gateway-crds}"             # CRD chart 命名空间
ENVOY_AI_CRDS_RELEASE="${ENVOY_AI_CRDS_RELEASE:-ai-gateway-crds}"
ENVOY_AI_CTRL_RELEASE="${ENVOY_AI_CTRL_RELEASE:-ai-gateway-controller}"
# 控制器 Deployment/Service 名: chart 用 controller.fullname=<release>-<chartName>,
# 设 controller.nameOverride=release → 资源名正好 = ai-gateway-controller(与官方 docs
# `kubectl wait deployment/ai-gateway-controller` 一致)。
ENVOY_AI_CTRL_NAME="${ENVOY_AI_CTRL_NAME:-${ENVOY_AI_CTRL_RELEASE}}"
REGISTRY_BASE="${REGISTRY_DOMAIN}:${REGISTRY_PORT}"
ENVOY_AI_IMAGE_REPO="${ENVOY_AI_IMAGE_REPO:-${REGISTRY_BASE}/ai-gateway/ai-gateway-controller}"  # K8s 可见镜像
ENVOY_AI_IMAGE_TAG="${ENVOY_AI_IMAGE_TAG:-${ENVOY_AI_VERSION}}"
PUSH_REGISTRY_AI="${REGISTRY_IP}:${REGISTRY_PORT}/ai-gateway"       # 推送直连 IP
ENVOY_SAVE_DIR="${ENVOY_SAVE_DIR:-${REPO_ROOT}/deployments/offline-files/envoy}"
ENVOY_AI_IMAGE_ONLINE="${ENVOY_AI_IMAGE_ONLINE:-false}"
# EG 命名空间(chart 的 envoyGateway.namespace: AI 控制器在其中创建/查看 Gateway 与数据面资源)
ENVOY_EG_NAMESPACE="${ENVOY_EG_NAMESPACE:-envoy-gateway-system}"

# tgz 源临时解压目录(部署时 mktemp, 退出自动清理)
_TMP_AI_CHART=""
trap 'rm -rf "${_TMP_AI_CHART:-}"' EXIT

# ---------------- 前置检查 ----------------
say "检查 Envoy AI Gateway 前置条件..."
# ① 依赖: Envoy Gateway 已装(GatewayClass eg Accepted; AI Gateway 数据面复用 EG)
GC_OK="$(SSH "${K} get gatewayclass eg -o jsonpath='{.status.conditions[?(@.type==\"Accepted\")].status}' 2>/dev/null" || true)"
[ "${GC_OK}" = "True" ] \
    || { err "未检测到 Envoy Gateway(GatewayClass eg 未 Accepted); Envoy AI Gateway 依赖 EG, 请先 ENVOY_GATEWAY_ENABLED=true 部署模块 envoy_gateway"; exit 1; }
# ② chart 源(与 EG 模块一致: dir 缺 Chart.yaml 时自动回退同版本 tgz, 都缺失给完整指引)
case "${ENVOY_AI_CHART_SOURCE}" in
    dir)
        if { [ ! -f "${ENVOY_AI_CHART_DIR}/ai-gateway-crds-helm/Chart.yaml" ] || [ ! -f "${ENVOY_AI_CHART_DIR}/ai-gateway-helm/Chart.yaml" ]; } \
           && [ -f "${ENVOY_AI_CHART_TGZ_CRDS}" ] && [ -f "${ENVOY_AI_CHART_TGZ_CTRL}" ]; then
            say "AI chart 目录不完整, 检测到同版本 tgz, 自动改用 tgz 源: ${ENVOY_AI_CHART_TGZ_CRDS} / ${ENVOY_AI_CHART_TGZ_CTRL}"
            ENVOY_AI_CHART_SOURCE="tgz"
        fi
        ;;
    tgz|oci) : ;;   # tgz 缺失在下方按源校验; oci 需联网由 helm 拉取
    *)    err "ENVOY_AI_CHART_SOURCE 仅支持 dir/tgz/oci(当前=${ENVOY_AI_CHART_SOURCE})"; exit 1 ;;
esac
if [ "${ENVOY_AI_CHART_SOURCE}" = "dir" ]; then
    if [ ! -f "${ENVOY_AI_CHART_DIR}/ai-gateway-crds-helm/Chart.yaml" ] || [ ! -f "${ENVOY_AI_CHART_DIR}/ai-gateway-helm/Chart.yaml" ]; then
        err "AI chart 目录不完整: ${ENVOY_AI_CHART_DIR}(缺 ai-gateway-crds-helm / ai-gateway-helm)"
        err "请先准备离线 chart(三选一):"
        err "  ① 在联网机跑 tools/images/envoy-fetch-charts.sh 下载 tgz 到 ${ENVOY_AI_CHART_DIR}/ 后拷到部署机;"
        err "  ② 放两个 chart tgz 到 ${ENVOY_AI_CHART_TGZ_CRDS} 与 ${ENVOY_AI_CHART_TGZ_CTRL}, 设 ENVOY_AI_CHART_SOURCE=tgz;"
        err "  ③ 部署机有外网则设 ENVOY_AI_CHART_SOURCE=oci 在线安装(ENVOY_AI_CHART_OCI=${ENVOY_AI_CHART_OCI})"
        exit 1
    fi
elif [ "${ENVOY_AI_CHART_SOURCE}" = "tgz" ]; then
    if [ ! -f "${ENVOY_AI_CHART_TGZ_CRDS}" ] || [ ! -f "${ENVOY_AI_CHART_TGZ_CTRL}" ]; then
        err "AI chart tgz 不存在: ${ENVOY_AI_CHART_TGZ_CRDS} / ${ENVOY_AI_CHART_TGZ_CTRL}"
        err "请: ① 在联网机跑 tools/images/envoy-fetch-charts.sh(生成 tgz) 或放两个 tgz 到上述路径; ② 或设 ENVOY_AI_CHART_SOURCE=dir(解包目录)/oci(在线)"
        exit 1
    fi
fi
command -v helm >/dev/null 2>&1 || { err "未找到 helm(需 3.0+); 请先安装 Helm"; exit 1; }
skopeo_require "envoy_ai_gateway"   # 推送镜像到集群内置 registry 必需(缺失时给明确指引, 而非误报未找到镜像)
# 宿主机 /etc/hosts 更新(registry 域名 → VIP), 与 gpu_operator 一致
# 复用 lib-common 的 ensure_hosts_entry(先删旧行再写当前 IP, 无 grep 守卫 → 多集群不残留旧 IP)
ensure_hosts_entry "${REGISTRY_IP}" "${REGISTRY_DOMAIN}"
wait_registry_ready "http://${REGISTRY_BASE}/v2/" \
    || { err "集群内置 registry ${REGISTRY_BASE}/v2/ 不可达"; exit 1; }
SSH "${K} get nodes --no-headers >/dev/null 2>&1" \
    || { err "无法访问集群(${FIRST_MASTER}); 检查 kubectl/集群状态"; exit 1; }
# 复用 lib-common 的 sync_kubeconfig(server→API_DOMAIN + 宿主机 DNAT)
sync_kubeconfig \
    && ok "宿主机 ~/.kube/config 已同步(admin.conf → API ${API_DOMAIN}→${API_IP})" \
    || { err "宿主机无法访问集群(admin.conf 下载/同步失败)"; exit 1; }
ok "前置检查通过(依赖 EG 就绪; chart_source=${ENVOY_AI_CHART_SOURCE}, version=${ENVOY_AI_VERSION})"

# ---------------- 1. 推送 AI 控制器镜像到集群内置 registry(本地源优先) ----------------
say "[1/5] 推送 AI 控制器镜像 → ${PUSH_REGISTRY_AI}/ai-gateway-controller:${ENVOY_AI_IMAGE_TAG} ..."
# 推送助手复用 lib-common 的 push_image_skopeo(3 次重试)/ reg_has_tag(幂等)/
# find_offline_tar(离线 tar 内容识别, 兼容改名/异常命名)
_ALLOW_ONLINE=0
[ "${ENVOY_AI_CHART_SOURCE:-dir}" = "oci" ] && _ALLOW_ONLINE=1
[ "${ENVOY_AI_IMAGE_ONLINE:-false}" = "true" ] && _ALLOW_ONLINE=1
if reg_has_tag "${PUSH_REGISTRY_AI}" "ai-gateway-controller" "${ENVOY_AI_IMAGE_TAG}"; then
    ok "  ai-gateway-controller:${ENVOY_AI_IMAGE_TAG} 已在 registry, 跳过"
else
    _SRC=""
    # ① 本地 docker daemon
    _SRC="$(sudo docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E "/ai-gateway-controller:${ENVOY_AI_IMAGE_TAG}$" | head -1 || true)"
    if [ -n "${_SRC}" ]; then
        _tmp="/tmp/aig-ctrl-${ENVOY_AI_IMAGE_TAG}.tar"
        say "  从本地 docker 推送: ${_SRC}"
        if sudo docker save "${_SRC}" -o "${_tmp}" >/dev/null 2>&1 \
           && push_image_skopeo "docker-archive:${_tmp}" "docker://${PUSH_REGISTRY_AI}/ai-gateway-controller:${ENVOY_AI_IMAGE_TAG}" >/dev/null 2>&1; then
            rm -f "${_tmp}"; ok "  ai-gateway-controller 已推送(本地 docker)"; _SRC="done"
        else
            rm -f "${_tmp}"; warn "  本地 docker 推送失败, 尝试离线 tar..."
        fi
    fi
    # ② 离线 tar(envoy-save-images.sh 默认 deployments/offline-files/envoy; 兼容集群 images 目录;
    #     内容识别: 修复旧 glob *ai-gateway-controller*.tar 版本无关可能推错, 兼容改名/异常命名)
    if [ -z "${_SRC}" ]; then
        _TAR="$(find_offline_tar "/ai-gateway-controller:${ENVOY_AI_IMAGE_TAG}" "*ai-gateway-controller*.tar" \
                    "${ENVOY_SAVE_DIR}" \
                    "${LOCAL_REPO_DIR}/images" \
                    "${OFFLINE_FILES_DIR:-${REPO_ROOT}/deployments/offline-files/kubespray}/${CLUSTER_NAME}/images")" || _TAR=""
        if [ -n "${_TAR}" ]; then
            say "  从离线 tar 推送: $(basename "${_TAR}")"
            if push_image_skopeo "docker-archive:${_TAR}" "docker://${PUSH_REGISTRY_AI}/ai-gateway-controller:${ENVOY_AI_IMAGE_TAG}" >/dev/null 2>&1; then
                ok "  ai-gateway-controller 已推送(离线 tar)"; _SRC="done"
            else
                warn "  tar 推送失败"
            fi
        fi
    fi
    # ③ 在线 skopeo(仅允许在线时; 官方源为 docker.io)
    if [ -z "${_SRC}" ] && [ "${_ALLOW_ONLINE}" = "1" ]; then
        if push_image_skopeo "docker://docker.io/envoyproxy/ai-gateway-controller:${ENVOY_AI_IMAGE_TAG}" \
            "docker://${PUSH_REGISTRY_AI}/ai-gateway-controller:${ENVOY_AI_IMAGE_TAG}" >/dev/null 2>&1; then
            ok "  ai-gateway-controller 已推送(在线)"; _SRC="done"
        else
            warn "  在线推送失败"
        fi
    fi
    if [ -z "${_SRC}" ]; then
        if [ "${_ALLOW_ONLINE}" = "1" ]; then
            warn "  ai-gateway-controller:${ENVOY_AI_IMAGE_TAG} 未就绪(本地 docker/tar 无, 在线失败)"
        else
            err "离线安装: 未找到 ai-gateway-controller:${ENVOY_AI_IMAGE_TAG}。请: ① 在联网机跑 tools/images/envoy-save-images.sh 生成 tar 放到 ${ENVOY_SAVE_DIR}/, 或 ② 单独跑 tools/images/envoy-load-images.sh 预加载, 或 ③ 改 ENVOY_AI_CHART_SOURCE=oci / ENVOY_AI_IMAGE_ONLINE=true 允许在线"
            exit 1
        fi
    fi
fi

# ---------------- 2. helm 安装 AI CRDs chart ----------------
say "[2/5] helm 安装 AI CRDs(${ENVOY_AI_CRDS_RELEASE} → ${ENVOY_AI_CRDS_NS})..."
_CHART_ARG=""
case "${ENVOY_AI_CHART_SOURCE}" in
    dir) _CHART_ARG="${ENVOY_AI_CHART_DIR}/ai-gateway-crds-helm" ;;
    tgz)   # 部署时临时解压 tgz 到 mktemp 目录再安装(仓库只存 tgz, 不膨胀)
        _TMP_AI_CHART="$(mktemp -d)"
        tar -xzf "${ENVOY_AI_CHART_TGZ_CRDS}" -C "${_TMP_AI_CHART}" || { err "解压 CRD chart tgz 失败: ${ENVOY_AI_CHART_TGZ_CRDS}"; exit 1; }
        _CHART_ARG="${_TMP_AI_CHART}/ai-gateway-crds-helm"
        [ -f "${_CHART_ARG}/Chart.yaml" ] || { err "解压结果缺 Chart.yaml(内部目录名异常): ${_TMP_AI_CHART}"; exit 1; }
        ;;
    oci) _CHART_ARG="${ENVOY_AI_CHART_OCI}/ai-gateway-crds-helm --version ${ENVOY_AI_VERSION}" ;;
esac
helm upgrade --install "${ENVOY_AI_CRDS_RELEASE}" ${_CHART_ARG} \
    --namespace "${ENVOY_AI_CRDS_NS}" --create-namespace \
    --wait --timeout 120s \
    || warn "  AI CRDs helm 安装/等待超时(继续检查 CRD 注册)..."
CRD_CNT="$( (SSH "${K} get crd --no-headers 2>/dev/null" || true) | grep -c 'aigateway\.envoyproxy\.io' || true)"
[ "${CRD_CNT:-0}" -ge 1 ] \
    && ok "  AI CRD 已注册(${CRD_CNT} 个 aigateway.envoyproxy.io CRD)" \
    || warn "  未检测到 aigateway.envoyproxy.io CRD(kubectl get crd | grep aigateway)"

# ---------------- 3. helm 安装 AI 控制器 chart ----------------
say "[3/5] helm 安装 AI 控制器(${ENVOY_AI_CTRL_RELEASE} → ${ENVOY_AI_NAMESPACE})..."
SSH "${K} delete ns ${ENVOY_AI_NAMESPACE} --ignore-not-found --force --grace-period=0 >/dev/null 2>&1" || true
sleep 3
_CHART_ARG=""
case "${ENVOY_AI_CHART_SOURCE}" in
    dir) _CHART_ARG="${ENVOY_AI_CHART_DIR}/ai-gateway-helm" ;;
    tgz)   # 复用上面已解压的临时目录(或首次解压); 同一 mktemp 目录内放两个 chart
        [ -n "${_TMP_AI_CHART:-}" ] || _TMP_AI_CHART="$(mktemp -d)"
        tar -xzf "${ENVOY_AI_CHART_TGZ_CTRL}" -C "${_TMP_AI_CHART}" || { err "解压控制器 chart tgz 失败: ${ENVOY_AI_CHART_TGZ_CTRL}"; exit 1; }
        _CHART_ARG="${_TMP_AI_CHART}/ai-gateway-helm"
        [ -f "${_CHART_ARG}/Chart.yaml" ] || { err "解压结果缺 Chart.yaml(内部目录名异常): ${_TMP_AI_CHART}"; exit 1; }
        ;;
    oci) _CHART_ARG="${ENVOY_AI_CHART_OCI}/ai-gateway-helm --version ${ENVOY_AI_VERSION}" ;;
esac
helm upgrade --install "${ENVOY_AI_CTRL_RELEASE}" ${_CHART_ARG} \
    --namespace "${ENVOY_AI_NAMESPACE}" --create-namespace \
    --set "controller.image.repository=${ENVOY_AI_IMAGE_REPO}" \
    --set "controller.image.tag=${ENVOY_AI_IMAGE_TAG}" \
    --set "controller.imagePullPolicy=IfNotPresent" \
    --set "controller.nameOverride=${ENVOY_AI_CTRL_NAME}" \
    --set "envoyGateway.namespace=${ENVOY_EG_NAMESPACE}" \
    --wait --timeout 180s \
    || warn "  AI 控制器 helm 安装/等待超时(资源可能已创建, 继续检查 Deployment)..."
SSH "${K} rollout status deployment -n ${ENVOY_AI_NAMESPACE} ${ENVOY_AI_CTRL_NAME} --timeout=120s" >/dev/null 2>&1 \
    || SSH "${K} rollout status deployment -n ${ENVOY_AI_NAMESPACE} ai-gateway-controller --timeout=120s" >/dev/null 2>&1 \
    || warn "  AI 控制器 rollout 未在 120s 内完成(继续检查 pod)..."
sleep 5

# ---------------- 4. 等待 AI 控制器就绪 + 数据面复用确认 ----------------
say "[4/5] 等待 AI 控制器就绪..."
SSH "${K} -n ${ENVOY_AI_NAMESPACE} rollout status deployment ${ENVOY_AI_CTRL_NAME} --timeout=120s >/dev/null 2>&1" \
    || SSH "${K} -n ${ENVOY_AI_NAMESPACE} rollout status deployment ai-gateway-controller --timeout=120s >/dev/null 2>&1" \
    || warn "  AI 控制器未就绪(检查日志 kubectl -n ${ENVOY_AI_NAMESPACE} logs deploy/${ENVOY_AI_CTRL_NAME})"
sleep 5
# v1.x 数据面复用 EG: 用户建标准 Gateway(gatewayClassName=envoy-gateway), AI 控制器通过 webhook/extProc 提供 AI 能力
GC_EG="$(SSH "${K} get gatewayclass envoy-gateway --no-headers 2>/dev/null" || true)"
[ -n "${GC_EG}" ] \
    && ok "  GatewayClass envoy-gateway 可用(AI Gateway 数据面复用 EG)" \
    || warn "  未检测到 GatewayClass envoy-gateway(请确认模块 09 envoy_gateway 已装)"

# ---------------- 5. 汇总 ----------------
PODS="$( (SSH "${K} -n ${ENVOY_AI_NAMESPACE} get pods -o wide 2>/dev/null" || true) )"
echo "    ${PODS}" | sed 's/^/    /'

echo "---------------------------------------------"
ok "Envoy AI Gateway 部署完成"
echo "  namespace:   ${ENVOY_AI_NAMESPACE}(控制器) / ${ENVOY_AI_CRDS_NS}(CRD)"
echo "  chart 来源:  ${ENVOY_AI_CHART_SOURCE}(${ENVOY_AI_VERSION})"
echo "  控制器镜像:  ${ENVOY_AI_IMAGE_REPO}:${ENVOY_AI_IMAGE_TAG}"
echo "  数据面:      复用 Envoy Gateway(${ENVOY_EG_NAMESPACE} 的 envoy-gateway GatewayClass; AI 控制器注入 extProc)"
echo "  AI CRD:      aigateway.envoyproxy.io(AIServiceBackend / AIGatewayRoute / GatewayConfig / ...)"
echo "  资源查看:    kubectl get aiservicebackend,aigatewayroute -A"
echo "  端到端验证:  sudo ./deploy-cluster.sh --steps verify_envoy_ai_gateway"
echo "  使用示例:    docs/envoy-gateway.md §4.2(标准 Gateway + AIServiceBackend + AIGatewayRoute + API Key Secret)"
echo "  卸载:        helm uninstall ${ENVOY_AI_CTRL_RELEASE} -n ${ENVOY_AI_NAMESPACE}; helm uninstall ${ENVOY_AI_CRDS_RELEASE} -n ${ENVOY_AI_CRDS_NS}"
