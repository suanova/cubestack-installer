#!/bin/bash
# ============================================================
# MODULE: nvidia_gpu_operator
# DESC: 部署 NVIDIA GPU Operator(英伟达官方)—— 离线=镜像集推入集群内置 registry + vendored
#       chart 安装;在线=按 chart 定义(或 Harbor 镜像前缀)直接拉取。预编译驱动容器模式(免内核包下载)。
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: NVIDIA_GPU_OPERATOR_ENABLED
# UNINSTALL: 1
# REQUIRES: k8s_deploy k8s_registry
# 说明:
#   · 版本/开关全部来自 cluster.conf(NVIDIA_GPU_OPERATOR_* / ONLINE_DEPLOY_NVIDIA_GPU_OPERATOR /
#     NVIDIA_GPU_DRIVER_BRANCH / NVIDIA_GPU_DRIVER_PRECOMPILED_KERNELS / REGISTRY_* / NODES), 无硬编码。
#   · 驱动策略 = **预编译驱动容器**(driver.usePrecompiled=true + driver.version=<分支>):
#     operator 依 NFD 的**内核标签**在运行期组合实际镜像 driver:<分支>-<内核>-<OS>(内核必须恰在
#     NGC 预编译覆盖列表; 本模块对有卡节点做**内核白名单门禁**, 不覆盖即 fail-fast 并给出补拉指令)。
#     usePrecompiled 在 v26.7.2 标注 tech-preview(仅 ubuntu22.04) —— 真机验收必须确认
#     driver DaemonSet Ready + nvidia-smi; 退路(自制带包驱动镜像)见 docs/nvidia-gpu-operator.md。
#   · 离线 / 在线模式(2026-10-14, 对标 ONLINE_DEPLOY_CUBESTACK_OPERATOR 口径):
#       false(默认/离线): 镜像集 = chart 渲染提取(tools/images/nvidia-chart-images.sh, 唯一来源)
#             + 预编译驱动镜像(逐内核) → 从离线 tar 推入集群内置 registry 的 mirrors/nvcr.io/**
#             → 各组件 repository 覆盖为集群 registry(节点只从 registry 拉);
#       true(在线): 不推不搬, 镜像按 chart 定义(nvcr.io)直拉; 若集群只可达 Harbor 镜像,
#             NVIDIA_GPU_OPERATOR_ONLINE_IMAGE_BASE=<Harbor>/mirrors 一键切换取源前缀。
#   · chart: vendored 副本恒用(cubestack-addon/nvidia-gpu-operator/<tgz>+digest 边车);
#     NVIDIA_GPU_OPERATOR_CHART_SYNC=auto 探测 nvcr.io 可达 → online 比对刷新 / offline 纯本地。
#   · NFD: cluster.conf NFD_ENABLED=true(kubespray 已布 NFD)时自动 nfd.enabled=false;
#     否则 operator 自带 NFD(v0.19.0, 镜像在本集内)。
#   · 验证: sudo ./deploy-cluster.sh --steps verify_nvidia_gpu。
#   · 本次设计边界(如实标注): 无卡集群走"快路径"(组件级就绪); 端到端(cuda-vectoradd)需真卡环境;
#     预编译不支持 vGPU/GDS、混 OS 不适用(门禁报错); 禁用组件(vGPU/DRA/sandbox 等)未纳入离线
#     支持(镜像虽在集内, repository 未覆盖, 启用需按文档补 --set 与备料)。
# 数据源: cluster.conf (NVIDIA_GPU_OPERATOR_* / ONLINE_DEPLOY_NVIDIA_GPU_OPERATOR / NFD_ENABLED /
#         REGISTRY_* / NODES / SSH_KEY_NAME)
# 用法:   sudo ./deploy-cluster.sh --steps nvidia_gpu_operator
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# 卸载分支(优雅覆盖): 存在性检查 → helm uninstall(连带 chart 内 CR/RBAC/NFD) → 5 个 CRD →
# 命名空间(finalizer 清除+强删)。⚠ 位于 TOGGLE 检查之前(GPU 开关关掉也要能卸旧装)。
if [ "${CUBESTACK_MODULE_ACTION:-install}" = "uninstall" ]; then
    init_remote_kubectl || exit 1
    _ns="${NVIDIA_GPU_OPERATOR_NAMESPACE:-gpu-operator}"
    _rel="${NVIDIA_GPU_OPERATOR_RELEASE:-gpu-operator}"
    _have=0
    SSH "${K} -n ${_ns} get deploy ${_rel} --no-headers >/dev/null 2>&1" && _have=1
    SSH "${K} get ns ${_ns} >/dev/null 2>&1" && _have=1
    SSH "${K} get crd clusterpolicies.nvidia.com >/dev/null 2>&1" && _have=1
    if [ "${_have}" = "0" ]; then
        say "  NVIDIA GPU Operator 不存在, 跳过"
        exit 0
    fi
    if command -v helm >/dev/null 2>&1 && sync_kubeconfig >/dev/null 2>&1; then
        say "  nvidia: helm uninstall ${_rel}(ns=${_ns})..."
        helm uninstall "${_rel}" -n "${_ns}" --wait --timeout 180s >/dev/null 2>&1 \
            || warn "  helm uninstall 未完成(残留由下方清理兜底)"
    else
        warn "  helm 不可用 / kubeconfig 同步失败 → 跳过 helm uninstall, 直接残留清理"
    fi
    say "  清理 CRD 与命名空间残留(幂等)..."
    for _crd in clusterpolicies.nvidia.com gpuclusters.nvidia.com nvidiadrivers.nvidia.com \
                computedomaincliques.resource.nvidia.com computedomains.resource.nvidia.com; do
        SSH "${K} delete crd ${_crd} --ignore-not-found >/dev/null 2>&1" || true
    done
    SSH "${K} patch ns ${_ns} --type=merge -p '{\"metadata\":{\"finalizers\":null}}' >/dev/null 2>&1" || true
    SSH "${K} delete ns ${_ns} --ignore-not-found --force --grace-period=0 >/dev/null 2>&1" || true
    ok "  NVIDIA GPU Operator 已卸载"
    say "  注: 节点侧残留(内核模块已加载至重启前、/run/nvidia 驱动根、containerd 的 99-nvidia.toml"
    say "      注入配置)不在本分支清理范围 —— 重装/回退详见 docs/nvidia-gpu-operator.md 卸载节"
    exit 0
fi

# ---- 开关 ----
# (镜像列表模式 NVIDIA_LIST_IMAGES=true 在下方派生变量后、本检查之前处理 —— 组件关着也能查清单)

# ---------------- 派生变量(全部来自 cluster.conf) ----------------
NS="${NVIDIA_GPU_OPERATOR_NAMESPACE:-gpu-operator}"
RELEASE="${NVIDIA_GPU_OPERATOR_RELEASE:-gpu-operator}"
CHART_VER="${NVIDIA_GPU_OPERATOR_VERSION:-v26.7.2}"
CHART_REF="${NVIDIA_GPU_OPERATOR_CHART_REF:-oci://nvcr.io/nvidia/cloud-native-charts/gpu-operator}"
CHART_DIR="${REPO_ROOT}/deployments/cubestack-addon/nvidia-gpu-operator"
CHART_TGZ="${CHART_DIR}/gpu-operator-${CHART_VER}.tgz"
SYNC_MODE="${NVIDIA_GPU_OPERATOR_CHART_SYNC:-auto}"
ONLINE_DEPLOY="${ONLINE_DEPLOY_NVIDIA_GPU_OPERATOR:-false}"
DRIVER_BRANCH="${NVIDIA_GPU_DRIVER_BRANCH:-595}"
KERNELS="${NVIDIA_GPU_DRIVER_PRECOMPILED_KERNELS:-5.15.0-186-generic}"
ONLINE_IMAGE_BASE="${NVIDIA_GPU_OPERATOR_ONLINE_IMAGE_BASE:-}"
OFFLINE_DIR="${NVIDIA_GPU_OPERATOR_OFFLINE_DIR:-${REPO_ROOT}/deployments/offline-files/nvidia-gpu-operator}"
IMG_SRC_MODE="${NVIDIA_GPU_OPERATOR_IMAGE_SOURCE:-auto}"
REG_BASE="${REGISTRY_DOMAIN:-${REGISTRY_IP}}:${REGISTRY_PORT:-5000}"
REG_DIRECT="${REGISTRY_DIRECT:-${REGISTRY_IP:-$(first_master_ip)}:${REGISTRY_PORT:-5000}}"
IMG_TOOL="${SCRIPT_DIR}/tools/images/nvidia-chart-images.sh"
VERIFY_SAMPLE="nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0-ubuntu22.04"

# ---------------- 镜像列表模式(NVIDIA_LIST_IMAGES=true 仅打印备料清单, 不部署) ----------------
if [ "${NVIDIA_LIST_IMAGES:-false}" = "true" ]; then
    [ -f "${CHART_TGZ}" ] || { err "chart 缺失: ${CHART_TGZ}(先在联网机 helm pull 并提交)"; exit 1; }
    echo "=============================================="
    echo "NVIDIA GPU Operator 所需镜像(chart ${CHART_VER}, 驱动分支 ${DRIVER_BRANCH})"
    echo "  组件镜像(chart 渲染提取, 唯一来源):"
    bash "${IMG_TOOL}" "${CHART_TGZ}" \
        --set "driver.usePrecompiled=true" --set "driver.version=${DRIVER_BRANCH}" \
        | grep -v '/driver:' | sed 's/^/    /'
    echo "  预编译驱动镜像(逐内核; 内核升级/更换需补拉):"
    IFS=',' read -r -a _ks <<< "${KERNELS}"
    for _k in "${_ks[@]:-}"; do
        _k="$(printf '%s' "${_k}" | tr -d '[:space:]')"
        [ -n "${_k}" ] && echo "    nvcr.io/nvidia/driver:${DRIVER_BRANCH}-${_k}-ubuntu22.04"
    done
    echo "  验证样例镜像(verify 模块用):"
    echo "    ${VERIFY_SAMPLE}"
    echo "=============================================="
    echo "  备料: sudo ./deployments/scripts/tools/images/nvidia-save-images.sh"
    echo "       (或 docker pull + docker save 至 ${OFFLINE_DIR}, tar 命名 <域>_<路径>_<tag>.tar)"
    exit 0
fi

# ---- 开关(置于 LIST 模式之后: 组件关着也能用 NVIDIA_LIST_IMAGES=true 查备料清单) ----
[ "${NVIDIA_GPU_OPERATOR_ENABLED:-false}" = "true" ] || { say "NVIDIA_GPU_OPERATOR_ENABLED=false, 跳过 NVIDIA GPU Operator"; exit 0; }

init_remote_kubectl || exit 1
command -v helm >/dev/null 2>&1 || { err "未找到 helm(需 3.0+); CLI 镜像已内置, 宿主手工跑请先安装"; exit 1; }
skopeo_require "nvidia_gpu_operator"

# Harbor 可达性(与 nvcr 同构; auto 模式 chart 刷新探测用)
_nvcr_reachable() {
    local code
    code="$(curl -s -o /dev/null -m 6 -w '%{http_code}' "https://nvcr.io/v2/" 2>/dev/null || true)"
    [ -n "${code}" ] && [ "${code}" != "000" ]
}
case "${SYNC_MODE}" in
    auto)    if _nvcr_reachable; then _MODE=online; else _MODE=offline; fi ;;
    online|offline) _MODE="${SYNC_MODE}" ;;
    *) err "NVIDIA_GPU_OPERATOR_CHART_SYNC 仅支持 auto|online|offline(当前=${SYNC_MODE})"; exit 1 ;;
esac

# 镜像源前缀(同时用于 --set 覆盖与自检口径):
#   离线            → ${REG_BASE}/mirrors(第三方镜像的仓库路径 = mirrors/<上游注册域>/<路径>)
#   在线 + BASE     → ${ONLINE_IMAGE_BASE}(Harbor 镜像前缀, 同一布局)
#   在线 无 BASE    → 空(chart 定义 nvcr.io / registry.k8s.io, 不覆盖)
if [ "${ONLINE_DEPLOY}" = "true" ]; then
    _MIRROR="${ONLINE_IMAGE_BASE}"
else
    _MIRROR="${REG_BASE}/mirrors"
fi

# 组件 repository 覆盖表(启用组件; 路径=helm values 点径; 形式 <组件> <上游 repository>)
# 说明: 仅覆盖**默认启用**的组件; 禁用组件(vGPU/DRA/sandbox 等)未纳入离线支持(见文件头边界)。
_REPO_MAP=(
    "operator nvcr.io/nvidia"
    "validator nvcr.io/nvidia"
    "driver nvcr.io/nvidia"
    "driver.manager nvcr.io/nvidia/cloud-native"
    "toolkit nvcr.io/nvidia/k8s"
    "devicePlugin nvcr.io/nvidia"
    "dcgmExporter nvcr.io/nvidia/k8s"
    "gfd nvcr.io/nvidia"
    "migManager nvcr.io/nvidia/cloud-native"
    "vfioManager nvcr.io/nvidia/cloud-native"
    "vfioManager.driverManager nvcr.io/nvidia/cloud-native"
    # ⚠ NFD(子 chart)的 image.repository 值是**含镜像名的完整仓库路径**(模板原样拼 :tag)——
    #   覆盖值必须给到 "…/nfd/node-feature-discovery", 只给到 "…/nfd" 会拉 <repo>:tag(2026-10-14 实机)
    "node-feature-discovery.image registry.k8s.io/nfd/node-feature-discovery"
)

# 组装 helm --set(安装与渲染提取**共用同一组参数** —— 保证推送集与运行引用零漂移)
_SET_REPOS=()
if [ -n "${_MIRROR}" ]; then
    for _ent in "${_REPO_MAP[@]}"; do
        _p="${_ent%% *}"; _up="${_ent#* }"
        _SET_REPOS+=( --set "${_p}.repository=${_MIRROR}/${_up}" )
    done
fi
_SET_DRIVER=( --set "driver.usePrecompiled=true" --set "driver.version=${DRIVER_BRANCH}" )
if [ "${NFD_ENABLED:-false}" = "true" ]; then
    _SET_NFD=( --set "nfd.enabled=false" )
    say "  检测到集群级 NFD(NFD_ENABLED=true): operator 内嵌 NFD 关闭(nfd.enabled=false)"
else
    _SET_NFD=( --set "nfd.enabled=true" )
fi
# ⚠ 空数组不要用 "${arr[@]:-}" 展开(会产生一个空字符串元素, 变成 helm 的杂散参数) —— 条件追加
_ALL_SET=( "${_SET_DRIVER[@]}" "${_SET_NFD[@]}" )
if [ "${#_SET_REPOS[@]}" -gt 0 ]; then
    _ALL_SET+=( "${_SET_REPOS[@]}" )
fi

# ---------------- [1/6] 前置检查 + GPU 探测 + 内核门禁 ----------------
say "[1/6] 前置检查(registry/集群/kubeconfig) + GPU 节点探测 ..."
API_ENTRY_IP="$(api_entry_ip)" || exit 1
ensure_hosts_entry "${REGISTRY_IP}" "${REGISTRY_DOMAIN}"
ensure_hosts_entry "${API_ENTRY_IP}" "${API_DOMAIN}"
# ★ 2026-10-14 实机: 本环境 fabric 对 MetalLB VIP 的跨段投递会**时通时断**(部署机→VIP 死而
#   →NodePort 通, 集群内节点侧 VIP 正常)。registry 直连端点自适应: VIP 探测不通 → 查询 svc 实际
#   nodePort → 降级直连 <首master>:<nodePort>(推送/预检全程走它), 对 fabric 抖动免疫。
_probe_reg() { curl -s -m 6 -o /dev/null "http://$1/v2/" 2>/dev/null; }
if ! _probe_reg "${REG_DIRECT}"; then
    _np="$( (SSH "${K}" -n kube-system get svc registry -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null) || true )"
    if [ -n "${_np}" ] && _probe_reg "$(first_master_ip):${_np}"; then
        warn "  registry VIP ${REG_DIRECT} 暂不可达(fabric 抖动), 已降级直连 NodePort: $(first_master_ip):${_np}"
        REG_DIRECT="$(first_master_ip):${_np}"
    fi
fi
unset -f _probe_reg
wait_registry_ready "http://${REG_DIRECT}/v2/" \
    || { err "集群内置 registry ${REG_DIRECT}/v2/ 不可达(VIP 与 NodePort 均试过; 检查 REGISTRY_* 与 k8s_registry 模块)"; exit 1; }
SSH "${K} get nodes --no-headers >/dev/null 2>&1" \
    || { err "无法访问集群(${FIRST_MASTER}); 检查 kubectl/集群状态"; exit 1; }
sync_kubeconfig >/dev/null 2>&1 \
    || { err "宿主机 kubeconfig 同步失败(admin.conf 下载失败?); helm 无法连集群"; exit 1; }
ok "  前置检查通过(registry=${REG_DIRECT}, API=${API_DOMAIN}→${API_ENTRY_IP})"

# GPU 探测: 不依赖 nvidia-smi/lspci(驱动未装) —— 直接读 PCI vendor id(sysfs, 0x10de=NVIDIA)
# 同时取内核与 OS(预编译驱动是按内核×OS 组合的镜像; 仅 ubuntu22.04 受支持)。
GPU_NODES=()          # "<hostname> <ip> <kernel>"
for _line in "${NODES[@]:-}"; do
    [ -z "${_line}" ] && continue
    node_parse "${_line}"
    [ -n "${NODE_IP:-}" ] || continue
    _info="$(ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
        "$(ssh_user_for_ip "${NODE_IP}")@${NODE_IP}" \
        "ng=\$(grep -l 0x10de /sys/bus/pci/devices/*/vendor 2>/dev/null | wc -l); k=\$(uname -r); . /etc/os-release 2>/dev/null; echo \"\$ng \$k \$VERSION_ID\"" 2>/dev/null || echo "0 unknown unknown")"
    _ngpu="${_info%% *}"; _rest="${_info#* }"; _kern="${_rest%% *}"; _osid="${_rest#* }"
    _ngpu="$(printf '%s' "${_ngpu:-0}" | tr -d '[:space:]' | grep -E '^[0-9]+$' || echo 0)"
    if [ "${_ngpu}" -gt 0 ] 2>/dev/null; then
        ok "  节点 ${NODE_HOSTNAME}(${NODE_IP}) 检测到 ${_ngpu} 个 NVIDIA PCI 设备(内核 ${_kern}, OS ${_osid})"
        [ "${_osid}" = "22.04" ] \
            || { err "  ${NODE_HOSTNAME} OS=${_osid} 非 22.04: 预编译驱动容器仅支持 ubuntu22.04; 见 docs/nvidia-gpu-operator.md 的退路"; exit 1; }
        GPU_NODES+=("${NODE_HOSTNAME} ${NODE_IP} ${_kern}")
    else
        say "  节点 ${NODE_HOSTNAME}(${NODE_IP}) 无 NVIDIA PCI 设备"
    fi
done

# 内核白名单门禁(有卡才检): 内核必须在本模块的预编译列表内, 且对应镜像可获取(离线=离线集/tar,
# 在线=registry 已有或可拉) —— 否则 operator 会在运行期拉不到内核镜像, 报模糊错误。
IFS=',' read -r -a _KLIST <<< "${KERNELS}"
if [ "${#GPU_NODES[@]}" -gt 0 ]; then
    for _gn in "${GPU_NODES[@]}"; do
        _gk="${_gn##* }"
        _hit=0
        for _k in "${_KLIST[@]:-}"; do
            _k="$(printf '%s' "${_k}" | tr -d '[:space:]')"
            [ -n "${_k}" ] && [ "${_k}" = "${_gk}" ] && _hit=1
        done
        [ "${_hit}" = "1" ] \
            || { err "  有卡节点 ${_gn%% *} 内核 ${_gk} 不在 NVIDIA_GPU_DRIVER_PRECOMPILED_KERNELS(${KERNELS}) 内"; \
                 err "  → 补料: 联网机 skopeo copy docker://nvcr.io/nvidia/driver:${DRIVER_BRANCH}-${_gk}-ubuntu22.04 → 离线目录/registry 后重跑; 或改用自制带包驱动镜像(见文档)"; exit 1; }
    done
    ok "  内核门禁通过(有卡节点内核均在预编译覆盖列表内)"
else
    warn "  集群未检测到 NVIDIA 卡: 走快路径(仅验证组件级就绪; driver/toolkit 等 DS 不会落地)"
fi

# ---------------- [2/6] chart 离线副本就绪(在线则比对 digest 刷新) ----------------
say "[2/6] chart 离线副本就绪(sync=${SYNC_MODE} → ${_MODE})..."
helm_chart_ensure "${RELEASE}" "${CHART_TGZ}" "${CHART_VER}" "${_MODE}" "${CHART_REF}" || exit 1
ok "  chart 就绪: $(basename "${CHART_TGZ}")(本地副本, 部署恒用它)"

# ---------------- [3/6] 镜像集构造(渲染提取) + 推送(离线)/跳过(在线) ----------------
say "[3/6] 构造镜像集(渲染提取)..."
# ⚠ 提取只喂 driver/nfd 参数、**不喂 repository 覆盖**(2026-10-14 实机教训: 喂了覆盖后启用组件的
#   ref 变成"已镜像形态"(registry…/mirrors/nvcr.io/…), 推送循环按上游形态解析 tar/目标全歪)——
#   推送集恒为**上游全限定 ref**, 目标 mirrors/<ref> 由循环统一推导。
SRC_IMAGES=()
while IFS= read -r _l; do
    [ -z "${_l}" ] && continue
    # driver 渲染行是 "<分支>" 占位(usePrecompiled 运行期由 operator 组合内核化 tag) → 丢弃, 另行补入
    case "${_l}" in */driver:"${DRIVER_BRANCH}") continue ;; esac
    SRC_IMAGES+=("${_l}")
done < <( bash "${IMG_TOOL}" "${CHART_TGZ}" "${_SET_DRIVER[@]}" "${_SET_NFD[@]}" )
# 预编译驱动镜像(逐内核)
for _k in "${_KLIST[@]:-}"; do
    _k="$(printf '%s' "${_k}" | tr -d '[:space:]')"
    [ -n "${_k}" ] && SRC_IMAGES+=("nvcr.io/nvidia/driver:${DRIVER_BRANCH}-${_k}-ubuntu22.04")
done
# 验证样例(verify 模块用; 归入本集, 备料/推送与组件一致)
SRC_IMAGES+=("${VERIFY_SAMPLE}")
[ "${#SRC_IMAGES[@]}" -gt 0 ] || { err "镜像集为空(chart 渲染失败? 手工确认: bash ${IMG_TOOL} ${CHART_TGZ})"; exit 1; }
say "  镜像集共 ${#SRC_IMAGES[@]} 个:"
for _img in "${SRC_IMAGES[@]}"; do say "    ${_img}"; done

if [ "${ONLINE_DEPLOY}" = "true" ]; then
    say "[3/6] 在线部署: 跳过镜像推送 —— 按 chart 定义${_MIRROR:+ / 前缀 ${_MIRROR}}拉取"
else
    say "[3/6] 推送镜像 → ${REG_BASE}/mirrors/**(节点只从集群 registry 拉)..."
    _N_PUSH=0; _N_SKIP=0; _N_WARN=0
    for _img in "${SRC_IMAGES[@]}"; do
        # 目标路径 = mirrors/<上游全限定 ref>(与 Harbor 镜像布局一致)
        _path="${_img%%:*}"                 # nvcr.io/nvidia/gpu-operator
        _tag="${_img##*:}"
        _repo_dir="$(dirname "${_path}")"   # nvcr.io/nvidia
        _repo_name="$(basename "${_path}")" # gpu-operator
        _pr="${REG_DIRECT}/mirrors/${_repo_dir}"
        _dst="docker://${_pr}/${_repo_name}:${_tag}"
        # 幂等: 版本化 tag 不可变 → registry 已有该 tag 即跳过(tar/docker/harbor 都不用找)
        if reg_has_tag "${_pr}" "${_repo_name}" "${_tag}"; then
            _N_SKIP=$((_N_SKIP+1)); continue
        fi
        # 源优先级: tar → docker(本地 daemon) → harbor/chart 上游(仅 chart-sync=online 时尝试)
        _tar="$(find_offline_tar "${_img}" "*${_repo_name}*${_tag}*.tar" "${OFFLINE_DIR}" 2>/dev/null || true)"
        _pushed=0
        if [ -n "${_tar}" ]; then
            say "  推 ${_img} ← $(basename "${_tar}")"
            if push_image_skopeo "docker-archive:${_tar}" "${_dst}" >/dev/null 2>&1; then _pushed=1; fi
        fi
        if [ "${_pushed}" = "0" ]; then
            _local="$(sudo docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -Fx "${_img}" | head -1 || true)"
            if [ -n "${_local}" ]; then
                _tmp="/tmp/nvidia-gpu-op-$$.tar"
                say "  推 ${_img} ← 本地 docker"
                if sudo docker save "${_local}" -o "${_tmp}" >/dev/null 2>&1 \
                   && push_image_skopeo "docker-archive:${_tmp}" "${_dst}" >/dev/null 2>&1; then _pushed=1; fi
                rm -f "${_tmp}"
            fi
        fi
        if [ "${_pushed}" = "0" ] && [ "${_MODE}" = "online" ]; then
            say "  推 ${_img} ← 上游直拉(chart-online)"
            push_image_skopeo "docker://${_img}" "${_dst}" >/dev/null 2>&1 && _pushed=1 || true
        fi
        if [ "${_pushed}" = "1" ]; then
            _N_PUSH=$((_N_PUSH+1))
        else
            # cuda-sample 仅 verify 用 → best-effort 告警; 组件镜像缺失 = 硬失败
            if [ "${_img}" = "${VERIFY_SAMPLE}" ]; then
                _N_WARN=$((_N_WARN+1))
                warn "  验证样例镜像未就绪(verify_nvidia_gpu 的端到端步会跳过): ${_img}"
                warn "    补料: nvidia-save-images.sh 或 docker pull/save 到 ${OFFLINE_DIR}/"
            else
                err "镜像推送失败: ${_img}"
                err "  可用源都不成立(离线 tar 缺 + 本地 docker 无${_MODE:+ + 上游不可达})"
                err "  修法: ① 联网机备料: sudo ./deployments/scripts/tools/images/nvidia-save-images.sh"
                err "        ② 或把 ${_img} 手工 pull/save 到 ${OFFLINE_DIR}/ 后重跑"
                exit 1
            fi
        fi
    done
    ok "  镜像就绪: 新推 ${_N_PUSH} 个, 已在 registry 跳过 ${_N_SKIP} 个${_N_WARN:+ , 未就绪 ${_N_WARN} 个(见告警)}"
fi

# ---------------- [4/6] CRD 预应用(chart crds/, SSA 幂等) ----------------
say "[4/6] 应用 chart 内 CRD(crds/ 目录)..."
_WORK="$(mktemp -d)"
trap 'rm -rf "${_WORK}"' EXIT
tar -xzf "${CHART_TGZ}" -C "${_WORK}"
CRD_DIR="$(find "${_WORK}" -maxdepth 2 -type d -name crds | head -1 || true)"
if [ -n "${CRD_DIR}" ] && ls "${CRD_DIR}"/*.yaml >/dev/null 2>&1; then
    for _crd in "${CRD_DIR}"/*.yaml; do
        if cat "${_crd}" | SSH "${K} apply --server-side --force-conflicts -f -" >/dev/null 2>&1; then
            ok "  CRD 已应用: $(basename "${_crd}")"
        else
            err "CRD apply 失败: $(basename "${_crd}")"; exit 1
        fi
    done
else
    warn "  chart 内未找到 crds/ 目录(跳过; chart 结构异常?)"
fi

# ---------------- [5/6] helm upgrade --install ----------------
say "[5/6] helm upgrade --install ${RELEASE} → ${NS} ..."
# 命名空间先建 + PSA 提权标签(官方建议; 幂等)
SSH "${K} get ns ${NS} >/dev/null 2>&1 || ${K} create namespace ${NS} >/dev/null 2>&1" || true
SSH "${K} label ns ${NS} pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null 2>&1" || true
# ⚠ --wait 对 driver DS 在真卡环境可能超时(首次镜像拉取/驱动就绪) —— 告警不中止, [6/6] 续等
helm upgrade --install "${RELEASE}" "${CHART_TGZ}" \
    --namespace "${NS}" --create-namespace \
    "${_ALL_SET[@]}" \
    --wait --timeout 300s \
    || warn "  helm 安装/等待超时(资源可能已创建, 继续等待; 排查: helm status ${RELEASE} -n ${NS})"

# ---------------- [6/6] 就绪等待 + 活体自检 + 登记 ----------------
say "[6/6] 等待组件就绪 ..."
SSH "${K} -n ${NS} rollout status deployment/${RELEASE} --timeout=180s" >/dev/null 2>&1 \
    || SSH "${K} -n ${NS} rollout status deployment/${RELEASE}-gpu-operator --timeout=180s" >/dev/null 2>&1 \
    || warn "  operator Deployment 未在 180s 内就绪(继续; 端到端验证会给确切状态)"

# NFD DaemonSet(operator 自带时)就绪; 集群级 NFD 时跳过
if [ "${NFD_ENABLED:-false}" != "true" ]; then
    _nfd_ok=0
    for _i in $(seq 1 36); do
        _nfd_ok="$( (SSH "${K} -n ${NS} get ds --no-headers 2>/dev/null" || true) \
            | awk '/node-feature-discovery/ && $2>0 && $2==$4 {n++} END{print n+0}' )"
        [ "${_nfd_ok:-0}" -ge 1 ] && break
        sleep 5
    done
    [ "${_nfd_ok:-0}" -ge 1 ] && ok "  NFD DaemonSet 就绪" \
        || warn "  NFD DaemonSet 未在 180s 内 Ready(检查: kubectl -n ${NS} get ds,pods)"
fi

# ClusterPolicy ready(限时; 无卡集群也应 ready —— 不 ready 属异常, 如实提示)
_cp_name="$( (SSH "${K} get clusterpolicy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null" || true) )"
_cp_state=""
if [ -n "${_cp_name}" ]; then
    for _i in $(seq 1 60); do
        _cp_state="$( (SSH "${K} get clusterpolicy ${_cp_name} -o jsonpath='{.status.state}' 2>/dev/null" || true) )"
        [ "${_cp_state}" = "ready" ] && break
        sleep 5
    done
fi
if [ "${_cp_state}" = "ready" ]; then
    ok "  ClusterPolicy ${_cp_name} 状态: ready"
else
    warn "  ClusterPolicy 状态: ${_cp_state:-未知}(未 ready; 排查: kubectl describe clusterpolicy ${_cp_name:-cluster-policy})"
fi

# 活体 CR repository 自检 + 纠偏(2026-10-13 实机教训: helm 三路合并对 CR 更新不可靠,
# 在线↔离线切换后活体 CR 可能残留旧前缀 → 组件持续按旧值拉镜像)
if [ -n "${_MIRROR}" ] && [ -n "${_cp_name}" ]; then
    _cr_json="$( (SSH "${K} get clusterpolicy ${_cp_name} -o json 2>/dev/null" || true) )"
    _patch_file="/tmp/nvidia-gpu-operator-cr-patch.$$.json"
    _changed="$(printf '%s' "${_cr_json}" | python3 -c '
import json, sys
base = sys.argv[1].rstrip("/")
outfile = sys.argv[2]
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); sys.exit(0)
spec = d.get("spec", {})
ch = []
def walk(o, p):
    if isinstance(o, dict):
        for k, v in list(o.items()):
            if k == "repository" and isinstance(v, str) and v and not v.startswith(base):
                ch.append("/".join(p + [k])); o[k] = base + "/" + v
            else:
                walk(v, p + [k])
    elif isinstance(o, list):
        for i, x in enumerate(o):
            walk(x, p + [str(i)])
walk(spec, [])
if ch:
    open(outfile, "w").write(json.dumps({"spec": spec}))
print(" ".join(ch))
' "${_MIRROR}" "${_patch_file}" 2>/dev/null || true)"
    if [ -n "${_changed}" ]; then
        warn "  CR 镜像前缀漂移(残留旧值): ${_changed}"
        say "  → kubectl patch 纠偏为 ${_MIRROR}/** ..."
        if SSH "${K}" -n "${NS}" patch clusterpolicy "${_cp_name}" --type=merge --patch-file=/dev/stdin < "${_patch_file}" >/dev/null 2>&1; then
            ok "  CR 已纠偏(operator 将按新前缀滚动组件)"
        else
            warn "  CR 纠偏失败(手工: kubectl -n ${NS} get clusterpolicy ${_cp_name} -o yaml; 期望 repository 前缀 ${_MIRROR})"
        fi
    else
        ok "  CR 镜像前缀自检通过(全部指向 ${_MIRROR}/**)"
    fi
    rm -f "${_patch_file}"
fi

# GPU 资源(有卡时等设备插件注册; 与 metax 同款的注册竞态等待)
if [ "${#GPU_NODES[@]}" -gt 0 ]; then
    _gpu_allocatable() {
        (SSH "${K} get nodes -o json 2>/dev/null" || true) | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    for n in d["items"]:
        g=n["status"]["allocatable"].get("nvidia.com/gpu")
        if g: print(n["metadata"]["name"], g)
except Exception: pass'
    }
    GPU_ALLOC=""
    for _gpui in $(seq 1 60); do
        GPU_ALLOC="$(_gpu_allocatable)"
        [ -n "${GPU_ALLOC}" ] && break
        [ "${_gpui}" -lt 60 ] && sleep 5
    done
    unset -f _gpu_allocatable
    if [ -n "${GPU_ALLOC}" ]; then
        ok "  节点已发现 GPU 资源(nvidia.com/gpu allocatable):"
        echo "${GPU_ALLOC}" | sed 's/^/    /'
    else
        warn "  暂未发现 nvidia.com/gpu allocatable(设备插件注册有秒级~分钟级时延; 稍后复查)"
        warn "    复查: kubectl get nodes -o json | grep -A2 'nvidia.com/gpu' / --steps verify_nvidia_gpu"
    fi
fi

echo "---------------------------------------------"
if [ "${#GPU_NODES[@]}" -gt 0 ]; then
    ok "NVIDIA GPU Operator 部署完成(检测到 ${#GPU_NODES[@]} 个有卡节点)"
else
    ok "NVIDIA GPU Operator 部署完成(纯 CPU 集群: 组件级就绪; 插入 NVIDIA 卡后重跑本模块或 verify 复查)"
fi
echo "  namespace:   ${NS}"
echo "  部署模式:    $([ "${ONLINE_DEPLOY}" = "true" ] && echo "在线(按 chart 定义${_MIRROR:+ / ${_MIRROR}})恒拉" || echo "离线(镜像已推 ${REG_BASE}/mirrors/**)")"
echo "  驱动:        预编译容器(分支 ${DRIVER_BRANCH}; 内核: ${KERNELS})"
echo "  资源查看:    kubectl get pods,ds -n ${NS}; kubectl get clusterpolicy ${_cp_name:-cluster-policy}"
echo "  端到端验证:  sudo ./deploy-cluster.sh --steps verify_nvidia_gpu"
echo "  卸载:        删除模块状态后重跑本模块卸载(cluster-teardown 反序优雅卸载), 或 helm uninstall ${RELEASE} -n ${NS}"

# 优雅覆盖登记(仅安装路径到达此处)
record_installed_component "nvidia_gpu_operator"
