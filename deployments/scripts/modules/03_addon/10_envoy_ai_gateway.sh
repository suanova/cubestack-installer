#!/bin/bash
# ============================================================
# MODULE: envoy_ai_gateway
# DESC: 部署 Envoy AI Gateway(LLM/AI 专用网关; 基于 Envoy Gateway 的扩展层; 离线 helm + 集群内置 registry 镜像)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: ENVOY_AI_GATEWAY_ENABLED
# 说明:
#   · 断点续跑: REPEAT:0 → 安装成功写入状态, 重跑自动跳过; --fresh 清状态重装。
#   · 定位: Envoy AI Gateway **不是独立二进制**, = 特制 Envoy Gateway 控制面 + AI 控制器 +
#     一组 AI CRD(aigateway.envoyproxy.io: AIGateway/Backend/BackendSecurityPolicy/AIGatewayRoute)+ 转换层。
#     它通过 EG 的 **Extension Server 机制**(extensionManager)把 AI CRD 注册给 EG 控制面:
#       AI 控制器: AIGateway/Backend → 翻译为 Gateway/HTTPRoute(Gateway API 资源)
#       EG 控制面 : Gateway/HTTPRoute → xDS 推送数据面(本模块 [4/6] 负责注入 extensionManager 配置)
#   · **依赖 Envoy Gateway 先装**(模块 09, ENVOY_GATEWAY_ENABLED=true), 前置检查会强制确认。
#   · Chart 来源(ENVOY_AI_CHART_SOURCE, 默认 dir 本地离线; 由 tools/images/envoy-fetch-charts.sh 在联网机下载):
#       dir  = 本地解包目录(默认 ENVOY_AI_CHART_DIR = deployments/cubestack-addon/envoy-gateway/ai,
#              内含 ai-gateway-crds-helm + ai-gateway-controller-helm 两个 chart)
#       tgz  = 本地 chart 压缩包(ENVOY_AI_CHART_TGZ_CRDS / ENVOY_AI_CHART_TGZ_CTRL)
#       oci  = 官方 OCI(oci://ghcr.io/envoyproxy/ai-gateway/charts, 需联网)
#   · 离线优先(与 lws/EG 一致): 本地源时控制器镜像强制走本地 docker/离线 tar; 仅 oci 源或
#     ENVOY_AI_IMAGE_ONLINE=true 才允许在线拉取。离线 tar 由 tools/images/envoy-save-images.sh 生成。
#   · 数据面: 复用 Envoy Gateway 模块已安装的数据面(envoyproxy/envoy), AI 控制器本身只翻译 AI CRD。
#   · ⚠ 版本敏感(AI 项目 Alpha/Beta, 快速迭代): AI CRD 字段与 extensionManager 配置结构随版本变化,
#     本模块的关键字段(服务 host/port、证书 secret、GatewayClass 名、CRD apiVersion)全部走 cluster.conf
#     变量, 升级版本时按官方文档核对 docs/envoy-gateway.md §三。
#   · 参考: https://aigateway.envoyproxy.io/ 与 docs/envoy-gateway.md
# 数据源: cluster.conf (ENVOY_AI_GATEWAY_ENABLED / ENVOY_AI_CHART_SOURCE / ENVOY_AI_CHART_DIR / ENVOY_AI_VERSION /
#                       ENVOY_AI_IMAGE_* / ENVOY_AI_NAMESPACE / ENVOY_AI_EXT_* / ENVOY_EG_* / REGISTRY_* / NODES)
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
ENVOY_AI_VERSION="${ENVOY_AI_VERSION:-v1.0.0}"           # AI 控制器版本(镜像 tag + chart version; 1.0 = GA)
ENVOY_AI_CHART_SOURCE="${ENVOY_AI_CHART_SOURCE:-dir}"
ENVOY_AI_CHART_DIR="${ENVOY_AI_CHART_DIR:-${REPO_ROOT}/deployments/cubestack-addon/envoy-gateway/ai}"
ENVOY_AI_CHART_TGZ_CRDS="${ENVOY_AI_CHART_TGZ_CRDS:-${ENVOY_AI_CHART_DIR}/ai-gateway-crds-helm-${ENVOY_AI_VERSION}.tgz}"
ENVOY_AI_CHART_TGZ_CTRL="${ENVOY_AI_CHART_TGZ_CTRL:-${ENVOY_AI_CHART_DIR}/ai-gateway-controller-helm-${ENVOY_AI_VERSION}.tgz}"
ENVOY_AI_CHART_OCI="${ENVOY_AI_CHART_OCI:-oci://ghcr.io/envoyproxy/ai-gateway/charts}"
ENVOY_AI_NAMESPACE="${ENVOY_AI_NAMESPACE:-ai-gateway-system}"       # 控制器命名空间
ENVOY_AI_CRDS_NS="${ENVOY_AI_CRDS_NS:-ai-gateway-crds}"             # CRD chart 命名空间
ENVOY_AI_CRDS_RELEASE="${ENVOY_AI_CRDS_RELEASE:-ai-gateway-crds}"
ENVOY_AI_CTRL_RELEASE="${ENVOY_AI_CTRL_RELEASE:-ai-gateway-controller}"
ENVOY_AI_API_VERSION="${ENVOY_AI_API_VERSION:-v1beta1}"            # AI CRD apiVersion(aigateway.envoyproxy.io/<v>; v1.0 起 v1beta1)
REGISTRY_BASE="${REGISTRY_DOMAIN}:${REGISTRY_PORT}"
ENVOY_AI_IMAGE_REPO="${ENVOY_AI_IMAGE_REPO:-${REGISTRY_BASE}/ai-gateway/ai-gateway-controller}"  # K8s 可见镜像
ENVOY_AI_IMAGE_TAG="${ENVOY_AI_IMAGE_TAG:-${ENVOY_AI_VERSION}}"
PUSH_REGISTRY_AI="${REGISTRY_IP}:${REGISTRY_PORT}/ai-gateway"       # 推送直连 IP
ENVOY_SAVE_DIR="${ENVOY_SAVE_DIR:-${REPO_ROOT}/deployments/offline-files/envoy}"
ENVOY_AI_IMAGE_ONLINE="${ENVOY_AI_IMAGE_ONLINE:-false}"
# EG 扩展(extensionManager)配置: 指向 AI 控制器 Extension Server
ENVOY_AI_EXT_HOST="${ENVOY_AI_EXT_HOST:-ai-gateway-controller.${ENVOY_AI_NAMESPACE}.svc.cluster.local}"
ENVOY_AI_EXT_PORT="${ENVOY_AI_EXT_PORT:-18090}"
ENVOY_AI_EXT_CERT_NS="${ENVOY_AI_EXT_CERT_NS:-${ENVOY_AI_NAMESPACE}}"
ENVOY_AI_EXT_CERT_NAME="${ENVOY_AI_EXT_CERT_NAME:-ai-gateway-controller-cert}"
ENVOY_AI_GATEWAYCLASS="${ENVOY_AI_GATEWAYCLASS:-envoy-ai-gateway}"  # AI 控制器管理的 GatewayClass 名
# EG 侧(复用 09 模块的 chart/命名空间, 用于 helm upgrade 注入扩展配置)
ENVOY_EG_NAMESPACE="${ENVOY_EG_NAMESPACE:-envoy-gateway-system}"
ENVOY_EG_RELEASE_NAME="${ENVOY_EG_RELEASE_NAME:-eg}"
ENVOY_EG_CHART_DIR="${ENVOY_EG_CHART_DIR:-${REPO_ROOT}/deployments/cubestack-addon/envoy-gateway/eg}"

# ---------------- 前置检查 ----------------
say "检查 Envoy AI Gateway 前置条件..."
# ① 依赖: Envoy Gateway 已装(GatewayClass eg Accepted)
GC_OK="$(SSH "${K} get gatewayclass eg -o jsonpath='{.status.conditions[?(@.type==\"Accepted\")].status}' 2>/dev/null" || true)"
[ "${GC_OK}" = "True" ] \
    || { err "未检测到 Envoy Gateway(GatewayClass eg 未 Accepted); Envoy AI Gateway 依赖 EG, 请先 ENVOY_GATEWAY_ENABLED=true 部署模块 envoy_gateway"; exit 1; }
# ② chart 源
case "${ENVOY_AI_CHART_SOURCE}" in
    dir)  [ -f "${ENVOY_AI_CHART_DIR}/ai-gateway-crds-helm/Chart.yaml" ] && [ -f "${ENVOY_AI_CHART_DIR}/ai-gateway-controller-helm/Chart.yaml" ] \
              || { err "AI chart 目录不完整: ${ENVOY_AI_CHART_DIR}(缺 ai-gateway-crds-helm / ai-gateway-controller-helm; 联网机跑 tools/images/envoy-fetch-charts.sh)"; exit 1; } ;;
    tgz)  [ -f "${ENVOY_AI_CHART_TGZ_CRDS}" ] && [ -f "${ENVOY_AI_CHART_TGZ_CTRL}" ] || { err "AI chart tgz 不存在: ${ENVOY_AI_CHART_TGZ_CRDS} / ${ENVOY_AI_CHART_TGZ_CTRL}"; exit 1; } ;;
    oci)  : ;;   # 需联网
    *)    err "ENVOY_AI_CHART_SOURCE 仅支持 dir/tgz/oci(当前=${ENVOY_AI_CHART_SOURCE})"; exit 1 ;;
esac
command -v helm >/dev/null 2>&1 || { err "未找到 helm(需 3.0+); 请先安装 Helm"; exit 1; }
_ensure_hosts() {   # <ip> <domain>
    local ip="$1" dom="$2" re
    [ -n "${ip}" ] && [ -n "${dom}" ] || return 0
    re="$(echo "${dom}" | sed 's/\./\\./g')"
    sed -i -E "/[[:space:]]${re}([[:space:]]|$)/d" /etc/hosts 2>/dev/null || true
    grep -qE "^${ip}[[:space:]]+${dom}([[:space:]]|$)" /etc/hosts 2>/dev/null \
        || echo "${ip} ${dom}" >> /etc/hosts 2>/dev/null
}
_ensure_hosts "${REGISTRY_IP}" "${REGISTRY_DOMAIN}"
curl -s -m 8 "http://${REGISTRY_BASE}/v2/" >/dev/null 2>&1 \
    || { err "集群内置 registry ${REGISTRY_BASE}/v2/ 不可达"; exit 1; }
SSH "${K} get nodes --no-headers >/dev/null 2>&1" \
    || { err "无法访问集群(${FIRST_MASTER}); 检查 kubectl/集群状态"; exit 1; }
_sync_kubeconfig() {
    local tmp newctx
    tmp="$(mktemp)"
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
        "${SSH_USER:-ubuntu}@${FIRST_MASTER}" "sudo cat /etc/kubernetes/admin.conf" > "${tmp}" 2>/dev/null \
        || { rm -f "${tmp}"; return 1; }
    [ -s "${tmp}" ] || { rm -f "${tmp}"; return 1; }
    mkdir -p "${HOME}/.kube"
    newctx="$(grep -E '^[[:space:]]*current-context:' "${tmp}" | head -1 | awk '{print $2}')"
    if [ -f "${HOME}/.kube/config" ]; then
        KUBECONFIG="${tmp}:${HOME}/.kube/config" kubectl config view --flatten > "${tmp}.merged" 2>/dev/null \
            && mv "${tmp}.merged" "${HOME}/.kube/config" || cp "${tmp}" "${HOME}/.kube/config"
    else
        cp "${tmp}" "${HOME}/.kube/config"
    fi
    [ -n "${newctx}" ] && KUBECONFIG="${HOME}/.kube/config" kubectl config use-context "${newctx}" >/dev/null 2>&1 || true
    chmod 600 "${HOME}/.kube/config"
    rm -f "${tmp}"
    KUBECONFIG="${HOME}/.kube/config" timeout 15 kubectl get nodes --no-headers >/dev/null 2>&1
}
_sync_kubeconfig \
    && ok "宿主机 ~/.kube/config 已同步(admin.conf)" \
    || { err "宿主机无法访问集群(admin.conf 下载/同步失败)"; exit 1; }
ok "前置检查通过(依赖 EG 就绪; chart_source=${ENVOY_AI_CHART_SOURCE}, version=${ENVOY_AI_VERSION})"

# ---------------- 1. 推送 AI 控制器镜像到集群内置 registry(本地源优先) ----------------
say "[1/6] 推送 AI 控制器镜像 → ${PUSH_REGISTRY_AI}/ai-gateway-controller:${ENVOY_AI_IMAGE_TAG} ..."
_push_skopeo() {   # <src> <dst>
    local src="$1" dst="$2" n=1 err
    for n in 1 2 3; do
        if skopeo copy --quiet --src-tls-verify=false --dest-tls-verify=false \
            --dest-no-creds "${src}" "${dst}" 2>/tmp/skopeo-err-aig; then
            rm -f /tmp/skopeo-err-aig; return 0
        fi
        err="$(tail -1 /tmp/skopeo-err-aig 2>/dev/null || true)"
        if [ "${n}" -lt 3 ]; then
            warn "  推送失败(第 ${n}/3 次: ${err}), 3s 后重试整包..."
            sleep 3
        fi
    done
    rm -f /tmp/skopeo-err-aig
    return 1
}
_reg_has_tag() {   # <tag>
    local ver="$1" path="${PUSH_REGISTRY_AI#*/}"
    if command -v skopeo >/dev/null 2>&1; then
        skopeo inspect --tls-verify=false --no-creds "docker://${PUSH_REGISTRY_AI}/ai-gateway-controller:${ver}" >/dev/null 2>&1 && return 0
    fi
    curl -s -m 6 "http://${REGISTRY_BASE}/v2/${path}/ai-gateway-controller/tags/list" 2>/dev/null | grep -q "\"${ver}\""
}
_ALLOW_ONLINE=0
[ "${ENVOY_AI_CHART_SOURCE:-dir}" = "oci" ] && _ALLOW_ONLINE=1
[ "${ENVOY_AI_IMAGE_ONLINE:-false}" = "true" ] && _ALLOW_ONLINE=1
if _reg_has_tag "${ENVOY_AI_IMAGE_TAG}"; then
    ok "  ai-gateway-controller:${ENVOY_AI_IMAGE_TAG} 已在 registry, 跳过"
else
    _SRC=""
    # ① 本地 docker daemon
    _SRC="$(sudo docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E "/ai-gateway-controller:${ENVOY_AI_IMAGE_TAG}$" | head -1 || true)"
    if [ -n "${_SRC}" ]; then
        _tmp="/tmp/aig-ctrl-${ENVOY_AI_IMAGE_TAG}.tar"
        say "  从本地 docker 推送: ${_SRC}"
        if sudo docker save "${_SRC}" -o "${_tmp}" >/dev/null 2>&1 \
           && _push_skopeo "docker-archive:${_tmp}" "docker://${PUSH_REGISTRY_AI}/ai-gateway-controller:${ENVOY_AI_IMAGE_TAG}" >/dev/null 2>&1; then
            rm -f "${_tmp}"; ok "  ai-gateway-controller 已推送(本地 docker)"; _SRC="done"
        else
            rm -f "${_tmp}"; warn "  本地 docker 推送失败, 尝试离线 tar..."
        fi
    fi
    # ② 离线 tar(envoy-save-images.sh 默认 deployments/offline-files/envoy; 兼容集群 images 目录)
    if [ -z "${_SRC}" ]; then
        _TAR=""
        for _td in "${ENVOY_SAVE_DIR}" "${LOCAL_REPO_DIR}/images" \
                   "${OFFLINE_FILES_DIR:-${REPO_ROOT}/deployments/offline-files/kubespray}/${CLUSTER_NAME}/images"; do
            [ -d "${_td}" ] || continue
            for _t in "${_td}"/*ai-gateway-controller*.tar; do
                [ -f "${_t}" ] && { _TAR="${_t}"; break; }
            done
            [ -n "${_TAR}" ] && break
        done
        if [ -n "${_TAR}" ]; then
            say "  从离线 tar 推送: $(basename "${_TAR}")"
            if _push_skopeo "docker-archive:${_TAR}" "docker://${PUSH_REGISTRY_AI}/ai-gateway-controller:${ENVOY_AI_IMAGE_TAG}" >/dev/null 2>&1; then
                ok "  ai-gateway-controller 已推送(离线 tar)"; _SRC="done"
            else
                warn "  tar 推送失败"
            fi
        fi
    fi
    # ③ 在线 skopeo(仅允许在线时)
    if [ -z "${_SRC}" ] && [ "${_ALLOW_ONLINE}" = "1" ]; then
        if _push_skopeo "docker://ghcr.io/envoyproxy/ai-gateway/ai-gateway-controller:${ENVOY_AI_IMAGE_TAG}" \
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
            err "离线安装: 未找到 ai-gateway-controller:${ENVOY_AI_IMAGE_TAG}。请: ① 在联网机跑 tools/images/envoy-save-images.sh 生成 tar 放到 ${ENVOY_SAVE_DIR}/, 或 ② 改 ENVOY_AI_CHART_SOURCE=oci / ENVOY_AI_IMAGE_ONLINE=true 允许在线"
            exit 1
        fi
    fi
fi

# ---------------- 2. helm 安装 AI Gateway CRDs chart ----------------
say "[2/6] helm 安装 AI CRDs(${ENVOY_AI_CRDS_RELEASE} → ${ENVOY_AI_CRDS_NS})..."
_CHART_ARG=""
case "${ENVOY_AI_CHART_SOURCE}" in
    dir) _CHART_ARG="${ENVOY_AI_CHART_DIR}/ai-gateway-crds-helm" ;;
    tgz) _CHART_ARG="${ENVOY_AI_CHART_TGZ_CRDS}" ;;
    oci) _CHART_ARG="${ENVOY_AI_CHART_OCI}/ai-gateway-crds-helm --version ${ENVOY_AI_VERSION#v}" ;;
esac
helm upgrade --install "${ENVOY_AI_CRDS_RELEASE}" ${_CHART_ARG} \
    --namespace "${ENVOY_AI_CRDS_NS}" --create-namespace \
    --wait --timeout 120s \
    || warn "  AI CRDs helm 安装/等待超时(继续检查 CRD 注册)..."
CRD_CNT="$( (SSH "${K} get crd --no-headers 2>/dev/null" || true) | grep -c 'aigateway\.envoyproxy\.io' || true)"
[ "${CRD_CNT:-0}" -ge 1 ] \
    && ok "  AI CRD 已注册(${CRD_CNT} 个 aigateway.envoyproxy.io CRD)" \
    || warn "  未检测到 aigateway.envoyproxy.io CRD(kubectl get crd | grep aigateway)"

# ---------------- 3. helm 安装 AI Gateway 控制器 chart ----------------
say "[3/6] helm 安装 AI 控制器(${ENVOY_AI_CTRL_RELEASE} → ${ENVOY_AI_NAMESPACE})..."
SSH "${K} delete ns ${ENVOY_AI_NAMESPACE} --ignore-not-found --force --grace-period=0 >/dev/null 2>&1" || true
sleep 3
_CHART_ARG=""
case "${ENVOY_AI_CHART_SOURCE}" in
    dir) _CHART_ARG="${ENVOY_AI_CHART_DIR}/ai-gateway-controller-helm" ;;
    tgz) _CHART_ARG="${ENVOY_AI_CHART_TGZ_CTRL}" ;;
    oci) _CHART_ARG="${ENVOY_AI_CHART_OCI}/ai-gateway-controller-helm --version ${ENVOY_AI_VERSION#v}" ;;
esac
helm upgrade --install "${ENVOY_AI_CTRL_RELEASE}" ${_CHART_ARG} \
    --namespace "${ENVOY_AI_NAMESPACE}" --create-namespace \
    --set "image.repository=${ENVOY_AI_IMAGE_REPO}" \
    --set "image.tag=${ENVOY_AI_IMAGE_TAG}" \
    --set "image.pullPolicy=IfNotPresent" \
    --wait --timeout 180s \
    || warn "  AI 控制器 helm 安装/等待超时(资源可能已创建, 继续检查 Deployment)..."
SSH "${K} rollout status deployment -n ${ENVOY_AI_NAMESPACE} ${ENVOY_AI_CTRL_RELEASE} --timeout=120s" >/dev/null 2>&1 \
    || SSH "${K} rollout status deployment -n ${ENVOY_AI_NAMESPACE} ai-gateway-controller --timeout=120s" >/dev/null 2>&1 \
    || warn "  AI 控制器 rollout 未在 120s 内完成(继续检查 pod)..."
sleep 5

# ---------------- 4. 把 AI 扩展注册进 Envoy Gateway(extensionManager) ----------------
say "[4/6] 把 AI Extension Server 注册进 Envoy Gateway(helm upgrade eg --reuse-values)..."
# 生成扩展配置 values 片段(gateway-helm 的 config.envoyGateway 渲染为 EnvoyGateway 运行时配置,
# extensionManager 让 EG 在翻译时咨询 AI 控制器的 Extension Server, 处理 aigateway.envoyproxy.io CRD)
_EXT_VALUES="$(mktemp)"
cat > "${_EXT_VALUES}" <<EOF
config:
  envoyGateway:
    extensionManager:
      resources:
        - group: aigateway.envoyproxy.io
          version: ${ENVOY_AI_API_VERSION}
          kind: AIGateway
          plural: aigateways
      service:
        host: ${ENVOY_AI_EXT_HOST}
        port: ${ENVOY_AI_EXT_PORT}
      hook:
        certificateRef:
          name: ${ENVOY_AI_EXT_CERT_NAME}
          namespace: ${ENVOY_AI_EXT_CERT_NS}
EOF
if helm upgrade "${ENVOY_EG_RELEASE_NAME}" "${ENVOY_EG_CHART_DIR}" \
    --namespace "${ENVOY_EG_NAMESPACE}" --reuse-values -f "${_EXT_VALUES}" \
    --wait --timeout 180s; then
    ok "  Envoy Gateway 扩展注册完成(extensionManager → ${ENVOY_AI_EXT_HOST}:${ENVOY_AI_EXT_PORT})"
else
    warn "  helm upgrade eg 失败(不改动既有安装, 详见下方手工指引); 继续后续检查..."
    echo "  ── 手工注入 EG extensionManager(离线环境替代方案) ──"
    echo "  # 1) 修改 envoy-gateway ConfigMap 的 envoy-gateway.yaml, 在顶层追加:"
    echo "  kubectl -n ${ENVOY_EG_NAMESPACE} edit cm envoy-gateway"
    echo "  # 2) 追加内容(注意缩进):"
    cat > /tmp/envoy-ext-eg-snippet.txt <<EOF
extensionManager:
  resources:
    - group: aigateway.envoyproxy.io
      version: ${ENVOY_AI_API_VERSION}
      kind: AIGateway
      plural: aigateways
  service:
    host: ${ENVOY_AI_EXT_HOST}
    port: ${ENVOY_AI_EXT_PORT}
  hook:
    certificateRef:
      name: ${ENVOY_AI_EXT_CERT_NAME}
      namespace: ${ENVOY_AI_EXT_CERT_NS}
EOF
    sed 's/^/  /' /tmp/envoy-ext-eg-snippet.txt
    echo "  # 3) 重启 EG 控制面加载新配置:"
    echo "  kubectl -n ${ENVOY_EG_NAMESPACE} rollout restart deploy/${ENVOY_EG_RELEASE_NAME}  # 或 deploy/envoy-gateway"
    rm -f /tmp/envoy-ext-eg-snippet.txt
fi
rm -f "${_EXT_VALUES}"
sleep 8   # 等 EG 控制面重启加载新配置

# ---------------- 5. 等待 AI 控制器就绪 + GatewayClass 检查 ----------------
say "[5/6] 等待 AI 控制器就绪..."
SSH "${K} -n ${ENVOY_AI_NAMESPACE} rollout status deployment ${ENVOY_AI_CTRL_RELEASE} --timeout=120s >/dev/null 2>&1" \
    || SSH "${K} -n ${ENVOY_AI_NAMESPACE} rollout status deployment ai-gateway-controller --timeout=120s >/dev/null 2>&1" \
    || warn "  AI 控制器未就绪(检查日志 kubectl -n ${ENVOY_AI_NAMESPACE} logs deploy/ai-gateway-controller)"
sleep 5
# AI 控制器通常自建 GatewayClass(envoy-ai-gateway); 未建则提示
AIGC_OK="$(SSH "${K} get gatewayclass ${ENVOY_AI_GATEWAYCLASS} --no-headers 2>/dev/null" || true)"
[ -n "${AIGC_OK}" ] \
    && ok "  GatewayClass ${ENVOY_AI_GATEWAYCLASS} 已创建" \
    || warn "  未检测到 GatewayClass ${ENVOY_AI_GATEWAYCLASS}(AI 控制器可能尚未自建; AIGateway 创建后确认)"

# ---------------- 6. 汇总 ----------------
PODS="$( (SSH "${K} -n ${ENVOY_AI_NAMESPACE} get pods -o wide 2>/dev/null" || true) )"
echo "    ${PODS}" | sed 's/^/    /'

echo "---------------------------------------------"
ok "Envoy AI Gateway 部署完成"
echo "  namespace:   ${ENVOY_AI_NAMESPACE}(控制器) / ${ENVOY_AI_CRDS_NS}(CRD)"
echo "  chart 来源:  ${ENVOY_AI_CHART_SOURCE}(${ENVOY_AI_VERSION})"
echo "  控制器镜像:  ${ENVOY_AI_IMAGE_REPO}:${ENVOY_AI_IMAGE_TAG}"
echo "  EG 扩展:     extensionManager → ${ENVOY_AI_EXT_HOST}:${ENVOY_AI_EXT_PORT}(EG 命名空间 ${ENVOY_EG_NAMESPACE})"
echo "  GatewayClass: ${ENVOY_AI_GATEWAYCLASS}(AIGateway 引用; AI 控制器管理)"
echo "  资源查看:    kubectl get aigateway,backend,aigatewayroute -A"
echo "  端到端验证:  sudo ./deploy-cluster.sh --steps verify_envoy_ai_gateway"
echo "  使用示例:    docs/envoy-gateway.md §4.2(需配置真实 LLM Backend + API Key Secret)"
echo "  卸载:        helm uninstall ${ENVOY_AI_CTRL_RELEASE} -n ${ENVOY_AI_NAMESPACE}; helm uninstall ${ENVOY_AI_CRDS_RELEASE} -n ${ENVOY_AI_CRDS_NS}; 并移除 EG 的 extensionManager 配置"
