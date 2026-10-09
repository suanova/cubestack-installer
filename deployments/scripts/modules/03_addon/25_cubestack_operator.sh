#!/bin/bash
# ============================================================
# MODULE: cubestack_operator
# DESC: 部署 CubeStack 平台 Operator —— 本地 vendored chart 渲染提取镜像 → 推入集群内置
#       registry → helm upgrade --install(image.repository 指向集群 registry);
#       在线时每次部署比对 OCI chart digest 并刷新离线副本
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: CUBESTACK_OPERATOR_ENABLED
# REQUIRES: k8s_deploy k8s_registry
# 说明:
#   · 离线 / 在线(需求 1): CUBESTACK_OPERATOR_CHART_SYNC=auto(默认) —— 探测 Harbor 可达则
#     online(拉远端 → 取 Digest 与 <tgz>.digest 边车比对 → 变了覆盖本地副本, 未变仓库保持干净),
#     否则 offline(纯本地, 不发起任何联网动作); 也可显式写 online|offline 强制。
#   · chart 来源(需求 2): oci://harbor.isuanova.com/suanova-private/cubestack-operator-chart,
#     离线副本 = deployments/cubestack-addon/cubestack-operator/<chart>-<版本>.tgz(+ .digest 边车),
#     随 git 分发。安装**恒用这份本地副本** —— 线上拉到的东西不直接装(见 scripts-development-spec §2.4)。
#   · 镜像清单(需求 4): **从 chart 渲染结果动态提取**(不写死清单); 逐个推入集群内置 registry。
#     离线 tar 目录 = deployments/offline-files/cubestack-operator/(联网机用
#     tools/images/harbor-save-images.sh --group cubestack-operator 生成)。
#   · 镜像拉取(需求 5): 节点**只从集群内置 registry 拉取**(--set image.repository=
#     <REGISTRY_DOMAIN>:<port>/suanova-private/cubestack-operator), 部署时节点不访问 Harbor。
#   · REPEAT:1(每次执行, 不是断点续跑): chart 是 1.0.0-latest 滚动版、镜像 tag=latest,
#     每次部署都必须重新比对刷新 —— REPEAT:0 的"完成后跳过"会让它永远停在首次拉到的版本。
#     安装本身幂等: helm upgrade --install + 镜像按 digest 比对后才推。
#   · 滚动 tag 的节点缓存陷阱(重要): 镜像 ref 恒为 ...:latest, 若只改内容不改 ref, kubelet
#     在 IfNotPresent 下会直接用节点缓存 → 部署"成功"但跑的是旧镜像, 且 Deployment spec 没变
#     不会触发滚动。故本模块默认: ① 把刚推入镜像的 **digest** 写进 podAnnotations
#     (cubestack.io/image-digest), digest 变了 pod 模板就变 → 自动滚动; ② pullPolicy 默认
#     **Always**(与 README 对滚动构建的建议一致), 保证新 pod 真的去 registry 重新解析 tag。
#     要跟随滚动构建: 保持默认; 要钉住节点缓存: CUBESTACK_OPERATOR_IMAGE_PULL_POLICY=IfNotPresent。
# 数据源: cluster.conf (CUBESTACK_OPERATOR_* / REGISTRY_* / HARBOR_MIRROR_* / NODES / SSH_KEY_NAME)
# 用法:   sudo ./deploy-cluster.sh --steps cubestack_operator
# 验证:   sudo ./deploy-cluster.sh --steps verify_cubestack_operator
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# ---- 开关 ----
[ "${CUBESTACK_OPERATOR_ENABLED:-false}" = "true" ] || { say "CUBESTACK_OPERATOR_ENABLED=false, 跳过 CubeStack Operator 部署"; exit 0; }

init_remote_kubectl || exit 1
command -v helm >/dev/null 2>&1 || { err "未找到 helm(需 3.0+): 本模块用 helm template 提取镜像 + helm upgrade --install 安装(CLI 镜像已内置)"; exit 1; }

# ---------------- 派生变量(全部来自 cluster.conf, 无硬编码) ----------------
NS="${CUBESTACK_OPERATOR_NAMESPACE:-cubestack-system}"
RELEASE="${CUBESTACK_OPERATOR_RELEASE:-cubestack-operator}"
CHART_REF="${CUBESTACK_OPERATOR_CHART_REF:-oci://harbor.isuanova.com/suanova-private/cubestack-operator-chart}"
CHART_VER="${CUBESTACK_OPERATOR_CHART_VERSION:-1.0.0-latest}"
CHART_DIR="${REPO_ROOT}/deployments/cubestack-addon/cubestack-operator"
CHART_NAME="$(basename "${CHART_REF}")"                      # cubestack-operator-chart
CHART_TGZ="${CHART_DIR}/${CHART_NAME}-${CHART_VER}.tgz"
SYNC_MODE="${CUBESTACK_OPERATOR_CHART_SYNC:-auto}"
IMG_TAG="${CUBESTACK_OPERATOR_IMAGE_TAG:-latest}"
IMG_SRC_MODE="${CUBESTACK_OPERATOR_IMAGE_SOURCE:-auto}"
IMG_PULL_POLICY="${CUBESTACK_OPERATOR_IMAGE_PULL_POLICY:-Always}"
PIN_DIGEST="${CUBESTACK_OPERATOR_PIN_IMAGE_DIGEST:-true}"
OFFLINE_DIR="${CUBESTACK_OPERATOR_OFFLINE_DIR:-${REPO_ROOT}/deployments/offline-files/cubestack-operator}"
CR_ENABLED="${CUBESTACK_OPERATOR_CLUSTER_CR_ENABLED:-true}"
CR_VALUES_FILE="${CUBESTACK_OPERATOR_CR_VALUES_FILE:-}"
HARBOR_HOST="${CUBESTACK_OPERATOR_HARBOR_HOST:-${HARBOR_MIRROR_REGISTRY:-harbor.isuanova.com}}"
# 私有项目凭据: 未单独配置时复用镜像源凭据(HARBOR_MIRROR_USER/PASSWORD, 同一台 Harbor)
HARBOR_USER="${CUBESTACK_OPERATOR_HARBOR_USER:-${HARBOR_MIRROR_USER:-}}"
HARBOR_PASSWORD="${CUBESTACK_OPERATOR_HARBOR_PASSWORD:-${HARBOR_MIRROR_PASSWORD:-}}"
# 集群内置 registry 双端点(与 gpu_operator/gpu_lws 同款):
#   REG_BASE   = 节点可解析的域名端点(K8s 按此拉取)   REG_DIRECT = 推送用直连端点(无 DNS 依赖)
REG_BASE="${REGISTRY_DOMAIN:-${REGISTRY_IP}}:${REGISTRY_PORT:-5000}"
REG_DIRECT="${REGISTRY_DIRECT:-${REGISTRY_IP:-$(first_master_ip)}:${REGISTRY_PORT:-5000}}"
_EXTRA_VALUES=()          # 额外 values 文件(-f)
_CR_VALUES=()             # clusterCR 相关 --set

# ---------------- 凭据(skokpeo / helm 共用, 不进 ps) ----------------
# 仅在**在线刷新 chart / 在线拉镜像**时需要; 部署路径(本地 chart + 集群 registry)不需要凭据。
_AUTH_FILE=""
_cleanup() { [ -n "${_AUTH_FILE}" ] && rm -f "${_AUTH_FILE}" || true; }
trap '_cleanup' EXIT
if [ -n "${HARBOR_USER}" ] && [ -n "${HARBOR_PASSWORD}" ]; then
    _AUTH_FILE="$(mktemp)"; chmod 600 "${_AUTH_FILE}"
    _b64="$(printf '%s:%s' "${HARBOR_USER}" "${HARBOR_PASSWORD}" | base64 -w0 2>/dev/null \
            || printf '%s:%s' "${HARBOR_USER}" "${HARBOR_PASSWORD}" | base64)"
    printf '{"auths":{"%s":{"auth":"%s"}}}' "${HARBOR_HOST}" "${_b64}" > "${_AUTH_FILE}"
    unset _b64
    export REGISTRY_AUTH_FILE="${_AUTH_FILE}"     # skopeo 读它(密码不进命令行, ps 看不到)
fi

# Harbor 可达性探测(000=不可达; 200/401 都算"在")。用 /v2/ 而非具体仓库: 只判"网络是否通"。
_harbor_reachable() {
    local code
    code="$(curl -s -o /dev/null -m 6 -w '%{http_code}' "https://${HARBOR_HOST}/v2/" 2>/dev/null || true)"
    [ -n "${code}" ] && [ "${code}" != "000" ]
}

# 解析同步模式: auto 由"能否连上 Harbor"决定 —— 离线机不会发起 chart 拉取(不阻塞部署),
# 联网机自动取最新。显式 online 时若网络不通, helm_chart_ensure 会降级回退本地副本(告警不中断)。
case "${SYNC_MODE}" in
    auto)    if _harbor_reachable; then _MODE=online; else _MODE=offline; fi ;;
    online|offline) _MODE="${SYNC_MODE}" ;;
    *) err "CUBESTACK_OPERATOR_CHART_SYNC 仅支持 auto|online|offline(当前=${SYNC_MODE})"; exit 1 ;;
esac

# 渲染提取镜像 ref(动态, 不写死): 只看行首为 image: 的键 —— 不会误匹配 imagePullPolicy/imagePullSecrets
_render_images() {
    helm template "${RELEASE}" "${CHART_TGZ}" -n "${NS}" "$@" 2>/dev/null \
        | sed -n 's/^[[:space:]]*image:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' \
        | sort -u
}

# 镜像 digest(取 amd64/linux 那一层的清单 digest; 取不到输出空 → 调用方保守重推, 不会误判)
#   ⚠ skopeo inspect **不支持** --override-arch(CLI 镜像内 1.16.1 实测), 多架构 index 上
#     {{.Digest}} 给的是 index 自身摘要、与"推过去的单架构镜像"不可比(会比不出相等而每次重推)。
#     故自己解析 --raw: index → 取 amd64/linux 条目的 digest; 单架构清单 → 清单字节的 sha256
#     (= 该清单在 registry 里的 digest, 与 --override-arch 推过去的目标同一比对空间)。
_digest() {   # <docker://ref | docker-archive:path>
    local ref="$1" raw=""
    raw="$(skopeo inspect --raw --tls-verify=false "${ref}" 2>/dev/null || true)"
    [ -n "${raw}" ] || return 0
    printf '%s' "${raw}" | python3 -c '
import hashlib, json, sys
raw = sys.stdin.buffer.read()
try:
    d = json.loads(raw)
except Exception:
    sys.exit(0)
ms = d.get("manifests")
if isinstance(ms, list):                 # 多架构 index → amd64/linux 条目
    for m in ms:
        p = m.get("platform") or {}
        if p.get("architecture") == "amd64" and p.get("os") == "linux":
            print(m.get("digest", "")); break
else:                                     # 单架构清单 → 字节 sha256 = 它自己的 digest
    print("sha256:" + hashlib.sha256(raw).hexdigest())
' 2>/dev/null || true
}

# ---------------- [1/6] chart 离线副本就绪(在线则比对 digest 刷新) ----------------
say "[1/6] chart 离线副本就绪(sync=${SYNC_MODE} → ${_MODE})..."
if [ "${_MODE}" = "online" ]; then
    if [ -n "${HARBOR_USER}" ]; then
        # --password-stdin: 不进 ps/日志(与 harbor-save-images.sh 的 auth 文件同一考虑)
        printf '%s' "${HARBOR_PASSWORD}" | helm registry login "${HARBOR_HOST}" -u "${HARBOR_USER}" --password-stdin >/dev/null 2>&1 \
            || warn "  helm registry login ${HARBOR_HOST} 失败(检查凭据); 远端拉取将 401 → 自动回退本地离线副本"
    else
        warn "  未配置 ${HARBOR_HOST} 凭据(CUBESTACK_OPERATOR_HARBOR_USER/HARBOR_MIRROR_USER): 依赖既有 helm 登录态, 否则远端拉取 401 并回退本地副本"
    fi
fi
helm_chart_ensure "${RELEASE}" "${CHART_TGZ}" "${CHART_VER}" "${_MODE}" "${CHART_REF}" || exit 1
ok "  chart 就绪: $(basename "${CHART_TGZ}")(本地副本, 部署恒用它)"

# ---------------- [2/6] 前置检查 ----------------
say "[2/6] 前置检查(registry 可达 / 集群可达 / kubeconfig)..."
skopeo_require "cubestack_operator"
# 宿主机 /etc/hosts 收敛(registry 域名 → 当前集群 IP; 复用 ensure_hosts_entry, 防多集群残留旧 IP)
API_ENTRY_IP="$(api_entry_ip)" || exit 1
ensure_hosts_entry "${REGISTRY_IP}" "${REGISTRY_DOMAIN}"
ensure_hosts_entry "${API_ENTRY_IP}" "${API_DOMAIN}"
grep -qE "^${REGISTRY_IP}[[:space:]]+${REGISTRY_DOMAIN}" /etc/hosts 2>/dev/null \
    || warn "无法写入宿主机 /etc/hosts(非 root?), ${REGISTRY_DOMAIN} 可能无法从宿主按域名访问"
wait_registry_ready "http://${REG_DIRECT}/v2/" \
    || { err "集群内置 registry ${REG_DIRECT}/v2/ 不可达(检查 REGISTRY_* 与 k8s_registry 模块; SERVICE_EXPOSE_MODE=${SERVICE_EXPOSE_MODE:-nodeport})"; exit 1; }
SSH "${K} get nodes --no-headers >/dev/null 2>&1" \
    || { err "无法访问集群(${FIRST_MASTER}); 检查 kubectl/集群状态"; exit 1; }
# helm 从宿主连 API Server(kubeconfig 的 server 改写为 API_DOMAIN + 宿主机 DNAT, 见 sync_kubeconfig)
sync_kubeconfig >/dev/null 2>&1 \
    || { err "宿主机 kubeconfig 同步失败(admin.conf 下载失败?); helm 无法连集群"; exit 1; }
ok "  前置检查通过(registry=${REG_DIRECT}, API=${API_DOMAIN}→${API_ENTRY_IP})"

# ---------------- [3/6] 从 chart 渲染提取镜像清单(动态) ----------------
say "[3/6] 渲染 chart 提取镜像清单(helm template, 不写死清单)..."
EXTRA_CR_VALUES_ARG=()
if [ "${CR_ENABLED}" = "true" ]; then
    _CR_VALUES=( --set "clusterCR.enabled=true" )
    # ★ 2026-10-08 平台组件离线链路: CR 全局镜像源注入 → **集群内置 registry**(离线可用性的关键)。
    #   自研组件走 imageRegistry(平铺布局), 第三方走 externalImageRegistryPrefix(原样前置);
    #   与 [4b/6] 的推送目标映射一一对应(镜像由本模块预先推入)。
    #   · imagePullSecrets 置空 —— 集群 registry 匿名可拉; 保留渲染默认(harbor-credentials)而
    #     Secret 不存在时, 所有组件会 ImagePullBackOff(k8s: 引用不存在的 pull secret 直接失败)。
    _CR_VALUES+=(
        --set "clusterCR.spec.global.imageRegistry=${REG_BASE}/suanova"
        --set "clusterCR.spec.global.externalImageRegistryPrefix=${REG_BASE}/mirrors"
        --set-json "clusterCR.spec.global.imagePullSecrets=[]"
        # 默认裁剪(离线开箱可部署; 要开用 CUBESTACK_OPERATOR_CR_VALUES_FILE 覆盖, 见 docs):
        #   ① 模型 bundles 清空 + modelBundles 关 —— chart 默认下发 7 个 bundle(推理 Pod/GPU 需求),
        #      非"平台服务"必需; ② bmc 关 —— 需管理员先建 cubestack-bmc-credentials Secret,
        #      缺失会 Degraded(operator 只读该 Secret, 从不创建)。
        --set-json "clusterCR.spec.bundles=[]"
        --set "clusterCR.spec.components.modelBundles.enabled=false"
        --set "clusterCR.spec.components.exporters.bmc.enabled=false"
    )
    EXTRA_CR_VALUES_ARG=( "${_CR_VALUES[@]}" )
fi
if [ -n "${CR_VALUES_FILE}" ]; then
    [ -f "${CR_VALUES_FILE}" ] || { err "CUBESTACK_OPERATOR_CR_VALUES_FILE 不存在: ${CR_VALUES_FILE}"; exit 1; }
    _EXTRA_VALUES=( -f "${CR_VALUES_FILE}" )
fi

SRC_IMAGES=()
while IFS= read -r _line; do
    [ -n "${_line}" ] && SRC_IMAGES+=("${_line}")
done < <( _render_images "${EXTRA_CR_VALUES_ARG[@]}" "${_EXTRA_VALUES[@]}" )
[ "${#SRC_IMAGES[@]}" -gt 0 ] \
    || { err "chart 未渲染出任何镜像(helm template 失败? 手工确认: helm template ${RELEASE} ${CHART_TGZ} -n ${NS})"; exit 1; }
say "  chart 需要 ${#SRC_IMAGES[@]} 个镜像:"
for _img in "${SRC_IMAGES[@]}"; do say "    ${_img}"; done

# ---------------- [4/6] 推送镜像 → 集群内置 registry ----------------
# 目标 ref = 去注册域、保仓库路径(与 multus/lws 一致, 避免与其它组件撞名):
#   harbor.isuanova.com/suanova-private/cubestack-operator:latest
#     → <REG_BASE>/suanova-private/cubestack-operator:latest
say "[4/6] 推送镜像 → ${REG_BASE}/**(节点只从这个 registry 拉, 不访问 Harbor)..."
declare -a TARGET_REFS=()
for _img in "${SRC_IMAGES[@]}"; do
    _path="${_img#*/}"                                   # 去注册域(保 suanova-private/... 路径)
    _tag="${_path##*:}"
    _dst="docker://${REG_DIRECT}/${_path}"               # 推送用直连端点
    _dst_ref="${REG_BASE}/${_path}"                      # 写进 chart 的引用(节点用它拉)
    _d_dst="$(_digest "${_dst}")"

    _pushed=0
    # 源优先级: auto → ① Harbor(在线, 最新) ② 离线 tar ③ 本地 docker daemon; 也可显式指定
    _try=()
    case "${IMG_SRC_MODE}" in
        harbor) _try=( harbor ) ;;
        tar)    _try=( tar ) ;;
        docker) _try=( docker ) ;;
        auto)   if [ "${_MODE}" = "online" ]; then _try+=( harbor ); fi
                _try+=( tar docker ) ;;
        *) err "CUBESTACK_OPERATOR_IMAGE_SOURCE 仅支持 auto|harbor|tar|docker(当前=${IMG_SRC_MODE})"; exit 1 ;;
    esac

    _tar="$(find_offline_tar "/${_path}" "*$(basename "${_path%%:*}")*.tar" "${OFFLINE_DIR}" 2>/dev/null || true)"

    for _s in "${_try[@]}"; do
        _src_arg=""; _d_src=""
        case "${_s}" in
            harbor)
                _src_arg="docker://${_img}"
                # 私有无凭据且未登录时, inspect 会失败 → digest 空 → 直接尝试 copy(失败则换下一个源)
                _d_src="$(_digest "${_src_arg}")" ;;
            tar)
                [ -n "${_tar}" ] || continue
                _src_arg="docker-archive:${_tar}"
                _d_src="$(_digest "${_src_arg}")" ;;
            docker)
                _local="$(sudo docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -Fx "${_img}" | head -1 || true)"
                [ -n "${_local}" ] || continue
                _tmp_tar="/tmp/cubestack-operator-${_tag}-$$.tar"
                say "  从本地 docker daemon 导出: ${_local}"
                if sudo docker save "${_local}" -o "${_tmp_tar}" >/dev/null 2>&1; then
                    _src_arg="docker-archive:${_tmp_tar}"
                    _d_src="$(_digest "${_src_arg}")"
                else
                    rm -f "${_tmp_tar}"; continue
                fi ;;
        esac

        # 幂等: 目标已有同 digest → 跳过(rolling :latest 必须比 digest, 不能只看 tag 存在)
        if [ -n "${_d_dst}" ] && [ -n "${_d_src}" ] && [ "${_d_dst}" = "${_d_src}" ]; then
            ok "  ${_path} 内容未变(digest ${_d_dst:0:19}...), 跳过推送(源=${_s})"
            _pushed=1; break
        fi
        if push_image_skopeo "${_src_arg}" "${_dst}"; then
            _d_dst="$(_digest "${_dst}")"
            ok "  ${_path} 已推送(源=${_s}${_d_dst:+, digest ${_d_dst:0:19}...})"
            _pushed=1; break
        fi
        warn "  源 ${_s} 推送失败, 尝试下一个源..."
    done

    [ "${_pushed}" = "1" ] || {
        err "镜像推送失败: ${_img}"
        err "  可用源都不成立(Harbor 不可达/无凭据 + 本地无离线 tar + docker daemon 无该镜像)"
        err "  修法: ① 联网机生成离线 tar: sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group cubestack-operator"
        err "        ② 或配好 CUBESTACK_OPERATOR_HARBOR_USER/PASSWORD 后重跑(在线直拉)"
        err "        ③ 或把 ${_img} 手工 pull/save 到 ${OFFLINE_DIR}/"
        exit 1
    }
    TARGET_REFS+=("${_dst_ref}")
done
# 保存 operator 摘要, 避免组件循环覆盖 _d_dst。
_OPERATOR_DIGEST="${_d_dst}"

# ---------------- [4b/6] CR 平台组件镜像推送(仅 CR_ENABLED=true) ----------------
# 组件镜像集 = OFFLINE_DIR 下**全部离线 tar**(人工维护口径; 2026-10-08 起与 operator 镜像内
# assets/charts 的渲染对账而来, 清单与维护方法见 offline-files/cubestack-operator/README.md)。
# 目标映射(与 [3/6] 的 CR 两条前缀注入一一对应):
#   自研 harbor.isuanova.com/suanova/<name>:tag  → <REG>/suanova/<name>:tag (imageRegistry)
#   第三方 <上游ref>(docker.io/quay.io/ghcr.io…) → <REG>/mirrors/<上游ref> (externalImageRegistryPrefix)
# 幂等: digest 比对(同本体机制)。失败即 err —— CR 模式缺组件镜像=组件将 ImagePullBackOff。
if [ "${CR_ENABLED}" = "true" ]; then
    say "[4b/6] 推送平台组件镜像(CR 用; 源=离线 tar, 幂等 digest 比对)..."
    _n_push=0; _n_skip=0
    for _tarfile in "${OFFLINE_DIR}"/*.tar; do
        [ -f "${_tarfile}" ] || continue
        _tra="$(tar -xOf "${_tarfile}" manifest.json 2>/dev/null \
            | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["RepoTags"][0])' 2>/dev/null || true)"
        # ★ 目标 ref **以 tar 文件名为权威**(文件名 = 上游 ref 的 / 与 : 替换为 _ 的产物,
        #   与 CR 注入的镜像引用同源)。为什么不用 tar 内 RepoTags: 早期(09-23 时代)生成的
        #   tar RepoTags 可能是**短式**(如 envoyproxy/gateway, 缺 docker.io 域)⇒ 按它推会把
        #   镜像放到 <REG>/mirrors/envoyproxy/gateway, 而节点按 CR 引用拉
        #   <REG>/mirrors/docker.io/envoyproxy/gateway ⇒ not found(2026-10-08 实机踩到)。
        #   解析: <域>_<路径段…>_<tag> ⇒ 域/路径(段内 _ → /):tag; RepoTags 仅作**尾部校验**。
        _base="$(basename "${_tarfile}" .tar)"
        _domain="${_base%%_*}"
        _tag="${_base##*_}"
        _mid="${_base%_*}"; _mid="${_mid#*_}"
        _src_ref="${_domain}/$(printf '%s' "${_mid}" | tr '_' '/')${_tag:+:${_tag}}"
        if [ -n "${_tra}" ]; then
            case "${_tra}" in
                *"${_src_ref#*/}") : ;;   # RepoTags 尾部(去域)与文件名解析一致
                *) warn "  $(basename "${_tarfile}") 文件名解析(${_src_ref})与 RepoTags(${_tra})不符, 跳过"; continue ;;
            esac
        fi
        case "${_src_ref}" in
            "${HARBOR_HOST}"/suanova/*|"${HARBOR_HOST}"/mirrors/*) _dst_path="${_src_ref#${HARBOR_HOST}/}" ;;
            *) _dst_path="mirrors/${_src_ref}" ;;
        esac
        _dst="docker://${REG_DIRECT}/${_dst_path}"
        _d_dst="$(_digest "${_dst}")"
        _d_src="$(_digest "docker-archive:${_tarfile}")"
        if [ -n "${_d_dst}" ] && [ "${_d_dst}" = "${_d_src}" ]; then
            _n_skip=$((_n_skip + 1)); continue
        fi
        if push_image_skopeo "docker-archive:${_tarfile}" "${_dst}"; then
            _n_push=$((_n_push + 1))
        else
            err "组件镜像推送失败: ${_src_ref}(源=$(basename "${_tarfile}"))"
            err "  → 检查 registry 可达/磁盘空间; 重跑本模块会自动续推(已推送的按 digest 跳过)"
            exit 1
        fi
    done
    ok "  组件镜像就绪: 新推 ${_n_push} 个, digest 相同跳过 ${_n_skip} 个"
fi

# ---------------- [5/6] CRD 预应用(helm 的 crds/ 只在"CRD 不存在"时装) ----------------
# README 明确: 已装过 operator 的集群升级前必须先 apply 新 CRD, 否则旧 CRD 会剪掉新字段。
# 幂等无副作用(SSA), 故每次部署都跑 —— 不依赖 helm 的"仅首次安装"语义。
say "[5/6] 应用 chart 内的 CRD(crds/ 目录)..."
_WORK="$(mktemp -d)"
trap '_cleanup; rm -rf "${_WORK}"' EXIT
tar -xzf "${CHART_TGZ}" -C "${_WORK}"
CRD_DIR="$(find "${_WORK}" -maxdepth 2 -type d -name crds | head -1 || true)"
if [ -n "${CRD_DIR}" ] && ls "${CRD_DIR}"/*.yaml >/dev/null 2>&1; then
    for _crd in "${CRD_DIR}"/*.yaml; do
        if cat "${_crd}" | SSH "${K} apply --server-side --force-conflicts -f -" >/dev/null 2>&1; then
            ok "  CRD 已应用: $(basename "${_crd}")"
        else
            err "CRD apply 失败: $(basename "${_crd}")(手工确认: kubectl apply --server-side -f <chart>/crds/)"; exit 1
        fi
    done
else
    warn "  chart 内未找到 crds/ 目录(跳过; 若 operator 依赖 CRD 请检查 chart 结构)"
fi

# ---------------- [6/6] helm upgrade --install(本地 chart + 集群 registry 镜像) ----------------
say "[6/6] helm upgrade --install(本地 chart; 镜像走集群 registry)..."
IMG_REPO_OVERRIDE="${TARGET_REFS[0]%:*}"     # <REG_BASE>/suanova-private/cubestack-operator
IMG_TAG_OVERRIDE="${TARGET_REFS[0]##*:}"
_SET_ARGS=(
    --set "image.repository=${IMG_REPO_OVERRIDE}"
    --set "image.tag=${IMG_TAG_OVERRIDE}"
    --set "image.pullPolicy=${IMG_PULL_POLICY}"
)
# 滚动 tag 的"节点缓存冻结"防护: 把镜像 digest 写进 podAnnotations —— digest 变了模板就变,
# helm 才会滚动新 pod; 否则 Deployment spec 原封不动, 新镜像永远不会被拉起来(见文件头说明)。
if [ "${PIN_DIGEST}" = "true" ] && [[ "${_OPERATOR_DIGEST}" =~ ^sha256:[[:xdigit:]]{64}$ ]]; then
    _SET_ARGS+=( --set "podAnnotations.cubestack\\.io/image-digest=${_OPERATOR_DIGEST}" )
fi

# 渲染自检: 覆盖后的镜像必须**全部**落在集群 registry 下 —— chart 以后新增第 2 个镜像时,
# 这里会响亮失败(而不是静默从 Harbor 拉, 让离线集群 ImagePullBackOff)。
FINAL_IMAGES=()
while IFS= read -r _line; do
    [ -n "${_line}" ] && FINAL_IMAGES+=("${_line}")
done < <( _render_images "${_SET_ARGS[@]}" "${EXTRA_CR_VALUES_ARG[@]}" "${_EXTRA_VALUES[@]}" )
for _img in "${FINAL_IMAGES[@]}"; do
    case "${_img}" in
        "${REG_BASE}/"*) : ;;
        *) err "渲染后仍有镜像不在集群 registry 下: ${_img}"
           err "  → chart 可能新增了镜像; 请在本模块补 --set 覆盖(并登记 images.manifest)"
           exit 1 ;;
    esac
done
ok "  渲染自检通过: ${#FINAL_IMAGES[@]} 个镜像全部指向 ${REG_BASE}"

if [ "${CR_ENABLED}" = "true" ]; then
    say "  clusterCR.enabled=true: 平台组件镜像已由 [4b/6] 推入集群 registry, 且 CR 全局镜像源"
    say "    已注入 ${REG_BASE}(自研→/suanova, 第三方→/mirrors)—— 节点不访问 Harbor。"
    say "    默认裁剪: 模型 bundles 清空 + modelBundles/bmc 关闭(开启方法见 docs/cubestack-operator.md)。"
    [ -f "${OFFLINE_DIR}/docker.io_envoyproxy_ratelimit_8fe6ea42.tar" ] \
        || warn "    已知缺口: docker.io/envoyproxy/ratelimit:8fe6ea42 未备料(本网络到 docker.io 不通) —— 默认不拉起(仅配 RateLimitPolicy 时用); 补料: 在可访问 docker.io 的机器 pull 后放入 ${OFFLINE_DIR}/"
fi

helm upgrade --install "${RELEASE}" "${CHART_TGZ}" \
    --namespace "${NS}" --create-namespace \
    "${_SET_ARGS[@]}" "${EXTRA_CR_VALUES_ARG[@]}" "${_EXTRA_VALUES[@]}" \
    --wait --timeout 300s \
    || warn "  helm 安装/等待超时(资源可能已创建, 继续等待 Deployment; 排查: helm status ${RELEASE} -n ${NS})"

# 等 operator 就绪(名字 = release 名; 用户改了 release 名时回退 <release>-cubestack-operator)
SSH "${K} -n ${NS} rollout status deployment/${RELEASE} --timeout=180s" >/dev/null 2>&1 \
    || SSH "${K} -n ${NS} rollout status deployment/${RELEASE}-cubestack-operator --timeout=180s" >/dev/null 2>&1 \
    || warn "  operator Deployment 未在 180s 内就绪(继续汇总; 端到端验证会给出确切状态)"

echo "---------------------------------------------"
( SSH "${K} -n ${NS} get pods,deploy -o wide 2>/dev/null" || true ) | sed 's/^/    /'
echo "---------------------------------------------"
ok "CubeStack Operator 部署完成"
echo "  release:      ${RELEASE}(namespace ${NS})"
echo "  chart:        $(basename "${CHART_TGZ}")(sync=${SYNC_MODE}→${_MODE})"
echo "  镜像:         ${IMG_REPO_OVERRIDE}:${IMG_TAG_OVERRIDE}(pullPolicy=${IMG_PULL_POLICY})"
echo "  集群 registry: ${REG_BASE}(镜像已推入; 节点从这里拉, 不访问 Harbor)"
echo "  平台实例 CR:  clusterCR.enabled=${CR_ENABLED}(改 cluster.conf CUBESTACK_OPERATOR_CLUSTER_CR_ENABLED)"
echo "  端到端验证:   sudo ./deploy-cluster.sh --steps verify_cubestack_operator"
echo "  状态查看:     kubectl get csc -n ${NS}"
