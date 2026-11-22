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
    # ★ 扩容(k8s_scale)只设置 ONLY_HOSTS、不传 --ip: 必须按 ONLY_HOSTS 过滤, 否则会把
    #   .deb 上传/apt 对账到已有节点(07_k8s_scale.sh 的注释明确要求只动新节点)。
    #   显式 --ip 仍视为调用方精确指定, 不受 ONLY_HOSTS 过滤。
    _only="${ONLY_HOSTS:-}"
    _hosts="${REPO_ROOT}/deployments/kubespray/inventory/${CLUSTER_NAME:-cubestack-cluster}/hosts.yml"
    # ONLY_HOSTS(扩容)场景: 地址以 cluster.conf NODES 为准 —— 扩容时 hosts.yml 还是**扩容前**
    # 生成的(同一 hostname 可能是旧 IP), 而 hosts.yml 要到流程稍后才重建。若把 inventory 的
    # 过期地址也收进来, .deb 会被分发/对账到旧机器。这里先建 NODES 的 hostname→IP 映射,
    # inventory 中与 NODES 冲突的地址一律跳过(不跳过则两条都会被 IP 去重逻辑保留)。
    declare -A _nodes_ip=()
    _nodes_match_ips=""
    if [ -n "${_only}" ]; then
        for _line in "${NODES[@]:-}"; do
            [ -z "${_line}" ] && continue
            node_parse "${_line}"
            [ -n "${NODE_IP}" ] || continue
            node_matches "${NODE_HOSTNAME}" || continue
            [ -n "${_nodes_ip[${NODE_HOSTNAME}]:-}" ] || _nodes_ip["${NODE_HOSTNAME}"]="${NODE_IP}"
            case " ${_nodes_match_ips} " in
                *" ${NODE_IP} "*) ;;
                *) _nodes_match_ips="${_nodes_match_ips:+${_nodes_match_ips} }${NODE_IP}" ;;
            esac
        done
    fi
    if [ -f "${_hosts}" ]; then
        while IFS=$'\t' read -r _hn _ip; do
            [ -n "${_ip}" ] || continue
            node_matches "${_hn}" || continue
            if [ -n "${_only}" ]; then
                if [ -n "${_nodes_ip[${_hn}]:-}" ]; then
                    if [ "${_nodes_ip[${_hn}]}" != "${_ip}" ]; then
                        warn "  跳过 inventory 过期地址: ${_hn} -> ${_ip}(NODES 现地址 ${_nodes_ip[${_hn}]}; hosts.yml 将在扩容流程中重建)"
                        continue
                    fi
                elif [ -n "${_nodes_match_ips}" ]; then
                    # 该 inventory 主机名不在 NODES 中, 但 selector 在 NODES 里匹配到了别的地址:
                    # 本行不是 NODES 指认的那台主机(如 --only w1 同时匹配 old-w1/new-w1),
                    # 其 inventory 地址可能是过期机器的 —— 一律不以它为准。
                    _foreign=0
                    for _nip in ${_nodes_match_ips}; do
                        [ "${_nip}" = "${_ip}" ] || { _foreign=1; break; }
                    done
                    if [ "${_foreign}" = "1" ]; then
                        warn "  跳过 inventory 行: ${_hn} -> ${_ip}(selector 在 NODES 中匹配的地址为 ${_nodes_match_ips}; 只认 NODES)"
                        continue
                    fi
                fi
            fi
            IPS+=("${_ip}")
        done < <(awk '
            /^[[:space:]]*[A-Za-z0-9_.-]+:[[:space:]]*$/ {
                hn=$1; sub(/:$/,"",hn); next
            }
            /^[[:space:]]*ansible_host:/ {
                ip=$2; gsub(/"/,"",ip)
                if (hn != "" && ip != "") print hn "\t" ip
            }
        ' "${_hosts}" | sort -u)
    fi
    # ONLY_HOSTS 显式指定: 再从 NODES 补入(inventory 可能尚未包含扩容新节点),
    # 仍由 node_matches 只保留匹配节点; ONLY_HOSTS 未设置时保持 inventory 全量行为,
    # 仅当 inventory 完全取不到才回退 NODES。
    if [ -n "${_only}" ] || [ "${#IPS[@]}" -eq 0 ]; then
        for _line in "${NODES[@]:-}"; do
            [ -z "${_line}" ] && continue
            node_parse "${_line}"
            [ -n "${NODE_IP}" ] || continue
            node_matches "${NODE_HOSTNAME}" || continue
            _dup=0
            for _x in ${IPS[@]+"${IPS[@]}"}; do
                [ "${_x}" = "${NODE_IP}" ] && { _dup=1; break; }
            done
            [ "${_dup}" = "0" ] && IPS+=("${NODE_IP}")
        done
        unset _line _x _dup
    fi
    unset _hn _ip _only _nodes_ip _nodes_match_ips _nip _foreign
fi
[ "${#IPS[@]}" -gt 0 ] || { err "没有目标节点(cluster.conf NODES 为空?)"; exit 1; }

# 离线 .deb 来源:
#   新布局 <OFFLINE_FILES_ROOT>/os/packages/ubuntu-<VERSION_ID>/*.deb;
#   旧布局 <OFFLINE_FILES_ROOT>/os/packages/*.deb 兼容。
# OS 版本优先用 OS_PACKAGES_VERSION; 未设置时从第一个目标节点 /etc/os-release 读取。
# ⚠ 只扫所选目录**顶层** *.deb: chrony 等"专用安装集"放子目录(如 <版本>/chrony/), 不做对账。
_pkg_root="${OFFLINE_FILES_ROOT:-${REPO_ROOT}/deployments/offline-files}/os/packages"
_os_ver="${OS_PACKAGES_VERSION:-}"
if [ -z "${_os_ver}" ] && [ "${#IPS[@]}" -gt 0 ]; then
    _det_key="${SSH_KEY_DIR:-${REAL_HOME:-$HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
    _det_user="${USER:-$(ssh_user_for_ip "${IPS[0]}")}"
    _os_ver="$(ssh -i "${_det_key}" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "${_det_user}@${IPS[0]}" \
        "bash -c '. /etc/os-release; echo \"\$VERSION_ID\"'" 2>/dev/null | tr -d '\r' | head -1 || true)"
    unset _det_key _det_user
fi
if [ -n "${_os_ver}" ] && [ -d "${_pkg_root}/ubuntu-${_os_ver}" ]; then
    DEB_DIRS=("${_pkg_root}/ubuntu-${_os_ver}")
else
    DEB_DIRS=("${_pkg_root}")
fi
# helm/nodejs 单独目录（自动流程安装；手动脚本通过 NODE_PKGS_EXCLUDE_PATTERNS 跳过）
#   helm 在根目录（静态、版本通用）；nodejs 在 ubuntu-<VERSION_ID>/（按目标 OS 适配）。
_helm_dir="$(dirname "${_pkg_root}")/helm-nodejs"
if [ -d "${_helm_dir}" ]; then
    DEB_DIRS+=("${_helm_dir}")
    if [ -d "${_helm_dir}/ubuntu-${_os_ver}" ]; then
        DEB_DIRS+=("${_helm_dir}/ubuntu-${_os_ver}")
    fi
fi
unset _helm_dir
say "目标 OS=${_os_ver:-未知}; 离线包目录=${DEB_DIRS[*]}"
DEBS=()
# NODE_PKGS_EXCLUDE_PATTERNS: 可选 basename glob 排除列表(空格/逗号分隔)。
#   手动安装脚本用它排除 helm/nodejs 等由其他流程负责的包; 默认空 = 行为不变。
_excl_pats="${NODE_PKGS_EXCLUDE_PATTERNS:-}"
if [ -n "${_excl_pats}" ]; then
    say "排除离线包模式: ${_excl_pats}"
fi
for d in "${DEB_DIRS[@]}"; do
    [ -d "${d}" ] || continue
    for f in "${d}"/*.deb; do
        [ -f "${f}" ] || continue
        _base="$(basename "${f}")"
        _skip=0
        if [ -n "${_excl_pats}" ]; then
            for _pat in ${_excl_pats//,/ }; do
                case "${_base}" in ${_pat}) _skip=1; break ;; esac
            done
        fi
        [ "${_skip}" = "1" ] && continue
        DEBS+=("${f}")
    done
done
unset _excl_pats _base _skip _pat 2>/dev/null || true
[ "${#DEBS[@]}" -gt 0 ] || { err "离线目录下没有任何 .deb(${DEB_DIRS[*]})"; exit 1; }
say "离线包: ${#DEBS[@]} 个; 目标节点: ${#IPS[@]} 个"

SSH_KEY="${SSH_KEY_DIR:-${REAL_HOME:-$HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
SSH_OPTS=(-i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8)

# ---------------- 控制器侧前置探测(2026-10-19 实机事故) ----------------
# 在分发离线包/装包之前, 用短超时探测每个节点是否有**旧集群 Ceph/RBD 残留**:
#   ceph/rbd 挂载、/sys/bus/rbd/devices、相关 D 状态进程、fuser 超时。
# 处置策略(2026-11-04 更新):
#   · D 状态 + 存储挂载 = 僵尸态: 默认**不阻断**(覆盖安装口径) —— 只告警、不自动卸载、
#     继续分发/装包, 由后续 Ceph/K8s 覆盖流程重建; 需要回到旧行为时设
#     NODE_PKGS_ALLOW_DSTATE=0(硬失败并给重启指引);
#   · D 状态 / fuser 超时但探测本身无响应(rc=124) 仍失败 —— 拿不到证据, 不能盲目继续;
#   · 挂载不健康但未卡死 → 控制器放行, 由远端脚本自动 stop kubelet/containerd +
#     umount -l/-f + rbd unmap, 成功后继续;
#   · 活动且健康的 Ceph/RBD(当前集群正在用) → 不阻断(避免误伤运行中的 CephFS/RBD PVC)。
NODE_PKGS_ALLOW_DSTATE="${NODE_PKGS_ALLOW_DSTATE:-1}"
_probe="$(cat <<'PROBE'
ceph_mnts=$(timeout 5 findmnt -t ceph,rbd -n -o TARGET,FSTYPE 2>/dev/null | head -5)
# D 状态进程(ps 只读 /proc, 不触碰挂载); 排除 rsync 等仅因含 "sync" 而误匹配的进程。
stuck=$(timeout 5 ps -eo pid,stat,etime,cmd 2>/dev/null | awk '$2 ~ /^D/ && /rbd|ceph|mdadm|initramfs|dpkg|fuser/ && $0 !~ /rsync/' | head -3)
n_rbd=$(ls -1 /sys/bus/rbd/devices 2>/dev/null | wc -l | tr -d ' ')
# ★ 修复的唯一判据 = 逐挂载健康检查: 只有读不出(ls 失败)的 ceph/rbd 挂载才算"存储不健康"。
#   不能把任意 D 状态进程当作存储不健康(2026-11-04 CodeRabbit) —— 否则会卸载/解映射正在使用的健康卷。
#   存在 D 状态时不执行 ls(挂载可能已卡死, ls 会再次挂起), 只做上报。
_bad=""
if [ -n "${ceph_mnts}" ] && [ -z "${stuck}" ]; then
    while read -r _t _f; do
        [ -n "${_t}" ] || continue
        timeout 5 ls "${_t}" >/dev/null 2>&1 || _bad="${_bad} ${_t}"
    done <<< "${ceph_mnts}"
fi
if [ -n "${_bad}" ]; then echo "repair-needed:${_bad}"; exit 0; fi
# D 状态: 有存储挂载时无法安全逐挂载确认 → 不自动卸载(交人工/重启); 无存储挂载 → 与本次无关
if [ -n "${stuck}" ] && [ -n "${ceph_mnts}" ]; then echo "d-state-storage:${stuck}"; exit 0; fi
if [ -n "${stuck}" ]; then echo "d-state-unrelated:${stuck}"; exit 0; fi
[ -n "${ceph_mnts}" ] && echo "active-ceph-ok: $(printf '%s' "${ceph_mnts}" | tr '\n' ' ')"
[ "${n_rbd:-0}" -gt 0 ] && echo "active-rbd-ok: ${n_rbd}"
exit 0
PROBE
)"
# 控制器侧"外科式自动修复"(2026-11-04): 只卸载**逐挂载检查确认读不出**的挂载(由控制器作为
#   参数传入), 绝不碰健康卷; 不对 rbd 设备做 force unmap(可能正被健康 PVC 使用)。
#   挂载被 lazy 摘除后 fuser 不再遍历僵尸挂载, 常见残留可不重启恢复; 仍不健康则交人工/重启。
_repair="$(cat <<'REPAIR'
systemctl stop kubelet containerd 2>/dev/null || true
for _t in "$@"; do
    [ -n "${_t}" ] || continue
    umount -l "${_t}" 2>/dev/null || umount -f "${_t}" 2>/dev/null || true
done
sync -f 2>/dev/null || sync 2>/dev/null || true
# ★ 成功路径也必须恢复 containerd(2026-11-05 实机):
#   后续 k8s 覆盖流程的 `kubeadm reset -f` 是**通过 CRI** 停止/删除旧静态 Pod 容器的。
#   containerd 停着时 reset 只能删文件, 旧容器(shim 存活)继续占 6443/10257/10259
#   → kubespray 随后报 `[ERROR Port-10257]: Port 10257 is in use` 中断部署。
#   只拉起 containerd, **不拉 kubelet** —— 避免旧集群在清理前被重新拉起。
systemctl start containerd 2>/dev/null || true
exit 0
REPAIR
)"
# 修复未成功时恢复服务(2026-11-04, CodeRabbit): _repair 先停了 kubelet/containerd,
#   若重探仍失败, preflight 会 exit 1; 必须把它们重新拉起, 否则节点被留在"服务已停"的
#   不可用状态, 只能等人工处理。仅在重探仍异常时执行(成功路径由 _repair 恢复 containerd、
#   kubelet 留给后续 k8s 覆盖流程)。
_restore="$(cat <<'RESTORE'
systemctl start containerd kubelet 2>/dev/null || true
exit 0
RESTORE
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
_preflight_warn_report=""
for _ip in "${IPS[@]}"; do
    _u="${USER:-$(ssh_user_for_ip "${_ip}")}"
    _out="$(timeout 20 ssh "${SSH_OPTS[@]}" "${_u}@${_ip}" "${_probe}" 2>&1)"
    _rc=$?
    if [ "${_rc}" -eq 124 ]; then
        # 探测本身超时: 没有逐挂载健康信息 → 不做破坏性 repair(避免误伤健康卷)
        _preflight_bad=1
        _preflight_wedged_report="${_preflight_wedged_report}"$'\n'"  ${_u}@${_ip}: 探测超时(SSH 无响应/节点卡死; 无逐挂载健康信息, 不自动修复)"
    elif [ "${_rc}" -eq 255 ]; then
        _preflight_bad=1
        _preflight_ssh_report="${_preflight_ssh_report}"$'\n'"  $(_ssh_fail_reason "${_u}@${_ip}" "${_out}" "${_rc}")"
    elif [ "${_rc}" -ne 0 ]; then
        _preflight_bad=1
        _preflight_probe_report="${_preflight_probe_report}"$'\n'"  ${_u}@${_ip}: 前置探测失败(rc=${_rc}): $(_clean_out "${_out}")"
    else
        case "${_out}" in
            *repair-needed*)
                # 逐挂载健康检查确认"读不出" → 仅卸载这些挂载(不碰健康卷)
                _bad_mnts="${_out#*repair-needed:}"; _bad_mnts="${_bad_mnts%%$'\n'*}"
                _bad_mnts="${_bad_mnts# }"
                say "  ${_ip}: 存储不健康(逐挂载确认读不出:${_bad_mnts}) → 仅自动卸载这些挂载..."
                printf '%s\n' "${_repair}" | timeout 90 ssh "${SSH_OPTS[@]}" "${_u}@${_ip}" "sudo bash -s -- ${_bad_mnts}" >/dev/null 2>&1 || true
                _out="$(timeout 20 ssh "${SSH_OPTS[@]}" "${_u}@${_ip}" "${_probe}" 2>&1)"; _rc=$?
                if [ "${_rc}" -eq 0 ] && ! printf '%s' "${_out}" | grep -q 'repair-needed'; then
                    say "  ${_ip}: 自动卸载后存储恢复, 继续"
                else
                    say "  ${_ip}: 自动卸载后仍不健康 → 恢复 kubelet/containerd 并交人工/重启处理"
                    printf '%s\n' "${_restore}" | timeout 60 ssh "${SSH_OPTS[@]}" "${_u}@${_ip}" "sudo bash -s" >/dev/null 2>&1 || true
                    _preflight_bad=1
                    _preflight_wedged_report="${_preflight_wedged_report}"$'\n'"  ${_u}@${_ip}: 自动卸载后仍不健康(逐挂载检查) —— 需人工/重启"
                fi
                ;;
            *d-state-storage*)
                if [ "${NODE_PKGS_ALLOW_DSTATE}" = "1" ]; then
                    # 覆盖安装口径(2026-11-04 用户): 旧集群 Ceph 已被拆, D 状态 + 陈旧的
                    # ceph 挂载属预期残留; 不卸载(避免误伤), 直接继续分发/装包。
                    warn "  ${_ip}: 存在 D 状态 + 存储挂载(覆盖安装策略: 忽略并继续, 不自动卸载): $(_clean_out "${_out}")"
                    _preflight_warn_report="${_preflight_warn_report}"$'\n'"  ${_u}@${_ip}: D 状态+存储挂载(已忽略, 覆盖安装继续)"
                else
                    say "  ${_ip}: 存在 D 状态且有待存储挂载, 无法安全逐挂载确认 → 不自动卸载(需人工/重启)"
                    _preflight_bad=1
                    _preflight_wedged_report="${_preflight_wedged_report}"$'\n'"  ${_u}@${_ip}: D 状态+存储挂载(未自动卸载): $(_clean_out "${_out}")"
                fi
                ;;
            *d-state-unrelated*)
                say "  ${_ip}: 检测到非存储 D 状态进程(不触发修复, 继续): $(_clean_out "${_out}")"
                ;;
            *active-ceph-ok*|*active-rbd-ok*|*"活动 Ceph/RBD"*)
                say "  ${_ip}: 活动 Ceph/RBD 健康(当前集群在用), 不阻断" ;;
        esac
    fi
done
if [ -n "${_preflight_warn_report}" ]; then
    warn "以下节点存在 D 状态 + 存储挂载残留(覆盖安装策略: 已忽略, 继续装包; 设 NODE_PKGS_ALLOW_DSTATE=0 可恢复硬失败):"
    printf '%s\n' "${_preflight_warn_report}"
fi
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
# 参数: --dry-run / --allow-dstate(跟随控制器侧 NODE_PKGS_ALLOW_DSTATE)
DRY=0; ALLOW_DSTATE=0
for _a in "$@"; do
    case "${_a}" in
        --dry-run) DRY=1 ;;
        --allow-dstate) ALLOW_DSTATE=1 ;;
    esac
done
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
# ★ 2026-11-05 (CodeRabbit): 远端门禁必须跟随控制器侧的 NODE_PKGS_ALLOW_DSTATE
#   （覆盖安装策略）——控制器放行 D 状态时，远端不能无条件 exit 2；但 fuser 超时
#   （无法判断锁持有者）仍必须硬失败。D 状态存在时**不做**挂载健康探测/自动卸载
#   （挂载可能正被僵尸进程引用，卸载不安全）。
_ceph_mnts="$(timeout 5 findmnt -t ceph,rbd -n -o TARGET,FSTYPE 2>/dev/null | head -5 || true)"
_stuck="$(timeout 5 ps -eo pid,stat,etime,cmd 2>/dev/null \
    | awk '$2 ~ /^D/ && /rbd|ceph|mdadm|initramfs|dpkg|sync|fuser/' | head -3 || true)"
_n_rbd="$(ls -1 /sys/bus/rbd/devices 2>/dev/null | wc -l | tr -d ' ' || true)"
timeout 5 fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1
_frc=$?
if [ "${_frc}" -eq 124 ]; then
    echo "         ❌ fuser /var/lib/dpkg/lock-frontend 超时(僵尸态, 无法自动修复, 必须重启):"
    echo "            处置: ① systemctl stop kubelet containerd"
    echo "                  ② systemctl reboot -f   # 跳过卡死的 ceph 卸载"
    echo "                  ③ 重启后再重跑本模块"
    exit 2
fi
_skip_ceph_repair=0
if [ -n "${_stuck}" ]; then
    if [ "${ALLOW_DSTATE}" = "1" ]; then
        echo "         ⚠ 存在 D 状态进程(覆盖安装策略: 忽略并继续, 不自动卸载):"
        echo "${_stuck}" | sed 's/^/            D 状态进程: /'
        _skip_ceph_repair=1
    else
        echo "         ❌ 节点存在 D 状态进程(僵尸态, 无法自动修复, 必须重启):"
        echo "${_stuck}" | sed 's/^/            D 状态进程: /'
        echo "            处置: ① systemctl stop kubelet containerd"
        echo "                  ② systemctl reboot -f   # 跳过卡死的 ceph 卸载"
        echo "                  ③ 重启后再重跑本模块"
        exit 2
    fi
fi
_ceph_bad=""
if [ -n "${_ceph_mnts}" ] && [ "${_skip_ceph_repair}" = "0" ]; then
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
    if [ "${_skip_ceph_repair}" = "1" ]; then
        echo "         ℹ Ceph/RBD 挂载存在(D 状态策略: 未做健康检查/未卸载): ${_ceph_mnts:-无挂载}; rbd=${_n_rbd:-0}; 继续"
    else
        echo "         ℹ 活动 Ceph/RBD(健康, 当前集群在用): ${_ceph_mnts:-无挂载}; rbd=${_n_rbd:-0}; 继续"
    fi
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
# 恢复 initramfs 配置(正常收尾与 EXIT trap 共用): **只有拷回成功才删除备份** ——
# 拷回失败时必须保留备份并提示人工路径, 否则节点会停在 update_initramfs=no 且没有任何
# 可恢复的原配置; 同时**返回非零**, 调用方不得把本次对账报告为成功(2026-11-19 CodeRabbit)。
_ir_restore() {
    [ -n "${_ir_bak}" ] && [ -f "${_ir_bak}" ] || return 0
    if cp -a "${_ir_bak}" "${_ir_conf}"; then
        rm -f "${_ir_bak}"
        return 0
    fi
    echo "         ⚠ 恢复 ${_ir_conf} 失败; 备份保留在 ${_ir_bak} —— 请人工 cp 回该文件(节点当前仍是 update_initramfs=no)"
    return 1
}
if [ "${DRY}" = "0" ] && [ -f "${_ir_conf}" ] && ! grep -qE '^[[:space:]]*update_initramfs[[:space:]]*=[[:space:]]*no' "${_ir_conf}"; then
    _ir_bak="$(mktemp)"
    # ⚠ 备份失败时**不得**继续修改: 否则后续"恢复"会把空 mktemp 文件拷回去
    if cp -a "${_ir_conf}" "${_ir_bak}"; then
        if grep -qE '^[[:space:]]*update_initramfs=' "${_ir_conf}"; then
            sed -i -E 's|^[[:space:]]*update_initramfs=.*|update_initramfs=no|' "${_ir_conf}"
        else
            echo 'update_initramfs=no' >> "${_ir_conf}"
        fi
        echo "         已临时禁用 initramfs 重建(规避 rbd/mdadm 扫描卡死链)"
        # 提前退出(如 [1/4]-[3/4] 发现不健康)也必须恢复配置 → EXIT trap 兜底
        trap _ir_restore EXIT
        trap 'exit 143' HUP INT TERM
    else
        rm -f "${_ir_bak}"; _ir_bak=""
        echo "         ⚠ 备份 ${_ir_conf} 失败 → 跳过临时禁用 initramfs 重建(不做无备份的修改)"
    fi
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
# 正常收尾恢复配置; 恢复失败必须让本节点对账**失败**(节点仍是 update_initramfs=no),
# 不能因为 apt 依赖图健康就报告成功(EXIT trap 仍会兜底重试, 备份保留)。
_ir_rc=0
_ir_restore || _ir_rc=$?
if apt-get check >/dev/null 2>&1; then
    if [ "${_ir_rc}" -ne 0 ]; then
        echo "         ❌ apt 依赖图健康, 但 initramfs 配置恢复失败(节点仍为 update_initramfs=no; 备份路径见上) —— 拒绝报告成功" >&2
        exit 1
    fi
    echo "         ✅ 健康"; exit 0
fi
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
    _args=""
    [ "${DRY}" = "1" ] && _args="${_args} --dry-run"
    [ "${NODE_PKGS_ALLOW_DSTATE}" = "1" ] && _args="${_args} --allow-dstate"
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
