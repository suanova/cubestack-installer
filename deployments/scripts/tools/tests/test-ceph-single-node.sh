#!/bin/bash
# ============================================================
# test-ceph-single-node.sh — 单节点 Ceph 独立入口 + 共享引擎
#
# 覆盖:
#   ① 02_ceph.sh 在 CUBESTACK_CEPH_ENGINE_ONLY=1 时只定义函数, 不执行卸载/门禁/部署
#   ② 单节点脚本 CEPH_MODE=none → 跳过(rc0)
#   ③ 单节点脚本 CEPH_MODE=external → 跳过(rc0, 本脚本只管 internal)
#   ④ 单节点脚本 2 台存储节点 → 硬失败(rc1, 不进入 SSH)
#   ⑤ 02 模块入口包含单节点分发与 ceph_engine_uninstall 调用
#
# 用法: bash deployments/scripts/tools/tests/test-ceph-single-node.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
MOD="${REPO_ROOT}/deployments/scripts/modules/03_addon/02_ceph.sh"
SINGLE="${REPO_ROOT}/deployments/scripts/tools/k8s/ceph-single-node.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$3] 实际[$2]"; fail=1; fi; }

echo "== ① 引擎模式只定义函数 =="
out="$( ( set +u
    CLUSTER_CONF="${TMP}/none.conf"
    printf 'NODES=()\nCEPH_MODE=none\n' > "${TMP}/none.conf"
    export CUBESTACK_CEPH_ENGINE_ONLY=1
    source "${MOD}" >/dev/null 2>&1
    if declare -F ceph_engine_main >/dev/null && declare -F ceph_engine_uninstall >/dev/null; then echo funcs; else echo missing; fi
) 2>/dev/null )"
chk "ceph_engine_main/uninstall 已定义" "${out}" "funcs"

echo "== ② mode=none 跳过 =="
printf 'NODES=()\nCEPH_MODE=none\n' > "${TMP}/none.conf"
out="$(CLUSTER_CONF="${TMP}/none.conf" bash "${SINGLE}" 2>&1 || true)"
case "${out}" in *"跳过单节点 Ceph"*) echo "  ok  none 跳过" ;; *) echo "  FAIL none 未跳过: ${out}"; fail=1 ;; esac

echo "== ③ mode=external 跳过 =="
printf 'NODES=()\nCEPH_MODE=external\n' > "${TMP}/ext.conf"
out="$(CLUSTER_CONF="${TMP}/ext.conf" bash "${SINGLE}" 2>&1 || true)"
case "${out}" in *"不创建集群内 CephCluster"*) echo "  ok  external 跳过" ;; *) echo "  FAIL external 未跳过: ${out}"; fail=1 ;; esac

echo "== ④ 2 台存储节点硬失败 =="
cat > "${TMP}/two.conf" <<'EOF'
NODES=("master,n1,10.0.0.1,root,pw" "master,n2,10.0.0.2,root,pw")
CEPH_MODE=internal
CEPH_TOPOLOGY=auto
EOF
rc=0
out="$(CLUSTER_CONF="${TMP}/two.conf" bash "${SINGLE}" 2>&1)" || rc=$?
chk "2 节点 rc=1" "${rc}" "1"
case "${out}" in *"恰好 1 台"*) echo "  ok  错误信息" ;; *) echo "  FAIL 缺少错误信息: ${out}"; fail=1 ;; esac

echo "== ⑤ 02 入口分发 =="
grep -q 'ceph_engine_uninstall' "${MOD}" && echo "  ok  卸载函数调用" || { echo "  FAIL 缺卸载调用"; fail=1; }
grep -q 'ceph-single-node.sh' "${MOD}" && echo "  ok  单节点分发" || { echo "  FAIL 缺单节点分发"; fail=1; }
grep -q 'ceph_engine_main' "${SINGLE}" && echo "  ok  单脚本复用引擎" || { echo "  FAIL 单脚本未复用引擎"; fail=1; }
# 单脚本不得先 load_config(否则 defaults 值让 CEPH_EXPLICIT_* 误判为 1, 单节点 profile 失效)
if grep -qE '^load_config$' "${SINGLE}"; then
    echo "  FAIL 单脚本不应先调用 load_config"; fail=1
else
    echo "  ok  单脚本不在 source 引擎前重复 load_config"
fi

echo "== ⑥ 单节点 profile 不被 defaults 误判为显式覆盖 =="
printf 'NODES=("master,m1,10.0.0.1,root,-")\nSSH_USER=root\nKUBESPRAY_PROFILE=none\nCEPH_MODE=internal\n' > "${TMP}/single.conf"
out="$( ( set +u
    CLUSTER_CONF="${TMP}/single.conf"
    source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
    export CUBESTACK_CEPH_ENGINE_ONLY=1
    source "${MOD}" >/dev/null 2>&1
    ceph_apply_effective_spec single >/dev/null 2>&1
    printf '%s/%s/%s/%s/%s\n' "$CEPH_EFF_MON_COUNT" "$CEPH_EFF_MGR_COUNT" \
      "$CEPH_EFF_POOL_REPLICAS" "$CEPH_EFF_POOL_MIN_SIZE" "$CEPH_EFF_FAILURE_DOMAIN"
) 2>/dev/null )"
chk "single profile" "${out}" "1/1/1/1/osd"

exit "${fail}"
