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
#     否则 kubespray runc role `apt-get remove runc` 会撞上系统 containerd 的 Depends 冲突
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
# 离线 .deb 包来源: 仓库根目录 + packages/ 子目录 + 共享 offline-files/kubespray/packages(lvm2 等放此处)
PKG_DIRS=("${REPO_DIR}" "${REPO_DIR}/packages" "${OFFLINE_FILES_DIR}/packages" "${REPO_ROOT}/deployments/offline-files/kubespray/packages")

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

# ── 远端探测: 已装包版本/状态 + kubelet 是否运行 ──
REMOTE_PROBE="$(mktemp)"
cat > "${REMOTE_PROBE}" <<'PROBE_EOF'
#!/bin/bash
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
# 状态码: ii=正常安装; hi/iU/iF/iH=半装/解包未配置(破损, 需修复); 实际版本为空=未装
dpkg-query -W -f='pkg|${db:Status-Abbrev}|${Package}|${Version}\n' 2>/dev/null | grep -E '^pkg\|' || true
echo "kubelet_running=$([ "$(systemctl is-active kubelet 2>/dev/null)" = "active" ] && echo 1 || echo 0)"
PROBE_EOF

say "探测节点 ${IP} 已装包状态/版本 ..."
probe_out="$(${SSH_SUDO} ssh ${SSH_OPTS} -o BatchMode=yes -o ConnectTimeout=10 "${USER}@${IP}" "bash -s" < "${REMOTE_PROBE}" 2>/dev/null || true)"
rm -f "${REMOTE_PROBE}"

# 解析远端状态 → REMOTE_VER(包名→已装版本)/REMOTE_BROKEN(包名→破损状态码)/REMOTE_KUBELET
declare -A REMOTE_VER REMOTE_BROKEN
REMOTE_KUBELET=0
while IFS= read -r rline; do
    [ -z "${rline}" ] && continue
    case "${rline}" in
        kubelet_running=*) REMOTE_KUBELET="${rline#kubelet_running=}" ;;
        pkg\|*)
            rrest="${rline#pkg|}"; rst="${rrest%%|*}"; rrest="${rrest#*|}"
            rname="${rrest%%|*}"; rver="${rrest#*|}"
            REMOTE_VER["${rname}"]="${rver}"
            case "${rst}" in ii) : ;; *) REMOTE_BROKEN["${rname}"]="${rst}" ;; esac
            ;;
    esac
done <<< "${probe_out}"

# ── 逐个 deb: 解析包名, 决定本次是否需要安装 ──
# 规则:
#   ① 远端已装同包(任何版本)→ 跳过(避免离线版本与系统版本漂移破坏依赖, 如 curl 25 vs libcurl4 17)
#   ② 待装集合: 仅"未装"的 deb; 再校验其 Depends 能在(远端已装 ∪ 待装)内满足, 否则 skip + warn
NEED_DEBS=()        # 待复制/安装的 deb 路径
NEED_PKGS=()        # 对应包名
declare -A NEED_SET
for f in "${DEBS[@]}"; do
    pkg="$(deb_pkg_name "$f")"
    [ -n "${pkg}" ] || { warn "无法解析 deb 包名: $(basename "$f"), 跳过"; continue; }
    if [ -n "${REMOTE_VER[${pkg}]:-}" ]; then
        vlog "  [${pkg}] 已装 ${REMOTE_VER[${pkg}]}(离线包不重复装), 跳过"
        continue
    fi
    NEED_DEBS+=("$f"); NEED_PKGS+=("${pkg}"); NEED_SET["${pkg}"]=1
done

# ② 依赖预检(fixpoint 迭代剔除): Depends 逗号分组(每组内 | 为备选), 每组至少一个备选
#    在(远端已装 ∪ 剩余待装)内 → 满足; 否则该 deb 剔除并告警。最多迭代 10 轮。
if [ "${#NEED_DEBS[@]}" -gt 0 ] && command -v dpkg-deb >/dev/null 2>&1; then
    _dep_round=0
    while [ "${_dep_round}" -lt 10 ]; do
        _dep_round=$((_dep_round + 1))
        _kept_debs=(); _kept_pkgs=(); _dropped=0
        declare -A _kept_set=()
        for i in "${!NEED_DEBS[@]}"; do
            f="${NEED_DEBS[$i]}"; pkg="${NEED_PKGS[$i]}"
            deps="$(deb_depends "$f")"
            # Depends 为空(无依赖或无法解析)→ 视为可装
            if [ -z "${deps}" ]; then
                _kept_debs+=("$f"); _kept_pkgs+=("${pkg}"); _kept_set["${pkg}"]=1
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
                        # 取备选包名: 去掉版本约束(括号)与架构后缀(:amd64)
                        _dn="$(echo "${_alt}" | sed -E 's/^[[:space:]]*([A-Za-z0-9+.-]+).*/\1/')"
                        if [ -n "${REMOTE_VER[${_dn}]:-}" ] || [ -n "${NEED_SET[${_dn}]:-}" ]; then
                            _grp_ok=1; break
                        fi
                    done
                    if [ "${_grp_ok}" != "1" ]; then dep_ok=0; dep_miss="${_grp}"; break; fi
                done
            done <<< "${deps}"
            if [ "${dep_ok}" = "1" ]; then
                _kept_debs+=("$f"); _kept_pkgs+=("${pkg}"); _kept_set["${pkg}"]=1
            else
                warn "  [${pkg}] 依赖不可满足(${dep_miss}), 本次跳过(不破坏 apt 状态)"
                _dropped=1
            fi
        done
        NEED_DEBS=("${_kept_debs[@]}"); NEED_PKGS=("${_kept_pkgs[@]}")
        NEED_SET=()
        for _kp in "${NEED_PKGS[@]}"; do NEED_SET["${_kp}"]=1; done
        [ "${_dropped}" = "0" ] && break   # 无剔除 → 稳定
    done
fi

if [ "${#NEED_DEBS[@]}" -eq 0 ]; then
    ok "节点 ${IP} 所需离线包均已安装(无需上传/装包)"
    exit 0
fi

say "待安装 ${#NEED_DEBS[@]} 个包: ${NEED_PKGS[*]}"

# ── 远端修复段(幂等): 修半装 + apt 依赖修复 + 清理系统容器包(fresh 节点) ──
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
# fresh 节点(非集群成员, kubelet 未运行): 清除系统容器包, 消除 kubespray runc role 的 Depends 冲突
if [ "$(systemctl is-active kubelet 2>/dev/null)" != "active" ]; then
    echo "--- [fix] 清理系统容器包(containerd/containerd.io/runc) ---"
    apt-get purge -y containerd containerd.io runc 2>&1 | tail -5 || true
fi
dpkg --audit 2>&1 | tail -5 || true
FIX_EOF

say "执行远端修复(半装/apt 依赖/系统容器包)..."
if ! ${SSH_SUDO} ssh ${SSH_OPTS} -o BatchMode=yes -o ConnectTimeout=15 "${USER}@${IP}" \
    "sudo bash -s" < "${REMOTE_FIX}" 2>/dev/null; then
    warn "远端修复部分失败(半装状态可能未完全清理; 继续尝试安装)"
fi
rm -f "${REMOTE_FIX}"

# ── 复制待装包到目标节点 ──
${SSH_SUDO} ssh ${SSH_OPTS} "${USER}@${IP}" "mkdir -p /tmp/packages" 2>/dev/null || true
say "复制 ${#NEED_DEBS[@]} 个离线包到 ${IP}:/tmp/packages/ ..."
for f in "${NEED_DEBS[@]}"; do
    vlog "  复制: $(basename "$f")"
    ${SSH_SUDO} rsync -e "ssh ${SSH_OPTS}" "$f" "${USER}@${IP}:/tmp/packages/" 2>/dev/null || \
      ${SSH_SUDO} scp ${SSH_OPTS} "$f" "${USER}@${IP}:/tmp/packages/" 2>/dev/null || true
done

# ── 安装(dpkg -i; 远端 pipefail 保证 dpkg 失败不被 tail 管道吞掉, 失败显式中止) ──
say "安装中 (dpkg -i, 失败将中止) ..."
INSTALL_LOG="$(mktemp)"
if ! ${SSH_SUDO} ssh ${SSH_OPTS} "${USER}@${IP}" \
    "set -o pipefail; sudo dpkg -i /tmp/packages/*.deb 2>&1 | tail -20" \
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

ok "✅ ${IP} 离线包安装完成: ${NEED_PKGS[*]}"
