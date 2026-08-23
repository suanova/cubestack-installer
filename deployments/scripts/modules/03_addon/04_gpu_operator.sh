#!/bin/bash
# ============================================================
# MODULE: gpu_operator
# DESC: 部署沐曦 MetaX GPU Operator(镜像推送 + Helm 离线渲染安装 + GPU 资源验证)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: GPU_OPERATOR_ENABLED
# 说明:
#   · 断点续跑: REPEAT:0 → 安装成功写入状态, 重跑部署自动跳过(不重复重装); --fresh 清状态后重装。
#     (幂等的就绪检查类模块(metallb/local_path/k8s_registry)用 REPEAT:1 每次执行)
#   · 版本不硬编码: 全部版本/路径由 cluster.conf METAX_* 配置派生, 升级只改 METAX_VERSION。
#   · 镜像加载两种方式(METAX_IMAGE_MODE, 默认 auto):
#       run = 用包内 metax-k8s-images.<ver>.run 内嵌镜像直接 push(无需预存 tar, 离线可用;
#             本机容器运行时用 ctr, 支持 --plain-http 免 daemon 配置)
#       tar = 从 METAX_OFFLINE_DIR(默认 offline-files/metax-gpu)加载离线 tar 逐镜像 skopeo
#             推送到集群内置 registry(需先用 tools/images/metax-save-images.sh 在联网机生成 tar)
#   · 镜像目标: 集群内置 registry 的 METAX_REGISTRY(默认 registry.local:5000/metax);
#     模块自动把宿主机 /etc/hosts 的 registry.local/k8s-api 解析到正确 IP(registry VIP / API 入口,
#     不留 10.66.3.37 这类过期条目), 宿主机即可按域名 push 与 helm 连集群(外部机器同理改 /etc/hosts)。
#   · METAX_LIST_IMAGES=true 可仅打印所需镜像的 docker pull+save 命令(离线 tar 预置清单), 不部署。
#   · MACA SDK 与内核驱动镜像不在资源包内: 优先本地 docker / METAX_OFFLINE_DIR 离线 tar,
#     否则尝试在线从 cr.metax-tech.com 拉取推送(best-effort, 缺省仅 warn 不阻塞)。
#   · 安装: 修复官方 chart 的已知 bug(deployment 缺 namespace / openshift.deploy 默认 false)后
#     用 helm upgrade --install 原生安装(helm 自动装 CRD + 命名空间); 每次重部署先清理残留
#     (CR/CRD/命名空间/default 旧资源) → 等 operator DS/Pods 就绪 → 验证 metax-tech.com/gpu allocatable。
#   · master 节点: 用 mx-smi 在宿主机检测 GPU 卡; 检测到 GPU 的 master 自动移除 control-plane 污点并
#     uncordon(使其可调度, 供 PD 分离等 pod 使用); 无 GPU 的 master 保持默认不可调度。
#   · 验证: tools/k8s/verify-metax-gpu.sh 或 --steps verify_metax_gpu(列各节点 GPU 清单/汇总)。
#   · 参考: Kubernetes 沐曦GPU Operator部署文档(metax-gpu-k8s 0.15.3, MXMACA 3.7.0.7)
# 数据源: cluster.conf (GPU_OPERATOR_ENABLED / METAX_* / REGISTRY_* / NODES / SSH_KEY_NAME)
# 用法:   sudo ./deploy-cluster.sh --enable gpu_operator  或  GPU_OPERATOR_ENABLED=true
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# ---------------- 镜像列表模式(METAX_LIST_IMAGES=true 仅打印离线 save 清单, 不部署) ----------------
# 离线 tar 方式需在联网机器 pull+save 到 METAX_OFFLINE_DIR, 本模式打印所需镜像与保存命令。
if [ "${METAX_LIST_IMAGES:-false}" = "true" ]; then
    _save_cmd() {
        local img="$1" fname
        fname="$(echo "${img}" | sed 's#/#_#g; s#:#_#g').tar"
        echo "  docker pull ${img}"
        echo "  docker save ${img} -o ${METAX_OFFLINE_DIR}/${fname}"
    }
    echo "=============================================="
    echo "沐曦 GPU Operator 所需镜像(版本 v${METAX_VERSION}, 目标仓库 ${METAX_REGISTRY})"
    echo "  核心组件(内嵌于 metax-k8s-images.${METAX_VERSION}.run, run 方式无需手动 save; tar 方式用 .run dump 生成):"
    for c in ${METAX_IMAGE_COMPONENTS}; do
        echo "    cr.metax-tech.com/cloud/${c}:${METAX_VERSION}"
    done
    echo "  MXMACA SDK(不在资源包, 需手动 pull+save):"
    _save_cmd "cr.metax-tech.com/public-library/${METAX_MACA_IMAGE}"
    echo "  内核驱动(不在资源包, 需手动 pull+save; 或 METAX_DRIVER_DEPLOY_POLICY=PreferHost 用宿主机驱动免该镜像):"
    _save_cmd "cr.metax-tech.com/public-cloud-release/driver-image:${METAX_DRIVER_VERSION}"
    echo "=============================================="
    echo "  说明: save 的 tar 放入 METAX_OFFLINE_DIR=${METAX_OFFLINE_DIR}(可用 tools/images/metax-save-images.sh 一键生成), tar 模式按 METAX_TAR_PATTERN=${METAX_TAR_PATTERN} 自动推送"
    exit 0
fi

# ---- 开关 ----
[ "${GPU_OPERATOR_ENABLED:-false}" = "true" ] || { say "GPU_OPERATOR_ENABLED=false, 跳过沐曦 GPU Operator"; exit 0; }

FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
SSH() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
           "${SSH_USER:-ubuntu}@${FIRST_MASTER}" "$@"; }
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

# ---------------- 派生变量(全部来自 cluster.conf, 无硬编码) ----------------
PKG_TGZ="${METAX_PKG_DIR}/${METAX_PKG_TGZ}"
RUN_TOOL="${METAX_PKG_DIR}/metax-k8s-images.${METAX_VERSION}.run"
CHART_TGZ="${METAX_PKG_DIR}/metax-operator-${METAX_VERSION}.tgz"
CHART_DIR="${METAX_CHART_DIR:-${METAX_PKG_DIR}/metax-operator}"   # 修复后的 chart 目录(直接 helm 安装, 不重新解包)
WORK_DIR="${METAX_PKG_DIR}/_work"
RENDER_YAML="${WORK_DIR}/metax-render.yaml"
REGISTRY_BASE="${REGISTRY_DOMAIN}:${REGISTRY_PORT}"    # 集群内置 registry(registry.local:5000, 节点/chart/宿主统一用域名)
# 推送到集群 registry 用 MetalLB VIP 直连(绕开宿主 DNAT 转发, 大镜像/大 blob 传输更稳, 避免 broken pipe)
PUSH_REGISTRY="${REGISTRY_IP}:${REGISTRY_PORT}/metax"
# 大 blob 上传加重试(transient broken pipe 自愈)
_SKOPEO_RETRY=("--retry-times=3")

# ---------------- 前置检查 ----------------
say "检查沐曦 GPU Operator 前置条件..."
[ -d "${CHART_DIR}" ] || { err "修复后的 helm chart 目录不存在: ${CHART_DIR}(应放在 deployments/metax-gpu-operator/metax-operator)"; exit 1; }
[ -f "${PKG_TGZ}" ] || warn "未找到资源包 ${PKG_TGZ}(tar 模式不需要; run 模式需 metax-k8s-images.*.run 在 METAX_PKG_DIR)"
command -v helm >/dev/null 2>&1 || { err "未找到 helm(需 3.0+); 请先安装 Helm"; exit 1; }
command -v skopeo >/dev/null 2>&1 || { warn "未找到 skopeo(tar 模式推送将不可用)"; }
# 宿主机 /etc/hosts 每次部署统一更新为正确 IP(不允许遗留 10.66.3.37 等过期条目):
#   REGISTRY_DOMAIN → REGISTRY_IP(集群内置 registry VIP, 供宿主按域名 push)
#   API_DOMAIN      → API_IP(API Server 入口, 供宿主 helm/kubectl 连集群)
_ensure_hosts() {   # <ip> <domain>: 删除该域名的旧行再写入正确 IP(幂等)
    local ip="$1" dom="$2" re
    [ -n "${ip}" ] && [ -n "${dom}" ] || return 0
    re="$(echo "${dom}" | sed 's/\./\\./g')"
    sed -i -E "/[[:space:]]${re}([[:space:]]|$)/d" /etc/hosts 2>/dev/null || true
    grep -qE "^${ip}[[:space:]]+${dom}([[:space:]]|$)" /etc/hosts 2>/dev/null \
        || echo "${ip} ${dom}" >> /etc/hosts 2>/dev/null
}
_ensure_hosts "${REGISTRY_IP}" "${REGISTRY_DOMAIN}"
_ensure_hosts "${API_IP}" "${API_DOMAIN}"
grep -qE "^${REGISTRY_IP}[[:space:]]+${REGISTRY_DOMAIN}" /etc/hosts 2>/dev/null \
    || warn "无法写入宿主机 /etc/hosts(非 root?), ${REGISTRY_DOMAIN}/${API_DOMAIN} 可能无法从宿主按域名访问"
curl -s -m 8 "http://${REGISTRY_BASE}/v2/" >/dev/null 2>&1 \
    || { err "集群内置 registry ${REGISTRY_BASE}/v2/ 不可达(检查: 宿主机 /etc/hosts 的 ${REGISTRY_DOMAIN} 是否解析到 ${REGISTRY_IP}, 及 MetalLB VIP)"; exit 1; }
SSH "${K} get nodes --no-headers >/dev/null 2>&1" \
    || { err "无法访问集群(${FIRST_MASTER}); 检查 kubectl/集群状态"; exit 1; }
# helm 需要从宿主连 API Server: 下载集群 admin.conf 并同步到 ~/.kube/config
# (每次部署后执行, 确保安装机 kubectl/helm 可访问集群; 合并而非覆盖, 避免破坏其他集群配置)
_sync_kubeconfig() {
    local tmp newctx
    tmp="$(mktemp)"
    # admin.conf 属 root(600), scp 会 Permission denied → 用 ssh + sudo cat 读取
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
        "${SSH_USER:-ubuntu}@${FIRST_MASTER}" "sudo cat /etc/kubernetes/admin.conf" > "${tmp}" 2>/dev/null \
        || { rm -f "${tmp}"; return 1; }
    [ -s "${tmp}" ] || { rm -f "${tmp}"; return 1; }
    mkdir -p "${HOME}/.kube"
    newctx="$(grep -E '^[[:space:]]*current-context:' "${tmp}" | head -1 | awk '{print $2}')"
    if [ -f "${HOME}/.kube/config" ]; then
        # 合并(新 admin.conf 在前, 同名校则新集群优先); 合并失败则直接覆盖
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
    && ok "宿主机 ~/.kube/config 已同步(admin.conf → API ${API_DOMAIN}→${API_IP})" \
    || { err "宿主机无法访问集群(admin.conf 下载/同步失败; 检查 ${FIRST_MASTER} 的 /etc/kubernetes/admin.conf, 以及 ${API_DOMAIN}→${API_IP} 解析)"; exit 1; }
ok "前置检查通过(registry=${REGISTRY_BASE}, API=${API_DOMAIN}→${API_IP})"

# ---------------- 1. 确认资源(修复后的 chart + 镜像加载源) ----------------
say "[1/5] 确认资源: 修复后的 helm chart + 镜像加载源 ..."
[ -f "${CHART_DIR}/Chart.yaml" ] || { err "修复后的 helm chart 不存在: ${CHART_DIR}(应放在 deployments/metax-gpu-operator/metax-operator)"; exit 1; }
mkdir -p "${WORK_DIR}"
[ -x "${RUN_TOOL}" ] || warn "未找到 ${RUN_TOOL}(tar 模式不需要; run 模式需在 METAX_PKG_DIR 放置 metax-k8s-images.*.run)"

# 修复官方 chart 的已知 bug(幂等; 修正后 helm install 才正确):
#   ① deployment 模板缺显式 namespace → 补 .Release.Namespace
#   ② clusteroperator 模板 openshift.deploy 无默认 → 默认 false(否则 CRD 要求 spec.openshift 有值而渲染为空)
#   ③ vendor.config 的 domain/charDev/driver/virtDriver 未加 | quote → 空值时渲染 null, CRD 要求 string
_patch_chart() {
    local d="${CHART_DIR}" ok=1
    grep -q 'namespace: {{ .Release.Namespace }}' "${d}/templates/deployment.yaml" 2>/dev/null \
        || sed -i '/^  name: {{ include "metax-operator.fullname" . }}$/a\  namespace: {{ .Release.Namespace }}' "${d}/templates/deployment.yaml" \
        || ok=0
    grep -q 'default false (.Values.openshift).deploy' "${d}/templates/clusteroperator.yaml" 2>/dev/null \
        || python3 - "${d}/templates/clusteroperator.yaml" << 'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
old = re.compile(r'\n  openshift:\n    \{\{- if \(hasKey \.Values\.openshift "deploy"\) \}\}\n    deploy:.*?\n    \{\{- end \}\}', re.S)
s = old.sub('\n  openshift:\n    deploy: {{ (default false (.Values.openshift).deploy) }}', s)
open(p, 'w').write(s)
PY
    grep -q 'default false (.Values.openshift).deploy' "${d}/templates/clusteroperator.yaml" 2>/dev/null || ok=0
    # ③ vendor 字段空值加 | quote(避免渲染 null)
    grep -q 'domain: {{ \$vendorConfig.domain | quote }}' "${d}/templates/_helpers.tpl" 2>/dev/null \
        || python3 - "${d}/templates/_helpers.tpl" << 'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
for k in ('domain', 'charDev', 'driver', 'virtDriver'):
    s = s.replace('{0}: {{ $vendorConfig.{0} }}\n'.format(k), '{0}: {{ $vendorConfig.{0} | quote }}\n'.format(k))
open(p, 'w').write(s)
PY
    grep -q 'domain: {{ \$vendorConfig.domain | quote }}' "${d}/templates/_helpers.tpl" 2>/dev/null || ok=0
    [ "${ok}" = "1" ] && say "  chart 已修复(namespace / openshift.deploy=false / vendor 引号)" \
                     || warn "  chart 修复可能未完全生效, 请检查 ${d}/templates"
}
# chart 为修复版(metax-gpu-operator/metax-operator), 幂等补丁兜底(重新解包/未修复场景自动修复)
_patch_chart
ok "资源就绪: chart=${CHART_DIR}(已修复) + 镜像加载方式=${METAX_IMAGE_MODE:-tar}"

# ---------------- 2. 镜像推送 ----------------
# 模式判定(auto: 有 .run 用 run, 否则 tar)
_MODE="${METAX_IMAGE_MODE:-auto}"
[ "${_MODE}" = "auto" ] && { [ -x "${RUN_TOOL}" ] && _MODE="run" || _MODE="tar"; }
say "[2/5] 推送沐曦镜像 → ${METAX_REGISTRY}(方式: ${_MODE}) ..."

_PUSHED=0
if [ "${_MODE}" = "run" ]; then
    # run 方式: .run 把内嵌镜像 load 进宿主 ctr(离线), 再逐组件打标推送到 ${METAX_REGISTRY}(域名, 宿主 /etc/hosts 已解析到 VIP)。
    # 注: 不用 .run 自带的 push(其 --plain-http 置于镜像 ref 之后, 新版 ctr 会当作镜像名报错),
    #     由本脚本 tag + ctr push --plain-http(flag 在前)完成。
    say "  用 .run 加载内嵌镜像到宿主 ctr ..."
    ( cd "${METAX_PKG_DIR}" && "${RUN_TOOL}" ctr load ) \
        || { err "metax-k8s-images load 失败(检查宿主机 containerd 是否运行)"; exit 1; }
    ARCH="$(uname -m)"; case "${ARCH}" in x86_64|amd64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; *) ARCH=amd64;; esac
    say "  逐组件推送(arch=${ARCH}, 目标=${METAX_REGISTRY}) ..."
    while IFS= read -r _img; do
        [ -n "${_img}" ] || continue
        case "${_img}" in
            cr.metax-tech.com/cloud/*:${METAX_VERSION}-${ARCH})
                _comp="${_img#cr.metax-tech.com/cloud/}"; _comp="${_comp%:${METAX_VERSION}-${ARCH}}"
                _dst="${PUSH_REGISTRY}/${_comp}:${METAX_VERSION}"
                sudo ctr -n k8s.io images tag "${_img}" "${_dst}" >/dev/null 2>&1 || true
                sudo ctr -n k8s.io images push --plain-http "${_dst}" >/dev/null 2>&1 \
                    || { err "推送失败 ${_dst}(检查: 宿主机能否达 ${REGISTRY_BASE}、registry 磁盘空间)"; exit 1; }
                ok "  ${_comp}:${METAX_VERSION} ✓"
                _PUSHED=$((_PUSHED+1))
                ;;
        esac
    done < <(sudo ctr -n k8s.io images ls -q 2>/dev/null | grep 'cr.metax-tech.com/cloud/' || true)
    [ "${_PUSHED}" -gt 0 ] || { err "ctr 中未找到 cr.metax-tech.com/cloud/*:${METAX_VERSION}-${ARCH} 镜像(.run load 未生效?)"; exit 1; }
else
    # tar 方式: 从 METAX_OFFLINE_DIR(优先)/METAX_IMAGE_DIR 找匹配 tar, 逐镜像 skopeo 推送到集群内置 registry
    ARCH="$(uname -m)"; case "${ARCH}" in x86_64|amd64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; *) ARCH=amd64;; esac
    shopt -s nullglob
    _TARS=("${METAX_OFFLINE_DIR}"/*.tar "${METAX_IMAGE_DIR}"/*.tar)
    shopt -u nullglob
    for t in "${_TARS[@]:-}"; do
        [ -f "${t}" ] || continue
        case "$(basename "${t}")" in *"${METAX_TAR_PATTERN}"*) ;; *) continue ;; esac
        src="$(tar_first_image_tag "${t}")"
        [ -n "${src}" ] || { warn "  跳过 $(basename "${t}"): 无法读取源镜像名(manifest.json)"; continue; }
        comp="${src%%:*}"; comp="${comp##*/}"     # .../cloud/gpu-label → gpu-label
        ver="${src##*:}"
        # 只推当前 gpu operator 需要的版本: maca/driver 只推配置版本, 核心组件只推本机架构的 METAX_VERSION
        case "${comp}" in
            maca)
                [ "${ver}" = "${METAX_MACA_IMAGE#*:}" ] || { say "  跳过非当前所需 ${comp}:${ver}"; continue; }
                ;;
            driver-image)
                [ "${ver}" = "${METAX_DRIVER_VERSION}" ] || { say "  跳过非当前所需 ${comp}:${ver}"; continue; }
                ;;
            *)
                case "${ver}" in
                    ${METAX_VERSION}-${ARCH}|${METAX_VERSION}) ;;
                    *) say "  跳过非当前所需 ${comp}:${ver}"; continue ;;
                esac
                ;;
        esac
        # 核心组件镜像带架构后缀(如 0.15.3-amd64 / 0.15.3-arm64): 单 arch 集群只推本机架构, 并去掉后缀
        # (chart 引用的是无后缀 ref: metax/gpu-label:0.15.3); maca/driver 的版本后缀是 tag 一部分, 不处理。
        case "${ver}" in
            ${METAX_VERSION}-amd64|${METAX_VERSION}-arm64)
                _arch="${ver##*-}"
                [ "${_arch}" = "${ARCH}" ] || { say "  跳过非本机架构 ${comp}:${ver}"; continue; }
                ver="${METAX_VERSION}"
                ;;
        esac
        say "  推 ${comp}:${ver} ← $(basename "${t}")"
        skopeo copy --quiet --retry-times=3 --dest-tls-verify=false --dest-no-creds \
            "docker-archive:${t}" "docker://${PUSH_REGISTRY}/${comp}:${ver}" \
            || { err "推送失败 ${t} → ${PUSH_REGISTRY}/${comp}:${ver}"; exit 1; }
        _PUSHED=$((_PUSHED+1))
    done
    [ "${_PUSHED}" -gt 0 ] || { err "METAX_OFFLINE_DIR=${METAX_OFFLINE_DIR} / METAX_IMAGE_DIR=${METAX_IMAGE_DIR} 未找到匹配 ${METAX_TAR_PATTERN} 的 tar(可用 metax-save-images.sh 生成, 或改 METAX_TAR_PATTERN)"; exit 1; }
fi

# MACA + 驱动镜像(不在 .run 包内): registry 已有 → 本地 docker → 离线 tar → 在线, 逐级尝试
push_extra() {   # <comp> <源镜像>  (如 maca cr.metax-tech.com/public-library/maca:<tag>)
    local comp="$1" src="$2" t found="" docker_src=""
    # ⓪ registry 已有该 tag → 跳过(避免重复推送大镜像)
    if curl -s -m 6 "http://${REGISTRY_BASE}/v2/${comp}/tags/list" 2>/dev/null | grep -q "\"${src##*:}\""; then
        ok "  ${comp}:${src##*:} 已在 registry, 跳过"; return 0
    fi
    # ① 本地 docker daemon 已有该镜像(按 名字:tag 匹配任意 registry 前缀)
    #    → docker save 成临时 tar + skopeo docker-archive 推送(注: skopeo docker-daemon 传输在此 docker 上 API 版本过旧不可用)
    docker_src="$(sudo docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E "/${comp}:${src##*:}$" | head -1 || true)"
    if [ -n "${docker_src}" ]; then
        _tmp="/tmp/metax-${comp}-${src##*:}.tar"
        say "  推 ${comp}:${src##*:} ← 本地 docker(${docker_src})"
        if sudo docker save "${docker_src}" -o "${_tmp}" >/dev/null 2>&1 \
           && sudo skopeo copy --quiet --retry-times=3 --dest-tls-verify=false --dest-no-creds \
               "docker-archive:${_tmp}" "docker://${PUSH_REGISTRY}/${comp}:${src##*:}" >/dev/null 2>&1; then
            rm -f "${_tmp}"
            ok "  ${comp} 已就绪(本地 docker)"; return 0
        fi
        rm -f "${_tmp}"
        warn "  ${comp} docker 推送失败, 尝试 tar/在线..."
    fi
    # ② 离线 tar(METAX_OFFLINE_DIR + METAX_IMAGE_DIR)
    for _td in "${METAX_OFFLINE_DIR}" "${METAX_IMAGE_DIR}"; do
        [ -d "${_td}" ] || continue
        for t in "${_td}"/*.tar; do
            [ -f "${t}" ] || continue
            case "$(basename "${t}")" in *"${comp}"*) found="${t}"; break ;; esac
        done
        [ -n "${found}" ] && break
    done
    if [ -n "${found}" ]; then
        say "  推 ${comp} ← $(basename "${found}")"
        skopeo copy --quiet --retry-times=3 --dest-tls-verify=false --dest-no-creds \
            "docker-archive:${found}" "docker://${PUSH_REGISTRY}/${comp}:${src##*:}" \
            && { ok "  ${comp} 已就绪(离线 tar)"; return 0; }
        warn "  ${comp} tar 推送失败, 尝试在线..."
    fi
    # ③ 在线 skopeo(需 cr.metax-tech.com 可访问/有凭据)
    if [ "${_MODE}" = "run" ]; then
        say "  尝试在线拉取推送 ${src} → ${PUSH_REGISTRY}/${comp}:${src##*:}"
        if skopeo copy --quiet --retry-times=3 --src-tls-verify=false --dest-tls-verify=false --dest-no-creds \
            "docker://${src}" "docker://${PUSH_REGISTRY}/${comp}:${src##*:}" 2>/dev/null; then
            ok "  ${comp} 已在线就绪"; return 0
        fi
    fi
    warn "  ${comp} 镜像未就绪(本地 docker/tar 均无且在线不可达)。请先 docker pull ${src} 或放离线 tar 到 ${METAX_IMAGE_DIR}"
    return 0
}
push_extra "maca" "cr.metax-tech.com/public-library/${METAX_MACA_IMAGE}"
push_extra "driver-image" "cr.metax-tech.com/public-cloud-release/driver-image:${METAX_DRIVER_VERSION}"
# 兼容独立驱动包 metax-k8s-driver-image.*.run
DRV_RUN="$(ls "${METAX_PKG_DIR}"/metax-k8s-driver-image*.run 2>/dev/null | head -1 || true)"
if [ -n "${DRV_RUN}" ] && [ "${_MODE}" = "run" ]; then
    say "  发现驱动包 ${DRV_RUN}, 执行 push ..."
    ( cd "${METAX_PKG_DIR}" && "${DRV_RUN}" ctr push "${METAX_REGISTRY}" -- --plain-http ) 2>/dev/null \
        && ok "  驱动包镜像已推送" || warn "  驱动包推送失败(忽略, 可改 METAX_DRIVER_DEPLOY_POLICY=PreferHost 用宿主机驱动)"
fi
ok "镜像推送完成(共推送 ${_PUSHED} 个组件镜像 → ${METAX_REGISTRY})"

# ---------------- 3. 获取集群版本 ----------------
say "[3/5] 获取集群版本 + 准备 helm 安装 ..."
K8S_VERSION="$(SSH "${K} version -o json" 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["serverVersion"]["gitVersion"])
except Exception: pass' || true)"
[ -n "${K8S_VERSION}" ] || K8S_VERSION="v1.28.0"

# ---------------- 4. helm 原生安装(取代 kubectl apply) ----------------
say "[4/5] helm 安装 ${METAX_RELEASE_NAME} → ${METAX_NAMESPACE}(registry=${METAX_REGISTRY}, k8s=${K8S_VERSION}) ..."
# 先清理上次部署的残留(CR/CRD/命名空间/default 旧资源), 避免 operator 状态/CRD 冲突导致异常
say "  清理上次残留(CR / CRD / ${METAX_NAMESPACE} 命名空间 / default 旧资源)..."
SSH "${K} delete clusteroperator -n ${METAX_NAMESPACE} cluster-operator --ignore-not-found >/dev/null 2>&1" || true
SSH "${K} delete crd clusteroperators.gpu.metax-tech.com --ignore-not-found >/dev/null 2>&1" || true
SSH "${K} patch ns ${METAX_NAMESPACE} --type=merge -p '{\"metadata\":{\"finalizers\":null}}' >/dev/null 2>&1" || true
SSH "${K} delete ns ${METAX_NAMESPACE} --ignore-not-found --force --grace-period=0 >/dev/null 2>&1" || true
# 清理集群级残留(ClusterRole/RoleBinding 无命名空间资源; 无 Helm 标签时 helm 无法接管 → 必须删掉)
for _cr in $(SSH "${K} get clusterrole -o name 2>/dev/null" | grep -i 'metax' || true); do
    SSH "${K} delete ${_cr} --ignore-not-found >/dev/null 2>&1" || true
done
for _crb in $(SSH "${K} get clusterrolebinding -o name 2>/dev/null" | grep -i 'metax' || true); do
    SSH "${K} delete ${_crb} --ignore-not-found >/dev/null 2>&1" || true
done
for _res in "deployment ${METAX_RELEASE_NAME}-metax-operator" "job metax-pre-delete" \
            "service controller-manager-metrics-service" "service upgrade-webhook-service" \
            "serviceaccount metax-operator" "serviceaccount metax-gpu-scheduler" \
            "serviceaccount metax-maca" "serviceaccount metax-pre-delete" \
            "configmap metax-pre-delete-configmap"; do
    SSH "${K} delete ${_res} -n default --ignore-not-found >/dev/null 2>&1" || true
done
SSH "${K} delete clusterrolebinding metax-operator-rolebinding metax-gpu-scheduler --ignore-not-found >/dev/null 2>&1" || true
sleep 3
# 说明: 使用修复过的 chart(已补 deployment namespace + openshift.deploy=false);
# helm 自动安装 crds/ 目录的 CRD、自动把资源放进 release 命名空间(不再需要手工 CRD/kubectl apply)。
helm upgrade --install "${METAX_RELEASE_NAME}" "${CHART_DIR}" \
    --namespace "${METAX_NAMESPACE}" --create-namespace \
    --set "registry=${METAX_REGISTRY}" \
    --set "cluster.type=${METAX_CLUSTER_TYPE}" \
    --set "cluster.version=${K8S_VERSION}" \
    --set "driver.deployPolicy=${METAX_DRIVER_DEPLOY_POLICY}" \
    --set "driver.payload.version=${METAX_DRIVER_VERSION}" \
    --set "maca.payload.registry=${METAX_REGISTRY}" \
    --set "maca.payload.images[0]=${METAX_MACA_IMAGE}" \
    --set "vendor.vendorID=" --set "vendor.driver=" --set "vendor.domain=" \
    --set "vendor.charDev=" --set "vendor.virtDriver=" \
    --wait --timeout 300s \
    || warn "  helm 安装/等待超时(检查 --set 与 chart; 资源可能已创建, 继续等待 DS)..."

# ---------------- 5. 等待就绪 + 验证 ----------------
say "[5/5] 等待 GPU Operator 组件就绪(最长 300s)..."
SSH "${K} rollout status deployment -n ${METAX_NAMESPACE} ${METAX_RELEASE_NAME}-metax-operator --timeout=120s" >/dev/null 2>&1 \
    || warn "  operator deployment rollout 未在 120s 内完成(继续等待 DS)..."
DS_READY=0; DS_TOTAL=0
for _i in $(seq 1 60); do
    # ⚠ (SSH ... || true) 必须加括号: `A || true | awk` 会被解析为 A || (true|awk), awk 收不到 SSH 输出
    DS_READY="$( (SSH "${K} -n ${METAX_NAMESPACE} get ds --no-headers 2>/dev/null" || true) | awk '$2==$4 && $2>0 {n++} END{print n+0}' )"
    DS_TOTAL="$( (SSH "${K} -n ${METAX_NAMESPACE} get ds --no-headers 2>/dev/null" || true) | wc -l )"
    [ "${DS_TOTAL:-0}" -ge 1 ] && [ "${DS_READY:-0}" -ge "${DS_TOTAL:-0}" ] && [ "${DS_READY:-0}" -ge 1 ] && break
    sleep 5
done
[ "${DS_TOTAL}" -ge 1 ] || { err "metax-operator 命名空间无 DaemonSet(检查 apply 结果与 operator 日志)"; exit 1; }
if [ "${DS_READY}" -ge "${DS_TOTAL}" ] && [ "${DS_READY}" -ge 1 ]; then
    ok "DaemonSet 就绪 ${DS_READY}/${DS_TOTAL}"
else
    warn "DaemonSet 未全部 Ready(${DS_READY}/${DS_TOTAL}), 稍后重查: kubectl get pods,ds -n ${METAX_NAMESPACE}"
fi

# 条件解除 master 不可调度: 仅当宿主机用 mx-smi 检测到沐曦 GPU 卡的 master 才 uncordon(移除 control-plane/master 污点)。
# 无 GPU 的 master 保持默认不可调度; 检测直接在节点上跑 mx-smi, 不依赖集群 label(避免"先有鸡还是蛋")。
say "  检测 master 节点 GPU(mx-smi)并条件解除不可调度 ..."
for _line in "${NODES[@]:-}"; do
    [ -z "${_line}" ] && continue
    IFS=, read -r _role _hn _ip _rest <<<"${_line}"
    [ "${_role}" = "master" ] && [ -n "${_ip}" ] || continue
    _GPUCNT="$(ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
        "${SSH_USER:-ubuntu}@${_ip}" "sudo mx-smi 2>/dev/null | grep 'Attached GPUs' | awk '{print \$NF}'" 2>/dev/null || echo 0)"
    _GPUCNT="$(echo "${_GPUCNT:-0}" | tr -d '[:space:]')"
    if [ "${_GPUCNT:-0}" -gt 0 ] 2>/dev/null; then
        SSH "${K} taint nodes ${_hn} node-role.kubernetes.io/control-plane- >/dev/null 2>&1" || true
        SSH "${K} taint nodes ${_hn} node-role.kubernetes.io/master- >/dev/null 2>&1" || true
        SSH "${K} uncordon ${_hn} >/dev/null 2>&1" || true
        ok "  master ${_hn}(${_ip}) 检测到 ${_GPUCNT} 张 GPU, 已解除不可调度"
    else
        say "  master ${_hn}(${_ip}) 未检测到 GPU, 保持默认不可调度"
    fi
done
# 等 DS 调度到已解除的 master 并给有 GPU 的 master 打标(gpu-label 先跑)
say "  等待 gpu-label 给有 GPU 的 master 打标(最长 300s)..."
for _i in $(seq 1 60); do
    # 用标签选择器只取匹配节点名(轻量; 避免 `get nodes -o json` 在大集群(如 500 节点)返回巨大数据)
    _GMASTERS="$( (SSH "${K} get nodes -l node-role.kubernetes.io/control-plane,metax-tech.com/gpu.installed=true --no-headers 2>/dev/null" || true) | wc -l )"
    [ "${_GMASTERS:-0}" -ge 1 ] && { ok "  ${_GMASTERS} 个 master 已获得 gpu.installed 标签"; break; }
    sleep 5
done

# 验证节点 GPU allocatable(metax-tech.com/gpu)
say "  验证节点 GPU 资源 allocatable ..."
# 注: jsonpath 的 ["metax-tech.com/gpu"] 在 kubectl 会报 invalid array index, 改用 python 解析
#      ⚠ (SSH ... || true) 必须加括号, 否则 `A || true | python3` 会让 python3 收不到 SSH 输出
GPU_NODES="$( (SSH "${K} get nodes -o json 2>/dev/null" || true) | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    for n in d["items"]:
        g=n["status"]["allocatable"].get("metax-tech.com/gpu")
        if g: print(n["metadata"]["name"], g)
except Exception: pass')"
if [ -n "${GPU_NODES}" ]; then
    ok "GPU 已可调度:"
    echo "    ${GPU_NODES}" | sed 's/^/    /'
else
    warn "未检测到 metax-tech.com/gpu allocatable。可能原因: 节点无沐曦 GPU、驱动未就绪、或 operator 尚未完成(重查: kubectl get pods,ds -n ${METAX_NAMESPACE})"
fi

echo "---------------------------------------------"
ok "沐曦 GPU Operator 部署完成"
echo "  namespace:   ${METAX_NAMESPACE}"
echo "  镜像仓库:    ${METAX_REGISTRY}"
echo "  资源查看:    kubectl get pods,ds -n ${METAX_NAMESPACE}"
echo "  节点 GPU:    kubectl get nodes -o json | jq '.items[].status.allocatable | with_entries(select(.key|startswith(\"metax\")))'"
echo "  GPU 任务测试: 参考文档 §5 gpu-task.yaml(vectorAdd), 需 MACA 镜像就绪"
echo "  卸载:        删除 ${METAX_NAMESPACE} 与 CRD(gpu.metax-tech.com) 后重跑本模块"
