#!/bin/bash
set -euo pipefail

# 自动检测: 脚本所在目录 = deployments/kubespray/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 运行根与布局(2026-09-30 起**不再靠父目录名判定** —— 物化版本树的父目录名不叫 deployments,
#   旧判据会让它在物化后静默走错目录; 见 docs/kubespray-versioning/design.md §5.3):
#   CUBESTACK_BASE_DIR  运行根(默认 = 脚本目录; 物化版本时 = deployments/kubespray/versions/<版本>)
#   CUBESTACK_LAYOUT    布局: repo(默认, 离线件在 <仓库>/deployments/offline-files)/ flat(standalone)
# 运行根: ① 显式 CUBESTACK_BASE_DIR(模块传入)  ② 选定版本 != 仓库树版本 ⇒ 物化版本根
#   versions/<版本>/(默认位置见 cubestack-version-dir.sh materialize)  ③ 否则仓库根(现状)
#   ⚠ 没有这条映射时, KUBESPRAY_VERSION=v2.28.0 仍会指向仓库树(v2.32)—— 树与资产错配且不报错。
if [ -n "${CUBESTACK_BASE_DIR:-}" ]; then
    BASE_DIR="${CUBESTACK_BASE_DIR}"
else
    _repo_tree_ver="$(awk '/^version:/{print "v"$2; exit}' "${SCRIPT_DIR}/kubespray/galaxy.yml" 2>/dev/null || true)"
    if [ -n "${KUBESPRAY_VERSION:-}" ] && [ -n "${_repo_tree_ver}" ] && [ "${KUBESPRAY_VERSION}" != "${_repo_tree_ver}" ]; then
        BASE_DIR="${SCRIPT_DIR}/versions/${KUBESPRAY_VERSION}"
    else
        BASE_DIR="${SCRIPT_DIR}"
    fi
    unset _repo_tree_ver
fi
KUBESPRAY_DIR="${CUBESTACK_KUBESPRAY_DIR:-${BASE_DIR}/kubespray}"
OFFLINE_LAYOUT="${CUBESTACK_LAYOUT:-repo}"
# 离线件真根: repo 布局从**脚本位置**推(脚本始终在 <仓库>/deployments/kubespray/, 与运行根无关),
# 不随 BASE_DIR 漂移 —— 这是"物化树不搬离线件"的落点。
if [ "${OFFLINE_LAYOUT}" = "flat" ]; then
    OFFLINE_FILES_ROOT="${OFFLINE_FILES_ROOT:-${BASE_DIR}/offline-files}"
else
    # SCRIPT_DIR = <仓库>/deployments/kubespray ⇒ 上一级就是 deployments/, 再加 offline-files(只退一层!)
    OFFLINE_FILES_ROOT="${OFFLINE_FILES_ROOT:-$(dirname "${SCRIPT_DIR}")/offline-files}"
fi
# kubespray 版本(单一开关; 目录名 = 上游 tag 全名, 决策 D8)。
#   派生源 = **实际要用的那棵树**的 galaxy.yml(CUBESTACK_KUBESPRAY_DIR 优先) —— 不是脚本目录:
#   物化版本(versions/<V>)时脚本仍在仓库里, 按脚本目录派生会取到"仓库当前树版本"⇒ 资产与树错配。
#   默认 = **最新版本** = max(仓库树版本, 有入库档案的版本目录)—— 与 lib-common 的
#   kubespray_latest_version() 同口径(本脚本不 source lib-common, 故内联一份; 改动要同步两处)。
if [ -z "${KUBESPRAY_VERSION:-}" ]; then
    # ① 被指向的树在 → **以那棵树为准**(物化版本根/仓库树都适用; "你指哪棵树"比"仓库最新"更接近意图)
    _tree_ver="$(awk '/^version:/{print "v"$2; exit}' "${KUBESPRAY_DIR}/galaxy.yml" 2>/dev/null || true)"
    if [ -n "${_tree_ver}" ]; then
        KUBESPRAY_VERSION="${_tree_ver}"
    else
        # ② 树不在 → 最新版本 = max(仓库树版本, 有入库档案的版本目录)
        #    (与 lib-common 的 kubespray_latest_version() 同口径; 本脚本不 source lib-common, 内联一份)
        _rt_ver="$(awk '/^version:/{print "v"$2; exit}' "${SCRIPT_DIR}/kubespray/galaxy.yml" 2>/dev/null || true)"
        KUBESPRAY_VERSION="$( { printf '%s\n' "${_rt_ver}"
            for _pf in "${SCRIPT_DIR}"/../config/profiles/*.profile; do
                [ -f "${_pf}" ] || continue
                sed -nE 's/^[[:space:]]*KUBESPRAY_VERSION=([^[:space:]#]+).*/\1/p' "${_pf}" | head -1
            done; } | sed '/^$/d' | sort -V | tail -1 )"
        unset _rt_ver _pf
    fi
    unset _tree_ver
fi
KUBESPRAY_VERSION="${KUBESPRAY_VERSION:-$(awk '/^version:/{print "v"$2; exit}' "${KUBESPRAY_DIR}/galaxy.yml" 2>/dev/null || true)}"
OFFLINE_FILES_DIR="${OFFLINE_FILES_DIR:-${OFFLINE_FILES_ROOT}/kubespray/${KUBESPRAY_VERSION}}"
LOCAL_REPO_BASE="${OFFLINE_FILES_DIR}"
# 资产目录默认值(兼容旧调用名): 一律收敛到**版本目录**(不再按集群名隔离)
default_local_repo_dir() { printf '%s\n' "${OFFLINE_FILES_DIR}"; }
INVENTORY_BASE="${BASE_DIR}/inventory"
REMOTE_USER="${CUBESTACK_REMOTE_USER:-ubuntu}"
CONTAINER_RUNTIME="containerd"
KUBESPRAY_REPO="https://github.com/kubernetes-sigs/kubespray.git"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 日志文件(全局, 由 start_log_tee 设置): 所有输出函数同时写入该文件
LOG_FILE="${LOG_FILE:-}"
_log_file() { [ -n "${LOG_FILE}" ] && echo -e "$*" >> "${LOG_FILE}" 2>/dev/null || true; }
log()       { local m="[INFO] $*";  echo -e "${GREEN}${m}${NC}"; _log_file "${m}"; }
warn()      { local m="[WARN] $*";  echo -e "${YELLOW}${m}${NC}"; _log_file "${m}"; }
err()       { local m="[ERROR] $*"; echo -e "${RED}${m}${NC}" >&2; _log_file "${m}"; exit 1; }
highlight() { local m=">>> $*";     echo -e "${CYAN}${m}${NC}"; _log_file "${m}"; }

# 写文件: 内嵌内容为权威 —— 缺失则生成; 存在但内容不同则覆盖(2026-10-08)。
# 背景: 旧的"仅缺失才生成"模式在内容演进后**永不更新**(实机: 老树 install-packages.yml 缺
#   os/packages 新路径修复, 靠人肉 docker cp 补; 树文件丢失走兜底重建时还会生成旧内容)。
_write_if_changed() {
    local target="$1" tmp
    tmp="$(mktemp)"
    cat > "${tmp}"
    if [ ! -f "${target}" ]; then
        mkdir -p "$(dirname "${target}")" 2>/dev/null || true
        cp "${tmp}" "${target}"
        log "生成 ${target}(内嵌内容)"
    elif ! cmp -s "${tmp}" "${target}"; then
        cp "${tmp}" "${target}"
        log "更新 ${target}(内嵌内容已演进, 旧版文件被刷新)"
    fi
    rm -f "${tmp}"
}

# 补丁层自动保障(2026-10-08): 树以"纯净上游 + cubestack-patches/"为准 —— 任何来源的树
#   (CLI 镜像自带 / 版本目录物化 / 联网克隆 / 存量老环境)就绪后, 验证补丁全部在位,
#   缺失/漂移即**自动按序重放**(工具幂等: APPLY/SKIP/CONFLICT)。
# 为什么必须自动: 存量树缺补丁的故障是**静默的** —— 实机 2026-10-08: 树缺
#   12-coredns-forward-resolvconf ⇒ coredns forward 渲染成 pod 自身 ⇒ loop 自杀 18+ 次、
#   cluster DNS 全断; 过去靠人肉 docker cp 补, 遗忘必复发。CONFLICT 即 err(不带伤继续)。
_ensure_patches_applied() {
    local tool="${SCRIPT_DIR}/cubestack-patch-apply.sh"
    local n
    [ -f "${tool}" ] || { warn "未找到补丁工具 ${tool}, 跳过补丁层保障"; return 0; }
    # ⚠ CLI 镜像曾未内置 `patch`(2026-10-08 实测)⇒ 检查恒 MISSING、apply 必炸 —— 先防呆,
    #   工具不备时**降级跳过**(不 err 中断部署);镜像/Dockerfile-cli-base 已补装 GNU patch。
    command -v patch >/dev/null 2>&1 || {
        warn "容器内无 patch 命令 → 跳过补丁层自动保障(修法: 重建 CLI 镜像[已含 patch], 或 docker cp /usr/bin/patch 进容器)"
        return 0
    }
    n="$(ls "${SCRIPT_DIR}/cubestack-patches"/*.patch 2>/dev/null | wc -l)"
    if bash "${tool}" --root "${KUBESPRAY_DIR}" --check >/dev/null 2>&1; then
        log "✅ 补丁层已全部在位(${n} 个)"
    else
        highlight "补丁层缺失/漂移 → 自动重放 ${n} 个补丁(幂等)..."
        bash "${tool}" --root "${KUBESPRAY_DIR}" --apply 2>&1 | sed 's/^/    /' \
            || err "补丁重放存在 CONFLICT(树被外部改动?), 请人工处理后再部署"
    fi
}

# 启动日志: 设置 LOG_FILE, 后续 log/warn/err/highlight 及 ansible 日志都写入该文件
# 同时输出到终端 + 写文件, 不使用 exec > >(tee)(会导致 Python subprocess 调用死锁)
start_log_tee() {
    local log="$1"
    # 若文件存在但当前用户不可写: 优先删除(自己创建的), 否则放开权限
    if [ -e "${log}" ] && [ ! -w "${log}" ]; then
        rm -f "${log}" 2>/dev/null || chmod 666 "${log}" 2>/dev/null || true
    fi
    if touch "${log}" 2>/dev/null; then
        LOG_FILE="${log}"
    else
        warn "无法写入日志 ${log}, 本次仅输出到终端, 不记录日志文件"
        LOG_FILE=""
    fi
    echo ">>> 日志: 同时显示终端 + 写入 ${LOG_FILE}"
    echo ">>> 可实时查看: tail -f ${LOG_FILE}"
}

# 运行 ansible-playbook, 日志输出到文件 + 可选终端
# 环境变量 ANSIBLE_LOG_TERMINAL(默认 1): 1=同时终端+文件, 0=仅文件
# 用法: run_ansible_playbook <日志文件> <ansible-playbook 参数...>
run_ansible_playbook() {
    local log_file="$1"; shift
    if [ "${ANSIBLE_LOG_TERMINAL:-1}" = "1" ]; then
        ansible-playbook "$@" 2>&1 | tee -a "${log_file}"
    else
        ansible-playbook "$@" 2>&1 >> "${log_file}"
    fi
    return "${PIPESTATUS[0]}"
}

usage() {
    echo "用法: $0 <命令> [集群名称] [选项]"
    echo ""
    echo "  集群名称可选，默认为 cubestack-cluster"
    echo "  也可通过环境变量 CUBESTACK_CLUSTER 指定"
    echo ""
    echo "命令:"
    echo "  init       [名称]           初始化环境"
    echo "  download   [名称]           下载离线资源（使用 download-hosts.yml，本地 root）"
    echo "  install    [名称] [选项]    执行集群安装（使用 hosts.yml，目标节点 ubuntu）"
    echo "  reset      [名称] --yes     清除目标节点上的旧集群状态（覆盖安装的前置步骤; 见下）"
    echo "  scale      [名称] [选项]    扩容集群 — 添加新节点到已有集群"
    echo "  check      [名称]           预检资源与连通性"
    echo "  paths      [名称]           只读: 打印全部路径推导(版本/资产目录/树/inventory; 排障用)"
    echo "  # upgrade  [名称] [选项]    (未实现) 原地升级到新版本 —— 设计见 docs/cluster-upgrade-path.md"
    echo ""
    echo "选项:"
    echo "  --limit <group>   限制目标组，可选值:"
    echo "                      kube_control_plane  — 仅部署 master 节点"
    echo "                      kube_node           — 仅部署 worker 节点"
    echo "                      etcd                — 仅部署 etcd 节点"
    echo ""
    echo "示例:"
    echo "  $0 install mycluster --limit kube_control_plane   # 仅部署 master"
    echo "  $0 install mycluster --limit kube_node            # 仅部署 worker"
    echo "  $0 scale   mycluster --limit kube_node            # 扩容加入新 worker"
    echo "  $0 scale   mycluster --limit kube_control_plane   # 扩容加入新 master"
    exit 0
}

resolve_cluster_name() {
    local cmd="$1"
    local arg="$2"
    if [ -n "$arg" ]; then
        echo "$arg"
    elif [ -n "${CUBESTACK_CLUSTER:-}" ]; then
        echo "${CUBESTACK_CLUSTER}"
    else
        echo "cubestack-cluster"
    fi
}

detect_runtime() {
    if command -v nerdctl >/dev/null 2>&1; then
        echo "nerdctl"
    elif command -v docker >/dev/null 2>&1; then
        echo "docker"
    elif command -v podman >/dev/null 2>&1; then
        echo "podman"
    else
        err "未找到容器运行时 (nerdctl/docker/podman)"
    fi
}

# 返回对应运行时的 pull 命令（含参数）
get_pull_cmd() {
    case "$1" in
        nerdctl) echo "nerdctl -n k8s.io pull --quiet" ;;
        docker)  echo "docker pull" ;;
        podman)  echo "podman pull" ;;
        *)       err "未知运行时: $1" ;;
    esac
}

# 返回对应运行时的 save 命令（不含输出文件参数，调用方自行追加 -o <dest>）
get_save_cmd() {
    case "$1" in
        nerdctl) echo "nerdctl -n k8s.io save" ;;
        docker)  echo "docker save" ;;
        podman)  echo "podman save" ;;
        *)       err "未知运行时: $1" ;;
    esac
}

ensure_kubespray() {
    if [ -d "${KUBESPRAY_DIR}/.git" ] || [ -f "${KUBESPRAY_DIR}/cluster.yml" ]; then
        log "✅ Kubespray 源码已就绪: ${KUBESPRAY_DIR}"
        _ensure_patches_applied
        return 0
    fi
    # ① 版本目录自带**预打补丁的树 tar** → 优先物化(离线、含补丁层、可验指纹; 2026-09-30 起)
    #    仅当"选定版本 ≠ 仓库树版本"(= 目标是物化树)且本机有该版本目录时才走这条路;
    #    仓库树版本仍走下面的原路径(不改变原来的部署模式)。
    local _tree_tar="${OFFLINE_FILES_DIR:-}/tree.tar.gz"
    local _repo_tree_ver; _repo_tree_ver="$(awk '/^version:/{print "v"$2; exit}' "${SCRIPT_DIR}/kubespray/galaxy.yml" 2>/dev/null || true)"
    # ⚠ 只在"选定版本 ≠ 仓库树版本"时物化: 否则万一仓库树缺失, 会把 tar 解进 **git 跟踪**的
    #    deployments/kubespray/kubespray/(与 HEAD 可能不一致) —— 那不是本机制该做的事。
    if [ -n "${OFFLINE_FILES_DIR:-}" ] && [ -f "${_tree_tar}" ] && [ "${KUBESPRAY_VERSION}" != "${_repo_tree_ver}" ]; then
        highlight "从版本目录物化 Kubespray ${KUBESPRAY_VERSION}(离线, 顶层 kubespray/)"
        mkdir -p "$(dirname "${KUBESPRAY_DIR}")"
        tar -xzf "${_tree_tar}" -C "$(dirname "${KUBESPRAY_DIR}")" || err "解树失败: ${_tree_tar}"
        log "✅ 已物化: ${KUBESPRAY_DIR}(版本 ${KUBESPRAY_VERSION}; .venv 由 ensure_venv 按需重建)"
        _ensure_patches_applied
        return 0
    fi
    # ② 原路径: 联网 clone(行为不变)
    highlight "正在克隆 Kubespray ${KUBESPRAY_VERSION}..."
    git clone --depth 1 --branch "${KUBESPRAY_VERSION}" "${KUBESPRAY_REPO}" "${KUBESPRAY_DIR}" || err "Git clone 失败，请检查网络或版本号"
    log "✅ Kubespray 源码克隆完成"
    _ensure_patches_applied
}

# .venv 是否**真的可用**: 目录在 ≠ 环境能用(2026-09-28 实机事故)
#   失败或中断的 `python3 -m venv`(典型: Ubuntu 缺 python3-venv, ensurepip 不可用)会在目标目录
#   留下**空壳**: pyvenv.cfg + bin/python* + lib/, 但**没有 bin/activate**(venv 在写 activate
#   脚本之前就中止了)。原实现只判 `[ -d .venv ]`, 于是下次运行走 else 分支直接
#   `source .venv/bin/activate` → "No such file or directory", 既没有修法提示, 也永远不会自愈。
#   bin/python 也要求真能跑: venv 从别的机器/别的 python 版本拷来时, activate 在但 python 是
#   悬空符号链接 → 之后 ansible-playbook 全报 bad interpreter。
venv_is_usable() {
    local v="${KUBESPRAY_DIR}/.venv"
    [ -f "${v}/bin/activate" ] && "${v}/bin/python" -c "" >/dev/null 2>&1
}

# 版本比较: sort -V 取小者(与树里 assert 的语义一致: 恰好等于门算通过)
_venv_av_lt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }

ensure_venv() {
    cd "${KUBESPRAY_DIR}"

    # 半成品 .venv(空壳 / 悬空 python): 留着只会把下一次运行卡死在 source 上, 直接删掉重建
    if [ -d ".venv" ] && ! venv_is_usable; then
        warn ".venv/ 存在但不可用(缺 bin/activate 或 bin/python 跑不起来) —— 判为创建失败/中断的半成品, 删除重建"
        rm -rf .venv || err "删除半成品 .venv 失败(权限/属主): 请手工执行 rm -rf ${KUBESPRAY_DIR}/.venv 后重试"
    fi

    if [ ! -d ".venv" ]; then
        highlight "创建 Python 虚拟环境(继承镜像预装的系统依赖, 完全离线)..."
        # --system-site-packages: 复用镜像/系统已预装的 ansible 等依赖(见 Dockerfile-cli),
        # 避免新建空 venv 后联网 pip install 拉取失败(离线环境)。
        # ⚠ 解释器选择: 树内 requirements.txt 是 ansible==12.3.0(= ansible-core 2.19.x), 它在
        #   **控制端**硬要求 Python ≥3.11;ubuntu 22.04 自带的 python3 是 3.10 → 建 3.10 venv 时
        #   pip 会直接拒绝装 ansible 12。故优先挑一个 ≥3.11 的解释器(裸机装 deadsnakes 的
        #   python3.11 即可), 挑不到才回退 python3(回退时下面的版本自检会打印修法)。
        local _venv_py=""
        for _c in python3.12 python3.11 python3.13; do
            command -v "${_c}" >/dev/null 2>&1 && { _venv_py="${_c}"; break; }
        done
        [ -n "${_venv_py}" ] || _venv_py=python3
        log "虚拟环境解释器: ${_venv_py}($(${_venv_py} -V 2>&1))"
        if ! "${_venv_py}" -m venv --system-site-packages .venv; then
            # ⚠ 失败时目标目录里已经留了空壳 —— 不清掉的话, 下次运行会把它当"已就绪"(见上)
            rm -rf .venv 2>/dev/null || true
            err "创建 venv 失败(见上方 python3 报错); Ubuntu/Debian 缺 venv 模块时: 装 python3-venv 后重试"
        fi
        venv_is_usable || { rm -rf .venv 2>/dev/null || true; err "venv 创建后仍不可用(无 bin/activate): 请确认发行版提供可用的 python3 -m venv"; }
        log "✅ 虚拟环境就绪"
    else
        log "✅ 虚拟环境已激活"
    fi

    source .venv/bin/activate

    # ansible 可用性: **两条路径都要查** —— 原实现只在"新建"分支查, 复用路径上一套没装 ansible 的
    # venv 会被静默放行, 直到 ansible-playbook 报 command not found 才炸。
    # ⚠ 判据用 ansible-playbook 本尊, 不用 `python3 -c "import ansible, ansible_runner"`:
    #   ansible_runner **不在** kubespray 的 requirements.txt 里(树里也没人用), 那个 import 恒失败
    #   → 无论 ansible 装没装都报"未预装"(假阴性)。
    if ! command -v ansible-playbook >/dev/null 2>&1; then
        if ls .venv_wheels/*.whl >/dev/null 2>&1; then
            highlight "系统无预装 ansible, 从 .venv_wheels/ 离线安装 ..."
            pip install --no-index --find-links=.venv_wheels -r requirements.txt -q \
                || err "离线安装 ansible 失败(缺少 .venv_wheels 缓存)"
        else
            warn "当前环境没有 ansible-playbook, 且无 .venv_wheels 缓存: 请用 CLI 镜像(已预装), 或本机 pip install -r ${KUBESPRAY_DIR}/requirements.txt"
        fi
    fi

    # ansible 大版本自检(判据与 cubestack-kubespray-upgrade.sh [5/8] 一致): 换树后 .venv 是被
    # **有意保留**的, 而树里 playbooks/ansible_version.yml 对 ansible-core 硬断言(v2.32: ≥2.19
    # <2.20)。陈旧 venv(实测 core 2.16.19)会顶掉 CLI 镜像里预装的新 ansible → 部署第一个 play
    # 硬失败。此处只警告不拦停(download/init 用不到新版特性), 但把修法写清楚。
    if command -v ansible-playbook >/dev/null 2>&1 && [ -f "${KUBESPRAY_DIR}/playbooks/ansible_version.yml" ]; then
        local av_min av_line av_have
        av_min="$(sed -n 's/^[[:space:]]*minimal_ansible_version:[[:space:]]*//p' \
                    "${KUBESPRAY_DIR}/playbooks/ansible_version.yml" | head -1 | tr -d "\"'")"
        av_line="$(ansible --version 2>/dev/null | head -1 || true)"
        av_have="$(printf '%s' "${av_line}" | sed -nE 's/.*\[core ([0-9][0-9.]*)\].*/\1/p')"
        [ -n "${av_have}" ] || av_have="$(printf '%s' "${av_line}" | sed -nE 's/^ansible[[:space:]]+v?([0-9][0-9.]*).*/\1/p')"
        if [ -n "${av_min}" ] && [ -n "${av_have}" ] && _venv_av_lt "${av_have}" "${av_min}"; then
            warn "ansible-core ${av_have} 低于本树要求(≥ ${av_min}): 部署第一个 play 就会硬失败"
            warn "  修法: rm -rf ${KUBESPRAY_DIR}/.venv 后重跑本脚本(会重建), 或删掉它走 CLI 镜像预装的 ansible"
            warn "  ⚠ 若系统 python3 < 3.11: 先装 python3.11(ansible 12 在控制端硬要求 ≥3.11;ubuntu 22.04 需 deadsnakes), 再重建 venv"
        fi
    fi
}

ensure_cluster_dirs() {
    mkdir -p "${LOCAL_REPO_DIR}/images"
    mkdir -p "${INVENTORY_DIR}/group_vars/all"
    mkdir -p "${INVENTORY_DIR}/group_vars/k8s_cluster"
    log "✅ 集群目录已就绪: ${CLUSTER_NAME}"
}

cmd_init() {
    highlight "初始化集群 [${CLUSTER_NAME}] 部署环境..."
    ensure_kubespray
    ensure_venv
    ensure_cluster_dirs
    if [ ! -f "${INVENTORY_DIR}/hosts.yml" ]; then
        if [ -d "${KUBESPRAY_DIR}/inventory/sample" ]; then
            cp -rn "${KUBESPRAY_DIR}/inventory/sample/"* "${INVENTORY_DIR}/" 2>/dev/null || true
            log "✅ 已从 sample 生成 Inventory 模板"
        fi
        # 覆盖生成 hosts.yml 模板（含 scale 注释说明）
        cat > "${INVENTORY_DIR}/hosts.yml" << 'HOSTS_EOF'
# ============================================================
# 集群节点清单 — install / scale 共用
# ============================================================
# • install: 按组定义所有节点，全量部署
# • scale:   在已有组中追加新节点，然后执行 scale --limit <group>
#
# ── 使用说明 ──
# 1. 初始部署: 编辑下方节点，执行 install
# 2. 扩容 worker: 在 [kube_node] 下追加新节点，执行 scale --limit kube_node
# 3. 扩容 master: 在 [kube_control_plane] 下追加新节点，执行 scale --limit kube_control_plane
# ============================================================

[kube_control_plane]
# 初始 master 节点
node1 ansible_host=10.0.0.1 ansible_user=ubuntu
# 扩容 master 时取消下行注释并填入新节点
# node2 ansible_host=10.0.0.2 ansible_user=ubuntu

[etcd:children]
kube_control_plane

[kube_node]
# 初始 worker 节点
node1 ansible_host=10.0.0.1 ansible_user=ubuntu
# 扩容 worker 时取消下行注释并填入新节点
# node3 ansible_host=10.0.0.10 ansible_user=ubuntu
# node4 ansible_host=10.0.0.11 ansible_user=ubuntu

[k8s_cluster:children]
kube_control_plane
kube_node
HOSTS_EOF
        log "✅ 已生成 hosts.yml 模板"
    else
        log "✅ 安装 Inventory 已存在 (hosts.yml)"
    fi

    # 生成 scale 场景示例文件（仅供参考，实际 scale 直接编辑 hosts.yml）
    mkdir -p "${INVENTORY_DIR}/_examples"
    cat > "${INVENTORY_DIR}/_examples/hosts-scale-add-worker.yml" << 'SCALE_WORKER_EOF'
# ============================================================
# Scale 示例: 向已有集群加入新 worker 节点
# ============================================================
# 使用方式:
#   1. 将此文件中新增节点的部分合并到 ../hosts.yml 对应组下
#   2. 执行: ./cubestack-offline.sh scale mycluster --limit kube_node
# ============================================================
#
# 假设原 hosts.yml 已有:
#   [kube_control_plane]
#   master1 ansible_host=10.0.0.1 ansible_user=ubuntu
#
#   [kube_node]
#   worker1 ansible_host=10.0.0.10 ansible_user=ubuntu

[kube_node]
# --- 已有节点（保持不变）---
worker1 ansible_host=10.0.0.10 ansible_user=ubuntu
# --- 新增节点 ---
worker2 ansible_host=10.0.0.11 ansible_user=ubuntu
worker3 ansible_host=10.0.0.12 ansible_user=ubuntu

[k8s_cluster:children]
kube_control_plane
kube_node
SCALE_WORKER_EOF

    cat > "${INVENTORY_DIR}/_examples/hosts-scale-add-master.yml" << 'SCALE_MASTER_EOF'
# ============================================================
# Scale 示例: 向已有集群加入新 master 节点
# ============================================================
# 使用方式:
#   1. 将此文件中新增节点的部分合并到 ../hosts.yml 对应组下
#   2. 执行: ./cubestack-offline.sh scale mycluster --limit kube_control_plane
# ============================================================
#
# 假设原 hosts.yml 已有:
#   [kube_control_plane]
#   master1 ansible_host=10.0.0.1 ansible_user=ubuntu
#
#   [kube_node]
#   worker1 ansible_host=10.0.0.10 ansible_user=ubuntu

[kube_control_plane]
# --- 已有节点（保持不变）---
master1 ansible_host=10.0.0.1 ansible_user=ubuntu
# --- 新增节点 ---
master2 ansible_host=10.0.0.2 ansible_user=ubuntu
master3 ansible_host=10.0.0.3 ansible_user=ubuntu

[etcd:children]
kube_control_plane

[k8s_cluster:children]
kube_control_plane
kube_node
SCALE_MASTER_EOF
    log "✅ 已生成 Scale 示例文件: ${INVENTORY_DIR}/_examples/"
    if [ ! -f "${INVENTORY_DIR}/download-hosts.yml" ]; then
        cat > "${INVENTORY_DIR}/download-hosts.yml" << 'DOWNLOAD_EOF'
# Download-only inventory — localhost with root
# Used by generate_list.sh, no SSH to nodes required.
[kube_control_plane]
node1 ansible_host=localhost ansible_user=root

[etcd:children]
kube_control_plane

[kube_node]
node1 ansible_host=localhost ansible_user=root

[k8s_cluster:children]
kube_control_plane
kube_node
DOWNLOAD_EOF
        log "✅ 已生成 download-hosts.yml（本地 root，用于下载离线资源）"
    fi
    log "🎉 集群 [${CLUSTER_NAME}] 初始化完成! 下一步: 编辑 hosts.yml → $0 download ${CLUSTER_NAME}"
}

build_extra_vars() {
    EXTRA_VARS_STR=""
    # ⚠ k8s-versions.yml 必须在列: 它才是**版本钉子的单一来源**(kube_version/calico_version…)。
    #   不带它时两个 ansible 调用会各算一套版本 —— generate_list.sh 用 `-i <hosts.yml>` 拿得到
    #   它(经 inventory 的 group_vars), 而下面生成 URL→dest 映射的 play 用的是 `-i localhost,`
    #   (不加载任何 group_vars, 有意不碰集群), 于是 kube_version 退回**树里 checksum 表的第一
    #   个键**(v2.32 树 = 1.36.4)。后果: files.list 的 URL 是 v1.35.8, 映射表里却是 v1.36.4 →
    #   按 URL 查不到 → 全部退回 URL basename → kubelet/kubectl/kubeadm 被存成**没有版本号的
    #   `kubelet`/`kubectl`/`kubeadm`**(2026-09-28 实测), 装机时按 dl.dest 找不到, 离线必失败。
    for vars_file in \
        "${INVENTORY_DIR}/group_vars/all/offline.yml" \
        "${INVENTORY_DIR}/group_vars/all/all.yml" \
        "${INVENTORY_DIR}/group_vars/all/k8s-versions.yml" \
        "${INVENTORY_DIR}/group_vars/k8s_cluster/k8s-cluster.yml" \
        "${INVENTORY_DIR}/group_vars/k8s_cluster/addons.yml"; do
        if [ -f "$vars_file" ]; then
            # 跳过全注释/空文件/YAML文档分隔符文件，避免 ansible -e @ 解析失败
            # 使用 || true 避免 pipefail + local 触发 errexit
            local content
            content=$(grep -vE '^\s*(#|---|\.\.\.)' "$vars_file" | grep -v '^\s*$' | head -1) || true
            if [ -z "$content" ]; then
                warn "    跳过纯注释文件: $vars_file"
                continue
            fi
            EXTRA_VARS_STR="${EXTRA_VARS_STR} -e @${vars_file}"
            log "    加载变量文件: $vars_file"
        fi
    done
}

lookup_dest_from_map() {
    local search_url="$1"
    local map_file="$2"
    if [ -f "$map_file" ]; then
        grep -F "$search_url " "$map_file" 2>/dev/null | head -1 | awk '{print $2}'
    fi
}

cmd_download() {
    highlight "下载集群 [${CLUSTER_NAME}] 离线资源..."
    ensure_kubespray
    ensure_venv
    ensure_cluster_dirs

    DOWNLOAD_HOSTS_FILE="${DOWNLOAD_HOSTS:-${INVENTORY_DIR}/download-hosts.yml}"
    [ -f "${DOWNLOAD_HOSTS_FILE}" ] || err "Download hosts 不存在: ${DOWNLOAD_HOSTS_FILE}"

    runtime=$(detect_runtime)
    pull_cmd=$(get_pull_cmd "$runtime")
    save_cmd=$(get_save_cmd "$runtime")
    log "容器运行时: ${runtime}"

    build_extra_vars

    log "[1/4] 生成离线资源清单..."
    cd "${OFFLINE_CONTRIB}"
    bash generate_list.sh -i "${DOWNLOAD_HOSTS_FILE}" ${EXTRA_VARS_STR}
    [ -s "temp/images.list" ] || err "images.list 为空"
    [ -s "temp/files.list" ] || err "files.list 为空"

    log "    生成文件命名映射..."
    cd "${KUBESPRAY_DIR}"
    cat > /tmp/cubestack_map_dest.yml << 'PLAYBOOK_EOF'
- hosts: localhost
  become: false
  roles:
    - role: kubespray_defaults
      when: false
    - role: download
      when: false
  tasks:
    - name: Generate URL-to-dest mapping
      copy:
        content: |
          {% for key, dl in downloads.items() %}
          {% if not (dl.container | default(false)) and dl.url is defined and dl.dest is defined and dl.dest is not none %}
          {{ dl.url }} {{ dl.dest | basename }}
          {% endif %}
          {% endfor %}
        dest: "{{ mapping_file }}"
PLAYBOOK_EOF
    ansible-playbook --connection=local -i localhost, /tmp/cubestack_map_dest.yml \
        -e "mapping_file=${OFFLINE_CONTRIB}/temp/url_dest.map" \
        ${EXTRA_VARS_STR} || warn "URL→dest 映射生成有警告，继续..."
    rm -f /tmp/cubestack_map_dest.yml
    cd "${OFFLINE_CONTRIB}"
    [ -s "temp/url_dest.map" ] || warn "URL→dest 映射为空，将使用 URL basename"

    total_images=$(wc -l < "temp/images.list" | tr -d ' ')
    total_files=$(wc -l < "temp/files.list" | tr -d ' ')
    log "    镜像清单: ${total_images} 个, 文件清单: ${total_files} 个"

    log "[2/4] 下载容器镜像..."
    mkdir -p "${LOCAL_REPO_DIR}/images"

    count=0
    while IFS= read -r image; do
        [ -z "$image" ] && continue
        # 与 kubespray set_container_facts.yml 保持一致的文件名规则:
        # image_reponame | regex_replace('/|\0|:', '_') + '.tar'
        filename=$(echo "$image" | sed 's#/#_#g; s#:#_#g').tar
        dest="${LOCAL_REPO_DIR}/images/${filename}"
        count=$((count + 1))

        if [ -f "$dest" ]; then
            log "  [${count}/${total_images}] 已缓存: $image"
            continue
        fi

        log "  [${count}/${total_images}] 拉取: $image"
        retry=0
        while [ $retry -lt 5 ]; do
            if sudo $pull_cmd "$image" 2>&1; then
                break
            fi
            retry=$((retry + 1))
            warn "    重试 ${retry}/5: $image"
            if [ $retry -ge 5 ]; then
                err "镜像拉取失败: $image"
            fi
        done

        sudo $save_cmd -o "$dest" "$image"
        log "    保存: $filename"
    done < "temp/images.list"

    log "    镜像下载完成: $(ls "${LOCAL_REPO_DIR}/images/" | wc -l) 个"

    log "[3/4] 下载二进制文件..."
    url_dest_map="${OFFLINE_CONTRIB}/temp/url_dest.map"

    count=0
    while IFS= read -r url; do
        [ -z "$url" ] && continue
        count=$((count + 1))

        mapped_dest=$(lookup_dest_from_map "$url" "$url_dest_map")
        if [ -n "$mapped_dest" ]; then
            filename="$mapped_dest"
        else
            filename=$(basename "$url" | sed 's/[?#].*//')
            # 映射表按 URL 精确匹配缺失时退回 URL basename —— 该名字多半**不等于**树里这条的
            # dest(kubespray 用 `download_cache_dir/<dest | basename>` 找缓存文件), 装机时就
            # 找不到、转而联网下载, 离线必失败。常见根因是 files.list 与 url_dest.map 的版本
            # 不一致(见 build_extra_vars 里 k8s-versions.yml 的注释), 故把后果写在这里。
            warn "    $filename 未找到映射，使用 URL basename(⚠ 该名未必等于装机期望的 dest, 离线装机可能找不到它)"
        fi
        dest="${LOCAL_REPO_DIR}/${filename}"

        if [ -f "$dest" ]; then
            log "  [${count}/${total_files}] 已缓存: $filename"
            continue
        fi

        log "  [${count}/${total_files}] 下载: $filename"
        wget -q --show-progress -O "$dest" "$url" || err "下载失败: $url"
    done < "temp/files.list"

    log "    文件下载完成: $(find "${LOCAL_REPO_DIR}" -maxdepth 1 -type f | wc -l) 个"

    log "[4/4] 验证资源..."
    img_cnt=$(ls "${LOCAL_REPO_DIR}/images/" 2>/dev/null | wc -l)
    file_cnt=$(find "${LOCAL_REPO_DIR}" -maxdepth 1 -type f 2>/dev/null | wc -l)
    log "    镜像: ${img_cnt} 个, 文件: ${file_cnt} 个"
    log "🎉 集群 [${CLUSTER_NAME}] 离线资源下载完成!"
    log "   仓库: ${LOCAL_REPO_DIR}"
    log "   结构: images/ + 二进制文件（kubespray download_cache_dir 格式）"
}

# 预加载离线镜像到目标节点(all / kube_control_plane / kube_node)
# 必须先于 playbook 加载镜像: kubelet 启动 pod 时会尝试拉镜像,
# 离线环境下必须先 load 到 containerd, 否则 ImagePullBackOff / 启动慢
# 仅同步"部署 kubespray 最小镜像集合"(PRELOAD_IMAGE_PATTERNS 配置, 空=全量),
# 避免全量 rsync 大量无关镜像(cilium/flannel/ingress 等)拖慢部署
# 匹配规则: 条目含 ".tar" 为精确文件名匹配, 否则为文件名包含匹配
# 用 rsync 逐台同步(仅匹配镜像, --delete-excluded 清理目标残留) + 逐个镜像验证加载
# 解析预加载镜像文件清单(按 PRELOAD_IMAGE_PATTERNS 规则过滤 LOCAL_REPO_DIR/images/*.tar)
# 结果: 全局数组 PRELOAD_IMAGE_FILES; 同时写入 inventory/preload-images.lst,
# 供 cluster.yml/scale.yml 内置的镜像预加载 play 读取(空文件=无镜像可同步)
resolve_preload_image_files() {
    local patterns=(${PRELOAD_IMAGE_PATTERNS:-})
    PRELOAD_IMAGE_FILES=()
    local f p base matched
    if [ "${#patterns[@]}" -eq 0 ]; then
        # 全量同步(向后兼容): images/ 下所有 *.tar
        for f in "${LOCAL_REPO_DIR}"/images/*.tar; do
            [ -f "${f}" ] && PRELOAD_IMAGE_FILES+=("$(basename "${f}")")
        done
        log "  同步集合: 全量 ${#PRELOAD_IMAGE_FILES[@]} 个镜像(未配置 PRELOAD_IMAGE_PATTERNS)"
    else
        for f in "${LOCAL_REPO_DIR}"/images/*.tar; do
            [ -f "${f}" ] || continue
            base="$(basename "${f}")"
            matched=0
            for p in "${patterns[@]}"; do
                if [[ "${p}" == *".tar"* ]]; then
                    [ "${p}" = "${base}" ] && { matched=1; break; }
                else
                    [[ "${base}" == *"${p}"* ]] && { matched=1; break; }
                fi
            done
            [ "${matched}" = "1" ] && PRELOAD_IMAGE_FILES+=("${base}")
        done
        log "  同步集合: ${#PRELOAD_IMAGE_FILES[@]} 个镜像(最小集合: ${patterns[*]})"
    fi

    # ★ Ceph 离线镜像纳入 k8s 阶段预加载(与 kubespray 镜像同机制): CEPH_ENABLED=true 时把
    #   CEPH_IMAGE_DIR 的 *.tar(rook/ceph/cephcsi 等)一并写进 preload-images.lst,
    #   由 cluster.yml 内置预加载 play 同步到全部节点并 ctr import —— 替代 ceph 模块的
    #   ceph-sync-images.sh 独立同步, 统一在 k8s 部署阶段完成(需求)。
    # ⚠ 必须用**真实复制(cp)**, 不用软链/硬链: 离线文件需经 mc mirror 上传 MinIO 再下载分发,
    #   软链会被当小链接文件上传(下载回来是坏文件), 硬链虽传真实内容但在对象存储中无链接语义。
    #   真实复制后 images/ 目录全是普通文件, mc mirror / rsync / preload 均安全。
    #   幂等: 已存在且大小一致 → 跳过; 内容变化 → 覆盖。
    if [ "${CEPH_ENABLED:-false}" = "true" ]; then
        # ① 源目录存在 → 真实复制到 images/(不依赖软链, mc mirror 安全)
        if [ -n "${CEPH_IMAGE_DIR:-}" ] && [ -d "${CEPH_IMAGE_DIR}" ]; then
            mkdir -p "${LOCAL_REPO_DIR}/images"
            for f in "${CEPH_IMAGE_DIR}"/*.tar; do
                [ -f "${f}" ] || continue
                base="$(basename "${f}")"
                dst="${LOCAL_REPO_DIR}/images/${base}"
                if [ ! -f "${dst}" ] || [ "$(stat -c%s "${dst}" 2>/dev/null || echo 0)" != "$(stat -c%s "${f}")" ]; then
                    rm -f "${dst}"
                    cp "${f}" "${dst}" 2>/dev/null || warn "  ceph 镜像复制失败: ${base}"
                fi
                PRELOAD_IMAGE_FILES+=("${base}")
            done
        fi
        # ② 兜底: 源目录已删除(为省空间)时, images/ 中已有的 ceph tar 仍追加进清单(去重),
        #    保证新节点/扩容时 ceph 镜像不丢失
        for f in "${LOCAL_REPO_DIR}"/images/*.tar; do
            [ -f "${f}" ] || continue
            base="$(basename "${f}")"
            case "${base}" in *rook*|*ceph*|*csi-*) ;;
                *) continue ;;
            esac
            _in=0
            for _p in "${PRELOAD_IMAGE_FILES[@]:-}"; do [ "${_p}" = "${base}" ] && { _in=1; break; }; done
            [ "${_in}" = "0" ] && PRELOAD_IMAGE_FILES+=("${base}")
        done
        [ "${#patterns[@]}" -gt 0 ] && log "  ceph 体系开启(CEPH_ENABLED=${CEPH_ENABLED:-false} CEPH_CSI_ENABLED=${CEPH_CSI_ENABLED:-false}) → ceph 镜像并入预加载清单(源 ${CEPH_IMAGE_DIR:-<无>} / images/ 兜底)"
    fi

    # 写入 inventory 目录: 每行一个 tar 文件名; 空文件表示无镜像可同步
    # (playbook 仅在清单文件不存在时才回退为全量同步)
    {
        if [ "${#PRELOAD_IMAGE_FILES[@]}" -gt 0 ]; then
            printf '%s\n' "${PRELOAD_IMAGE_FILES[@]}"
        fi
    } > "${INVENTORY_DIR}/preload-images.lst" 2>/dev/null || \
        warn "无法写入镜像清单 ${INVENTORY_DIR}/preload-images.lst(playbook 预加载将回退为全量同步)"
}

preload_images() {
    local target="${1:-all}"
    log "预加载离线镜像到 ${target} 节点..."

    # ── 1. 解析预加载镜像文件列表(过滤 images/ 目录) ──
    resolve_preload_image_files
    local image_files=("${PRELOAD_IMAGE_FILES[@]}")

    if [ "${#image_files[@]}" -eq 0 ]; then
        warn "预加载: 未匹配到任何镜像(检查 PRELOAD_IMAGE_PATTERNS 或 ${PRELOAD_CONF})"
        return 0
    fi

    # 构建 rsync 过滤参数: 仅同步匹配镜像 + --delete-excluded 清理目标残留(断点续跑场景)
    local rsync_filter=()
    for f in "${image_files[@]}"; do
        rsync_filter+=(--include="${f}")
    done
    rsync_filter+=(--exclude='*')

    # 解析节点清单(含连接信息): 输出 "node|host|user|key" 每行
    local nodes_str
    nodes_str=$(ansible-inventory -i "${INVENTORY_DIR}/hosts.yml" --list 2>/dev/null | python3 -c '
import sys, json
inv = json.load(sys.stdin)
meta = inv.get("_meta", {}).get("hostvars", {})
target = "'"${target}"'"
groups = ["kube_control_plane", "kube_node"] if target == "all" else [target]
seen = set()
for g in groups:
    for h in inv.get(g, {}).get("hosts", []):
        if h in seen or h not in meta:
            continue
        seen.add(h)
        hv = meta[h]
        print("%s|%s|%s|%s" % (
            h,
            hv.get("ansible_host", h),
            hv.get("ansible_user", "ubuntu"),
            hv.get("ansible_ssh_private_key_file", "~/.ssh/cubestack_k8s"),
        ))
')

    local total=0 ok_sum=0 fail_nodes=0
    # 用 for 循环遍历(while read + 内部 ssh/rsync 会吞 stdin 导致只处理首行)
    local oldifs="${IFS}"
    IFS=$'\n'
    for line in ${nodes_str}; do
        IFS='|' read -r node host user key <<< "${line}"
        [ -z "${node}" ] && continue
        total=$((total + 1))
        log "  → [${node}](${host}) 同步并加载 ${#image_files[@]} 个镜像 ..."

        # 0. 确保节点侧 repository/images 目录存在(幂等)。
        #    根因: kubespray download role 的 "Upload image to node" 用
        #    ansible.posix.synchronize(rsync --rsync-path='sudo -u root rsync')
        #    把镜像 push 到节点 ${LOCAL_REPO_DIR}/images/, 但该目录不会被 playbook 自动创建;
        #    全新节点(scale 新 worker / 裸金属 worker)上不存在 → rsync 报
        #    "change_dir failed: No such file or directory" → 镜像没有全部同步成功。
        ssh -i "${key}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "${user}@${host}" "sudo mkdir -p '${LOCAL_REPO_DIR}/images'" >/dev/null 2>&1 || {
            warn "  ${node}: 创建节点侧仓库目录失败(${LOCAL_REPO_DIR}/images),跳过"
            fail_nodes=$((fail_nodes + 1))
            continue
        }

        # 1. rsync 仅同步匹配镜像(比 ansible copy 可靠)
        rsync -az --delete --delete-excluded --timeout=300 "${rsync_filter[@]}" \
            -e "ssh -i ${key} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
            "${LOCAL_REPO_DIR}/images/" "${user}@${host}:/tmp/cubestack-images/" 2>&1 || {
            warn "  ${node}: rsync 同步失败,跳过(见上方错误)"
            fail_nodes=$((fail_nodes + 1))
            continue
        }

        # 2. 逐个 import 所有 tar 并校验: 只统计真正导入成功的镜像,
        #    失败镜像单独告警(避免之前"按文件数计数"虚报成功导致部分镜像缺失)
        #    全新 VM 上 containerd 尚未安装(kubespray 下载角色才安装)时返回 SKIP, 优雅跳过
        local loaded
        loaded=$(ssh -i "${key}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "${user}@${host}" "sudo bash -c '
                command -v ctr >/dev/null 2>&1 || { rm -rf /tmp/cubestack-images; echo SKIP; exit 0; }
                ok=0; fail=0
                for f in /tmp/cubestack-images/*.tar; do
                    [ -f \"\$f\" ] || continue
                    if ctr -n k8s.io image import \"\$f\" >/dev/null 2>&1; then
                        ok=\$((ok + 1))
                    elif sleep 1 && ctr -n k8s.io image import \"\$f\" >/dev/null 2>&1; then
                        ok=\$((ok + 1))
                    else
                        fail=\$((fail + 1))
                        echo \"[FAIL] 导入失败: \$(basename \"\$f\")\" >&2
                        # 尝试获取失败原因(如磁盘空间不足/镜像名冲突)
                        ctr -n k8s.io image import \"\$f\" 2>&1 | head -3 >&2
                    fi
                done
                rm -rf /tmp/cubestack-images
                echo \$ok
            '" || echo 0)
        if [ "${loaded}" = "SKIP" ]; then
            warn "  ${node}: 节点上 containerd 未安装, 跳过镜像预加载(将由 kubespray 下载角色安装 containerd 并加载镜像)"
            continue
        fi
        ok_sum=$((ok_sum + loaded))
        log "  → ${node}: 成功加载 ${loaded} 个镜像"
    done
    IFS="${oldifs}"

    if [ "${total}" -eq 0 ]; then
        warn "预加载: 未解析到节点(inventory 可能为空)"
    else
        log "✅ 离线镜像预加载完成: ${total} 台节点, 失败 ${fail_nodes} 台, 共加载 ${ok_sum} 个镜像"
    fi
}

# 修复 artifacts 目录权限问题(kubectl_localhost/kubeconfig_localhost 用)
# 根因: kubespray 的 client role 用 `delegate_to: localhost + connection: local + become: false`
#       创建 artifacts 目录(mode 0750), 但在 play 全局 --become 下实际以 root 创建,
#       导致后续 fetch kubectl(become: false, 本地用户) 写目录时 Permission denied。
# 根治: patch kubespray 的 Create kube artifacts dir 任务 mode → 0777, 无论谁创建都可写。
fix_artifacts_perms() {
    # 1. patch kubespray client role: mode 0750 → 0777 (幂等, 只 patch 一次)
    local client_role="${KUBESPRAY_DIR}/roles/kubernetes/client/tasks/main.yml"
    if [ -f "${client_role}" ]; then
        if grep -q 'mode: "0777"' "${client_role}"; then
            log "✅ kubespray artifacts 权限已 patch(0777)"
        elif grep -q 'mode: "0750"' "${client_role}"; then
            sed -i 's/mode: "0750"/mode: "0777"/' "${client_role}"
            log "✅ 已 patch kubespray client role: artifacts 目录 mode 0750 → 0777"
        fi
    fi

    # 2. 清理旧 artifacts(避免 root 残留)
    local artifacts_dir="${INVENTORY_DIR}/artifacts"
    rm -rf "${artifacts_dir}" 2>/dev/null || sudo rm -rf "${artifacts_dir}" 2>/dev/null || true
    mkdir -p "${artifacts_dir}" 2>/dev/null || sudo mkdir -p "${artifacts_dir}" 2>/dev/null || true
    chmod 777 "${artifacts_dir}" 2>/dev/null || sudo chmod 777 "${artifacts_dir}" 2>/dev/null || true
    # 确保 inventory 目录可读写
    chmod -R u+rwX "${INVENTORY_DIR}" 2>/dev/null || true
}

# 确保 cluster.yml/scale.yml 已挂载镜像预加载 play(幂等)
# 背景: 预加载 play 位于 kubespray/patch-playbooks/(kubespray 升级/重新 clone 会丢失),
#       本函数在文件缺失时从内置内容重新生成, 并把 import 重新插回 playbook,
#       保证镜像同步逻辑在升级后依然生效(插入标记取自各版本稳定的 play 名称)
ensure_preload_play() {
    local preload_file="${KUBESPRAY_DIR}/patch-playbooks/cubestack-preload.yml"
# 生成 PRELOAD_EOF 内嵌内容(权威源; 由 _write_if_changed 决定是否落盘)
_gen_preload_play() {
    cat << 'PRELOAD_EOF'
---
# ═══════════════════════════════════════════════════════════════════════════
# cubestack-installer: 离线镜像预加载 play(cluster.yml / scale.yml 共用)
#
# 在 containerd 安装完成后, 将离线镜像从部署机缓存同步到目标节点并 load 进 containerd,
# 解决新节点 kube-proxy/calico 等镜像缺失问题。不硬编码任何路径或集群名:
#   · 镜像缓存目录: download_cache_dir / local_release_dir(入口脚本写入 offline.yml)
#   · 同步文件清单: {{ inventory_dir }}/preload-images.lst(入口脚本生成, 每行一个 tar 名)
#     清单不存在 → 回退为同步缓存目录下全部 *.tar; 空文件 → 无镜像可同步(跳过)
#
# 同步机制与 kubespray download role 的镜像上传一致: synchronize(use_ssh_args, push)
# 保证完全同步并 load 成功: 每个清单文件必须存在于节点且 ctr import 成功(最多重试 3 次),
# 任一镜像缺失或导入失败 → play 失败, 不会被静默跳过
# ═══════════════════════════════════════════════════════════════════════════
- name: Preload offline images to target nodes
  hosts: "{{ preload_target | default('k8s_cluster') }}"
  gather_facts: false
  environment: "{{ proxy_disable_env }}"
  roles:
    - { role: kubespray_defaults }
  tasks:
    - name: Preload | Resolve image file list (lst file or all tars in cache)
      set_fact:
        preload_image_files: >-
          {%- set raw = lookup('file', inventory_dir + '/preload-images.lst', errors='ignore') -%}
          {%- set lst = (raw if raw is string else '').splitlines() | select() | list -%}
          {%- if raw is string -%}
          {{ lst }}
          {%- else -%}
          {{ query('fileglob', download_cache_dir + '/images/*.tar') | map('basename') | sort | list }}
          {%- endif -%}

    - name: Preload | Build rsync include filter
      set_fact:
        # ceph 镜像以硬链接/复制并入 images/ 源目录(见 resolve_preload_image_files), 均为真实文件
        preload_rsync_opts: "{{ preload_image_files | map('regex_replace', '^(.*)$', '--include=\\1') | list + ['--exclude=*'] }}"
      when: preload_image_files | length > 0

    - name: Preload | Ensure node-side images directory
      file:
        path: "{{ local_release_dir }}/images"
        state: directory
        recurse: true
      when: preload_image_files | length > 0

    - name: Preload | Sync image tars from cache to node
      ansible.posix.synchronize:
        src: "{{ download_cache_dir }}/images/"
        dest: "{{ local_release_dir }}/images/"
        mode: push
        use_ssh_args: true
        rsync_opts: "{{ preload_rsync_opts }}"
      register: preload_sync
      until: preload_sync is succeeded
      retries: 2
      delay: 5
      when: preload_image_files | length > 0

    - name: Preload | Load images into containerd (逐镜像校验, 失败重试 3 次)
      shell: |
        set -euo pipefail
        files="{{ preload_image_files | join(' ') }}"
        total=$(wc -w <<< "${files}")
        ok=0
        rc=0
        i=0
        for f in ${files}; do
          i=$((i + 1))
          img="{{ local_release_dir }}/images/$f"
          if [ ! -f "$img" ]; then
            echo "  ✗ [$i/$total] $f: 节点缺少镜像文件(同步未完成或清单过期, 请重新运行入口脚本)"
            rc=1
            continue
          fi
          imported=0
          for attempt in 1 2 3; do
            if ctr -n k8s.io images import "$img" >/dev/null 2>&1; then
              imported=1
              break
            fi
            sleep $((attempt * attempt))
          done
          if [ "$imported" = "1" ]; then
            ok=$((ok + 1))
            echo "  ✓ [$i/$total] $f"
          else
            echo "  ✗ [$i/$total] $f: 3 次导入均失败"
            rc=1
          fi
        done
        echo "  预加载结果: ${ok}/${total} 个镜像导入成功"
        exit $rc
      args:
        executable: /bin/bash
      changed_when: false
      when: preload_image_files | length > 0
PRELOAD_EOF
}

    # 2026-10-08: 内嵌内容为权威 —— 缺失生成, 漂移即刷新(旧版不更新曾致实机缺口)
    _write_if_changed "${preload_file}" < <(_gen_preload_play)
        [ -f "${preload_file}" ] || { warn "无法生成 ${preload_file}, 跳过预加载 play 挂载"; return 0; }

    local py name
    for py in "${KUBESPRAY_DIR}/playbooks/cluster.yml" "${KUBESPRAY_DIR}/playbooks/scale.yml"; do
        [ -f "${py}" ] || continue
        name="$(basename "${py}")"
        if grep -q "cubestack-preload.yml" "${py}"; then
            log "✅ ${name} 已挂载镜像预加载 play"
            continue
        fi
        python3 - "${py}" "${name}" << 'PYEOF'
import sys
path, name = sys.argv[1], sys.argv[2]
src = open(path).read()
marker = {
    "cluster.yml": "- name: Install etcd",
    "scale.yml": '- name: Target only workers to get kubelet installed and checking in on any new nodes(node)',
}.get(name)
if not marker or marker not in src:
    print("marker not found, skip")
    sys.exit(0)
block = (
    "# ──────────────────────────────────────────────────────────────────────\n"
    "# 在 containerd 安装完成后, 预加载离线镜像到目标节点(解决新节点 kube-proxy/\n"
    "# calico 等镜像缺失问题)。同步/加载逻辑见 patch-playbooks/cubestack-preload.yml;\n"
    "# 镜像目录由入口脚本写入 offline.yml, 文件清单由入口脚本生成(preload-images.lst)。\n"
    "# 本 import 由入口脚本 ensure_preload_play 自动维护(kubespray 升级后重新挂载)\n"
    "# ──────────────────────────────────────────────────────────────────────\n"
)
if name == "scale.yml":
    block += (
        "- name: Preload offline images to scale nodes\n"
        "  vars:\n"
        "    preload_target: kube_node\n"
        "  import_playbook: ../patch-playbooks/cubestack-preload.yml\n"
    )
else:
    block += (
        "- name: Preload offline images to cluster nodes\n"
        "  import_playbook: ../patch-playbooks/cubestack-preload.yml\n"
    )
open(path, "w").write(src.replace(marker, block + "\n" + marker, 1))
print("patched")
PYEOF
        if grep -q "cubestack-preload.yml" "${py}"; then
            log "✅ 已挂载镜像预加载 play 到 ${name}"
        else
            warn "无法挂载镜像预加载 play 到 ${name}(未找到插入标记, kubespray 版本结构可能已变化)"
        fi
    done
}

# 将内置 registry 域名解析 play 注入 cluster.yml/scale.yml(幂等, 与 ensure_preload_play 同机制)
# 作用: 在节点 /etc/hosts 写入 "REGISTRY_IP REGISTRY_DOMAIN", 配合 containerd certs.d 信任,
#       实现集群内节点拉取 registry.cubestack.io:5000 镜像。变量由 group_vars/all/registry.yml 提供。
ensure_registry_play() {
    local py name
    for py in "${KUBESPRAY_DIR}/playbooks/cluster.yml" "${KUBESPRAY_DIR}/playbooks/scale.yml"; do
        [ -f "${py}" ] || continue
        name="$(basename "${py}")"
        if grep -q "cubestack-registry.yml" "${py}"; then
            log "✅ ${name} 已挂载 registry 节点 hosts play"
            continue
        fi
        python3 - "${py}" "${name}" << 'PYEOF'
import sys
path, name = sys.argv[1], sys.argv[2]
src = open(path).read()
marker = {
    "cluster.yml": "- name: Install etcd",
    "scale.yml": '- name: Target only workers to get kubelet installed and checking in on any new nodes(node)',
}.get(name)
if not marker or marker not in src:
    print("marker not found, skip")
    sys.exit(0)
block = (
    "# ──────────────────────────────────────────────────────────────────────\n"
    "# 在内置 registry(LoadBalancer)就绪前, 在节点 /etc/hosts 写入 registry 域名解析,\n"
    "# 配合 containerd certs.d HTTP 信任, 实现集群内节点拉取 registry.cubestack.io 镜像。\n"
    "# 本 import 由入口脚本 ensure_registry_play 自动维护(kubespray 升级后重新挂载)\n"
    "# ──────────────────────────────────────────────────────────────────────\n"
    "- name: Configure nodes /etc/hosts for internal registry\n"
    "  import_playbook: ../patch-playbooks/cubestack-registry.yml\n"
)
# 注: "单节点控制面污点收敛"play 原先是和上面这条一起插在这里的 —— 那是**错的**:
#     它要用 kubectl 读 /etc/kubernetes/admin.conf, 而此处还在 "Install etcd"/kubeadm 之前,
#     全新集群上 admin.conf 必然不存在(2026-09-28 实机中断在 mxgpu-3-28)。
#     现由 ensure_single_node_play 挂在"K8s+CNI 之后、addon 之前"(见该函数)。
open(path, "w").write(src.replace(marker, block + "\n" + marker, 1))
print("patched")
PYEOF
        if grep -q "cubestack-registry.yml" "${py}"; then
            log "✅ 已挂载 registry 节点 hosts play 到 ${name}"
        else
            warn "无法挂载 registry 节点 hosts play 到 ${name}(未找到插入标记, kubespray 版本结构可能已变化)"
        fi
    done
}

# 将"离线安装系统包(lvm2 等)"play 注入 cluster.yml/scale.yml(幂等, 与 ensure_registry_play 同机制)
# 作用: 在 k8s 部署阶段把 offline-files/os/packages 的 .deb(lvm2 全家桶等)自动
#       安装到全部 kube_node —— 供后续 ceph/Rook OSD 使用(重启后逻辑卷激活依赖 lvm)。
#       包来源与 lvm2 离线准备见 patch-playbooks/install-packages.yml 头部注释。
# 将"单节点集群控制面污点收敛"play 注入 cluster.yml/scale.yml(幂等, 与 ensure_cni_restart_play 同机制)
# ⚠ 位置必须在**控制面起来之后**:该 play 用 kubectl(`/etc/kubernetes/admin.conf`)数 control-plane 节点,
#   在 "Install etcd"/kubeadm 之前跑必然失败(2026-09-28 实机:全新集群全量部署中断在 mxgpu-3-28,
#   报 "stat /etc/kubernetes/admin.conf: no such file or directory")。旧实现把它和 registry hosts play
#   一起插在 "Install etcd" 之前 —— 那个位置对 registry(只写 /etc/hosts)无害, 对本 play 是错的;
#   scale.yml 场景(集群已存在)掩盖了这个 bug。现与 cubestack-cni-restart.yml 用同一组锚点。
ensure_single_node_play() {
    local py name
    for py in "${KUBESPRAY_DIR}/playbooks/cluster.yml" "${KUBESPRAY_DIR}/playbooks/scale.yml"; do
        [ -f "${py}" ] || continue
        name="$(basename "${py}")"
        # ① 迁移: 先摘掉任何位置的旧注入(含历史上插在 "Install etcd" 之前的那份)
        #    连同它自己的注释块一起摘 —— 否则每跑一次都会再堆一层注释(不幂等)。
        #    只回扫紧邻的注释行: 旧形态里 import 上面是 registry 的 import 行(非注释)⇒ 不会误伤它的注释。
        python3 - "${py}" << 'PYEOF'
import sys
path = sys.argv[1]
lines = open(path).read().splitlines(keepends=True)
out, removed = [], 0
for ln in lines:
    if "cubestack-single-node.yml" in ln:
        removed += 1
        if out and "Make single control-plane node schedulable" in out[-1]:
            out.pop()                      # 紧邻其上的 - name: 行
        while out and out[-1].lstrip().startswith("#"):
            out.pop()                      # 它自己的注释块
        continue
    out.append(ln)
if removed:
    open(path, "w").write("".join(out))
print("stripped %d" % removed)
PYEOF
        if grep -q "cubestack-single-node.yml" "${py}"; then
            log "✅ ${name} 已挂载单节点收敛 play"
            continue
        fi
        python3 - "${py}" "${name}" << 'PYEOF'
import re, sys
path, name = sys.argv[1], sys.argv[2]
src = open(path).read()
marker = {
    "cluster.yml": "- name: Install Kubernetes apps",
    "scale.yml": "- name: Apply resolv.conf changes now that cluster DNS is up",
}.get(name)
if not marker or marker not in src:
    print("marker not found, skip")
    sys.exit(0)
# ⚠ marker 前若有多个空行, 先收敛成一个 —— 否则"摘除→重挂"每跑一次会多留一行空行(不幂等)
src = re.sub(r"\n{3,}" + re.escape(marker), "\n\n" + marker, src)
block = (
    "# ──────────────────────────────────────────────────────────────────────\n"
    "# K8s+CNI 就绪后、addon/operator 之前: 若集群恰好 1 个 control-plane, 去掉它的\n"
    "# NoSchedule 污点并 uncordon(否则 metallb/local-path/registry/operator 等会一直 Pending)。\n"
    "# ⚠ 本 play 用 kubectl 读 admin.conf ⇒ 必须在控制面起来之后, **不要**挪到 etcd 之前。\n"
    "# 本 import 由入口脚本 ensure_single_node_play 自动维护(kubespray 升级后重新挂载)。\n"
    "# ──────────────────────────────────────────────────────────────────────\n"
    "- name: Make single control-plane node schedulable (before addon/operator)\n"
    "  import_playbook: ../patch-playbooks/cubestack-single-node.yml\n"
)
open(path, "w").write(src.replace(marker, block + "\n" + marker, 1))
print("patched")
PYEOF
        if grep -q "cubestack-single-node.yml" "${py}"; then
            log "✅ 已挂载单节点收敛 play 到 ${name}(K8s+CNI 之后)"
        else
            warn "无法挂载单节点收敛 play 到 ${name}(未找到插入标记, kubespray 版本结构可能已变化)"
        fi
    done
}

ensure_packages_play() {
    local py name packages_file="${KUBESPRAY_DIR}/patch-playbooks/install-packages.yml"
    # kubespray 升级/重新 clone 会丢失 patch-playbooks → 从内置内容重新生成(与 ensure_preload_play 同机制)
# 生成 PKG_EOF 内嵌内容(权威源; 由 _write_if_changed 决定是否落盘)
_gen_install_packages_play() {
    cat << 'PKG_EOF'
---
# ============================================================
# 离线安装**全部 k8s 节点**(worker + control-plane)的系统包(lvm2/curl/rsync/iptables 等)
# ⚠ 2026-09-30 根因修复: 原为 `hosts: kube_node`(**只 worker**)⇒ **master 从未拿到这批离线包**,
#   而 master 上 base 镜像没自带 curl ⇒ 依赖 curl 的检查/脚本全挂(实测: master01 缺 curl,
#   而 lvm2/rsync/iptables/ca-certificates 都在 —— 别处装过, curl 只在这条 play 里发)。
#   注意 master 在本项目里**也可能是 Ceph 存储节点**(CEPH_NODE_ROLE 默认 master)⇒ lvm 家族同样需要。
# 将 offline-files 中的 .deb 包复制到目标节点并安装
# 包来源: offline-files/os/packages/*.deb(**版本无关 OS 层**, 2026-10-08 起节点 .deb 统一收敛
#         到此目录; 原 <版本目录>/packages 与 packages/repair 已并入 —— 同名同版本去重)
# 路径说明: playbook 位于 kubespray/patch-playbooks/,
#           {{ offline_dir }}/../../os/packages = deployments/offline-files/os/packages
# 挂载: 由 cubestack-offline.sh ensure_packages_play 自动注入 cluster.yml/scale.yml
#       (k8s 部署阶段自动安装; kubespray 升级后自动重新挂载)。
# lvm2: 离线包由联网机 tools/offline/fetch-lvm-packages.sh 生成到共享 packages/ 目录;
#       未包含 lvm2 .deb 时仅告警不失败(其余包照常安装), 避免 packages/ 内容变化误失败。
# 用法(手动):
#   ansible-playbook -i <inventory> install-packages.yml
# ============================================================
- name: Install required packages on all cluster nodes (workers + control plane)
  hosts: kube_node:kube_control_plane
  gather_facts: false
  vars:
    # 必需包(唯一来源): 末尾断言按此校验; 上面的"资产预检"也按此检查 .deb 是否随离线件提供。
    required_packages:
      - iputils-ping
      - rsync
      - iptables
      - curl
      - ca-certificates
      - lvm2
      - dmsetup
      - dmeventd
      - libdevmapper1.02.1
      - libdevmapper-event1.02.1
      - thin-provisioning-tools
    # ★ 离线目录解析: 优先用 offline.yml 注入的 download_cache_dir(= LOCAL_REPO_DIR, 由
    #   cubestack-offline.sh 生成且 -e @offline.yml 全局可用), 保证与离线文件实际位置一致;
    #   容器/standalone 下 playbook_dir 相对路径会算到 deployments/kubespray/offline-files(不存在)。
    #   回退: 相对路径(inventory_dir | basename, 无硬编码)。
    offline_dir: "{{ download_cache_dir | default(playbook_dir + '/../../offline-files/kubespray') }}"
    # ★ 2026-10-08: 节点 .deb 统一收敛到 offline-files/os/packages(版本无关 OS 层, 见该目录 README);
    #   原 <版本目录>/packages 与 packages/repair 已并入(同名同版本去重), repair 白名单 find 一并取消。
    packages_dirs:
      - "{{ offline_dir }}/../../os/packages"

  tasks:
    - name: Ensure /tmp/packages directory exists on target
      file:
        path: /tmp/packages
        state: directory

    - name: Find offline .deb packages (os/packages)
      find:
        paths: "{{ packages_dirs }}"
        patterns: "*.deb"
        file_type: file
      delegate_to: localhost
      register: deb_files

    - name: Copy offline .deb packages to target
      # ★ 不能 delegate_to: localhost —— 那样 src/dest 都解析为控制器路径, 只会把 .deb 原地复制到
      #   控制器 /tmp/packages, 节点永远收不到(此前 dpkg 报 cannot access archive)。
      #   不 delegate 时任务在目标节点执行, copy 自动从控制器(src)拉取到节点(dest), 这才是跨主机传输。
      copy:
        src: "{{ item.path }}"
        dest: /tmp/packages/
      loop: "{{ deb_files.files | default([]) }}"
      when: (deb_files.files | default([])) | length > 0

    - name: Install packages from local files (逐包安装, 单包失败不阻断)
      # ★ 逐个 dpkg -i + ignore_errors: 任何单个包失败(如 skopeo 缺 golang-github-containers-common /
      #   libgpgme11, sysstat 缺 libsensors5)都只记失败、不中断整个 k8s 部署 —— 需要与否由下方
      #   "Verify required packages" 按必需包校验(仅 base 工具 + lvm 家族, 非全部 .deb)。
      # ★ 2026-09-24 事故修复(实机: ansible 任务"有时候卡在这里很长时间", 实测卡 38 分钟以上):
      #   链式根因 —— dpkg -i dmsetup/lvm2 → initramfs-tools.postinst → `update-initramfs -u`
      #   → mkinitramfs → hooks/mdadm → `mdadm --examine --scan`(遍历**所有**块设备)
      #   → 读到**上一代集群遗留、后端已不可达的 /dev/rbd0** → 进程进 D 状态(不可中断), 永不返回;
      #   同一节点上还有 ext4 挂在那块 rbd 上, 其 jbd2 线程也一并卡死(实测 [registry] 内核线程
      #   D 态 1h37m)。8 台里只有 2 台(3-33/3-36)有该残留 → 于是表现为"有时候"卡住。
      #   两层修复:
      #     ① **安装期间禁用 initramfs 重建**(update_initramfs=no, 装完恢复): 我们发的包
      #        (lvm2/dmsetup 家族)在这些节点上**不需要**重建 initrd(内核没变、root 不在 LVM 上),
      #        而重建会把 initramfs 的所有 hooks 跑一遍(pvscan/vgscan/mdadm 都会扫设备)——
      #        只要有 hang 住的块设备就必卡。禁用后这条链根本不会被触发。
      #     ② **已安装且版本相同 → 跳过**: 之前每次部署都对同一批 .deb 重跑 dpkg -i,
      #        不仅重复触发 postinst/触发器链, 也在无谓地消耗时间。
      shell: |
        set -u
        ir_conf=/etc/initramfs-tools/update-initramfs.conf
        ir_backup=""
        if [ -f "${ir_conf}" ] && ! grep -qE '^[[:space:]]*update_initramfs[[:space:]]*=[[:space:]]*no' "${ir_conf}"; then
          ir_backup="$(mktemp)"
          cp -a "${ir_conf}" "${ir_backup}"
          if grep -qE '^[[:space:]]*update_initramfs=' "${ir_conf}"; then
            sed -i -E 's|^[[:space:]]*update_initramfs=.*|update_initramfs=no|' "${ir_conf}"
          else
            echo 'update_initramfs=no' >> "${ir_conf}"
          fi
          echo "[install-packages] 本次安装期间已禁用 initramfs 重建(避免 mdadm/lvm hooks 扫描块设备而卡死)"
        fi
        n_rbd="$(ls -1 /sys/bus/rbd/devices 2>/dev/null | wc -l | tr -d ' ')"
        if [ "${n_rbd:-0}" -gt 0 ]; then
          echo "[install-packages] ⚠ 本节点存在 ${n_rbd} 个内核 rbd 映射 —— 若其后端已不可达, 任何设备扫描都会卡死; 见 docs/troubleshooting.md"
        fi
        # ★ 2026-09-29(用户要求: 装之前先修 apt)—— **离线安全版**:
        #   `apt --fix-broken install` / `apt-get -f install` 在纯离线节点上会去抓缺失的包并失败
        #   (实机: `E: Unable to fetch some archives`), 所以这里只做**不需要网络**的两步:
        #     ① `dpkg --configure -a`        —— 把"解包未配置"(iU)的包配上(依赖已在场时才可能成功)
        #     ② `apt-get -f install --no-download` —— 只用 /var/cache/apt/archives 里已有的包补依赖
        #   两步都 best-effort 不阻断; 真正"缺依赖且离线补不到"的可选包由下方回滚逻辑兜底。
        dpkg --configure -a >/dev/null 2>&1 || true
        apt-get -f install --no-download -y >/dev/null 2>&1 || true
        dpkg --configure -a >/dev/null 2>&1 || true
        failed=""
        skipped=""
        attempted=""
        for deb in /tmp/packages/*.deb; do
          [ -e "${deb}" ] || continue
          pkg="$(dpkg-deb -f "${deb}" Package 2>/dev/null)"
          newver="$(dpkg-deb -f "${deb}" Version 2>/dev/null)"
          curstat="$(dpkg-query -W -f='${db:Status-Abbrev}|${Version}' "${pkg}" 2>/dev/null || true)"
          # ★ 2026-09-28 事故修复(实机): 判据原为"**已装且版本相同**才跳过" ⇒ 版本不同的离线包
          #   会被覆盖安装 —— 本仓库的 libudev1_…3.22 就这么把节点的 libudev1(3.12)升了级,
          #   而节点的 udev 仍是 3.12 且**严格依赖 `libudev1 (= 3.12)`** ⇒ dpkg 依赖被打破,
          #   该节点上**任何 apt 操作都失败**(E: Unmet dependencies)⇒ 下次部署在 bootstrap_os →
          #   system_packages 的 "Manage packages" 上死掉(且报错只提 udev, 根因在几轮之前)。
          #   现改为与 tools/node/install-worker-packages.sh 同一条经过验证的规则:
          #   **远端已装同名包(任意版本) ⇒ 一律跳过**(宁缺毋滥, 绝不拿离线包去动节点已装的系统包);
          #   需要"升级"时走 apt, 不走这套离线 .deb。必需包**是否在场**由下方 Verify required packages 校验。
          if [ -n "${pkg}" ] && [ -n "${newver}" ] && [ "${curstat#ii }" != "${curstat}" ]; then
            skipped="${skipped} ${pkg}"
            continue
          fi
          attempted="${attempted} ${deb}"
          dpkg -i "${deb}" >/dev/null 2>&1 || true
        done
        # ★ 2026-09-29 根因修复(第二层): 逐个 dpkg -i 时, **依赖包排在后面就必然先失败** ——
        #   curl 依赖 libcurl4, 而字典序 `curl_*` 在 `libcurl4_*` 之前 ⇒ curl 首轮必失败、
        #   libcurl4 紧随其后装上, 结果 curl 始终缺失(在自带 curl 的镜像上被掩盖)。
        #   这里把首轮**没装上**的包**成组再装一次**: 同一次 dpkg -i 调用内 dpkg 会自行排序,
        #   满足批内依赖。
        retry=""
        for deb in ${attempted}; do
          pkg="$(dpkg-deb -f "${deb}" Package 2>/dev/null)"
          dpkg-query -W -f='${db:Status-Abbrev}' "${pkg}" 2>/dev/null | grep -q '^ii' || retry="${retry} ${deb}"
        done
        if [ -n "${retry}" ]; then
          # shellcheck disable=SC2086
          dpkg -i ${retry} >/dev/null 2>&1 || true
        fi
        # ★ 2026-09-29 根因修复(第三层; 实机: 精简 VM 上 sysstat 卡在 `iU` ⇒ apt 依赖图破损 ⇒
        #   node_pkgs 对账硬失败、整个部署中断):
        #   可选包的**依赖没随离线件提供**时, dpkg -i 会把它留在"解包未配置"(iU) —— 这不止是该包
        #   不可用, 还会**弄坏 apt 依赖图**(之后任何 apt 操作都报 Unmet dependencies), 而离线节点上
        #   apt 补不回来(要联网抓包) ⇒ **回滚**: 把尝试过却没配起来的包 purge 掉, 恢复 apt 健康,
        #   并明确打印"缺哪个依赖 → 应补哪个 deb 进 packages/"。最终成功与否一律按**实际安装状态**
        #   (dpkg-query 的 `ii`)判定, 不看 dpkg 退出码。
        rolled=""
        for deb in ${attempted}; do
          pkg="$(dpkg-deb -f "${deb}" Package 2>/dev/null)"
          [ -n "${pkg}" ] || continue
          st="$(dpkg-query -W -f='${db:Status-Abbrev}' "${pkg}" 2>/dev/null || true)"
          case "${st}" in
            ii*) continue ;;                                            # 装好
            "")  failed="${failed} $(basename "${deb}")"; continue ;;    # 根本没落进 dpkg
          esac
          miss=""
          for d in $(dpkg-deb -f "${deb}" Depends 2>/dev/null | tr ',' '\n' \
                     | sed 's/([^)]*)//g; s/|.*//g; s/[[:space:]]//g'); do
            [ -n "${d}" ] || continue
            dpkg-query -W -f='${db:Status-Abbrev}' "${d}" 2>/dev/null | grep -q '^ii' || miss="${miss} ${d}"
          done
          if dpkg --purge "${pkg}" >/dev/null 2>&1; then
            rolled="${rolled} ${pkg}(缺:${miss:-未知})"
          else
            failed="${failed} ${pkg}(回滚失败)"
          fi
        done
        if [ -n "${ir_backup}" ] && [ -f "${ir_backup}" ]; then
          cp -a "${ir_backup}" "${ir_conf}"; rm -f "${ir_backup}"
        fi
        rm -rf /tmp/packages
        [ -n "${skipped}" ] && echo "[install-packages] 已装(任意版本) ⇒ 跳过(不改动节点已装系统包):${skipped}"
        if [ -n "${rolled}" ]; then
          echo "⚠ 以下可选包因**依赖未随离线件提供**装不全, 已回滚(purge)以保住 apt 依赖图健康:${rolled}"
          echo "   ↳ 修法: 把这些依赖的 .deb 也放进 packages/(或在联网机把它们加进 tools/offline/fetch-lvm-packages.sh 的清单后重跑)"
        fi
        if [ -n "${failed}" ]; then
          echo "⚠ 以下包安装失败且未能回滚(请人工确认, 会影响 apt 依赖图):${failed}"
        fi
      become: true
      ignore_errors: true
      when: deb_files.files | length > 0

    - name: Derive expected package names from shipped .deb files
      # deb 文件名 <name>_<version>_<arch>.deb → 包名(如 lvm2_2.03.11-2.1ubuntu2_amd64.deb → lvm2)
      set_fact:
        expected_packages: >-
          {{ (deb_files.files | default([]))
             | map(attribute='path') | map('basename') | map('regex_replace', '_.*', '') | unique | list }}
      when: (deb_files.files | default([])) | length > 0

    - name: Warn when lvm2 offline package is not shipped
      debug:
        msg: >-
          ⚠ os/packages 未包含 lvm2 离线包 —— 存储节点无法离线安装 lvm2
          (Rook OSD 重启后需 lvm 激活逻辑卷)。请先在联网机执行
          tools/offline/fetch-lvm-packages.sh 并把 .deb 放到 os/packages 目录。
      when:
        - deb_files.files | length > 0
        - "'lvm2' not in expected_packages"

    - name: "Precheck: 必需包必须随离线件提供 .deb(缺失则立刻停, 不等节点断言)"
      # ★ 2026-09-29 加: 这条把"离线件缺包"从**节点上的断言失败**(在 3 台机器上刷屏、看不出该补什么)
      #   提前成**起点处的明确报错**。本文件历史上就吃过一次: required_packages 里有 curl,
      #   而 curl 的 .deb 只在 packages/repair/(find 不递归扫不到) ⇒ 精简 VM 上必失败。
      #   (2026-10-08 repair/ 并入 os/packages 后此坑自动消失, 断言保留作一般防护)
      assert:
        that:
          - item in (expected_packages | default([]))
        fail_msg: >-
          ❌ 必需包 {{ item }} 没有对应的 .deb 随离线件提供(它会缺席节点, 并让本 play 末尾的断言失败)。
          修法: 把 {{ item }} 的 .deb 放进 offline-files/os/packages/(联网机下载后同步该目录)。
        success_msg: "必需包 {{ item }} 的 .deb 已随离线件提供"
      loop: "{{ required_packages }}"
      when: (deb_files.files | default([])) | length > 0

    - name: Verify required packages
      package_facts:
        manager: apt
      when: deb_files.files | length > 0

    - name: "Check installation status (仅必需包: base 工具 + lvm 家族; skopeo/sysstat 等可选包失败不阻断)"
      assert:
        that:
          - item in ansible_facts.packages
        fail_msg: "Required package missing on {{ inventory_hostname }}: {{ item }}"
        success_msg: "All required packages installed on {{ inventory_hostname }}"
      loop: "{{ required_packages }}"
      when: (deb_files.files | default([])) | length > 0
PKG_EOF
}

    # 2026-10-08: 内嵌内容为权威 —— 缺失生成, 漂移即刷新(旧版不更新曾致实机缺口)
    _write_if_changed "${packages_file}" < <(_gen_install_packages_play)
    for py in "${KUBESPRAY_DIR}/playbooks/cluster.yml" "${KUBESPRAY_DIR}/playbooks/scale.yml"; do
        [ -f "${py}" ] || continue
        name="$(basename "${py}")"
        if grep -q "install-packages.yml" "${py}"; then
            log "✅ ${name} 已挂载系统包安装 play"
            continue
        fi
        python3 - "${py}" "${name}" << 'PYEOF'
import sys
path, name = sys.argv[1], sys.argv[2]
src = open(path).read()
marker = {
    "cluster.yml": "- name: Install etcd",
    "scale.yml": '- name: Target only workers to get kubelet installed and checking in on any new nodes(node)',
}.get(name)
if not marker or marker not in src:
    print("marker not found, skip")
    sys.exit(0)
block = (
    "# ──────────────────────────────────────────────────────────────────────\n"
    "# 离线安装系统包(lvm2 全家桶等): 把 offline-files/os/packages 的 .deb\n"
    "# 装到全部 kube_node, 供后续 ceph/Rook OSD 使用(重启后逻辑卷激活依赖 lvm)。\n"
    "# 本 import 由入口脚本 ensure_packages_play 自动维护(kubespray 升级后重新挂载)\n"
    "# ──────────────────────────────────────────────────────────────────────\n"
    "- name: Install offline packages (lvm2 etc.) on kube nodes\n"
    "  import_playbook: ../patch-playbooks/install-packages.yml\n"
)
open(path, "w").write(src.replace(marker, block + "\n" + marker, 1))
print("patched")
PYEOF
        if grep -q "install-packages.yml" "${py}"; then
            log "✅ 已挂载系统包安装 play 到 ${name}"
        else
            warn "无法挂载系统包安装 play 到 ${name}(未找到插入标记, kubespray 版本结构可能已变化)"
        fi
    done
}

# 将"重启 containerd + kubelet 确保 CNI 初始化"play 注入 cluster.yml/scale.yml(幂等)
# 作用: 在 Kubernetes+CNI 部署完成后、metallb 等 operator 安装前重启节点容器运行时,
#       解决 containerd 因残留/缺失 /etc/cni/net.d 而标记 CNI 未初始化导致的节点
#       NotReady(表现为 apiserver 访问其他节点 pod 超时 → admission webhook 失败)。
ensure_cni_restart_play() {
    local restart_file="${KUBESPRAY_DIR}/patch-playbooks/cubestack-cni-restart.yml"
# 生成 CNI_EOF 内嵌内容(权威源; 由 _write_if_changed 决定是否落盘)
_gen_cni_restart_play() {
    cat << 'CNI_EOF'
---
# ═══════════════════════════════════════════════════════════════════════════
# cubestack-installer: 重启 containerd + kubelet, 确保 CNI 插件初始化
#
# 在 Kubernetes 部署完成(CNI 已安装)、metallb 等 operator 安装之前执行, 保证
# 集群跨节点网络正常。根因: 节点 NotReady / apiserver 无法访问其他节点 pod 时,
# 各类 admission webhook 调用会超时(如 MetalLB "context deadline exceeded")。
#
# 根因: containerd 启动时读取 /etc/cni/net.d 初始化 CNI 插件; 若 reset 删除过
#       该目录(或首次部署时 CNI 未就绪), containerd 标记 CNI 未初始化,
#       calico 之后创建配置也不会重新加载 → 节点 NotReady。
#
# 挂载位置: cluster.yml / scale.yml 中"安装 Kubernetes + CNI"之后、
#           "Install Kubernetes apps"(metallb 等 operator)之前。
# 由入口脚本 ensure_cni_restart_play 自动维护(kubespray 升级后重新挂载)。
#
# 顺序: 先重启 worker 再串行重启 control-plane(尽量缩短 apiserver 中断窗口),
#       结束时等待 apiserver 就绪, 保证后续 kubernetes-apps 正常执行。
# ═══════════════════════════════════════════════════════════════════════════
- name: Restart containerd + kubelet on worker nodes (re-init CNI)
  hosts: kube_node
  gather_facts: false
  any_errors_fatal: false
  environment: "{{ proxy_disable_env }}"
  roles:
    - { role: kubespray_defaults }
  tasks:
    - name: Restart kubelet then containerd (re-init CNI plugins)
      ansible.builtin.shell: |
        systemctl restart kubelet
        sleep 5
        systemctl restart containerd
      args:
        executable: /bin/bash
      register: cni_restart_worker
      ignore_errors: true
      changed_when: false
    - name: Warn if worker restart failed
      ansible.builtin.debug:
        msg: "节点 {{ inventory_hostname }} kubelet/containerd 重启失败(rc={{ cni_restart_worker.rc | default('N/A') }}), 可手动执行: systemctl restart containerd && systemctl restart kubelet"
      when: cni_restart_worker is failed

- name: Restart containerd + kubelet on control-plane nodes (re-init CNI)
  hosts: kube_control_plane
  serial: 1
  gather_facts: false
  any_errors_fatal: false
  environment: "{{ proxy_disable_env }}"
  roles:
    - { role: kubespray_defaults }
  tasks:
    - name: Restart kubelet then containerd (re-init CNI plugins)
      ansible.builtin.shell: |
        systemctl restart kubelet
        sleep 5
        systemctl restart containerd
      args:
        executable: /bin/bash
      register: cni_restart_master
      ignore_errors: true
      changed_when: false
    - name: Warn if control-plane restart failed
      ansible.builtin.debug:
        msg: "节点 {{ inventory_hostname }} kubelet/containerd 重启失败(rc={{ cni_restart_master.rc | default('N/A') }}), 可手动执行: systemctl restart containerd && systemctl restart kubelet"
      when: cni_restart_master is failed

- name: Wait for kube-apiserver to be healthy after node restarts
  hosts: kube_control_plane[0]
  gather_facts: false
  any_errors_fatal: false
  environment:
    KUBECONFIG: "{{ kube_config_dir }}/admin.conf"
  roles:
    - { role: kubespray_defaults }
  tasks:
    - name: Wait for apiserver readyz (up to 5 minutes)
      ansible.builtin.shell: |
        for i in $(seq 1 60); do
          {{ bin_dir }}/kubectl get --raw /readyz >/dev/null 2>&1 && exit 0
          sleep 5
        done
        echo "apiserver 在 5 分钟内未恢复就绪" >&2
        exit 1
      args:
        executable: /bin/bash
      register: cni_apiserver_wait
      changed_when: false
CNI_EOF
}

    # 2026-10-08: 内嵌内容为权威 —— 缺失生成, 漂移即刷新(旧版不更新曾致实机缺口)
    _write_if_changed "${restart_file}" < <(_gen_cni_restart_play)
        [ -f "${restart_file}" ] || { warn "无法生成 ${restart_file}, 跳过 CNI 重启 play 挂载"; return 0; }

    local py name
    for py in "${KUBESPRAY_DIR}/playbooks/cluster.yml" "${KUBESPRAY_DIR}/playbooks/scale.yml"; do
        [ -f "${py}" ] || continue
        name="$(basename "${py}")"
        if grep -q "cubestack-cni-restart.yml" "${py}"; then
            log "✅ ${name} 已挂载 CNI 重启 play"
            continue
        fi
        python3 - "${py}" "${name}" << 'PYEOF'
import sys
path, name = sys.argv[1], sys.argv[2]
src = open(path).read()
marker = {
    "cluster.yml": "- name: Install Kubernetes apps",
    "scale.yml": "- name: Apply resolv.conf changes now that cluster DNS is up",
}.get(name)
if not marker or marker not in src:
    print("marker not found, skip")
    sys.exit(0)
block = (
    "# ──────────────────────────────────────────────────────────────────────\n"
    "# 在 Kubernetes + CNI 部署完成后、metallb 等 operator 安装之前, 重启\n"
    "# containerd + kubelet, 确保 CNI 插件初始化(解决节点 NotReady / webhook 超时)。\n"
    "# 逻辑见 patch-playbooks/cubestack-cni-restart.yml; 由入口脚本\n"
    "# ensure_cni_restart_play 自动维护(kubespray 升级后重新挂载)。\n"
    "# ──────────────────────────────────────────────────────────────────────\n"
    "- name: Restart containerd + kubelet to (re)init CNI plugins\n"
    "  import_playbook: ../patch-playbooks/cubestack-cni-restart.yml\n"
)
open(path, "w").write(src.replace(marker, block + "\n" + marker, 1))
print("patched")
PYEOF
        if grep -q "cubestack-cni-restart.yml" "${py}"; then
            log "✅ 已挂载 CNI 重启 play 到 ${name}"
        else
            warn "无法挂载 CNI 重启 play 到 ${name}(未找到插入标记, kubespray 版本结构可能已变化)"
        fi
    done
}

# 修复 kubespray download role 镜像上传同步缺目录问题(幂等)
# 根因: download_container.yml 的 "Upload image to node" 用 ansible.posix.synchronize(rsync)
#       把镜像 push 到节点 ${local_release_dir}/images/, 但该目录不会被自动创建,
#       全新节点(scale 新 worker / 裸金属 worker)上 rsync 报 "change_dir failed:
#       No such file or directory" → 镜像没有全部同步成功。
# 根治: 在 Upload 任务前插入 "Create dest directory" 任务(与 download_file.yml 一致),
#       使 ansible-playbook 自身就能全量同步, 不依赖 preload 预建目录。
fix_download_sync_dirs() {
    local dcf="${KUBESPRAY_DIR}/roles/download/tasks/download_container.yml"
    [ -f "${dcf}" ] || { warn "未找到 ${dcf},跳过 patch"; return 0; }
    if grep -q "Download_container | Create dest directory for image upload" "${dcf}"; then
        log "✅ kubespray download_container 已 patch(上传前创建目标目录)"
        return 0
    fi
    python3 - "${dcf}" << 'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
marker = "    - name: Download_container | Upload image to node if it is cached"
if "Download_container | Create dest directory for image upload" in src:
    sys.exit(0)
assert marker in src, f"marker not found in {path}"
insert = (
    "    - name: Download_container | Create dest directory for image upload\n"
    "      file:\n"
    "        path: \"{{ image_path_final | dirname }}\"\n"
    "        state: directory\n"
    "        recurse: true\n"
    "      when:\n"
    "        - pull_required\n"
    "        - download_force_cache\n"
    "\n"
)
open(path, "w").write(src.replace(marker, insert + marker, 1))
print("patched")
PYEOF
    log "✅ 已 patch kubespray download_container.yml: 镜像上传前创建目标目录"
}

# 修复 kubespray download 角色中 dnsautoscaler / metrics_server 镜像的 groups 配置(幂等)
# 根因: 这两个镜像的 group 仅包含 kube_control_plane(master 节点), 不包含 k8s_cluster,
#       导致 kubespray 的 download role 只把镜像推到 master, 不推 worker 节点。
#       当 pod 调度到 worker 时, 镜像不存在 → kubelet 尝试外网拉取 → 离线环境超时 → ImagePullBackOff。
# 根治: 在 groups 中追加 k8s_cluster, 使 playbook 将镜像推送到所有节点。
fix_download_groups() {
    local dcf="${KUBESPRAY_DIR}/roles/kubespray_defaults/defaults/main/download.yml"
    [ -f "${dcf}" ] || { warn "未找到 ${dcf},跳过 patch"; return 0; }
    local result
    result=$(python3 - "${dcf}" << 'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
changed = False
for key in ("dnsautoscaler", "metrics_server"):
    marker = f"  {key}:"
    idx = src.find(marker)
    if idx < 0:
        continue
    # 检查 groups 块中是否已有 k8s_cluster(幂等)
    groups_pos = src.find("    groups:", idx)
    if groups_pos < 0:
        continue
    # 从 groups 行之后到下一个顶层 key 之间查找
    blk_start = src.find("\n", groups_pos) + 1
    blk_end = src.find("\n\n  ", blk_start)  # 空行 + 下一个顶层 key
    if blk_end < 0:
        blk_end = len(src)
    groups_block = src[blk_start:blk_end]
    if "k8s_cluster" in groups_block:
        continue  # 已包含, 跳过
    if "kube_control_plane" in groups_block:
        insert_pos = src.find("      - kube_control_plane", groups_pos)
        if insert_pos >= 0:
            nl = src.find("\n", insert_pos)
            src = src[:nl+1] + "      - k8s_cluster\n" + src[nl+1:]
            changed = True
if changed:
    open(path, "w").write(src)
    print("patched")
else:
    print("no change needed")
PYEOF
) 2>/dev/null
    case "${result}" in
        *patched*) log "✅ kubespray download groups 已 patch(dnsautoscaler/metrics_server 追加 k8s_cluster)" ;;
        *) log "✅ kubespray download groups 已包含 k8s_cluster(幂等跳过)" ;;
    esac
}

# ============================================================
# 依据 hosts.yml 自动同步 kubespray group_vars 中的环境 IP(与 inventory 同源)
#   group_vars/all/all.yml
#     loadbalancer_apiserver.address            = 本次的 API 入口(阶段一=第一个 master / 阶段二=VIP),
#                                                 **以 all.yml 现值 + sync-kubespray-config.sh 的判定为准**
#     apiserver_loadbalancer_domain_name        = 保持 all.yml 现有值(默认 lb.k8s.local)
#     supplementary_addresses_in_ssl_keys       = API 域名 + 全部 master 节点 IP
#   group_vars/k8s_cluster/k8s-cluster.yml
#     kube_apiserver_extra_args.advertise-address = **按节点各写各的**(Jinja 表达式, 不再同步具体 IP)
#   group_vars/k8s_cluster/k8s-net-calico.yml
#     calico_ip_auto_method: can-reach=<第一个 worker IP>(无 worker 时回退第一个 master)
# 数据源: 全部节点 IP 来自 hosts.yml(kube_control_plane / kube_node 组), 随 inventory 自动更新
# ============================================================
update_loadbalancer_all_yml() {
    # ★ 本地代理模式(API_LOCAL_LB_ENABLED=true, 兼容别名 KUBE_VIP_LOCAL_PROXY): all.yml 的
    #   loadbalancer_apiserver 块由 tools/k8s/sync-kubespray-config.sh **独占维护并保持注释**。
    #   本函数是 all.yml 的**第二个写入者** —— 若按"读不到入口就回退首 master 并写回", 会把注释
    #   恢复成未注释态 → 上游 kube_apiserver_endpoint 模板随即走域名分支 → 本地代理**静默失效**
    #   (看着装好了, kubelet 仍走域名单点)。故本地代理模式下**只跳过 all.yml 那一段**。
    #   ⚠ 不整体 return: 下面第 2/3 段(k8s-cluster.yml 的 advertise-address 按节点取值、
    #     calico can-reach 探测点)与入口模式无关, 跳掉会让 kubernetes Service 退回单点 /
    #     calico 探测点漂移 —— 那是另外两个静默故障。
    #   ⚠ 本脚本**不 source lib-common**, 故用最小解析而非 api_local_lb_enabled():
    #     环境变量优先, 否则子 shell 求值 cluster.conf(与 check-modules.sh 第 ⑫ 项同法)。
    local _local_lb="${API_LOCAL_LB_ENABLED:-}"
    if [ -z "${_local_lb}" ]; then
        local _conf="${REPO_ROOT:-}/deployments/config/cluster.conf"
        [ -f "${_conf}" ] || _conf="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/deployments/config/cluster.conf"
        if [ -f "${_conf}" ]; then
            _local_lb="$( ( set +u; . "${_conf}" >/dev/null 2>&1 || true
                            printf '%s' "${API_LOCAL_LB_ENABLED:-${KUBE_VIP_LOCAL_PROXY:-false}}" ) )"
        else
            _local_lb="false"
        fi
    fi
    local _skip_all_yml=0
    case "${_local_lb}" in
        1|true|yes|on) _skip_all_yml=1 ;;
    esac

    local inv="${INVENTORY_DIR}/hosts.yml"
    local all_yml="${INVENTORY_DIR}/group_vars/all/all.yml"
    [ -f "${inv}" ] || { warn "未找到 ${inv}, 跳过 hosts.yml 同步"; return 0; }

    # 收集 kube_control_plane(master) 与 kube_node(worker) 节点 IP(优先 access_ip, 兜底 ip), 去重
    local master_ips=() worker_ips=()
    mapfile -t master_ips < <(awk '
        /^[A-Za-z0-9_]+:/ { in_cp = ($0 ~ /^kube_control_plane:/) ? 1 : 0; next }
        in_cp && /^[[:space:]]*access_ip:[[:space:]]*[0-9.]+/ { if (!seen[$2]++) print $2; next }
        in_cp && /^[[:space:]]*ip:[[:space:]]*[0-9.]+/         { if (!seen[$2]++) print $2 }
    ' "${inv}")
    mapfile -t worker_ips < <(awk '
        /^[A-Za-z0-9_]+:/ { in_w = ($0 ~ /^kube_node:/) ? 1 : 0; next }
        in_w && /^[[:space:]]*access_ip:[[:space:]]*[0-9.]+/ { if (!seen[$2]++) print $2; next }
        in_w && /^[[:space:]]*ip:[[:space:]]*[0-9.]+/         { if (!seen[$2]++) print $2 }
    ' "${inv}")
    [ "${#master_ips[@]}" -gt 0 ] || { warn "hosts.yml 中无 master 节点(kube_control_plane), 跳过同步"; return 0; }

    # API 入口: **以 sync-kubespray-config.sh 已写入 all.yml 的值为准**, 不在本脚本重新判定阶段。
    # 原因: 阶段判定含 SSH 探测与用户确认(倒计时), 只能有一处权威实现; 本脚本若自己算一遍,
    # 会用不同值把 sync 的写法顶掉(本函数在 kubespray 启动前还会再跑一次)。
    # 正常路径下 06_k8s_deploy.sh 已先调用 sync, all.yml 的值就是本次要用的入口(阶段一=master01 /
    # 阶段二=VIP); 仅在直连本脚本时 all.yml 可能未就绪, 此时按第一阶段回退。
    local all_yml_path="${INVENTORY_DIR}/group_vars/all/all.yml"
    local api_ip=""
    if [ -f "${all_yml_path}" ]; then
        api_ip="$(awk '/^loadbalancer_apiserver:/{f=1; next} f && /^[[:space:]]+address:/{print $2; exit}' "${all_yml_path}")"
    fi
    if [ -z "${api_ip}" ]; then
        # ⚠ 2026-09-28 rebase 取舍: 保留 api-ha 的"本地代理模式"分支(它解释得对: 安静是设计如此),
        #   但兜底默认取 main 的 false —— 9832975 已把 kube-vip 默认翻成关, api-ha 那版是翻之前的。
        if [ "${_skip_all_yml}" = "1" ]; then
            # 本地代理模式下 all.yml 里没有生效入口是**设计如此**(块须保持注释) —— 不是"忘了跑 sync",
            # 别让运维照旧文案去重跑 sync。此处回退值仅供下面 calico can-reach 兜底使用。
            log "本地代理模式: all.yml 无生效 API 入口(块保持注释, 设计如此) —— 该值仅作 calico can-reach 兜底"
        elif [ "${KUBE_VIP_ENABLED:-false}" = "true" ]; then
            log "all.yml 尚无 API 入口(未先跑 sync)→ 按阶段一回退第一个 master; kube-vip 就位后重跑即切换"
        fi
        api_ip="${master_ips[0]}"
    fi
    local calico_ip="${worker_ips[0]:-${api_ip}}"   # 无 worker 时回退第一个 master

    # ---------- 1. all.yml: API 负载均衡 + SAN ----------
    if [ "${_skip_all_yml}" = "1" ]; then
        # 本地代理模式: 该段整体交由 sync-kubespray-config.sh 独占(块保持注释 = 上游走 localhost:6443)
        log "本地代理模式: 跳过 all.yml 的 loadbalancer_apiserver 同步(由 sync 脚本独占)"
    elif [ -f "${all_yml}" ] && grep -qE '^loadbalancer_apiserver:' "${all_yml}" && grep -qE '^supplementary_addresses_in_ssl_keys:' "${all_yml}"; then
        local domain port
        domain="$(sed -nE 's/^apiserver_loadbalancer_domain_name:[[:space:]]*"?([^" ]+)"?.*/\1/p' "${all_yml}" | tail -1)"
        [ -n "${domain}" ] || domain="lb.k8s.local"
        port="$(awk '/^loadbalancer_apiserver:/{f=1} f&&/port:/{print $2; exit}' "${all_yml}")"
        [ -n "${port}" ] || port="6443"

        awk -v api="${api_ip}" -v domain="${domain}" -v port="${port}" -v masters="${master_ips[*]}" '
            BEGIN { n = split(masters, m, " ") }
            /^apiserver_loadbalancer_domain_name:/ {
                printf "apiserver_loadbalancer_domain_name: \"%s\"\n", domain
                next
            }
            /^loadbalancer_apiserver:/ { print; in_lb = 1; next }
            in_lb {
                if ($0 ~ /^[[:space:]]+address:/) { printf "  address: %s   # 第一个 master 节点 IP(由 hosts.yml 自动同步)\n", api; next }
                if ($0 ~ /^[[:space:]]+port:/)     { printf "  port: %s\n", port; next }
                in_lb = 0
            }
            /^supplementary_addresses_in_ssl_keys:/ { print; in_san = 1; next }
            in_san {
                if ($0 ~ /^[[:space:]]*-/) { next }
                printf "  - %s\n", domain
                for (i = 1; i <= n; i++) printf "  - %s\n", m[i]
                in_san = 0
            }
            { print }
        ' "${all_yml}" > "${all_yml}.tmp" && mv "${all_yml}.tmp" "${all_yml}"
        log "✅ 已依据 hosts.yml 同步 ${all_yml}: API=${api_ip}:${port}, SAN=[${master_ips[*]}]"
    else
        warn "all.yml 中未找到 loadbalancer_apiserver / supplementary_addresses_in_ssl_keys 区块(可能仍为注释), 跳过 all.yml 同步"
    fi

    # ---------- 2. k8s-cluster.yml: kube_apiserver_extra_args.advertise-address ----------
    # ⚠ 该字段已改为"按节点各写各的"Jinja 表达式(kube_apiserver_address), **不再随主机 IP 同步**。
    #   旧实现统一写死第一个 master IP → 三个 apiserver 都宣告同一地址 → kubernetes Service 的
    #   EndpointSlice 只有一条 → 集群内经 Service 访问 API 单点(详见 docs/kube-vip-api-ha.md 2.5)。
    #   这里是幂等修复: 只在发现它还是具体 IP 时改写, 已经是表达式则不动。
    local cluster_yml="${INVENTORY_DIR}/group_vars/k8s_cluster/k8s-cluster.yml"
    if [ -f "${cluster_yml}" ]; then
        local _adv_want='  advertise-address: "{{ kube_apiserver_address }}"'
        if grep -qF "${_adv_want}" "${cluster_yml}"; then
            :   # 已是目标值, 无需动作(常规路径)
        elif grep -qE '^[[:space:]]+advertise-address:[[:space:]]*' "${cluster_yml}"; then
            sed -i -E 's|^([[:space:]]+advertise-address:).*|\1 "{{ kube_apiserver_address }}"|' "${cluster_yml}"
            log "✅ advertise-address 已修正为按节点取值(原为固定 IP, 会造成 kubernetes Service 单点)"
        else
            sed -i -E "/^kube_apiserver_extra_args:/a\\${_adv_want}" "${cluster_yml}"
            log "✅ advertise-address 已补写为按节点取值"
        fi
    else
        warn "未找到 ${cluster_yml}, 跳过 advertise-address 检查"
    fi

    # ---------- 3. k8s-net-calico.yml: calico_ip_auto_method can-reach ----------
    local calico_yml="${INVENTORY_DIR}/group_vars/k8s_cluster/k8s-net-calico.yml"
    if [ -f "${calico_yml}" ]; then
        if grep -qE '^calico_ip_auto_method:' "${calico_yml}"; then
            sed -i -E "s/^calico_ip_auto_method:.*/calico_ip_auto_method: \"can-reach=${calico_ip}\"/" "${calico_yml}"
        else
            echo "calico_ip_auto_method: \"can-reach=${calico_ip}\"" >> "${calico_yml}"
        fi
        log "✅ 已依据 hosts.yml 同步 ${calico_yml}: calico can-reach=${calico_ip}"
    else
        warn "未找到 ${calico_yml}, 跳过 calico can-reach 同步"
    fi
}

# 在真正部署前, 通过 SSH 检查并中立化目标节点上的旧 Kubernetes 状态
# 检测到残留 → 醒目警告 + sleep 60 → 中立化旧 K8s + kubeadm reset -f + IPVS 清理
# 未检测到 → 直接部署, 不执行清理
# 用法: reset_kubernetes_if_needed <scope>
# 返回: 0 = 目标节点的 kubelet API 端口(10250)已确认让出(部署可继续)
#       1 = 仍有节点被占(调用方**必须中止** —— 见下方"真实退出码")
#
# ⚠ 要让路的对象不止 kubeadm 残留, 而是**任何占着 10250 的东西**, 包括 RKE2/k3s/microK8s
#   这类第三方发行版: 它们的内嵌 kubelet 由各自的 agent 单元托管(不叫 kubelet.service),
#   对 `kubeadm reset -f` 和 `systemctl stop kubelet` 完全免疫。
#   2026-09-23 实机事故: 9 台节点里只有 mxgpu-3-32 的 rke2-agent 还在跑(另外 4 台装了 RKE2
#   但已 disabled), 旧清理逻辑对它三个判据全部漏检 → 部署跑 22 分钟后才在 kubespray 的
#   kubeadm join 阶段报 `[ERROR Port-10250]: Port 10250 is in use` 中断, 报错点离真因
#   (RKE2 agent)隔了一整个 playbook, 且现场早已"✅ 清理完成: 7 台成功"。
# 检查并重置节点上的旧 Kubernetes 状态(部署/扩容前清理残留)
# 参数 scope:
#   all — 检查并重置全部有残留的节点(全新部署场景, 旧集群将被整体替换)
#   new — 仅检查并重置"未加入运行中集群"的新节点(扩容场景, 绝不重置旧集群节点):
#         通过首个 master 的 kubectl 获取集群现有节点(名称+InternalIP), 按清单名/
#         ansible_host/远端 hostname 三重匹配排除旧节点; 无法获取集群状态时,
#         为安全起见跳过全部 reset(宁可不清理, 也不误重置运行中的集群)
reset_kubernetes_if_needed() {
    local scope="${1:-all}"

    # 解析节点清单(host+user+key) 从 hosts.yml 获取
    # ⚠ 枚举顺序 = **worker 在前, master 在后**(2026-10-09 修): 旧集群的存储后端(ceph mon/osd)
    #   住在 master 上 —— 先清 master 会把 worker 尚未卸载的 CSI-RBD 卷**后端先杀死**, 之后
    #   worker 的 umount 卡死在"日志回写死设备"(内核 D 状态不可杀, 部署无限挂; worker12 两度复现)。
    #   worker 的残留挂载必须在旧存储仍存活时先卸干净。
    local nodes_str
    nodes_str=$(ansible-inventory -i "${INVENTORY_DIR}/hosts.yml" --list 2>/dev/null | python3 -c '
import sys, json
inv = json.load(sys.stdin)
meta = inv.get("_meta", {}).get("hostvars", {})
seen = set()
for g in ["kube_node", "kube_control_plane"]:
    for h in inv.get(g, {}).get("hosts", []):
        if h in seen or h not in meta:
            continue
        seen.add(h)
        hv = meta[h]
        print("%s|%s|%s|%s" % (
            h,
            hv.get("ansible_host", h),
            hv.get("ansible_user", "ubuntu"),
            hv.get("ansible_ssh_private_key_file", "~/.ssh/cubestack_k8s"),
        ))
')
    [ -n "${nodes_str}" ] || { warn "无法解析节点清单(${INVENTORY_DIR}/hosts.yml), 跳过 reset 检查"; return 0; }

    # 扩容场景: 从运行中的集群获取现有节点列表(名称 + InternalIP), 用于排除旧节点
    local existing_nodes=""
    if [ "${scope}" = "new" ]; then
        local mstr
        mstr=$(ansible-inventory -i "${INVENTORY_DIR}/hosts.yml" --list 2>/dev/null | python3 -c '
import sys, json
inv = json.load(sys.stdin)
meta = inv.get("_meta", {}).get("hostvars", {})
cp = inv.get("kube_control_plane", {}).get("hosts", [])
if not cp:
    sys.exit(0)
hv = meta.get(cp[0], {})
print("%s|%s|%s" % (
    hv.get("ansible_host", cp[0]),
    hv.get("ansible_user", "ubuntu"),
    hv.get("ansible_ssh_private_key_file", "~/.ssh/cubestack_k8s"),
))
')
        if [ -n "${mstr}" ]; then
            local mhost muser mkey
            IFS='|' read -r mhost muser mkey <<< "${mstr}"
            # 获取集群现有节点: 名称 + InternalIP + ExternalIP, 并归一化为单行空格分隔
            # (多行输出时 token 前后是换行而非空格, 会导致除首行名称/末行 IP 外的条目匹配失败)
            existing_nodes=$(ssh -i "${mkey}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
                "${muser}@${mhost}" \
                "sudo kubectl get nodes --no-headers -o wide 2>/dev/null | awk '{print \$1, \$6, \$7}'" 2>/dev/null | tr '\n' ' ' || true)
        fi
        if [ -z "${existing_nodes}" ]; then
            warn "无法获取运行中集群的节点列表, 为安全起见跳过全部 reset(避免误重置旧集群节点)"
            return 0
        fi
        log "扩容场景: 已获取集群现有节点列表($(wc -w <<< "${existing_nodes}" | tr -d ' ') 个标识), reset 仅作用于未加入集群的新节点"
    fi

    # 逐个节点检查是否已有 Kubernetes 残留(kubelet 运行 / etcd 数据 / /etc/kubernetes 等)
    # 并记录需要重置的节点(仅重置有残留的节点, 不影响干净节点)
    local found=0
    local reset_targets=()
    local oldifs="${IFS}"
    IFS=$'\n'
    for line in ${nodes_str}; do
        IFS='|' read -r node host user key <<< "${line}"
        [ -z "${node}" ] && continue

        # 探针: 首行远端 hostname; 次行 YES(需清理)/NO(干净); 第三行起为详情(供告警点名)
        #   判"需清理"的三个来源:
        #     ① kubelet API 端口 10250 被监听 —— 与发行版无关的硬判据: kubeadm join 的
        #        preflight 只要看到 10250 被占, 就 [ERROR Port-10250] 直接失败。
        #     ② 第三方发行版单元存在(RKE2/k3s/microK8s): 即使当前没在跑也要 disable,
        #        否则重启后复活重新占端口。
        #     ③ kubeadm/kubespray 残留(原有判据, 全部保留 —— 每条都对应过一次实机事故)
        local probe probe_rc=0
        probe=$(ssh -i "${key}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
            "${user}@${host}" \
            "sudo bash -c '
                hostname
                _d=\"\"
                # ① 端口被占(kubeadm join 的硬门槛)
                ss -lnt 2>/dev/null | grep -qE \"[:.]10250[[:space:]]\" && _d=\"\${_d}port-10250;\"
                # ② 第三方 K8s 发行版: 内嵌 kubelet 由各自 agent 单元托管, 不叫 kubelet.service
                for _u in rke2-agent rke2-server k3s k3s-agent microk8s; do
                    if systemctl is-active \"\${_u}.service\" >/dev/null 2>&1; then
                        _d=\"\${_d}\${_u}:running;\"
                    elif [ -f \"/etc/systemd/system/\${_u}.service\" ] || [ -f \"/usr/local/lib/systemd/system/\${_u}.service\" ] || [ -f \"/lib/systemd/system/\${_u}.service\" ]; then
                        _d=\"\${_d}\${_u}:installed;\"
                    fi
                done
                # ③ kubeadm 残留
                systemctl is-active kubelet 2>/dev/null | grep -qx active && _d=\"\${_d}kubelet:running;\"
                # 残留 kubelet.service unit(即使 /etc/kubernetes 等目录已被手动清理, 只要 unit
                # 还在, kubespray validate-container-engine 就误判节点曾加入集群 → 卸载
                # docker/containerd 前先 drain → kubectl get nodes 读 admin.conf(全新部署
                # 尚未生成) 失败, 单机重装必踩, 见 “Drain node” 报 admin.conf 不存在)
                [ -f /etc/systemd/system/kubelet.service ] && _d=\"\${_d}kubelet-unit;\"
                [ -f /lib/systemd/system/kubelet.service ] && _d=\"\${_d}kubelet-unit;\"
                [ -d /etc/kubernetes ] && [ -n \"\$(ls -A /etc/kubernetes 2>/dev/null)\" ] && _d=\"\${_d}etc-kubernetes;\"
                [ -d /var/lib/etcd/member ] && _d=\"\${_d}etcd-member;\"
                [ -d /var/lib/kubelet ] && [ -n \"\$(ls -A /var/lib/kubelet 2>/dev/null)\" ] && _d=\"\${_d}var-lib-kubelet;\"
                [ -n \"\${_d}\" ] && { echo YES; echo \"\${_d}\"; exit 0; }
                echo NO
            '" 2>/dev/null) || probe_rc=$?
        # 探测不到 ≠ 干净: 不静默跳过, 点名告警 —— 否则该节点若占着 10250,
        # 又要等 20 分钟后 kubespray 报 [ERROR Port-10250] 才知道
        if [ "${probe_rc}" != "0" ] || [ -z "${probe}" ]; then
            warn "  → [${node}](${host}) 探测失败(ssh rc=${probe_rc}), 无法确认其 K8s 状态, 跳过清理"
            continue
        fi

        # 扩容: 已属于运行中集群的节点绝不重置(清单名/ansible_host/远端 hostname 匹配)
        if [ "${scope}" = "new" ]; then
            local remote_name in_cluster=0
            remote_name=$(head -1 <<< "${probe}")
            case " ${existing_nodes} " in
                *" ${node} "*|*" ${host} "*) in_cluster=1 ;;
            esac
            if [ -n "${remote_name}" ]; then
                case " ${existing_nodes} " in
                    *" ${remote_name} "*) in_cluster=1 ;;
                esac
            fi
            if [ "${in_cluster}" = "1" ]; then
                log "  → [${node}](${host}) 已属于运行中的集群, 跳过 reset"
                continue
            fi
        fi

        if grep -qx "YES" <<< "${probe}"; then
            # 详情行(第 3 行)用于点名"到底占了什么", 让 60 秒倒计时可判断
            local pdet
            pdet=$(sed -n '3p' <<< "${probe}")
            log "  → [${node}](${host}) 检测到旧 Kubernetes 残留/占用${pdet:+ [${pdet}]}"
            found=1
            reset_targets+=("${line}")
        fi
    done
    IFS="${oldifs}"

    if [ "${found}" = "0" ]; then
        log "未检测到需要清理的旧 Kubernetes 状态, 直接部署"
        return 0
    fi

    # 检测到残留 → 醒目警告 + sleep 60
    echo ""
    highlight "╔══════════════════════════════════════════════════════════╗"
    highlight "║   ⚠️  检测到节点上已有 Kubernetes 部署! ⚠️                 ║"
    highlight "║                                                          ║"
    highlight "║  将在 60 秒后自动让出这些节点(kubelet API 端口 10250)     ║"
    highlight "║  含第三方发行版(RKE2/k3s/microK8s): 只 stop + disable     ║"
    highlight "║  其数据目录(/var/lib/rancher 等)保留, 不卸载不删除        ║"
    highlight "║  如需中断, 请按 Ctrl+C 退出                              ║"
    highlight "╚══════════════════════════════════════════════════════════╝"
    echo ""
    local countdown=60
    while [ "${countdown}" -gt 0 ]; do
        printf "\r  ⏳ 倒计时 %3d 秒后自动清理并继续部署..." "${countdown}"
        sleep 1
        countdown=$((countdown - 1))
    done
    printf "\r  ✅ 继续部署...                          \n"
    echo ""

    # 执行清理: 先让出 10250(第三方发行版 stop+disable) → 再 kubeadm reset -f + IPVS 清理 + 删残留
    log "清理节点上的旧 Kubernetes 状态(第三方发行版 stop+disable + kubeadm reset -f + IPVS 清理)..."
    log "  (顺序: worker 先于 master —— 旧集群存储后端在 master 上, 须让 worker 先卸掉残留挂载)"
    local reset_ok=0 reset_fail=0
    for line in "${reset_targets[@]}"; do
        IFS='|' read -r node host user key <<< "${line}"
        [ -z "${node}" ] && continue
        log "  → [${node}](${host}) 清理中..."
        local cleanup_out="" cleanup_rc=0
        # ⚠ 远端载荷加**总超时**(2026-10-09): 清理一旦卡死(如死挂载的 umount)当前是**无限挂**;
        #   `timeout` 管住"壳"(bash 可被 TERM/KILL 杀) —— 即便内层 D 状态进程不可杀, 也能让本步
        #   以明确失败(rc=124)收场、走下面的失败分支, 而不是把整个部署永久挂起。
        cleanup_out=$(ssh -i "${key}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
            "${user}@${host}" \
            "sudo timeout -k 15 240 bash -c '
                # ── ⓪ 预备 + 强制脱挂(2026-10-09 实机根因落地; 用户口径: 免人工重启, 自动强制清干净):
                #   ① disable --now 旧 kubelet: 关掉 10250, 并**杜绝清理途中旧 CSI 再把卷挂回来**
                #      (复活的旧集群会自愈重挂 —— 实测: 全量重启后旧 kubelet/CSI 复活并重挂 RBD)。
                #   ② /var/lib/kubelet 下一切残留挂载(含旧集群 CSI-RBD/ceph 卷)一律**后台惰性卸载**:
                #      死后端下正规 umount 会卡死在\"日志回写死设备\"(内核 D 状态不可杀, 部署无限挂 ——
                #      worker12 两度实机事故)。惰性卸载只做命名空间脱开(纯内核操作, 不碰文件系统),
                #      因此**永不在本进程阻塞**; 后台进程即便 D 态也只是惰性残留(免重启场景的代价, 无害)。
                #      脱净后 kubeadm reset 见不到挂载 ⇒ 从根上消除卡死路径。
                systemctl disable --now kubelet 2>/dev/null || true
                for _m in \$(findmnt -Rrn -o TARGET /var/lib/kubelet 2>/dev/null | tac); do
                    [ -n \"\${_m}\" ] || continue
                    [ \"\${_m}\" = \"/var/lib/kubelet\" ] && continue
                    setsid umount -l \"\${_m}\" >/dev/null 2>&1 &
                done
                # 轮询确认脱净(纯内核操作, 正常亚秒; 上限 ~10s)
                for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
                    findmnt -Rrn -o TARGET /var/lib/kubelet 2>/dev/null | grep -vx \"/var/lib/kubelet\" | grep -q . || break
                    sleep 0.5
                done

                # ── ① 第三方 K8s 发行版(RKE2/k3s/microK8s): 先把 10250 让出来 ────────
                # 它们的内嵌 kubelet 由各自的 agent 单元托管, 不叫 kubelet.service:
                #   · kubeadm reset -f       → 对它们是完全的空操作
                #   · systemctl stop kubelet → 停的是 kubespray 那个 unit, 停不到点子上
                # 于是其 kubelet 继续占着 10250 → kubespray 的 kubeadm join preflight 报
                # [ERROR Port-10250] 中断整个部署(2026-09-23 实机事故)。
                # disable(而非只 stop): 防止节点重启后复活重新占端口。
                # 契约是“让出端口”而非“卸载别人的集群”: 只 stop+disable, 不卸载不删数据
                # (/var/lib/rancher 等一律原样保留)。
                for _u in rke2-agent rke2-server k3s k3s-agent microk8s; do
                    systemctl disable --now \"\${_u}.service\" >/dev/null 2>&1 || true
                done
                # 兜底: 上面的 stop 靠各自 unit 的 ExecStopPost 清理 cgroup 内的 kubelet
                # (rke2 是 KillMode=process, 只保证杀主进程, kubelet 靠 ExecStopPost 尽力扫),
                # 扫漏时用官方 killall 补刀 —— 它只杀进程并清理 /var/lib/cni、pod 日志等运行态,
                # 不动 /var/lib/rancher 数据
                if ss -lnt 2>/dev/null | grep -qE \"[:.]10250[[:space:]]\"; then
                    [ -x /usr/local/bin/rke2-killall.sh ] && /usr/local/bin/rke2-killall.sh >/dev/null 2>&1 || true
                    [ -x /usr/local/bin/k3s-killall.sh ] && /usr/local/bin/k3s-killall.sh >/dev/null 2>&1 || true
                fi
                # ── ② kubeadm/kubespray 残留(原有逻辑) ──────────────────────────────
                kubeadm reset -f 2>/dev/null || true;
                # 清理 IPVS 规则与 kube-ipvs0 虚拟接口
                ipvsadm -C 2>/dev/null;
                ip link del kube-ipvs0 2>/dev/null;
                rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd 2>/dev/null;
                # 清理 CNI 配置与旧插件残留(切 CNI 时旧插件配置会残留并优先于新 CNI 被
                # kubelet 选用 → pod sandbox 报 “plugin type=cilium-cni failed: connection refused”)
                rm -rf /etc/cni/net.d 2>/dev/null;
                rm -f /opt/cni/bin/cilium* 2>/dev/null;
                rm -rf /var/run/cilium 2>/dev/null;
                systemctl stop kubelet 2>/dev/null || true;
                systemctl stop etcd 2>/dev/null || true;
                # 移除残留 kubelet systemd unit(/etc/kubernetes 等目录可能已被清空, 但 unit
                # 文件仍在 → validate-container-engine “Ensure kubelet systemd unit exists”
                # 误判节点已部署 → 卸载 docker/containerd 前先 drain → kubectl get nodes 读
                # /etc/kubernetes/admin.conf(全新部署尚未生成) 失败, 单机重装必踩)
                rm -f /etc/systemd/system/kubelet.service \
                      /etc/systemd/system/kubelet.service.d \
                      /lib/systemd/system/kubelet.service \
                      /lib/systemd/system/kubelet.service.d \
                      /etc/kubernetes/kubelet.env 2>/dev/null;
                systemctl daemon-reload 2>/dev/null || true;
                rm -f /etc/etcd.env /etc/systemd/system/etcd.service 2>/dev/null;
                # ── ③ 复核: 10250 必须真的空出来 ──────────────────────────────────
                # 原实现这里以 true 收尾 → ssh 恒返回 0 → “N 台成功” 是**假信号**:
                # 2026-09-23 事故里 mxgpu-3-32 被报“清理成功”, 22 分钟后却因 10250 被占中断部署。
                # 改成真实判据: 最多等 10s 让 LISTEN socket 释放, 仍被占则打印元凶并以非 0 退出。
                for _i in 1 2 3 4 5 6 7 8 9 10; do
                    ss -lnt 2>/dev/null | grep -qE \"[:.]10250[[:space:]]\" || exit 0
                    sleep 1
                done
                echo \"PORT_BUSY: 10250 仍被占用, kubeadm join 必然失败:\"
                ss -lntp 2>/dev/null | grep -E \"[:.]10250[[:space:]]\" | head -3
                _pid=\$(ss -lntp 2>/dev/null | grep -E \"[:.]10250[[:space:]]\" | grep -oE \"pid=[0-9]+\" | head -1 | cut -d= -f2)
                [ -n \"\${_pid}\" ] && ps -o pid,lstart,cmd -p \"\${_pid}\" | tail -1
                exit 1
            '" 2>&1) || cleanup_rc=$?
        if [ "${cleanup_rc}" = "0" ]; then
            reset_ok=$((reset_ok + 1))
        else
            reset_fail=$((reset_fail + 1))
            if [ "${cleanup_rc}" = "124" ]; then
                warn "  ${node}: 远端清理**超时**(240s) —— 该步已强制脱挂, 仍超时请排查(见下方输出)后重跑"
            else
                warn "  ${node}: 清理后 kubelet API 端口(10250)仍未让出(ssh rc=${cleanup_rc}):"
            fi
            if [ -n "${cleanup_out}" ]; then printf '%s\n' "${cleanup_out}" | sed 's/^/      /'; fi
        fi
    done
    if [ "${reset_fail}" -gt 0 ]; then
        log "⚠ 清理完成: ${reset_ok} 台成功, ${reset_fail} 台失败(元凶见上方输出)"
        return 1
    fi
    log "✅ 清理完成: ${reset_ok} 台成功(10250 均已确认让出)"
    return 0
}

cmd_install() {
    highlight "安装集群 [${CLUSTER_NAME}]..."
    ensure_kubespray
    ensure_venv
    cmd_check
    # 依据 hosts.yml 自动同步 all.yml 的 API 负载均衡/SAN 配置
    update_loadbalancer_all_yml
    # 部署前: 检查并重置旧 Kubernetes 状态(检测到残留/第三方 K8s/10250 被占 才清理;
    # 全新部署覆盖全部节点)。清理后仍被占 → 立刻中止: 否则要等 20 分钟后 kubespray 在
    # join 阶段才报 [ERROR Port-10250], 报错点离真因隔了一整个 playbook(2026-09-23 事故)
    reset_kubernetes_if_needed all \
        || err "节点 10250 端口清理未通过(元凶见上方输出), 已中止部署"
    log "注入离线安装变量..."
    OFFLINE_VARS="${INVENTORY_DIR}/group_vars/all/offline.yml"
    {
        echo "---"
        echo "# 离线安装变量（由 cubestack-offline.sh 自动生成）"
        echo ""
        echo "## 下载控制"
        echo "download_run_once: true"
        echo "download_localhost: true"
        echo "download_force_cache: true"
        echo "download_always_pull: false"
        # ★ 2026-09-14 修复: download_localhost:true 使 download 任务的 remove 阶段
        #   delegate 到部署机(localhost)执行 → delete 的是部署机 off线缓存
        #   local_release_dir 下的镜像 tar; 而挂载的 preload 同步 play 重新从同一
        #   缓存目录(download_cache_dir=LOCAL_REPO_DIR)同步 → 源已被删 → 每个全新多节点
        #   首次部署预加载必失败。download_keep_remote_cache:true 保留缓存, preload 才有源。
        echo "download_keep_remote_cache: true"
        echo ""
        echo "## 缓存目录"
        echo "download_cache_dir: \"${LOCAL_REPO_DIR}\""
        echo "local_release_dir: \"${LOCAL_REPO_DIR}\""
        echo ""
        echo "## 容器运行时"
        echo "container_manager: \"${CONTAINER_RUNTIME}\""
        echo "container_manager_on_localhost: \"${CONTAINER_RUNTIME}\""
        echo ""
        echo "## 连接"
        echo "ansible_user: \"${REMOTE_USER}\""
        echo "ansible_become: true"
        echo "ansible_become_method: sudo"
        echo ""
        echo "## 离线环境 — 跳过不必要的检查"
        echo "ping_access_ip: false"
        echo ""
        echo "## 离线环境 API server 冷启动慢, 加大 kubeadm init 等待超时(默认300s)"
        echo "kubeadm_init_timeout: 900s"
    } > "${OFFLINE_VARS}"

    # 生成镜像文件清单(inventory/preload-images.lst), 供 cluster.yml 内置预加载 play 使用
    # (实际同步+加载由 cluster.yml 在 containerd 安装完成后完成;
    #  全新节点此时尚无 containerd, 入口脚本直接预加载会跳过)
    resolve_preload_image_files

    # 修复 artifacts 目录权限(kubectl_localhost/kubeconfig_localhost 用)
    fix_artifacts_perms

    # 修复 download role 镜像上传缺目录问题(使 ansible-playbook 自身可全量同步镜像)
    fix_download_sync_dirs

    # 修复 download role 镜像 groups 配置(使 dnsautoscaler/metrics-server 镜像推送到全节点)
    fix_download_groups

    # 确保 cluster.yml 已挂载镜像预加载 play(kubespray 升级后自动重新挂载)
    ensure_preload_play

    # 确保 cluster.yml 已挂载 registry 节点 hosts play(域名解析, 配合 containerd certs.d)
    ensure_registry_play

    # 确保 cluster.yml 已挂载单节点控制面收敛 play(⚠ 必须在 K8s+CNI 之后, 见函数注释)
    ensure_single_node_play

    # 确保 cluster.yml 已挂载系统包安装 play(lvm2 等离线 .deb, 供 ceph/Rook OSD)
    ensure_packages_play

    # 确保 cluster.yml 已挂载 CNI 重启 play(K8s+CNI 之后、operator 之前重启 containerd+kubelet)
    ensure_cni_restart_play

    # ansible 日志: tee 同时写入文件 + 输出到终端
    INSTALL_LOG="/tmp/${CLUSTER_NAME}-install.log"
    log "执行 Kubespray 离线安装..."
    log "ansible 日志: 同时显示终端 + 写入 ${INSTALL_LOG}"
    [ "${ANSIBLE_LOG_TERMINAL:-1}" != "1" ] && log "ansible 日志: 仅写入文件(ANSIBLE_LOG_TERMINAL=0, 终端不显示)"
    if [ -n "$LIMIT_GROUP" ]; then
        log "  ▶ 限定目标组: ${LIMIT_GROUP}"
    fi
    cd "${KUBESPRAY_DIR}"

    # 当使用 --limit 时,预先收集全节点 facts (排除的节点也需要 facts 缓存)
    if [ -n "$LIMIT_GROUP" ]; then
        log "预收集全节点 facts (为 --limit 做准备)..."
        ansible-playbook playbooks/facts.yml \
            -i "${INVENTORY_DIR}/hosts.yml" \
            --become --become-user=root \
            -e @${OFFLINE_VARS} \
            --skip-tags system-packages,kube-proxy \
            -v 2>&1 | tee "/tmp/${CLUSTER_NAME}-facts.log" || true
        log "✅ Facts 收集完成"
    fi

    run_ansible_playbook "${INSTALL_LOG}" cluster.yml \
        -i "${INVENTORY_DIR}/hosts.yml" \
        --become --become-user=root \
        ${LIMIT_FLAG} \
        -e @${OFFLINE_VARS} \
        --skip-tags system-packages,kube-proxy \
        -vv

    # CNI 插件重启(containerd + kubelet)已移入 kubespray
    # patch-playbooks/cubestack-cni-restart.yml: 在 K8s+CNI 部署完成后、operator 安装前由
    # ensure_cni_restart_play 自动挂载到 cluster.yml。
    # 镜像预加载已由 cluster.yml 内置的 cubestack-preload play 在 containerd 就绪后完成,
    # 不再需要安装后单独 preload_images(preload_images 仅保留给 preload/scale 命令)。

    log "🎉 [集群 ${CLUSTER_NAME}] 安装完成!"
    log "完整 ansible 日志: ${INSTALL_LOG} (终端已同步显示)"
}

cmd_scale() {
    highlight "扩容集群 [${CLUSTER_NAME}] — 添加新节点..."
    ensure_kubespray
    ensure_venv
    cmd_check
    # 依据 hosts.yml 自动同步 all.yml 的 API 负载均衡/SAN 配置
    update_loadbalancer_all_yml
    # 扩容前: 仅检查并重置"新加入"节点上的旧 Kubernetes 状态
    # (已在运行集群中的节点绝不重置; 无法获取集群状态时跳过全部 reset)
    # 新节点若占着 10250 同样是硬失败(与全量部署同理), 中止优于 20 分钟后才报
    reset_kubernetes_if_needed new \
        || err "新节点 10250 端口清理未通过(元凶见上方输出), 已中止扩容"

    # 确保离线变量文件存在
    OFFLINE_VARS="${INVENTORY_DIR}/group_vars/all/offline.yml"
    if [ ! -f "${OFFLINE_VARS}" ]; then
        warn "离线变量文件不存在，正在生成..."
        {
            echo "---"
            echo "# 离线安装变量（由 cubestack-offline.sh 自动生成）"
            echo ""
            echo "## 下载控制"
            echo "download_run_once: true"
            echo "download_localhost: true"
            echo "download_force_cache: true"
            echo "download_always_pull: false"
            echo ""
            echo "## 缓存目录"
            echo "download_cache_dir: \"${LOCAL_REPO_DIR}\""
            echo "local_release_dir: \"${LOCAL_REPO_DIR}\""
            echo ""
            echo "## 容器运行时"
            echo "container_manager: \"${CONTAINER_RUNTIME}\""
            echo "container_manager_on_localhost: \"${CONTAINER_RUNTIME}\""
            echo ""
            echo "## 连接"
            echo "ansible_user: \"${REMOTE_USER}\""
            echo "ansible_become: true"
            echo "ansible_become_method: sudo"
            echo ""
            echo "## 离线环境 — 跳过不必要的检查"
            echo "ping_access_ip: false"
            echo ""
            echo "## 离线环境 API server 冷启动慢, 加大 kubeadm init 等待超时(默认300s)"
            echo "kubeadm_init_timeout: 900s"
        } > "${OFFLINE_VARS}"
    fi

    # 自动检测 hosts.yml 中是否有扩容专用组(名由 SCALE_GROUP_NAME 控制, 默认 new_node)
    # 存在时自动 --limit 该组, 仅对新增节点执行扩容, 避免对已有节点重复操作
    local scale_group="${SCALE_GROUP_NAME:-new_node}"
    if [ -z "$LIMIT_GROUP" ] && grep -q "^${scale_group}:" "${INVENTORY_DIR}/hosts.yml" 2>/dev/null; then
        LIMIT_GROUP="${scale_group}"
        LIMIT_FLAG="--limit ${LIMIT_GROUP}"
        log "检测到 hosts.yml 中 ${scale_group} 组, 自动 --limit ${scale_group}(仅扩容新增节点)"
    fi

    if [ -n "$LIMIT_GROUP" ]; then
        log "  ▶ 限定目标组: ${LIMIT_GROUP}"

        # Kubespray 要求 --limit 排除的节点也必须有 facts 缓存
        # 先不带 --limit 跑一次 facts.yml 收集全量 facts
        log "预收集全节点 facts (为 --limit 做准备)..."
        cd "${KUBESPRAY_DIR}"
        ansible-playbook playbooks/facts.yml \
            -i "${INVENTORY_DIR}/hosts.yml" \
            --become --become-user=root \
            -e @${OFFLINE_VARS} \
            --skip-tags system-packages,kube-proxy \
            -v 2>&1 | tee "/tmp/${CLUSTER_NAME}-facts.log"
        log "✅ Facts 收集完成"
    fi

    # ── 镜像预加载方案 ──
    # 必须先于 scale.yml 加载镜像: kubelet 启动 kube-proxy 时会尝试拉镜像,
    # 离线环境下必须先 load 到 containerd, 否则 ImagePullBackOff
    # 新 worker 节点可能尚未安装 containerd(入口脚本直接预加载会跳过)
    # 解决方案: 先跑一次 scale.yml 的前半段(仅安装 containerd + 下载镜像),
    # 然后生成镜像清单 inventory/preload-images.lst, 由 scale.yml 内置的
    # 预加载 play 在 containerd 装完后完成同步+加载
    log "预安装 containerd 到新节点(为镜像预加载做准备)..."
    cd "${KUBESPRAY_DIR}"
    run_ansible_playbook "/tmp/${CLUSTER_NAME}-prescale.log" scale.yml \
        -i "${INVENTORY_DIR}/hosts.yml" \
        --become --become-user=root \
        ${LIMIT_FLAG} \
        -e @${OFFLINE_VARS} \
        --skip-tags system-packages,kube-proxy \
        --tags container-engine,download \
        -v 2>&1 || warn "containerd 预安装部分节点可能失败(首次 scale 可忽略)"
    log "✅ containerd 预安装完成"

    # 生成镜像文件清单(inventory/preload-images.lst), 供 scale.yml 内置预加载 play 使用
    # (实际同步+加载由 scale.yml 完成, 入口脚本不再重复预加载)
    resolve_preload_image_files

    # 修复 download role 镜像上传缺目录问题(使 scale.yml 对新 worker 也能全量同步镜像)
    fix_download_sync_dirs

    # 确保 scale.yml 已挂载镜像预加载 play(kubespray 升级后自动重新挂载)
    ensure_preload_play

    # 确保 scale.yml 已挂载系统包安装 play(新 worker 离线安装 lvm2 等)
    ensure_packages_play

    # 确保 scale.yml 已挂载 CNI 重启 play(新节点 K8s+CNI 之后重启 containerd+kubelet)
    ensure_cni_restart_play

    # 确保 scale.yml 已挂载单节点控制面收敛 play(扩容后 master 可能被 kubeadm 重新打回污点)
    ensure_single_node_play

    log "执行 Kubespray 扩容 (scale.yml)..."
    log "ansible 日志: 同时显示终端 + 写入 /tmp/${CLUSTER_NAME}-scale.log"
    [ "${ANSIBLE_LOG_TERMINAL:-1}" != "1" ] && log "ansible 日志: 仅写入文件(ANSIBLE_LOG_TERMINAL=0, 终端不显示)"
    cd "${KUBESPRAY_DIR}"
    run_ansible_playbook "/tmp/${CLUSTER_NAME}-scale.log" scale.yml \
        -i "${INVENTORY_DIR}/hosts.yml" \
        --become --become-user=root \
        ${LIMIT_FLAG} \
        -e @${OFFLINE_VARS} \
        --skip-tags system-packages,kube-proxy \
        -vv || {
            err "Kubespray 扩容失败,完整日志: /tmp/${CLUSTER_NAME}-scale.log"
            return 1
        }

    # 扩容后兜底预加载: 补加载附加组件镜像(如 dns-autoscaler/metrics-server),
    # 同时重新生成镜像清单(供下次扩容或独立运行 scale.yml 使用)
    preload_images "${LIMIT_GROUP:-kube_node}"

    # ── 扩容后置处理 ──
    log "扩容后置处理..."

    # 1. 修复 Calico ClusterRole RBAC：Calico v3.29+ 需要 ipamconfigs 等 CRD 权限
    log "  [1/2] 修复 Calico ClusterRole RBAC..."
    MISSING_CALICO_RESOURCES="ipamconfigs kubecontrollersconfigurations"
    for res in $MISSING_CALICO_RESOURCES; do
        ansible kube_control_plane[0] -i "${INVENTORY_DIR}/hosts.yml" \
            --become --become-user=root \
            -m shell \
            -a "
              if kubectl get clusterrole calico-node -o json 2>/dev/null | \
                 jq -e '.rules[] | select(.apiGroups | index(\"crd.projectcalico.org\")) | .resources' 2>/dev/null | \
                 grep -q '\"${res}\"'; then
                echo '  calico-node ClusterRole 已包含 ${res}，跳过'
              else
                kubectl patch clusterrole calico-node --type='json' \
                  -p='[{\"op\": \"add\", \"path\": \"/rules/3/resources/-\", \"value\": \"${res}\"}]' 2>/dev/null && \
                echo '  ✅ 已添加 ${res} 到 calico-node ClusterRole'
              fi
            " \
            >/dev/null 2>&1 || true
    done
    log "  ✅ Calico RBAC 修复完成"

    # 2. 若 Calico pods CrashLoopBackOff，删除让其用新权限重建
    log "  [2/2] 重建异常的 Calico pods..."
    ansible kube_control_plane[0] -i "${INVENTORY_DIR}/hosts.yml" \
        --become --become-user=root \
        -m shell \
        -a "
          kubectl -n kube-system get pods -l k8s-app=calico-node 2>/dev/null | \
          awk '/CrashLoopBackOff|Error/{print \$1}' | \
          xargs -r kubectl -n kube-system delete pod 2>/dev/null || true
        " \
        >/dev/null 2>&1 || true

    # CNI 插件初始化重启(containerd + kubelet)已移入 kubespray
    # patch-playbooks/cubestack-cni-restart.yml: 在新节点 K8s+CNI 部署完成后自动执行,
    # 由 ensure_cni_restart_play 自动挂载到 scale.yml, 此处不再单独重启

    log "🎉 集群 [${CLUSTER_NAME}] 扩容完成! 日志: /tmp/${CLUSTER_NAME}-scale.log"
}

cmd_check() {
    highlight "预检集群 [${CLUSTER_NAME}]..."
    if [ ! -d "${LOCAL_REPO_DIR}/images" ] || [ -z "$(ls -A "${LOCAL_REPO_DIR}/images" 2>/dev/null)" ]; then
        err "镜像目录为空: ${LOCAL_REPO_DIR}/images"
    fi
    if [ -z "$(find "${LOCAL_REPO_DIR}" -maxdepth 1 -type f 2>/dev/null | head -1)" ]; then
        err "未找到离线二进制文件: ${LOCAL_REPO_DIR}"
    fi
    log "✅ 离线资源完整"

    cd "${KUBESPRAY_DIR}"
    source .venv/bin/activate 2>/dev/null || true

    # ── 终极修复：将 Python 逻辑写入临时文件，$() 内只做简单调用 ──
    local py_script="/tmp/.cubestack_count_hosts.py"
    cat > "$py_script" << 'PYEOF'
import sys, json
try:
    d = json.load(sys.stdin)
    print(len(d.get("_meta", {}).get("hostvars", {})))
except Exception:
    print(0)
PYEOF

    local inv_json
    inv_json=$(ansible-inventory -i "${INVENTORY_DIR}/hosts.yml" --list 2>/dev/null || echo "{}")

    HOST_COUNT=$(echo "$inv_json" | python3 "$py_script")
    rm -f "$py_script"

    [ "${HOST_COUNT}" -gt 0 ] || err "Inventory 解析失败: ${INVENTORY_DIR}/hosts.yml"
    log "✅ Inventory 有效，共 ${HOST_COUNT} 台主机"

    # 预检连通性: 加超时防卡死。ansible ping 默认无 SSH 连接超时, 节点关机/不可达时会无限挂起
    # (曾出现: 全部 VM 关机 → 部署卡在预检不动)。timeout 60 兜底 + ConnectTimeout 让单节点快速失败。
    # 注意: ansible -e key=value 的值含空格时会被解析器按空格拆成多个 var, 必须在值外层再包一层引号,
    #       否则 ansible_ssh_common_args 只拿到 "-o", ssh 报 "no argument after keyword -o", 预检恒失败。
    timeout 60 ansible all -i "${INVENTORY_DIR}/hosts.yml" -m ping -u "${REMOTE_USER}" --become \
        -e "ansible_ssh_common_args='-o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2'" \
        >/dev/null 2>&1 || warn "部分主机 SSH/sudo 异常或不可达(预检连通性超时 60s)"
    log "✅ 预检通过"
}

# ──────────────────────────────────────────────────────────
# 主入口 — 参数解析
# ──────────────────────────────────────────────────────────
LIMIT_GROUP=""
COMMAND=""
CLUSTER_ARG=""
RESET_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --limit)
            [ -z "${2:-}" ] && err "--limit 需要指定一个组名 (kube_control_plane, kube_node, etcd)"
            LIMIT_GROUP="$2"
            shift 2
            ;;
        --yes|-y)
            # 仅供 reset 使用: 显式确认"清空旧集群"
            RESET_YES=1
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            if [ -z "$COMMAND" ]; then
                COMMAND="$1"
            elif [ -z "$CLUSTER_ARG" ]; then
                CLUSTER_ARG="$1"
            else
                err "未知参数: $1"
            fi
            shift
            ;;
    esac
done

[ -z "$COMMAND" ] && usage

CLUSTER_NAME=$(resolve_cluster_name "${COMMAND}" "${CLUSTER_ARG}")
OFFLINE_CONTRIB="${KUBESPRAY_DIR}/contrib/offline"
INVENTORY_DIR="${INVENTORY_BASE}/${CLUSTER_NAME}"
LOCAL_REPO_DIR="$(default_local_repo_dir)"

# ── 环境变量覆盖(让调用方如 deploy-cluster.sh 可传入项目路径) ──
KUBESPRAY_DIR="${CUBESTACK_KUBESPRAY_DIR:-${KUBESPRAY_DIR}}"
INVENTORY_DIR="${CUBESTACK_INVENTORY_DIR:-${INVENTORY_DIR}}"
# OFFLINE_FILES_DIR 可整体切换离线文件根目录(全局变量); LOCAL_REPO_DIR 仍可单独覆盖(最高优先)
# 默认值由 default_local_repo_dir() 按布局给出 —— 仓库布局不加集群名子目录(见文件头 §离线文件根目录)
OFFLINE_FILES_DIR="${OFFLINE_FILES_DIR:-${LOCAL_REPO_BASE}}"
LOCAL_REPO_DIR="${CUBESTACK_LOCAL_REPO_DIR:-$(default_local_repo_dir)}"
OFFLINE_CONTRIB="${KUBESPRAY_DIR}/contrib/offline"

# ── 预加载镜像集合配置(仅同步部署 kubespray 所需的最小镜像集合) ──
# 优先级: CUBESTACK_PRELOAD_IMAGE_PATTERNS 环境变量(含空串) > inventory 下 preload-images.conf > PRELOAD_IMAGE_PATTERNS 环境变量 > 内置默认最小集合
# 匹配规则: 条目含 ".tar" 为精确文件名匹配(如 quay.io_calico_node_v3.29.3.tar), 否则为文件名包含匹配(如 calico)
# 任一来源显式置空(如 preload-images.conf 中 PRELOAD_IMAGE_PATTERNS="") = 全量同步 images/ 目录
PRELOAD_CONF="${INVENTORY_DIR}/preload-images.conf"
if [ -n "${CUBESTACK_PRELOAD_IMAGE_PATTERNS+x}" ]; then
    # 环境变量显式传递(deploy-cluster.sh 透传 cluster.conf 配置, 空串=全量同步)
    PRELOAD_IMAGE_PATTERNS="${CUBESTACK_PRELOAD_IMAGE_PATTERNS}"
    log "预加载镜像集合(环境变量): ${PRELOAD_IMAGE_PATTERNS:-<空=全量>}"
elif [ -f "${PRELOAD_CONF}" ]; then
    # shellcheck disable=SC1090
    source "${PRELOAD_CONF}"
    log "预加载镜像集合(preload-images.conf): ${PRELOAD_IMAGE_PATTERNS:-<空=全量>}"
elif [ -z "${PRELOAD_IMAGE_PATTERNS:-}" ]; then
    # 内置默认最小集合: kubespray 默认部署 + calico 网络插件 + metallb/registry/local-path/lws/nginx 附加组件所需镜像
    # (排除 cilium/flannel/ingress-nginx/dashboard 等未启用组件的镜像)
    # ⚠ 本行是**第 4 份**副本(standalone 直跑本脚本时的兜底默认值), 必须与 cluster.conf /
    #   cluster.conf.example / tools/offline/trim-offline-files.sh 三份**逐字节一致** ——
    #   check-modules.sh 第 ⑭ 项断言这**四份**(2026-09-28 起本份已纳入; 本行不在 file 顶部,
    #   断言脚本会跳过上面那条 ${CUBESTACK_PRELOAD_IMAGE_PATTERNS} 透传行, 取到本行);
    #   本份漂移会让"备料保留 / 节点预加载"两边不一致
    #   (典型症状: 装了却没有镜像)。新增镜像 token 时四处都要加。
    PRELOAD_IMAGE_PATTERNS="calico_cni calico_kube-controllers calico_node etcd kube-apiserver kube-controller-manager kube-proxy kube-scheduler coredns cluster-proportional-autoscaler k8s-dns-node-cache metrics-server pause local-volume-provisioner node-feature-discovery metallb kube-vip library_registry local-path-provisioner busybox lws_manager library_nginx"
    log "预加载镜像集合(内置默认最小集合): ${PRELOAD_IMAGE_PATTERNS}"
fi
export PRELOAD_IMAGE_PATTERNS

# 构建 ansible-playbook 通用 limit 参数
LIMIT_FLAG=""
[ -n "$LIMIT_GROUP" ] && LIMIT_FLAG="--limit ${LIMIT_GROUP}"

# ============================================================
# 命令: reset —— 清除目标节点上的**旧集群状态**(转调 kubespray reset.yml)
# ---------------------------------------------------------------------------
# 为什么需要它(2026-09-28 实机): 默认全量运行 / (deploy-cluster.sh 的) --fresh 只清**本仓库的
# 断点状态**, 不清节点上的旧集群。节点上若残留上一代集群(实测: k8s 1.32 + etcd 3.5.16),
# kubespray 会按**升级**处理, 撞两道**上游硬闸**:
#   ① etcd 3.5(<3.5.26) → 3.6: roles/etcd/tasks/clean_v2_store.yml:12 直接 fail
#      ("You need to upgrade etcd to 3.5.26 or later before upgrade to 3.6");
#   ② kubeadm 跨小版本(如 1.32→1.35)本就不允许跳。
# ⇒ **覆盖安装 = 先 reset 旧集群, 再全量部署**。原地升级未实现, 设计(含伪代码)见
#   docs/cluster-upgrade-path.md。
#
# ⚠ 会**永久删除**(节点由 inventory 决定): etcd 数据目录 / /etc/kubernetes /
#   kubelet·containerd 的配置与 cri 容器、Pod(= 该集群的工作负载与 etcd 数据全部丢失)。
#   故必须显式 `--yes`, 且留 10 秒可中断的倒计时。
# ============================================================
cmd_reset() {
    [ "${RESET_YES:-0}" = "1" ] || {
        err "reset 会清空目标节点上的旧集群(etcd 数据 / 工作负载 / kubelet 配置全部丢失, 不可恢复)"
        err "  确认要重装该集群时, 显式加 --yes 重跑:  $0 reset ${CLUSTER_NAME} --yes"
        err "  原地升级**不走** reset —— 那是未实现的 feature, 设计见 docs/cluster-upgrade-path.md"
        exit 1
    }
    ensure_venv
    cd "${KUBESPRAY_DIR}"

    local log="/tmp/${CLUSTER_NAME}-reset.log"
    [ -e "${log}" ] && { rm -f "${log}" 2>/dev/null || sudo rm -f "${log}" 2>/dev/null || true; }
    start_log_tee "${log}"

    highlight "将要清除集群 [${CLUSTER_NAME}] 的旧状态(目标节点由 inventory 决定${LIMIT_GROUP:+, 限 ${LIMIT_GROUP}}):"
    echo "    · etcd 数据目录(/var/lib/etcd)+ etcd/kubelet/containerd 服务与配置"
    echo "    · /etc/kubernetes(证书、kubeconfig、静态 Pod 清单)"
    echo "    · 全部 CRI 容器与 Pod —— 该集群工作负载一并消失, 不可恢复"
    local _t=10
    while [ "${_t}" -gt 0 ]; do
        printf '\r    ⚠ %d 秒后开始(ctrl-c 可取消)...' "${_t}"
        sleep 1; _t=$((_t - 1))
    done
    printf '\r\033[K'

    local ov="${INVENTORY_DIR}/group_vars/all/offline.yml"
    local -a _ov=(); [ -f "${ov}" ] && _ov=(-e "@${ov}")
    log "执行 kubespray reset(日志: ${log})..."
    run_ansible_playbook "${log}" reset.yml \
        -i "${INVENTORY_DIR}/hosts.yml" \
        --become --become-user=root \
        ${LIMIT_FLAG} \
        -e reset_confirmation=yes \
        "${_ov[@]}" \
        -vv || err "reset 失败, 见 ${log}"

    log "✅ 旧集群状态已清除(etcd 数据 / /etc/kubernetes / cri 容器与 Pod)"

    # ---- 复核: 旧**二进制**是否真被卸掉(覆盖安装成立的前提) ----
    # ⚠ 关键机制(树内): etcd 的版本探测读的是 `etcd --version` 的输出
    #   (roles/etcd/tasks/install_host.yml:24 用 regex_search('etcd Version: x.y.z') 算
    #    etcd_current_version) —— **不是**读数据目录。所以只删数据、留下旧 etcd 二进制,
    #   上游版本闸(roles/etcd/tasks/clean_v2_store.yml:12)下一次照样会拦。
    #   reset 角色本就会删 bin_dir 下的 etcd/etcdctl/kubelet/kubeadm/kubectl/helm/calicoctl
    #   (roles/reset/tasks/main.yml:355-375), 这里只做**验证**(失败不中止, 给手工修法)。
    local _fm _probe=""
    _fm="$(first_master_ip 2>/dev/null || true)"
    if [ -n "${_fm}" ]; then
        _probe="$(ssh -i "${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}" \
            -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
            "${SSH_USER:-ubuntu}@${_fm}" \
            "ls -d /usr/local/bin/etcd /usr/local/bin/etcdctl /usr/local/bin/kubeadm /usr/local/bin/kubelet /etc/etcd.env 2>/dev/null || true" 2>/dev/null || true)"
    fi
    if [ -n "${_probe}" ]; then
        warn "首个 master(${_fm})上仍残留旧集群文件 —— 它们会让下一次安装重新走【升级】路径:"
        echo "${_probe}" | sed 's/^/      /'
        warn "  手工修法(逐台 master): sudo rm -rf /usr/local/bin/{etcd,etcdctl,kubeadm,kubelet} /etc/etcd.env"
    else
        [ -n "${_fm}" ] && log "✅ 已复核: 首个 master 上无残留的 etcd/kubeadm/kubelet 二进制与 /etc/etcd.env"
    fi
    echo ""
    log "ℹ️ 下一步: 全量部署(etcd 会以 ${ETCD_VERSION:-当前钉值} 全新安装) —— 在容器内跑 deploy-cluster.sh 即可"
}

# 只读自检: 打印全部路径推导(排障 + 版本目录回归套件用; 不联网/不碰集群/不需 root)
cmd_paths() {
    printf 'KUBESPRAY_VERSION=%s\nBASE_DIR=%s\nKUBESPRAY_DIR=%s\nOFFLINE_LAYOUT=%s\nOFFLINE_FILES_ROOT=%s\nOFFLINE_FILES_DIR=%s\nLOCAL_REPO_DIR=%s\nINVENTORY_DIR=%s\n' \
        "${KUBESPRAY_VERSION}" "${BASE_DIR}" "${KUBESPRAY_DIR}" "${OFFLINE_LAYOUT}" "${OFFLINE_FILES_ROOT}" \
        "${OFFLINE_FILES_DIR}" "${LOCAL_REPO_DIR}" "${INVENTORY_DIR}"
}

case "${COMMAND}" in
    init)     cmd_init ;;
    paths)    cmd_paths ;;
    download) cmd_download ;;
    reset)    cmd_reset ;;
    install)
        # 整个安装过程所有日志(含 ansible): 同时显示终端 + 写入日志文件
        # 每次执行前清理旧日志: 旧文件可能被上次 root/sudo 运行占用导致 tee 写失败(Permission denied),
        # 非 root 时用 sudo 删除; start_log_tee 仍作为最终兜底(回退 HOME 日志/仅终端), 不中断安装
        LOG_FILE="/tmp/${CLUSTER_NAME}-install.log"
        [ -e "${LOG_FILE}" ] && { rm -f "${LOG_FILE}" 2>/dev/null || sudo rm -f "${LOG_FILE}" 2>/dev/null || true; }
        start_log_tee "${LOG_FILE}"
        cmd_install
        ;;
    scale)
        LOG_FILE="/tmp/${CLUSTER_NAME}-scale.log"
        [ -e "${LOG_FILE}" ] && { rm -f "${LOG_FILE}" 2>/dev/null || sudo rm -f "${LOG_FILE}" 2>/dev/null || true; }
        start_log_tee "${LOG_FILE}"
        cmd_scale
        ;;
    check)    cmd_check ;;
    preload)  preload_images "${LIMIT_GROUP:-all}" ;;   # 单独预加载镜像(补镜像/修复)
    *)        usage ;;
esac
