#!/bin/bash
# ============================================================
# lib-image-manifest.sh — images.manifest 解析库(**被 source, 不直接执行**)
# ============================================================
# 职责(单一实现, 供 harbor-sync-images.sh / harbor-save-images.sh / check-image-manifest.sh 共用):
#   ① 加载版本变量默认值(cluster.conf 优先, 缺失回退 cluster.conf.example)
#   ② 解析 deployments/config/images.manifest 的 <group> <ref> 两列
#   ③ 展开 ref 里的 ${VAR} 占位符(带派生: CUBEPILOT_IMAGE_TAG 留空时按 chart 版本派生)
#   ④ group → 离线目录(offline-files/<...>)映射
#   ⑤ 上游 ref → Harbor 镜像 ref 映射(唯一规则)
#   ⑥ 上游 ref → 离线 tar 文件名(**按上游 ref 命名**, 保证既有模块的通配匹配不失效)
#
# ⚠ 本库**不 source lib-common.sh**: CI(GitHub Actions)上没有集群/没有 cluster.conf,
#   必须能独立跑。调用方若已 load_config, 其变量会自然生效(本库只在变量未设置时才补默认)。
#
# Harbor 路径规则(唯一, 见 images.manifest 头部说明):
#   上游注册域 ≠ Harbor          → mirrors/<注册域>/<仓库路径>:<tag>
#   上游就是该台 Harbor 自身      → mirrors/<仓库路径>:<tag>(去掉域名前缀)
#
# 用法(调用方):
#   source ".../lib-image-manifest.sh"
#   image_manifest_load                 || exit 1     # 加载变量默认值
#   while IFS=$'\t' read -r group ref; do ...; done < <(image_manifest_entries)
#   tar="$(image_tar_path "${group}" "${ref}")"
#   mirror="$(image_mirror_ref "${ref}")"
# ============================================================

# ---------- 0. 路径与默认值 ----------
# 本库可能在 CI 上被 source(无 lib-common), 自己推导仓库根: .../deployments/scripts/tools/images/ → 根
_IM_PATH_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IM_REPO_ROOT="${REPO_ROOT:-}"
if [ -z "${IM_REPO_ROOT}" ]; then
    _d="${_IM_PATH_SELF}"
    while [ "${_d}" != "/" ] && [ -z "${IM_REPO_ROOT}" ]; do
        [ -d "${_d}/deployments/scripts" ] && [ -d "${_d}/deployments/config" ] && IM_REPO_ROOT="${_d}"
        _d="$(dirname "${_d}")"
    done
fi
IM_REPO_ROOT="${IM_REPO_ROOT:-${PWD}}"
unset _d _IM_PATH_SELF

# ---------- 1. 加载版本变量 ----------
# 分层加载(标准 idiom): 先 source cluster.conf.example 取**全部默认值**, 再 source
# cluster.conf 覆盖。这样:
#   · CI 上没有 cluster.conf        → 纯用 example 内置默认, 照常工作;
#   · 已有环境 cluster.conf 早于本次新增变量(如未重抄 example) → 缺失的用 example 默认补齐,
#     **不需要用户改任何配置**;
#   · 真实配置里显式设过的值优先。
image_manifest_load() {
    local _conf="${IMAGE_MANIFEST_CONF:-}"        # 显式指定则只用它(单文件模式)
    local _example="${IM_REPO_ROOT}/deployments/config/cluster.conf.example"
    local _real="${IM_REPO_ROOT}/deployments/config/cluster.conf"

    # 保存调用方已显式设置的关键变量(有值才保护; 空值不保护 —— 空=用清单默认)
    local -a _protected=()
    local _v
    for _v in CUBEPILOT_IMAGE_TAG CUBEPILOT_VERSION CUBEPILOT_HARBOR CUBEPILOT_PROJECT \
              METAX_HARBOR METAX_PROJECT METAX_VERSION METAX_DRIVER_VERSION METAX_MACA_IMAGE \
              HARBOR_MIRROR_REGISTRY HARBOR_MIRROR_PROJECT HARBOR_MIRROR_USER HARBOR_MIRROR_PASSWORD \
              REPO_ROOT K8S_VERSION; do
        [ -n "${!_v:-}" ] && _protected+=( "${_v}=${!_v}" )
    done

    # ⚠ cluster.conf **不是**自包含文件: 它直接用 ${REPO_ROOT} / ${CLUSTER_NAME}(无 :- 兜底),
    #   而这两个平时由 lib-common.sh 定义。CI / 独立运行时不 source lib-common, 于是 set -u 下
    #   会 "REPO_ROOT: unbound variable" / "CLUSTER_NAME: unbound variable"。
    #   这里两手准备: ① 先补两个已知变量; ② source 期间临时关掉 nounset(未来 conf 再引用新变量
    #   也不会让镜像工具链挂掉 —— 本库只关心其中少数变量, 其余缺失与我们无关)。
    REPO_ROOT="${REPO_ROOT:-${IM_REPO_ROOT}}"
    CLUSTER_NAME="${CLUSTER_NAME:-cubestack-cluster}"

    local _nounset_was_on=0
    case "$-" in *u*) _nounset_was_on=1 ;; esac
    set +u
    local _loaded="" _src_rc=0
    if [ -n "${_conf}" ]; then
        [ -f "${_conf}" ] || { [ "${_nounset_was_on}" = 1 ] && set -u; echo "【错误】IMAGE_MANIFEST_CONF 指定的文件不存在: ${_conf}" >&2; return 1; }
        # shellcheck disable=SC1090
        source "${_conf}" >/dev/null 2>&1; _src_rc=$?; _loaded="${_conf}"
    else
        for _c in "${_example}" "${_real}"; do
            [ -f "${_c}" ] || continue
            # shellcheck disable=SC1090
            source "${_c}" >/dev/null 2>&1 || _src_rc=$?
            _loaded="${_loaded}${_loaded:+,}${_c}"
        done
    fi
    [ "${_nounset_was_on}" = "1" ] && set -u
    unset _nounset_was_on

    if [ -z "${_loaded}" ]; then
        echo "【错误】找不到 cluster.conf / cluster.conf.example(IMAGE_MANIFEST_CONF 可指定)" >&2
        return 1
    fi
    IM_CONF_FILE="${_loaded}"

    # 还原调用方显式设置的值
    if [ "${#_protected[@]}" -gt 0 ]; then
        for _v in "${_protected[@]}"; do
            printf -v "${_v%%=*}" '%s' "${_v#*=}"
        done
    fi
    unset _v _protected _c _conf _example _real _loaded _src_rc
    return 0
}

# ---------- 2. 派生: CUBEPILOT_IMAGE_TAG 留空时按 chart 版本派生 ----------
# 规则与 modules/03_addon/31_cubepilot.sh 完全一致: chart 版本以 -latest 结尾 → 镜像 tag=latest;
# 否则 tag=chart 版本。两处必须同步, 否则清单里的 ref 与模块实际拉的镜像不是同一个。
image_derive_globals() {
    if [ -z "${CUBEPILOT_IMAGE_TAG:-}" ]; then
        local _cv="${CUBEPILOT_VERSION:-0.1.0-latest}"
        if [ "${_cv%-latest}" != "${_cv}" ]; then
            CUBEPILOT_IMAGE_TAG="latest"
        else
            CUBEPILOT_IMAGE_TAG="${_cv}"
        fi
    fi
    return 0
}

# ---------- 3. 清单解析 ----------
image_manifest_path() {
    echo "${IMAGE_MANIFEST:-${IM_REPO_ROOT}/deployments/config/images.manifest}"
}

# 输出: 每行 "<group>\t<展开后的 ref>\t<tar 文件名>"(第三列可为空 = 按 ref 自动派生)
image_manifest_entries() {
    local _mf; _mf="$(image_manifest_path)"
    [ -f "${_mf}" ] || { echo "【错误】镜像清单不存在: ${_mf}" >&2; return 1; }
    image_derive_globals
    local _line _group _ref _name _rest
    while IFS= read -r _line || [ -n "${_line}" ]; do
        # 去注释与首尾空白; 支持行尾 "# 注释"
        _line="${_line%%#*}"
        _line="$(printf '%s' "${_line}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -z "${_line}" ] && continue
        _group="${_line%%[[:space:]]*}"
        _rest="$(printf '%s' "${_line#*[[:space:]]}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        # _rest = "<ref>" 或 "<ref> <tar 文件名>"
        _ref="${_rest%%[[:space:]]*}"
        _name=""
        [ "${_rest}" != "${_ref}" ] && _name="$(printf '%s' "${_rest#*[[:space:]]}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -z "${_ref}" ] && continue
        if ! _ref="$(image_expand_ref "${_ref}")"; then
            echo "【错误】清单内容无法展开(set -u 下有变量未定义): group=${_group} ref=${_ref}" >&2
            return 1
        fi
        printf '%s\t%s\t%s\n' "${_group}" "${_ref}" "${_name}"
    done < "${_mf}"
}

# 展开 ref 里的 ${VAR}(只用取值替换, **不 eval** —— 清单是数据不是代码)
image_expand_ref() {
    local s="$1" name val out=""
    while [[ "${s}" =~ ^([^$]*)\$\{([A-Za-z_][A-Za-z0-9_]*)\}(.*)$ ]]; do
        name="${BASH_REMATCH[2]}"
        # set -u 下取未定义变量会报错 → 显式判空并给出可定位的报错
        if [ -z "${!name+x}" ]; then
            echo "【错误】镜像清单引用了未定义变量: \${${name}}(在 ${IM_CONF_FILE:-cluster.conf} 中补声明)" >&2
            return 1
        fi
        val="${!name}"
        if [ -z "${val}" ]; then
            echo "【错误】镜像清单变量 \${${name}} 为空(会导致镜像 ref 非法)" >&2
            return 1
        fi
        out="${out}${BASH_REMATCH[1]}${val}"
        s="${BASH_REMATCH[3]}"
    done
    printf '%s' "${out}${s}"
}

# 列出清单里出现的全部 group(去重, 保持首次出现顺序)
image_groups() {
    image_manifest_entries | cut -f1 | awk '!seen[$0]++'
}

# ---------- 4. group → 离线目录 ----------
# 默认: <offline-files>/<group>/  ; 例外见 case。
image_group_dir() {
    local group="$1"
    local base="${IMAGE_OFFLINE_ROOT:-${IM_REPO_ROOT}/deployments/offline-files}"
    case "${group}" in
        # kubespray 基座 + ceph: 节点 containerd **预加载**走 kubespray 的 images/ 目录
        # (见 02_ceph.sh 的 CEPH_IMAGE_DIR 与 tools/offline/trim-offline-files.sh), 必须同目录
        k8s-base|ceph) echo "${IMAGE_K8S_IMAGES_DIR:-${base}/kubespray/images}" ;;
        *)             echo "${base}/${group}" ;;
    esac
}

# ---------- 5. 上游 ref → Harbor 镜像 ref ----------
# 规则: mirrors/<注册域>/<仓库路径>:<tag>  ; 上游就在本 Harbor 上时去掉 <注册域>。
image_mirror_ref() {
    local ref="$1"
    local host="${HARBOR_MIRROR_REGISTRY:-harbor.isuanova.com}"
    local proj="${HARBOR_MIRROR_PROJECT:-mirrors}"
    local reg path tag
    # 拆 <注册域>/<路径>:<tag> —— 第一段必含 '.' 或 ':'(docker.io / registry.k8s.io / host:port)
    if [[ "${ref}" =~ ^([^/]+)/(.+):([^/:]+)$ ]]; then
        reg="${BASH_REMATCH[1]}"; path="${BASH_REMATCH[2]}"; tag="${BASH_REMATCH[3]}"
    else
        echo "【错误】镜像 ref 非法(需 <注册域>/<仓库路径>:<tag>): ${ref}" >&2
        return 1
    fi
    if [ "${reg}" = "${host}" ]; then
        # 上游就是本 Harbor(如 harbor.isuanova.com/metax/...)→ 去掉域名前缀, 避免路径里出现两遍域名
        echo "${host}/${proj}/${path}:${tag}"
    else
        echo "${host}/${proj}/${reg}/${path}:${tag}"
    fi
}

# ---------- 6. 上游 ref → 离线 tar 路径 ----------
# ⚠ 默认**按上游 ref 命名**(如 registry.k8s.io_kube-state-metrics_kube-state-metrics_v2.20.0.tar):
#   既有部署模块都用 "*<repo>_<tag>.tar" 通配查找, 沿用上游命名可**零改动**兼容。
#   `override` 非空时用它 —— 少数"历史短名"镜像(如 busybox.tar / nginx.tar)由既有模块
#   按字面文件名读取, 不能改名, 在清单里用第 3 列显式指定。
image_tar_name() {
    local override="${2:-}"
    if [ -n "${override}" ] && [ "${override}" != "-" ]; then
        printf '%s\n' "${override}"
        return 0
    fi
    printf '%s\n' "$(printf '%s' "$1" | sed 's#/#_#g; s#:#_#g').tar"
}

image_tar_path() {
    printf '%s/%s\n' "$(image_group_dir "$1")" "$(image_tar_name "$2" "${3:-}")"
}
