#!/usr/bin/env bash
#
# Offline smoke test for the github-planning skill.
#
# Runs `gp` entirely under --dry-run --state <fixture> with a fake `gh` shim that
# fails loudly if it is ever invoked. Passing the test therefore proves that no
# real GitHub API call was attempted — no auth, no network, no live repo needed.
#
# Usage: bash tests/smoke-test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GP="$ROOT/scripts/gp"
FIX="$ROOT/tests/fixtures"

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required but not installed" >&2; exit 1; }

# Fake gh shim: any real invocation is a test failure.
FBIN="$(mktemp -d)"
trap 'rm -rf "$FBIN"' EXIT
printf '#!/bin/sh\necho "FAIL: gh invoked — offline test must not call the API" >&2\nexit 127\n' > "$FBIN/gh"
chmod +x "$FBIN/gh"
PATH="$FBIN:$PATH"

fail() { echo "FAIL: $1" >&2; exit 1; }

# 1. validate — offline manifest schema checks
"$GP" validate "$FIX/plan.json" >/dev/null || fail "valid manifest rejected"
"$GP" validate "$FIX/invalid-plan.json" >/dev/null 2>&1 && fail "invalid manifest accepted"
invalid_errs="$("$GP" validate "$FIX/invalid-plan.json" 2>&1 || true)"
echo "$invalid_errs" | grep -q "story_points" || fail "no off-scale story_points error"
echo "$invalid_errs" | grep -q "depends_on" || fail "no unresolved depends_on error"

# 2. plan — fresh (empty) state: expect label ensures + creates + links
out="$("$GP" plan --dry-run --state "$FIX/empty-state.json" "$FIX/plan.json")"
echo "$out" | grep -q "ensure label: epic"               || fail "no epic label ensure"
echo "$out" | grep -q "ensure label: story"              || fail "no story label ensure"
echo "$out" | grep -q "create issue: Epic: onboarding"   || fail "no issue create"
echo "$out" | grep -q "create issue: Onboard via OAuth"  || fail "cross-milestone match not re-created"
echo "$out" | grep -q "link sub-issue:"                  || fail "no sub-issue link"
echo "$out" | grep -q "link blocked_by:"                 || fail "no dependency link"

# 3. plan — re-run state: expect pure skips, zero creates/ensures
out="$("$GP" plan --dry-run --state "$FIX/re-run-state.json" "$FIX/plan.json")"
echo "$out" | grep -q "skip (exists): Epic: onboarding" || fail "no idempotent skip"
echo "$out" | grep -q "milestone: using existing 'v1.0'" || fail "existing milestone not reused"
if echo "$out" | grep -q "create issue:"; then fail "created on re-run"; fi
if echo "$out" | grep -q "ensure label:"; then fail "re-ensured labels on re-run"; fi

# 4. release-notes — dry-run against a milestone issue list
out="$("$GP" release-notes --dry-run --state "$FIX/milestone-issues.json" v1.0)"
echo "$out" | grep -q "## Features"       || fail "no type grouping"
echo "$out" | grep -q "#1 — Add auth"     || fail "issue not rendered"
echo "$out" | grep -q "Story points:"     || fail "no estimate total"

# 5. update-milestone — dry-run: progress recompute + auto-close decision
out="$("$GP" update-milestone --dry-run --state "$FIX/milestone-issues.json" v1.0 --auto-close)"
echo "$out" | grep -q "progress: 2/5"    || fail "bad progress"
echo "$out" | grep -q "close milestone"   || fail "no auto-close signal"

echo "ALL SMOKE TESTS PASSED (offline, no auth, no gh)"
