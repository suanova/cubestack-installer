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
# 认证: 优先 SSH 密钥(cubestack_k8s), 回退节点密码(NODES 第5字段 / SSH_DEFAULT_PASSWORD)。
# 全部配置来自 config/cluster.conf(NODES / SSH_KEY / REGISTRY_*), 无硬编码。
# 用法: sudo ./deploy-registry.sh
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

need_root() { [ "$(id -u)" -eq 0 ] || { err "需要 root 权限,请执行: sudo $0"; exit 1; }; }
need_root

# REGISTRY_ENABLED 兼容 1/true/yes/on(TOGGLE 导出可能为 "true" 字符串)
case "${REGISTRY_ENABLED:-0}" in
    1|true|yes|on) ;;
    *) warn "REGISTRY_ENABLED!=1, 跳过 registry 部署(集群内 registry 默认不部署, 设置 REGISTRY_ENABLED=1 可启用)"; exit 0 ;;
esac
[ -n "${REGISTRY_IP:-}" ] && [ -n "${REGISTRY_PORT:-}" ] && [ -n "${REGISTRY_DOMAIN:-}" ] || { err "未配置 REGISTRY_DOMAIN/REGISTRY_IP/REGISTRY_PORT(cluster.conf)"; exit 1; }

SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
SSH_OPTS=(-i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8)

# ---------- 节点远程执行(密钥优先, 密码回退; 密码场景 sudo -S) ----------
node_pw() { node_password "$1" "$2"; }   # 复用 lib-common: 显式密码优先, "-"→默认密码

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
    node_parse "${line}"
    [ -n "${NODE_IP}" ] && [ -n "${NODE_USER}" ] || continue
    NODE_ENTRIES+=("${NODE_IP}:${NODE_USER}:${NODE_PW}:${NODE_HOSTNAME}")
done
[ "${#NODE_ENTRIES[@]}" -gt 0 ] || { err "cluster.conf NODES 为空"; exit 1; }

# 第一个 master 作为 kubectl 入口(按 NODES 顺序找第一个 role=master)
FIRST_MASTER="" ; FIRST_MASTER_USER="" ; FIRST_MASTER_PW=""
for line in "${NODES[@]:-}"; do
    [ -z "${line}" ] && continue
    node_parse "${line}"
    if [ "${NODE_ROLE}" = "master" ]; then FIRST_MASTER="${NODE_IP}"; FIRST_MASTER_USER="${NODE_USER}"; FIRST_MASTER_PW="${NODE_PW}"; break; fi
done
[ -n "${FIRST_MASTER}" ] || { err "cluster.conf 中无 master 节点"; exit 1; }

say "内置 registry 部署(域名=${REGISTRY_DOMAIN}, VIP=${REGISTRY_IP}, 端口=${REGISTRY_PORT}, 节点=${#NODE_ENTRIES[@]}台) ..."

# ---------- 关键: 分配 registry VIP 前先检测冲突(避免撞上其他集群/设备的 IP) ----------
# 背景: MetalLB Layer2 VIP 一旦被其他集群(同样默认取 METALLB_POOL 首地址)或设备占用,
#   ARP 会由"先通告/就近"的一方响应 → 推送/拉取可能打到别的集群的 registry(数据看似在、
#   实际当前集群 registry pod 是空的 → 节点 pull NotFound / ImagePullBackOff)。
# 策略:
#   ① REGISTRY_IP 显式设置 → 原样使用(用户已确认, 跳过探测);
#   ② REGISTRY_IP 留空(自动取 METALLB_POOL 首地址)→ 对候选 VIP 做**服务端口探测**:
#      候选的 ${REGISTRY_PORT} 端口有响应(很可能被其他集群 registry 占用)→ 醒目提示冲突;
#      无响应 → 正常使用。
#   ③ 醒目提示: 若多集群共用同一网段, 首地址必然被第一个集群占用, 后续集群必须显式指定
#      REGISTRY_IP(如池内第二个/更靠后的空闲地址), 避免与其他集群 VIP 冲突。
# 注: ping 对 MetalLB VIP 无效(不响应 ICMP), 改为探测服务端口(/v2/ 有响应即视为被占用)。
#     每次部署的 VIP 是【固定的】(自动取池首地址 / 显式指定), 不会每次随机变化 ——
#     因此多集群/多环境必须保证 METALLB_POOL 或 REGISTRY_IP 彼此不重叠, 否则必然冲突。
_registry_vip_check() {
    local cand="${REGISTRY_IP:-}"
    [ -n "${cand}" ] || return 0
    # 仅自动派生(REGISTRY_IP_EXPLICIT=0)时探测; 显式设置跳过(用户已确认)
    if [ "${REGISTRY_IP_EXPLICIT:-0}" != "1" ]; then
        if curl -s -m 3 "http://${cand}:${REGISTRY_PORT:-5000}/v2/" >/dev/null 2>&1; then
            echo ""
            echo -e "\033[41m\033[97m==============================================================\033[0m"
            echo -e "\033[41m\033[97m ⚠⚠⚠  registry VIP 冲突检测: ${cand}:${REGISTRY_PORT:-5000} 已有服务响应  ⚠⚠⚠\033[0m"
            echo -e "\033[41m\033[97m  自动派生的 METALLB_POOL 首地址可能已被其他集群/设备占用 →        \033[0m"
            echo -e "\033[41m\033[97m  推送/拉取会打到别人的 registry(数据看似在, 实际本集群 registry 空)  \033[0m"
            echo -e "\033[41m\033[97m  【VIP 是固定的, 不会每次随机变化】多集群共用网段时, 后续集群必须:    \033[0m"
            echo -e "\033[41m\033[97m  ① 改 METALLB_POOL 避开已占用段; 或                                   \033[0m"
            echo -e "\033[41m\033[97m  ② 显式设置 REGISTRY_IP 为一个不冲突的池内空闲地址:                 \033[0m"
            echo -e "\033[41m\033[97m    vim ${CLUSTER_CONF:-config/cluster.conf} → REGISTRY_IP=\"10.66.1.13x\"  \033[0m"
            echo -e "\033[41m\033[97m  (用 curl -s http://<候选IP>:5000/v2/ 逐个探测, 无响应者可用)          \033[0m"
            echo -e "\033[41m\033[97m  继续使用将可能再次把镜像推到别的集群(当前部署会继续, 请注意)       \033[0m"
            echo -e "\033[41m\033[97m==============================================================\033[0m"
            echo ""
            warn "registry VIP ${cand}:${REGISTRY_PORT:-5000} 冲突探测: 已有服务响应(可能被其他集群占用), 继续使用有风险"
        fi
    fi
}

# ---------------- 1. registry Service 暴露方式(LoadBalancer 固定 VIP / NodePort) ----------------
say "[1/4] 设置 registry Service 暴露方式(${REGISTRY_SERVICE_TYPE:-loadbalancer}) ..."
# 分配前检测候选 VIP 是否与既有集群/设备冲突(仅自动派生时提示; 显式设置不提示)
_registry_vip_check
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

# ⚠ nodeport 模式(nodeport 默认): 节点侧 containerd 经 hosts.toml 镜像直连首个 master 的
#   REGISTRY_NODEPORT(_NP_MIRROR, 客户端侧改写, 不依赖节点 iptables —— kube-proxy 会周期性重置
#   节点 nat 规则); 宿主机侧 registry.local:5000(→ REGISTRY_IP=首个 master IP)由下方 DNAT 转发到
#   该 master 的 NodePort, 使宿主机 push/curl registry.local:5000 直达 registry(宿主无 kube-proxy,
#   systemd 持久化, 重启自动重建)。
#   ⚠ 容器/无 systemd 环境(如 CLI 部署容器)跳过该 DNAT: nodeport 模式下节点与部署端已直连
#   <首个master>:REGISTRY_NODEPORT 拉取/推送(containerd hosts.toml / ENVOY_PUSH_ENDPOINT), DNAT
#   仅裸机宿主机 registry.local:5000 push 别名的便利项; 且容器内无 NET_ADMIN/systemd 无法生效。
if [ "${REGISTRY_SERVICE_TYPE:-loadbalancer}" = "nodeport" ]; then
    _NP_MIRROR="http://${FIRST_MASTER}:${REGISTRY_NODEPORT:-31148}"
    if [ -f /.dockerenv ] || [ ! -d /run/systemd/system ]; then
        say "[1.5/4] nodeport 模式: 容器/无 systemd 环境, 跳过宿主机 DNAT(registry.local:5000 别名)"
        say "  镜像拉取/推送直连 NodePort: ${_NP_MIRROR}(无需 iptables/systemd)"
    else
        say "[1.5/4] nodeport 模式: 宿主机 registry.local:${REGISTRY_PORT:-5000} → 首个 master:${REGISTRY_NODEPORT:-31148} DNAT ..."
        _FWD_UNIT="cubestack-registry-nodeport"
        _FWD_SCRIPT="/usr/local/bin/${_FWD_UNIT}.sh"
        cat > "${_FWD_SCRIPT}" <<FWDEOF
#!/bin/bash
# Auto-generated by deploy-registry.sh — nodeport 模式宿主机 registry.local:PORT → 首个 master NodePort(勿手工编辑)
# ${REGISTRY_IP}:${REGISTRY_PORT:-5000} → ${FIRST_MASTER}:${REGISTRY_NODEPORT:-31148}
set -e
action="\${1:---add}"
if [ "\${action}" = "--delete" ]; then
    iptables -t nat -D PREROUTING -d ${FIRST_MASTER} -p tcp -m tcp --dport ${REGISTRY_PORT:-5000} -j DNAT --to-destination ${FIRST_MASTER}:${REGISTRY_NODEPORT:-31148} 2>/dev/null || true
    iptables -t nat -D OUTPUT -d ${FIRST_MASTER} -p tcp -m tcp --dport ${REGISTRY_PORT:-5000} -j DNAT --to-destination ${FIRST_MASTER}:${REGISTRY_NODEPORT:-31148} 2>/dev/null || true
else
    iptables -t nat -C PREROUTING -d ${FIRST_MASTER} -p tcp -m tcp --dport ${REGISTRY_PORT:-5000} -j DNAT --to-destination ${FIRST_MASTER}:${REGISTRY_NODEPORT:-31148} 2>/dev/null || \
        iptables -t nat -A PREROUTING -d ${FIRST_MASTER} -p tcp -m tcp --dport ${REGISTRY_PORT:-5000} -j DNAT --to-destination ${FIRST_MASTER}:${REGISTRY_NODEPORT:-31148}
    iptables -t nat -C OUTPUT -d ${FIRST_MASTER} -p tcp -m tcp --dport ${REGISTRY_PORT:-5000} -j DNAT --to-destination ${FIRST_MASTER}:${REGISTRY_NODEPORT:-31148} 2>/dev/null || \
        iptables -t nat -A OUTPUT -d ${FIRST_MASTER} -p tcp -m tcp --dport ${REGISTRY_PORT:-5000} -j DNAT --to-destination ${FIRST_MASTER}:${REGISTRY_NODEPORT:-31148}
fi
exit 0
FWDEOF
        chmod +x "${_FWD_SCRIPT}"
        if bash "${_FWD_SCRIPT}" --add; then
            ok "  宿主机 DNAT 已生效(${FIRST_MASTER}:${REGISTRY_PORT:-5000} → ${FIRST_MASTER}:${REGISTRY_NODEPORT:-31148})"
        else
            warn "  宿主机 DNAT 应用失败(检查 iptables/root 权限; iptables-nft 需 -m tcp 或装 iptables-legacy)"
        fi
        # systemd 持久化(重启自动重建; 本分支已确保 systemd 环境)
        cat > "/etc/systemd/system/${_FWD_UNIT}.service" <<UEOF
[Unit]
Description=CubeStack registry nodeport forward (${REGISTRY_PORT:-5000} -> ${FIRST_MASTER}:${REGISTRY_NODEPORT:-31148})
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${_FWD_SCRIPT} --add
ExecStop=${_FWD_SCRIPT} --delete

[Install]
WantedBy=multi-user.target
UEOF
        systemctl daemon-reload
        systemctl enable "${_FWD_UNIT}" >/dev/null 2>&1 || true
        systemctl start "${_FWD_UNIT}" >/dev/null 2>&1 || true
    fi
else
    _NP_MIRROR="http://${REGISTRY_DOMAIN}:${REGISTRY_PORT}"
fi

# ---------------- 2. 各节点 /etc/hosts + containerd certs.d(vm + bm 全覆盖, 幂等) ----------------
say "[2/4] 配置各节点 /etc/hosts + containerd certs.d ..."
CERTS_DIR="/etc/containerd/certs.d/${REGISTRY_DOMAIN}:${REGISTRY_PORT}"
REMOTE_SCRIPT="/tmp/cubestack-registry-node.sh"
NODE_SCRIPT="$(mktemp)"
cat > "${NODE_SCRIPT}" <<EOF
#!/bin/bash
set -e
# ★ 删旧域名残留行(安装环境 IP 会变): 先删任何指向 REGISTRY_DOMAIN 的旧行, 再写当前 VIP
#   (节点 /etc/hosts 是普通文件系统, sed -i 无 bind-mount rename 问题, 与 lib-common 行为一致)
#   ⚠ heredoc 内需节点运行时展开的变量(如下面 _rd 的赋值命令)必须转义(写成 \$()/\\\$()),
#     让外层 deploy-registry.sh(set -u) 原样输出、由节点 bash 执行; 未转义会在外层展开报 unbound。
_rd="\$(echo '${REGISTRY_DOMAIN}' | sed 's/\./\\\\./g')"
sed -i -E "/[[:space:]]\${_rd}([[:space:]]|\$)/d" /etc/hosts 2>/dev/null || true
echo "${REGISTRY_IP} ${REGISTRY_DOMAIN}" >> /etc/hosts
mkdir -p "${CERTS_DIR}"
cat > "${CERTS_DIR}/hosts.toml" <<HT
server = "http://${REGISTRY_DOMAIN}:${REGISTRY_PORT}"
[host."${_NP_MIRROR}"]
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

# ---------------- 3. 宿主机对外 DNAT(可选, 集群外 push; 默认只用 MetalLB VIP, 不做宿主机 NAT) ----------------
if [ "${REGISTRY_EXPOSE_HOST:-0}" = "1" ]; then
    say "[3/4] 配置宿主机对外 DNAT(REGISTRY_EXPOSE_HOST=1) ..."
    bash "${SCRIPT_DIR}/tools/lb/setup-registry-expose.sh" --add
else
    say "[3/4] 跳过宿主机对外 DNAT(REGISTRY_EXPOSE_HOST!=1; 集群内/节点直接用 MetalLB VIP 拉取, 仅集群外 push 需设 1)"
fi

# ---------------- 4. 验证 + 用法 ----------------
say "[4/4] 验证 ..."
# registry(MetalLB VIP / NodePort)就绪存在时序竞态: kubespray 刚部署完, MetalLB speaker
# 冷启动时可能被 liveness probe 误杀重启, ARP 通告与 kube-proxy DNAT 需更久才稳定;
# registry pod 也可能仍在拉镜像。→ 重试 90s(每 2s 一次, 45 次), 避免误报不可达。
# 注: 不能用 ping VIP 判活(ICMP 无 DNAT 规则必回 "port unreachable"), 只能 curl 服务端口。
_wait_ready() {   # <url> <desc> → 0=可达
    local url="$1" desc="$2" t
    for t in $(seq 1 45); do
        curl -s -m 5 "${url}" >/dev/null 2>&1 && { ok "  ${desc} 可达"; return 0; }
        [ "${t}" -lt 45 ] && { say "  ${desc} 未就绪, 等待第 ${t}/45 次(MetalLB 数据面/registry pod 初始化) ..."; sleep 2; }
    done
    warn "  ${desc} 90s 内不可达"
    return 1
}
if [ "${REGISTRY_SERVICE_TYPE:-loadbalancer}" = "nodeport" ]; then
    NP_OK=$(node_cmd "${FIRST_MASTER}" "${FIRST_MASTER_USER}" "${FIRST_MASTER_PW}" \
        "kubectl get svc -n kube-system registry -o jsonpath='{.spec.ports[0].nodePort}'" 2>/dev/null || echo "")
    FIRST_NODE_IP="$(node_cmd "${FIRST_MASTER}" "${FIRST_MASTER_USER}" "${FIRST_MASTER_PW}" \
        "kubectl get nodes --no-headers -o wide | awk '{print \$6}' | head -1" 2>/dev/null || echo "")"
    say "registry Service NodePort: ${NP_OK:-<获取失败>}(节点 ${FIRST_NODE_IP:-?})"
    [ -n "${NP_OK}" ] && [ -n "${FIRST_NODE_IP}" ] \
        && _wait_ready "http://${FIRST_NODE_IP}:${NP_OK}/v2/" "节点 NodePort ${NP_OK}/v2/"
else
    VIP_OK=$(node_cmd "${FIRST_MASTER}" "${FIRST_MASTER_USER}" "${FIRST_MASTER_PW}" \
        "kubectl get svc -n kube-system registry -o jsonpath='{.status.loadBalancer.ingress[0].ip}'" 2>/dev/null || echo "")
    say "registry Service EXTERNAL-IP: ${VIP_OK:-<获取失败>}"
    _wait_ready "http://${REGISTRY_IP}:${REGISTRY_PORT}/v2/" "${REGISTRY_IP}:${REGISTRY_PORT}/v2/"
fi
# 集群外 push 用的宿主机 DNAT(仅 REGISTRY_EXPOSE_HOST=1 时配置/验证; 集群内走 MetalLB VIP 即可)
if [ "${REGISTRY_EXPOSE_HOST:-0}" = "1" ]; then
    if curl -s -m 5 "http://${HOST_PHYS_IP}:${REGISTRY_PORT}/v2/" >/dev/null 2>&1; then
        ok "  ${HOST_PHYS_IP}:${REGISTRY_PORT}/v2/(DNAT) 可达(集群外 push 入口)"
    else
        say "  ${HOST_PHYS_IP}:${REGISTRY_PORT}/v2/(DNAT) 未启用/不可达(检查 setup-registry-expose.sh --add)"
    fi
fi

echo "---------------------------------------------"
ok "内置 registry 部署完成"
echo "  集群内 pod 拉取:  image: ${REGISTRY_DOMAIN}:${REGISTRY_PORT}/<namespace>/<image>:<tag>(走 MetalLB VIP ${REGISTRY_IP})"
if [ "${REGISTRY_EXPOSE_HOST:-0}" = "1" ]; then
    echo "  集群外 push:     先让 push 机把 ${REGISTRY_DOMAIN} 解析到 ${HOST_PHYS_IP}(/etc/hosts 或内网 DNS),"
    echo "                    docker daemon insecure-registries 加 \"${REGISTRY_DOMAIN}:${REGISTRY_PORT}\", 然后"
    echo "                    docker push ${REGISTRY_DOMAIN}:${REGISTRY_PORT}/<namespace>/<image>:<tag>"
    echo "  撤销对外转发:    sudo ${SCRIPT_DIR}/tools/lb/setup-registry-expose.sh --delete"
fi
echo "  验证 registry:    curl http://${REGISTRY_IP}:${REGISTRY_PORT}/v2/  (loadbalancer) 或 节点:${REGISTRY_NODEPORT:-31148} (nodeport)"
