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
# 不复制: 离线大文件(images/镜像 tar/节点侧二进制/VM 镜像/OS 镜像)、运行时凭据文件
#         (cluster.conf / hosts.yml / inventory.ini / artifacts)。
# 基础镜像: 默认 ubuntu:22.04 完整重建; 本地缺失时自动从
#           deployments/offline-files/os/ubuntu-22.04.tar docker load(离线可构建)。
# 增量构建(--incremental): 基础 = Harbor 旧 CLI 镜像, 只补装缺失 package + 更新 deployments, 秒级。
# 用法: sudo ./build-cli-context.sh                  # 生成 deployments/cli-context/
#       sudo ./build-cli-context.sh --build           # 全量构建(基础 ubuntu:22.04)
#       sudo ./build-cli-context.sh --build --push    # 全量构建并推送 Harbor
#       sudo ./build-cli-context.sh --build --incremental   # 增量构建(基础 Harbor latest)
#       sudo ./build-cli-context.sh --build --incremental --push   # 增量构建并推送
#       sudo ./build-cli-context.sh --output /tmp/cli-ctx
# 构建(手动): 生成后执行
#       sudo docker build -f Dockerfile-cli -t harbor.isuanova.com/cubestack/cubestack-installer-cli:latest deployments/cli-context/
# 说明: cli-context/ 为生成目录(gitignore), 每次构建前重新生成即可保证与源码一致。
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"

OUT="${REPO_ROOT}/deployments/cli-context"
IMAGE="harbor.isuanova.com/cubestack/cubestack-installer-cli:latest"
BASE_IMAGE="ubuntu:22.04"
INC_BASE_IMAGE="harbor.isuanova.com/cubestack/cubestack-installer-cli:latest"
OS_TAR="${REPO_ROOT}/deployments/offline-files/os/ubuntu-22.04.tar"
DO_BUILD=0
DO_PUSH=0
INCREMENTAL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --output) OUT="$2"; shift 2 ;;
        --build)  DO_BUILD=1; shift ;;
        --push)   DO_BUILD=1; DO_PUSH=1; shift ;;
        --incremental) DO_BUILD=1; INCREMENTAL=1; shift ;;
        -h|--help) head -20 "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "未知参数: $1(可用 --output/--build/--push/--incremental)"; exit 1 ;;
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

echo ""
ok "构建上下文就绪: ${OUT}  ($(du -sh "${OUT}" 2>/dev/null | awk '{print $1}'))"

if [ "${DO_BUILD}" = "1" ]; then
    if [ "${INCREMENTAL}" = "1" ]; then
        # ---- 增量构建: 基础 = Harbor 旧 CLI 镜像, 只补装缺失包 + 更新 deployments ----
        if ! docker image inspect "${INC_BASE_IMAGE}" >/dev/null 2>&1; then
            say "本地无 ${INC_BASE_IMAGE}, 尝试从 Harbor 拉取 ..."
            docker pull "${INC_BASE_IMAGE}" 2>/dev/null || {
                err "增量构建需要基础镜像 ${INC_BASE_IMAGE}(本地或 Harbor); 首次构建请用全量 --build 或 docker pull"; exit 1; }
        fi
        say "增量构建(基础 ${INC_BASE_IMAGE}: 补装缺失包 + 更新 deployments) ..."
        docker build -f "${OUT}/Dockerfile-cli-incremental" -t "${IMAGE}" "${OUT}" \
            || { err "增量构建失败"; exit 1; }
    else
        # ---- 全量构建: 基础 ubuntu:22.04, 本地缺失时从离线 OS 镜像 tar docker load(离线可构建) ----
        if ! docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1; then
            if [ -f "${OS_TAR}" ]; then
                say "本地无 ${BASE_IMAGE}, 从离线文件 docker load ..."
                docker load -i "${OS_TAR}"
            else
                err "基础镜像 ${BASE_IMAGE} 缺失且离线文件不存在(${OS_TAR}); 先运行 fetch-offline-from-minio.sh 或 docker pull ${BASE_IMAGE}"
                exit 1
            fi
        fi
        say "构建镜像(基于 ${BASE_IMAGE}) ..."
        docker build -f "${OUT}/Dockerfile-cli" -t "${IMAGE}" "${OUT}" \
            || { err "构建失败"; exit 1; }
    fi
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