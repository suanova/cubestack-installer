#!/bin/bash
# ============================================================
# test-ceph-nbd-guards.sh — Ceph nbd/0-OSD/官方导出卡死的静态回归
# 背景(2026-10-19 实机):
#   · CSI RBD nodeplugin 显式 modprobe nbd → /sys/block/nbd0 常驻;
#   · 新集群 osd-prepare 的 ceph-volume inventory 在 nbd0 上抛
#     "No udev data could be retrieved", 跳过 vdb/vdc/vdd → 0 OSD;
#   · 0 OSD 时 ceph-expose-external 的官方 create-external-cluster-resources.py
#     在 inactive PG / 未 Ready 的 RGW realm 上无限等待(实机 pending 20min+)。
# 覆盖(源码围栏):
#   ① nbd 清理: install nbd /bin/false、卸载后校验、STILL-PRESENT/IN-USE 硬失败
#   ② OSD=0: Ceph Ready 但 OSD=0 必须 exit 1, 不再 warn 后继续
#   ③ 官方导出: OSD=0 预检跳过 + python3 timeout + RGW 未就绪省略参数
#   ④ 强制清理: 所有 --force delete 必须带 --wait=false(2026-10-20 实机 PV finalizer 卡死)
# 用法: bash deployments/scripts/tools/tests/test-ceph-nbd-guards.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CEPH="${REPO_ROOT}/deployments/scripts/modules/03_addon/02_ceph.sh"
EXPOSE="${REPO_ROOT}/deployments/scripts/tools/k8s/ceph-expose-external.sh"
CLEANUP="${REPO_ROOT}/deployments/scripts/tools/k8s/ceph-cleanup.sh"
fail=0
chk_contains() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  ok  $1"; else echo "  FAIL $1: [$3] 未包含 [$2]"; fail=1; fi; }
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_not_contains() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  FAIL $1: [$3] 不应包含 [$2]"; fail=1; else echo "  ok  $1"; fi; }

echo "== ① nbd 清理/校验 =="
chk_contains "install nbd /bin/false(挡显式 modprobe)" "install nbd /bin/false" "${CEPH}"
chk_contains "nbds_max=0 预载(CSI 容器内 modprobe 不读宿主机规则)" "nbds_max=0" "${CEPH}"
chk_contains "OSD 就绪后恢复 nbd 默认设备" "_ceph_nbd_restore_one" "${CEPH}"
chk_contains "卸载后校验 lsmod/设备" "STILL-PRESENT" "${CEPH}"
chk_contains "调用方硬失败标记" "_CEPH_NBD_FAIL" "${CEPH}"
chk_contains "拒绝创建 CephCluster 的报错" "拒绝继续创建 CephCluster" "${CEPH}"

echo "== ② 0 OSD 硬失败 =="
chk_contains "就绪判据必须 HEALTH_OK 且 OSD>0" '[ "${_hl}" = "HEALTH_OK" ] && [ "${_osd_n:-0}" -gt 0 ]' "${CEPH}"
chk_contains "Ready 但 OSD=0 判定" "Ceph 集群 Ready 但 OSD=0" "${CEPH}"
chk_contains "给出 nbd 根因提示" "ceph-volume inventory" "${CEPH}"
chk_contains "OSD=0 分支 exit 1" 'exit 1' "${CEPH}"

echo "== ③ 官方导出预检/超时/RGW =="
chk_contains "OSD=0 跳过官方导出" "Ceph OSD=0, 跳过官方" "${EXPOSE}"
chk_contains "python3 带 timeout" "timeout 120 python3" "${EXPOSE}"
chk_contains "RGW 未就绪省略参数" "CephObjectStore/RGW 未就绪" "${EXPOSE}"
chk_contains "RGW 端点可达性探测" "timeout 5 curl" "${EXPOSE}"

echo "== ④ Ceph 强制清理不得无限等待 finalizer =="
# 2026-10-20 实机: wait_ceph_volumes_gone 的 `kubectl delete pv --force --grace-period=0`
# 未带 --wait=false → PVC/PV 的 pvc-protection / external-provisioner finalizer 不清除时
# delete 无限阻塞(卡 7.5min+, 直到模块 1800s timeout)。强制清理只应发起删除、不陪等。
chk_contains "PVC 强删带 --wait=false" 'delete pvc ${_p#*/} --ignore-not-found --force --grace-period=0 --wait=false' "${CLEANUP}"
chk_contains "PV 强删带 --wait=false" 'delete pv ${_pv} --ignore-not-found --force --grace-period=0 --wait=false' "${CLEANUP}"
chk_contains "PV finalizer patch 有 timeout" 'timeout 30 ${K} patch pv' "${CLEANUP}"
_bad_force="$(grep -nE -- 'delete .*--force' "${CLEANUP}" | grep -v -- '--wait=false' || true)"
if [ -z "${_bad_force}" ]; then
    echo "  ok  所有 --force delete 都带 --wait=false"
else
    echo "  FAIL 存在 --force delete 未带 --wait=false:"
    printf '%s\n' "${_bad_force}" | sed 's/^/    /'
    fail=1
fi
# 2026-10-20 CodeRabbit: --wait=false 只代表"不陪等 finalizer", 不代表 CSI unmap 完成。
# 强制删除后必须有界复查; 仍残留则返回非零, 默认拒绝继续删 nodeplugin/CephCluster。
chk_contains "强制清理后有界复查开关" 'CEPH_CLEANUP_FORCE_RECHECK_SECONDS' "${CLEANUP}"
chk_contains "强制清理残留返回非零" '未确认 CSI unmap 完成' "${CLEANUP}"
chk_contains "复查含 ceph CSI VolumeAttachment" '_list_ceph_volumeattachments' "${CLEANUP}"
chk_contains "VolumeAttachment 消失才算 unmap" 'VolumeAttachment 已消失' "${CLEANUP}"
chk_contains "PVC 清单包含 Lost(强删 PV 后)" '"Bound", "Lost"' "${CLEANUP}"
chk "三个列表查询失败均返回非零(异常/非 List 两处)" "6" "$(grep -cF 'sys.exit(2)' "${CLEANUP}" || true)"
chk "两处复查都要求查询成功" "2" "$(grep -cF '_left_pv="$(_list_ceph_pvs' "${CLEANUP}" || true)"
chk "CephCluster 查询均用 ignore-not-found" "5" "$(grep -cF -- '--ignore-not-found -o name' "${CLEANUP}" || true)"
chk_not_contains "CephCluster 消失判断不吞查询错误" '_still="$( (SSH' "${CLEANUP}"
chk_contains "无集群预检查不吞查询错误" '查询 CephCluster 失败(无法确认是否存在)' "${CLEANUP}"
chk_contains "查询失败标记中止擦盘" '_CEPH_ABORT_WIPE' "${CLEANUP}"
chk_contains "CephCluster 查询失败标记" '_cluster_query_failed' "${CLEANUP}"
chk_contains "stop_consumers 检查卷清理结果" 'if ! wait_ceph_volumes_gone 120 0' "${CLEANUP}"
chk_contains "默认拒绝删 rbd nodeplugin" '拒绝删除 rbd csi nodeplugin' "${CLEANUP}"
chk_contains "显式不安全放行开关" 'CEPH_CLEANUP_ALLOW_UNSAFE_UNMAP' "${CLEANUP}"
chk_contains "delete_cluster 二次卷检查" 'if ! wait_ceph_volumes_gone 120 1' "${CLEANUP}"
chk_contains "cleanup_all 不安全时中止清盘" '_CEPH_UNSAFE_UNMAP' "${CLEANUP}"
chk_contains "CephCluster 强删后复查开关" 'CEPH_CLEANUP_CLUSTER_FORCE_GONE_SECONDS' "${CLEANUP}"
chk_contains "CephCluster 未消失返回失败" 'CephCluster 强制删除后仍存在' "${CLEANUP}"
chk_contains "cleanup_all 传播删除失败" '_dc_rc' "${CLEANUP}"

echo ""
if [ "${fail}" = "0" ]; then
    echo "✅ test-ceph-nbd-guards: 全部通过"
else
    echo "❌ test-ceph-nbd-guards: 存在失败项"
fi
exit "${fail}"
