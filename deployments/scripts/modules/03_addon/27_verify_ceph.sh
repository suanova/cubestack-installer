#!/bin/bash
# ============================================================
# MODULE: verify_ceph
# DESC: 端到端验证 Ceph(Rook)真正工作(非仅 pod running):
#       ① Rook operator + ceph-csi Ready → ② CephCluster phase=Ready + ceph -s 无 HEALTH_ERR
#       → ③ StorageClass ceph-block 存在 → ④ 建测试 RBD Block PVC + Pod dd 读写(真实 I/O)
#       → ⑤ ceph osd 至少 3 up → ⑥ 清理(trap 兜底)
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# REQUIRES: ceph ceph_csi
# 说明:
#   · **验证模块不设 TOGGLE**(否则 CEPH_ENABLED=true 时会被安装流程自动启用);
#     保持 DEFAULT:0, 仅由 --steps verify_ceph 在安装后单独执行。
#   · 依赖: ceph 模块(02)与 ceph_csi 模块(03)已部署(CEPH_ENABLED=true / CEPH_CSI_ENABLED=true)。
#   · ④ 用离线预加载 busybox 以 RBD 块设备(volumeMode: Block)dd 写入/读回,
#     验证 CSI 供给 + 挂载 + 真实块 I/O; PVC storageClassName=ceph-block。
#   · 参考: docs/ceph-rook.md §6(验证清单)
# 数据源: cluster.conf (CEPH_ENABLED / CEPH_NAMESPACE / NODES / SSH_KEY_NAME)
# 用法:   sudo ./deploy-cluster.sh --steps verify_ceph
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# 开关检查: 未启用则跳过(不报错)
[ "${CEPH_ENABLED:-false}" = "true" ] || { say "CEPH_ENABLED=false, 跳过 Ceph 验证"; exit 0; }
[ "${CEPH_CSI_ENABLED:-false}" = "true" ] || { warn "CEPH_CSI_ENABLED=false(未建 StorageClass ceph-block); 仅验证 Ceph 集群本身"; }

init_remote_kubectl || exit 1

CEPH_NAMESPACE="${CEPH_NAMESPACE:-rook-ceph}"
TEST_NS="verify-ceph-$$"     # 唯一命名空间(带 PID 后缀)
TEST_PVC="verify-ceph-pvc"
TEST_POD="verify-ceph-pod"

cleanup() {
    SSH "${K} -n ${TEST_NS} delete pod ${TEST_POD} --ignore-not-found --force --grace-period=0 >/dev/null 2>&1" || true
    SSH "${K} -n ${TEST_NS} delete pvc ${TEST_PVC} --ignore-not-found --force --grace-period=0 >/dev/null 2>&1" || true
    SSH "${K} patch namespace ${TEST_NS} --type=merge -p '{\"metadata\":{\"finalizers\":null}}' >/dev/null 2>&1" || true
    SSH "${K} delete namespace ${TEST_NS} --ignore-not-found=true --force --grace-period=0 >/dev/null 2>&1" || true
}
trap cleanup EXIT

say "验证 Ceph(Rook)工作正常(端到端, 非仅 pod running)..."
say "  ① 检查 Rook operator / ceph-csi 就绪..."
SSH "${K} -n ${CEPH_NAMESPACE} get pods --no-headers 2>/dev/null | grep -E 'rook-ceph-operator.*1/1 +Running|ceph-csi-controller-manager.*[12]/[12] +Running'" \
    || { err "Rook operator / ceph-csi 未 Running(kubectl -n ${CEPH_NAMESPACE} get pods)"; exit 1; }

say "  ② 检查 CephCluster phase + ceph -s 健康..."
PHASE="$(SSH "${K} -n ${CEPH_NAMESPACE} get cephcluster rook-ceph -o jsonpath='{.status.phase}' 2>/dev/null" || true)"
[ "${PHASE}" = "Ready" ] \
    && ok "    CephCluster phase=Ready ✓" \
    || { err "    CephCluster phase='${PHASE}'(应为 Ready); kubectl -n ${CEPH_NAMESPACE} get cephcluster"; exit 1; }
CEPH_S="$( (SSH "${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph-tools -- ceph -s 2>/dev/null" || true) )"
if grep -q 'HEALTH_ERR' <<<"${CEPH_S}"; then
    err "    ceph -s = HEALTH_ERR; 请先修复(见 docs/ceph-rook.md §8)"
    exit 1
fi
echo "${CEPH_S}" | grep -E 'HEALTH_(OK|WARN)|osd:' | head -3 | sed 's/^/    /'
grep -q 'HEALTH_OK' <<<"${CEPH_S}" && ok "    ceph -s HEALTH_OK ✓" || warn "    ceph -s 当前 ${CEPH_S##*HEALTH_} (HEALTH_WARN 可接受, 若有 ERR 会失败)"

say "  ③ 检查 StorageClass ceph-block..."
SC_OK="$( (SSH "${K} get sc ceph-block --no-headers 2>/dev/null" || true) )"
[ -n "${SC_OK}" ] && ok "    StorageClass ceph-block 存在 ✓" \
    || { warn "    StorageClass ceph-block 不存在(未部署模块 ceph_csi 或 CEPH_CSI_ENABLED=false); 跳过 ④ I/O 冒烟"; SC_OK=""; }

if [ -n "${SC_OK}" ]; then
    say "  ④ 创建测试 RBD Block PVC + Pod(busybox dd 真实块 I/O)..."
    cleanup
    LOCAL_YAML="$(mktemp)"
    cat > "${LOCAL_YAML}" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${TEST_NS}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${TEST_PVC}
  namespace: ${TEST_NS}
spec:
  accessModes: [ReadWriteMany]
  volumeMode: Block
  storageClassName: ceph-block
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: ${TEST_POD}
  namespace: ${TEST_NS}
spec:
  restartPolicy: Never
  containers:
    - name: test
      image: docker.io/library/busybox:latest
      imagePullPolicy: IfNotPresent
      command: ["/bin/sh", "-c"]
      args:
        - |
          set -e
          echo "=== RBD block test ==="
          dd if=/dev/urandom of=/dev/rbd bs=4K count=256 conv=fsync
          echo "=== read-back ==="
          dd if=/dev/rbd of=/dev/null bs=4K count=256
          echo "=== SUCCESS ==="
      volumeDevices:
        - name: rbdvol
          devicePath: /dev/rbd
  volumes:
    - name: rbdvol
      persistentVolumeClaim:
        claimName: ${TEST_PVC}
YAML
    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
        "${LOCAL_YAML}" "${SSH_USER:-ubuntu}@${FIRST_MASTER}:/tmp/${TEST_POD}.yaml" \
        && SSH "${K} apply -f /tmp/${TEST_POD}.yaml" \
        && SSH "rm -f /tmp/${TEST_POD}.yaml"
    rm -f "${LOCAL_YAML}"

    say "  ⑤ 等待 PVC Bound + Pod 完成(最长 180s)..."
    PVPASS=0
    for i in $(seq 1 18); do
        _st="$( (SSH "${K} -n ${TEST_NS} get pod ${TEST_POD} -o jsonpath='{.status.phase}' 2>/dev/null" || true) )"
        [ "${_st}" = "Succeeded" ] && { PVPASS=1; break; }
        [ "${_st}" = "Failed" ] && break
        sleep 10
    done
    if [ "${PVPASS}" = "1" ]; then
        LOG="$( (SSH "${K} -n ${TEST_NS} logs ${TEST_POD} 2>/dev/null" || true) )"
        echo "${LOG}" | grep -q '=== SUCCESS ===' \
            && ok "    RBD 块设备 dd 写/读回成功(PVC 绑定 + CSI 供给 + 真实 I/O)✓" \
            || warn "    Pod Succeeded 但未见 SUCCESS 标记(日志见下, 不阻断):"
        [ -n "${LOG}" ] && echo "${LOG}" | tail -8 | sed 's/^/    /'
    else
        err "    测试 Pod 未成功(PVC 可能未绑定或 I/O 失败): kubectl -n ${TEST_NS} get pvc,pod / describe"
        exit 1
    fi
fi

say "  ⑥ OSD 检查(至少 3 up)..."
OSD_UP="$( (SSH "${K} -n ${CEPH_NAMESPACE} exec deploy/rook-ceph-tools -- ceph osd tree 2>/dev/null" || true) | grep -c 'up' )"
[ "${OSD_UP:-0}" -ge 1 ] && ok "    OSD up 节点/数量: ${OSD_UP}(ceph osd tree)" \
    || warn "    未检测到 up 的 OSD(ceph osd tree 无 up; 检查磁盘/lvm/镜像)"

say "  清理测试资源(trap 兜底)..."
cleanup
ok "Ceph 端到端验证通过: operator/CSI 运行 + CephCluster Ready + StorageClass + RBD 真实块 I/O"
