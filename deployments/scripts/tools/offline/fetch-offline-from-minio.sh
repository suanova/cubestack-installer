#!/bin/bash
# ============================================================
# fetch-offline-from-minio.sh — 从 MinIO 下载离线部署文件到宿主机大磁盘, 并给出容器挂载命令
# ------------------------------------------------------------
# 用途: 从 MinIO 拉取离线部署文件(binary + 镜像 tar + 系统包 + GPU/LWS/虚拟机镜像)到
#       默认下载目录 /opt/cubestack-installer/deployments/offline-files:
#       · 容器内执行(CLI 镜像已内置 mc): 下载直接落到容器挂载的 offline-files, 即装即用;
#       · 宿主机执行: 可 --auto 自动挑空闲最大的大磁盘下载, 完成后打印容器挂载命令。
# 特性:
#   · mc 检测: 未安装时给出安装指引, 并可选择自动下载(MinIO 官方二进制, 与 Dockerfile-cli 同源);
#   · mc alias 检测/配置: 优先用 cluster.conf 的 MINIO_ENDPOINT/ACCESS_KEY/SECRET_KEY 自动配置;
#     否则探测本机已有 alias 是否可访问(自动跳过占位 alias), 都没有则交互式录入并配置;
#   · 桶/目录自适应: 默认桶 cubestack-installer、目录 offline-files(与 MinIO 实际布局一致),
#     自动回退探测旧布局(cubestack-offline/kubespray);
#   · 磁盘检查(默认开启): 醒目提示磁盘至少需 MIN_FREE_GB(默认 50)GiB 空闲, 并比对
#     本次下载所需(远程总大小 + 缓冲)与目标可用空间; 不足时红色横幅警告并中止(--force 强制继续);
#   · 下载范围: 默认全量拉取 offline-files 下所有子目录(含 kubespray/metax-gpu/lws/os/虚拟镜像);
#     需要时可用 --sub <目录> 只拉某子目录;
#   · 结果提示: 容器内就绪提示; 宿主机打印容器挂载命令 + 直跑 OFFLINE_FILES_DIR 指引。
# 用法(容器内已 root, 无需 sudo):
#   ./fetch-offline-from-minio.sh                                 # 默认: 全量下载 offline-files 下所有文件
#   ./fetch-offline-from-minio.sh --sub kubespray                 # 只拉某子目录(如 kubespray)
#   ./fetch-offline-from-minio.sh --dest /data/offline-files      # 指定下载目录(即 offline-files 根)
#   sudo ./fetch-offline-from-minio.sh --auto                     # 宿主机: 自动挑空闲 ≥ 门槛的最大磁盘
#   sudo ./fetch-offline-from-minio.sh --min-free 100             # 磁盘空闲门槛 100GiB
#   sudo ./fetch-offline-from-minio.sh --force                    # 跳过磁盘空间不足检查(谨慎)
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
AUTO=0
FORCE=0
MIN_FREE_GB="${MIN_FREE_GB:-50}"     # 磁盘空间门槛(GB): 默认至少 50GiB 空闲, 离线文件会持续增加
WARN_NEED_GB="${WARN_NEED_GB:-50}"   # 醒目警告建议的总空闲门槛(GB)
while [ $# -gt 0 ]; do
    case "$1" in
        --dest) DEST_ARG="$2"; shift 2 ;;
        --sub)  SUB_ARG="$2"; shift 2 ;;
        --min-free) MIN_FREE_GB="$2"; shift 2 ;;
        --all)  ALL=1; shift ;;
        --list) LIST_ONLY=1; shift ;;
        --auto) AUTO=1; shift ;;
        --force) FORCE=1; shift ;;
        -y|--yes) YES=1; shift ;;
        -h|--help) head -30 "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "未知参数: $1(可用 --dest/--sub/--min-free/--auto/--force/--list/-y)"; exit 1 ;;
    esac
done

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
say "MinIO 中离线文件子目录(默认全量下载; 可 --sub <目录> 只拉某子目录):"
mc ls "${SRC_ROOT}" 2>/dev/null | awk '{print "  - " $NF}'
echo ""

# --list 模式: 到此结束
if [ "${LIST_ONLY}" = "1" ]; then
    echo "  用法示例: sudo ./fetch-offline-from-minio.sh --sub kubespray   # 只拉 kubespray"
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
DEFAULT_DIR="${REPO_ROOT}/deployments/offline-files"
if [ -n "${DEST_ARG}" ]; then
    TARGET="${DEST_ARG}"
    say "使用指定下载目录: ${TARGET}"
elif [ "${IS_CONTAINER}" = "1" ]; then
    TARGET="${DEFAULT_DIR}"
    say "容器内执行: 下载到默认目录 ${TARGET}"
elif [ "${AUTO}" = "1" ]; then
    _minkib="$(( MIN_FREE_GB * 1024 * 1024 ))"
    BEST="$(df -Pk 2>/dev/null \
        | awk -v mink="${_minkib}" 'NR>1 && $4 >= mink && $1 !~ /^\/dev\/loop/ && $1 !~ /^(tmpfs|devtmpfs|overlay|squashfs|shm|udev|none|proc|sysfs|iso9660|nfs|fuse|cgroup)/ \
               && $6 !~ /^\/(proc|sys|dev|run|snap|boot)/ {print $4, $6}' \
        | sort -rn | head -1 | awk '{print $2}')"
    if [ -n "${BEST}" ]; then
        BEST_AVAIL="$(df -Pk "${BEST}" 2>/dev/null | awk 'NR==2 {printf "%.1f", $4/1024/1024}')"
        TARGET="${BEST}/offline-files"
        say "自动检测: 空闲 ≥ ${MIN_FREE_GB} GiB 的挂载点中最大 = ${BEST}(约 ${BEST_AVAIL} GiB 可用)"
        say "下载目标: ${TARGET}"
    else
        TARGET="${DEFAULT_DIR}"
        warn "无可选磁盘空闲 ≥ ${MIN_FREE_GB} GiB(或检测失败), 使用默认目录: ${TARGET}"
    fi
else
    TARGET="${DEFAULT_DIR}"
    say "下载目录(默认): ${TARGET}"
    if [ "${YES}" != "1" ]; then
        read -r -p "  确认下载到此目录? [Y/n] (n = --auto 自动挑最大磁盘, 或直接输入其他路径): " _ans
        case "${_ans:-Y}" in
            [Yy]|"") : ;;
            [Nn]) TARGET="${TARGET}" ;;
            *) TARGET="${_ans}" ;;
        esac
    fi
fi
DST_ROOT="${TARGET}"

# ---------------- 7. 选择下载范围 ----------------
SUBS=()
if [ "${ALL}" = "1" ]; then
    mapfile -t SUBS < <(mc ls "${SRC_ROOT}" 2>/dev/null | awk '{print $NF}')
    say "全量下载: ${#SUBS[@]} 个子目录"
elif [ -n "${SUB_ARG}" ]; then
    mc_has "${SRC_ROOT}/${SUB_ARG}" || { err "MinIO 中无子目录 ${SRC_ROOT}/${SUB_ARG}(用 --list 查看)"; exit 1; }
    SUBS=("${SUB_ARG}")
    say "只拉取子目录: ${SUB_ARG}"
else
    # 默认全量: offline-files 下所有子目录都下载
    mapfile -t SUBS < <(mc ls "${SRC_ROOT}" 2>/dev/null | awk '{print $NF}')
    say "默认全量下载 offline-files 下所有子目录: ${#SUBS[@]} 个"
    if [ "${#SUBS[@]}" -eq 0 ]; then
        err "MinIO 离线目录 ${SRC_ROOT} 下无子目录可下载"; exit 1
    fi
fi

# ---------------- 8. 磁盘空间检查(醒目警告, 默认启用) ----------------
# 下载需要足够空间: 醒目提示至少 MIN_FREE_GB(默认 50)GiB 空闲;
# 并按"远程待下载大小 + 缓冲"预检, 不足时红色横幅警告并中止(--force 强制继续)。
[ -d "${DST_ROOT}" ] || mkdir -p "${DST_ROOT}"
TARGET_AVAIL_BYTES="$(df -Pk "${DST_ROOT}" 2>/dev/null | awk 'NR==2 {print $4*1024}')"
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
    _rsize="$(mc du "${SRC_ROOT}/${s}" 2>/dev/null | awk -F'\t' '{print $1}')"
    _rbytes="$(echo "${_rsize}" | awk '
        /[0-9.]+[Tt](i?B)?$/ { x=$1; sub(/[Tt](i?B)?$/,"",x); printf "%d", x*1024^4; exit }
        /[0-9.]+[Gg](i?B)?$/ { x=$1; sub(/[Gg](i?B)?$/,"",x); printf "%d", x*1024^3; exit }
        /[0-9.]+[Mm](i?B)?$/ { x=$1; sub(/[Mm](i?B)?$/,"",x); printf "%d", x*1024^2; exit }
        /[0-9.]+[Kk](i?B)?$/ { x=$1; sub(/[Kk](i?B)?$/,"",x); printf "%d", x*1024; exit }
        { gsub(/[^0-9.]/,""); printf "%d", $1 }')"
    say "  远程 ${s}: ${_rsize:-?}"
    # 计算未下载部分大小(增量续传场景)
    if [ -n "${_rbytes}" ] && [ "${_rbytes}" -gt 0 ] && [ -d "${DST_ROOT}/${s}" ]; then
        _local="$(du -sb "${DST_ROOT}/${s}" 2>/dev/null | awk '{print $1}')"
        _local="${_local:-0}"
        [ "${_local}" -gt 0 ] && [ "${_local}" -le "${_rbytes}" ] && _rbytes=$(( _rbytes - _local ))
    fi
    NEED_BYTES=$(( NEED_BYTES + _rbytes ))
done
NEED_BYTES=$(( NEED_BYTES + 10 * 1024 * 1024 ))
NEED_GB="$(awk -v n="${NEED_BYTES}" 'BEGIN{printf "%.1f", n/1024/1024/1024}')"

echo ""
echo -e "\033[41m\033[97m================================================================\033[0m"
echo -e "\033[41m\033[97m ⚠ 磁盘空间检查: 离线文件下载至少需要 ${WARN_NEED_GB} GiB 空闲空间           \033[0m"
echo -e "\033[41m\033[97m   本次下载约需 ${NEED_GB} GiB, 目标 ${DST_ROOT} 可用 ${TARGET_AVAIL_GB} GiB         \033[0m"
echo -e "\033[41m\033[97m   空间不足会导致 mc mirror 下载中断/文件损坏, 请确保磁盘充足!      \033[0m"
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

# ---------------- 9. 下载(mc mirror 增量同步) ----------------
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
if [ "${IS_CONTAINER}" = "1" ]; then
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
    echo "       harbor.isuanova.com/cubestack/cubestack-installer-cli:latest"
    echo ""
    echo "  ② 宿主机直跑(非容器, 让部署脚本指向大磁盘离线文件):"
    echo "     export OFFLINE_FILES_DIR=${DST_ROOT}"
    echo "     sudo ./deployments/scripts/deploy-cluster.sh"
fi
echo "================================================================="
