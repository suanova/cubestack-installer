#!/bin/bash
# ============================================================
# test-ceph-fallback.sh — Ceph 安装条件探测 + 默认回退 local-path
#
# 覆盖:
#   ① external: external-ceph.env 完整 → 具备; 缺失 → 不满足
#   ② internal: 1 节点 + 显式 CEPH_DATA_DISKS → 具备(single)
#   ③ internal: 2 节点 auto 拓扑 → 不满足
#   ④ ceph_apply_fallback_decision: 条件不足 → 10 + CEPH_MODE=none + local-path
#   ⑤ fallback=false: 条件不足 → 1 且不改配置
#   ⑥ CEPH_MODE=none: 直接 0, 不探测
#
# 用法: bash deployments/scripts/tools/tests/test-ceph-fallback.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$3] 实际[$2]"; fail=1; fi; }

run() {  # run <shell-code>
    ( set +u
      source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
      eval "$1" )
}

echo "== ① external env =="
cat > "${TMP}/external-ceph.env" <<'EOF'
ROOK_EXTERNAL_FSID=abc
ROOK_EXTERNAL_CEPH_MON_DATA=a=192.0.2.1:6789
ROOK_EXTERNAL_USERNAME=client.admin
ROOK_EXTERNAL_USER_SECRET=xyz
EOF
chk "env 完整" "$(run "CEPH_MODE=external CEPH_EXTERNAL_ENV_FILE='${TMP}/external-ceph.env' ceph_installable_check >/dev/null 2>&1; echo \$?")" "0"
chk "env 缺失" "$(run "CEPH_MODE=external CEPH_EXTERNAL_ENV_FILE='${TMP}/missing.env' CEPH_MONITORS= ceph_installable_check >/dev/null 2>&1; echo \$?")" "1"
chk "手填完整" "$(run "CEPH_MODE=external CEPH_EXTERNAL_ENV_FILE='${TMP}/missing.env' CEPH_MONITORS='192.0.2.1:6789' CEPH_USER=admin CEPH_KEYRING=k ceph_installable_check >/dev/null 2>&1; echo \$?")" "0"

echo "== ② internal 单节点显式磁盘 =="
chk "1 节点具备" "$(run "ceph_preflight_node_ssh() { case \"\$2\" in *df*) echo 104857600 ;; *) return 0 ;; esac; }; NODES=('master,n1,10.0.0.1,root,pw'); CEPH_MODE=internal CEPH_TOPOLOGY=auto CEPH_MIN_NODES=3 CEPH_DATA_DISKS='n1:/dev/vdb'; ceph_installable_check --probe >/dev/null 2>&1; echo \$?")" "0"

echo "== ③ internal 2 节点 auto → 不满足 =="
chk "2 节点不满足" "$(run "NODES=('master,n1,10.0.0.1,root,pw' 'master,n2,10.0.0.2,root,pw'); CEPH_MODE=internal CEPH_TOPOLOGY=auto CEPH_MIN_NODES=3 CEPH_DATA_DISKS='n1:/dev/vdb;n2:/dev/vdb'; ceph_installable_check >/dev/null 2>&1; echo \$?")" "1"

echo "== ④ 回退 =="
out="$(run '
    ceph_installable_check() { echo "未检测到空闲裸盘"; return 1; }
    CEPH_MODE=internal CEPH_FALLBACK_TO_LOCALPATH=true
    ceph_apply_fallback_decision >/dev/null 2>&1
    printf "%s|%s|%s|%s\n" "$?" "${CEPH_MODE}" "${REGISTRY_STORAGE_CLASS}" "${LOCAL_PATH_ENABLED}"')"
chk "回退 → 10 + none/local-path/true" "${out}" "10|none|local-path|true"

echo "== ⑤ fallback=false 硬失败 =="
out="$(run '
    ceph_installable_check() { echo "未检测到空闲裸盘"; return 1; }
    CEPH_MODE=internal CEPH_FALLBACK_TO_LOCALPATH=false
    ceph_apply_fallback_decision >/dev/null 2>&1
    printf "%s|%s\n" "$?" "${CEPH_MODE}"')"
chk "硬失败 → 1 且 mode 不变" "${out}" "1|internal"

echo "== ⑥ CEPH_MODE=none 不探测 =="
out="$(run '
    ceph_installable_check() { echo "SHOULD-NOT-RUN"; return 1; }
    CEPH_MODE=none CEPH_FALLBACK_TO_LOCALPATH=true
    ceph_apply_fallback_decision >/dev/null 2>&1
    printf "%s|%s\n" "$?" "${CEPH_MODE}"')"
chk "none → 0" "${out}" "0|none"

echo "== ⑦ 回退标志跨子模块传播(字面量配置也强制 none/local-path) =="
cat > "${TMP}/literal.conf" <<'EOF'
NODES=()
CEPH_MODE="internal"
LOCAL_PATH_ENABLED="false"
REGISTRY_STORAGE_CLASS="ceph-block"
EOF
out="$( ( set +u
    CLUSTER_CONF="${TMP}/literal.conf"
    CLUSTER_DEFAULTS_CONF="${REPO_ROOT}/deployments/config/cluster.defaults.conf"
    export CUBESTACK_CEPH_FALLBACK=1
    source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
    load_config >/dev/null 2>&1
    printf "%s|%s|%s\n" "${CEPH_MODE}" "${REGISTRY_STORAGE_CLASS}" "${LOCAL_PATH_ENABLED}" ) )"
chk "fallback 强制 none/local-path/true" "${out}" "none|local-path|true"

exit "${fail}"
