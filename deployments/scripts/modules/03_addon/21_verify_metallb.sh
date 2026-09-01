#!/bin/bash
# ============================================================
# MODULE: verify_metallb
# DESC: 端到端验证 MetalLB 真正工作(非仅 pod running): 测试 LoadBalancer Service
#       分配到池内 VIP 且节点可访问(HTTP 可达), 验后自动清理
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# 说明:
#   · **验证模块不设 TOGGLE**(否则 METALLB_ENABLED=true 时会被安装流程自动启用);
#     保持 DEFAULT:0, 仅由 --steps verify_metallb 在安装后单独执行。
#   · ⚠ SERVICE_EXPOSE_MODE 二选一: nodeport 模式自动关闭 MetalLB(未部署),
#     本验证须跳过(METALLB_ENABLED 默认 true 不代表已部署)。
#   · 在 metallb 部署后执行, 做真实功能验证(不只查 pod Ready):
#       ① controller/speaker pod Ready
#       ② IPAddressPool / L2Advertisement 存在 + **预检池不含 .0/.255**(网络/广播地址,
#          命中即提前失败, 省去创建测试资源后才发现 VIP 不可用)
#       ②b **按地址池规模决定验证方式**(本次需求):
#          · 池内地址 **>1 个** → 【新建测试 LoadBalancer, 验证"分配新 VIP"能力】(③④⑤⑥)
#          · 池内地址 **仅 1 个** → 该地址通常已被 registry 等既有 LoadBalancer 占用
#            (新建必然拿不到 VIP → 90s 超时误报), 改为**直接验证已分配 VIP 工作是否正常**;
#            若单地址池尚空闲则仍走新建分配验证
#       ③ 需要新建时创建测试命名空间 + nginx httpd 后端 + LoadBalancer Service
#       ④ 等待分配到池内 VIP, 校验 VIP 在 METALLB_POOL 范围内
#       ⑤ 从首个 master curl http://VIP 验证 L2 通告真正可达
#       ⑥ 清理测试资源(命名空间, trap 兜底)
#   · 本文件可作其他 operator/组件的 verify_<组件>.sh 模板:
#     复制后改 MODULE/DESC 与第 ③⑤ 步的实际验证逻辑即可(勿加 TOGGLE)
# 数据源: cluster.conf (METALLB_ENABLED / METALLB_POOL / NODES / SSH_KEY_NAME)
# 用法:   sudo ./deploy-cluster.sh --steps verify_metallb
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# 开关检查: 未启用 MetalLB 或 nodeport 暴露模式(未部署 MetalLB)则跳过(不报错)
[ "${METALLB_ENABLED:-true}" = "true" ] || { say "METALLB_ENABLED=false, 跳过验证"; exit 0; }
[ "${SERVICE_EXPOSE_MODE:-metallb}" = "nodeport" ] \
    && { say "SERVICE_EXPOSE_MODE=nodeport(未部署 MetalLB), 跳过验证"; exit 0; }

FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
SSH() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
           "${SSH_USER:-ubuntu}@${FIRST_MASTER}" "$@"; }
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

# 测试后端镜像: 离线优先, 幂等确保 nginx 已在集群 registry(不依赖节点 containerd 预加载)
TEST_IMAGE="$(ensure_registry_nginx)" || exit 1

TEST_NS="verify-metallb-$$"   # 唯一命名空间(带 PID 后缀), 避免与残留的 Terminating ns 冲突
TEST_NAME="verify-lb"

cleanup() {
    # 先强制清 namespace finalizers(上一轮残留的 Terminating ns 会挂起删除, 自愈后再删)
    SSH "${K} patch namespace ${TEST_NS} --type=merge -p '{\"metadata\":{\"finalizers\":null}}' >/dev/null 2>&1" || true
    SSH "${K} delete namespace ${TEST_NS} --ignore-not-found=true --force --grace-period=0 >/dev/null 2>&1" || true
}

# VIP 是否在池内(支持 起止区间 / CIDR / 单地址)
_ip_in_pool() {
    local ip="$1" pool="$2"
    python3 - "${ip}" "${pool}" <<'PY'
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
pool = sys.argv[2]
if "-" in pool and "/" not in pool:
    a, b = pool.split("-")
    print(1 if int(ipaddress.ip_address(a)) <= int(ip) <= int(ipaddress.ip_address(b)) else 0)
elif "/" in pool:
    print(1 if ip in ipaddress.ip_network(pool, strict=False) else 0)
else:
    print(1 if ip == ipaddress.ip_address(pool) else 0)
PY
}

trap cleanup EXIT

say "验证 MetalLB 工作正常(端到端, 非仅 pod running)..."
say "  ① 检查 metallb 组件 pod 就绪..."
SSH "${K} -n metallb-system get pods -o wide 2>/dev/null | grep -E 'controller.*1/1 +Running|speaker.*1/1 +Running'" \
    || { err "metallb controller/speaker 未全部 Running(当前列序: NAME READY STATUS)"; exit 1; }

say "  ② 检查地址池与 L2 通告 CR..."
SSH "${K} -n metallb-system get ipaddresspools 2>/dev/null"
SSH "${K} -n metallb-system get l2advertisements 2>/dev/null"

# 预检: 从集群读取实际 IPAddressPool(非仅信 cluster.conf), 若含 .0/.255(网络/广播地址)
# → 提前失败并给指引, 避免创建测试资源+等 90s 后才发现 VIP 不可用(见 troubleshooting 三.2)
say "    预检地址池不含网络/广播地址(.0/.255)..."
POOL_SPECS="$(SSH "${K} -n metallb-system get ipaddresspools -o jsonpath='{range .items[*].spec.addresses[*]}{@}{\" \"}{end}' 2>/dev/null")"
BAD_SPEC="$(POOL_SPECS="${POOL_SPECS}" python3 - <<'PY'
import ipaddress, os, sys
specs = os.environ.get("POOL_SPECS", "").split()

def last_octet_bad(ip):
    return str(ip).rsplit(".", 1)[-1] in ("0", "255")

def range_contains_bad(a, b):
    # 判断 [a,b] 是否含末位为 0 或 255 的地址(逐 /24 段跳进, 最多 ~256 次)
    cur = a
    while cur <= b:
        if last_octet_bad(cur):
            return True
        cur = ipaddress.ip_address((int(cur) & ~0xFF) + 0x100)  # 跳到下一个 /24 起点
    return False

for s in specs:
    if "/" in s:
        net = ipaddress.ip_network(s, strict=False)
        if last_octet_bad(net.network_address) or last_octet_bad(net.broadcast_address):
            print(s); sys.exit(0)
    elif "-" in s:
        a, b = (ipaddress.ip_address(x) for x in s.split("-"))
        if range_contains_bad(a, b):
            print(s); sys.exit(0)
    else:
        if last_octet_bad(ipaddress.ip_address(s)):
            print(s); sys.exit(0)
PY
)"
if [ -n "${BAD_SPEC}" ]; then
    err "地址池 ${BAD_SPEC} 含网络/广播地址(.0/.255), MetalLB 可能分配出不可用的 VIP。请把 METALLB_POOL=${METALLB_POOL} 改为排除它们的区间(如 10.244.2.1-10.244.2.254)或开 avoidBuggyIPs, 重新同步(重跑 sync-kubespray-config.sh + 重 apply 池)后再验证"
    exit 1
fi

# ②b ★ 按地址池规模决定验证方式(需求):
#   · 池内地址 **>1 个** → 【新建测试 LoadBalancer, 验证"分配新 VIP"能力】(③④⑤⑥)
#   · 池内地址 **仅 1 个** → 该地址通常已被 registry 等既有 LoadBalancer 占用
#     (新建必然拿不到 VIP → 90s 超时误报), 改为**直接验证已分配 VIP 工作是否正常**;
#     若单地址池尚空闲则仍走新建分配验证。
_pool_size() {   # 地址池地址数量(支持 起止区间 / CIDR / 单地址)
    local pool="$1"
    python3 - "${pool}" <<'PY'
import ipaddress, sys
pool = sys.argv[1]
if "-" in pool and "/" not in pool:
    a, b = (ipaddress.ip_address(x) for x in pool.split("-"))
    print(int(b) - int(a) + 1)
elif "/" in pool:
    print(ipaddress.ip_network(pool, strict=False).num_addresses)
else:
    print(1)
PY
}
say "  ②b 按地址池规模决定验证方式..."
POOL_SIZE="$(_pool_size "${METALLB_POOL}")"
say "    地址池 ${METALLB_POOL} 共 ${POOL_SIZE} 个地址"
VERIFY_MODE="allocate_new"   # allocate_new=新建分配 | verify_existing=直接验证已分配
if [ "${POOL_SIZE}" -le 1 ]; then
    say "    单地址池: 检查 ${METALLB_POOL} 是否已被既有 LoadBalancer 占用..."
    EXISTING_VIP=""; EXISTING_SVC=""; EXISTING_PORT=""
    while read -r svc_line; do
        [ -z "${svc_line}" ] && continue
        _ns="${svc_line%% *}"; _name="$(echo "${svc_line}" | awk '{print $2}')"; _ip="$(echo "${svc_line}" | awk '{print $3}')"; _port="$(echo "${svc_line}" | awk '{print $4}')"
        # 过滤非池内 IP 与默认 kubernetes svc(ClusterIP, 无 LB IP)
        if [ "$(_ip_in_pool "${_ip}" "${METALLB_POOL}")" = "1" ] && [ "${_ip}" != "<none>" ]; then
            EXISTING_VIP="${_ip}"; EXISTING_SVC="${_ns}/${_name}"; EXISTING_PORT="${_port}"; break
        fi
    done < <(SSH "${K} get svc -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,LBIP:.status.loadBalancer.ingress[0].ip,PORT:.spec.ports[0].port --no-headers 2>/dev/null")
    if [ -n "${EXISTING_VIP}" ]; then
        say "    池内唯一地址已被 ${EXISTING_SVC} 占用 (${EXISTING_VIP}:${EXISTING_PORT:-?}), 直接验证该 VIP 工作是否正常"
        VERIFY_MODE="verify_existing"
        VIP="${EXISTING_VIP}"
    else
        say "    池内唯一地址空闲, 走新建分配验证"
    fi
else
    say "    多地址池(≥2 个): 走新建分配验证"
fi
if [ "${VERIFY_MODE}" = "allocate_new" ]; then
    say "  ③ 创建测试后端(nginx httpd) + LoadBalancer Service..."
    cleanup
    LOCAL_YAML="$(mktemp)"
    cat > "${LOCAL_YAML}" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${TEST_NS}
---
apiVersion: v1
kind: Pod
metadata:
  name: ${TEST_NAME}
  namespace: ${TEST_NS}
  labels:
    app: ${TEST_NAME}
spec:
  containers:
  - name: httpd
    image: ${TEST_IMAGE}
    imagePullPolicy: IfNotPresent
    command: ["/bin/sh","-c","echo 'cubestack-verify-ok' > /usr/share/nginx/html/index.html && nginx -g 'daemon off;'"]
---
apiVersion: v1
kind: Service
metadata:
  name: ${TEST_NAME}
  namespace: ${TEST_NS}
spec:
  type: LoadBalancer
  selector:
    app: ${TEST_NAME}
  ports:
  - port: 80
    targetPort: 80
YAML
    # scp 方式提交(避免 heredoc→SSH stdin 管道挂起): 本地写文件 → scp → apply → 清理
    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
        "${LOCAL_YAML}" "${SSH_USER:-ubuntu}@${FIRST_MASTER}:/tmp/${TEST_NAME}.yaml" \
        && SSH "${K} apply -f /tmp/${TEST_NAME}.yaml" \
        && SSH "rm -f /tmp/${TEST_NAME}.yaml"
    rm -f "${LOCAL_YAML}"

    say "  ④ 等待 LoadBalancer 分配到池内 VIP(最长 90s)..."
    VIP=""
    for i in $(seq 1 18); do
        VIP="$(SSH "${K} -n ${TEST_NS} get svc ${TEST_NAME} -o jsonpath={.status.loadBalancer.ingress[0].ip} 2>/dev/null")"
        [ -n "${VIP}" ] && break
        sleep 5
    done
    [ -n "${VIP}" ] || { err "LoadBalancer 90s 内未分配到 VIP。先检查: ① IPAddressPool / L2Advertisement 是否已创建(kubectl -n metallb-system get ipaddresspools; 无池则无法分配); ② METALLB_POOL=${METALLB_POOL} 是否为空闲且与节点同网段; ③ 若池刚配好, 重新 apply 池 CR 或重跑 k8s_deploy 后再验证"; exit 1; }
    say "    已分配 VIP: ${VIP}"
fi

say "  ⑤ 校验 VIP 在 METALLB_POOL=${METALLB_POOL} 内..."
# ⚠ .0/.255 是网络/广播地址, 不应作为 LB VIP; 池子若用 CIDR(如 10.244.2.0/24)会分配出 .0
case "${VIP}" in
    *.0|*.255) err "VIP ${VIP} 是网络/广播地址(.0/.255)。请把 METALLB_POOL=${METALLB_POOL} 改为排除它们的区间(如 10.244.2.1-10.244.2.254)或开 avoidBuggyIPs, 再重试验证"; exit 1 ;;
esac
if [ "$(_ip_in_pool "${VIP}" "${METALLB_POOL}")" = "1" ]; then
    ok "    VIP ${VIP} 在池内 ✓"
else
    err "VIP ${VIP} 不在 ${METALLB_POOL} 内(MetalLB 分配异常)"; exit 1
fi

say "  ⑥ 从首个 master(${FIRST_MASTER}) 访问 http://${VIP}/ ..."
if [ "${VERIFY_MODE}" = "verify_existing" ]; then
    # 复用已有 VIP(来自既有 LB 服务, 如 registry): 不校验测试后端, 直接 curl 验证可达性
    say "    (复用既有服务 ${EXISTING_SVC} 的 VIP:${EXISTING_PORT:-80}, 跳过测试后端等待)"
    HTTP_CODE=""
    for i in 1 2 3; do
        HTTP_CODE="$(SSH "curl -s -m 6 -o /dev/null -w %{http_code} http://${VIP}:${EXISTING_PORT:-80}/ 2>/dev/null")"
        [ -n "${HTTP_CODE}" ] && [ "${HTTP_CODE}" != "000" ] && break
        sleep 3
    done
    case "${HTTP_CODE}" in
        200|301|302|404) ok "    http://${VIP}:${EXISTING_PORT:-80}/ → HTTP ${HTTP_CODE}(VIP 已可达, L2 通告正常) ✓" ;;
        *) err "VIP ${VIP}:${EXISTING_PORT:-80} 访问失败(HTTP=${HTTP_CODE:-超时}); 检查 speaker/节点网络"; exit 1 ;;
    esac
    ok "MetalLB 端到端验证通过: 单地址池既有 VIP ${VIP}:${EXISTING_PORT:-80}(${EXISTING_SVC}) 工作正常, 无需新建测试 LoadBalancer"
    exit 0
fi
say "    等待测试后端 Ready..."
POD_OK=""
for i in $(seq 1 12); do
    POD_OK="$(SSH "${K} -n ${TEST_NS} get pod ${TEST_NAME} -o jsonpath={.status.phase} 2>/dev/null")"
    [ "${POD_OK}" = "Running" ] && break
    sleep 5
done
[ "${POD_OK}" = "Running" ] || { err "测试后端 ${TEST_NAME} 未 Running(phase=${POD_OK:-?}); 检查 nginx 镜像是否已推送进集群 registry(${TEST_IMAGE})与节点能否拉取"; exit 1; }

HTTP_CODE=""
for i in 1 2 3; do
    HTTP_CODE="$(SSH "curl -s -m 6 -o /dev/null -w %{http_code} http://${VIP}/ 2>/dev/null")"
    [ -n "${HTTP_CODE}" ] && [ "${HTTP_CODE}" != "000" ] && break
    sleep 3
done
case "${HTTP_CODE}" in
    200|301|302|404) ok "    http://${VIP}/ → HTTP ${HTTP_CODE}(VIP 已可达, L2 通告正常) ✓" ;;
    *) err "VIP ${VIP} 访问失败(HTTP=${HTTP_CODE:-超时}); 检查 speaker/节点网络"; exit 1 ;;
esac

ok "MetalLB 端到端验证通过: LoadBalancer 分配到池内 VIP ${VIP} 且节点可访问"
