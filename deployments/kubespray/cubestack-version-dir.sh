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

# 树内版本表解析(与 check-modules.sh ⑯ 共用一份口径; 见该库头部)
# shellcheck source=lib-kubespray-tables.sh
source "${SELF_DIR}/lib-kubespray-tables.sh"

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

# ── new: 造版本目录(预验证补丁在位 → 打包树 → 机械推导档案骨架) ──
# ⚠ 版本面的 k8s 小版本线**不是"推导"出来的**: 树里 kubelet_checksums 表是"可安装全集",
#   上游默认取表首(最新线), 而我们有意钉较稳的线(如 v2.32.0 树钉 1.35 而非表首 1.36)。
#   故 --k8s-version 必须显式给(或在库档案已有该版本时沿用), 且**校验其在表内**;
#   其余 10 项全部从树内表机械取值(禁手抄)。
_derive_profile() {   # <树根> <版本> <k8s_version>
    local tree="$1" ver="$2" k8s="$3"
    local dl="${tree}/roles/kubespray_defaults/defaults/main/download.yml"
    local ck="${tree}/roles/kubespray_defaults/vars/main/checksums.yml"
    local vm="${tree}/roles/kubespray_defaults/vars/main/main.yml"
    [ -f "${dl}" ] && [ -f "${ck}" ] && [ -f "${vm}" ] || { bad "树内表不全(缺 download.yml/checksums.yml/vars-main)"; return 1; }
    local major="${k8s#v}"; major="${major%.*}"
    [ "$(kb_tables_kubelet_has "${ck}" "${k8s#v}")" = "1" ] || {
        bad "K8S_VERSION=${k8s} 不在该树 kubelet_checksums 表内(该表=可安装版本全集)"
        warn "表内可选项: $(kb_tables_kubelet_list "${ck}" | tr '\n' ' ')"
        return 1
    }
    local calico etcd coredns pause ndc metrics cpa nginx lvp nfd
    calico="$(kb_tables_first_key "${ck}" calicoctl_binary_checksums amd64)"
    etcd="$(kb_tables_etcd "${ck}" "${vm}" "${major}")"
    coredns="$(kb_tables_inline "${dl}" coredns_supported_versions "${major}")"
    pause="$(kb_tables_inline "${vm}" pod_infra_supported_versions "${major}")"
    ndc="$(kb_tables_scalar "${dl}" nodelocaldns_version)"
    metrics="$(kb_tables_scalar "${dl}" metrics_server_version)"
    cpa="$(kb_tables_scalar "${dl}" dnsautoscaler_version)"
    nginx="$(kb_tables_scalar "${dl}" nginx_image_tag)"
    lvp="$(kb_tables_scalar "${dl}" local_volume_provisioner_version)"
    nfd="$(kb_tables_scalar "${dl}" node_feature_discovery_version)"
    local v
    for v in "${calico}" "${etcd}" "${coredns}" "${pause}" "${ndc}" "${metrics}" "${cpa}" "${nginx}" "${lvp}" "${nfd}"; do
        [ -n "${v}" ] || { bad "有表值取不到(kube_major=${major}) —— 树内表可能没有该 k8s 线"; return 1; }
    done
    cat <<EOF
# 版本套装档案: kubespray ${ver}(本文件由 cubestack-version-dir.sh new 从树内表值机械推导)
#
# 规则(见 docs/kubespray-versioning/design.md §3.2):
#   · 选定档案后, 本文件的版本面变量**接管** cluster.conf 的同名变量(档案 > cluster.conf);
#   · 要手工钉某一项 → KUBESPRAY_PROFILE=none;
#   · 字段真值由 check-modules.sh ⑯ 对照该版本树表值逐项断言。
#   · K8S_VERSION=${k8s} 为**人工选定**的线(kubelet_checksums 表内; 表内全集见 ⑯ 输出), 其余为推导值。
KUBESPRAY_VERSION=${ver}
K8S_VERSION=${k8s}
PAUSE_VERSION=${pause}
COREDNS_VERSION=${coredns}
DNS_NODE_CACHE_VERSION=${ndc}
ETCD_VERSION=${etcd}
CALICO_VERSION=${calico}
METRICS_SERVER_VERSION=${metrics}
CPA_VERSION=${cpa}
API_LB_NGINX_IMAGE_TAG=${nginx}
LOCAL_VOLUME_PROVISIONER_VERSION=${lvp}
NFD_VERSION=${nfd}
EOF
}

cmd_new() {   # new <标签> --from-root DIR [--local] [--assets-from DIR] [--k8s-version vX.Y.Z]
    local v="${1:-}"; [ -n "${v}" ] || { bad "用法: $0 new <标签> --from-root <部署根> [--local] [--assets-from DIR] [--k8s-version vX.Y.Z]"; return 2; }
    shift || true
    local from_root="" local_only=0 assets_from="" k8s_arg=""
    while [ $# -gt 0 ]; do case "$1" in
        --from-root)   from_root="${2:?}"; shift 2 ;;
        --assets-from) assets_from="${2:?}"; shift 2 ;;
        --k8s-version) k8s_arg="${2:?}"; shift 2 ;;
        --local)       local_only=1; shift ;;
        *) bad "未知参数: $1"; return 2 ;;
    esac; done
    [ -n "${from_root}" ] || { bad "缺 --from-root <部署根>(需含 kubespray/ 与 cubestack-patch-apply.sh)"; return 2; }
    local tree="${from_root}/kubespray"
    [ -d "${tree}" ] || { bad "--from-root 下无 kubespray/: ${from_root}"; return 2; }
    local d; d="$(vd_dir kubespray "${v}")"
    [ -e "${d}" ] && { bad "版本目录已存在(先删或换版本): ${d}"; return 1; }

    # ① 预验证: 补丁必须在位 —— 只打包"已验证过"的树(设计 §5.2)
    if [ -x "${from_root}/cubestack-patch-apply.sh" ]; then
        say "预验证补丁在位: cubestack-patch-apply.sh --check"
        bash "${from_root}/cubestack-patch-apply.sh" --check \
            || { bad "补丁不在位 → 拒收(先按 docs/kubespray-upgrade.md 重放补丁)"; return 1; }
    else
        bad "缺 cubestack-patch-apply.sh(无法证明补丁在位) → 拒收"; return 1
    fi

    # ② 树版本自洽: galaxy.yml 版本 == 目录名
    local gal_ver; gal_ver="$(awk '/^version:/{print $2; exit}' "${tree}/galaxy.yml")"
    [ "v${gal_ver}" = "${v}" ] || { bad "galaxy.yml 版本 v${gal_ver} ≠ 目录名 ${v}"; return 1; }

    # ③ k8s 线: 显式给 → 校验; 否则沿用在库档案的同名值; 都没有 → 报错并给候选
    local k8s="${k8s_arg}"
    if [ -z "${k8s}" ] && [ -f "${REPO_ROOT}/deployments/config/profiles/${v}.profile" ]; then
        k8s="$(grep -m1 -E '^K8S_VERSION=' "${REPO_ROOT}/deployments/config/profiles/${v}.profile" | cut -d= -f2-)"
        [ -n "${k8s}" ] && say "沿用入库档案的 K8S_VERSION=${k8s}"
    fi
    [ -n "${k8s}" ] || { bad "缺 --k8s-version: 树表只是'可安装全集', 小版本线是人工选择"; \
        warn "表内可选项: $(kb_tables_kubelet_list "${tree}/roles/kubespray_defaults/vars/main/checksums.yml" | tr '\n' ' ')"; return 2; }

    mkdir -p "${d}"
    say "打包树 → ${d}/tree.tar.gz(排除 .venv 与 inventory/local)"
    tar -czf "${d}/tree.tar.gz" -C "${tree}" --exclude='./.venv' --exclude='./inventory/local' . \
        || { bad "打包失败"; return 1; }
    ( cd "${d}" && sha256sum tree.tar.gz > tree.tar.gz.sha256 )

    say "机械推导档案骨架 → ${d}/VERSION.profile"
    _derive_profile "${tree}" "${v}" "${k8s}" > "${d}/VERSION.profile" || { bad "档案骨架推导失败"; rm -rf "${d}"; return 1; }

    [ "${local_only}" = "1" ] && printf '本地临时版本: 不入 git、不上 MinIO(设计 D4)\n' > "${d}/LOCAL_ONLY"
    if [ -n "${assets_from}" ]; then
        [ -d "${assets_from}" ] || { bad "--assets-from 不是目录: ${assets_from}"; return 1; }
        say "拷入资产: ${assets_from}/ → ${d}/"
        cp -a "${assets_from}"/. "${d}"/
    fi
    ok "版本目录已产出: ${d}"
    [ "${local_only}" = "1" ] && warn "本地临时版本(LOCAL_ONLY): 不会进 git、不会被 sync-to-minio 上传"
    say "下一步: $0 verify ${v}    # 校验(树指纹/档案/images)"
}

main() {
    local sub="${1:-}"
    case "${sub}" in
        list)        cmd_list ;;
        verify)      shift; cmd_verify "$@" ;;
        materialize) shift; cmd_materialize "$@" ;;
        new)         shift; cmd_new "$@" ;;
        -h|--help|"") sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
        *)           bad "未知子命令: ${sub}(可用 list / verify / materialize / new)"; exit 2 ;;
    esac
}
main "$@"
