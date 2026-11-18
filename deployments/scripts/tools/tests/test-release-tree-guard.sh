#!/bin/bash
# ============================================================
# test-release-tree-guard.sh — installer 不再解包 full package
#
# 覆盖:
#   ① 已组装的版本树(offline-files/release.env)通过
#   ② 只有 meta tar 的 full package 直接失败, 并提示 fetch-offline.sh
#   ③ 既无 meta 也无 release.env 的目录交给后续现有检查
# ============================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
GUARD="${ROOT}/deployments/scripts/tools/offline/check-release-tree.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if [[ "$3" == *"$2"* ]]; then echo "  ok  $1"; else echo "  FAIL $1: 未包含 [$2]"; fail=1; fi; }

mkdir -p "${TMP}/good/2.1.0/offline-files"
printf 'RELEASE_VERSION=2.1.0\n' > "${TMP}/good/2.1.0/offline-files/release.env"
: > "${TMP}/good/2.1.0/cubestack-2.1.0.meta.tar.zst"
echo "== ① 已组装版本树(保留 meta) =="
if out="$(bash "${GUARD}" "${TMP}/good" "2.1.0" 2>&1)"; then rc=0; else rc=$?; fi
chk "退出码" "0" "${rc}"

echo "== ② 未组装 full package =="
mkdir -p "${TMP}/bad/2.1.0"
: > "${TMP}/bad/2.1.0/cubestack-2.1.0.meta.tar.zst"
if out="$(bash "${GUARD}" "${TMP}/bad" "2.1.0" 2>&1)"; then rc=0; else rc=$?; fi
chk "退出码" "3" "${rc}"
chk_contains "提示 fetch-offline.sh" "fetch-offline.sh" "${out}"
chk_contains "给出 package-dir" "--package-dir" "${out}"

echo "== ③ 普通目录 =="
mkdir -p "${TMP}/plain/2.1.0"
if out="$(bash "${GUARD}" "${TMP}/plain" "2.1.0" 2>&1)"; then rc=0; else rc=$?; fi
chk "退出码" "0" "${rc}"

echo "== ④ 非法版本名 =="
if out="$(bash "${GUARD}" "${TMP}/plain" ".." 2>&1)"; then rc=0; else rc=$?; fi
chk "退出码" "2" "${rc}"
chk_contains "提示非法版本" "invalid release version" "${out}"

if [ "${fail}" = "0" ]; then
    echo "✅ test-release-tree-guard: 全部通过"
else
    echo "❌ test-release-tree-guard: 存在失败项"
    exit 1
fi
