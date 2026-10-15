#!/bin/bash
# ============================================================
# TOOL: ensure-containerd-device-ownership
# DESC: 确保节点 containerd 启用 device_ownership_from_security_context(非 root 容器访问
#       MetaX GPU /dev/mxcd 的前提; 2026-10-13 实机根因闭环)
# 背景(为什么必须有): 设备插件把 /dev/mxcd 注入容器时属主 = root(root:root 0600) ⇒
#   runAsUser:1000 的环境 open() 得 EACCES、torch.cuda.is_available()=False —— 而**一切表面
#   检查都"正常"**: mx-smi exit 0 打印设备表(它只读 sysfs、不开 /dev 节点), torch.cuda.
#   device_count() 返回请求值(报的是 vendor 配置的可见集, 不是成功的 open)。容器照跑、资源
#   照申请, 没有任何 status/event 会提示。containerd 的该 CRI 布尔(默认 false)置 true 后,
#   容器创建时按 runAsUser/runAsGroup 对设备节点 chown(实测: crw------- root root →
#   crw------- ubuntu ubuntu, open fd 成功, torch.cuda.is_available() True)。
# 作用范围: 默认 = cluster.conf NODES 中 **mx-smi 检测到 GPU** 的节点(即"会跑 Metax 工作负载"
#   的节点); 显式给 IP 参数则按参数; --all 不过滤 GPU。
# 行为(幂等): 键已存在且为 true → 不动; 缺失或为 false → 备份 /etc/containerd/config.toml
#   (config.toml.orig-<epoch>)后用 python 精确改写(2.x 段落 io.containerd.cri.v1.runtime /
#   1.x 段落 io.containerd.grpc.v1.cri 自动识别; 都没有则在文末新建 2.x 段落),
#   **仅在发生修改时** systemctl restart containerd(containerd 重启不影响运行中的容器)。
# ⚠ 生效时机: 属主在**容器创建时**写入 —— 已运行的容器保持旧属主, 需重建工作负载
#   (kubectl rollout restart / 重删 Pod)才生效; 本工具会打印该提示。
# ⚠ 厂商安装器共存: mx-ctk-installer 等守护进程可能重写 config.toml(实机见 mtime 被改) ——
#   每次部署(gpu_operator 模块)会重跑本工具兜底; 怀疑被改时手工重跑本工具即可。
# 用法:
#   sudo ./ensure-containerd-device-ownership.sh                  # NODES 中 GPU 节点
#   sudo ./ensure-containerd-device-ownership.sh 10.66.3.13 10.66.3.48   # 指定 IP
#   sudo ./ensure-containerd-device-ownership.sh --all            # 不筛 GPU, 全部 NODES
# 数据源: cluster.conf (NODES / SSH_USER / SSH_DEFAULT_PASSWORD / CONTAINERD_DEVICE_OWNERSHIP)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# 总开关(与 sync-kubespray-config.sh 同一数据源): false → 明确跳过(也供 k8s 侧渲染对齐)
if [ "${CONTAINERD_DEVICE_OWNERSHIP:-true}" != "true" ]; then
    say "CONTAINERD_DEVICE_OWNERSHIP=false, 跳过设备属主前置(节点侧不改)"
    exit 0
fi

# ---------------- 参数 ----------------
ALL=0; TARGETS=()
for _a in "$@"; do
    case "${_a}" in
        --all) ALL=1 ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) err "未知参数: ${_a}(可用 --all / 或直接给节点 IP 列表)"; exit 1 ;;
        *) TARGETS+=("${_a}") ;;
    esac
done

SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
SSH_BASE_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8)

# 按 IP 找 NODES 里的 user/pw(node_parse 归一化); 找不到用全局默认
# 按 IP 找 NODES 里的 user(node_parse 归一化; "-" → 全局 SSH_USER); 找不到用全局默认
# 2026-10-15: 收编到 lib-common 的 ssh_user_for_ip(单一实现, 勿再各自内联)
_node_user_of() {  # <ip>
    ssh_user_for_ip "$1"
}
_node_pw_of() {    # <ip>
    local _l
    for _l in "${NODES[@]:-}"; do
        [ -z "${_l}" ] && continue
        node_parse "${_l}"
        [ "${NODE_IP}" = "$1" ] && { echo "${NODE_PW:-}"; return 0; }
    done
    echo "${SSH_DEFAULT_PASSWORD:-}"
}

# 在目标上执行远端脚本: 先密钥(BatchMode); 失败且 sshpass 可用且有密码 → 密码通道兜底
_remote_bash() {   # <ip> <script-string>
    local _ip="$1" _script="$2" _user _pw
    _user="$(_node_user_of "${_ip}")"
    if ssh -i "${SSH_KEY}" "${SSH_BASE_OPTS[@]}" "${_user}@${_ip}" 'sudo bash -s' <<< "${_script}" 2>/dev/null; then
        return 0
    fi
    _pw="$(_node_pw_of "${_ip}")"
    if command -v sshpass >/dev/null 2>&1 && [ -n "${_pw}" ]; then
        say "    (密钥不通, 用节点密码通道重试)"
        sshpass -p "${_pw}" ssh "${SSH_BASE_OPTS[@]}" "${_user}@${_ip}" 'sudo bash -s' <<< "${_script}"
        return $?
    fi
    return 1
}

# ---------------- 远端执行体(经 stdin 直送, 无嵌套引号问题) ----------------
REMOTE_SCRIPT="$(cat <<'RSCRIPT'
set -euo pipefail
CFG=/etc/containerd/config.toml
KEY=device_ownership_from_security_context
if [ ! -f "${CFG}" ]; then echo "RESULT=NO-CONFIG"; exit 0; fi

# 已存在: true → 幂等跳过; false → 视为缺失(改写为 true)
if grep -qE "^[[:space:]]*${KEY}[[:space:]]*=" "${CFG}"; then
    if grep -E "^[[:space:]]*${KEY}[[:space:]]*=" "${CFG}" | grep -q true; then
        echo "RESULT=ALREADY"; exit 0
    fi
fi

cp -a "${CFG}" "${CFG}.orig-$(date +%s)"
python3 - "${CFG}" <<'PY'
import re, sys
path = sys.argv[1]
key  = "device_ownership_from_security_context"
src  = open(path).read()
if re.search(r'^\s*' + key + r'\s*=', src, re.M):
    src = re.sub(r'^\s*' + key + r'\s*=.*$', f"  {key} = true", src, flags=re.M)
else:
    secs = [r'plugins."io.containerd.cri.v1.runtime"', r'plugins."io.containerd.grpc.v1.cri"']
    placed = False
    for sec in secs:
        m = re.search(r'^\[%s\]\s*$' % re.escape(sec), src, re.M)
        if m:
            src = src[:m.end()] + f"\n  {key} = true" + src[m.end():]
            placed = True
            break
    if not placed:   # 无 CRI 段落(极简配置) → 文末补 2.x 段落
        src = src.rstrip() + '\n\n[plugins."io.containerd.cri.v1.runtime"]\n  %s = true\n' % key
open(path, 'w').write(src)
PY

if ! grep -qE "^[[:space:]]*${KEY}[[:space:]]*=.*true" "${CFG}"; then
    echo "RESULT=WRITE-FAILED"; exit 1
fi
systemctl restart containerd
for _i in $(seq 1 20); do systemctl is-active --quiet containerd && break; sleep 1; done
if systemctl is-active --quiet containerd; then
    echo "RESULT=APPLIED-RESTARTED"
else
    echo "RESULT=APPLIED-BUT-NOT-ACTIVE"; exit 1
fi
RSCRIPT
)"

# ---------------- 组装目标列表 ----------------
CANDIDATES=()
if [ "${#TARGETS[@]}" -gt 0 ]; then
    CANDIDATES=("${TARGETS[@]}")
else
    for _l in "${NODES[@]:-}"; do
        [ -z "${_l}" ] && continue
        node_parse "${_l}"
        [ -n "${NODE_IP}" ] && CANDIDATES+=("${NODE_IP}")
    done
fi

say "设备属主前置(device_ownership_from_security_context=true): 候选 ${#CANDIDATES[@]} 个节点(GPU 过滤: $([ "${ALL}" = "1" ] && echo 关 || echo 开))..."
_n_applied=0; _n_already=0; _n_skip=0; _n_fail=0
for _ip in "${CANDIDATES[@]}"; do
    if [ "${ALL}" != "1" ]; then
        _ngpu="$(_remote_bash "${_ip}" "sudo mx-smi 2>/dev/null | grep 'Attached GPUs' | awk '{print \$NF}'" 2>/dev/null | tr -d '[:space:]' | grep -E '^[0-9]+$' || echo 0)"
        if [ "${_ngpu:-0}" -le 0 ] 2>/dev/null; then
            say "  ${_ip}: 无 GPU(mx-smi 未识别/无驱动), 跳过"
            _n_skip=$((_n_skip + 1)); continue
        fi
    fi
    _out="$(_remote_bash "${_ip}" "${REMOTE_SCRIPT}" || true)"
    case "${_out}" in
        *RESULT=ALREADY*)
            ok "  ${_ip}: 已启用(幂等, 未修改)"
            _n_already=$((_n_already + 1)) ;;
        *RESULT=APPLIED-RESTARTED*)
            ok "  ${_ip}: 已写入并重启 containerd"
            warn "      ⚠ 属主在容器创建时写入: 已运行容器保持旧属主, 需重建工作负载才生效(kubectl rollout restart / 重删 Pod)"
            _n_applied=$((_n_applied + 1)) ;;
        *RESULT=NO-CONFIG*)
            warn "  ${_ip}: 无 /etc/containerd/config.toml(节点未装 containerd?), 跳过"
            _n_skip=$((_n_skip + 1)) ;;
        *RESULT=APPLIED-BUT-NOT-ACTIVE*)
            err "  ${_ip}: 已写入但 containerd 重启后未 active(立即检查: systemctl status containerd)"
            _n_fail=$((_n_fail + 1)) ;;
        *)
            err "  ${_ip}: 执行失败(密钥/密码均不可达或远端报错)"
            _n_fail=$((_n_fail + 1)) ;;
    esac
done
unset _ip _out _l _a _ngpu _user _pw

echo "---------------------------------------------"
say "设备属主前置完成: 新应用 ${_n_applied} / 已启用 ${_n_already} / 跳过(无GPU等) ${_n_skip} / 失败 ${_n_fail}"
[ "${_n_fail}" -eq 0 ] || exit 1
