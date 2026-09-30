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
# ⑤b 版本 → 物化树映射(不依赖目录存在, CI 可跑; 曾漏: KUBESPRAY_VERSION=v2.28.0 仍指向仓库树 v2.32)
_offline_paths_ver() { # _offline_paths_ver <版本>
    ( set +u; export CLUSTER_CONF=/nonexistent KUBESPRAY_VERSION="$1" \
        OFFLINE_FILES_ROOT="" OFFLINE_FILES_DIR="" LOCAL_REPO_DIR="" CUBESTACK_BASE_DIR=""
      bash "${REPO_ROOT}/deployments/kubespray/cubestack-offline.sh" paths 2>/dev/null )
}
out4="$(_offline_paths_ver v9.9.9)"
chk "非仓库版本 → 运行根取 versions/<版本>" \
    "${REPO_ROOT}/deployments/kubespray/versions/v9.9.9" "$(_val "${out4}" BASE_DIR)"
chk "非仓库版本 → 树在物化版本根下" \
    "${REPO_ROOT}/deployments/kubespray/versions/v9.9.9/kubespray" "$(_val "${out4}" KUBESPRAY_DIR)"
out5="$(_offline_paths_ver "${TREE_VER}")"
chk "仓库树版本 → 仍用仓库根(行为不变)" \
    "${REPO_ROOT}/deployments/kubespray" "$(_val "${out5}" BASE_DIR)"
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
chk "档案骨架含推导的 CALICO_VERSION(v 前缀随 cluster.conf.example 继承)" "v9.9.9" \
    "$(awk -F= '/^CALICO_VERSION=/{print $2; exit}' "${_ro2}/kubespray/v9.9.9/VERSION.profile")"
chk "档案骨架含 PAUSE(pod_infra 内联表; 该键无 v 前缀)" "9.9.9" \
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

echo "== ⑨ 离线链路: sync 源目录/本地临时排除; trim 版本范围; fetch 参数校验 =="
_ro3="$(mktemp -d)"; mkdir -p "${_ro3}/kubespray/v9.9.9/images" "${_ro3}/kubespray/v9.9.8/images"
printf 'LOCAL_ONLY\n' > "${_ro3}/kubespray/v9.9.9/LOCAL_ONLY"
touch "${_ro3}/kubespray/v9.9.9/images/a.tar" "${_ro3}/kubespray/v9.9.8/images/b.tar"
sout="$(OFFLINE_FILES_ROOT="${_ro3}" bash "${REPO_ROOT}/deployments/scripts/tools/offline/sync-to-minio.sh" --plan-versions 2>/dev/null)"
chk "sync 源目录 = offline-files 真根(哨兵回归护栏)" "${_ro3}" \
    "$(printf '%s\n' "${sout}" | awk -F': ' '/^源目录:/{print $2}')"
printf '%s\n' "${sout}" | grep -q '将跳过.*v9.9.9' && chk "sync 跳过 LOCAL_ONLY 版本" 1 1 || chk "sync 跳过 LOCAL_ONLY 版本" 1 0
printf '%s\n' "${sout}" | grep -q '将上传: kubespray/v9.9.8' && chk "sync 计划上传在库版本" 1 1 || chk "sync 计划上传在库版本" 1 0
sout2="$(OFFLINE_FILES_DIR=/mnt/x bash "${REPO_ROOT}/deployments/scripts/tools/offline/sync-to-minio.sh" --plan-versions 2>/dev/null)"
chk "显式 OFFLINE_FILES_DIR(旧用法)仍生效" "/mnt/x" \
    "$(printf '%s\n' "${sout2}" | awk -F': ' '/^源目录:/{print $2}')"
rc=0; OFFLINE_FILES_ROOT="${_ro3}" bash "${REPO_ROOT}/deployments/scripts/tools/offline/sync-to-minio.sh" --prune >/dev/null 2>&1 || rc=$?
chk "--prune 无 --force-full-prune → 拒绝(多版本互删保护)" 1 "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
tout="$(OFFLINE_FILES_ROOT="${_ro3}" bash "${REPO_ROOT}/deployments/scripts/tools/offline/trim-offline-files.sh" --dry-run --version v9.9.8 2>/dev/null)"
printf '%s\n' "${tout}" | grep -q 'v9.9.9' && chk "trim 声明其它版本不触碰" 1 1 || chk "trim 声明其它版本不触碰" 1 0
rc=0; OFFLINE_FILES_ROOT="${_ro3}" bash "${REPO_ROOT}/deployments/scripts/tools/offline/trim-offline-files.sh" --dry-run --version v7.7.7 >/dev/null 2>&1 || rc=$?
chk "trim 对不存在版本 → 拒绝" 1 "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
rc=0; bash "${REPO_ROOT}/deployments/scripts/tools/offline/fetch-offline-from-minio.sh" --kubespray-version v9.9.9 --sub kubespray/v9.9.9 >/dev/null 2>&1 || rc=$?
chk "fetch --kubespray-version 与 --sub 互斥 → 拒绝" 1 "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
rc=0; bash "${REPO_ROOT}/deployments/scripts/tools/offline/fetch-offline-from-minio.sh" --sub /etc >/dev/null 2>&1 || rc=$?
chk "fetch --sub 绝对路径 → 拒绝" 1 "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
rm -rf "${_ro3}"

echo "== ⑩ CLI 镜像契约: 只含 deployments/ 代码(静态断言, 防回归) =="
# 用户口径 2026-09-30: 离线二进制不打进 CLI 镜像; kubectl/helm/skopeo 由容器运行期从挂载的
# 版本目录挂 PATH。以下三条是这条契约的**可执行**形式(改坏任何一条, 部署容器会静默少工具)。
for _df in Dockerfile-cli Dockerfile-cli-incremental; do
    if grep -qE '^COPY bin/(kubectl|helm|skopeo)' "${REPO_ROOT}/${_df}"; then
        chk "${_df} 不得打离线二进制(kubectl/helm/skopeo)" "无" "有"
    else
        chk "${_df} 不得打离线二进制(kubectl/helm/skopeo)" "无" "无"
    fi
    if grep -q '/etc/profile.d/50-cubestack-tools.sh' "${REPO_ROOT}/${_df}"; then
        chk "${_df} 已安装运行期工具链钩子" "有" "有"
    else
        chk "${_df} 已安装运行期工具链钩子" "有" "无"
    fi
done
chk "钩子源文件在位" "有" "$([ -f "${REPO_ROOT}/deployments/scripts/tools/docker/cli-toolchain-from-offline.sh" ] && echo 有 || echo 无)"
# mc 是**唯一例外**: 必须打进镜像(拉离线文件的引导工具, 不能被挂载提供; 上游 URL 已 410 Gone)
chk "base 层打进 mc(COPY bin/mc)" "有" "$(grep -q '^COPY bin/mc' "${REPO_ROOT}/Dockerfile-cli-base" && echo 有 || echo 无)"
# 只禁"下载命令"(注释里保留 410 说明是有意的, 别把注释也判成违规)
chk "base 层不再用已失效的 dl.min.io 下载" "无" "$(grep -qE '(wget|curl)[^#]*dl\.min\.io' "${REPO_ROOT}/Dockerfile-cli-base" && echo 有 || echo 无)"
chk "构建工具会把 mc 拷进上下文(离线件/宿主机)" "有" "$(grep -q 'offline-files/os/mc-' "${REPO_ROOT}/deployments/scripts/tools/docker/build-cli-context.sh" && echo 有 || echo 无)"
# 两层结构(2026-09-30): base(系统/工具链) + 代码层(FROM base);代码层不再 FROM 上一版 latest ⇒ 层数不累积
chk "存在 base 层 Dockerfile" "有" "$([ -f "${REPO_ROOT}/Dockerfile-cli-base" ] && echo 有 || echo 无)"
for _df in Dockerfile-cli Dockerfile-cli-incremental; do
    chk "${_df} FROM base 层(而非上一版 latest)" "有" "$(grep -q '^FROM ${CLI_BASE_TAG}' "${REPO_ROOT}/${_df}" && echo 有 || echo 无)"
done
# .dockerignore 必须挡住版本目录整层与物化树(否则整仓上下文构建会把 GB 级离线件打进镜像)
for _pat in 'deployments/offline-files/kubespray/\*/' 'deployments/kubespray/versions'; do
    if grep -qE "^${_pat}" "${REPO_ROOT}/.dockerignore"; then
        chk ".dockerignore 含 ${_pat}" "有" "有"
    else
        chk ".dockerignore 含 ${_pat}" "有" "无"
    fi
done

echo "== ⑪ 默认版本 = 最新(用户口径); 本地临时版本不进默认; 目录副本回退 =="
# 带夹具根的探针(OFFLINE_FILES_ROOT 指向夹具, 用于"版本目录自带档案副本"的回退路径)
_probe_root() { # _probe_root <offline_root> <版本|-> <conf 行...>
    local root="$1" ver="$2"; shift 2
    local c; c="$(mktemp)"; _conf "$@" > "${c}"
    ( set +u
      export CLUSTER_CONF="${c}" OFFLINE_FILES_ROOT="${root}"
      export KUBESPRAY_VERSION="" KUBESPRAY_PROFILE="" OFFLINE_FILES_DIR="" LOCAL_REPO_DIR="" KUBESPRAY_BASE_DIR=""
      [ "${ver}" != "-" ] && export KUBESPRAY_VERSION="${ver}"
      source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
      load_config >/dev/null 2>&1
      printf 'KUBESPRAY_VERSION=%s\nK8S_VERSION=%s\n' "${KUBESPRAY_VERSION}" "${K8S_VERSION:-}" )
    rm -f "${c}"
}
# (1) 默认 = max(仓库树版本, 有入库档案的版本) —— 当前 = TREE_VER
outd="$(_probe "${NODES_CONF}" 'X=1')"
chk "默认 = 最新版本(${TREE_VER})" "${TREE_VER}" "$(_val "${outd}" KUBESPRAY_VERSION)"
# (2)(4) 夹具: 一个只有"版本目录自带档案副本"的版本(v9.9.9), 无入库档案
_troot="$(mktemp -d)"; mkdir -p "${_troot}/kubespray/v9.9.9"
printf 'LOCAL_ONLY\n' > "${_troot}/kubespray/v9.9.9/LOCAL_ONLY"
printf 'KUBESPRAY_VERSION=v9.9.9\nK8S_VERSION=v9.9.9\n' > "${_troot}/kubespray/v9.9.9/VERSION.profile"
out_lo="$(_probe_root "${_troot}" - "${NODES_CONF}" 'X=1')"
chk "本地临时版本(无入库档案)不进默认" "${TREE_VER}" "$(_val "${out_lo}" KUBESPRAY_VERSION)"
# (3) 临时加一个更高的**入库档案** → 默认跟随(用完即删; trap 兜底)
_fake_prof="${REPO_ROOT}/deployments/config/profiles/v9.9.9.profile"
trap 'rm -f "${_fake_prof}"' EXIT
printf 'KUBESPRAY_VERSION=v9.9.9\nK8S_VERSION=v9.9.9\n' > "${_fake_prof}"
out_hi="$(_probe "${NODES_CONF}" 'X=1')"
chk "默认跟随最新入库档案(v9.9.9)" "v9.9.9" "$(_val "${out_hi}" KUBESPRAY_VERSION)"
rm -f "${_fake_prof}"; trap - EXIT
# (4) 显式选"只有目录副本"的版本 → 不硬失败, 且钉子取自副本
out_cp="$(_probe_root "${_troot}" v9.9.9 "${NODES_CONF}" 'K8S_VERSION="${K8S_VERSION:-v0.0.0}"')"
chk "目录副本回退: 不硬失败且版本生效" "v9.9.9" "$(_val "${out_cp}" KUBESPRAY_VERSION)"
chk "目录副本回退: 钉子来自副本" "v9.9.9" "$(_val "${out_cp}" K8S_VERSION)"
rm -rf "${_troot}"

if [ "${fail}" = "0" ]; then echo "== 全部通过 =="; else echo "== 有失败项 =="; fi
exit "${fail}"
