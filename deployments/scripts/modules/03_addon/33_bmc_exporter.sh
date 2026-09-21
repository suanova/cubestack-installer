#!/bin/bash
# ============================================================
# MODULE: bmc_exporter
# DESC: BMC 带外监控(bmc-oem-exporter + idrac-exporter, 1 chart + 2 镜像。默认 online=先从私服同步制品, 再统一经集群内置 registry 部署)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: BMC_EXPORTER_ENABLED
# REQUIRES: prometheus
# 说明:
#   · 交付形态(cubestack 源仓库 observability/helm/cubestack-bmc-exporter-chart):
#       Deployment×2 + Service×2 + ScrapeConfig×2 + Secret×2, BMC 凭据经 values 传入。
#     chart 与两个 exporter 镜像均由 CI 在 main 合入后发布到私服 harbor.isuanova.com/suanova,
#     该项目**公开只读(anonymous pull), 无需凭据**。
#   · **制品流向统一(核心)**: 不论哪种模式, 节点**只从集群内置 registry 拉镜像**, 部署机 helm 装**本地 chart tgz**。
#       online  = 部署前先从私服同步制品到本地(镜像 pull 成 offline-files/bmc/*.tar),
#                 再推入内置 registry, 之后与 offline **同路**部署; chart 另见下条(恒用本地副本)
#       offline = 不碰外网, 直接用盘上已有制品(联网机预置的, 或上一次 online 留下的)推入内置 registry 后部署
#     ⇒ 两种模式的**部署路径是同一段代码**, 差别只在"开头要不要联网同步"。
#     ⚠ online 在私服不可达时**自动降级**: 拉不到就退回本地已有制品(告警, 不中断); 本地也没有才报错。
#     ⚠ 上游只发 :latest(main 线), 会跟上游漂移 → 本模块用 **digest 边车文件**检测"私服上这个
#       tag 变没变", 变了才重下(不白传)。想强制重拉: 删掉对应 tar(或它的 .digest 边车)即可。
#   · **chart 恒用仓库内 vendored 的离线副本**(cubestack-addon/bmc-exporter/cubestack-bmc-exporter-<ver>.tgz,
#     随 git 分发)。online **不直接装私服上拉到的那份** —— 它只负责拿远端 digest 与 <tgz>.digest
#     边车比对: 未变 → 继续用本地那份(仓库保持干净); 有更新 → 覆盖本地副本并提示 commit;
#     拉取失败 → 回退本地那份。实现收敛在 lib-common 的 helm_chart_ensure。
#     ⇒ **离线副本缺失就是致命错误**(拿不到任何 chart), 必须随仓库提交, 不能只在部署时拉到盘上。
#   · ⚠ 与 31_cubepilot 的**一处有意差异**: 不提供"节点本地构建"离线路径。
#     cubestack 源仓库文档给的是 buildah 在节点多阶段构建 bmc-oem-exporter(需 golang:1.26
#     基础镜像)再 ctr import —— 那要求每个部署节点都有 buildah + Go 工具链, 与仓库其它组件
#     不一致且脆弱。本模块改用与 cubepilot 完全同构的"私服 → tar → 内置 registry"路径:
#     离线机只要在联网机跑一次 tools/images/bmc-save-images.sh 备好两个 tar, 节点侧零工具链依赖。
#   · ScrapeConfig 的 release 标签必须与 Prometheus CR 的 scrapeConfigSelector 匹配, 否则
#     **BMC 指标静默丢失**: chart 的 scrapeConfigs.releaseLabel 默认 kube-prometheus(= 本仓库
#     stack 的 release 名), 本模块显式传 PROMETHEUS_RELEASE_NAME; 且 chart 同时给 ScrapeConfig
#     打了 app.kubernetes.io/part-of: cubestack-observability(见 chart _helpers.tpl), 与
#     08_prometheus 的 scrapeConfigSelector 并集匹配 —— 两条路都能选中, 冗余一层防静默失效。
#   · **BMC 凭据不走 argv**(§7.2): shell history / ps 可见, 且含特殊字符时 helm 易误解析。
#     凭据一律写临时 values 文件(600), 由 python3 生成以确保 YAML 转义正确, helm 装完立即删除。
#   · 前置条件(本模块检查并给指引, 不静默失败):
#       ① 监控栈已按 08_prometheus 部署(REQUIRES: prometheus), 且 ScrapeConfig CRD 存在;
#       ② BMC_HOSTS 已按环境确认真实 BMC IP(**不是按末位推的**), 且节点到这些 IP 可达;
#       ③ 钉 control-plane 节点时必须带 tolerations(默认已加, 见 BMC_EXPORTER_TOLERATE_CONTROL_PLANE)。
# 数据源: cluster.conf (BMC_EXPORTER_* / BMC_HOSTS / BMC_USERNAME / BMC_PASSWORD / BMC_TLS_INSECURE /
#                       PROMETHEUS_RELEASE_NAME / PROMETHEUS_NAMESPACE / REGISTRY_* / SSH_KEY_NAME / NODES)
# 用法:   sudo ./deploy-cluster.sh --steps bmc_exporter
#         或 cluster.conf 置 BMC_EXPORTER_ENABLED=true(全量部署时一并安装)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

if [ "${BMC_EXPORTER_ENABLED:-false}" != "true" ]; then
    say "跳过 BMC exporter(配置 BMC_EXPORTER_ENABLED=true 可启用)"
    exit 0
fi

init_remote_kubectl || exit 1

# ---------------- 模式与派生变量(全部来自 cluster.conf, 无硬编码) ----------------
BMC_EXPORTER_MODE="${BMC_EXPORTER_MODE:-online}"
case "${BMC_EXPORTER_MODE}" in
    online|offline) ;;
    *) err "BMC_EXPORTER_MODE 仅支持 online|offline(当前=${BMC_EXPORTER_MODE})"; exit 1 ;;
esac

BMC_EXPORTER_HARBOR="${BMC_EXPORTER_HARBOR:-harbor.isuanova.com}"    # 私服域名(公开只读, 免凭据)
BMC_EXPORTER_PROJECT="${BMC_EXPORTER_PROJECT:-suanova}"              # Harbor 项目名
BMC_EXPORTER_CHART_VERSION="${BMC_EXPORTER_CHART_VERSION:-1.0.0}"
BMC_EXPORTER_IMAGE_TAG="${BMC_EXPORTER_IMAGE_TAG:-latest}"
BMC_EXPORTER_RELEASE="${BMC_EXPORTER_RELEASE:-cubestack-bmc-exporter}"
BMC_EXPORTER_NAMESPACE="${BMC_EXPORTER_NAMESPACE:-monitoring}"       # 与 Prometheus 同 ns(ScrapeConfig 在此被选中)
BMC_EXPORTER_WAIT_SECONDS="${BMC_EXPORTER_WAIT_SECONDS:-300}"
BMC_TLS_INSECURE="${BMC_TLS_INSECURE:-true}"                         # BMC 多为自签证书
PROMETHEUS_RELEASE_NAME="${PROMETHEUS_RELEASE_NAME:-kube-prometheus}"
PROMETHEUS_NAMESPACE="${PROMETHEUS_NAMESPACE:-monitoring}"
# ⚠ chart 仓库名带 -chart 后缀(cubestack-bmc-exporter-chart), 不是 cubestack-bmc-exporter
BMC_EXPORTER_CHART_REF="${BMC_EXPORTER_CHART_REF:-oci://${BMC_EXPORTER_HARBOR}/${BMC_EXPORTER_PROJECT}/cubestack-bmc-exporter-chart}"
BMC_EXPORTER_CHART_DIR="${BMC_EXPORTER_CHART_DIR:-${REPO_ROOT}/deployments/cubestack-addon/bmc-exporter}"
BMC_EXPORTER_CHART_TGZ="${BMC_EXPORTER_CHART_TGZ:-${BMC_EXPORTER_CHART_DIR}/cubestack-bmc-exporter-${BMC_EXPORTER_CHART_VERSION}.tgz}"
BMC_EXPORTER_OFFLINE_DIR="${BMC_EXPORTER_OFFLINE_DIR:-${REPO_ROOT}/deployments/offline-files/bmc}"
# 两个镜像前缀, 各司其职(不要混):
#   _SRC_IMAGE_BASE         私服 Harbor 侧(online 拉取制品的源; 节点**不**访问它)
#   BMC_EXPORTER_IMAGE_BASE 集群内置 registry 侧(helm --set 的目标; **两种模式都指向这里**)
_SRC_IMAGE_BASE="${BMC_EXPORTER_HARBOR}/${BMC_EXPORTER_PROJECT}"
REGISTRY_BASE="${REGISTRY_DOMAIN:-registry.cubestack.io}:${REGISTRY_PORT:-5000}"
BMC_EXPORTER_IMAGE_BASE="${BMC_EXPORTER_IMAGE_BASE:-${REGISTRY_BASE}/${BMC_EXPORTER_PROJECT}}"
BMC_EXPORTER_PUSH_BASE="${BMC_EXPORTER_PUSH_BASE:-${REGISTRY_DIRECT}/${BMC_EXPORTER_PROJECT}}"
# 两个 exporter 组件名(= 私服仓库名后缀 = chart 里 deployment 名后缀)
_BMC_COMPONENTS=(bmc-oem-exporter idrac-exporter)
# 镜像 tar 规范文件名: / 与 : → _(与 cubepilot-save-images.sh、harbor-save-images.sh 同一约定)
_tar_name_of() { echo "$(echo "$1" | sed 's#/#_#g; s#:#_#g').tar"; }
# 私服凭据(可选): 该 Harbor 公开只读, 留空即匿名 pull; 配了则 helm/skopeo 两侧都带上
_HAVE_CREDS=0
if [ -n "${BMC_EXPORTER_HARBOR_USER:-}" ] && [ -n "${BMC_EXPORTER_HARBOR_PASSWORD:-}" ]; then
    _HAVE_CREDS=1
fi
_skopeo_src_opts() {   # 输出可选参数(空格分隔调用方自行展开)
    [ "${BMC_EXPORTER_HARBOR_INSECURE:-false}" = "true" ] && printf '%s\n' "--src-tls-verify=false"
    [ "${_HAVE_CREDS}" = "1" ] && printf '%s\n' "--src-creds" "${BMC_EXPORTER_HARBOR_USER}:${BMC_EXPORTER_HARBOR_PASSWORD}"
    return 0
}

# ---------------- 凭据与目标 BMC 校验(§7.2; 在推镜像**之前**做, 尽早失败) ----------------
# 与 08_prometheus 的 Grafana 口令硬校验同理: 缺凭据时 exporter 拿不到数据, 且表现为
# "target up 但指标为空", 极难排查 —— 宁可在起手就拒。
if [ -z "${BMC_HOSTS:-}" ]; then
    err "BMC_HOSTS 未设置(要监控的 BMC 管理 IP 列表, 空格或逗号分隔)"
    err "  cluster.conf 示例: BMC_HOSTS=\"10.6.2.14 10.6.2.18\""
    err "  ⚠ BMC IP 必须按环境**实际确认**(与节点不是按末位对应的关系), 不要按规律推。"
    exit 1
fi
if [ -z "${BMC_USERNAME:-}" ] || [ -z "${BMC_PASSWORD:-}" ]; then
    err "BMC_USERNAME / BMC_PASSWORD 未设置(exporter 需凭据登录 BMC 的 Redfish 接口)"
    exit 1
fi
case "${BMC_PASSWORD}" in
    CHANGE_ME|changeme|change-me|CHANGEME) err "BMC_PASSWORD 仍是占位符, 拒绝用已知默认口令访问 BMC"; exit 1 ;;
esac
# 归一化 host 列表: 逗号/空格都接受 → 数组
_BMC_HOSTS=()
for _h in ${BMC_HOSTS//,/ }; do
    [ -n "${_h}" ] && _BMC_HOSTS+=("${_h}")
done
[ "${#_BMC_HOSTS[@]}" -ge 1 ] || { err "BMC_HOSTS 解析后为空: ${BMC_HOSTS}"; exit 1; }
say "目标 BMC: ${#_BMC_HOSTS[@]} 个(${_BMC_HOSTS[*]})"

# ---------------- 前置检查 ----------------
say "检查 BMC exporter 前置条件(模式=${BMC_EXPORTER_MODE}, chart ${BMC_EXPORTER_CHART_VERSION}, 镜像 tag ${BMC_EXPORTER_IMAGE_TAG})..."
command -v helm >/dev/null 2>&1 || { err "未找到 helm(需 3.0+); 安装本地 chart 必需"; exit 1; }
SSH "${K} get nodes --no-headers >/dev/null 2>&1" \
    || { err "无法访问集群(${FIRST_MASTER}); 检查 kubectl/集群状态"; exit 1; }
sync_kubeconfig \
    && ok "本机 ~/.kube/config 已同步(admin.conf → API ${API_DOMAIN:-k8s-api.cubestack.io})" \
    || { err "本机无法访问集群(admin.conf 下载/同步失败), helm 无法安装"; exit 1; }
# ScrapeConfig 是 Prometheus **Operator** 的 CRD: 没它就装不出抓取配置(BMC 指标静默丢失), 提前拦
SSH "${K} get crd scrapeconfigs.monitoring.coreos.com >/dev/null 2>&1" \
    || { err "缺少 ScrapeConfig CRD(monitoring.coreos.com/v1alpha1) —— 监控栈未部署或版本过旧"; err "  先跑: sudo ./deploy-cluster.sh --steps prometheus"; exit 1; }
ok "  ScrapeConfig CRD 就绪"

# ============================================================
# 1. 制品就绪 —— 节点只从内置 registry 拉镜像, chart 恒用本地离线副本
# ============================================================
# 本段结束后的**不变量**(后续步骤只依赖它, 不再关心模式):
#   · ${BMC_EXPORTER_CHART_TGZ} 存在                  (helm 从这里装)
#   · 两个组件在内置 registry 里已有 <tag> 镜像        (节点从这里拉)
mkdir -p "${BMC_EXPORTER_CHART_DIR}" "${BMC_EXPORTER_OFFLINE_DIR}"

# ---- 1a. chart 就绪: 恒用仓库内 vendored 的离线副本 ----
# online **不直接装私服上拉到的那份** —— 它的作用是拿远端 digest 与 <tgz>.digest 边车比对,
# 决定要不要刷新本地这份副本(见 lib-common helm_chart_ensure):
#   digest 未变 → 继续用本地那份(仓库保持干净); 有更新 → 覆盖并提示 commit;
#   拉取失败    → 降级回退本地那份(这正是本地副本存在的意义)。
# offline 完全不联网。⚠ 离线副本必须**随 git 分发** —— 只在部署时拉到盘上不算数。
say "[1/6] chart 离线副本 $(basename "${BMC_EXPORTER_CHART_TGZ}")(模式=${BMC_EXPORTER_MODE})..."
if [ "${BMC_EXPORTER_MODE}" = "online" ] && [ "${_HAVE_CREDS}" = "1" ]; then
    # --password-stdin: 不把密码放进 argv(ps 可见); 无凭据时 helm 走匿名(该 Harbor 公开只读)
    printf '%s' "${BMC_EXPORTER_HARBOR_PASSWORD}" | helm registry login "${BMC_EXPORTER_HARBOR}" \
        -u "${BMC_EXPORTER_HARBOR_USER}" --password-stdin >/dev/null 2>&1 \
        || warn "  helm registry login 失败(继续尝试匿名拉取)"
fi
helm_chart_ensure "bmc-exporter" "${BMC_EXPORTER_CHART_TGZ}" "${BMC_EXPORTER_CHART_VERSION}" \
    "${BMC_EXPORTER_MODE}" "${BMC_EXPORTER_CHART_REF}" || exit 1

# ---- 1b. online: 镜像同步(私服 pull → 本地 tar; digest 未变则跳过下载) ----
# 只负责"私服 → 本地 tar"这一段; 推入内置 registry 由 1c 统一做(两种模式共用)。
if [ "${BMC_EXPORTER_MODE}" = "online" ]; then
    skopeo_require "bmc"     # 拉取与推送都依赖 skopeo
    _SYNC_N=0; _SYNC_SKIP=0; _SYNC_FB=0
    sync_bmc_tar() {   # <comp>
        local comp="$1"
        local src="${_SRC_IMAGE_BASE}/${comp}:${BMC_EXPORTER_IMAGE_TAG}"
        local tar="${BMC_EXPORTER_OFFLINE_DIR}/$(_tar_name_of "${src}")"
        local dgfile="${tar}.digest"
        local remote_dg="" local_dg="" ok_dl=0
        local -a srcopts=()
        while IFS= read -r _o; do
            if [ -n "${_o}" ]; then srcopts+=("${_o}"); fi
        done < <(_skopeo_src_opts)

        # ① 取私服上该 tag 的 digest(同时验证"镜像存在 + 私服可达")
        #    走共享助手(3 次重试): 单次 TLS 超时不得被当成"私服没这个镜像"而静默跳过下载
        #    结果经全局回传(**不能写成 $(...)**: 子 shell 里函数设的 SKOPEO_PULL_ERR 传不出来)
        remote_image_digest "${src}" "${srcopts[@]}"; remote_dg="${SKOPEO_REMOTE_DIGEST}"
        # ② 与本地边车比对: digest 相同且 tar 在 → 跳过下载(不白传)
        [ -f "${dgfile}" ] && local_dg="$(cat "${dgfile}" 2>/dev/null || true)"
        if [ -n "${remote_dg}" ] && [ -n "${local_dg}" ] && [ "${remote_dg}" = "${local_dg}" ] && [ -f "${tar}" ]; then
            ok "  ${comp}:${BMC_EXPORTER_IMAGE_TAG} 私服 digest 未变, 跳过下载(本地已有 $(basename "${tar}"))"
            _SYNC_SKIP=$((_SYNC_SKIP + 1)); return 0
        fi
        # ③ 下载(走共享助手: 3 次整包重试 + 失败不动原有 tar; 原因回传给下面的告警)
        if [ -n "${remote_dg}" ]; then
            say "  [拉取] ${comp}:${BMC_EXPORTER_IMAGE_TAG} → $(basename "${tar}")"
            if pull_image_skopeo "${src}" "${tar}" "${srcopts[@]}"; then
                printf '%s' "${remote_dg}" > "${dgfile}"
                chmod 644 "${tar}" "${dgfile}" 2>/dev/null || true
                ok "  ${comp} 已落盘(digest ${remote_dg:0:19}...)"
                _SYNC_N=$((_SYNC_N + 1)); ok_dl=1
            fi
        fi
        if [ "${ok_dl}" != "1" ]; then
            # 私服不可达/拉取失败 → 回退本地已有 tar(与 chart 的降级语义对称)
            # ⚠ 回退是**降级**不是成功: 必须把原因打出来, 否则"用着旧制品"这件事没人看得见
            if [ -f "${tar}" ]; then
                warn "  ${comp} 私服拉取失败(${SKOPEO_PULL_ERR:-未知原因}), **回退使用本地 tar**(可能是旧版本)"
                _SYNC_FB=$((_SYNC_FB + 1))
                return 0
            fi
            err "  ${comp} 私服拉取失败且本地无 tar: ${tar}"
            err "  原因: ${SKOPEO_PULL_ERR:-未知原因}"
            err "  排查: skopeo inspect docker://${src}(私服可达? tag 存在?)"
            return 1
        fi
        return 0
    }
    say "[1/6] online: 从私服同步镜像(${_SRC_IMAGE_BASE}/{bmc-oem-exporter,idrac-exporter}:${BMC_EXPORTER_IMAGE_TAG})..."
    for _c in "${_BMC_COMPONENTS[@]}"; do sync_bmc_tar "${_c}" || exit 1; done
    # 汇总里必须出现"回退 N 个" —— 否则"0 新下载 0 跳过"读起来像一切正常, 实际是全部用了旧 tar
    if [ "${_SYNC_FB}" -gt 0 ]; then
        warn "  镜像同步完成(新下载 ${_SYNC_N} 个, digest 未变跳过 ${_SYNC_SKIP} 个, **回退本地旧 tar ${_SYNC_FB} 个**)"
    else
        ok "  镜像同步完成(新下载 ${_SYNC_N} 个, digest 未变跳过 ${_SYNC_SKIP} 个)"
    fi
    unset _SYNC_N _SYNC_SKIP _SYNC_FB _c
fi

# ---- 1c. 推入集群内置 registry(两种模式共用; 节点只从这里拉) ----
say "[1/6] 推送镜像到集群内置 registry(${BMC_EXPORTER_PUSH_BASE})..."
skopeo_require "bmc"       # 离线机没跑过 1b, 这里要再确认一次
ensure_hosts_entry "${REGISTRY_IP:-}" "${REGISTRY_DOMAIN:-registry.cubestack.io}"   # 部署机 /etc/hosts 解析内置 registry
wait_registry_ready "http://${REGISTRY_DIRECT}/v2/" \
    || { err "集群内置 registry ${REGISTRY_DIRECT}/v2/ 不可达(当前 SERVICE_EXPOSE_MODE=${SERVICE_EXPOSE_MODE:-})"; exit 1; }

# 推送单组件镜像: ① 已是目标 tag(幂等跳过) ② 从离线 tar 推入内置 registry
_PUSH=0; _SKIP_N=0
push_bmc_image() {   # <comp>
    local comp="$1" _tarbase="" _t="" _src=""
    if reg_has_tag "${BMC_EXPORTER_PUSH_BASE}" "${comp}" "${BMC_EXPORTER_IMAGE_TAG}"; then
        ok "  ${comp}:${BMC_EXPORTER_IMAGE_TAG} 已在内置 registry, 跳过"
        _SKIP_N=$((_SKIP_N + 1)); return 0
    fi
    _tarbase="${BMC_EXPORTER_OFFLINE_DIR}/$(_tar_name_of "${_SRC_IMAGE_BASE}/${comp}:${BMC_EXPORTER_IMAGE_TAG}")"
    # ① 规范命名快路径; ② 目录内通配(文件名含组件名); ③ 内容兜底扫描(兼容完全改名的 tar)
    if [ -f "${_tarbase}" ]; then
        _t="${_tarbase}"
    else
        local _d _f
        for _d in "${BMC_EXPORTER_OFFLINE_DIR}" "${LOCAL_REPO_DIR}/images" \
                  "${OFFLINE_FILES_DIR:-${REPO_ROOT}/deployments/offline-files/kubespray}/images"; do
            [ -d "${_d}" ] || continue
            for _f in "${_d}"/*"${comp}"*.tar; do
                [ -f "${_f}" ] || continue
                _t="${_f}"; break 2
            done
        done
        # ③ 内容兜底: 文件名完全不含组件名时(改名/异常命名), 按 tar 内 RepoTags 识别。
        #    ⚠ 只扫 ${BMC_EXPORTER_OFFLINE_DIR}(文档约定的制品目录, 体积可控);
        #      另两个兼容目录不做全量扫描 —— 那里可能有几十个大 tar, 逐个读代价过高。
        if [ -z "${_t}" ] && [ -d "${BMC_EXPORTER_OFFLINE_DIR}" ]; then
            for _f in "${BMC_EXPORTER_OFFLINE_DIR}"/*.tar; do
                [ -f "${_f}" ] || continue
                case "$(tar_first_image_tag "${_f}")" in
                    *"/${comp}:"*) _t="${_f}"; break ;;
                esac
            done
        fi
        # 通配命中时也要用 tar 内 ref 复核(防"文件名像、内容不是"推错镜像)
        if [ -n "${_t}" ]; then
            _src="$(tar_first_image_tag "${_t}")"
            case "${_src}" in
                *"/${comp}:"*) : ;;
                *) warn "  $(basename "${_t}") 内容为 ${_src:-<读不出>}, 非 ${comp}, 跳过"
                   _t="" ;;
            esac
        fi
        unset _d _f
    fi
    if [ -z "${_t}" ]; then
        err "  离线镜像缺失: ${comp}:${BMC_EXPORTER_IMAGE_TAG}"
        err "  online : 检查私服可达性后重跑(会自动同步)"
        err "  离线机 : 在联网机执行 tools/images/bmc-save-images.sh 生成后放入 ${BMC_EXPORTER_OFFLINE_DIR}/"
        return 1
    fi
    say "  推送 ${comp} → ${BMC_EXPORTER_PUSH_BASE}/${comp}:${BMC_EXPORTER_IMAGE_TAG}(源: $(basename "${_t}"))"
    if push_image_skopeo "docker-archive:${_t}" "docker://${BMC_EXPORTER_PUSH_BASE}/${comp}:${BMC_EXPORTER_IMAGE_TAG}" >/dev/null 2>&1; then
        ok "  ${comp} 已推入内置 registry"
        _PUSH=$((_PUSH + 1))
    else
        err "  ${comp} 推送失败(skopeo copy docker-archive:${_t} → docker://${BMC_EXPORTER_PUSH_BASE}/${comp}:${BMC_EXPORTER_IMAGE_TAG})"
        return 1
    fi
}
for _c in "${_BMC_COMPONENTS[@]}"; do push_bmc_image "${_c}" || exit 1; done
ok "  内置 registry 就绪(新推 ${_PUSH} 个, 已存在 ${_SKIP_N} 个)"
unset _PUSH _SKIP_N _c

# ============================================================
# 2. 命名空间(与 Prometheus 同 ns —— ScrapeConfig 在这里才会被选中)
# ============================================================
say "[2/6] 准备命名空间 ${BMC_EXPORTER_NAMESPACE}..."
# 幂等: 已存在时 create 失败属正常, 以"能读到该 ns"为最终判据
SSH "${K} create namespace ${BMC_EXPORTER_NAMESPACE} >/dev/null 2>&1" || true
SSH "${K} get namespace ${BMC_EXPORTER_NAMESPACE} >/dev/null 2>&1" \
    || { err "无法创建/访问命名空间 ${BMC_EXPORTER_NAMESPACE}"; exit 1; }
ok "  命名空间就绪(镜像来自内置 registry, 无需 imagePullSecret)"

# ============================================================
# 3. 凭据 → 临时 values 文件(600; 不进 argv; 装完即删)
# ============================================================
# ⚠ 用 python3 的 yaml 生成而不是手拼字符串: BMC 口令/用户名可能含引号、冒号、#、@ 等,
#   手拼时表现为 helm 报 "could not find expected ':'" 之类, 用户很难联想到是口令里的字符。
say "[3/6] 生成 helm values(BMC 凭据不入 argv)..."
_BMC_VALUES="$(mktemp)"
chmod 600 "${_BMC_VALUES}"
BMC_TOLERATE_CP="${BMC_EXPORTER_TOLERATE_CONTROL_PLANE:-true}"
# ⚠ 凭据以**位置参数**传给 python(而不是嵌进 python 源码): 源码里插值会让含引号/反斜杠的
#   口令破坏 python 语法; yaml.safe_dump 负责最终的转义。
python3 - "${_BMC_VALUES}" "${BMC_USERNAME}" "${BMC_PASSWORD}" "${BMC_TLS_INSECURE}" \
          "${PROMETHEUS_RELEASE_NAME}" "${PROMETHEUS_SCRAPE_INTERVAL:-60s}" "${BMC_TOLERATE_CP}" \
          "${_BMC_HOSTS[@]}" <<'PY'
import sys, yaml
path = sys.argv[1]
username, password, tls_insecure, release_label, interval, tolerate_cp = sys.argv[2:8]
hosts = sys.argv[8:]
out = {
    'bmc': {
        'username': username,
        'password': password,
        'hosts': hosts,
    },
    'bmcOemExporter': {'tlsInsecure': tls_insecure == 'true'},
    'scrapeConfigs': {
        'enabled': True,
        # ScrapeConfig 的 release 标签必须与 Prometheus CR 的 scrapeConfigSelector 匹配,
        # 否则 BMC 指标静默丢失(见文件头说明)
        'releaseLabel': release_label,
        'interval': interval,
    },
}
if tolerate_cp == 'true':
    # ⚠ 钉在 control-plane 节点时**必须**有 tolerations, 否则 NoSchedule 污点让 pod 永远 Pending
    #   (2026-09-14 实测)。两个 exporter 都要加 —— 只加一个另一个仍会 Pending。
    # ⚠ 两个 exporter 用**各自独立**的 list 对象: 复用同一个会让 safe_dump 输出 YAML 锚点/别名
    #   (&id001/*id001), 虽能解析, 但读 values 的人会困惑。
    def cp_tolerations():
        return [{'key': 'node-role.kubernetes.io/control-plane',
                 'operator': 'Exists', 'effect': 'NoSchedule'}]
    out['bmcOemExporter']['tolerations'] = cp_tolerations()
    out['idracExporter'] = {'tolerations': cp_tolerations()}
yaml.safe_dump(out, open(path, 'w', encoding='utf-8'),
               default_flow_style=False, allow_unicode=True, sort_keys=False)
PY
ok "  values 已生成(600): ${_BMC_VALUES}"

# ============================================================
# 4. helm 安装(恒本地 tgz + 恒内置 registry 镜像)
# ============================================================
# 两种模式**在这里完全合流**: chart 一律取自本地 tgz(online 已同步), 2 个镜像一律指向内置 registry。
say "[4/6] helm upgrade --install ${BMC_EXPORTER_RELEASE}(→ ${BMC_EXPORTER_NAMESPACE})..."
say "  chart 来源: 本地 ${BMC_EXPORTER_CHART_TGZ}"
# --set-string 用于镜像这类字符串值(避免 helm 对 tag 做类型推断)
_HELM_ARGS=(
    --namespace "${BMC_EXPORTER_NAMESPACE}" --create-namespace
    -f "${_BMC_VALUES}"
    --set-string "bmcOemExporter.image.repository=${BMC_EXPORTER_IMAGE_BASE}/bmc-oem-exporter"
    --set-string "bmcOemExporter.image.tag=${BMC_EXPORTER_IMAGE_TAG}"
    --set-string "idracExporter.image.repository=${BMC_EXPORTER_IMAGE_BASE}/idrac-exporter"
    --set-string "idracExporter.image.tag=${BMC_EXPORTER_IMAGE_TAG}"
)
# 调度约束: 钉到指定节点(如 control-plane)。两种 exporter 都要钉, 只钉一个另一个仍可能被调度走。
if [ -n "${BMC_EXPORTER_NODE_SELECTOR:-}" ]; then
    say "  钉节点(nodeSelector kubernetes.io/hostname=${BMC_EXPORTER_NODE_SELECTOR}, 两个 exporter)..."
    _HELM_ARGS+=(
        --set-string "bmcOemExporter.nodeSelector.kubernetes\.io/hostname=${BMC_EXPORTER_NODE_SELECTOR}"
        --set-string "idracExporter.nodeSelector.kubernetes\.io/hostname=${BMC_EXPORTER_NODE_SELECTOR}"
    )
fi
if [ "${BMC_TOLERATE_CP}" = "true" ]; then
    say "  已加 control-plane tolerations(两个 exporter; 置 BMC_EXPORTER_TOLERATE_CONTROL_PLANE=false 可关)"
fi
say "  镜像: ${BMC_EXPORTER_IMAGE_BASE}/{bmc-oem-exporter,idrac-exporter}:${BMC_EXPORTER_IMAGE_TAG}"
# ⚠ 本地 tgz 的版本由文件本身决定, **不传 --version**(那是 OCI 源才有效的参数)
# --wait 超时只 warn: 资源可能已创建(镜像首次拉取较慢), 后面按 Deployment 实际状态判定
helm upgrade --install "${BMC_EXPORTER_RELEASE}" "${BMC_EXPORTER_CHART_TGZ}" \
    "${_HELM_ARGS[@]}" \
    --wait --timeout "${BMC_EXPORTER_WAIT_SECONDS}s" \
    || warn "  helm --wait 超时(资源可能已创建; 继续按实际状态检查)"
# 凭据已进集群 secret, 临时 values 立刻销毁(不留盘)
rm -f "${_BMC_VALUES}"; unset _BMC_VALUES

# ============================================================
# 5. 等 rollout + 收集状态
# ============================================================
say "[5/6] 等待两个 exporter 就绪(最长 ${BMC_EXPORTER_WAIT_SECONDS}s)..."
_ROLL_FAIL=""
for _comp in bmc-oem-exporter idrac-exporter; do
    _dep="${BMC_EXPORTER_RELEASE}-${_comp}"
    if [ -n "$( (SSH "${K} -n ${BMC_EXPORTER_NAMESPACE} get deploy ${_dep} --no-headers 2>/dev/null" || true) )" ]; then
        SSH "${K} -n ${BMC_EXPORTER_NAMESPACE} rollout status deploy/${_dep} --timeout=${BMC_EXPORTER_WAIT_SECONDS}s" >/dev/null 2>&1 \
            && ok "  ${_dep} Ready" \
            || { warn "  ${_dep} 未在 ${BMC_EXPORTER_WAIT_SECONDS}s 内 Ready"; _ROLL_FAIL="${_ROLL_FAIL} ${_dep}"; }
    else
        warn "  未发现 Deployment ${_dep}(helm 安装是否成功?)"
        _ROLL_FAIL="${_ROLL_FAIL} ${_dep}(缺失)"
    fi
done
unset _comp _dep

# ScrapeConfig 是否真的建出来了(chart 有 apiVersion 守卫: CRD 不在时**静默不建**)
_SC_N="$( (SSH "${K} -n ${BMC_EXPORTER_NAMESPACE} get scrapeconfig --no-headers 2>/dev/null" || true) | grep -c "${BMC_EXPORTER_RELEASE}" || true)"
if [ "${_SC_N:-0}" -ge 1 ]; then
    ok "  ScrapeConfig 已创建 ${_SC_N} 个(期望 2 个: bmc-oem + idrac)"
else
    warn "  未发现本 release 的 ScrapeConfig —— BMC 指标不会被采集(kubectl -n ${BMC_EXPORTER_NAMESPACE} get scrapeconfig)"
fi
unset _SC_N

# 节点 → BMC 连通性: exporter 跑在节点上, 部署机探不到, 所以从节点侧探
if [ "${BMC_EXPORTER_SKIP_REACHABILITY:-false}" != "true" ]; then
    say "  探测节点 → BMC 连通性(从首个 master, 与 exporter 同侧)..."
    _UNREACH=""
    for _h in "${_BMC_HOSTS[@]}"; do
        if [ "$(SSH "timeout 5 bash -c '</dev/tcp/${_h}/443' 2>/dev/null && echo ok || echo no" 2>/dev/null || true)" = "ok" ]; then
            ok "    ${_h}:443 可达"
        else
            _UNREACH="${_UNREACH} ${_h}"
        fi
    done
    if [ -n "${_UNREACH}" ]; then
        warn "    以下 BMC 的 443 从节点不可达:${_UNREACH}"
        warn "    → exporter 会 up 但指标为空(scrape 超时)。核对 BMC_HOSTS 是否为该环境真实 BMC IP,"
        warn "      以及节点到 BMC 管理网段的路由/ACL(实测集群节点通常可达, 无需隧道)。"
    fi
    unset _UNREACH _h
fi

# ============================================================
# 6. 汇总
# ============================================================
echo "---------------------------------------------"
ok "BMC exporter 部署完成"
echo "  模式:        ${BMC_EXPORTER_MODE}$( [ "${BMC_EXPORTER_MODE}" = "online" ] && echo "(已从私服 ${BMC_EXPORTER_HARBOR} 同步制品)" || echo "(未联网, 使用本地制品)" )"
echo "  chart:       $(basename "${BMC_EXPORTER_CHART_TGZ}")(仓库内 vendored 离线副本, 随 git 分发)"
echo "  镜像:        ${BMC_EXPORTER_IMAGE_BASE}/{bmc-oem-exporter,idrac-exporter}:${BMC_EXPORTER_IMAGE_TAG}"
echo "               (统一来自集群内置 registry; 节点不需任何私服凭据)"
echo "  namespace:   ${BMC_EXPORTER_NAMESPACE}(helm release ${BMC_EXPORTER_RELEASE})"
echo "  BMC 目标:    ${#_BMC_HOSTS[@]} 个(${_BMC_HOSTS[*]})"
echo "  TLS 校验:    $( [ "${BMC_TLS_INSECURE}" = "true" ] && echo "已跳过(自签证书; 生产应配 CA 并置 false)" || echo "开启" )"
echo "  ScrapeConfig releaseLabel: ${PROMETHEUS_RELEASE_NAME}(须与 Prometheus CR 的 scrapeConfigSelector 匹配)"
echo "  离线制品:    ${BMC_EXPORTER_OFFLINE_DIR}/(镜像 tar, 可直接切纯离线)"
if [ -n "${_ROLL_FAIL}" ]; then
    echo "  ⚠ 未就绪:${_ROLL_FAIL}(kubectl -n ${BMC_EXPORTER_NAMESPACE} get pods 复查)"
fi
echo "  资源查看:    kubectl -n ${BMC_EXPORTER_NAMESPACE} get deploy,scrapeconfig | grep -i bmc"
echo "  端到端验证:  sudo ./deploy-cluster.sh --steps verify_prometheus   # ⑧ 段断言 bmc target up"
echo "  切纯离线:    cluster.conf 置 BMC_EXPORTER_MODE=offline —— chart 用仓库内离线副本,"
echo "               镜像用 ${BMC_EXPORTER_OFFLINE_DIR}/(上面那次 online 已备好), 无需其他准备"
echo "  卸载:        helm uninstall ${BMC_EXPORTER_RELEASE} -n ${BMC_EXPORTER_NAMESPACE}"
unset _BMC_HOSTS _ROLL_FAIL
