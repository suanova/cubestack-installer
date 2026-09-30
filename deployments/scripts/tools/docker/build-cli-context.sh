#!/bin/bash
# ============================================================
# build-cli-context.sh — 生成 Docker CLI 镜像独立构建上下文(deployments/cli-context/)
# ------------------------------------------------------------
# 用途: 把"CLI 镜像需要的文件"单独生成到 cli-context/ 目录, 作为 docker build 的构建上下文,
#       与全量 offline-files 解耦 —— offline-files 未来增加镜像/组件/系统包都不影响镜像构建
#       (无需维护 .dockerignore 白名单, 也避免把 20G+ 离线文件送进构建上下文)。
# 原则: ① 全量同步 deployments/(仅排除 offline-files 大文件与运行时凭据), 保证除离线
#       **大文件**外, 所有部署代码/脚本/配置模板(kubespray 源码 / inventory group_vars /
#       cubestack-addon / config 模板 / skills 等)都打进容器, 避免漏文件;
#       ② **不打任何离线文件**(2026-09-30 起): kubectl/helm/skopeo 由容器**运行期**从挂载的
#       版本目录挂到 PATH(见 deployments/scripts/tools/docker/cli-toolchain-from-offline.sh),
#       镜像只含 deployments/ 代码 ⇒ 构建上下文与离线件体积彻底解耦。
#       ⚠ 唯一例外: **mc**(拉离线文件的引导工具, 不能被挂载提供; 上游 URL 已 410 Gone)
#         —— 从 offline-files/os/mc-* 拷入上下文 bin/mc。
# 不复制: 离线大文件(images/镜像 tar/节点侧二进制/VM 镜像/OS 镜像)、运行时凭据文件
#         (cluster.conf / hosts.yml / inventory.ini / artifacts)。
# 基础镜像: 默认 ubuntu:22.04 完整重建; 本地缺失时自动从
#           deployments/offline-files/os/ubuntu-22.04.tar docker load(离线可构建)。
# 增量构建(--incremental): 与 --build 同为**代码层**构建(都 FROM base), 区别只是跳过依赖对齐。
#   ⚠ **层数累积(2026-09-30 实测)**:增量每次在旧镜像上再叠十几层 ⇒ 层数单调增长;几百层时
#     containerd overlayfs 的 lowerdir(全部祖先层)超过内核 PAGE_SIZE 上限(4096 字节)⇒ buildkit 报
#     `mount source: overlay ... invalid argument`(实测 443 → 590 层, 第 5 步即挂不上, 与 Dockerfile 无关)。
#     ⇒ 有**层数守卫**(默认阈值 INCREMENTAL_MAX_LAYERS=300, 超了直接拒绝并提示改全量);
#     定期做一次**全量构建**即可把层数归零(基础 ubuntu:22.04 只有几层)。
# 用法: sudo ./build-cli-context.sh                  # 生成 deployments/cli-context/
#       sudo ./build-cli-context.sh --build           # 全量构建(基础 ubuntu:22.04)
#       sudo ./build-cli-context.sh --build --push    # 全量构建并推送 Harbor
#       sudo ./build-cli-context.sh --build --incremental   # 增量构建(基础 Harbor latest)
#       sudo ./build-cli-context.sh --build --incremental --push   # 增量构建并推送
#       sudo ./build-cli-context.sh --base            # **只在系统/工具/依赖变化时**重建 base 层
#       sudo ./build-cli-context.sh --base --push     # 重建并推送 base 层
# ★ 两层结构(2026-09-30): base(Dockerfile-cli-base: 系统+工具链+ansible+mc)极少变;
#   --build / --incremental 都只做**代码层**(FROM base + copy deployments)⇒ 快, 且**层数不累积**。
#       sudo ./build-cli-context.sh --output /tmp/cli-ctx
# 构建(手动): 生成后执行
#       sudo docker build -f Dockerfile-cli -t harbor.isuanova.com/suanova/cubestack-installer-cli:latest deployments/cli-context/
# 说明: cli-context/ 为生成目录(gitignore), 每次构建前重新生成即可保证与源码一致。
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"

OUT="${REPO_ROOT}/deployments/cli-context"
IMAGE="harbor.isuanova.com/suanova/cubestack-installer-cli:latest"
BASE_IMAGE="ubuntu:22.04"
# 两层结构(2026-09-30): base = 系统+工具链层(极少变), 代码层 FROM 它 ⇒ 层数不累积
CLI_BASE_TAG="harbor.isuanova.com/suanova/cubestack-installer-cli-base:latest"
CLI_BASE_DOCKERFILE="${REPO_ROOT}/Dockerfile-cli-base"
INC_BASE_IMAGE="${CLI_BASE_TAG}"
OS_TAR="${REPO_ROOT}/deployments/offline-files/os/ubuntu-22.04.tar"
DO_BUILD=0
DO_BASE=0
DO_PUSH=0
INCREMENTAL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --output) OUT="$2"; shift 2 ;;
        --build)  DO_BUILD=1; shift ;;
        --push)   DO_BUILD=1; DO_PUSH=1; shift ;;
        --incremental) DO_BUILD=1; INCREMENTAL=1; shift ;;
        --base)   DO_BASE=1; DO_BUILD=1; shift ;;
        -h|--help) head -20 "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "未知参数: $1(可用 --output/--build/--push/--incremental/--base)"; exit 1 ;;
    esac
done

say "生成 CLI 镜像构建上下文 → ${OUT}"
rm -rf "${OUT}"
mkdir -p "${OUT}/deployments"

# ---------------- 同步 Dockerfile-cli / Dockerfile-cli-incremental / .dockerignore(构建上下文 = 仓库根 Dockerfile) ----------------
# 构建统一以仓库根的 Dockerfile 为唯一事实来源: 先拷进上下文(便于 --output 独立上下文/离线),
# 后面 docker build 用 -f "${OUT}/<Dockerfile>", 保证构建与最新 Dockerfile 一致。
# .dockerignore 同理; 根目录缺失时(如只拷出 deployments)回退用上下文内默认。
cp "${REPO_ROOT}/Dockerfile-cli" "${OUT}/Dockerfile-cli"
[ -f "${CLI_BASE_DOCKERFILE}" ] && cp "${CLI_BASE_DOCKERFILE}" "${OUT}/Dockerfile-cli-base"
[ -f "${REPO_ROOT}/Dockerfile-cli-incremental" ] && cp "${REPO_ROOT}/Dockerfile-cli-incremental" "${OUT}/Dockerfile-cli-incremental"
[ -f "${REPO_ROOT}/.dockerignore" ] && cp "${REPO_ROOT}/.dockerignore" "${OUT}/.dockerignore" \
    || touch "${OUT}/.dockerignore"
ok "已同步 Dockerfile-cli(-incremental) / .dockerignore → ${OUT}"

# ---------------- 部署代码/配置模板(全量同步, 仅排除离线大文件与运行时凭据) ----------------
say "同步整个 deployments/(排除 offline-files 大文件与运行时凭据) ..."
# ⚠ 凭据类文件必须逐个挡掉(2026-09-20 事故): 原先只挡 cluster.conf / cluster.conf.bak,
#   结果 cluster.conf.bak.ceph(带后缀)、external-ceph.env、external-ceph-self-define-access.conf
#   全都进了构建上下文 → 被烧进 CLI 镜像层(镜像会分发, 等同凭据泄露)。
#   external-ceph* 用通配, 覆盖生成器以后新增的同族文件。
# ⚠ 注释只能写在命令**之前**: 续行符(\)之后的 `#` 不是注释, 会被当成 rsync 参数(踩过, 报
#   "syntax or usage error ... [Receiver]")。
rsync -a \
    --exclude 'offline-files' \
    --exclude 'cli-context' \
    --exclude 'kubespray/versions' \
    --exclude '.git' --exclude '.venv' --exclude 'venv' --exclude '.ansible' --exclude '.cache' \
    --exclude 'config/cluster.conf' --exclude 'config/cluster.conf.bak' --exclude 'config/cluster.conf.bak.*' \
    --exclude 'config/external-ceph*' --exclude 'config/minio.conf' \
    --exclude 'config/.deploy.state' --exclude 'config/.deploy.state.lock' \
    --exclude 'hosts.yml' --exclude 'inventory.ini' --exclude 'artifacts' \
    --exclude '*.swp' --exclude '*.swo' --exclude '*.swx' --exclude '*~' \
    "${REPO_ROOT}/deployments/" "${OUT}/deployments/"
say "同步 skills ..."
rsync -a --exclude '.git' "${REPO_ROOT}/skills" "${OUT}/"

# ---------------- CLI 工具链: 不再拷入(运行期从挂载离线目录挂载) ----------------
# 镜像只含 deployments/ 代码(用户口径 2026-09-30); 容器内 /etc/profile.d/50-cubestack-tools.sh
# 在**登录 shell**里把 kubectl/helm/skopeo 从挂载的版本目录挂到 PATH。故此处不再有 bin/ 段落。
say "跳过 CLI 二进制打包 —— kubectl/helm/skopeo 运行期从挂载的版本目录挂载(bash -lc 生效)"
# ⚠ 唯一例外: mc(MinIO Client)—— 容器要用它拉离线文件(先有鸡还是先有蛋), 且上游下载 URL
#   已 410 Gone(2026-09-30 实测)⇒ 从**离线件**拷入构建上下文 bin/mc(缺失时回退宿主机 mc)。
_mc_src=""
MC_ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
case "${MC_ARCH}" in amd64|arm64) : ;; *) MC_ARCH="amd64" ;; esac
for _c in "${REPO_ROOT}/deployments/offline-files/os"/mc-*; do
    [ -f "${_c}" ] && { _mc_src="${_c}"; break; }
done
if [ -z "${_mc_src}" ]; then
    # 回退 ①: 官方地址联网下载(⚠ 路径会变: 2026-09-30 实测老路径 /client/ 已 410 Gone,
    #   新路径带 /aistor/ 前缀; 故首选离线件, 这条路只是兜底)
    _mc_url="https://dl.min.io/aistor/mc/release/linux-${MC_ARCH}/mc"
    warn "离线件里没有 mc(offline-files/os/mc-*), 尝试联网下载: ${_mc_url}"
    if wget -q -O "${OUT}/bin/mc" "${_mc_url}" 2>/dev/null && [ -s "${OUT}/bin/mc" ]; then
        chmod +x "${OUT}/bin/mc"
        if "${OUT}/bin/mc" --version >/dev/null 2>&1; then
            _mc_src="${_mc_url}"
            warn "  已下载并验版本 ✓ —— 建议沉淀成离线件(offline-files/os/mc-<版本>-linux-amd64)后再发布镜像"
        else
            rm -f "${OUT}/bin/mc"; _mc_src=""
        fi
    fi
fi
if [ -z "${_mc_src}" ] && command -v mc >/dev/null 2>&1; then
    _mc_src="$(command -v mc)"
    warn "联网下载也失败, 回退用宿主机的 ${_mc_src} —— 建议沉淀成离线件后再发布镜像"
fi
if [ -n "${_mc_src}" ] && [ -f "${_mc_src}" ]; then
    mkdir -p "${OUT}/bin"
    cp "${_mc_src}" "${OUT}/bin/mc"
    ok "  mc ← ${_mc_src#${REPO_ROOT}/}"
elif [ -n "${_mc_src}" ]; then
    ok "  mc ← ${_mc_src}(联网下载)"
else
    err "找不到 mc: 离线件 offline-files/os/mc-* 缺失且宿主机没有 mc —— 全量构建会在 COPY bin/mc 处失败"
    err "  → 备料: 在任何有 mc 的机器上 cp /usr/bin/mc deployments/offline-files/os/mc-<版本>-linux-amd64"
    exit 1
fi

echo ""
ok "构建上下文就绪: ${OUT}  ($(du -sh "${OUT}" 2>/dev/null | awk '{print $1}'))"

if [ "${DO_BUILD}" = "1" ]; then
    if [ "${DO_BASE}" = "1" ]; then
        # ---- 只重建 base 层(系统+工具链): 新增 package/工具/依赖版本变化时才需要 ----
        if ! docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1; then
            if [ -f "${OS_TAR}" ]; then
                say "本地无 ${BASE_IMAGE}, 从离线文件 docker load ..."
                docker load -i "${OS_TAR}"
            else
                err "基础镜像 ${BASE_IMAGE} 缺失且离线文件不存在(${OS_TAR}); 先运行 fetch-offline-from-minio.sh 或 docker pull ${BASE_IMAGE}"
                exit 1
            fi
        fi
        [ -f "${OUT}/Dockerfile-cli-base" ] || { err "上下文缺 Dockerfile-cli-base(仓库里没有 ${CLI_BASE_DOCKERFILE}?)"; exit 1; }
        say "构建 base 层(系统+工具链; 需要联网 apt/pip) → ${CLI_BASE_TAG} ..."
        docker build -f "${OUT}/Dockerfile-cli-base" -t "${CLI_BASE_TAG}" "${OUT}" \
            || { err "base 构建失败"; exit 1; }
        _base_layers="$(docker history --no-trunc "${CLI_BASE_TAG}" 2>/dev/null | tail -n +2 | wc -l)"
        ok "base 层完成: ${CLI_BASE_TAG}(${_base_layers} 层)"
    fi

    # ---- 代码层构建(两种 Dockerfile 都 FROM base): 只 copy deployments 代码, 层数不累积 ----
    if ! docker image inspect "${CLI_BASE_TAG}" >/dev/null 2>&1; then
        say "本地无 base 镜像 ${CLI_BASE_TAG}, 尝试从 Harbor 拉取 ..."
        docker pull "${CLI_BASE_TAG}" 2>/dev/null || {
            err "缺 base 镜像 ${CLI_BASE_TAG}(本地与 Harbor 都没有)"
            err "  → 首次/系统或工具变化时先建 base: sudo $0 --base     (需要联网 apt/pip)"
            exit 1; }
    fi
    _df="Dockerfile-cli"; [ "${INCREMENTAL}" = "1" ] && _df="Dockerfile-cli-incremental"
    # 层数信息(base 是固定的, 代码层每次只加 1~2 层; 这里给个可观察的数字)
    _base_layers="$(docker history --no-trunc "${CLI_BASE_TAG}" 2>/dev/null | tail -n +2 | wc -l)"
    _cur_layers="$(docker history --no-trunc "${IMAGE}" 2>/dev/null | tail -n +2 | wc -l)"
    say "代码层构建(${_df} ← base ${CLI_BASE_TAG}(base ${_base_layers} 层 / 当前 latest ${_cur_layers:-0} 层)) ..."
    if [ "${INCREMENTAL}" = "1" ]; then
        say "  说明: --incremental 只 copy 代码(不跑依赖对齐); 依赖变化请用 --build"
    fi
    docker build -f "${OUT}/${_df}" --build-arg "CLI_BASE_TAG=${CLI_BASE_TAG}" -t "${IMAGE}" "${OUT}" \
        || { err "代码层构建失败"; exit 1; }
    ok "构建完成: ${IMAGE}"
    if [ "${DO_PUSH}" = "1" ]; then
        say "推送到 Harbor ..."
        docker push "${IMAGE}" || { err "推送失败(需先 docker login)"; exit 1; }
        ok "已推送: ${IMAGE}"
    fi
else
    echo "  构建镜像(全量, 基础 ubuntu:22.04):"
    echo "    sudo docker build -f Dockerfile-cli -t ${IMAGE} ${OUT}"
    echo "  构建镜像(增量, 基础 Harbor latest):"
    echo "    sudo docker build -f Dockerfile-cli-incremental -t ${IMAGE} ${OUT}"
    echo "  推送:"
    echo "    sudo docker push ${IMAGE}"
fi