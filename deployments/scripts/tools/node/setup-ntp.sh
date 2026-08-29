#!/bin/bash
# ============================================================
# 集群节点 NTP 时间同步(在 kubespray 部署前保证各节点时钟一致)
#
# 权威时间源(默认: 第一个 master 节点):
#   · 多节点集群: 第一个 master 起 chrony 服务端(local stratum + 可选 NTP_UPSTREAM 公网上游),
#     其他 master/worker 作为 chrony/timesyncd 客户端指向第一个 master;
#   · **不再用 installer 所在节点(宿主机 HOST_PHYS_IP)作 NTP 服务器** —— 部署机可能在 NAT 后/跨网段,
#     节点无法可靠访问; 以集群内第一个 master 为权威更稳。
#   · 单节点集群(仅 1 个 master + 0 个 worker): 无跨节点时间同步需求, **跳过 NTP**。
#   · 显式 NTP_SERVER 仍可覆盖(用户指定权威时间源, 如公司内 NTP)。
#   · 应用时对偏差 >1s 的节点一次性 date -s @权威epoch 硬对齐(即使 NTP 传输失败也保证部署时刻一致)
#   · 校验: 各节点与权威(第一个 master)偏差 ≤ NTP_MAX_OFFSET_MS, 超限退出码 1 → 部署在 kubespray 前中止
# 用法:
#   sudo ./setup-ntp.sh            # apply: 首master chrony服务端 + 各节点配置 + 硬对齐 + 校验(幂等)
#   sudo ./setup-ntp.sh --check    # 仅校验当前时钟偏差(零写入)
#   sudo ./setup-ntp.sh --delete   # 关闭节点时间同步服务(幂等)
# 兼容: ONLY_HOSTS(部署框架 / modules/02_k8s/05_k8s_ntp.sh / scale 传入, 只处理指定节点)
# 数据源: config/cluster.conf (NTP_ENABLED/NTP_SERVER/NTP_UPSTREAM/NTP_ALLOW/NTP_MAX_OFFSET_MS/NODES)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

ACTION="${1:-apply}"
case "${ACTION}" in
    apply|--check|--delete) : ;;
    *) err "用法: $0 [apply|--check|--delete]"; exit 1 ;;
esac

[ "${NTP_ENABLED:-1}" = "1" ] || { warn "NTP_ENABLED=0, 跳过时间同步(不推荐, k8s/etcd 对时钟偏差敏感)"; exit 0; }
[ "$(id -u)" -eq 0 ] || { err "需要 root 权限: sudo $0 ${ACTION}"; exit 1; }

# ---------------- 节点解析(ip:user:pw:hostname) ----------------
NODE_ENTRIES=()
FIRST_MASTER_IP=""
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    node_parse "${line}"
    [ -n "${NODE_IP}" ] && [ -n "${NODE_USER}" ] || continue
    NODE_ENTRIES+=("${NODE_IP}:${NODE_USER}:${NODE_PW}:${NODE_HOSTNAME}")
    [ -z "${FIRST_MASTER_IP:-}" ] && [ "${NODE_ROLE}" = "master" ] && FIRST_MASTER_IP="${NODE_IP}"
done
[ "${#NODE_ENTRIES[@]}" -gt 0 ] || { err "cluster.conf NODES 为空"; exit 1; }
[ -n "${FIRST_MASTER_IP:-}" ] || { err "cluster.conf 中无 master 节点"; exit 1; }

# ---------------- 单节点判定: 仅 1 个 master 且 0 个 worker → 跳过 NTP ----------------
# (与 gen-inventory.sh 的 SINGLE_NODE 判定一致; 单节点无跨节点时间同步需求)
node_entries_count() {   # <role> → 该角色节点数
    local role="$1" n=0 line
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        [ "${NODE_ROLE}" = "${role}" ] && n=$((n+1))
    done
    echo "${n}"
}
MASTER_CNT=$(node_entries_count master)
WORKER_CNT=$(node_entries_count worker)
if [ "${MASTER_CNT}" -eq 1 ] && [ "${WORKER_CNT}" -eq 0 ]; then
    say "单节点集群(1 个 master, 0 个 worker), 无跨节点时间同步需求, 跳过 NTP 同步"
    exit 0
fi

# 权威时间源 = 显式 NTP_SERVER, 否则第一个 master(不再用宿主机 HOST_PHYS_IP)
NTP_AUTHORITY="${NTP_SERVER:-${FIRST_MASTER_IP}}"
NTP_MAX_OFFSET_MS="${NTP_MAX_OFFSET_MS:-2000}"

say "NTP 时间同步(权威=${NTP_AUTHORITY}${NTP_SERVER:+[NTP_SERVER]}${NTP_SERVER:+[首master]}, 动作=${ACTION}, 阈值=${NTP_MAX_OFFSET_MS}ms) ..."

# ---------------- SSH 助手(与 deploy-registry.sh 一致: 密钥优先, 密码回退) ----------------
SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
SSH_OPTS=(-i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8)

# 在节点以 root 执行单条命令(<ip> <user> <pw> <remote cmd...>)
node_cmd() {
    local ip="$1" u="$2" pw="$3"; shift 3
    local full="sudo $*"
    if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${u}@${ip}" "$full" 2>/dev/null; then return 0; fi
    [ -n "${pw}" ] || return 1
    SSHPASS="${pw}" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8 \
        "${u}@${ip}" "echo '${pw}' | sudo -S -p '' $*"
}

# 复制本地脚本到节点(<local> <ip> <user> <pw> <remote_path>)
node_scp() {
    local l="$1" ip="$2" u="$3" pw="$4" r="$5"
    if scp "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=8 "$l" "${u}@${ip}:${r}" 2>/dev/null; then return 0; fi
    [ -n "${pw}" ] || return 1
    SSHPASS="${pw}" sshpass -e scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8 "$l" "${u}@${ip}:${r}"
}

# ---------- 解析节点列表(ip:user:pw:hostname) ----------
NODE_ENTRIES=()
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    node_parse "${line}"
    [ -n "${NODE_IP}" ] && [ -n "${NODE_USER}" ] || continue
    NODE_ENTRIES+=("${NODE_IP}:${NODE_USER}:${NODE_PW}:${NODE_HOSTNAME}")
done
[ "${#NODE_ENTRIES[@]}" -gt 0 ] || { err "cluster.conf NODES 为空"; exit 1; }

# ---------------- 第一个 master chrony 权威服务端配置(仅 apply 且未显式 NTP_SERVER 时) ----------------
# 不再用宿主机(installer 节点)作权威; 改由第一个 master 起 chrony 服务端,
# 其他节点作为客户端指向它。首 master 本身: 有 NTP_UPSTREAM 则同步公网上游,
# 否则 local stratum 10 离线兜底。
master_chrony_setup() {
    [ -z "${NTP_SERVER:-}" ] || return 0   # 显式 NTP_SERVER 时, 首 master 作为普通客户端, 不额外起服务端
    local m_ip m_user m_pw
    m_ip="${FIRST_MASTER_IP}"
    for e in "${NODE_ENTRIES[@]:-}"; do
        local ip rest u pw
        ip="${e%%:*}"; rest="${e#*:}"; u="${rest%%:*}"; rest="${rest#*:}"; pw="${rest%%:*}"
        [ "${ip}" = "${m_ip}" ] && { m_user="${u}"; m_pw="${pw}"; break; }
    done
    [ -n "${m_user:-}" ] || { warn "未找到第一个 master(${m_ip}) 连接信息, 跳过其 chrony 服务端配置"; return 0; }

    say "配置第一个 master ${m_ip} 为 NTP 权威服务端(local stratum + allow 集群网段) ..."
    local MASTER_CONF="# === cubestack-managed ===\n"
    [ -n "${NTP_UPSTREAM:-}" ] && MASTER_CONF+="${NTP_UPSTREAM}\n"
    MASTER_CONF+="local stratum 10\n"
    # NTP_ALLOW 独立于虚拟/裸金属网络: 默认空=仅本机; 多子网节点需显式填节点所在网段
    for net in ${NTP_ALLOW:-}; do
        [ -n "${net}" ] && MASTER_CONF+="allow ${net}\n"
    done
    MASTER_CONF+="driftfile /var/lib/chrony/drift\nmakestep 1.0 3\nrtcsync\nlogdir /var/log/chrony\n"

    # 在首 master 写 chrony 配置并重启(有 chrony 用 chrony; 无则 chronyd 直拉)
    node_cmd "${m_ip}" "${m_user}" "${m_pw}" \
        "bash -c 'cat > /etc/chrony/chrony.conf <<EOF
${MASTER_CONF}EOF
systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true
systemctl enable chrony >/dev/null 2>&1 || true
systemctl restart chrony >/dev/null 2>&1 || systemctl restart chronyd >/dev/null 2>&1 || true
chronyc -a makestep >/dev/null 2>&1 || true'" >/dev/null 2>&1 \
        && ok "  第一个 master ${m_ip} chrony 服务端已就绪" \
        || warn "  第一个 master ${m_ip} chrony 服务端配置失败(仍以一次性 date 硬对齐兜底)"
}

# ---------------- 生成节点侧脚本(占位符经 sed 替换, 防止宿主展开节点变量) ----------------
# 注意: 硬对齐基准 HOST_MS 由外层(apply)传入 —— 已改为「权威(首 master / NTP_SERVER)的 epoch」,
# 不再用宿主机(installer)时钟。
NODE_SCRIPT="$(mktemp)"
REMOTE_SCRIPT="/tmp/cubestack-ntp-node.sh"
cat > "${NODE_SCRIPT}" <<'EOF'
#!/bin/bash
# Auto-generated by setup-ntp.sh — do not edit
set -u
MODE="${1:-apply}"
SERVER="__AUTHORITY__"
HOST_MS="${2:-0}"
CHRONY_OK=0   # 1=chrony 已即时精调成功(跳过易引入误差的一次性 date 覆盖)

if [ "${MODE}" = "delete" ]; then
    systemctl disable --now chrony chronyd systemd-timesyncd >/dev/null 2>&1 || true
    timedatectl set-ntp false >/dev/null 2>&1 || true
    exit 0
fi

if [ -n "${SERVER}" ]; then
    if command -v chronyd >/dev/null 2>&1; then
        # chrony 客户端(VM 黄金镜像已预装)
        systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true
        cat > /etc/chrony/chrony.conf <<CFG
# === cubestack-managed ===
server ${SERVER} iburst
__UPSTREAM_LINE__
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
CFG
        systemctl enable chrony >/dev/null 2>&1 || true
        systemctl restart chrony >/dev/null 2>&1 || systemctl restart chronyd >/dev/null 2>&1 || true
        chronyc -a makestep >/dev/null 2>&1 && CHRONY_OK=1 || CHRONY_OK=0
    else
        # 裸金属(bm): 无 chrony 包 → systemd-timesyncd 客户端
        sed -i '/^NTP=/d' /etc/systemd/timesyncd.conf 2>/dev/null || true
        printf '\n[Time]\nNTP=%s\n' "${SERVER}" >> /etc/systemd/timesyncd.conf
        timedatectl set-ntp true >/dev/null 2>&1 || true
        systemctl restart systemd-timesyncd >/dev/null 2>&1 || true
    fi
fi

# 一次性硬对齐: 仅当 chrony 未能即时精调(makestep 失败/无 chrony)时,
# 用权威时钟 epoch 兜底覆盖偏差 >1s 的时钟。注意 HOST_MS 采集于连接建立之前(含网络延迟),
# 直接 date 覆盖会引入与延迟等量的虚假偏差, 故不得用于干扰正常同步的时钟。
if [ "${CHRONY_OK}" != "1" ]; then
    NODE_MS="$(date +%s%3N)"
    OFF=$(( NODE_MS - HOST_MS ))
    if [ "${OFF#-}" -gt 1000 ]; then
        date -s "@$(( HOST_MS / 1000 ))" >/dev/null 2>&1 && echo "date-stepped-by-${OFF}ms" || echo "date-step-failed"
    fi
fi

# 返回最终 epoch(ms)
date +%s%3N
EOF
chmod +x "${NODE_SCRIPT}"
sed -i "s|__AUTHORITY__|${NTP_AUTHORITY}|g" "${NODE_SCRIPT}"
if [ -n "${NTP_UPSTREAM:-}" ]; then
    sed -i "s|__UPSTREAM_LINE__|${NTP_UPSTREAM}|g" "${NODE_SCRIPT}"
else
    sed -i "/__UPSTREAM_LINE__/d" "${NODE_SCRIPT}"
fi

# 读取单节点时钟偏差(3 样本取中位数, 过滤 SSH RTT/单次波动; 已在宿主侧做中点半程补偿)
# 权威基准: 第一个 master(或显式 NTP_SERVER)的时钟, 不再用宿主机(installer)时钟。
# <ip> <user> <pw> → stdout: 偏差ms(绝对值), 全部样本读取失败输出 -1
clock_offset() {
    local ip="$1" u="$2" pw="$3"
    local hb ha node_ms s samples=() vals
    for _ in 1 2 3; do
        hb="$(date +%s%3N)"
        node_ms="$(node_cmd "${ip}" "${u}" "${pw}" "date +%s%3N" 2>/dev/null || true)"
        ha="$(date +%s%3N)"
        [ -z "${node_ms:-}" ] && continue
        # 权威时钟: 显式 NTP_SERVER 用其 epoch; 否则用首 master(权威)epoch
        local auth_ms
        if [ -n "${NTP_SERVER:-}" ]; then
            auth_ms="$(node_cmd "${NTP_SERVER}" "${u}" "${pw}" "date +%s%3N" 2>/dev/null || true)"
        else
            auth_ms="$(node_cmd "${FIRST_MASTER_IP}" "${u}" "${pw}" "date +%s%3N" 2>/dev/null || true)"
        fi
        [ -z "${auth_ms:-}" ] && continue
        s=$(( node_ms - auth_ms )); [ "${s}" -lt 0 ] && s=$(( -s ))
        samples+=("${s}")
    done
    [ "${#samples[@]}" -eq 0 ] && { echo -1; return; }
    vals=($(printf '%s\n' "${samples[@]}" | sort -n))
    echo "${vals[$(( ${#vals[@]} / 2 ))]}"
}

# ---------------- 校验全节点与权威的时钟偏差(所有模式共用; 超限 → exit 1) ----------------
# apply 模式下 AUTO_SYNC_ON_FAIL=1: 超限节点自动重新下发同步(重对齐)并复测一次,
# 吸收部署高峰期的瞬时波动(见 apply 硬对齐注释: 过期的权威时间戳/chrony 收敛窗口);
# --check 模式保持零写入, 超限直接失败。
# 权威基准 = 第一个 master(或显式 NTP_SERVER), 不再用宿主机(installer)。
verify_clocks() {
    say "校验各节点与权威(${NTP_AUTHORITY})时钟偏差(阈值 ${NTP_MAX_OFFSET_MS}ms) ..."
    local FAIL=0 FAIL_LIST=""
    for e in "${NODE_ENTRIES[@]:-}"; do
        local ip rest u pw hn
        ip="${e%%:*}"; rest="${e#*:}"; u="${rest%%:*}"; rest="${rest#*:}"; pw="${rest%%:*}"; rest="${rest#*:}"; hn="${rest%%:*}"
        node_matches "${hn}" || continue
        off="$(clock_offset "${ip}" "${u}" "${pw}")"
        if [ "${off}" -eq -1 ]; then
            warn "  ${hn}(${ip}) 无法读取时钟(SSH/sudo 失败?)"
            FAIL=1; FAIL_LIST="${FAIL_LIST}${hn} "
            continue
        fi
        if [ "${off}" -gt "${NTP_MAX_OFFSET_MS}" ]; then
            if [ "${AUTO_SYNC_ON_FAIL:-0}" = "1" ]; then
                warn "  ${hn}(${ip}) 偏差 ${off}ms ✗(>${NTP_MAX_OFFSET_MS}ms), 自动重对齐并复测 ..."
                local hms
                hms="$(date +%s%3N)"
                if node_scp "${NODE_SCRIPT}" "${ip}" "${u}" "${pw}" "${REMOTE_SCRIPT}" \
                    && node_cmd "${ip}" "${u}" "${pw}" "bash ${REMOTE_SCRIPT} apply ${hms}" >/dev/null 2>&1; then
                    sleep 1
                    off="$(clock_offset "${ip}" "${u}" "${pw}")"
                fi
                if [ "${off}" -eq -1 ] || [ "${off}" -gt "${NTP_MAX_OFFSET_MS}" ]; then
                    warn "  ${hn}(${ip}) 复测仍偏差 ${off}ms ✗(>${NTP_MAX_OFFSET_MS}ms)"
                    FAIL=1; FAIL_LIST="${FAIL_LIST}${hn} "
                else
                    ok "  ${hn}(${ip}) 自动重对齐后偏差 ${off}ms ✓"
                fi
            else
                warn "  ${hn}(${ip}) 偏差 ${off}ms ✗(>${NTP_MAX_OFFSET_MS}ms)"
                FAIL=1; FAIL_LIST="${FAIL_LIST}${hn} "
            fi
        else
            ok "  ${hn}(${ip}) 偏差 ${off}ms ✓"
        fi
    done
    if [ "${FAIL}" = "1" ]; then
        err "时钟偏差超限: ${FAIL_LIST}(阈值 ${NTP_MAX_OFFSET_MS}ms); 请修复时间源/网络后重跑本步骤, 避免 k8s/etcd 时间敏感故障"
        return 1
    fi
    ok "全节点时钟一致(≤${NTP_MAX_OFFSET_MS}ms)"
}

# ---------------- 主流程 ----------------
case "${ACTION}" in
    --check)
        verify_clocks || exit $?
        ;;
    --delete)
        say "关闭节点时间同步服务(chrony/timesyncd, 幂等) ..."
        for e in "${NODE_ENTRIES[@]:-}"; do
            ip="${e%%:*}"; rest="${e#*:}"; u="${rest%%:*}"; rest="${rest#*:}"; pw="${rest%%:*}"; rest="${rest#*:}"; hn="${rest%%:*}"
            node_matches "${hn}" || continue
            if node_scp "${NODE_SCRIPT}" "${ip}" "${u}" "${pw}" "${REMOTE_SCRIPT}" \
                && node_cmd "${ip}" "${u}" "${pw}" "bash ${REMOTE_SCRIPT} delete" >/dev/null 2>&1; then
                ok "  ${hn}(${ip}) 时间同步已关闭"
            else
                warn "  ${hn}(${ip}) 关闭失败(检查密钥/密码/连通性)"
            fi
        done
        ;;
    apply)
        master_chrony_setup
        say "下发并执行节点时间同步(chrony/timesyncd + 一次性硬对齐, 权威=${NTP_AUTHORITY}) ..."
        for e in "${NODE_ENTRIES[@]:-}"; do
            ip="${e%%:*}"; rest="${e#*:}"; u="${rest%%:*}"; rest="${rest#*:}"; pw="${rest%%:*}"; rest="${rest#*:}"; hn="${rest%%:*}"
            node_matches "${hn}" || continue
            # 权威 = 第一个 master(或显式 NTP_SERVER); 首 master 自身若未显式 NTP_SERVER,
            # 已是权威服务端, 不再向自己同步(跳过), 其余节点作为客户端指向它。
            if [ -z "${NTP_SERVER:-}" ] && [ "${ip}" = "${FIRST_MASTER_IP}" ]; then
                ok "  ${hn}(${ip}) 为 NTP 权威(首 master), 跳过自我同步"
                continue
            fi
            # 一次性硬对齐基准: 权威时钟 epoch。显式 NTP_SERVER 时用其 epoch;
            # 否则用首 master 的 epoch(权威), 不再用宿主机(installer)时钟。
            if [ -n "${NTP_SERVER:-}" ]; then
                HOST_MS="$(node_cmd "${NTP_SERVER}" "${u}" "${pw}" "date +%s%3N" 2>/dev/null || date +%s%3N)"
            else
                HOST_MS="$(node_cmd "${FIRST_MASTER_IP}" "${u}" "${pw}" "date +%s%3N" 2>/dev/null || date +%s%3N)"
            fi
            if node_scp "${NODE_SCRIPT}" "${ip}" "${u}" "${pw}" "${REMOTE_SCRIPT}"; then
                node_cmd "${ip}" "${u}" "${pw}" "bash ${REMOTE_SCRIPT} apply ${HOST_MS}" >/dev/null 2>&1 \
                    && ok "  ${hn}(${ip}) 时间已同步" || warn "  ${hn}(${ip}) 配置失败(检查密钥/密码)"
            else
                warn "  ${hn}(${ip}) 无法上传脚本(检查密钥/密码)"
            fi
        done
        echo "---------------------------------------------"
        AUTO_SYNC_ON_FAIL=1 verify_clocks || exit $?
        rm -f "${NODE_SCRIPT}"
        ;;
esac

ok "NTP 时间同步步骤完成"