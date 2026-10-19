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
# 用法: bash deployments/scripts/tools/tests/test-ceph-nbd-guards.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CEPH="${REPO_ROOT}/deployments/scripts/modules/03_addon/02_ceph.sh"
EXPOSE="${REPO_ROOT}/deployments/scripts/tools/k8s/ceph-expose-external.sh"
fail=0
chk_contains() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  ok  $1"; else echo "  FAIL $1: [$3] 未包含 [$2]"; fail=1; fi; }

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

echo ""
if [ "${fail}" = "0" ]; then
    echo "✅ test-ceph-nbd-guards: 全部通过"
else
    echo "❌ test-ceph-nbd-guards: 存在失败项"
fi
exit "${fail}"
