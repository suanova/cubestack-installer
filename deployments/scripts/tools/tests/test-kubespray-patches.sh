#!/bin/bash
# 离线回归: cubestack-patch-apply.sh 的三态与退役判定(不联网; fixture 树 + fixture 补丁目录)
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../../../.." && pwd)"
APPLY="${REPO_ROOT}/deployments/kubespray/cubestack-patch-apply.sh"
PASS=0; FAIL=0
ok(){ echo "  ok  $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

mk_fixture() {   # $1=目录: 造 {target/f.txt 纯净, patches/01-demo.patch}
    local d="$1"; rm -rf "$d"; mkdir -p "$d/target" "$d/patches"
    printf 'line1\nline2\n' > "$d/target/f.txt"
    printf '# patch: 01-demo.patch\n# 目标: target/f.txt\n--- a/target/f.txt\n+++ b/target/f.txt\n@@ -1,2 +1,2 @@\n line1\n-line2\n+line2-changed\n' > "$d/patches/01-demo.patch"
}

# 未打 → APPLY
mk_fixture /tmp/pt-unapplied
out="$("$APPLY" --root /tmp/pt-unapplied --patches /tmp/pt-unapplied/patches --apply 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q 'APPLY.*01-demo' <<<"$out" && ok "未打 → APPLY, 退出 0" || bad "未打场景: rc=$rc out=$out"
grep -q 'line2-changed' /tmp/pt-unapplied/target/f.txt && ok "内容确实变了" || bad "内容没变"

# 已打 → SKIP
out="$("$APPLY" --root /tmp/pt-unapplied --patches /tmp/pt-unapplied/patches --apply 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q 'SKIP.*01-demo' <<<"$out" && ok "已打 → SKIP(幂等)" || bad "幂等场景: rc=$rc out=$out"

# 冲突 → CONFLICT + 非 0
mk_fixture /tmp/pt-conflict
printf 'line1\nline2-DIFFERENT\n' > /tmp/pt-conflict/target/f.txt
out="$("$APPLY" --root /tmp/pt-conflict --patches /tmp/pt-conflict/patches --apply 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'CONFLICT.*01-demo' <<<"$out" && ok "冲突 → CONFLICT + 非 0" || bad "冲突场景: rc=$rc out=$out"

# 退役: 树已等于"打过之后"的样子 → 该补丁应被列为可退休
mk_fixture /tmp/pt-retired
printf 'line1\nline2-changed\n' > /tmp/pt-retired/target/f.txt
out="$("$APPLY" --root /tmp/pt-retired --patches /tmp/pt-retired/patches --check-retired 2>&1)"
grep -q 'RETIRE.*01-demo' <<<"$out" && ok "已被上游吸收 → RETIRE" || bad "退役场景: out=$out"

# 未吸收(干净树, 补丁尚未打) → 必须 KEEP, 不得误判 RETIRE(T3 靠这个输出决定删不删补丁)
mk_fixture /tmp/pt-keep
out="$("$APPLY" --root /tmp/pt-keep --patches /tmp/pt-keep/patches --check-retired 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q 'KEEP.*01-demo' <<<"$out" && ok "未被吸收 → KEEP(干净树不误判 RETIRE)" || bad "KEEP 场景: rc=$rc out=$out"

echo "---------------------------------------------"
[ "$FAIL" = 0 ] && { echo "✅ 全部 ${PASS} 项通过"; exit 0; } || { echo "❌ ${FAIL} 项失败"; exit 1; }
