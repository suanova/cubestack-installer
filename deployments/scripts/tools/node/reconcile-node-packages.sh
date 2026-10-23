#!/bin/bash
# ============================================================
# reconcile-node-packages.sh —— 节点系统包对账(离线, 幂等, 旧版本先摘后装)
#
# 为什么需要(2026-09-28 实机事故):
#   离线 .deb 集里带了**与节点既有系统包同版本不同**的包(实测 libudev1 3.22 vs 节点 3.12),
#   而 ansible 侧 install-packages 当时是"逐包 dpkg -i"(不做版本对账)⇒ 把节点已装的系统库
#   覆盖升级, 而它的**严格依赖兄弟包**(udev 要求 `libudev1 (= 3.12)`)还是旧版 ⇒ dpkg 依赖被打破,
#   该节点上**任何 apt 操作都失败**(E: Unmet dependencies)⇒ 下次部署死在 bootstrap_os →
#   system_packages 的 "Manage packages"(报错只提 udev, 根因在几轮之前, 极难定位)。
#
# 设计(用户 2026-09-28 定案):
#   · **模块化**: 逻辑在本工具, 模块 12_node_pkgs 只做壳; 部署前由 06 的 REQUIRES 保证先跑。
#   · **旧版本先卸后装**: 不手写"配对/闭包"逻辑, 交给 **apt 求解器**(它自己会先摘旧兄弟再装新的),
#     我们只负责把离线 .deb 放到它能看见的地方(`Dir::Cache::archives`, 且 `--no-download` 全程离线)。
#   · **不引入新问题**: ① 先跑 `apt-get -s -f install` 打印计划再执行; ② 只碰"我们带的包";
#     ③ 收尾 `apt-get check` 复核依赖图, 不健康即非零退出(把问题挡在 6 分钟的 kubespray 之前)。
#   · **chrony/timesyncd 互斥护栏**(2026-10-07 事故): 节点已有 chrony(VM 黄金镜像)时跳过
#     systemd-timesyncd —— 二者 apt 互斥, 对账装 timesyncd 会把权威 NTP 服务端摘掉 ⇒ 05_k8s_ntp 失败。
#
# 用法: reconcile-node-packages.sh [--ip <IP>]... [--dry-run] [--user <u>]
#       不给 --ip = 对 cluster.conf NODES 里全部节点执行。
# 退出码: 0=全部节点 apt 依赖图健康; 1=有节点仍不健康
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# USER 留空 = 按节点逐个解析(ssh_user_for_ip: NODES 逐行覆盖 → 全局 SSH_USER), --user 显式覆盖全部
DRY=0; USER=""; IPS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --ip) IPS+=("${2:?--ip 需要地址}"); shift 2 ;;
        --user) USER="$2"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        *) err "未知参数: $1"; exit 1 ;;
    esac
done
if [ "${#IPS[@]}" -eq 0 ]; then
    # 目标节点来源**以 inventory 为准**(部署本身就是 inventory 驱动的; cluster.conf 的 NODES
    # 在容器里可能与实际不同/为空 —— 实测 2026-09-28)。取不到再回退 cluster.conf 的 NODES。
    _hosts="${REPO_ROOT}/deployments/kubespray/inventory/${CLUSTER_NAME:-cubestack-cluster}/hosts.yml"
    if [ -f "${_hosts}" ]; then
        while IFS= read -r ip; do [ -n "${ip}" ] && IPS+=("${ip}"); done \
            < <(awk '/^[[:space:]]*ansible_host:/{print $2}' "${_hosts}" | sort -u)
    fi
    if [ "${#IPS[@]}" -eq 0 ]; then
        while IFS= read -r ip; do [ -n "${ip}" ] && IPS+=("${ip}"); done < <(all_node_ips)
    fi
fi
[ "${#IPS[@]}" -gt 0 ] || { err "没有目标节点(cluster.conf NODES 为空?)"; exit 1; }

# 离线 .deb 来源: offline-files/os/packages(版本无关 OS 层; 2026-10-08 起节点 .deb 统一收敛于此,
# 原 <版本目录>/packages 与 packages/repair 已并入 —— 同名同版本去重; 版本目录不再放 .deb)
# ⚠ 只扫该目录**顶层** *.deb: chrony 等"专用安装集"放子目录(如 os/packages/chrony/), 不做对账。
DEB_DIRS=("${OFFLINE_FILES_ROOT:-${REPO_ROOT}/deployments/offline-files}/os/packages")
DEBS=()
for d in "${DEB_DIRS[@]}"; do
    [ -d "${d}" ] || continue
    for f in "${d}"/*.deb; do [ -f "${f}" ] && DEBS+=("${f}"); done
done
[ "${#DEBS[@]}" -gt 0 ] || { err "离线目录下没有任何 .deb(${DEB_DIRS[*]})"; exit 1; }
say "离线包: ${#DEBS[@]} 个; 目标节点: ${#IPS[@]} 个"

SSH_KEY="${SSH_KEY_DIR:-${REAL_HOME:-$HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
SSH_OPTS=(-i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8)

# ---------------- 控制器侧前置探测(2026-10-19 实机事故) ----------------
# 在分发离线包/装包之前, 用短超时探测每个节点是否有**旧集群 Ceph/RBD 残留**:
#   ceph/rbd 挂载、/sys/bus/rbd/devices、相关 D 状态进程、fuser 超时。
# 处置策略(2026-10-19 用户口径):
#   · D 状态 / fuser 超时 = 僵尸态, 无法自动修复 → 整轮失败并给出重启指引;
#   · 挂载不健康但未卡死 → 控制器放行, 由远端脚本自动 stop kubelet/containerd +
#     umount -l/-f + rbd unmap, 成功后继续;
#   · 活动且健康的 Ceph/RBD(当前集群正在用) → 不阻断(避免误伤运行中的 CephFS/RBD PVC)。
_probe="$(cat <<'PROBE'
ceph_mnts=$(timeout 5 findmnt -t ceph,rbd -n -o TARGET,FSTYPE 2>/dev/null | head -5)
stuck=$(timeout 5 ps -eo pid,stat,etime,cmd 2>/dev/null | awk '$2 ~ /^D/ && /rbd|ceph|mdadm|initramfs|dpkg|sync|fuser/' | head -3)
n_rbd=$(ls -1 /sys/bus/rbd/devices 2>/dev/null | wc -l | tr -d ' ')
timeout 5 fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1
frc=$?
issues=""
# 活动且健康的 Ceph/RBD(当前集群正在用)不是"旧集群残留": 只要挂载可读、无 D 状态/
# fuser 超时, 就放行(2026-10-19 实机: cephfs_mount DS + RBD PVC 正常在用, 却被旧逻辑误拦)。
_ceph_bad=""
if [ -n "${ceph_mnts}" ] && [ -z "${stuck}" ] && [ "${frc}" -ne 124 ]; then
    while read -r _t _f; do
        [ -n "${_t}" ] || continue
        timeout 5 ls "${_t}" >/dev/null 2>&1 || _ceph_bad="${_ceph_bad} ${_t}"
    done <<< "${ceph_mnts}"
else
    _ceph_bad="${ceph_mnts}"
fi
[ -n "${stuck}" ] && issues="${issues}D-state: ${stuck}; "
[ "${frc}" -eq 124 ] && issues="${issues}fuser-timeout; "
# 只有 D 状态/fuser 超时才是"不可自动修复"的僵尸态。挂载不健康但未卡死 → 交给远端脚本
# 自动 stop kubelet/containerd + umount/rbd unmap 后再试。
if [ -n "${issues}" ]; then echo "${issues}"; exit 2; fi
[ -n "${_ceph_bad}" ] && echo "auto-repair-needed:${_ceph_bad}"
[ -n "${ceph_mnts}" ] && echo "active-ceph-ok: $(printf '%s' "${ceph_mnts}" | tr '\n' ' ')"
[ "${n_rbd:-0}" -gt 0 ] && echo "active-rbd-ok: ${n_rbd}"
exit 0
PROBE
)"
# ssh 自身失败(认证/网络)必须与"Ceph 探测发现卡死"分开报 —— 否则密码错误会被
# 误导成"重置节点"(2026-10-22 用户实机: 密码错 → 提示 systemctl reboot -f)。
# ssh 返回 255 = 连接/认证层失败; 远端探测显式返回 2 = D 状态/fuser 超时(只能重启)。
_clean_out() {
    printf '%s\n' "$1" | grep -vE '^Warning: Permanently added ' \
        | grep -v '^[[:space:]]*$' | tail -3 | tr '\n' ' ' || true
}
_ssh_fail_reason() {   # <user@ip> <output> <rc>
    local _host="$1" _out="$2" _rc="$3" _clean
    _clean="$(_clean_out "${_out}")"
    if printf '%s' "${_out}" | grep -qiE 'permission denied|no supported authentication methods'; then
        printf '%s: SSH 认证失败(密码/公钥被拒绝): %s' "${_host}" "${_clean:-Permission denied}"
    elif printf '%s' "${_out}" | grep -qiE 'connection refused|connection timed out|connection closed|no route to host|network is unreachable'; then
        printf '%s: SSH 网络不可达: %s' "${_host}" "${_clean:-连接失败}"
    else
        printf '%s: SSH 连接失败(rc=%s): %s' "${_host}" "${_rc}" "${_clean:-无输出}"
    fi
}
_preflight_bad=0
_preflight_ssh_report=""
_preflight_wedged_report=""
_preflight_probe_report=""
for _ip in "${IPS[@]}"; do
    _u="${USER:-$(ssh_user_for_ip "${_ip}")}"
    _out="$(timeout 20 ssh "${SSH_OPTS[@]}" "${_u}@${_ip}" "${_probe}" 2>&1)"
    _rc=$?
    if [ "${_rc}" -eq 124 ]; then
        _preflight_bad=1
        _preflight_wedged_report="${_preflight_wedged_report}"$'\n'"  ${_u}@${_ip}: 探测超时(SSH 无响应; 可能被旧 ceph/rbd 卡死, 或网络不通)"
    elif [ "${_rc}" -eq 255 ]; then
        _preflight_bad=1
        _preflight_ssh_report="${_preflight_ssh_report}"$'\n'"  $(_ssh_fail_reason "${_u}@${_ip}" "${_out}" "${_rc}")"
    elif [ "${_rc}" -eq 2 ]; then
        _preflight_bad=1
        _preflight_wedged_report="${_preflight_wedged_report}"$'\n'"  ${_u}@${_ip}: 检测到 D 状态/fuser 超时: $(_clean_out "${_out}")"
    elif [ "${_rc}" -ne 0 ]; then
        _preflight_bad=1
        _preflight_probe_report="${_preflight_probe_report}"$'\n'"  ${_u}@${_ip}: 前置探测失败(rc=${_rc}): $(_clean_out "${_out}")"
    else
        case "${_out}" in
            *auto-repair-needed*)
                say "  ${_ip}: Ceph/RBD 挂载不健康但未卡死 → 远端自动卸载/解映射" ;;
            *active-ceph-ok*|*active-rbd-ok*|*"活动 Ceph/RBD"*)
                say "  ${_ip}: 活动 Ceph/RBD 健康(当前集群在用), 不阻断" ;;
        esac
    fi
done
if [ "${_preflight_bad}" -ne 0 ]; then
    if [ -n "${_preflight_ssh_report}" ]; then
        err "以下节点 SSH 认证/连接失败 —— 部署无法继续(与 Ceph/RBD 无关):"
        printf '%s\n' "${_preflight_ssh_report}"
        err "  处置: ① 认证失败 → 核对 cluster.conf 的 SSH_DEFAULT_PASSWORD(或 NODES 行节点密码)"
        err "        ② 网络不可达 → 检查节点网络/防火墙, 以及 sshd 是否监听 22"
        err "        ③ 确认目标 sshd 允许该用户登录(密码登录需 PasswordAuthentication yes)"
        err "        ④ 修正后先单跑复核: sudo ./deploy-cluster.sh --steps k8s_passwordless"
        err "        ⑤ 纯密钥登录环境: 确认公钥已写入目标 ~/.ssh/authorized_keys"
    fi
    if [ -n "${_preflight_wedged_report}" ]; then
        err "以下节点存在**不健康**的 Ceph/RBD 残留(僵尸态) —— 必须先重启后再部署:"
        printf '%s\n' "${_preflight_wedged_report}"
        err "  处置: ① systemctl stop kubelet containerd"
        err "        ② systemctl reboot -f   # 跳过卡死的 ceph 卸载"
        err "        ③ 重启后再重跑本模块"
    fi
    if [ -n "${_preflight_probe_report}" ]; then
        err "以下节点前置探测执行失败(既非 Ceph/RBD 卡死, 也非 SSH 认证失败):"
        printf '%s\n' "${_preflight_probe_report}"
        err "  处置: 按上面的原始输出检查节点环境(如 findmnt/ps/fuser/timeout 是否可用)"
    fi
    exit 1
fi

# 远端脚本(推到节点上跑 —— 避免内嵌命令的单引号地狱, 见仓库既有教训)
REMOTE="$(mktemp)"; trap 'rm -f "${REMOTE}"' EXIT
cat > "${REMOTE}" <<'REMOTE_EOF'
#!/bin/bash
# 在节点上执行(由 reconcile-node-packages.sh 推入): 用 /tmp/cubestack-debs 的离线 .deb 对账系统包
set -uo pipefail
D=/tmp/cubestack-debs
[ "${1:-}" = "--dry-run" ] && DRY=1 || DRY=0
APT=( -o "Dir::Cache::archives=${D}" --no-download -y --no-install-recommends
      -o "Dpkg::Options::=--force-confdef" -o "Dpkg::Options::=--force-confold" )

# ---- ⓪ Ceph/RBD 残留检测 + 自动修复(必须在任何 apt/fuser 之前; 2026-10-19 实机事故) ----
#   背景: cephfs_mount 把 CephFS 挂到宿主机 /mnt/cephfs/models; 非优雅拆除(集群直接消失/
#   未走 uninstall)时该挂载会残留。mons 已不可达 → 内核 ceph 客户端无限重试;
#   `fuser /var/lib/dpkg/lock-frontend` 会遍历 /proc 并撞上该挂载 → **D 状态**
#   (ceph_mdsc_wait_request), 永不返回 ⇒ node_pkgs 在第一个节点永久 pending。
#   旧 rbd 映射同理(jbd2/rbd0 / rbd remove D 状态)。
# 处置策略(2026-10-19 用户口径):
#   · D 状态进程 / fuser 超时 = 僵尸态, SIGKILL 无效 → **只有这种情况**才提示重启;
#   · 挂载不健康但未卡死 → 自动 stop kubelet/containerd + umount -l/-f + rbd unmap;
#   · 活动且健康的 Ceph/RBD(当前集群正在用) → 不动, 直接继续。
_ceph_mnts="$(timeout 5 findmnt -t ceph,rbd -n -o TARGET,FSTYPE 2>/dev/null | head -5 || true)"
_stuck="$(timeout 5 ps -eo pid,stat,etime,cmd 2>/dev/null \
    | awk '$2 ~ /^D/ && /rbd|ceph|mdadm|initramfs|dpkg|sync|fuser/' | head -3 || true)"
_n_rbd="$(ls -1 /sys/bus/rbd/devices 2>/dev/null | wc -l | tr -d ' ' || true)"
timeout 5 fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1
_frc=$?
if [ -n "${_stuck}" ] || [ "${_frc}" -eq 124 ]; then
    echo "         ❌ 节点存在 D 状态/fuser 超时(僵尸进程, 无法自动修复, 必须重启):"
    [ -n "${_stuck}" ] && echo "${_stuck}" | sed 's/^/            D 状态进程: /'
    [ "${_frc}" -eq 124 ] && echo "            fuser /var/lib/dpkg/lock-frontend 超时"
    echo "            处置: ① systemctl stop kubelet containerd"
    echo "                  ② systemctl reboot -f   # 跳过卡死的 ceph 卸载"
    echo "                  ③ 重启后再重跑本模块"
    exit 2
fi
_ceph_bad=""
if [ -n "${_ceph_mnts}" ]; then
    while read -r _t _f; do
        [ -n "${_t}" ] || continue
        timeout 5 ls "${_t}" >/dev/null 2>&1 || _ceph_bad="${_ceph_bad} ${_t}"
    done <<< "${_ceph_mnts}"
fi
if [ -n "${_ceph_bad}" ]; then
    echo "         ⚠ Ceph/RBD 挂载不健康:${_ceph_bad}; 自动卸载/解映射..."
    systemctl stop kubelet containerd 2>/dev/null || true
    while read -r _t _f; do
        [ -n "${_t}" ] || continue
        umount -l "${_t}" 2>/dev/null || umount -f "${_t}" 2>/dev/null || true
    done <<< "${_ceph_mnts}"
    if command -v rbd >/dev/null 2>&1; then
        for _dev in $(rbd showmapped 2>/dev/null | awk 'NR>1{print $5}'); do
            [ -n "${_dev}" ] && rbd unmap -o force "${_dev}" 2>/dev/null || true
        done
    fi
    _left=""
    for _wi in 1 2 3 4 5; do
        _left="$(timeout 5 findmnt -t ceph,rbd -n -o TARGET,FSTYPE 2>/dev/null | head -5 || true)"
        _n_rbd_left="$(ls -1 /sys/bus/rbd/devices 2>/dev/null | wc -l | tr -d ' ' || true)"
        [ -z "${_left}" ] && [ "${_n_rbd_left:-0}" -eq 0 ] && break
        sleep 2
    done
    if [ -n "${_left}" ] || [ "${_n_rbd_left:-0}" -gt 0 ]; then
        echo "         ❌ 自动卸载后仍有 Ceph/RBD 残留(挂载=${_left:-无}; rbd=${_n_rbd_left:-0})"
        echo "            处置: ① systemctl stop kubelet containerd"
        echo "                  ② systemctl reboot -f"
        echo "                  ③ 重启后再重跑本模块"
        exit 2
    fi
    echo "         ✅ 自动卸载/解映射完成, 继续"
fi
if [ -n "${_ceph_mnts}" ] || [ "${_n_rbd:-0}" -gt 0 ]; then
    echo "         ℹ 活动 Ceph/RBD(健康, 当前集群在用): ${_ceph_mnts:-无挂载}; rbd=${_n_rbd:-0}; 继续"
fi

# ---- ① apt 锁仲裁(2026-10-10 实测事故): 节点重启后 apt-daily 定时器触发 unattended-upgrades,
#   它持着 dpkg 锁做下载(离线节点必然失败重试)⇒ 本工具一切 apt 操作撞锁, [4/4] 报"仍不健康"
#   被误判成"依赖图破损"(实为"忙")。处置: 停 **并 disable** unattended-upgrades 与 apt 定时器
#   (离线部署目标上自动更新无意义, 且每次重启后必然复发; 要恢复: systemctl enable --now <单元>),
#   再**有界等待** dpkg 锁释放; 仍被占则响亮报错并点名持有者 —— 不再把"忙"当"坏"。
systemctl stop unattended-upgrades 2>/dev/null || true
systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl disable unattended-upgrades apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
if command -v fuser >/dev/null 2>&1; then
    _lock_free=0
    for _li in $(seq 1 24); do
        # fuser 本身也可能被 ceph/rbd 挂载卡成 D 状态 → 必须加 timeout
        # (实机 2026-10-19: fuser 在 ceph_mdsc_wait_request 里 36 分钟不返回)
        timeout 5 fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1
        _frc=$?
        if [ "${_frc}" -eq 0 ]; then
            sleep 5; continue
        elif [ "${_frc}" -eq 124 ]; then
            echo "         ❌ fuser 超时(节点疑似被 ceph/rbd 卡死) —— 必须重启该节点后再试"
            exit 2
        fi
        _lock_free=1; break
    done
    if [ "${_lock_free}" != "1" ]; then
        echo "         ❌ dpkg 锁被占用 >120s(已停 unattended-upgrades/apt 定时器):"
        timeout 5 fuser -v /var/lib/dpkg/lock-frontend 2>&1 | sed -n '2,3p' | tr -s ' ' | sed 's/^/            /'
        echo "           处置: 人工确认持有者(ps -ef)后重跑本工具"
        exit 1
    fi
fi
echo "   [1/4] 当前 apt 依赖图:"
if apt-get check >/dev/null 2>&1; then echo "         健康"; else echo "         **破损**(下面用离线包修)"; fi

echo "   [2/4] 修复破损依赖(计划见下, 由 apt 求解器决定先摘谁):"
# ① 安装期间禁用 initramfs 重建: 2026-09-24 事故链(dpkg → initramfs-tools.postinst →
#    update-initramfs → hooks/mdadm → `mdadm --examine --scan` 扫**所有**块设备 → 撞上后端已不可达的
#    遗留 /dev/rbd0 → 进程进 D 状态永不返回, dpkg 永不放锁 ⇒ 部署卡 38 分钟以上, 且**下次**再修还会卡)。
#    patch-playbooks/install-packages.yml 早已这样防(update_initramfs=no 装完恢复); 本工具同样处理。
_ir_conf=/etc/initramfs-tools/update-initramfs.conf
_ir_bak=""
if [ "${DRY}" = "0" ] && [ -f "${_ir_conf}" ] && ! grep -qE '^[[:space:]]*update_initramfs[[:space:]]*=[[:space:]]*no' "${_ir_conf}"; then
    _ir_bak="$(mktemp)"; cp -a "${_ir_conf}" "${_ir_bak}"
    if grep -qE '^[[:space:]]*update_initramfs=' "${_ir_conf}"; then
        sed -i -E 's|^[[:space:]]*update_initramfs=.*|update_initramfs=no|' "${_ir_conf}"
    else
        echo 'update_initramfs=no' >> "${_ir_conf}"
    fi
    echo "         已临时禁用 initramfs 重建(规避 rbd/mdadm 扫描卡死链)"
fi
# ② 标准急救: 把"已解包但未配置"的半装包配置完(实测 2026-09-28: 3.33 因历史上的块设备卡死被中断,
#    留下一串 Conf 状态的包 ⇒ 只跑 apt -f install 修不掉, 必须先 dpkg --configure -a)
if [ "${DRY}" = "0" ]; then
    dpkg --configure -a >/dev/null 2>&1 || true
fi
apt-get -s "${APT[@]}" -f install 2>&1 | sed -n '/^\(The following\|  \|E:\)/p' | head -8 | sed 's/^/         /'
if [ "${DRY}" = "0" ]; then
    apt-get "${APT[@]}" -f install >/dev/null 2>&1 || true
fi

echo "   [3/4] 对账离线包(旧版本由 apt 先摘后装; 整批一次求解):"
# ★ 2026-10-19 实机根因: 旧实现逐包 `apt-get install <单个 .deb>`。apt 看不到**同批**离线包,
#   于是系统包组(systemd/udev/libsystemd0/libudev1…)的 `Breaks`/精确版本依赖无法一起满足:
#   先单独升级 libudev1 成功, 再装 udev 时因 systemd 仍旧版报 "held broken packages" →
#   节点被留成 libudev1=3.22 + systemd/libsystemd0=3.21 的**混合态**, 每次 --fresh 都告警。
#   现在把所有"版本不符"的离线 deb **一次性**交给 apt 求解(--no-remove: 只升级/安装,
#   不允许为解依赖摘包), 让 systemd 版本组原子升级。
_TO_DEBS=(); _TO_PKGS=(); _TO_VERS=(); _TO_OLDS=()
for deb in "${D}"/*.deb; do
    [ -e "${deb}" ] || continue
    pkg="$(dpkg-deb -f "${deb}" Package 2>/dev/null)"; ver="$(dpkg-deb -f "${deb}" Version 2>/dev/null)"
    [ -n "${pkg}" ] && [ -n "${ver}" ] || continue
    # ★ 2026-10-07 修复(权威 chrony 被摘除事故根因): systemd-timesyncd 与 chrony **互斥**
    #   (apt 自动摘除对方)。VM 黄金镜像装的是 chrony(create-vm-template.sh 装 chrony 时即卸
    #   timesyncd), 对账若把 timesyncd 装回去 ⇒ 首 master 权威 NTP 服务端消失 ⇒ 05_k8s_ntp
    #   必失败(离线环境 apt 又装不回来)。有 chrony 的节点跳过 timesyncd; 裸金属(无 chrony)
    #   仍正常装 timesyncd 作客户端。
    if [ "${pkg}" = "systemd-timesyncd" ] && dpkg-query -W -f='${Status}' chrony 2>/dev/null | grep -q "install ok installed"; then
        printf '         skip %s(节点已装 chrony, 二者互斥; 保持 VM 镜像口径)\n' "${pkg}"
        continue
    fi
    cur="$(dpkg-query -W -f='${Version}' "${pkg}" 2>/dev/null || true)"
    if [ "${cur}" = "${ver}" ]; then printf '         ok   %s=%s\n' "${pkg}" "${ver}"; continue; fi
    if [ "${DRY}" = "1" ]; then printf '         计划 %s: %s → %s\n' "${pkg}" "${cur:-未装}" "${ver}"; continue; fi
    _TO_DEBS+=("${deb}"); _TO_PKGS+=("${pkg}"); _TO_VERS+=("${ver}"); _TO_OLDS+=("${cur:-未装}")
done
if [ "${DRY}" = "0" ] && [ "${#_TO_DEBS[@]}" -gt 0 ]; then
    if out="$(apt-get "${APT[@]}" --allow-downgrades --no-remove install "${_TO_DEBS[@]}" 2>&1)"; then
        for i in "${!_TO_PKGS[@]}"; do
            printf '         ✅   %s: %s → %s\n' "${_TO_PKGS[$i]}" "${_TO_OLDS[$i]}" "${_TO_VERS[$i]}"
        done
    else
        printf '         ⚠    整批安装失败, 逐包兜底(错误: %s)\n' "$(printf '%s' "${out}" | tail -1 | cut -c1-140)"
        for i in "${!_TO_DEBS[@]}"; do
            cur="$(dpkg-query -W -f='${Version}' "${_TO_PKGS[$i]}" 2>/dev/null || true)"
            [ "${cur}" = "${_TO_VERS[$i]}" ] && { printf '         ok   %s=%s\n' "${_TO_PKGS[$i]}" "${_TO_VERS[$i]}"; continue; }
            if out="$(apt-get "${APT[@]}" --allow-downgrades --no-remove install "${_TO_DEBS[$i]}" 2>&1)"; then
                printf '         ✅   %s: %s → %s\n' "${_TO_PKGS[$i]}" "${_TO_OLDS[$i]}" "${_TO_VERS[$i]}"
            else
                printf '         ⚠    %s: 未按 %s 装到位 —— %s\n' "${_TO_PKGS[$i]}" "${_TO_VERS[$i]}" "$(printf '%s' "${out}" | tail -1 | cut -c1-120)"
            fi
        done
    fi
fi

echo "   [4/4] 复核 apt 依赖图:"
if [ -n "${_ir_bak}" ] && [ -f "${_ir_bak}" ]; then cp -a "${_ir_bak}" "${_ir_conf}"; rm -f "${_ir_bak}"; fi
if apt-get check >/dev/null 2>&1; then echo "         ✅ 健康"; exit 0; fi
echo "         ❌ 仍不健康:"; apt-get check 2>&1 | sed -n '/E:/p' | head -4 | sed 's/^/            /'
exit 1
REMOTE_EOF

FAIL=0
# 远端对账硬超时(默认 30min): 即使节点在装包中途卡死(ceph/rbd/initramfs), 也不能让**整轮部署**
# 永久挂起; 超时后记失败并继续下一节点。2026-10-19 实机: 无超时导致 node_pkgs 在首个节点 pending。
RECONCILE_SSH_TIMEOUT="${RECONCILE_SSH_TIMEOUT:-1800}"
for ip in "${IPS[@]}"; do
    say "── ${ip} ──"
    _u="${USER:-$(ssh_user_for_ip "${ip}")}"
    if ! ssh "${SSH_OPTS[@]}" "${_u}@${ip}" "rm -rf /tmp/cubestack-debs && mkdir -p /tmp/cubestack-debs" 2>/dev/null; then
        warn "  SSH 不可达, 跳过"; FAIL=1; continue
    fi
    if ! scp -q "${SSH_OPTS[@]}" "${DEBS[@]}" "${REMOTE}" "${_u}@${ip}:/tmp/cubestack-debs/" 2>/dev/null; then
        warn "  分发离线包失败, 跳过"; FAIL=1; continue
    fi
    _args=""; [ "${DRY}" = "1" ] && _args="--dry-run"
    if timeout "${RECONCILE_SSH_TIMEOUT}" ssh "${SSH_OPTS[@]}" "${_u}@${ip}" "sudo bash /tmp/cubestack-debs/$(basename "${REMOTE}") ${_args}" 2>&1; then
        ok "  ${ip}: 对账完成, apt 依赖图健康"
    else
        _rc=$?
        [ "${_rc}" = "124" ] && warn "  ${ip}: 远端对账超过 ${RECONCILE_SSH_TIMEOUT}s(疑似 ceph/rbd 卡死), 已终止"
        FAIL=1
    fi
    ssh "${SSH_OPTS[@]}" "${_u}@${ip}" "rm -rf /tmp/cubestack-debs" >/dev/null 2>&1 || true
done

[ "${FAIL}" = "0" ] || { err "有节点 apt 依赖图仍不健康(见上; 未修复前 kubespray 的 system_packages 必失败)"; exit 1; }
ok "全部节点系统包已对账, apt 依赖图健康"
