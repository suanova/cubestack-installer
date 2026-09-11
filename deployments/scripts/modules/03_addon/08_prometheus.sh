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
#   · 参考: deployments/cubestack-addon/observability/prometheus/README.md
# 数据源: cluster.conf (PROMETHEUS_ENABLED / PROMETHEUS_NAMESPACE / PROMETHEUS_RETENTION_DAYS /
#         PROMETHEUS_STORAGE_SIZE / PROMETHEUS_APP_VERSION / PROMETHEUS_IMAGE_* / REGISTRY_BASE / NODES)
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
CHART_DIR="${REPO_ROOT}/deployments/cubestack-addon/observability/prometheus/kube-prometheus-stack"
# ★ 2026-09-11: prometheus 镜像目录默认 `offline-files/prometheus`(save 脚本默认, 与 envoy/lws 同构)。
#   早期错误套过 ${OFFLINE_FILES_DIR}(→.../kubespray)致找不到; 已修回独立目录。
SAVE_DIR="${PROMETHEUS_SAVE_DIR:-${REPO_ROOT}/deployments/offline-files/prometheus}"
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

# ── 1. 校验离线资源(chart + 镜像 tar) ──
say "[1/4] 校验离线资源(chart + 镜像 tar)..."
[ -f "${CHART_DIR}/Chart.yaml" ] || { err "chart 缺失: ${CHART_DIR}(联网机执行 tools/images/prometheus-fetch-charts.sh 下载)"; exit 1; }
[ -d "${SAVE_DIR}" ] || { err "离线镜像目录缺失: ${SAVE_DIR}(联网机执行 tools/images/prometheus-save-images.sh 下载)"; exit 1; }
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
# halves: 用 ls 通配末段匹配(注册域前缀不定),直接对目录校验
echo "  ✓ 离线镜像目录: ${SAVE_DIR}"
for _repo in "${!IMG_REPO[@]}"; do
    _tag="${IMG_REPO[${_repo}]}"
    _pat="$(echo "${_repo}" | sed 's#/#_#g')_${_tag}.tar"
    # 文件名必须整体结束于 <repo>_<tag>.tar(如 registry.k8s.io_kube-state-metrics_kube-state-metrics_v2.20.0.tar)
    if ls "${SAVE_DIR}"/*"${_pat}" >/dev/null 2>&1; then
        :   # 命中
    else
        _MISSING="${_MISSING} ${_repo}:${_tag}"
    fi
done
if [ -n "${_MISSING}" ]; then
    err "离线镜像 tar 缺失:${_MISSING}"
    err "  联网机执行: sudo bash deployments/scripts/tools/images/prometheus-save-images.sh(下载到 ${SAVE_DIR})"
    exit 1
fi
ok "chart + ${#IMG_REPO[@]} 个镜像 tar 就绪(目录: ${SAVE_DIR})"

# ── 2. 推送镜像 → 集群内置 registry ──
say "[2/4] 推送镜像到内置 registry(${REG_DIRECT})..."
for _repo in "${!IMG_REPO[@]}"; do
    _tag="${IMG_REPO[${_repo}]}"
    _pat="$(echo "${_repo}" | sed 's#/#_#g')_${_tag}.tar"
    # 目录里唯一以 _pat 结尾的 tar(注册域前缀不定, 取实际存在的那个)
    _tar="$(ls "${SAVE_DIR}"/*"${_pat}" 2>/dev/null | head -1)"
    [ -n "${_tar}" ] || { err "  tar 缺失: ${_repo}:${_tag}(校验应已拦截)"; exit 1; }
    _push_skopeo "docker-archive:${_tar}" "docker://${REG_DIRECT}/${_repo}:${_tag}" \
        && ok "  ${_repo}:${_tag} 已推送" \
        || { err "  ${_repo}:${_tag} 推送失败(重试 3 次)"; exit 1; }
done

# ── 3. helm 离线安装(镜像注册域重写 + retention + 50Gi 默认 SC) ──
say "[3/4] helm 安装 kube-prometheus-stack(namespace=${PROMETHEUS_NAMESPACE}; retention=${PROMETHEUS_RETENTION_DAYS}; PVC ${PROMETHEUS_STORAGE_SIZE} 默认 SC)..."
sync_kubeconfig || { err "宿主机无法访问集群(admin.conf 同步失败; 检查 ${FIRST_MASTER})"; exit 1; }
helm upgrade --install "${PROMETHEUS_RELEASE_NAME}" "${CHART_DIR}" \
    --namespace "${PROMETHEUS_NAMESPACE}" --create-namespace \
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
    || warn "  helm 安装/等待超时(检查 --set 与 chart; 资源可能已创建, 继续等待组件就绪)..."

# ── 4. 等待组件就绪 + 验证 ──
say "[4/4] 等待监控组件就绪(operator / prometheus / alertmanager / grafana / exporters)..."
SSH "${K} -n ${PROMETHEUS_NAMESPACE} rollout status deploy ${PROMETHEUS_RELEASE_NAME}-operator --timeout=180s" >/dev/null 2>&1 \
    && ok "  prometheus-operator Ready" || warn "  operator 180s 内未 Ready(继续检查其余组件)..."
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
_PROM_IP_JSON=$(SSH "${K}" -n "${PROMETHEUS_NAMESPACE}" get pod -l operator.prometheus.io/name="${_PROM_CR_N}" -o jsonpath '{.items[0].status.podIP}' 2>/dev/null || true)
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

# ── 5. Prometheus/Grafana 对外暴露(nodeport / loadbalancer 两种模式, 与 RGW 同款配置) ──
# PROMETHEUS_EXPOSE_MODE: nodeport(默认, 随 SERVICE_EXPOSE_MODE) / loadbalancer / clusterip
#   nodeport     → prometheus 9090 + grafana 3000 各建 NodePort Service(独立, 防 helm 覆盖)
#   loadbalancer → 改 LoadBalancer(需 MetalLB 已部署); 否则 warn 保持 ClusterIP
#   clusterip    → 保持默认仅集群内
say "配置 Prometheus/Grafana 对外暴露(PROMETHEUS_EXPOSE_MODE=${PROMETHEUS_EXPOSE_MODE:-<随 SERVICE_EXPOSE_MODE>})..."
PROMETHEUS_EXPOSE_MODE="${PROMETHEUS_EXPOSE_MODE:-${SERVICE_EXPOSE_MODE:-clusterip}}"
PROMETHEUS_EXPOSE_MODE="$(echo "${PROMETHEUS_EXPOSE_MODE}" | tr '[:upper:]' '[:lower:]')"
_PROM_APPS=(prometheus grafana)
_PROM_NP_BASE="${PROMETHEUS_NODEPORT_BASE:-31000}"   # prometheus=31000, grafana=31001
for _idx in "${!_PROM_APPS[@]}"; do
    _app="${_PROM_APPS[$_idx]}"
    _svc="${PROMETHEUS_RELEASE_NAME}-${_app}"
    _port="$((_PROM_NP_BASE + _idx))"
    case "${PROMETHEUS_EXPOSE_MODE}" in
        nodeport)
            say "  ${_app}: NodePort ${_port}(独立 Service ${_svc}-external)..."
            SSH "${K} -n ${PROMETHEUS_NAMESPACE} delete svc ${_svc}-external --ignore-not-found >/dev/null 2>&1" || true
            SSH "${K} -n ${PROMETHEUS_NAMESPACE} create service nodeport ${_svc}-external --tcp=${_port}:${_port} >/dev/null 2>&1" || true
            SSH "${K} -n ${PROMETHEUS_NAMESPACE} patch svc ${_svc}-external --type merge \
                -p '{"spec":{"selector":{"app.kubernetes.io/name":"'${_app}'","app.kubernetes.io/instance":"'${PROMETHEUS_RELEASE_NAME}'"}}}' >/dev/null 2>&1" || true
            ;;
        loadbalancer)
            if [ -n "$( (SSH "${K} get ns metallb-system --no-headers 2>/dev/null" || true) )" ]; then
                say "  ${_app}: LoadBalancer(需 MetalLB)..."
                SSH "${K} -n ${PROMETHEUS_NAMESPACE} patch svc ${_svc} --type merge -p '{"spec":{"type":"LoadBalancer"}}' >/dev/null 2>&1" || true
            else
                warn "  MetalLB 未部署; ${_app} 保持 ClusterIP(可先 CEPH/PROMETHEUS_EXPOSE_MODE=nodeport)"
            fi
            ;;
        *) say "  ${_app}: ClusterIP(仅集群内)" ;;
    esac
done
unset _idx _app _svc _port

echo "---------------------------------------------"
ok "Prometheus 监控底座部署完成(kube-prometheus-stack)"
echo "  namespace:    ${PROMETHEUS_NAMESPACE}"
echo "  retention:    ${PROMETHEUS_RETENTION_DAYS}   Prometheus PVC: ${PROMETHEUS_STORAGE_SIZE}(默认 StorageClass)"
echo "  查询:         kubectl -n ${PROMETHEUS_NAMESPACE} get pods,svc"
if [ "${PROMETHEUS_EXPOSE_MODE}" = "nodeport" ]; then
    echo "  访问(NodePort): Prometheus http://<节点IP>:${PROMETHEUS_NODEPORT_BASE:-31000}  Grafana http://<节点IP>:$((PROMETHEUS_NODEPORT_BASE:-31000 + 1))"
elif [ "${PROMETHEUS_EXPOSE_MODE}" = "loadbalancer" ]; then
    echo "  访问(LoadBalancer): 见 kubectl -n monitoring get svc ${PROMETHEUS_RELEASE_NAME}-prometheus / -grafana EXTERNAL-IP"
else
    echo "  Prometheus:   kubectl -n ${PROMETHEUS_NAMESPACE} port-forward svc/${PROMETHEUS_RELEASE_NAME}-prometheus 9090"
    echo "  Grafana:      kubectl -n ${PROMETHEUS_NAMESPACE} port-forward svc/${PROMETHEUS_RELEASE_NAME}-grafana 3000"
fi
echo "  卸载:         helm uninstall ${PROMETHEUS_RELEASE_NAME} -n ${PROMETHEUS_NAMESPACE}"
