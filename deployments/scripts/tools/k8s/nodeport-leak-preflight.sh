#!/bin/bash
# ============================================================
# nodeport-leak-preflight.sh — 固定 NodePort 泄漏分配预检(只读等待)
# ------------------------------------------------------------
# 背景(2026-11-03 实机, docs/troubleshooting.md §三.14):
#   kube-apiserver 的 NodePort 分配器把固定端口(registry 默认 31148)持久化在
#   /registry/ranges/servicenodeports。上一次部署/集群重置可能留下"已分配但无 Service
#   持有"的泄漏条目; repair 控制器约 6min 才清理。落在窗口内的 apply 会报
#     provided port is already allocated
#   ⇒ kubespray registry role 中断 ⇒ PVC 未创建 ⇒ registry Pod Pending ⇒ k8s_deploy 失败。
#
# 本工具在 k8s_deploy 入口做一次**只读**预检:
#   · 端口已被某个 Service 持有 → 跳过(正常, 不是泄漏);
#   · 端口无持有者 → `kubectl apply --dry-run=server` 探测(不落盘);
#       - 成功 → 可分配;
#       - already allocated → apiserver 泄漏分配, 有界等待 repair 清理;
#       - 其他错误 → 只告警, 交给真正的 apply 报错。
#   集群尚不存在(全新安装)/不可达 → 直接跳过(fail-open)。
#
# registry role 内的补丁 16 在 apply 前还有一层同类等待(双保险; 本工具让 --fresh/重跑
# 更早收敛, 不必等到 playbook 末尾)。
#
# 用法: bash nodeport-leak-preflight.sh [--port 31148]... [--wait-seconds 600] [--interval 10]
#   默认端口 = REGISTRY_NODEPORT(31148); 可重复 --port 检查多个固定端口。
# 退出码: 0 = 可用/已收敛/集群不可达(fail-open); 1 = 参数/内部错误
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib-common.sh
source "${SCRIPT_DIR}/../../lib-common.sh"
load_config

PORTS=()
WAIT_SECONDS="${NODEPORT_LEAK_WAIT_SECONDS:-600}"
INTERVAL="${NODEPORT_LEAK_WAIT_INTERVAL:-10}"
while [ $# -gt 0 ]; do
    case "$1" in
        --port) PORTS+=("${2:?--port 需要端口}"); shift 2 ;;
        --wait-seconds) WAIT_SECONDS="${2:?--wait-seconds 需要秒数}"; shift 2 ;;
        --interval) INTERVAL="${2:?--interval 需要秒数}"; shift 2 ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "未知参数: $1(可用 --port/--wait-seconds/--interval)"; exit 1 ;;
    esac
done
[ "${#PORTS[@]}" -gt 0 ] || PORTS=("${REGISTRY_NODEPORT:-31148}")
case "${WAIT_SECONDS}" in ''|*[!0-9]*) err "--wait-seconds 必须是非负整数: ${WAIT_SECONDS}"; exit 1 ;; esac
case "${INTERVAL}" in ''|*[!0-9]*|0) err "--interval 必须是正整数: ${INTERVAL}"; exit 1 ;; esac

init_remote_kubectl >/dev/null 2>&1 || { warn "无法定位 master, 跳过 NodePort 泄漏预检"; exit 0; }
SSH "${K} get nodes --no-headers" >/dev/null 2>&1 || { warn "集群尚不存在/不可达, 跳过 NodePort 泄漏预检"; exit 0; }

# 端口是否已被某个 Service 持有(任意命名空间)
_port_held() {   # <port> → 0=持有
    local p="$1" json
    json="$( (SSH "${K} get svc -A -o json" 2>/dev/null) || true )"
    # here-string 而非管道: `grep -q` 命中即退出会让左侧 printf 收到 SIGPIPE,
    # pipefail 下可能把"命中"误判成失败(与仓库里 mc ls | grep -q 的坑同源)。
    command grep -qE "\"nodePort\"[[:space:]]*:[[:space:]]*${p}([^0-9]|$)" <<< "${json}"
}

# server-side dry-run 探测: 0=可分配; 2=already allocated(泄漏); 1=其他错误
_probe() {   # <port>; 其他错误的输出已写到 stderr
    local p="$1" out rc=0
    out="$(printf '%s\n' "apiVersion: v1
kind: Service
metadata:
  name: cubestack-nodeport-preflight
  namespace: default
spec:
  type: NodePort
  selector:
    app: cubestack-nodeport-preflight
  ports:
  - name: probe
    port: 5000
    targetPort: 5000
    nodePort: ${p}" | SSH "${K} apply --dry-run=server -f -" 2>&1)" || rc=$?
    case "${rc}" in
        0) return 0 ;;
    esac
    case "${out}" in
        *"already allocated"*) return 2 ;;
        *) printf '%s\n' "${out}" >&2; return 1 ;;
    esac
}

for _p in "${PORTS[@]}"; do
    case "${_p}" in ''|*[!0-9]*) warn "跳过非法 NodePort: ${_p}"; continue ;; esac
    if _port_held "${_p}"; then
        ok "  NodePort ${_p}: 已被现有 Service 持有(正常, 跳过泄漏预检)"
        continue
    fi
    _rc=0
    _probe "${_p}" || _rc=$?
    case "${_rc}" in
        0) ok "  NodePort ${_p}: 可分配"; continue ;;
        2) : ;;   # 泄漏分配 → 进入等待
        *) warn "  NodePort ${_p}: 预检出现非泄漏错误(交由真正的 apply 报错)"; continue ;;
    esac
    warn "  NodePort ${_p}: apiserver 标记为泄漏分配(无 Service 持有); 等待 repair 控制器清理(最多 ${WAIT_SECONDS}s) ..."
    _deadline=$(( $(date +%s) + WAIT_SECONDS ))
    while :; do
        sleep "${INTERVAL}"
        _rc=0
        _probe "${_p}" || _rc=$?
        case "${_rc}" in
            0) ok "  NodePort ${_p}: repair 已清理, 可分配"; break ;;
            2) ;;
            *) warn "  NodePort ${_p}: 等待期间出现其他错误, 停止等待(交由真正的 apply 报错)"; break ;;
        esac
        if [ "$(date +%s)" -ge "${_deadline}" ]; then
            warn "  NodePort ${_p}: 等待超时(${WAIT_SECONDS}s); registry role 内仍会等待/报错"
            break
        fi
        say "  NodePort ${_p}: 仍在 repair 中, ${INTERVAL}s 后重试 ..."
    done
done
exit 0
