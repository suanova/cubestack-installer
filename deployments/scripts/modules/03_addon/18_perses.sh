#!/bin/bash
# ============================================================
# MODULE: perses
# DESC: Perses 云原生看板(P1 可视化; 1 chart + 2 镜像。默认 online=先从私服 mirrors 同步制品, 再统一经集群内置 registry 部署)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: PERSES_ENABLED
# REQUIRES: k8s_registry
# 说明:
#   · **制品流向统一(核心)**: 不论哪种模式, 节点**只从集群内置 registry 拉镜像**, 部署机 helm 装**本地 chart tgz**。
#       online  = 部署前先从私服 Harbor 的 mirrors 项目同步镜像到本地(pull 成 offline-files/perses/*.tar),
#                 再推入内置 registry, 之后与 offline **同路**部署; chart 另见下条(恒用本地副本)
#       offline = 不碰外网, 直接用盘上已有制品推入内置 registry 后部署
#     ⇒ 两种模式的**部署路径是同一段代码**, 差别只在"开头要不要联网同步"。
#     ⚠ online 在私服不可达时**自动降级**: 拉不到就退回本地已有 tar(告警, 不中断); 本地也没有才报错。
#   · **chart 恒用仓库内 vendored 的离线副本**(cubestack-addon/perses/perses-<ver>.tgz, 随 git 分发)。
#     online **不直接装上游拉到的那份** —— 它只负责拿远端 digest 与 <tgz>.digest 边车比对:
#     未变 → 继续用本地那份(仓库保持干净); 有更新 → 覆盖本地副本并提示 commit; 拉取失败 → 回退本地那份。
#     实现收敛在 lib-common 的 helm_chart_ensure(全仓库统一约定, 见 docs/scripts-development-spec.md §2.4)。
#     ⇒ 所以**离线副本缺失就是致命错误**, 必须随仓库提交, 不能只在部署时拉到盘上。
#     ⚠ 上游 chart 走**经典 helm repo**(perses.github.io), 不是 OCI; 其 digest 就是 tgz 的 sha256。
#   · 私服来源是 **mirrors 项目**(不是 suanova): Perses 是第三方上游镜像, 由 CI 读
#     deployments/config/images.manifest 的 perses 组从 docker.io 同步过去 ——
#     这是仓库对第三方镜像的统一在线源(与 cubepilot 这种"自家产品走 suanova"不同)。
#     mirrors 项目**公开只读**, 通常免凭据; 私有化后填 PERSES_HARBOR_USER/PASSWORD。
#   · chart 形状(实测 0.23.2, 与本模块的取值强相关, 改动前先核对):
#       - 设 `config.database.file` → 渲染 **StatefulSet**(不是 Deployment); 设 `config.database.sql` 才渲染 Deployment。
#         verify 模块因此按 StatefulSet 找, 不写死 Deployment。
#       - `persistence.enabled=false` 时用 **emptyDir** → Pod 重建即丢全部看板, 故本模块恒置 true。
#       - v0.53+ 容器用户由 nobody 改 nonroot → 文件存储必须让 PVC 可写, 靠 `persistence.securityContext.fsGroup=2000`。
#       - `config.provisioning.interval` 默认 10m(上游 schema 甚至写 1h)→ 装完要干等十分钟才出现看板,
#         本模块收到 1m。
#       - chart 自带 `gateway` / `ingress` 模板。按 2026-09-18 定案**模块不创建 Gateway/HTTPRoute**,
#         故两者恒置 false; 对外入口只在末尾给 port-forward 指引。
#       - `testFramework.enabled=true` 会引入 ghcr.io 上的测试镜像(离线环境拉不到)→ 恒置 false。
#   · 数据源供给(默认开): 建一个带 sidecar 标签的 ConfigMap, 由 **chart 自带 sidecar**(k8s-sidecar)
#     写进 provisioning 目录, Perses 的 provisioning 机制加载。**不用已废弃的 `datasources:` 列表**。
#     ⚠ sidecar 需要 `allNamespaces: true` 对应的 ClusterRole(configmaps get/watch/list), chart 会自建。
#   · 数据源 spec(实测自上游 model 文档):
#       proxy.kind=HTTPProxy + spec.url → 前端**经 Perses 服务端代理**查询后端。
#     **故意不设 directUrl**: 设了它浏览器要能直连 Prometheus, 而 port-forward 场景下
#     `*.svc.cluster.local` 在浏览器侧根本解析不了 → UI 必然报错。走代理则只需访客能访问 Perses 自身。
#     (顺带: 本模块 verify 的数据面断言走 /proxy/globaldatasources/<name>/... —— 只有不设 directUrl 才成立)
#   · Prometheus 是**软依赖**: REQUIRES 只声明 k8s_registry(硬)。运行时在内网发现 Prometheus Service,
#     找到才建数据源; 找不到只告警并跳过 provisioning, 不中断(这样 --steps perses 不会被硬拉进整套监控栈)。
#   · 容器安全: chart 默认 readOnlyRootFilesystem=true + runAsNonRoot, /perses 是 PVC、plugins 是 emptyDir,
#     无需提权。
# 数据源: cluster.conf (PERSES_* / REGISTRY_* / SERVICE_EXPOSE_MODE / CEPH_ENABLED / CEPH_CSI_ENABLED /
#                       PROMETHEUS_NAMESPACE / NODES)
# 用法:   sudo ./deploy-cluster.sh --steps perses
#         或 cluster.conf 置 PERSES_ENABLED=true(全量部署时一并安装)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

if [ "${PERSES_ENABLED:-false}" != "true" ]; then
    say "跳过 Perses(配置 PERSES_ENABLED=true 可启用)"
    exit 0
fi

init_remote_kubectl || exit 1

# ---------------- 模式与派生变量(全部来自 cluster.conf, 无硬编码) ----------------
PERSES_MODE="${PERSES_MODE:-online}"
case "${PERSES_MODE}" in
    online|offline) ;;
    *) err "PERSES_MODE 仅支持 online|offline(当前=${PERSES_MODE})"; exit 1 ;;
esac

PERSES_NAMESPACE="${PERSES_NAMESPACE:-perses}"
PERSES_RELEASE="${PERSES_RELEASE:-perses}"
# chart 版本(经典 helm repo 的版本号)与镜像 tag(appVersion)是两个东西, 不要混
PERSES_CHART_VERSION="${PERSES_CHART_VERSION:-0.23.2}"
PERSES_IMAGE_VERSION="${PERSES_IMAGE_VERSION:-v0.54.0}"
PERSES_IMAGE_NAME="${PERSES_IMAGE_NAME:-persesdev/perses}"           # 上游仓库路径(内置 registry 上同路径)
# sidecar(看板/数据源供给用): 版本对齐 08_prometheus 在用的那个 —— 同一个镜像, 离线只备一份,
# 且推入内置 registry 后路径重合 → 先到者推、后到者 reg_has_tag 跳过, 不重复传。
PERSES_SIDECAR_ENABLED="${PERSES_SIDECAR_ENABLED:-true}"
PERSES_SIDECAR_IMAGE_VERSION="${PERSES_SIDECAR_IMAGE_VERSION:-2.11.2}"
PERSES_SIDECAR_IMAGE_NAME="${PERSES_SIDECAR_IMAGE_NAME:-kiwigrid/k8s-sidecar}"

PERSES_CHART_REF="${PERSES_CHART_REF:-perses}"
PERSES_CHART_REPO="${PERSES_CHART_REPO:-https://perses.github.io/helm-charts}"
PERSES_CHART_DIR="${PERSES_CHART_DIR:-${REPO_ROOT}/deployments/cubestack-addon/perses}"
PERSES_CHART_TGZ="${PERSES_CHART_TGZ:-${PERSES_CHART_DIR}/perses-${PERSES_CHART_VERSION}.tgz}"
PERSES_OFFLINE_DIR="${PERSES_OFFLINE_DIR:-${REPO_ROOT}/deployments/offline-files/perses}"

PERSES_HARBOR="${PERSES_HARBOR:-harbor.isuanova.com}"                 # 私服(公开只读, 免凭据)
PERSES_MIRROR_PROJECT="${PERSES_MIRROR_PROJECT:-mirrors}"             # 第三方镜像统一在线源(见 images.manifest)
# 两个镜像前缀, 各司其职(不要混):
#   _SRC_IMAGE_BASE      私服 mirrors 侧(online 拉取制品的源; 节点**不**访问它)
#   PERSES_IMAGE_BASE    集群内置 registry 侧(helm --set 的目标; **两种模式都指向这里**)
_SRC_IMAGE_BASE="${PERSES_HARBOR}/${PERSES_MIRROR_PROJECT}/docker.io"
REGISTRY_BASE="${REGISTRY_DOMAIN:-registry.cubestack.io}:${REGISTRY_PORT:-5000}"
PERSES_IMAGE_BASE="${PERSES_IMAGE_BASE:-${REGISTRY_BASE}}"
PERSES_PUSH_BASE="${PERSES_PUSH_BASE:-${REGISTRY_DIRECT}}"

PERSES_STORAGE_SIZE="${PERSES_STORAGE_SIZE:-8Gi}"
PERSES_WAIT_SECONDS="${PERSES_WAIT_SECONDS:-300}"
PERSES_PROVISION_ENABLED="${PERSES_PROVISION_ENABLED:-true}"
PERSES_DATASOURCE_NAME="${PERSES_DATASOURCE_NAME:-prometheus}"
PERSES_PROMETHEUS_NAMESPACE="${PERSES_PROMETHEUS_NAMESPACE:-${PROMETHEUS_NAMESPACE:-monitoring}}"
PERSES_PROMETHEUS_URL="${PERSES_PROMETHEUS_URL:-}"                    # 留空=自动发现 Prometheus Service
PERSES_NODEPORT_BASE="${PERSES_NODEPORT_BASE:-31010}"
PERSES_EXPOSE_MODE="${PERSES_EXPOSE_MODE:-}"

# chart 的 fullname: release 名含 chart 名(perses)时直接用 release 名, 否则 <release>-perses。
# (复刻 chart helpers/_identity.tpl 的 perses.fullname; StatefulSet/Service/PVC 都用这个名字)
case "${PERSES_RELEASE}" in
    *perses*) _PERSES_FULLNAME="${PERSES_RELEASE}" ;;
    *)        _PERSES_FULLNAME="${PERSES_RELEASE}-perses" ;;
esac

# StorageClass 自动派生: 显式配置优先; 否则 ceph 体系 → ceph-block; 非 ceph → 留空(用集群默认 SC)
if [ -n "${PERSES_STORAGE_CLASS:-}" ]; then
    _SC="${PERSES_STORAGE_CLASS}"
elif [ "${CEPH_ENABLED:-false}" = "true" ] || [ "${CEPH_CSI_ENABLED:-false}" = "true" ]; then
    _SC="ceph-block"
else
    _SC=""
fi

# 镜像 tar 规范文件名: / 与 : → _(与 cubepilot-save-images.sh、harbor-save-images.sh 同一约定)
_tar_name_of() { echo "$(echo "$1" | sed 's#/#_#g; s#:#_#g').tar"; }
# 私服凭据(可选): mirrors 项目公开只读, 留空即匿名 pull
_HAVE_CREDS=0
if [ -n "${PERSES_HARBOR_USER:-}" ] && [ -n "${PERSES_HARBOR_PASSWORD:-}" ]; then
    _HAVE_CREDS=1
fi
_skopeo_src_opts() {   # 输出可选参数(空格分隔, 调用方自行展开)
    [ "${PERSES_HARBOR_INSECURE:-false}" = "true" ] && printf '%s\n' "--src-tls-verify=false"
    [ "${_HAVE_CREDS}" = "1" ] && printf '%s\n' "--src-creds" "${PERSES_HARBOR_USER}:${PERSES_HARBOR_PASSWORD}"
    return 0
}

# ---------------- 前置检查 ----------------
say "检查 Perses 前置条件(模式=${PERSES_MODE}, chart ${PERSES_CHART_VERSION}, 镜像 ${PERSES_IMAGE_VERSION})..."
command -v helm >/dev/null 2>&1 || { err "未找到 helm(需 3.0+); 安装本地 chart 必需"; exit 1; }
SSH "${K} get nodes --no-headers >/dev/null 2>&1" \
    || { err "无法访问集群(${FIRST_MASTER}); 检查 kubectl/集群状态"; exit 1; }
# 本机 helm 直连集群(与 31_cubepilot 同款: server 改写为证书 SAN 内的 API_DOMAIN)
sync_kubeconfig \
    && ok "本机 ~/.kube/config 已同步(admin.conf → API ${API_DOMAIN}→${API_IP})" \
    || { err "本机无法访问集群(admin.conf 下载/同步失败), helm 无法安装"; exit 1; }

# ============================================================
# 1. 制品就绪 —— 节点只从内置 registry 拉镜像, chart 恒用本地离线副本
# ============================================================
# 本段结束后的**不变量**(后续步骤只依赖它, 不再关心模式):
#   · ${PERSES_CHART_TGZ} 存在                        (helm 从这里装)
#   · 用到的每个组件在内置 registry 里已有 <tag> 镜像  (节点从这里拉)
mkdir -p "${PERSES_CHART_DIR}" "${PERSES_OFFLINE_DIR}"

# ---- 1a. chart 就绪: 恒用仓库内 vendored 的离线副本(online 仅用于比对刷新) ----
say "[1/7] chart 离线副本 $(basename "${PERSES_CHART_TGZ}")(模式=${PERSES_MODE})..."
if [ "${PERSES_MODE}" = "online" ] && [ "${_HAVE_CREDS}" = "1" ]; then
    # --password-stdin: 不把密码放进 argv(ps 可见); 无凭据时 helm 走匿名(该 Harbor 公开只读)
    printf '%s' "${PERSES_HARBOR_PASSWORD}" | helm registry login "${PERSES_HARBOR}" \
        -u "${PERSES_HARBOR_USER}" --password-stdin >/dev/null 2>&1 \
        || warn "  helm registry login 失败(继续尝试匿名拉取)"
fi
helm_chart_ensure "perses" "${PERSES_CHART_TGZ}" "${PERSES_CHART_VERSION}" \
    "${PERSES_MODE}" "${PERSES_CHART_REF}" "${PERSES_CHART_REPO}" || exit 1

# ---- 1b. online: 镜像同步(私服 mirrors → 本地 tar; digest 未变则跳过下载) ----
# 只负责"私服 → 本地 tar"这一段; 推入内置 registry 由 1c 统一做(两种模式共用)。
if [ "${PERSES_MODE}" = "online" ]; then
    skopeo_require "perses"
    _SYNC_N=0; _SYNC_SKIP=0; _SYNC_FB=0
    sync_perses_tar() {   # <上游仓库路径> <tag>
        local repo="$1" tag="$2"
        local src="${_SRC_IMAGE_BASE}/${repo}:${tag}"
        local tar="${PERSES_OFFLINE_DIR}/$(_tar_name_of "${src}")"
        local dgfile="${tar}.digest"
        local remote_dg="" local_dg="" ok_dl=0
        local -a srcopts=()
        while IFS= read -r _o; do
            if [ -n "${_o}" ]; then srcopts+=("${_o}"); fi
        done < <(_skopeo_src_opts)

        # ① 取私服上该 tag 的 digest(同时验证"镜像存在 + 私服可达"); 走共享助手 3 次重试 ——
        #    单次 TLS 超时不得被当成"私服没这个镜像"而静默跳过下载
        #    结果经全局回传(**不能写成 $(...)**: 子 shell 里函数设的 SKOPEO_PULL_ERR 传不出来)
        remote_image_digest "${src}" "${srcopts[@]}"; remote_dg="${SKOPEO_REMOTE_DIGEST}"
        # ② 与本地边车比对: digest 相同且 tar 在 → 跳过下载(不白传)
        [ -f "${dgfile}" ] && local_dg="$(cat "${dgfile}" 2>/dev/null || true)"
        if [ -n "${remote_dg}" ] && [ -n "${local_dg}" ] && [ "${remote_dg}" = "${local_dg}" ] && [ -f "${tar}" ]; then
            ok "  ${repo}:${tag} 私服 digest 未变, 跳过下载(本地已有 $(basename "${tar}"))"
            _SYNC_SKIP=$((_SYNC_SKIP + 1)); return 0
        fi
        # ③ 下载(共享助手: 3 次整包重试 + 失败不动原有 tar; 原因回传给下面的告警)
        if [ -n "${remote_dg}" ]; then
            say "  [拉取] ${repo}:${tag} → $(basename "${tar}")"
            if pull_image_skopeo "${src}" "${tar}" "${srcopts[@]}"; then
                printf '%s' "${remote_dg}" > "${dgfile}"
                chmod 644 "${tar}" "${dgfile}" 2>/dev/null || true
                ok "  ${repo} 已落盘(digest ${remote_dg:0:19}...)"
                _SYNC_N=$((_SYNC_N + 1)); ok_dl=1
            fi
        fi
        if [ "${ok_dl}" != "1" ]; then
            # 私服不可达/拉取失败 → 回退本地已有 tar(与 chart 的降级语义对称)
            # ⚠ 回退是**降级**不是成功: 必须把原因打出来, 否则"用着旧制品"这件事没人看得见
            if [ -f "${tar}" ]; then
                warn "  ${repo} 私服拉取失败(${SKOPEO_PULL_ERR:-未知原因}), **回退使用本地 tar**(可能是旧版本)"
                _SYNC_FB=$((_SYNC_FB + 1))
                return 0
            fi
            err "  ${repo} 私服拉取失败且本地无 tar: ${tar}"
            err "  原因: ${SKOPEO_PULL_ERR:-未知原因}"
            err "  排查: skopeo inspect docker://${src}(私服可达? tag 存在? mirrors 项目同步过?)"
            return 1
        fi
        return 0
    }
    say "[1/7] online: 从私服同步镜像(${_SRC_IMAGE_BASE}/${PERSES_IMAGE_NAME}:${PERSES_IMAGE_VERSION} ...)..."
    sync_perses_tar "${PERSES_IMAGE_NAME}" "${PERSES_IMAGE_VERSION}" || exit 1
    # sidecar 仅在启用 provisioning 时才有 Pod 去拉它 → 关闭时**完全不处理**(不下载不推送, 省流量)
    if [ "${PERSES_SIDECAR_ENABLED}" = "true" ] && [ "${PERSES_PROVISION_ENABLED}" = "true" ]; then
        sync_perses_tar "${PERSES_SIDECAR_IMAGE_NAME}" "${PERSES_SIDECAR_IMAGE_VERSION}" || exit 1
    fi
    # 汇总里必须出现"回退 N 个" —— 否则"0 新下载 0 跳过"读起来像一切正常, 实际是全部用了旧 tar
    if [ "${_SYNC_FB}" -gt 0 ]; then
        warn "  镜像同步完成(新下载 ${_SYNC_N} 个, digest 未变跳过 ${_SYNC_SKIP} 个, **回退本地旧 tar ${_SYNC_FB} 个**)"
    else
        ok "  镜像同步完成(新下载 ${_SYNC_N} 个, digest 未变跳过 ${_SYNC_SKIP} 个)"
    fi
    unset _SYNC_N _SYNC_SKIP _SYNC_FB
fi

# ---- 1c. 推入集群内置 registry(两种模式共用; 节点只从这里拉) ----
say "[1/7] 推送镜像到集群内置 registry(${PERSES_PUSH_BASE})..."
skopeo_require "perses"          # 推送必需(离线机没跑过 1b, 这里要再确认一次)
ensure_hosts_entry "${REGISTRY_IP}" "${REGISTRY_DOMAIN:-registry.cubestack.io}"   # 部署机 /etc/hosts 解析内置 registry
wait_registry_ready "http://${REGISTRY_DIRECT}/v2/" \
    || { err "集群内置 registry ${REGISTRY_DIRECT}/v2/ 不可达(当前 SERVICE_EXPOSE_MODE=${SERVICE_EXPOSE_MODE})"; exit 1; }

# 推送单个镜像: ① 已是目标 tag(幂等跳过) ② 从离线 tar 推入内置 registry
# ⚠ 内置 registry 上的仓库路径 = **上游仓库路径去掉注册域**(与 images.manifest 的 mirrors 规则一致,
#   也与 08_prometheus 推 kiwigrid/k8s-sidecar 的落点重合 → 两边谁先推谁生效, 后者跳过)
push_perses_image() {   # <上游仓库路径> <tag>
    local repo="$1" tag="$2" _t="" _src=""
    if reg_has_tag "${PERSES_PUSH_BASE}" "${repo}" "${tag}"; then
        ok "  ${repo}:${tag} 已在内置 registry, 跳过"
        return 0
    fi
    _t="${PERSES_OFFLINE_DIR}/$(_tar_name_of "${_SRC_IMAGE_BASE}/${repo}:${tag}")"
    if [ ! -f "${_t}" ]; then
        # 兜底扫描: 目录内 *.tar 按**内容里的 ref** 匹配。
        # ⚠ 必须如此 —— tar 文件名带的是**上游 ref**(如 docker.io_persesdev_perses_v0.54.0.tar,
        #   由 tools/images/harbor-save-images.sh 产出), 与本模块的私服 ref 前缀不同;
        #   这不是异常, 是仓库既有约定(注册域前缀不定, 各模块统一按后缀/内容匹配)。
        local _f
        for _f in "${PERSES_OFFLINE_DIR}"/*.tar; do
            [ -f "${_f}" ] || continue
            case "$(tar_first_image_tag "${_f}")" in
                *"/${repo}:"*) _t="${_f}"; break ;;
            esac
        done
        if [ -n "${_t}" ] && [ -f "${_t}" ]; then
            _src="$(tar_first_image_tag "${_t}")"
            case "${_src}" in
                *"/${repo}:"*) : ;;
                *) warn "  $(basename "${_t}") 内容为 ${_src:-<读不出>}, 非 ${repo}, 跳过"
                   _t="" ;;
            esac
        fi
        unset _f
    fi
    if [ -z "${_t}" ] || [ ! -f "${_t}" ]; then
        err "  离线镜像缺失: ${repo}:${tag}"
        err "  online : 检查私服可达性后重跑(会自动同步)"
        err "  离线机 : ./deployments/scripts/tools/images/harbor-save-images.sh --group perses"
        err "           (源是私服 mirrors; 首次需先跑 harbor-sync-images.sh 把上游同步到 mirrors)"
        return 1
    fi
    say "  推送 ${repo}:${tag} → ${PERSES_PUSH_BASE}/${repo}:${tag}(源: $(basename "${_t}"))"
    if push_image_skopeo "docker-archive:${_t}" "docker://${PERSES_PUSH_BASE}/${repo}:${tag}" >/dev/null 2>&1; then
        ok "  ${repo} 已推入内置 registry"
    else
        err "  ${repo} 推送失败(skopeo copy docker-archive:${_t} → docker://${PERSES_PUSH_BASE}/${repo}:${tag})"
        return 1
    fi
}
push_perses_image "${PERSES_IMAGE_NAME}" "${PERSES_IMAGE_VERSION}" || exit 1
if [ "${PERSES_SIDECAR_ENABLED}" = "true" ] && [ "${PERSES_PROVISION_ENABLED}" = "true" ]; then
    push_perses_image "${PERSES_SIDECAR_IMAGE_NAME}" "${PERSES_SIDECAR_IMAGE_VERSION}" || exit 1
else
    say "  跳过 ${PERSES_SIDECAR_IMAGE_NAME}(未启用 provisioning 或 sidecar)"
fi

# ---------------- 2. 命名空间 ----------------
# 不需要 imagePullSecret / 节点级凭据: 节点只访问内置 registry(免认证且节点已信任)。
say "[2/7] 准备命名空间 ${PERSES_NAMESPACE}..."
SSH "${K} create namespace ${PERSES_NAMESPACE} >/dev/null 2>&1" || true    # 幂等: 已存在时 create 失败属正常
SSH "${K} get namespace ${PERSES_NAMESPACE} >/dev/null 2>&1" \
    || { err "无法创建/访问命名空间 ${PERSES_NAMESPACE}"; exit 1; }
ok "  命名空间就绪(镜像来自内置 registry, 无需 imagePullSecret)"

# ---------------- 3. 数据源供给(可选, 默认开) ----------------
# 建一个带 sidecar 标签的 ConfigMap, sidecar 监听到后写入 provisioning 目录, Perses 的
# provisioning 机制加载它。**不用已废弃的 chart `datasources:` 列表**(上游标注将来移除)。
# ⚠ Prometheus 是软依赖: 找不到就不建数据源(只告警), 不中断整个安装。
_DATASOURCE_READY=0
if [ "${PERSES_PROVISION_ENABLED}" != "true" ]; then
    say "[3/7] PERSES_PROVISION_ENABLED!=true, 跳过数据源供给(装完在 UI 里手工配)"
elif [ "${PERSES_SIDECAR_ENABLED}" != "true" ]; then
    warn "  [3/7] sidecar 未启用, 无法自动供给数据源(置 PERSES_SIDECAR_ENABLED=true 或手工在 UI 配)"
else
    say "[3/7] 供给 Prometheus 数据源(GlobalDatasource ${PERSES_DATASOURCE_NAME})..."
    _PROM_URL="${PERSES_PROMETHEUS_URL}"
    if [ -z "${_PROM_URL}" ]; then
        # 自动发现: 在 PROMETHEUS 命名空间里找"名字含 prometheus、不是 headless、带 9090 端口"的 Service。
        # 不硬编码服务名 —— 它由 release 名 + chart 规则派生(kube-prometheus-stack 会截断), 写死必错。
        _PROM_SVC="$( (SSH "${K} -n ${PERSES_PROMETHEUS_NAMESPACE} get svc -o jsonpath='{range .items[*]}{.metadata.name}{\"|\"}{.spec.ports[*].port}{\"\n\"}{end}' 2>/dev/null" || true) \
            | awk -F'|' '$1 ~ /prometheus/ && $1 !~ /headless/ && $2 ~ /(^| )9090( |$)/ {print $1; exit}' )"
        if [ -n "${_PROM_SVC}" ]; then
            # FQDN 结尾带 .svc.cluster.local, 避免受 Pod 的 search 域影响
            _PROM_URL="http://${_PROM_SVC}.${PERSES_PROMETHEUS_NAMESPACE}.svc.cluster.local:9090"
            ok "    自动发现 Prometheus Service: ${_PROM_SVC}(ns ${PERSES_PROMETHEUS_NAMESPACE})"
        fi
    fi
    if [ -z "${_PROM_URL}" ]; then
        warn "    未发现 Prometheus Service(ns ${PERSES_PROMETHEUS_NAMESPACE}); 跳过数据源供给"
        warn "    装完可用 PERSES_PROMETHEUS_URL 显式指定后端地址后重跑本模块"
    else
        # ⚠ **故意不设 directUrl**: 设了它浏览器必须能直连 Prometheus, 而 port-forward 场景下
        #   *.svc.cluster.local 在浏览器侧解析不了 → UI 必然报错。走 proxy 则只需访客能访问 Perses。
        #   (顺带: verify 的数据面断言走 /proxy/globaldatasources/... —— 只有不设 directUrl 才成立)
        _DS_YAML="$(mktemp)"
        ( umask 077; cat > "${_DS_YAML}" <<PERSES_DS_EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${PERSES_RELEASE}-datasource-${PERSES_DATASOURCE_NAME}
  namespace: ${PERSES_NAMESPACE}
  labels:
    perses.dev/resource: "true"
data:
  ${PERSES_DATASOURCE_NAME}.yaml: |
    kind: GlobalDatasource
    metadata:
      name: ${PERSES_DATASOURCE_NAME}
    spec:
      default: true
      plugin:
        kind: PrometheusDatasource
        spec:
          proxy:
            kind: HTTPProxy
            spec:
              url: ${_PROM_URL}
PERSES_DS_EOF
        )
        if SSH "${K} apply -f -" < "${_DS_YAML}" >/dev/null 2>&1; then
            ok "    数据源 ConfigMap 已下发(后端 ${_PROM_URL}, 经 Perses 服务端代理)"
            _DATASOURCE_READY=1
        else
            warn "    数据源 ConfigMap 下发失败; 装完在 UI 里手工加数据源"
        fi
        rm -f "${_DS_YAML}"; unset _DS_YAML
    fi
    unset _PROM_SVC
fi

# ---------------- 4. helm 安装(恒本地 tgz + 恒内置 registry 镜像) ----------------
# 两种模式**在这里完全合流**: chart 一律取自本地 tgz(1a 已确保存在), 镜像一律指向内置 registry。
say "[4/7] helm upgrade --install ${PERSES_RELEASE}(→ ${PERSES_NAMESPACE})..."
say "  chart 来源: 本地 ${PERSES_CHART_TGZ}"
# 走**临时 values 文件**(mktemp + umask 077), 不用 --set:
# config.provisioning.folders 是数组、sidecar 是嵌套结构, --set 既易错又难 review(同 08_prometheus 的理由)
_VALUES_YAML="$(mktemp)"
( umask 077; cat > "${_VALUES_YAML}" <<PERSES_VALUES_EOF
# Perses(模块 perses 生成, 勿手改 —— 改 cluster.conf 后重跑)
image:
  registry: ${PERSES_IMAGE_BASE}
  name: ${PERSES_IMAGE_NAME}
  version: ${PERSES_IMAGE_VERSION}

replicas: 1

persistence:
  enabled: true              # false 时 chart 用 emptyDir → Pod 重建即丢全部看板
  storageClass: ${_SC}
  size: ${PERSES_STORAGE_SIZE}
  securityContext:
    fsGroup: 2000            # v0.53+ 容器用户 nobody→nonroot, 文件存储必须让 PVC 可写

config:
  database:
    file:
      folder: /perses
      extension: json
  provisioning:
    folders:
      - /etc/perses/provisioning
    interval: 1m             # 上游默认 10m, 装完要干等十分钟才出现看板

sidecar:
  enabled: ${PERSES_SIDECAR_ENABLED}
  image:
    registry: ${PERSES_IMAGE_BASE}
    repository: ${PERSES_SIDECAR_IMAGE_NAME}
    tag: ${PERSES_SIDECAR_IMAGE_VERSION}
  label: perses.dev/resource
  labelValue: "true"
  allNamespaces: true        # chart 据此建 ClusterRole(configmaps get/watch/list)

serviceMonitor:
  selfMonitor: true          # 集群 Prometheus 是 serviceMonitorSelector:{} 全选, 无需额外标签

# 按 2026-09-18 定案: 模块**不创建** Gateway / HTTPRoute / Ingress, 对外由专门的网关模块负责。
gateway:
  enabled: false
ingress:
  enabled: false

# chart 的 helm test 用 ghcr.io 上的镜像, 离线环境拉不到 → 关掉模板
testFramework:
  enabled: false
PERSES_VALUES_EOF
)
if [ -n "${_SC}" ]; then
    say "  PVC StorageClass: ${_SC}(持久化 ${PERSES_STORAGE_SIZE})"
else
    say "  PVC StorageClass: 留空(回落集群默认 StorageClass)"
fi
say "  镜像: ${PERSES_IMAGE_BASE}/${PERSES_IMAGE_NAME}:${PERSES_IMAGE_VERSION}"
[ "${PERSES_SIDECAR_ENABLED}" = "true" ] && say "  sidecar: ${PERSES_IMAGE_BASE}/${PERSES_SIDECAR_IMAGE_NAME}:${PERSES_SIDECAR_IMAGE_VERSION}"
# --wait 超时只 warn: 资源可能已创建(镜像首次拉取较慢), 后面按实际状态判定
# ⚠ 本地 tgz 的版本由文件本身决定, **不传 --version**(那是远端源才有效的参数)
helm upgrade --install "${PERSES_RELEASE}" "${PERSES_CHART_TGZ}" \
    --namespace "${PERSES_NAMESPACE}" --create-namespace \
    -f "${_VALUES_YAML}" \
    --wait --timeout "${PERSES_WAIT_SECONDS}s" \
    || warn "  helm --wait 超时(资源可能已创建; 继续按实际状态检查)"
rm -f "${_VALUES_YAML}"; unset _VALUES_YAML

# ---------------- 5. 等待工作负载就绪 ----------------
# ⚠ chart 在 file 数据库下渲染的是 **StatefulSet**(不是 Deployment); 这里不写死类型, 按实际发现。
say "[5/7] 等待 Perses 工作负载就绪(最长 ${PERSES_WAIT_SECONDS}s)..."
_WL_KIND=""; _WL_NAME=""
for _k in statefulset deployment; do
    _n="$( (SSH "${K} -n ${PERSES_NAMESPACE} get ${_k} -o name 2>/dev/null" || true) | sed -n 's#.*/##p' | head -1 || true)"
    if [ -n "${_n}" ]; then _WL_KIND="${_k}"; _WL_NAME="${_n}"; break; fi
done
unset _k _n
if [ -z "${_WL_NAME}" ]; then
    warn "  未发现 Perses 工作负载(helm 安装是否成功? kubectl -n ${PERSES_NAMESPACE} get all)"
else
    SSH "${K} -n ${PERSES_NAMESPACE} rollout status ${_WL_KIND}/${_WL_NAME} --timeout=${PERSES_WAIT_SECONDS}s" >/dev/null 2>&1 \
        && ok "  ${_WL_KIND}/${_WL_NAME} 就绪" \
        || warn "  ${_WL_KIND}/${_WL_NAME} 未在 ${PERSES_WAIT_SECONDS}s 内就绪(检查 pods 与镜像拉取)"
fi
# PVC 已绑定? (未绑定说明 StorageClass 有问题, 是"看着在跑但数据其实在 emptyDir"之外的另一种坑)
_PVC_PH="$( (SSH "${K} -n ${PERSES_NAMESPACE} get pvc ${_PERSES_FULLNAME} -o jsonpath='{.status.phase}' 2>/dev/null" || true) || true)"
if [ -n "${_PVC_PH}" ]; then
    [ "${_PVC_PH}" = "Bound" ] && ok "  PVC ${_PERSES_FULLNAME} 已 Bound(${_SC:-集群默认 SC})" \
                               || warn "  PVC ${_PERSES_FULLNAME} 状态 ${_PVC_PH}(StorageClass 是否可用?)"
else
    warn "  未找到 PVC ${_PERSES_FULLNAME}(persistence.enabled=true 却没建出来? 检查 values)"
fi

# ---------------- 6. 对外暴露(nodeport / loadbalancer; 默认随 SERVICE_EXPOSE_MODE) ----------------
# 按 2026-09-18 定案, 本模块**不建 Gateway/HTTPRoute/Ingress**; 需要集群外访问时用 NodePort/LB,
# 或交由专门的网关模块统一下发路由。默认 clusterip 时只给 port-forward 指引(见末尾汇总)。
say "[6/7] 配置 Perses 对外暴露(PERSES_EXPOSE_MODE=${PERSES_EXPOSE_MODE:-<随 SERVICE_EXPOSE_MODE>})..."
PERSES_EXPOSE_MODE="${PERSES_EXPOSE_MODE:-${SERVICE_EXPOSE_MODE:-clusterip}}"
PERSES_EXPOSE_MODE="$(echo "${PERSES_EXPOSE_MODE}" | tr '[:upper:]' '[:lower:]')"
_PERSES_APP_PORT=8080
case "${PERSES_EXPOSE_MODE}" in
    nodeport)
        _ext_port="${PERSES_NODEPORT_BASE}"
        say "  Perses: NodePort ${_ext_port}(独立 Service ${_PERSES_FULLNAME}-external)..."
        # 直接 apply 完整 YAML(幂等), 不用 kubectl create service nodeport —— 后者会把 targetPort
        # 也写成外部端口, 且自带一个不存在的 selector(app=<svc名>), 导致 Endpoints 永远为空。
        # (这两处是 08_prometheus 踩过的坑, 见其 [8/8] 段注释)
        _ext_yaml="$(mktemp)"
        cat > "${_ext_yaml}" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${_PERSES_FULLNAME}-external
  namespace: ${PERSES_NAMESPACE}
  labels:
    app.kubernetes.io/name: ${_PERSES_FULLNAME}-external
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: perses
    app.kubernetes.io/instance: ${PERSES_RELEASE}
  ports:
    - port: ${_ext_port}
      targetPort: ${_PERSES_APP_PORT}
      nodePort: ${_ext_port}
      protocol: TCP
EOF
        SSH "${K} -n ${PERSES_NAMESPACE} delete svc ${_PERSES_FULLNAME}-external --ignore-not-found=true >/dev/null 2>&1" || true
        SSH "${K} -n ${PERSES_NAMESPACE} apply -f -" < "${_ext_yaml}" >/dev/null 2>&1 \
            && ok "  Perses 外部入口: http://<节点IP>:${_ext_port}/  (target ${_PERSES_APP_PORT})" \
            || warn "  外部 Service 创建失败(kubectl -n ${PERSES_NAMESPACE} get svc ${_PERSES_FULLNAME}-external)"
        rm -f "${_ext_yaml}"; unset _ext_yaml
        ;;
    loadbalancer)
        if [ -n "$( (SSH "${K} get ns metallb-system --no-headers 2>/dev/null" || true) )" ]; then
            say "  Perses: LoadBalancer(需 MetalLB)..."
            SSH "${K} -n ${PERSES_NAMESPACE} patch svc ${_PERSES_FULLNAME} --type merge -p '{"spec":{"type":"LoadBalancer"}}' >/dev/null 2>&1" || true
        else
            warn "  MetalLB 未部署; Perses 保持 ClusterIP(可改 PERSES_EXPOSE_MODE=nodeport)"
        fi
        ;;
    *) say "  Perses: ClusterIP(仅集群内; port-forward 见末尾)" ;;
esac

# ---------------- 7. 汇总 ----------------
echo "---------------------------------------------"
ok "Perses 部署完成"
echo "  模式:        ${PERSES_MODE}$( [ "${PERSES_MODE}" = "online" ] && echo "(已从私服 ${PERSES_HARBOR} 同步镜像制品)" || echo "(未联网, 使用本地制品)" )"
echo "  chart:       $(basename "${PERSES_CHART_TGZ}")(仓库内 vendored 离线副本, 随 git 分发)"
echo "  镜像:        ${PERSES_IMAGE_BASE}/${PERSES_IMAGE_NAME}:${PERSES_IMAGE_VERSION}"
echo "               (统一来自集群内置 registry; 节点不需任何私服凭据)"
echo "  namespace:   ${PERSES_NAMESPACE}(helm release ${PERSES_RELEASE}, 工作负载 ${_WL_KIND:-?}/${_WL_NAME:-?})"
echo "  持久化:      ${PERSES_STORAGE_SIZE} @ ${_SC:-<集群默认 SC>}(PVC ${_PERSES_FULLNAME})"
echo "  离线制品:    ${PERSES_OFFLINE_DIR}/(镜像 tar, 可直接切纯离线)"
if [ "${_DATASOURCE_READY}" = "1" ]; then
    echo "  数据源:      GlobalDatasource/${PERSES_DATASOURCE_NAME} → ${_PROM_URL:-?}(经 Perses 服务端代理)"
else
    echo "  数据源:      未自动供给(装完在 UI 的 Datasources 里手工添加)"
fi
echo "  资源查看:    kubectl -n ${PERSES_NAMESPACE} get statefulset,pods,svc,pvc"
echo "  端口转发:    kubectl -n ${PERSES_NAMESPACE} port-forward svc/${_PERSES_FULLNAME} 8080:8080   # http://127.0.0.1:8080"
echo "  端到端验证:  sudo ./deploy-cluster.sh --steps verify_perses"
echo "  切纯离线:    cluster.conf 置 PERSES_MODE=offline —— chart 用仓库内离线副本,"
echo "               镜像用 ${PERSES_OFFLINE_DIR}/(上面那次 online 已备好), 无需其他准备"
echo "  卸载:        helm uninstall ${PERSES_RELEASE} -n ${PERSES_NAMESPACE}"
echo "               ⚠ PVC ${_PERSES_FULLNAME} 不会随 helm 删除(需手工删才能真正清数据)"
