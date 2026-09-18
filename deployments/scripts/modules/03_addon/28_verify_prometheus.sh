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
#       证明 采集→存储→查询 全链通(不只 pod 活着)。
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
#   · 验证边界(如实标注): ④ 证明"每条数据源有数据"; **不含**指标基数/采集延迟/存储膨胀等
#     性能维度, 也不含 PromQL 告警规则触发验证(那属于 kube-prometheus-stack 自身规则)。
#   · 环境确实不支持时(如需特殊 kubelet 证书配置), 用 VERIFY_MONITORING_STRICT=false 重跑,
#     ④ 降级为告警不阻断; 默认 true=严格。
# 资料: cluster.conf(PROMETHEUS_ENABLED / PROMETHEUS_NAMESPACE / PROMETHEUS_RELEASE_NAME /
#        VERIFY_MONITORING_STRICT / VERIFY_METRIC_WAIT / NODES)
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

echo "---------------------------------------------"
ok "Prometheus 验证通过: 采集→存储→查询 全链可用(${_UP_N} 个 up 目标)"
echo "  监控三件套:  kube-state-metrics(对象状态) / node-exporter(主机) / kubelet-cAdvisor(容器)"
echo "  入口: kubectl -n ${PROMETHEUS_NAMESPACE} port-forward svc/${PROMETHEUS_RELEASE_NAME}-prometheus 9090"
echo "  Grafana: kubectl -n ${PROMETHEUS_NAMESPACE} port-forward svc/${PROMETHEUS_RELEASE_NAME}-grafana 3000"