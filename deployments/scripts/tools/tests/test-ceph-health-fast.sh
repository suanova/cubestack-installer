#!/bin/bash
# ============================================================
# test-ceph-health-fast.sh — 单节点 Ceph 健康检查慢的回归护栏(optimize-single-ceph)
#
# 背景(2026-11-27): 单节点只有 1 个 mon。旧实现即使 [7/8] 已经拿到 HEALTH_OK, 仍会
#   **无条件** makestep + rollout restart mon(quorum 完全中断)再等一次健康; 同时无论
#   toolbox 是否全新都强制 restart; 所有 ceph 查询没有 timeout, mon 卡住时 exec 会永久
#   阻塞等待循环。表现为"健康检查非常慢"。
#
# 本测试是静态护栏(模块无法离线真跑集群), 断言:
#   ① toolbox 仅在 apply 前已存在时才 restart(全新安装直接等待)
#   ② [7/8] HEALTH_OK 时跳过 mon clock-skew 清理/重启
#   ③ 未 HEALTH_OK 时也只在 ceph health detail 含 MON_CLOCK_SKEW 才重启 mon
#   ④ 所有 ceph exec 查询都有 timeout 包裹
#   ⑤ CephCluster CR 通过 cephConfig 提前下发 pool size/min_size/clock 阈值
#   ⑥ daemon 滚动后的 600s 健康等待仅在 placement 真的 patch 过时执行
#
# 用法: bash deployments/scripts/tools/tests/test-ceph-health-fast.sh
#       CEPH_MODULE=/tmp/old-02_ceph.sh bash ...   # 对旧实现反证(应失败)
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
MOD="${CEPH_MODULE:-${REPO_ROOT}/deployments/scripts/modules/03_addon/02_ceph.sh}"
fail=0
chk_contains() { if grep -qF -- "$2" "$MOD"; then echo "  ok  $1"; else echo "  FAIL $1: 未找到 [$2]"; fail=1; fi; }
chk_absent()   { if ! grep -qF -- "$2" "$MOD"; then echo "  ok  $1"; else echo "  FAIL $1: 不应出现 [$2]"; fail=1; fi; }

echo "== ① toolbox 重启仅限已存在的 Deployment =="
chk_contains "记录 apply 前 toolbox 是否存在" '_TB_EXISTED=0'
chk_contains "条件重启已有 toolbox" 'if [ "${_TB_EXISTED}" = "1" ]; then'
chk_contains "全新 toolbox 跳过重启" '全新 toolbox(无需重启)'

echo "== ② [7/8] HEALTH_OK 时跳过 mon 重启 =="
chk_contains "HEALTH_OK 短路" 'if [ "${CLUSTER_OK:-0}" = "1" ]; then'
chk_contains "跳过提示" '跳过 clock skew 清理与 mon 重启'
chk_contains "仅在确有 MON_CLOCK_SKEW 时重启" "MON_CLOCK_SKEW"
chk_contains "clock skew 检测分支" 'if [ "${_need_mon_restart}" = "1" ]; then'

echo "== ③ 单盘 size=1 的 POOL_NO_REDUNDANCY 预期告警 =="
chk_contains "识别 POOL_NO_REDUNDANCY" "POOL_NO_REDUNDANCY"
chk_contains "预期告警标记" "CLUSTER_EXPECTED_WARN=1"
chk_contains "仅无其它 WRN 才放行" '_other_warn'
chk_contains "预期告警提示" '单盘无冗余属预期'

echo "== ④ ceph 查询必须有 timeout(防 mon 卡死阻塞等待循环) =="
missing="$(python3 - "$MOD" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
miss = []
for i, line in enumerate(lines, 1):
    s = line.strip()
    if s.startswith("#"):
        continue
    # 帮助文本里的示例命令不算实际调用
    if 'echo "' in line:
        continue
    # 单行: exec ... -- ceph ...
    if "exec deploy/rook-ceph-tools -- ceph" in line and "timeout" not in line:
        miss.append(i)
    # 续行: 上一行以 "-- \" 结尾且是 toolbox exec, 本行以 ceph 开头
    if i >= 2:
        prev = lines[i - 2]
        if s.startswith("ceph ") and prev.rstrip().endswith("-- \\") \
           and "rook-ceph-tools" in prev and "timeout" not in line:
            miss.append(i)
print(" ".join(str(x) for x in miss))
PY
)"
if [ -z "${missing}" ]; then echo "  ok  所有 ceph exec 查询均带 timeout"; else echo "  FAIL 缺少 timeout 的行: ${missing}"; fail=1; fi

echo "== ⑤ CephCluster CR 提前下发关键配置 =="
chk_contains "CR 含 cephConfig" 'echo "  cephConfig:"'
chk_contains "提前下发 mon clock 阈值" 'mon_clock_drift_allowed'
chk_contains "提前下发 pool size" 'osd_pool_default_size'
chk_contains "单节点 PG 上限" 'mon_max_pg_per_osd'

echo "== ⑥ daemon 滚动等待仅在 placement patch 后 =="
chk_contains "记录 placement 是否 patch" '_CEPH_PLACEMENT_PATCHED=1'
chk_contains "条件等待" 'if [ "${_CEPH_PLACEMENT_PATCHED:-0}" = "1" ]; then'
chk_contains "无变更跳过提示" '无需变更 → 跳过滚动后健康等待'

echo "== ⑦ 旧实现反证(仅在指定 CEPH_MODULE 时) =="
if [ -n "${CEPH_MODULE:-}" ]; then
    # 旧实现应至少缺少上述某项; 本测试已按新实现断言, 旧文件必然失败。
    echo "  (当前 MOD=${MOD})"
fi

[ "${fail}" = "0" ] && echo "✅ test-ceph-health-fast: 全部通过" || { echo "❌ 有失败项"; exit 1; }
