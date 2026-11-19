#!/bin/bash
# ============================================================
# 离线安装 worker 节点所需系统包(版本感知 + 依赖预检 + 半装修复)
# 将 repository 中的离线 .deb 包复制到目标节点并安装
# 自动从 cluster.conf 读取 SSH 密钥配置
# 用法:
#   ./install-worker-packages.sh <IP> [user]         # 直接 SSH 安装
#   ansible-playbook -i <hosts> install-packages.yml  # Ansible 安装
#
# ★ 2026-09-10 加固(扩容 runc `E: Unmet dependencies` 根因):
#   · 按需复制: 本地解析每个 deb 的包名, 远端已装同包 → 跳过(不重复上传/装包;
#     避免离线包版本与节点系统版本漂移破坏依赖, 如 curl 25 vs libcurl4 17)
#   · 依赖预检: deb 的 Depends 必须在"远端已装 ∪ 本次待装"内, 否则 skip(宁缺毋滥, 不破坏 apt)
#   · 修复半装: 安装前 dpkg --configure -a + apt-get install -f; 失败再探测半装包清理
#   · 清除系统容器包: kubelet 未运行(fresh 节点)时 purge containerd/containerd.io/runc ——
#     否则 kubespray runc role `apt-get remove runc` 会撞上系统 containerd 的 Depends 冲突;
#     **在远端探测/选包之前执行**, 保证依赖预检看到的是 purge 后的真实状态
#   · 失败不再掩盖: 远端 shell 启用 pipefail, dpkg 退出码显式捕获; 失败 → err 退出
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

IP="${1:?用法: $0 <IP> [user]}"
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

# ── fresh 节点准备: 必须在 inventory/选包之前清除系统容器包 ──
# purge 会删除 runc/containerd; 若先探测再 purge, REMOTE_VER 会把已删的 runc 当成
# 满足依赖, 随后 dpkg -i 失败. 因此这里先做破坏性清理, 再探测, 选包基于 purge 后状态.
say "检查 fresh 节点系统容器包(containerd/containerd.io/runc)..."
PRE_PURGE_LOG="$(mktemp)"
PRE_PURGE_PAYLOAD="$(cat <<'PRE_PURGE'
set -o pipefail
if [ "$(systemctl is-active kubelet 2>/dev/null)" != "active" ]; then
    echo "--- [pre] kubelet 未运行: 清理系统容器包(containerd/containerd.io/runc) ---"
    apt-get purge -y containerd containerd.io runc 2>&1 | tail -5
else
    echo "--- [pre] kubelet active: 跳过系统容器包清理 ---"
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

# ── 远端探测: 已装包版本/状态 + kubelet 是否运行 ──
REMOTE_PROBE="$(mktemp)"
cat > "${REMOTE_PROBE}" <<'PROBE_EOF'
#!/bin/bash
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
# 状态码: ii=正常安装(唯一可用状态); rc=仅剩配置文件; hi/iU/iF/iH=半装/解包未配置;
#   其他非 ii 状态(如有版本残留)一律不算已装, 不能用来跳过离线包或满足依赖。
dpkg-query -W -f='pkg|${db:Status-Abbrev}|${Package}|${Version}\n' 2>/dev/null | grep -E '^pkg\|' || true
echo "kubelet_running=$([ "$(systemctl is-active kubelet 2>/dev/null)" = "active" ] && echo 1 || echo 0)"
PROBE_EOF

say "探测节点 ${IP} 已装包状态/版本 ..."
probe_out="$(${SSH_SUDO} ssh ${SSH_OPTS} -o BatchMode=yes -o ConnectTimeout=10 "${USER}@${IP}" "bash -s" < "${REMOTE_PROBE}" 2>/dev/null || true)"
rm -f "${REMOTE_PROBE}"

# 解析远端状态 → REMOTE_VER(仅 ii=可用已装)/REMOTE_BROKEN(非 ii 且有版本)/
#   REMOTE_CONFIG_ONLY(rc=仅剩配置文件)/REMOTE_KUBELET
declare -A REMOTE_VER REMOTE_BROKEN REMOTE_CONFIG_ONLY
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
    esac
done <<< "${probe_out}"

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
            if [ -z "${NEED_SET[${p}]:-}" ]; then
                vlog "  [${p}] 同版本 cohort 升级(版本 ${v}) → 加入本次安装"
                NEED_DEBS+=("$f"); NEED_PKGS+=("${p}"); NEED_SET["${p}"]=1
            fi
        done
    fi
fi

# ② 依赖预检(fixpoint 迭代剔除): Depends 逗号分组(每组内 | 为备选), 每组至少一个备选
#    在(远端已装 ∪ 剩余待装)内且**版本约束满足** → 满足; 否则该 deb 剔除并告警。
#    已装版本不满足但离线集有满足约束的升级版 → 选择升级版加入待装集, 下一轮继续校验。
#    最多迭代 10 轮。
if [ "${#NEED_DEBS[@]}" -gt 0 ] && command -v dpkg-deb >/dev/null 2>&1; then
    # 离线集内每个包的最高版本(用于选择满足 Depends 的升级版)
    declare -A _dep_deb_by_pkg=() _dep_ver_by_pkg=()
    for f in "${DEBS[@]}"; do
        p="$(deb_pkg_name "$f")"; [ -n "$p" ] || continue
        v="$(dpkg-deb -f "$f" Version 2>/dev/null || true)"; [ -n "$v" ] || continue
        if [ -z "${_dep_ver_by_pkg[$p]:-}" ] \
           || dpkg --compare-versions "$v" gt "${_dep_ver_by_pkg[$p]}"; then
            _dep_deb_by_pkg["$p"]="$f"; _dep_ver_by_pkg["$p"]="$v"
        fi
    done
    _dep_round=0
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
                            # 无版本约束: 已装或本次待装(含升级)即可
                            if [ -n "${REMOTE_VER[${_dn}]:-}" ] || [ -n "${NEED_SET[${_dn}]:-}" ]; then
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
                        # 当前版本不满足: 选择离线集中满足约束且高于当前版本的升级版
                        _cand_v="${_dep_ver_by_pkg[${_dn}]:-}"
                        if _deb_ver_ok "${_cand_v}" "${_op}" "${_dv}"; then
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
        [ "${_dropped}" = "0" ] && [ "${_added}" = "0" ] && break
    done
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
    unset _dep_deb_by_pkg _dep_ver_by_pkg _kept_debs _kept_pkgs _need_ver _best_deb _best_ver
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
BREAKS_SKIPPED=()
_br_round=0
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
    [ "${_br_changed}" = "0" ] && break
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
        [ "${_seen}" = "1" ] || BREAKS_SKIPPED+=("${_rp}")
    done
    NEED_DEBS=("${_kept_debs[@]}"); NEED_PKGS=("${_kept_pkgs[@]}")
    NEED_SET=()
    for _kp in "${NEED_PKGS[@]}"; do NEED_SET["${_kp}"]=1; done
done
unset _br_need_ver _br_remove _br_changed _breaks _bn _op _bv _final _bad _bad_bn \
      _kept_debs _kept_pkgs _rp _skip _seen _sp _kp i f pkg

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

# 没有待装包但存在相关的半装/仅剩配置(rc)状态: 远端修复已执行; 未进入安装计划的
# 破损包已在上面告警(rc 需要可用 deb; hi/iU 交 dpkg/apt 修复).
if [ "${#NEED_DEBS[@]}" -eq 0 ]; then
    if [ "${REPAIR_RC}" -ne 0 ]; then
        err "远端半装修复失败, 且本次无待安装离线包; 请检查节点 ${IP} 后重跑"
        exit 1
    fi
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
    cp -a "${_ir}" "${_bak}"
    if grep -qE '^[[:space:]]*update_initramfs=' "${_ir}"; then
        sed -i -E 's|^[[:space:]]*update_initramfs=.*|update_initramfs=no|' "${_ir}"
    else
        echo 'update_initramfs=no' >> "${_ir}"
    fi
    echo "[install] 本次安装期间已临时禁用 initramfs 重建(避免 mdadm/lvm hooks 扫描块设备而卡死)"
fi
n_rbd="$(ls -1 /sys/bus/rbd/devices 2>/dev/null | wc -l | tr -d ' ')"
if [ "${n_rbd:-0}" -gt 0 ]; then
    echo "[install] ⚠ 节点存在 ${n_rbd} 个内核 rbd 映射 —— 后端不可达时任何设备扫描都可能卡死; 见 docs/troubleshooting.md"
fi
dpkg -i /tmp/packages/*.deb </dev/null 2>&1 | tail -20
_rc="${PIPESTATUS[0]}"
if [ -n "${_bak}" ] && [ -f "${_bak}" ]; then
    cp -a "${_bak}" "${_ir}"; rm -f "${_bak}"
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
