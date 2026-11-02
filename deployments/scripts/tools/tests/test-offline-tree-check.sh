#!/bin/bash
# ============================================================
# test-offline-tree-check.sh — tree.tar.gz 边车校验最小回归
# 用法: bash deployments/scripts/tools/tests/test-offline-tree-check.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
OFFLINE="${REPO_ROOT}/deployments/kubespray/cubestack-offline.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }

# 提取函数(脚本末尾有 COMMAND case, 不能直接 source)
awk '/^verify_tree_tar_sidecar\(\)/,/^}/' "${OFFLINE}" > "${TMP}/fn.sh"
chk "函数可提取" "1" "$([ -s "${TMP}/fn.sh" ] && echo 1 || echo 0)"

warn() { :; }
log()  { :; }
err()  { echo "$*" >&2; return 1; }
# shellcheck disable=SC1090
source "${TMP}/fn.sh"

mkdir -p "${TMP}/kubespray/v9.9.9/images"
printf 'x' > "${TMP}/kubespray/v9.9.9/images/a.tar"
mkdir -p "${TMP}/src/kubespray"
printf 'y' > "${TMP}/src/kubespray/f"
tar -C "${TMP}/src" -czf "${TMP}/kubespray/v9.9.9/tree.tar.gz" kubespray
printf '%s\n' "$(sha256sum "${TMP}/kubespray/v9.9.9/tree.tar.gz" | awk '{print $1}')" \
    > "${TMP}/kubespray/v9.9.9/tree.tar.gz.sha256"

chk "边车一致通过" "0" "$(verify_tree_tar_sidecar "${TMP}/kubespray/v9.9.9" >/dev/null 2>&1; echo $?)"
printf 'deadbeef\n' > "${TMP}/kubespray/v9.9.9/tree.tar.gz.sha256"
chk "边车不符失败" "1" "$(verify_tree_tar_sidecar "${TMP}/kubespray/v9.9.9" >/dev/null 2>&1; echo $?)"
rm -f "${TMP}/kubespray/v9.9.9/tree.tar.gz.sha256"
chk "缺边车只警告" "0" "$(verify_tree_tar_sidecar "${TMP}/kubespray/v9.9.9" >/dev/null 2>&1; echo $?)"

echo "---------------------------------------------"
if [ "${fail}" = "0" ]; then
    echo "✅ tree.tar.gz 边车回归通过"
    exit 0
else
    echo "❌ 回归失败"
    exit 1
fi
