#!/bin/bash
# ============================================================
# prometheus-save-images.sh — kube-prometheus-stack 镜像: 离线下载 + 保存 tar
# 用途: 在联网/内网机器上把官方镜像下载并保存为 tar, 供离线环境(集群安装机)使用:
#       部署模块 modules/03_addon/08_prometheus.sh 会自动从 deployments/offline-files/prometheus
#       找到这些 tar 并推送至集群内置 registry(本地源, 不联网)。
#
# ── 需要下载的镜像清单(对齐 chart 90.0.0 默认启用的组件; 版本可用环境变量覆盖)──
#   [operator 三件套]  quay.io/prometheus-operator/{prometheus-operator,prometheus-config-reloader,admission-webhook}:<PROMETHEUS_APP_VERSION>
#   [prometheus]        quay.io/prometheus/prometheus:<PROMETHEUS_IMAGE_PROMETHEUS>
#   [alertmanager]      quay.io/prometheus/alertmanager:<PROMETHEUS_IMAGE_ALERTMANAGER>
#   [node-exporter]     quay.io/prometheus/node-exporter:<PROMETHEUS_IMAGE_NODE_EXPORTER>
#   [kube-state-metrics] registry.k8s.io/kube-state-metrics/kube-state-metrics:<PROMETHEUS_IMAGE_KSM>
#   [grafana]           docker.io/grafana/grafana:<PROMETHEUS_IMAGE_GRAFANA>
#   [grafana sidecar]   quay.io/kiwigrid/k8s-sidecar:<PROMETHEUS_IMAGE_SIDECAR>
#   [webhook certgen]   docker.io/jkroepke/kube-webhook-certgen:<PROMETHEUS_IMAGE_CERTGEN>
#   (thanosRuler / kubeRBACProxy / windows-exporter / CRD 升级 Job 默认关闭, 不备料)
#
# 下载方式(按顺序尝试, 与 envoy-save-images.sh 一致):
#   ① 本地 docker daemon 已有 → docker save 直接导出
#   ② docker pull(5 次重试)→ docker save
#   ③ skopeo copy docker:// → docker-archive(--platform linux/amd64, docker 不可用时兜底)
# 文件名: <repo>_<tag>.tar(与 08_prometheus 模块一致, 如 quay.io_prometheus_prometheus_v3.14.0-distroless.tar)
#
# 「保持」语义(幂等): 默认**已有 tar 则跳过**(只补缺/补新版本); 加 --force 强制重新下载覆盖。
#
# 独立运行: 本脚本**不依赖 lib-common.sh / cluster.conf / 其他脚本**, 自带最小日志/路径/skopeo
#   trust policy, 在无任何部署配置的联网准备机上可直接运行; 镜像清单用环境变量 PROMETHEUS_IMAGE_LIST 覆盖。
# 数据源: 环境变量(优先) / 内置默认(与 chart 90.0.0 / cluster.conf.example 声明一致)
#
# 用法:   sudo ./prometheus-save-images.sh                  # 下载并保存全部镜像(已有 tar 跳过, 幂等保持)
#         sudo ./prometheus-save-images.sh --list           # 只列出要下载的镜像清单(不下载)
#         sudo ./prometheus-save-images.sh --force          # 强制重新下载(覆盖已有 tar)
#         sudo ./prometheus-save-images.sh <镜像ref ...>    # 只下载指定镜像
# 注意: sudo 会清空环境变量, 指定版本时**必须把 VAR= 写在 sudo 之后**(否则被丢弃用默认值):
#         sudo PROMETHEUS_APP_VERSION=v0.93.1 ./prometheus-save-images.sh
# ============================================================
set -euo pipefail

# ---- 独立运行: 自带最小日志与路径(不 source lib-common.sh / 不 load_config) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../deployments/scripts/tools/images
REPO_ROOT=""
_d="${SCRIPT_DIR}"
while [ "${_d}" != "/" ] && [ -z "${REPO_ROOT}" ]; do
    if [ -d "${_d}/deployments/scripts" ] && [ -d "${_d}/deployments/cubestack-addon" ]; then
        REPO_ROOT="${_d}"
    fi
    _d="$(dirname "${_d}")"
done
REPO_ROOT="${REPO_ROOT:-${PWD}}"
_log_file() { [ -n "${LOG_FILE:-}" ] && echo -e "$*" >> "${LOG_FILE}" 2>/dev/null || true; }
say()  { local m="→  $*"; echo -e "\033[36m${m}\033[0m"; _log_file "${m}"; }
ok()   { local m="✅ $*"; echo -e "\033[32m${m}\033[0m"; _log_file "${m}"; }
warn() { local m="⚠  $*"; echo -e "\033[33m${m}\033[0m"; _log_file "${m}"; }
err()  { local m="【错误】$*"; echo -e "\033[31m${m}\033[0m" >&2; _log_file "${m}"; }

ensure_skopeo_policy() {
    command -v skopeo >/dev/null 2>&1 || return 0
    [ -f "/etc/containers/policy.json" ] && return 0
    mkdir -p /etc/containers 2>/dev/null || { warn "无法创建 /etc/containers: skopeo 兜底可能失败(需 root)"; return 1; }
    cat > /etc/containers/policy.json <<'POLICY_EOF'
{
    "default": [
        {
            "type": "insecureAcceptAnything"
        }
    ]
}
POLICY_EOF
}

[ "$(id -u)" -eq 0 ] || { err "需要 root(docker 访问), 请 sudo 执行"; exit 1; }
ensure_skopeo_policy

# ---- 版本(与 cluster.conf.example / chart 90.0.0 默认一致; 环境变量可覆盖) ----
PROMETHEUS_APP_VERSION="${PROMETHEUS_APP_VERSION:-v0.93.1}"              # operator/config-reloader/admission-webhook
PROMETHEUS_IMAGE_PROMETHEUS="${PROMETHEUS_IMAGE_PROMETHEUS:-v3.14.0-distroless}"
PROMETHEUS_IMAGE_ALERTMANAGER="${PROMETHEUS_IMAGE_ALERTMANAGER:-v0.34.0}"
PROMETHEUS_IMAGE_NODE_EXPORTER="${PROMETHEUS_IMAGE_NODE_EXPORTER:-1.12.1}"
PROMETHEUS_IMAGE_KSM="${PROMETHEUS_IMAGE_KSM:-2.20.0}"
PROMETHEUS_IMAGE_GRAFANA="${PROMETHEUS_IMAGE_GRAFANA:-13.2.1-distroless}"
PROMETHEUS_IMAGE_SIDECAR="${PROMETHEUS_IMAGE_SIDECAR:-2.11.2}"
PROMETHEUS_IMAGE_CERTGEN="${PROMETHEUS_IMAGE_CERTGEN:-1.8.8}"
PROMETHEUS_SAVE_DIR="${PROMETHEUS_SAVE_DIR:-${REPO_ROOT}/deployments/offline-files/prometheus}"
mkdir -p "${PROMETHEUS_SAVE_DIR}"
say "配置: app=${PROMETHEUS_APP_VERSION} prometheus=${PROMETHEUS_IMAGE_PROMETHEUS} grafana=${PROMETHEUS_IMAGE_GRAFANA} 保存目录=${PROMETHEUS_SAVE_DIR}"

# ---- 参数解析: --list / --force / 镜像 ref ----
MODE="save"; FORCE=0
for a in "$@"; do
    case "${a}" in
        --list|-l)  MODE="list" ;;
        --force|-f) FORCE=1 ;;
        *)          EXTRA_IMGS="${EXTRA_IMGS:-} ${a}" ;;
    esac
done

PROMETHEUS_IMAGE_LIST="${PROMETHEUS_IMAGE_LIST:-}"
if [ -z "${PROMETHEUS_IMAGE_LIST}" ]; then
    PROMETHEUS_IMAGE_LIST="quay.io/prometheus-operator/prometheus-operator:${PROMETHEUS_APP_VERSION}
quay.io/prometheus-operator/prometheus-config-reloader:${PROMETHEUS_APP_VERSION}
quay.io/prometheus-operator/admission-webhook:${PROMETHEUS_APP_VERSION}
quay.io/prometheus/prometheus:${PROMETHEUS_IMAGE_PROMETHEUS}
quay.io/prometheus/alertmanager:${PROMETHEUS_IMAGE_ALERTMANAGER}
quay.io/prometheus/node-exporter:${PROMETHEUS_IMAGE_NODE_EXPORTER}
registry.k8s.io/kube-state-metrics/kube-state-metrics:${PROMETHEUS_IMAGE_KSM}
docker.io/grafana/grafana:${PROMETHEUS_IMAGE_GRAFANA}
quay.io/kiwigrid/k8s-sidecar:${PROMETHEUS_IMAGE_SIDECAR}
docker.io/jkroepke/kube-webhook-certgen:${PROMETHEUS_IMAGE_CERTGEN}"
fi

[ -n "${EXTRA_IMGS:-}" ] && PROMETHEUS_IMAGE_LIST="${EXTRA_IMGS# }"

if [ "${MODE}" = "list" ]; then
    echo "kube-prometheus-stack 需下载的镜像清单(保存目录: ${PROMETHEUS_SAVE_DIR}):"
    while IFS= read -r img; do
        [ -z "${img}" ] && continue
        fname="$(echo "${img}" | sed 's#/#_#g; s#:#_#g').tar"
        if [ -f "${PROMETHEUS_SAVE_DIR}/${fname}" ]; then
            echo "  ✓ [已存在] ${img}  →  ${fname}"
        else
            echo "  ☐ [待下载] ${img}  →  ${fname}"
        fi
    done <<< "${PROMETHEUS_IMAGE_LIST}"
    exit 0
fi

save_one() {
    local src="$1" fname dest SRC_TAG _LOCAL retry=0
    fname="$(echo "${src}" | sed 's#/#_#g; s#:#_#g').tar"
    dest="${PROMETHEUS_SAVE_DIR}/${fname}"
    if [ -f "${dest}" ] && [ "${FORCE}" != "1" ]; then
        ok "tar 已存在, 跳过(保持幂等): ${fname}"
        return 0
    fi
    say "镜像: ${src}"
    say "保存到: ${dest}"

    # ① 本地 docker daemon 已有
    _LOCAL="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -x "${src}" | head -1 || true)"
    [ -z "${_LOCAL}" ] \
        && _LOCAL="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E "/${src##*/}$|^${src}$" | head -1 || true)"
    if [ -n "${_LOCAL}" ]; then
        say "  本地 docker 已有: ${_LOCAL}, 直接 save ..."
        if docker save "${_LOCAL}" -o "${dest}"; then
            chmod 644 "${dest}"
            ok "保存完成(本地 docker): ${fname}"; return 0
        fi
        rm -f "${dest}"
        warn "  本地 save 失败, 尝试 pull ..."
    fi

    # ② docker pull(5 次重试)→ save
    if command -v docker >/dev/null 2>&1; then
        say "  docker pull ${src}(5 次重试)..."
        retry=0
        while ! docker pull --platform linux/amd64 "${src}" >/dev/null 2>&1; do
            retry=$((retry + 1))
            [ "${retry}" -ge 5 ] && { err "docker pull 失败(5 次重试): ${src}"; return 1; }
            warn "    重试 ${retry}/5: ${src} ..."
            sleep 3
        done
        if docker save "${src}" -o "${dest}"; then
            chmod 644 "${dest}"
            ok "保存完成(docker pull + save): ${fname}"; return 0
        fi
        rm -f "${dest}"
    fi

    # ③ skopeo 兜底(--platform linux/amd64, 与 ceph-save-images.sh 同款防多架构 manifest-list)
    if command -v skopeo >/dev/null 2>&1; then
        say "  skopeo copy ${src}(linux/amd64)→ docker-archive:${dest} ..."
        if skopeo copy --quiet --src-tls-verify=false --override-arch=amd64 --override-os=linux "docker://${src}" "docker-archive:${dest}"; then
            chmod 644 "${dest}"
            ok "保存完成(skopeo): ${fname}"; return 0
        fi
        rm -f "${dest}"
    fi

    err "保存失败: ${src}(docker/skopeo 均不可用或拉取失败); 检查网络/镜像源"
    return 1
}

say "kube-prometheus-stack 镜像清单:"
echo "${PROMETHEUS_IMAGE_LIST}" | sed 's/^/  - /'
count=0
while IFS= read -r img; do
    [ -z "${img}" ] && continue
    if save_one "${img}"; then
        count=$((count + 1))
    fi
done <<< "${PROMETHEUS_IMAGE_LIST}"

echo "---------------------------------------------"
ok "保存完成: ${count} 个镜像 → ${PROMETHEUS_SAVE_DIR}"
du -sh "${PROMETHEUS_SAVE_DIR}" 2>/dev/null | awk '{print "  总大小: "$1}'
echo "  部署时由 08_prometheus.sh 自动推送至集群内置 registry(本地源, 不联网)"
echo "  或手动: skopeo copy --src-tls-verify=false docker-archive:<tar> docker://<registry>/<repo>:<tag>"
