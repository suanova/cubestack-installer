#!/bin/bash
# ============================================================
# cubestack-version-dir.sh — kubespray 版本目录: 列出 / 校验 / 物化
#
#  版本目录 = ${OFFLINE_FILES_ROOT}/kubespray/<版本>/(版本名 = 上游 tag 全名, 决策 D8)
#  内容: tree.tar.gz(预打补丁的整树, 不含 .venv 与 inventory/local)+ images/ + packages/
#        + 裸二进制 + VERSION.profile(档案副本)+ 可选 LOCAL_ONLY(本地临时版本标记, 不上 MinIO)
#
# 设计: docs/kubespray-versioning/design.md §9.1
#
# 用法:
#   bash cubestack-version-dir.sh list                 # 列出在场版本目录(档位/树 tar/镜像数)
#   bash cubestack-version-dir.sh verify <版本>        # 校验: tar 指纹 + 档案副本 + images 非空
#   bash cubestack-version-dir.sh materialize <版本>   # 解树 → deployments/kubespray/versions/<版本>/
#
# 退出码: 0=通过; 1=校验不过; 2=参数/环境错误
# ============================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
OFFLINE_ROOT="${OFFLINE_FILES_ROOT:-${REPO_ROOT}/deployments/offline-files}"
VERSIONS_DIR="${REPO_ROOT}/deployments/kubespray/versions"

ok()   { echo -e "\033[32m✅ $*\033[0m"; }
bad()  { echo -e "\033[31m❌ $*\033[0m"; }
say()  { echo -e "\033[36m→ $*\033[0m"; }
warn() { echo -e "\033[33m⚠  $*\033[0m"; }

vd_dir() { printf '%s\n' "${OFFLINE_ROOT}/$1/$2"; }

# 是不是"版本目录": 至少有一个版本目录标记(树 tar / 档案副本 / LOCAL_ONLY / images/)
_is_version_dir() {
    local d="$1"
    [ -f "${d}/tree.tar.gz" ] || [ -f "${d}/VERSION.profile" ] || [ -f "${d}/LOCAL_ONLY" ] || [ -d "${d}/images" ]
}

cmd_list() {
    local comp_dir comp d name tier has_tree n_img marker
    say "版本目录(${OFFLINE_ROOT}; 档位 = 在库 / 本地临时)"
    shopt -s nullglob
    for comp_dir in "${OFFLINE_ROOT}"/*/; do
        comp="$(basename "${comp_dir}")"
        for d in "${comp_dir}"*/; do
            name="$(basename "${d}")"
            _is_version_dir "${d}" || { printf '  %-14s %-12s %s\n' "${comp}" "${name}" "(不像版本目录, 跳过标注)"; continue; }
            if [ -f "${d}/LOCAL_ONLY" ]; then tier="本地临时(不入库/不上 MinIO)"; else tier="在库"; fi
            has_tree="无 tree.tar.gz"; [ -f "${d}/tree.tar.gz" ] && has_tree="有 tree.tar.gz"
            n_img="$(find "${d}/images" -maxdepth 1 -name '*.tar' 2>/dev/null | wc -l)"
            marker=""; [ -f "${d}/VERSION.profile" ] || marker=" ⚠缺 VERSION.profile"
            printf '  %-14s %-12s %-28s %-16s images=%s%s\n' "${comp}" "${name}" "${tier}" "${has_tree}" "${n_img}" "${marker}"
        done
    done
    shopt -u nullglob
}

cmd_verify() {
    local v="${1:-}"
    [ -n "${v}" ] || { bad "用法: $0 verify <版本>"; return 2; }
    local d rc=0
    d="$(vd_dir kubespray "${v}")"
    [ -d "${d}" ] || { bad "版本目录不存在: ${d}"; return 1; }
    say "校验 ${d}"
    if [ -f "${d}/tree.tar.gz" ]; then
        if [ -f "${d}/tree.tar.gz.sha256" ]; then
            ( cd "${d}" && sha256sum -c --quiet tree.tar.gz.sha256 ) \
                || { bad "tree.tar.gz 指纹不符(重打包或重新下载)"; rc=1; }
        else
            warn "无 tree.tar.gz.sha256(旧目录?), 跳过指纹校验"
        fi
    else
        bad "缺 tree.tar.gz(版本目录无法物化出树)"; rc=1
    fi
    [ -f "${d}/VERSION.profile" ] || { bad "缺 VERSION.profile(自包含档案副本)"; rc=1; }
    if [ ! -d "${d}/images" ] || [ -z "$(find "${d}/images" -maxdepth 1 -name '*.tar' -print -quit 2>/dev/null)" ]; then
        bad "images/ 为空(节点预加载镜像缺失)"; rc=1
    fi
    [ "${rc}" = "0" ] && ok "版本目录校验通过: ${v}"
    return "${rc}"
}

cmd_materialize() {
    local v="${1:-}"
    [ -n "${v}" ] || { bad "用法: $0 materialize <版本>"; return 2; }
    local d dst want have
    d="$(vd_dir kubespray "${v}")"; dst="${VERSIONS_DIR}/${v}"
    [ -f "${d}/tree.tar.gz" ] || { bad "缺 ${d}/tree.tar.gz(无法物化)"; return 1; }
    want="$(sha256sum "${d}/tree.tar.gz" | awk '{print $1}')"
    if [ -d "${dst}/kubespray" ] && [ -f "${dst}/.tree.sha256" ] && [ "$(cat "${dst}/.tree.sha256")" = "${want}" ]; then
        ok "已物化且指纹一致(跳过): ${dst}"
        return 0
    fi
    mkdir -p "${dst}"
    say "解树 → ${dst}(已有内容会被覆盖)"
    tar -xzf "${d}/tree.tar.gz" -C "${dst}" || { bad "解包失败"; return 1; }
    printf '%s\n' "${want}" > "${dst}/.tree.sha256"
    ok "已物化: ${dst}/kubespray(版本 ${v}; .venv 由首次运行时按需重建)"
}

main() {
    local sub="${1:-}"
    case "${sub}" in
        list)        cmd_list ;;
        verify)      shift; cmd_verify "$@" ;;
        materialize) shift; cmd_materialize "$@" ;;
        -h|--help|"") sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
        *)           bad "未知子命令: ${sub}(可用 list / verify / materialize)"; exit 2 ;;
    esac
}
main "$@"
