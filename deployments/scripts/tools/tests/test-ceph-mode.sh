#!/bin/bash
# ============================================================
# test-ceph-mode.sh — CEPH_MODE 归一化 / legacy 映射 / 布尔归一化
#
# 背景(2026-11-20): Ceph 启停收敛为单一 CEPH_MODE(none|external|internal),
#   删除 CEPH_ENABLED/CEPH_CSI_ENABLED; 旧配置自动映射并告警; 值大小写不敏感。
#
# 覆盖:
#   ① ceph_norm_lower / ceph_norm_bool 大小写与布尔归一化
#   ② ceph_resolve_mode: 旧开关四种组合 + 显式 CEPH_MODE 优先 + 非法值失败
#   ③ load_config: CEPH_MODE=nOne 关闭子能力并回 local-path
#   ④ load_config: 旧开关映射为 internal 且旧变量被 unset
#
# 用法: bash deployments/scripts/tools/tests/test-ceph-mode.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$3] 实际[$2]"; fail=1; fi; }

run() {  # run <shell-code> → stdout
    ( set +u
      source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
      eval "$1" )
}

echo "== ① 归一化 =="
chk "None"   "$(run 'ceph_norm_lower " NOne "')" "none"
chk "TRUE"   "$(run 'ceph_norm_bool TRUE')" "true"
chk "Off"    "$(run 'ceph_norm_bool Off')" "false"
chk "yes"    "$(run 'ceph_norm_bool yes')" "true"
chk "1"      "$(run 'ceph_norm_bool 1')" "true"
chk "空值"   "$(run 'ceph_norm_bool ""')" "false"

echo "== ② legacy 映射 =="
chk "both true"      "$(run 'ceph_resolve_mode "" true true 0')" "internal"
chk "csi only"       "$(run 'ceph_resolve_mode "" false true 0')" "external"
chk "cluster only"   "$(run 'ceph_resolve_mode "" true false 0')" "internal"
chk "both false"     "$(run 'ceph_resolve_mode "" false false 0')" "none"
chk "explicit none"  "$(run 'ceph_resolve_mode "NOne" true true 1')" "none"
chk "explicit external uppercase" "$(run 'ceph_resolve_mode "EXTERNAL" true true 1')" "external"
chk "invalid fails"  "$(run 'if ceph_resolve_mode "bogus" "" "" 1; then echo ok; else echo bad; fi')" "bad"

echo "== ③ load_config: CEPH_MODE=nOne → 子开关关闭 + local-path =="
tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT
printf 'NODES=()\nCEPH_MODE=nOne\n' > "${tmp}/cluster.conf"
out="$( ( set +u
    CLUSTER_CONF="${tmp}/cluster.conf"
    CLUSTER_DEFAULTS_CONF="${REPO_ROOT}/deployments/config/cluster.defaults.conf"
    source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
    load_config >/dev/null 2>&1
    printf '%s|%s|%s|%s\n' "${CEPH_MODE}" "${CEPHFS_ENABLED}" "${LOCAL_PATH_ENABLED}" "${REGISTRY_STORAGE_CLASS}" ) )"
chk "mode none → 子开关关闭" "${out}" "none|false|true|local-path"

echo "== ④ load_config: 旧开关 → internal + unset =="
printf 'NODES=()\nCEPH_ENABLED=true\nCEPH_CSI_ENABLED=true\n' > "${tmp}/legacy.conf"
out="$( ( set +u
    CLUSTER_CONF="${tmp}/legacy.conf"
    CLUSTER_DEFAULTS_CONF="${REPO_ROOT}/deployments/config/cluster.defaults.conf"
    source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
    load_config >/dev/null 2>&1
    printf '%s|%s|%s\n' "${CEPH_MODE}" \
        "$([ -z "${CEPH_ENABLED+x}" ] && echo unset || echo set)" "${LOCAL_PATH_ENABLED}" ) )"
chk "legacy → internal 且旧变量 unset" "${out}" "internal|unset|false"

echo "== ⑤ load_config: CEPH_MODE=external → ceph-block =="
printf 'NODES=()\nCEPH_MODE=EXTERNAL\nCEPH_MONITORS="192.0.2.1:6789"\nCEPH_KEYRING="x"\n' > "${tmp}/ext.conf"
out="$( ( set +u
    CLUSTER_CONF="${tmp}/ext.conf"
    CLUSTER_DEFAULTS_CONF="${REPO_ROOT}/deployments/config/cluster.defaults.conf"
    source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
    load_config >/dev/null 2>&1
    printf '%s|%s|%s\n' "${CEPH_MODE}" "${REGISTRY_STORAGE_CLASS}" "${LOCAL_PATH_ENABLED}" ) )"
chk "external → ceph-block + local-path off" "${out}" "external|ceph-block|false"

echo "== ⑧ 默认 CEPH_MODE=internal(未写任何 Ceph 开关) =="
printf 'NODES=()\n' > "${tmp}/default.conf"
out="$( ( set +u
    CLUSTER_CONF="${tmp}/default.conf"
    CLUSTER_DEFAULTS_CONF="${REPO_ROOT}/deployments/config/cluster.defaults.conf"
    source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
    load_config >/dev/null 2>&1
    printf '%s|%s|%s\n' "${CEPH_MODE}" "${REGISTRY_STORAGE_CLASS}" "${LOCAL_PATH_ENABLED}" ) )"
chk "默认 internal → ceph-block + local-path off" "${out}" "internal|ceph-block|false"

exit "${fail}"
