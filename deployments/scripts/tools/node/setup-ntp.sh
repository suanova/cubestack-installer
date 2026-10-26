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
#   · 节点→权威 IP 可达性预检(2026-10-14 扩容事故新增): ping 不通即硬失败并给出明确诊断 ——
#     节点与权威不在可达网段时, 硬对齐/重对齐都不可能真正兜住, 早失败早定位(禁 ICMP 环境可 NTP_REACH_CHECK=0)
#   · 校验: 各节点与权威(第一个 master)偏差 ≤ NTP_MAX_OFFSET_MS, 超限退出码 1 → 部署在 kubespray 前中止
# 用法:
#   sudo ./setup-ntp.sh            # apply: 首master chrony服务端 + 各节点配置 + 硬对齐 + 校验(幂等)
#   sudo ./setup-ntp.sh --check    # 仅校验当前时钟偏差(零写入)
#   sudo ./setup-ntp.sh --delete   # 关闭节点时间同步服务(幂等)
# 兼容: ONLY_HOSTS(部署框架 / modules/02_k8s/05_k8s_ntp.sh / scale 传入, 只处理指定节点)
# 数据源: config/cluster.conf (NTP_ENABLED/NTP_SERVER/NTP_UPSTREAM/NTP_ALLOW/NTP_MAX_OFFSET_MS/NTP_REACH_CHECK/NODES)
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
# ★ 2026-10-14: 节点→权威 IP 可达性预检开关(默认开)。仅"环境禁节点间 ICMP 但 NTP(UDP123) 可达"
#   这类特殊口径才置 0(先人工确认再关); 关闭后回到旧行为(靠硬对齐兜底 + 偏差校验收尾)。
NTP_REACH_CHECK="${NTP_REACH_CHECK:-1}"

say "NTP 时间同步(权威=${NTP_AUTHORITY}${NTP_SERVER:+[NTP_SERVER]}${NTP_SERVER:+[首master]}, 动作=${ACTION}, 阈值=${NTP_MAX_OFFSET_MS}ms) ..."

# ---------------- SSH 助手(与 deploy-registry.sh 一致: 密钥优先, 密码回退) ----------------
SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
SSH_OPTS=(-i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8)

# 在节点以 root 执行单条命令(<ip> <user> <pw> <remote cmd...>)
# ★ 2026-10-26: root 用户不再套 sudo。实机 master02 在全量部署负载下
#   `sudo date` 延迟约 4s, 被 clock_offset 误判成"时钟偏差 4s"; root 本身已有权限,
#   去掉 sudo 同时消除 PAM/DNS/终端等延迟源。
node_cmd() {
    local ip="$1" u="$2" pw="$3"; shift 3
    local full
    if [ "${u}" = "root" ]; then
        full="$*"
    else
        full="sudo $*"
    fi
    if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${u}@${ip}" "$full" 2>/dev/null; then return 0; fi
    [ -n "${pw}" ] || return 1
    if [ "${u}" = "root" ]; then
        SSHPASS="${pw}" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8 \
            "${u}@${ip}" "$*"
    else
        SSHPASS="${pw}" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8 \
            "${u}@${ip}" "echo '${pw}' | sudo -S -p '' $*"
    fi
}

# 节点 sudo 是否可用(root 直接可用; 其他用户要求免密或密码回退可执行 sudo true)
node_sudo_ready() {
    local ip="$1" u="$2" pw="$3"
    [ "${u}" = "root" ] && return 0
    node_cmd "${ip}" "${u}" "${pw}" "true" >/dev/null 2>&1
}

# 复制本地脚本到节点(<local> <ip> <user> <pw> <remote_path>)
# ★ 上传前先清陈旧目标(2026-10-15 root 安装实机根因): 目标是**固定 /tmp 名** —— 若文件由
#   "其他用户"的历史运行遗留(实机: 昨天 ubuntu 运行留下 ubuntu:ubuntu 的文件), 今天新用户的
#   scp(O_CREAT|O_TRUNC 打开既有文件)会被 sticky /tmp 的 fs.protected_regular=2 拒为
#   "Permission denied"(实测 root 也不例外: ①拒 ②新路径过 ③先删再传过)。删除后 scp 新建
#   的文件属主=本次用户, 后续运行同类安全。
node_scp() {
    local l="$1" ip="$2" u="$3" pw="$4" r="$5"
    if [[ "${r}" == */ ]]; then
        node_cmd "${ip}" "${u}" "${pw}" "rm -rf '${r}' && mkdir -p '${r}'" >/dev/null 2>&1 || true
    else
        node_cmd "${ip}" "${u}" "${pw}" "rm -f '${r}'" >/dev/null 2>&1 || true
    fi
    if scp "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=8 "$l" "${u}@${ip}:${r}" 2>/dev/null; then return 0; fi
    [ -n "${pw}" ] || return 1
    SSHPASS="${pw}" sshpass -e scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8 "$l" "${u}@${ip}:${r}"
}

# 节点→权威 IP 通路探测(<ip> <user> <pw>)。
# 返回码: 0=可达 / 1=SSH 通但 ping 权威不通 / 2=SSH 不通(节点本身连不上)。
# ★ 2026-10-14 扩容事故(worker13, VM 网络接入缺陷): 节点与权威完全无 IP 通路时, 旧行为是
#   反复"硬对齐 + 复测仍偏差超限"(6.5s→2.5s)的误导链, 完全掩盖真实故障。预检把它变成一条明确诊断。
# 口径: ping 有应答即算可达 —— 本平台 proxy-ARP fabric 上健康节点间 ICMP 实测可通(见 docs/troubleshooting.md §一.3);
#   若环境确属"仅禁 ICMP 而不禁 NTP", 置 NTP_REACH_CHECK=0 关闭本预检后重跑。
authority_reachable_from() {
    [ "${NTP_REACH_CHECK}" = "1" ] || return 0
    local ip="$1" u="$2" pw="$3"
    node_cmd "${ip}" "${u}" "${pw}" "true" >/dev/null 2>&1 || return 2
    node_cmd "${ip}" "${u}" "${pw}" "ping -n -c 2 -W 2 ${NTP_AUTHORITY} >/dev/null 2>&1" >/dev/null 2>&1
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

# 解析权威节点的 SSH 凭据(不能拿"当前被测节点"的 user/pw 去连权威 —— 节点独立密码时
# 会把权威采样读空/读慢, 进而把 SSH 延迟误判成时钟偏差)。
AUTH_USER="${SSH_USER:-ubuntu}"
AUTH_PW=""
resolve_authority_creds() {
    local e ip rest u pw
    AUTH_USER="${SSH_USER:-ubuntu}"; AUTH_PW=""
    for e in "${NODE_ENTRIES[@]:-}"; do
        ip="${e%%:*}"; [ "${ip}" = "${NTP_AUTHORITY}" ] || continue
        rest="${e#*:}"; u="${rest%%:*}"; rest="${rest#*:}"; pw="${rest%%:*}"
        AUTH_USER="${u}"; AUTH_PW="${pw}"; return 0
    done
}

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
    # 权限前置: 非 root 用户必须 sudo 可用, 否则后面的 cp/systemctl/chronyc 全部静默失败,
    # 最终只表现为"权威没起来"或客户端偏差超限, 排查方向会被带偏。
    if ! node_sudo_ready "${m_ip}" "${m_user}" "${m_pw}"; then
        err "第一个 master ${m_ip} 的 ${m_user} 用户 sudo 不可用 —— 请设 SSH_USER=root,"
        err "  或在节点配置 sudoers: echo '${m_user} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-cubestack"
        exit 1
    fi
    # ⚠ 配置用 scp 文件写入(真实换行), 不再用内联 heredoc —— 字面 \n 会把 chrony.conf 写坏
    local mconf_tmp mscript_tmp
    # ★ 2026-10-07 修复(离线环境权威缺 chrony 事故根因): VM 黄金镜像预装的 chrony 会被
    #   reconcile-node-packages.sh 的 systemd-timesyncd 修复包**互斥摘除**(apt 自动 remove,
    #   实测 09-30 各 master 全部中招), 而节点无外网 ⇒ 远程脚本 `apt-get install -y chrony`
    #   静默失败 ⇒ 权威不监听 123。解决: offline-files/os/packages/chrony/ 有 deb 则先**离线安装**
    #   (apt --no-download + Dir::Cache::archives), 仍失败才走 apt 在线兜底, 再失败硬报错。
    #   ⚠ 目录口径(2026-10-08): chrony 与其依赖闭包(含 libc6 等系统库 deb)**必须隔离在
    #   os/packages/chrony/ 子目录** —— os/packages 顶层是 reconcile 对账集(会被逐个装到全部
    #   节点), 闭包里的系统库一旦进对账集会被无差别顶版(09-28 libudev1 事故的同类风险)。
    local has_deb=0 deb
    NTP_DEB_DIR="${OFFLINE_FILES_ROOT}/os/packages/chrony"
    if [ -d "${NTP_DEB_DIR}" ]; then
        for deb in "${NTP_DEB_DIR}"/chrony_*.deb; do [ -f "${deb}" ] && { has_deb=1; break; }; done
        [ "${has_deb}" = "1" ] && say "  chrony 离线包: ${NTP_DEB_DIR}($(ls "${NTP_DEB_DIR}"/*.deb | wc -l) 个)"
    fi
    mconf_tmp="$(mktemp)"
    mscript_tmp="$(mktemp)"
    {
        echo "# === cubestack-managed ==="
        [ -n "${NTP_UPSTREAM:-}" ] && echo "${NTP_UPSTREAM}"
        echo "local stratum 10"
        # ★ allow 网段自动推导(2026-09-05 事故修复): NTP_ALLOW 为空时, 从 NODES 所有节点 IP
        #   推导所在网段(按 /16 粗粒度合并), 否则 chrony 只监听本机(local stratum 不对外),
        #   客户端永远连不上(^? Reach 0) → 时间偏差 0.5~1.2s 无法收敛。
        #   支持: 显式 NTP_ALLOW(覆盖) / 多子网(自动推导每个节点网段)。
        _allow_nets=()
        if [ -n "${NTP_ALLOW:-}" ]; then
            for net in ${NTP_ALLOW}; do _allow_nets+=("${net}"); done
        else
            for e in "${NODE_ENTRIES[@]:-}"; do
                local _nip _net
                _nip="${e%%:*}"
                case "${_nip}" in
                    *.*.*.*) _net="$(printf '%s' "${_nip}" | cut -d. -f1-2).0.0/16" ;;
                    *) continue ;;
                esac
                local _seen=0 _n2
                for _n2 in "${_allow_nets[@]:-}"; do [ "${_n2}" = "${_net}" ] && _seen=1; done
                [ "${_seen}" = "0" ] && _allow_nets+=("${_net}")
            done
        fi
        for net in "${_allow_nets[@]:-}"; do
            [ -n "${net}" ] && echo "allow ${net}"
        done
        echo "driftfile /var/lib/chrony/drift"
        echo "makestep 1 1"
        echo "rtcsync"
        echo "logdir /var/log/chrony"
    } > "${mconf_tmp}"
    # ★ 打印在重定向块外(say 走 stdout, 在 { } > 块内会被写进配置文件 → chrony 解析失败)
    [ "${#_allow_nets[@]}" -gt 0 ] && say "  chrony allow: ${_allow_nets[*]}(自动从 NODES 推导)"
    # ★ 2026-09-08 修复(权威不监听 123 事故根因): 配置+重启+自检全部放远程脚本, 经「单个 sudo bash」
    #   执行。旧实现把整条 && 链直接传给 node_cmd, 而 node_cmd 只给链的**第一个命令**(cp)加 sudo,
    #   后续 systemctl/chronyc 以普通用户执行 → 全部静默失败(`>/dev/null 2>&1 || true` 吞掉) →
    #   chrony 从未重启加载新配置 → 权威不监听 123 → 客户端全 Reach=0, 仅一次性 date 硬对齐兜底
    #   (偏差残留 ~1s, 超 2000ms 阈值即模块失败)。新版脚本内置自检(123 监听), 失败即硬失败。
    # 头部预挂载共享离线安装原语(lib-common::deb_install_remote_lib; 单一口径) + 执行体
    { deb_install_remote_lib; cat <<'EOF'
#!/bin/bash
# Auto-generated by setup-ntp.sh — master chrony authority setup(do not edit)
set -u
[ -f /tmp/cubestack-chrony.conf ] || { echo "MISSING-CONF"; exit 1; }
# chrony 缺失则自动安装: ① 离线 deb(offline-files/ntp/, 由 setup-ntp.sh 推入) ② apt 在线兜底。
# ★ 2026-10-07: 节点无外网时 apt 在线必失败, 旧实现 `|| true` 把错误静默吞掉 ⇒ 权威不监听 123,
#   客户端全 Reach=0, 模块只报一句"未监听 NTP 123"无从排查。现改为: 失败亮出 apt 输出, 再硬失败。
HAS_DEB="${1:-0}"
if ! command -v chronyd >/dev/null 2>&1; then
    # ★ 2026-10-14 三轮实机事故后重构: 离线安装统一走 lib-common::install_debs_offline
    #   (随本脚本头部预挂载; 口径单一事实来源 —— 预卸互斥提供者 / 已装即跳不升级 /
    #   批量 dpkg 失败逐包隔离 / 输出全程保留)。根因与禁令(禁止 apt --fix-broken)见该库注释。
    if [ "${HAS_DEB}" = "1" ] && ls /tmp/cubestack-ntp-debs/chrony_*.deb >/dev/null 2>&1; then
        echo "  [install] chrony 缺失 → 离线安装($(ls /tmp/cubestack-ntp-debs/*.deb 2>/dev/null | wc -l) 个 deb) ..."
        install_debs_offline /tmp/cubestack-ntp-debs chrony
        # 旧 apt 离线路径(健康节点兼容保留; 破损态下会被全局门禁拒绝, 无害)
        if ! command -v chronyd >/dev/null 2>&1; then
            _apt_log=/tmp/cubestack-ntp-apt.log
            if ! apt-get -o "Dir::Cache::archives=/tmp/cubestack-ntp-debs" --no-download -y \
                    --allow-downgrades install /tmp/cubestack-ntp-debs/chrony_*.deb >"${_apt_log}" 2>&1; then
                echo "  [install] apt 离线安装失败(见下, 转 apt 在线兜底):"
                tail -5 "${_apt_log}" | sed 's/^/      /'
            fi
        fi
    fi
    command -v chronyd >/dev/null 2>&1 || apt-get install -y chrony >/dev/null 2>&1 || true
fi
command -v chronyd >/dev/null 2>&1 || { echo "CHRONY-INSTALL-FAILED(离线 deb 缺失/依赖不满足且无外网)"; exit 1; }
cp /tmp/cubestack-chrony.conf /etc/chrony/chrony.conf
rm -f /tmp/cubestack-chrony.conf
systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true
systemctl enable chrony >/dev/null 2>&1 || true
systemctl restart chrony >/dev/null 2>&1 || systemctl restart chronyd >/dev/null 2>&1
sleep 2
chronyc -a makestep >/dev/null 2>&1 || true
# 自检: NTP 端口 123 监听(权威必须对外服务, 否则客户端全 Reach=0)
if ss -ulnp 2>/dev/null | grep -q ':123 '; then
    echo "NTP-LISTENING-OK"
else
    echo "NTP-LISTENING-FAIL"
    exit 1
fi
EOF
    } > "${mscript_tmp}"
    # 上传: ① chrony 配置 ② 远程脚本(必须先于执行; 2026-10-07 教训: 曾漏掉这两个 scp,
    #   节点跑的是上次失败的残留脚本 ⇒ MISSING-CONF)
    if ! node_scp "${mconf_tmp}" "${m_ip}" "${m_user}" "${m_pw}" "/tmp/cubestack-chrony.conf" >/dev/null 2>&1; then
        err "上传 cubestack-chrony.conf 到 ${m_ip} 失败, 停止 NTP 配置"
        rm -f "${mconf_tmp}" "${mscript_tmp}"
        exit 1
    fi
    if ! node_scp "${mscript_tmp}" "${m_ip}" "${m_user}" "${m_pw}" "/tmp/cubestack-chrony-master.sh" >/dev/null 2>&1; then
        err "上传 cubestack-chrony-master.sh 到 ${m_ip} 失败, 停止 NTP 配置"
        rm -f "${mconf_tmp}" "${mscript_tmp}"
        exit 1
    fi
    # 推离线 deb 到节点(有则推; scp 失败不致命 —— 远程脚本有在线兜底与硬失败)
    if [ "${has_deb}" = "1" ]; then
        node_cmd "${m_ip}" "${m_user}" "${m_pw}" "rm -rf /tmp/cubestack-ntp-debs && mkdir -p /tmp/cubestack-ntp-debs" >/dev/null 2>&1 || true
        for deb in "${NTP_DEB_DIR}"/*.deb; do
            [ -f "${deb}" ] || continue
            # ⚠ 目标必须写成**文件全路径**：node_scp 对以 / 结尾的目录目标会先
            #   rm -rf 整个目录再拷 —— 在循环里会把前一次推的 deb 全删掉, 最后只剩 1 个。
            node_scp "${deb}" "${m_ip}" "${m_user}" "${m_pw}" "/tmp/cubestack-ntp-debs/$(basename "${deb}")" >/dev/null 2>&1 || true
        done
    fi
    # 执行远程脚本并**保留输出**: 失败时打印诊断(tail)。旧实现 `>/dev/null 2>&1` 吞掉一切,
    # 只剩一句"未监听 NTP 123", 无从排查 —— 2026-10-07 教训。
    local _rout _mok
    _rout="$(node_cmd "${m_ip}" "${m_user}" "${m_pw}" "bash /tmp/cubestack-chrony-master.sh ${has_deb}" 2>&1)" && _mok=1 || _mok=0
    if [ "${_mok}" = "1" ]; then
        node_cmd "${m_ip}" "${m_user}" "${m_pw}" "rm -f /tmp/cubestack-chrony-master.sh" >/dev/null 2>&1 || true
        node_cmd "${m_ip}" "${m_user}" "${m_pw}" "rm -rf /tmp/cubestack-ntp-debs" >/dev/null 2>&1 || true
        # 二次确认(防自检误判): 无上游时权威必须 local stratum 10;
        # 有上游时允许已同步的任意 stratum(1-15), 但 Leap status 必须是 Normal。
        # `|| true`: node_cmd(ssh)一抖就会让管道非 0 → 赋值非 0 → set -e 结束模块;
        # 下面按空值走硬失败, 不再"warn 后继续"。
        _STRATUM="$(node_cmd "${m_ip}" "${m_user}" "${m_pw}" "chronyc tracking 2>/dev/null | awk '/Stratum/{print \$3}'" 2>/dev/null | tr -d ' \r' || true)"
        _LEAP="$(node_cmd "${m_ip}" "${m_user}" "${m_pw}" "chronyc tracking 2>/dev/null | awk -F: '/Leap status/{gsub(/^ +/,\"\",\$2); print \$2}'" 2>/dev/null | tr -d ' \r' || true)"
        _AUTH_READY=0
        if [ -n "${NTP_UPSTREAM:-}" ]; then
            if [ -n "${_STRATUM}" ] && [ "${_STRATUM}" -gt 0 ] 2>/dev/null && [ "${_LEAP}" = "Normal" ]; then
                _AUTH_READY=1
            fi
        else
            [ "${_STRATUM:-}" = "10" ] && _AUTH_READY=1
        fi
        if [ "${_AUTH_READY}" = "1" ]; then
            ok "  第一个 master ${m_ip} chrony 服务端已就绪(监听 123, stratum ${_STRATUM}${NTP_UPSTREAM:+, upstream})"
        else
            err "  第一个 master ${m_ip} chrony 未就绪: stratum=${_STRATUM:-?}, leap=${_LEAP:-?}(无上游时应为 stratum 10)"
            err "  诊断输出(chronyc/端口/journal):"
            node_cmd "${m_ip}" "${m_user}" "${m_pw}" \
                "chronyc tracking 2>&1; chronyc sources -v 2>&1; ss -lunp 2>/dev/null | grep ':123 ' || true; journalctl -u chrony -n 80 --no-pager 2>&1" 2>&1 \
                | grep -v '^Warning' | tail -40 | sed 's/^/      /' || true
            rm -f "${mconf_tmp}" "${mscript_tmp}"
            exit 1
        fi
    else
        err "第一个 master ${m_ip} chrony 服务端配置失败(未监听 NTP 123) —— 客户端将无法真正同步; 请检查后重跑本模块"
        printf '%s\n' "${_rout}" | grep -v '^Warning' | tail -12
        exit 1
    fi
    rm -f "${mconf_tmp}" "${mscript_tmp}"
}

# ---------------- 生成节点侧脚本(占位符经 sed 替换, 防止宿主展开节点变量) ----------------
# 注意: 硬对齐基准 HOST_MS 由外层(apply)传入 —— 已改为「权威(首 master / NTP_SERVER)的 epoch」,
# 不再用宿主机(installer)时钟。
NODE_SCRIPT="$(mktemp)"
REMOTE_SCRIPT="/tmp/cubestack-ntp-node.sh"
{
deb_install_remote_lib
cat <<'EOF'
#!/bin/bash
# Auto-generated by setup-ntp.sh — do not edit
set -u
MODE="${1:-apply}"
SERVER="__AUTHORITY__"
HOST_MS="${2:-0}"
HAS_DEB="${3:-0}"
CHRONY_OK=0   # 1=chrony 已即时精调成功(跳过易引入误差的一次性 date 覆盖)
DAEMON_OK=0   # 1=chrony 或 systemd-timesyncd 已 active(有持久时间服务)

if [ "${MODE}" = "delete" ]; then
    systemctl disable --now chrony chronyd systemd-timesyncd >/dev/null 2>&1 || true
    timedatectl set-ntp false >/dev/null 2>&1 || true
    exit 0
fi

if [ -n "${SERVER}" ]; then
    # ★ 2026-10-26: 客户端缺 chrony 时先从离线 deb 安装(与 authority 同源)。
    #   实机 master02/worker05-08 的黄金镜像没有 chrony, 旧脚本假设"已预装"并回退
    #   systemd-timesyncd, 但 timesyncd 也是 inactive ⇒ 节点没有持久时间服务。
    if ! command -v chronyd >/dev/null 2>&1 || ! command -v chronyc >/dev/null 2>&1; then
        if [ "${HAS_DEB}" = "1" ] && ls /tmp/cubestack-ntp-debs/chrony_*.deb >/dev/null 2>&1; then
            echo "  [install] chrony 缺失 → 离线安装($(ls /tmp/cubestack-ntp-debs/*.deb 2>/dev/null | wc -l) 个 deb) ..."
            install_debs_offline /tmp/cubestack-ntp-debs chrony || true
        fi
        # 安装失败时把 dpkg 日志尾部打出来, 避免只看到 NO-TIME-DAEMON 而不知道缺什么。
        if ! command -v chronyd >/dev/null 2>&1 || ! command -v chronyc >/dev/null 2>&1; then
            echo "CHRONY-INSTALL-FAILED"
            tail -10 /tmp/cubestack-deb-install.log 2>/dev/null | sed 's/^/  /' || true
        fi
    fi
    if command -v chronyd >/dev/null 2>&1 && command -v chronyc >/dev/null 2>&1; then
        # chrony 客户端(预装或刚从离线 deb 安装)
        systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true
        cat > /etc/chrony/chrony.conf <<CFG
# === cubestack-managed ===
server ${SERVER} iburst
__UPSTREAM_LINE__
driftfile /var/lib/chrony/drift
makestep 1 1
rtcsync
logdir /var/log/chrony
CFG
        systemctl enable chrony >/dev/null 2>&1 || true
        systemctl restart chrony >/dev/null 2>&1 || systemctl restart chronyd >/dev/null 2>&1 || true
        if systemctl is-active chrony >/dev/null 2>&1 || systemctl is-active chronyd >/dev/null 2>&1; then
            DAEMON_OK=1
        fi
        # ★ 2026-09-08: 刚重启的 chronyd 在首轮 iburst 收到响应前, makestep 必失败
        #   ("No suitable source for synchronisation") → 重试 3 次(间隔 2s;
        #   局域网 iburst 足够完成首轮同步), 提高真正 NTP 同步命中率(而非 date 硬对齐兜底)
        CHRONY_OK=0
        for _nt in 1 2 3; do
            chronyc -a makestep >/dev/null 2>&1 && { CHRONY_OK=1; break; }
            sleep 2
        done
    else
        # 无 chrony 包 → systemd-timesyncd 客户端; 必须确认它真的 active,
        # 不能像旧实现那样 restart 失败也继续。
        # ⚠ 幂等清理: 删除历史追加产生的重复 [Time] 段与 NTP 行(每次运行只保留一个干净 [Time]
        #   段 —— 旧实现只删 NTP= 不删 [Time], 累积几十个 [Time] 段后 timesyncd 变 Idle 不再同步)
        sed -i '/^\[Time\]/d; /^NTP=/d; /^FallbackNTP=/d' /etc/systemd/timesyncd.conf 2>/dev/null || true
        printf '\n[Time]\nNTP=%s\n' "${SERVER}" >> /etc/systemd/timesyncd.conf
        timedatectl set-ntp true >/dev/null 2>&1 || true
        systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || systemctl restart systemd-timesyncd >/dev/null 2>&1 || true
        if systemctl is-active systemd-timesyncd >/dev/null 2>&1; then
            DAEMON_OK=1
        fi
    fi
    if [ "${DAEMON_OK}" != "1" ]; then
        echo "NO-TIME-DAEMON(chrony 未安装/未启动, systemd-timesyncd 也未 active)"
    fi
fi

# 一次性硬对齐: 仅当 chrony 未能即时精调(makestep 失败/无 chrony)时,
# 用权威时钟 epoch 兜底覆盖偏差 >1s 的时钟。注意 HOST_MS 采集于连接建立之前(含网络延迟),
# 直接 date 覆盖会引入与延迟等量的虚假偏差, 故不得用于干扰正常同步的时钟。
STEPPED=0
OFF_ABS=0
if [ "${CHRONY_OK}" != "1" ]; then
    NODE_MS="$(date +%s%3N)"
    OFF=$(( NODE_MS - HOST_MS ))
    OFF_ABS=${OFF#-}
    if [ "${OFF_ABS}" -gt 1000 ]; then
        if date -s "@$(( HOST_MS / 1000 ))" >/dev/null 2>&1; then
            STEPPED=1
            echo "date-stepped-by-${OFF}ms"
        else
            echo "date-step-failed"
        fi
    fi
fi

# 明确成功信号: 必须有 active 的时间守护进程(chrony/timesyncd), 且
# chrony makestep 成功 / 偏差本就 ≤1s / date -s 成功。
# 没有守护进程时, 一次性 date -s 不算成功(旧实现会误报 SYNC-OK)。
if [ "${DAEMON_OK}" = "1" ] \
   && { [ "${CHRONY_OK}" = "1" ] || [ "${STEPPED}" = "1" ] || [ "${OFF_ABS}" -le 1000 ]; }; then
    echo "SYNC-OK"
else
    echo "SYNC-FAIL"
fi

# 返回最终 epoch(ms)
date +%s%3N
EOF
} > "${NODE_SCRIPT}"
chmod +x "${NODE_SCRIPT}"
sed -i "s|__AUTHORITY__|${NTP_AUTHORITY}|g" "${NODE_SCRIPT}"
if [ -n "${NTP_UPSTREAM:-}" ]; then
    sed -i "s|__UPSTREAM_LINE__|${NTP_UPSTREAM}|g" "${NODE_SCRIPT}"
else
    sed -i "/__UPSTREAM_LINE__/d" "${NODE_SCRIPT}"
fi

# 读取单节点时钟偏差(优先 chrony 自身 offset; 回退 RTT 补偿的 SSH date)
# 权威基准: 第一个 master(或显式 NTP_SERVER)的时钟, 不再用宿主机(installer)时钟。
# <ip> <user> <pw> → stdout: 偏差ms(绝对值), 全部样本读取失败输出 -1
clock_offset() {
    local ip="$1" u="$2" pw="$3"
    local hb ha node_ms auth_ms s samples=() vals
    local tracking sys leap reach _chrony_note
    local nb na ab ae node_mid auth_mid

    # 权威自身: 无上游时它就是基准。不要再 SSH 自测 —— 否则 SSH/sudo 抖动
    # 会被当成 0.2-0.6s 的"偏差", 把阈值预算白白吃掉。
    if [ "${ip}" = "${NTP_AUTHORITY}" ] && [ -z "${NTP_UPSTREAM:-}" ]; then
        echo 0
        return
    fi

    # 1) 优先 chrony 自身口径: System time + Leap status + 选中源 Reach。
    #    这样 master02 这类"SSH/sudo 慢 4s 但时钟其实已同步"的节点不会被误判。
    #    同时区分"chrony 未安装"与"已安装但未选中源", 便于定位缺包问题。
    if node_cmd "${ip}" "${u}" "${pw}" "bash -c 'command -v chronyc >/dev/null 2>&1'" >/dev/null 2>&1; then
        tracking="$(node_cmd "${ip}" "${u}" "${pw}" "chronyc tracking 2>/dev/null" 2>/dev/null || true)"
        if [ -n "${tracking}" ]; then
            sys="$(printf '%s\n' "${tracking}" | awk '/^System time/{for(i=1;i<=NF;i++) if($i ~ /^-?[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$/) {print $i; exit}}')"
            leap="$(printf '%s\n' "${tracking}" | awk -F: '/^Leap status/{gsub(/^ +/,"",$2); print $2; exit}')"
            reach="$(node_cmd "${ip}" "${u}" "${pw}" \
                "chronyc sources 2>/dev/null | awk '\$1==\"^*\"{print \$5; exit}'" 2>/dev/null | tr -d ' \r' || true)"
            # Reach>0 且已选中 ^* 源即说明 NTP 已在工作; 37/377 只是"收敛稳定"的更高标准,
            # 刚重启 chrony 时通常要几十秒才到 377, 不能因此判失败。
            if [ -n "${sys}" ] && [ "${leap}" = "Normal" ] && [ -n "${reach}" ] && [ "${reach}" -ge 1 ] 2>/dev/null; then
                awk -v s="${sys}" 'BEGIN{d=s; if(d<0)d=-d; printf "%.0f", d*1000}'
                return
            fi
        fi
        _chrony_note="chrony 已安装但未选中源/Reach=0"
    else
        _chrony_note="chrony 未安装(chronyc not found)"
    fi

    # 2) 回退: SSH date 对比。用两个采样的中点对齐, 减少 SSH/负载延迟造成的假偏差;
    #    权威采样用权威自己的 user/pw, 不用被测节点的凭据。
    # ⚠ warn 必须显式 >&2: 本函数在 $(...) 中调用, stdout 只能留最终数字。
    warn "  ${ip}: ${_chrony_note}, 回退 SSH date 测量(受 SSH/负载延迟影响)" >&2
    for _ in 1 2 3; do
        nb="$(date +%s%3N)"
        node_ms="$(node_cmd "${ip}" "${u}" "${pw}" "date +%s%3N" 2>/dev/null || true)"
        na="$(date +%s%3N)"
        [ -z "${node_ms:-}" ] && continue
        ab="$(date +%s%3N)"
        auth_ms="$(node_cmd "${NTP_AUTHORITY}" "${AUTH_USER:-${u}}" "${AUTH_PW:-${pw}}" \
            "date +%s%3N" 2>/dev/null || true)"
        ae="$(date +%s%3N)"
        [ -z "${auth_ms:-}" ] && continue
        node_mid=$(( (nb + na) / 2 ))
        auth_mid=$(( (ab + ae) / 2 ))
        s=$(( node_ms - auth_ms - (node_mid - auth_mid) )); [ "${s}" -lt 0 ] && s=$(( -s ))
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
    # ★ 2026-10-14 实机(10.66.3.203 二次中断的根因): 校准**基准**= 权威节点时钟 —— 权威的
    #   sshd 一旦不可达, clock_offset 里"权威 epoch"读取全空 ⇒ **每个节点都被误报
    #   "无法读取时钟(SSH/sudo 失败?)"**(真实故障在权威身上, 报错却指向全部节点 ⇒ 排查方向全错)。
    #   先定向探测权威可达性: 不可达 → 一条明确的权威级错误 + 退出(不再逐节点空转误报)。
    resolve_authority_creds
    if ! node_sudo_ready "${NTP_AUTHORITY}" "${AUTH_USER}" "${AUTH_PW}"; then
        err "  NTP 权威 ${NTP_AUTHORITY} sudo 不可用(user=${AUTH_USER}) —— 请设 SSH_USER=root,"
        err "  或在节点配置 sudoers: echo '${AUTH_USER} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-cubestack"
        exit 1
    fi
    if ! node_cmd "${NTP_AUTHORITY}" "${AUTH_USER:-ubuntu}" "${AUTH_PW:-}" "true" >/dev/null 2>&1; then
        err "  NTP 权威 ${NTP_AUTHORITY} 不可达(SSH 失败/连接拒绝)—— 校准基准缺失, 其余节点读数必然全部失败"
        err "  请先在该节点控制台检查 ssh 服务(systemctl status ssh; 典型: sshd 未运行/节点异常),"
        err "  恢复后重跑本步骤; 亦可用 NTP_SERVER 显式指定其他校准基准"
        exit 1
    fi
    local FAIL=0 FAIL_LIST=""
    for e in "${NODE_ENTRIES[@]:-}"; do
        local ip rest u pw hn
        ip="${e%%:*}"; rest="${e#*:}"; u="${rest%%:*}"; rest="${rest#*:}"; pw="${rest%%:*}"; rest="${rest#*:}"; hn="${rest%%:*}"
        node_matches "${hn}" || continue
        if ! node_sudo_ready "${ip}" "${u}" "${pw}"; then
            err "  ${hn}(${ip}) sudo 不可用(user=${u}) —— 请设 SSH_USER=root 或在节点配置 NOPASSWD"
            FAIL=1; FAIL_LIST="${FAIL_LIST}${hn} "
            continue
        fi
        # 没有 chrony 且 timesyncd 未运行 ⇒ 节点没有持久时间服务。
        # 此时一次性 date -s 只能保证部署瞬间, 不能算 NTP 通过。
        # ⚠ 必须用 bash -c 包住整条 `||` 链: node_cmd 对非 root 会前置 sudo,
        #   而 `sudo command -v` 无法执行 shell 内建 → 所有节点被误判无守护进程
        #   (2026-10-26 实机: apply 全部 SYNC-OK, verify 却全员报 NO daemon)。
        if ! node_cmd "${ip}" "${u}" "${pw}" \
            "bash -c 'command -v chronyc >/dev/null 2>&1 || systemctl is-active systemd-timesyncd >/dev/null 2>&1'" >/dev/null 2>&1; then
            err "  ${hn}(${ip}) 无可用时间守护进程(chrony 未安装且 systemd-timesyncd 未运行)"
            err "    修复: 安装 chrony 离线 deb, 或 systemctl enable --now systemd-timesyncd 后重跑"
            FAIL=1; FAIL_LIST="${FAIL_LIST}${hn} "
            continue
        fi
        # ★ 2026-10-14: 节点→权威 IP 通路预检(与 apply 同一口径)。--check 模式由此获得明确诊断,
        #   不再把"无 IP 通路"呈现为"无法读取时钟"/"偏差超限"这类指向错误方向的报错。
        local _rr=0
        authority_reachable_from "${ip}" "${u}" "${pw}" || _rr=$?
        if [ "${_rr}" -ne 0 ]; then
            if [ "${_rr}" -eq 2 ]; then
                err "  ${hn}(${ip}) SSH 不可达 —— 检查密钥/密码/节点状态"
            else
                err "  ${hn}(${ip}) 与 NTP 权威 ${NTP_AUTHORITY} 无 IP 通路(ping 不通) —— 检查该节点虚拟网络接入(与正常节点对比; 见 setup-ntp.sh 2026-10-14 注释)"
            fi
            FAIL=1; FAIL_LIST="${FAIL_LIST}${hn} "
            continue
        fi
        off="$(clock_offset "${ip}" "${u}" "${pw}")"
        # 防御: clock_offset 的 stdout 必须只有数字。任何诊断(warn/say)都必须走 stderr;
        # 否则 off 会变成"⚠ ... 3986", 后续 [ -eq/-gt ] 报 integer expression expected,
        # 并且两个比较都失败后会被误走到"✓ 通过"分支。
        if ! [[ "${off}" =~ ^-?[0-9]+$ ]]; then
            err "  ${hn}(${ip}) 时钟偏差解析失败(非数字): ${off}"
            FAIL=1; FAIL_LIST="${FAIL_LIST}${hn} "
            continue
        fi
        if [ "${off}" -eq -1 ]; then
            warn "  ${hn}(${ip}) 无法读取时钟(SSH/sudo 失败?)"
            FAIL=1; FAIL_LIST="${FAIL_LIST}${hn} "
            continue
        fi
        if [ "${off}" -gt "${NTP_MAX_OFFSET_MS}" ]; then
            if [ "${AUTO_SYNC_ON_FAIL:-0}" = "1" ]; then
                warn "  ${hn}(${ip}) 偏差 ${off}ms ✗(>${NTP_MAX_OFFSET_MS}ms), 自动重对齐并复测 ..."
                # ★ 2026-09-08 修复: 重对齐基准必须用**权威时钟**(与 apply 主流程一致)——
                #   旧实现取部署机(installer)时钟, 与权威偏差可能数百 ms, 会把节点设到错误基准
                local hms _hb _ha _aut _rout
                # ★ 2026-10-14 修复(扩容实机: 新 VM 偏 6.5s; 重对齐后复测仍 2493ms 失败):
                #   ① 硬对齐基准 = **采集时刻**的权威 epoch, scp+脚本启动延迟未补偿 ⇒ 落点必然
                #      偏迟数百 ms~数秒。改为**中点半程补偿**(同 clock_offset 口径; 权威不可达时
                #      退回控制器时钟, 不做补偿)。
                _hb="$(date +%s%3N)"
                _aut="$(node_cmd "${NTP_AUTHORITY}" "${AUTH_USER}" "${AUTH_PW}" "date +%s%3N" 2>/dev/null || true)"
                _ha="$(date +%s%3N)"
                if [ -n "${_aut}" ]; then hms=$(( _aut + (_ha - _hb) / 2 )); else hms="$(date +%s%3N)"; fi
                if node_scp "${NODE_SCRIPT}" "${ip}" "${u}" "${pw}" "${REMOTE_SCRIPT}" \
                    && _rout="$(node_cmd "${ip}" "${u}" "${pw}" "bash ${REMOTE_SCRIPT} apply ${hms} 0" 2>&1)" \
                    && printf '%s' "${_rout}" | command grep -q 'SYNC-OK'; then
                    #   ② 旧实现复测只等 1s: chrony 客户端首个 iburst 样本还没到, 尚未自我纠正。
                    #      改为**有界收敛等待**(每 5s 复测, ≤6 次): 正常节点一两个 NTP 样本内步进到
                    #      ms 级直接通过; 真故障节点仍在 ~40s 内有界失败。
                    off=-1
                    for _t in 1 2 3 4 5 6; do
                        sleep 5
                        off="$(clock_offset "${ip}" "${u}" "${pw}")"
                        if [ "${off}" -ne -1 ] && [ "${off}" -le "${NTP_MAX_OFFSET_MS}" ]; then break; fi
                    done
                    unset _t
                fi
                node_cmd "${ip}" "${u}" "${pw}" "rm -f ${REMOTE_SCRIPT}" >/dev/null 2>&1 || true   # 用完即删(2026-10-16)
                unset _hb _ha _aut
                if [ "${off}" -eq -1 ] || [ "${off}" -gt "${NTP_MAX_OFFSET_MS}" ]; then
                    [ -n "${_rout:-}" ] && warn "    远端输出: $(printf '%s' "${_rout}" | tail -3 | tr '\n' ' ')"
                    warn "  ${hn}(${ip}) 复测仍偏差 ${off}ms ✗(>${NTP_MAX_OFFSET_MS}ms)"
                    FAIL=1; FAIL_LIST="${FAIL_LIST}${hn} "
                else
                    ok "  ${hn}(${ip}) 自动重对齐后偏差 ${off}ms ✓"
                fi
                unset _rout
            else
                warn "  ${hn}(${ip}) 偏差 ${off}ms ✗(>${NTP_MAX_OFFSET_MS}ms)"
                FAIL=1; FAIL_LIST="${FAIL_LIST}${hn} "
            fi
        else
            ok "  ${hn}(${ip}) 偏差 ${off}ms ✓"
            # ★ NTP 同步有效性验证(2026-09-05 事故修复): 偏差小 ≠ NTP 在工作 —— chrony 服务端
            #   缺 allow 时客户端永远 ^?(Reach 0), 只有一次性 makestep 兜底, 后续漂移无收敛。
            #   客户端若是 chrony 且权威为首 master, 校验 sources 里权威源的 Reach(期望 377)。
            if [ "${ip}" != "${NTP_AUTHORITY}" ] && node_cmd "${ip}" "${u}" "${pw}" \
                "bash -c 'command -v chronyc >/dev/null 2>&1'" 2>/dev/null; then
                # Reach 是 `chronyc sources` 的第 5 列(1=^*, 2=源, 3=stratum, 4=poll, 5=reach);
                # 旧实现取 $6(LastRx), 阈值判断没有意义 —— 这里修正为 $5。
                _reach="$(node_cmd "${ip}" "${u}" "${pw}" \
                    "chronyc sources 2>/dev/null | awk '\$1==\"^*\"{print \$5; exit}'" 2>/dev/null | tr -d ' \r' || true)"
                if [ -z "${_reach}" ] || ! [ "${_reach}" -ge 1 ] 2>/dev/null; then
                    warn "  ${hn}(${ip}) 无 ^* 源或 Reach=0, 强制 makestep 后复检 ..."
                    node_cmd "${ip}" "${u}" "${pw}" "chronyc -a makestep >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
                    sleep 3
                    _reach="$(node_cmd "${ip}" "${u}" "${pw}" \
                        "chronyc sources 2>/dev/null | awk '\$1==\"^*\"{print \$5; exit}'" 2>/dev/null | tr -d ' \r' || true)"
                    if [ -z "${_reach}" ] || ! [ "${_reach}" -ge 1 ] 2>/dev/null; then
                        warn "  ${hn}(${ip}) NTP 源仍无 ^* 源/Reach=0(检查: 权威 chrony 是否 allow 节点网段 / chronyc sources)"
                        FAIL=1; FAIL_LIST="${FAIL_LIST}${hn} "
                    fi
                elif [ "${_reach}" -lt 37 ] 2>/dev/null; then
                    # Reach 17/33 等说明已经收到过权威响应、NTP 正在收敛; 不阻塞部署。
                    warn "  ${hn}(${ip}) NTP 源 Reach=${_reach}(收敛中, 已选中 ^* 源; 继续)"
                fi
            fi
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
            node_cmd "${ip}" "${u}" "${pw}" "rm -f ${REMOTE_SCRIPT}" >/dev/null 2>&1 || true   # 用完即删(2026-10-16)
        done
        ;;
    apply)
        master_chrony_setup
        resolve_authority_creds
        # 客户端同样需要 chrony(实机 master02/worker05-08 的镜像没预装);
        # 有离线 deb 就推给缺 chrony 的节点, 由远端脚本安装。
        NTP_DEB_DIR="${OFFLINE_FILES_ROOT}/os/packages/chrony"
        NTP_HAS_DEB=0
        if compgen -G "${NTP_DEB_DIR}/chrony_*.deb" >/dev/null; then
            NTP_HAS_DEB=1
            say "  chrony 离线包: ${NTP_DEB_DIR}($(ls "${NTP_DEB_DIR}"/*.deb | wc -l) 个; 客户端缺失时自动安装)"
        else
            warn "  未找到 chrony 离线包(${NTP_DEB_DIR}/chrony_*.deb); 客户端缺 chrony 时将回退 systemd-timesyncd"
        fi
        # 闭包自检(离线安装 chrony 的真实前置): 只 warn, 节点可能已自带部分依赖;
        # 需要严格离线保证时设 NTP_REQUIRE_CHRONY_CLOSURE=1。
        _NTP_CLOSURE_TOOL="${SCRIPT_DIR}/tools/node/chrony-offline-debs.py"
        if [ "${NTP_HAS_DEB}" = "1" ] && [ -f "${_NTP_CLOSURE_TOOL}" ] && command -v python3 >/dev/null 2>&1; then
            if ! _closure_out="$(python3 -I "${_NTP_CLOSURE_TOOL}" --check "${NTP_DEB_DIR}" 2>&1)"; then
                warn "  chrony 离线依赖闭包不完整(干净节点会安装失败):" >&2
                printf '%s\n' "${_closure_out}" | command grep -E '^  - ' | head -10 | sed 's/^/    /' >&2 || true
                warn "  联网构建机补齐: python3 ${_NTP_CLOSURE_TOOL} --fetch ${NTP_DEB_DIR}" >&2
                if [ "${NTP_REQUIRE_CHRONY_CLOSURE:-0}" = "1" ]; then
                    err "NTP_REQUIRE_CHRONY_CLOSURE=1 → 停止部署"
                    exit 1
                fi
            fi
        fi
        say "下发并执行节点时间同步(chrony/timesyncd + 一次性硬对齐, 权威=${NTP_AUTHORITY}) ..."
        REACH_FAIL=""
        APPLY_FAIL=""
        for e in "${NODE_ENTRIES[@]:-}"; do
            ip="${e%%:*}"; rest="${e#*:}"; u="${rest%%:*}"; rest="${rest#*:}"; pw="${rest%%:*}"; rest="${rest#*:}"; hn="${rest%%:*}"
            node_matches "${hn}" || continue
            # 权限前置: 非 root 的 sudo 不可用时, 后续 scp/脚本/chronyc 都会失败,
            # 且容易被误报成"时间同步失败"; 这里直接点名。
            if ! node_sudo_ready "${ip}" "${u}" "${pw}"; then
                err "  ${hn}(${ip}) sudo 不可用(user=${u}) —— 请设 SSH_USER=root 或在节点配置 NOPASSWD"
                APPLY_FAIL="${APPLY_FAIL}${hn} "
                continue
            fi
            # 权威 = 第一个 master(或显式 NTP_SERVER); 首 master 自身若未显式 NTP_SERVER,
            # 已是权威服务端, 不再向自己同步(跳过), 其余节点作为客户端指向它。
            if [ -z "${NTP_SERVER:-}" ] && [ "${ip}" = "${FIRST_MASTER_IP}" ]; then
                ok "  ${hn}(${ip}) 为 NTP 权威(首 master), 跳过自我同步"
                continue
            fi
            # 客户端缺 chrony 时推送离线 deb(已装则跳过); 远端脚本负责 install_debs_offline。
            if [ "${NTP_HAS_DEB}" = "1" ] \
               && ! node_cmd "${ip}" "${u}" "${pw}" "bash -c 'command -v chronyd >/dev/null 2>&1 && command -v chronyc >/dev/null 2>&1'" >/dev/null 2>&1; then
                node_cmd "${ip}" "${u}" "${pw}" "rm -rf /tmp/cubestack-ntp-debs && mkdir -p /tmp/cubestack-ntp-debs" >/dev/null 2>&1 || true
                for _deb in "${NTP_DEB_DIR}"/*.deb; do
                    [ -f "${_deb}" ] || continue
                    # ⚠ 必须用文件全路径, 不能用 "/tmp/cubestack-ntp-debs/" 目录尾斜杠:
                    #   node_scp 会先 rm -rf 该目录, 循环中会把前面推的 deb 全部删掉。
                    node_scp "${_deb}" "${ip}" "${u}" "${pw}" "/tmp/cubestack-ntp-debs/$(basename "${_deb}")" >/dev/null 2>&1 \
                        || warn "  ${hn}(${ip}) chrony deb 推送失败: $(basename "${_deb}")"
                done
            fi
            # ★ 2026-10-14 扩容事故(worker13): 节点↔权威无 IP 通路时, 同步/硬对齐都不可能建立,
            #   旧流程还会拖进 verify 的"重对齐+复测"表演。此处提前点名, 跳过该节点的同步尝试,
            #   循环后统一硬失败(不再浪费 40s 收敛等待)。
            _rr=0
            authority_reachable_from "${ip}" "${u}" "${pw}" || _rr=$?
            if [ "${_rr}" -ne 0 ]; then
                if [ "${_rr}" -eq 2 ]; then
                    err "  ${hn}(${ip}) SSH 不可达 —— 检查密钥/密码/节点状态后重跑"
                else
                    err "  ${hn}(${ip}) 与 NTP 权威 ${NTP_AUTHORITY} 无 IP 通路(ping 不通) —— 时间同步不可能建立, 该节点接入集群后同样不可用"
                    err "    典型原因: 该 VM 的网络接入与集群其余节点不同段/被隔离(2026-10-14 扩容实机案例);"
                    err "    排查: 在该节点手工 ping ${NTP_AUTHORITY}(并反向 ping), 与正常节点的虚拟网络配置对比;"
                    err "    若环境仅禁 ICMP 而 NTP(UDP123) 可达: 置 NTP_REACH_CHECK=0 关闭本预检"
                fi
                REACH_FAIL="${REACH_FAIL}${hn} "
                continue
            fi
            # 一次性硬对齐基准: 权威时钟 epoch(权威自己的 user/pw, 不用被测节点凭据)。
            # ★ 2026-10-14: 采样加**中点半程补偿**(消除 SSH RTT 偏迟; scp+脚本启动的小段残余
            #   延迟由 verify_clocks 的收敛等待窗口吸收)。
            _hb="$(date +%s%3N)"
            _aut="$(node_cmd "${NTP_AUTHORITY}" "${AUTH_USER}" "${AUTH_PW}" "date +%s%3N" 2>/dev/null || true)"
            _ha="$(date +%s%3N)"
            if [ -n "${_aut}" ]; then HOST_MS=$(( _aut + (_ha - _hb) / 2 )); else HOST_MS="$(date +%s%3N)"; fi
            unset _hb _ha _aut
            if node_scp "${NODE_SCRIPT}" "${ip}" "${u}" "${pw}" "${REMOTE_SCRIPT}"; then
                _rout="$(node_cmd "${ip}" "${u}" "${pw}" "bash ${REMOTE_SCRIPT} apply ${HOST_MS} ${NTP_HAS_DEB}" 2>&1)" && _rok=1 || _rok=0
                if [ "${_rok}" = "1" ] && printf '%s' "${_rout}" | command grep -q 'SYNC-OK'; then
                    ok "  ${hn}(${ip}) 时间已同步"
                else
                    warn "  ${hn}(${ip}) 同步失败: $(printf '%s' "${_rout}" | tail -3 | tr '\n' ' ')"
                    APPLY_FAIL="${APPLY_FAIL}${hn} "
                fi
            else
                warn "  ${hn}(${ip}) 无法上传脚本(检查密钥/密码)"
                APPLY_FAIL="${APPLY_FAIL}${hn} "
            fi
            unset _rout _rok
            node_cmd "${ip}" "${u}" "${pw}" "rm -f ${REMOTE_SCRIPT}" >/dev/null 2>&1 || true   # 用完即删(2026-10-16)
        done
        if [ -n "${REACH_FAIL}" ] || [ -n "${APPLY_FAIL}" ]; then
            [ -n "${REACH_FAIL}" ] && err "存在无法与权威建立通路的节点: ${REACH_FAIL}(原因见上); 网络修复前时间同步不可能成功"
            [ -n "${APPLY_FAIL}" ] && err "以下节点时间同步执行失败: ${APPLY_FAIL}(查看上方 SYNC-FAIL/date-step-failed 输出)"
            rm -f "${NODE_SCRIPT}"
            exit 1
        fi
        echo "---------------------------------------------"
        AUTO_SYNC_ON_FAIL=1 verify_clocks || exit $?
        rm -f "${NODE_SCRIPT}"
        ;;
esac

ok "NTP 时间同步步骤完成"