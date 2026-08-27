#!/bin/bash
# ============================================================
# MODULE: verify_registry_storage
# DESC: 端到端验证内置 registry + local-path: 从离线 tar 真实 push busybox 到集群
#       registry(MetalLB VIP 直连), 再用 local-path PVC 跨 Pod 落盘并校验数据持久化
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# 说明:
#   · **验证模块不设 TOGGLE**, 保持 DEFAULT:0, 仅由 --steps verify_registry_storage 显式执行。
#   · registry 是集群内 Pod, 经 MetalLB LoadBalancer 分配 VIP 对外; 宿主机经 VIP 直连推送,
#     不依赖宿主机 DNAT/daemon insecure-registries(skopeo --dest-tls-verify=false)。
#   · 验证 registry(真 push, 非仅 curl /v2/):
#       ① registry Service 存在 + 取到推送端点(VIP:PORT 或 NodePort:PORT)
#       ② 宿主机 curl 端点 /v2/ 可达
#       ③ 从离线包 repository/<cluster>/images/busybox.tar 取 busybox(无则报错给指引)
#       ④ skopeo copy docker-archive → docker://<端点>/verify/busybox:<tag>(--dest-tls-verify=false)
#       ⑤ curl /v2/verify/busybox/tags/list 确认 manifest 已入库
#   · 验证 local-path(真落盘, 非仅 SC 存在):
#       ⑥ local-path StorageClass 是默认 + provisioner pod Running
#       ⑦ 建 PVC(local-path) + pod1 写 marker 文件后退出(镜像用 ④ push 的 busybox, 顺带验证集群内 pull)
#       ⑧ 等 PVC Bound + pod1 Completed; pod2 挂同一 PVC 读 marker 打印到日志
#       ⑨ SSH 到 PV 所在节点 cat 落盘文件, 与 pod1 写入一致(证明数据真实持久化到宿主机磁盘)
#       ⑩ 清理: 删测试命名空间(连带 PVC/PV); 测试镜像 tag 保留(registry 默认不开 API delete)
#   · 本文件可作 verify_<组件>.sh 模板: 复制后改 MODULE/DESC 与验证逻辑即可(勿加 TOGGLE)
# 数据源: cluster.conf (REGISTRY_ENABLED / REGISTRY_* / LOCAL_REPO_DIR / NODES / SSH_KEY_NAME)
# 用法:   sudo ./deploy-cluster.sh --steps verify_registry_storage
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# ---- 开关: 两个组件都没启用则跳过(不报错) ----
REGISTRY_ON="$([ "${REGISTRY_ENABLED:-0}" = "1" ] || [ "${REGISTRY_ENABLED:-false}" = "true" ] && echo 1 || echo 0)"
LOCALPATH_ON="$([ "${LOCAL_PATH_ENABLED:-false}" = "true" ] || [ "${LOCAL_PATH_ENABLED:-0}" = "1" ] && echo 1 || echo 0)"
if [ "${REGISTRY_ON}" = "0" ] && [ "${LOCALPATH_ON}" = "0" ]; then
    say "REGISTRY_ENABLED 与 LOCAL_PATH_ENABLED 均未开启, 跳过验证"
    exit 0
fi

FIRST_MASTER="$(first_master_ip)" || { err "未找到 master 节点"; exit 1; }
SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
SSH() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
           "${SSH_USER:-ubuntu}@${FIRST_MASTER}" "$@"; }
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

# 节点 hostname → IP(cluster.conf NODES, 供 kubectl nodeName→SSH 目标)
node_ip_by_name() {
    local hn="$1" line
    for line in "${NODES[@]:-}"; do
        [ -z "${line}" ] && continue
        node_parse "${line}"
        [ "${NODE_HOSTNAME}" = "${hn}" ] && { echo "${NODE_IP}"; return 0; }
    done
    return 1
}

TEST_NS="verify-registry-storage-$$"     # 唯一命名空间(PID 后缀), 避免与残留 Terminating ns 冲突
TEST_TAG="verify-$(date +%s)"
TEST_MARKER="cubestack-localpath-${TEST_TAG}"
POD1="lp-writer"
POD2="lp-reader"
PVC_NAME="lp-test-pvc"
PUSH_NS="verify"

# 推送/校验端点: loadbalancer → VIP:PORT; nodeport → 首个节点 IP:REGISTRY_NODEPORT
REGISTRY_ENDPOINT=""
if [ "${REGISTRY_SERVICE_TYPE:-loadbalancer}" = "nodeport" ]; then
    REGISTRY_ENDPOINT="$(SSH "${K} get nodes --no-headers -o wide | awk '{print \$6}' | head -1" 2>/dev/null || true):${REGISTRY_NODEPORT:-31148}"
else
    REGISTRY_ENDPOINT="${REGISTRY_IP}:${REGISTRY_PORT:-5000}"
fi
[ -n "${REGISTRY_ENDPOINT%%:*}" ] || { err "无法确定 registry 推送端点(loadbalancer 需 REGISTRY_IP / nodeport 需集群节点可访问)"; exit 1; }

TAR="${LOCAL_REPO_DIR}/images/busybox.tar"

# ---- 清理: 删测试命名空间 + 删 registry 测试镜像(trap 兜底) ----
cleanup() {
    [ -n "${FIRST_MASTER:-}" ] || return 0
    SSH "${K} patch namespace ${TEST_NS} --type=merge -p '{\"metadata\":{\"finalizers\":null}}' >/dev/null 2>&1" || true
    SSH "${K} delete namespace ${TEST_NS} --ignore-not-found=true --force --grace-period=0 >/dev/null 2>&1" || true
    # 测试镜像: 本集群 registry 默认未开启 API delete(返回 405), 无法自动删除 tag/blob;
    # 测试 tag 体积小(busybox 约 2M)且不影响使用, 保留在 registry 中, 见末尾说明。
    rm -f "/tmp/${TEST_NS}-"*.yaml 2>/dev/null || true
}
trap cleanup EXIT

say "验证内置 registry + local-path 工作正常(端到端, 非仅 pod running)..."

# ============================================================
# 第一部分: registry 真实 push 验证
# ============================================================
if [ "${REGISTRY_ON}" = "1" ]; then
    say "=== [A] 验证内置 registry(真实 push 离线 busybox 镜像) ==="
    say "  ① registry Service 存在且拿到推送端点(${REGISTRY_ENDPOINT})..."
    SSH "${K} -n kube-system get svc registry -o wide 2>/dev/null | grep -E 'registry'" \
        || { err "未找到 kube-system/registry Service(检查 addons.yml registry_enabled 与 kubespray 是否部署)"; exit 1; }

    say "  ② 宿主机 curl http://${REGISTRY_ENDPOINT}/v2/ 可达(MetalLB 通告正常)..."
    curl -s -m 8 "http://${REGISTRY_ENDPOINT}/v2/" >/dev/null 2>&1 \
        || { err "${REGISTRY_ENDPOINT}/v2/ 不可达。检查: ① MetalLB 是否分配 VIP(kubectl -n metallb-system get ipaddresspool); ② 宿主机能否路由到节点网段"; exit 1; }
    ok "    ${REGISTRY_ENDPOINT}/v2/ 可达"

    say "  ③ 取离线 busybox 镜像 tar(${TAR})..."
    [ -f "${TAR}" ] || { err "未找到 ${TAR}。离线镜像包缺 busybox.tar, 请先补全 offline-files/kubespray/images/(见 kubespray/cubestack-offline.sh download); 或改 TAR 指向其他验证用镜像"; exit 1; }
    ls -lh "${TAR}" | awk '{print "    " $5" "$9}'

    say "  ④ 推送 busybox → ${REGISTRY_ENDPOINT}/${PUSH_NS}/busybox:${TEST_TAG}(--dest-tls-verify=false)..."
    if command -v skopeo >/dev/null 2>&1; then
        skopeo copy --quiet --dest-tls-verify=false --dest-no-creds \
            "docker-archive:${TAR}" \
            "docker://${REGISTRY_ENDPOINT}/${PUSH_NS}/busybox:${TEST_TAG}" \
            || { err "skopeo push 失败(HTTP registry 已 --dest-tls-verify=false, 检查 VIP/端口与磁盘空间)"; exit 1; }
    else
        # 回退: 经节点 ctr 推送(节点已信任 registry.local:PORT, 无需 daemon 配置; 离线可用)
        say "    未找到 skopeo, 改用节点 ctr 加载本地 tar 并 --plain-http 推送..."
        REMOTE_TAR="/tmp/busybox-${TEST_TAG}.tar"
        scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
            "${TAR}" "${SSH_USER:-ubuntu}@${FIRST_MASTER}:${REMOTE_TAR}" \
            || { err "scp busybox.tar 到 ${FIRST_MASTER} 失败"; exit 1; }
        SSH "sudo ctr -n k8s.io images import ${REMOTE_TAR} && sudo ctr -n k8s.io images tag docker.io/library/busybox:latest ${REGISTRY_DOMAIN}:${REGISTRY_PORT}/${PUSH_NS}/busybox:${TEST_TAG} && sudo ctr -n k8s.io images push --plain-http ${REGISTRY_DOMAIN}:${REGISTRY_PORT}/${PUSH_NS}/busybox:${TEST_TAG}" \
            || { err "节点 ctr push 失败(检查: 节点 containerd certs.d 是否信任 registry.local / /etc/hosts 是否有 registry.local)"; exit 1; }
        SSH "sudo ctr -n k8s.io images rm ${REGISTRY_DOMAIN}:${REGISTRY_PORT}/${PUSH_NS}/busybox:${TEST_TAG} docker.io/library/busybox:latest >/dev/null 2>&1; sudo rm -f ${REMOTE_TAR}" 2>/dev/null || true
    fi
    ok "    已推送 ${PUSH_NS}/busybox:${TEST_TAG}"

    say "  ⑤ 校验 manifest 已入库(tags/list)..."
    TAGS="$(curl -s -m 8 "http://${REGISTRY_ENDPOINT}/v2/${PUSH_NS}/busybox/tags/list" 2>/dev/null || true)"
    echo "    tags/list → ${TAGS:-<空>}"
    echo "${TAGS}" | grep -q "${TEST_TAG}" \
        || { err "registry tags/list 未出现 ${TEST_TAG}(push 未生效或 registry 有缓存), 请检查 skopeo 输出与 registry Pod 日志"; exit 1; }
    ok "    镜像已在集群 registry 中: ${REGISTRY_DOMAIN}:${REGISTRY_PORT}/${PUSH_NS}/busybox:${TEST_TAG}"

    # 集群内 pull 验证由 local-path 部分的 pod 顺带完成(image 用本镜像)
else
    say "=== [A] REGISTRY_ENABLED=false, 跳过 registry 推送验证 ==="
fi

# ============================================================
# 第二部分: local-path 真实落盘验证
# ============================================================
if [ "${LOCALPATH_ON}" = "1" ]; then
    say "=== [B] 验证 local-path(真实落盘 + 跨 Pod 持久化) ==="
    say "  ⑥ local-path StorageClass 为默认 + provisioner pod Running..."
    SC_DEFAULT="$(SSH "${K} get sc local-path -o jsonpath='{.metadata.annotations.storageclass\\.kubernetes\\.io/is-default-class}' 2>/dev/null")" || true
    [ "${SC_DEFAULT}" = "true" ] || { err "StorageClass local-path 不是默认(default), 检查 addons.yml local_path_provisioner_enabled"; exit 1; }
    SSH "${K} -n local-path-storage get pods 2>/dev/null | grep -E 'local-path-provisioner.*1/1 +Running'" \
        || { err "local-path-provisioner pod 未 Running"; exit 1; }
    ok "    StorageClass local-path(default) + provisioner Running"

    # 测试镜像: registry 验证已 push 的 busybox; 未启用 registry 时用离线 busybox 拉取源(docker.io/library/busybox)
    if [ "${REGISTRY_ON}" = "1" ]; then
        TEST_IMAGE="${REGISTRY_DOMAIN}:${REGISTRY_PORT}/${PUSH_NS}/busybox:${TEST_TAG}"
    else
        TEST_IMAGE="docker.io/library/busybox:latest"
    fi

    say "  ⑦ 创建 PVC(local-path) + pod1(${POD1}) 写入 marker 文件后退出..."
    YAML="/tmp/${TEST_NS}-resources.yaml"
    cat > "${YAML}" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${TEST_NS}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${TEST_NS}
spec:
  storageClassName: local-path
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 100Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: ${POD1}
  namespace: ${TEST_NS}
spec:
  restartPolicy: Never
  containers:
  - name: writer
    image: ${TEST_IMAGE}
    imagePullPolicy: Always
    command: ["/bin/sh","-c","mkdir -p /mnt/data && echo '${TEST_MARKER}' > /mnt/data/marker.txt && cat /mnt/data/marker.txt"]
    volumeMounts:
    - name: data
      mountPath: /mnt/data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: ${PVC_NAME}
---
apiVersion: v1
kind: Pod
metadata:
  name: ${POD2}
  namespace: ${TEST_NS}
spec:
  restartPolicy: Never
  containers:
  - name: reader
    image: ${TEST_IMAGE}
    imagePullPolicy: Always
    command: ["/bin/sh","-c","cat /mnt/data/marker.txt"]
    volumeMounts:
    - name: data
      mountPath: /mnt/data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: ${PVC_NAME}
YAML
    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
        "${YAML}" "${SSH_USER:-ubuntu}@${FIRST_MASTER}:/tmp/${TEST_NS}-resources.yaml" \
        && SSH "${K} apply -f /tmp/${TEST_NS}-resources.yaml" \
        && SSH "rm -f /tmp/${TEST_NS}-resources.yaml"
    rm -f "${YAML}"

    say "  ⑧ 等待 pod1 拉取镜像并写盘完成(Completed, 最长 120s; 同时验证集群内从 registry pull)..."
    PHASE1=""
    for i in $(seq 1 24); do
        PHASE1="$(SSH "${K} -n ${TEST_NS} get pod ${POD1} -o jsonpath={.status.phase} 2>/dev/null")" || true
        [ "${PHASE1}" = "Succeeded" ] && break
        [ "${PHASE1}" = "Failed" ] && { SSH "${K} -n ${TEST_NS} logs ${POD1} 2>/dev/null | tail -20"; err "pod1 执行失败(镜像拉取/写盘问题, 见上方日志)"; exit 1; }
        sleep 5
    done
    [ "${PHASE1}" = "Succeeded" ] || { SSH "${K} -n ${TEST_NS} describe pod ${POD1} 2>/dev/null | grep -A8 'Events:' | tail -12"; err "pod1 120s 内未 Completed(phase=${PHASE1:-?}); 检查镜像 ${TEST_IMAGE} 能否被集群拉取(kubectl describe pod 见 Events)"; exit 1; }
    POD1_LOG="$(SSH "${K} -n ${TEST_NS} logs ${POD1}" 2>/dev/null | tr -d '\r')" || true
    ok "    pod1 写盘完成(${POD1_LOG})"

    say "    等待 PVC Bound..."
    PVC_PHASE=""
    for i in $(seq 1 12); do
        PVC_PHASE="$(SSH "${K} -n ${TEST_NS} get pvc ${PVC_NAME} -o jsonpath={.status.phase} 2>/dev/null")" || true
        [ "${PVC_PHASE}" = "Bound" ] && break
        sleep 5
    done
    [ "${PVC_PHASE}" = "Bound" ] || { err "PVC 未 Bound(phase=${PVC_PHASE:-?}); 检查 local-path-provisioner 日志"; exit 1; }

    say "  ⑨ pod2(${POD2}) 挂同一 PVC 读取 marker..."
    PHASE2=""
    for i in $(seq 1 24); do
        PHASE2="$(SSH "${K} -n ${TEST_NS} get pod ${POD2} -o jsonpath={.status.phase} 2>/dev/null")" || true
        [ "${PHASE2}" = "Succeeded" ] && break
        [ "${PHASE2}" = "Failed" ] && { SSH "${K} -n ${TEST_NS} logs ${POD2} 2>/dev/null | tail -10"; err "pod2 读取失败"; exit 1; }
        sleep 5
    done
    [ "${PHASE2}" = "Succeeded" ] || { err "pod2 120s 内未 Completed(phase=${PHASE2:-?})"; exit 1; }
    POD2_OUT="$(SSH "${K} -n ${TEST_NS} logs ${POD2}" 2>/dev/null | tr -d '\r')" || true
    echo "${POD2_OUT}" | grep -q "${TEST_MARKER}" \
        || { err "pod2 读到的内容(${POD2_OUT:-<空>})与写入的 marker(${TEST_MARKER})不一致 —— 数据未持久化"; exit 1; }
    ok "    pod2 读到 marker ✓(${POD2_OUT})"

    say "    从宿主机 SSH 到 PV 所在节点 cat 落盘文件(验证真实写入宿主机磁盘)..."
    POD2_NODE="$(SSH "${K} -n ${TEST_NS} get pod ${POD2} -o jsonpath={.spec.nodeName} 2>/dev/null")" || true
    # 本集群 local-path-provisioner v0.0.24 创建的 PV 用 spec.hostPath.path(非 spec.local.path)
    PV_INFO="$(SSH "${K} get pv -o jsonpath='{range .items[*]}{.spec.claimRef.namespace}{\"/\"}{.spec.claimRef.name}{\" \"}{.spec.hostPath.path}{\"\\n\"}{end}' 2>/dev/null")" || true
    PV_PATH="$(echo "${PV_INFO}" | grep "^${TEST_NS}/${PVC_NAME}" | awk '{print $2}')" || true
    PV_NODE_IP="$(node_ip_by_name "${POD2_NODE}")" || true
    [ -n "${POD2_NODE}" ] && [ -n "${PV_PATH}" ] && [ -n "${PV_NODE_IP}" ] \
        || { err "未能定位 PV 所在节点(node=${POD2_NODE:-?}, ip=${PV_NODE_IP:-?}, path=${PV_PATH:-?}); 检查 kubectl get pv 输出(spec.hostPath.path) 与 cluster.conf NODES"; exit 1; }
    DISK_MARKER="$(ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
        "${SSH_USER:-ubuntu}@${PV_NODE_IP}" "sudo cat ${PV_PATH}/marker.txt 2>/dev/null" 2>/dev/null || true)"
    echo "    node=${POD2_NODE}(${PV_NODE_IP})  path=${PV_PATH}  →  ${DISK_MARKER}"
    [ "${DISK_MARKER}" = "${TEST_MARKER}" ] \
        || { err "宿主机落盘内容(${DISK_MARKER:-<空>})不一致 —— 数据未真正持久化"; exit 1; }
    ok "    宿主机磁盘 ${PV_PATH}/marker.txt 内容一致, local-path 持久化验证通过 ✓"
else
    say "=== [B] LOCAL_PATH_ENABLED=false, 跳过 local-path 落盘验证 ==="
fi

# ============================================================
say "清理测试资源(命名空间 + registry 测试镜像)..."
cleanup
trap - EXIT

ok "验证通过: registry 真实 push + local-path 真实落盘均工作正常"
echo "  推送的镜像 tag:  ${PUSH_NS}/busybox:${TEST_TAG}(来自离线 tar, 全程未访问外网)"
echo "  registry 端点:   ${REGISTRY_ENDPOINT}"
echo "  注: 该 registry 未开启 API delete(默认 405), 测试 tag/blob 保留在 registry(约 2M, 不影响使用);"
echo "      如需彻底清理: registry 配置开 delete 并 GC, 或停 registry 后清理其数据目录中 verify/busybox 的层"
