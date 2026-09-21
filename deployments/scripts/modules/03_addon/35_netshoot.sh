#!/bin/bash
# ============================================================
# MODULE: netshoot
# DESC: 部署集群内网络/RDMA 诊断 pod(netshoot + rdma-core + perftest; 离线, 命名空间默认 default)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# TOGGLE: NETSHOOT_ENABLED
# REQUIRES: k8s_deploy k8s_registry
# 说明:
#   · 定位: 集群里**常驻一台"网络工具箱"** —— kubectl exec 进去就能用 tcpdump / ip / ss / ethtool /
#     mtr / ping / nslookup 排障; 镜像里额外装了 rdma-core(ibv_devices/ibv_devinfo)与
#     perftest(ib_write_bw/ib_read_bw...), 用于 RDMA(IB/RoCE)链路诊断与带宽/时延实测。
#   · 镜像(离线): 自建镜像 tar 由**联网机** tools/images/netshoot-rdma-build.sh 生成
#     (netshoot-rdma.Dockerfile: netshoot + rdma-core + 源码编译 perftest —— Alpine 无 perftest 包);
#     放到 ${NETSHOOT_SAVE_DIR}(默认 deployments/offline-files/netshoot/)→ 本模块推入集群内置 registry。
#     ⚠ 自建 tar 缺失时**回退**用离线包里的原始 netshoot(netshoot.tar): pod 照样能起, 但
#       **没有 ibv_*/perftest**(会有醒目告警) —— 总比"诊断工具起不来"强。
#   · ★ RDMA 资源**自动降级**: 只有集群节点真的注册了 ${NETSHOOT_RDMA_RESOURCE}(默认
#     rdma/hca_shared_devices, 与 10_rdma 的 by-link IB 池一致)才申请该扩展资源;
#     没注册(未部署 RDMA 插件 / 占位模式 / 无卡)就不申请 —— 同一个诊断 pod 在有卡/无卡集群都能起。
#     ⚠ 不降级的后果: 无卡集群里 pod 永远 Pending, "诊断工具"自己先挂了。
#   · 容器启动即打印**设备视图**((/dev/infiniband 授予的 uverbsN) × (sysfs 里全部 mlx5_X → netdev)),
#     并列出工具在位清单: `kubectl logs <pod>` 一眼看完。脚本落在 ConfigMap, 可随时重跑:
#     `kubectl exec <pod> -- sh /diag/diag.sh`。
#   · 命名空间默认 **default**(NETSHOOT_NAMESPACE 可改); pod 名默认 cubestack-netshoot(固定名, 便于 exec)。
#   · 边界(如实标注): 本 pod 提供的是**诊断能力**(设备可见性 + 工具在手 + 可跑 verbs/带宽);
#     它**不证明** RDMA 数据面可用 —— 那需要两端各起一个 ib_write_bw/perftest 实测。
#   · 相关: 模块 10_rdma_shared_dev_plugin(设备插件)/ 30_verify_rdma_shared_dev_plugin(自动验证);
#     详见 docs/netshoot.md
# 数据源: cluster.conf (NETSHOOT_ENABLED / NETSHOOT_NAMESPACE / NETSHOOT_POD_NAME / NETSHOOT_SAVE_DIR /
#         NETSHOOT_RDMA_VERSION / NETSHOOT_RDMA_RESOURCE / NETSHOOT_BASE_TAR / RDMA_IB_RESOURCE /
#         REGISTRY_* / NODES / SSH_KEY_NAME)
# 用法:   sudo ./deploy-cluster.sh --steps netshoot  或  NETSHOOT_ENABLED=true
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# ---- 开关 ----
[ "${NETSHOOT_ENABLED:-false}" = "true" ] || { say "NETSHOOT_ENABLED=false, 跳过网络诊断 pod"; exit 0; }

init_remote_kubectl || exit 1

# ---------------- 派生变量(全部来自 cluster.conf / load_config, 无硬编码) ----------------
NS="${NETSHOOT_NAMESPACE:-default}"
POD="${NETSHOOT_POD_NAME:-cubestack-netshoot}"
CM_NAME="${NETSHOOT_POD_NAME:-cubestack-netshoot}-diag"
SAVE_DIR="${NETSHOOT_SAVE_DIR:-${REPO_ROOT}/deployments/offline-files/netshoot}"
TAG="${NETSHOOT_RDMA_VERSION:-26.04.17}"          # 自建镜像 tag(= perftest 版本, 见构建脚本)
BASE_TAR="${NETSHOOT_BASE_TAR:-${REPO_ROOT}/deployments/offline-files/os/netshoot.tar}"   # 回退用的原始 netshoot
RDMA_RES="${NETSHOOT_RDMA_RESOURCE:-${RDMA_IB_RESOURCE:-rdma/hca_shared_devices}}"        # 与 10_rdma by-link 的 IB 池一致
# push 用直连端点(与 10_rdma/gpu_operator 一致): nodeport→master:REGISTRY_NODEPORT / metallb→VIP:5000
REG_DIRECT="${REGISTRY_DIRECT:-${REGISTRY_IP:-$(first_master_ip)}:${REGISTRY_PORT:-5000}}"
REG_BASE="${REGISTRY_DOMAIN:-${REGISTRY_IP}}:${REGISTRY_PORT:-5000}"   # 节点按域名拉取
PUSH_REPO="${REG_DIRECT}/netshoot"

# ---- [1/4] 选镜像 tar(自建优先, 原始 netshoot 回退) ----
say "[1/4] 选择诊断镜像 tar(自建优先; 目录 ${SAVE_DIR})..."
USING_RDMA_IMG=1
TAR_FILE="$(find_offline_tar "/netshoot-rdma:${TAG}" "netshoot-rdma-*.tar" "${SAVE_DIR}" 2>/dev/null || true)"
if [ -z "${TAR_FILE}" ]; then
    # tag 不匹配(如换过 perftest 版本)时, 只要目录里有任意自建 tar 就用最新的那个
    _latest="$(ls -t "${SAVE_DIR}"/netshoot-rdma-*.tar 2>/dev/null | head -1 || true)"
    if [ -n "${_latest}" ]; then
        TAR_FILE="${_latest}"
        case "$(basename "${TAR_FILE}")" in
            *"${TAG}"*) : ;;   # 文件名就是目标版本(只是 tar 内容标签与查找后缀不同) → 不吵
            *) warn "  未找到 netshoot-rdma-${TAG}.tar, 使用目录内最新: $(basename "${TAR_FILE}")" ;;
        esac
    fi
fi
IMG_NAME="netshoot-rdma"
if [ -z "${TAR_FILE}" ]; then
    USING_RDMA_IMG=0
    IMG_NAME="netshoot"
    [ -f "${BASE_TAR}" ] || { err "自建镜像 tar 与回退 tar 都没有:"; \
        err "  ① 自建(推荐, 含 ibv_*/perftest): 联网机跑 tools/images/netshoot-rdma-build.sh → tar 放到 ${SAVE_DIR}/"; \
        err "  ② 或放原始 netshoot 到 ${BASE_TAR}(无 ibv_*/perftest)"; exit 1; }
    TAR_FILE="${BASE_TAR}"
    TAG="$(tar_first_image_tag "${TAR_FILE}")"; TAG="${TAG##*:}"
    [ -n "${TAG}" ] || TAG="latest"
    warn "  未找到自建镜像 tar(netshoot-rdma-*.tar in ${SAVE_DIR})→ 回退原始 netshoot(${TAR_FILE##*/})"
    warn "  ⚠ 回退版**没有 ibv_*/perftest**; 要 RDMA 诊断: 联网机跑 tools/images/netshoot-rdma-build.sh 后重跑本模块"
else
    ok "  自建镜像 tar: ${TAR_FILE}"
fi
IMG_TAG="${TAG}"
IMG_REF="${REG_BASE}/netshoot/${IMG_NAME}:${IMG_TAG}"

# ---- [2/4] 推送镜像到集群内置 registry ----
say "[2/4] 推送 ${IMG_NAME}:${IMG_TAG} → ${PUSH_REPO}(离线关键: 节点只从内置 registry 拉)..."
skopeo_require netshoot
wait_registry_ready "http://${REG_DIRECT}/v2/" 30 \
    || { err "集群内置 registry ${REG_DIRECT}/v2/ 不可达(检查 SERVICE_EXPOSE_MODE / registry pod / REGISTRY_DIRECT)"; exit 1; }
if reg_has_tag "${PUSH_REPO}" "${IMG_NAME}" "${IMG_TAG}"; then
    say "  registry 已有 ${IMG_NAME}:${IMG_TAG}, 跳过推送"
else
    _SRC_REF="$(tar_first_image_tag "${TAR_FILE}")"
    # tar 形态两种都吃: docker save 产物(docker-archive) / 部分备料 tar 是 oci 布局(oci-archive:...:ref)
    if push_image_skopeo "docker-archive:${TAR_FILE}" "docker://${PUSH_REPO}/${IMG_NAME}:${IMG_TAG}"; then
        ok "  已推送(docker-archive): ${PUSH_REPO}/${IMG_NAME}:${IMG_TAG}"
    elif [ -n "${_SRC_REF}" ] && push_image_skopeo "oci-archive:${TAR_FILE}:${_SRC_REF}" "docker://${PUSH_REPO}/${IMG_NAME}:${IMG_TAG}"; then
        ok "  已推送(oci-archive): ${PUSH_REPO}/${IMG_NAME}:${IMG_TAG}"
    else
        err "镜像推送失败(重试后仍失败; 检查宿主机能否达 ${REG_DIRECT} 与 tar 完整性: ${TAR_FILE})"; exit 1
    fi
fi

# ---- [3/4] RDMA 资源检测(自动降级)+ 生成 manifest ----
say "[3/4] 检测节点是否注册扩展资源 ${RDMA_RES}(决定是否给 pod 申请)..."
_NODES_JSON="$( (SSH "${K} get nodes -o json" 2>/dev/null || true) )"
_RDMA_HITS="$(printf '%s' "${_NODES_JSON}" | python3 -c '
import json, sys
res = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for n in d.get("items", []):
    v = (n.get("status") or {}).get("allocatable", {}).get(res)
    if v:
        print("%s=%s" % (n["metadata"]["name"], v))
' "${RDMA_RES}" 2>/dev/null || true)"
RDMA_MODE=1
if [ -n "${_RDMA_HITS}" ]; then
    ok "  已注册: $(echo "${_RDMA_HITS}" | tr '\n' ' ')"
else
    RDMA_MODE=0
    warn "  未注册 → 本次**不申请** RDMA 资源(pod 照常起, 用于通用网络诊断)"
    warn "  原因通常是: 未部署 RDMA 设备插件(10_rdma)/ 占位模式无卡 / 资源名不匹配(当前查的是 ${RDMA_RES})"
fi

# 诊断脚本(ConfigMap 挂进 pod: 启动打印一次, 之后可随时 `sh /diag/diag.sh` 重跑)
_DIAG_TMP="$(mktemp)"
cat > "${_DIAG_TMP}" <<'DIAG'
#!/bin/sh
# CubeStack 诊断 pod 自检: 设备视图 + 工具清单(不依赖任何外部工具, 只读 /dev 与 /sys)
echo "==================== CubeStack netshoot 诊断 ===================="
echo "[RDMA 设备 /dev/infiniband(设备插件实际授予本容器的)]"
if ls /dev/infiniband/ >/dev/null 2>&1 && [ -n "$(ls -A /dev/infiniband/ 2>/dev/null)" ]; then
    ls -l /dev/infiniband/
else
    echo "  (空) 本容器未挂载 RDMA 设备 —— 集群未注册 RDMA 资源, 或本 pod 未申请"
fi
echo
echo "[RDMA HCA 总览 /sys/class/infiniband(宿主 sysfs, 只读; 含未被授予的卡)]"
echo "  ★ = 本容器**实际拿到**的设备(对应上面 /dev/infiniband 里的 uverbsN)"
if [ -d /sys/class/infiniband ] && [ -n "$(ls -A /sys/class/infiniband 2>/dev/null)" ]; then
    for d in /sys/class/infiniband/*; do
        [ -e "$d" ] || continue
        dev="$(basename "$d")"
        # 链路类型(InfiniBand / Ethernet=RoCE)、速率、端口状态: 这三个在容器里**可读**, 且比网卡名更有用
        layer="$(cat "$d"/ports/*/link_layer 2>/dev/null | sort -u | tr '\n' '/' | sed 's:/$::')"
        rate="$(cat "$d"/ports/*/rate 2>/dev/null | head -1)"
        state="$(cat "$d"/ports/*/state 2>/dev/null | tr -d ' ' | tr '\n' '/' | sed 's:/$::')"
        verbs="$(ls "$d"/device/infiniband_verbs 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
        mark=" "
        _uv="$(ls "$d"/device/infiniband_verbs 2>/dev/null | head -1)"
        [ -n "$_uv" ] && [ -e "/dev/infiniband/${_uv}" ] && mark="★"
        echo "  ${mark} ${dev}  [${layer:-未知}]  ${rate:-速率未知}  ${state:-状态未知}  verbs=[${verbs:-无}]"
    done
    echo "  ⚠ 网卡名(如 ibs2/manage0)在 pod 内**看不到**: 容器有自己的 net namespace, /sys/class/net 只有 pod 自己的网卡。"
    echo "    设备状态/速率看上面即可(容器内可读); 要网卡名请到节点上跑: rdma link show | ip -br addr; 或看设备插件 ConfigMap:"
    echo "    kubectl -n kube-system get cm rdma-devices -o go-template='{{index .data \"config.json\"}}'"
else
    echo "  (无) 本节点没有 RDMA HCA(或容器内看不到 sysfs)"
fi
echo
echo "[RDMA 链路 rdma link show(容器 netns 视角)]"
if command -v rdma >/dev/null 2>&1; then
    rdma link show 2>&1 | sed 's/^/  /' | head -10
    echo "  ⚠ 列出的是本 netns 的**全部** HCA(含未授予本容器的): 真正能用的只有上面 ★ 标记的设备。"
    echo "    网卡名字段(netdev)属宿主 netns, 此处为空 —— 要网卡名到节点上跑 rdma link show。"
else
    echo "  (缺 rdma 命令: 当前镜像未含 iproute2-rdma —— 用 ibv_devinfo 看设备; 节点上有 rdma link show)"
fi
echo
echo "[网络接口]"
ip -br link show 2>/dev/null | sed 's/^/  /' | head -12 || echo "  (ip 不可用)"
echo
echo "[工具在位清单]"
for t in tcpdump ip ss ethtool mtr ping nslookup curl nc socat iperf3 rdma ibv_devices ibv_devinfo ib_write_bw ib_read_bw ib_write_lat; do
    if command -v "$t" >/dev/null 2>&1; then printf "  ok  %s\n" "$t"; else printf "  --  %s (缺)\n" "$t"; fi
done
echo
echo "[verbs 视角 ibv_devinfo -l]"
if command -v ibv_devinfo >/dev/null 2>&1; then
    ibv_devinfo -l 2>&1 | sed 's/^/  /' | head -12
    echo "  提示: 无设备时说明本容器没拿到 RDMA 设备(未申请/集群无卡), 不是工具坏了"
else
    echo "  (缺 ibv_devinfo: 当前镜像是回退版 netshoot, 不含 rdma-core; 见模块说明)"
fi
echo
echo "[常用命令]"
echo "  tcpdump -i any -nn                 # 抓包"
echo "  ip addr / ip route / ss -tunap     # 地址/路由/连接"
echo "  ethtool -S eth0 / ethtool eth0     # 网卡统计/速率"
echo "  mtr -rw <host> / ping <host>       # 链路质量"
echo "  ibv_devinfo / ibv_devices          # RDMA 卡与端口(verbs)"
echo "  rdma link show / rdma dev          # RDMA 链路状态(state/physical_state)"
echo "  ib_write_bw -d mlx5_0 -a           # 带宽实测(需对端服务端起 ib_write_bw)"
echo "================================================================="
# 容器启动时带 --keep-running: 打印完视图后常驻(诊断 pod 要能 exec 进去);
# 手动 `kubectl exec <pod> -- sh /diag/diag.sh`(不带参数)则只打印, 正常退出。
if [ "${1:-}" = "--keep-running" ]; then
    echo "(诊断 pod 常驻中 —— kubectl exec -it <pod> -- bash 进去排障; 重跑本视图: sh /diag/diag.sh)"
    exec sleep infinity
fi
DIAG

# pod 入口提示(挂到 /root/motd, 覆盖基础镜像的欢迎语): exec 进去 ls/cat motd 就能看到 RDMA 用法
_MOTD_TMP="$(mktemp)"
cat > "${_MOTD_TMP}" <<'MOTD'

  CubeStack 诊断 pod(网络 + RDMA)        完整视图: sh /diag/diag.sh
  ──────────────────────────────────────────────────────────────────────
  RDMA(本容器已申请扩展资源, 设备已注入 /dev/infiniband, 可直接用):
    rdma link show            # RDMA 链路状态(state / physical_state)
    ibv_devinfo               # 设备/端口详情(verbs 层)
    ib_write_bw -d mlx5_0     # 带宽实测(对端同样跑 ib_write_bw -d mlx5_0 当服务端)
  网络:
    tcpdump -i any -nn | ip addr | ss -tunap | mtr <host> | ethtool -S eth0
  ⚠ 网卡名(ibs2/manage0)属宿主 net namespace, pod 内看不到; 设备本身可用(如上)。
MOTD
_CM_TMP="$(mktemp)"
{
    echo "apiVersion: v1"
    echo "kind: ConfigMap"
    echo "metadata:"
    echo "  name: ${CM_NAME}"
    echo "  namespace: ${NS}"
    echo "data:"
    echo "  diag.sh: |"
    sed 's/^/    /' "${_DIAG_TMP}"
    echo "  motd: |"
    sed 's/^/    /' "${_MOTD_TMP}"
} > "${_CM_TMP}"
rm -f "${_DIAG_TMP}" "${_MOTD_TMP}"

_POD_TMP="$(mktemp)"
{
    echo "apiVersion: v1"
    echo "kind: Pod"
    echo "metadata:"
    echo "  name: ${POD}"
    echo "  namespace: ${NS}"
    echo "  labels:"
    echo "    app: ${POD}"
    echo "    app.kubernetes.io/part-of: cubestack-diagnostics"
    echo "spec:"
    echo "  restartPolicy: Always"
    echo "  containers:"
    echo "    - name: netshoot"
    echo "      image: ${IMG_REF}"
    echo "      imagePullPolicy: IfNotPresent"
    echo "      command: [\"/bin/sh\", \"/diag/diag.sh\", \"--keep-running\"]"
    echo "      volumeMounts:"
    echo "        - name: diag"
    echo "          mountPath: /diag"
    echo "        - name: diag"
    echo "          mountPath: /root/motd"
    echo "          subPath: motd"
    if [ "${RDMA_MODE}" = "1" ]; then
        echo "      resources:"
        echo "        limits:"
        echo "          ${RDMA_RES}: 1"
    fi
    echo "  volumes:"
    echo "    - name: diag"
    echo "      configMap:"
    echo "        name: ${CM_NAME}"
    echo "        defaultMode: 0755"
} > "${_POD_TMP}"

say "  下发命名空间/ConfigMap/Pod(NS=${NS}, POD=${POD})..."
SSH "${K} get namespace ${NS} >/dev/null 2>&1" \
    || SSH "${K} create namespace ${NS}" >/dev/null 2>&1 \
    || { err "命名空间 ${NS} 不存在且创建失败"; exit 1; }
SSH "${K} apply -f -" < "${_CM_TMP}" >/dev/null || { err "ConfigMap ${CM_NAME} 下发失败"; rm -f "${_CM_TMP}" "${_POD_TMP}"; exit 1; }
# Pod 用 replace 语义: 镜像/资源变了要真正生效(apply 对 Pod 的不可变字段会报错)
SSH "${K} delete pod ${POD} --ignore-not-found=true --wait=true >/dev/null 2>&1" || true
SSH "${K} apply -f -" < "${_POD_TMP}" >/dev/null || { err "Pod ${POD} 下发失败"; rm -f "${_CM_TMP}" "${_POD_TMP}"; exit 1; }
rm -f "${_CM_TMP}" "${_POD_TMP}"

# ---- [4/4] 等待 Ready + 打印用法 ----
say "[4/4] 等待 Pod Ready(最长 120s)..."
READY=0; PHASE=""
for _i in $(seq 1 24); do
    PHASE="$( (SSH "${K} -n ${NS} get pod ${POD} -o jsonpath='{.status.phase}' 2>/dev/null" || true) )"
    _rd="$( (SSH "${K} -n ${NS} get pod ${POD} -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null" || true) )"
    [ "${_rd}" = "true" ] && { READY=1; break; }
    [ "${PHASE}" = "Failed" ] && break
    sleep 5
done
if [ "${READY}" = "1" ]; then
    ok "  Pod 已 Ready"
else
    warn "  Pod 未在 120s 内 Ready(当前 phase=${PHASE:-未知})"
    warn "  排查: kubectl -n ${NS} describe pod ${POD}; kubectl -n ${NS} get events --sort-by=.lastTimestamp | tail"
    [ "${RDMA_MODE}" = "1" ] && warn "  若事件里是 Insufficient ${RDMA_RES}: 该资源只在部分节点上, 试试换节点或确认设备插件已就绪"
fi

echo "---------------------------------------------"
ok "网络诊断 pod 部署完成(命名空间 ${NS})"
echo "  名字:        ${POD}"
echo "  镜像:        ${IMG_REF}$([ "${USING_RDMA_IMG}" = "1" ] && echo "" || echo "  ⚠ 回退版(无 ibv_*/perftest)")"
if [ "${RDMA_MODE}" = "1" ]; then
    echo "  RDMA 资源:   已申请 ${RDMA_RES}: 1(节点: $(echo "${_RDMA_HITS}" | tr '\n' ' '))"
else
    echo "  RDMA 资源:   未申请(${RDMA_RES} 在集群未注册 —— 通用网络诊断不受影响)"
fi
echo "  进 pod:      kubectl -n ${NS} exec -it ${POD} -- bash"
echo "  看设备视图:  kubectl -n ${NS} logs ${POD}"
echo "  重跑视图:    kubectl -n ${NS} exec ${POD} -- sh /diag/diag.sh"
echo "  常用:        tcpdump -i any -nn | ip addr | ss -tunap | ethtool -S eth0 | mtr <host>"
[ "${USING_RDMA_IMG}" = "1" ] && echo "  RDMA 实测:   ibv_devinfo; ib_write_bw -d mlx5_0(对端需同步起 ib_write_bw 服务端)"
echo "  删除:        kubectl -n ${NS} delete pod ${POD} configmap ${CM_NAME}"
