#!/bin/bash
# ============================================================
# MODULE: envoy_ai_gateway
# DESC: 部署 Envoy AI Gateway(LLM/AI 专用网关; 官方 helm chart, 离线; 依赖 Envoy Gateway 数据面)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: ENVOY_AI_GATEWAY_ENABLED
# REQUIRES: envoy_gateway k8s_registry
# 说明:
#   · 断点续跑: REPEAT:0 → 安装成功写入状态, 重跑自动跳过; --fresh 清状态重装。
#   · 定位(v1.1, 官方架构): Envoy AI Gateway = 独立控制器(AI Gateway Controller)+ AI 扩展 CRD +
#     数据面**复用 Envoy Gateway**。v1.x 不再有 v0.x 的 AIGateway/Backend CRD; 控制器通过
#     **EG extension server 机制**(控制器内嵌 gRPC 扩展服务器, 端口 1063)+ **Mutating Webhook +
#     extProc sidecar 注入**, 对标准 Gateway(Gateway API, gatewayClassName=eg)提供 AI 能力:
#       · AI 控制器: 安装 aigateway.envoyproxy.io 扩展 CRD(AIServiceBackend / AIGatewayRoute /
#         GatewayConfig / BackendSecurityPolicy / ...), 运行 EG 扩展服务器 + 注入 extProc sidecar;
#       · EG 接线(本模块 [5/6] 自动完成): EG 自身 config(envoy-gateway-config CM)须声明
#         extensionManager.hooks.xdsTranslator 回调 → AI 控制器扩展服务器(1063), EG 每次 xDS 翻译
#         回调插入 ext_proc/header_to_metadata 过滤器。漏配 → AI 请求 404 "No matching route found"
#         (官方最小配置见 ai-gateway 仓库 manifests/envoy-gateway-values.yaml; 模块 09 **故意不配**:
#         EG 连不上扩展服务器会 xDS 翻译失败, 独立 EG 验证模块 25 会挂, 故须等控制器就绪后本模块补上);
#       · 用法: 用户建标准 Gateway(EG 的 eg 类)+ AIServiceBackend(LLM 上游)
#         + AIGatewayRoute(路由到 /v1/chat/completions 等), 数据面由 EG 托管、AI 控制器注入 extProc。
#   · **依赖 Envoy Gateway 先装**(模块 09, ENVOY_GATEWAY_ENABLED=true), 前置检查会强制确认。
#   · Chart(两个官方 chart, **均托管在 DockerHub OCI**, 版本带 v 如 v1.1.0; 注意 ghcr 同名路径不存在会 403):
#       ai-gateway-crds-helm   = CRD chart(所有 aigateway.envoyproxy.io CRD)
#       ai-gateway-helm        = AI 控制器 chart(controller Deployment/Service/webhook)
#   · 命名空间: 两个 chart **默认都装进 ENVOY_AI_NAMESPACE**(ai-gateway-system)。CRD 为 cluster-scoped,
#     namespace 仅 helm release 归属; 早期版本把 CRD chart 单独装 ai-gateway-crds(无 pod 的空 ns,
#     易被误判为废弃), 已合并并自动清理旧 ns(ENVOY_AI_CRDS_NS=ai-gateway-crds 可恢复拆分)。
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

init_remote_kubectl || exit 1

# ---------------- 派生变量(全部来自 cluster.conf, 无硬编码) ----------------
ENVOY_AI_VERSION="${ENVOY_AI_VERSION:-v1.1.0}"           # chart 版本 + 控制器镜像 tag(带 v, 与官方一致)
ENVOY_AI_CHART_SOURCE="${ENVOY_AI_CHART_SOURCE:-tgz}"    # 默认 tgz(仓库只存 tgz, 部署时临时解压)
ENVOY_AI_CHART_DIR="${ENVOY_AI_CHART_DIR:-${REPO_ROOT}/deployments/cubestack-addon/envoy-gateway/ai}"
ENVOY_AI_CHART_TGZ_CRDS="${ENVOY_AI_CHART_TGZ_CRDS:-${ENVOY_AI_CHART_DIR}/ai-gateway-crds-helm-${ENVOY_AI_VERSION}.tgz}"
ENVOY_AI_CHART_TGZ_CTRL="${ENVOY_AI_CHART_TGZ_CTRL:-${ENVOY_AI_CHART_DIR}/ai-gateway-helm-${ENVOY_AI_VERSION}.tgz}"
ENVOY_AI_CHART_OCI="${ENVOY_AI_CHART_OCI:-oci://docker.io/envoyproxy}"
ENVOY_AI_NAMESPACE="${ENVOY_AI_NAMESPACE:-ai-gateway-system}"       # 控制器命名空间
# CRD chart 命名空间: 默认与控制器**合并**(CRD 为 cluster-scoped, namespace 仅 helm release 归属;
# 早期版本单独 ai-gateway-crds 空 ns 易被误判为废弃, 已统一)。设 ENVOY_AI_CRDS_NS=ai-gateway-crds 可恢复拆分。
ENVOY_AI_CRDS_NS="${ENVOY_AI_CRDS_NS:-${ENVOY_AI_NAMESPACE}}"
ENVOY_AI_CRDS_RELEASE="${ENVOY_AI_CRDS_RELEASE:-ai-gateway-crds}"
ENVOY_AI_CTRL_RELEASE="${ENVOY_AI_CTRL_RELEASE:-ai-gateway-controller}"
# 控制器 Deployment/Service 名: chart 用 controller.fullname=<release>-<chartName>,
# 设 controller.nameOverride=release → 资源名正好 = ai-gateway-controller(与官方 docs
# `kubectl wait deployment/ai-gateway-controller` 一致)。
ENVOY_AI_CTRL_NAME="${ENVOY_AI_CTRL_NAME:-${ENVOY_AI_CTRL_RELEASE}}"
REGISTRY_BASE="${REGISTRY_DOMAIN}:${REGISTRY_PORT}"
ENVOY_AI_IMAGE_REPO="${ENVOY_AI_IMAGE_REPO:-${REGISTRY_BASE}/ai-gateway/ai-gateway-controller}"  # K8s 可见镜像
ENVOY_AI_EXTPROC_IMAGE_REPO="${ENVOY_AI_EXTPROC_IMAGE_REPO:-${REGISTRY_BASE}/ai-gateway/ai-gateway-extproc}"  # extProc sidecar 镜像(K8s 可见; ⚠ 必收必推, 见 [1/5])
ENVOY_AI_IMAGE_TAG="${ENVOY_AI_IMAGE_TAG:-${ENVOY_AI_VERSION}}"
PUSH_REGISTRY_AI="${REGISTRY_DIRECT}/ai-gateway"       # 推送直连端点: metallb→VIP:PORT / nodeport→master:REGISTRY_NODEPORT
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
wait_registry_ready "http://${REGISTRY_DIRECT}/v2/" \
    || { err "集群内置 registry ${REGISTRY_DIRECT}/v2/ 不可达(当前 SERVICE_EXPOSE_MODE=${SERVICE_EXPOSE_MODE})"; exit 1; }
SSH "${K} get nodes --no-headers >/dev/null 2>&1" \
    || { err "无法访问集群(${FIRST_MASTER}); 检查 kubectl/集群状态"; exit 1; }
# 复用 lib-common 的 sync_kubeconfig(server→API_DOMAIN + 宿主机 DNAT)
sync_kubeconfig \
    && ok "宿主机 ~/.kube/config 已同步(admin.conf → API ${API_DOMAIN}→${API_IP})" \
    || { err "宿主机无法访问集群(admin.conf 下载/同步失败)"; exit 1; }
ok "前置检查通过(依赖 EG 就绪; chart_source=${ENVOY_AI_CHART_SOURCE}, version=${ENVOY_AI_VERSION})"

# ---------------- 1. 推送 AI 镜像到集群内置 registry(本地源优先: 控制器 + extProc sidecar) ----------------
say "[1/6] 推送 AI 镜像 → ${PUSH_REGISTRY_AI}(ai-gateway-controller + ai-gateway-extproc, tag=${ENVOY_AI_IMAGE_TAG}) ..."
# ⚠ extProc 是必推项: AI 控制器把数据面 pod 注入 extProc sidecar(镜像由控制器 --extProcImage 参数决定,
#   chart 值 extProc.image.repository/tag)。漏推/漏改 → 数据面 pod 2/3 ImagePullBackOff(离线拉不到
#   docker.io), AI 路由 404 "No matching route found"(见 envoy-save-images.sh 镜像清单)。
# 推送助手复用 lib-common 的 push_image_skopeo(3 次重试)/ reg_has_tag(幂等)/
# find_offline_tar(离线 tar 内容识别, 兼容改名/异常命名)
_ALLOW_ONLINE=0
[ "${ENVOY_AI_CHART_SOURCE:-dir}" = "oci" ] && _ALLOW_ONLINE=1
[ "${ENVOY_AI_IMAGE_ONLINE:-false}" = "true" ] && _ALLOW_ONLINE=1
push_ai_image() {
    local short="$1" tarpatt="$2" _SRC="" _TAR="" _tmp=""
    if reg_has_tag "${PUSH_REGISTRY_AI}" "${short}" "${ENVOY_AI_IMAGE_TAG}"; then
        ok "  ${short}:${ENVOY_AI_IMAGE_TAG} 已在 registry, 跳过"
        return 0
    fi
    # ① 本地 docker daemon
    _SRC="$(sudo docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E "/${short}:${ENVOY_AI_IMAGE_TAG}$" | head -1 || true)"
    if [ -n "${_SRC}" ]; then
        _tmp="/tmp/aig-${short}-${ENVOY_AI_IMAGE_TAG}.tar"
        say "  从本地 docker 推送: ${_SRC}"
        if sudo docker save "${_SRC}" -o "${_tmp}" >/dev/null 2>&1 \
           && push_image_skopeo "docker-archive:${_tmp}" "docker://${PUSH_REGISTRY_AI}/${short}:${ENVOY_AI_IMAGE_TAG}" >/dev/null 2>&1; then
            rm -f "${_tmp}"; ok "  ${short} 已推送(本地 docker)"; return 0
        else
            rm -f "${_tmp}"; warn "  本地 docker 推送失败, 尝试离线 tar..."
        fi
    fi
    # ② 离线 tar(envoy-save-images.sh 默认 deployments/offline-files/envoy; 兼容集群 images 目录;
    #     内容识别: glob 版本无关可能推错, find_offline_tar 按 tar 内容兜底, 兼容改名/异常命名)
    _TAR="$(find_offline_tar "/${short}:${ENVOY_AI_IMAGE_TAG}" "${tarpatt}" \
                "${ENVOY_SAVE_DIR}" \
                "${LOCAL_REPO_DIR}/images" \
                "${OFFLINE_FILES_DIR:-${REPO_ROOT}/deployments/offline-files/kubespray}/${CLUSTER_NAME}/images")" || _TAR=""
    if [ -n "${_TAR}" ]; then
        say "  从离线 tar 推送: $(basename "${_TAR}")"
        if push_image_skopeo "docker-archive:${_TAR}" "docker://${PUSH_REGISTRY_AI}/${short}:${ENVOY_AI_IMAGE_TAG}" >/dev/null 2>&1; then
            ok "  ${short} 已推送(离线 tar)"; return 0
        else
            warn "  tar 推送失败"
        fi
    fi
    # ③ 在线 skopeo(仅允许在线时; 官方源为 docker.io)
    if [ "${_ALLOW_ONLINE}" = "1" ]; then
        if push_image_skopeo "docker://docker.io/envoyproxy/${short}:${ENVOY_AI_IMAGE_TAG}" \
            "docker://${PUSH_REGISTRY_AI}/${short}:${ENVOY_AI_IMAGE_TAG}" >/dev/null 2>&1; then
            ok "  ${short} 已推送(在线)"; return 0
        fi
        warn "  在线推送失败"
    fi
    if [ "${_ALLOW_ONLINE}" = "1" ]; then
        warn "  ${short}:${ENVOY_AI_IMAGE_TAG} 未就绪(本地 docker/tar 无, 在线失败)"
        return 1
    else
        err "离线安装: 未找到 ${short}:${ENVOY_AI_IMAGE_TAG}。请: ① 在联网机跑 tools/images/envoy-save-images.sh 生成 tar 放到 ${ENVOY_SAVE_DIR}/, 或 ② 单独跑 tools/images/envoy-load-images.sh 预加载, 或 ③ 改 ENVOY_AI_CHART_SOURCE=oci / ENVOY_AI_IMAGE_ONLINE=true 允许在线"
        return 1
    fi
}
push_ai_image "ai-gateway-controller" "*ai-gateway-controller*.tar"
push_ai_image "ai-gateway-extproc"    "*ai-gateway-extproc*.tar"

# ---------------- 2. helm 安装 AI CRDs chart ----------------
say "[2/6] helm 安装 AI CRDs(${ENVOY_AI_CRDS_RELEASE} → ${ENVOY_AI_CRDS_NS})..."
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

# 旧版遗留清理(命名空间合并): 早期版本 CRD chart 单独装在 ai-gateway-crds ns(只有 CRD, 无 pod,
# 空 ns 易被误判为废弃)。上面新 ns 的 release 已接管 CRD(helm 所有权 annotation 指向新 release,
# 卸载旧 release 不会连带删除 CRD/用户实例), 这里卸载旧 release 并删除旧 ns。
if [ "${ENVOY_AI_CRDS_NS}" != "ai-gateway-crds" ] && SSH "${K} get ns ai-gateway-crds >/dev/null 2>&1"; then
    say "  检测到旧版独立 ai-gateway-crds 命名空间, 合并清理(卸载旧 CRD release + 删 ns)..."
    helm uninstall "${ENVOY_AI_CRDS_RELEASE}" -n ai-gateway-crds >/dev/null 2>&1 \
        || warn "  旧 release ${ENVOY_AI_CRDS_RELEASE}(ns=ai-gateway-crds) 卸载失败, 继续..."
    SSH "${K} delete ns ai-gateway-crds --ignore-not-found=true --force --grace-period=0 >/dev/null 2>&1" || true
fi

# ---------------- 3. helm 安装 AI 控制器 chart ----------------
say "[3/6] helm 安装 AI 控制器(${ENVOY_AI_CTRL_RELEASE} → ${ENVOY_AI_NAMESPACE})..."
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
    --set "extProc.image.repository=${ENVOY_AI_EXTPROC_IMAGE_REPO}" \
    --set "extProc.image.tag=${ENVOY_AI_IMAGE_TAG}" \
    --wait --timeout 180s \
    || warn "  AI 控制器 helm 安装/等待超时(资源可能已创建, 继续检查 Deployment)..."
SSH "${K} rollout status deployment -n ${ENVOY_AI_NAMESPACE} ${ENVOY_AI_CTRL_NAME} --timeout=120s" >/dev/null 2>&1 \
    || SSH "${K} rollout status deployment -n ${ENVOY_AI_NAMESPACE} ai-gateway-controller --timeout=120s" >/dev/null 2>&1 \
    || warn "  AI 控制器 rollout 未在 120s 内完成(继续检查 pod)..."
sleep 5

# ---------------- 4. 等待 AI 控制器就绪 + 数据面复用确认 ----------------
say "[4/6] 等待 AI 控制器就绪..."
SSH "${K} -n ${ENVOY_AI_NAMESPACE} rollout status deployment ${ENVOY_AI_CTRL_NAME} --timeout=120s >/dev/null 2>&1" \
    || SSH "${K} -n ${ENVOY_AI_NAMESPACE} rollout status deployment ai-gateway-controller --timeout=120s >/dev/null 2>&1" \
    || warn "  AI 控制器未就绪(检查日志 kubectl -n ${ENVOY_AI_NAMESPACE} logs deploy/${ENVOY_AI_CTRL_NAME})"
sleep 5
# v1.x 数据面复用 EG: 用户建标准 Gateway(gatewayClassName=eg), AI 控制器通过 webhook/extProc 提供 AI 能力
GC_EG="$(SSH "${K} get gatewayclass eg --no-headers 2>/dev/null" || true)"
[ -n "${GC_EG}" ] \
    && ok "  GatewayClass eg 可用(AI Gateway 数据面复用 EG)" \
    || warn "  未检测到 GatewayClass eg(请确认模块 09 envoy_gateway 已装)"

# ---------------- 5. 接线: 配置 EG extensionManager → AI 控制器扩展服务器 ----------------
say "[5/6] 配置 Envoy Gateway extensionManager(核心接线: xDS 翻译回调 AI 控制器, 插入 ext_proc 过滤器)..."
# 背景(v1.1 架构, 官方要求): AI 控制器进程内跑 gRPC 扩展服务器(端口 1063, 实现 EG 的
# EnvoyGatewayExtensionServer 接口); EG 须在自身 config(envoy-gateway-config CM)声明
# extensionManager.hooks.xdsTranslator 回调, 才在每次 xDS 翻译时调用 AI 控制器插入
# ext_proc(ENDPOINT_PICKER) 与 header_to_metadata 等过滤器。漏配 → 数据面无 AI 过滤器,
# AI 请求 404 "No matching route found"(历史调试曾误判为 extProc 镜像问题)。
# 官方最小配置见 ai-gateway 仓库 manifests/envoy-gateway-values.yaml(仅 extensionManager 段 +
# enableBackend; TLS 缺省为明文 gRPC, 无需证书)。
# ⚠ 模块 09 **故意不声明** extensionManager(EG 控制面启动即连不上扩展服务器 → 所有 Gateway
#   xDS 翻译失败, 独立 EG 验证模块 25 会挂); 因此必须等 AI 控制器就绪后由本模块补上并重启 EG 控制面。
# 幂等: CM 已含 extensionManager 则跳过(重跑不重复接线)。
_EG_CM="envoy-gateway-config"
_EG_CM_NS="${ENVOY_EG_NAMESPACE}"
# ⚠ chart 内控制面 Deployment 名固定为 envoy-gateway(release 名 eg 只是 helm 记录), 勿用 release 名重启
_EG_DEPLOY="${ENVOY_EG_DEPLOY:-envoy-gateway}"
_EXT_FQDN="${ENVOY_AI_CTRL_NAME}.${ENVOY_AI_NAMESPACE}.svc.cluster.local"
_EXT_PORT=1063
_TMP_CM="$(mktemp)"
if SSH "${K} get cm -n ${_EG_CM_NS} ${_EG_CM} -o yaml" > "${_TMP_CM}" 2>/dev/null && [ -s "${_TMP_CM}" ]; then
    # python: 读 EnvoyGateway 配置, 无 extensionManager 则注入并输出 merge patch JSON
    _PATCH_OUT="$(python3 - "${_TMP_CM}" "${_EXT_FQDN}" "${_EXT_PORT}" <<'PYEOF' 2>/dev/null || true
import json, sys, yaml
cm = yaml.safe_load(open(sys.argv[1]))
eg = yaml.safe_load(cm["data"]["envoy-gateway.yaml"])
if "extensionManager" in eg:
    print("already-present")
    sys.exit(0)
eg["extensionManager"] = {
    "hooks": {"xdsTranslator": {
        "translation": {"listener": {"includeAll": True}, "route": {"includeAll": True},
                        "cluster": {"includeAll": True}, "secret": {"includeAll": True}},
        "post": ["Translation", "Cluster", "Route"]}},
    "service": {"fqdn": {"hostname": sys.argv[2], "port": int(sys.argv[3])}},
}
print(json.dumps({"data": {"envoy-gateway.yaml": yaml.safe_dump(eg, sort_keys=False)}}))
PYEOF
)"
    if [ "${_PATCH_OUT}" = "already-present" ]; then
        ok "  extensionManager 已在 EG 配置中, 跳过"
    elif [ -n "${_PATCH_OUT}" ] && SSH "${K} patch cm ${_EG_CM} -n ${_EG_CM_NS} --type merge -p '${_PATCH_OUT}'" >/dev/null 2>&1; then
        ok "  extensionManager 已写入 ${_EG_CM_NS}/${_EG_CM}(→ ${_EXT_FQDN}:${_EXT_PORT})"
        say "  重启 EG 控制面加载新配置..."
        if SSH "${K} rollout restart deployment -n ${_EG_CM_NS} ${_EG_DEPLOY}" >/dev/null 2>&1 \
           && SSH "${K} rollout status deployment -n ${_EG_CM_NS} ${_EG_DEPLOY} --timeout=120s" >/dev/null 2>&1; then
            ok "  EG 控制面已重启并就绪"
        else
            warn "  EG 控制面重启/就绪超时(检查: kubectl -n ${_EG_CM_NS} get deploy ${_EG_DEPLOY})"
        fi
    else
        warn "  EG 配置注入失败(可手工在 CM ${_EG_CM_NS}/${_EG_CM} 的 data.envoy-gateway.yaml 加 extensionManager 段)"
    fi
else
    warn "  读取 EG 配置 CM ${_EG_CM_NS}/${_EG_CM} 失败(可手工添加 extensionManager 段)"
fi
rm -f "${_TMP_CM}"

# ---------------- 6. 汇总 ----------------
PODS="$( (SSH "${K} -n ${ENVOY_AI_NAMESPACE} get pods -o wide 2>/dev/null" || true) )"
echo "    ${PODS}" | sed 's/^/    /'

echo "---------------------------------------------"
ok "Envoy AI Gateway 部署完成"
if [ "${ENVOY_AI_CRDS_NS}" = "${ENVOY_AI_NAMESPACE}" ]; then
    echo "  namespace:   ${ENVOY_AI_NAMESPACE}(控制器 + CRD release 合并)"
else
    echo "  namespace:   ${ENVOY_AI_NAMESPACE}(控制器) / ${ENVOY_AI_CRDS_NS}(CRD)"
fi
echo "  chart 来源:  ${ENVOY_AI_CHART_SOURCE}(${ENVOY_AI_VERSION})"
echo "  控制器镜像:  ${ENVOY_AI_IMAGE_REPO}:${ENVOY_AI_IMAGE_TAG}"
echo "  extProc 镜像: ${ENVOY_AI_EXTPROC_IMAGE_REPO}:${ENVOY_AI_IMAGE_TAG}"
echo "  数据面:      复用 Envoy Gateway(${ENVOY_EG_NAMESPACE} 的 eg GatewayClass; AI 控制器注入 extProc sidecar)"
echo "  EG 接线:     extensionManager → ${ENVOY_AI_CTRL_NAME}.${ENVOY_AI_NAMESPACE}.svc.cluster.local:1063(已写入 envoy-gateway-config)"
echo "  AI CRD:      aigateway.envoyproxy.io(AIServiceBackend / AIGatewayRoute / GatewayConfig / ...)"
echo "  资源查看:    kubectl get aiservicebackend,aigatewayroute -A"
echo "  端到端验证:  sudo ./deploy-cluster.sh --steps verify_envoy_ai_gateway"
echo "  使用示例:    docs/envoy-gateway.md §4.2(标准 Gateway + AIServiceBackend + AIGatewayRoute + API Key Secret)"
echo "  卸载:        helm uninstall ${ENVOY_AI_CTRL_RELEASE} -n ${ENVOY_AI_NAMESPACE}; helm uninstall ${ENVOY_AI_CRDS_RELEASE} -n ${ENVOY_AI_CRDS_NS}"
