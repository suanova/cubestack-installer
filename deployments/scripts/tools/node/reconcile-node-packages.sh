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

DRY=0; USER="${SSH_USER:-ubuntu}"; IPS=()
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

# 远端脚本(推到节点上跑 —— 避免内嵌命令的单引号地狱, 见仓库既有教训)
REMOTE="$(mktemp)"; trap 'rm -f "${REMOTE}"' EXIT
cat > "${REMOTE}" <<'REMOTE_EOF'
#!/bin/bash
# 在节点上执行(由 reconcile-node-packages.sh 推入): 用 /tmp/cubestack-debs 的离线 .deb 对账系统包
set -uo pipefail
D=/tmp/cubestack-debs
[ "${1:-}" = "--dry-run" ] && DRY=1 || DRY=0
APT=( -o "Dir::Cache::archives=${D}" --no-download -y
      -o "Dpkg::Options::=--force-confdef" -o "Dpkg::Options::=--force-confold" )

# ---- ⓪ apt 锁仲裁(2026-10-10 实测事故): 节点重启后 apt-daily 定时器触发 unattended-upgrades,
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
        fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || { _lock_free=1; break; }
        sleep 5
    done
    if [ "${_lock_free}" != "1" ]; then
        echo "         ❌ dpkg 锁被占用 >120s(已停 unattended-upgrades/apt 定时器):"
        fuser -v /var/lib/dpkg/lock-frontend 2>&1 | sed -n '2,3p' | tr -s ' ' | sed 's/^/            /'
        echo "           处置: 人工确认持有者(ps -ef)后重跑本工具"
        exit 1
    fi
fi
echo "   [1/4] 当前 apt 依赖图:"
if apt-get check >/dev/null 2>&1; then echo "         健康"; else echo "         **破损**(下面用离线包修)"; fi

# 已知死锁的**自动识别**(2026-09-24 事故链; 2026-09-28 又在 3.33/3.36 复现):
#   dpkg/apt → initramfs-tools.postinst → update-initramfs → hooks/mdadm →
#   `mdadm --examine --scan` 扫全部块设备 → 撞上后端已不可达的遗留 /dev/rbd0 → **D 状态(不可中断)**,
#   dpkg 永不放锁 ⇒ 任何 apt 操作都报 "Could not get lock /var/lib/dpkg/lock-frontend"。
#   ⚠ D 态进程**连 SIGKILL 都无效**(内核不可中断睡眠)⇒ 自动化只能**识别并给出重启指引**, 不能替用户重启。
_stuck=""
if [ -e /var/lib/dpkg/lock-frontend ]; then
    for p in $(ps -eo pid,stat,cmd | awk '$2 ~ /^D/ && /mdadm|initramfs|dpkg|sync/ {print $1}'); do
        _stuck="${_stuck} $(ps -o pid,stat,cmd -p "${p}" --no-headers 2>/dev/null | tr -s ' ' | cut -c1-90)"
    done
fi
_n_rbd="$(ls -1 /sys/bus/rbd/devices 2>/dev/null | wc -l | tr -d ' ')"
if [ -n "${_stuck}" ]; then
    echo "         ⚠ 检测到**不可中断(D 状态)进程** —— 这是已知死锁链, 重启该节点才能解开:"
    echo "${_stuck}" | sed 's/^/            /'
    echo "           判据/处置见 docs/node-package-repair.md; 本工具到此为止(不代重启)"
elif [ "${_n_rbd:-0}" -gt 0 ]; then
    echo "         ⚠ 本节点有 ${_n_rbd} 个内核 rbd 映射(后端若已不可达, 任何块设备扫描都会卡) —— 建议先重启再修"
fi

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

echo "   [3/4] 对账离线包(旧版本由 apt 先摘后装):"
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
    if out="$(apt-get "${APT[@]}" --allow-downgrades install "${deb}" 2>&1)"; then
        printf '         ✅   %s: %s → %s\n' "${pkg}" "${cur:-未装}" "${ver}"
    else
        printf '         ⚠    %s: 未按 %s 装到位 —— %s\n' "${pkg}" "${ver}" "$(printf '%s' "${out}" | tail -1 | cut -c1-120)"
    fi
done

echo "   [4/4] 复核 apt 依赖图:"
if [ -n "${_ir_bak}" ] && [ -f "${_ir_bak}" ]; then cp -a "${_ir_bak}" "${_ir_conf}"; rm -f "${_ir_bak}"; fi
if apt-get check >/dev/null 2>&1; then echo "         ✅ 健康"; exit 0; fi
echo "         ❌ 仍不健康:"; apt-get check 2>&1 | sed -n '/E:/p' | head -4 | sed 's/^/            /'
exit 1
REMOTE_EOF

FAIL=0
for ip in "${IPS[@]}"; do
    say "── ${ip} ──"
    if ! ssh "${SSH_OPTS[@]}" "${USER}@${ip}" "rm -rf /tmp/cubestack-debs && mkdir -p /tmp/cubestack-debs" 2>/dev/null; then
        warn "  SSH 不可达, 跳过"; FAIL=1; continue
    fi
    if ! scp -q "${SSH_OPTS[@]}" "${DEBS[@]}" "${REMOTE}" "${USER}@${ip}:/tmp/cubestack-debs/" 2>/dev/null; then
        warn "  分发离线包失败, 跳过"; FAIL=1; continue
    fi
    _args=""; [ "${DRY}" = "1" ] && _args="--dry-run"
    if ssh "${SSH_OPTS[@]}" "${USER}@${ip}" "sudo bash /tmp/cubestack-debs/$(basename "${REMOTE}") ${_args}" 2>&1; then
        ok "  ${ip}: 对账完成, apt 依赖图健康"
    else
        FAIL=1
    fi
    ssh "${SSH_OPTS[@]}" "${USER}@${ip}" "rm -rf /tmp/cubestack-debs" >/dev/null 2>&1 || true
done

[ "${FAIL}" = "0" ] || { err "有节点 apt 依赖图仍不健康(见上; 未修复前 kubespray 的 system_packages 必失败)"; exit 1; }
ok "全部节点系统包已对账, apt 依赖图健康"
