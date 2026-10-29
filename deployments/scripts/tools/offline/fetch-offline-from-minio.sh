#!/bin/bash
# ============================================================
# fetch-offline-from-minio.sh — 从 MinIO 下载离线部署文件到宿主机大磁盘, 并给出容器挂载命令
# ------------------------------------------------------------
# 用途: 从 MinIO 拉取离线部署文件(binary + 镜像 tar + 系统包 + GPU/虚拟机镜像)到
#       默认下载目录 /opt/cubestack-installer/deployments/offline-files:
#       · 容器内执行(CLI 镜像已内置 mc): 下载直接落到容器挂载的 offline-files, 即装即用;
#       · 宿主机执行: 可 --auto 自动挑空闲最大的大磁盘下载, 完成后打印容器挂载命令。
# 特性:
#   · mc 检测: 未安装时给出安装指引, 并可选择自动下载(MinIO 官方二进制, 与 Dockerfile-cli 同源);
#   · mc alias 检测/配置: 优先用独立 MinIO 配置(config/minio.conf 或 MINIO_* 环境变量)自动配置;
#     否则探测本机已有 alias 是否可访问(自动跳过占位 alias), 都没有则交互式录入并配置;
#   · 桶/目录自适应: 默认桶 cubestack-installer、目录 offline-files(与 MinIO 实际布局一致),
#     自动回退探测旧布局(cubestack-offline/kubespray);
#   · 磁盘检查(默认开启): 醒目提示磁盘至少需 MIN_FREE_GB(默认 50)GiB 空闲, 并比对
#     本次下载所需(远程总大小 + 缓冲)与目标可用空间; 不足时红色横幅警告并中止(--force 强制继续);
#   · 下载范围: 默认下载【部署必需】子目录(kubespray/metax-gpu/os 等),
#     不下载 virtual-machine(虚拟机镜像, 体积大且仅创建 VM 时用);
#     需要时可 --sub virtual-machine 只拉 VM 镜像, 或 --all 全量(含 VM 镜像)。
#   · 子目录排除: DEFAULT_EXCLUDE_SUBS(默认 virtual-machine)在默认/全量下载时自动跳过;
#     显式 --sub <目录> 不受排除限制(按需下载)。
#   · 需要时可用 --sub <目录> 只拉某子目录; --sub 支持**嵌套路径**(如 kubespray/v2.32.0)⇒
#     只下载指定版本的离线件(离线件按版本目录组织, 见 docs/kubespray-versioning/);
#   · 断点续传/重试: mc mirror 按对象 --retry + 整命令重试(--retry N, 默认 3);
#     --resume 先校验本地树, 部分文件用 mc cat --offset 续传后按清单 sha 校验,
#     失败再完整重下; 本地已完整则直接退出; --repair 重下坏文件;
#   · 精确清理(release/flat 默认): 用 mc mirror --overwrite --remove 让本地树与 MinIO 一致,
#     删除本地多余文件; 默认 30s 红色倒计时(--clean-countdown N / --yes 跳过);
#     非交互环境无 --yes 时中止; --no-clean 保留本地多余文件; .cubestack-* 始终保留。
#   · 结果提示: 容器内就绪提示; 宿主机打印容器挂载命令 + 直跑 OFFLINE_FILES_DIR 指引。
# 用法(容器内已 root, 无需 sudo):
#   ./fetch-offline-from-minio.sh                                 # 默认: 下载部署必需子目录(排除 virtual-machine)
#   ./fetch-offline-from-minio.sh --sub virtual-machine           # 按需拉 VM 镜像(仅创建虚拟机时)
#   ./fetch-offline-from-minio.sh --all                           # 真正全量(含 virtual-machine 等所有子目录)
#   ./fetch-offline-from-minio.sh --sub kubespray                 # 只拉某子目录(如 kubespray)
#   ./fetch-offline-from-minio.sh --sub kubespray/v2.32.0         # 二级路径: 只拉**指定版本**(版本目录, 见下)
#   ./fetch-offline-from-minio.sh --kubespray-version v2.32.0     # 等价糖(版本名 = 上游 tag 全名, 决策 D8)
#   ./fetch-offline-from-minio.sh --dest /data/offline-files      # 指定下载目录(即 offline-files 根)
#   sudo ./fetch-offline-from-minio.sh --auto                     # 宿主机: 自动挑空闲 ≥ 门槛的最大磁盘
#   sudo ./fetch-offline-from-minio.sh --min-free 100             # 磁盘空闲门槛 100GiB
#   sudo ./fetch-offline-from-minio.sh --force                    # 跳过磁盘空间不足检查(谨慎)
#   sudo ./fetch-offline-from-minio.sh --yes                      # 跳过交互确认(自动化)
#   ./fetch-offline-from-minio.sh --list                          # 只列出 MinIO 可用目录(不需 root)
#   ./fetch-offline-from-minio.sh --sub cubestack-operator         # 平台镜像整目录(37 件)
#   ./fetch-offline-from-minio.sh --sub cubestack-operator/portal  # 下钻: 只取某个平台组件(刷新单组件)
#   ./fetch-offline-from-minio.sh --sub ceph,cubestack-operator/lws   # 多值(逗号分隔, 或重复给 --sub)
#   ./fetch-offline-from-minio.sh --list --sub cubestack-operator  # 列出其下全部组件名(无需登录 MinIO 控制台)
#   ./fetch-offline-from-minio.sh --list-releases                  # 列出桶根可用发布版本
#   ./fetch-offline-from-minio.sh --release 2.0.0 --dest /data/cubestack-installer
#                                                                  # 取发布版本到 <dest>/2.0.0/
#   ./fetch-offline-from-minio.sh --release 2.0.0 --verify-only --dest /data/cubestack-installer
#                                                                  # 只校验已下载的发布版本
#   ./fetch-offline-from-minio.sh --release 2.0.0 --no-verify      # 跳过 sha256(调试用)
#   ./fetch-offline-from-minio.sh --release 2.0.0 --resume          # 断点续传(失败后重跑)
#   ./fetch-offline-from-minio.sh --release 2.0.0 --retry 5 --retry-delay 5  # 重试策略
#   ./fetch-offline-from-minio.sh --release 2.0.0 --no-clean       # 不删除本地多余文件
#   ./fetch-offline-from-minio.sh --release 2.0.0 --clean-countdown 30  # 30s 倒计时
#   ./fetch-offline-from-minio.sh --release 2.0.0 --flat --dest /opt/cubestack-installer/deployments/offline-files
#                                                                  # flat: 把 <版本>/offline-files 平铺到 offline-files 根
#   · --release <版本>: 远端 = <bucket>/<版本>/{offline-files/,cubestack-installer-cli-v<版本>.tar},
#     旧布局的 cubestack-installer-cli.tar 仅做兼容读取;
#     本地 = <本地桶根>/<版本>/; 本地桶根优先 --dest > CUBESTACK_RELEASE_ROOT >
#     ${REPO_ROOT}/offline-releases。⚠ release 模式下 --dest 表示**本地桶根**
#     (包含 <版本>/ 与 offline-files/), 与 --sub 的 --dest(offline-files 根)语义不同。
#   · --verify-only: 只校验本地已下载的树, **不需要 mc/MinIO 配置**(纯本地, 不联网);
#   · --resume: 下载前先 full 校验本地树; 部分文件按 offset 续传并校验 sha; 完整则跳过下载;
#     失败/不完整再正常下载并最终全量校验。下载命令默认重试 3 次(--retry/--retry-delay)。
#   · --clean/--no-clean: release/flat 默认精确清理(删除本地多余文件); dev/--sub 需显式 --clean;
#     非交互环境必须加 --yes, 否则中止; .cubestack-* (校验戳/清单备份) 保留。
#   · --flat(仅配合 --release): 不建 <版本>/ 目录, 把远端的 <版本>/offline-files/ 内容
#     平铺到 --dest(默认 deployments/offline-files); release.env 随资产一起落地,
#     load_config 会自动识别 release flat 模式。CLI tar 不在 flat 模式下载。
# 数据源: config/minio.conf(独立 MinIO 配置, 模板 minio.conf.example)或 MINIO_* 环境变量;
#         刻意不依赖 cluster.conf / lib-common.sh —— 本脚本是部署【前置】的下载工具,
#         下载离线文件时集群配置往往还不存在, 不应要求先配好集群。
# ============================================================
set -euo pipefail

# ---------------- 独立配置加载(不依赖 cluster.conf / lib-common) ----------------
# 本脚本是部署【前置】的下载工具: 下载离线文件时往往还没有集群配置, 因此刻意
# 不 source lib-common.sh、不读 cluster.conf, 只读独立的 MinIO 配置(避免"先有鸡还是先有蛋")。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"   # tools/offline/ → 仓库根

# fetch 辅助模块: mc 重试/断点续传/清理/校验/修复(纯函数, 依赖调用方全局变量)
# shellcheck source=lib-offline-fetch.sh
source "${SCRIPT_DIR}/lib-offline-fetch.sh"

# 校验器定位/自举(独立小库; 不引入 cluster.conf 依赖)
# shellcheck source=lib-offline-verify.sh
source "${SCRIPT_DIR}/lib-offline-verify.sh"

# 极简日志助手(风格与 lib-common 一致, 独立定义以免引入整个配置链)
say()  { echo -e "\033[36m→  $*\033[0m"; }
ok()   { echo -e "\033[32m✅ $*\033[0m"; }
warn() { echo -e "\033[33m⚠  $*\033[0m"; }
err()  { echo -e "\033[31m【错误】$*\033[0m" >&2; }

# MinIO 配置来源(优先级: 环境变量 > minio.conf > 内置默认):
#   · 默认读 config/minio.conf(独立文件, 模板 config/minio.conf.example; 含密钥已 gitignore);
#     可用环境变量 MINIO_CONF 覆盖路径, 或完全不用文件、直接设 MINIO_* 环境变量。
#   · minio.conf 内变量以 ${VAR:-默认} 形式定义 → 环境变量自然优先于文件。
MINIO_CONF="${MINIO_CONF:-${REPO_ROOT}/deployments/config/minio.conf}"
if [ -f "${MINIO_CONF}" ]; then
    # shellcheck disable=SC1090
    source "${MINIO_CONF}"
    say "已加载 MinIO 配置: ${MINIO_CONF}"
fi

# 下载目标根目录: 仅用户显式设置 OFFLINE_FILES_DIR(环境变量/minio.conf)时采用;
#   不设则走默认/--dest/--auto(offline-files 总根, 与 lib-common 的内层默认语义无关)。
OFFLINE_FILES_DIR_EXPLICIT="${OFFLINE_FILES_DIR:-}"
export OFFLINE_FILES_DIR_EXPLICIT

# ---------------- 参数解析 ----------------
DEST_ARG=""
SUB_ARG=""
ALL=0
LIST_ONLY=0
YES=0
AUTO=0
FORCE=0
KUBESPRAY_VERSION_ARG=""
RELEASE_ARG=""
LIST_RELEASES=0
VERIFY_ONLY=0
NO_VERIFY=0
REPAIR=0
RESUME=0
REPAIR_DONE=0
RELEASE_MODE=0
FLAT=0
CLEAN_MODE="auto"                     # auto|yes|no; auto = release/flat 默认清理
CLEAN_COUNTDOWN="${CLEAN_COUNTDOWN:-30}"  # 清理倒计时秒数(--yes 跳过)
CLEAN=0
FETCH_RETRY="${FETCH_RETRY:-3}"
FETCH_RETRY_DELAY="${FETCH_RETRY_DELAY:-3}"
_CLEAN_STASH=""
_CLEAN_DST=""
CLI_TAR_BASENAME=""                  # 解析后的 CLI tar 文件名(带版本; 旧布局兼容时=无版本名)
MIN_FREE_GB="${MIN_FREE_GB:-50}"     # 磁盘空间门槛(GB): 默认至少 50GiB 空闲, 离线文件会持续增加
WARN_NEED_GB="${WARN_NEED_GB:-50}"   # 醒目警告建议的总空闲门槛(GB)
# 默认/全量下载时自动排除的子目录(体积大且非部署必需, 需用时 --sub 单独拉):
DEFAULT_EXCLUDE_SUBS="${DEFAULT_EXCLUDE_SUBS:-virtual-machine}"

# --help: 头部说明 + **可用子目录图**(不必登录 MinIO 控制台; 平台组件清单读仓库内 image-list.tsv)
_print_help() {
    awk '/^set -euo pipefail$/{exit} {print}' "$0" | sed 's/^# \{0,1\}//'
    echo ""
    echo "════ 可用子目录(offline-files/ 下; 实时: --list / 下钻: --list --sub <路径>)════"
    echo "  kubespray/               kubespray 离线仓(版本子目录 vX.Y.Z; --sub kubespray/v2.32.0)"
    echo "  ceph/  metax-gpu/  nvidia-gpu-operator/  multus/  rdma/  netshoot/  os/"
    echo "  dev-lab/                 开发镜像: cpu / maca / cuda 家族(3 件; 顶层平铺, 大件 .tar.gz)"
    echo "  model-collection/        模型推理镜像: sglang/ 与 vllm/(3 件 ≈33G, .tar.gz; 来源 suanova/model-collection)"
    echo "  virtual-machine/         虚拟机镜像(大; 默认排除, --sub virtual-machine 单独拉)"
    echo "  cli/                     CLI 镜像 tar(rebuild-cli-image.yml 自动上传; 取回: --sub cli)"
    echo "  cubestack-operator/      CubeStack 平台镜像 + operator chart"
    echo "                           顶层 <上游ref>.tar = operator 本体; charts/ = helm chart"
    echo "                           (chart 与镜像同集合, 默认/--sub cubestack-operator 会一起拉取)"
    local _rd _list
    _rd="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
    _list="${_rd}/deployments/offline-files/cubestack-operator/image-list.tsv"
    if [ -f "${_list}" ]; then
        echo "    组件子目录(取自仓库 image-list.tsv, 随组件自动更新; charts/ 是 chart, 不是组件):"
        awk -F'\t' '!/^#/ && $1 != "." && NF {print $1}' "${_list}" | sort -u | tr '\n' ' ' | fold -s -w 96 | sed 's/^/      /'
        echo ""
    else
        echo "    组件子目录: lws envoy-gateway controller-manager prometheus perses cuberouter bmc cubepilot portal"
    fi
    echo "  示例: ./fetch-offline-from-minio.sh --sub cubestack-operator/portal   # 只取某个平台组件"
    echo "        ./fetch-offline-from-minio.sh --sub cubestack-operator          # 取镜像 tar + chart"
    echo ""
    echo "════ 发布版本(桶根 <版本>/offline-files + <版本>/cubestack-installer-cli-v<版本>.tar)════"
    echo "  --list-releases                       列出桶根可用版本"
    echo "  --release 2.0.0 --dest <本地桶根>     取版本到 <本地桶根>/2.0.0/"
    echo "  --release 2.0.0 --verify-only ...     只校验已下载版本(sha256 + CLI tar)"
    echo "  --release 2.0.0 --repair ...          校验失败时只重下坏文件(最多 1 轮)"
    echo "  --release 2.0.0 --resume ...          断点续传: 校验本地树, 部分文件用 offset 续传"
    echo "  --release 2.0.0 --no-verify ...       跳过 sha256(调试用)"
    echo "  --release 2.0.0 --clean ...           精确镜像: 覆盖并删除本地多余文件"
    echo "  --release 2.0.0 --no-clean ...        保留本地多余文件(默认 release/flat 清理)"
    echo "  --clean-countdown N                   清理倒计时秒数(默认 30; --yes 跳过)"
    echo "  --retry N                             下载失败重试次数(默认 3)"
    echo "  --retry-delay N                       重试间隔秒数(默认 3)"
}
while [ $# -gt 0 ]; do
    case "$1" in
        --dest) DEST_ARG="$2"; shift 2 ;;
        --sub)  SUB_ARG="${SUB_ARG:+${SUB_ARG},}$2"; shift 2 ;;   # 支持多值: 逗号分隔或重复 --sub
        --min-free) MIN_FREE_GB="$2"; shift 2 ;;
        --all)  ALL=1; shift ;;
        --list) LIST_ONLY=1; shift ;;
        --auto) AUTO=1; shift ;;
        --force) FORCE=1; shift ;;
        -y|--yes) YES=1; shift ;;
        --kubespray-version) KUBESPRAY_VERSION_ARG="$2"; shift 2 ;;
        --release) RELEASE_ARG="$2"; shift 2 ;;
        --flat) FLAT=1; shift ;;
        --list-releases) LIST_RELEASES=1; shift ;;
        --verify-only) VERIFY_ONLY=1; shift ;;
        --no-verify) NO_VERIFY=1; shift ;;
        --repair) REPAIR=1; shift ;;
        --resume) RESUME=1; shift ;;
        --clean) CLEAN_MODE=yes; shift ;;
        --no-clean) CLEAN_MODE=no; shift ;;
        --clean-countdown) CLEAN_COUNTDOWN="${2:?--clean-countdown 需要秒数}"; shift 2 ;;
        --retry) FETCH_RETRY="${2:?--retry 需要次数}"; shift 2 ;;
        --retry-delay) FETCH_RETRY_DELAY="${2:?--retry-delay 需要秒数}"; shift 2 ;;
        -h|--help) _print_help; exit 0 ;;
        *) err "未知参数: $1(可用 --dest/--sub/--release/--list-releases/--verify-only/--no-verify/--repair/--clean/--no-clean/--clean-countdown/--kubespray-version/--min-free/--auto/--force/--all/--list/--flat/-y)"; exit 1 ;;
    esac
done
# --release 与 --sub/--all/--kubespray-version 互斥; --verify-only/--no-verify 只用于 release
if [ -n "${RELEASE_ARG}" ]; then
    [ -n "${SUB_ARG}" ] && { err "--release 与 --sub 互斥"; exit 1; }
    [ "${ALL}" = "1" ] && { err "--release 与 --all 互斥"; exit 1; }
    [ -n "${KUBESPRAY_VERSION_ARG}" ] && { err "--release 与 --kubespray-version 互斥"; exit 1; }
fi
[ "${VERIFY_ONLY}" = "1" ] && [ -z "${RELEASE_ARG}" ] && { err "--verify-only 需要配合 --release <版本>"; exit 1; }
[ "${FLAT}" = "1" ] && [ -z "${RELEASE_ARG}" ] && { err "--flat 需要配合 --release <版本>(平铺到 offline-files 根)"; exit 1; }
[ "${NO_VERIFY}" = "1" ] && [ -z "${RELEASE_ARG}" ] && { err "--no-verify 需要配合 --release <版本>"; exit 1; }
[ "${REPAIR}" = "1" ] && [ -z "${RELEASE_ARG}" ] && { err "--repair 需要配合 --release <版本>"; exit 1; }
[ "${REPAIR}" = "1" ] && [ "${NO_VERIFY}" = "1" ] && { err "--repair 与 --no-verify 互斥"; exit 1; }
[ "${REPAIR}" = "1" ] && [ "${VERIFY_ONLY}" = "1" ] && { err "--repair 需要网络下载, 不能与 --verify-only 同用"; exit 1; }
[ "${RESUME}" = "1" ] && [ -z "${RELEASE_ARG}" ] && { err "--resume 需要配合 --release <版本>"; exit 1; }
[ "${RESUME}" = "1" ] && [ "${VERIFY_ONLY}" = "1" ] && { err "--resume 不能与 --verify-only 同用(verify-only 只校验)"; exit 1; }
[ "${RESUME}" = "1" ] && [ "${NO_VERIFY}" = "1" ] && { err "--resume 不能与 --no-verify 同用(续传后必须校验)"; exit 1; }
case "${CLEAN_COUNTDOWN}" in ''|*[!0-9]*) err "--clean-countdown 必须是非负整数: ${CLEAN_COUNTDOWN}"; exit 1 ;; esac
case "${FETCH_RETRY}" in ''|*[!0-9]*|0) err "--retry 必须是正整数: ${FETCH_RETRY}"; exit 1 ;; esac
case "${FETCH_RETRY_DELAY}" in ''|*[!0-9]*) err "--retry-delay 必须是非负整数: ${FETCH_RETRY_DELAY}"; exit 1 ;; esac
# --kubespray-version <V> ≡ --sub kubespray/<V>(只下载该版本的离线件; 版本名 = 上游 tag 全名)
if [ -n "${KUBESPRAY_VERSION_ARG}" ]; then
    [ -n "${SUB_ARG}" ] && { err "--kubespray-version 与 --sub 互斥(后者已给 ${SUB_ARG})"; exit 1; }
    SUB_ARG="kubespray/${KUBESPRAY_VERSION_ARG}"
fi
# --sub: 多值 + 路径归一化 —— 容忍"桶内全路径"写法(如 offline-files/cubestack-operator/portal
#   或 <桶名>/offline-files/...), 统一剥成相对 offline-files 的路径(cubestack-operator/portal);
#   仍拒绝绝对路径 / 上跳(免得拼出桶外路径)。
if [ -n "${SUB_ARG}" ]; then
    _norm=""
    for _s in ${SUB_ARG//,/ }; do
        [ -n "${_s}" ] || continue
        _s="${_s#./}"
        case "${_s}" in
            "${MINIO_BUCKET:-cubestack-installer}/${MINIO_REMOTE_DIR:-offline-files}/"*)
                _s="${_s#"${MINIO_BUCKET:-cubestack-installer}/${MINIO_REMOTE_DIR:-offline-files}/"}" ;;
        esac
        case "${_s}" in
            "${MINIO_REMOTE_DIR:-offline-files}/"*) _s="${_s#"${MINIO_REMOTE_DIR:-offline-files}/"}" ;;
            "${MINIO_REMOTE_DIR:-offline-files}")  _s="" ;;
        esac
        case "${_s}" in
            /*|*..*) err "--sub 必须是桶内相对路径(不允许以 / 开头或含 ..): ${_s}"; exit 1 ;;
        esac
        [ -n "${_s}" ] || continue
        case ",${_norm}," in *",${_s},"*) : ;; *) _norm="${_norm:+${_norm},}${_s}" ;; esac
    done
    SUB_ARG="${_norm}"
    [ -n "${SUB_ARG}" ] || { err "--sub 归一化后为空(只给 offline-files 根=全量; 请不带 --sub 走默认模式)"; exit 1; }
fi

# ---------------- 0. 校验器封装(供 verify-only / 下载后校验) ----------------
# release 模式校验: 统一调用 verify-offline-files.sh(唯一实现)。
# 失败时点名文件; --repair 只重下坏文件(最多 1 轮, 避免无限循环)。
# --verify-only: 本地只校验, 不依赖 mc/MinIO/远端/磁盘预检
if [ "${VERIFY_ONLY}" = "1" ]; then
    RELEASE_MODE=1
    if [ "${FLAT}" = "1" ]; then
        TARGET="${DEST_ARG:-${REPO_ROOT}/deployments/offline-files}"
        DST_ROOT="${TARGET}"
    else
        TARGET="${DEST_ARG:-${CUBESTACK_RELEASE_ROOT:-${REPO_ROOT}/offline-releases}}"
        DST_ROOT="${TARGET}/${RELEASE_ARG}"
    fi
    say "只校验, 不下载: ${DST_ROOT}(跳过下载磁盘空间预检)"
    _verify_release || exit 1
    echo ""
    ok "校验完成(未改动任何文件)"
    exit 0
fi

# ---------------- 1. mc client 检测 ----------------
say "检查 mc(MinIO Client) ..."
if command -v mc >/dev/null 2>&1; then
    ok "mc 已安装: $(command -v mc) ($(mc --version 2>/dev/null | awk '{print $3}' | head -c 12))"
else
    warn "未检测到 mc(MinIO Client)"
    echo "   安装方式一(MinIO 官方二进制, 推荐):"
    echo "     curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc && sudo chmod +x /usr/local/bin/mc"
    echo "   安装方式二: 直接使用 CLI 容器(Dockerfile-cli 已内置 mc)"
    if [ "${YES}" = "1" ]; then
        err "mc 未安装(--yes 模式不自动安装), 请先安装后重试"; exit 1
    fi
    read -r -p "是否自动下载安装 mc? [Y/n] " _ans
    if [[ "${_ans:-Y}" =~ ^[Yy] ]]; then
        curl -fsSL "https://dl.min.io/client/mc/release/linux-amd64/mc" -o /usr/local/bin/mc \
            && chmod +x /usr/local/bin/mc || { err "mc 下载/安装失败, 请手动安装"; exit 1; }
        ok "mc 已安装: $(command -v mc)"
    else
        exit 1
    fi
fi

# ---------------- 2. MinIO alias 检测 / 配置 ----------------
MINIO_ALIAS="${MINIO_ALIAS:-minio}"
MINIO_BUCKET="${MINIO_BUCKET:-cubestack-installer}"
MINIO_REMOTE_DIR="${MINIO_REMOTE_DIR:-offline-files}"

# mc ls 对不存在的路径也返回 0(空输出), 需以"输出非空"判定路径存在
# ⚠ 不要写成 `mc ls "$1" | grep -q .`:grep -q 命中第一行即退出 → mc 收到 SIGPIPE(退出码 141),
#   而本脚本是 `set -euo pipefail` → 整条管线被判为失败 → **输出多行的目录恒被判成"不存在"**
#   (桶级只有 1 行输出时 mc 已写完, 反而正常 —— 于是表现为"桶能访问、离线目录却找不到")。
#   实测: 17 行输出的目录 = 141; 改用命令替换读完所有输出则正常。
mc_has() { [ -n "$(mc ls "$1" 2>/dev/null)" ]; }

# ---------------- 发布版本 CLI tar 命名(2026-10-25) ----------------
# 新布局文件名带发布版本: cubestack-installer-cli-v<版本>.tar; 旧布局(无版本名)仅做兼容读取。
# release.json 的 cli_tar 字段是首选来源; 只取 basename, 防止路径穿越。
_default_cli_tar_name() { printf 'cubestack-installer-cli-v%s.tar' "${RELEASE_ARG#v}"; }
_cli_tar_name_from_json() {
    local json="$1"
    [ -f "${json}" ] || { printf '%s' ""; return 0; }
    python3 - "${json}" <<'PY' 2>/dev/null || true
import json, os, sys
try:
    v = json.load(open(sys.argv[1])).get("cli_tar") or ""
except Exception:
    v = ""
print(os.path.basename(v) if v else "")
PY
}
# 本地已下载布局: 按 release.json/版本化默认名定位; 旧布局回退。
_cli_tar_name_local() {
    local root="$1" name
    name="$(_cli_tar_name_from_json "${root}/offline-files/release.json")"
    [ -n "${name}" ] || name="$(_default_cli_tar_name)"
    if [ ! -f "${root}/${name}" ] && [ "${name}" != "cubestack-installer-cli.tar" ] \
        && [ -f "${root}/cubestack-installer-cli.tar" ]; then
        warn "本地缺少 ${name}, 回退旧布局 cubestack-installer-cli.tar"
        name="cubestack-installer-cli.tar"
    fi
    printf '%s' "${name}"
}
# 远端下载: 同上, 但以远端对象是否存在为准(兼容旧版本目录)。
_cli_tar_name_remote() {
    local src="$1" name
    name="$(_cli_tar_name_from_json "${DST_ROOT}/offline-files/release.json")"
    [ -n "${name}" ] || name="$(_default_cli_tar_name)"
    if ! mc_has "${src}/${name}" && [ "${name}" != "cubestack-installer-cli.tar" ] \
        && mc_has "${src}/cubestack-installer-cli.tar"; then
        warn "远端缺少 ${name}, 回退旧布局 cubestack-installer-cli.tar"
        name="cubestack-installer-cli.tar"
    fi
    printf '%s' "${name}"
}
# mc du 的大小字段(如 "1.1GiB") → 字节数; 无法解析输出 0
mc_size_to_bytes() {
    echo "${1:-}" | awk '
        /[0-9.]+[Tt](i?B)?$/ { x=$1; sub(/[Tt](i?B)?$/,"",x); printf "%d", x*1024^4; exit }
        /[0-9.]+[Gg](i?B)?$/ { x=$1; sub(/[Gg](i?B)?$/,"",x); printf "%d", x*1024^3; exit }
        /[0-9.]+[Mm](i?B)?$/ { x=$1; sub(/[Mm](i?B)?$/,"",x); printf "%d", x*1024^2; exit }
        /[0-9.]+[Kk](i?B)?$/ { x=$1; sub(/[Kk](i?B)?$/,"",x); printf "%d", x*1024; exit }
        { gsub(/[^0-9.]/,""); printf "%d", $1 }'
}

mc_alias_ready=0
if [ -n "${MINIO_ENDPOINT:-}" ] && [ -n "${MINIO_ACCESS_KEY:-}" ] && [ -n "${MINIO_SECRET_KEY:-}" ]; then
    say "MinIO 配置就绪(环境变量/minio.conf) → 配置 alias ${MINIO_ALIAS}: ${MINIO_ENDPOINT}"
    mc alias set "${MINIO_ALIAS}" "${MINIO_ENDPOINT}" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" >/dev/null 2>&1 \
        || { err "mc alias 配置失败(检查 MINIO_ENDPOINT/凭证/网络)"; exit 1; }
    ok "alias ${MINIO_ALIAS} 配置就绪"
    mc_alias_ready=1
else
    say "探测本机已有 mc alias(无 MINIO_ENDPOINT 配置) ..."
    # 先试默认 alias, 再遍历所有已配置 alias; 桶候选 = MINIO_BUCKET 值 + 已知布局
    # (默认桶 cubestack-installer 可能与实际 MinIO 布局不一致, 需逐个试)
    for al in "${MINIO_ALIAS}" $(mc alias list 2>/dev/null | awk '/^[A-Za-z0-9_.-]+[[:space:]]*$/{print $1}'); do
        [ -n "${al}" ] || continue
        for _b in "${MINIO_BUCKET}" "cubestack-installer" "cubestack-offline"; do
            [ -n "${_b}" ] || continue
            if mc_has "${al}/${_b}"; then
                ok "已有 alias '${al}' 可访问桶 ${_b}"
                MINIO_ALIAS="${al}"; MINIO_BUCKET="${_b}"; mc_alias_ready=1; break 2
            fi
        done
    done
fi
if [ "${mc_alias_ready}" != "1" ]; then
    if [ "${YES}" = "1" ]; then
        err "无可用 mc alias(--yes 模式不交互), 请先在 config/minio.conf 填 MINIO_ENDPOINT/ACCESS_KEY/SECRET_KEY 或配置 mc alias"; exit 1
    fi
    warn "未检测到可用的 MinIO 配置, 请交互录入(或先在 config/minio.conf 配置 MINIO_* 变量):"
    read -r -p "  MinIO 服务地址 (如 http://<minio-host>:9000): " _ept
    read -r -p "  AccessKey: " _ak
    read -r -s -p "  SecretKey: " _sk; echo ""
    [ -n "${_ept}" ] || { err "未输入 MinIO 地址"; exit 1; }
    mc alias set "${MINIO_ALIAS}" "${_ept}" "${_ak}" "${_sk}" >/dev/null 2>&1 \
        || { err "alias 配置失败(检查地址/凭证/网络)"; exit 1; }
    ok "alias ${MINIO_ALIAS} 配置就绪: ${_ept}"
fi

# ---------------- 3. 桶/目录自适应(兼容新旧布局) ----------------
probe_remote() {   # 找到可访问的 <bucket>/<remotedir>, 更新全局变量
    local b r
    for b in "${MINIO_BUCKET}" "cubestack-installer" "cubestack-offline"; do
        [ -n "${b}" ] || continue
        for r in "${MINIO_REMOTE_DIR}" "offline-files" "kubespray"; do
            if mc_has "${MINIO_ALIAS}/${b}/${r}"; then
                MINIO_BUCKET="${b}"; MINIO_REMOTE_DIR="${r}"; return 0
            fi
        done
    done
    return 1
}
if ! probe_remote; then
    # release 模式: 版本目录在桶根, 不依赖 offline-files/ 是否存在
    if [ -n "${RELEASE_ARG}" ] && mc_has "${MINIO_ALIAS}/${MINIO_BUCKET}/${RELEASE_ARG}"; then
        MINIO_REMOTE_DIR="offline-files"
    else
        err "MinIO 中找不到离线目录(尝试了 cubestack-installer / cubestack-offline 桶, offline-files / kubespray 目录)"
        err "请检查 config/minio.conf 的 MINIO_BUCKET / MINIO_REMOTE_DIR, 或 mc ls ${MINIO_ALIAS}/ 确认布局"
        exit 1
    fi
fi
# probe_remote 会更新 MINIO_BUCKET/MINIO_REMOTE_DIR, 须在其后组装 SRC_ROOT
SRC_ROOT="${MINIO_ALIAS}/${MINIO_BUCKET}/${MINIO_REMOTE_DIR}"
ok "MinIO 离线目录: ${SRC_ROOT}"

# ---------------- 3b. 发布版本(桶根 <版本>/offline-files + CLI tar) ----------------
if [ "${LIST_RELEASES}" = "1" ]; then
    say "MinIO 桶 ${MINIO_ALIAS}/${MINIO_BUCKET} 可用发布版本:"
    mc ls "${MINIO_ALIAS}/${MINIO_BUCKET}/" 2>/dev/null \
        | awk '{print $NF}' | sed 's#/$##' | command grep -E '^[0-9]' | sed 's/^/  - /' || true
    echo ""
    echo "  取件: $0 --release <版本> --dest <本地桶根>"
    exit 0
fi
if [ -n "${RELEASE_ARG}" ]; then
    RELEASE_MODE=1
    RELEASE_ROOT="${MINIO_ALIAS}/${MINIO_BUCKET}/${RELEASE_ARG}"
    if ! mc_has "${RELEASE_ROOT}/offline-files"; then
        err "MinIO 中无发布版本 ${RELEASE_ARG}: ${RELEASE_ROOT}/offline-files"
        err "  先看可用版本: $0 --list-releases"
        exit 1
    fi
    if ! mc_has "${RELEASE_ROOT}/offline-files/_SUCCESS"; then
        if mc_has "${RELEASE_ROOT}/_REFRESH_PENDING"; then
            err "发布正在原地刷新: ${RELEASE_ROOT}/_REFRESH_PENDING 存在(组件镜像同步中)"
            err "  刷新完成后 _SUCCESS 会重新写入; 请稍后重试, 不要手工删除 marker"
        else
            err "发布未完成: ${RELEASE_ROOT}/offline-files/_SUCCESS 不存在(上传中断或版本目录不完整)"
        fi
        exit 1
    fi
    SRC_ROOT="${RELEASE_ROOT}"
    ok "MinIO 发布版本: ${SRC_ROOT}"
fi

# ---------------- 4. 列出可用子目录 ----------------
if [ "${RELEASE_MODE}" = "1" ]; then
    say "发布版本 ${RELEASE_ARG} 包含: offline-files/ + cubestack-installer-cli-v${RELEASE_ARG#v}.tar"
else
echo ""
say "MinIO 中离线文件子目录(默认下载部署必需子目录, 排除 ${DEFAULT_EXCLUDE_SUBS}; 可 --sub <目录> 只拉某子目录 / --all 全量):"
mc ls "${SRC_ROOT}" 2>/dev/null | awk '{print "  - " $NF}'
echo ""
fi

# --list 模式: 到此结束
if [ "${LIST_ONLY}" = "1" ]; then
    if [ -n "${SUB_ARG}" ]; then
        # --list --sub <路径>: 下钻一级(如 --list --sub cubestack-operator → 列出全部组件子目录)
        _s="${SUB_ARG%%,*}"    # 列表模式取第一个(不做多值叠加)
        echo ""
        echo "  ${SRC_ROOT}/${_s}/ 下一级(全部可用名字):"
        mc ls "${SRC_ROOT}/${_s}" 2>/dev/null | awk '{print "    - "$NF}' || true
        echo ""
        echo "  下载其中某项: sudo ./fetch-offline-from-minio.sh --sub ${_s}/<名字>"
        exit 0
    fi
    echo ""
    echo "  二级(版本目录 + 各组件子目录; 名字以本输为准, 无需登录 MinIO 控制台):"
    # ⚠ set -euo pipefail: mc ls 打空时管道非 0 → 整支脚本静默中止; 每处都 || true。
    for _c in $(mc ls "${SRC_ROOT}" 2>/dev/null | awk '{print $NF}' | sed 's#/$##' || true); do
        [ -n "${_c}" ] || continue
        _subs="$( { mc ls "${SRC_ROOT}/${_c}" 2>/dev/null | awk '{print $NF}' | sed 's#/$##' || true; } | tr '\n' ' ')"
        [ -n "${_subs}" ] && echo "    ${_c}: ${_subs}"
    done | head -30
    echo ""
    echo "  下钻更多层级: sudo ./fetch-offline-from-minio.sh --list --sub cubestack-operator"
    echo "  只下载指定版本: sudo ./fetch-offline-from-minio.sh --kubespray-version v2.32.0"
    exit 0
fi

# ---------------- 5. 运行环境检测(容器内 / 宿主机) ----------------
# 容器内(CLI 镜像): 下载即落在 /opt/cubestack-installer/deployments/offline-files(离线文件唯一入口),
#   即装即用, 无需挂载提示; 宿主机: --auto 自动挑空闲 ≥ 门槛的最大磁盘, 完成后打印挂载命令。
IS_CONTAINER=0
if [ -f "/.dockerenv" ] || grep -qE '/docker/|/containerd/' /proc/1/cgroup 2>/dev/null; then
    IS_CONTAINER=1
fi

# ---------------- 6. 目标目录决策(离线文件根目录) ----------------
# 默认下载到 /opt/cubestack-installer/deployments/offline-files:
#   · 容器内: REPO_ROOT=/opt/cubestack-installer, 即默认 offline-files 路径;
#   · 宿主机直跑本仓库: 默认同一路径; 磁盘不足时用 --auto 换更大磁盘。
# 下载目录 = offline-files 总根(远端 offline-files/<子目录> 直接落到 <TARGET>/<子目录>):
#   只认用户显式 OFFLINE_FILES_DIR(环境变量/minio.conf)或 --dest; 都不设则用默认总根。
#   (本脚本不依赖 lib-common, 不会有它自动导出的 .../offline-files/kubespray 内层默认,
#    天然就是 offline-files 总根语义, 不会下载进 kubespray/ 内层。)
DEFAULT_DIR="${REPO_ROOT}/deployments/offline-files"
if [ "${RELEASE_MODE}" = "1" ]; then
    if [ "${FLAT}" = "1" ]; then
        DEFAULT_DIR="${REPO_ROOT}/deployments/offline-files"
    else
        DEFAULT_DIR="${REPO_ROOT}/offline-releases"
    fi
fi
if [ -n "${DEST_ARG}" ]; then
    TARGET="${DEST_ARG}"
    say "使用指定下载目录: ${TARGET}"
elif [ "${RELEASE_MODE}" = "1" ] && [ "${FLAT}" != "1" ] && [ -n "${CUBESTACK_RELEASE_ROOT:-}" ]; then
    TARGET="${CUBESTACK_RELEASE_ROOT}"
    say "使用 CUBESTACK_RELEASE_ROOT 本地桶根: ${TARGET}"
elif [ -n "${OFFLINE_FILES_DIR_EXPLICIT:-}" ] && [ "${RELEASE_MODE}" != "1" ]; then
    # 仅用户显式设置(环境变量/minio.conf)时才采用; release 模式不沿用 dev 根语义
    TARGET="${OFFLINE_FILES_DIR_EXPLICIT}"
    say "使用显式 OFFLINE_FILES_DIR 下载目录: ${TARGET}"
elif [ "${IS_CONTAINER}" = "1" ]; then
    TARGET="${DEFAULT_DIR}"
    say "容器内执行: 下载到默认目录 ${TARGET}"
elif [ "${AUTO}" = "1" ]; then
    _minkib="$(( MIN_FREE_GB * 1024 * 1024 ))"
    # `|| true`: df/sort 任一环节失败都会让赋值非 0 → set -e 结束脚本; 下面正是靠
    # `[ -n "${BEST}" ]` 判"没探到合适挂载点 → 用默认目录 + warn"。
    BEST="$(df -Pk 2>/dev/null \
        | awk -v mink="${_minkib}" 'NR>1 && $4 >= mink && $1 !~ /^\/dev\/loop/ && $1 !~ /^(tmpfs|devtmpfs|overlay|squashfs|shm|udev|none|proc|sysfs|iso9660|nfs|fuse|cgroup)/ \
               && $6 !~ /^\/(proc|sys|dev|run|snap|boot)/ {print $4, $6}' \
        | sort -rn | head -1 | awk '{print $2}' || true)"
    if [ -n "${BEST}" ]; then
        BEST_AVAIL="$(df -Pk "${BEST}" 2>/dev/null | awk 'NR==2 {printf "%.1f", $4/1024/1024}')"
        if [ "${RELEASE_MODE}" = "1" ] && [ "${FLAT}" != "1" ]; then
            TARGET="${BEST}/cubestack-installer"
        else
            TARGET="${BEST}/offline-files"
        fi
        say "自动检测: 空闲 ≥ ${MIN_FREE_GB} GiB 的挂载点中最大 = ${BEST}(约 ${BEST_AVAIL} GiB 可用)"
        say "下载目标: ${TARGET}"
    else
        TARGET="${DEFAULT_DIR}"
        warn "无可选磁盘空闲 ≥ ${MIN_FREE_GB} GiB(或检测失败), 使用默认目录: ${TARGET}"
    fi
else
    TARGET="${DEFAULT_DIR}"
    say "下载目录(默认): ${TARGET}"
    if [ "${YES}" != "1" ] && [ "${VERIFY_ONLY}" != "1" ]; then
        read -r -p "  确认下载到此目录? [Y/n] (n = --auto 自动挑最大磁盘, 或直接输入其他路径): " _ans
        case "${_ans:-Y}" in
            [Yy]|"") : ;;
            [Nn]) TARGET="${TARGET}" ;;
            *) TARGET="${_ans}" ;;
        esac
    fi
fi
DST_ROOT="${TARGET}"
if [ "${RELEASE_MODE}" = "1" ]; then
    if [ "${FLAT}" = "1" ]; then
        DST_ROOT="${TARGET}"
        say "release flat 下载目录(offline-files 根): ${DST_ROOT}"
    else
        DST_ROOT="${TARGET}/${RELEASE_ARG}"
        say "发布版本下载目录: ${DST_ROOT}"
    fi
fi

# ---------------- 7. 选择下载范围 ----------------
# 默认下载【部署必需】子目录(排除 DEFAULT_EXCLUDE_SUBS=virtual-machine, 仅创建 VM 时用);
#   --all = 真正全量(含 virtual-machine); --sub <目录> = 只拉指定目录(不受排除限制)。
_subs_all() {   # 输出 MinIO 根下全部子目录(排除 DEFAULT_EXCLUDE_SUBS)
    # 注: mc ls 对目录名带尾斜杠(如 "virtual-machine/"), 先剥掉再与排除列表匹配;
    #     跳过提示(say)写 stderr, 避免混入 stdout 被 mapfile 当子目录名收集。
    local s
    for s in $(mc ls "${SRC_ROOT}" 2>/dev/null | awk '{print $NF}' | sed 's#/$##'); do
        [ -n "${s}" ] || continue
        case " ${DEFAULT_EXCLUDE_SUBS} " in
            *" ${s} "*) say "  跳过 ${s}(默认排除, 需用 --sub ${s} 单独下载)" >&2 ;;
            *) echo "${s}" ;;
        esac
    done
}
SUBS=()
if [ "${RELEASE_MODE}" = "1" ]; then
    SUBS=("offline-files")
    if [ "${FLAT}" = "1" ]; then
        say "发布版本 ${RELEASE_ARG}: flat 平铺 offline-files/ → ${DST_ROOT}/"
    else
        say "发布版本 ${RELEASE_ARG}: 下载 offline-files/ + cubestack-installer-cli-v${RELEASE_ARG#v}.tar"
    fi
elif [ "${ALL}" = "1" ]; then
    # --all = 真正全量(含 virtual-machine; 同样剥掉目录名尾斜杠)
    mapfile -t SUBS < <(mc ls "${SRC_ROOT}" 2>/dev/null | awk '{print $NF}' | sed 's#/$##')
    say "全量下载(--all, 含 ${DEFAULT_EXCLUDE_SUBS}): ${#SUBS[@]} 个子目录"
elif [ -n "${SUB_ARG}" ]; then
    # 显式 --sub 不受排除限制; 支持多值(逗号分隔, 已在解析期归一化/去重)—— 逐个校验存在性
    for _s in ${SUB_ARG//,/ }; do
        [ -n "${_s}" ] || continue
        mc_has "${SRC_ROOT}/${_s}" || { err "MinIO 中无子目录 ${SRC_ROOT}/${_s}(用 --list 或 --list --sub <路径> 查看)"; exit 1; }
        SUBS+=("${_s}")
    done
    say "只拉取子目录(${#SUBS[@]} 个): ${SUB_ARG}"
else
    # 默认: 下载部署必需子目录(排除 virtual-machine)
    mapfile -t SUBS < <(_subs_all)
    say "默认下载部署必需子目录(排除 ${DEFAULT_EXCLUDE_SUBS}): ${#SUBS[@]} 个"
    if [ "${#SUBS[@]}" -eq 0 ]; then
        err "MinIO 离线目录 ${SRC_ROOT} 下无子目录可下载(全部被排除? 用 --sub <目录> 或 --all 或改 DEFAULT_EXCLUDE_SUBS)"; exit 1
    fi
fi

# ---------------- 8. 磁盘空间检查(醒目警告, 默认启用; --verify-only 跳过) ----------------
# 只校验本地已有发布树时不下载任何文件, 空间预检没有意义(且会误报"空间不足")。
if [ "${VERIFY_ONLY}" = "1" ]; then
    say "只校验模式: 跳过下载磁盘空间预检"
else
# 下载需要足够空间: 醒目提示至少 MIN_FREE_GB(默认 50)GiB 空闲;
# 并按"远程待下载大小 + 缓冲"预检, 不足时红色横幅警告并中止(--force 强制继续)。
[ -d "${DST_ROOT}" ] || mkdir -p "${DST_ROOT}"
# df 输出可能为科学计数法(>1TB 文件系统, 如 7.42899e+12)或带逗号, 统一规整为整数 Byte 数
TARGET_AVAIL_BYTES="$(df -Pk "${DST_ROOT}" 2>/dev/null | awk 'NR==2 {gsub(/,/,"",$4); printf "%.0f", $4*1024}')"
if [ -n "${TARGET_AVAIL_BYTES}" ] && [ "${TARGET_AVAIL_BYTES}" -gt 0 ]; then
    TARGET_AVAIL_GB="$(awk -v a="${TARGET_AVAIL_BYTES}" 'BEGIN{printf "%.1f", a/1024/1024/1024}')"
    say "目标磁盘可用: ${TARGET_AVAIL_GB} GiB (${DST_ROOT})"
else
    TARGET_AVAIL_BYTES=""
    TARGET_AVAIL_GB="?"
    warn "无法读取目标磁盘可用空间: ${DST_ROOT}"
fi

# 本次下载所需空间 = 远程待下载文件总大小(未下载部分) + 缓冲(重新同步文件数 × 10MiB)
NEED_BYTES=0
for s in "${SUBS[@]}"; do
    [ -n "${s}" ] || continue
    # 本次下载所需 = 远程待下载总大小 + 缓冲; mc du 输出 "大小<TAB>N objects<TAB>路径",
    # 大小在第 1 列(如 1.1GiB), 取 $1 即可
    # `|| true`: mc 取不到(网络/路径不存在)时管道非 0 → set -e 结束; 下面按 `${_rsize:-?}` 展示
    _rsize="$(mc du "${SRC_ROOT}/${s}" 2>/dev/null | awk -F'\t' '{print $1}' || true)"
    _rbytes="$(mc_size_to_bytes "${_rsize}")"
    _rbytes="${_rbytes:-0}"
    say "  远程 ${s}: ${_rsize:-?}"
    # 计算未下载部分大小(增量续传场景)
    _local_dir="${DST_ROOT}/${s}"
    [ "${FLAT}" = "1" ] && _local_dir="${DST_ROOT}"
    if [ "${_rbytes}" -gt 0 ] && [ -d "${_local_dir}" ]; then
        _local="$(du -sb "${_local_dir}" 2>/dev/null | awk '{print $1}')"
        _local="${_local:-0}"
        [ "${_local}" -gt 0 ] && [ "${_local}" -le "${_rbytes}" ] && _rbytes=$(( _rbytes - _local ))
    fi
    NEED_BYTES=$(( NEED_BYTES + _rbytes ))
done
if [ "${RELEASE_MODE}" = "1" ] && [ "${FLAT}" != "1" ]; then
    # 此时 release.json 尚未下载到本地; 先按版本化默认名探测, 旧版本目录回退旧名。
    _cli_rname="$(_default_cli_tar_name)"
    mc_has "${SRC_ROOT}/${_cli_rname}" || _cli_rname="cubestack-installer-cli.tar"
    _cli_rsize="$(mc du "${SRC_ROOT}/${_cli_rname}" 2>/dev/null | awk -F'\t' '{print $1}' || true)"
    _cli_rbytes="$(mc_size_to_bytes "${_cli_rsize}")"
    say "  远程 ${_cli_rname}: ${_cli_rsize:-?}"
    NEED_BYTES=$(( NEED_BYTES + ${_cli_rbytes:-0} ))
fi
NEED_BYTES=$(( NEED_BYTES + 10 * 1024 * 1024 ))
NEED_GB="$(awk -v n="${NEED_BYTES}" 'BEGIN{printf "%.1f", n/1024/1024/1024}')"

echo ""
echo -e "\033[41m\033[97m================================================================\033[0m"
echo -e "\033[41m\033[97m ⚠ 磁盘空间检查: 离线文件下载至少需要 ${WARN_NEED_GB} GiB 空闲空间           \033[0m"
echo -e "\033[41m\033[97m   本次下载约需 ${NEED_GB} GiB, 目标 ${DST_ROOT} 可用 ${TARGET_AVAIL_GB} GiB         \033[0m"
echo -e "\033[41m\033[97m   空间不足会导致 mc mirror/mc cp 下载中断/文件损坏, 请确保磁盘充足!      \033[0m"
echo -e "\033[41m\033[97m================================================================\033[0m"
echo ""

# 校验 1: 本次下载所需 ≤ 目标可用 → 不足则警告并中止(--force 强制继续)
if [ -n "${TARGET_AVAIL_BYTES}" ] && [ "${NEED_BYTES}" -gt "${TARGET_AVAIL_BYTES}" ]; then
    if [ "${FORCE}" = "1" ]; then
        warn "目标磁盘空间不足以完成本次下载(--force 强制继续, 风险自负)"
    else
        err "目标磁盘空间不足: 需要 ${NEED_GB} GiB, 仅剩 ${TARGET_AVAIL_GB} GiB"
        err "建议 --dest 换更大目录 / --auto 自动挑最大磁盘, 或用 --force 强制继续"
        exit 1
    fi
fi

# 校验 2: 醒目警告建议的空闲门槛(默认 50 GiB) — 达标只提示; 不达标且可用偏低时给更大横幅
if [ -n "${TARGET_AVAIL_BYTES}" ] && [ "${TARGET_AVAIL_BYTES}" -lt "$(( WARN_NEED_GB * 1024 * 1024 * 1024 ))" ]; then
    warn "当前磁盘剩余不足建议门槛 ${WARN_NEED_GB} GiB(仅 ${TARGET_AVAIL_GB} GiB), 离线文件会持续增加, 请留意空间"
fi

# ---------------- 8. 空间预检 ----------------
mkdir -p "${DST_ROOT}"
TARGET_AVAIL="$(df -Pk "${TARGET}" 2>/dev/null | awk 'NR==2 {gsub(/,/,"",$4); printf "%.0f", $4*1024}')"
for s in "${SUBS[@]}"; do
    [ -n "${s}" ] || continue
    # `|| true`: mc 取不到(网络/路径不存在)时管道非 0 → set -e 结束; 下面按 `${_rsize:-?}` 展示
    _rsize="$(mc du "${SRC_ROOT}/${s}" 2>/dev/null | awk -F'\t' '{print $1}' || true)"
    _rbytes="$(mc_size_to_bytes "${_rsize}")"
    _rbytes="${_rbytes:-0}"
    say "  远程 ${s}: ${_rsize:-?} → 目标可用: $(awk -v a="${TARGET_AVAIL}" 'BEGIN{printf "%.1f GiB", a/1024/1024/1024}')"
    # 预检: 远程大小 + MIN_FREE_GB 余量(未来离线文件还会增加) > 目标可用 → 警告
    if [ -n "${TARGET_AVAIL}" ] \
       && [ "$(( _rbytes + MIN_FREE_GB * 1024 * 1024 * 1024 ))" -gt "${TARGET_AVAIL}" ]; then
        warn "⚠ 远程 ${s}(${_rsize}) + ${MIN_FREE_GB} GiB 余量已接近/超过 ${TARGET} 可用空间, 建议 --dest 换更大磁盘"
    fi
done
fi

# --resume: 下载前先校验本地树; 不完整的文件按 offset 续传, 完整则直接退出
if [ "${RESUME}" = "1" ]; then
    _resume_base="${DST_ROOT}/offline-files"
    [ "${FLAT}" = "1" ] && _resume_base="${DST_ROOT}"
    if [ -f "${_resume_base}/SHA256SUMS" ]; then
        say "断点续传: 校验并修复本地树 ${_resume_base} ...(full 含镜像层校验, 大版本可能需数分钟)"
        REPAIR=1
        if _verify_release; then
            ok "本地树已完整, 无需重新下载"
            exit 0
        fi
        warn "断点续传/修复未完成, 继续正常下载(完成后仍会全量校验)"
        REPAIR=0
        REPAIR_DONE=0
    else
        warn "本地无 SHA256SUMS, 无法断点续传; 将正常下载"
    fi
    unset _resume_base
fi

# 清理模式: auto = release/flat 默认; dev/--sub 需显式 --clean
case "${CLEAN_MODE}" in
    yes) CLEAN=1 ;;
    no)  CLEAN=0 ;;
    auto) if [ "${RELEASE_MODE}" = "1" ]; then CLEAN=1; else CLEAN=0; fi ;;
esac
if [ "${CLEAN}" = "1" ]; then
    if [ "${YES}" != "1" ] && [ ! -t 0 ]; then
        err "精确清理需要交互确认: 非交互环境请加 --yes(或 --no-clean 保留本地多余文件)"
        exit 1
    fi
    if [ "${RELEASE_MODE}" = "1" ] && [ "${FLAT}" = "1" ]; then
        _clean_desc="${DST_ROOT}"
    elif [ "${RELEASE_MODE}" = "1" ]; then
        _clean_desc="${DST_ROOT}/offline-files"
    else
        _clean_desc="${DST_ROOT}(仅本次选中的子目录)"
    fi
    _clean_warning "${_clean_desc}"
    unset _clean_desc
fi

if [ "${VERIFY_ONLY}" = "1" ]; then
    CLI_TAR_BASENAME="$(_cli_tar_name_local "${DST_ROOT}")"
    say "只校验, 不下载: ${DST_ROOT}(跳过下载磁盘空间预检)"
    _verify_release || exit 1
else
    for s in "${SUBS[@]}"; do
        [ -n "${s}" ] || continue
        if [ "${RELEASE_MODE}" = "1" ] && [ "${FLAT}" = "1" ]; then
            if [ "${CLEAN}" = "1" ]; then
                say "精确镜像(清理多余) ${SRC_ROOT}/${s}/ → ${DST_ROOT}/ ..."
            else
                say "平铺复制 ${SRC_ROOT}/${s}/ → ${DST_ROOT}/ ..."
            fi
            _transfer "${SRC_ROOT}/${s}" "${DST_ROOT}" 0 \
                || { err "平铺复制 ${s} 失败(检查网络/磁盘空间)"; exit 1; }
        elif [ "${RELEASE_MODE}" = "1" ]; then
            # 默认 mc cp --recursive(按对象名精确复制); --clean 时用 mirror --remove 清理多余。
            if [ "${CLEAN}" = "1" ]; then
                say "精确镜像(清理多余) ${SRC_ROOT}/${s}/ → ${DST_ROOT}/${s}/ ..."
            else
                say "复制(精确对象) ${SRC_ROOT}/${s}/ → ${DST_ROOT}/${s}/ ..."
            fi
            _transfer "${SRC_ROOT}/${s}" "${DST_ROOT}/${s}" 1 \
                || { err "复制 ${s} 失败(检查网络/磁盘空间)"; exit 1; }
        else
            say "同步 ${SRC_ROOT}/${s}/ → ${DST_ROOT}/${s}/ ..."
            _transfer "${SRC_ROOT}/${s}" "${DST_ROOT}/${s}" 0 \
                || { err "同步 ${s} 失败(检查网络/磁盘空间)"; exit 1; }
        fi
        if [ "${FLAT}" = "1" ]; then
            ok "完成: ${DST_ROOT}  ($(du -sh "${DST_ROOT}" 2>/dev/null | awk '{print $1}'))"
        else
            ok "完成: ${DST_ROOT}/${s}  ($(du -sh "${DST_ROOT}/${s}" 2>/dev/null | awk '{print $1}'))"
        fi
    done
    if [ "${RELEASE_MODE}" = "1" ]; then
        if [ "${FLAT}" != "1" ]; then
            CLI_TAR_BASENAME="$(_cli_tar_name_remote "${SRC_ROOT}")"
            say "下载 ${SRC_ROOT}/${CLI_TAR_BASENAME} → ${DST_ROOT}/${CLI_TAR_BASENAME} ..."
            _mc_retry mc cp "${SRC_ROOT}/${CLI_TAR_BASENAME}" "${DST_ROOT}/${CLI_TAR_BASENAME}" \
                || { err "下载 CLI tar 失败"; exit 1; }
        fi
        _verify_release || exit 1
    fi
fi

echo ""
echo "================================================================="
ok "离线文件下载完成 → ${DST_ROOT}"
du -sh "${DST_ROOT}" 2>/dev/null | awk '{print "  总大小: "$1}'

echo ""
# 末尾配置提示: release 模式(flat/non-flat)都给出, 与容器内非 release 分支一致
_print_config_hint() {
    echo "  首次部署前(容器内还没有 cluster.conf):"
    echo "     cp deployments/config/cluster.conf.example deployments/config/cluster.conf"
    echo "     # ⑦ 修改配置(必须改): SSH_DEFAULT_PASSWORD 密码 / NODES 节点 IP 等信息 / METALLB_POOL 地址池"
    echo "     vim deployments/config/cluster.conf"
    echo "  ⚠ 已有 cluster.conf 请勿覆盖, 直接 vim 修改。"
}

if [ "${RELEASE_MODE}" = "1" ]; then
    echo "  发布版本 ${RELEASE_ARG} 已就绪 → ${DST_ROOT}"
    if [ "${FLAT}" = "1" ]; then
        echo "  flat 布局: 资产已平铺在 offline-files 根; 无需在 cluster.conf 配 release 变量。"
        echo "  load_config 会自动读取 ${DST_ROOT}/release.env(RELEASE_VERSION/版本变量)。"
        echo "  如需切回 latest: 移除/改名该 release.env, 或设 CUBESTACK_RELEASE_AUTO=\"false\"。"
        echo "  CLI tar 不在 flat 模式下载; 使用已有 CLI 镜像或单独 mc cp。"
        _print_config_hint
        echo "  部署:"
        echo "     sudo ./deployments/scripts/deploy-cluster.sh"
    else
        echo "  配置(cluster.conf):"
        echo "     CUBESTACK_RELEASE=\"${RELEASE_ARG}\""
        echo "     CUBESTACK_RELEASE_ROOT=\"${TARGET}\""
        echo "  加载 CLI 镜像:"
        echo "     sudo docker load -i ${DST_ROOT}/${CLI_TAR_BASENAME:-cubestack-installer-cli-v${RELEASE_ARG#v}.tar}"
        _print_config_hint
        echo "  部署:"
        echo "     sudo ./deployments/scripts/deploy-cluster.sh --release ${RELEASE_ARG}"
    fi
elif [ "${IS_CONTAINER}" = "1" ]; then
    echo "  容器内下载完成: 离线文件已落在 ${DST_ROOT}(容器挂载的 offline-files)。"
    echo "  接下来配置并开始部署:"
    echo "     cd /opt/cubestack-installer"
    echo "     # ① 首次: 从模板生成真实配置(cluster.conf 是唯一数据源, 所有 IP 不硬编码)"
    echo "     cp deployments/config/cluster.conf.example deployments/config/cluster.conf"
    echo "     # ② 修改配置(必须改): SSH_DEFAULT_PASSWORD 密码 / NODES 节点 IP 等信息 / METALLB_POOL 地址池"
    echo "     vim deployments/config/cluster.conf"
    echo "     # ③ 一键部署(默认 = --with-cubestack 全量: 装全部组件 + kubespray 离线安装)"
    echo "     ./deployments/scripts/deploy-cluster.sh"
else
    echo "  ① Docker CLI 容器挂载(把 ${DST_ROOT} 挂进容器 offline-files):"
    echo "     sudo docker run --rm -it --network host \\"
    echo "       -v ${DST_ROOT}:/opt/cubestack-installer/deployments/offline-files \\"
    echo "       -v \$PWD/deployments/config/cluster.conf:/opt/cubestack-installer/deployments/config/cluster.conf \\"
    echo "       -v \$HOME/.ssh:/root/.ssh \\"
    echo "       harbor.isuanova.com/suanova/cubestack-installer-cli:latest"
    echo ""
    echo "  ② 宿主机直跑(非容器, 让部署脚本指向大磁盘离线文件):"
    echo "     export OFFLINE_FILES_DIR=${DST_ROOT}"
    echo "     sudo ./deployments/scripts/deploy-cluster.sh"
fi
echo "================================================================="
