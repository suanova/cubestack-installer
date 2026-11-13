#!/bin/bash
# ============================================================
# test-module-provenance.sh — 模块来源判定与列表展示回归
# 背景: installer 是 public 的。它的 --list-steps 曾无条件打印一组硬编码的
#   "平台组件级更新"模块名(cubepilot / cuberouter / …), 而公共版本里这些模块
#   根本不存在 —— 开源用户照着敲 --steps 只会得到"未知模块"。
# 现在改为按**模块来源**判定: 来自版本树附带目录(CUBESTACK_EXTRA_MODULES_DIRS
#   软链进合并根)的、addon 阶段、无 TOGGLE、非 verify 的模块才算。
#   断言用中性假模块名, 不引用任何真实组件名。
# 用法: bash deployments/scripts/tools/tests/test-module-provenance.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIB_COMMON="${REPO_ROOT}/deployments/scripts/lib-common.sh"
LIB_MODULE="${REPO_ROOT}/deployments/scripts/lib-module.sh"
DEPLOY="${REPO_ROOT}/deployments/scripts/deploy-cluster.sh"
TMP="$(mktemp -d)"
_cleanup_merged() {
    find "${REPO_ROOT}/deployments/scripts" -maxdepth 1 -type d \
        -name '.modules-merged.*' -exec rm -rf {} + 2>/dev/null || true
}
trap '_cleanup_merged; rm -rf "${TMP}"' EXIT
_cleanup_merged
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_empty() { if [ -z "$2" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望空, 实际[$2]"; fail=1; fi; }
chk_nonempty() { if [ -n "$2" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望非空"; fail=1; fi; }

printf 'NODES=()\nSSH_USER="root"\nKUBESPRAY_PROFILE="none"\n' > "${TMP}/cluster.conf"

# 中性假模块: 三种都应出现在"组件级更新"里(无 TOGGLE / addon / 非 verify)
mkdir -p "${TMP}/tree/1.0.0/offline-files" "${TMP}/tree/1.0.0/modules/03_addon"
printf 'RELEASE_VERSION=1.0.0\nKUBESPRAY_VERSION=v2.32.0\n' > "${TMP}/tree/1.0.0/offline-files/release.env"
M="${TMP}/tree/1.0.0/modules/03_addon"
for n in alpha beta; do
    printf '#!/bin/bash\n# MODULE: %s\n# DESC: fake\n# PHASE: addon\n# DEFAULT: 0\n' "${n}" > "${M}/90_fake_${n}.sh"
done
# 有 TOGGLE 的: 应进主列表, 不进"组件级更新"
printf '#!/bin/bash\n# MODULE: gamma\n# DESC: fake operator\n# PHASE: addon\n# TOGGLE: GAMMA_ENABLED\n' > "${M}/25_fake_gamma.sh"
# verify_*: 应进"验证模块"段, 不进"组件级更新"
printf '#!/bin/bash\n# MODULE: verify_gamma\n# DESC: fake verify\n# PHASE: addon\n' > "${M}/26_verify_fake_gamma.sh"

_comp_keys_of() {  # <额外参数...> —— 打印 _component_update_keys 的结果
    bash -c '
      source "$1" >/dev/null 2>&1; source "$2"
      CLUSTER_CONF="$3"; CUBESTACK_RELEASE=1.0.0; CUBESTACK_RELEASE_ROOT="$4"
      load_config >/dev/null 2>&1
      cs_merge_modules_dirs; discover_modules
      _component_update_keys | tr "\n" " "
    ' _ "${LIB_COMMON}" "${LIB_MODULE}" "${TMP}/cluster.conf" "${TMP}/tree" 2>/dev/null
}

echo "== ① 无额外目录(公共形态): 组件级更新集合为空 =="
out="$(bash -c '
  source "$1" >/dev/null 2>&1; source "$2"; discover_modules
  _component_update_keys | tr "\n" " "
' _ "${LIB_COMMON}" "${LIB_MODULE}" 2>/dev/null)"
chk_empty "公共 installer 没有组件级更新模块" "${out}"

echo "== ② 版本树附带模块: 只收 addon+无TOGGLE+非verify =="
out="$(_comp_keys_of)"
chk "收集到的模块" "alpha beta " "$(printf '%s' "${out}" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/^ *//' | tr -s ' ')"
case "${out}" in *gamma*) echo "  FAIL 有 TOGGLE 的模块不应进组件级更新"; fail=1 ;; *) echo "  ok  有 TOGGLE 的模块不在组件级更新里" ;; esac
case "${out}" in *verify_*) echo "  FAIL verify_* 不应进组件级更新"; fail=1 ;; *) echo "  ok  verify_* 不在组件级更新里" ;; esac

echo "== ③ 合并根重建后仍能正确判定来源(第二次 merge) =="
out="$(bash -c '
  source "$1" >/dev/null 2>&1; source "$2"
  CLUSTER_CONF="$3"; CUBESTACK_RELEASE=1.0.0; CUBESTACK_RELEASE_ROOT="$4"
  load_config >/dev/null 2>&1
  cs_merge_modules_dirs; discover_modules
  first="$(_component_update_keys | tr "\n" " ")"
  cs_merge_modules_dirs; discover_modules
  second="$(_component_update_keys | tr "\n" " ")"
  [ "${first}" = "${second}" ] && printf "%s" "${second}" || printf "DRIFT[%s|%s]" "${first}" "${second}"
' _ "${LIB_COMMON}" "${LIB_MODULE}" "${TMP}/cluster.conf" "${TMP}/tree" 2>/dev/null)"
chk "重复合并结果稳定" "alpha beta " "$(printf '%s' "${out}" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/^ *//' | tr -s ' ')"

echo "== ④ --list-steps 不再打印公共版没有的组件名 =="
public_out="$(CLUSTER_CONF="${TMP}/cluster.conf" bash "${DEPLOY}" --list-steps 2>&1)"
if printf '%s' "${public_out}" | grep -qF "平台组件级更新"; then
    echo "  FAIL 公共版不应出现组件级更新段"; fail=1
else
    echo "  ok  公共版没有组件级更新段"
fi
if printf '%s' "${public_out}" | grep -qF "alpha"; then
    echo "  FAIL 公共版不应出现版本树模块名"; fail=1
else
    echo "  ok  公共版没有版本树模块名"
fi

private_out="$(CLUSTER_CONF="${TMP}/cluster.conf" CUBESTACK_RELEASE_ROOT="${TMP}/tree" \
    bash "${DEPLOY}" --release 1.0.0 --list-steps 2>&1)"
if printf '%s' "${private_out}" | grep -qF "平台组件级更新"; then
    echo "  ok  版本树模式出现组件级更新段"
else
    echo "  FAIL 版本树模式缺少组件级更新段"; fail=1
fi
for n in alpha beta; do
    if printf '%s' "${private_out}" | sed -n '/平台组件级更新/,/验证模块/p' | grep -qF "${n}"; then
        echo "  ok  组件级更新段含 ${n}"
    else
        echo "  FAIL 组件级更新段缺 ${n}"; fail=1
    fi
done
if printf '%s' "${private_out}" | sed -n '/平台组件级更新/,/验证模块/p' | grep -qF "gamma"; then
    echo "  FAIL gamma(有 TOGGLE)不应在组件级更新段"; fail=1
else
    echo "  ok  gamma 不在组件级更新段"
fi

echo "== ⑤ --list-steps --verbose 与紧凑模式口径一致 =="
verbose_out="$(CLUSTER_CONF="${TMP}/cluster.conf" CUBESTACK_RELEASE_ROOT="${TMP}/tree" \
    bash "${DEPLOY}" --release 1.0.0 --list-steps --verbose 2>&1)"
for n in alpha beta; do
    if printf '%s' "${verbose_out}" | sed -n '/平台组件级更新/,/验证模块/p' | grep -qF "${n}"; then
        echo "  ok  verbose 组件段含 ${n}"
    else
        echo "  FAIL verbose 组件段缺 ${n}"; fail=1
    fi
done

echo "---------------------------------------------"
if [ "${fail}" = "0" ]; then echo "✅ test-module-provenance: 全部通过"; else echo "❌ test-module-provenance: 存在失败项"; exit 1; fi
