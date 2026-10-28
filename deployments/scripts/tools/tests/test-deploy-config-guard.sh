#!/bin/bash
# ============================================================
# test-deploy-config-guard.sh — k8s_deploy 配置漂移门禁离线回归
# 覆盖:
#   ① config_fingerprint: 注释变更不触发, 变量变更触发
#   ② addons_metallb_enabled: true/false/missing
#   ③ k8s_deploy 模块包含倒计时后/部署后的配置漂移门禁
#   ④ metallb 模块包含 addons↔cluster.conf 不一致的显式报错与修复指引
# 隔离: 仅临时文件, 不连集群/不读真实配置.
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIB="${REPO_ROOT}/deployments/scripts/lib-common.sh"
K8S="${REPO_ROOT}/deployments/scripts/modules/02_k8s/06_k8s_deploy.sh"
METALLB="${REPO_ROOT}/deployments/scripts/modules/03_addon/01_metallb.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if [[ "$3" == *"$2"* ]]; then echo "  ok  $1"; else echo "  FAIL $1: 未包含 [$2]"; fail=1; fi; }

echo "== ① config_fingerprint =="
cat > "${TMP}/cluster.conf" <<'EOF'
SERVICE_EXPOSE_MODE="metallb"
METALLB_ENABLED="true"
METALLB_POOL="192.0.2.225-192.0.2.226"
EOF
fp1="$(CLUSTER_CONF="${TMP}/cluster.conf" bash -c 'source "$1" >/dev/null 2>&1; config_fingerprint' _ "${LIB}" 2>/dev/null)"
cat >> "${TMP}/cluster.conf" <<'EOF'
# comment-only change
EOF
fp2="$(CLUSTER_CONF="${TMP}/cluster.conf" bash -c 'source "$1" >/dev/null 2>&1; config_fingerprint' _ "${LIB}" 2>/dev/null)"
sed -i 's/^SERVICE_EXPOSE_MODE=.*/SERVICE_EXPOSE_MODE="nodeport"/' "${TMP}/cluster.conf"
fp3="$(CLUSTER_CONF="${TMP}/cluster.conf" bash -c 'source "$1" >/dev/null 2>&1; config_fingerprint' _ "${LIB}" 2>/dev/null)"
chk "注释变更不影响 fingerprint" "${fp1}" "${fp2}"
chk "变量变更改变 fingerprint" "1" "$([ "${fp1}" != "${fp3}" ] && echo 1 || echo 0)"

echo "== ② addons_metallb_enabled =="
cat > "${TMP}/addons.yml" <<'EOF'
metallb_enabled: true
metallb_speaker_enabled: true
EOF
chk "enabled=true" "true" "$(bash -c 'source "$1" >/dev/null 2>&1; addons_metallb_enabled "$2"' _ "${LIB}" "${TMP}/addons.yml" 2>/dev/null)"
sed -i 's/^metallb_enabled:.*/metallb_enabled: false/' "${TMP}/addons.yml"
chk "enabled=false" "false" "$(bash -c 'source "$1" >/dev/null 2>&1; addons_metallb_enabled "$2"' _ "${LIB}" "${TMP}/addons.yml" 2>/dev/null)"
chk "missing file" "missing" "$(bash -c 'source "$1" >/dev/null 2>&1; addons_metallb_enabled "$2"' _ "${LIB}" "${TMP}/no-such.yml" 2>/dev/null)"

echo "== ③ k8s_deploy 配置漂移门禁 =="
k8s_txt="$(cat "${K8S}" 2>/dev/null)"
chk_contains "记录启动指纹" "_CONF_FP_START" "${k8s_txt}"
chk_contains "倒计时后/部署后调用门禁" "_conf_guard" "${k8s_txt}"
chk "门禁至少 3 处(定义+2 调用)" "1" "$([ "$(printf '%s' "${k8s_txt}" | command grep -c '_conf_guard')" -ge 3 ] && echo 1 || echo 0)"
chk_contains "中止提示重跑 k8s_deploy" "steps k8s_deploy --fresh" "${k8s_txt}"

echo "== ④ metallb addons 一致性门禁 =="
mb_txt="$(cat "${METALLB}" 2>/dev/null)"
chk_contains "使用 addons_metallb_enabled" "addons_metallb_enabled" "${mb_txt}"
chk_contains "显式说明配置漂移根因" "addons.yml" "${mb_txt}"
chk_contains "给出 gen-inventory 修复命令" "gen-inventory.sh" "${mb_txt}"
chk_contains "给出 k8s_deploy 重跑命令" "steps k8s_deploy --fresh" "${mb_txt}"

echo "== ⑤ VM 网段提示条件(2026-10-26) =="
chk_contains "VM 提示受 create-vms.sh 注释保护" "command grep -qF '由 create-vms.sh 自动推导'" "${k8s_txt}"

echo ""
if [ "${fail}" = "0" ]; then echo "✅ test-deploy-config-guard: 全部通过"; else echo "❌ test-deploy-config-guard: 有失败"; fi
exit "${fail}"
