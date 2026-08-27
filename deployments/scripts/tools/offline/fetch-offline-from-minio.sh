#!/bin/bash
# ============================================================
# fetch-offline-from-minio.sh — 从 MinIO 下载离线部署文件到宿主机大磁盘, 并给出容器挂载命令
# ------------------------------------------------------------
# 用途: 在部署机(宿主机/新机器)上从 MinIO 拉取离线部署文件(binary + 镜像 tar + 系统包 +
#       GPU/LWS/虚拟机镜像), 下载到磁盘空间最大的挂载点(或 --dest 指定 / 默认 /opt/offline-files),
#       完成后打印 Docker CLI 容器的挂载命令(把下载目录挂进容器 offline-files 即可部署)。
# 特性:
#   · mc 检测: 未安装时给出安装指引, 并可选择自动下载(华为云镜像, 与 Dockerfile-cli 同源);
#   · mc alias 检测/配置: 优先用 cluster.conf 的 MINIO_ENDPOINT/ACCESS_KEY/SECRET_KEY 自动配置;
#     否则探测本机已有 alias 是否可访问(自动跳过占位 alias), 都没有则交互式录入并配置;
#   · 桶/目录自适应: 默认桶 cubestack-installer、目录 offline-files(与 MinIO 实际布局一致),
#     自动回退探测旧布局(cubestack-offline/kubespray);
#   · 磁盘检测: 自动选择可用空间最大的挂载点(排除 tmpfs/overlay/loop/snap/boot 等),
#     且要求空闲 ≥ MIN_FREE_GB(默认 50, 离线文件会持续增加; 用 --min-free 调整);
#   · 选择性下载: 默认只拉 kubespray(部署必需); --all 全量(含 metax-gpu/lws/os/虚拟镜像);
#   · 空间预检: 比对远程大小与本地可用空间, 不足时醒目警告;
#   · 结果提示: 打印容器挂载命令 + 宿主机直跑 OFFLINE_FILES_DIR 指引。
# 用法:
#   sudo ./fetch-offline-from-minio.sh                            # 默认: 只拉 kubespray
#   sudo ./fetch-offline-from-minio.sh --all                      # 全量离线文件(34GiB 级)
#   sudo ./fetch-offline-from-minio.sh --sub metax-gpu            # 只拉某子目录
#   sudo ./fetch-offline-from-minio.sh --dest /data/offline       # 指定下载目录(跳过磁盘检测)
#   sudo ./fetch-offline-from-minio.sh --min-free 100             # 磁盘空闲门槛 100GiB
#   sudo ./fetch-offline-from-minio.sh --yes                      # 跳过交互确认(自动化)
#   ./fetch-offline-from-minio.sh --list                          # 只列出 MinIO 可用目录(不需 root)
# 数据源: cluster.conf (MINIO_ALIAS / MINIO_ENDPOINT / MINIO_ACCESS_KEY / MINIO_SECRET_KEY /
#                       MINIO_BUCKET / MINIO_REMOTE_DIR)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# ---------------- 参数解析 ----------------
DEST_ARG=""
SUB_ARG=""
ALL=0
LIST_ONLY=0
YES=0
MIN_FREE_GB="${MIN_FREE_GB:-50}"     # 磁盘选择的最小空闲门槛(GB, 离线文件会持续增加)
while [ $# -gt 0 ]; do
    case "$1" in
        --dest) DEST_ARG="$2"; shift 2 ;;
        --sub)  SUB_ARG="$2"; shift 2 ;;
        --min-free) MIN_FREE_GB="$2"; shift 2 ;;
        --all)  ALL=1; shift ;;
        --list) LIST_ONLY=1; shift ;;
        -y|--yes) YES=1; shift ;;
        -h|--help) head -30 "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "未知参数: $1(可用 --dest/--sub/--min-free/--all/--list/-y)"; exit 1 ;;
    esac
done

# ---------------- 1. mc client 检测 ----------------
say "检查 mc(MinIO Client) ..."
if command -v mc >/dev/null 2>&1; then
    ok "mc 已安装: $(command -v mc) ($(mc --version 2>/dev/null | awk '{print $3}' | head -c 12))"
else
    warn "未检测到 mc(MinIO Client)"
    echo "   安装方式一(华为云镜像, 推荐):"
    echo "     sudo curl -fsSL https://mirrors.huaweicloud.com/minio/client/mc/latest/linux-amd64/mc -o /usr/local/bin/mc && sudo chmod +x /usr/local/bin/mc"
    echo "   安装方式二(MinIO 官方):"
    echo "     curl -O https://dl.min.io/client/mc/release/linux-amd64/mc && chmod +x mc && sudo mv mc /usr/local/bin/"
    echo "   安装方式三: 直接使用 CLI 容器(Dockerfile-cli 已内置 mc)"
    if [ "${YES}" = "1" ]; then
        err "mc 未安装(--yes 模式不自动安装), 请先安装后重试"; exit 1
    fi
    read -r -p "是否自动下载安装 mc? [Y/n] " _ans
    if [[ "${_ans:-Y}" =~ ^[Yy] ]]; then
        curl -fsSL "https://mirrors.huaweicloud.com/minio/client/mc/latest/linux-amd64/mc" -o /usr/local/bin/mc \
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
mc_has() { mc ls "$1" 2>/dev/null | grep -q .; }

mc_alias_ready=0
if [ -n "${MINIO_ENDPOINT:-}" ] && [ -n "${MINIO_ACCESS_KEY:-}" ] && [ -n "${MINIO_SECRET_KEY:-}" ]; then
    say "cluster.conf 提供 MinIO 配置 → 配置 alias ${MINIO_ALIAS}: ${MINIO_ENDPOINT}"
    mc alias set "${MINIO_ALIAS}" "${MINIO_ENDPOINT}" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" >/dev/null 2>&1 \
        || { err "mc alias 配置失败(检查 MINIO_ENDPOINT/凭证/网络)"; exit 1; }
    ok "alias ${MINIO_ALIAS} 配置就绪"
    mc_alias_ready=1
else
    say "探测本机已有 mc alias(无 cluster.conf MinIO 配置) ..."
    # 先试默认 alias, 再遍历所有已配置 alias; 桶候选 = cluster.conf 值 + 已知布局
    # (cluster.conf 示例默认 cubestack-offline 可能与实际 MinIO 布局不一致, 需逐个试)
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
        err "无可用 mc alias(--yes 模式不交互), 请先在 cluster.conf 填 MINIO_ENDPOINT/ACCESS_KEY/SECRET_KEY 或配置 mc alias"; exit 1
    fi
    warn "未检测到可用的 MinIO 配置, 请交互录入(或先在 cluster.conf 配置 MINIO_* 变量):"
    read -r -p "  MinIO 服务地址 (如 http://192.168.16.6:9000): " _ept
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
    err "MinIO 中找不到离线目录(尝试了 cubestack-installer / cubestack-offline 桶, offline-files / kubespray 目录)"
    err "请检查 cluster.conf 的 MINIO_BUCKET / MINIO_REMOTE_DIR, 或 mc ls ${MINIO_ALIAS}/ 确认布局"
    exit 1
fi
# probe_remote 会更新 MINIO_BUCKET/MINIO_REMOTE_DIR, 须在其后组装 SRC_ROOT
SRC_ROOT="${MINIO_ALIAS}/${MINIO_BUCKET}/${MINIO_REMOTE_DIR}"
ok "MinIO 离线目录: ${SRC_ROOT}"

# ---------------- 4. 列出可用子目录 ----------------
echo ""
say "MinIO 中离线文件子目录(可 --sub <目录> 单独拉取, --all 全量):"
mc ls "${SRC_ROOT}" 2>/dev/null | awk '{print "  - " $NF}'
echo ""

# --list 模式: 到此结束
if [ "${LIST_ONLY}" = "1" ]; then
    echo "  用法示例: sudo ./fetch-offline-from-minio.sh --sub kubespray   # 只拉 kubespray"
    exit 0
fi

# ---------------- 5. 目标目录决策 ----------------
# 优先级: --dest > 自动检测最大磁盘 > 默认 /opt/offline-files
if [ -n "${DEST_ARG}" ]; then
    TARGET="${DEST_ARG}"
    say "使用指定目录: ${TARGET}"
else
    # 磁盘选择: 空闲 ≥ MIN_FREE_GB 的挂载点中取可用空间最大的(排除伪文件系统/loop/snap/boot)
    _minkib="$(( MIN_FREE_GB * 1024 * 1024 ))"
    BEST="$(df -Pk 2>/dev/null \
        | awk -v mink="${_minkib}" 'NR>1 && $4 >= mink && $1 !~ /^\/dev\/loop/ && $1 !~ /^(tmpfs|devtmpfs|overlay|squashfs|shm|udev|none|proc|sysfs|iso9660|nfs|fuse|cgroup)/ \
               && $6 !~ /^\/(proc|sys|dev|run|snap|boot)/ {print $4, $6}' \
        | sort -rn | head -1 | awk '{print $2}')"
    if [ -n "${BEST}" ]; then
        BEST_AVAIL="$(df -Pk "${BEST}" 2>/dev/null | awk 'NR==2 {printf "%.1f", $4/1024/1024}')"
        TARGET="${BEST}/offline-files"
        say "自动检测: 空闲 ≥ ${MIN_FREE_GB} GiB 的挂载点中最大 = ${BEST}(约 ${BEST_AVAIL} GiB 可用)"
        echo "  下载目标: ${TARGET}"
        if [ "${YES}" != "1" ]; then
            read -r -p "  确认下载到此目录? [Y/n] (输入 n 改默认 /opt/offline-files, 或直接输入其他路径): " _ans
            case "${_ans:-Y}" in
                [Yy]|"") : ;;
                [Nn]) TARGET="/opt/offline-files"; say "改用默认目录: ${TARGET}" ;;
                *) TARGET="${_ans}"; say "改用指定目录: ${TARGET}" ;;
            esac
        fi
    else
        TARGET="/opt/offline-files"
        warn "无可选磁盘空闲 ≥ ${MIN_FREE_GB} GiB(或检测失败), 使用默认目录: ${TARGET}"
    fi
fi
DST_ROOT="${TARGET}/offline-files"

# ---------------- 6. 选择下载范围 ----------------
SUBS=()
if [ "${ALL}" = "1" ]; then
    mapfile -t SUBS < <(mc ls "${SRC_ROOT}" 2>/dev/null | awk '{print $NF}')
    say "全量下载: ${#SUBS[@]} 个子目录"
elif [ -n "${SUB_ARG}" ]; then
    mc_has "${SRC_ROOT}/${SUB_ARG}" || { err "MinIO 中无子目录 ${SRC_ROOT}/${SUB_ARG}(用 --list 查看)"; exit 1; }
    SUBS=("${SUB_ARG}")
else
    SUBS=("kubespray")
    say "默认下载 kubespray(部署必需); 如需 GPU/LWS/虚拟镜像等加 --all"
fi

# ---------------- 7. 空间预检 ----------------
mkdir -p "${DST_ROOT}"
TARGET_AVAIL="$(df -Pk "${TARGET}" 2>/dev/null | awk 'NR==2 {print $4*1024}')"
for s in "${SUBS[@]}"; do
    [ -n "${s}" ] || continue
    _rsize="$(mc du "${SRC_ROOT}/${s}" 2>/dev/null | awk -F'\t' '{print $1}')"
    _rbytes="$(echo "${_rsize}" | awk '
        /[0-9.]+[Tt](i?B)?$/ { x=$1; sub(/[Tt](i?B)?$/,"",x); printf "%d", x*1024^4; exit }
        /[0-9.]+[Gg](i?B)?$/ { x=$1; sub(/[Gg](i?B)?$/,"",x); printf "%d", x*1024^3; exit }
        /[0-9.]+[Mm](i?B)?$/ { x=$1; sub(/[Mm](i?B)?$/,"",x); printf "%d", x*1024^2; exit }
        /[0-9.]+[Kk](i?B)?$/ { x=$1; sub(/[Kk](i?B)?$/,"",x); printf "%d", x*1024; exit }
        { gsub(/[^0-9.]/,""); printf "%d", $1 }')"
    say "  远程 ${s}: ${_rsize:-?} → 目标可用: $(awk -v a="${TARGET_AVAIL}" 'BEGIN{printf "%.1f GiB", a/1024/1024/1024}')"
    # 预检: 远程大小 + MIN_FREE_GB 余量(未来离线文件还会增加) > 目标可用 → 警告
    if [ -n "${_rbytes}" ] && [ -n "${TARGET_AVAIL}" ] \
       && [ "$(( _rbytes + MIN_FREE_GB * 1024 * 1024 * 1024 ))" -gt "${TARGET_AVAIL}" ]; then
        warn "⚠ 远程 ${s}(${_rsize}) + ${MIN_FREE_GB} GiB 余量已接近/超过 ${TARGET} 可用空间, 建议 --dest 换更大磁盘"
    fi
done

# ---------------- 8. 下载(mc mirror 增量同步) ----------------
for s in "${SUBS[@]}"; do
    [ -n "${s}" ] || continue
    say "同步 ${SRC_ROOT}/${s}/ → ${DST_ROOT}/${s}/ ..."
    mc mirror --overwrite "${SRC_ROOT}/${s}" "${DST_ROOT}/${s}" \
        || { err "同步 ${s} 失败(检查网络/磁盘空间)"; exit 1; }
    ok "完成: ${DST_ROOT}/${s}  ($(du -sh "${DST_ROOT}/${s}" 2>/dev/null | awk '{print $1}'))"
done

echo ""
echo "================================================================="
ok "离线文件下载完成 → ${DST_ROOT}"
du -sh "${DST_ROOT}" 2>/dev/null | awk '{print "  总大小: "$1}'

echo ""
echo "  ① Docker CLI 容器挂载(把 ${TARGET} 挂进容器 offline-files):"
echo "     sudo docker run --rm -it --network host \\"
echo "       -v ${TARGET}/offline-files:/opt/cubestack-installer/deployments/offline-files \\"
echo "       -v \$PWD/deployments/config/cluster.conf:/opt/cubestack-installer/deployments/config/cluster.conf \\"
echo "       -v \$HOME/.ssh:/root/.ssh \\"
echo "       harbor.isuanova.com/cubestack/cubestack-installer-cli:latest"
echo ""
echo "  ② 宿主机直跑(非容器, 让部署脚本指向大磁盘离线文件):"
echo "     export OFFLINE_FILES_DIR=${DST_ROOT}"
echo "     sudo ./deployments/scripts/deploy-cluster.sh"
echo "================================================================="
