#!/bin/bash
# ============================================================
# MODULE: prometheus
# DESC: Prometheus + Prometheus Operator(kube-prometheus-stack)离线部署(P1 监控底座)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: PROMETHEUS_ENABLED
# REQUIRES: k8s_deploy k8s_registry
# 说明:
#   · 断点续跑: REPEAT:0 → 安装成功写状态; --fresh 重装。
#   · chart 源码 vendored 于 deployments/cubestack-addon/observability/prometheus/kube-prometheus-stack
#     (默认 90.0.0 / appVersion v0.93.1; 刷新: tools/images/prometheus-fetch-charts.sh)
#   · 离线镜像: tools/images/prometheus-save-images.sh(联网机, 独立运行)保存 tar 到
#     offline-files/prometheus/ → 本模块推送进集群内置 registry(仓库路径=chart 默认仓库名,
#     注册域由 helm --set image.registry 重写为 REGISTRY_BASE)
#   · 安装参数(对齐用户要求): retention=15d; Prometheus PVC 50Gi(不指定 storageClassName,
#     用系统默认 StorageClass); namespace=monitoring
#   · 组件: operator + prometheus + alertmanager + node-exporter + kube-state-metrics + grafana;
#     thanosRuler / kubeRBACProxy / windows-exporter / CRD 升级 Job 默认关闭(不备料)
#   · 对外暴露(末步): 默认**只暴露 Grafana**(PROMETHEUS_EXPOSE_PROMETHEUS=true 才连 Prometheus 一起):
#     PROMETHEUS_EXPOSE_MODE=nodeport(*-external NodePort; grafana=base+1=31001) /
#     metallb|loadbalancer(独立 *-external LoadBalancer, 默认**共用 registry 的 VIP**、以端口区分) /
#     clusterip。⚠ metallb 与 loadbalancer 同义, 见末段归一化注释。
#   ★ 2026-09-20(用户要求): 按 cubestack 源仓库 observability/docs/installer-requirements.md
#     补齐 CubeStack 可观测性落地, 共 5 块(详见 docs/prometheus-observability.md):
#       ① kube-prometheus-stack values(§1) —— 全部走**临时 values 文件**(mktemp + umask 077), 不用 --set:
#            · KSM label allowlist(§1.1) —— 值里含逗号, --set 的逗号是键分隔符, 必被切断
#            · 4 组 Prometheus selector(§1.2) —— 嵌套结构用 --set 易错且难 review
#            · node-exporter --collector.infiniband + node label relabeling(§1.3)
#            · scrapeInterval/evaluationInterval(§1.4) + grafana 管理员口令
#          ⚠ 两个**静默失效**陷阱(实测, 详见文档):
#            (a) ruleSelector 若按 §1.2 写 `matchLabels: {app.kubernetes.io/part-of: cubestack-observability}`,
#                chart **自带的 40+ 组默认规则会被一起丢掉**(它们带的是 release / part-of: kube-prometheus-stack),
#                且无任何报错 → 本模块改用 matchExpressions In [cubestack-observability, kube-prometheus-stack] 取并集。
#            (b) chart 的 `*SelectorNilUsesHelmValues: true` 会把 `{}` 渲染成 `matchLabels: {release: <release>}`,
#                即"写 {} 并不等于全选" → 必须同时置 false 才能真正全选(否则跨 namespace 的 SM/ScrapeConfig 全丢)。
#       ② CubeStack recording rules(§2) —— apply vendored 的 6 个 PrometheusRule
#       ③ Grafana dashboards(§3) —— 11 个 dashboard 做成 ConfigMap, 由 grafana sidecar 导入
#          (sidecar 每次启动从 ConfigMap 重新导入; **不要**用 Grafana API 导入 —— 只写 DB, Pod 重建即丢)
#       ④ MetaX mx-exporter(§7.1) —— 打开 dataExporter 并建 ServiceMonitor
#       ⑤ Prometheus/Grafana 对外暴露(原有)
#   · Grafana 口令**硬校验**(§4): GRAFANA_ADMIN_PASSWORD 未设/为空/仍为 CHANGE_ME → 立即报错退出。
#     不设置时 helm 会随机生成口令存 secret, 用户无法预知(实测环境因此手工重置过), 不可接受。
#     出厂默认值是 admin(见 cluster.conf.example), 用它部署**只告警不阻断**(见下方 warn)。
#     口令只经 values 文件传递, **不进 argv**(ps 可见), 文件权限 600 且用后即删。
#   · 资产目录(§5, 三级回退, 会打印实际用了哪个): CUBESTACK_OBSERVABILITY_DIR >
#     /opt/cubestack/observability(离线包约定) > 仓库内 vendored(cubestack-addon/observability/cubestack/)。
#     刷新: tools/observability/fetch-observability-assets.sh
#   · 参考: deployments/cubestack-addon/observability/prometheus/README.md
# 数据源: cluster.conf (PROMETHEUS_ENABLED / PROMETHEUS_NAMESPACE / PROMETHEUS_RELEASE_NAME /
#         PROMETHEUS_RETENTION_DAYS / PROMETHEUS_STORAGE_SIZE / PROMETHEUS_APP_VERSION /
#         PROMETHEUS_IMAGE_* / PROMETHEUS_SCRAPE_INTERVAL / PROMETHEUS_EVALUATION_INTERVAL /
#         GRAFANA_ADMIN_USER / GRAFANA_ADMIN_PASSWORD / CUBESTACK_OBSERVABILITY_DIR /
#         MX_EXPORTER_ENABLED / METAX_NAMESPACE / REGISTRY_BASE / PROMETHEUS_EXPOSE_MODE /
#         PROMETHEUS_EXPOSE_PROMETHEUS / PROMETHEUS_SHARE_REGISTRY_VIP / REGISTRY_IP / NODES)
# 用法:   sudo ./deploy-cluster.sh --steps prometheus  或  PROMETHEUS_ENABLED=true
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

if [ "${PROMETHEUS_ENABLED:-false}" != "true" ]; then
    say "跳过 Prometheus 监控(配置 PROMETHEUS_ENABLED=true 可启用)"
    exit 0
fi

init_remote_kubectl || exit 1

PROMETHEUS_NAMESPACE="${PROMETHEUS_NAMESPACE:-monitoring}"
PROMETHEUS_RELEASE_NAME="${PROMETHEUS_RELEASE_NAME:-kube-prometheus}"
PROMETHEUS_RETENTION_DAYS="${PROMETHEUS_RETENTION_DAYS:-15d}"
PROMETHEUS_STORAGE_SIZE="${PROMETHEUS_STORAGE_SIZE:-50Gi}"
# 镜像版本(与 tools/images/prometheus-save-images.sh 默认一致; conf 可覆盖)
PROMETHEUS_APP_VERSION="${PROMETHEUS_APP_VERSION:-v0.93.1}"                  # operator/config-reloader/admission-webhook
PROMETHEUS_IMAGE_PROMETHEUS="${PROMETHEUS_IMAGE_PROMETHEUS:-v3.14.0-distroless}"
PROMETHEUS_IMAGE_ALERTMANAGER="${PROMETHEUS_IMAGE_ALERTMANAGER:-v0.34.0}"
# ⚠ 2026-09-11 修复: node-exporter / kube-state-metrics 的 registry tag **带 v 前缀**
#   (quay.io/prometheus/node-exporter:v1.12.1、registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0,
#   与 subchart "v+appVersion" 默认渲染一致); 裸 1.12.1/2.20.0 不存在。
PROMETHEUS_IMAGE_NODE_EXPORTER="${PROMETHEUS_IMAGE_NODE_EXPORTER:-v1.12.1}"
PROMETHEUS_IMAGE_KSM="${PROMETHEUS_IMAGE_KSM:-v2.20.0}"
PROMETHEUS_IMAGE_GRAFANA="${PROMETHEUS_IMAGE_GRAFANA:-13.2.1-distroless}"
PROMETHEUS_IMAGE_SIDECAR="${PROMETHEUS_IMAGE_SIDECAR:-2.11.2}"
PROMETHEUS_IMAGE_CERTGEN="${PROMETHEUS_IMAGE_CERTGEN:-1.8.8}"
CHART_DIR="${PROMETHEUS_CHART_DIR:-${REPO_ROOT}/deployments/cubestack-addon/observability/prometheus/kube-prometheus-stack}"
# ★ 2026-09-11: prometheus 镜像目录默认 `offline-files/prometheus`(save 脚本默认, 与 envoy/lws 同构)。
#   早期错误套过 ${OFFLINE_FILES_DIR}(→.../kubespray) 致找不到; 已修回独立目录。
SAVE_DIR="${PROMETHEUS_SAVE_DIR:-${REPO_ROOT}/deployments/offline-files/prometheus}"

# ★ 2026-09-20: CubeStack 可观测性落地所需的新配置(见文件头说明与 docs/prometheus-observability.md)
PROMETHEUS_SCRAPE_INTERVAL="${PROMETHEUS_SCRAPE_INTERVAL:-30s}"        # §1.4
PROMETHEUS_EVALUATION_INTERVAL="${PROMETHEUS_EVALUATION_INTERVAL:-60s}"   # §1.4
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-}"
# Grafana 13.2 起**数据源插件外置**(prometheus/loki/elasticsearch/… 不再内置, 启动时去 grafana.com
# 下载) —— 离线环境装不上 → 数据源对象存在但查询报 "Unable to find datasource plugin", 看板全空
# (2026-09-22 实机定位)。解法: 用预装插件的**派生镜像**(tools/images/grafana-plugin-build.sh),
# 并把下面这个变量设为镜像内插件目录 —— 插件必须放在 /var/lib/grafana **之外**: 该路径被 chart
# 挂成 emptyDir, 烤在里面的插件会被挂载点整个遮住。留空 = 不覆盖(Grafana ≤13.1 / 在线环境用默认值)。
PROMETHEUS_GRAFANA_PLUGIN_DIR="${PROMETHEUS_GRAFANA_PLUGIN_DIR:-}"
# 数据源可用性校验的失败动作: fail(默认, 硬失败) / warn(只告警) / off(跳过)
GRAFANA_DS_VERIFY="${GRAFANA_DS_VERIFY:-fail}"
# 看板数据源自动绑定(★ 2026-09-22): 上游看板里写死的是**别人环境的数据源 uid**(如 rYdddlPWk、
# eefhg6y1xs8owa)或用小写名字, 导入后那些面板一律 "Datasource not found" → 导入前统一改绑到
# 本集群这份数据源(chart 默认 uid=prometheus / name=Prometheus, 见 lib-common 里 provisioning 那段)。
# 关掉它 = 保留原始 JSON 导入(需要手工在 Grafana 里逐面板选数据源)。
GRAFANA_DS_AUTOBIND="${GRAFANA_DS_AUTOBIND:-true}"
GRAFANA_DATASOURCE_UID="${GRAFANA_DATASOURCE_UID:-prometheus}"
GRAFANA_DATASOURCE_NAME="${GRAFANA_DATASOURCE_NAME:-Prometheus}"
MX_EXPORTER_ENABLED="${MX_EXPORTER_ENABLED:-true}"                     # §7.1(auto: 无 metax 时自动跳过)
METAX_NAMESPACE="${METAX_NAMESPACE:-metax-operator}"

# 资产目录四级回退(§5): 显式配置 > 离线包约定目录 > **offline-files 离线包落点** > 仓库内 vendored。
# 第 3 级是 2026-09-22 补的: 走 MinIO 离线通道时资产落在 offline-files/observability/(由
# tools/offline/pack-observability-assets.sh 装配), 之前没有这一级 → 拉下来的那份没人读。
# 一次性解析成 _OBS_DIR, 后续步骤只用它 —— 避免每处都重复判断, 也让"实际用了哪个"只打印一次。
_OBS_DIR=""
_OBS_SRC=""
if [ -n "${CUBESTACK_OBSERVABILITY_DIR:-}" ]; then
    _OBS_DIR="${CUBESTACK_OBSERVABILITY_DIR}"; _OBS_SRC="CUBESTACK_OBSERVABILITY_DIR"
elif [ -d "/opt/cubestack/observability/recording-rules" ]; then
    _OBS_DIR="/opt/cubestack/observability"; _OBS_SRC="离线包默认目录 /opt/cubestack/observability"
elif [ -d "${REPO_ROOT}/deployments/offline-files/observability/recording-rules" ]; then
    _OBS_DIR="${REPO_ROOT}/deployments/offline-files/observability"; _OBS_SRC="offline-files 离线包(MinIO 通道)"
else
    _OBS_DIR="${REPO_ROOT}/deployments/cubestack-addon/observability/cubestack"; _OBS_SRC="仓库内 vendored"
fi
_OBS_RULES_DIR="${_OBS_DIR}/recording-rules"
_OBS_DASH_DIR="${_OBS_DIR}/dashboards/grafana"

# ★ Grafana 口令硬校验(§4, helm **之前**): 未设/为空/仍为占位符 → 立即失败。
#   不设置时 helm 会随机生成口令存进 secret, 用户拿不到(实测环境因此手工重置过), 不是可接受的行为。
#   校验放在这里(而非用到时)是为了**尽早失败** —— 别等推完镜像、装完 chart 才报错。
if [ -z "${GRAFANA_ADMIN_PASSWORD}" ]; then
    err "GRAFANA_ADMIN_PASSWORD 未设置(或为空)"
    err "  必须在 cluster.conf 显式设置 Grafana 管理员口令后重跑;"
    err "  留空时 helm 会随机生成口令存进 secret, 用户无法预知, 因此本模块拒绝继续。"
    exit 1
fi
case "${GRAFANA_ADMIN_PASSWORD}" in
    CHANGE_ME|changeme|change-me|CHANGEME|'')
        err "GRAFANA_ADMIN_PASSWORD 仍是占位符 '${GRAFANA_ADMIN_PASSWORD}', 拒绝用已知默认口令部署 Grafana"
        err "  请在 cluster.conf 改成实际口令(与 BMC exporter 的凭据校验同理)。"
        exit 1 ;;
esac

# ★ 2026-09-21: 出厂默认口令(cluster.conf.example 的 GRAFANA_ADMIN_PASSWORD 默认值)—— 不阻断部署,
#   但每次都在日志里显式提醒。监控入口常对外暴露(NodePort/LoadBalancer), 默认口令等于公开知识。
if [ "${GRAFANA_ADMIN_PASSWORD}" = "admin" ]; then
    warn "GRAFANA_ADMIN_PASSWORD 仍是出厂默认口令 'admin'(用户名 ${GRAFANA_ADMIN_USER})"
    warn "  若监控入口对外可达, 请尽快在 cluster.conf 改成实际口令后重跑本模块。"
fi

# ★ 2026-09-18: 监控三件套各自独立成组/目录(用户要求 + 便于单独升级与离线备料)。
#   kube-state-metrics / node-exporter 有自己的 offline-files 子目录(见 images.manifest);
#   kubelet/cAdvisor **无镜像**(内置于 kubelet), 故只列文档目录、不参与 tar 查找。
#   查找策略: **优先组件自己的目录, 再回退 prometheus/** —— 老布局(tar 全在 prometheus/)
#   与新布局(各自目录)都能工作, 升级/迁移期不炸。
_COMP_DIR_OF() {   # <repo(去注册域)> → 优先查找目录
    case "$1" in
        kube-state-metrics/*) echo "${REPO_ROOT}/deployments/offline-files/kube-state-metrics" ;;
        prometheus/node-exporter) echo "${REPO_ROOT}/deployments/offline-files/node-exporter" ;;
        *) echo "${SAVE_DIR}" ;;
    esac
}
# 按优先级返回全部候选目录(去重), 供"找不到就换个目录再找"
_TAR_DIRS_FOR() {   # <repo>
    local pref; pref="$(_COMP_DIR_OF "$1")"
    printf '%s\n' "${pref}"
    [ "${pref}" != "${SAVE_DIR}" ] && printf '%s\n' "${SAVE_DIR}"
    return 0
}
# 在候选目录里找 **唯一以 <pat> 结尾** 的 tar(注册域前缀不定, 取实际存在的那个)
_find_tar() {   # <repo> <pat>
    local _repo="$1" _pat="$2" _d _hit
    while IFS= read -r _d; do
        [ -d "${_d}" ] || continue
        _hit="$(ls "${_d}"/*"${_pat}" 2>/dev/null | head -1)"
        [ -n "${_hit}" ] && { printf '%s\n' "${_hit}"; return 0; }
    done < <(_TAR_DIRS_FOR "${_repo}")
    return 1
}
REG_BASE="${REGISTRY_BASE:-registry.cubestack.io:5000}"      # helm --set 用的集群内解析域(节点 containerd hosts.toml 已改写)
REG_DIRECT="${REGISTRY_DIRECT:-${REGISTRY_IP:-$(first_master_ip)}:${REGISTRY_PORT:-31148}}"  # skopeo 直连推送地址(免域名解析)

# 推送 skopeo(脚本级重试 3 次, 同 gpu_operator)
_push_skopeo() {
    local src="$1" dst="$2" n=1 err
    ensure_skopeo_policy
    for n in 1 2 3; do
        if skopeo copy --quiet --src-tls-verify=false --dest-tls-verify=false --dest-no-creds "${src}" "${dst}" 2>/tmp/prom-skopeo-err; then
            rm -f /tmp/prom-skopeo-err; return 0
        fi
        err="$(tail -1 /tmp/prom-skopeo-err 2>/dev/null || true)"
        if [ "${n}" -lt 3 ]; then
            warn "  推送失败(第 ${n}/3 次: ${err}), 3s 后重试整包..."
            sleep 3
        fi
    done
    rm -f /tmp/prom-skopeo-err
    return 1
}

# ── 1. 校验离线资源(chart + 镜像 tar + observability 资产) ──
say "[1/8] 校验离线资源(chart + 镜像 tar + observability 资产)..."
[ -f "${CHART_DIR}/Chart.yaml" ] || { err "chart 缺失: ${CHART_DIR}(联网机执行 tools/images/prometheus-fetch-charts.sh 下载)"; exit 1; }
[ -d "${SAVE_DIR}" ] || { err "离线镜像目录缺失: ${SAVE_DIR}(联网机执行 tools/images/prometheus-save-images.sh 下载)"; exit 1; }
# ★ 2026-09-20: observability 资产(recording rules + dashboards)必须先在盘上 ——
#   缺了不是"少个看板", 而是规则静默不加载/CubeStack 监控整体不可见, 因此与 chart/镜像同等对待(硬失败)。
[ -d "${_OBS_RULES_DIR}" ] || { err "recording rules 目录缺失: ${_OBS_RULES_DIR}"; err "  取法: bash deployments/scripts/tools/observability/fetch-observability-assets.sh"; exit 1; }
[ -d "${_OBS_DASH_DIR}" ]  || { err "dashboard 目录缺失: ${_OBS_DASH_DIR}"; err "  取法: bash deployments/scripts/tools/observability/fetch-observability-assets.sh"; exit 1; }
shopt -s nullglob
_OBS_RULES=("${_OBS_RULES_DIR}"/*.yaml)
_OBS_DASHS=("${_OBS_DASH_DIR}"/*.json)
shopt -u nullglob
[ "${#_OBS_RULES[@]}" -ge 1 ] || { err "${_OBS_RULES_DIR} 下没有 *.yaml"; exit 1; }
[ "${#_OBS_DASHS[@]}" -ge 1 ] || { err "${_OBS_DASH_DIR} 下没有 *.json"; exit 1; }
say "  observability 资产: ${#_OBS_RULES[@]} 个规则文件 + ${#_OBS_DASHS[@]} 个 dashboard(来源: ${_OBS_SRC})"
# ⚠ 2026-09-11 修复: tar 文件名与 IMG_REPO key 的映射必须**去注册域**(save 脚本用完整 ref
#   的 repository 部分做文件名: 如 registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0
#   → registry.k8s.io_kube-state-metrics_kube-state-metrics_v2.20.0.tar)。
#   IMG_REPO 里 key 一律用 <repo>(去注册域), 版本值与 save 脚本 tag 一致(含 v 前缀)。
declare -A IMG_REPO=(
    [prometheus-operator/prometheus-operator]="${PROMETHEUS_APP_VERSION}"
    [prometheus-operator/prometheus-config-reloader]="${PROMETHEUS_APP_VERSION}"
    [prometheus-operator/admission-webhook]="${PROMETHEUS_APP_VERSION}"
    [jkroepke/kube-webhook-certgen]="${PROMETHEUS_IMAGE_CERTGEN}"
    [prometheus/prometheus]="${PROMETHEUS_IMAGE_PROMETHEUS}"
    [prometheus/alertmanager]="${PROMETHEUS_IMAGE_ALERTMANAGER}"
    [prometheus/node-exporter]="${PROMETHEUS_IMAGE_NODE_EXPORTER}"
    [kube-state-metrics/kube-state-metrics]="${PROMETHEUS_IMAGE_KSM}"
    [grafana/grafana]="${PROMETHEUS_IMAGE_GRAFANA}"
    [kiwigrid/k8s-sidecar]="${PROMETHEUS_IMAGE_SIDECAR}"
)
_MISSING=""
# halves: 用 ls 通配末段匹配(注册域前缀不定), 在**候选目录**里逐个校验
echo "  ✓ 离线镜像目录: ${SAVE_DIR}(KSM → offline-files/kube-state-metrics, node-exporter → offline-files/node-exporter)"
for _repo in "${!IMG_REPO[@]}"; do
    _tag="${IMG_REPO[${_repo}]}"
    _pat="$(echo "${_repo}" | sed 's#/#_#g')_${_tag}.tar"
    # 文件名必须整体结束于 <repo>_<tag>.tar(如 registry.k8s.io_kube-state-metrics_kube-state-metrics_v2.20.0.tar)
    if _find_tar "${_repo}" "${_pat}" >/dev/null; then
        :   # 命中(组件自有目录优先, 回退 prometheus/)
    else
        _MISSING="${_MISSING} ${_repo}:${_tag}"
    fi
done
if [ -n "${_MISSING}" ]; then
    err "离线镜像 tar 缺失:${_MISSING}"
    err "  统一取法(推荐, 从 Harbor 镜像源拉): sudo bash deployments/scripts/tools/images/harbor-save-images.sh --group prometheus,kube-state-metrics,node-exporter"
    err "  或直连上游: sudo bash deployments/scripts/tools/images/prometheus-save-images.sh"
    exit 1
fi
ok "chart + ${#IMG_REPO[@]} 个镜像 tar + ${#_OBS_RULES[@]} 规则 + ${#_OBS_DASHS[@]} 看板就绪"

# ── 2. 推送镜像 → 集群内置 registry ──
say "[2/8] 推送镜像到内置 registry(${REG_DIRECT})..."
for _repo in "${!IMG_REPO[@]}"; do
    _tag="${IMG_REPO[${_repo}]}"
    _pat="$(echo "${_repo}" | sed 's#/#_#g')_${_tag}.tar"
    # 候选目录里唯一以 _pat 结尾的 tar(注册域前缀不定, 取实际存在的那个)
    _tar="$(_find_tar "${_repo}" "${_pat}" || true)"
    [ -n "${_tar}" ] || { err "  tar 缺失: ${_repo}:${_tag}(校验应已拦截)"; exit 1; }
    _push_skopeo "docker-archive:${_tar}" "docker://${REG_DIRECT}/${_repo}:${_tag}" \
        && ok "  ${_repo}:${_tag} 已推送" \
        || { err "  ${_repo}:${_tag} 推送失败(重试 3 次)"; exit 1; }
done

# ── 3. helm 离线安装(镜像注册域重写 + retention + 50Gi 默认 SC + CubeStack 可观测性 values) ──
say "[3/8] helm 安装 kube-prometheus-stack(namespace=${PROMETHEUS_NAMESPACE}; retention=${PROMETHEUS_RETENTION_DAYS}; PVC ${PROMETHEUS_STORAGE_SIZE} 默认 SC)..."
sync_kubeconfig || { err "宿主机无法访问集群(admin.conf 同步失败; 检查 ${FIRST_MASTER})"; exit 1; }

# ★ 2026-09-20: CubeStack 可观测性 values 走**临时 values 文件**(而不是 --set)。两个硬理由:
#   ① KSM allowlist 的值里含**逗号**, 而 --set 的逗号是键分隔符 → 必被切断成两个畸形键(静默失效);
#   ② selector 是嵌套结构, 用 --set 表达易错且无法 review → 写成 YAML 后可用
#      `helm template -f <此文件>` 离线断言渲染结果(见 docs/prometheus-observability.md 的验证方式)。
# ⚠ 数组语义: Helm 对 **list 是整体替换**不是合并 —— 覆盖 node-exporter.extraArgs 时必须把
#   chart 默认的两条 filesystem exclude **原样带上**, 否则过滤失效(node_filesystem_* 指标爆炸)。
# ⚠ 口令只经本文件传递, 不进 argv; 文件 umask 077 + 用后即删。
_VALUES_YAML="$(mktemp)"
chmod 600 "${_VALUES_YAML}"
# 插件目录覆盖块(仅当 PROMETHEUS_GRAFANA_PLUGIN_DIR 非空时非空)。
# 用 printf -v 而非 $(...): 命令替换会吃掉行尾换行, 拼进 YAML 时会把两行黏成一行。
# ⚠ 必须并进**同一个 grafana:** 映射(YAML 顶层重复键后者覆盖前者 → 会把 adminUser/Password 顶掉)。
_PROM_GRAFANA_PLUGIN_BLOCK=""
if [ -n "${PROMETHEUS_GRAFANA_PLUGIN_DIR}" ]; then
    printf -v _PROM_GRAFANA_PLUGIN_BLOCK '  grafana.ini:\n    paths:\n      plugins: %s\n  env:\n    # 插件随镜像预装且目录只读 → 关掉自动更新(否则每次重启都尝试更新并报 permission denied)\n    GF_PLUGINS_PREINSTALL_AUTO_UPDATE: "false"\n' "${PROMETHEUS_GRAFANA_PLUGIN_DIR}"
    say "  Grafana 插件目录覆盖为 ${PROMETHEUS_GRAFANA_PLUGIN_DIR}(配合预装插件的派生镜像)"
fi
# 第一段: 静态结构, 用**带引号的 heredoc** 以免 bash 误展开 regex 里的 $ 与 [](chart 的默认 extraArgs 是逐字复制而来的)
cat > "${_VALUES_YAML}" <<'PROM_VALUES_STATIC'
# ── §1.1 kube-state-metrics label allowlist ──
# 缺了这条, 所有 `* on(namespace,pod) group_left(label_ai_cubestack_io_*) kube_pod_labels` 的
# recording rule join 全部失效(键不存在 → join 结果为空)。
#   pods=[...]        : 让 kube_pod_labels 透传 pod label, 供 SGLang/GPU/cAdvisor 指标关联回 CR
#   statefulsets=[...]: 让 kube_statefulset_labels 透传 StatefulSet label(Overview 的 DevEnvironment 计数)
# ⚠ 实测(2026-09-20, KSM v2.20.0 实机): allowlist **只作用于 <resource>_labels 指标**,
#   不会加到 kube_statefulset_replicas / kube_pod_status_ready 这类指标上 ——
#   需要那些指标带 label 时必须走 join(recording rules 已如此实现)。
kube-state-metrics:
  extraArgs:
    - --metric-labels-allowlist=pods=[app.kubernetes.io/part-of,ai.cubestack.io/inference-service,ai.cubestack.io/role,ai.cubestack.io/dev-environment],statefulsets=[ai.cubestack.io/dev-environment]

# ── §1.2 Prometheus 发现范围: 能看见 CubeStack 的 ServiceMonitor / PrometheusRule / ScrapeConfig ──
prometheus:
  prometheusSpec:
    serviceMonitorNamespaceSelector: {}
    serviceMonitorSelector: {}
    # ⚠ 必须显式 false: chart 的 NilUsesHelmValues=true 会把上面的 {} 改写成
    #   `matchLabels: {release: <release名>}` —— "写 {} 并不等于全选", 跨 namespace 的
    #   ServiceMonitor(如 metax-operator 的 mx-exporter)会因此全丢, 且无任何报错。
    serviceMonitorSelectorNilUsesHelmValues: false
    ruleNamespaceSelector: {}
    # ⚠ 这里**不是** matchLabels{part-of: cubestack-observability}: 那样写会把 chart **自带的
    #   40+ 组默认规则一起丢掉**(它们带的是 release + part-of: kube-prometheus-stack),
    #   表现为"CubeStack 规则能加载, 但 kubernetes-apps / node.rules 等默认告警全没了"。
    #   改用 matchExpressions 取并集: CubeStack 规则 + chart 自带规则都进。
    ruleSelector:
      matchExpressions:
        - key: app.kubernetes.io/part-of
          operator: In
          values:
            - cubestack-observability
            - kube-prometheus-stack
    ruleSelectorNilUsesHelmValues: false
    scrapeConfigNamespaceSelector: {}
    scrapeConfigSelector:
      matchExpressions:
        - key: app.kubernetes.io/part-of
          operator: In
          values:
            - cubestack-observability
            - kube-prometheus-stack
    scrapeConfigSelectorNilUsesHelmValues: false
PROM_VALUES_STATIC

# 第二段: 需要展开变量的少量标量(interval / 口令)。单独一段是为了让第一段能用带引号的 heredoc。
# 外加 PROMETHEUS_GRAFANA_PLUGIN_DIR 非空时的插件目录覆盖(见下)。
cat >> "${_VALUES_YAML}" <<PROM_VALUES_DYN
    scrapeInterval: "${PROMETHEUS_SCRAPE_INTERVAL}"
    evaluationInterval: "${PROMETHEUS_EVALUATION_INTERVAL}"
grafana:
  adminUser: "${GRAFANA_ADMIN_USER}"
  adminPassword: "${GRAFANA_ADMIN_PASSWORD}"
PROM_VALUES_DYN
# 插件目录覆盖块必须**单独追加**: heredoc 结束符要求顶格独占一行, 不能写成 ${VAR}DELIM。
# 内容是缩进的键, 直接续在上面的 `grafana:` 映射里(YAML 合法)。
[ -n "${_PROM_GRAFANA_PLUGIN_BLOCK}" ] && printf '%s' "${_PROM_GRAFANA_PLUGIN_BLOCK}" >> "${_VALUES_YAML}"

# 第三段: node-exporter —— IB 采集 + node label(§1.3)
# ⚠ extraArgs 是**整体替换**: 前两条是 chart 默认值(必须原样保留), 第三条才是本次新增。
cat >> "${_VALUES_YAML}" <<'PROM_VALUES_NODE'
# ── §1.3 node-exporter: infiniband 采集 + node label(RDMA / 按节点分组规则依赖) ──
prometheus-node-exporter:
  extraArgs:
    # ↓ 以下两条是 kube-prometheus-stack 的默认值, 因 Helm 对数组是整体替换, 必须原样带上
    - --collector.filesystem.mount-points-exclude=^/(dev|proc|sys|run/containerd/.+|var/lib/docker/.+|var/lib/kubelet/.+)($|/)
    - --collector.filesystem.fs-types-exclude=^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs|erofs)$
    # ↓ 本次新增: 默认 collector 不含 IB; 不开则 node_infiniband_* 全缺, RDMA dashboard 无数据。
    #   无需额外挂载 —— chart 已把宿主 /sys 挂到 /host/sys 且传了 --path.sysfs, infiniband
    #   collector 正是走 sysfsPath(与 10_rdma 那次"无设备节点挂 /sys/class/infiniband 报
    #   operation not permitted"是两回事)。
    - --collector.infiniband
  prometheus:
    monitor:
      # 默认 ServiceMonitor 不打 node label(instance 是 节点IP:端口, 不是节点名), 而
      # cluster_node:cubestack_network_rdma_port_up:min 等规则按 node 分组 → 缺 label 时
      # 输出无节点维度的序列。这里从 SD 元数据把 pod 所在节点名补成 node label。
      relabelings:
        - sourceLabels: [__meta_kubernetes_pod_node_name]
          targetLabel: node
          action: replace
PROM_VALUES_NODE

helm upgrade --install "${PROMETHEUS_RELEASE_NAME}" "${CHART_DIR}" \
    --namespace "${PROMETHEUS_NAMESPACE}" --create-namespace \
    -f "${_VALUES_YAML}" \
    --set "prometheusOperator.image.registry=${REG_BASE}" --set "prometheusOperator.image.tag=${PROMETHEUS_APP_VERSION}" \
    --set "prometheusOperator.prometheusConfigReloader.image.registry=${REG_BASE}" --set "prometheusOperator.prometheusConfigReloader.image.tag=${PROMETHEUS_APP_VERSION}" \
    --set "prometheusOperator.admissionWebhooks.patch.image.registry=${REG_BASE}" --set "prometheusOperator.admissionWebhooks.patch.image.tag=${PROMETHEUS_IMAGE_CERTGEN}" \
    --set "prometheusOperator.admissionWebhooks.deployment.image.registry=${REG_BASE}" --set "prometheusOperator.admissionWebhooks.deployment.image.tag=${PROMETHEUS_APP_VERSION}" \
    --set "prometheus.prometheusSpec.image.registry=${REG_BASE}" --set "prometheus.prometheusSpec.image.tag=${PROMETHEUS_IMAGE_PROMETHEUS}" \
    --set "prometheus.prometheusSpec.retention=${PROMETHEUS_RETENTION_DAYS}" \
    --set "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=${PROMETHEUS_STORAGE_SIZE}" \
    --set "alertmanager.alertmanagerSpec.image.registry=${REG_BASE}" --set "alertmanager.alertmanagerSpec.image.tag=${PROMETHEUS_IMAGE_ALERTMANAGER}" \
    --set "kube-state-metrics.image.registry=${REG_BASE}" --set "kube-state-metrics.image.tag=${PROMETHEUS_IMAGE_KSM}" \
    --set "kube-state-metrics.kubeRBACProxy.enabled=false" \
    --set "prometheus-node-exporter.image.registry=${REG_BASE}" --set "prometheus-node-exporter.image.tag=${PROMETHEUS_IMAGE_NODE_EXPORTER}" \
    --set "prometheus-node-exporter.image.distroless=false" \
    --set "grafana.image.registry=${REG_BASE}" --set "grafana.image.tag=${PROMETHEUS_IMAGE_GRAFANA}" \
    --set "grafana.sidecar.image.registry=${REG_BASE}" --set "grafana.sidecar.image.tag=${PROMETHEUS_IMAGE_SIDECAR}" \
    --set "thanosRuler.enabled=false" \
    --wait --timeout 300s \
    || warn "  helm 安装/等待超时(检查 --set/values 与 chart; 资源可能已创建, 继续等待组件就绪)..."
# 口令已进集群 secret, 临时 values 文件即刻销毁(不留盘)
rm -f "${_VALUES_YAML}"; unset _VALUES_YAML

# ── 4. 等待组件就绪 + 验证 ──
say "[4/8] 等待监控组件就绪(operator / prometheus / alertmanager / grafana / exporters)..."
# ★ 2026-09-20 修复(既有的**永久假告警**): 原来是 `rollout status deploy ${RELEASE}-operator`,
#   但 chart 生成的 operator Deployment 名是 `<release>-kube-prome-operator`
#   (kube-prometheus-stack 对子组件加 `kube-prome-` 中缀), 于是这条**从来没成功过** ——
#   每次都打 "operator 180s 内未 Ready", 而 operator 其实早就 1/1 Running。
#   永假的告警会训练人忽略告警, 所以按名字动态查(与 31_cubepilot 同款写法), 不硬编码。
_OP_DEPLOY="$( (SSH "${K} -n ${PROMETHEUS_NAMESPACE} get deploy -o name 2>/dev/null" || true) | sed -n 's#.*/##p' | grep -m1 'operator' || true)"
if [ -n "${_OP_DEPLOY}" ]; then
    SSH "${K} -n ${PROMETHEUS_NAMESPACE} rollout status deploy/${_OP_DEPLOY} --timeout=180s" >/dev/null 2>&1 \
        && ok "  prometheus-operator Ready(${_OP_DEPLOY})" \
        || warn "  operator ${_OP_DEPLOY} 180s 内未 Ready(继续检查其余组件)..."
else
    warn "  未发现 operator Deployment(helm 安装是否成功?)"
fi
unset _OP_DEPLOY
_PODS_READY=0
for _i in $(seq 1 60); do
    _pending="$( (SSH "${K} -n ${PROMETHEUS_NAMESPACE} get pods --no-headers 2>/dev/null" || true) | awk '$3 != "Running" && $3 != "Completed" {n++} END{print n+0}' )"
    _running="$( (SSH "${K} -n ${PROMETHEUS_NAMESPACE} get pods --no-headers 2>/dev/null" || true) | awk '$3 == "Running" {n++} END{print n+0}' )"
    if [ "${_pending:-0}" -eq 0 ] && [ "${_running:-0}" -ge 4 ]; then
        _PODS_READY=1; break
    fi
    sleep 10
done
if [ "${_PODS_READY}" = "1" ]; then
    ok "  监控组件全部 Running(${_running} 个 pod)"
else
    warn "  300s 内未全部就绪(部分 pod 可能仍 Pending/CrashLoop; 用 kubectl -n ${PROMETHEUS_NAMESPACE} get pods 复查)"
fi
unset _pending _running _PODS_READY _i

# ★ 2026-09-11(用户要求): 部署流程内自动做**真实功能验证**(不只 pod Running)。
#   取出 Prometheus pod IP, 从首个 master curl PromQL API 查询 `up == 1` + node 指标:
#   若 operator 只把 pod 拉起来但 采集/存储/查询 链断, data.result 为空即此处失败提示;
#   不阻断部署(组成为 Base 在继续), 只 ok/warn 供早暴露故障(同 22/27 verify 的"早暴露"意图)。
_PROM_CR_N="${PROMETHEUS_RELEASE_NAME}-kube-prome-prometheus"
# ★ 2026-09-20: 带重试。Prometheus CR 的 spec 一变(如本次改 selector/interval)operator 就会
#   重建 pod, pod IP 在重建窗口内**取得到但为空** —— 原来一次取不到就跳过自检,
#   结果是"改了 values 的那次部署恰恰不做数据链自检"(最需要它的时候没有)。
_PROM_IP_JSON=""
for _i in $(seq 1 12); do
    _PROM_IP_JSON=$(SSH "${K}" -n "${PROMETHEUS_NAMESPACE}" get pod -l operator.prometheus.io/name="${_PROM_CR_N}" -o jsonpath '{.items[0].status.podIP}' 2>/dev/null || true)
    [ -n "${_PROM_IP_JSON}" ] && break
    sleep 10
done
if [ -n "${_PROM_IP_JSON}" ]; then
    say "  数据链自检: curl ${_PROM_IP_JSON}:9090 PromQL up ..."
    # ★ 2026-09-11 修复: curl 必须在首个 master 节点上执行(部署机/容器 bridge 网络
    #   到不了集群 overlay 的 10.233.x pod IP, 本地 curl 返回空 → 误报"无结果")
    _PROM_UP=$(SSH "curl -s --max-time 15 'http://${_PROM_IP_JSON}:9090/api/v1/query?query=up'" 2>/dev/null || true)
    _PROM_N=$(printf '%s\n' "${_PROM_UP}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data',{}).get('result',[])))" 2>/dev/null || echo 0)
    if [ "${_PROM_N:-0}" -gt 0 ] 2>/dev/null; then
        ok "  Prometheus 数据链自检通过: up 查询 → ${_PROM_N} 个采集目标"
    else
        warn "  Prometheus 数据链自检: up 查询暂无结果(非必现, 稍后 kubectl -n ${PROMETHEUS_NAMESPACE} get servicemonitor 复核)"
    fi
    unset _PROM_UP _PROM_N
else
    warn "  取不到 Prometheus pod IP, 跳过数据链自检"
fi
unset _PROM_CR_N _PROM_IP_JSON

# ── 5. CubeStack recording rules(§2) ──
# 规则 CR 里写死 `namespace: monitoring`; 与 PROMETHEUS_NAMESPACE 不一致时**必须重写** ——
# kubectl apply 对 manifest 内显式 namespace 是"以文件为准", 会静默建到 monitoring 去
# (规则"消失"且不报错)。sed 重写后再下发, 两种命名空间都正确。
say "[5/8] 下发 CubeStack recording rules(${#_OBS_RULES[@]} 个 → ns ${PROMETHEUS_NAMESPACE})..."
_RULES_OK=0
for _rf in "${_OBS_RULES[@]}"; do
    _rf_name="$(basename "${_rf}")"
    _rf_tmp="$(mktemp)"
    # 只重写 metadata 下的 namespace 行(anchored), 避免误伤 spec 内的同名文本
    sed -E "s/^([[:space:]]*)namespace:[[:space:]]*monitoring[[:space:]]*\$/\1namespace: ${PROMETHEUS_NAMESPACE}/" \
        "${_rf}" > "${_rf_tmp}"
    if SSH "${K} apply -f -" < "${_rf_tmp}" >/dev/null 2>&1; then
        _RULES_OK=$((_RULES_OK + 1))
    else
        warn "  ${_rf_name} 下发失败(kubectl apply --dry-run=server 复查)"
    fi
    rm -f "${_rf_tmp}"
done
if [ "${_RULES_OK}" -eq 0 ]; then
    err "  没有一条 recording rule 下发成功(检查 CRD 是否就绪: kubectl get crd prometheusrules.monitoring.coreos.com)"
    exit 1
fi
# 第二道保险(§2 实测采用的另一种做法): 给规则 CR 补 `release: <release>` 标签。
# 本模块的 ruleSelector 已按 part-of 取并集, 理论上不需要它; 但静默失效的代价太大(规则不加载
# 且无任何报错), 冗余一层 —— 万一有人把 selector 改回 chart 默认的 release 匹配, 规则仍在。
SSH "${K} -n ${PROMETHEUS_NAMESPACE} label prometheusrule -l app.kubernetes.io/part-of=cubestack-observability release=${PROMETHEUS_RELEASE_NAME} --overwrite" >/dev/null 2>&1 \
    && ok "  recording rules 已下发 ${_RULES_OK}/${#_OBS_RULES[@]} 个, 并补 release=${PROMETHEUS_RELEASE_NAME} 标签" \
    || warn "  recording rules 已下发 ${_RULES_OK}/${#_OBS_RULES[@]} 个(补 release 标签失败, 不影响 part-of 选择器)"
unset _rf _rf_name _rf_tmp _RULES_OK

# ── 6. Grafana dashboard → ConfigMap(§3) ──
# 一个 dashboard 一个 CM(文件名即 key), 打 grafana_dashboard=1 → grafana sidecar 自动导入。
# 为什么用 ConfigMap 而不是 Grafana API: API 导入只写 Grafana DB, 而默认 chart 不挂 PVC,
# Pod 重建即丢; ConfigMap 在 etcd 里, sidecar 每次启动重新导入, helm upgrade/重建都不丢。
say "[6/8] 导入 Grafana dashboard(${#_OBS_DASHS[@]} 个 → ConfigMap, sidecar 自动导入)..."
_DASH_OK=0
for _df in "${_OBS_DASHS[@]}"; do
    _d_base="$(basename "${_df}" .json)"
    _d_cm="cubestack-${_d_base}"
    _d_tmp="$(mktemp)"
    _d_src="${_df}"
    # ★ 数据源自动绑定: 上游看板里的数据源引用是别人环境的 uid/名字 → 统一改绑本集群这份,
    #   否则面板报 "Datasource not found"(看板导入成功但全空)。改的是**临时副本**, 仓库源不动。
    if bool_is_true "${GRAFANA_DS_AUTOBIND}"; then
        _d_norm="$(mktemp)"
        if python3 "${SCRIPT_DIR}/tools/observability/normalize-dashboard-datasource.py" \
                "${_df}" "${_d_norm}" "${GRAFANA_DATASOURCE_UID}" "${GRAFANA_DATASOURCE_NAME}" 2>>"${LOG_FILE:-/dev/null}"; then
            _d_src="${_d_norm}"
        else
            warn "  ${_d_base} 数据源引用规范化失败, 按原始 JSON 导入(该看板面板可能选不到数据源)"
        fi
    fi
    # ⚠ CM 的 key 必须仍是原始文件名(用 --from-file=<key>=<path>): 规范化后是临时文件名
    # 本地生成 CM YAML(kubectl 负责把 JSON 正确地渲染成块标量), 再管道给集群 apply。
    # `kubectl label --local` 只改本地对象、不碰 API → 一次 apply 就带上 label,
    # 避免"先 apply 再 label"让 sidecar 看到两次变更而重复重载。
    # ★ 2026-09-20: 必须用 **--server-side**。客户端 apply 会把整个配置存进
    #   `kubectl.kubernetes.io/last-applied-configuration` 注解, 而该注解**硬上限 256KiB**
    #   → 大看板(node-exporter-1860.json 460KB → CM 522KB)必报
    #   "metadata.annotations: Too long: may not be more than 262144 bytes" 而失败。
    #   服务端 apply 不走这个注解, 522KB 正常创建(实机验证)。
    #   本模块独占管理这些 CM, 不存在与其它 field manager 的冲突。
    if kubectl create configmap "${_d_cm}" -n "${PROMETHEUS_NAMESPACE}" \
            --from-file="${_d_base}.json=${_d_src}" --dry-run=client -o yaml 2>/dev/null \
        | kubectl label --local -f - -o yaml \
            grafana_dashboard=1 \
            app.kubernetes.io/part-of=cubestack-observability \
            "cubestack.io/dashboard=${_d_base}" 2>/dev/null > "${_d_tmp}" \
        && [ -s "${_d_tmp}" ] \
        && SSH "${K} apply --server-side -f -" < "${_d_tmp}" >/dev/null 2>&1; then
        _DASH_OK=$((_DASH_OK + 1))
    else
        warn "  ${_d_base} 导入失败(kubectl create configmap --dry-run=client 本地复查)"
    fi
    rm -f "${_d_tmp}" "${_d_norm:-}"
done
if [ "${_DASH_OK}" -eq 0 ]; then
    err "  没有一条 dashboard 导入成功"
    exit 1
fi
ok "  dashboard ConfigMap 已下发 ${_DASH_OK}/${#_OBS_DASHS[@]} 个(label grafana_dashboard=1)"
unset _df _d_base _d_cm _d_tmp _DASH_OK

# ── 7. MetaX mx-exporter(§7.1) ──
# GPU dashboard 的数据源: MetaX operator 的 dataExporter 默认**不部署**
# (ClusterOperator CR spec.dataExporter.deploy: false), 需显式打开。
# 判据用 CR 是否存在(而不是 GPU_OPERATOR_ENABLED 配置) —— 配置为 true 但实际没装时,
# 这里应该安静跳过而不是报错。
say "[7/8] MetaX GPU exporter(mx-exporter)..."
if [ "${MX_EXPORTER_ENABLED}" != "true" ]; then
    say "  MX_EXPORTER_ENABLED!=true, 跳过"
elif [ -z "$( (SSH "${K} -n ${METAX_NAMESPACE} get clusteroperator cluster-operator --no-headers 2>/dev/null" || true) )" ]; then
    say "  未发现 MetaX ClusterOperator(ns ${METAX_NAMESPACE}), 跳过(未部署 MetaX GPU Operator 时正常)"
else
    # ① 打开 dataExporter。这里 patch 是**兜底** —— 06_gpu_operator 已通过 helm value 设过,
    #    但 helm upgrade 会把 CR 重渲染回 chart 默认值, 而 06 是 REPEAT:0(装过就不再跑),
    #    所以对"用旧版脚本装的集群"这一步是唯一能让 exporter 起来的途径。幂等。
    _MXDEPLOY="$(SSH "${K} -n ${METAX_NAMESPACE} get clusteroperator cluster-operator -o jsonpath='{.spec.dataExporter.deploy}' 2>/dev/null" || true)"
    if [ "${_MXDEPLOY}" = "true" ]; then
        ok "  ClusterOperator dataExporter 已开启"
    else
        say "  ClusterOperator dataExporter=${_MXDEPLOY:-<未设置>} → 置为 true..."
        SSH "${K} -n ${METAX_NAMESPACE} patch clusteroperator cluster-operator --type=merge -p '{\"spec\":{\"dataExporter\":{\"deploy\":true}}}'" >/dev/null 2>&1 \
            && ok "  已开启(operator 随后在 GPU 节点起 metax-data-exporter DaemonSet + Service)" \
            || warn "  patch 失败(kubectl -n ${METAX_NAMESPACE} get clusteroperator cluster-operator -o yaml 复查)"
    fi
    # ② ServiceMonitor: 让 Prometheus 抓它。Service 的 label 由 operator 打, selector 按文档用 app: metax-data-exporter。
    _MXSM="$(mktemp)"
    cat > "${_MXSM}" <<MXSM_YAML
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: cubestack-mx-exporter
  namespace: ${METAX_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: cubestack-observability
spec:
  namespaceSelector:
    matchNames:
      - ${METAX_NAMESPACE}
  selector:
    matchLabels:
      app: metax-data-exporter
  endpoints:
    - port: metrics
      interval: ${PROMETHEUS_SCRAPE_INTERVAL}
MXSM_YAML
    SSH "${K} apply -f -" < "${_MXSM}" >/dev/null 2>&1 \
        && ok "  ServiceMonitor cubestack-mx-exporter 已下发(选 app=metax-data-exporter)" \
        || warn "  ServiceMonitor 下发失败(CRD monitoring.coreos.com/v1 就绪?)"
    rm -f "${_MXSM}"
    unset _MXDEPLOY _MXSM
fi

# ── 8. Grafana 对外暴露(nodeport / loadbalancer; MetalLB 模式下与 registry 共用同一 VIP) ──
# PROMETHEUS_EXPOSE_MODE: 空 = 随 SERVICE_EXPOSE_MODE(nodeport / metallb); 也可显式
#                         nodeport | loadbalancer | metallb | clusterip
#   ⚠ **metallb 与 loadbalancer 同义**(全局开关写 metallb, 本变量历史上写 loadbalancer)。
#     不做归一化的话 SERVICE_EXPOSE_MODE=metallb 会掉进 *) 分支 → 静默变成 ClusterIP,
#     只给 port-forward 提示(2026-09-22 实机踩到: 用户以为暴露了, 实际根本没建 Service)。
# PROMETHEUS_EXPOSE_PROMETHEUS: 是否连 Prometheus 一起暴露(默认 false —— 从 Grafana 里当数据源看即可)
#   nodeport     → <svc>-external NodePort(prometheus=base+0 / grafana=base+1, 偏移固定不随暴露清单变)
#   loadbalancer → <svc>-external LoadBalancer; 默认**共用 registry 的 VIP**(不同端口区分),
#                  共用不成立时自动降级为独立 VIP 并打印实际地址(绝不静默停在 <pending>)
#   clusterip    → 保持仅集群内(末尾给 port-forward 指引)
say "[8/8] 配置 Grafana 对外暴露(PROMETHEUS_EXPOSE_MODE=${PROMETHEUS_EXPOSE_MODE:-<随 SERVICE_EXPOSE_MODE>})..."
PROMETHEUS_EXPOSE_MODE="${PROMETHEUS_EXPOSE_MODE:-${SERVICE_EXPOSE_MODE:-clusterip}}"
case "$(echo "${PROMETHEUS_EXPOSE_MODE}" | tr '[:upper:]' '[:lower:]')" in
    metallb|loadbalancer|lb) PROMETHEUS_EXPOSE_MODE="loadbalancer" ;;
    nodeport|np)             PROMETHEUS_EXPOSE_MODE="nodeport" ;;
    ""|clusterip|none)       PROMETHEUS_EXPOSE_MODE="clusterip" ;;
    *) warn "  PROMETHEUS_EXPOSE_MODE=${PROMETHEUS_EXPOSE_MODE} 无法识别(可用 nodeport|metallb|loadbalancer|clusterip) → 按 clusterip 处理"
       PROMETHEUS_EXPOSE_MODE="clusterip" ;;
esac

_PROM_APPS=(grafana)                                  # 默认只暴露 Grafana
bool_is_true "${PROMETHEUS_EXPOSE_PROMETHEUS:-false}" && _PROM_APPS=(prometheus grafana)
_PROM_NP_BASE="${PROMETHEUS_NODEPORT_BASE:-31000}"    # prometheus=base+0, grafana=base+1
_prom_app_port() { case "$1" in prometheus) echo 9090 ;; grafana) echo 3000 ;; *) echo "" ;; esac; }
_prom_np_port()  { case "$1" in prometheus) echo "$(( _PROM_NP_BASE + 0 ))" ;; grafana) echo "$(( _PROM_NP_BASE + 1 ))" ;; esac; }
_PROM_ACCESS=()                                       # 汇总可访问地址(供末尾打印)
_PROM_NODE_IP="<节点IP>"                              # nodeport 模式的入口 = 任意节点 IP(打印具体值更省事)
if [ "${PROMETHEUS_EXPOSE_MODE}" = "nodeport" ]; then
    _PROM_NODE_IP="$(first_node_ip 2>/dev/null || echo '<节点IP>')"
fi

# 共用 registry 的 VIP: 需要 registry 侧带同一个 sharing key 注解(MetalLB 的硬要求, 见 lib-common.sh 约定)。
_PROM_SHARE_VIP=0
if [ "${PROMETHEUS_EXPOSE_MODE}" = "loadbalancer" ] && bool_is_true "${PROMETHEUS_SHARE_REGISTRY_VIP:-true}" && [ -n "${REGISTRY_IP:-}" ]; then
    _PROM_SHARE_VIP=1
    # 存量集群: registry Service 由 kubespray 建, 其 manifest 里的 sharing key 注解要等下次
    # k8s_deploy 才生效 → 这里幂等补一次, 否则 MetalLB 不会让 Grafana 共用它的 VIP。
    SSH "${K}" -n kube-system annotate svc registry "${SHARED_VIP_ANNOTATION}=${SHARED_VIP_KEY}" --overwrite >/dev/null 2>&1 \
        && vlog "已确保 registry Service 带共用注解 ${SHARED_VIP_ANNOTATION}=${SHARED_VIP_KEY}" \
        || warn "  registry Service 注解补写失败(kubectl -n kube-system annotate svc registry ${SHARED_VIP_ANNOTATION}=${SHARED_VIP_KEY} --overwrite)"
fi

# 建/更新 <svc>-external 的 LoadBalancer Service 并等 MetalLB 分配。
#   $1=app 名 $2=svc 名 $3=应用端口 $4=1 表示带共用 VIP 配置(注解 + 固定 loadBalancerIP)
# 结果放全局 _PROM_LB_IP(拿不到 VIP 时为空); apply 提交失败返回 1。
_prom_lb_apply() {
    local _app="$1" _svc="$2" _port="$3" _share="$4" _ann="" _ip="" _yaml _t
    _PROM_LB_IP=""
    if [ "${_share}" = "1" ]; then
        # printf -v(而非 $(...)): 命令替换会吃掉行尾换行, 拼进 YAML 时会把两行黏成一行
        printf -v _ann '  annotations:\n    %s: %s\n' "${SHARED_VIP_ANNOTATION}" "${SHARED_VIP_KEY}"
        printf -v _ip '  loadBalancerIP: %s\n' "${REGISTRY_IP}"
    fi
    _yaml="$(mktemp)"
    cat > "${_yaml}" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${_svc}-external
  namespace: ${PROMETHEUS_NAMESPACE}
  labels:
    app.kubernetes.io/name: ${_svc}-external
${_ann}spec:
  type: LoadBalancer
  externalTrafficPolicy: Cluster
${_ip}  selector:
    app.kubernetes.io/name: ${_app}
    app.kubernetes.io/instance: ${PROMETHEUS_RELEASE_NAME}
  ports:
    - port: ${_port}
      targetPort: ${_port}
      protocol: TCP
EOF
    if ! SSH "${K}" -n "${PROMETHEUS_NAMESPACE}" apply -f - < "${_yaml}" >/dev/null 2>&1; then
        rm -f "${_yaml}"; return 1
    fi
    rm -f "${_yaml}"

    for _t in $(seq 1 "${PROMETHEUS_LB_WAIT_TRIES:-20}"); do   # 最长 tries × 3s
        _PROM_LB_IP="$(SSH "${K}" -n "${PROMETHEUS_NAMESPACE}" get svc "${_svc}-external" -o 'jsonpath={.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
        [ -n "${_PROM_LB_IP}" ] && break
        sleep 3
    done
    return 0
}

for _idx in "${!_PROM_APPS[@]}"; do
    _app="${_PROM_APPS[$_idx]}"
    _svc="${PROMETHEUS_RELEASE_NAME}-${_app}"
    _app_port="$(_prom_app_port "${_app}")"
    case "${PROMETHEUS_EXPOSE_MODE}" in
        nodeport)
            _ext_port="$(_prom_np_port "${_app}")"        # 外部 NodePort(偏移固定, 与是否暴露 prometheus 无关)
            say "  ${_app}: NodePort ${_ext_port}(独立 Service ${_svc}-external)..."
            # ★ 2026-09-14 修复(两处缺陷):
            #   1. kubectl create service nodeport --tcp=<port>:<port> 会把 targetPort 也写成外部端口
            #      (31000/31001), 而 Prometheus 实际监听 9090、Grafana 3000 → 转发目标错, 连接失败。
            #      正确: service port 用 NodePort 外部端口, targetPort 用应用真实端口。
            #   2. 该 create 自带 selector(app=<svc名>, 指向不存在的 label), 之后 merge patch 追加
            #      两个 selector 键 → 与默认合并成 AND(要求同时匹配 app=<svc名>)→ Endpoints 永远为空。
            #      修复: 先删默认 selector(app=键), 再 merge patch 真正的 selector。
            #   改用直接 apply 完整 YAML(幂等), 不再 create+patch 两段式。
            _ext_yaml="$(mktemp)"
            cat > "${_ext_yaml}" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${_svc}-external
  namespace: ${PROMETHEUS_NAMESPACE}
  labels:
    app.kubernetes.io/name: ${_svc}-external
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: ${_app}
    app.kubernetes.io/instance: ${PROMETHEUS_RELEASE_NAME}
  ports:
    - port: ${_ext_port}
      targetPort: ${_app_port}
      nodePort: ${_ext_port}
      protocol: TCP
EOF
            SSH "${K}" -n "${PROMETHEUS_NAMESPACE}" delete svc "${_svc}-external" --ignore-not-found=true >/dev/null 2>&1 || true
            SSH "${K}" -n "${PROMETHEUS_NAMESPACE}" apply -f - < "${_ext_yaml}" >/dev/null 2>&1 \
                && ok "  ${_app} 外部入口: http://${_PROM_NODE_IP}:${_ext_port}/  (target ${_app_port})" \
                || warn "  ${_app} 外部 Service 创建失败(kubectl -n ${PROMETHEUS_NAMESPACE} get svc ${_svc}-external)"
            rm -f "${_ext_yaml}"
            _PROM_ACCESS+=("${_app}|http://${_PROM_NODE_IP}:${_ext_port}/")
            ;;
        loadbalancer)
            # 用独立 *-external Service(而不是把 helm 管的 Service 改成 LoadBalancer):
            # helm upgrade 不会把这个类型改回去, 也不会与 chart 的期望状态打架。
            if [ "${_PROM_SHARE_VIP}" = "1" ]; then
                say "  ${_app}: LoadBalancer 端口 ${_app_port} —— 与 registry 共用 VIP ${REGISTRY_IP} ..."
            else
                say "  ${_app}: LoadBalancer 端口 ${_app_port} —— MetalLB 自动分配 VIP ..."
            fi
            if ! _prom_lb_apply "${_app}" "${_svc}" "${_app_port}" "${_PROM_SHARE_VIP}"; then
                warn "  ${_app} 外部 Service 创建失败(kubectl -n ${PROMETHEUS_NAMESPACE} get svc ${_svc}-external 复查)"
            elif [ -n "${_PROM_LB_IP}" ]; then
                [ "${_PROM_SHARE_VIP}" = "1" ] && [ "${_PROM_LB_IP}" != "${REGISTRY_IP}" ] && \
                    warn "  期望共用 ${REGISTRY_IP}, 实际拿到 ${_PROM_LB_IP}(MetalLB 未接受共用, 端口冲突?)"
                ok "  ${_app} 入口: http://${_PROM_LB_IP}:${_app_port}/"
                _PROM_ACCESS+=("${_app}|http://${_PROM_LB_IP}:${_app_port}/")
            elif [ "${_PROM_SHARE_VIP}" = "1" ]; then
                # 共用没成(注解未生效 / 该 IP 已被别人占) → 降级为独立 VIP 重建, 绝不静默停在 <pending>。
                warn "  共用 ${REGISTRY_IP} 超时未分配到 VIP → 降级为独立 VIP(从 METALLB_POOL 自动分配)重试"
                if _prom_lb_apply "${_app}" "${_svc}" "${_app_port}" 0 && [ -n "${_PROM_LB_IP}" ]; then
                    ok "  ${_app} 入口(独立 VIP): http://${_PROM_LB_IP}:${_app_port}/"
                    _PROM_ACCESS+=("${_app}|http://${_PROM_LB_IP}:${_app_port}/")
                else
                    warn "  ${_app} 仍未拿到 VIP —— 检查 METALLB_POOL 是否还有空闲地址(kubectl -n ${PROMETHEUS_NAMESPACE} describe svc ${_svc}-external)"
                fi
            else
                warn "  ${_app} 超时未拿到 VIP —— 检查 METALLB_POOL 是否还有空闲地址(kubectl -n ${PROMETHEUS_NAMESPACE} describe svc ${_svc}-external)"
            fi
            ;;
        *) say "  ${_app}: ClusterIP(仅集群内)" ;;
    esac
done
unset _idx _app _svc _app_port _ext_port _ext_yaml

# ── 9. 数据源可用性校验(★ 2026-09-22 新增; 这一步的存在本身就是一次事故的产物) ──
# 为什么必须"真查一次": Grafana 13.2 起数据源插件外置(见开头 PROMETHEUS_GRAFANA_PLUGIN_DIR 注释),
# 离线环境装不上插件时 —— 数据源**对象**照样被 provisioning 建出来、Grafana 也照样 Running,
# 但任何查询都报 "Unable to find datasource plugin", **所有看板无数据**。
# 2026-09-22 实机就是这样一路绿灯装完、用户点开看板才发现是空的。所以本模块不再"装完即成功"。
#   判据(两条都要过): ① 数据源 health 正常; ② 经 Grafana 代理跑一条真实 PromQL 返回 success。
# 口令处理: 经 heredoc 文本(SSH stdin)下发 → 落成 master 上 600 的临时 netrc 用后即删,
# **不进任何一端 argv/ps**; 含单引号的口令为避免转义风险跳过自动校验并提示手工验。
if [ "${GRAFANA_DS_VERIFY}" = "off" ]; then
    say "[9/9] 数据源可用性校验: 已关闭(GRAFANA_DS_VERIFY=off)"
else
    say "[9/9] 校验 Grafana → Prometheus 数据源真的可用..."
    _g_ip="$( (SSH "${K}" -n "${PROMETHEUS_NAMESPACE}" get svc "${PROMETHEUS_RELEASE_NAME}-grafana" -o 'jsonpath={.spec.clusterIP}' 2>/dev/null || true) )"
    _ds_ok=0; _ds_msg=""
    if [ -z "${_g_ip}" ]; then
        _ds_msg="取不到 Grafana Service ClusterIP(kubectl -n ${PROMETHEUS_NAMESPACE} get svc ${PROMETHEUS_RELEASE_NAME}-grafana)"
    elif case "${GRAFANA_ADMIN_PASSWORD}" in *"'"*) true;; *) false;; esac; then
        warn "  GRAFANA_ADMIN_PASSWORD 含单引号, 跳过自动校验(避免远端转义踩坑); 请手工验证:"
        warn "    curl -u admin:'<口令>' http://<grafana>:3000/api/datasources/uid/prometheus/health"
        _ds_ok=2
    else
        _ds_out="$(SSH "bash -s" <<REMOTE 2>/dev/null || true
umask 077
_nrc="/tmp/.grafana-ds-netrc.\$\$"
printf 'machine %s login %s password %s\n' "${_g_ip}" "${GRAFANA_ADMIN_USER}" '${GRAFANA_ADMIN_PASSWORD}' > "\${_nrc}"
trap 'rm -f "\${_nrc}"' EXIT
echo "HEALTH:\$(curl -s -m 10 --netrc-file "\${_nrc}" "http://${_g_ip}/api/datasources/uid/prometheus/health")"
echo "QUERY:\$(curl -s -m 10 --netrc-file "\${_nrc}" --get --data-urlencode 'query=count(up)' "http://${_g_ip}/api/datasources/proxy/uid/prometheus/api/v1/query")"
REMOTE
)"
        _ds_health="$(printf '%s' "${_ds_out}" | sed -n 's/^HEALTH://p')"
        _ds_query="$(printf '%s' "${_ds_out}"  | sed -n 's/^QUERY://p')"
        if printf '%s' "${_ds_health}${_ds_query}" | grep -q 'plugin.notRegistered\|Unable to find datasource plugin'; then
            _ds_msg="Grafana 找不到 prometheus 数据源插件(插件未预装)"
        elif printf '%s' "${_ds_query}" | grep -q '"status":"success"'; then
            _ds_ok=1
        else
            _ds_msg="查询未返回 success: health=${_ds_health:-<空>} query=${_ds_query:-<空>}"
        fi
    fi

    if [ "${_ds_ok}" = "1" ]; then
        _ds_val="$(printf '%s' "${_ds_query}" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); r=d["data"]["result"]
    print(r[0]["value"][1] if r else "0")
except Exception: print("?")' 2>/dev/null || echo "?")"
        ok "  数据源可用: Prometheus 查询正常(count(up)=${_ds_val}); Grafana 看板可出数"
    elif [ "${_ds_ok}" = "2" ]; then
        :   # 上面已提示手工验
    else
        err "  Grafana 数据源不可用: ${_ds_msg}"
        err "  影响: Grafana 能登录, 但所有 dashboard 无数据(数据源对象存在 ≠ 能用)。"
        err "  最常见的根因: Grafana ≥13.2 把数据源改成**独立插件**, 离线环境下载不到。"
        err "  修法(二选一):"
        err "    ① 用预装插件的派生镜像 —— 联网机执行:"
        err "         bash deployments/scripts/tools/images/grafana-plugin-build.sh"
        err "       然后 cluster.conf 设 PROMETHEUS_IMAGE_GRAFANA=<构建出的 tag>(如 13.2.1-distroless-r1)"
        err "       与 PROMETHEUS_GRAFANA_PLUGIN_DIR=/opt/grafana-plugins 后重跑本模块;"
        err "    ② 或把 Grafana 换回仍内置数据源的版本(≤13.1, 改 PROMETHEUS_IMAGE_GRAFANA)。"
        err "  排查: kubectl -n ${PROMETHEUS_NAMESPACE} logs deploy/${PROMETHEUS_RELEASE_NAME}-grafana -c grafana | grep -i 'plugins installed'"
        err "  (确认是环境问题想先放过: cluster.conf 设 GRAFANA_DS_VERIFY=warn)"
        [ "${GRAFANA_DS_VERIFY}" = "warn" ] && warn "  GRAFANA_DS_VERIFY=warn → 仅告警, 继续" || exit 1
    fi
    unset _g_ip _ds_out _ds_health _ds_query _ds_ok _ds_msg _ds_val
fi

echo "---------------------------------------------"
ok "Prometheus 监控底座部署完成(kube-prometheus-stack + CubeStack 可观测性)"
echo "  namespace:    ${PROMETHEUS_NAMESPACE}"
echo "  retention:    ${PROMETHEUS_RETENTION_DAYS}   Prometheus PVC: ${PROMETHEUS_STORAGE_SIZE}(默认 StorageClass)"
echo "  查询:         kubectl -n ${PROMETHEUS_NAMESPACE} get pods,svc"
echo "  ── CubeStack 可观测性(★ 2026-09-20 新增) ──"
echo "  资产来源:     ${_OBS_DIR}(${_OBS_SRC})"
echo "  recording rules: ${#_OBS_RULES[@]} 个 PrometheusRule(已补 release=${PROMETHEUS_RELEASE_NAME} 标签)"
echo "                  ⚠ 必须用 /api/v1/rules 确认真实加载, 不能只看 CR 创建成功(CR 建了规则未必加载)"
echo "                     sudo ./deploy-cluster.sh --steps verify_prometheus 会逐组断言实际加载情况"
echo "  dashboards:   ${#_OBS_DASHS[@]} 个 ConfigMap(label grafana_dashboard=1, 由 sidecar 导入)"
echo "  Grafana 口令: 见 cluster.conf GRAFANA_ADMIN_PASSWORD(用户 ${GRAFANA_ADMIN_USER})"
echo "  KSM allowlist: pods=[part-of,inference-service,role,dev-environment],statefulsets=[dev-environment]"
echo "  发现范围:     serviceMonitorSelector/ruleSelector/scrapeConfigSelector = {{}}(全选, 且已关 NilUsesHelmValues)"
if [ "${MX_EXPORTER_ENABLED}" = "true" ]; then
    echo "  mx-exporter:  已尝试开启(ns ${METAX_NAMESPACE} 无 ClusterOperator 时自动跳过)"
fi
if [ "${#_PROM_ACCESS[@]}" -gt 0 ]; then
    echo "  访问地址(浏览器打开即可):"
    for _l in "${_PROM_ACCESS[@]}"; do printf '    %-12s %s\n' "${_l%%|*}" "${_l#*|}"; done
    if [ "${_PROM_SHARE_VIP}" = "1" ]; then
        echo "    (Grafana 与 registry 共用 VIP ${REGISTRY_IP}, 以端口区分: registry ${REGISTRY_PORT:-5000} / Grafana 3000)"
    fi
elif [ "${PROMETHEUS_EXPOSE_MODE}" = "clusterip" ]; then
    echo "  Grafana:      kubectl -n ${PROMETHEUS_NAMESPACE} port-forward svc/${PROMETHEUS_RELEASE_NAME}-grafana 3000"
    echo "                (要对外暴露: cluster.conf 设 SERVICE_EXPOSE_MODE=metallb 或 nodeport 后重跑)"
fi
echo "  端到端验证:   sudo ./deploy-cluster.sh --steps verify_prometheus"
echo "  卸载:         helm uninstall ${PROMETHEUS_RELEASE_NAME} -n ${PROMETHEUS_NAMESPACE}"
echo "                (dashboard 的 ConfigMap 不会随 helm 卸载; 需手工 kubectl -n ${PROMETHEUS_NAMESPACE} delete cm -l app.kubernetes.io/part-of=cubestack-observability)"
unset _OBS_RULES _OBS_DASHS _OBS_RULES_DIR _OBS_DASH_DIR _OBS_DIR _OBS_SRC
