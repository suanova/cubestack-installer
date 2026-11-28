#!/bin/bash
# ============================================================
# MODULE: t_head_ppu
# DESC: 部署 T-Head 真武 PPU device plugin —— 默认 ACK ack-ppu-device-plugin PoC,
#       T_HEAD_PPU_PLUGIN_SOURCE=native 时切换到自研 t-head-ppu-device-plugin。
#       推镜像到集群内置 registry → 应用 vendored 清单(ACK/native) → 等待 DS → 校验 allocatable。
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: T_HEAD_PPU_ENABLED
# UNINSTALL: 1
# REQUIRES: k8s_deploy k8s_registry t_head_ppu_runtime
# 说明:
#   · **ACK 优先**: 默认 T_HEAD_PPU_PLUGIN_SOURCE=ack。ACK 镜像自带 PPU 用户态库
#     (libnvidia-ml/libhgml/libuki), 只缺宿主 KMD; 先按整卡 PoC 验证, 不要默认开
#     --enable-cdi/--enable-topology(见 cubestack-addon/t-head-ppu/ack/daemonset.yaml 注释)。
#   · **native fallback**: 自研插件只做整卡, 资源名同为 alibabacloud.com/ppu;
#     需要 SAIL SDK 的 ppu-smi, 由 15_t_head_ppu_runtime.sh 保证。
#   · **不能同时装两个**: 两者都上报 alibabacloud.com/ppu。切换来源时本模块用同名
#     DaemonSet/SA/ClusterRole 覆盖, 并在卸载分支统一清理。
#   · 镜像先推入集群内置 registry(节点只从内置 registry 拉); 离线 tar 由联网机
#     导出到 T_HEAD_PPU_OFFLINE_DIR(ACK 上游镜像 / native 镜像由插件仓库构建后推 Harbor)。
#   · 节点选择: DaemonSet 用 NFD PCI 标签(feature.node.kubernetes.io/pci-1ded.present=true)
#     或 installer fallback 标签(ppu.example.com/device=true), 二者 OR。
#   · 验证: 24_verify_t_head_ppu.sh(DaemonSet/allocatable/冒烟 Pod)。
# 数据源: cluster.conf (T_HEAD_PPU_* / REGISTRY_* / NODES / SSH_KEY_NAME)
# 用法:   sudo ./deploy-cluster.sh --enable t_head_ppu
#         sudo ./deploy-cluster.sh --steps t_head_ppu
#         T_HEAD_PPU_PLUGIN_SOURCE=native sudo ./deploy-cluster.sh --steps t_head_ppu --fresh
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

NS="${T_HEAD_PPU_NAMESPACE:-kube-system}"

# ---------------- 卸载分支(必须在 TOGGLE 之前) ----------------
if [ "${CUBESTACK_MODULE_ACTION:-install}" = "uninstall" ]; then
    init_remote_kubectl || exit 1
    say "  t_head_ppu: 删除 DS/SA/ClusterRole/ClusterRoleBinding/ConfigMap..."
    SSH "${K} -n ${NS} delete ds ppu-device-plugin --ignore-not-found >/dev/null 2>&1 || true"
    SSH "${K} -n ${NS} delete sa ppu-device-plugin --ignore-not-found >/dev/null 2>&1 || true"
    SSH "${K} delete clusterrole ppu-device-plugin --ignore-not-found >/dev/null 2>&1 || true"
    SSH "${K} delete clusterrolebinding ppu-device-plugin --ignore-not-found >/dev/null 2>&1 || true"
    SSH "${K} -n ${NS} delete cm t-head-ppu-config --ignore-not-found >/dev/null 2>&1 || true"
    ok "  T-Head PPU device plugin 已卸载(KMD/SDK/节点标签保留)"
    exit 0
fi

[ "${T_HEAD_PPU_ENABLED:-false}" = "true" ] || { say "T_HEAD_PPU_ENABLED=false, 跳过 T-Head PPU device plugin"; exit 0; }

init_remote_kubectl || exit 1
skopeo_require

SOURCE="${T_HEAD_PPU_PLUGIN_SOURCE:-ack}"
case "${SOURCE}" in
    ack|native) ;;
    *) err "T_HEAD_PPU_PLUGIN_SOURCE 只能是 ack|native(当前=${SOURCE})"; exit 1 ;;
esac

OFFLINE_DIR="${T_HEAD_PPU_OFFLINE_DIR:-${REPO_ROOT}/deployments/offline-files/t-head-ppu}"
MANIFEST_DIR="${REPO_ROOT}/deployments/cubestack-addon/t-head-ppu/${SOURCE}"
REG_DIRECT="${REGISTRY_DIRECT:-${REGISTRY_IP:-$(first_master_ip)}:${REGISTRY_PORT:-5000}}"
REG_BASE="${REGISTRY_DOMAIN:-${REGISTRY_IP}}:${REGISTRY_PORT:-5000}"

# ---------------- 1/4 选择镜像 + 推入内置 registry ----------------
if [ "${SOURCE}" = "ack" ]; then
    SRC_REF="${T_HEAD_PPU_ACK_IMAGE}"
else
    SRC_REF="${T_HEAD_PPU_NATIVE_IMAGE}"
fi
case "${SRC_REF}" in
    *"@"*) err "不支持 digest 引用: ${SRC_REF}(需要 tag)"; exit 1 ;;
    *"/"*":"*) ;;
    *) err "镜像 ref 非法(需要 <registry>/<path>:<tag>): ${SRC_REF}"; exit 1 ;;
esac
IMG_TAG="${SRC_REF##*:}"
IMG_PATH="${SRC_REF#*/}"
IMG_PATH="${IMG_PATH%:*}"
IMG_REF="${REG_BASE}/${IMG_PATH}:${IMG_TAG}"
IMG_TARGET="${REG_DIRECT}/${IMG_PATH}:${IMG_TAG}"
IMG_BASE="${IMG_PATH##*/}"

say "[1/4] 推送 ${SOURCE} 镜像到集群内置 registry..."
say "  源: ${SRC_REF}"
say "  目标: ${IMG_REF}"
TAR_FILE="$(find_offline_tar "${IMG_BASE}:${IMG_TAG}" "*${IMG_BASE}*${IMG_TAG}*.tar" "${OFFLINE_DIR}")" || TAR_FILE=""
if [ -z "${TAR_FILE}" ]; then
    err "离线镜像 tar 缺失: ${OFFLINE_DIR}/*${IMG_BASE}*${IMG_TAG}*.tar"
    err "  获取: 在联网机用 skopeo copy … docker-archive: 把 ${SRC_REF} 导出到 ${OFFLINE_DIR}"
    err "  (文件名需包含 ${IMG_BASE} 与 ${IMG_TAG}; 详见 ${OFFLINE_DIR}/README.md)"
    exit 1
fi
say "  tar: $(basename "${TAR_FILE}")"
image_push_args_init
push_image_skopeo "docker-archive:${TAR_FILE}" "docker://${IMG_TARGET}" ${IMAGE_PUSH_ARGS[@]+"${IMAGE_PUSH_ARGS[@]}"} \
    || { err "镜像推送失败: ${IMG_TARGET}"; exit 1; }
ok "  镜像已推送: ${IMG_REF}"

# ---------------- 2/4 应用 ConfigMap(source/image) ----------------
say "[2/4] 应用 t-head-ppu-config..."
SSH "${K}" create ns "${NS}" >/dev/null 2>&1 || true
_CM_TMP="$(mktemp)"
cat > "${_CM_TMP}" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: t-head-ppu-config
  namespace: ${NS}
data:
  source: "${SOURCE}"
  image: "${IMG_REF}"
EOF
SSH "${K} apply -f -" < "${_CM_TMP}" || { rm -f "${_CM_TMP}"; err "ConfigMap apply 失败"; exit 1; }
rm -f "${_CM_TMP}"
ok "  ConfigMap ${NS}/t-head-ppu-config 已就绪"

# ---------------- 3/4 应用 vendored 清单 ----------------
say "[3/4] 应用 ${SOURCE} 清单(${MANIFEST_DIR})..."
[ -d "${MANIFEST_DIR}" ] || { err "vendored 清单目录不存在: ${MANIFEST_DIR}"; exit 1; }

_render_apply() {
    local src="$1"
    local tmp
    tmp="$(mktemp)"
    sed -e "s#@@IMAGE@@#${IMG_REF}#g" \
        -e "s#namespace: kube-system#namespace: ${NS}#g" \
        "${src}" > "${tmp}"
    SSH "${K}" apply -f - < "${tmp}" || { rm -f "${tmp}"; return 1; }
    rm -f "${tmp}"
    return 0
}

if [ "${SOURCE}" = "ack" ]; then
    [ -f "${MANIFEST_DIR}/rbac.yaml" ] || { err "缺少 ${MANIFEST_DIR}/rbac.yaml"; exit 1; }
    _render_apply "${MANIFEST_DIR}/rbac.yaml" || { err "ACK RBAC apply 失败"; exit 1; }
    ok "  ACK RBAC 已应用"
fi
[ -f "${MANIFEST_DIR}/daemonset.yaml" ] || { err "缺少 ${MANIFEST_DIR}/daemonset.yaml"; exit 1; }
_render_apply "${MANIFEST_DIR}/daemonset.yaml" || { err "DaemonSet apply 失败"; exit 1; }
ok "  DaemonSet ppu-device-plugin 已应用(来源=${SOURCE})"

# ---------------- 4/4 等待 + 校验 allocatable ----------------
say "[4/4] 等待 ppu-device-plugin DaemonSet Ready..."
if ! SSH "${K} -n ${NS} rollout status ds/ppu-device-plugin --timeout=180s" >/dev/null 2>&1; then
    warn "  DaemonSet 180s 内未 Ready; 当前状态:"
    SSH "${K} -n ${NS} get pods -l app.kubernetes.io/name=ppu-device-plugin -o wide 2>/dev/null | sed 's/^/    /' || true
    warn "  最近日志:"
    SSH "${K} -n ${NS} logs -l app.kubernetes.io/name=ppu-device-plugin --tail=40 2>/dev/null | sed 's/^/    /' || true
    err "ppu-device-plugin 未就绪; 常见原因: KMD 未加载 / KMD 与 ACK 镜像内 libuki ABI 不匹配 / SDK 缺失(source=native)"
    exit 1
fi
ok "  DaemonSet 已 Ready"

_ppu_alloc() {
    (SSH "${K}" get nodes -o json 2>/dev/null || true) | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for n in d.get("items", []):
    name=n.get("metadata",{}).get("name","")
    for k,v in (n.get("status",{}).get("allocatable",{}) or {}).items():
        if k.startswith("alibabacloud.com/ppu"):
            try:
                if int(v) > 0:
                    print(name, f"{k}={v}")
            except Exception:
                pass'
}

ALLOC=""
for _i in $(seq 1 36); do
    ALLOC="$(_ppu_alloc)"
    [ -n "${ALLOC}" ] && break
    [ "${_i}" -lt 36 ] && sleep 5
done

if [ -n "${ALLOC}" ]; then
    ok "  节点已上报 PPU 资源:"
    printf '%s\n' "${ALLOC}" | sed 's/^/    /'
else
    if [ "${T_HEAD_PPU_ALLOW_NO_DEVICE:-false}" = "true" ]; then
        warn "  未发现 alibabacloud.com/ppu allocatable(T_HEAD_PPU_ALLOW_NO_DEVICE=true → 放行)"
    else
        err "  未发现 alibabacloud.com/ppu allocatable; 检查 DS 日志/节点 KMD/设备节点"
        err "  排查: kubectl -n ${NS} logs ds/ppu-device-plugin; kubectl describe node <node> | grep alibabacloud.com"
        exit 1
    fi
fi

record_installed_component "t_head_ppu"

echo "---------------------------------------------"
ok "T-Head PPU device plugin 部署完成(来源=${SOURCE})"
echo "  镜像:   ${IMG_REF}"
echo "  资源:   alibabacloud.com/ppu(ACK 可能同时上报 ppu-* 切片资源)"
echo "  验证:   sudo ./deploy-cluster.sh --steps verify_t_head_ppu"
