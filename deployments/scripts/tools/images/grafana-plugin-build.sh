#!/bin/bash
# ============================================================
# grafana-plugin-build.sh — Grafana 数据源插件派生镜像: 联网机构建 + 保存离线 tar
#
# ── 为什么需要(2026-09-22 实机定位) ──
# Grafana 13.2 把 Prometheus 等数据源从内置改为**独立插件**, 启动时去 grafana.com 拉取;
# 离线环境拉不到 → 数据源对象存在但 Grafana 报 "Plugin not registered",
# **所有看板无数据**(Grafana 日志: `msg="Plugins installed" plugins=[]`)。
# 本脚本把官方签名插件**烤进镜像**, 配套模块 08 把 GF_PATHS_PLUGINS 指到 /opt/grafana-plugins。
#
# ── 与 netshoot-rdma 同款落地方式(仓库既有先例) ──
#   联网机构建 → docker save 到 offline-files/prometheus/ → 模块 08 把 tar 推进集群内置 registry。
#   派生镜像**不登记** images.manifest(它不对应任何上游镜像, CI 无从同步; 见该清单第 186 行附近的说明)。
#
# ── 基础镜像(按顺序回退, 全程不依赖 docker.io 也能建) ──
#   ① 本地 docker 已有 → 直接用;
#   ② offline-files/prometheus/ 里已有的 grafana tar → docker load;
#   ③ **Harbor 镜像源**(harbor.isuanova.com/mirrors/docker.io/grafana/grafana:<tag>) → docker pull;
#      CI 已把上游 grafana 镜像同步到那里(images.manifest 的 prometheus 组), 故通不了 docker.io 也能取;
#   ④ docker.io 直连(--online 强制走这条)。
#
# ── 插件 zip 也可预置(连 grafana.com 都不通时) ──
#   正常联网机直接下载; 若构建机连不上 grafana.com, 先在别处下好 zip, 用 PLUGIN_ZIP=<文件> 传入。
#   成功下载的 zip 会顺手留一份在 offline-files/prometheus/ 供下次复用。
#
# ── ⚠ 改了镜像内容必须换新 tag ──
#   同 tag 重建到不了集群: 节点 imagePullPolicy=IfNotPresent 会命中旧缓存。
#   本脚本默认 tag = <基础 tag>-r1; 改了插件/基础镜像就递增 rN, 并同步改 cluster.conf 的
#   PROMETHEUS_IMAGE_GRAFANA(那个值就是 pod 用的 tag)。
#
# 「保持」语义(幂等): 目标 tar 已存在 → 跳过(只打印); --force 强制重建。
# 独立运行: 不 source lib-common.sh / 不 load_config(联网准备机上可裸跑)。
#
# 用法:   sudo ./grafana-plugin-build.sh                    # 构建 + 自检 + 保存 tar(已有则跳过)
#         sudo ./grafana-plugin-build.sh --force            # 强制重建
#         sudo ./grafana-plugin-build.sh --online           # 基础镜像走 docker pull
#         sudo ./grafana-plugin-build.sh --output DIR       # 指定输出目录
#         sudo ./grafana-plugin-build.sh --push-harbor      # 存完 tar 再推 Harbor mirrors 作备份
#         sudo ./grafana-plugin-build.sh --from-harbor      # 反向: 跳过构建, 取 Harbor 上的派生镜像
#                                                           #  (CI 产物, 见 .github/workflows/build-grafana-plugin-image.yml)
# 换版本: sudo 会清空环境变量, VAR= 必须写在 sudo **之后**:
#         sudo PLUGIN_VERSION=2.1.0 IMAGE_TAG=13.2.1-distroless-r2 ./grafana-plugin-build.sh --force
# ============================================================
set -euo pipefail

# ---- 独立运行: 自带最小日志与仓库根探测(与 netshoot-rdma-build.sh 同款) ----
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
GRAFANA_BASE_TAG="${GRAFANA_BASE_TAG:-13.2.1-distroless}"                  # 基础镜像 tag(= cluster.conf PROMETHEUS_IMAGE_GRAFANA 的基础部分)
BASE_IMAGE="${GRAFANA_BASE_IMAGE:-grafana/grafana:${GRAFANA_BASE_TAG}}"    # 上游基础镜像
IMAGE_TAG="${IMAGE_TAG:-${GRAFANA_BASE_TAG}-r1}"                           # 派生镜像 tag(必须与 cluster.conf 一致)
IMAGE_REPO="${GRAFANA_DERIVED_REPO:-grafana}"                              # 本地构建 tag 的仓库名
PLUGIN_ID="${PLUGIN_ID:-prometheus}"                                       # grafana.com 插件 ID
PLUGIN_VERSION="${PLUGIN_VERSION:-}"                                       # 留空 = 取官方最新版(会打印出来)
SAVE_DIR="${GRAFANA_PLUGIN_SAVE_DIR:-${REPO_ROOT}/deployments/offline-files/prometheus}"
# Harbor 镜像源(基础镜像的兜底取法; 与 cluster.conf.example 的默认一致)
HARBOR_REGISTRY="${HARBOR_MIRROR_REGISTRY:-harbor.isuanova.com}"
HARBOR_PROJECT="${HARBOR_MIRROR_PROJECT:-mirrors}"
# Harbor 路径: mirrors/<上游注册域>/<仓库路径>:<tag>(见 images.manifest 头部的路径规则)
BASE_IMAGE_UPSTREAM="${GRAFANA_BASE_UPSTREAM:-docker.io/grafana/grafana:${GRAFANA_BASE_TAG}}"
HARBOR_BASE_REF="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${BASE_IMAGE_UPSTREAM}"
PLUGIN_ZIP_IN="${PLUGIN_ZIP:-}"                                            # 预置的插件 zip(跳过下载)
DOCKERFILE="${SCRIPT_DIR}/grafana-plugin.Dockerfile"
# --from-harbor 用: CI 构建后推到的位置(.github/workflows/build-grafana-plugin-image.yml)
HARBOR_DERIVED_REF="${HARBOR_REGISTRY:-harbor.isuanova.com}/cubestack/${IMAGE_REPO:-grafana}:${IMAGE_TAG:-}"
IMG_REF="${IMAGE_REPO}:${IMAGE_TAG}"
# ⚠ 文件名必须让模块 08 的末段通配 `*grafana_grafana_<tag>.tar` 命中(该模块按 tar 名找镜像)
TAR_PATH="${SAVE_DIR}/docker.io_grafana_grafana_${IMAGE_TAG}.tar"
BASE_TAR_GLOB="${SAVE_DIR}/*grafana_grafana_${GRAFANA_BASE_TAG}.tar"       # 已在离线目录里的基础镜像 tar

FORCE=0; ONLINE=0; FROM_HARBOR=0; PUSH_HARBOR=0
while [ $# -gt 0 ]; do
    case "$1" in
        --force|-f)  FORCE=1 ;;
        --online)    ONLINE=1 ;;
        --from-harbor) FROM_HARBOR=1 ;;   # 跳过本地构建: 直接拉 CI 已推到 Harbor 的派生镜像
        --push-harbor) PUSH_HARBOR=1 ;;   # 存完 tar 后, 再推到 Harbor mirrors 作备份
        --output)    shift; SAVE_DIR="${1:?--output 需要目录参数}"; TAR_PATH="${SAVE_DIR}/docker.io_grafana_grafana_${IMAGE_TAG}.tar"; BASE_TAR_GLOB="${SAVE_DIR}/*grafana_grafana_${GRAFANA_BASE_TAG}.tar" ;;
        --plugin-version) shift; PLUGIN_VERSION="${1:?--plugin-version 需要版本号}" ;;
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

# ---- 公共收尾: 自检 + 存离线 tar(两条路径共用: 本地构建 / --from-harbor) ----
_verify_and_save() {
    # 自检: 确认插件**真的在镜像里的预期路径**。为什么必须验: 若插件被烤到 /var/lib/grafana/plugins,
    # 部署后会被 chart 的 emptyDir 遮住 —— 那种"看着建成功、跑起来没插件"的镜像不能产出。
    # distroless 无 shell → 用 docker create + docker cp 取文件(cp 不需要容器内有任何二进制)。
    say "  自检: 校验镜像内插件路径与内容..."
    local _cid _pjt _pj
    _pjt="$(mktemp -d)"
    _cid="$(docker create "${IMG_REF}")"
    # ⚠ docker cp 目标是 `-` 时输出的是 **tar 流**, 不是裸文件 → 这里拷到临时目录再读
    if ! docker cp "${_cid}:/opt/grafana-plugins/${PLUGIN_ID}/plugin.json" "${_pjt}/" >/dev/null 2>&1; then
        docker rm -f "${_cid}" >/dev/null 2>&1 || true; rm -rf "${_pjt}"
        err "自检失败: 镜像内没有 /opt/grafana-plugins/${PLUGIN_ID}/plugin.json"
        err "  (插件被烤到了别处? 或 Dockerfile 的 COPY 目标与模块 08 的 PROMETHEUS_GRAFANA_PLUGIN_DIR 不一致)"
        exit 1
    fi
    docker rm -f "${_cid}" >/dev/null 2>&1 || true
    python3 - "${_pjt}/plugin.json" <<'PYEOF' || { rm -rf "${_pjt}"; err "自检失败: 镜像内 plugin.json 解析不了"; exit 1; }
import json, sys
m = json.load(open(sys.argv[1]))
print("  ✓ 镜像内插件: id=%s version=%s" % (m.get("id"), m.get("info", {}).get("version", "?")))
PYEOF
    rm -rf "${_pjt}"

    mkdir -p "${SAVE_DIR}"
    say " 保存离线 tar → ${TAR_PATH}"
    docker save "${IMG_REF}" -o "${TAR_PATH}" || { err "docker save 失败"; exit 1; }
    ok "已保存: ${TAR_PATH}($(du -h "${TAR_PATH}" | awk '{print $1}'))"

    # 可选: 推 Harbor mirrors 作备份(与上游 grafana 镜像同一路径规则, 只换 tag)。
    # 用途: ① 站点重装/换机时能从 Harbor 直接取, 不必重跑构建; ② 留一份可追溯的镜像源。
    # 需要先 docker login "${HARBOR_REGISTRY}"(私有项目); 失败只告警 —— tar 已落盘, 离线链路不受影响。
    if [ "${PUSH_HARBOR}" = "1" ]; then
        local _href="${HARBOR_REGISTRY}/mirrors/${BASE_IMAGE_UPSTREAM%:*}:${IMAGE_TAG}"
        say " 推送到 Harbor 备份 → ${_href}"
        if docker tag "${IMG_REF}" "${_href}" && docker push "${_href}" >/dev/null 2>&1; then
            ok "  已推送: ${_href}"
        else
            warn "  推送失败(需先 docker login ${HARBOR_REGISTRY}); tar 已保存, 离线部署不受影响"
        fi
    fi

    echo "---------------------------------------------"
    echo "  镜像 ref : ${IMG_REF}"
    echo "  离线 tar : ${TAR_PATH}"
    echo "  下一步   :"
    echo "    ① 把 offline-files/prometheus/ 同步到部署机(容器 c 的挂载目录 /data/offline-files);"
    echo "    ② cluster.conf 设 PROMETHEUS_IMAGE_GRAFANA=${IMAGE_TAG}"
    echo "       以及 PROMETHEUS_GRAFANA_PLUGIN_DIR=/opt/grafana-plugins(两处必须与本次构建一致);"
    echo "    ③ 重跑模块: bash deployments/scripts/modules/03_addon/08_prometheus.sh"
    echo "       (模块会把该 tar 推进集群内置 registry, 并断言 Grafana 数据源真的可用)"
}

# ---- --from-harbor: 跳过本地构建, 直接取 CI 已推到 Harbor 的派生镜像 ----
# 用途: 站点直连 GCS/grafana.com 很慢或不通时 —— 由 GitHub Actions 构建并推 Harbor
#       (.github/workflows/build-grafana-plugin-image.yml), 部署机只从 Harbor 取(局域网快)。
if [ "${FROM_HARBOR}" = "1" ]; then
    say "从 Harbor 拉取 CI 构建的派生镜像: ${HARBOR_DERIVED_REF}"
    docker pull "${HARBOR_DERIVED_REF}" || {
        err "拉取失败: ${HARBOR_DERIVED_REF}"
        err "  ① tag 是否已由 CI 构建推送? (Actions → build-grafana-plugin-image)"
        err "  ② 私有项目需先 docker login ${HARBOR_REGISTRY}"
        err "  ③ 没有 CI 产物时: 去掉 --from-harbor 走本地构建(需要能访问插件源)"
        exit 1
    }
    docker tag "${HARBOR_DERIVED_REF}" "${IMG_REF}"
    ok "  已取得并打 tag: ${IMG_REF}"
    _verify_and_save
    exit 0
fi

say "构建 ${IMG_REF}(基础镜像 ${BASE_IMAGE}; 插件 ${PLUGIN_ID})..."

# ---- 基础镜像: 本地 → 离线 tar → docker pull ----
if docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1; then
    say "  基础镜像已在本地 docker: ${BASE_IMAGE}"
elif [ "${ONLINE}" != "1" ] && ls ${BASE_TAR_GLOB} >/dev/null 2>&1; then
    _base_tar="$(ls -1 ${BASE_TAR_GLOB} | head -1)"
    say "  从离线 tar 载入基础镜像: ${_base_tar}"
    if docker load -i "${_base_tar}" >/dev/null 2>&1 && docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1; then
        ok "  已载入 ${BASE_IMAGE}"
    else
        # tar 里的 tag 可能与 BASE_IMAGE 不同: 找同仓库镜像改 tag
        _found="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -m1 '^grafana/grafana:' || true)"
        if [ -n "${_found}" ]; then
            docker tag "${_found}" "${BASE_IMAGE}"
            warn "  tar 内 tag 为 ${_found}, 已额外打上 ${BASE_IMAGE}"
        else
            err "离线 tar 载入失败且未找到 grafana/grafana 镜像: ${_base_tar}"
            err "  ① 联网机确定可用时: 加 --online 直接 docker pull; ② 或先跑 tools/images/harbor-save-images.sh --group prometheus 备料"
            exit 1
        fi
    fi
else
    # ③ Harbor 镜像源(CI 已同步过上游 grafana 镜像 → 通不了 docker.io 也能取)
    if [ "${ONLINE}" != "1" ] && docker pull "${HARBOR_BASE_REF}" >/dev/null 2>&1; then
        say "  已从 Harbor 镜像源取得: ${HARBOR_BASE_REF}"
        docker tag "${HARBOR_BASE_REF}" "${BASE_IMAGE}"
        ok "  已打 tag: ${BASE_IMAGE}"
    else
        [ "${ONLINE}" = "1" ] && say "  基础镜像不在本地, docker pull(在线模式)..." \
                              || warn "  离线 tar 与 Harbor 都取不到, 退回 docker.io 直连"
        docker pull "${BASE_IMAGE}" || {
            err "基础镜像取不到: ${BASE_IMAGE}"
            err "  ① 联网机: 加 --online; ② 纯离线: 先把 grafana tar 放进 ${SAVE_DIR}/;"
            err "  ③ 或由 CI 同步到 Harbor(images.manifest 的 prometheus 组)后确认 ${HARBOR_BASE_REF} 可达"
            exit 1
        }
    fi
fi

# ---- 插件版本: 留空则取官方最新 ----
if [ -z "${PLUGIN_VERSION}" ]; then
    say "  查询 ${PLUGIN_ID} 插件最新版本(grafana.com)..."
    PLUGIN_VERSION="$(curl -fsSL -m 25 "https://grafana.com/api/plugins/${PLUGIN_ID}" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null || true)"
    [ -n "${PLUGIN_VERSION}" ] || { err "取插件版本失败(网络? 或手工指定 --plugin-version <版本>)"; exit 1; }
fi
say "  插件版本: ${PLUGIN_ID}@${PLUGIN_VERSION}"

# ---- 插件 zip: 预置优先, 否则下载(3 次重试, 与仓库其他拉取逻辑同款) ----
_PLUGIN_ZIP="$(mktemp /tmp/grafana-plugin-XXXXXX.zip)"
trap 'rm -rf "${_CTX:-}"; rm -f "${_PLUGIN_ZIP:-}"' EXIT
_PLUGIN_URL="https://grafana.com/api/plugins/${PLUGIN_ID}/versions/${PLUGIN_VERSION}/download"
if [ -n "${PLUGIN_ZIP_IN}" ]; then
    [ -f "${PLUGIN_ZIP_IN}" ] || { err "PLUGIN_ZIP 指向的文件不存在: ${PLUGIN_ZIP_IN}"; exit 1; }
    cp "${PLUGIN_ZIP_IN}" "${_PLUGIN_ZIP}"
    say "  使用预置插件包: ${PLUGIN_ZIP_IN}"
else
    say "  下载插件: ${_PLUGIN_URL}"
    _ok=0
    for _try in 1 2 3; do
        curl -fsSL -m 300 -o "${_PLUGIN_ZIP}" "${_PLUGIN_URL}" && _ok=1 && break
        [ "${_try}" -lt 3 ] && { warn "  下载失败(第 ${_try}/3 次), 3s 后重试..."; sleep 3; }
    done
    if [ "${_ok}" != "1" ]; then
        err "插件下载失败(3 次): ${_PLUGIN_URL}"
        err "  构建机连不上 grafana.com 时: 先在能上网的机器下好该 zip, 再用 PLUGIN_ZIP=<文件> 重跑"
        exit 1
    fi
    # 留一份在离线目录: 下次纯离线重建可直接 PLUGIN_ZIP 复用, 也便于核对构建用了哪版
    mkdir -p "${SAVE_DIR}"
    cp "${_PLUGIN_ZIP}" "${SAVE_DIR}/${PLUGIN_ID}-${PLUGIN_VERSION}.zip" 2>/dev/null || true
fi

# ---- 解包到构建上下文 + 校验(签名/ID/版本) ----
_CTX="$(mktemp -d)"
# ⚠ 官方插件 zip **自带顶层目录**(条目形如 `prometheus/plugin.json`)—— 不能直接往 <ctx>/prometheus/
#   里解(cp 会变成 prometheus/prometheus/)。这里先解到临时目录, 再**动态定位** plugin.json 所在目录
#   当成 <ctx>/prometheus/, 两种布局(带/不带顶层目录)都成立。
_EXTRACT="$(mktemp -d)"
trap 'rm -rf "${_CTX:-}" "${_EXTRACT:-}"; rm -f "${_PLUGIN_ZIP:-}"' EXIT
python3 - "${_PLUGIN_ZIP}" "${_EXTRACT}" <<'PYEOF' || { err "解包失败(下载到的可能不是 zip: 代理错误页?)"; exit 1; }
import sys, zipfile
zf = zipfile.ZipFile(sys.argv[1])
zf.extractall(sys.argv[2])
PYEOF
_pj_parent="$(dirname "$(find "${_EXTRACT}" -name plugin.json -print -quit)")"
[ -n "${_pj_parent}" ] && [ -d "${_pj_parent}" ] || { err "插件包内找不到 plugin.json"; exit 1; }
mkdir -p "${_CTX}/${PLUGIN_ID}"
cp -a "${_pj_parent}/." "${_CTX}/${PLUGIN_ID}/"

python3 - "${_CTX}/${PLUGIN_ID}" "${PLUGIN_ID}" "${PLUGIN_VERSION}" <<'PYEOF' || exit 1
import json, os, sys
d, pid, pver = sys.argv[1:4]
pj = os.path.join(d, 'plugin.json')
if not os.path.isfile(pj):
    print(f"【错误】插件包内没有 plugin.json: {pj}"); sys.exit(1)
m = json.load(open(pj))
if m.get('id') != pid:
    print(f"【错误】插件 ID 不符: 期望 {pid}, 实得 {m.get('id')}"); sys.exit(1)
if m.get('type') != 'datasource':
    print(f"【错误】插件 type 不是 datasource: {m.get('type')}"); sys.exit(1)
# 签名文件: 官方 grafana.com 插件带 MANIFEST.txt(内含 Grafana Labs 签名)。缺了它 Grafana 会拒绝加载
# (除非开 allow_loading_unsigned_plugins, 那等于关掉这道防线 —— 本脚本不产出这种镜像)。
if not os.path.isfile(os.path.join(d, 'MANIFEST.txt')):
    print("【错误】插件包内缺 MANIFEST.txt(签名清单) —— 非官方包? 拒绝用它构建"); sys.exit(1)
print(f"  ✓ 插件校验通过: id={m.get('id')} type={m.get('type')} version={m.get('info',{}).get('version','?')} 期望版本={pver}")
PYEOF
cp "${DOCKERFILE}" "${_CTX}/"

# ---- 构建 ----
say "  docker build(基础镜像 + 插件 → ${IMG_REF})..."
docker build -f "${_CTX}/$(basename "${DOCKERFILE}")" \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    -t "${IMG_REF}" "${_CTX}" \
    || { err "镜像构建失败"; exit 1; }
ok "  构建完成: ${IMG_REF}"

# ---- 自检 + 保存(与 --from-harbor 路径共用同一段逻辑, 见上方 _verify_and_save) ----
_verify_and_save
