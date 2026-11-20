#!/bin/bash
# ============================================================
# test-k8s-registry-storage.sh — registry 的 Ceph StorageClass 前置检查(issue #206)
# 覆盖:
#   ① 后端 SC 不存在时立即失败, 并提示先跑 ceph_csi / 改 local-path
#   ② 检查发生在 deploy-registry.sh 之前(不先创建 PVC/不空等)
# 隔离: 静态断言模块文本; 不连集群
# 用法: bash deployments/scripts/tools/tests/test-k8s-registry-storage.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
MODULE="${REPO_ROOT}/deployments/scripts/modules/03_addon/05_k8s_registry.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  ok  $1"; else echo "  FAIL $1: [$3] 未包含 [$2]"; fail=1; fi; }

txt="$(cat "${MODULE}" 2>/dev/null)"
chk_contains "校验后端 StorageClass 存在" 'get storageclass "${REGISTRY_STORAGE_CLASS}"' "${MODULE}"
chk_contains "缺失时提示先跑 ceph_csi" '--steps ceph_csi' "${MODULE}"
chk_contains "给出 local-path 退路" 'REGISTRY_STORAGE_CLASS 改为 local-path' "${MODULE}"
chk_contains "已 Bound 的 PVC 跳过检查" '[ "${_reg_pvc_phase}" != "Bound" ]' "${MODULE}"

sc_line="$(printf '%s\n' "${txt}" | grep -n 'get storageclass "${REGISTRY_STORAGE_CLASS}"' | head -1 | cut -d: -f1)"
deploy_line="$(printf '%s\n' "${txt}" | grep -n '^[[:space:]]*bash .*deploy-registry\.sh' | head -1 | cut -d: -f1)"
init_line="$(printf '%s\n' "${txt}" | grep -n '^init_remote_kubectl' | head -1 | cut -d: -f1)"
chk "检查在 deploy-registry 之前" "1" "$([ -n "${sc_line}" ] && [ -n "${deploy_line}" ] && [ "${sc_line}" -lt "${deploy_line}" ] && echo 1 || echo 0)"
chk "检查在 init_remote_kubectl 之后" "1" "$([ -n "${sc_line}" ] && [ -n "${init_line}" ] && [ "${sc_line}" -gt "${init_line}" ] && echo 1 || echo 0)"

[ "${fail}" = "0" ] && echo "✅ test-k8s-registry-storage: 全部通过" || { echo "❌ 有失败项"; exit 1; }
