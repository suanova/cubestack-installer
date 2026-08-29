#!/bin/bash
# ============================================================
# trim-offline-files.sh — 清理 offline-files 中本部署不需要的镜像/二进制
# ------------------------------------------------------------
# 背景: kubespray/metax-gpu 离线目录由下载命令生成全量清单, 含大量本部署用不到的
#   镜像 tar 与二进制:
#   · kubespray: 未启用 addon 的镜像(cilium/flannel/weave/...)+ 非 containerd 运行时二进制
#   · metax-gpu: 非本机架构(arm64)/非当前版本(maca/driver 旧版)/非本部署组件(operator-bundle 等)
# 部署时只同步/load 必要镜像, 其余纯属冗余。
#
# ⚠ 删除前请先备份 offline-files; 未来启用新 addon/切换架构/版本时需重新下载或从 MinIO 恢复。
#
# 清理范围(可 DRY_RUN 预览):
#   ① kubespray/images 下未匹配 PRELOAD_IMAGE_PATTERNS 的镜像 tar
#   ② kubespray 根下非本部署运行时的二进制/工具(白名单外的)
#   ③ metax-gpu 下非当前架构/版本/组件 的镜像 tar
#      保留: 当前 METAX_VERSION amd64 核心组件 + METAX_MACA_IMAGE + METAX_DRIVER_VERSION 对应 tar
#      删除: 非 amd64(arm64) / 非当前版本(maca/driver 旧版) / 非本部署组件(operator-bundle/catalog)
# 用法:
#   sudo ./trim-offline-files.sh              # 实际清理(打印删除项)
#   sudo ./trim-offline-files.sh --dry-run    # 仅预览将删除的文件(不删除)
# 数据源: cluster.conf (PRELOAD_IMAGE_PATTERNS / METAX_* / OFFLINE_FILES_DIR)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1
[ "$(id -u)" -eq 0 ] || { err "需要 root 权限: sudo $0"; exit 1; }

OFFLINE_ROOT="${OFFLINE_FILES_DIR:-${REPO_ROOT}/deployments/offline-files}"
KUBE_DIR="${OFFLINE_ROOT}/kubespray"
METAX_DIR="${OFFLINE_ROOT}/metax-gpu"
[ -d "${KUBE_DIR}" ] || { err "未找到 ${KUBE_DIR}"; exit 1; }

# ---------------- ① 冗余镜像: 未匹配 PRELOAD_IMAGE_PATTERNS ----------------
# PRELOAD_IMAGE_PATTERNS: 空格分隔; 含 ".tar" 为精确文件名匹配, 否则为文件名包含匹配
PRELOAD_IMAGE_PATTERNS="${PRELOAD_IMAGE_PATTERNS:-calico_cni calico_kube-controllers calico_node etcd kube-apiserver kube-controller-manager kube-proxy kube-scheduler coredns cluster-proportional-autoscaler k8s-dns-node-cache metrics-server pause metallb library_registry local-path-provisioner busybox lws_manager}"
_img_match() {   # <文件名> → 0=匹配(PRELOAD 需要)
    local f="$1" p
    for p in ${PRELOAD_IMAGE_PATTERNS}; do
        case "${p}" in
            *.tar) [ "${f}" = "${p}" ] && return 0 ;;
            *)     case "${f}" in *"${p}"*) return 0 ;; esac ;;
        esac
    done
    return 1
}

# ---------------- ② 冗余二进制: 白名单外的(非 containerd 运行时/未启用组件) ----------------
# 本部署(containerd + calico)需要的二进制白名单(精确文件名前缀, 避免误匹配):
#   gvisor-containerd-shim 文件名含 "containerd", 故白名单用更精确的前缀模式,
#   且 gvisor/kata/youki/crun/nerdctl/cri-dockerd/cilium 明确归为冗余(非 containerd 运行时)。
BIN_KEEP_PREFIX="containerd- cni-plugins- kubelet- kubeadm- kubectl- etcd- calicoctl- runc- helm- skopeo- yq- crictl-"
_bin_keep() {   # <文件名> → 0=保留(白名单前缀匹配)
    local f="$1" b
    for b in ${BIN_KEEP_PREFIX}; do case "${f}" in ${b}*) return 0 ;; esac; done
    return 1
}

# ---------------- ③ metax-gpu 冗余镜像 tar ----------------
# 保留: 当前 METAX_VERSION 的 amd64 核心组件 + METAX_MACA_IMAGE + METAX_DRIVER_VERSION 对应 tar
# 删除: arm64 / 非当前 maca/driver 版本 / operator-bundle/catalog(非本部署组件)
METAX_VERSION="${METAX_VERSION:-0.15.3}"
METAX_IMAGE_COMPONENTS="${METAX_IMAGE_COMPONENTS:-gpu-label gpu-device gpu-aware topo-master topo-worker operator-controller container-runtime driver-manager gpu-scheduler mx-exporter}"
METAX_MACA_TAG="${METAX_MACA_IMAGE:-maca:3.8.1.2-ubuntu20.04-amd64}"; METAX_MACA_TAG="${METAX_MACA_TAG##*:}"
METAX_DRIVER_TAG="${METAX_DRIVER_VERSION:-3.8.1.6-amd64}"
# 判断 tar 是否为当前部署需要
_metax_keep() {   # <文件名> → 0=保留
    local f="$1" comp ver rest
    # 文件名形如: harbor.isuanova.com_metax_<comp>_<ver>.tar(组件名可含 "-", 版本可含 "_")
    case "${f}" in
        *.tar) ;;
        *) return 0 ;;   # 非 tar(如 .run/.tgz/package)不处理
    esac
    rest="${f#harbor.isuanova.com_metax_}"
    comp="${rest%_*}"              # 去掉最后一个 "_" 及之后 → 组件名(container-runtime)
    ver="${rest##*_}"              # 最后一段 → 版本(0.15.3-amd64)
    ver="${ver%.tar}"
    # maca / driver-image: 只保留配置版本
    case "${comp}" in
        maca)         [ "${ver}" = "${METAX_MACA_TAG}" ] && return 0 || return 1 ;;
        driver-image) [ "${ver}" = "${METAX_DRIVER_TAG}" ] && return 0 || return 1 ;;
    esac
    # 核心组件: 需在当前组件列表 + 当前版本 + amd64
    case " ${METAX_IMAGE_COMPONENTS} " in
        *" ${comp} "*) ;;
        *) return 1 ;;   # 非核心组件(operator-bundle/catalog 等)
    esac
    case "${ver}" in
        ${METAX_VERSION}-amd64) return 0 ;;
        *) return 1 ;;
    esac
}

say "清理 offline-files 中本部署不需要的镜像/二进制 ..."
say "  模式: $([ "${DRY_RUN}" = "1" ] && echo 'DRY-RUN 预览(不删除)' || echo '实际删除')"
say "  镜像保留依据(kubespray): PRELOAD_IMAGE_PATTERNS($(echo "${PRELOAD_IMAGE_PATTERNS}" | wc -w) 项)"
say "  二进制保留白名单: ${BIN_KEEP_PREFIX}"
say "  metax-gpu 保留: ${METAX_VERSION}-amd64 核心组件 + maca:${METAX_MACA_TAG} + driver-image:${METAX_DRIVER_TAG}"

DELETED=0; FREED=0
_del() {   # <路径> 删除或预览(支持文件与目录)
    local f="$1"
    if [ -e "${f}" ]; then
        local sz
        sz="$(stat -c %s "${f}" 2>/dev/null || echo 0)"
        if [ "${DRY_RUN}" = "1" ]; then
            echo "  [预览] ${f#${REPO_ROOT}/} ($(du -sh "${f}" 2>/dev/null | cut -f1))"
        else
            rm -rf "${f}"
            echo "  [删除] ${f#${REPO_ROOT}/} ($(du -sh "${f}" 2>/dev/null | cut -f1))"
        fi
        DELETED=$((DELETED+1)); FREED=$((FREED+sz))
    fi
}

# ① 冗余镜像 tar
say "[1/2] 清理未匹配 PRELOAD_IMAGE_PATTERNS 的镜像 tar ..."
shopt -s nullglob
for f in "${KUBE_DIR}"/images/*.tar; do
    [ -f "${f}" ] || continue
    _img_match "$(basename "${f}")" || _del "${f}"
done
shopt -u nullglob

# ② 冗余二进制(白名单外)
say "[2/3] 清理非本部署运行时的二进制(白名单外) ..."
shopt -s nullglob
for f in "${KUBE_DIR}"/{cilium*,cri-o*,gvisor*,kata*,youki*,crun*,nerdctl*,cri-dockerd*,cilium-chart}; do
    [ -e "${f}" ] || continue
    _bin_keep "$(basename "${f}")" || _del "${f}"
done
shopt -u nullglob

# ③ metax-gpu 冗余镜像 tar(非当前架构/版本/组件)
if [ -d "${METAX_DIR}" ]; then
    say "[3/3] 清理 metax-gpu 非当前架构/版本/组件的镜像 tar ..."
    shopt -s nullglob
    for f in "${METAX_DIR}"/*.tar; do
        [ -f "${f}" ] || continue
        _metax_keep "$(basename "${f}")" || _del "${f}"
    done
    shopt -u nullglob
else
    say "[3/3] 跳过(未找到 metax-gpu 目录 ${METAX_DIR})"
fi

FREED_GB="$(awk -v n="${FREED}" 'BEGIN{printf "%.2f", n/1024/1024/1024}')"
echo "---------------------------------------------"
if [ "${DRY_RUN}" = "1" ]; then
    ok "预览完成: 将删除 ${DELETED} 个文件, 释放约 ${FREED_GB} GiB(实际删除去掉 --dry-run)"
else
    ok "清理完成: 删除 ${DELETED} 个文件, 释放约 ${FREED_GB} GiB"
    echo "  如需恢复: 从 MinIO 重新下载对应子目录(或还原备份的 offline-files)"
fi
