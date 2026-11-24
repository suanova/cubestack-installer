#!/bin/bash
# ============================================================
# test-module-requires-skip.sh — --skip 不得留下"依赖已被跳过"的计划
# 背景(2026-11-24 实机): 全量部署时 --skip k8s_registry, 但 multus(REQUIRES:
#   k8s_deploy k8s_registry)仍留在计划里; multus 推镜像时 registry 未配置, 等待
#   60s 后失败, 部署在 multus 处中断。默认模式的 REQUIRES 只用于排序, 不校验
#   "被依赖模块是否真的在计划里"; 本测试钉住该计划期校验。
# 用法: bash deployments/scripts/tools/tests/test-module-requires-skip.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
# shellcheck source=../../lib-common.sh
source "${REPO_ROOT}/deployments/scripts/lib-common.sh"
# shellcheck source=../../lib-module.sh
source "${REPO_ROOT}/deployments/scripts/lib-module.sh"

TMP="$(mktemp -d -t cubestack-module-requires.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT
STATE_FILE="${TMP}/state"
: > "${STATE_FILE}"
export STATE_FILE

# 只打开本用例关心的开关; 其余默认关闭, 避免计划里出现无关的 REQUIRES 组合。
export MULTUS_ENABLED=true
export REGISTRY_ENABLED=1
export CEPH_MODE=none
export METALLB_ENABLED=false
export LOCAL_PATH_ENABLED=false
export GPU_OPERATOR_ENABLED=false
export NVIDIA_GPU_OPERATOR_ENABLED=false
export CUBESTACK_OPERATOR_ENABLED=false
export MODEL_IMAGES_ENABLED=false
export RDMA_SHARED_DEV_PLUGIN_ENABLED=false

fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$3] 实际[$2]"; fail=1; fi; }
contains() { if printf '%s' "$3" | grep -qF -- "$2"; then echo "  ok  $1"; else echo "  FAIL $1: 输出未包含 [$2]"; fail=1; fi; }

discover_modules >/dev/null 2>&1 || { echo "FAIL: discover_modules"; exit 1; }

run_resolve() {  # <steps> <skip> → OUT/RC (global RUN_STEPS 在本 shell 内更新)
    # 不能放在 $(...) 里: 命令替换是子 shell, resolve_run_steps 对 RUN_STEPS 的修改会丢失。
    resolve_run_steps "$1" "$2" "" "" >"${TMP}/resolve.out" 2>&1
    RC=$?
    OUT="$(cat "${TMP}/resolve.out")"
}
in_plan() { case " ${RUN_STEPS[*]:-} " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

echo "== ① 正常计划: multus 与 k8s_registry 都在 =="
run_resolve "" ""
chk "正常计划 exit 0" "${RC}" "0"
in_plan multus && echo "  ok  计划含 multus" || { echo "  FAIL 计划缺 multus"; fail=1; }
in_plan k8s_registry && echo "  ok  计划含 k8s_registry" || { echo "  FAIL 计划缺 k8s_registry"; fail=1; }

echo "== ② --skip k8s_registry 但保留 multus: 计划必须失败 =="
run_resolve "" "k8s_registry"
if [ "${RC}" -ne 0 ]; then echo "  ok  exit 非 0"; else echo "  FAIL exit=0(计划被静默接受)"; fail=1; fi
contains "错误点名 multus" "multus" "${OUT}"
contains "错误点名 k8s_registry" "k8s_registry" "${OUT}"
if in_plan multus; then echo "  FAIL multus 仍在计划中"; fail=1; else echo "  ok  multus 未被调度"; fi

echo "== ③ 显式 --skip pre_install_check 仍允许(k8s_deploy 的既定例外) =="
run_resolve "" "pre_install_check"
chk "skip pre_install_check exit 0" "${RC}" "0"

echo "== ④ 同时 skip multus,k8s_registry: 允许(依赖者也被排除) =="
run_resolve "" "multus,k8s_registry"
chk "skip both exit 0" "${RC}" "0"

echo "== ⑤ 可选基座依赖 local_path 被 skip: 仍允许(registry 可走 ceph-block/nodeport) =="
export LOCAL_PATH_ENABLED=true
run_resolve "" "local_path"
chk "skip local_path exit 0" "${RC}" "0"

echo "== ⑥ 依赖者已完成(done, REPEAT=0): 允许跳过其依赖 =="
printf 'multus=done\n' > "${STATE_FILE}"
run_resolve "" "k8s_registry"
chk "done multus + skip registry exit 0" "${RC}" "0"
: > "${STATE_FILE}"

echo "---------------------------------------------"
if [ "${fail}" = "0" ]; then
    echo "✅ test-module-requires-skip: 全部通过"
else
    echo "❌ test-module-requires-skip: 存在失败项"
fi
exit "${fail}"
