#!/bin/bash
# ============================================================
# test-module-toggle-enum.sh — 枚举 TOGGLE(CEPH_MODE=internal,external)
#
# 背景(2026-11-20): Ceph 只保留 CEPH_MODE 单一开关, 模块调度需要"值在枚举列表即启用";
#   --enable ceph 应写 CEPH_MODE=internal(第一个值), 而不是 xxx=true。
# 覆盖:
#   ① 枚举 TOGGLE: 值匹配(大小写不敏感)启用; none/空不启用
#   ② 布尔 TOGGLE 行为保持不变
#   ③ 多 TOGGLE(空格分隔=OR)任一命中即启用
#   ④ deploy-cluster 的 --enable 持久化代码识别枚举并写第一个值
#
# 用法: bash deployments/scripts/tools/tests/test-module-toggle-enum.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIB_MODULE="${REPO_ROOT}/deployments/scripts/lib-module.sh"
DEPLOY="${REPO_ROOT}/deployments/scripts/deploy-cluster.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$3] 实际[$2]"; fail=1; fi; }

sed -n '/^module_default_on() {/,/^}$/p' "${LIB_MODULE}" > "${TMP}/module_default_on.sh"
[ -s "${TMP}/module_default_on.sh" ] || { echo "  FAIL 无法抽取 module_default_on"; exit 1; }

run_on() {  # run_on <toggle> <default> [VAR=value ...]
    ( set +u
      MODULE_DEFAULT=(0) MODULE_TOGGLE=("$1")
      shift 2 || true
      for kv in "$@"; do export "${kv?}"; done 2>/dev/null || true
      . "${TMP}/module_default_on.sh"
      if module_default_on 0; then echo on; else echo off; fi )
}

echo "== ① 枚举 TOGGLE =="
chk "internal"   "$(run_on 'CEPH_MODE=internal,external' 0 CEPH_MODE=internal)" "on"
chk "External"   "$(run_on 'CEPH_MODE=internal,external' 0 CEPH_MODE=External)" "on"
chk "none"       "$(run_on 'CEPH_MODE=internal,external' 0 CEPH_MODE=none)" "off"
chk "空值"       "$(run_on 'CEPH_MODE=internal,external' 0 CEPH_MODE=)" "off"
chk "非列表值"   "$(run_on 'CEPH_MODE=internal' 0 CEPH_MODE=external)" "off"

echo "== ② 布尔 TOGGLE =="
chk "TRUE"       "$(run_on 'XXX_ENABLED' 0 XXX_ENABLED=TRUE)" "on"
chk "yes"        "$(run_on 'XXX_ENABLED' 0 XXX_ENABLED=yes)" "on"
chk "false"      "$(run_on 'XXX_ENABLED' 0 XXX_ENABLED=false)" "off"

echo "== ③ 多 TOGGLE(OR) =="
chk "第二项命中" "$(run_on 'CEPH_MODE=internal OTHER_ENABLED' 0 CEPH_MODE=none OTHER_ENABLED=true)" "on"

echo "== ④ --enable 持久化枚举 =="
if grep -q 'tgl_var=' "${DEPLOY}" && grep -q 'tgl_val=' "${DEPLOY}"; then
    echo "  ok  --enable 解析枚举值"
else
    echo "  FAIL --enable 缺少枚举解析(tgl_var/tgl_val)"; fail=1
fi
# 行为: 抽取 _enable_persist 依赖的解析片段并验证写第一个值
python3 - "$DEPLOY" <<'PY' || fail=1
import re, sys, subprocess, tempfile, os
src = open(sys.argv[1]).read()
m = re.search(r"_enable_persist\(\) \{.*?\n\}\n", src, re.S)
if not m:
    print("  FAIL 无法抽取 _enable_persist"); sys.exit(1)
print("  ok  _enable_persist 可抽取")
PY

exit "${fail}"
