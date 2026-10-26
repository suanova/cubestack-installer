#!/bin/bash
# ============================================================
# MODULE: metallb
# DESC: 确保 MetalLB 就绪(controller/speaker Running + IPAddressPool/L2Advertisement 存在)
#       作为 registry 等依赖 MetalLB 组件的**前置检查**, 排在 addon 阶段第一位。
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: METALLB_ENABLED
# REQUIRES: k8s_deploy
# 说明:
#   · MetalLB 由 kubespray addon 安装; 本模块仅做**就绪校验**(幂等), 不重复安装。
#   · 依赖顺序: metallb(本模块)→ local-path → registry —— registry 的 LoadBalancer VIP
#     依赖 metallb,故 registry 前先确认 metallb 就绪。
#   · ⚠ SERVICE_EXPOSE_MODE 二选一: nodeport 模式自动关闭 MetalLB(sync-addons-config
#     metallb_enabled=false), 此时本校验须跳过(集群本就不部署 MetalLB), 否则假阳性失败。
#   · 校验: ① metallb-system 命名空间 ② controller/speaker 全部 Running
#     ③ IPAddressPool / L2Advertisement 存在 ④ 地址池收敛到 cluster.conf 的 METALLB_POOL
#       (改池后重跑本模块即生效; 同时同步 addons.yml 供后续 k8s_deploy 使用)
#       ④-0 冲突预检: 池内未分配地址必须 ping 不通(本集群已分配 VIP 排除)
# 用法:   sudo ./deploy-cluster.sh --with-k8s(TOGGLE 自动启用) 或 --enable metallb
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

[ "${METALLB_ENABLED:-true}" = "true" ] || { say "METALLB_ENABLED=false, 跳过 metallb 就绪检查"; exit 0; }
[ "${SERVICE_EXPOSE_MODE:-metallb}" = "nodeport" ] \
    && { say "SERVICE_EXPOSE_MODE=nodeport(自动关闭 MetalLB), 跳过 metallb 就绪检查"; exit 0; }

# addons.yml 与 cluster.conf 一致性门禁(2026-10-26 实机):
# k8s_deploy 入口一次性 load_config; 若用户在倒计时/kubespray 运行期间改了 cluster.conf,
# k8s_deploy 仍按旧配置生成 addons.yml, 而本模块重新加载后看到新值 → 直接报“未找到
# metallb-system”, 根因被掩盖。这里先给出可操作的明确错误, 不再让用户猜 addons.yml。
_ADDONS_YML="${KUBESPRAY_INV_DIR:-${REPO_ROOT}/deployments/kubespray/inventory/${CLUSTER_NAME}}/group_vars/k8s_cluster/addons.yml"
_m_enabled="$(addons_metallb_enabled "${_ADDONS_YML}")"
_m_speaker="$(awk -F':[[:space:]]*' '/^[[:space:]]*metallb_speaker_enabled:/{v=$2; gsub(/["[:space:]]/,"",v); print v; found=1; exit} END{if(!found) print "missing"}' "${_ADDONS_YML}" 2>/dev/null || true)"
if [ "${_m_enabled}" != "true" ] || [ "${_m_speaker}" != "true" ]; then
    err "MetalLB 配置不一致: 当前 SERVICE_EXPOSE_MODE=${SERVICE_EXPOSE_MODE:-metallb} / METALLB_ENABLED=${METALLB_ENABLED:-true}"
    err "  但 ${_ADDONS_YML} 的 metallb_enabled=${_m_enabled:-missing} metallb_speaker_enabled=${_m_speaker:-missing}"
    err "  根因通常是 k8s_deploy 期间修改了 cluster.conf: 已加载旧变量生成 addons.yml, 后续模块读到新值。"
    err "  修复: bash deployments/scripts/tools/k8s/gen-inventory.sh && sudo ./deploy-cluster.sh --steps k8s_deploy --fresh --yes"
    exit 1
fi
unset _ADDONS_YML _m_enabled _m_speaker

init_remote_kubectl || exit 1

say "检查 MetalLB 就绪(registry 等 LoadBalancer 组件的前置依赖)..."
say "  ① metallb-system 命名空间..."
if ! SSH "${K} get ns metallb-system >/dev/null 2>&1"; then
    err "未找到 metallb-system 命名空间, 检查 addons.yml metallb_enabled 且 kubespray 已部署 metallb"
    err "  若 addons.yml 已为 true, 说明本次 k8s_deploy 未成功安装 addon; 重跑:"
    err "  sudo ./deploy-cluster.sh --steps k8s_deploy --fresh --yes"
    exit 1
fi
say "  ② 等待 controller/speaker pod 全部 Running(最长 90s)..."
PODS_OK=0
for i in $(seq 1 18); do
    PODS="$(SSH "${K} -n metallb-system get pods 2>/dev/null" || true)"
    if [ -n "${PODS}" ]; then
        # 要求: 至少 1 个 controller + 1 个 speaker, 且所有 controller/speaker 行都是 1/1 Running
        NONREADY="$(echo "${PODS}" | grep -E 'controller|speaker' | grep -vE '1/1 +Running' || true)"
        HAS_CTL="$(echo "${PODS}" | grep -c controller || true)"
        HAS_SPK="$(echo "${PODS}" | grep -c speaker || true)"
        if [ -z "${NONREADY}" ] && [ "${HAS_CTL:-0}" -ge 1 ] && [ "${HAS_SPK:-0}" -ge 1 ]; then
            PODS_OK=1
            break
        fi
    fi
    sleep 5
done
if [ "${PODS_OK}" != "1" ]; then
    err "metallb controller/speaker 未全部 Running(90s 超时), 执行: kubectl -n metallb-system get pods"
    exit 1
fi
say "  ③ IPAddressPool / L2Advertisement 存在..."
if ! SSH "${K} -n metallb-system get ipaddresspools -o name 2>/dev/null | grep -q ipaddresspool"; then
    err "metallb 地址池未配置, 检查 addons.yml metallb_config.address_pools"
    exit 1
fi
if ! SSH "${K} -n metallb-system get l2advertisements -o name 2>/dev/null | grep -q l2advertisement"; then
    err "metallb L2 通告未配置, 检查 addons.yml metallb_config.layer2"
    exit 1
fi

# ④ 地址池与 cluster.conf 收敛(2026-10-25):
#   只校验 CR 存在不够 —— 改 METALLB_POOL 后重跑本模块/verify_metallb 仍会用旧池,
#   LoadBalancer 分不到 VIP(实机踩到)。这里把 primary 池收敛到 METALLB_POOL,
#   并同步 addons.yml, 保证下次 k8s_deploy 也使用同一份池。
if [ -n "${METALLB_POOL:-}" ]; then
    _pool_json="$(python3 - "${METALLB_POOL}" <<'PY'
import json, sys
print(json.dumps([x.strip() for x in sys.argv[1].split(",") if x.strip()]))
PY
)"
    # ④-0 地址冲突预检(2026-10-25, 用户口径"主要避免 IP 冲突"):
    #   池内**未分配**地址必须 ping 不通; 本集群已分配的 VIP 从检查中排除(重跑不误报)。
    #   检查是第一道防线, 不能替代人工确认(防火墙可能不回 ICMP)。
    if [ "${SKIP_METALLB_POOL_CHECK:-false}" != "true" ]; then
        _alloc_ips="$( (SSH "${K} get svc -A -o json 2>/dev/null" || true) | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for it in d.get("items", []) or []:
    for ing in ((it.get("status") or {}).get("loadBalancer") or {}).get("ingress") or []:
        if ing.get("ip"): print(ing["ip"])
    for ip in (it.get("spec") or {}).get("externalIPs") or []:
        print(ip)
' 2>/dev/null || true)"
        _cand_ips="$(python3 - "${METALLB_POOL}" <<'PY'
import ipaddress, sys
out = []
for tok in sys.argv[1].split(','):
    tok = tok.strip()
    if not tok:
        continue
    try:
        if '-' in tok and '/' not in tok:
            a, b = tok.split('-', 1)
            s = int(ipaddress.ip_address(a.strip()))
            e = int(ipaddress.ip_address(b.strip()))
            out.extend(str(ipaddress.ip_address(n)) for n in range(s, e + 1))
        elif '/' in tok:
            out.extend(str(h) for h in list(ipaddress.ip_network(tok, strict=False).hosts())[:1024])
        else:
            out.append(str(ipaddress.ip_address(tok)))
    except Exception:
        pass
print('\n'.join(out))
PY
)"
        _conflicts=""
        while IFS= read -r _ip; do
            [ -n "${_ip}" ] || continue
            case " ${_alloc_ips} " in *" ${_ip} "*) continue ;; esac
            # SSH 必须接 </dev/null: 否则会吞掉 while 的剩余输入, 只检查第一个地址
            if SSH "ping -c1 -W1 ${_ip} >/dev/null 2>&1" </dev/null; then
                _conflicts="${_conflicts} ${_ip}"
            fi
        done <<< "${_cand_ips}"
        if [ -n "${_conflicts}" ]; then
            err "MetalLB 地址池存在已被占用的 IP:${_conflicts}"
            err "  请修改 cluster.conf METALLB_POOL(排除在用地址), 或确认不是其他集群/主机在占用"
            err "  确认无冲突但仍需继续: SKIP_METALLB_POOL_CHECK=true 重跑(风险自负)"
            exit 1
        fi
        ok "MetalLB 地址池冲突预检通过(已排除本集群已分配 VIP)"
    fi
    _cur_addrs="$(SSH "${K} -n metallb-system get ipaddresspool primary -o jsonpath='{.spec.addresses}' 2>/dev/null" || true)"
    _same="$(python3 - "${_cur_addrs:-[]}" "${_pool_json}" <<'PY'
import json, sys
def norm(s):
    try:
        v = json.loads(s)
        return [str(x).strip() for x in v] if isinstance(v, list) else []
    except Exception:
        return []
print("1" if norm(sys.argv[1]) == norm(sys.argv[2]) else "0")
PY
)"
    if [ "${_same}" != "1" ]; then
        say "  ④ 收敛 IPAddressPool primary → ${METALLB_POOL} ..."
        if ! SSH "${K} -n metallb-system patch ipaddresspool primary --type=merge --patch-file=/dev/stdin" >/dev/null 2>&1 <<EOF
{"spec":{"addresses":${_pool_json}}}
EOF
        then
            err "MetalLB 地址池收敛失败(primary ← ${METALLB_POOL}); 手工: kubectl -n metallb-system patch ipaddresspool primary --type=merge -p '{\"spec\":{\"addresses\":${_pool_json}}}'"
            exit 1
        fi
    fi
    # addons.yml 同步: 保证后续 k8s_deploy/覆盖安装继续使用本次池
    _sync_tool="${REPO_ROOT}/deployments/scripts/tools/k8s/sync-kubespray-config.sh"
    if [ -x "${_sync_tool}" ]; then
        bash "${_sync_tool}" >/dev/null 2>&1 || warn "sync-kubespray-config.sh 同步失败; 下次 k8s_deploy 可能仍使用旧地址池"
    fi
    ok "MetalLB 地址池已收敛: primary = ${METALLB_POOL}"
fi
ok "MetalLB 就绪: controller/speaker Running, IPAddressPool/L2Advertisement 存在"

# 优雅覆盖登记(安装/校验成功才登记; --fresh 覆盖时按登记反序卸载, 见 docs/graceful-overwrite/)
record_installed_component "metallb"
