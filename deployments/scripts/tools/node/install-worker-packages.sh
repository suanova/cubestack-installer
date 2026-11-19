#!/bin/bash
# ============================================================
# 离线安装 worker 节点所需系统包(版本感知 + 依赖预检 + 半装修复)
# 将 repository 中的离线 .deb 包复制到目标节点并安装
# 自动从 cluster.conf 读取 SSH 密钥配置
# 用法:
#   ./install-worker-packages.sh [--fresh-node] <IP> [user]   # 直接 SSH 安装
#   ansible-playbook -i <hosts> install-packages.yml          # Ansible 安装
#
# ★ 2026-09-10 加固(扩容 runc `E: Unmet dependencies` 根因):
#   · 按需复制: 本地解析每个 deb 的包名, 远端已装同包 → 跳过(不重复上传/装包;
#     避免离线包版本与节点系统版本漂移破坏依赖, 如 curl 25 vs libcurl4 17)
#   · 依赖预检: deb 的 Depends 必须在"远端已装 ∪ 本次待装"内, 否则 skip(宁缺毋滥, 不破坏 apt;
#     备选按具体包名或 Provides 虚拟名解析, 带版本依赖只认版本化 Provides)
#   · 修复半装: 安装前 dpkg --configure -a + apt-get install -f; 失败再探测半装包清理;
#     修复后**重新探测**状态并重跑依赖/Breaks 校验(apt -f 可能移除已装依赖, 不能用旧结论装包)
#   · 清除系统容器包: 仅当调用方**显式声明 fresh 节点**(--fresh-node 或
#     CUBESTACK_FRESH_NODE=1)且 kubelet 未运行时 purge containerd/containerd.io/runc ——
#     否则 kubespray runc role `apt-get remove runc` 会撞上系统 containerd 的 Depends 冲突;
#     (**在远端探测/选包之前执行**, 保证依赖预检看到的是 purge 后的真实状态;)
#     ⚠ kubelet inactive **不是** fresh 判据: 维护中的已加入 worker 也会停 kubelet,
#       无显式声明时绝不能 purge 其运行时(2026-11-19 CodeRabbit).
#   · 失败不再掩盖: 远端 shell 启用 pipefail, dpkg 退出码显式捕获; 失败 → err 退出
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# fresh 节点显式声明(调用方必须显式给出; 环境变量便于模块/部署流程透传)
FRESH_NODE=0
case "$(printf '%s' "${CUBESTACK_FRESH_NODE:-0}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on) FRESH_NODE=1 ;;
esac
while [ $# -gt 0 ]; do
    case "$1" in
        --fresh-node) FRESH_NODE=1; shift ;;
        --) shift; break ;;
        -*) err "未知参数: $1(用法: $0 [--fresh-node] <IP> [user])"; exit 1 ;;
        *) break ;;
    esac
done

IP="${1:?用法: $0 [--fresh-node] <IP> [user]}"
USER="${2:-ubuntu}"

# 定位离线包目录(REPO_ROOT 由 lib-common.sh 计算,为仓库根目录)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 离线文件根目录(全局变量, load_config 已派生); 包目录 = 当前集群离线资源目录
OFFLINE_FILES_DIR="${OFFLINE_FILES_DIR:-${REPO_ROOT}/deployments/offline-files/kubespray}"
REPO_DIR="${LOCAL_REPO_DIR:-${OFFLINE_FILES_DIR}/${CLUSTER_NAME:-cubestack-cluster}}"
# 离线 .deb 包来源: 仓库根目录 + packages/ 子目录 + 共享 offline-files/os/packages(版本无关 OS 层,
# 2026-10-08 起节点 .deb 统一收敛于此; 原 kubespray/<版本>/packages 已并入)
PKG_DIRS=("${REPO_DIR}" "${REPO_DIR}/packages" "${OFFLINE_FILES_ROOT:-${REPO_ROOT}/deployments/offline-files}/os/packages")

# SSH 密钥配置: 优先 root 默认 id_rsa(物理 worker 已预配 root 免密), 回退 cubestack_k8s
SSH_KEY_DIR="${SSH_KEY_DIR:-${REAL_HOME}/.ssh}"
SSH_KEY_NAME="${SSH_KEY_NAME:-cubestack_k8s}"
if [ -f /root/.ssh/id_rsa ] && [ "${ROOT_SSH:-0}" = "1" ]; then
    SSH_KEY="/root/.ssh/id_rsa"
    SSH_SUDO="sudo"
else
    SSH_KEY="${SSH_KEY_DIR}/${SSH_KEY_NAME}"
    SSH_SUDO=""
fi
SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# 收集所有存在的 .deb 包完整路径(按 basename 去重,优先仓库根目录)
DEBS=()
declare -A DEB_SEEN
for d in "${PKG_DIRS[@]}"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.deb; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        if [ -z "${DEB_SEEN[$base]:-}" ]; then
            DEB_SEEN["$base"]=1
            DEBS+=("$f")
        fi
    done
done
[ "${#DEBS[@]}" -gt 0 ] || { err "未找到离线 .deb 包: ${REPO_DIR} 或 ${REPO_DIR}/packages"; exit 1; }

[ -f "${SSH_KEY}" ] || { err "SSH 密钥不存在: ${SSH_KEY}"; exit 1; }

# ── 本地解析 deb 包名(dpkg-deb 优先; 无 dpkg-deb 时按 <name>_<version>_<arch>.deb 文件名解析,
#    Debian 规范中包名/版本均不含下划线, 按 _ 切 3 段安全) ──
deb_pkg_name() {   # <deb路径> → 包名
    local f="$1"
    if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -f "$f" Package 2>/dev/null && return 0
    fi
    local base="${f##*/}"
    base="${base%.deb}"
    echo "${base%%_*}"
}
deb_depends() {   # <deb路径> → Depends 原文(无 dpkg-deb 时为空=跳过预检)
    local f="$1"
    if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -f "$f" Depends 2>/dev/null || true
    fi
}

# Debian 版本约束比较(<version> <operator> <required>)
# 支持 <<, <=, =, >=, >> 以及旧写法 <, >.
_deb_ver_ok() {
    [ -n "$1" ] || return 1
    case "$2" in
        "<<"|"<") dpkg --compare-versions "$1" lt "$3" ;;
        "<=")     dpkg --compare-versions "$1" le "$3" ;;
        "=")      dpkg --compare-versions "$1" eq "$3" ;;
        ">=")     dpkg --compare-versions "$1" ge "$3" ;;
        ">>"|">") dpkg --compare-versions "$1" gt "$3" ;;
        *) return 0 ;;
    esac
}

# 一组 Provides 提供者(记录行: 包名<TAB>提供版本)是否满足依赖备选。
# dpkg 语义: 无版本 Provides 只满足无版本依赖; 带版本依赖要求版本化 Provides 且版本满足。
_dep_prov_ok() { # <提供者记录> <op> <要求版本>
    local vals="$1" op="$2" req="$3" pkg ver
    [ -n "${vals}" ] || return 1
    while IFS=$'\t' read -r pkg ver; do
        [ -n "${pkg}" ] || continue
        if [ -z "${op}" ]; then
            return 0
        fi
        [ -n "${ver}" ] || continue
        _deb_ver_ok "${ver}" "${op}" "${req}" && return 0
    done <<< "${vals}"
    return 1
}

# 本次待装集合里有满足约束的 Provides 吗(数据: _off_prov_by_pkg[包名]="虚拟名<TAB>版本";
# 用 NEED_SET 判定"在计划内", 与具体包名检查同一口径, 且对同轮新加入的候选同样生效)
_dep_planned_prov_ok() { # <虚拟名> <op> <要求版本>
    local virt="$1" op="$2" req="$3" p _vn _vv
    [ "${#NEED_SET[@]}" -gt 0 ] || return 1
    for p in "${!NEED_SET[@]}"; do
        [ -n "${_off_prov_by_pkg[$p]:-}" ] || continue
        while IFS=$'\t' read -r _vn _vv; do
            [ "${_vn}" = "${virt}" ] || continue
            if [ -z "${op}" ]; then
                return 0
            fi
            [ -n "${_vv}" ] && _deb_ver_ok "${_vv}" "${op}" "${req}" && return 0
        done <<< "${_off_prov_by_pkg[$p]}"
    done
    return 1
}

# ── fresh 节点准备: 必须在 inventory/选包之前清除系统容器包 ──
# purge 会删除 runc/containerd; 若先探测再 purge, REMOTE_VER 会把已删的 runc 当成
# 满足依赖, 随后 dpkg -i 失败. 因此这里先做破坏性清理, 再探测, 选包基于 purge 后状态.
# ⚠ 只有**调用方显式声明 fresh 节点**(--fresh-node / CUBESTACK_FRESH_NODE=1)才进入:
#   kubelet inactive 不能作为判据 —— 维护中的已加入 worker 也会停 kubelet, 误 purge
#   会毁掉节点运行时与已 join 的状态(2026-11-19 CodeRabbit).
if [ "${FRESH_NODE}" = "1" ]; then
    say "检查 fresh 节点系统容器包(containerd/containerd.io/runc)..."
    PRE_PURGE_LOG="$(mktemp)"
    PRE_PURGE_PAYLOAD="$(cat <<'PRE_PURGE'
set -o pipefail
if [ "$(systemctl is-active kubelet 2>/dev/null)" != "active" ]; then
    echo "--- [pre] 已声明 fresh 且 kubelet 未运行: 清理系统容器包(containerd/containerd.io/runc) ---"
    apt-get purge -y containerd containerd.io runc 2>&1 | tail -5
else
    echo "--- [pre] 已声明 fresh 但 kubelet active: 跳过系统容器包清理 ---"
fi
PRE_PURGE
)"
    if ! ${SSH_SUDO} ssh ${SSH_OPTS} -o BatchMode=yes -o ConnectTimeout=15 "${USER}@${IP}" \
        "sudo bash -s" <<< "${PRE_PURGE_PAYLOAD}" > "${PRE_PURGE_LOG}" 2>&1; then
        warn "fresh 节点系统容器包清理失败(继续; 后续按节点实际状态探测):"
        tail -5 "${PRE_PURGE_LOG}" | sed 's/^/      /' >&2
    elif [ -s "${PRE_PURGE_LOG}" ]; then
        tail -3 "${PRE_PURGE_LOG}" | sed 's/^/    /'
    fi
    rm -f "${PRE_PURGE_LOG}"
    unset PRE_PURGE_LOG PRE_PURGE_PAYLOAD
else
    say "未声明 fresh 节点(如需清理系统 containerd/runc, 显式传 --fresh-node 或 CUBESTACK_FRESH_NODE=1); 跳过系统容器包清理"
fi

# ── 远端探测(可重复调用: 初次选包 / 远端修复后重新校验) ──
# 成功: probe_out 含完成哨兵; 失败: 重试 3 次后返回 1(调用方决定是否中止)。
# ⚠ 绝不能把失败当"空清单": 空清单会让所有离线包都被当成"未安装",
#   已装的更新版本可能被离线旧版本重装/降级。
_probe_remote() {
    local rf errf ok=0 try=0
    rf="$(mktemp)"; errf="$(mktemp)"
    cat > "${rf}" <<'PROBE_EOF'
#!/bin/bash
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
# 状态码: ii=正常安装(唯一可用状态); rc=仅剩配置文件; hi/iU/iF/iH=半装/解包未配置;
#   其他非 ii 状态(如有版本残留)一律不算已装, 不能用来跳过离线包或满足依赖。
dpkg-query -W -f='pkg|${db:Status-Abbrev}|${Package}|${Version}\n' 2>/dev/null | grep -E '^pkg\|' || true
# Provides(虚拟包)清单: 依赖备选可能是虚拟名(如 virt-foo (>= 2) 由 Provides: virt-foo (= 2) 满足)
dpkg-query -W -f='prov|${db:Status-Abbrev}|${Package}|${Provides}\n' 2>/dev/null | grep -E '^prov\|' || true
echo "kubelet_running=$([ "$(systemctl is-active kubelet 2>/dev/null)" = "active" ] && echo 1 || echo 0)"
# 完成哨兵: 只有整段探测脚本跑到这里才算有效清单(失联/截断的输出不能当"空清单")
echo "probe_done=1"
PROBE_EOF
    probe_out=""
    while [ "${try}" -lt 3 ]; do
        try=$((try + 1))
        if ! probe_out="$(${SSH_SUDO} ssh ${SSH_OPTS} -o BatchMode=yes -o ConnectTimeout=10 \
                "${USER}@${IP}" "bash -s" < "${rf}" 2>"${errf}")"; then
            probe_out=""
        elif [[ "${probe_out}" != *"probe_done=1"* ]]; then
            # SSH 返回 0 但输出截断/不完整(缺完成哨兵) → 同样视为探测失败
            probe_out=""
        else
            ok=1; break
        fi
        if [ "${try}" -lt 3 ]; then
            warn "  包清单探测失败(第 ${try}/3 次, SSH 不可达或输出不完整), 2s 后重试 ..."
            sleep 2
        fi
    done
    rm -f "${rf}"
    if [ "${ok}" != "1" ]; then
        err "远程包清单探测失败(节点 ${IP}; SSH 不可达或输出不完整)"
        [ -s "${errf}" ] && tail -5 "${errf}" | sed 's/^/      /' >&2
        rm -f "${errf}"
        return 1
    fi
    rm -f "${errf}"
    return 0
}

say "探测节点 ${IP} 已装包状态/版本 ..."
if ! _probe_remote; then
    err "  拒绝在空/残缺清单上继续选包: 空清单会把已装包当成未装(可能用离线旧版本覆盖重装); 请修复 SSH/权限后重跑"
    exit 1
fi

# 解析远端状态 → REMOTE_VER(仅 ii=可用已装)/REMOTE_BROKEN(非 ii 且有版本)/
#   REMOTE_PROV(已装包的 Provides: 虚拟名 → "提供者包<TAB>提供版本" 多行)/
#   REMOTE_CONFIG_ONLY(rc=仅剩配置文件)/REMOTE_KUBELET
# 可重复调用(修复后重新探测): 每次清空并按 probe_out 重建。
declare -A REMOTE_VER REMOTE_BROKEN REMOTE_CONFIG_ONLY REMOTE_PROV
_parse_probe() {
    REMOTE_VER=(); REMOTE_BROKEN=(); REMOTE_CONFIG_ONLY=(); REMOTE_PROV=()
    REMOTE_KUBELET=0
    while IFS= read -r rline; do
        [ -z "${rline}" ] && continue
        case "${rline}" in
            kubelet_running=*) REMOTE_KUBELET="${rline#kubelet_running=}" ;;
            pkg\|*)
                rrest="${rline#pkg|}"; rst="${rrest%%|*}"; rrest="${rrest#*|}"
                # dpkg-query 的 ${db:Status-Abbrev} 带尾随空格("ii "/"rc "); 归一化后再比较.
                rst="$(printf '%s' "${rst}" | tr -d '[:space:]')"
                rname="${rrest%%|*}"; rver="${rrest#*|}"
                # 只有 ii(install ok installed) 才算可用已装; rc(config-files)/
                # hi/iU/iF/iH 等状态不满足依赖, 也不能用来跳过离线包.
                case "${rst}" in
                    ii) REMOTE_VER["${rname}"]="${rver}" ;;
                    *)
                        if [ -n "${rver}" ]; then
                            REMOTE_BROKEN["${rname}"]="${rst}"
                            [ "${rst}" = "rc" ] && REMOTE_CONFIG_ONLY["${rname}"]=1
                        fi ;;
                esac
                ;;
            prov\|*)
                # 只有 ii 的提供者算可用; 无版本 Provides 仅满足无版本依赖(由 _dep_prov_ok 判定).
                prest="${rline#prov|}"; pst="${prest%%|*}"; prest="${prest#*|}"
                pst="$(printf '%s' "${pst}" | tr -d '[:space:]')"
                ppkg="${prest%%|*}"; praw="${prest#*|}"
                [ "${pst}" = "ii" ] && [ -n "${praw}" ] && [ -n "${ppkg}" ] || continue
                IFS=',' read -ra _pvents <<< "${praw}"
                for _pe in "${_pvents[@]}"; do
                    _pe="$(printf '%s' "${_pe}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
                    [ -n "${_pe}" ] || continue
                    _pn="${_pe%%(*}"; _pv=""
                    case "${_pe}" in
                        *'('*)
                            _pv="${_pe#*(}"; _pv="${_pv%%)*}"
                            _pv="$(printf '%s' "${_pv}" | tr -d '[:space:]')"
                            _pv="${_pv#=}" ;;
                    esac
                    _pn="$(printf '%s' "${_pn}" | tr -d '[:space:]')"
                    [ -n "${_pn}" ] || continue
                    REMOTE_PROV["${_pn}"]="${REMOTE_PROV[${_pn}]:-}${ppkg}"$'\t'"${_pv}"$'\n'
                done ;;
        esac
    done <<< "${probe_out}"
    unset prest pst ppkg praw _pvents _pe _pn _pv
}
_parse_probe

# ── 逐个 deb: 解析包名, 决定本次是否需要安装 ──
# 规则:
#   ① 远端已装同包(任何版本)→ 跳过(避免离线版本与系统版本漂移破坏依赖, 如 curl 25 vs libcurl4 17)
#   ② 待装集合: 仅"未装"的 deb; 再校验其 Depends 能在(远端已装 ∪ 待装)内满足, 否则 skip + warn
NEED_DEBS=()        # 待复制/安装的 deb 路径
NEED_PKGS=()        # 对应包名
DEP_SKIPPED=()      # 依赖不可满足而跳过的包(最终必须非零退出, 不能报告全量成功)
declare -A NEED_SET DEB_PKG_SET
for f in "${DEBS[@]}"; do
    pkg="$(deb_pkg_name "$f")"
    [ -n "${pkg}" ] || { warn "无法解析 deb 包名: $(basename "$f"), 跳过"; continue; }
    DEB_PKG_SET["${pkg}"]=1
    # ★ 2026-10-14 重构(P0): 互斥提供者判定改为共享表(lib-common::pkg_conflict_providers,
    #   与节点侧 _pkg_conflict_providers 同步; 夹具断言两处一致)—— 不再手写单个包名。
    #   语义: 本工具只"补缺"; 若待装包的互斥提供者任一已装 → 跳过(保持节点既有口径 ——
    #   如 VM 黄金镜像带 chrony 时跳过 timesyncd)。实机血证: 10-14 直接装 timesyncd
    #   撞 dpkg "conflicts with time-daemon" 整批中止。
    _cp_conflict=0
    for _cp in $(pkg_conflict_providers "${pkg}"); do
        [ -n "${REMOTE_VER[${_cp}]:-}" ] && { _cp_conflict=1; break; }
    done
    if [ "${_cp_conflict}" = "1" ]; then
        warn "  [${pkg}] 节点已装互斥提供者(time-daemon 系只允许一个), 跳过(保持既有口径)"
        continue
    fi
    if [ -n "${REMOTE_VER[${pkg}]:-}" ]; then
        vlog "  [${pkg}] 已正常安装 ${REMOTE_VER[${pkg}]}(离线包不重复装), 跳过"
        continue
    fi
    if [ -n "${REMOTE_BROKEN[${pkg}]:-}" ]; then
        warn "  [${pkg}] 节点状态=${REMOTE_BROKEN[${pkg}]}(非 ii, 不算可用已装); 将重新安装/修复"
    fi
    NEED_DEBS+=("$f"); NEED_PKGS+=("${pkg}"); NEED_SET["${pkg}"]=1
done

# ── ①b Breaks 预判 + 同版本 cohort 升级(2026-10-19 实机根因) ──
# 场景: worker 未装 udev, 离线 udev=249.11-0ubuntu3.22 `Breaks: systemd (<< 249.11-0ubuntu3.22)`,
#   而节点 systemd=3.21 已装。规则①"已装同包→跳过"让 systemd 升级版没进本次安装集合,
#   只 dpkg -i udev → "installing udev would break systemd" 失败(实机 192.0.2.215/.204)。
# 处理: 把 Breaks 指向的已装包**同版本 cohort**(离线集里所有同版本 deb, 如 systemd/
#   libsystemd0/libudev1/systemd-sysv/libnss-systemd/libpam-systemd=3.22)一并加入本次安装,
#   dpkg -i 原子升级整组; 若离线集没有可满足的升级版, 跳过该 deb 并告警(不制造半装/混合态)。
if [ "${#NEED_DEBS[@]}" -gt 0 ] && command -v dpkg-deb >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1; then
    declare -A DEB_BY_PKG=() DEB_VER_BY_PKG=() FORCE_COHORT=()
    for f in "${DEBS[@]}"; do
        p="$(deb_pkg_name "$f")"; [ -n "$p" ] || continue
        v="$(dpkg-deb -f "$f" Version 2>/dev/null || true)"; [ -n "$v" ] || continue
        if [ -z "${DEB_BY_PKG[${p}]:-}" ] || dpkg --compare-versions "$v" gt "${DEB_VER_BY_PKG[${p}]}"; then
            DEB_BY_PKG["${p}"]="$f"; DEB_VER_BY_PKG["${p}"]="$v"
        fi
    done
    _kept_debs=(); _kept_pkgs=()
    for i in "${!NEED_DEBS[@]}"; do
        f="${NEED_DEBS[$i]}"; pkg="${NEED_PKGS[$i]}"
        _breaks="$(dpkg-deb -f "$f" Breaks 2>/dev/null || true)"
        _bad=0
        if [ -n "${_breaks}" ]; then
            while IFS=',' read -ra _bgroups; do
                for _bgrp in "${_bgroups[@]}"; do
                    [ -n "${_bgrp// /}" ] || continue
                    _bn="$(printf '%s' "$_bgrp" | sed -E 's/^[[:space:]]*([^ (]+).*/\1/')"
                    _inst="${REMOTE_VER[${_bn}]:-}"
                    [ -n "${_inst}" ] || continue
                    # 只处理 "name (<< ver)" / "name (<= ver)" 等带版本约束的形态
                    _op="$(printf '%s' "$_bgrp" | sed -nE 's/.*\(([<>]{1,2}=?|=)[[:space:]]*([^)]+)\).*/\1/p')"
                    _bv="$(printf '%s' "$_bgrp" | sed -nE 's/.*\(([<>]{1,2}=?|=)[[:space:]]*([^)]+)\).*/\2/p')"
                    [ -n "${_op}" ] && [ -n "${_bv}" ] || continue
                    _conflict=0
                    case "${_op}" in
                        "<<") dpkg --compare-versions "${_inst}" lt "${_bv}" && _conflict=1 ;;
                        "<=") dpkg --compare-versions "${_inst}" le "${_bv}" && _conflict=1 ;;
                        "=")  dpkg --compare-versions "${_inst}" eq "${_bv}" && _conflict=1 ;;
                        ">=") dpkg --compare-versions "${_inst}" ge "${_bv}" && _conflict=1 ;;
                        ">>") dpkg --compare-versions "${_inst}" gt "${_bv}" && _conflict=1 ;;
                    esac
                    [ "${_conflict}" = "1" ] || continue
                    _upv="${DEB_VER_BY_PKG[${_bn}]:-}"
                    if [ -z "${_upv}" ]; then
                        warn "  [${pkg}] Breaks ${_bn} (${_op} ${_bv}), 节点已装 ${_inst} 且离线集无该包升级版 → 跳过(不制造半装)"
                        _bad=1; break
                    fi
                    _still=0
                    case "${_op}" in
                        "<<") dpkg --compare-versions "${_upv}" lt "${_bv}" && _still=1 ;;
                        "<=") dpkg --compare-versions "${_upv}" le "${_bv}" && _still=1 ;;
                        "=")  dpkg --compare-versions "${_upv}" eq "${_bv}" && _still=1 ;;
                        ">=") dpkg --compare-versions "${_upv}" ge "${_bv}" && _still=1 ;;
                        ">>") dpkg --compare-versions "${_upv}" gt "${_bv}" && _still=1 ;;
                    esac
                    if [ "${_still}" = "1" ]; then
                        warn "  [${pkg}] Breaks ${_bn} (${_op} ${_bv}); 离线升级版 ${_upv} 仍不满足 → 跳过"
                        _bad=1; break
                    fi
                    vlog "  [${pkg}] Breaks ${_bn} (${_op} ${_bv}) → 同版本 cohort 升级 ${_bn}=${_upv}"
                    FORCE_COHORT["${_upv}"]=1
                done
                [ "${_bad}" = "1" ] && break
            done <<< "${_breaks}"
        fi
        if [ "${_bad}" = "0" ]; then _kept_debs+=("$f"); _kept_pkgs+=("${pkg}"); fi
    done
    NEED_DEBS=("${_kept_debs[@]}"); NEED_PKGS=("${_kept_pkgs[@]}")
    NEED_SET=(); for _kp in "${NEED_PKGS[@]}"; do NEED_SET["${_kp}"]=1; done
    if [ "${#FORCE_COHORT[@]}" -gt 0 ]; then
        for f in "${DEBS[@]}"; do
            v="$(dpkg-deb -f "$f" Version 2>/dev/null || true)"
            [ -n "${FORCE_COHORT[${v}]:-}" ] || continue
            p="$(deb_pkg_name "$f")"; [ -n "$p" ] || continue
            # cohort 是"整版本组"批量加入, 会绕过上面的互斥预检 —— time-daemon 系必须在这里
            # 再挡一次: systemd-timesyncd Conflicts: time-daemon, 节点已装 chrony 时 dpkg -i
            # 会因冲突整批失败(2026-10-19 实机解决 udev 问题时发现)。
            if [ "${p}" = "systemd-timesyncd" ]; then
                _td_installed=0
                for _tdp in $(pkg_conflict_providers "${p}"); do
                    [ -n "${REMOTE_VER[${_tdp}]:-}" ] && { _td_installed=1; break; }
                done
                unset _tdp
                if [ "${_td_installed}" = "1" ]; then
                    vlog "  [${p}] 节点已装 time-daemon 提供者 → cohort 中跳过(保持既有口径)"
                    continue
                fi
            fi
            if [ -z "${NEED_SET[${p}]:-}" ] && ! _plan_blocked "${p}"; then
                vlog "  [${p}] 同版本 cohort 升级(版本 ${v}) → 加入本次安装"
                NEED_DEBS+=("$f"); NEED_PKGS+=("${p}"); NEED_SET["${p}"]=1
                _plan_epoch=$((_plan_epoch + 1))
            fi
        done
    fi
fi

# 被裁剪阶段(时间提供者互斥 / Breaks 复核)移除的包名: 依赖解析不得把它们重新加回计划,
# 否则"依赖检查加回 → 裁剪再移除"会无限振荡。跨轮次保留, 只在最终计划中缺席。
PLAN_BLOCKED=()
# Breaks 复核累计剔除的包(跨轮次保留, 最终必须非零退出/报告)
BREAKS_SKIPPED=()

# 计划指纹(按 deb basename 排序; 含 PLAN_BLOCKED): 外层 fixpoint 判断计划是否仍在变化。
# 把"已禁止回加"的包也算进指纹 —— 只有计划与禁用集都相同, 后续轮次才会确定性重复。
_plan_sig() {
    { printf '%s\n' ${NEED_DEBS[@]+"${NEED_DEBS[@]}"}
      printf 'blocked:%s\n' ${PLAN_BLOCKED[@]+"${PLAN_BLOCKED[@]}"}; } \
        | sed 's#.*/##' | sort -u | paste -sd ',' -
}

# 该包名是否已被裁剪阶段移除(不得由依赖解析重新加入)
_plan_blocked() { # <包名>
    local x="$1" e
    for e in ${PLAN_BLOCKED[@]+"${PLAN_BLOCKED[@]}"}; do
        [ "${e}" = "${x}" ] && return 0
    done
    return 1
}

# ── 计划裁剪单遍: 依赖预检(②) → 时间提供者互斥 → Breaks 复核 ──
# 三步互相影响, 单独跑一遍不保证最终计划自洽:
#   · 依赖检查通过的前提可能被后面的时间提供者选择破坏(计划里 chrony 与
#     systemd-timesyncd 并存时, 依赖 systemd-timesyncd 的包先通过; 提供者只留
#     chrony 后该包依赖悬空);
#   · Breaks 复核会移除包, 而其他包的依赖可能还指向它。
# 因此由调用处的 fixpoint 反复执行本函数, 直到一遍下来计划不再变化;
# 裁剪阶段移除的包进入 PLAN_BLOCKED, 依赖解析不会把它们重新加回。
_prune_plan_once() {
# ② 依赖预检(fixpoint 迭代剔除): Depends 逗号分组(每组内 | 为备选), 每组至少一个备选
#    在(远端已装 ∪ 剩余待装)内且**版本约束满足** → 满足; 否则该 deb 剔除并告警。
#    备选按"具体包名"或"Provides 虚拟名"解析: 带版本依赖只认版本化 Provides 且版本满足
#    (无版本 Provides 不满足带版本依赖, dpkg 语义); 已装包与离线集都要作为提供者。
#    已装版本不满足但离线集有满足约束的升级版 → 选择升级版加入待装集, 下一轮继续校验。
#    最多迭代 10 轮; 出现重复计划(振荡)立即失败; 10 轮仍未收敛也必须失败 ——
#    绝不能带着未稳定的计划进入复制/安装(例: A 要求 B>=2, 离线 B=2 依赖缺失,
#    每轮"加 B→删 B"交替, 旧实现会在第 10 轮留下 A 而不带 B)。
if [ "${#NEED_DEBS[@]}" -gt 0 ] && command -v dpkg-deb >/dev/null 2>&1; then
    # 离线集内每个包的最高版本(用于选择满足 Depends 的升级版);
    # 同时登记 Provides(虚拟包): _off_prov_by_pkg[包名] 供"本次待装"侧判定,
    # _dep_prov_deb/_dep_prov_ver 记录每个虚拟名的版本化提供者(供离线候选选包).
    declare -A _dep_deb_by_pkg=() _dep_ver_by_pkg=() _off_prov_by_pkg=() \
               _dep_prov_deb=() _dep_prov_ver=() _dep_prov_pkg=() _dep_prov_pv=()
    for f in "${DEBS[@]}"; do
        p="$(deb_pkg_name "$f")"; [ -n "$p" ] || continue
        v="$(dpkg-deb -f "$f" Version 2>/dev/null || true)"; [ -n "$v" ] || continue
        if [ -z "${_dep_ver_by_pkg[$p]:-}" ] \
           || dpkg --compare-versions "$v" gt "${_dep_ver_by_pkg[$p]}"; then
            _dep_deb_by_pkg["$p"]="$f"; _dep_ver_by_pkg["$p"]="$v"
        fi
        _provraw="$(dpkg-deb -f "$f" Provides 2>/dev/null || true)"
        [ -n "${_provraw}" ] || continue
        IFS=',' read -ra _pvents <<< "${_provraw}"
        for _pe in "${_pvents[@]}"; do
            _pe="$(printf '%s' "${_pe}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
            [ -n "${_pe}" ] || continue
            _pn="${_pe%%(*}"; _pv=""
            case "${_pe}" in
                *'('*)
                    _pv="${_pe#*(}"; _pv="${_pv%%)*}"
                    _pv="$(printf '%s' "${_pv}" | tr -d '[:space:]')"
                    _pv="${_pv#=}" ;;
            esac
            _pn="$(printf '%s' "${_pn}" | tr -d '[:space:]')"
            [ -n "${_pn}" ] || continue
            _off_prov_by_pkg["$p"]="${_off_prov_by_pkg[$p]:-}${_pn}"$'\t'"${_pv}"$'\n'
            # 无版本 Provides 不满足带版本依赖(dpkg 语义) → 候选只登记版本化 Provides
            [ -n "${_pv}" ] || continue
            if [ -z "${_dep_prov_deb[${_pn}]:-}" ] \
               || dpkg --compare-versions "${_pv}" gt "${_dep_prov_ver[${_pn}]}"; then
                _dep_prov_deb["${_pn}"]="$f"; _dep_prov_ver["${_pn}"]="${_pv}"
                _dep_prov_pkg["${_pn}"]="$p"; _dep_prov_pv["${_pn}"]="$v"
            fi
        done
    done
    unset _provraw _pvents _pe _pn _pv
    _dep_round=0
    _dep_stable=0
    _dep_seen_sigs=""
    while [ "${_dep_round}" -lt 10 ]; do
        _dep_round=$((_dep_round + 1))
        _kept_debs=(); _kept_pkgs=(); _dropped=0; _added=0
        declare -A _need_ver=()
        # 本轮待装集内各包的最高版本
        for i in "${!NEED_DEBS[@]}"; do
            p="${NEED_PKGS[$i]}"
            v="$(dpkg-deb -f "${NEED_DEBS[$i]}" Version 2>/dev/null || true)"
            if [ -n "$v" ] && { [ -z "${_need_ver[$p]:-}" ] \
               || dpkg --compare-versions "$v" gt "${_need_ver[$p]}"; }; then
                _need_ver["$p"]="$v"
            fi
        done
        for i in "${!NEED_DEBS[@]}"; do
            f="${NEED_DEBS[$i]}"; pkg="${NEED_PKGS[$i]}"
            deps="$(deb_depends "$f")"
            # Depends 为空(无依赖或无法解析)→ 视为可装
            if [ -z "${deps}" ]; then
                _kept_debs+=("$f"); _kept_pkgs+=("${pkg}")
                continue
            fi
            dep_ok=1; dep_miss=""
            while IFS=',' read -ra _groups; do
                for _grp in "${_groups[@]}"; do
                    [ -z "${_grp}" ] && continue
                    _grp_ok=0
                    IFS='|' read -ra _alts <<< "${_grp}"
                    for _alt in "${_alts[@]}"; do
                        [ -z "${_alt}" ] && continue
                        # 包名: 去掉版本约束(括号)与架构后缀(:amd64)
                        _dn="$(echo "${_alt}" | sed -E 's/^[[:space:]]*([A-Za-z0-9+.-]+).*/\1/')"
                        # 版本约束(可空)
                        _op="$(printf '%s' "${_alt}" | sed -nE 's/.*\(([<>]{1,2}=?|=)[[:space:]]*([^)]+)\).*/\1/p')"
                        _dv="$(printf '%s' "${_alt}" | sed -nE 's/.*\(([<>]{1,2}=?|=)[[:space:]]*([^)]+)\).*/\2/p')"
                        _dv="$(printf '%s' "${_dv}" | tr -d '[:space:]')"
                        if [ -z "${_op}" ] || [ -z "${_dv}" ]; then
                            # 无版本约束: 已装/本次待装(含升级)或任一 Provides 提供者即可
                            if [ -n "${REMOTE_VER[${_dn}]:-}" ] || [ -n "${NEED_SET[${_dn}]:-}" ] \
                               || _dep_prov_ok "${REMOTE_PROV[${_dn}]:-}" "" "" \
                               || _dep_planned_prov_ok "${_dn}" "" ""; then
                                _grp_ok=1; break
                            fi
                            continue
                        fi
                        # 版本约束: 先看"将被保留"的版本(待装集优先于已装)
                        if [ -n "${NEED_SET[${_dn}]:-}" ]; then
                            _cur="${_need_ver[${_dn}]:-${REMOTE_VER[${_dn}]:-}}"
                        else
                            _cur="${REMOTE_VER[${_dn}]:-}"
                        fi
                        if _deb_ver_ok "${_cur}" "${_op}" "${_dv}"; then
                            _grp_ok=1; break
                        fi
                        # 虚拟包(Provides): 只有版本化 Provides 且版本满足才算数
                        # (无版本 Provides 不满足带版本依赖, dpkg 语义; _dep_prov_ok 已强制)
                        if _dep_prov_ok "${REMOTE_PROV[${_dn}]:-}" "${_op}" "${_dv}" \
                           || _dep_planned_prov_ok "${_dn}" "${_op}" "${_dv}"; then
                            _grp_ok=1; break
                        fi
                        # 当前版本不满足: 选择离线集中满足约束且高于当前版本的升级版
                        # (被裁剪阶段移除的包不得重新加回 → 否则"加回→再裁剪"振荡)
                        _cand_v="${_dep_ver_by_pkg[${_dn}]:-}"
                        if ! _plan_blocked "${_dn}" && _deb_ver_ok "${_cand_v}" "${_op}" "${_dv}"; then
                            _upgrade_ok=1
                            if [ -n "${_cur}" ] \
                               && ! dpkg --compare-versions "${_cand_v}" gt "${_cur}"; then
                                _upgrade_ok=0   # 只接受升级, 不做隐性降级
                            fi
                            # 不能为满足依赖引入与已装/待装提供者冲突的包
                            if [ "${_upgrade_ok}" = "1" ]; then
                                _up_conflict=0
                                for _ucp in $(pkg_conflict_providers "${_dn}"); do
                                    [ -n "${REMOTE_VER[${_ucp}]:-}" ] && { _up_conflict=1; break; }
                                    [ -n "${NEED_SET[${_ucp}]:-}" ] && { _up_conflict=1; break; }
                                done
                                if [ "${_up_conflict}" = "0" ]; then
                                    _kept_debs+=("${_dep_deb_by_pkg[${_dn}]}")
                                    _kept_pkgs+=("${_dn}")
                                    NEED_SET["${_dn}"]=1
                                    _need_ver["${_dn}"]="${_cand_v}"
                                    _added=1
                                    _grp_ok=1; break
                                fi
                            fi
                        fi
                        # 虚拟依赖的离线候选: 版本化 Provides 满足约束的提供者 deb
                        # (已装提供者未满足 → 只接受"未装"或"提供者包可升级"的情形;
                        #  被裁剪阶段移除的提供者包不得重新加回)
                        _pcand_deb="${_dep_prov_deb[${_dn}]:-}"
                        _ppkg="${_dep_prov_pkg[${_dn}]:-}"
                        _ppv="${_dep_prov_pv[${_dn}]:-}"
                        if [ -n "${_pcand_deb}" ] && ! _plan_blocked "${_ppkg}" \
                           && _deb_ver_ok "${_dep_prov_ver[${_dn}]:-}" "${_op}" "${_dv}"; then
                            _upgrade_ok=1
                            if [ -n "${NEED_SET[${_ppkg}]:-}" ]; then
                                # 已在计划中却没通过上面的 planned 检查 → 不能靠重复加入绕过
                                _upgrade_ok=0
                            elif [ -n "${REMOTE_VER[${_ppkg}]:-}" ] \
                               && ! dpkg --compare-versions "${_ppv}" gt "${REMOTE_VER[${_ppkg}]}"; then
                                _upgrade_ok=0   # 已装且不是升级 → 不做降级/同版重装
                            fi
                            if [ "${_upgrade_ok}" = "1" ]; then
                                _up_conflict=0
                                for _ucp in $(pkg_conflict_providers "${_ppkg}"); do
                                    [ -n "${REMOTE_VER[${_ucp}]:-}" ] && { _up_conflict=1; break; }
                                    [ -n "${NEED_SET[${_ucp}]:-}" ] && { _up_conflict=1; break; }
                                done
                                if [ "${_up_conflict}" = "0" ]; then
                                    _kept_debs+=("${_pcand_deb}")
                                    _kept_pkgs+=("${_ppkg}")
                                    NEED_SET["${_ppkg}"]=1
                                    _added=1
                                    _grp_ok=1; break
                                fi
                            fi
                        fi
                    done
                    if [ "${_grp_ok}" != "1" ]; then dep_ok=0; dep_miss="${_grp}"; break; fi
                done
            done <<< "${deps}"
            if [ "${dep_ok}" = "1" ]; then
                _kept_debs+=("$f"); _kept_pkgs+=("${pkg}")
            else
                warn "  [${pkg}] 依赖不可满足(${dep_miss}), 本次跳过(不破坏 apt 状态)"
                DEP_SKIPPED+=("${pkg}")
                _dropped=1
            fi
        done
        NEED_DEBS=("${_kept_debs[@]}"); NEED_PKGS=("${_kept_pkgs[@]}")
        NEED_SET=()
        for _kp in "${NEED_PKGS[@]}"; do NEED_SET["${_kp}"]=1; done
        if [ "${_dropped}" = "0" ] && [ "${_added}" = "0" ]; then
            _dep_stable=1; break
        fi
        _plan_epoch=$((_plan_epoch + 1))
        # 振荡检测: 同一待装集再次出现 → 后续轮次只会无限重复(加→删→加…),
        # 必须在这里失败, 而不是带着残缺计划去复制/安装。
        _sig="$(printf '%s\n' ${NEED_DEBS[@]+"${NEED_DEBS[@]}"} \
                | sed 's#.*/##' | sort -u | paste -sd ',' -)"
        if [ -n "${_sig}" ] && [ -n "${_dep_seen_sigs}" ]; then
            case "|${_dep_seen_sigs}|" in
                *"|${_sig}|"*)
                    err "依赖解析出现振荡(待装集重复: ${_sig}); 拒绝继续选包(不进入复制/安装)"
                    err "  典型原因: 离线升级版自身依赖不可满足, 而其他包又要求该升级版; 请补齐离线依赖闭包"
                    exit 1 ;;
            esac
        fi
        _dep_seen_sigs="${_dep_seen_sigs:+${_dep_seen_sigs}|}${_sig}"
    done
    if [ "${_dep_stable}" != "1" ]; then
        err "依赖解析在 10 轮内未收敛(仍有包在添加/剔除); 拒绝继续选包(不进入复制/安装)"
        err "  常见原因: 离线集依赖闭包不完整或版本互相牵制; 请补齐 .deb 后重跑"
        exit 1
    fi
    # 同一包可能因升级选择出现多版本: 只保留最高版本, 避免 dpkg -i 处理顺序不定
    declare -A _best_deb=() _best_ver=()
    for i in "${!NEED_DEBS[@]}"; do
        p="${NEED_PKGS[$i]}"; f="${NEED_DEBS[$i]}"
        v="$(dpkg-deb -f "$f" Version 2>/dev/null || true)"
        if [ -z "${_best_deb[$p]:-}" ] || { [ -n "$v" ] \
           && dpkg --compare-versions "$v" gt "${_best_ver[$p]:-0}"; }; then
            _best_deb["$p"]="$f"; _best_ver["$p"]="${v:-${_best_ver[$p]:-0}}"
        fi
    done
    NEED_DEBS=(); NEED_PKGS=(); NEED_SET=()
    for p in "${!_best_deb[@]}"; do
        NEED_DEBS+=("${_best_deb[$p]}"); NEED_PKGS+=("$p"); NEED_SET["$p"]=1
    done
    unset _dep_deb_by_pkg _dep_ver_by_pkg _off_prov_by_pkg _dep_prov_deb _dep_prov_ver \
          _dep_prov_pkg _dep_prov_pv _pcand_deb _ppkg _ppv _kept_debs _kept_pkgs _need_ver \
          _best_deb _best_ver _dep_stable _dep_seen_sigs _sig
fi

# ── 时间提供者互斥(chrony / systemd-timesyncd / openntpd / ntp 只允许一个) ──
# 已装提供者: 保留它, 移除待装集里的其他提供者(初始循环已按 REMOTE_VER 过滤, 这里兜底 cohort);
# 未装提供者: 在待装集里按 chrony > systemd-timesyncd > openntpd > ntp 选一个,
#   避免两个 provider 一起 dpkg -i 撞 "conflicts with time-daemon".
_td_installed=""
for _tdp in chrony systemd-timesyncd openntpd ntp; do
    [ -n "${REMOTE_VER[${_tdp}]:-}" ] && { _td_installed="${_tdp}"; break; }
done
_td_keep=""
if [ -n "${_td_installed}" ]; then
    _td_keep="${_td_installed}"
else
    for _tdp in chrony systemd-timesyncd openntpd ntp; do
        [ -n "${NEED_SET[${_tdp}]:-}" ] && { _td_keep="${_tdp}"; break; }
    done
fi
if [ -n "${_td_keep}" ]; then
    _kept_debs=(); _kept_pkgs=()
    for i in "${!NEED_DEBS[@]}"; do
        f="${NEED_DEBS[$i]}"; pkg="${NEED_PKGS[$i]}"
        case "${pkg}" in
            chrony|systemd-timesyncd|openntpd|ntp)
                if [ "${pkg}" != "${_td_keep}" ]; then
                    if [ -n "${_td_installed}" ]; then
                        warn "  [${pkg}] 时间提供者互斥: 节点已装 ${_td_keep}; 跳过"
                    else
                        warn "  [${pkg}] 时间提供者互斥: 本次只保留 ${_td_keep}; 跳过"
                    fi
                    # 被互斥选择移除的提供者不得由依赖解析重新加回(否则裁剪-加回振荡)
                    PLAN_BLOCKED+=("${pkg}")
                    _plan_epoch=$((_plan_epoch + 1))
                    continue
                fi ;;
        esac
        _kept_debs+=("$f"); _kept_pkgs+=("${pkg}")
    done
    NEED_DEBS=("${_kept_debs[@]}"); NEED_PKGS=("${_kept_pkgs[@]}")
    NEED_SET=()
    for _kp in "${NEED_PKGS[@]}"; do NEED_SET["${_kp}"]=1; done
fi
unset _td_installed _td_keep _tdp _kept_debs _kept_pkgs _kp i f pkg

# ── Breaks 复核(依赖/提供者裁剪之后): 触发包不能依赖已被裁掉的 cohort 升级 ──
# cohort 预检假设 b=2 会被装上; 若 b=2 后续被依赖预检/提供者选择剔除, 已装 b=1 仍在,
# 触发包的 Breaks b (<< 2) 冲突会重新出现 —— 此时必须把触发包一起从计划移除。
# BREAKS_SKIPPED 已在 fixpoint 外初始化(跨轮次保留)
_br_round=0
_br_stable=0
while [ "${_br_round}" -lt 10 ]; do
    _br_round=$((_br_round + 1))
    declare -A _br_need_ver=()
    for i in "${!NEED_DEBS[@]}"; do
        p="${NEED_PKGS[$i]}"
        v="$(dpkg-deb -f "${NEED_DEBS[$i]}" Version 2>/dev/null || true)"
        if [ -n "$v" ] && { [ -z "${_br_need_ver[$p]:-}" ] \
           || dpkg --compare-versions "$v" gt "${_br_need_ver[$p]}"; }; then
            _br_need_ver["$p"]="$v"
        fi
    done
    _br_remove=(); _br_changed=0
    for i in "${!NEED_DEBS[@]}"; do
        f="${NEED_DEBS[$i]}"; pkg="${NEED_PKGS[$i]}"
        _breaks="$(dpkg-deb -f "$f" Breaks 2>/dev/null || true)"
        [ -n "${_breaks}" ] || continue
        _bad=0; _bad_bn=""
        while IFS=',' read -ra _bgroups; do
            for _bgrp in "${_bgroups[@]}"; do
                [ -n "${_bgrp// /}" ] || continue
                _bn="$(printf '%s' "${_bgrp}" | sed -E 's/^[[:space:]]*([^ (]+).*/\1/')"
                _op="$(printf '%s' "${_bgrp}" | sed -nE 's/.*\(([<>]{1,2}=?|=)[[:space:]]*([^)]+)\).*/\1/p')"
                _bv="$(printf '%s' "${_bgrp}" | sed -nE 's/.*\(([<>]{1,2}=?|=)[[:space:]]*([^)]+)\).*/\2/p')"
                _bv="$(printf '%s' "${_bv}" | tr -d '[:space:]')"
                # 最终会留下的版本: 本次计划优先, 否则已装
                if [ -n "${_br_need_ver[${_bn}]:-}" ]; then
                    _final="${_br_need_ver[${_bn}]}"
                else
                    _final="${REMOTE_VER[${_bn}]:-}"
                fi
                [ -n "${_final}" ] || continue
                if [ -z "${_op}" ] || [ -z "${_bv}" ]; then
                    _bad=1; _bad_bn="${_bn}"; break
                fi
                if _deb_ver_ok "${_final}" "${_op}" "${_bv}"; then
                    _bad=1; _bad_bn="${_bn}"; break
                fi
            done
            [ "${_bad}" = "1" ] && break
        done <<< "${_breaks}"
        if [ "${_bad}" = "1" ]; then
            warn "  [${pkg}] Breaks 与最终计划/已装版本冲突(${_bad_bn}: ${_final}); 从本次安装计划移除"
            _br_remove+=("${pkg}")
            _br_changed=1
        fi
    done
    [ "${_br_changed}" = "0" ] && { _br_stable=1; break; }
    _plan_epoch=$((_plan_epoch + 1))
    _kept_debs=(); _kept_pkgs=()
    for i in "${!NEED_DEBS[@]}"; do
        pkg="${NEED_PKGS[$i]}"
        _skip=0
        for _rp in ${_br_remove[@]+"${_br_remove[@]}"}; do
            [ "${pkg}" = "${_rp}" ] && { _skip=1; break; }
        done
        [ "${_skip}" = "1" ] && continue
        _kept_debs+=("${NEED_DEBS[$i]}"); _kept_pkgs+=("${pkg}")
    done
    for _rp in ${_br_remove[@]+"${_br_remove[@]}"}; do
        _seen=0
        for _sp in ${BREAKS_SKIPPED[@]+"${BREAKS_SKIPPED[@]}"}; do
            [ "${_sp}" = "${_rp}" ] && { _seen=1; break; }
        done
        [ "${_seen}" = "1" ] || { BREAKS_SKIPPED+=("${_rp}"); PLAN_BLOCKED+=("${_rp}"); }
    done
    NEED_DEBS=("${_kept_debs[@]}"); NEED_PKGS=("${_kept_pkgs[@]}")
    NEED_SET=()
    for _kp in "${NEED_PKGS[@]}"; do NEED_SET["${_kp}"]=1; done
done
if [ "${_br_stable}" != "1" ]; then
    err "Breaks 复核在 10 轮内未收敛(移除连锁仍在继续); 拒绝继续选包(不进入复制/安装)"
    exit 1
fi
unset _br_need_ver _br_remove _br_changed _breaks _bn _op _bv _final _bad _bad_bn \
      _kept_debs _kept_pkgs _rp _skip _seen _sp _kp i f pkg _br_stable
}

# ── 计划 fixpoint: 反复执行"依赖预检 → 时间提供者互斥 → Breaks 复核"整遍, ──
# 直到一整遍下来计划没有任何变更(epoch 不变)才允许进入复制/安装。
# 单遍不保证自洽: 依赖检查通过的前提可能被后两步裁剪破坏(例: 计划里同时有 chrony
# 与 systemd-timesyncd, 依赖 systemd-timesyncd 的包先通过; 提供者只留 chrony 后该包
# 依赖悬空; Breaks 移除被依赖的包同理)。被裁剪移除的包进入 PLAN_BLOCKED, 依赖解析
# 不会再把它们加回, 因此该 fixpoint 单调收敛; 若计划集合重复出现(振荡)或 10 遍仍
# 在变化, 直接失败(不进入复制/安装)。
_plan_fixpoint() {
    local _epoch_before=0
    _plan_epoch=0
    _outer_round=0
    _outer_seen=""
    while :; do
        _outer_round=$((_outer_round + 1))
        _epoch_before="${_plan_epoch}"
        _prune_plan_once
        # 整遍无任何变更(依赖/提供者/Breaks 都没动过计划) → 稳定, 可以继续
        [ "${_plan_epoch}" = "${_epoch_before}" ] && break
        _plan_after="$(_plan_sig)"
        if [ -n "${_plan_after}" ] && [ -n "${_outer_seen}" ]; then
            case "|${_outer_seen}|" in
                *"|${_plan_after}|"*)
                    err "计划裁剪出现振荡(待装集重复: ${_plan_after}); 拒绝继续选包(不进入复制/安装)"
                    exit 1 ;;
            esac
        fi
        _outer_seen="${_outer_seen:+${_outer_seen}|}${_plan_after}"
        if [ "${_outer_round}" -ge 10 ]; then
            err "计划裁剪在 10 轮内未收敛(依赖/提供者/Breaks 互相牵制); 拒绝继续选包(不进入复制/安装)"
            exit 1
        fi
    done
    unset _outer_round _outer_seen _plan_after
}
_plan_fixpoint

# 只关心"离线集里存在对应 deb"的破损包: 无关的 rc/半装包不应触发本工具的修复/告警.
BROKEN_RELEVANT=()
for _p in "${!REMOTE_BROKEN[@]}"; do
    [ -n "${DEB_PKG_SET[${_p}]:-}" ] && BROKEN_RELEVANT+=("${_p}")
done
for _p in ${BROKEN_RELEVANT[@]+"${BROKEN_RELEVANT[@]}"}; do
    [ -n "${NEED_SET[${_p}]:-}" ] && continue
    if [ -n "${REMOTE_CONFIG_ONLY[${_p}]:-}" ]; then
        warn "  [${_p}] 仅剩配置文件(rc), 但离线 deb 未进入安装计划(依赖/冲突); 无法自动重装"
    else
        warn "  [${_p}] 状态=${REMOTE_BROKEN[${_p}]}, 离线 deb 未进入安装计划; 已交远端 dpkg/apt 修复"
    fi
done
unset _p

if [ "${#NEED_DEBS[@]}" -eq 0 ] && [ "${#BROKEN_RELEVANT[@]}" -eq 0 ]; then
    _skipped="${DEP_SKIPPED[*]:-} ${BREAKS_SKIPPED[*]:-}"
    if [ -n "${_skipped// /}" ]; then
        err "以下包未按本次计划安装(依赖不可满足/Breaks 冲突):${_skipped}"
        exit 1
    fi
    ok "节点 ${IP} 所需离线包均已正常安装(无需上传/装包)"
    exit 0
fi
unset _skipped

if [ "${#NEED_DEBS[@]}" -gt 0 ]; then
    say "待安装 ${#NEED_DEBS[@]} 个包: ${NEED_PKGS[*]}"
else
    say "离线集无需安装新包; 检测到 ${#BROKEN_RELEVANT[@]} 个半装/仅剩配置包, 执行远端修复 ..."
fi

# ── 远端修复段(幂等): 修半装 + apt 依赖修复 ──
REMOTE_FIX="$(mktemp)"
cat > "${REMOTE_FIX}" <<'FIX_EOF'
#!/bin/bash
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
echo "--- [fix] dpkg --configure -a ---"
dpkg --configure -a 2>&1 | tail -5 || true
echo "--- [fix] apt-get install -f -y ---"
apt-get install -f -y --no-install-recommends 2>&1 | tail -8 || true
# 半装包清理(apt -f 失败兜底): 破损包 force 移除, 再修
BROKEN="$(dpkg-query -W -f='${db:Status-Abbrev}|${Package}\n' 2>/dev/null | grep -E '^(hi|iU|iF|iH)\|' | cut -d'|' -f2 || true)"
if [ -n "${BROKEN}" ]; then
    echo "--- [fix] 破损包清理: ${BROKEN} ---"
    for bp in ${BROKEN}; do
        dpkg --remove --force-remove-reinstreq --force-depends "${bp}" 2>&1 | tail -2 || true
    done
    apt-get install -f -y --no-install-recommends 2>&1 | tail -5 || true
fi
dpkg --audit 2>&1 | tail -5 || true
FIX_EOF

say "执行远端修复(半装/apt 依赖)..."
REPAIR_RC=0
if ! ${SSH_SUDO} ssh ${SSH_OPTS} -o BatchMode=yes -o ConnectTimeout=15 "${USER}@${IP}" \
    "sudo bash -s" < "${REMOTE_FIX}" 2>/dev/null; then
    REPAIR_RC=1
    warn "远端修复部分失败(半装状态可能未完全清理; 继续尝试安装)"
fi
rm -f "${REMOTE_FIX}"

# ── 修复后重新探测包状态并复核计划(2026-11-19 CodeRabbit) ──
# apt-get install -f 的求解不受本计划限制, 可能移除已装依赖/改变版本; 若沿用修复前的
# 探测结论继续复制/安装, 会出现"依赖已被修复动作删掉"的悬空安装。这里用修复后的真实
# 状态重新解析, 并用同一 fixpoint 重跑 Depends 与 Breaks 校验; 探测失败直接停止
# (绝不猜状态、绝不用旧结论进入 staging)。
say "远端修复后重新探测包状态并复核计划 ..."
if ! _probe_remote; then
    err "  无法获取修复后的包状态 → 停止(不能沿用修复前的旧依赖结论继续装包)"
    exit 1
fi
_parse_probe
# 修复后已正常安装(ii)的待装包不再需要安装(与初始"已装即跳过"同口径)
_kept_debs=(); _kept_pkgs=()
for i in "${!NEED_DEBS[@]}"; do
    p="${NEED_PKGS[$i]}"
    if [ -n "${REMOTE_VER[${p}]:-}" ]; then
        vlog "  [${p}] 修复后已正常安装 ${REMOTE_VER[${p}]}, 从本次安装计划移除"
        continue
    fi
    _kept_debs+=("${NEED_DEBS[$i]}"); _kept_pkgs+=("${p}")
done
NEED_DEBS=("${_kept_debs[@]}"); NEED_PKGS=("${_kept_pkgs[@]}")
NEED_SET=()
for _kp in "${NEED_PKGS[@]}"; do NEED_SET["${_kp}"]=1; done
unset _kept_debs _kept_pkgs _kp i p
# 依赖 + Breaks 按修复后状态整体重校验(PLAN_BLOCKED 跨调用保留, 不会回加已裁剪包)
_plan_fixpoint

# 没有待装包但存在相关的半装/仅剩配置(rc)状态: 远端修复已执行; 未进入安装计划的
# 破损包已在上面告警(rc 需要可用 deb; hi/iU 交 dpkg/apt 修复).
if [ "${#NEED_DEBS[@]}" -eq 0 ]; then
    if [ "${REPAIR_RC}" -ne 0 ]; then
        err "远端半装修复失败, 且本次无待安装离线包; 请检查节点 ${IP} 后重跑"
        exit 1
    fi
    # ⚠ 修复成功 ≠ 跳过的包已装上: apt -f/破损清理可能只是把破损包移除。计划里被剔除
    # (依赖不可满足 / Breaks 冲突)的包必须在这里同样报错, 不能从这条"修复成功"路径
    # 静默 exit 0(否则绕过末尾的同一检查)。
    _skipped="${DEP_SKIPPED[*]:-} ${BREAKS_SKIPPED[*]:-}"
    if [ -n "${_skipped// /}" ]; then
        err "以下包未按本次计划安装(依赖不可满足/Breaks 冲突):${_skipped}"
        exit 1
    fi
    unset _skipped
    ok "节点 ${IP} 半装状态已执行修复(无待安装离线包)"
    exit 0
fi

# ── 复制待装包到目标节点 ──
# 重建目标目录(先清: /tmp 陈旧文件属主非本次用户时 scp/rsync 会被 fs.protected_regular 拒, root 也不例外)
${SSH_SUDO} ssh ${SSH_OPTS} "${USER}@${IP}" "sudo rm -rf /tmp/packages && mkdir -p /tmp/packages" 2>/dev/null || true
say "复制 ${#NEED_DEBS[@]} 个离线包到 ${IP}:/tmp/packages/ ..."
for f in "${NEED_DEBS[@]}"; do
    vlog "  复制: $(basename "$f")"
    _copied=0
    if ${SSH_SUDO} rsync -e "ssh ${SSH_OPTS}" "$f" "${USER}@${IP}:/tmp/packages/" 2>/dev/null; then
        _copied=1
    elif ${SSH_SUDO} scp ${SSH_OPTS} "$f" "${USER}@${IP}:/tmp/packages/" 2>/dev/null; then
        _copied=1
    fi
    if [ "${_copied}" != "1" ]; then
        err "离线包复制失败(rsync/scp 均失败): $(basename "$f")"
        exit 1
    fi
    # 传输成功也要核对大小: 截断/半包不能进入 dpkg -i
    _lsz="$(stat -c%s "$f" 2>/dev/null || true)"
    _rsz="$(${SSH_SUDO} ssh ${SSH_OPTS} -o BatchMode=yes -o ConnectTimeout=15 "${USER}@${IP}" \
        "stat -c%s '/tmp/packages/$(basename "$f")'" 2>/dev/null || true)"
    if [ -z "${_lsz}" ] || [ "${_rsz}" != "${_lsz}" ]; then
        err "离线包复制不完整: $(basename "$f")(本地 ${_lsz:-?} / 远端 ${_rsz:-缺失})"
        exit 1
    fi
done
unset _copied _lsz _rsz f

# dpkg -i 前校验远端暂存集完整: 防止"部分上传 + dpkg 装子集后仍报告全量成功"
_expected_names=""
for f in "${NEED_DEBS[@]}"; do _expected_names="${_expected_names} $(basename "$f")"; done
_staged_names="$(${SSH_SUDO} ssh ${SSH_OPTS} -o BatchMode=yes -o ConnectTimeout=15 "${USER}@${IP}" \
    "ls -1 /tmp/packages" 2>/dev/null || true)"
_missing_names=""
for _bn in ${_expected_names}; do
    grep -qxF -- "${_bn}" <<< "${_staged_names}" || _missing_names="${_missing_names} ${_bn}"
done
if [ -n "${_missing_names}" ]; then
    err "以下离线包未成功复制到 ${IP}:/tmp/packages:${_missing_names}"
    exit 1
fi
unset _expected_names _staged_names _missing_names _bn

# ── 安装(dpkg -i; 远端 pipefail 保证 dpkg 失败不被 tail 管道吞掉, 失败显式中止) ──
# ★ 2026-09-24 事故修复: 安装期间临时**禁用 initramfs 重建**, 装完恢复。
#   与 patch-playbooks/install-packages.yml 同一根因(那边已修): `dpkg -i lvm2/dmsetup`
#   → initramfs-tools.postinst → `update-initramfs -u` → `mkinitramfs` → `hooks/mdadm`
#   → `mdadm --examine --scan` 遍历所有块设备 → 若节点上有**后端不可达的内核 rbd 映射/挂死块设备**,
#   进程进 D 状态(不可中断) → 本脚本的 ssh 调用**永不返回**, 表现为部署"卡在这里很长时间"
#   (实测 192.0.2.36 卡 38 分钟以上, mdadm 的 fd 直指 /dev/rbd0)。
#   我们装的包(lvm2 家族)在节点上不需要重建 initrd(内核未变、root 不在 LVM 上), 禁用是安全的。
#   载荷用**引号 heredoc** 构造(仓库既有风格): 免去多层转义, 也便于离线测试。
INSTALL_PAYLOAD="$(cat <<'PAYLOAD'
set -o pipefail
_ir=/etc/initramfs-tools/update-initramfs.conf
_bak=""
if [ -f "${_ir}" ] && ! grep -qE '^[[:space:]]*update_initramfs[[:space:]]*=[[:space:]]*no' "${_ir}"; then
    _bak="$(mktemp)"
    # 备份失败时不得继续修改(否则恢复时会拷回空 mktemp 文件)
    if cp -a "${_ir}" "${_bak}"; then
        if grep -qE '^[[:space:]]*update_initramfs=' "${_ir}"; then
            sed -i -E 's|^[[:space:]]*update_initramfs=.*|update_initramfs=no|' "${_ir}"
        else
            echo 'update_initramfs=no' >> "${_ir}"
        fi
        echo "[install] 本次安装期间已临时禁用 initramfs 重建(避免 mdadm/lvm hooks 扫描块设备而卡死)"
    else
        rm -f "${_bak}"; _bak=""
        echo "[install] ⚠ 备份 ${_ir} 失败 → 跳过临时禁用 initramfs 重建(不做无备份的修改)"
    fi
fi
n_rbd="$(ls -1 /sys/bus/rbd/devices 2>/dev/null | wc -l | tr -d ' ')"
if [ "${n_rbd:-0}" -gt 0 ]; then
    echo "[install] ⚠ 节点存在 ${n_rbd} 个内核 rbd 映射 —— 后端不可达时任何设备扫描都可能卡死; 见 docs/troubleshooting.md"
fi
dpkg -i /tmp/packages/*.deb </dev/null 2>&1 | tail -20
_rc="${PIPESTATUS[0]}"
# 只有拷回成功才删除备份; 失败保留备份并提示路径(节点仍停在 update_initramfs=no)
if [ -n "${_bak}" ] && [ -f "${_bak}" ]; then
    if cp -a "${_bak}" "${_ir}"; then
        rm -f "${_bak}"
    else
        echo "[install] ⚠ 恢复 ${_ir} 失败; 备份保留在 ${_bak} —— 请人工 cp 回该文件(当前仍是 update_initramfs=no)"
    fi
fi
exit "${_rc}"
PAYLOAD
)"
say "安装中 (dpkg -i, 失败将中止; 期间禁用 initramfs 重建) ..."
INSTALL_LOG="$(mktemp)"
if ! ${SSH_SUDO} ssh ${SSH_OPTS} "${USER}@${IP}" "sudo bash -s" <<< "${INSTALL_PAYLOAD}" \
    > "${INSTALL_LOG}" 2>&1; then
    err "dpkg -i 安装失败(节点 ${IP}), 日志:"
    cat "${INSTALL_LOG}" >&2 || true
    err "  可能原因: 离线包版本与节点系统不匹配 / 依赖缺失"
    err "  修复动作(apt-get install -f / 半装清理)已执行过; 重跑本脚本会先清理半装再重试"
    rm -f "${INSTALL_LOG}"
    exit 1
fi
cat "${INSTALL_LOG}" || true
rm -f "${INSTALL_LOG}"

# ── 安装后: apt -f 收尾修复 + 清理临时包目录 ──
${SSH_SUDO} ssh ${SSH_OPTS} "${USER}@${IP}" \
    "sudo apt-get install -f -y --no-install-recommends 2>&1 | tail -5; sudo rm -rf /tmp/packages" 2>/dev/null || true

_skipped="${DEP_SKIPPED[*]:-} ${BREAKS_SKIPPED[*]:-}"
if [ -n "${_skipped// /}" ]; then
    err "以下包未按本次计划安装(依赖不可满足/Breaks 冲突):${_skipped}"
    exit 1
fi
unset _skipped

ok "✅ ${IP} 离线包安装完成: ${NEED_PKGS[*]}"
