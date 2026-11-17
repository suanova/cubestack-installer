#!/bin/bash
# ============================================================
# pre-install-check.sh — 安装前节点环境检查(只读, 不改动任何节点)
#
# 检查对象: cluster.conf NODES 中的 master/worker(支持 --only / ONLY_HOSTS 过滤)
# 检查项:
#   · SSH: 部署密钥免密可用; 密钥不通时用节点密码回退验证(只验证, 不写配置)
#         主机密钥校验(2026-11-17 CodeRabbit): 不再 no + /dev/null。
#         · 持久 known_hosts: ${PRE_INSTALL_SSH_KNOWN_HOSTS:-${SSH_KEY_DIR}/cubestack_known_hosts}
#           —— 密钥探测 accept-new(首次记录, 之后换钥拒绝);
#         · 密码回退恒 StrictHostKeyChecking=yes, 且使用**独立的密码认证 known_hosts**
#           ${PRE_INSTALL_SSH_PASSWORD_KNOWN_HOSTS:-${SSH_KEY_DIR}/cubestack_known_hosts_password}
#           —— 该文件只由人工核对节点指纹后写入, 本工具**从不自动写入**;
#           密钥探测 accept-new 学到的 key 即使出现/持久化在第一个文件里, 也不能授权密码回退
#           (防止"冒充者拒绝密钥认证却先被 accept-new 记录 → 下次重试把密码发给冒充者");
#           未受信 → 关键项失败, 给出人工核对指纹 + 写入该文件的处置。
#         可覆盖: PRE_INSTALL_SSH_HOST_KEY_CHECKING(accept-new|yes, 默认 accept-new)
#                 PRE_INSTALL_SSH_KNOWN_HOSTS(默认 ${SSH_KEY_DIR}/cubestack_known_hosts)
#                 PRE_INSTALL_SSH_PASSWORD_KNOWN_HOSTS(默认 ${SSH_KEY_DIR}/cubestack_known_hosts_password)
#   · sudo: 非 root 用户要求 sudo -n 可用; root 用户要求节点存在 sudo
#           (与 modules/02_k8s/01_k8s_passwordless.sh 同一口径)
#   · chronyd: NTP_ENABLED≠0 时要求 chronyd 已安装/运行;
#              客户端/有上游的权威还要求 Leap status 已同步且偏差 ≤ NTP_MAX_OFFSET_MS;
#              本地权威(首 master, local stratum, 无 NTP_SERVER/NTP_UPSTREAM)只要求服务运行
#              (它本身就是时间源, setup-ntp.sh 以 stratum 10 作为就绪判据);
#              无 chrony 的节点允许 systemd-timesyncd 回退(已启用且已同步)
#              (单节点集群与 NTP_ENABLED=0 一样跳过同步检查)
#   · 资源容量: CPU 核数、内存、/var/lib 可用空间
#
# 分级(2026-11-17 用户口径):
#   关键项(SSH/sudo/chronyd/CPU/内存/磁盘下限)任一失败 → 退出码 1(模块随之中止部署)
#   建议项(master 内存推荐值 / 磁盘推荐值 / chronyd 开机自启 / 密码回退)只告警
#
# 用法:
#   ./pre-install-check.sh [--check] [--only <host>]
#   ./pre-install-check.sh --help
# 数据源: deployments/config/cluster.conf + cluster.defaults.conf
# 可覆盖阈值(写在 cluster.conf 或环境变量):
#   PRE_INSTALL_MIN_CPU(默认 2)          PRE_INSTALL_MIN_MEM_MB(默认 2048)
#   PRE_INSTALL_MASTER_MIN_MEM_MB(默认 4096, 建议)
#   PRE_INSTALL_MIN_DISK_GB(默认 10)     PRE_INSTALL_RECOMMENDED_DISK_GB(默认 20, 建议)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"

usage() {
    cat <<'EOF'
用法: pre-install-check.sh [--check] [--only <host>]

只读检查 master/worker 安装前环境(SSH/sudo/chronyd/CPU/内存/磁盘)。
  --check        执行检查(默认动作; 保留该参数便于模块显式调用)
  --only <host>  只检查指定节点(全名精确或短名后缀, 可逗号分隔)
  -h, --help     显示本帮助

退出码: 0=通过(可含建议项告警); 1=存在关键项失败(部署应中止)
EOF
}

ONLY_ARG=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --check)    : ;;
        --only)     ONLY_ARG="${2:?--only 需要节点名}"; shift ;;
        --only=*)   ONLY_ARG="${1#*=}" ;;
        -h|--help)  usage; exit 0 ;;
        *)          err "未知参数: $1"; usage; exit 2 ;;
    esac
    shift
done
[ -n "${ONLY_ARG}" ] && ONLY_HOSTS="${ONLY_ARG}"

load_config

# ---------------- 阈值(关键项 / 建议项) ----------------
_num() {  # <value> <default> → 正整数或默认值
    local v="${1:-}" d="$2"
    [[ "${v}" =~ ^[0-9]+$ ]] && echo "${v}" || echo "${d}"
}
MIN_CPU="$(_num "${PRE_INSTALL_MIN_CPU:-}" 2)"
MIN_MEM_MB="$(_num "${PRE_INSTALL_MIN_MEM_MB:-}" 2048)"
MASTER_MIN_MEM_MB="$(_num "${PRE_INSTALL_MASTER_MIN_MEM_MB:-}" 4096)"
MIN_DISK_GB="$(_num "${PRE_INSTALL_MIN_DISK_GB:-}" 10)"
REC_DISK_GB="$(_num "${PRE_INSTALL_RECOMMENDED_DISK_GB:-}" 20)"
NTP_MAX_OFFSET_MS="$(_num "${NTP_MAX_OFFSET_MS:-}" 2000)"

# NTP 是否要求同步: NTP_ENABLED=0 或单节点集群 → 不要求(与 setup-ntp.sh 同口径)
NTP_REQUIRED=1
case "$(printf '%s' "${NTP_ENABLED:-1}" | tr '[:upper:]' '[:lower:]')" in
    0|false|no|off) NTP_REQUIRED=0 ;;
esac

# ---------------- SSH 连接口径(与 setup-passwordless.sh 一致) ----------------
SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
# 主机密钥策略(与 node-net-guard.sh 同口径; 本工具的**密码回退**更严格):
#   · 密钥探测: accept-new(首次记录、之后换钥拒绝) 或 yes(仅接受已预置 key);
#   · 密码回退: 恒 yes —— 只向已受信 host key 发送密码, 不接受首次 TOFU/未认证探测。
SSH_HKC="${PRE_INSTALL_SSH_HOST_KEY_CHECKING:-accept-new}"
case "${SSH_HKC}" in
    accept-new|yes) : ;;
    *)
        err "PRE_INSTALL_SSH_HOST_KEY_CHECKING 非法: '${SSH_HKC}'(accept-new|yes)"
        exit 1
        ;;
esac
SSH_KNOWN_HOSTS="${PRE_INSTALL_SSH_KNOWN_HOSTS:-${SSH_KEY_DIR:-${HOME}/.ssh}/cubestack_known_hosts}"
# 密码认证专用 known_hosts: 只放人工核对指纹后批准的 key; 本工具从不自动写入
# (accept-new 学到的 key 不能授权密码回退, 否则失败的密钥探测会把冒充者 key 持久化)。
SSH_PW_KNOWN_HOSTS="${PRE_INSTALL_SSH_PASSWORD_KNOWN_HOSTS:-${SSH_KEY_DIR:-${HOME}/.ssh}/cubestack_known_hosts_password}"
mkdir -p "$(dirname "${SSH_KNOWN_HOSTS}")" "$(dirname "${SSH_PW_KNOWN_HOSTS}")" 2>/dev/null || true
SSH_BASE_OPTS=(-i "${SSH_KEY}" -F /dev/null -o IdentitiesOnly=yes -o LogLevel=ERROR
    -o StrictHostKeyChecking="${SSH_HKC}" -o UserKnownHostsFile="${SSH_KNOWN_HOSTS}" -o ConnectTimeout=8)
SSH_PW_OPTS=(-F /dev/null -o LogLevel=ERROR -o StrictHostKeyChecking=yes
    -o UserKnownHostsFile="${SSH_PW_KNOWN_HOSTS}"
    -o ConnectTimeout=8 -o PreferredAuthentications=password -o PubkeyAuthentication=no
    -o NumberOfPasswordPrompts=1)

# 当前节点(node_parse 设置 NODE_IP/NODE_USER/NODE_PW)
AUTH=""
_key_ok() {
    ssh "${SSH_BASE_OPTS[@]}" -o BatchMode=yes "${NODE_USER}@${NODE_IP}" true 2>/dev/null
}
# 本次运行开始前, 该节点 host key 是否已在**密码认证专用** known_hosts 中受信。
# 只认人工批准的文件; 密钥探测 accept-new 自动学到的 key(SSH_KNOWN_HOSTS)不能授权密码回退。
_host_key_pretrusted() {
    [ -s "${SSH_PW_KNOWN_HOSTS}" ] \
        && ssh-keygen -F "${NODE_IP}" -f "${SSH_PW_KNOWN_HOSTS}" >/dev/null 2>&1
}
_pw_ok() {
    SSHPASS="${NODE_PW}" sshpass -e ssh "${SSH_PW_OPTS[@]}" "${NODE_USER}@${NODE_IP}" true 2>/dev/null
}
# 远端探针: 用选定认证方式执行 stdin 脚本
_remote_probe() {
    case "${AUTH}" in
        key) ssh "${SSH_BASE_OPTS[@]}" -o BatchMode=yes "${NODE_USER}@${NODE_IP}" 'bash -s' ;;
        pw)  SSHPASS="${NODE_PW}" sshpass -e ssh "${SSH_PW_OPTS[@]}" "${NODE_USER}@${NODE_IP}" 'bash -s' ;;
        *)   return 1 ;;
    esac
}

# ---------------- 节点清单 / 单节点判定 ----------------
[ -n "${NODES[*]:-}" ] || { err "cluster.conf NODES 为空"; exit 1; }
MASTER_CNT=0; WORKER_CNT=0; FIRST_MASTER_IP=""
for _line in "${NODES[@]:-}"; do
    [ -z "${_line}" ] && continue
    node_parse "${_line}"
    case "${NODE_ROLE}" in
        master) MASTER_CNT=$((MASTER_CNT + 1)); [ -z "${FIRST_MASTER_IP}" ] && FIRST_MASTER_IP="${NODE_IP}" ;;
        worker) WORKER_CNT=$((WORKER_CNT + 1)) ;;
    esac
done
unset _line
if [ "${MASTER_CNT}" -eq 0 ]; then
    err "cluster.conf NODES 中没有 master 节点"
    exit 1
fi
if [ "${MASTER_CNT}" -eq 1 ] && [ "${WORKER_CNT}" -eq 0 ] && [ "${NTP_REQUIRED}" = "1" ]; then
    say "单节点集群(1 master / 0 worker): chronyd 同步检查自动跳过"
    NTP_REQUIRED=0
fi

# ---------------- 检查统计 ----------------
CRIT=0
ADV=0
CHECKED=0
_crit() { err "$*"; CRIT=$((CRIT + 1)); }
_adv()  { warn "$*";  ADV=$((ADV + 1)); }
_pass() { ok "$*"; }

say "安装前环境检查(SSH/sudo/chronyd/资源容量; 阈值: CPU≥${MIN_CPU}核, 内存≥${MIN_MEM_MB}MB, /var/lib≥${MIN_DISK_GB}GB) ..."

for _line in "${NODES[@]:-}"; do
    [ -z "${_line}" ] && continue
    node_parse "${_line}"
    case "${NODE_ROLE}" in master|worker) ;; *) continue ;; esac
    node_matches "${NODE_HOSTNAME}" || continue

    _label="${NODE_HOSTNAME:-${NODE_IP}}(${NODE_IP}, user=${NODE_USER}, ${NODE_ROLE})"
    CHECKED=$((CHECKED + 1))
    AUTH=""
    echo ""
    say "节点: ${_label}"

    # ---- ① SSH: 密钥优先, 密码回退(密码只发给本次运行前已受信 host key 的节点) ----
    HOST_KEY_PRETRUSTED=0
    _host_key_pretrusted && HOST_KEY_PRETRUSTED=1
    if [ -f "${SSH_KEY}" ] && _key_ok; then
        AUTH="key"
        _pass "  SSH: 部署密钥免密可用"
    elif [ -n "${NODE_PW}" ]; then
        if [ "${HOST_KEY_PRETRUSTED}" != "1" ]; then
            _crit "  SSH: 免密不可用; 密码回退已阻止 —— 节点 ${NODE_IP} 的 host key 未在密码认证 known_hosts 中人工批准"
            _crit "    文件: ${SSH_PW_KNOWN_HOSTS}(密钥探测自动学到的 ${SSH_KNOWN_HOSTS} 不能授权密码回退)"
            _crit "    处置: 人工核对节点指纹后执行 ssh-keyscan -H ${NODE_IP} >> ${SSH_PW_KNOWN_HOSTS}(或先配置 SSH 免密)"
            continue
        fi
        if ! command -v sshpass >/dev/null 2>&1; then
            _crit "  SSH: 免密不可用, 且缺少 sshpass 无法用密码回退(安装: apt-get install -y sshpass)"
            continue
        fi
        if _pw_ok; then
            AUTH="pw"
            _adv "  SSH: 可达但免密未配置(host key 已受信, 密码回退可用; k8s_passwordless 会在安装前补齐密钥)"
        else
            _crit "  SSH: 不可达或认证失败(host key 已受信; 密钥 ${SSH_KEY} + 节点密码均失败)"
            continue
        fi
    else
        _crit "  SSH: 免密不可用且未配置节点密码(检查 SSH_DEFAULT_PASSWORD / NODES 密码与 sshd)"
        continue
    fi

    # ---- ② 采集远端指标(单次连接) ----
    if ! _out="$(_remote_probe <<'REMOTE'
set -u
echo "CPU=$(nproc 2>/dev/null || echo 0)"
echo "MEM_MB=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
echo "DISK_GB=$(df -Pk /var/lib 2>/dev/null | awk 'NR==2{printf "%d", $4/1024/1024}')"
if command -v chronyd >/dev/null 2>&1; then echo "CHRONYD_BIN=yes"; else echo "CHRONYD_BIN=no"; fi
ACT="unknown"
for u in chrony chronyd; do
  a="$(systemctl is-active "$u" 2>/dev/null || true)"
  [ -n "$a" ] || continue
  [ "$ACT" = "unknown" ] && ACT="$a"
  [ "$a" = "active" ] && { ACT=active; break; }
done
echo "CHRONY_ACTIVE=$ACT"
EN="unknown"
for u in chrony chronyd; do
  e="$(systemctl is-enabled "$u" 2>/dev/null || true)"
  [ -n "$e" ] || continue
  EN="$e"
  [ "$e" = "enabled" ] && break
done
echo "CHRONY_ENABLED=$EN"
TSA="$(systemctl is-active systemd-timesyncd 2>/dev/null || true)"
echo "TIMESYNCD_ACTIVE=${TSA:-unknown}"
TSS="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
if [ -z "$TSS" ]; then
  TSS="$(timedatectl status 2>/dev/null | awk -F: '/System clock synchronized/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}')"
fi
echo "TIMESYNCD_SYNC=${TSS:-unknown}"
TRACK="$(chronyc -n tracking 2>/dev/null || sudo -n chronyc -n tracking 2>/dev/null || true)"
OFF="$(printf '%s\n' "$TRACK" | awk -F: '/^System time/{gsub(/^[ \t]+/,"",$2); split($2,a," "); if (a[1] ~ /^-?[0-9]+([.][0-9]+)?$/) {v=a[1]; if (v < 0) v = -v; printf "%.3f", v*1000}}')"
echo "CHRONY_OFFSET_MS=$OFF"
LEAP="$(printf '%s\n' "$TRACK" | awk -F: '/^Leap status/{gsub(/^[ \t]+/,"",$2); print $2}')"
echo "CHRONY_LEAP=$LEAP"
if command -v sudo >/dev/null 2>&1; then echo "HAS_SUDO=yes"; else echo "HAS_SUDO=no"; fi
if [ "$(id -u)" = "0" ]; then
  echo "SUDO_OK=root"
elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  echo "SUDO_OK=yes"
else
  echo "SUDO_OK=no"
fi
REMOTE
    )"; then
        _crit "  远端探针执行失败(SSH 连接中断或远端 bash 不可用)"
        continue
    fi

    _get() { printf '%s\n' "${_out}" | sed -n "s/^$1=//p" | head -1; }
    CPU="$(_get CPU)";        CPU="${CPU:-0}"
    MEM_MB="$(_get MEM_MB)";  MEM_MB="${MEM_MB:-0}"
    DISK_GB="$(_get DISK_GB)"; DISK_GB="${DISK_GB:-0}"
    CHRONYD_BIN="$(_get CHRONYD_BIN)"
    CHRONY_ACTIVE="$(_get CHRONY_ACTIVE)"
    CHRONY_ENABLED="$(_get CHRONY_ENABLED)"
    CHRONY_OFFSET_MS="$(_get CHRONY_OFFSET_MS)"
    CHRONY_LEAP="$(_get CHRONY_LEAP)"
    TIMESYNCD_ACTIVE="$(_get TIMESYNCD_ACTIVE)"
    TIMESYNCD_SYNC="$(_get TIMESYNCD_SYNC)"
    HAS_SUDO="$(_get HAS_SUDO)"
    SUDO_OK="$(_get SUDO_OK)"
    unset _get

    # ---- ③ sudo ----
    if [ "${SUDO_OK}" = "root" ]; then
        if [ "${HAS_SUDO}" = "yes" ]; then
            _pass "  sudo: root 用户, 节点 sudo 可用"
        else
            _crit "  sudo: root 用户但节点缺少 sudo(部署远端管理命令仍经 sudo; 安装 sudo 或改用 SSH_USER=ubuntu)"
        fi
    elif [ "${SUDO_OK}" = "yes" ]; then
        _pass "  sudo: ${NODE_USER} 免密 sudo 可用"
    else
        _crit "  sudo: ${NODE_USER} 无法免密 sudo(sudo -n true 失败; 配置 /etc/sudoers.d/90-cubestack NOPASSWD)"
    fi

    # ---- ④ 时间同步(chronyd; 无 chrony 的裸金属节点允许 systemd-timesyncd 回退) ----
    if [ "${NTP_REQUIRED}" = "1" ]; then
        if [ "${CHRONYD_BIN}" != "yes" ]; then
            if [ "${TIMESYNCD_ACTIVE}" = "active" ] && [ "${TIMESYNCD_SYNC}" = "yes" ]; then
                _adv "  chronyd: 未安装; 使用 systemd-timesyncd 且已同步(项目支持的裸金属回退)"
            else
                _crit "  chronyd: 未安装, 且 systemd-timesyncd 未就绪(active=${TIMESYNCD_ACTIVE:-unknown}, sync=${TIMESYNCD_SYNC:-unknown})"
            fi
        else
            if [ "${CHRONY_ACTIVE}" != "active" ]; then
                _crit "  chronyd: 服务未运行(state=${CHRONY_ACTIVE:-unknown}; systemctl start chrony)"
            elif [ -z "${NTP_SERVER:-}" ] && [ -z "${NTP_UPSTREAM:-}" ] \
                 && [ "${NODE_IP}" = "${FIRST_MASTER_IP}" ]; then
                # 本地权威(首 master, local stratum, 无上游): 它本身就是时间源,
                # 不要求自身处于 Normal/可跟踪状态; setup-ntp.sh 以 stratum 10 作为就绪判据。
                _pass "  chronyd: 本地权威(无上游, local stratum)服务运行中; 跳过 Leap/偏差检查"
            else
                # 客户端/有上游的权威: 必须先确认已同步(Leap status),
                # 否则 "Not synchronised + 很小的 System time" 会被误判为通过。
                _leap_lc="$(printf '%s' "${CHRONY_LEAP:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
                if [ -z "${_leap_lc}" ]; then
                    _crit "  chronyd: 无法读取 Leap status(chronyc tracking 无输出/权限不足)"
                elif [ "${_leap_lc}" = "notsynchronised" ] || [ "${_leap_lc}" = "notsynchronized" ]; then
                    _crit "  chronyd: 未同步(Leap status=${CHRONY_LEAP}); 检查 chronyc sources/tracking"
                elif [ "${_leap_lc}" != "normal" ] \
                     && [ "${_leap_lc}" != "insertsecond" ] && [ "${_leap_lc}" != "deletesecond" ]; then
                    _crit "  chronyd: Leap status=${CHRONY_LEAP} 不是已同步状态"
                elif [ -z "${CHRONY_OFFSET_MS}" ]; then
                    _crit "  chronyd: 服务在运行但无法读取 chronyc 偏差(Leap=${CHRONY_LEAP:-unknown}; 检查 chronyc tracking)"
                elif awk -v o="${CHRONY_OFFSET_MS}" -v m="${NTP_MAX_OFFSET_MS}" 'BEGIN{exit !(o + 0 > m + 0)}'; then
                    _crit "  chronyd: 偏差 ${CHRONY_OFFSET_MS}ms > 阈值 ${NTP_MAX_OFFSET_MS}ms"
                else
                    _pass "  chronyd: 服务运行中, Leap=${CHRONY_LEAP}, 偏差 ${CHRONY_OFFSET_MS}ms ≤ ${NTP_MAX_OFFSET_MS}ms"
                fi
            fi
            case "${CHRONY_ENABLED}" in
                enabled|enabled-runtime) : ;;
                *) _adv "  chronyd: 未设置开机自启(state=${CHRONY_ENABLED:-unknown}; systemctl enable chrony)" ;;
            esac
        fi
    else
        _adv "  chronyd: 跳过同步检查(NTP_ENABLED=${NTP_ENABLED:-1} / 单节点集群)"
    fi

    # ---- ⑤ 资源容量 ----
    if [ "${CPU}" -lt "${MIN_CPU}" ] 2>/dev/null; then
        _crit "  CPU: ${CPU} 核 < 最低要求 ${MIN_CPU} 核"
    else
        _pass "  CPU: ${CPU} 核"
    fi

    if [ "${MEM_MB}" -lt "${MIN_MEM_MB}" ] 2>/dev/null; then
        _crit "  内存: ${MEM_MB}MB < 最低要求 ${MIN_MEM_MB}MB"
    else
        _pass "  内存: ${MEM_MB}MB"
    fi
    if [ "${NODE_ROLE}" = "master" ] && [ "${MEM_MB}" -lt "${MASTER_MIN_MEM_MB}" ] 2>/dev/null; then
        _adv "  内存: master 建议 ≥ ${MASTER_MIN_MEM_MB}MB(当前 ${MEM_MB}MB)"
    fi

    if [ "${DISK_GB}" -lt "${MIN_DISK_GB}" ] 2>/dev/null; then
        _crit "  /var/lib: 可用 ${DISK_GB}GB < 最低要求 ${MIN_DISK_GB}GB"
    else
        _pass "  /var/lib: 可用 ${DISK_GB}GB"
    fi
    if [ "${DISK_GB}" -lt "${REC_DISK_GB}" ] 2>/dev/null; then
        _adv "  /var/lib: 建议 ≥ ${REC_DISK_GB}GB(当前 ${DISK_GB}GB; 视镜像/etcd 数据量而定)"
    fi
done

echo ""
if [ "${CHECKED}" -eq 0 ]; then
    err "没有匹配的节点可检查(检查 cluster.conf NODES 与 --only 过滤)"
    exit 1
fi
if [ "${CRIT}" -gt 0 ]; then
    err "安装前环境检查未通过: ${CRIT} 个关键项, ${ADV} 个建议项(共 ${CHECKED} 台节点)"
    err "  修复后重试; 确需跳过本步: sudo ./deploy-cluster.sh --skip pre_install_check ..."
    exit 1
fi
ok "安装前环境检查通过: ${CHECKED} 台节点, ${ADV} 个建议项(不阻断部署)"
exit 0
