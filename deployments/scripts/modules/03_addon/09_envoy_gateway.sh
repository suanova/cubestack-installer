#!/bin/bash
# ============================================================
# MODULE: envoy_gateway
# DESC: 部署 Envoy Gateway(通用 K8s API 网关; Gateway API 标准实现; 离线 helm + 集群内置 registry 镜像)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: ENVOY_GATEWAY_ENABLED
# 说明:
#   · 断点续跑: REPEAT:0 → 安装成功写入状态, 重跑自动跳过; --fresh 清状态重装。
#   · 定位: Envoy Gateway = 通用 K8s API 网关基座; Envoy AI Gateway(模块 10_envoy_ai_gateway.sh)
#     基于它构建。本模块只装 EG 基座(GatewayClass/Gateway/HTTPRoute 通用能力)。
#   · Chart 来源(三选一, ENVOY_EG_CHART_SOURCE 控制; **本地源优先, 默认离线安装**):
#       dir  = 本地解包目录(ENVOY_EG_CHART_DIR = deployments/cubestack-addon/envoy-gateway/eg)
#       tgz  = 本地 chart 压缩包(**默认**, ENVOY_EG_CHART_TGZ; 仓库只存 tgz 不膨胀,
#              部署时临时解压到 mktemp 目录再 helm 安装)
#       oci  = 官方 OCI registry(ENVOY_EG_CHART_OCI, 需联网)
#   · 离线优先: 本地源(dir/tgz)时, 镜像强制走本地 docker/离线 tar(不联网); 仅 oci 源或
#     ENVOY_EG_IMAGE_ONLINE=true 才允许在线拉取。离线 tar 由 tools/images/envoy-save-images.sh
#     生成, 默认放 ${REPO_ROOT}/deployments/offline-files/envoy。
#   · 镜像流向(与 gpu_operator/lws 一致): 把 envoyproxy/gateway(控制面)与 envoyproxy/envoy(数据面)
#     镜像推送到集群内置 registry; helm 安装时 --set deployment.envoyGateway.image.*(控制面/certgen)与
#     global.images.envoyProxy.image(数据面)改写为内置 registry 路径, K8s 节点从集群内置 registry 按域名拉取。
#   · 数据面镜像改写是关键: 用户创建 Gateway 后控制器动态创建的 Envoy Proxy Deployment
#     必须能用内置 registry 镜像(默认 docker.io 在离线集群不可达)。
#   · ⚠ 默认启用 extensionApis.enableBackend(EG Backend API): AI Gateway v1.1+ 的 AIServiceBackend
#     必须引用 EG Backend 资源; 该 API 默认禁用(安全原因), 离线内网集群启用无额外风险。
#   · 默认 GatewayClass: eg(gateway.envoyproxy.io/gatewayclass-controller), 安装后自动创建。
#   · nodeport 暴露模式(SERVICE_EXPOSE_MODE=nodeport, 无 MetalLB): 数据面 Service 默认仍创建为
#     LoadBalancer, 需转 NodePort 才可访问 —— 创建 Gateway 时加注解 gateway.envoyproxy.io/service-type: NodePort,
#     或对已创建 Gateway 运行 tools/lb/gateway-nodeport.sh 转换; 详见 docs/envoy-gateway.md。
#   · 参考: https://gateway.envoyproxy.io/ 与 docs/envoy-gateway.md
# 数据源: cluster.conf (ENVOY_GATEWAY_ENABLED / ENVOY_EG_CHART_SOURCE / ENVOY_EG_CHART_DIR / ENVOY_EG_CHART_TGZ /
#                       ENVOY_EG_CHART_OCI / ENVOY_EG_VERSION / ENVOY_EG_IMAGE_* / ENVOY_SAVE_DIR / REGISTRY_* / NODES)
# 用法:   sudo ./deploy-cluster.sh --enable envoy_gateway  或  ENVOY_GATEWAY_ENABLED=true
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# ---- 开关 ----
[ "${ENVOY_GATEWAY_ENABLED:-false}" = "true" ] || { say "ENVOY_GATEWAY_ENABLED=false, 跳过 Envoy Gateway"; exit 0; }

FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
SSH() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
           "${SSH_USER:-ubuntu}@${FIRST_MASTER}" "$@"; }
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

# ---------------- 派生变量(全部来自 cluster.conf, 无硬编码) ----------------
ENVOY_EG_VERSION="${ENVOY_EG_VERSION:-v1.9.1}"       # EG 版本(控制面 gateway 镜像 tag)
# ⚠ 数据面 Envoy tag 与 EG 版本不同(EG 1.9.x 配套 Envoy 1.39.x, 见控制面 ENVOY_PROXY_VERSION);
#   误用 <EG版本> 会拉到远古 Envoy(如 v1.9.1), 数据面启动报 --cpuset-threads 无法识别而 CrashLoop
ENVOY_PROXY_VERSION="${ENVOY_PROXY_VERSION:-distroless-v1.39.1}"   # 数据面 Envoy 镜像 tag
ENVOY_EG_CHART_SOURCE="${ENVOY_EG_CHART_SOURCE:-tgz}"   # 默认 tgz(仓库只存 tgz, 部署时临时解压)
ENVOY_EG_CHART_DIR="${ENVOY_EG_CHART_DIR:-${REPO_ROOT}/deployments/cubestack-addon/envoy-gateway/eg}"
ENVOY_EG_CHART_TGZ="${ENVOY_EG_CHART_TGZ:-${REPO_ROOT}/deployments/cubestack-addon/envoy-gateway/eg/gateway-helm-${ENVOY_EG_VERSION}.tgz}"
ENVOY_EG_CHART_OCI="${ENVOY_EG_CHART_OCI:-oci://docker.io/envoyproxy/gateway-helm}"
ENVOY_EG_NAMESPACE="${ENVOY_EG_NAMESPACE:-envoy-gateway-system}"
ENVOY_EG_RELEASE_NAME="${ENVOY_EG_RELEASE_NAME:-eg}"
# 镜像: 内置 registry 路径(helm --set 用域名, K8s 节点按域名拉取)
REGISTRY_BASE="${REGISTRY_DOMAIN}:${REGISTRY_PORT}"
ENVOY_EG_IMAGE_BASE="${ENVOY_EG_IMAGE_BASE:-${REGISTRY_BASE}/envoyproxy}"
# 推送用直连 IP(与 gpu_operator/lws 一致): PUSH_REGISTRY=${REGISTRY_IP}:${REGISTRY_PORT}
PUSH_REGISTRY="${REGISTRY_IP}:${REGISTRY_PORT}/envoyproxy"
ENVOY_SAVE_DIR="${ENVOY_SAVE_DIR:-${REPO_ROOT}/deployments/offline-files/envoy}"
ENVOY_EG_IMAGE_ONLINE="${ENVOY_EG_IMAGE_ONLINE:-false}"   # 允许在线拉取镜像(仅 oci 源或显式 true)

# tgz 源临时解压目录(部署时 mktemp, 退出自动清理)
_TMP_CHART=""
trap 'rm -rf "${_TMP_CHART:-}"' EXIT

# ---------------- 前置检查 ----------------
say "检查 Envoy Gateway 前置条件..."
# chart 来源: 默认 tgz(本地离线, 部署时临时解压)。dir 缺 Chart.yaml 时自动回退同版本 tgz(两源均本地, 安全);
# 两者都缺失则给完整指引(离线 chart tgz 需在联网机用 envoy-fetch-charts.sh 下载后拷到部署机)。
case "${ENVOY_EG_CHART_SOURCE}" in
    dir)
        if [ ! -f "${ENVOY_EG_CHART_DIR}/Chart.yaml" ] && [ -f "${ENVOY_EG_CHART_TGZ}" ]; then
            say "EG chart 目录缺失, 检测到同版本 tgz, 自动改用 tgz 源: ${ENVOY_EG_CHART_TGZ}"
            ENVOY_EG_CHART_SOURCE="tgz"
        fi
        ;;
    tgz|oci) : ;;   # tgz 缺失在下方按源校验; oci 需联网由 helm 拉取
    *)  err "ENVOY_EG_CHART_SOURCE 仅支持 dir/tgz/oci(当前=${ENVOY_EG_CHART_SOURCE})"; exit 1 ;;
esac
if [ "${ENVOY_EG_CHART_SOURCE}" = "dir" ]; then
    if [ ! -f "${ENVOY_EG_CHART_DIR}/Chart.yaml" ]; then
        err "EG chart 目录不存在/缺 Chart.yaml: ${ENVOY_EG_CHART_DIR}"
        err "请先准备离线 chart(三选一):"
        err "  ① 在联网机跑 tools/images/envoy-fetch-charts.sh 下载 tgz 到 ${ENVOY_EG_CHART_DIR}/ 后拷到部署机;"
        err "  ② 放 chart 压缩包到 ${ENVOY_EG_CHART_TGZ}, 设 ENVOY_EG_CHART_SOURCE=tgz;"
        err "  ③ 部署机有外网则设 ENVOY_EG_CHART_SOURCE=oci 在线安装(ENVOY_EG_CHART_OCI=${ENVOY_EG_CHART_OCI})"
        exit 1
    fi
elif [ "${ENVOY_EG_CHART_SOURCE}" = "tgz" ]; then
    if [ ! -f "${ENVOY_EG_CHART_TGZ}" ]; then
        err "EG chart tgz 不存在: ${ENVOY_EG_CHART_TGZ}"
        err "请: ① 在联网机跑 tools/images/envoy-fetch-charts.sh(生成 tgz) 或放 tgz 到上述路径; ② 或设 ENVOY_EG_CHART_SOURCE=dir(解包目录)/oci(在线)"
        exit 1
    fi
fi
command -v helm >/dev/null 2>&1 || { err "未找到 helm(需 3.0+); 请先安装 Helm"; exit 1; }
skopeo_require "envoy_gateway"   # 推送镜像到集群内置 registry 必需(缺失时给明确指引, 而非误报未找到镜像)
# 宿主机 /etc/hosts 更新(registry 域名 → VIP), 与 gpu_operator 一致
# 复用 lib-common 的 ensure_hosts_entry(先删旧行再写当前 IP, 无 grep 守卫 → 多集群不残留旧 IP)
ensure_hosts_entry "${REGISTRY_IP}" "${REGISTRY_DOMAIN}"
wait_registry_ready "http://${REGISTRY_BASE}/v2/" \
    || { err "集群内置 registry ${REGISTRY_BASE}/v2/ 不可达(检查: 宿主机 /etc/hosts 的 ${REGISTRY_DOMAIN} 是否解析到 ${REGISTRY_IP}, 及 MetalLB VIP)"; exit 1; }
SSH "${K} get nodes --no-headers >/dev/null 2>&1" \
    || { err "无法访问集群(${FIRST_MASTER}); 检查 kubectl/集群状态"; exit 1; }
# helm 需要从宿主连 API Server: 复用 lib-common 的 sync_kubeconfig(server→API_DOMAIN + 宿主机 DNAT)
sync_kubeconfig \
    && ok "宿主机 ~/.kube/config 已同步(admin.conf → API ${API_DOMAIN}→${API_IP})" \
    || { err "宿主机无法访问集群(admin.conf 下载/同步失败; 检查 ${FIRST_MASTER} 的 /etc/kubernetes/admin.conf)"; exit 1; }
ok "前置检查通过(chart_source=${ENVOY_EG_CHART_SOURCE}, version=${ENVOY_EG_VERSION})"

# ---------------- 1. 推送 EG 镜像到集群内置 registry(本地源优先, 离线安装) ----------------
# 离线优先策略(与 lws 一致):
#   · dir/tgz(本地源, 默认) → 镜像强制走本地 docker daemon / 离线 tar, 绝不尝试联网
#   · oci 源或 ENVOY_EG_IMAGE_ONLINE=true → 才允许在线 skopeo 拉取官方镜像
say "[1/4] 推送 EG 镜像 → ${PUSH_REGISTRY}(控制面 gateway + 数据面 envoy, tag=${ENVOY_EG_VERSION}) ..."
# 推送助手复用 lib-common 的 push_image_skopeo(3 次重试)/ reg_has_tag(幂等)/
# find_offline_tar(离线 tar 内容识别, 兼容改名/异常命名)
_ALLOW_ONLINE=0
[ "${ENVOY_EG_CHART_SOURCE:-dir}" = "oci" ] && _ALLOW_ONLINE=1
[ "${ENVOY_EG_IMAGE_ONLINE:-false}" = "true" ] && _ALLOW_ONLINE=1
# push_one <镜像短名 gateway|envoy> <tar匹配模式> <tag>
#   注意: 控制面 tag=ENVOY_EG_VERSION, 数据面 tag=ENVOY_PROXY_VERSION(两者不同!)
push_one() {
    local short="$1" tarpatt="$2" tag="${3:-${ENVOY_EG_VERSION}}" src="" _tar
    if reg_has_tag "${PUSH_REGISTRY}" "${short}" "${tag}"; then
        ok "  ${short}:${tag} 已在 registry, 跳过"
        return 0
    fi
    # ① 本地 docker daemon(任意前缀, 匹配 /gateway:<tag> 或 /envoy:<tag>)
    src="$(sudo docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E "/${short}:${tag}$" | head -1 || true)"
    if [ -n "${src}" ]; then
        _tmp="/tmp/eg-${short}-${tag}.tar"
        say "  从本地 docker 推送: ${src}"
        if sudo docker save "${src}" -o "${_tmp}" >/dev/null 2>&1 \
           && push_image_skopeo "docker-archive:${_tmp}" "docker://${PUSH_REGISTRY}/${short}:${tag}" >/dev/null 2>&1; then
            rm -f "${_tmp}"
            ok "  ${short} 已推送(本地 docker)"; return 0
        else
            rm -f "${_tmp}"
            warn "  本地 docker 推送失败, 尝试离线 tar..."
        fi
    fi
    # ② 离线 tar(envoy-save-images.sh 默认 deployments/offline-files/envoy; 兼容集群 images 目录;
    #     内容识别: 文件名 glob 快路径 + 全部 tar 按内容兜底, 兼容改名/异常命名)
    _tar="$(find_offline_tar "/${short}:${tag}" "${tarpatt}" \
                "${ENVOY_SAVE_DIR}" \
                "${LOCAL_REPO_DIR}/images" \
                "${OFFLINE_FILES_DIR:-${REPO_ROOT}/deployments/offline-files/kubespray}/${CLUSTER_NAME}/images")" || _tar=""
    if [ -n "${_tar}" ]; then
        say "  从离线 tar 推送: $(basename "${_tar}")"
        if push_image_skopeo "docker-archive:${_tar}" "docker://${PUSH_REGISTRY}/${short}:${tag}" >/dev/null 2>&1; then
            ok "  ${short} 已推送(离线 tar)"; return 0
        else
            warn "  tar 推送失败: $(basename "${_tar}")"
        fi
    fi
    # ③ 在线 skopeo(仅允许在线时)
    if [ "${_ALLOW_ONLINE}" = "1" ]; then
        if push_image_skopeo "docker://docker.io/envoyproxy/${short}:${tag}" \
            "docker://${PUSH_REGISTRY}/${short}:${tag}" >/dev/null 2>&1; then
            ok "  ${short} 已推送(在线)"; return 0
        fi
        warn "  在线推送失败"
    fi
    # 离线安装: 本地源且镜像未就绪 → 报错给指引(不静默继续)
    if [ "${_ALLOW_ONLINE}" = "1" ]; then
        warn "  envoyproxy/${short}:${tag} 未就绪(本地 docker/tar 无, 在线失败)"
        return 1
    else
        err "离线安装: 未找到 envoyproxy/${short}:${tag}(本地 docker 无 + 离线 tar 无)。请: ① 在联网机跑 tools/images/envoy-save-images.sh 生成 tar 放到 ${ENVOY_SAVE_DIR}/, 或 ② 放离线 tar 到 ${LOCAL_REPO_DIR}/images/, 或 ③ 单独跑 tools/images/envoy-load-images.sh 预加载, 或 ④ 改 ENVOY_EG_CHART_SOURCE=oci 允许在线"
        return 1
    fi
}
# 控制面(tag=EG 版本)+ 数据面(tag=ENVOY_PROXY_VERSION, 与 EG 版本不同!)
push_one "gateway" "*gateway_${ENVOY_EG_VERSION}.tar" "${ENVOY_EG_VERSION}"
push_one "envoy"   "*envoy_${ENVOY_PROXY_VERSION}.tar" "${ENVOY_PROXY_VERSION}"

# ---------------- 2. helm 安装 gateway-helm(三种 chart 源) ----------------
say "[2/4] helm 安装 ${ENVOY_EG_RELEASE_NAME} → ${ENVOY_EG_NAMESPACE}(chart=${ENVOY_EG_CHART_SOURCE}, version=${ENVOY_EG_VERSION}) ..."
# 清理上次残留(避免 helm 无法接管)
SSH "${K} delete ns ${ENVOY_EG_NAMESPACE} --ignore-not-found --force --grace-period=0 >/dev/null 2>&1" || true
sleep 3

_CHART_ARG=""
case "${ENVOY_EG_CHART_SOURCE}" in
    dir) _CHART_ARG="${ENVOY_EG_CHART_DIR}" ;;
    tgz)   # 部署时临时解压 tgz 到 mktemp 目录再安装(仓库只存 tgz, 不膨胀)
        _TMP_CHART="$(mktemp -d)"
        tar -xzf "${ENVOY_EG_CHART_TGZ}" -C "${_TMP_CHART}" || { err "解压 chart tgz 失败: ${ENVOY_EG_CHART_TGZ}"; exit 1; }
        _CHART_ARG="${_TMP_CHART}/gateway-helm"
        [ -f "${_CHART_ARG}/Chart.yaml" ] || { err "解压结果缺 Chart.yaml(内部目录名异常): ${_TMP_CHART}"; exit 1; }
        ;;
    oci) _CHART_ARG="${ENVOY_EG_CHART_OCI}"; _CHART_ARG+=" --version ${ENVOY_EG_VERSION#v}" ;;
esac

# gateway-helm v1.9.1 的镜像值路径(与 v0.x 不同, 详见 chart _helpers.tpl 的 eg.image):
#   · 控制面 Deployment + certgen Job 都经 eg.image helper → deployment.envoyGateway.image.repository/tag
#   · 数据面 EnvoyProxy(创建 Gateway 时动态拉起)→ global.images.envoyProxy.image(完整镜像串)
# 错误示例(曾用, 无效果): image.repository / envoyGateway.image.repository(顶层不存在, 落默认 docker.io)
# ⚠ extensionApis.enableBackend=true: EG Backend API 默认禁用(安全原因, 参考 CVE-2021-25740),
#   但 Envoy AI Gateway(v1.1+)的 AIServiceBackend 必须引用 EG Backend 资源; 不启用则 HTTPRoute 报
#   "Backend is disabled in Envoy Gateway configuration" (ResolvedRefs=False), AI 路由 500。
helm upgrade --install "${ENVOY_EG_RELEASE_NAME}" ${_CHART_ARG} \
    --namespace "${ENVOY_EG_NAMESPACE}" --create-namespace \
    --set "deployment.envoyGateway.image.repository=${ENVOY_EG_IMAGE_BASE}/gateway" \
    --set "deployment.envoyGateway.image.tag=${ENVOY_EG_VERSION}" \
    --set "deployment.envoyGateway.imagePullPolicy=IfNotPresent" \
    --set "global.images.envoyProxy.image=${ENVOY_EG_IMAGE_BASE}/envoy:${ENVOY_PROXY_VERSION}" \
    --set "global.images.envoyProxy.pullPolicy=IfNotPresent" \
    --set "config.envoyGateway.extensionApis.enableBackend=true" \
    --wait --timeout 180s \
    || warn "  helm 安装/等待超时(检查 --set 与 chart; 资源可能已创建, 继续等待 Deployment)..."

# ---------------- 3. 创建默认 GatewayClass(eg) ----------------
say "[3/4] 创建默认 GatewayClass(eg)..."
# 控制器名: gateway.envoyproxy.io/gatewayclass-controller(与 chart config 一致)
SSH "${K} apply -f - <<'YAML'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
YAML
" || warn "  GatewayClass eg 创建失败(可稍后手工 kubectl apply)"

# ---------------- 4. 等待就绪 + 验证 ----------------
say "[4/4] 等待 Envoy Gateway 控制面就绪(最长 180s)..."
SSH "${K} rollout status deployment -n ${ENVOY_EG_NAMESPACE} ${ENVOY_EG_RELEASE_NAME} --timeout=120s" >/dev/null 2>&1 \
    || SSH "${K} rollout status deployment -n ${ENVOY_EG_NAMESPACE} envoy-gateway --timeout=120s" >/dev/null 2>&1 \
    || warn "  控制面 rollout 未在 120s 内完成(继续检查 pod)..."
sleep 5

# 检查 GatewayClass 是否 Accepted
GC_OK="$(SSH "${K} get gatewayclass eg -o jsonpath='{.status.conditions[?(@.type==\"Accepted\")].status}' 2>/dev/null" || true)"
[ "${GC_OK}" = "True" ] \
    && ok "GatewayClass eg 已 Accepted" \
    || warn "GatewayClass eg 未 Accepted(当前='${GC_OK}'); 检查控制面日志: kubectl -n ${ENVOY_EG_NAMESPACE} logs deploy/${ENVOY_EG_RELEASE_NAME}"

PODS="$( (SSH "${K} -n ${ENVOY_EG_NAMESPACE} get pods -o wide 2>/dev/null" || true) )"
echo "    ${PODS}" | sed 's/^/    /'

echo "---------------------------------------------"
ok "Envoy Gateway 部署完成"
echo "  namespace:   ${ENVOY_EG_NAMESPACE}"
echo "  chart 来源:  ${ENVOY_EG_CHART_SOURCE}(${ENVOY_EG_VERSION})"
echo "  控制面镜像:  ${ENVOY_EG_IMAGE_BASE}/gateway:${ENVOY_EG_VERSION}"
echo "  数据面镜像:  ${ENVOY_EG_IMAGE_BASE}/envoy:${ENVOY_EG_VERSION}(Gateway 创建后动态拉起)"
echo "  GatewayClass: eg(已 Accepted)"
echo "  资源查看:    kubectl get gatewayclass,gateway,httproute -A"
echo "  端到端验证:  sudo ./deploy-cluster.sh --steps verify_envoy_gateway"
echo "  AI 扩展:     Envoy AI Gateway 见 --enable envoy_ai_gateway(docs/envoy-gateway.md)"
echo "  卸载:        helm uninstall ${ENVOY_EG_RELEASE_NAME} -n ${ENVOY_EG_NAMESPACE}; kubectl delete gatewayclass eg"
