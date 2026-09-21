#!/bin/bash
# ============================================================
# MODULE: cubepilot
# DESC: CubePilot 平台(AI Agent 平台; 4 镜像 + 1 chart。默认 online=先从私服同步制品, 再统一经集群内置 registry 部署)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: CUBEPILOT_ENABLED
# REQUIRES: k8s_registry
# 说明:
#   · **制品流向统一(核心)**: 不论哪种模式, 节点**只从集群内置 registry 拉镜像**, 部署机 helm 装**本地 chart tgz**。
#       online  = 部署前先从私服 Harbor 同步制品到本地(镜像 pull 成 offline-files/cubepilot/*.tar),
#                 再推入内置 registry, 之后与 offline **同路**部署; chart 另见下条(恒用本地副本)
#       offline = 不碰外网, 直接用盘上已有制品(联网机预置的, 或上一次 online 留下的)推入内置 registry 后部署
#     ⇒ 两种模式的**部署路径是同一段代码**, 差别只在"开头要不要联网同步"。
#     ⚠ online 在私服不可达时**自动降级**: 拉不到就退回本地已有制品(告警, 不中断); 本地也没有才报错。
#   · **chart 恒用仓库内 vendored 的离线副本**(cubestack-addon/cubepilot/cubepilot-<ver>.tgz, 随 git 分发)。
#     online **不直接装私服上拉到的那份** —— 它只负责拿远端 digest 与 <tgz>.digest 边车比对:
#     未变 → 继续用本地那份(仓库保持干净); 有更新 → 覆盖本地副本并提示 commit; 拉取失败 → 回退本地那份。
#     实现收敛在 lib-common 的 helm_chart_ensure(全仓库统一约定, 见 docs/scripts-development-spec.md §2.4)。
#     ⇒ 所以**离线副本缺失就是致命错误**(拿不到任何 chart), 必须随仓库提交, 不能只在部署时拉到盘上。
#   · 私服 Harbor: harbor.isuanova.com/suanova —— 该项目**公开只读(anonymous pull)**, 无需任何凭据;
#     如将来收紧为私有, 配 CUBEPILOT_HARBOR_USER/PASSWORD 即可(helm 与 skopeo 两侧都会带上)。
#     私服自签证书时置 CUBEPILOT_HARBOR_INSECURE=true 跳过 TLS 校验。
#   · 制品来源(chart 版本 ↔ 镜像 tag 一一对应):
#       chart : oci://harbor.isuanova.com/suanova/cubepilot-chart
#               ⚠ 仓库名是 **cubepilot-chart**, 不是 cubepilot(曾经写错, 那个仓库不存在)
#       镜像  : harbor.isuanova.com/suanova/cubepilot-{openclaw,operator,api,web}
#       main 分支 → chart 0.1.0-latest + 镜像 :latest; 正式 tag vX.Y.Z → chart X.Y.Z + 镜像 :X.Y.Z
#     (本模块自动派生: 版本以 -latest 结尾 → tag=latest, 否则 tag=chart 版本; CUBEPILOT_IMAGE_TAG 可覆盖)
#     ⚠ chart 各镜像默认 tag 是 :latest, **会跟上游漂移** → 本模块恒显式传 4 个镜像 ref 锁到内置 registry。
#   · 制品刷新(online): 每次部署都校验一遍, 但**不白传** ——
#       ① skopeo inspect 取私服上该 tag 的 digest;
#       ② 与本地 <tar>.digest 边车文件比对: 相同且 tar 在 → 跳过下载(仍会 push, push 本身幂等);
#          不同或 tar/边车缺失 → 重新 pull 覆盖。
#     想强制重拉: 删掉对应 tar(或它的 .digest 边车)即可。
#     digest 存**边车文件**而非集中清单 —— 制品拷到别的机器时 digest 跟着走; 无边车视为"未知"→ 重下(安全默认)。
#   · 无需节点级凭据 / 无需 imagePullSecret: 节点只访问内置 registry(免认证且节点已信任),
#     不需要任何私服凭据 —— operator 运行时为用户**铸造 ServiceAccount** 也照样能拉,
#     这正是 per-SA imagePullSecret "挂不全/被 operator 覆盖"老问题的根治(旧版 online 直连私服时才需要节点级 certs.d)。
#   · CRD 归属(两类, 不要混淆): chart 的 crds/ 目录内置 6 个 **ai.cubestack.io** CRD,
#     helm install 时自动装上(AgentInstance 等), 无需干预;
#     CubePilot 自带的另一个 **CubeStack 平台 CRD**(DevEnvironment / InferenceService / ...)chart 不含,
#     需从 cubepilot 源仓库 test/e2e/framework/testdata/cubestack-crds 取 —— 默认关闭, 见 CUBEPILOT_PLATFORM_CRDS_ENABLED。
#   · StorageClass: 两个 PVC(cubepilot-api-data 元数据 / cubepilot-api-skill-repo 共享技能仓)
#     的 storageClassName **非空才生效**, 留空则回落到集群默认 SC。本模块默认自动派生:
#     Ceph 体系启用(lib-common 已归一 REGISTRY_STORAGE_CLASS=ceph-block)→ 传 ceph-block;
#     否则留空(用集群默认), 避免纯 local-path 集群上 PVC 永久 Pending。
#   · 内置 Portal: chart 自带 React 门户(cubepilot-web; nginx 提供 SPA 页面并把 /api 反代给 api)。
#     **CUBEPILOT_WEB_ENABLED 默认 true** —— 装完即可用: port-forward svc/cubepilot 8080:8080。
#     置 false(如已有统一 UI 接管前端)则不建 cubepilot-web Deployment 与相关 Service,
#     同步/推送阶段也会跳过 web 镜像, 不白传。
#   · LLM: 默认**无心智模型**(不假设平台已有 LLM), 装完在 Portal 的 Agent Config → LLM Config 里加。
#     要在安装时预置平台默认模型: 填 CUBEPILOT_LLM_ENDPOINT / CUBEPILOT_LLM_MODEL
#     + CUBEPILOT_LLM_API_KEY。
#   · 对外访问: 本模块只装组件, **不管暴露** —— 平台网关与各服务路由由**专门的网关模块**统一
#     创建(尚在重构中, 待落地后 cubepilot-api.cubestack.io / cubepilot.cubestack.io 由该模块下发)。
#     当前入口: port-forward(见模块末尾汇总)。
# 数据源: cluster.conf (CUBEPILOT_* / REGISTRY_* / SERVICE_EXPOSE_MODE / REGISTRY_STORAGE_CLASS /
#                       CEPH_ENABLED / CEPH_CSI_ENABLED / SSH_KEY_NAME / NODES)
# 用法:   sudo ./deploy-cluster.sh --steps cubepilot
#         或 cluster.conf 置 CUBEPILOT_ENABLED=true(全量部署时一并安装)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

if [ "${CUBEPILOT_ENABLED:-false}" != "true" ]; then
    say "跳过 CubePilot(配置 CUBEPILOT_ENABLED=true 可启用)"
    exit 0
fi

init_remote_kubectl || exit 1

# ---------------- 模式与派生变量(全部来自 cluster.conf, 无硬编码) ----------------
CUBEPILOT_MODE="${CUBEPILOT_MODE:-online}"
case "${CUBEPILOT_MODE}" in
    online|offline) ;;
    *) err "CUBEPILOT_MODE 仅支持 online|offline(当前=${CUBEPILOT_MODE})"; exit 1 ;;
esac

CUBEPILOT_HARBOR="${CUBEPILOT_HARBOR:-harbor.isuanova.com}"          # 私服域名(公开只读, 免凭据)
CUBEPILOT_PROJECT="${CUBEPILOT_PROJECT:-suanova}"                     # Harbor 项目名(也是内置 registry 下的仓库前缀)
CUBEPILOT_VERSION="${CUBEPILOT_VERSION:-0.1.0-latest}"                # chart 版本(= OCI tag)
CUBEPILOT_NAMESPACE="${CUBEPILOT_NAMESPACE:-cubepilot}"
CUBEPILOT_RELEASE="${CUBEPILOT_RELEASE:-cubepilot}"
# ⚠ chart 仓库名是 cubepilot-chart(不是 cubepilot) —— 曾经写错成后者, 那个仓库根本不存在
CUBEPILOT_CHART_REF="${CUBEPILOT_CHART_REF:-oci://${CUBEPILOT_HARBOR}/${CUBEPILOT_PROJECT}/cubepilot-chart}"
CUBEPILOT_CHART_DIR="${CUBEPILOT_CHART_DIR:-${REPO_ROOT}/deployments/cubestack-addon/cubepilot}"
CUBEPILOT_CHART_TGZ="${CUBEPILOT_CHART_TGZ:-${CUBEPILOT_CHART_DIR}/cubepilot-${CUBEPILOT_VERSION}.tgz}"
CUBEPILOT_OFFLINE_DIR="${CUBEPILOT_OFFLINE_DIR:-${REPO_ROOT}/deployments/offline-files/cubepilot}"
# 镜像 tag 派生: main 线(chart 版本以 -latest 结尾)发布 :latest; 正式 tag vX.Y.Z 发布 :X.Y.Z。
# 显式设 CUBEPILOT_IMAGE_TAG 可覆盖(如 chart 与镜像 tag 不同步时的应急口)。
if [ -n "${CUBEPILOT_IMAGE_TAG:-}" ]; then
    _IMG_TAG="${CUBEPILOT_IMAGE_TAG}"
elif [ "${CUBEPILOT_VERSION%-latest}" != "${CUBEPILOT_VERSION}" ]; then
    _IMG_TAG="latest"
else
    _IMG_TAG="${CUBEPILOT_VERSION}"
fi
# 两个镜像前缀, 各司其职(不要混):
#   _SRC_IMAGE_BASE       私服 Harbor 侧(online 拉取制品的源; 节点**不**访问它)
#   CUBEPILOT_IMAGE_BASE  集群内置 registry 侧(helm --set 的目标; **两种模式都指向这里**)
_SRC_IMAGE_BASE="${CUBEPILOT_HARBOR}/${CUBEPILOT_PROJECT}"
REGISTRY_BASE="${REGISTRY_DOMAIN:-registry.cubestack.io}:${REGISTRY_PORT:-5000}"
CUBEPILOT_IMAGE_BASE="${CUBEPILOT_IMAGE_BASE:-${REGISTRY_BASE}/${CUBEPILOT_PROJECT}}"
CUBEPILOT_PUSH_BASE="${CUBEPILOT_PUSH_BASE:-${REGISTRY_DIRECT}/${CUBEPILOT_PROJECT}}"   # 推送直连端点(nodeport→master:NP / metallb→VIP)
CUBEPILOT_WEB_ENABLED="${CUBEPILOT_WEB_ENABLED:-true}"
CUBEPILOT_WAIT_SECONDS="${CUBEPILOT_WAIT_SECONDS:-300}"
CUBEPILOT_LLM_SECRET="${CUBEPILOT_LLM_SECRET:-cubepilot-llm}"
CUBEPILOT_PLATFORM_CRDS_ENABLED="${CUBEPILOT_PLATFORM_CRDS_ENABLED:-false}"
CUBEPILOT_PLATFORM_CRDS_DIR="${CUBEPILOT_PLATFORM_CRDS_DIR:-${CUBEPILOT_CHART_DIR}/cubestack-crds}"
# StorageClass 自动派生: 显式配置优先; 否则 ceph 体系 → ceph-block(与 registry 后端同 SC);
# 非 ceph → 留空(PVC 走集群默认 SC)。⚠ 与 issue 的"non-empty 才生效"语义一致: 留空时不传参。
if [ -n "${CUBEPILOT_STORAGE_CLASS:-}" ]; then
    _SC="${CUBEPILOT_STORAGE_CLASS}"
elif [ "${CEPH_ENABLED:-false}" = "true" ] || [ "${CEPH_CSI_ENABLED:-false}" = "true" ]; then
    _SC="ceph-block"
else
    _SC=""
fi
# 镜像 tar 规范文件名: / 与 : → _(与 cubepilot-save-images.sh、envoy-save-images.sh 同一约定)
_tar_name_of() { echo "$(echo "$1" | sed 's#/#_#g; s#:#_#g').tar"; }
# 私服凭据(可选): 该 Harbor 公开只读, 留空即匿名 pull; 配了则 helm/skopeo 两侧都带上
_HAVE_CREDS=0
if [ -n "${CUBEPILOT_HARBOR_USER:-}" ] && [ -n "${CUBEPILOT_HARBOR_PASSWORD:-}" ]; then
    _HAVE_CREDS=1
fi
# skopeo 访问私服的开关(仅 online 拉取用; 默认开启 TLS 校验)
_skopeo_src_opts() {   # 输出可选参数(空格分隔调用方自行展开)
    [ "${CUBEPILOT_HARBOR_INSECURE:-false}" = "true" ] && printf '%s\n' "--src-tls-verify=false"
    [ "${_HAVE_CREDS}" = "1" ] && printf '%s\n' "--src-creds" "${CUBEPILOT_HARBOR_USER}:${CUBEPILOT_HARBOR_PASSWORD}"
    return 0
}

# ---------------- 前置检查 ----------------
say "检查 CubePilot 前置条件(模式=${CUBEPILOT_MODE}, chart ${CUBEPILOT_VERSION}, 镜像 tag ${_IMG_TAG})..."
command -v helm >/dev/null 2>&1 || { err "未找到 helm(需 3.0+); 安装本地 chart 必需"; exit 1; }
SSH "${K} get nodes --no-headers >/dev/null 2>&1" \
    || { err "无法访问集群(${FIRST_MASTER}); 检查 kubectl/集群状态"; exit 1; }
# 本机 helm 直连集群(与 16_envoy_ai_gateway 同款: server 改写为证书 SAN 内的 API_DOMAIN)
sync_kubeconfig \
    && ok "本机 ~/.kube/config 已同步(admin.conf → API ${API_DOMAIN}→${API_IP})" \
    || { err "本机无法访问集群(admin.conf 下载/同步失败), helm 无法安装"; exit 1; }

# ============================================================
# 1. 制品就绪 —— 节点只从内置 registry 拉镜像, chart 恒用本地离线副本
# ============================================================
# 本段结束后的**不变量**(后续步骤只依赖它, 不再关心模式):
#   · ${CUBEPILOT_CHART_TGZ} 存在                       (helm 从这里装)
#   · 用到的每个组件在内置 registry 里已有 <tag> 镜像    (节点从这里拉)
mkdir -p "${CUBEPILOT_CHART_DIR}" "${CUBEPILOT_OFFLINE_DIR}"

# ---- 1a. chart 就绪: 恒用仓库内 vendored 的离线副本 ----
# online **不直接装私服上拉到的那份** —— 它的作用是拿远端 digest 与 <tgz>.digest 边车比对,
# 决定要不要刷新本地这份副本(见 lib-common helm_chart_ensure):
#   digest 未变 → 继续用本地那份(仓库保持干净); 有更新 → 覆盖并提示 commit;
#   拉取失败    → 降级回退本地那份(这正是本地副本存在的意义)。
# offline 完全不联网。⚠ 离线副本必须**随 git 分发** —— 只在部署时拉到盘上不算数。
say "[1/7] chart 离线副本 $(basename "${CUBEPILOT_CHART_TGZ}")(模式=${CUBEPILOT_MODE})..."
if [ "${CUBEPILOT_MODE}" = "online" ] && [ "${_HAVE_CREDS}" = "1" ]; then
    # --password-stdin: 不把密码放进 argv(ps 可见); 无凭据时 helm 走匿名(该 Harbor 公开只读)
    printf '%s' "${CUBEPILOT_HARBOR_PASSWORD}" | helm registry login "${CUBEPILOT_HARBOR}" \
        -u "${CUBEPILOT_HARBOR_USER}" --password-stdin >/dev/null 2>&1 \
        || warn "  helm registry login 失败(继续尝试匿名拉取)"
fi
helm_chart_ensure "cubepilot" "${CUBEPILOT_CHART_TGZ}" "${CUBEPILOT_VERSION}" \
    "${CUBEPILOT_MODE}" "${CUBEPILOT_CHART_REF}" || exit 1

# ---- 1b. online: 镜像同步(私服 pull → 本地 tar; digest 未变则跳过下载) ----
# 只负责"私服 → 本地 tar"这一段; 推入内置 registry 由 1c 统一做(两种模式共用)。
if [ "${CUBEPILOT_MODE}" = "online" ]; then
    skopeo_require "cubepilot"     # 拉取与推送都依赖 skopeo
    _SYNC_N=0; _SYNC_SKIP=0; _SYNC_FB=0
    sync_cubepilot_tar() {   # <comp>
        local comp="$1"
        local src="${_SRC_IMAGE_BASE}/cubepilot-${comp}:${_IMG_TAG}"
        local tar="${CUBEPILOT_OFFLINE_DIR}/$(_tar_name_of "${src}")"
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
            ok "  cubepilot-${comp}:${_IMG_TAG} 私服 digest 未变, 跳过下载(本地已有 $(basename "${tar}"))"
            _SYNC_SKIP=$((_SYNC_SKIP + 1)); return 0
        fi
        # ③ 下载(走共享助手: 3 次整包重试 + 失败不动原有 tar; 原因回传给下面的告警)
        if [ -n "${remote_dg}" ]; then
            say "  [拉取] cubepilot-${comp}:${_IMG_TAG} → $(basename "${tar}")"
            if pull_image_skopeo "${src}" "${tar}" "${srcopts[@]}"; then
                printf '%s' "${remote_dg}" > "${dgfile}"
                chmod 644 "${tar}" "${dgfile}" 2>/dev/null || true
                ok "  cubepilot-${comp} 已落盘(digest ${remote_dg:0:19}...)"
                _SYNC_N=$((_SYNC_N + 1)); ok_dl=1
            fi
        fi
        if [ "${ok_dl}" != "1" ]; then
            # 私服不可达/拉取失败 → 回退本地已有 tar(与 chart 的降级语义对称)
            # ⚠ 回退是**降级**不是成功: 必须把原因打出来, 否则"用着旧制品"这件事没人看得见
            if [ -f "${tar}" ]; then
                warn "  cubepilot-${comp} 私服拉取失败(${SKOPEO_PULL_ERR:-未知原因}), **回退使用本地 tar**(可能是旧版本)"
                _SYNC_FB=$((_SYNC_FB + 1))
                return 0
            fi
            err "  cubepilot-${comp} 私服拉取失败且本地无 tar: ${tar}"
            err "  原因: ${SKOPEO_PULL_ERR:-未知原因}"
            err "  排查: skopeo inspect docker://${src}(私服可达? tag 存在?)"
            return 1
        fi
        return 0
    }
    say "[1/7] online: 从私服同步镜像(${_SRC_IMAGE_BASE}/cubepilot-{openclaw,operator,api,web}:${_IMG_TAG})..."
    sync_cubepilot_tar openclaw || exit 1
    sync_cubepilot_tar operator || exit 1
    sync_cubepilot_tar api      || exit 1
    # web 仅在启用内置 Portal 时才有 Pod 去拉它 → 关闭时**完全不处理**(不下载不推送, 省流量);
    # 之后若置 CUBEPILOT_WEB_ENABLED=true, 重跑本模块会自动补上。
    if [ "${CUBEPILOT_WEB_ENABLED}" = "true" ]; then
        sync_cubepilot_tar web || exit 1
    else
        say "  跳过 cubepilot-web(内置 Portal 未启用; 需要时置 CUBEPILOT_WEB_ENABLED=true 重跑)"
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
say "[1/7] 推送镜像到集群内置 registry(${CUBEPILOT_PUSH_BASE})..."
skopeo_require "cubepilot"       # 推送必需(离线机没跑过 1b, 这里要再确认一次)
ensure_hosts_entry "${REGISTRY_IP}" "${REGISTRY_DOMAIN:-registry.cubestack.io}"   # 部署机 /etc/hosts 解析内置 registry
wait_registry_ready "http://${REGISTRY_DIRECT}/v2/" \
    || { err "集群内置 registry ${REGISTRY_DIRECT}/v2/ 不可达(当前 SERVICE_EXPOSE_MODE=${SERVICE_EXPOSE_MODE})"; exit 1; }

# 推送单组件镜像: ① 已是目标 tag(幂等跳过) ② 从离线 tar 推入内置 registry
# 目标 ref 的 tag 用 _IMG_TAG(与 helm 传的镜像 ref 一致), 源 tar 里的 tag 只作内容识别。
_PUSH=0; _SKIP_N=0
push_cubepilot_image() {   # <comp>
    local comp="$1" _tarbase="" _t="" _src=""
    if reg_has_tag "${CUBEPILOT_PUSH_BASE}" "cubepilot-${comp}" "${_IMG_TAG}"; then
        ok "  cubepilot-${comp}:${_IMG_TAG} 已在内置 registry, 跳过"
        _SKIP_N=$((_SKIP_N + 1)); return 0
    fi
    _tarbase="${CUBEPILOT_OFFLINE_DIR}/$(_tar_name_of "${_SRC_IMAGE_BASE}/cubepilot-${comp}:${_IMG_TAG}")"
    # ① 规范命名快路径; ② 目录内通配(文件名含 cubepilot-<comp>); ③ 内容兜底扫描(兼容完全改名的 tar)
    if [ -f "${_tarbase}" ]; then
        _t="${_tarbase}"
    else
        local _d _f
        for _d in "${CUBEPILOT_OFFLINE_DIR}" "${LOCAL_REPO_DIR}/images" \
                  "${OFFLINE_FILES_DIR:-${REPO_ROOT}/deployments/offline-files/kubespray}/images"; do
            [ -d "${_d}" ] || continue
            for _f in "${_d}"/*cubepilot-${comp}*.tar; do
                [ -f "${_f}" ] || continue
                _t="${_f}"; break 2
            done
        done
        # ③ 内容兜底: 文件名完全不含组件名时(改名/异常命名), 按 tar 内 RepoTags 识别。
        #    ⚠ 只扫 ${CUBEPILOT_OFFLINE_DIR}(文档约定的制品目录, 体积可控);
        #      另两个兼容目录不做全量扫描 —— 那里可能有几十个大 tar, 逐个读代价过高。
        if [ -z "${_t}" ] && [ -d "${CUBEPILOT_OFFLINE_DIR}" ]; then
            for _f in "${CUBEPILOT_OFFLINE_DIR}"/*.tar; do
                [ -f "${_f}" ] || continue
                case "$(tar_first_image_tag "${_f}")" in
                    *"/cubepilot-${comp}:"*) _t="${_f}"; break ;;
                esac
            done
        fi
        # 通配命中时也要用 tar 内 ref 复核(防"文件名像、内容不是"推错镜像)
        if [ -n "${_t}" ]; then
            _src="$(tar_first_image_tag "${_t}")"
            case "${_src}" in
                *"/cubepilot-${comp}:"*) : ;;
                *) warn "  $(basename "${_t}") 内容为 ${_src:-<读不出>}, 非 cubepilot-${comp}, 跳过"
                   _t="" ;;
            esac
        fi
        unset _d _f
    fi
    if [ -z "${_t}" ]; then
        err "  离线镜像缺失: cubepilot-${comp}:${_IMG_TAG}"
        err "  online : 检查私服可达性后重跑(会自动同步)"
        err "  离线机 : ./deployments/scripts/tools/images/cubepilot-save-images.sh 生成后放入 ${CUBEPILOT_OFFLINE_DIR}/"
        return 1
    fi
    say "  推送 cubepilot-${comp} → ${CUBEPILOT_PUSH_BASE}/cubepilot-${comp}:${_IMG_TAG}(源: $(basename "${_t}"))"
    if push_image_skopeo "docker-archive:${_t}" "docker://${CUBEPILOT_PUSH_BASE}/cubepilot-${comp}:${_IMG_TAG}" >/dev/null 2>&1; then
        ok "  cubepilot-${comp} 已推入内置 registry"
        _PUSH=$((_PUSH + 1))
    else
        err "  cubepilot-${comp} 推送失败(skopeo copy docker-archive:${_t} → docker://${CUBEPILOT_PUSH_BASE}/cubepilot-${comp}:${_IMG_TAG})"
        return 1
    fi
}
# openclaw/operator/api 恒需要; web 仅在启用内置 Portal 时需要(关了就没人拉它, 不推省流量)
push_cubepilot_image openclaw || exit 1
push_cubepilot_image operator || exit 1
push_cubepilot_image api      || exit 1
if [ "${CUBEPILOT_WEB_ENABLED}" = "true" ]; then
    push_cubepilot_image web || exit 1
else
    say "  跳过 cubepilot-web(内置 Portal 未启用)"
fi
ok "  内置 registry 就绪(新推 ${_PUSH} 个, 已存在 ${_SKIP_N} 个)"
unset _PUSH _SKIP_N

# ---------------- 2. 命名空间 ----------------
# 不需要 imagePullSecret / 节点级凭据: 节点只访问内置 registry(免认证且节点已信任),
# operator 运行时铸造的 ServiceAccount 也照样能拉 —— 这正是"统一走内置 registry"最大的收益。
say "[2/7] 准备命名空间 ${CUBEPILOT_NAMESPACE}..."
# 幂等: 已存在时 create 失败属正常, 以"能读到该 ns"为最终判据
SSH "${K} create namespace ${CUBEPILOT_NAMESPACE} >/dev/null 2>&1" || true
SSH "${K} get namespace ${CUBEPILOT_NAMESPACE} >/dev/null 2>&1" \
    || { err "无法创建/访问命名空间 ${CUBEPILOT_NAMESPACE}"; exit 1; }
ok "  命名空间就绪(镜像来自内置 registry, 无需 imagePullSecret)"

# ---------------- 3. LLM 预置(可选) ----------------
# 默认**不预置**: 不假设平台已有 LLM, 装完在 Portal 的 Agent Config → LLM Config 里配。
# 要预置: 配 CUBEPILOT_LLM_ENDPOINT / CUBEPILOT_LLM_MODEL + CUBEPILOT_LLM_API_KEY。
# ⚠ 与 operator 的先后无要求(operator 会 watch 这个 Secret, 装完再建也认)。
if [ -n "${CUBEPILOT_LLM_ENDPOINT:-}" ] || [ -n "${CUBEPILOT_LLM_API_KEY:-}" ]; then
    say "[3/7] 预置平台默认 LLM(endpoint=${CUBEPILOT_LLM_ENDPOINT:-<空>}, model=${CUBEPILOT_LLM_MODEL:-<空>})..."
    if [ -z "${CUBEPILOT_LLM_API_KEY:-}" ]; then
        warn "  未配置 CUBEPILOT_LLM_API_KEY, 跳过 Secret 创建(仅有 endpoint/model 时模型不可用)"
    else
        _LLM_YAML="$(mktemp)"
        ( umask 077; printf '%s\n' \
            "apiVersion: v1" \
            "kind: Secret" \
            "metadata:" \
            "  name: ${CUBEPILOT_LLM_SECRET}" \
            "  namespace: ${CUBEPILOT_NAMESPACE}" \
            "type: Opaque" \
            "stringData:" \
            "  apiKey: '${CUBEPILOT_LLM_API_KEY}'" > "${_LLM_YAML}" )
        # stringData 里用户填的值可能含单引号 → apply 失败时提示改用 Portal 配置, 不静默失败
        if SSH "${K} apply -f -" < "${_LLM_YAML}" >/dev/null 2>&1; then
            ok "  Secret ${CUBEPILOT_NAMESPACE}/${CUBEPILOT_LLM_SECRET} 已下发(operator 会自动读取)"
        else
            warn "  Secret 下发失败(API Key 含特殊字符?); 可改用 Portal → Agent Config → LLM Config 配置"
        fi
        rm -f "${_LLM_YAML}"
    fi
else
    say "[3/7] 未配置 LLM(CUBEPILOT_LLM_*), 跳过预置 —— 装完在 Portal 的 Agent Config → LLM Config 里添加"
fi

# ---------------- 4. CubeStack 平台 CRD(可选, 默认关) ----------------
# chart 只带 6 个 ai.cubestack.io CRD; CubePilot 内置 skills/chat 若要用到 CubeStack 平台资源
# (DevEnvironment / InferenceService / ...), 需另装平台 CRD。默认**不装**(多数部署不需要),
# 目录不存在时只提示不报错(这些 CRD 未随本仓库 vendored, 需从 cubepilot 源仓库取)。
if [ "${CUBEPILOT_PLATFORM_CRDS_ENABLED}" = "true" ]; then
    say "[4/7] 下发 CubeStack 平台 CRD(${CUBEPILOT_PLATFORM_CRDS_DIR})..."
    shopt -s nullglob
    _CRD_FILES=("${CUBEPILOT_PLATFORM_CRDS_DIR}"/*.yaml)
    shopt -u nullglob
    if [ "${#_CRD_FILES[@]}" -eq 0 ]; then
        warn "  目录为空或不存在: ${CUBEPILOT_PLATFORM_CRDS_DIR}"
        warn "  取法: cubepilot 源仓库 test/e2e/framework/testdata/cubestack-crds/ 下的 CRD YAML 拷入该目录"
    else
        _CRD_N=0
        for _cf in "${_CRD_FILES[@]}"; do
            if SSH "${K} apply -f -" < "${_cf}" >/dev/null 2>&1; then
                _CRD_N=$((_CRD_N + 1))
            else
                warn "  $(basename "${_cf}") apply 失败(kubectl apply --dry-run=server 复查)"
            fi
        done
        ok "  平台 CRD 已下发 ${_CRD_N}/${#_CRD_FILES[@]} 个"
        unset _cf
    fi
    unset _CRD_FILES
else
    say "[4/7] CUBEPILOT_PLATFORM_CRDS_ENABLED!=true, 跳过 CubeStack 平台 CRD(仅用平台资源时才需要)"
fi

# ---------------- 5. helm 安装(恒本地 tgz + 恒内置 registry 镜像) ----------------
# 两种模式**在这里完全合流**: chart 一律取自本地 tgz(online 已同步), 4 个镜像一律指向内置 registry。
say "[5/7] helm upgrade --install ${CUBEPILOT_RELEASE}(→ ${CUBEPILOT_NAMESPACE})..."
say "  chart 来源: 本地 ${CUBEPILOT_CHART_TGZ}"
# --set-string 用于镜像/SC 这类字符串值(避免 helm 对 0.1.0-latest 之类做类型推断)
_HELM_ARGS=(
    --namespace "${CUBEPILOT_NAMESPACE}" --create-namespace
    --set-string "agents.image=${CUBEPILOT_IMAGE_BASE}/cubepilot-openclaw:${_IMG_TAG}"
    --set-string "operator.image=${CUBEPILOT_IMAGE_BASE}/cubepilot-operator:${_IMG_TAG}"
    --set-string "api.image=${CUBEPILOT_IMAGE_BASE}/cubepilot-api:${_IMG_TAG}"
    --set-string "web.image=${CUBEPILOT_IMAGE_BASE}/cubepilot-web:${_IMG_TAG}"
    --set "web.enabled=${CUBEPILOT_WEB_ENABLED}"
)
# SC 仅在非空时传 —— chart 语义是"留空回落集群默认 SC", 传空串反而可能覆盖成显式空值
if [ -n "${_SC}" ]; then
    _HELM_ARGS+=( --set-string "api.storageClassName=${_SC}" --set-string "api.skillRepo.storageClassName=${_SC}" )
    say "  PVC StorageClass: ${_SC}(两个 PVC 共用)"
else
    say "  PVC StorageClass: 留空(两个 PVC 回落集群默认 StorageClass)"
fi
say "  镜像: ${CUBEPILOT_IMAGE_BASE}/cubepilot-{openclaw,operator,api,web}:${_IMG_TAG}"
[ -n "${CUBEPILOT_LLM_ENDPOINT:-}" ] && _HELM_ARGS+=( --set-string "agents.llmEndpoint=${CUBEPILOT_LLM_ENDPOINT}" )
[ -n "${CUBEPILOT_LLM_MODEL:-}" ]    && _HELM_ARGS+=( --set-string "agents.llmModel=${CUBEPILOT_LLM_MODEL}" )
# --wait 超时只 warn: 资源可能已创建(镜像首次拉取较慢), 后面按 Deployment 实际状态判定
# ⚠ 本地 tgz 的版本由文件本身决定, **不传 --version**(那是 OCI 源才有效的参数)
helm upgrade --install "${CUBEPILOT_RELEASE}" "${CUBEPILOT_CHART_TGZ}" \
    "${_HELM_ARGS[@]}" \
    --wait --timeout "${CUBEPILOT_WAIT_SECONDS}s" \
    || warn "  helm --wait 超时(资源可能已创建; 继续按实际状态检查)"

# ---------------- 6. 等待 operator / api 就绪 + 收集 agentinstance ----------------
say "[6/7] 等待 CubePilot 工作负载就绪(最长 ${CUBEPILOT_WAIT_SECONDS}s)..."
# Deployment 名以 chart 为准, 不硬编码: 取命名空间内名字含 operator 的 deployment
_OP_DEPLOY="$( (SSH "${K} -n ${CUBEPILOT_NAMESPACE} get deploy -o name 2>/dev/null" || true) | sed -n 's#.*/##p' | grep -m1 'operator' || true)"
if [ -n "${_OP_DEPLOY}" ]; then
    SSH "${K} -n ${CUBEPILOT_NAMESPACE} rollout status deployment/${_OP_DEPLOY} --timeout=${CUBEPILOT_WAIT_SECONDS}s" >/dev/null 2>&1 \
        && ok "  operator 就绪: ${_OP_DEPLOY}" \
        || warn "  operator ${_OP_DEPLOY} 未在 ${CUBEPILOT_WAIT_SECONDS}s 内就绪(检查 pods 与镜像拉取)"
else
    warn "  未发现 operator Deployment(helm 安装是否成功? kubectl -n ${CUBEPILOT_NAMESPACE} get deploy)"
fi
# AI Agent CRD 与实例(admin-agent-for-cloud 由 operator 创建, 需要一点时间)
_AI_CRD_CNT="$( (SSH "${K} get crd --no-headers 2>/dev/null" || true) | grep -c 'ai\.cubestack\.io' || true)"
if [ "${_AI_CRD_CNT:-0}" -ge 1 ]; then
    ok "  ai.cubestack.io CRD 已注册(${_AI_CRD_CNT} 个, chart crds/ 自带)"
    _AI_WAIT=0
    for _i in $(seq 1 12); do
        _AI_CNT="$( (SSH "${K} -n ${CUBEPILOT_NAMESPACE} get agentinstances --no-headers 2>/dev/null" || true) | grep -c . || true)"
        [ "${_AI_CNT:-0}" -ge 1 ] && { _AI_WAIT=1; break; }
        sleep 5
    done
    if [ "${_AI_WAIT}" = "1" ]; then
        ok "  AgentInstance 已创建 ${_AI_CNT} 个(operator 已开始工作)"
    else
        warn "  operator 尚未创建 AgentInstance(60s 内; 观察 kubectl -n ${CUBEPILOT_NAMESPACE} logs deploy/${_OP_DEPLOY:-<operator>})"
    fi
    unset _AI_CNT _AI_WAIT _i
else
    warn "  未检测到 ai.cubestack.io CRD(chart 的 crds/ 未装上? kubectl get crd | grep cubestack)"
fi

# ---------------- 7. 汇总 ----------------
echo "---------------------------------------------"
ok "CubePilot 部署完成"
echo "  模式:        ${CUBEPILOT_MODE}$( [ "${CUBEPILOT_MODE}" = "online" ] && echo "(已从私服 ${CUBEPILOT_HARBOR} 同步制品)" || echo "(未联网, 使用本地制品)" )"
echo "  chart:       $(basename "${CUBEPILOT_CHART_TGZ}")(仓库内 vendored 离线副本, 随 git 分发)"
echo "  镜像:        ${CUBEPILOT_IMAGE_BASE}/cubepilot-{openclaw,operator,api,web}:${_IMG_TAG}"
echo "               (统一来自集群内置 registry; 节点不需任何私服凭据)"
echo "  namespace:   ${CUBEPILOT_NAMESPACE}(helm release ${CUBEPILOT_RELEASE})"
echo "  离线制品:    ${CUBEPILOT_OFFLINE_DIR}/(镜像 tar, 可直接切纯离线)"
if [ "${CUBEPILOT_WEB_ENABLED}" = "true" ]; then
    echo "  内置 Portal: 已启用(cubepilot-web; 置 CUBEPILOT_WEB_ENABLED=false 可关)"
else
    echo "  内置 Portal: 已关闭(web.enabled=false; 只有 API 入口)"
fi
echo "  StorageClass:${_SC:-<留空, 用集群默认 SC>}"
echo "  资源查看:    kubectl -n ${CUBEPILOT_NAMESPACE} get agentinstances,pods"
if [ "${CUBEPILOT_WEB_ENABLED}" = "true" ]; then
    echo "  端口转发:    kubectl -n ${CUBEPILOT_NAMESPACE} port-forward svc/cubepilot 8080:8080       # Portal(SPA + /api)"
fi
echo "               kubectl -n ${CUBEPILOT_NAMESPACE} port-forward svc/cubepilot-api 8080:8080   # 仅 API(/healthz)"
if [ -n "${CUBEPILOT_LLM_ENDPOINT:-}" ]; then
    echo "  LLM:         ${CUBEPILOT_LLM_ENDPOINT}(${CUBEPILOT_LLM_MODEL:-<未指定模型>}); 密钥 Secret ${CUBEPILOT_NAMESPACE}/${CUBEPILOT_LLM_SECRET}"
else
    echo "  LLM:         未预置(默认无心智模型; 在 Portal → Agent Config → LLM Config 添加)"
fi
echo "  端到端验证:  sudo ./deploy-cluster.sh --steps verify_cubepilot"
echo "  切纯离线:    cluster.conf 置 CUBEPILOT_MODE=offline —— chart 用仓库内离线副本,"
echo "               镜像用 ${CUBEPILOT_OFFLINE_DIR}/(上面那次 online 已备好), 无需其他准备"
echo "  卸载:        helm uninstall ${CUBEPILOT_RELEASE} -n ${CUBEPILOT_NAMESPACE}"
