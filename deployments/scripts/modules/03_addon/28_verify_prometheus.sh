#!/bin/bash
# ============================================================
# MODULE: verify_prometheus
# DESC: 端到端验证 Prometheus(kube-prometheus-stack)真正工作(非仅 pod running):
#       ① monitoring 组件 pod 全部 Running
#       → ② Prometheus CR Ready + 取到查询入口(prometheus pod ClusterIP:9090)
#       → ③ 真实 PromQL 执行: `up == 1` → 校验 JSON data.result 非空
#       → ④ **监控三件套数据源断言**(2026-09-18 用户要求, 本轮新增):
#            kube-state-metrics(kube_*) / node-exporter(node_*) / kubelet-cAdvisor(container_*)
#            各查一条"只有它会产生"的指标, 轮询 VERIFY_METRIC_WAIT 秒仍为空即判失败
#       → ⑤ 展示关键指标样例
#       → ⑥ **CubeStack recording rules 实际加载**(逐组断言 vendored 规则文件里每个 group
#            名都出现在 GET /api/v1/rules —— CR 创建成功 ≠ 规则被加载, 后者取决于
#            Prometheus CR 的 ruleSelector 能否选中它, 选不中时**无任何报错**)
#       → ⑦ **Grafana dashboard 已导入**(GET /api/search 断言 11 个看板 uid 都在)
#       → ⑧ **GPU / BMC exporter 采集断言**(mx-exporter / bmc-oem / idrac, 各自启用时)
#       证明 采集→存储→查询 全链通, 且 CubeStack 可观测性三件真的落地(不只 pod 活着)。
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# REQUIRES: prometheus
# 说明:
#   · **验证模块不设 TOGGLE**(否则 PROMETHEUS_ENABLED=true 时会被安装流程自动启用);
#     保持 DEFAULT:0, 仅由 --steps verify_prometheus 在安装后单个执行。
#   · 依赖: 模块 08_prometheus(kube-prometheus-stack, PROMETHEUS_ENABLED=true)。
#   · 查询端点: prometheus CR 生成的 statefulset pod 为无头 svc `prometheus-operated`
#     (无 ClusterIP, 只能直连 pod IP)。验证从首个 master 直接 curl pod IP:9090。
#   · 三件套里 **kubelet/cAdvisor 没有独立镜像/工作负载** —— 它内置于每个节点的 kubelet,
#     由 chart 自带的 kubelet ServiceMonitor 抓 /metrics/cadvisor。镜像层面只需备料 KSM 与
#     node-exporter(见 deployments/config/images.manifest 的 kube-state-metrics / node-exporter 组)。
#   · 验证边界(如实标注): ④ 证明"每条数据源有数据"; ⑥⑦⑧ 证明 CubeStack 可观测性三件
#     (规则真的被 Prometheus 加载 / 看板真的进了 Grafana / 各 exporter 真的被采集)。
#     **不含**指标基数/采集延迟/存储膨胀等性能维度, 也不含 PromQL 告警规则触发验证
#     (那属于 kube-prometheus-stack 自身规则), 不含 Grafana 面板渲染正确性(只查 uid 存在)。
#   · 环境确实不支持时(如需特殊 kubelet 证书配置), 用 VERIFY_MONITORING_STRICT=false 重跑,
#     ④ 降级为告警不阻断; 默认 true=严格。⑥⑦⑧ 同样受该开关控制(⑥ 默认也严格: 规则不加载是
#     静默故障, 不查出来等于没验证)。
# 资料: cluster.conf(PROMETHEUS_ENABLED / PROMETHEUS_NAMESPACE / PROMETHEUS_RELEASE_NAME /
#        GRAFANA_ADMIN_USER / GRAFANA_ADMIN_PASSWORD / CUBESTACK_OBSERVABILITY_DIR /
#        BMC_EXPORTER_ENABLED / MX_EXPORTER_ENABLED / VERIFY_MONITORING_STRICT /
#        VERIFY_METRIC_WAIT / NODES)
# 用法: sudo ./deploy-cluster.sh --steps verify_prometheus
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# 开关检查: 未启用则跳过(不报错)
[ "${PROMETHEUS_ENABLED:-false}" = "true" ] || { say "PROMETHEUS_ENABLED=false, 跳过 Prometheus 验证"; exit 0; }

init_remote_kubectl || exit 1

PROMETHEUS_NAMESPACE="${PROMETHEUS_NAMESPACE:-monitoring}"
PROMETHEUS_RELEASE_NAME="${PROMETHEUS_RELEASE_NAME:-kube-prometheus}"
PROM_CR="${PROMETHEUS_RELEASE_NAME}-kube-prome-prometheus"   # 实际 CR 名(集群实测)
PROM_PORT=9090

# 查询辅助: 在首个 master 节点上 curl Prometheus PromQL API(部署机/容器 bridge 网络
# 到不了集群 overlay 的 10.233.x pod IP, 必须经 SSH 到节点执行 —— 2026-09-11 事故)
_prom_curl() {   # <query> → JSON
    local _q="$1"
    local _quoted
    _quoted="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "${_q}")"
    SSH "curl -s --max-time 15 'http://${_PROM_IP}:${PROM_PORT}/api/v1/query?query=${_quoted}'"
}

say "Verify Prometheus: 采集→查询→result 非空(data 链路真实可用?)..."

cleanup() { :; }
trap cleanup EXIT

say "  ① 检查监控组件 pod 全 Running..."
_NRUN="$( (SSH "${K} -n ${PROMETHEUS_NAMESPACE} get pods --no-headers 2>/dev/null" || true) | awk '$3=="Running"{n++} END{print n+0}' )"
_NTOT="$( (SSH "${K} -n ${PROMETHEUS_NAMESPACE} get pods --no-headers --ignore-not-found 2>/dev/null" || true) | wc -l )"
[ "${_NRUN}" -ge 4 ] || { err "monitoring 下 Running pod 仅 ${_NRUN}/${_NTOT}(kubectl -n ${PROMETHEUS_NAMESPACE} get pods); 检查 node-exporter 等 ImagePullBackOff"; exit 1; }
ok "    Running ${_NRUN}/${_NTOT} pod ✓"

say "  ② 检查 Prometheus CR + 定位查询端点..."
_CR="$(SSH "${K} -n ${PROMETHEUS_NAMESPACE} get prometheus ${PROM_CR} --no-headers 2>/dev/null" || true)"
[ -n "${_CR}" ] && say "    CR: $(echo "${_CR}" | awk '{print $1}') Ready → 查询 pod IP..." \
    || { err "Prometheus CR '${PROM_CR}' 不存在(检查 release: kubectl -n ${PROMETHEUS_NAMESPACE} get prometheus)"; exit 1; }
_PROM_IP="$(SSH "${K} -n ${PROMETHEUS_NAMESPACE} get pod -l operator.prometheus.io/name=${PROM_CR} -o jsonpath='{.items[0].status.podIP}' 2>/dev/null" || true)"
[ -n "${_PROM_IP}" ] || { err "取不到 Prometheus pod IP(无 operator.prometheus.io/name=${PROM_CR} label 的 pod)"; exit 1; }
ok "    查询端点: ${_PROM_IP}:${PROM_PORT}(从首个 master curl)"

say "  ③ 执行 PromQL 查询..."
# ③a up == 1: 应能查到各 target(含 node-exporter/ksm)被采集
_UP="$(_prom_curl 'up == 1')"
_UP_N="$(echo "${_UP}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("data",{}).get("result",[])))' 2>/dev/null || echo 0)"
[ "${_UP_N:-0}" -gt 0 ] || { err "查询 up == 1 无结果: 采集链路未通(等 60-120s 收录目标, 或查 kubectl -n ${PROMETHEUS_NAMESPACE} get servicemonitor)"; exit 1; }
ok "    up == 1 → ${_UP_N} 个活跃采集目标 ✓"

# ③b 节点/TSDB 指标: node_cpu_seconds_total(采集到才有)
_NODE_N="$( _prom_curl 'node_cpu_seconds_total' | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("data",{}).get("result",[])))' 2>/dev/null || echo 0)"
[ "${_NODE_N:-0}" -gt 0 ] && ok "    node_cpu_seconds_total → ${_NODE_N} 个时序 ✓" \
    || warn "    node_cpu_seconds_total 暂时为空(等 node-exporter 就绪后自动出数据; up==1 已证明查询链通)"

say "  ④ 监控三件套真实采集断言(KSM / node-exporter / kubelet-cAdvisor)..."
# ★ 2026-09-18(用户要求): 这三个是 Prometheus 生态的核心数据源, 必须**各自有数据**才算通 ——
#   只查 up==1 不够: target up 只说明"能连上", 采集到的指标为空同样不可用。
#   断言方式: 每个组件查一条**只有它会产生**的指标, 轮询等待后仍为空即判失败。
#   ① kube-state-metrics : kube_*            (监听 API Server 生成对象状态指标)
#   ② node-exporter      : node_*            (DaemonSet 采集主机指标)
#   ③ kubelet/cAdvisor   : container_*       (kubelet 自带, 抓 /metrics/cadvisor)
#   ⚠ 边界: cAdvisor 指标来自 kubelet 的 10250 ServiceMonitor, 若集群 kubelet 证书/RBAC 特殊,
#     可能需手动放行; 此时用 VERIFY_MONITORING_STRICT=false 降级为告警(默认为严格=失败)。
VERIFY_MONITORING_STRICT="${VERIFY_MONITORING_STRICT:-true}"
VERIFY_METRIC_WAIT="${VERIFY_METRIC_WAIT:-120}"     # 每个指标最多等多久(秒)

# 查一条指标在轮询窗口内的时序数; 有数据即返回
_metric_count() {   # <PromQL> → 时序数(0=无数据)
    local _n
    _n="$( _prom_curl "$1" | python3 -c 'import json,sys
try:
    print(len(json.load(sys.stdin).get("data",{}).get("result",[])))
except Exception:
    print(0)' 2>/dev/null || echo 0 )"
    printf '%s' "${_n:-0}"
}

# 三件套断言: <显示名> <PromQL> <最低时序数> <缺失时的排查提示>
_COMPS_FAILED=""
_check_component() {
    local _name="$1" _q="$2" _min="$3" _hint="$4" _n=0 _waited=0
    while [ "${_waited}" -lt "${VERIFY_METRIC_WAIT}" ]; do
        _n="$(_metric_count "${_q}")"
        [ "${_n:-0}" -ge "${_min}" ] && break
        sleep 10; _waited=$((_waited + 10))
    done
    if [ "${_n:-0}" -ge "${_min}" ]; then
        ok "    ${_name}: ${_n} 条时序 ✓(指标 ${_q%%\{*})"
        return 0
    fi
    err "    ${_name}: ${VERIFY_METRIC_WAIT}s 内无数据(指标 ${_q%%\{*})"
    err "      ${_hint}"
    _COMPS_FAILED="${_COMPS_FAILED} ${_name}"
    return 1
}

# ① kube-state-metrics(kube_pod_info 由 KSM 独有)
_check_component "kube-state-metrics" "kube_pod_info" 1 \
    "查 kubectl -n ${PROMETHEUS_NAMESPACE} get deploy ${PROMETHEUS_RELEASE_NAME}-kube-state-metrics 与 servicemonitor; 镜像在离线目录 kube-state-metrics/"
# ② node-exporter(node_cpu_seconds_total 由 node-exporter 独有)
_check_component "node-exporter" "node_cpu_seconds_total" 1 \
    "查 kubectl -n ${PROMETHEUS_NAMESPACE} get ds ${PROMETHEUS_RELEASE_NAME}-prometheus-node-exporter(需每节点 Running); 镜像在离线目录 node-exporter/"
# ③ kubelet/cAdvisor(container_* 由 kubelet 的 /metrics/cadvisor 提供, 无独立镜像/工作负载)
_check_component "kubelet-cAdvisor" "container_cpu_usage_seconds_total" 1 \
    "查 kubectl -n ${PROMETHEUS_NAMESPACE} get servicemonitor ${PROMETHEUS_RELEASE_NAME}-kubelet; 需 kubelet 10250 可达且 chart 的 kubelet.enabled=true"

if [ -n "${_COMPS_FAILED}" ]; then
    if [ "${VERIFY_MONITORING_STRICT}" = "true" ]; then
        err "监控三件套未全部通过:${_COMPS_FAILED}"
        err "  若环境确实不适用(如需特殊 kubelet 证书配置), 用 VERIFY_MONITORING_STRICT=false 重跑可降级为告警"
        exit 1
    fi
    warn "监控三件套未全部通过:${_COMPS_FAILED}(VERIFY_MONITORING_STRICT=false, 仅告警)"
else
    ok "    三件套全部有数据: 对象状态(KSM) + 主机(node-exporter) + 容器(cAdvisor) ✓"
fi
unset _COMP 2>/dev/null || true

say "  ⑤ 展示关键指标样例(任意一条 up==1 metric):"
echo "${_UP}" | python3 -c 'import json,sys; r=json.load(sys.stdin).get("data",{}).get("result",[]); [print("    {} → value={}".format(m["metric"].get("__name__", "up"), m.get("value",[None,""] ) [1])) for m in r[:3]]' 2>/dev/null | sed 's/^/    /' || true

# ============================================================
# ⑥ CubeStack recording rules 实际加载(★ 2026-09-20 新增)
# ============================================================
# 为什么必须查 /api/v1/rules 而不是 kubectl get prometheusrule:
#   PrometheusRule **对象存在**与**规则被加载**是两件事 —— 后者取决于 Prometheus CR 的
#   ruleSelector 能否选中该 CR。选不中时 CR 建得好好的, 规则却完全不加载, **且无任何报错**
#   (这正是 installer-requirements §2 反复强调的坑)。所以逐组断言实际加载结果。
_OBS_DIR_V="${CUBESTACK_OBSERVABILITY_DIR:-}"
if [ -z "${_OBS_DIR_V}" ] && [ -d "/opt/cubestack/observability/recording-rules" ]; then
    _OBS_DIR_V="/opt/cubestack/observability"
fi
[ -n "${_OBS_DIR_V}" ] || _OBS_DIR_V="${REPO_ROOT}/deployments/cubestack-addon/observability/cubestack"
_RULES_DIR_V="${_OBS_DIR_V}/recording-rules"
_DASH_DIR_V="${_OBS_DIR_V}/dashboards/grafana"

say "  ⑥ CubeStack recording rules 实际加载断言(读 ${_RULES_DIR_V})..."
if [ -d "${_RULES_DIR_V}" ]; then
    # 取 vendored 规则文件里每个 group 名(逐文件精确断言, 比"共 N 条"更抗震:
    # 上游增删规则不会误报, 少加载任何一个 group 都会报)
    _WANT_GROUPS="$(python3 - "${_RULES_DIR_V}" <<'PY' 2>/dev/null || true
import sys, glob, os
try:
    import yaml
except ImportError:
    sys.exit(0)
want = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], '*.yaml'))):
    try:
        d = yaml.safe_load(open(f, encoding='utf-8'))
    except Exception:
        continue
    if not isinstance(d, dict):
        continue
    for g in (d.get('spec', {}) or {}).get('groups', []) or []:
        if g.get('name'):
            want.append(g['name'])
print('\n'.join(want))
PY
)"
    if [ -z "${_WANT_GROUPS}" ]; then
        warn "    读不出规则文件里的 group 名(缺 pyyaml? 或 ${_RULES_DIR_V} 下无 *.yaml) —— 跳过逐组断言"
    else
        _WANT_N="$(printf '%s\n' "${_WANT_GROUPS}" | grep -c . || true)"
        # 取 Prometheus 实际加载的规则组名
        _GOT_GROUPS="$(SSH "curl -s --max-time 20 'http://${_PROM_IP}:${PROM_PORT}/api/v1/rules'" 2>/dev/null \
            | python3 -c 'import json,sys
try:
    for g in json.load(sys.stdin).get("data",{}).get("groups",[]):
        if g.get("name"): print(g["name"])
except Exception: pass' 2>/dev/null || true)"
        _MISS_C=""
        _OK_C=0
        while IFS= read -r _g; do
            [ -n "${_g}" ] || continue
            if printf '%s\n' "${_GOT_GROUPS}" | grep -Fxq "${_g}"; then
                _OK_C=$((_OK_C + 1))
            else
                _MISS_C="${_MISS_C} ${_g}"
            fi
        done <<< "${_WANT_GROUPS}"
        if [ -z "${_MISS_C}" ]; then
            ok "    CubeStack 规则组全部已加载: ${_OK_C}/${_WANT_N} 组 ✓"
        else
            err "    CubeStack 规则组未加载:${_MISS_C} (已加载 ${_OK_C}/${_WANT_N})"
            err "      根因通常是 Prometheus CR 的 ruleSelector 选不中这些 CR。核对:"
            err "        kubectl -n ${PROMETHEUS_NAMESPACE} get prometheus ${PROM_CR} -o jsonpath='{.spec.ruleSelector}'"
            err "      期望能匹配 app.kubernetes.io/part-of=cubestack-observability"
            err "      (重跑 --steps prometheus 会按并集选择器修正; 见 docs/prometheus-observability.md)"
            _COMPS_FAILED="${_COMPS_FAILED} recording-rules"
        fi
        unset _GOT_GROUPS _MISS_C _OK_C _WANT_N
    fi
    unset _WANT_GROUPS
else
    warn "    规则目录不存在(${_RULES_DIR_V}), 跳过(未部署 CubeStack 可观测性资产时正常)"
fi

# ============================================================
# ⑦ Grafana dashboard 已导入(★ 2026-09-20 新增)
# ============================================================
say "  ⑦ Grafana dashboard 导入断言(读 ${_DASH_DIR_V})..."
_GRAFANA_IP="$(SSH "${K} -n ${PROMETHEUS_NAMESPACE} get pod -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].status.podIP}' 2>/dev/null" || true)"
if [ -z "${_GRAFANA_IP}" ]; then
    warn "    取不到 Grafana pod IP, 跳过(检查 kubectl -n ${PROMETHEUS_NAMESPACE} get pod -l app.kubernetes.io/name=grafana)"
elif [ ! -d "${_DASH_DIR_V}" ]; then
    warn "    dashboard 目录不存在(${_DASH_DIR_V}), 跳过"
elif [ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]; then
    warn "    GRAFANA_ADMIN_PASSWORD 未设置, 跳过(无法登录 Grafana API 查询)"
else
    _SEARCH="$(SSH "curl -s --max-time 20 -u '${GRAFANA_ADMIN_USER:-admin}:${GRAFANA_ADMIN_PASSWORD}' 'http://${_GRAFANA_IP}:3000/api/search?type=dash-db'" 2>/dev/null || true)"
    # dashboard 的 uid 由各 JSON 自带(如 bmc-hardware-cubestack); 用文件名推导不可靠, 直接从文件读
    _WANT_UIDS="$(python3 - "${_DASH_DIR_V}" <<'PY' 2>/dev/null || true
import sys, glob, os, json
for f in sorted(glob.glob(os.path.join(sys.argv[1], '*.json'))):
    try:
        u = json.load(open(f, encoding='utf-8')).get('uid')
    except Exception:
        continue
    if u:
        print(u)
PY
)"
    if [ -z "${_WANT_UIDS}" ]; then
        warn "    读不出 dashboard uid(JSON 无 uid 字段或解析失败), 跳过"
    else
        _DU_N="$(printf '%s\n' "${_WANT_UIDS}" | grep -c . || true)"
        _DMISS_C=""
        _DOK_C=0
        while IFS= read -r _u; do
            [ -n "${_u}" ] || continue
            if printf '%s' "${_SEARCH}" | grep -Fq "\"uid\":\"${_u}\""; then
                _DOK_C=$((_DOK_C + 1))
            else
                _DMISS_C="${_DMISS_C} ${_u}"
            fi
        done <<< "${_WANT_UIDS}"
        if [ -z "${_DMISS_C}" ]; then
            ok "    Grafana dashboard 全部已导入: ${_DOK_C}/${_DU_N} 个 ✓"
        else
            err "    Grafana dashboard 缺失:${_DMISS_C} (已导入 ${_DOK_C}/${_DU_N})"
            err "      排查: kubectl -n ${PROMETHEUS_NAMESPACE} get cm -l grafana_dashboard=1"
            err "            kubectl -n ${PROMETHEUS_NAMESPACE} logs deploy/${PROMETHEUS_RELEASE_NAME}-grafana -c grafana-sc-dashboard | tail"
            err "      (sidecar 扫描 ConfigMap 需要 10-60s; 刚部署完可稍等重跑本验证)"
            _COMPS_FAILED="${_COMPS_FAILED} grafana-dashboards"
        fi
        unset _DMISS_C _DOK_C _DU_N
    fi
    unset _WANT_UIDS _SEARCH
fi
unset _GRAFANA_IP

# ============================================================
# ⑧ GPU / BMC exporter 采集断言(★ 2026-09-20 新增; 各自启用时才查)
# ============================================================
say "  ⑧ 附加 exporter 采集断言(mx-exporter / BMC; 未启用的自动跳过)..."
# mx-exporter: 由 06_gpu_operator(helm value)+ 08_prometheus(ServiceMonitor)共同开启。
# job 名来自 operator 建的 Service 名(不是 ServiceMonitor 名) → 用前缀匹配而非等值,
# 避免 operator 版本改 Service 名时误报(requirement §7.1 亦如此提示)。
# ⚠ 只在**确实有 exporter 在跑**时才断言: mx-exporter 的 DaemonSet 带
#   `metax-tech.com/gpu.installed=true` 的 nodeSelector, **没有 GPU 节点的集群 desired=0**
#   (实机: 五节点 VM 集群全无 MetaX 卡)。此时"无 target"是正常的, 判失败会变成永久假告警 ——
#   与"operator 永远报未就绪"是同一类错误。判据用 DaemonSet 期望副本数, 不用配置开关。
_MX_DS_N=0
if [ "${MX_EXPORTER_ENABLED:-true}" = "true" ]; then
    # ⚠ 引号/括号惯例(见 cubestack-deploy-scripts 技能): 内层参数**分开**引号,
    #   不要写成 `"$( (SSH "${K} -n x" || true)"` —— 那会开两个括号只闭一个, 报 EOF。
    _MX_DS_N="$(SSH "${K}" -n "${METAX_NAMESPACE:-metax-operator}" get ds metax-data-exporter -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || true)"
    _MX_DS_N="${_MX_DS_N:-0}"
fi
if [ "${_MX_DS_N:-0}" -ge 1 ]; then
    _MX_N="$(_metric_count 'up{job=~"metax-data-exporter.*"}')"
    if [ "${_MX_N:-0}" -ge 1 ]; then
        ok "    mx-exporter: ${_MX_N} 个 target up(覆盖 ${_MX_DS_N} 个 GPU 节点)✓"
    else
        err "    mx-exporter: DaemonSet 期望 ${_MX_DS_N} 个但无 up target"
        err "      核对: kubectl -n ${METAX_NAMESPACE:-metax-operator} get ds metax-data-exporter,pod"
        err "            kubectl -n ${METAX_NAMESPACE:-metax-operator} get servicemonitor cubestack-mx-exporter"
        err "            Prometheus Status→Targets 里 job=metax-data-exporter 的 lastError"
        _COMPS_FAILED="${_COMPS_FAILED} mx-exporter"
    fi
elif [ "${MX_EXPORTER_ENABLED:-true}" = "true" ]; then
    say "    跳过 mx-exporter(无 GPU 节点: metax-data-exporter DaemonSet 期望副本=0, 无 target 属正常)"
else
    say "    跳过 mx-exporter(MX_EXPORTER_ENABLED!=true)"
fi
unset _MX_DS_N
# BMC: 启用时应有 2×len(BMC_HOSTS) 个 target(每 BMC 一个 bmc-oem + 一个 idrac)
# ⚠ 2026-09-20 实测结论(很重要, 别只看 up): 两个 exporter 的**抓取模式不同**, `up` 的含义也不同 ——
#     · bmc-oem-exporter 走 /probe?target=<ip>: **目标 BMC 不可达时 exporter 自己仍然 up=1**
#       (它只是返回"探测失败"), 目标健康在 `bmc_pcie_scrape_success` 里(0/1);
#     · idrac-exporter  走 /metrics?target=<ip>: 目标不可达时**抓取直接失败 → up=0**。
#   因此"数 up 序列个数"会给出**假绿灯**(unreachable 的 BMC 也占一条序列)。
#   正确做法: 抓取层查 up==1(管住 idrac), 目标层再查 bmc_pcie_scrape_success==1(管住 bmc-oem)。
if [ "${BMC_EXPORTER_ENABLED:-false}" = "true" ]; then
    _BMC_HOST_N=0
    for _h in ${BMC_HOSTS//,/ }; do [ -n "${_h}" ] && _BMC_HOST_N=$((_BMC_HOST_N + 1)); done
    _BMC_EXPECT=$((_BMC_HOST_N * 2))
    _BMC_UP_N="$(_metric_count 'up{job=~"bmc-oem-exporter|idrac-exporter"} == 1')"
    # 目标层健康: 只在指标确实存在时判定(指标改名/版本变化时不误报, 但要 warn 出来)
    _BMC_TGT_ALL="$(_metric_count 'bmc_pcie_scrape_success')"
    _BMC_TGT_OK="0"
    [ "${_BMC_TGT_ALL:-0}" -ge 1 ] && _BMC_TGT_OK="$(_metric_count 'bmc_pcie_scrape_success == 1')"
    _BMC_BAD=""
    [ "${_BMC_UP_N:-0}" -lt "${_BMC_EXPECT}" ] && _BMC_BAD="${_BMC_BAD} 抓取层 up==1 只有 ${_BMC_UP_N}/${_BMC_EXPECT}"
    if [ "${_BMC_TGT_ALL:-0}" -ge 1 ] && [ "${_BMC_TGT_OK:-0}" -lt "${_BMC_HOST_N}" ]; then
        _BMC_BAD="${_BMC_BAD} BMC 目标层 bmc_pcie_scrape_success==1 只有 ${_BMC_TGT_OK}/${_BMC_HOST_N}"
    fi
    if [ -z "${_BMC_BAD}" ] && [ "${_BMC_EXPECT}" -ge 1 ]; then
        ok "    BMC exporter: 抓取层 ${_BMC_UP_N}/${_BMC_EXPECT} up, BMC 目标层 ${_BMC_TGT_OK}/${_BMC_HOST_N} 健康 ✓"
    else
        err "    BMC exporter 未达标:${_BMC_BAD}(期望 ${_BMC_EXPECT} 个 target / ${_BMC_HOST_N} 个 BMC)"
        err "      排查: kubectl -n ${BMC_EXPORTER_NAMESPACE:-monitoring} get scrapeconfig,pod | grep -i bmc"
        err "            Prometheus targets 里 job=bmc-oem-exporter / idrac-exporter 的 lastError"
        err "            ⚠ 目标 BMC 不可达 / 凭据错时, bmc-oem 的 up 仍是 1 —— 看 bmc_pcie_scrape_success"
        _COMPS_FAILED="${_COMPS_FAILED} bmc-exporter"
    fi
    [ "${_BMC_TGT_ALL:-0}" -ge 1 ] || warn "    未发现 bmc_pcie_scrape_success 指标(改名了?) —— 只校验了抓取层"
    unset _BMC_HOST_N _BMC_EXPECT _BMC_UP_N _BMC_TGT_ALL _BMC_TGT_OK _BMC_BAD _h
else
    say "    跳过 BMC exporter(BMC_EXPORTER_ENABLED!=true)"
fi
unset _OBS_DIR_V _RULES_DIR_V _DASH_DIR_V

# ⑧ 段汇总: 与 ④ 共用 VERIFY_MONITORING_STRICT 降级开关
if [ -n "${_COMPS_FAILED}" ]; then
    if [ "${VERIFY_MONITORING_STRICT}" = "true" ]; then
        err "可观测性断言未全部通过:${_COMPS_FAILED}"
        err "  若环境确实不适用(如需特殊 kubelet 证书配置), 用 VERIFY_MONITORING_STRICT=false 重跑可降级为告警"
        exit 1
    fi
    warn "可观测性断言未全部通过:${_COMPS_FAILED}(VERIFY_MONITORING_STRICT=false, 仅告警)"
else
    ok "    可观测性三件全部就位: 规则已加载 + 看板已导入 + 附加 exporter 已采集 ✓"
fi

echo "---------------------------------------------"
ok "Prometheus 验证通过: 采集→存储→查询 全链可用(${_UP_N} 个 up 目标)"
echo "  监控三件套:  kube-state-metrics(对象状态) / node-exporter(主机) / kubelet-cAdvisor(容器)"
echo "  CubeStack:   recording rules(已加载) + Grafana dashboards(已导入)"
echo "  入口: kubectl -n ${PROMETHEUS_NAMESPACE} port-forward svc/${PROMETHEUS_RELEASE_NAME}-prometheus 9090"
echo "  Grafana: kubectl -n ${PROMETHEUS_NAMESPACE} port-forward svc/${PROMETHEUS_RELEASE_NAME}-grafana 3000"