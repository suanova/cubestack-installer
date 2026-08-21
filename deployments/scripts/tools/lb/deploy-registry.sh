#!/bin/bash
# ============================================================
# 内置 docker registry 部署/启用脚本(对已部署集群幂等; 新集群由 kubespray+patch-playbook 自动完成)
#
# 适用节点: 所有 k8s 节点 —— 虚拟机(node_type=vm)与裸金属(node_type=bm)一视同仁,
#           只要该节点可能调度拉取 registry.local 镜像的 pod, 都要配置 /etc/hosts + containerd certs.d。
#
# 目标:
#   1) 集群内节点能从 registry.local:5000 拉取镜像部署 pod
#      · registry Service 固定 MetalLB LoadBalancer IP(REGISTRY_IP)
#      · 各节点 /etc/hosts 写入 "REGISTRY_IP REGISTRY_DOMAIN"
#      · 各节点 containerd certs.d hosts.toml 信任该 HTTP registry(幂等, 首次才重启 containerd)
#   2) 集群外(物理网)能 push 镜像到内置 registry
#      · 宿主机 DNAT: HOST_PHYS_IP:REGISTRY_PORT → REGISTRY_IP:REGISTRY_PORT(setup-registry-expose.sh)
#
# 认证: 优先 SSH 密钥(cubestack_k8s), 回退节点密码(NODES 第9字段 / WORKER_SSH_PASSWORD)。
# 全部配置来自 config/cluster.conf(NODES / SSH_KEY / REGISTRY_*), 无硬编码。
# 用法: sudo ./deploy-registry.sh
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

need_root() { [ "$(id -u)" -eq 0 ] || { err "需要 root 权限,请执行: sudo $0"; exit 1; }; }
need_root

[ "${REGISTRY_ENABLED:-0}" = "1" ] || { warn "REGISTRY_ENABLED!=1, 跳过 registry 部署(集群内 registry 默认不部署, 设置 REGISTRY_ENABLED=1 可启用)"; exit 0; }
[ -n "${REGISTRY_IP:-}" ] && [ -n "${REGISTRY_PORT:-}" ] && [ -n "${REGISTRY_DOMAIN:-}" ] || { err "未配置 REGISTRY_DOMAIN/REGISTRY_IP/REGISTRY_PORT(cluster.conf)"; exit 1; }

SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
SSH_OPTS=(-i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8)

# ---------- 节点远程执行(密钥优先, 密码回退; 密码场景 sudo -S) ----------
node_pw() { node_password "$1" "$2"; }   # 复用 lib-common: worker→WORKER_SSH_PASSWORD, 其余→SSH_DEFAULT_PASSWORD

# 在节点以 root 执行单条命令(<ip> <user> <pw> <remote cmd...>)
node_cmd() {
    local ip="$1" u="$2" pw="$3"; shift 3
    local full="sudo $*"
    if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${u}@${ip}" "$full" 2>/dev/null; then return 0; fi
    [ -n "${pw}" ] || return 1
    SSHPASS="${pw}" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8 \
        "${u}@${ip}" "echo '${pw}' | sudo -S -p '' $*"
}

# 复制本地脚本到节点(<local> <ip> <user> <pw> <remote_path>)
node_scp() {
    local l="$1" ip="$2" u="$3" pw="$4" r="$5"
    if scp "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=8 "$l" "${u}@${ip}:${r}" 2>/dev/null; then return 0; fi
    [ -n "${pw}" ] || return 1
    SSHPASS="${pw}" sshpass -e scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8 "$l" "${u}@${ip}:${r}"
}

# ---------- 解析节点列表 ----------
NODE_ENTRIES=()   # "ip:user:pw:hostname"
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    IFS=, read -r role hostname ip mac mem cpu disk user pw node_type <<<"${line}"
    [ -n "${ip}" ] && [ -n "${user}" ] || continue
    NODE_ENTRIES+=("${ip}:${user}:$(node_pw "${role}" "${pw}"):${hostname}")
done
[ "${#NODE_ENTRIES[@]}" -gt 0 ] || { err "cluster.conf NODES 为空"; exit 1; }

# 第一个 master 作为 kubectl 入口(按 NODES 顺序找第一个 role=master)
FIRST_MASTER="" ; FIRST_MASTER_USER="" ; FIRST_MASTER_PW=""
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    IFS=, read -r role hostname ip mac mem cpu disk user pw node_type <<<"${line}"
    if [ "${role}" = "master" ]; then FIRST_MASTER="${ip}"; FIRST_MASTER_USER="${user}"; FIRST_MASTER_PW="$(node_pw master "${pw}")"; break; fi
done
[ -n "${FIRST_MASTER}" ] || { err "cluster.conf 中无 master 节点"; exit 1; }

say "内置 registry 部署(域名=${REGISTRY_DOMAIN}, VIP=${REGISTRY_IP}, 端口=${REGISTRY_PORT}, 节点=${#NODE_ENTRIES[@]}台) ..."

# ---------------- 1. registry Service 暴露方式(LoadBalancer 固定 VIP / NodePort) ----------------
say "[1/4] 设置 registry Service 暴露方式(${REGISTRY_SERVICE_TYPE:-loadbalancer}) ..."
SVC_EXISTS=$(node_cmd "${FIRST_MASTER}" "${FIRST_MASTER_USER}" "${FIRST_MASTER_PW}" \
    "kubectl get svc -n kube-system registry -o name" 2>/dev/null || echo "")
if [ -z "${SVC_EXISTS}" ]; then
    err "未找到 kube-system/registry Service(集群未部署 registry addon? 检查 addons.yml registry_enabled)"
    exit 1
fi
case "${REGISTRY_SERVICE_TYPE:-loadbalancer}" in
    nodeport)
        CUR_NP=$(node_cmd "${FIRST_MASTER}" "${FIRST_MASTER_USER}" "${FIRST_MASTER_PW}" \
            "kubectl get svc -n kube-system registry -o jsonpath='{.spec.ports[0].nodePort}'" 2>/dev/null || echo "")
        if [ "${CUR_NP}" != "${REGISTRY_NODEPORT:-31148}" ]; then
            node_cmd "${FIRST_MASTER}" "${FIRST_MASTER_USER}" "${FIRST_MASTER_PW}" \
                "kubectl patch svc -n kube-system registry -p '{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":${REGISTRY_PORT:-5000},\"targetPort\":5000,\"nodePort\":${REGISTRY_NODEPORT:-31148}}]}}'" >/dev/null 2>&1
            ok "registry Service → NodePort:${REGISTRY_NODEPORT:-31148}"
        else
            ok "registry Service 已是 NodePort:${CUR_NP}"
        fi
        ;;
    *)
        CUR_IP=$(node_cmd "${FIRST_MASTER}" "${FIRST_MASTER_USER}" "${FIRST_MASTER_PW}" \
            "kubectl get svc -n kube-system registry -o jsonpath='{.status.loadBalancer.ingress[0].ip}'" 2>/dev/null || echo "")
        if [ "${CUR_IP}" != "${REGISTRY_IP}" ]; then
            node_cmd "${FIRST_MASTER}" "${FIRST_MASTER_USER}" "${FIRST_MASTER_PW}" \
                "kubectl patch svc -n kube-system registry -p '{\"spec\":{\"type\":\"LoadBalancer\",\"loadBalancerIP\":\"${REGISTRY_IP}\"}}'" >/dev/null 2>&1
            ok "registry Service LB IP: ${CUR_IP:-<未分配>} → ${REGISTRY_IP}"
        else
            ok "registry Service LB IP 已是 ${REGISTRY_IP}"
        fi
        ;;
esac

# ---------------- 2. 各节点 /etc/hosts + containerd certs.d(vm + bm 全覆盖, 幂等) ----------------
say "[2/4] 配置各节点 /etc/hosts + containerd certs.d ..."
CERTS_DIR="/etc/containerd/certs.d/${REGISTRY_DOMAIN}:${REGISTRY_PORT}"
REMOTE_SCRIPT="/tmp/cubestack-registry-node.sh"
NODE_SCRIPT="$(mktemp)"
cat > "${NODE_SCRIPT}" <<EOF
#!/bin/bash
set -e
grep -qF "${REGISTRY_IP} ${REGISTRY_DOMAIN}" /etc/hosts || echo "${REGISTRY_IP} ${REGISTRY_DOMAIN}" >> /etc/hosts
mkdir -p "${CERTS_DIR}"
cat > "${CERTS_DIR}/hosts.toml" <<HT
server = "http://${REGISTRY_DOMAIN}:${REGISTRY_PORT}"
[host."http://${REGISTRY_DOMAIN}:${REGISTRY_PORT}"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
HT
if [ ! -f /var/lib/containerd/certs.d-stamp ]; then
    systemctl restart containerd
    touch /var/lib/containerd/certs.d-stamp
    echo "containerd restarted(首次配置)"
else
    echo "certs.d 已就绪(无需重启)"
fi
EOF
chmod +x "${NODE_SCRIPT}"

for e in "${NODE_ENTRIES[@]}"; do
    ip="${e%%:*}"; rest="${e#*:}"; u="${rest%%:*}"; rest="${rest#*:}"; pw="${rest%%:*}"; hn="${rest#*:}"
    if node_scp "${NODE_SCRIPT}" "${ip}" "${u}" "${pw}" "${REMOTE_SCRIPT}"; then
        out=$(node_cmd "${ip}" "${u}" "${pw}" "bash ${REMOTE_SCRIPT}" 2>/dev/null) \
            && ok "  ${hn}(${ip}): ${out}" || warn "  ${hn}(${ip}): 执行失败"
    else
        warn "  ${hn}(${ip}): 无法上传配置脚本(检查密钥/密码)"
    fi
done
rm -f "${NODE_SCRIPT}"

# ---------------- 3. 宿主机对外 DNAT(集群外 push) ----------------
say "[3/4] 配置宿主机对外 DNAT ..."
bash "${SCRIPT_DIR}/tools/lb/setup-registry-expose.sh" --add

# ---------------- 4. 验证 + 用法 ----------------
say "[4/4] 验证 ..."
sleep 2
if [ "${REGISTRY_SERVICE_TYPE:-loadbalancer}" = "nodeport" ]; then
    NP_OK=$(node_cmd "${FIRST_MASTER}" "${FIRST_MASTER_USER}" "${FIRST_MASTER_PW}" \
        "kubectl get svc -n kube-system registry -o jsonpath='{.spec.ports[0].nodePort}'" 2>/dev/null || echo "")
    FIRST_NODE_IP="$(node_cmd "${FIRST_MASTER}" "${FIRST_MASTER_USER}" "${FIRST_MASTER_PW}" \
        "kubectl get nodes --no-headers -o wide | awk '{print \$6}' | head -1" 2>/dev/null || echo "")"
    say "registry Service NodePort: ${NP_OK:-<获取失败>}(节点 ${FIRST_NODE_IP:-?})"
    curl -s -m 5 "http://${FIRST_NODE_IP:-127.0.0.1}:${NP_OK}/v2/" >/dev/null 2>&1 && ok "  节点 NodePort ${NP_OK}/v2/ 可达" || warn "  节点 NodePort ${NP_OK}/v2/ 不可达(稍后重试)"
else
    VIP_OK=$(node_cmd "${FIRST_MASTER}" "${FIRST_MASTER_USER}" "${FIRST_MASTER_PW}" \
        "kubectl get svc -n kube-system registry -o jsonpath='{.status.loadBalancer.ingress[0].ip}'" 2>/dev/null || echo "")
    say "registry Service EXTERNAL-IP: ${VIP_OK:-<获取失败>}"
    curl -s -m 5 "http://${REGISTRY_IP}:${REGISTRY_PORT}/v2/" >/dev/null 2>&1 && ok "  ${REGISTRY_IP}:${REGISTRY_PORT}/v2/ 可达" || warn "  ${REGISTRY_IP}:${REGISTRY_PORT}/v2/ 不可达(稍后重试)"
fi
curl -s -m 5 "http://${HOST_PHYS_IP}:${REGISTRY_PORT}/v2/" >/dev/null 2>&1 && ok "  ${HOST_PHYS_IP}:${REGISTRY_PORT}/v2/(DNAT) 可达" || warn "  ${HOST_PHYS_IP}:${REGISTRY_PORT}/v2/(DNAT) 不可达"

echo "---------------------------------------------"
ok "内置 registry 部署完成"
echo "  集群内 pod 拉取:  image: ${REGISTRY_DOMAIN}:${REGISTRY_PORT}/<namespace>/<image>:<tag>"
echo "  集群外 push:     先让 push 机把 ${REGISTRY_DOMAIN} 解析到 ${HOST_PHYS_IP}(/etc/hosts 或内网 DNS),"
echo "                    docker daemon insecure-registries 加 \"${REGISTRY_DOMAIN}:${REGISTRY_PORT}\", 然后"
echo "                    docker push ${REGISTRY_DOMAIN}:${REGISTRY_PORT}/<namespace>/<image>:<tag>"
echo "  验证 registry:    curl http://${REGISTRY_IP}:${REGISTRY_PORT}/v2/  (loadbalancer) 或 节点:${REGISTRY_NODEPORT:-31148} (nodeport)"
echo "  撤销对外转发:    sudo ${SCRIPT_DIR}/tools/lb/setup-registry-expose.sh --delete"
