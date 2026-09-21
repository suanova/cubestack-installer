#!/bin/bash
# ============================================================
# netshoot-rdma-build.sh — CubeStack RDMA 诊断镜像: 联网机构建 + 保存离线 tar
# 需求: 把 netshoot(Alpine; 自带 tcpdump/ethtool/ip/ss/mtr/ping/nslookup)加上
#       · rdma-core  → ibv_devices / ibv_devinfo(verbs 层能不能看到卡)
#       · perftest   → ib_write_bw / ib_read_bw / ib_write_lat …(带宽/时延实测)
#       打成 tar, 供离线部署机用: 模块 35_netshoot.sh 把 tar 推到集群内置 registry。
#
# ── 为什么必须自建(而不是直接用 netshoot) ──
#   · 上游 netshoot **不含 rdma-core** → 没有 ibv_*(实测镜像内无 libibverbs / 无 rdma 二进制);
#   · Alpine 社区源**没有 perftest 包** → 只能源码编译(见 netshoot-rdma.Dockerfile 两阶段构建);
#   · 离线集群没软件源, pod 里 `apk add` 跑不通 → 必须构建期装好, 运行期只读。
#
# ── 基础镜像(优先离线) ──
#   ① 本仓库已备好的 offline-files/os/netshoot.tar(默认, 不依赖 Docker Hub, 版本与离线包一致);
#   ② 缺失或 --online → docker pull nicolaka/netshoot:latest。
#
# 「保持」语义(幂等): 目标 tar 已存在 → 跳过(只打印); --force 强制重建覆盖。
# 独立运行: 不 source lib-common.sh / 不 load_config(联网准备机上可裸跑)。
# 数据源: 环境变量(优先) / 内置默认(与 cluster.conf.example 声明一致)
#
# 用法:   sudo ./netshoot-rdma-build.sh                 # 构建 + 自检 + 保存 tar(已有则跳过)
#         sudo ./netshoot-rdma-build.sh --force         # 强制重建
#         sudo ./netshoot-rdma-build.sh --online        # 基础镜像走 docker pull(不用本地 tar)
#         sudo ./netshoot-rdma-build.sh --output DIR    # 指定输出目录
# 换版本: sudo 会清空环境变量, VAR= 必须写在 sudo **之后**:
#         sudo PERFTEST_VERSION=26.04.17 ./netshoot-rdma-build.sh --force
# ============================================================
set -euo pipefail

# ---- 独立运行: 自带最小日志与仓库根探测(与 rdma-save-images.sh 同款) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../deployments/scripts/tools/images
REPO_ROOT=""
_d="${SCRIPT_DIR}"
while [ "${_d}" != "/" ] && [ -z "${REPO_ROOT}" ]; do
    if [ -d "${_d}/deployments/scripts" ] && [ -d "${_d}/deployments/cubestack-addon" ]; then
        REPO_ROOT="${_d}"
    fi
    _d="$(dirname "${_d}")"
done
[ -n "${REPO_ROOT}" ] || { echo "【错误】未找到仓库根(本脚本需放在 <repo>/deployments/scripts/tools/images/ 下)"; exit 1; }

say()  { echo -e "\033[36m→  $*\033[0m"; }
ok()   { echo -e "\033[32m✅ $*\033[0m"; }
warn() { echo -e "\033[33m⚠  $*\033[0m"; }
err()  { echo -e "\033[31m【错误】$*\033[0m" >&2; }

# ---- 可配项(环境变量优先; 默认与 cluster.conf.example 声明一致) ----
PERFTEST_VERSION="${PERFTEST_VERSION:-26.04.17}"                       # 自建镜像 tag 与 perftest 版本
IMAGE_REPO="${NETSHOOT_RDMA_IMAGE:-netshoot-rdma}"                     # 本地构建 tag 的仓库名
SAVE_DIR="${NETSHOOT_SAVE_DIR:-${REPO_ROOT}/deployments/offline-files/netshoot}"
BASE_IMAGE="${NETSHOOT_BASE_IMAGE:-nicolaka/netshoot:latest}"           # perftest 版本 = 镜像 tag
BASE_TAR="${NETSHOOT_BASE_TAR:-${REPO_ROOT}/deployments/offline-files/os/netshoot.tar}"
# apk 源(装 build-base 用): 留空 = 上游 CDN。⚠ 实测上游在部分网络只有 ~70 KB/s(装 build-base 像卡死),
# 慢网络传国内镜像, 例如: sudo APK_MIRROR=https://mirrors.aliyun.com/alpine ./netshoot-rdma-build.sh
APK_MIRROR="${APK_MIRROR:-}"
DOCKERFILE="${SCRIPT_DIR}/netshoot-rdma.Dockerfile"
IMG_REF="${IMAGE_REPO}:${PERFTEST_VERSION}"
TAR_PATH="${SAVE_DIR}/netshoot-rdma-${PERFTEST_VERSION}.tar"

FORCE=0; ONLINE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --force|-f)  FORCE=1 ;;
        --online)    ONLINE=1 ;;
        --output)    shift; SAVE_DIR="${1:?--output 需要目录参数}"; TAR_PATH="${SAVE_DIR}/netshoot-rdma-${PERFTEST_VERSION}.tar" ;;
        *) err "未知参数: $1(用法见脚本头)"; exit 1 ;;
    esac
    shift
done

# ---- 前置检查 ----
command -v docker >/dev/null 2>&1 || { err "未找到 docker(本脚本需在**联网机**上执行)"; exit 1; }
docker info >/dev/null 2>&1 || { err "docker daemon 不可用(sudo 权限? 服务未起?)"; exit 1; }
[ -f "${DOCKERFILE}" ] || { err "Dockerfile 缺失: ${DOCKERFILE}"; exit 1; }

# ---- 幂等: 已有 tar 且未 --force → 跳过 ----
if [ -f "${TAR_PATH}" ] && [ "${FORCE}" != "1" ]; then
    ok "已存在, 跳过(要重建加 --force): ${TAR_PATH}"
    echo "  tag: ${IMG_REF}   大小: $(du -h "${TAR_PATH}" | awk '{print $1}')"
    exit 0
fi

say "构建 ${IMG_REF}(基础镜像 ${BASE_IMAGE}, perftest ${PERFTEST_VERSION})..."

# ---- 基础镜像: 优先本地 tar(离线), 缺失或 --online 时 docker pull ----
if docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1; then
    say "  基础镜像已在本地 docker: ${BASE_IMAGE}"
elif [ "${ONLINE}" != "1" ] && [ -f "${BASE_TAR}" ]; then
    say "  从离线 tar 载入基础镜像: ${BASE_TAR}"
    if docker load -i "${BASE_TAR}" >/dev/null 2>&1 && docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1; then
        ok "  已载入 ${BASE_IMAGE}"
    else
        # tar 里 tag 可能与 BASE_IMAGE 不同(如 nicolaka/netshoot:<别的tag>): 找同仓库镜像改 tag
        _found="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -m1 '^nicolaka/netshoot:' || true)"
        if [ -n "${_found}" ]; then
            docker tag "${_found}" "${BASE_IMAGE}"
            warn "  tar 内 tag 为 ${_found}, 已额外打上 ${BASE_IMAGE}"
        else
            err "离线 tar 载入失败且未找到 netshoot 镜像: ${BASE_TAR}"
            err "  ① 联网机确定可用时: 加 --online 直接 docker pull; ② 或先跑 tools/images 的 netshoot 备料"
            exit 1
        fi
    fi
else
    [ "${ONLINE}" = "1" ] && say "  基础镜像不在本地, docker pull(在线模式)..." \
                          || warn "  离线 tar 不存在(${BASE_TAR}), 退回 docker pull"
    docker pull "${BASE_IMAGE}" || { err "docker pull ${BASE_IMAGE} 失败(联网机网络?)"; exit 1; }
fi

# ---- 构建 ----
say "  docker build(两阶段: 编译 perftest → 装进 netshoot 运行时)..."
[ -n "${APK_MIRROR}" ] || warn "  apk 源未指定(用上游 CDN); 下载慢/像卡死时加 APK_MIRROR=https://mirrors.aliyun.com/alpine"

# ---- perftest 源码: 在**宿主机**取好再放进构建上下文 ----
# 为什么不在 Dockerfile 里 wget: 实测容器内访问 github.com 报 "Resource temporarily unavailable"
# (宿主机正常)。宿主机下载 + COPY 既绕开该差异, 也支持离线构建机预置源码包(PERFTEST_TARBALL=...)。
PERFTEST_TARBALL="${PERFTEST_TARBALL:-}"
_SRC_TGZ="$(mktemp /tmp/perftest-src-XXXXXX.tar.gz)"
if [ -n "${PERFTEST_TARBALL}" ]; then
    [ -f "${PERFTEST_TARBALL}" ] || { err "PERFTEST_TARBALL 指向的文件不存在: ${PERFTEST_TARBALL}"; exit 1; }
    cp "${PERFTEST_TARBALL}" "${_SRC_TGZ}"
    say "  使用预置源码包: ${PERFTEST_TARBALL}"
else
    _SRC_URL="https://github.com/linux-rdma/perftest/archive/refs/tags/${PERFTEST_VERSION}.tar.gz"
    say "  下载 perftest 源码(宿主机): ${_SRC_URL}"
    # 3 次重试: 实测到 github 的 TLS 会间歇性断流("unexpected eof while reading"), 与仓库其他
    # 拉取逻辑同款处理(push_image_skopeo 也是 3 次)
    _ok=0
    for _try in 1 2 3; do
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL -o "${_SRC_TGZ}" "${_SRC_URL}" && _ok=1
        else
            wget -q -O "${_SRC_TGZ}" "${_SRC_URL}" && _ok=1
        fi
        [ "${_ok}" = "1" ] && break
        [ "${_try}" -lt 3 ] && { warn "  下载失败(第 ${_try}/3 次), 3s 后重试..."; sleep 3; }
    done
    if [ "${_ok}" != "1" ]; then
        err "下载失败(3 次): ${_SRC_URL}"
        err "  · 版本号是否存在? 见 https://github.com/linux-rdma/perftest/tags"
        err "  · 离线构建机/网络抖动: 先自行下好该 tar, 再用 PERFTEST_TARBALL=<文件> 重跑本脚本"
        rm -f "${_SRC_TGZ}"; exit 1
    fi
fi
# 校验是 gzip tar(防代理返回 HTML 错误页被当源码编)
gzip -t "${_SRC_TGZ}" 2>/dev/null || { err "下载到的不是合法 gzip 包(疑似网络代理返回了错误页): $(file -b "${_SRC_TGZ}" | cut -c1-60)"; rm -f "${_SRC_TGZ}"; exit 1; }

# ---- 构建上下文: Dockerfile + 源码包(固定名 perftest-src.tar.gz) ----
_CTX="$(mktemp -d)"
trap 'rm -rf "${_CTX:-}"; rm -f "${_SRC_TGZ:-}"' EXIT
cp "${DOCKERFILE}" "${_CTX}/"
mv "${_SRC_TGZ}" "${_CTX}/perftest-src.tar.gz"

docker build -f "${_CTX}/$(basename "${DOCKERFILE}")" \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "PERFTEST_VERSION=${PERFTEST_VERSION}" \
    --build-arg "APK_MIRROR=${APK_MIRROR}" \
    -t "${IMG_REF}" "${_CTX}" \
    || { err "镜像构建失败(perftest 编译报错请把上面日志完整贴出)"; exit 1; }
ok "  构建完成: ${IMG_REF}"

# ---- 构建后自检(缺工具就失败, 不留"看着建成功、用起来缺东西"的镜像) ----
say " 自检: 容器内验证诊断工具在位..."
_check='
set -e
missing=""
for b in ibv_devices ibv_devinfo ib_write_bw ib_write_lat ib_read_bw tcpdump ip ss ethtool mtr ping nslookup; do
    command -v "$b" >/dev/null 2>&1 || missing="$missing $b"
done
[ -z "$missing" ] || { echo "MISSING:$missing"; exit 1; }
echo "  netshoot 工具: $(tcpdump --version 2>&1 | head -1)"
echo "  verbs  工具: ibv_devinfo -l → $(ibv_devinfo -l 2>&1 | head -1)"
echo "  perftest: $(ib_write_bw -V 2>&1 | head -1)"
echo "  容器内 RDMA 设备(构建机上预期为空): $(ls /dev/infiniband 2>/dev/null | tr "\n" " " || echo 无)"
'
if docker run --rm "${IMG_REF}" sh -c "${_check}"; then
    ok "  自检通过(ibv_* / perftest / netshoot 工具全部在位)"
else
    err "自检失败: 镜像缺工具(见上面 MISSING 行), 已中止 —— 不产出残缺 tar"
    exit 1
fi

# ---- 保存 tar ----
mkdir -p "${SAVE_DIR}"
say " 保存离线 tar → ${TAR_PATH}"
docker save "${IMG_REF}" -o "${TAR_PATH}" || { err "docker save 失败"; exit 1; }
ok "已保存: ${TAR_PATH}($(du -h "${TAR_PATH}" | awk '{print $1}'))"

echo "---------------------------------------------"
echo "  镜像 ref : ${IMG_REF}"
echo "  离线 tar : ${TAR_PATH}"
echo "  下一步   :"
echo "    ① tar 已在 ${SAVE_DIR}/ —— 与仓库约定一致, 部署机/容器同步即可;"
echo "    ② 部署: sudo ./deploy-cluster.sh --steps netshoot(模块把 tar 推入集群内置 registry 后起诊断 pod)"
echo "  自检重跑 : docker run --rm ${IMG_REF} sh -c 'ibv_devinfo -l; ib_write_bw -V'"
