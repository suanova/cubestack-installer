#!/bin/bash
# ============================================================
# MODULE: t_head_ppu_runtime
# DESC: 平头哥真武 PPU 节点运行时准备: 预检 KMD/SAIL SDK/设备节点, 可选从离线目录安装,
#       并给 PPU 节点打 NFD 之外的 fallback 标签(ppu.example.com/device=true)与 board-type。
#       不创建任何 Kubernetes 工作负载; device plugin 由 16_t_head_ppu_device_plugin.sh 负责。
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: T_HEAD_PPU_ENABLED
# REQUIRES: k8s_deploy
# 说明:
#   · 默认只预检, **不自动改节点内核驱动/不自动装 SDK**。确认 runfile 与目标内核匹配后,
#     在 cluster.conf 打开 T_HEAD_PPU_INSTALL_KMD=true / T_HEAD_PPU_INSTALL_SDK=true,
#     模块才会从 T_HEAD_PPU_OFFLINE_DIR 取 runfile 安装。
#   · KMD 安装前置: /lib/modules/$(uname -r)/build、gcc、make、elfutils-libelf-devel 必须已就绪;
#     缺失时 fail-fast 并提示补离线内核头文件包, 不猜测内核矩阵。
#   · 节点探测顺序: ppu-smi -L → /dev/alixpu_ctl → PCI vendor 0x1ded; 允许在 KMD 尚未加载时
#     通过 PCI 发现卡, 以便首次安装 KMD。T_HEAD_PPU_NODES 显式指定时优先用该列表。
#   · T_HEAD_PPU_PLUGIN_SOURCE=native 时, SAIL SDK 是 device plugin 的硬依赖(需要 ppu-smi);
#     source=ack 时 SDK 只用于验证/运维, 缺失仅告警(ACK 镜像自带 PPU 用户态库)。
#   · 不卸载 KMD/SDK; 节点运行时不属于 cluster-teardown 的优雅覆盖范围。
# 数据源: cluster.conf (T_HEAD_PPU_* / NODES / SSH_KEY_NAME / SSH_USER)
# 用法:   sudo ./deploy-cluster.sh --enable t_head_ppu
#         sudo ./deploy-cluster.sh --steps t_head_ppu_runtime
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

[ "${T_HEAD_PPU_ENABLED:-false}" = "true" ] || { say "T_HEAD_PPU_ENABLED=false, 跳过 T-Head PPU 节点运行时准备"; exit 0; }

init_remote_kubectl || exit 1

OFFLINE_DIR="${T_HEAD_PPU_OFFLINE_DIR:-${REPO_ROOT}/deployments/offline-files/t-head-ppu}"
NODE_LABEL="${T_HEAD_PPU_NODE_LABEL:-ppu.example.com/device}"
BOARD_TYPE="${T_HEAD_PPU_BOARD_TYPE:-}"
SOURCE="${T_HEAD_PPU_PLUGIN_SOURCE:-ack}"
INSTALL_KMD="${T_HEAD_PPU_INSTALL_KMD:-false}"
INSTALL_SDK="${T_HEAD_PPU_INSTALL_SDK:-false}"
ALLOW_NO_DEVICE="${T_HEAD_PPU_ALLOW_NO_DEVICE:-false}"

_ssh_node() {
    local ip="$1" user="$2"; shift 2
    ssh -i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${user}@${ip}" "$@"
}

_scp_node() {
    local src="$1" ip="$2" user="$3" dst="$4"
    scp -i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${src}" "${user}@${ip}:${dst}"
}

_node_is_ppu() {
    local ip="$1" user="$2" out
    out="$(_ssh_node "${ip}" "${user}" '
        if command -v ppu-smi >/dev/null 2>&1 && ppu-smi -L >/dev/null 2>&1; then
            echo yes
        elif [ -x /usr/local/PPU_SDK/bin/ppu-smi ] && /usr/local/PPU_SDK/bin/ppu-smi -L >/dev/null 2>&1; then
            echo yes
        elif [ -e /dev/alixpu_ctl ]; then
            echo yes
        elif grep -qi "0x1ded" /sys/bus/pci/devices/*/vendor 2>/dev/null; then
            echo yes
        else
            echo no
        fi' 2>/dev/null || echo unknown)"
    printf '%s\n' "${out:-unknown}"
}

_has_device() {
    local ip="$1" user="$2"
    [ "$(_ssh_node "${ip}" "${user}" '[ -e /dev/alixpu_ctl ] && echo yes || echo no' 2>/dev/null || echo no)" = "yes" ]
}

_has_sdk() {
    local ip="$1" user="$2"
    [ "$(_ssh_node "${ip}" "${user}" 'if command -v ppu-smi >/dev/null 2>&1 || [ -x /usr/local/PPU_SDK/bin/ppu-smi ]; then echo yes; else echo no; fi' 2>/dev/null || echo no)" = "yes" ]
}

_find_runfile() {
    local var="$1" pattern="$2" explicit
    explicit="${!var:-}"
    if [ -n "${explicit}" ]; then
        printf '%s\n' "${explicit}"
        return 0
    fi
    ls -1 "${OFFLINE_DIR}"/${pattern} 2>/dev/null | head -1 || true
}

_install_kmd() {
    local ip="$1" user="$2" host="$3" runfile="$4"
    [ -f "${runfile}" ] || { err "KMD runfile 不存在: ${runfile}"; return 1; }
    say "  安装 KMD: ${host} ← $(basename "${runfile}")"
    local kh
    kh="$(_ssh_node "${ip}" "${user}" 'test -d /lib/modules/$(uname -r)/build && echo yes || echo no' 2>/dev/null || echo no)"
    if [ "${kh}" != "yes" ]; then
        err "  ${host} 缺少 /lib/modules/$(uname -r)/build, KMD 无法本地编译"
        err "  请先把 linux-headers-$(uname -r) / gcc / make / elfutils-libelf-devel 离线包装到该节点"
        return 1
    fi
    _scp_node "${runfile}" "${ip}" "${user}" "/tmp/t-head-ppu-kmd.run" || { err "  scp KMD 失败"; return 1; }
    local out="/tmp/t-head-ppu-kmd-${ip//[^A-Za-z0-9]/_}.log"
    if ! _ssh_node "${ip}" "${user}" 'sudo chmod +x /tmp/t-head-ppu-kmd.run && sudo /tmp/t-head-ppu-kmd.run' >"${out}" 2>&1; then
        tail -20 "${out}" | sed 's/^/    /' || true
        err "  KMD 安装失败(${host}); 完整日志: ${out}"
        return 1
    fi
    if ! grep -q 'install succeed' "${out}"; then
        tail -20 "${out}" | sed 's/^/    /' || true
        err "  KMD 安装未输出 install succeed(${host}); 完整日志: ${out}"
        return 1
    fi
    _ssh_node "${ip}" "${user}" 'sudo rm -f /tmp/t-head-ppu-kmd.run' >/dev/null 2>&1 || true
    ok "  KMD 安装成功: ${host}"
}

_install_sdk() {
    local ip="$1" user="$2" host="$3" runfile="$4"
    [ -f "${runfile}" ] || { err "SAIL SDK runfile 不存在: ${runfile}"; return 1; }
    say " 安装 SAIL SDK: ${host} ← $(basename "${runfile}")"
    _scp_node "${runfile}" "${ip}" "${user}" "/tmp/t-head-ppu-sdk.run" || { err "  scp SDK 失败"; return 1; }
    local out="/tmp/t-head-ppu-sdk-${ip//[^A-Za-z0-9]/_}.log"
    if ! _ssh_node "${ip}" "${user}" 'sudo chmod +x /tmp/t-head-ppu-sdk.run && sudo /tmp/t-head-ppu-sdk.run --silent' >"${out}" 2>&1; then
        tail -20 "${out}" | sed 's/^/    /' || true
        err "  SAIL SDK 安装失败(${host}); 完整日志: ${out}"
        return 1
    fi
    _ssh_node "${ip}" "${user}" 'sudo rm -f /tmp/t-head-ppu-sdk.run' >/dev/null 2>&1 || true
    ok "  SAIL SDK 安装成功: ${host}"
}

say "T-Head PPU 节点运行时预检(来源=${SOURCE}; 自动安装 KMD=${INSTALL_KMD}, SDK=${INSTALL_SDK})..."
say "  离线目录: ${OFFLINE_DIR}"

KMD_RUNFILE="$(_find_runfile T_HEAD_PPU_KMD_RUNFILE 'ppu-driver-*.run')"
SDK_RUNFILE="$(_find_runfile T_HEAD_PPU_SDK_RUNFILE 'ppu_*.run')"

FOUND=0
FAILED=0
for _line in "${NODES[@]:-}"; do
    [ -z "${_line}" ] && continue
    node_parse "${_line}"
    [ -n "${NODE_IP}" ] || continue

    _selected=1
    if [ -n "${T_HEAD_PPU_NODES:-}" ]; then
        _selected=0
        _want=" $(printf '%s' "${T_HEAD_PPU_NODES}" | tr ',' ' ') "
        case " ${_want} " in
            *" ${NODE_HOSTNAME} "*|*" ${NODE_IP} "*) _selected=1 ;;
        esac
    fi
    [ "${_selected}" = "1" ] || continue

    _user="$(ssh_user_for_ip "${NODE_IP}")"
    _state="$(_node_is_ppu "${NODE_IP}" "${_user}")"
    if [ "${_state}" != "yes" ]; then
        if [ -n "${T_HEAD_PPU_NODES:-}" ]; then
            warn "  节点 ${NODE_HOSTNAME}(${NODE_IP}) 未探测到 PPU(${_state}), 但它在 T_HEAD_PPU_NODES 中, 继续尝试"
        else
            vlog "  跳过非 PPU 节点 ${NODE_HOSTNAME}(${NODE_IP}): ${_state}"
            continue
        fi
    fi

    FOUND=$((FOUND + 1))
    say "  节点 ${NODE_HOSTNAME}(${NODE_IP})..."

    if ! _has_device "${NODE_IP}" "${_user}"; then
        if [ "${INSTALL_KMD}" = "true" ] && [ -n "${KMD_RUNFILE}" ]; then
            _install_kmd "${NODE_IP}" "${_user}" "${NODE_HOSTNAME}" "${KMD_RUNFILE}" || { FAILED=$((FAILED + 1)); continue; }
        else
            err "  ${NODE_HOSTNAME}: KMD 未加载(/dev/alixpu_ctl 不存在)"
            err "    处理: 把匹配内核的 ppu-driver-*.run 放入 ${OFFLINE_DIR}, 并设置 T_HEAD_PPU_INSTALL_KMD=true"
            FAILED=$((FAILED + 1)); continue
        fi
    fi
    if ! _has_device "${NODE_IP}" "${_user}"; then
        err "  ${NODE_HOSTNAME}: KMD 安装后 /dev/alixpu_ctl 仍不存在; 检查 dmesg/驱动版本/内核头文件"
        FAILED=$((FAILED + 1)); continue
    fi

    if ! _has_sdk "${NODE_IP}" "${_user}"; then
        if [ "${INSTALL_SDK}" = "true" ] && [ -n "${SDK_RUNFILE}" ]; then
            _install_sdk "${NODE_IP}" "${_user}" "${NODE_HOSTNAME}" "${SDK_RUNFILE}" || { FAILED=$((FAILED + 1)); continue; }
        elif [ "${SOURCE}" = "native" ]; then
            err "  ${NODE_HOSTNAME}: 自研插件需要 SAIL SDK(ppu-smi), 但节点上没有"
            err "    处理: 把 ppu_*.run 放入 ${OFFLINE_DIR}, 并设置 T_HEAD_PPU_INSTALL_SDK=true, 或改用 T_HEAD_PPU_PLUGIN_SOURCE=ack"
            FAILED=$((FAILED + 1)); continue
        else
            warn "  ${NODE_HOSTNAME}: 未发现 SAIL SDK(ppu-smi); ACK 镜像自带用户态库, 仅影响节点侧验证/运维"
        fi
    fi

    # 设备节点/驱动映射检查(插件用 /proc 做 UUID→minor 证明; 缺失时插件会退回 index/minor 候选)
    _devs="$(_ssh_node "${NODE_IP}" "${_user}" 'ls -1 /dev/alixpu_ppu* 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
    _proc="$(_ssh_node "${NODE_IP}" "${_user}" 'test -d /proc/driver/alixpu/ppus && echo yes || echo no' 2>/dev/null || echo no)"
    ok "  ${NODE_HOSTNAME}: 设备节点 ${_devs} 个; /proc/driver/alixpu/ppus=${_proc}"
    [ "${_proc}" = "yes" ] || warn "  ${NODE_HOSTNAME}: 无 /proc/driver/alixpu/ppus; 插件将退回 index/minor 设备节点候选"

    # 标签: fallback 选择标签 + 官方 board-type(供 ppu-scheduler-action 计算每卡配比)
    if SSH "${K} label node ${NODE_HOSTNAME} ${NODE_LABEL}=true --overwrite" >/dev/null 2>&1; then
        vlog "  已打标签 ${NODE_HOSTNAME}: ${NODE_LABEL}=true"
    else
        warn "  打标签失败: ${NODE_HOSTNAME} ${NODE_LABEL}=true(节点可能尚未加入集群)"
    fi
    if [ -n "${BOARD_TYPE}" ]; then
        SSH "${K} label node ${NODE_HOSTNAME} board-type=${BOARD_TYPE} --overwrite" >/dev/null 2>&1 \
            || warn "  打 board-type 标签失败: ${NODE_HOSTNAME}"
    fi
done

if [ "${FOUND}" -eq 0 ]; then
    if [ "${ALLOW_NO_DEVICE}" = "true" ]; then
        warn "未发现 PPU 节点(PCI 1ded/ppu-smi//dev/alixpu_ctl 均无), T_HEAD_PPU_ALLOW_NO_DEVICE=true → 跳过"
        exit 0
    fi
    err "未发现任何 PPU 节点。检查 T_HEAD_PPU_NODES 或节点 PCI 1ded/驱动状态。"
    err "若只是空跑流水线, 可临时设置 T_HEAD_PPU_ALLOW_NO_DEVICE=true。"
    exit 1
fi
if [ "${FAILED}" -gt 0 ]; then
    err "${FAILED}/${FOUND} 个 PPU 节点运行时准备失败; 修复后重跑 --steps t_head_ppu_runtime"
    exit 1
fi

ok "T-Head PPU 节点运行时准备完成: ${FOUND} 个节点; 来源=${SOURCE}"
echo "  下一步: sudo ./deploy-cluster.sh --steps t_head_ppu   # 部署 ACK/native device plugin"
