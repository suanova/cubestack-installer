#!/bin/bash
# ============================================================
# CubeStack 公共库: 统一配置加载 + 通用工具函数
# 所有 deployments/scripts/*.sh 在 set -euo pipefail 之后 source 本文件
# 配置统一来源: deployments/config/cluster.conf
# 优先级: 环境变量 > 配置文件 > 内置默认值(内置默认值在配置文件中声明)
# 说明: 本库不执行任何宿主修改,仅供各脚本复用
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"          # deployments/scripts/ → 根目录

# 真实用户 home(sudo bash 下 HOME=/root 会出错, 用 SUDO_USER 定位真实用户)
REAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
REAL_HOME="$(getent passwd "${REAL_USER}" 2>/dev/null | cut -d: -f6)"
[ -n "${REAL_HOME}" ] || REAL_HOME="${HOME}"
export REAL_HOME REAL_USER
# 统一 HOME 为真实用户(sudo bash 下 HOME=/root, 会导致配置里 ${HOME}/.ssh 等解析错误)
[ -n "${REAL_HOME}" ] && export HOME="${REAL_HOME}"

# ---------------- 配置文件: 统一读取 cluster.conf ----------------
CLUSTER_CONF="${CLUSTER_CONF:-${REPO_ROOT}/deployments/config/cluster.conf}"
export CLUSTER_CONF

# ---------------- 集群名(固定默认, 单集群) ----------------
# 默认集群名 cubestack-cluster, 用于 inventory/repository 目录与日志命名; 环境变量可覆盖
CLUSTER_NAME="${CLUSTER_NAME:-cubestack-cluster}"
export CLUSTER_NAME

# ---------------- 宿主机物理 IP 自动检测 ----------------
# 不 hardcode: 自动检测宿主机物理网卡 IP(排除虚拟网桥 docker0/privbr0/virbr0 等)
detect_host_ip() {
    local ip=""
    # 方法1: 默认路由出口源 IP(最可靠)
    ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    [ -n "${ip}" ] && echo "${ip}" && return 0
    # 方法2: hostname -I 过滤虚拟网桥/保留地址
    ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -vE '^(10\.244\.|10\.245\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.168\.122\.|127\.|169\.254\.)' | head -1)"
    [ -n "${ip}" ] && echo "${ip}" && return 0
    # 方法3: 枚举物理网卡 IP
    ip="$(ip -4 addr show 2>/dev/null | grep -oP 'inet \K[0-9.]+' | grep -vE '^(10\.244\.|10\.245\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.168\.122\.|127\.|169\.254\.)' | head -1)"
    [ -n "${ip}" ] && echo "${ip}" || echo "127.0.0.1"
}

# ---------------- 断点续跑: 状态文件 ----------------
# 统一的状态文件,记录已完成的任务阶段
# 用法: save_state <phase> <value>; get_state <phase>; clear_state
STATE_FILE="${REPO_ROOT}/deployments/config/.deploy.state"
save_state() {
    local key="$1" val="$2"
    # 移除旧记录再写入(避免重复)
    grep -vF "${key}=" "${STATE_FILE}" 2>/dev/null > "${STATE_FILE}.tmp" || true
    echo "${key}=${val}" >> "${STATE_FILE}.tmp"
    mv "${STATE_FILE}.tmp" "${STATE_FILE}"
}
get_state() {
    grep -F "$1=" "${STATE_FILE}" 2>/dev/null | tail -1 | cut -d= -f2-
}
clear_state() {
    rm -f "${STATE_FILE}"
}
# 检查是否所有 phases 都已完成 → 上次部署成功
is_state_completed() {
    local phases=("$@")
    for p in "${phases[@]}"; do
        [ "$(get_state "$p")" = "done" ] || return 1
    done
    return 0
}

# ---------------- 输出函数(同时写入日志文件) ----------------
# 日志文件路径: 设置 LOG_FILE 后, 所有输出同时写入该文件
# 用法: export LOG_FILE=/tmp/deploy.log; sudo ./deploy-cluster.sh ...
# 日志开关: LOG_VERBOSE=1 显示详细日志(默认) / 0 仅显示关键信息
LOG_VERBOSE="${LOG_VERBOSE:-1}"
_log_file() { [ -n "${LOG_FILE:-}" ] && echo -e "$*" >> "${LOG_FILE}" 2>/dev/null || true; }
say()  { local m="→  $*"; echo -e "\033[36m${m}\033[0m"; _log_file "${m}"; }
ok()   { local m="✅ $*"; echo -e "\033[32m${m}\033[0m"; _log_file "${m}"; }
warn() { local m="⚠  $*"; echo -e "\033[33m${m}\033[0m"; _log_file "${m}"; }
err()  { local m="【错误】$*"; echo -e "\033[31m${m}\033[0m" >&2; _log_file "${m}"; }
vlog() { [ "${LOG_VERBOSE}" = "1" ] && { local m="[DEBUG] $*"; echo -e "\033[90m${m}\033[0m"; _log_file "${m}"; } || true; }

# ---------------- 统一配置加载 ----------------
# 环境变量优先: 配置文件内使用 ${VAR:-default},已导出的环境变量不会被覆盖
load_config() {
    if [ -f "${CLUSTER_CONF}" ]; then
        # shellcheck disable=SC1090
        source "${CLUSTER_CONF}"
    else
        warn "未找到配置文件 ${CLUSTER_CONF},使用内置默认值"
        warn "建议: cp ${REPO_ROOT}/deployments/config/cluster.conf.example ${CLUSTER_CONF}"
    fi
    # 宿主机物理 IP 自动检测(不 hardcode): 仅当未显式设置或仍是占位符时覆盖
    if [ -z "${HOST_PHYS_IP:-}" ] || [ "${HOST_PHYS_IP}" = "CHANGE_ME" ]; then
        HOST_PHYS_IP="$(detect_host_ip)"
        export HOST_PHYS_IP
        vlog "自动检测宿主机物理 IP: ${HOST_PHYS_IP}"
    fi
    # NAT 模式同网段: APISERVER_ADDRESS 默认取第一个 master IP
    if [ -z "${APISERVER_ADDRESS:-}" ] && [ "${NET_MODE:-nat}" = "nat" ]; then
        for line in "${NODES[@]:-}"; do
            [ -z "${line}" ] && continue
            IFS=, read -r role hostname ip mac mem cpu disk user pw node_type <<<"${line}"
            [ "${role}" = "master" ] && { APISERVER_ADDRESS="${ip}"; export APISERVER_ADDRESS; vlog "NAT 模式自动设 APISERVER_ADDRESS=第一个master: ${ip}"; break; }
        done
    fi
    # 全局派生变量(由 cluster.conf 变量派生, 各脚本直接引用, 不各自设置本地变量):
    #   API_IP       API 入口地址 = APISERVER_ADDRESS(HAProxy IP / NAT 第一个 master), 回退 HOST_PHYS_IP(桥接=宿主机物理 IP)
    #   API_DOMAIN   API Server 域名(跨网段统一入口), 默认 k8s-api.nova.local
    API_IP="${API_IP:-${APISERVER_ADDRESS:-${HOST_PHYS_IP}}}"
    API_DOMAIN="${API_DOMAIN:-${APISERVER_DOMAIN:-k8s-api.nova.local}}"
    export API_IP API_DOMAIN
}

# ---------------- 指定节点过滤(--only) ----------------
# 仅在 ONLY_HOSTS(逗号分隔, 由 deploy-cluster.sh --only 收集)非空时过滤
# --only 过滤: 支持全名精确匹配或短名后缀匹配
# (如 --only worker02 可匹配 cubestack-k8s-worker02)
node_matches() {
    [ -z "${ONLY_HOSTS:-}" ] && return 0
    local h
    for h in ${ONLY_HOSTS//,/ }; do
        [ "$h" = "$1" ] && return 0
        case "$1" in
            *"-${h}") return 0 ;;   # 短名后缀: cubestack-k8s-worker02 匹配 worker02
        esac
    done
    return 1
}

# SSH 端口探测(免认证,仅确认就绪)
ssh_port_open() { timeout 3 bash -c "echo > /dev/tcp/$1/22" 2>/dev/null; }

# ---------------- IP / CIDR 工具 ----------------
ip2int() { local a b c d; IFS=. read -r a b c d <<<"$1"; echo $(( (a<<24) + (b<<16) + (c<<8) + d )); }
int2ip() { local n=$1; echo "$(( (n>>24)&255 )).$(( (n>>16)&255 )).$(( (n>>8)&255 )).$(( n&255 ))"; }
mask2int() { local n=0 p; for p in $(echo "$1" | tr '.' ' '); do n=$(( (n<<8) | p )); done; echo $(( n & 0xFFFFFFFF )); }
# <IP> <CIDR> → 退出码 0=在网段内
cidr_contains() {
    local net="${2%%/*}" prefix="${2#*/}" ip_int net_int mask
    ip_int=$(ip2int "$1"); net_int=$(ip2int "$net")
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    [ $(( ip_int & mask )) -eq $(( net_int & mask )) ]
}

# ---------------- MAC 生成 ----------------
# 未显式指定 MAC 时,按主机名确定性生成(幂等,重复部署 MAC 不变)
# <hostname> → 52:54:00:xx:xx:xx
mac_from_name() {
    local hex
    hex="$(printf '%s' "$1" | md5sum | cut -c1-6)"
    echo "52:54:00:${hex:0:2}:${hex:2:2}:${hex:4:2}"
}

# ---------------- 节点解析 ----------------
# 解析 NODES 配置行为字段,输出以 IFS=, 分隔的字段
# 格式: role,hostname,ip,mac,mem_g,cpu,disk_g,ssh_user,ssh_password
# mac: 显式或 "-"(自动生成); ssh_password: 显式或 "-"(用角色默认)
node_password() { # <role> <password>
    [ "$1" = "worker" ] && { [ -n "$2" ] && [ "$2" != "-" ] && echo "$2" || echo "${WORKER_SSH_PASSWORD:-}"; } \
                      || { [ -n "$2" ] && [ "$2" != "-" ] && echo "$2" || echo "${SSH_DEFAULT_PASSWORD:-}"; }
}

# ---------------- 节点类型判断(vm=虚拟机 / bm=裸金属) ----------------
# NODES 第10字段 node_type 显式指定节点类型; 省略时回退推断:
#   master 默认视为虚拟机; 其余按是否有 VM 参数(mac 非 "-" 且 内存>0)推断
# 用法: node_is_vm <role> <mac> <mem_g> <node_type> → 退出码 0=是虚拟机
node_is_vm() {
    local role="$1" mac="$2" mem="$3" ntype="$4"
    case "${ntype}" in
        vm) return 0 ;;
        bm) return 1 ;;
    esac
    # 未显式指定类型: 回退推断
    [ "${role}" = "master" ] && return 0
    [ -n "${mac}" ] && [ "${mac}" != "-" ] && [ "${mem:-0}" -gt 0 ]
}

# 获取根目录(供其它脚本引用路径)
repo_root() { echo "${REPO_ROOT}"; }

# ---------------- 节点注册到 cluster.conf ----------------
# 将节点信息写入 config/cluster.conf 的 NODES 数组(幂等)
# 用法: register_node_to_conf <role> <hostname> <ip> <mac> <mem> <cpu> <disk> <user> <password>
register_node_to_conf() {
    local role="$1" hostname="$2" ip="$3" mac="$4" mem="$5" cpu="$6" disk="$7" user="$8" pw="$9"
    local conf_file="${CLUSTER_CONF:-${REPO_ROOT}/config/cluster.conf}"

    [ -f "${conf_file}" ] || { warn "cluster.conf 不存在: ${conf_file}, 跳过注册 ${hostname}"; return 0; }
    [ -w "${conf_file}" ] || { warn "cluster.conf 不可写: ${conf_file}, 跳过注册 ${hostname}"; return 0; }

    # 已存在则跳过(幂等)
    if grep -qF "${hostname}," "${conf_file}" 2>/dev/null; then
        echo -e "\033[33m⚠ ${hostname} 已在 ${conf_file} 中注册,跳过\033[0m"
        return 0
    fi

    local new_entry="\"${role},${hostname},${ip},${mac},${mem},${cpu},${disk},${user},${pw}\""
    echo -e "\033[36m→ 注册节点到 ${conf_file}: ${new_entry}\033[0m"

    # 在 NODES=( 区块的结尾 ) 前插入新条目(awk 实现, 可靠)
    awk -v entry="  ${new_entry}" '
        /^NODES=\(/ { in_nodes=1 }
        in_nodes && /^\)/ {
            print entry
            in_nodes=0
        }
        { print }
    ' "${conf_file}" > "${conf_file}.tmp" && mv "${conf_file}.tmp" "${conf_file}"

    echo -e "\033[32m✅ ${hostname} 已注册到 cluster.conf\033[0m"
}

# ---------------- 附加组件通用工具 ----------------

# 返回第一个 master 节点 IP(附加组件执行 kubectl 的入口)
# 用法: FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
first_master_ip() {
    local line role hostname ip _rest
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        IFS=, read -r role hostname ip _rest <<<"${line}"
        if [ "${role}" = "master" ] && [ -n "${ip}" ]; then
            echo "${ip}"
            return 0
        fi
    done
    return 1
}

# 伪代码占位执行框架: 用于尚未实现真实逻辑的附加组件模块。
# 用法: addon_stub <模块key> <步骤数组名>
#   步骤数组格式: "步骤描述|要执行的命令(伪代码)" 每行一项
# 行为:
#   · ADDON_STUB_EXEC=1 时: 真实执行伪代码命令(用于实现验证/模拟)
#   · 否则: 仅打印伪代码步骤(占位, 不执行), 返回 0 表示"流程可继续"
#   · DEPLOY_MODE=sim 时额外 sleep 模拟耗时
addon_stub() {
    local key="$1" arr_name="$2"
    local -n _steps="${arr_name}"  # bash 4.3+ nameref
    local _desc _cmd _i=0
    say "▶ [${key}] 伪代码占位实现(尚未接入真实逻辑, ADDON_STUB_EXEC=1 可试执行)..."
    for _line in "${_steps[@]:-}"; do
        [ -z "${_line}" ] && continue
        _i=$((_i + 1))
        _desc="${_line%%|*}"
        _cmd="${_line#*|}"
        say "  ${_i}. ${_desc}"
        say "     \$ ${_cmd}"
        if [ "${ADDON_STUB_EXEC:-0}" = "1" ]; then
            # 试执行模式: 忽略失败继续
            bash -c "${_cmd}" 2>/dev/null || warn "     [占位试执行失败,忽略]"
        elif [ "${DEPLOY_MODE:-auto}" = "sim" ]; then
            sleep 0.5
        fi
    done
    say "◼ [${key}] 占位流程执行完毕(如需真实安装, 请按 TODO 实现模块逻辑)"
    return 0
}