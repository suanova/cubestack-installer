#!/bin/bash
# 桩式单元测试: kubespray 版本选择(不连集群、不联网、不碰真 offline-files)
#   · 变量推导: KUBESPRAY_VERSION → OFFLINE_FILES_DIR / LOCAL_REPO_DIR / 运行根 / 树
#   · 档案优先级与逃生阀(见 docs/kubespray-versioning/design.md §3.2)
# 设计: docs/kubespray-versioning/plan.md Task 1–4
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

fail=0
chk() { # chk <描述> <期望> <实际>
    if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi
}

# 用桩 cluster.conf 跑一次 load_config, 打印关心的变量(每行 KEY=VALUE)
_conf() { printf '%s\n' "$@"; }
_probe() { # _probe <cluster.conf 行...> —— 输出 KEY=VALUE 行
    # 调用者若用 `VAR=值 _probe …` 显式给了 OFFLINE_FILES_DIR/ROOT(即"显式设置"场景),
    # 这里原样保留;其余版本面变量一律清空, 保证断言不受调用者环境干扰。
    local _pre_offline="${OFFLINE_FILES_DIR:-}" _pre_root="${OFFLINE_FILES_ROOT:-}"
    local c; c="$(mktemp)"
    _conf "$@" > "${c}"
    ( set +u
      export CLUSTER_CONF="${c}"
      export OFFLINE_FILES_ROOT="${_pre_root}" KUBESPRAY_VERSION="" OFFLINE_FILES_DIR="${_pre_offline}" \
             LOCAL_REPO_DIR="" KUBESPRAY_BASE_DIR="" KUBESPRAY_PROFILE=""
      source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
      load_config >/dev/null 2>&1
      printf 'OFFLINE_FILES_ROOT=%s\nKUBESPRAY_VERSION=%s\nOFFLINE_FILES_DIR=%s\nLOCAL_REPO_DIR=%s\nKUBESPRAY_BASE_DIR=%s\n' \
        "${OFFLINE_FILES_ROOT}" "${KUBESPRAY_VERSION}" "${OFFLINE_FILES_DIR}" "${LOCAL_REPO_DIR}" \
        "${KUBESPRAY_BASE_DIR}" )
    rm -f "${c}"
}
_val() { printf '%s\n' "$1" | awk -F= -v k="$2" '$1==k {sub(/^[^=]*=/,""); print; exit}'; }

NODES_CONF='NODES=("master,m1,10.0.0.1,ubuntu,p")'
TREE_VER="$(awk '/^version:/{print "v"$2; exit}' "${REPO_ROOT}/deployments/kubespray/kubespray/galaxy.yml")"

echo "== ① 默认版本 = 仓库当前树版本(galaxy.yml 机械派生) =="
out="$(_probe "${NODES_CONF}" 'REPO_ROOT_FAKE=1')"
chk "KUBESPRAY_VERSION = 树版本 ${TREE_VER}" "${TREE_VER}" "$(_val "${out}" KUBESPRAY_VERSION)"

echo "== ② 资产目录 = <root>/kubespray/<版本>, 且 LOCAL_REPO_DIR == 资产目录 =="
chk "OFFLINE_FILES_ROOT" "${REPO_ROOT}/deployments/offline-files" "$(_val "${out}" OFFLINE_FILES_ROOT)"
chk "OFFLINE_FILES_DIR 带版本层" \
    "${REPO_ROOT}/deployments/offline-files/kubespray/${TREE_VER}" "$(_val "${out}" OFFLINE_FILES_DIR)"
chk "LOCAL_REPO_DIR == OFFLINE_FILES_DIR" "$(_val "${out}" OFFLINE_FILES_DIR)" "$(_val "${out}" LOCAL_REPO_DIR)"
chk "KUBESPRAY_BASE_DIR = 仓库根(树版本一致时)" \
    "${REPO_ROOT}/deployments/kubespray" "$(_val "${out}" KUBESPRAY_BASE_DIR)"

echo "== ③ 不再有 CLUSTER_NAME 幽灵层 =="
case "$(_val "${out}" LOCAL_REPO_DIR)" in
    *cubestack-cluster*) chk "LOCAL_REPO_DIR 不含集群名" "无" "$(_val "${out}" LOCAL_REPO_DIR)" ;;
    *) chk "LOCAL_REPO_DIR 不含集群名" "无" "无" ;;
esac

echo "== ④ 显式 OFFLINE_FILES_DIR 最高优先(运维/容器挂载场景) =="
out2="$(OFFLINE_FILES_DIR=/mnt/big/offline-files/kubespray/vX _probe "${NODES_CONF}" 'X=1')"
chk "显式值不被覆盖" "/mnt/big/offline-files/kubespray/vX" "$(_val "${out2}" OFFLINE_FILES_DIR)"

if [ "${fail}" = "0" ]; then echo "== 全部通过 =="; else echo "== 有失败项 =="; fi
exit "${fail}"
