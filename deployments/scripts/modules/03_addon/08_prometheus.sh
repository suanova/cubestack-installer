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
PROMETHEUS_IMAGE_NODE_EXPORTER="${PROMETHEUS_IMAGE_NODE_EXPORTER:-1.12.1}"
PROMETHEUS_IMAGE_KSM="${PROMETHEUS_IMAGE_KSM:-2.20.0}"
PROMETHEUS_IMAGE_GRAFANA="${PROMETHEUS_IMAGE_GRAFANA:-13.2.1-distroless}"
PROMETHEUS_IMAGE_SIDECAR="${PROMETHEUS_IMAGE_SIDECAR:-2.11.2}"
PROMETHEUS_IMAGE_CERTGEN="${PROMETHEUS_IMAGE_CERTGEN:-1.8.8}"
CHART_DIR="${REPO_ROOT}/deployments/cubestack-addon/observability/prometheus/kube-prometheus-stack"
SAVE_DIR="${PROMETHEUS_SAVE_DIR:-${OFFLINE_FILES_DIR:-${REPO_ROOT}/deployments/offline-files}/prometheus}"
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
# 镜像表: 原仓库路径(去注册域, 与 chart 默认 repository 一致)→ 版本变量
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
for _repo in "${!IMG_REPO[@]}"; do
    _tar="${SAVE_DIR}/$(echo "${_repo}" | sed 's#/#_#g')_${IMG_REPO[${_repo}]}.tar"
    [ -f "${_tar}" ] || _MISSING="${_MISSING} ${_repo}:${IMG_REPO[${_repo}]}"
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
    _tar="${SAVE_DIR}/$(echo "${_repo}" | sed 's#/#_#g')_${_tag}.tar"
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

echo "---------------------------------------------"
ok "Prometheus 监控底座部署完成(kube-prometheus-stack)"
echo "  namespace:    ${PROMETHEUS_NAMESPACE}"
echo "  retention:    ${PROMETHEUS_RETENTION_DAYS}   Prometheus PVC: ${PROMETHEUS_STORAGE_SIZE}(默认 StorageClass)"
echo "  查询:         kubectl -n ${PROMETHEUS_NAMESPACE} get pods,svc"
echo "  Prometheus:   kubectl -n ${PROMETHEUS_NAMESPACE} port-forward svc/${PROMETHEUS_RELEASE_NAME}-prometheus 9090"
echo "  Grafana:      kubectl -n ${PROMETHEUS_NAMESPACE} port-forward svc/${PROMETHEUS_RELEASE_NAME}-grafana 3000"
echo "  卸载:         helm uninstall ${PROMETHEUS_RELEASE_NAME} -n ${PROMETHEUS_NAMESPACE}"
