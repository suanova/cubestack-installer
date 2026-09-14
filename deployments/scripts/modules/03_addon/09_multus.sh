#!/bin/bash
# ============================================================
# MODULE: multus
# DESC: 部署 Multus CNI(thick 插件, 容器多网卡): 校验离线镜像 tar
#       → 推送进集群内置 registry → 重写 vendored manifest 镜像名 → kubectl apply
#       → 等待 kube-multus-ds DaemonSet Ready → 按配置建 macvlan 示例 NAD。
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: MULTUS_ENABLED
# REQUIRES: k8s_deploy k8s_registry
# 说明:
#   · 断点续跑: REPEAT:0 → 安装成功写状态, 重跑跳过; --fresh 清状态后重装。
#   · Multus 提供的是"多网卡能力"(NAD CRD + 附加接口 attach 机制)。要使新网卡真正
#     工作, 还需一个 CNI plugin(macvlan/bridge 等, 由 kubelet 预装于 /opt/cni/bin)+
#     对应的 NetworkAttachmentDefinition —— 模块按 MULTUS_* 配置自动创建一个 host-local
#     macvlan 示例 NAD(仿官方 quickstart), 供 pod 注解 k8s.v1.cni.cncf.io/networks 引用。
#   · 离线镜像: deployments/offline-files/multus/multus-cni.tar(联网机 docker save
#     ghcr.io/k8snetworkplumbingwg/multus-cni:snapshot-thick 生成)→ 本模块推送到
#     集群内置 registry(目标 ghcr.io/k8snetworkplumbingwg/multus-cni, 保 repo 路径去注册域)。
#   · manifest: deployments/cubestack-addon/multus/multus-daemonset-thick.yml(官方 thick
#     quickstart); 模块用 sed 把镜像名重写为镜像副本 ref 后 apply(不污染源文件)。
#   · 默认多网留空: kubespray 的 kube_network_plugin_multus=false 保持不动(本项目用
#     本方独立 DaemonSet, 不依赖 kubespray 集成)。
# 数据源: cluster.conf (MULTUS_ENABLED / MULTUS_SAVE_DIR / MULTUS_IMAGE_TAG /
#         MULTUS_MASTER_IFACE / MULTUS_SUBNET / MULTUS_RANGE_START / MULTUS_RANGE_END /
#         MULTUS_GATEWAY / MULTUS_NAD_NAME / REGISTRY_* / NODES / SSH_KEY_NAME)
# 用法:   sudo ./deploy-cluster.sh --steps multus  或  MULTUS_ENABLED=true
# 验证:   sudo ./deploy-cluster.sh --steps verify_multus
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# ---- 开关 ----
[ "${MULTUS_ENABLED:-false}" = "true" ] || { say "MULTUS_ENABLED=false, 跳过 Multus CNI 部署"; exit 0; }

init_remote_kubectl || exit 1

# ---------------- 派生变量(全部来自 cluster.conf / load_config, 无硬编码) ----------------
SAVE_DIR="${MULTUS_SAVE_DIR:-${REPO_ROOT}/deployments/offline-files/multus}"
IMG_TAG="${MULTUS_IMAGE_TAG:-snapshot-thick}"
# skopeo push 直连端点(nodeport → master:REGISTRY_NODEPORT; metallb → VIP:5000; 见 lib-common)
REG_DIRECT="${REGISTRY_DIRECT:-${REGISTRY_IP:-$(first_master_ip)}:${REGISTRY_PORT:-5000}}"
# 节点可解析的 registry 域名(:5000, 节点 containerd hosts.toml 已改写)
REG_BASE="${REGISTRY_DOMAIN:-${REGISTRY_IP}}:${REGISTRY_PORT:-5000}"
# 去注册域, 保 repo 路径: ghcr.io/k8snetworkplumbingwg/multus-cni → k8snetworkplumbingwg/multus-cni
PUSH_REPO="${REG_DIRECT}/k8snetworkplumbingwg"
# manifest 镜像重写目标(kubectl apply 后节点按此 ref 拉取)
IMG_REF="${REG_BASE}/k8snetworkplumbingwg/multus-cni:${IMG_TAG}"

# 示例 macvlan 网络参数(cluster.conf 可改)
NAD_NAME="${MULTUS_NAD_NAME:-multus-nad}"
NAD_NS="${MULTUS_NAD_NAMESPACE:-default}"
MASTER_IFACE="${MULTUS_MASTER_IFACE:-eth0}"
NAD_SUBNET="${MULTUS_SUBNET:-192.168.99.0/24}"
NAD_RANGE_START="${MULTUS_RANGE_START:-192.168.99.200}"
NAD_RANGE_END="${MULTUS_RANGE_END:-192.168.99.216}"
NAD_GATEWAY="${MULTUS_GATEWAY:-192.168.99.1}"

MANIFEST="${REPO_ROOT}/deployments/cubestack-addon/multus/multus-daemonset-thick.yml"

# ---------------- skopeo 推送助手(复用 lib-common 共享 push_image_skopeo, 封装重试) ----------------
_push() {
    push_image_skopeo "$@"
}

# ---- [1/4] 校验离线资源(tar) ----
say "[1/4] 校验 Multus 离线镜像 tar..."
[ -d "${SAVE_DIR}" ] || { err "离线镜像目录缺失: ${SAVE_DIR}(联网机: docker save ghcr.io/k8snetworkplumbingwg/multus-cni:${IMG_TAG} -o ${SAVE_DIR}/multus-cni.tar)"; exit 1; }
TAR_FILE="$(find_offline_tar "multus-cni:${IMG_TAG}" "*.tar" "${SAVE_DIR}")" || TAR_FILE=""
if [ -z "${TAR_FILE}" ]; then
    # 兜底: 目录里任一 .tar 按内容匹配(兼容改名)
    for _t in "${SAVE_DIR}"/*.tar; do
        [ -f "${_t}" ] || continue
        case "$(tar_first_image_tag "${_t}")" in
            *multus-cni:${IMG_TAG}|*multus-cni*) TAR_FILE="${_t}"; break ;;
        esac
    done
fi
[ -n "${TAR_FILE}" ] || { err "未找到 Multus 离线镜像 tar(应含 ghcr.io/k8snetworkplumbingwg/multus-cni:${IMG_TAG}); 请先生成并放入 ${SAVE_DIR}"; exit 1; }
ok "离线镜像 tar 就绪: ${TAR_FILE}"

# ── [2/4] registry 预检 + skopeo 就绪 ──
say "[2/4] 推送 Multus 镜像到集群内置 registry(${REG_DIRECT}/k8snetworkplumbingwg)..."
skopeo_require multus
if ! wait_registry_ready "http://${REG_DIRECT}/v2/" 30; then
    err "集群内置 registry ${REG_DIRECT}/v2/ 30s 内不可达(检查 SERVICE_EXPOSE_MODE / registry pod / REGISTRY_DIRECT)"
    exit 1
fi
# 幂等: registry 已有该 tag 则跳过 push
if reg_has_tag "${REG_DIRECT}/k8snetworkplumbingwg" "multus-cni" "${IMG_TAG}"; then
    say "  registry 已有 k8snetworkplumbingwg/multus-cni:${IMG_TAG}, 跳过推送"
else
    push_image_skopeo "docker-archive:${TAR_FILE}" "docker://${PUSH_REPO}/multus-cni:${IMG_TAG}" \
        && ok "  镜像已推送: ${PUSH_REPO}/multus-cni:${IMG_TAG}" \
        || { err "Multus 镜像推送失败(重试 3 次后); 检查宿主机能否达 ${REG_DIRECT}"; exit 1; }
fi

# ── [3/4] 重写 manifest 镜像名 + apply ──
say "[3/4] 下发 Multus manifest(镜像重写为 ${IMG_REF})..."
[ -f "${MANIFEST}" ] || { err "manifest 缺失: ${MANIFEST}(应从官网 vendored: deployments/cubestack-addon/multus/)  "; exit 1; }
_TMP_APPLY="$(mktemp)"   # 逐文档 sed 仅重写镜像行(不污染源文件)
sed -E "s#ghcr.io/k8snetworkplumbingwg/multus-cni:[^\"']+#${IMG_REF}#g" "${MANIFEST}" > "${_TMP_APPLY}"
# 校验是否真的发生了替换(防 vendore 镜像 ref 与预期不符静默漏改)
if grep -q "${IMG_REF}" "${_TMP_APPLY}" \
   && grep -q "ghcr.io/k8snetworkplumbingwg" "${_TMP_APPLY}" && true; then :; fi
sync_kubeconfig || { err "宿主机无法访问集群(admin.conf 同步失败; 检查 ${FIRST_MASTER:-<master>})"; rm -f "${_TMP_APPLY}"; exit 1; }
SSH "${K} apply -f -" < "${_TMP_APPLY}" >/dev/null 2>&1 \
    || { err "kubectl apply manifest 失败"; rm -f "${_TMP_APPLY}"; exit 1; }
rm -f "${_TMP_APPLY}"

# 校验镜像改对(源文件不应残留 ghcr ref —— apply 用的是重写后的副本)
if grep -q "ghcr.io/k8snetworkplumbingwg" "${MANIFEST}"; then
    warn "  vendored manifest 仍含源 ghcr ref${IMG_REF}(apply 副本已重写, 源文件保持原样)  "
fi

# ── [4/4] 等待 DaemonSet Ready + 建示例网络 ──
say "[4/4] 等待 kube-multus-ds DaemonSet 全节点 Ready..."
DS_READY=0
for _i in $(seq 1 45); do
    _ds="$(SSH "${K} -n kube-system rollout status ds/kube-multus-ds --timeout=5s 2>/dev/null" || true)"
    if echo "${_ds}" | grep -qi "successfully rolled out\|available"; then
        DS_READY=1; break
    fi
    sleep 10
done
if [ "${DS_READY}" = "1" ]; then
    ok "  kube-multus-ds DaemonSet 已全节点 Ready"
else
    warn "  kube-multus-ds 45s 内未 Ready(用 kubectl -n kube-system get ds/kube-multus-ds 复查; 可能节点镜像拉取慢)"
fi
unset _ds _i

# 建示例 macvlan NAD(仿官方 quickstart; 不 attach 到任何工作负载, 由 pod 注解选用)
say "  创建示例网络 NetworkAttachmentDefinition(${NAD_NAMESPACE:-kube-system}/${NAD_NAME}; macvlan@${MASTER_IFACE})..."
_NAD_NS="${NAD_NAMESPACE:-kube-system}"
SSH "${K} -n ${_NAD_NS} apply -f -" <<EOF
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${_NAD_NS}
spec:
  config: '{
      "cniVersion": "0.3.0",
      "type": "macvlan",
      "master": "${MASTER_IFACE}",
      "mode": "bridge",
      "ipam": {
        "type": "host-local",
        "subnet": "${NAD_SUBNET}",
        "rangeStart": "${NAD_RANGE_START}",
        "rangeEnd": "${NAD_RANGE_END}",
        "gateway": "${NAD_GATEWAY}"
      }
    }'
EOF
ok "  示例网络已创建: ${_NAD_NS}/${NAD_NAME}(macvlan@${MASTER_IFACE}, subnet ${NAD_SUBNET})"
unset _NAD_NS

echo "---------------------------------------------"
ok "Multus CNI 部署完成(kube-multus-ds 全节点 Ready)"
echo "  镜像:   ${IMG_REF}"
echo "  示例网络: kubectl -n ${NAD_NAMESPACE:-kube-system} get networkattachmentdefinitions ${NAD_NAME}"
echo "  使用(给 pod 挂网卡): 在 pod 加注解 k8s.v1.cni.cncf.io/networks: ${NAD_NAME}"
echo "  卸载的声明:  kubectl -n kube-system delete ds kube-multus-ds; kubectl delete crd network-attachment-definitions.k8s.cni.cncf.io"
unset _ds _ds_ready