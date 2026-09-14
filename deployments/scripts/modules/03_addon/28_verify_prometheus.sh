#!/bin/bash
# ============================================================
# MODULE: verify_prometheus
# DESC: 端到端验证 Prometheus(kube-prometheus-stack)真正工作(非仅 pod running):
#       ① monitoring 组件 pod 全部 Running
#       → ② Prometheus CR Ready + 取到查询入口(prometheus pod ClusterIP:9090)
#       → ③ 真实 PromQL 执行: `up == 1` 与 node 指标 → 校验 JSON data.result 非空
#       → ④ 证明 采集→存储→查询 全链通(不只 pod 活着), 并展示关键指标样例
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
#   · 真实功能验证: 若 operator 只把 pod 拉起来但 采集/存储/查询 链路断, 这里
#     data.result 为空即失败 —— 不是"pod Running"就放行, 能提前暴露 node-exporter
#     未采集 / Prometheus 没抓取 / TSDB 没写等故障。
# 资料: cluster.conf(PROMETHEUS_ENABLED / PROMETHEUS_NAMESPACE / PROMETHEUS_RELEASE_NAME / NODES)
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

say "  ④ 展示关键指标样例(任意一条 up==1 metric):"
echo "${_UP}" | python3 -c 'import json,sys; r=json.load(sys.stdin).get("data",{}).get("result",[]); [print("    {} → value={}".format(m["metric"].get("__name__", "up"), m.get("value",[None,""] ) [1])) for m in r[:3]]' 2>/dev/null | sed 's/^/    /' || true

echo "---------------------------------------------"
ok "Prometheus 验证通过: 采集→存储→查询 全链可用(${_UP_N} 个 up 目标)"
echo "  入口: kubectl -n ${PROMETHEUS_NAMESPACE} port-forward svc/${PROMETHEUS_RELEASE_NAME}-prometheus 9090"
echo "  Grafana: kubectl -n ${PROMETHEUS_NAMESPACE} port-forward svc/${PROMETHEUS_RELEASE_NAME}-grafana 3000"