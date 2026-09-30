#!/bin/bash
# 桩式单元测试: kubespray 版本选择(不连集群、不联网、不碰真 offline-files)
#   · 变量推导: KUBESPRAY_VERSION → OFFLINE_FILES_DIR / LOCAL_REPO_DIR / 运行根 / 树
#   · 档案优先级与逃生阀(见 docs/kubespray-versioning/design.md §3.2)
# 设计: docs/kubespray-versioning/plan.md Task 1–4
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

# 密闭基线: 清掉调用者环境里的版本面变量 —— check-modules ⑱ 的反证会用
# OFFLINE_FILES_ROOT=<fixture> 跑整支脚本, 该变量会漏进这里, 把"默认值"类断言打红。
# (用例需要"显式设置"时, 由该用例自己传, 不靠外部环境 —— 见 ④ 的 `VAR=值 _probe …`。)
unset OFFLINE_FILES_ROOT OFFLINE_FILES_DIR LOCAL_REPO_DIR KUBESPRAY_VERSION \
      KUBESPRAY_BASE_DIR KUBESPRAY_PROFILE

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

echo "== ⑤ cubestack-offline.sh paths: 版本根 → 资产目录/树 推导正确(不靠目录名判定) =="
_offline_paths() { # _offline_paths <BASE_DIR>
    ( set +u; export CUBESTACK_BASE_DIR="$1" CLUSTER_CONF=/nonexistent \
        KUBESPRAY_VERSION="" OFFLINE_FILES_ROOT="" OFFLINE_FILES_DIR="" LOCAL_REPO_DIR=""
      bash "${REPO_ROOT}/deployments/kubespray/cubestack-offline.sh" paths 2>/dev/null )
}
_fix="$(mktemp -d)"; mkdir -p "${_fix}/kubespray" "${_fix}/inventory"
# 物化树要能派生版本: 放一份 galaxy.yml 模拟 versions/<V>/kubespray 的树版本
printf 'version: 9.9.9\n' > "${_fix}/kubespray/galaxy.yml"
out3="$(_offline_paths "${_fix}")"
chk "BASE_DIR=版本根 → KUBESPRAY_DIR 在其下" "${_fix}/kubespray" "$(_val "${out3}" KUBESPRAY_DIR)"
chk "OFFLINE_LAYOUT=repo(不再看父目录名)" "repo" "$(_val "${out3}" OFFLINE_LAYOUT)"
chk "版本从树 galaxy.yml 派生(物化树场景)" "v9.9.9" \
    "$(printf '%s\n' "$(_val "${out3}" OFFLINE_FILES_DIR)" | sed 's#.*/kubespray/##')"
chk "OFFLINE_FILES_ROOT 仍指向仓库 offline-files" \
    "${REPO_ROOT}/deployments/offline-files" "$(_val "${out3}" OFFLINE_FILES_ROOT)"
rm -rf "${_fix}"

echo "== ⑥ 档案: 选定档案接管版本面; none = 不用档案; 缺档案 = 响亮失败 =="
_probe_prof() { # _probe_prof <档案名> <额外 conf 行...>
    local p="$1"; shift
    local c; c="$(mktemp)"
    _conf "$@" > "${c}"
    ( set +u
      export CLUSTER_CONF="${c}" KUBESPRAY_PROFILE="${p}"
      export OFFLINE_FILES_ROOT="" KUBESPRAY_VERSION="" OFFLINE_FILES_DIR="" LOCAL_REPO_DIR=""
      source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
      load_config >/dev/null 2>&1
      printf 'KUBESPRAY_PROFILE=%s\nK8S_VERSION=%s\n' "${KUBESPRAY_PROFILE}" "${K8S_VERSION:-}" )
    rm -f "${c}"
}
# ⑥a 选了在库档案 → 其 K8S_VERSION 生效(cluster.conf 里同名变量的默认不得覆盖)
_prof_val="$(awk -F= '/^K8S_VERSION=/{sub(/^[^=]*=/,""); print; exit}' \
    "${REPO_ROOT}/deployments/config/profiles/v2.32.0.profile")"
outp="$(_probe_prof v2.32.0 "${NODES_CONF}" 'K8S_VERSION="${K8S_VERSION:-v9.9.9}"')"
chk "档案接管 K8S_VERSION(期望 ${_prof_val})" "${_prof_val}" "$(_val "${outp}" K8S_VERSION)"
# ⑥b KUBESPRAY_PROFILE=none → 完全按 cluster.conf
outn="$(_probe_prof none "${NODES_CONF}" 'K8S_VERSION="${K8S_VERSION:-v9.9.9}"')"
chk "none 时用 cluster.conf 值" "v9.9.9" "$(_val "${outn}" K8S_VERSION)"
# ⑥c 选了不存在的档案 → rc!=0(不得静默继续)
( set +u; c="$(mktemp)"; _conf "${NODES_CONF}" > "${c}"
  export CLUSTER_CONF="${c}" KUBESPRAY_PROFILE=v9.9.9
  source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
  load_config ) >/dev/null 2>&1
rc=$?
chk "缺档案 → 非零退出" 1 "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"

echo "== ⑦ version-dir: list/verify 对 fixture 版本目录的行为 =="
_ro="$(mktemp -d)"; _vd="${_ro}/kubespray/v9.9.9"
mkdir -p "${_vd}/images" "${_vd}/packages"
printf 'LOCAL_ONLY\n' > "${_vd}/LOCAL_ONLY"
printf 'KUBESPRAY_VERSION=v9.9.9\n' > "${_vd}/VERSION.profile"
vout="$(OFFLINE_FILES_ROOT="${_ro}" bash "${REPO_ROOT}/deployments/kubespray/cubestack-version-dir.sh" list 2>&1)"
printf '%s\n' "${vout}" | grep -q 'v9.9.9' && chk "list 找到 fixture 版本" 1 1 || chk "list 找到 fixture 版本" 1 0
printf '%s\n' "${vout}" | grep -q '本地临时' && chk "list 标注本地临时档位" 1 1 || chk "list 标注本地临时档位" 1 0
rc=0
OFFLINE_FILES_ROOT="${_ro}" bash "${REPO_ROOT}/deployments/kubespray/cubestack-version-dir.sh" verify v9.9.9 >/dev/null 2>&1 || rc=$?
chk "verify 对残缺版本目录 → 非零(缺 tree.tar.gz)" 1 "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
rc=0
OFFLINE_FILES_ROOT="${_ro}" bash "${REPO_ROOT}/deployments/kubespray/cubestack-version-dir.sh" verify >/dev/null 2>&1 || rc=$?
chk "verify 缺参数 → rc=2" 2 "${rc}"
rm -rf "${_ro}"

echo "== ⑧ version-dir new: 预验证(补丁不在位必须拒收)+ 档案骨架机械推导 =="
_src="$(mktemp -d)"; mkdir -p "${_src}/kubespray/roles/kubespray_defaults/defaults/main" \
                          "${_src}/kubespray/roles/kubespray_defaults/vars/main"
printf 'version: 9.9.9\n' > "${_src}/kubespray/galaxy.yml"
# 最小树表(形状与真树一致, 值用 9.9.x 合成):
cat > "${_src}/kubespray/roles/kubespray_defaults/defaults/main/download.yml" <<'YML'
nodelocaldns_version: "1.25.0"
metrics_server_version: v0.9.0
dnsautoscaler_version: v1.10.3
nginx_image_tag: 1.30.1-alpine
local_volume_provisioner_version: 2.5.0
node_feature_discovery_version: 0.19.0
coredns_supported_versions:
  '9.9': v9.9.9
YML
cat > "${_src}/kubespray/roles/kubespray_defaults/vars/main/checksums.yml" <<'YML'
# ⚠ 形状必须与真树一致: <表>: → <arch>: → <版本>: <sha>(版本在 arch 之下)
kubelet_checksums:
  amd64:
    9.9.9: sha256:abc
calicoctl_binary_checksums:
  amd64:
    9.9.9: sha256:abc
etcd_binary_checksums:
  amd64:
    9.9.9: sha256:abc
YML
cat > "${_src}/kubespray/roles/kubespray_defaults/vars/main/main.yml" <<'YML'
pod_infra_supported_versions:
  '9.9': 9.9.9
etcd_supported_versions:
  '9.9': "select('version', '9.9.999', version)"
YML
printf '#!/bin/bash\n[ "${1:-}" = "--check" ] && exit 0\nexit 0\n' > "${_src}/cubestack-patch-apply.sh"; chmod +x "${_src}/cubestack-patch-apply.sh"
_ro2="$(mktemp -d)"
_vd2=(OFFLINE_FILES_ROOT="${_ro2}")
env "${_vd2[@]}" bash "${REPO_ROOT}/deployments/kubespray/cubestack-version-dir.sh" \
    new v9.9.9 --from-root "${_src}" --local --k8s-version v9.9.9 >/dev/null 2>&1
_new_rc=$?
chk "new 成功(rc=0)" 0 "${_new_rc}"
chk "new 产出 tree.tar.gz" 1 "$([ -f "${_ro2}/kubespray/v9.9.9/tree.tar.gz" ] && echo 1 || echo 0)"
chk "new 产出配置文件 sha256 边车" 1 "$([ -f "${_ro2}/kubespray/v9.9.9/tree.tar.gz.sha256" ] && echo 1 || echo 0)"
chk "--local 落 LOCAL_ONLY 标记" 1 "$([ -f "${_ro2}/kubespray/v9.9.9/LOCAL_ONLY" ] && echo 1 || echo 0)"
chk "档案骨架含推导的 CALICO_VERSION" "9.9.9" \
    "$(awk -F= '/^CALICO_VERSION=/{print $2; exit}' "${_ro2}/kubespray/v9.9.9/VERSION.profile")"
chk "档案骨架含 PAUSE(pod_infra 内联表)" "9.9.9" \
    "$(awk -F= '/^PAUSE_VERSION=/{print $2; exit}' "${_ro2}/kubespray/v9.9.9/VERSION.profile")"
# 反证 a: k8s 线不在表内 → 拒收(⚠ 目录已存在时也会拒 —— 两者都非零, 都算拒收)
rc=0
env "${_vd2[@]}" bash "${REPO_ROOT}/deployments/kubespray/cubestack-version-dir.sh" \
    new v9.9.9 --from-root "${_src}" --k8s-version v9.9.8 >/dev/null 2>&1 || rc=$?
chk "表外 k8s 线 → rc!=0" 1 "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
# 反证 b: 补丁不在位 → 拒收且不留目录(换个未占用的版本名, 确保走到补丁校验那一步)
printf '#!/bin/bash\nexit 1\n' > "${_src}/cubestack-patch-apply.sh"; chmod +x "${_src}/cubestack-patch-apply.sh"
rc=0
env "${_vd2[@]}" bash "${REPO_ROOT}/deployments/kubespray/cubestack-version-dir.sh" \
    new v9.9.8 --from-root "${_src}" --k8s-version v9.9.9 >/dev/null 2>&1 || rc=$?
chk "补丁不在位 → rc!=0 且不产物" 1 "$([ "${rc}" -ne 0 ] && [ ! -d "${_ro2}/kubespray/v9.9.8" ] && echo 1 || echo 0)"
# verify 全绿(用完整夹具再验一次)
rc=0
env "${_vd2[@]}" bash "${REPO_ROOT}/deployments/kubespray/cubestack-version-dir.sh" verify v9.9.9 >/dev/null 2>&1 || rc=$?
chk "verify 对 new 出来的目录 → rc!=0(images/ 空, 如实报缺)" 1 "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
rm -rf "${_src}" "${_ro2}"

if [ "${fail}" = "0" ]; then echo "== 全部通过 =="; else echo "== 有失败项 =="; fi
exit "${fail}"
