#!/bin/bash
# ============================================================
# metax-load-images.sh — 把离线目录中的沐曦(MetaX)镜像 tar 加载推送到集群内置 registry
# 用途: 离线环境(METAX_IMAGE_MODE=tar 的替代入口)手动把 tar 推送到集群 registry,
#       之后由 gpu-operator 模块 helm 安装使用。幂等, 可重复执行。
# 数据源: cluster.conf (METAX_OFFLINE_DIR / METAX_IMAGE_DIR / METAX_TAR_PATTERN /
#                      METAX_REGISTRY / REGISTRY_* / METAX_VERSION)
# 核心组件 tar 带架构后缀(0.15.3-amd64/-arm64): 单 arch 集群只推本机架构并去掉后缀
#   (chart 引用无后缀 ref: metax/gpu-label:0.15.3); maca/driver 的版本后缀是 tag 一部分, 原样推送。
# 用法:   sudo ./metax-load-images.sh [tar 目录]   (缺省 = METAX_OFFLINE_DIR + METAX_IMAGE_DIR)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

need_root() { [ "$(id -u)" -eq 0 ] || { err "需要 root, 请 sudo 执行"; exit 1; }; }
need_root

REGISTRY_BASE="${REGISTRY_DOMAIN}:${REGISTRY_PORT}"   # 集群内置 registry 域名(registry.local:5000)
PUSH_REGISTRY="${REGISTRY_IP}:${REGISTRY_PORT}/metax" # 推送用 MetalLB VIP 直连(绕开宿主 DNAT, 大 blob 更稳)

# 推送 skopeo(脚本级重试 3 次): 大 blob(如 maca 5.5G)连接中途断开时 skopeo 的 --retry-times 不覆盖, 这里整体重试
_push_skopeo() {
    local src="$1" dst="$2" n=1 err
    for n in 1 2 3; do
        if skopeo copy --quiet --src-tls-verify=false --dest-tls-verify=false \
            --dest-no-creds "${src}" "${dst}" 2>/tmp/skopeo-err; then
            rm -f /tmp/skopeo-err; return 0
        fi
        err="$(tail -1 /tmp/skopeo-err 2>/dev/null || true)"
        if [ "${n}" -lt 3 ]; then
            say "  推送失败(第 ${n}/3 次: ${err}), 3s 后重试整包..."
            sleep 3
        fi
    done
    rm -f /tmp/skopeo-err
    return 1
}

# ---------- 关键修复: 保证 operator 需要的镜像完整进入集群 registry ----------
# 背景: 仅 skopeo 远程推送到 registry, 若该镜像 tag 在 registry 里"看似存在但 blob 未真正
#   落盘"(如推送时 registry 后端不稳定 / 磁盘抖动), 节点 crictl pull 仍会 NotFound, 表现为
#   ImagePullBackOff 而 registry tags/list 却"已有"。彻底解法是"直灌节点" —— 直接把镜像 tar
#   import 进所有 master/worker 节点的 containerd, 节点再也不用去 registry pull。
#
# 同步方式(两者都做, 各自独立幂等):
#   ① 集群内置 registry(默认): skopeo 远程推送(所有 tar);
#   ② 每个节点 containerd 直灌: 把本地 tar scp 到节点 → ctr -n k8s.io images import →
#      打上 chart 引用所需的 registry.local:5000/metax/<comp>:<无后缀 tag>(与 chart 完全一致)。
#      节点侧 containerd 有镜像后, crictl pull registry.local:5000/metax/<comp>:<tag> 直接用
#      本地缓存, 不再依赖 registry 可用性 —— 单节点/registry 抖动环境最稳。
#   (可选离线 tar 目录之外的 METAX_IMAGE_DIR 同理并入扫描)
#
# 说明: 直灌节点只作用于"集群内置 registry 引用的无后缀 tag"; maca/driver 带架构后缀 tag 原样,
#   chart 引用的 ref 与本地 tar 完全一致, 直灌后 crictl 命中本地缓存。
_import_to_nodes() {   # <tar文件> <comp> <ver>
    local t="$1" comp="$2" ver="$3" line _ip _user _key
    _key="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        [ -n "${NODE_IP}" ] || continue
        local dst_ref="${REGISTRY_DOMAIN}:${REGISTRY_PORT}/metax/${comp}:${ver}"
        # 已存在则跳过(幂等; 节点无 ctr 直接跳过)
        if ssh -i "${_key}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
            "${NODE_USER:-ubuntu}@${NODE_IP}" \
            "sudo bash -c 'command -v ctr >/dev/null 2>&1 && ctr -n k8s.io images list -q | grep -qx \"${dst_ref}\"'" 2>/dev/null; then
            ok "    [${NODE_HOSTNAME}] 已直灌 ${comp}:${ver}(本地缓存)"
            continue
        fi
        # scp 本地 tar 到节点临时目录(tar 较大, 关压缩防 CPU 卡顿; 失败重试一次)
        if ! scp -i "${_key}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
            -o Compression=no "${t}" "${NODE_USER:-ubuntu}@${NODE_IP}:/tmp/metax-import-${comp}-${ver}.tar" 2>/dev/null \
           && ! scp -i "${_key}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
            -o Compression=no "${t}" "${NODE_USER:-ubuntu}@${NODE_IP}:/tmp/metax-import-${comp}-${ver}.tar" 2>/dev/null; then
            say "    [${NODE_HOSTNAME}] 直灌 ${comp}:${ver} 跳过(scp 失败)"
            continue
        fi
        if ! ssh -i "${_key}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
            "${NODE_USER:-ubuntu}@${NODE_IP}" \
            "sudo bash -c '
                command -v ctr >/dev/null 2>&1 || { rm -f /tmp/metax-import-${comp}-${ver}.tar; exit 9; }
                ctr -n k8s.io images list -q | grep -qx \"${dst_ref}\" && { rm -f /tmp/metax-import-${comp}-${ver}.tar; exit 0; }
                if ! ctr -n k8s.io images import /tmp/metax-import-${comp}-${ver}.tar >/dev/null 2>&1; then
                    sleep 2
                    ctr -n k8s.io images import /tmp/metax-import-${comp}-${ver}.tar >/dev/null 2>&1 || { rm -f /tmp/metax-import-${comp}-${ver}.tar; exit 1; }
                fi
                src=\$(ctr -n k8s.io images list -q | grep -E \".*/${comp}[:@].*\" | head -1)
                [ -n \"\$src\" ] && ctr -n k8s.io images tag \"\$src\" \"${dst_ref}\" >/dev/null 2>&1 || true
                rm -f /tmp/metax-import-${comp}-${ver}.tar
                ctr -n k8s.io images list -q | grep -qx \"${dst_ref}\" && exit 0 || exit 1
            '" 2>/dev/null; then
            say "    [${NODE_HOSTNAME}] 直灌 ${comp}:${ver} 失败(无 ctr / import 失败)"
        else
            ok "    [${NODE_HOSTNAME}] 已直灌 ${comp}:${ver}"
        fi
    done
}

TAR_DIR="${1:-}"
# 宿主机把 registry.local 解析到集群 registry VIP(供按域名推送, 不留过期 IP)
_ensure_hosts() {   # <ip> <domain>
    local ip="$1" dom="$2" re
    [ -n "${ip}" ] && [ -n "${dom}" ] || return 0
    re="$(echo "${dom}" | sed 's/\./\\./g')"
    sed -i -E "/[[:space:]]${re}([[:space:]]|$)/d" /etc/hosts 2>/dev/null || true
    grep -qE "^${ip}[[:space:]]+${dom}([[:space:]]|$)" /etc/hosts 2>/dev/null \
        || echo "${ip} ${dom}" >> /etc/hosts 2>/dev/null
}
_ensure_hosts "${REGISTRY_IP}" "${REGISTRY_DOMAIN}"
curl -s -m 8 "http://${REGISTRY_BASE}/v2/" >/dev/null 2>&1 \
    || { err "集群内置 registry ${REGISTRY_BASE}/v2/ 不可达(检查 hosts 与 MetalLB VIP)"; exit 1; }

if [ -n "${TAR_DIR}" ]; then
    DIRS=("${TAR_DIR}")
else
    DIRS=("${METAX_OFFLINE_DIR}" "${METAX_IMAGE_DIR}")
fi

ARCH="$(uname -m)"; case "${ARCH}" in x86_64|amd64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; *) ARCH=amd64;; esac

say "加载沐曦镜像 tar → ${METAX_REGISTRY}(arch=${ARCH}) ..."
_PUSHED=0; _SKIP=0
for d in "${DIRS[@]}"; do
    [ -d "${d}" ] || continue
    for t in "${d}"/*.tar; do
        [ -f "${t}" ] || continue
        case "$(basename "${t}")" in *"${METAX_TAR_PATTERN}"*) ;; *) continue ;; esac
        src="$(tar_first_image_tag "${t}")"
        [ -n "${src}" ] || { warn "  跳过 $(basename "${t}"): 无法读取源镜像名"; _SKIP=$((_SKIP+1)); continue; }
        comp="${src%%:*}"; comp="${comp##*/}"
        ver="${src##*:}"
        # 只推当前 gpu operator 需要的版本: maca/driver 只推配置版本, 核心组件只推本机架构的 METAX_VERSION
        case "${comp}" in
            maca)
                [ "${ver}" = "${METAX_MACA_IMAGE#*:}" ] || { say "  跳过非当前所需 ${comp}:${ver}"; _SKIP=$((_SKIP+1)); continue; }
                ;;
            driver-image)
                [ "${ver}" = "${METAX_DRIVER_VERSION}" ] || { say "  跳过非当前所需 ${comp}:${ver}"; _SKIP=$((_SKIP+1)); continue; }
                ;;
            *)
                case "${ver}" in
                    ${METAX_VERSION}-${ARCH}|${METAX_VERSION}) ;;
                    *) say "  跳过非当前所需 ${comp}:${ver}"; _SKIP=$((_SKIP+1)); continue ;;
                esac
                ;;
        esac
        case "${ver}" in
            ${METAX_VERSION}-amd64|${METAX_VERSION}-arm64)
                _arch="${ver##*-}"
                [ "${_arch}" = "${ARCH}" ] || { say "  跳过非本机架构 ${comp}:${ver}"; _SKIP=$((_SKIP+1)); continue; }
                ver="${METAX_VERSION}"
                ;;
        esac
        say "  推 ${comp}:${ver} ← $(basename "${t}")"
        _push_skopeo "docker-archive:${t}" "docker://${PUSH_REGISTRY}/${comp}:${ver}" \
            || { err "推送失败(3 次重试后) ${t}"; exit 1; }
        _PUSHED=$((_PUSHED+1))
        # 关键: 直灌该镜像到全部节点 containerd(节点本地有镜像, crictl pull 不再依赖 registry)
        _import_to_nodes "${t}" "${comp}" "${ver}"
    done
done
[ "${_PUSHED}" -gt 0 ] || { err "目录 [${DIRS[*]}] 未找到匹配 ${METAX_TAR_PATTERN} 的 tar"; exit 1; }
ok "加载完成: 推送 ${_PUSHED} 个, 跳过 ${_SKIP} 个 → ${METAX_REGISTRY}"
