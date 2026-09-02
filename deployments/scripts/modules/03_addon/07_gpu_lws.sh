#!/bin/bash
# ============================================================
# MODULE: gpu_lws
# DESC: 部署 LeaderWorkerSet(LWS)(默认官方 manifests.yaml bundle; 可选 helm chart 支持 cert-manager + DisaggregatedSet)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: LWS_ENABLED
# 说明:
#   · 断点续跑: REPEAT:0 → 安装成功写入状态, 重跑自动跳过; --fresh 清状态重装。
#   · 双安装方式(LWS_INSTALL_MODE, 默认 bundle; 设 LWS_CERT_MODE=cert-manager 自动切 helm):
#       bundle(推荐, 默认)= 官方 manifests.yaml 单文件(lws/manifests.yaml), kubectl apply --server-side 整体下发
#         (含 namespace + CRD + RBAC + controller + webhook; 逐资源应用, 不受 helm release Secret 1MiB 上限; 证书=internal 自签)。
#       helm = 本地 chart(lws/charts/, 官方 v0.10.0), 支持 cert-manager 模式 / 自定义 values。
#         官方 v0.10.0 的 CRD schema 超大 → crds/ 已在 charts/.helmignore 排除(helm 只装模板), CRD 由 kubectl 逐文件 apply。
#   · Chart 来源(仅 helm 方式, LWS_CHART_SOURCE 控制; 本地源优先, 默认离线安装):
#       dir  = 本地解包目录(默认 LWS_CHART_DIR = deployments/cubestack-addon/lws/charts)
#       tgz  = 本地 chart 压缩包(LWS_CHART_TGZ = deployments/cubestack-addon/lws/charts/lws-chart-v0.10.0.tgz)
#       oci  = 官方 OCI registry(LWS_CHART_OCI = oci://registry.k8s.io/lws/charts/lws, 需联网; 版本 LWS_CHART_VERSION)
#     oci 用法对应官方: helm install lws oci://registry.k8s.io/lws/charts/lws --version=<CHART_VERSION> ...
#   · 离线优先: 本地源(dir/tgz)时, 镜像强制走本地 docker/离线 tar(不联网); 仅 oci 源或
#     LWS_IMAGE_ONLINE=true 才允许在线拉取官方镜像。离线 tar 由
#     tools/images/lws-save-images.sh 生成, 默认放 ${REPO_ROOT}/deployments/offline-files/lws
#     (也兼容 ${LOCAL_REPO_DIR}/images 集群镜像目录)。
#   · 镜像流向(与 gpu_operator 一致): 默认把 lws/manager 镜像文件推送到集群内置 registry
#     (PUSH_REGISTRY = ${REGISTRY_IP}:${REGISTRY_PORT}/lws/manager, 源: 本地 docker daemon / 离线 tar);
#     bundle 方式由脚本 sed 把镜像改为 LWS_IMAGE_REPO, helm 方式 --set image.manager.repository
#     (均为 ${REGISTRY_DOMAIN}:${REGISTRY_PORT}/lws/manager), K8s 节点从集群内置 registry 按域名拉取。
#   · 证书管理模式(LWS_CERT_MODE): internal(默认; bundle 固定为控制器自签) / cert-manager(仅 helm 方式,
#     需集群已装 cert-manager; 设 cert-manager 时自动 LWS_INSTALL_MODE=helm)。
#   · DisaggregatedSet: bundle 已含; helm 方式由 enableDisaggregatedSet values 控制(LWS_DISAGGREGATEDSET_ENABLED, 默认 true)
#   · 离线镜像: lws/manager:v<LWS_IMAGE_TAG> 推送至集群内置 registry; 或由 PRELOAD_IMAGE_PATTERNS 预加载。
#   · 参考: https://lws.sigs.k8s.io/docs/installation/ 与 docs/lws.md
# 数据源: cluster.conf (LWS_ENABLED / LWS_INSTALL_MODE / LWS_MANIFEST / LWS_CHART_SOURCE / LWS_CHART_DIR / LWS_CHART_TGZ /
#                       LWS_CHART_OCI / LWS_CHART_VERSION / LWS_CERT_MODE / LWS_IMAGE_* / REGISTRY_* / NODES)
# 用法:   sudo ./deploy-cluster.sh --steps gpu_lws  或  LWS_ENABLED=true
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# ---- 开关 ----
[ "${LWS_ENABLED:-false}" = "true" ] || { say "LWS_ENABLED=false, 跳过 LeaderWorkerSet"; exit 0; }

FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
SSH() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
           "${SSH_USER:-ubuntu}@${FIRST_MASTER}" "$@"; }
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

# ---------------- 派生变量(全部来自 cluster.conf, 无硬编码) ----------------
# 双安装方式(LWS_INSTALL_MODE):
#   bundle(默认, 推荐)= 官方 manifests.yaml 单文件, kubectl apply --server-side 整体下发
#     (逐资源应用, 不受 helm release Secret 1MiB 上限; 含 namespace/CRD/RBAC/controller/webhook)
#   helm = 本地 chart(LWS_CHART_DIR, 默认 deployments/cubestack-addon/lws/charts; 未来 cert-manager 模式用)
LWS_INSTALL_MODE="${LWS_INSTALL_MODE:-bundle}"                 # bundle(默认)| helm
LWS_MANIFEST="${LWS_MANIFEST:-${REPO_ROOT}/deployments/cubestack-addon/lws/manifests.yaml}"   # 官方 bundle(离线 vendoring)
LWS_CHART_DIR="${LWS_CHART_DIR:-${REPO_ROOT}/deployments/cubestack-addon/lws/charts}"
LWS_CHART_TGZ="${LWS_CHART_TGZ:-${LWS_CHART_DIR}/lws-chart-v0.10.0.tgz}"
LWS_CHART_OCI="${LWS_CHART_OCI:-oci://registry.k8s.io/lws/charts/lws}"
LWS_CHART_VERSION="${LWS_CHART_VERSION:-v0.10.0}"       # 对应官方 CHART_VERSION
LWS_NAMESPACE="${LWS_NAMESPACE:-lws-system}"
LWS_RELEASE_NAME="${LWS_RELEASE_NAME:-lws}"
LWS_CERT_MODE="${LWS_CERT_MODE:-internal}"              # 默认 internal(离线友好, 官方 enableCertManager=false)
LWS_IMAGE_REPO="${LWS_IMAGE_REPO:-${REGISTRY_DOMAIN}:${REGISTRY_PORT}/lws/manager}"
LWS_IMAGE_TAG="${LWS_IMAGE_TAG:-v0.10.0}"               # 对应官方 image.manager.tag
LWS_DISAGGREGATEDSET_ENABLED="${LWS_DISAGGREGATEDSET_ENABLED:-true}"
REGISTRY_BASE="${REGISTRY_DOMAIN}:${REGISTRY_PORT}"
PUSH_REGISTRY="${REGISTRY_DIRECT}/lws"   # REGISTRY_DIRECT: metallb→VIP:PORT / nodeport→master:REGISTRY_NODEPORT

# ---------------- 前置检查 ----------------
say "检查 LeaderWorkerSet 前置条件..."
# 安装方式: 默认 bundle(官方 manifests.yaml); LWS_CERT_MODE=cert-manager 或显式 LWS_INSTALL_MODE=helm → 用 helm chart
[ "${LWS_CERT_MODE:-internal}" = "cert-manager" ] && LWS_INSTALL_MODE="helm"
case "${LWS_INSTALL_MODE}" in
    bundle|helm) ;;
    *) err "LWS_INSTALL_MODE 仅支持 bundle(默认)|helm(当前=${LWS_INSTALL_MODE})"; exit 1 ;;
esac
if [ "${LWS_INSTALL_MODE}" = "bundle" ]; then
    # 官方 manifests.yaml(离线 vendoring, 含 namespace+CRD+RBAC+controller+webhook; 控制器自签证书=internal)
    [ -f "${LWS_MANIFEST}" ] || { err "未找到官方 bundle: ${LWS_MANIFEST}(默认安装方式)。可设 LWS_INSTALL_MODE=helm 用本地 chart 安装"; exit 1; }
else
    LWS_CHART_SOURCE="${LWS_CHART_SOURCE:-dir}"
    case "${LWS_CHART_SOURCE}" in
        dir)  [ -f "${LWS_CHART_DIR}/Chart.yaml" ] || { err "LWS chart 目录不存在/缺 Chart.yaml: ${LWS_CHART_DIR}"; exit 1; } ;;
        tgz)  [ -f "${LWS_CHART_TGZ}" ] || { err "LWS chart tgz 不存在: ${LWS_CHART_TGZ}"; exit 1; } ;;
        oci)  : ;;   # OCI 需联网, 由 helm 拉取
        *)    err "LWS_CHART_SOURCE 仅支持 dir/tgz/oci(当前=${LWS_CHART_SOURCE})"; exit 1 ;;
    esac
    command -v helm >/dev/null 2>&1 || { err "未找到 helm(需 3.0+); 请先安装 Helm"; exit 1; }
fi
# 证书模式校验(对应官方 enableCertManager); bundle 方式固定 internal(官方 manifests.yaml 无 cert-manager)
case "${LWS_CERT_MODE}" in
    cert-manager|internal) ;;
    *) err "LWS_CERT_MODE 仅支持 cert-manager 或 internal(当前=${LWS_CERT_MODE})"; exit 1 ;;
esac
if [ "${LWS_INSTALL_MODE}" = "helm" ] && [ "${LWS_CERT_MODE}" = "cert-manager" ]; then
    if ! SSH "${K} get ns cert-manager >/dev/null 2>&1"; then
        warn "LWS_CERT_MODE=cert-manager 但集群未检测到 cert-manager; 建议改用 internal 模式(离线友好)。继续尝试安装(webhook 证书可能不生成)..."
    fi
fi
# 宿主机 /etc/hosts 更新(registry 域名 → VIP), 与 gpu_operator 一致
# 复用 lib-common 的 ensure_hosts_entry(先删旧行再写当前 IP, 无 grep 守卫 → 多集群不残留旧 IP)
ensure_hosts_entry "${REGISTRY_IP}" "${REGISTRY_DOMAIN}"
ensure_hosts_entry "${API_IP}" "${API_DOMAIN}"
grep -qE "^${REGISTRY_IP}[[:space:]]+${REGISTRY_DOMAIN}" /etc/hosts 2>/dev/null \
    || warn "无法写入宿主机 /etc/hosts(非 root?), ${REGISTRY_DOMAIN} 可能无法从宿主按域名访问"
wait_registry_ready "http://${REGISTRY_DIRECT}/v2/" \
    || { err "集群内置 registry ${REGISTRY_DIRECT}/v2/ 不可达(检查: 宿主机 /etc/hosts 的 ${REGISTRY_DOMAIN} 是否解析到 ${REGISTRY_IP}, 及 MetalLB VIP); 当前 SERVICE_EXPOSE_MODE=${SERVICE_EXPOSE_MODE}"; exit 1; }
SSH "${K} get nodes --no-headers >/dev/null 2>&1" \
    || { err "无法访问集群(${FIRST_MASTER}); 检查 kubectl/集群状态"; exit 1; }
# helm 需要从宿主连 API Server: 复用 lib-common 的 sync_kubeconfig(server→API_DOMAIN + 宿主机 DNAT)
sync_kubeconfig \
    && ok "宿主机 ~/.kube/config 已同步(admin.conf → API ${API_DOMAIN}→${API_IP})" \
    || { err "宿主机无法访问集群(admin.conf 下载/同步失败; 检查 ${FIRST_MASTER} 的 /etc/kubernetes/admin.conf, 以及 ${API_DOMAIN}→${API_IP} 解析)"; exit 1; }
ok "前置检查通过(chart_source=${LWS_CHART_SOURCE}, cert_mode=${LWS_CERT_MODE}, version=${LWS_CHART_VERSION})"

# ---------------- 1. 推送 LWS controller 镜像到集群内置 registry(本地源优先, 离线安装) ----------------
# 离线优先策略:
#   · LWS_CHART_SOURCE=dir/tgz(本地源, 默认) → 镜像也强制走本地(docker daemon / 离线 tar),
#     绝不尝试联网; 离线 tar 由 cubestack-offline.sh download 或手动放入 offline-files。
#   · LWS_CHART_SOURCE=oci 或 LWS_IMAGE_ONLINE=true → 才允许在线 skopeo 拉取官方镜像。
say "[1/3] 推送 lws/manager 镜像 → ${PUSH_REGISTRY}/manager:${LWS_IMAGE_TAG}(默认推送到集群内置 registry, 部署时 K8s 按域名拉取) ..."
# 推送 skopeo(脚本级重试 3 次): 大 blob 连接中途断开时整体重试(与 gpu_operator 一致)
_push_skopeo() {   # <src> <dst>
    local src="$1" dst="$2" n=1 err
    for n in 1 2 3; do
        if skopeo copy --quiet --src-tls-verify=false --dest-tls-verify=false \
            --dest-no-creds "${src}" "${dst}" 2>/tmp/skopeo-err-lws; then
            rm -f /tmp/skopeo-err-lws; return 0
        fi
        err="$(tail -1 /tmp/skopeo-err-lws 2>/dev/null || true)"
        if [ "${n}" -lt 3 ]; then
            warn "  推送失败(第 ${n}/3 次: ${err}), 3s 后重试整包..."
            sleep 3
        fi
    done
    rm -f /tmp/skopeo-err-lws
    return 1
}
# registry 是否已有该 tag? 优先 skopeo inspect 目标 tag(与 push 同通道 PUSH_REGISTRY、同 repo,
# 大镜像只拉 manifest/config 不传 blob); skopeo 缺失时退回 curl 查 tags/list
# (tags/list 路径必须带仓库路径 /lws/manager, 与 PUSH_REGISTRY 一致)
_reg_has_tag() {   # <tag>
    local ver="$1" repo="${PUSH_REGISTRY#*/}"
    if command -v skopeo >/dev/null 2>&1; then
        skopeo inspect --tls-verify=false --no-creds "docker://${PUSH_REGISTRY}/manager:${ver}" >/dev/null 2>&1 && return 0
    fi
    curl -s -m 6 "http://${REGISTRY_BASE}/v2/${repo}/manager/tags/list" 2>/dev/null | grep -q "\"${ver}\""
}
# 是否允许在线拉取: 仅 oci 源或显式 LWS_IMAGE_ONLINE=true
_ALLOW_ONLINE=0
[ "${LWS_CHART_SOURCE:-dir}" = "oci" ] && _ALLOW_ONLINE=1
[ "${LWS_IMAGE_ONLINE:-false}" = "true" ] && _ALLOW_ONLINE=1
if _reg_has_tag "${LWS_IMAGE_TAG}"; then
    ok "  ${LWS_IMAGE_TAG} 已在 registry, 跳过"
else
    _SRC=""
    # ① 本地 docker daemon(任意前缀, 匹配 /manager:<tag>)
    _SRC="$(sudo docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E "/manager:${LWS_IMAGE_TAG}$" | head -1 || true)"
    if [ -n "${_SRC}" ]; then
        _tmp="/tmp/lws-manager-${LWS_IMAGE_TAG}.tar"
        say "  从本地 docker 推送: ${_SRC}"
        if sudo docker save "${_SRC}" -o "${_tmp}" >/dev/null 2>&1 \
           && _push_skopeo "docker-archive:${_tmp}" "docker://${PUSH_REGISTRY}/manager:${LWS_IMAGE_TAG}" >/dev/null 2>&1; then
            rm -f "${_tmp}"
            ok "  lws/manager 已推送(本地 docker)"; _SRC="done"
        else
            rm -f "${_tmp}"
            warn "  本地 docker 推送失败, 尝试离线 tar..."
        fi
    fi
    # ② 离线 tar(lws-save-images.sh 默认 deployments/offline-files/lws; 兼容集群 images 目录) — 本地源的核心镜像来源
    if [ -z "${_SRC}" ]; then
        _TAR=""
        for _td in "${LWS_SAVE_DIR:-${REPO_ROOT}/deployments/offline-files/lws}" \
                   "${LOCAL_REPO_DIR}/images" \
                   "${OFFLINE_FILES_DIR:-${REPO_ROOT}/deployments/offline-files/kubespray}/${CLUSTER_NAME}/images"; do
            [ -d "${_td}" ] || continue
            # ① 按 tar 内容识别 lws controller 镜像(兼容任意文件名, 如 lws-save-images.sh /
            #    cubestack-offline.sh 生成的标准名 registry.k8s.io_lws_lws_<tag>.tar)
            for _t in "${_td}"/*.tar; do
                [ -f "${_t}" ] || continue
                case "$(tar_first_image_tag "${_t}")" in
                    *lws:${LWS_IMAGE_TAG}) _TAR="${_t}"; break ;;
                esac
            done
            # ② 旧命名兜底(*lws*manager*.tar / lws_manager*.tar)
            if [ -z "${_TAR}" ]; then
                for _t in "${_td}"/*lws*manager*.tar "${_td}"/lws_manager*.tar; do
                    [ -f "${_t}" ] && { _TAR="${_t}"; break; }
                done
            fi
            [ -n "${_TAR}" ] && break
        done
        if [ -n "${_TAR}" ]; then
            say "  从离线 tar 推送: $(basename "${_TAR}")"
            if _push_skopeo "docker-archive:${_TAR}" "docker://${PUSH_REGISTRY}/manager:${LWS_IMAGE_TAG}" >/dev/null 2>&1; then
                ok "  lws/manager 已推送(离线 tar)"; _SRC="done"
            else
                warn "  tar 推送失败"
            fi
        fi
    fi
    # ③ 在线 skopeo(仅允许在线时; 本地源默认跳过)
    if [ -z "${_SRC}" ] && [ "${_ALLOW_ONLINE}" = "1" ]; then
        if _push_skopeo "docker://registry.k8s.io/lws/lws:${LWS_IMAGE_TAG}" \
            "docker://${PUSH_REGISTRY}/manager:${LWS_IMAGE_TAG}" >/dev/null 2>&1; then
            ok "  lws/manager 已推送(在线)"; _SRC="done"
        else
            warn "  在线推送失败(OCI/在线模式)"
        fi
    fi
    # 离线安装: 本地源且镜像未就绪 → 报错给指引(不静默继续)
    if [ -z "${_SRC}" ]; then
        if [ "${_ALLOW_ONLINE}" = "1" ]; then
            warn "  lws/manager:${LWS_IMAGE_TAG} 未就绪(本地 docker/tar 无, 在线失败); 请先联网 docker pull 或放离线 tar"
        else
            err "离线安装: 未找到 lws/manager:${LWS_IMAGE_TAG}(本地 docker 无 + 离线 tar 无)。请: ① 在联网机跑 tools/images/lws-save-images.sh 生成 tar 放到 ${REPO_ROOT}/deployments/offline-files/lws/, 或 ② 放离线 tar 到 ${LOCAL_REPO_DIR}/images/, 或 ③ 改 LWS_CHART_SOURCE=oci 允许在线"
        fi
    fi
fi

# ---------------- 2. 安装(bundle: 官方 manifests.yaml | helm: chart) ----------------
say "[2/3] 安装 ${LWS_RELEASE_NAME} → ${LWS_NAMESPACE}(mode=${LWS_INSTALL_MODE}, cert=${LWS_CERT_MODE}, version=${LWS_CHART_VERSION}) ..."
# 清理上次残留(两种方式共用)
SSH "${K} delete validatingwebhookconfiguration lws-validating-webhook-configuration --ignore-not-found >/dev/null 2>&1" || true
SSH "${K} delete mutatingwebhookconfiguration lws-mutating-webhook-configuration --ignore-not-found >/dev/null 2>&1" || true
SSH "${K} patch ns ${LWS_NAMESPACE} --type=merge -p '{\"metadata\":{\"finalizers\":null}}' >/dev/null 2>&1" || true
SSH "${K} delete ns ${LWS_NAMESPACE} --ignore-not-found --force --grace-period=0 >/dev/null 2>&1" || true
sleep 3

if [ "${LWS_INSTALL_MODE}" = "bundle" ]; then
    # 官方 manifests.yaml 单文件: kubectl apply --server-side 整体下发(逐资源应用, 不受 helm Secret 1MiB 限制;
    # 含 namespace + 3 CRD + RBAC + controller + webhook; 控制器自签证书 = internal)。
    # --force-conflicts: 接管旧 helm 部署遗留的集群级 RBAC(字段由 "helm" manager 持有, 删 namespace 删不掉;
    #   不带此 flag 会 "Apply failed with N conflicts" → apply 非零退出 → 误判失败, 但资源其实已建)。
    _tmp="/tmp/lws-manifests-${LWS_IMAGE_TAG}.yaml"
    # 改镜像到集群内置 registry(bundle 内为官方 registry.k8s.io/lws/lws:<tag>)
    sed -E "s#registry\.k8s\.io/lws/lws(:${LWS_IMAGE_TAG})?#${LWS_IMAGE_REPO}\1#g" "${LWS_MANIFEST}" > "${_tmp}" \
        || { rm -f "${_tmp}"; err "生成临时 manifest(改镜像)失败: ${LWS_MANIFEST}"; exit 1; }
    say "  kubectl apply --server-side --force-conflicts ${LWS_MANIFEST}(镜像已改 → ${LWS_IMAGE_REPO}:${LWS_IMAGE_TAG}) ..."
    _apply_log="/tmp/lws-apply-$$.log"
    if cat "${_tmp}" | SSH "${K} apply --server-side --force-conflicts -f -" >"${_apply_log}" 2>&1; then
        ok "  bundle 已应用(namespace + CRD + RBAC + controller + webhook)"
        rm -f "${_tmp}" "${_apply_log}"
    else
        warn "  bundle apply 非零退出, 末尾输出:"
        tail -5 "${_apply_log}" | sed 's/^/    /'
        rm -f "${_tmp}" "${_apply_log}"
        err "bundle apply 失败(${LWS_MANIFEST}); 请检查上面 kubectl 输出"; exit 1
    fi
else
    # helm 方式(未来 cert-manager 模式 / 自定义 values): chart 在 lws/charts/
    # 证书模式 → 官方 values 键 enableCertManager(互斥)
    _CERT_SET=()
    if [ "${LWS_CERT_MODE}" = "cert-manager" ]; then
        _CERT_SET=(--set "enableCertManager=true")
    else
        _CERT_SET=(--set "enableCertManager=false")
    fi
    # DisaggregatedSet → 官方 values 键 enableDisaggregatedSet
    [ "${LWS_DISAGGREGATEDSET_ENABLED:-true}" = "true" ] \
        && _DSET_SET=(--set "enableDisaggregatedSet=true") \
        || _DSET_SET=(--set "enableDisaggregatedSet=false")
    # 解析 chart 参数(按来源)
    _CHART_ARG=""
    case "${LWS_CHART_SOURCE}" in
        dir) _CHART_ARG="${LWS_CHART_DIR}" ;;
        tgz) _CHART_ARG="${LWS_CHART_TGZ}" ;;
        oci) _CHART_ARG="${LWS_CHART_OCI}"; _CHART_ARG+=" --version ${LWS_CHART_VERSION}" ;;
    esac
    # 规避 helm Secret 1MiB 上限: 官方 v0.10.0 的 CRD(含 openAPIV3Schema)超大, 写进 release Secret 会超限。
    # → crds/ 已在 charts/.helmignore 排除(helm 只装模板), CRD 由下方 kubectl 逐文件 apply。
    INSTALL_CRD="${LWS_INSTALL_CRD:-true}"
    helm upgrade --install "${LWS_RELEASE_NAME}" ${_CHART_ARG} \
        --namespace "${LWS_NAMESPACE}" --create-namespace \
        --set "image.manager.repository=${LWS_IMAGE_REPO}" \
        --set "image.manager.tag=${LWS_IMAGE_TAG}" \
        --set "image.manager.pullPolicy=IfNotPresent" \
        "${_CERT_SET[@]}" "${_DSET_SET[@]}" \
        --wait --timeout 180s \
        || warn "  helm 安装/等待超时(检查 --set 与 chart; 资源可能已创建, 继续等待 Deployment)..."
    # CRD 单独 apply(逐文件: 单个 CRD ≤1.5MB, 低于 apiserver 请求体上限 3MiB; 合并多个会超限报 413)
    if [ "${INSTALL_CRD}" = "true" ] && [ "${LWS_CHART_SOURCE}" = "dir" ] && [ -d "${LWS_CHART_DIR}/crds" ]; then
        say "  用 kubectl 逐文件安装 CRD(${LWS_CHART_DIR}/crds) ..."
        for _crd in "${LWS_CHART_DIR}"/crds/*.yaml; do
            _name="$(grep -E '^  name: ' "${_crd}" | head -1 | awk '{print $2}')"
            # 先删旧 CRD 再 apply: 同名 CRD 内容变更时 kubectl apply 无法直接替换(结构冲突), 删后重建保证幂等
            [ -n "${_name}" ] && SSH "${K} delete crd ${_name} --ignore-not-found >/dev/null 2>&1" || true
            if cat "${_crd}" | SSH "${K} apply -f -" >/dev/null 2>&1; then
                ok "  CRD ${_name:-$(basename "${_crd}")} 已应用"
            else
                err "CRD apply 失败: ${_crd}(kubectl apply 报错见上方); 请检查 CRD yaml 与集群 API"; exit 1
            fi
        done
        sleep 3   # 等 CRD Established
    fi
fi

# ---------------- 3. 等待就绪 + 验证 ----------------
say "[3/3] 等待 LWS controller 就绪(最长 180s)..."
SSH "${K} rollout status deployment -n ${LWS_NAMESPACE} ${LWS_RELEASE_NAME}-controller-manager --timeout=120s" >/dev/null 2>&1 \
    || SSH "${K} rollout status deployment -n ${LWS_NAMESPACE} lws-controller-manager --timeout=120s" >/dev/null 2>&1 \
    || warn "  controller rollout 未在 120s 内完成(继续检查 pod)..."
sleep 5

# 检查 CRD 注册(leaderworkerset.x-k8s.io + disaggregatedset.x-k8s.io)
CRD_OK="$(SSH "${K} get crd leaderworkersets.leaderworkerset.x-k8s.io disaggregatedsets.disaggregatedset.x-k8s.io --no-headers 2>/dev/null" | wc -l)"
[ "${CRD_OK:-0}" -ge 2 ] \
    && ok "CRD 已注册(leaderworkersets + disaggregatedsets)" \
    || warn "CRD 未全部注册(当前 ${CRD_OK}/2): kubectl get crd | grep -E 'leaderworkerset|disaggregatedset'"

# 汇总 pod 状态(不因单个 pod 未 Ready 中断, 交给 verify 模块)
PODS="$( (SSH "${K} -n ${LWS_NAMESPACE} get pods -o wide 2>/dev/null" || true) )"
echo "    ${PODS}" | sed 's/^/    /'

echo "---------------------------------------------"
ok "LeaderWorkerSet 部署完成"
echo "  namespace:   ${LWS_NAMESPACE}"
echo "  chart 来源:  ${LWS_CHART_SOURCE}(${LWS_CHART_VERSION})"
echo "  证书模式:    ${LWS_CERT_MODE}(enableCertManager=$([ "${LWS_CERT_MODE}" = "cert-manager" ] && echo true || echo false))"
echo "  资源查看:    kubectl get pods -n ${LWS_NAMESPACE}"
echo "  CRD:         leaderworkersets.leaderworkerset.x-k8s.io / disaggregatedsets.disaggregatedset.x-k8s.io"
echo "  DisaggregatedSet: enableDisaggregatedSet=${LWS_DISAGGREGATEDSET_ENABLED:-true}(直接创建该 CR 即可, 解耦推理)"
echo "  端到端验证:  sudo ./deploy-cluster.sh --steps verify_lws"
echo "  卸载:        helm uninstall ${LWS_RELEASE_NAME} -n ${LWS_NAMESPACE}; 删 CRD"
