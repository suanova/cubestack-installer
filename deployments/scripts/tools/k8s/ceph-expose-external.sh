#!/bin/bash
# ============================================================
# TOOL: ceph-expose-external
# DESC: 本集群 Ceph 对外暴露与完整预定义(mon + RGW Service + 外部 RBD/CephFS 资源 + 专用用户)
#       —— 供其他 K8s 集群的 ceph-csi-operator(CEPH_MODE=external)接入
# 设计(对齐 ceph-csi-operator 外部连接需求):
#   ① 网络层: mon/RGW *-external Service(YAML 模板 → kubectl apply, 与集群内访问共存)
#   ② 资源层: 专用外部 RBD pool + 外部 CephFS(fs + meta/data pools)+ application tag
#   ③ 认证层: 专用用户(profile caps, 非 admin): cubestack-ext-rbd / cubestack-ext-cephfs(provisioner)
#      + cubestack-ext-cephfs-node(node 角色, 2026-09-10 Bug A 分用户: meta+data 池 rw)
#   ④ 导出:   ceph-external-access.conf(FSID/MONs/双用户 key/pool/fs 名, 拷贝到目标集群即可)
#   ⑤ 自检:   status 5 层, 含**外部客户端协议级测试**(mon 握手 + cephx 认证 + RBD API,
#              模拟 ceph-csi-operator 从集群外连接; 客户端=Dockerfile-cli 预装 ceph-common)
# 实现要点:
#   · mon/RGW 新建独立 *-external svc(不碰 Rook 自管 ClusterIP svc —— operator 会调和回滚)
#   · nodePort 自动分配(30000-32767; 显式 6789 超 kube-apiserver 端口范围会失败)
#   · 模式(大小写不敏感, 一律 tr 转小写): --mode > CEPH_EXTERNAL_EXPOSE_MODE > CEPH_EXPOSE_MODE >
#     CEPH_HOST_NETWORK=true 时默认 host-network
#     host-network(默认) → 直接对节点 IP 暴露 mon 原生 6789/3300 + RGW 80(无 kube-proxy/DNAT;
#                         CEPH_HOST_NETWORK=true 时 CephCluster spec.network.hostNetwork=true, mon 公告节点 IP);
#                         CEPH_MONITORS = <mon 所在节点 IP>:6789
#     nodeport → NodePort(历史; NodePort 环对 mon msgr 握手不可靠, 见 2026-09-09 事故);
#     metallb/loadbalancer → LoadBalancer VIP; clusterip/off → 不暴露
# 用法(部署机/容器内):
#   bash ceph-expose-external.sh apply [--mode host-network|nodeport|loadbalancer|metallb|clusterip]  # 暴露+预定义+导出
#   bash ceph-expose-external.sh show                                                   # 当前暴露状态
#   bash ceph-expose-external.sh status                                                 # 5 层自检(含外部客户端测试)
# 数据源: cluster.conf(CEPH_* / CEPH_EXTERNAL_* / CEPH_RGW_EXPOSE_MODE / CEPHFS_ENABLED /
#         CEPH_POOL_REPLICAS / SERVICE_EXPOSE_MODE / NODES / CEPH_HOST_NETWORK / CEPH_EXPOSE_MODE)
# 输出:   config/ceph-external-access.conf(外部集群配置用, 见 CEPH_MODE=external)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config
init_remote_kubectl || { err "init_remote_kubectl 失败"; exit 1; }

CEPH_NAMESPACE="${CEPH_NAMESPACE:-rook-ceph}"
EXPORT_CONF="${CEPH_EXTERNAL_CONF:-${REPO_ROOT}/deployments/config/ceph-external-access.conf}"
ROOK_DIR="${CEPH_ROOK_MANIFEST_DIR:-${REPO_ROOT}/deployments/cubestack-addon/rook}"
# ---- 外部专用资源/用户(2026-09-07 完整预定义; 对齐"外部 ceph-csi-operator 连接所需全部信息") ----
EXT_USER="${CEPH_EXTERNAL_USER:-cubestack-ext-rbd}"                 # 外部 RBD 专用用户
EXT_RBD_POOL="${CEPH_EXTERNAL_RBD_POOL:-cubestack-ext-rbd-pool}"    # 外部专用 RBD pool(独立于集群内 rbd-pool)
EXT_RBD_PG="${CEPH_EXTERNAL_RBD_PG:-32}"                            # 外部 RBD pool PG 数
EXT_CEPHFS_ENABLED="${CEPH_EXTERNAL_CEPHFS:-${CEPHFS_ENABLED:-false}}"  # 外部 CephFS(随集群 CEPHFS_ENABLED)
EXT_CEPHFS_USER="${CEPH_EXTERNAL_CEPHFS_USER:-cubestack-ext-cephfs}"   # 外部 CephFS 专用用户(provisioner 角色: mon allow r / mds allow rw / osd allow rw meta)
EXT_CEPHFS_NODE_USER="${CEPH_EXTERNAL_CEPHFS_NODE_USER:-cubestack-ext-cephfs-node}"  # 外部 CephFS node 角色用户(挂载 fs, 需 meta+data 池 rw; 2026-09-10 Bug A 分用户)
EXT_FS="${CEPH_EXTERNAL_CEPHFS_FS:-cubestack-ext-fs}"               # 外部 CephFS 名
EXT_FS_META="${CEPH_EXTERNAL_CEPHFS_META_POOL:-cubestack-ext-cephfs-metadata}"
EXT_FS_DATA="${CEPH_EXTERNAL_CEPHFS_DATA_POOL:-cubestack-ext-cephfs-data}"
EXT_FS_META_PG="${CEPH_EXTERNAL_CEPHFS_META_PG:-16}"
EXT_FS_DATA_PG="${CEPH_EXTERNAL_CEPHFS_DATA_PG:-32}"
# ---- 规律 NodePort(2026-09-08): mon 按 mon_list 顺序(base, base+1, base+2 ...), RGW 固定 ----
# 默认 30100 → mon a/b/c = 30100/30101/30102(默认 apiserver service-node-port-range=30000-32767 内, 无需扩范围)。
# 想要 36789 这种风格需先把 apiserver range 扩到 30000-40000(见 cluster.conf.example 说明)。
# base 留空 → 自动分配随机端口(原行为)。
MON_NP_BASE="${CEPH_MON_NODEPORT_BASE:-30100}"   # 规律 nodePort 起始值; 留空=自动分配
MON_NP_MAX="${CEPH_MON_NODEPORT_MAX:-32767}"      # 规律分配硬上限(kube-apiserver service-node-port-range 上限; 扩 range 后调大)
RGW_NP="${CEPH_RGW_NODEPORT:-}"                   # RGW 固定 NodePort(留空=自动分配; 已有配置兼容)

# ── 模式解析(大小写不敏感: 一律 tr 转小写; 优先级 --mode > CEPH_EXTERNAL_EXPOSE_MODE > SERVICE_EXPOSE_MODE) ──
MODE=""
ARGS=( "$@" )
while [ $# -gt 0 ]; do
    case "$1" in
        --mode) MODE="$2"; shift 2 ;;
        *) shift ;;
    esac
done
set -- "${ARGS[@]}"
ACTION="${1:-show}"
# ★ 暴露模式解析(2026-09-09): 优先级 --mode > CEPH_EXTERNAL_EXPOSE_MODE > CEPH_EXPOSE_MODE >
#   CEPH_HOST_NETWORK=true 时默认 host-network(直连节点 IP:6789, 绕开 kube-proxy/DNAT);
#   否则回退 SERVICE_EXPOSE_MODE(nodeport/metallb)。
[ -z "${MODE}" ] && MODE="${CEPH_EXTERNAL_EXPOSE_MODE:-${CEPH_EXPOSE_MODE:-}}"
[ -z "${MODE}" ] && { [ "${CEPH_HOST_NETWORK:-true}" = "true" ] && MODE="host-network" || MODE="${SERVICE_EXPOSE_MODE:-nodeport}"; }
MODE="$(echo "${MODE}" | tr '[:upper:]' '[:lower:]')"
# metallb(集群级暴露模式别名)→ loadbalancer(Service 类型语义)
[ "${MODE}" = "metallb" ] && MODE="loadbalancer"
# host-network 别名归一(hostNetwork/host)→ host-network
case "${MODE}" in hostnetwork|host_network|host) MODE="host-network" ;; esac

SVC_TYPE=""
case "${MODE}" in
    nodeport)     SVC_TYPE="NodePort" ;;
    loadbalancer) SVC_TYPE="LoadBalancer" ;;
    host-network) SVC_TYPE="" ;;   # 无 Service; 直接露出节点 IP 原生端口(mon 6789/3300, rgw 80)
    clusterip|off|none) ;;
    *) warn "  未知暴露模式: ${MODE}(可用 host-network/nodeport/loadbalancer/metallb/clusterip); 按不暴露处理" ;;
esac

# ── 总开关: 默认允许外部 ceph-csi-operator 接入 ──
[ "${CEPH_EXTERNAL_EXPOSE:-true}" = "true" ] || { say "CEPH_EXTERNAL_EXPOSE=false, 跳过 Ceph 对外暴露"; exit 0; }
# 仅集群内 Ceph 才有本集群 Ceph 可暴露(CEPH_MODE=external 的接入方集群直接跳过)
if ! SSH "${K} -n ${CEPH_NAMESPACE} get cephcluster --no-headers >/dev/null 2>&1"; then
    say "  本集群无集群内 CephCluster(CEPH_MODE=external 接入方), 跳过对外暴露"
    exit 0
fi

# ── 集群内 toolbox 执行 ceph 管理命令: <参数...> → 输出(失败返回非 0) ──
# ⚠ 逐参单引号包裹(经 ssh/远程 shell 传参时保留含空格参数, 如 caps "profile rbd";
#   若直接 $* 拼接, 引号丢失 → ceph 把 "profile rbd" 拆成两个 argv, 认证权限错乱)
_ceph_q() {   # <argv...> → 单引号包裹的命令串
    local out="" a
    for a in "$@"; do
        out="${out:+${out} }'${a//\'/\'\\\'\'}'"
    done
    printf '%s' "${out}"
}
_ceph_exec() {
    SSH "${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph-tools -- ceph $(_ceph_q "$@")"
}

# ── 远端应用 YAML: <内容> <临时名> → cat > /tmp + kubectl apply(幂等) ──
_apply_yaml() {
    local content="$1" name="$2"
    printf '%s' "${content}" | ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "${SSH_USER:-ubuntu}@${FIRST_MASTER}" "cat > /tmp/${name}.yaml && ${K} apply -f /tmp/${name}.yaml" \
        && SSH "rm -f /tmp/${name}.yaml" >/dev/null 2>&1 || true
}
_svc_np()  { ( SSH "${K} -n ${CEPH_NAMESPACE} get svc "$1" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null" || true ); }
_svc_vip() { ( SSH "${K} -n ${CEPH_NAMESPACE} get svc "$1" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null" || true ); }
_svc_type(){ ( SSH "${K} -n ${CEPH_NAMESPACE} get svc "$1" -o jsonpath='{.spec.type}' 2>/dev/null" || true ); }
_svc_port(){ ( SSH "${K} -n ${CEPH_NAMESPACE} get svc "$1" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null" || true ); }
# 等待 LoadBalancer VIP(最长 120s)
_wait_vip() {
    local svc="$1" vip=""
    for _vi in $(seq 1 12); do
        vip="$(_svc_vip "${svc}")"
        [ -n "${vip}" ] && break
        sleep 10
    done
    echo "${vip}"
}

# ── mon 列表: 从 rook-ceph-mon-endpoints CM 读实际 mon id(a/b/c), 读不到则回退 a b c ──
mon_list() {
    local data ids
    data="$( ( SSH "${K} -n ${CEPH_NAMESPACE} get cm rook-ceph-mon-endpoints -o jsonpath='{.data.data}' 2>/dev/null" || true) )"
    ids="$(echo "${data}" | tr ',' '\n' | sed -n 's/^rook-ceph-mon-\([a-z0-9]*\)=.*/\1/p' | tr '\n' ' ')"
    echo "${ids:-a b c}"
}

# 外部 mon 端点列表: "ip:port,ip:port"
#   host-network = mon 所在节点 IP:6789(原生端口直连, 绕开 kube-proxy —— 2026-09-09 默认推荐)
#   NodePort      = master:nodePort(规律值) / LB = VIP:svc.port(规律值)
ext_mon_eps() {
    local out="" m T np vip pt _nip
    if [ "${MODE}" = "host-network" ]; then
        # 从 rook-ceph-mon-endpoints CM mapping 读 mon 所在节点 IP(node ptr → Address)
        local mons data mapping
        for m in $(mon_list); do
            _nip="$(_mon_ip "${m}")"
            [ -n "${_nip}" ] && out="${out:+${out},}${_nip}:6789"
        done
        echo "${out}"
        return 0
    fi
    for m in $(mon_list); do
        T="$(_svc_type "rook-ceph-mon-${m}-external")"
        if [ "${T}" = "NodePort" ]; then
            np="$(_svc_np "rook-ceph-mon-${m}-external")"
            [ -n "${np}" ] && out="${out:+${out},}${FIRST_MASTER}:${np}"
        elif [ "${T}" = "LoadBalancer" ]; then
            vip="$(_svc_vip "rook-ceph-mon-${m}-external")"
            pt="$(_svc_port "rook-ceph-mon-${m}-external")"
            [ -n "${vip}" ] && [ -n "${pt}" ] && out="${out:+${out},}${vip}:${pt}"
        fi
    done
    echo "${out}"
}

# ★ host-network 模式: 返回 mon <id> 所在节点的 IP(从 rook-ceph-mon-endpoints CM 的 mapping 读;
#   读不到时回退: 在全部 NODES 里找 hostname/Address 匹配的 node, 无则跳过该 mon)
_mon_ip() {   # <mon_id> → 节点 IP(空=未知)
    local id="$1" mapping addr host ip out line
    # ① 从 CM mapping 字段取 Address(JSON: "a":{"Name":...,"Address":"10.244.1.33"})
    mapping="$( ( SSH "${K} -n ${CEPH_NAMESPACE} get cm rook-ceph-mon-endpoints -o jsonpath='{.data.mapping}' 2>/dev/null" || true) )"
    if [ -n "${mapping}" ]; then
        addr="$(echo "${mapping}" | python3 -c "import sys,json; d=json.load(sys.stdin).get('node',{}); print(d.get('${id}',{}).get('Address',''))" 2>/dev/null)"
        [ -n "${addr}" ] && { echo "${addr}"; return 0; }
    fi
    # ② 回退: 在 NODES 中按 hostname 找 IP
    data="$( ( SSH "${K} -n ${CEPH_NAMESPACE} get cm rook-ceph-mon-endpoints -o jsonpath='{.data.data}' 2>/dev/null" || true) )"
    host="$(echo "${data}" | tr ',' '\n' | sed -n "s/^rook-ceph-mon-${id}=//p" | head -1 || true)"
    [ -z "${host}" ] && return 1
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        [ "${NODE_HOSTNAME}" = "${host}" ] && { echo "${NODE_IP}"; return 0; }
    done
    return 1
}

# 生成并应用 external Service YAML: <模板文件> <临时名> [附加 sed 表达式...]
# 公共替换: __NAMESPACE__ / __TYPE__(由调用方传入)
# ⚠ sed 参数必须用数组构建(字符串拼接再 word-split 会拆裂含空格表达式)
_tpl_apply() {
    local tpl="$1" name="$2"; shift 2
    local -a _sedargs=(sed -e "s|__NAMESPACE__|${CEPH_NAMESPACE}|g")
    local expr
    for expr in "$@"; do _sedargs+=(-e "${expr}"); done
    local content
    content="$("${_sedargs[@]}" "${tpl}")"
    _apply_yaml "${content}" "${name}"
}

# ── 规律 NodePort: 按 mon_list 顺序给第 <idx> 个 mon 分配端口 ──
#   复用 lib-common 的 nodeport_alloc(base, count, max, off); 见 nodeport_alloc 说明。
_mon_np() {   # <idx>
    local _mc="$(mon_list | wc -w)" _i="${1:-0}"
    nodeport_alloc "${MON_NP_BASE}" "${_mc}" "${MON_NP_MAX}" "${_i}"
}

# ════════════════════════════ 官方 external-ceph.env 导出(2026-09-10) ════════════════════════════
# 经 toolbox 运行官方 create-external-cluster-resources.py(vendored, v1.20.2):
#   · 在提供方 Ceph 上创建官方 CSI 双角色用户(csi-rbd-node/provisioner + csi-cephfs-node/provisioner,
#     带 caps)/ client.healthchecker / rgw-admin-ops-user(RGW 启用时)
#   · --format bash 输出 export 行(Rook 官方 external-ceph.env 格式), 供消费方
#     CEPH_EXTERNAL_ENV_FILE 官方导入路径直接使用(见 03_ceph_csi.sh _ext_import_official)
# 输出: ${REPO_ROOT}/deployments/config/external-ceph.env(gitignore, 勿提交真实 key)
_export_official_env() {
    local _py="${ROOK_DIR}/external/create-external-cluster-resources.py"
    [ -f "${_py}" ] || { warn "  vendored 官方导出脚本缺失: ${_py}(联网机从 rook v1.20.2 deploy/examples/external 拷贝)"; return 1; }
    say "[导出] 官方 external-ceph.env(create-external-cluster-resources.py 经 toolbox)..."
    # ① 脚本拷进 toolbox(toolbox 内有 ceph.conf + admin keyring + python3)
    if ! base64 -w0 "${_py}" | SSH "${K} -n ${CEPH_NAMESPACE} exec -i deploy/rook-ceph-tools -- bash -c 'base64 -d > /tmp/create-external-cluster-resources.py'" >/dev/null 2>&1; then
        warn "  官方导出脚本拷入 toolbox 失败(检查 toolbox 是否 Ready: kubectl -n ${CEPH_NAMESPACE} get pods | grep tools)"; return 1
    fi
    # ② 组装参数: RBD 池必填; CephFS 启用时带 fs/两池; RGW 启用时带端点+realm/zone
    local _py_args="--namespace ${CEPH_NAMESPACE} --format bash --output /tmp/external-ceph.env"
    _py_args="${_py_args} --rbd-data-pool-name ${EXT_RBD_POOL}"
    if [ "${EXT_CEPHFS_ENABLED}" = "true" ]; then
        _py_args="${_py_args} --cephfs-filesystem-name ${EXT_FS} --cephfs-data-pool-name ${EXT_FS_DATA} --cephfs-metadata-pool-name ${EXT_FS_META}"
    fi
    if [ -n "${RGW_EP:-}" ]; then
        # 官方脚本 --rgw-endpoint 期望 ip:port(剥 http:// 前缀); realm/zone 跟随 CephObjectStore 名
        local _rgw_ep="${RGW_EP#http://}" _rgw_ep="${_rgw_ep#https://}"
        _py_args="${_py_args} --rgw-endpoint ${_rgw_ep} --rgw-realm-name s3-store --rgw-zonegroup-name s3-store --rgw-zone-name s3-store"
    fi
    # ③ toolbox 内运行(用户已存在 → 脚本幂等: EEXIST 回退 user info; 密钥轮换 CEPHX_KEY_GENERATION 自动递增)
    say "  toolbox 运行官方导出脚本(${_py_args})..."
    if ! SSH "${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph-tools -- python3 /tmp/create-external-cluster-resources.py ${_py_args}" >/tmp/ceph-ext-export.log 2>&1; then
        warn "  官方导出脚本运行失败(见 /tmp/ceph-ext-export.log; 常见: rgw 参数与 RGW 部署不一致/池不存在)"
        SSH "${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph-tools -- tail -5 /tmp/create-external-cluster-resources.py.log" >/dev/null 2>&1 || true
        return 1
    fi
    # ④ 取回 env 输出 → 部署机指定目录
    local _env_out="${REPO_ROOT}/deployments/config/external-ceph.env"
    mkdir -p "$(dirname "${_env_out}")"
    if SSH "${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph-tools -- cat /tmp/external-ceph.env" > "${_env_out}" 2>/dev/null \
        && grep -q "ROOK_EXTERNAL_FSID\|ROOK_EXTERNAL_CEPH_MON_DATA" "${_env_out}"; then
        chmod 600 "${_env_out}" 2>/dev/null || true
        ok "  官方 external-ceph.env 已导出 → ${_env_out}"
        echo "  (消费方把此文件放到其部署机, cluster.conf 设 CEPH_EXTERNAL_ENV_FILE=<路径> 即走官方导入)"
    else
        warn "  env 输出取回失败/内容不完整(见 /tmp/ceph-ext-export.log)"
        return 1
    fi
    # 清理 toolbox 内临时文件
    SSH "${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph-tools -- rm -f /tmp/external-ceph.env /tmp/create-external-cluster-resources.py" >/dev/null 2>&1 || true
    return 0
}

# ════════════════════════════ apply ════════════════════════════
apply_main() {
    say "==== Ceph 对外暴露 apply(模式=${MODE}, Service type=${SVC_TYPE:-host-network 直连}) ===="

    # ① 网络层: mon 对外端点
    #   host-network(默认) → 无 Service; CephCluster hostNetwork 下 mon 直接监听节点 IP,
    #     外部连 <mon 所在节点 IP>:6789 即 mon —— **绕开 kube-proxy/DNAT/CNI**
    #     (2026-09-09 事故: NodePort 环 mon msgr v1 握手发 auth 后无响应, 改用 node 直连原生端口)。
    #   nodeport / loadbalancer → 仍创建 *-external Service(历史路径, 见下方循环)。
    EXT_MONS=""
    if [ "${MODE}" = "host-network" ]; then
        say "[网络层] host-network 模式: mon 直连节点 IP:6789(无 Service, 绕开 kube-proxy)..."
        for m in $(mon_list); do
            _nip="$(_mon_ip "${m}")"
            if [ -n "${_nip}" ]; then
                say "    - mon.${m} → ${_nip}:6789(mon 所在节点 IP; v2=3300)"
                EXT_MONS="${EXT_MONS:+${EXT_MONS},}${_nip}:6789"
            else
                warn "  mon.${m} 节点 IP 未知(CM mapping/NODES 解析失败), 跳过"
            fi
        done
        if [ -z "${EXT_MONS}" ]; then
            err "  host-network 模式: 未解析到任何 mon 节点 IP(检查 rook-ceph-mon-endpoints CM 与 NODES)"
            exit 1
        fi
        ok "  mon 外部端点(hostNetwork 直连): ${EXT_MONS}"
        # RGW: hostNetwork 的 rgw pod 也直接监听节点 IP:80
        RGW_EP=""
        _rgw_host="$(_mon_ip "$(mon_list | awk '{print $1}')")"
        [ -n "${_rgw_host}" ] && RGW_EP="http://${_rgw_host}:80"
        say "  RGW s3-store → 节点 IP:80(http://${_rgw_host}:80)"
    else
    say "[网络层] 创建 mon 外部 Service(type=${SVC_TYPE}, nodePort=${MON_NP_BASE:-自动分配 30000-32767})..."
    _mon_i=0
    for m in $(mon_list); do
        if ! SSH "${K} -n ${CEPH_NAMESPACE} get svc rook-ceph-mon-${m} --no-headers >/dev/null 2>&1"; then
            warn "  rook-ceph-mon-${m} 不存在(mon 列表变化?), 跳过该 mon"
            continue
        fi
        _mnp="$(_mon_np "${_mon_i}")"
        _mport="${_mnp:-6789}"     # 对外规律端口: 仅 nodeport 模式用(nodePort=base+off)
        if [ "${MODE}" = "nodeport" ]; then
            if [ -n "${_mnp}" ]; then
                # 规律端口: 模板 nodePort 填规律值; port 保持 Ceph 原生 6789(内部不变)
                _tpl_apply "${ROOK_DIR}/external/01-mon-external.yaml" "ceph-mon-ext-${m}" \
                    "s|__MON_ID__|${m}|g" "s|__TYPE__|${SVC_TYPE}|g" \
                    "s|__MON_PORT__|6789|g" "s|__MON_NODEPORT__|${_mnp}|g" \
                    && ok "  rook-ceph-mon-${m}-external 已创建/更新(nodePort=${_mnp}, port=6789)" \
                    || warn "  rook-ceph-mon-${m}-external 应用失败"
            else
                # 自动分配: 只保留 port=6789, nodePort 由 apiserver 随机
                _tpl_apply "${ROOK_DIR}/external/01-mon-external.yaml" "ceph-mon-ext-${m}" \
                    "s|__MON_ID__|${m}|g" "s|__TYPE__|${SVC_TYPE}|g" \
                    "s|__MON_PORT__|6789|g" "/nodePort: __MON_NODEPORT__/d" \
                    && ok "  rook-ceph-mon-${m}-external 已创建/更新(自动分配)" \
                    || warn "  rook-ceph-mon-${m}-external 应用失败"
            fi
        else
            # LoadBalancer/MetalLB 模式: 用 Ceph 原生端口 6789(不套规律端口; LB VIP 不占宿主机端口,
            # 外部端点 = VIP:6789 即 Ceph 默认端口); 不分配 nodePort
            _tpl_apply "${ROOK_DIR}/external/01-mon-external.yaml" "ceph-mon-ext-${m}" \
                "s|__MON_ID__|${m}|g" "s|__TYPE__|${SVC_TYPE}|g" \
                "s|__MON_PORT__|6789|g" "/nodePort: __MON_NODEPORT__/d" \
                && ok "  rook-ceph-mon-${m}-external 已创建/更新(port=6789 Ceph 原生端口)" \
                || warn "  rook-ceph-mon-${m}-external 应用失败"
        fi
        if [ "${MODE}" = "nodeport" ]; then
            _np="$(_svc_np "rook-ceph-mon-${m}-external")"
            if [ -n "${_np}" ]; then
                ok "    NodePort=${_np}(任意节点 IP:${_np} 可达)"
                EXT_MONS="${EXT_MONS:+${EXT_MONS},}${FIRST_MASTER}:${_np}"
            else
                warn "    NodePort 读取失败(检查 svc 状态)"
            fi
        else
            _vip="$(_wait_vip "rook-ceph-mon-${m}-external")"
            _vport="$(_svc_port "rook-ceph-mon-${m}-external")"
            if [ -n "${_vip}" ]; then
                ok "    LoadBalancer VIP=${_vip}:${_vport:-6789}"
                EXT_MONS="${EXT_MONS:+${EXT_MONS},}${_vip}:${_vport:-6789}"
            else
                warn "    VIP 120s 未分配(检查 MetalLB: kubectl -n metallb-system get ipaddresspool / l2advertisement)"
            fi
        fi
        _mon_i=$((_mon_i + 1))
    done
    unset _mon_i

    # ①b 网络层: RGW *-external Service(CEPH_RGW_EXPOSE_MODE 独立覆盖, 大小写不敏感)
    RGW_EP=""
    _RGW_MODE="${CEPH_RGW_EXPOSE_MODE:-${MODE}}"
    _RGW_MODE="$(echo "${_RGW_MODE}" | tr '[:upper:]' '[:lower:]')"
    [ "${_RGW_MODE}" = "metallb" ] && _RGW_MODE="loadbalancer"
    if [ "${CEPH_RGW_ENABLED:-false}" = "true" ] && [ "${_RGW_MODE}" != "clusterip" ] && [ "${_RGW_MODE}" != "off" ] && [ "${_RGW_MODE}" != "none" ]; then
        _RGW_TYPE="NodePort"; [ "${_RGW_MODE}" = "loadbalancer" ] && _RGW_TYPE="LoadBalancer"
        # RGW 规律端口: 仅 nodeport 模式使用; metallb/LB 用 Ceph 原生端口 80(不套规律端口)。
        #   nodeport: 显式 CEPH_RGW_NODEPORT 优先; 否则若开了 mon 规律 base, RGW 用 base+mon_count(避开 mon 端口段)
        _RGW_BASE=""
        if [ "${_RGW_MODE}" = "nodeport" ]; then
            if [ -n "${RGW_NP}" ]; then
                _RGW_BASE="${RGW_NP}"
            elif [ -n "${MON_NP_BASE}" ]; then
                _MON_CNT="$(mon_list | wc -w)"
                _RGW_BASE="$(nodeport_alloc "${MON_NP_BASE}" "$((_MON_CNT + 1))" "${MON_NP_MAX}" "${_MON_CNT}")"
            fi
        fi
        say "[网络层] 创建 RGW 外部 Service rook-ceph-rgw-s3-store-external(type=${_RGW_TYPE}, port=${_RGW_BASE:-80(原生)})..."
        if [ "${_RGW_MODE}" = "nodeport" ]; then
            if [ -n "${_RGW_BASE}" ]; then
                _tpl_apply "${ROOK_DIR}/external/02-rgw-external.yaml" "ceph-rgw-ext" \
                    "s|__TYPE__|${_RGW_TYPE}|g" "s|__RGW_PORT__|80|g" "s|__RGW_NODEPORT__|${_RGW_BASE}|g"
            else
                # 自动分配: 删 nodePort 行, port 保持 80
                _tpl_apply "${ROOK_DIR}/external/02-rgw-external.yaml" "ceph-rgw-ext" \
                    "s|__TYPE__|${_RGW_TYPE}|g" "s|__RGW_PORT__|80|g" "/nodePort: __RGW_NODEPORT__/d"
            fi
        else
            # LoadBalancer/MetalLB 模式: 用 Ceph 原生端口 80(外部端点 = VIP:80), 不分配 nodePort
            _tpl_apply "${ROOK_DIR}/external/02-rgw-external.yaml" "ceph-rgw-ext" \
                "s|__TYPE__|${_RGW_TYPE}|g" "s|__RGW_PORT__|80|g" "/nodePort: __RGW_NODEPORT__/d"
        fi
        if [ "${_RGW_MODE}" = "nodeport" ]; then
            _np="$(_svc_np "rook-ceph-rgw-s3-store-external")"
            [ -n "${_np}" ] && { ok "    S3 NodePort=${_np}(http://${FIRST_MASTER}:${_np})"; RGW_EP="${FIRST_MASTER}:${_np}"; } \
                           || warn "    RGW NodePort 读取失败"
        else
            _vip="$(_wait_vip "rook-ceph-rgw-s3-store-external")"
            _vport="$(_svc_port "rook-ceph-rgw-s3-store-external")"
            [ -n "${_vip}" ] && { ok "    S3 LoadBalancer VIP=http://${_vip}:${_vport:-80}"; RGW_EP="${_vip}:${_vport:-80}"; } \
                           || warn "    RGW VIP 120s 未分配(检查 MetalLB)"
        fi
    else
        say "  RGW 不对外暴露(CEPH_RGW_ENABLED=${CEPH_RGW_ENABLED:-false} 或 RGW 模式=${_RGW_MODE})"
    fi
    fi   # end 非 host-network 的 *-external Service 创建

    # ② 资源层: 外部专用 RBD pool + 外部 CephFS(fs + meta/data pools), 与集群内资源隔离
    say "[资源层] 预定义外部连接资源(RBD pool / CephFS fs / application tag)..."
    if _ceph_exec osd pool get "${EXT_RBD_POOL}" size >/dev/null 2>&1; then
        ok "  外部 RBD pool ${EXT_RBD_POOL} 已存在"
    else
        _ceph_exec osd pool create "${EXT_RBD_POOL}" "${EXT_RBD_PG}" replicated \
            && ok "  已创建外部 RBD pool ${EXT_RBD_POOL}(${EXT_RBD_PG} PG)" \
            || warn "  外部 RBD pool 创建失败"
    fi
    _ceph_exec osd pool set "${EXT_RBD_POOL}" size "${CEPH_POOL_REPLICAS:-3}" >/dev/null 2>&1 || true
    _ceph_exec osd pool set "${EXT_RBD_POOL}" min_size "${CEPH_POOL_MIN_SIZE:-2}" >/dev/null 2>&1 || true
    if ! _ceph_exec osd pool application get "${EXT_RBD_POOL}" 2>/dev/null | grep -q "rbd"; then
        _ceph_exec osd pool application enable "${EXT_RBD_POOL}" rbd >/dev/null 2>&1 \
            && ok "  ${EXT_RBD_POOL} application=rbd" || warn "  ${EXT_RBD_POOL} application 设置失败"
    fi
    if [ "${EXT_CEPHFS_ENABLED}" = "true" ]; then
        for _fp in "${EXT_FS_META}:${EXT_FS_META_PG}" "${EXT_FS_DATA}:${EXT_FS_DATA_PG}"; do
            _fp_pool="${_fp%%:*}"; _fp_pg="${_fp##*:}"
            if _ceph_exec osd pool get "${_fp_pool}" size >/dev/null 2>&1; then
                ok "  CephFS pool ${_fp_pool} 已存在"
            else
                _ceph_exec osd pool create "${_fp_pool}" "${_fp_pg}" replicated \
                    && ok "  已创建 CephFS pool ${_fp_pool}(${_fp_pg} PG)" || warn "  CephFS pool ${_fp_pool} 创建失败"
            fi
            _ceph_exec osd pool set "${_fp_pool}" size "${CEPH_POOL_REPLICAS:-3}" >/dev/null 2>&1 || true
            _ceph_exec osd pool set "${_fp_pool}" min_size "${CEPH_POOL_MIN_SIZE:-2}" >/dev/null 2>&1 || true
            _ceph_exec osd pool application enable "${_fp_pool}" cephfs >/dev/null 2>&1 || true
        done
        # ★ 2026-09-09: 必须用 CephFilesystem CR 创建, 不能用 `ceph fs new` CLI ——
        #   CLI 建的 fs 没有 MDS 守护进程(MDS 只由 Rook 依据 CR 部署), fs 永久 offline
        #   → 提供方 HEALTH_ERR, 消费方 CephFS SC 无法 provision。
        #   已存在同名 fs/pool(历史 CLI 建的)时 Rook 自动接管, 幂等。
        say "  apply CephFilesystem CR ${EXT_FS}(Rook 部署 MDS; 已存在同名 fs 则接管)..."
        _FS_CR="$(sed -e "s|__NAMESPACE__|${CEPH_NAMESPACE}|g" \
            -e "s|__FS_NAME__|${EXT_FS}|g" \
            -e "s|__FS_META_POOL__|${EXT_FS_META}|g" \
            -e "s|__FS_DATA_POOL__|${EXT_FS_DATA}|g" \
            -e "s|__REPLICAS__|${CEPH_POOL_REPLICAS:-3}|g" \
            -e "s|__MIN_SIZE__|${CEPH_POOL_MIN_SIZE:-2}|g" \
            "${ROOK_DIR}/external/03-cephfilesystem-external.yaml")" \
            || { warn "  CephFilesystem CR 模板缺失: ${ROOK_DIR}/external/03-cephfilesystem-external.yaml"; unset _fp _fp_pool _fp_pg; return 0; }
        printf '%s' "${_FS_CR}" | ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "${SSH_USER:-ubuntu}@${FIRST_MASTER}" "cat > /tmp/ceph-ext-fs.yaml && ${K} apply -f /tmp/ceph-ext-fs.yaml" \
            && ok "  CephFilesystem CR ${EXT_FS} 已 apply(Rook 部署 MDS)" \
            || warn "  CephFilesystem CR apply 失败"
        # 等 MDS 拉起(fs active; 最长 300s)—— 消费方 CephFS SC 要等 fs 在线
        say "  等待外部 CephFilesystem MDS 就绪(最长 300s)..."
        _FS_ACTIVE=0
        for _fi in $(seq 1 30); do
            if _ceph_exec fs status "${EXT_FS}" 2>/dev/null | grep -q "active"; then
                _FS_ACTIVE=1; break
            fi
            sleep 10
        done
        [ "${_FS_ACTIVE}" = "1" ] && ok "  外部 CephFilesystem ${EXT_FS} MDS active" \
            || warn "  MDS 300s 内未 active(检查 rook operator 日志; 消费方 CephFS SC 将暂不可用)"
        unset _fp _fp_pool _fp_pg _FS_CR _FS_ACTIVE _fi
    else
        say "  外部 CephFS 跳过(CEPHFS_ENABLED=${CEPHFS_ENABLED:-false}; 设 true 可同时预定义外部 CephFS)"
    fi

    # ③ 认证层: 外部专用用户(profile caps, 非 admin)
    say "[认证层] 创建外部专用用户(profile rbd caps)..."
    _RBD_KEY="$( ( _ceph_exec auth get-or-create "client.${EXT_USER}" mon 'profile rbd' osd "profile rbd pool=${EXT_RBD_POOL}" mgr "profile rbd pool=${EXT_RBD_POOL}" 2>/dev/null || true) )"
    if [ -n "${_RBD_KEY}" ] && echo "${_RBD_KEY}" | grep -q "key = "; then
        EXT_RBD_KEY="$(echo "${_RBD_KEY}" | awk '/key = /{print $3; exit}')"
        ok "  用户 ${EXT_USER}(mon/osd/mgr profile rbd, pool=${EXT_RBD_POOL})"
    else
        warn "  用户 ${EXT_USER} 创建失败(检查 ceph auth caps 语法); key 将为空"
        EXT_RBD_KEY=""
    fi
    EXT_CEPHFS_KEY=""
    EXT_CEPHFS_NODE_KEY=""
    if [ "${EXT_CEPHFS_ENABLED}" = "true" ]; then
        # ★ 2026-09-10(Bug A 修复): 外部 CephFS 两角色**分用户** ——
        #   · ${EXT_CEPHFS_USER}(csi-cephfs-provisioner 用): 建删 subvolume, 提供方限定 metadata 读
        #     (osd allow rw pool=meta; 不给 data 池 —— 避免过度授权)
        #   · ${EXT_CEPHFS_NODE_USER}(csi-cephfs-node 用): 挂载 fs 承载全部文件 I/O, 需要
        #     metadata+data 池读写(osd allow rw pool=meta,data)
        #   消费者集群 secret 独立指定(03_ceph_csi.sh): CEPHFS_USER=provisioner / CEPHFS_NODE_USER=node。
        _FS_KEY="$( ( _ceph_exec auth get-or-create "client.${EXT_CEPHFS_USER}" mon 'allow r' mds "allow rw fsname=${EXT_FS}" osd "allow rw pool=${EXT_FS_META}" 2>/dev/null || true) )"
        if [ -n "${_FS_KEY}" ] && echo "${_FS_KEY}" | grep -q "key = "; then
            EXT_CEPHFS_KEY="$(echo "${_FS_KEY}" | awk '/key = /{print $3; exit}')"
            ok "  用户 ${EXT_CEPHFS_USER}(provisioner: mon allow r / mds allow rw / osd allow rw pool=${EXT_FS_META})"
        else
            warn "  用户 ${EXT_CEPHFS_USER} 创建失败; key 将为空"
        fi
        _FS_NODE_KEY="$( ( _ceph_exec auth get-or-create "client.${EXT_CEPHFS_NODE_USER}" mon 'allow r' mds "allow rw fsname=${EXT_FS}" osd "allow rw pool=${EXT_FS_META}, allow rw pool=${EXT_FS_DATA}" 2>/dev/null || true) )"
        if [ -n "${_FS_NODE_KEY}" ] && echo "${_FS_NODE_KEY}" | grep -q "key = "; then
            EXT_CEPHFS_NODE_KEY="$(echo "${_FS_NODE_KEY}" | awk '/key = /{print $3; exit}')"
            ok "  用户 ${EXT_CEPHFS_NODE_USER}(node: mon allow r / mds allow rw / osd allow rw pool=${EXT_FS_META},data)"
        else
            warn "  用户 ${EXT_CEPHFS_NODE_USER} 创建失败; key 将为空"
        fi
    fi

    # ④ 导出外部接入信息(FSID / MONs / RBD + CephFS 全部连接信息)
    FSID="$( (SSH "${K} -n ${CEPH_NAMESPACE} get secret rook-ceph-mon -o jsonpath='{.data.fsid}' 2>/dev/null" || true) | base64 -d 2>/dev/null )"
    say "[导出] 写入 ${EXPORT_CONF} ..."
    mkdir -p "$(dirname "${EXPORT_CONF}")"
    cat > "${EXPORT_CONF}" << EOF
# CubeStack Ceph 外部接入配置(由 ceph-expose-external.sh 生成, $(date +%Y-%m-%d_%H%M%S))
# 用途: 拷贝到目标 K8s 集群的 cluster.conf, 设 CEPH_MODE=external 后由其 ceph-csi-operator 接入。
# 本机 5 层自检(含外部客户端协议级测试): bash deployments/scripts/tools/k8s/ceph-expose-external.sh status
CEPH_MODE="external"
CEPH_MONITORS="${EXT_MONS}"
CEPH_FSID="${FSID}"
# --- RBD(ceph-csi RBD provisioner 使用) ---
CEPH_POOL="${EXT_RBD_POOL}"
CEPH_USER="${EXT_USER}"
CEPH_KEYRING="${EXT_RBD_KEY}"
# --- CephFS(ceph-csi CephFS provisioner/node 分用户使用, 2026-09-10) ---
CEPHFS_FS="${EXT_FS}"
CEPHFS_META_POOL="${EXT_FS_META}"
CEPHFS_DATA_POOL="${EXT_FS_DATA}"
# CephFS provisioner 角色(建删 subvolume; 提供方 caps 只给 meta 池 rw)
CEPHFS_USER="${EXT_CEPHFS_USER}"
CEPHFS_KEYRING="${EXT_CEPHFS_KEY}"
# CephFS node 角色(挂载 fs 承载文件 I/O; 提供方给 meta+data 池 rw) —— 不设则消费者回退 CEPHFS_USER(旧行为)
CEPHFS_NODE_USER="${EXT_CEPHFS_NODE_USER}"
CEPHFS_NODE_KEYRING="${EXT_CEPHFS_NODE_KEY}"
# --- RGW(S3, 供外部应用如 Model 仓库; csi-operator 不需要) ---
CEPH_RGW_EXTERNAL_ENDPOINT="${RGW_EP}"
EOF
    chmod 600 "${EXPORT_CONF}" 2>/dev/null || true
    ok "外部接入配置已导出 → ${EXPORT_CONF}(含 RBD/CephFS 全部连接信息)"
    echo "  (拷贝到目标集群 cluster.conf 即可; 详细自检见 status)"

    # ★ ⑤ 导出官方 external-ceph.env(2026-09-10, 供消费方 CEPH_EXTERNAL_ENV_FILE 官方导入路径)
    _export_official_env || warn "  官方 external-ceph.env 导出失败(自研 conf 已导出, 不影响手填路径消费方)"
}

# ════════════════════════════ show ════════════════════════════
show_main() {
    say "==== Ceph 对外暴露当前状态 ===="
    while read -r _svc; do
        [ -z "${_svc}" ] && continue
        _T="$(_svc_type "${_svc}")"; _VIP="$(_svc_vip "${_svc}")"; _NP="$(_svc_np "${_svc}")"
        echo "  ${_svc}: type=${_T:-?} VIP=${_VIP:-<无>} NodePort=${_NP:-<无>}"
    done < <(SSH "${K} -n ${CEPH_NAMESPACE} get svc -l app=rook-ceph-mon-external -o jsonpath='{.items[*].metadata.name}' 2>/dev/null" | tr ' ' '\n')
    while read -r _svc; do
        [ -z "${_svc}" ] && continue
        _T="$(_svc_type "${_svc}")"; _VIP="$(_svc_vip "${_svc}")"; _NP="$(_svc_np "${_svc}")"
        echo "  ${_svc}: type=${_T:-?} VIP=${_VIP:-<无>} NodePort=${_NP:-<无>}"
    done < <(SSH "${K} -n ${CEPH_NAMESPACE} get svc -l app=rook-ceph-rgw-external -o jsonpath='{.items[*].metadata.name}' 2>/dev/null" | tr ' ' '\n')
    [ -f "${EXPORT_CONF}" ] && { echo "  导出配置: ${EXPORT_CONF}"; echo "  $(grep CEPH_MONITORS "${EXPORT_CONF}")"; }
}

# ════════════════════════════ status(5 层) ════════════════════════════
# [5/5] 外部客户端协议级测试: 模拟 ceph-csi-operator 从集群外连接
#   · 客户端 = 部署机/容器本地 ceph/rbd(Dockerfile-cli 已预装 ceph-common),
#     连接外部端点(NodePort=master:端口 / LB=VIP:6789)→ 与 csi-operator 完全相同路径
#   · 验证: mon msgr 握手 + cephx 认证(外部用户 keyring)+ RBD API 访问(ls + create/rm 探测)
#   · 本地无 ceph 二进制时回退: toolbox 内经外部端点(连接路径经 kube-proxy DNAT, 一致)
status_ext_test() {
    local eps key keyfile
    eps="$(ext_mon_eps)"
    if [ -z "${eps}" ]; then
        warn "  [5/5] 无外部 mon 端点(未 apply 或未暴露); 跳过协议级测试"
        return 0
    fi
    say "[5/5] 外部客户端协议级测试(模拟 ceph-csi-operator 从集群外连接 ${eps})..."
    # 取外部用户 key: 优先导出配置, 否则实时 get-key
    key="$(grep '^CEPH_KEYRING=' "${EXPORT_CONF}" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)"
    [ -z "${key}" ] && key="$( ( _ceph_exec auth get-key "client.${EXT_USER}" 2>/dev/null || true) )"
    if [ -z "${key}" ]; then
        warn "   外部用户 ${EXT_USER} 的 key 获取失败(先 apply, 或检查 ceph auth get-key)"
        return 0
    fi
    keyfile="$(mktemp)"
    printf '[client.%s]\n\tkey = %s\n' "${EXT_USER}" "${key}" > "${keyfile}"
    chmod 600 "${keyfile}"

    if command -v ceph >/dev/null 2>&1 && command -v rbd >/dev/null 2>&1; then
        say "   客户端: 本地 ceph/rbd(Dockerfile-cli 预装 ceph-common, 部署机=集群外)✓"
        # ① mon 握手 + cephx 认证: ceph -s
        if timeout 30 ceph -m "${eps}" -n "client.${EXT_USER}" --keyring "${keyfile}" -s > /tmp/ceph-ext-status.out 2>&1; then
            grep -qE 'HEALTH_(OK|WARN|ERR)' /tmp/ceph-ext-status.out \
                && ok "   ceph -s ✓ (mon msgr 握手 + cephx 认证成功; 外部可读集群状态)" \
                || warn "   ceph -s 输出无健康状态(见 /tmp/ceph-ext-status.out)"
        else
            warn "   ceph -s 失败(mon 握手/认证失败? 见 /tmp/ceph-ext-status.out)"
            rm -f "${keyfile}"; return 0
        fi
        # ② RBD API 访问(读): rbd ls
        if timeout 30 rbd -m "${eps}" -n "client.${EXT_USER}" --keyring "${keyfile}" -p "${EXT_RBD_POOL}" ls > /tmp/ceph-ext-rbd.out 2>&1; then
            ok "   rbd -p ${EXT_RBD_POOL} ls ✓ (外部用户 RBD API 读访问)"
        else
            warn "   rbd ls 失败(见 /tmp/ceph-ext-rbd.out)"
        fi
        # ③ RBD 写路径探测(csi provisioner 同款): create 1MiB 测试卷 → rm
        if timeout 30 rbd -m "${eps}" -n "client.${EXT_USER}" --keyring "${keyfile}" -p "${EXT_RBD_POOL}" create "cubestack-ext-probe-$$" --size 1 \
            && timeout 30 rbd -m "${eps}" -n "client.${EXT_USER}" --keyring "${keyfile}" -p "${EXT_RBD_POOL}" rm "cubestack-ext-probe-$$"; then
            ok "   rbd create/rm 写路径 ✓ (外部用户在 ${EXT_RBD_POOL} 可建删卷, csi provisioner 同款)"
        else
            warn "   rbd 写路径探测失败(见 /tmp/ceph-ext-rbd.out; 检查 osd caps)"
        fi
    else
        # 回退: toolbox 内经外部端点(base64 传递 keyring, 避免引号嵌套)
        say "   客户端: toolbox 经外部端点(本地无 ceph 二进制 —— 建议重建 Dockerfile-cli 预装 ceph-common)"
        _KF_B64="$(base64 -w0 "${keyfile}")"
        SSH "${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph-tools -- bash -c 'echo ${_KF_B64} | base64 -d > /tmp/ext.keyring'"
        if SSH "${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph-tools -- timeout 30 ceph -m ${eps} -n client.${EXT_USER} --keyring /tmp/ext.keyring -s" > /tmp/ceph-ext-status.out 2>&1; then
            grep -qE 'HEALTH_(OK|WARN|ERR)' /tmp/ceph-ext-status.out \
                && ok "   toolbox 经外部端点 ceph -s ✓ (mon 握手 + cephx 认证; 路径经 kube-proxy DNAT 同外部)" \
                || warn "   ceph -s 输出无健康状态(见 /tmp/ceph-ext-status.out)"
        else
            warn "   toolbox 经外部端点 ceph -s 失败(见 /tmp/ceph-ext-status.out)"
        fi
        SSH "${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph-tools -- rm -f /tmp/ext.keyring" >/dev/null 2>&1 || true
    fi
    rm -f "${keyfile}"
}

status_main() {
    say "==== Ceph 外部接入自检(5 层) ===="
    # [1/5] 网络层: mon 端点从外部(部署机)可达?
    say "[1/5] mon 网络可达性(集群外 TCP)..."
    for m in $(mon_list); do
        _svc="rook-ceph-mon-${m}-external"
        _T="$(_svc_type "${_svc}")"
        if [ "${_T}" = "NodePort" ]; then
            _NP="$(_svc_np "${_svc}")"
            timeout 3 bash -c "echo > /dev/tcp/${FIRST_MASTER}/${_NP}" 2>/dev/null \
                && ok "  ${_svc}: ${FIRST_MASTER}:${_NP} 可达" || warn "  ${_svc}: NodePort ${_NP:-?} 不可达(防火墙/网络)"
        elif [ "${_T}" = "LoadBalancer" ]; then
            _VIP="$(_svc_vip "${_svc}")"
            _VPORT="$(_svc_port "${_svc}")"
            timeout 3 bash -c "echo > /dev/tcp/${_VIP}/${_VPORT:-6789}" 2>/dev/null \
                && ok "  ${_svc}: ${_VIP}:${_VPORT:-6789} 可达" || warn "  ${_svc}: VIP ${_VIP:-?}:${_VPORT:-6789} 不可达"
        else
            warn "  ${_svc}: type=${_T:-<无>}(未对外暴露, 外部集群无法连接)"
        fi
    done
    # [2/5] 认证层: 外部用户存在 + profile caps
    say "[2/5] 认证用户..."
    _AUTH="$( ( _ceph_exec auth get "client.${EXT_USER}" 2>/dev/null || true) )"
    if echo "${_AUTH}" | grep -q "profile rbd"; then
        ok "  ${EXT_USER}: profile rbd caps ✓"
    elif echo "${_AUTH}" | grep -q "client.${EXT_USER}"; then
        warn "  ${EXT_USER} 存在但非 profile rbd caps(检查; 建议 profile rbd pool=${EXT_RBD_POOL})"
    else
        warn "  用户 ${EXT_USER} 不存在(先 apply)"
    fi
    if [ "${EXT_CEPHFS_ENABLED}" = "true" ]; then
        # provisioner 角色用户
        _AUTH2="$( ( _ceph_exec auth get "client.${EXT_CEPHFS_USER}" 2>/dev/null || true) )"
        if echo "${_AUTH2}" | grep -q "fsname=${EXT_FS}"; then
            ok "  ${EXT_CEPHFS_USER}(provisioner): fsname=${EXT_FS} caps ✓"
        else
            warn "  用户 ${EXT_CEPHFS_USER} 缺失/非 fsname caps(检查)"
        fi
        # node 角色用户(2026-09-10 Bug A: 两角色分用户)
        _AUTH3="$( ( _ceph_exec auth get "client.${EXT_CEPHFS_NODE_USER}" 2>/dev/null || true) )"
        if echo "${_AUTH3}" | grep -q "fsname=${EXT_FS}"; then
            ok "  ${EXT_CEPHFS_NODE_USER}(node): fsname=${EXT_FS} caps ✓"
        else
            warn "  用户 ${EXT_CEPHFS_NODE_USER}(node) 缺失/非 fsname caps(检查; 消费者 CEPHFS_NODE_USER 需要)"
        fi
    fi
    # [3/5] 资源层: 外部 pool + fs + application tag
    say "[3/5] 外部资源(RBD pool / CephFS fs / app tag)..."
    if _ceph_exec osd pool application get "${EXT_RBD_POOL}" 2>/dev/null | grep -q "rbd"; then
        ok "  pool ${EXT_RBD_POOL} application=rbd ✓"
    else
        warn "  pool ${EXT_RBD_POOL} 缺失或未打 rbd tag(apply 时自动补)"
    fi
    if [ "${EXT_CEPHFS_ENABLED}" = "true" ]; then
        if _ceph_exec fs get "${EXT_FS}" >/dev/null 2>&1; then
            ok "  CephFilesystem ${EXT_FS} 存在 ✓"
        else
            warn "  CephFilesystem ${EXT_FS} 不存在(apply 时自动创建)"
        fi
    fi
    # [4/5] fsid + CephFS 集群状态
    say "[4/5] fsid + CephFS..."
    FSID="$( (SSH "${K} -n ${CEPH_NAMESPACE} get secret rook-ceph-mon -o jsonpath='{.data.fsid}' 2>/dev/null" || true) | base64 -d 2>/dev/null )"
    [ -n "${FSID}" ] && ok "  fsid=${FSID}(外部 CEPH_MODE=external 需一致)" || warn "  fsid 获取失败"
    if _ceph_exec fs status 2>/dev/null | grep -q "active"; then
        ok "  CephFS active ✓"
    fi
    # [5/5] 外部客户端协议级测试
    status_ext_test
    echo "---------------------------------------------"
    say "自检完成; 外部接入配置见 ${EXPORT_CONF}(若已 apply)"
}

# ════════════════════════════ 入口 ════════════════════════════
case "${ACTION}" in
    apply) apply_main ;;
    show)  show_main ;;
    status) status_main ;;
    *)
        err "用法: ceph-expose-external.sh {apply [--mode nodeport|loadbalancer|metallb|clusterip] | show | status}"
        exit 1
        ;;
esac
