#!/bin/bash
# ============================================================
# TOOL: ceph-backup
# DESC: Ceph 恢复数据备份工具 —— 备份信息持久化到节点根盘(防 wipe) + 时间戳轮转(防覆盖) + systemd timer 定期刷新(可选)
# 背景:
#   · Rook-Ceph 认领旧 OSD 数据的关键是 fsid(注入新 CR 的 spec.fsid)。仅靠部署机上的备份文件
#     不可靠: 部署机/容器丢失即无备份; 单文件每次重装被覆盖 → 认领失败。
#   · 本工具把备份写到第一个 master 根盘 /var/lib/ceph/backup/(数据盘会被 wipe, 根盘不会):
#       current/cephcluster-backup.yaml   最新备份
#       <时间戳>/cephcluster-backup.yaml  历史版本(防覆盖, 保留 CEPH_BACKUP_RETENTION 份)
#   · 备份在**部署时手动执行**: deploy-cluster.sh 预检检测到旧集群 → 备份 CR → save 推送到节点根盘;
#     02_ceph.sh HEALTH_OK 后也会 save 一次(新集群 fsid 入库)。无后台定时备份
#     (可选: install-cron 安装 systemd timer 每小时刷新, 适合长期运行环境)。
#   · 恢复为**自动注入**: 保留数据模式(PRE_CLEANUP=false)重装时, 02_ceph.sh 自动 fetch-fsid
#     注入新 CR 的 spec.fsid 认领旧 OSD 数据, 无需手工指定。
# 用法(部署机, 需 SSH 密钥 + 容器内):
#   ceph-backup.sh save <cr.yaml> [meta.txt]      # 备份 CR(+meta) 到各节点, 时间戳轮转 + 更新 current/
#   ceph-backup.sh fetch-fsid                      # 从第一个 master 备份目录读最新 fsid(恢复用)
#   ceph-backup.sh install-cron [retention]        # 在第一个 master 安装 systemd timer 定期刷新
#   ceph-backup.sh run-cron [retention]            # master 上执行: 从集群刷新 current/ + 轮转(timer 条目)
# 数据源: cluster.conf (CEPH_BACKUP_DIR / CEPH_BACKUP_RETENTION / SSH_KEY_NAME / NODES)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

BACKUP_DIR="${CEPH_BACKUP_DIR:-/var/lib/ceph/backup}"
RETENTION="${CEPH_BACKUP_RETENTION:-10}"
# ★ 统一远端初始化(lib-common 幂等): 定义 FIRST_MASTER / SSH_KEY / SSH() / K / SSH_CMD
init_remote_kubectl || { err "init_remote_kubectl 失败(cluster.conf NODES 无 master?)"; exit 1; }

# ---- 工具: master 端轮转脚本(经 ssh 写入 /var/lib/ceph/backup/rotate.sh) ----
gen_rotate_script() {   # <retention>
    local ret="$1"
    cat <<EOF
#!/bin/bash
# ceph-backup 轮转: 保留最近 ${ret} 份时间戳备份, 删除更旧的
[ -d "${BACKUP_DIR}" ] || exit 0
ls -1d "${BACKUP_DIR}"/[0-9]*_* 2>/dev/null | sort -r | tail -n +$((ret+1)) | xargs -r rm -rf
EOF
}

# ---- save: 把本地 CR 备份(+可选 meta) 存入第一个 master 备份目录 ----
# 注意: 只写第一个 master(根盘持久化即可; 集群崩溃时该盘数据仍在)。
# 若需每节点一份, 可自行遍历 NODES 调用。
cmd_save() {
    [ $# -ge 1 ] && [ -s "$1" ] || { err "用法: ceph-backup.sh save <cr.yaml> [meta.txt]"; exit 1; }
    local cr="$1" meta="${2:-}"
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"

    say "备份 Ceph 恢复信息 → ${FIRST_MASTER}:${BACKUP_DIR}/ (时间戳 ${ts}, 保留 ${RETENTION} 份)..."
    SSH "sudo mkdir -p ${BACKUP_DIR}/current ${BACKUP_DIR}/${ts} && sudo chown -R \$(id -un) ${BACKUP_DIR}" >/dev/null 2>&1
    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q \
        "${cr}" "${SSH_USER:-ubuntu}@${FIRST_MASTER}:${BACKUP_DIR}/${ts}/cephcluster-backup.yaml" \
        || { err "scp 备份 CR 失败"; exit 1; }
    # current/ 与历史版本都保留(防覆盖); 历史版本由轮转清理
    SSH "cp ${BACKUP_DIR}/${ts}/cephcluster-backup.yaml ${BACKUP_DIR}/current/cephcluster-backup.yaml && \
         cp ${BACKUP_DIR}/${ts}/cephcluster-backup.yaml ${BACKUP_DIR}/latest.yaml && \
         printf 'backup_time: %s\nfsid: %s\n' '${ts}' \"\$(awk '/^status:/{f=1} f&&/fsid:/{print \$2; exit}' ${BACKUP_DIR}/${ts}/cephcluster-backup.yaml)\" > ${BACKUP_DIR}/${ts}/meta.txt && \
         cp ${BACKUP_DIR}/${ts}/meta.txt ${BACKUP_DIR}/current/meta.txt" \
        || warn "  current/ 更新失败(时间戳备份仍保留)"
    # ★ 关键凭据备份: rook-ceph-mon secret(含 fsid + mon-secret + ceph-secret)。
    #   Rook v1.20 CRD 无 spec.fsid 字段, 认领旧 OSD 数据唯一途径 = 复用该 secret;
    #   整 ns 重建(secret 丢失)后必须从本备份恢复才能认领(此前缺失导致恢复链断裂)。
    _SECRET_YAML="$( (SSH "${K} -n rook-ceph get secret rook-ceph-mon -o yaml 2>/dev/null" || true) )"
    if [ -n "${_SECRET_YAML}" ]; then
        _SECRET_FILE="/tmp/rook-ceph-mon-${ts}.yaml"
        printf '%s\n' "${_SECRET_YAML}" > "${_SECRET_FILE}"
        scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q \
            "${_SECRET_FILE}" "${SSH_USER:-ubuntu}@${FIRST_MASTER}:${BACKUP_DIR}/${ts}/rook-ceph-mon-secret.yaml" \
            && SSH "cp ${BACKUP_DIR}/${ts}/rook-ceph-mon-secret.yaml ${BACKUP_DIR}/current/rook-ceph-mon-secret.yaml" \
            && ok "  已备份 rook-ceph-mon secret(认领旧 OSD 数据的凭据, 整 ns 重建后可 restore-secret 恢复)" \
            || warn "  rook-ceph-mon secret 备份失败(整 ns 重建后将无法自动认领旧数据)"
        rm -f "${_SECRET_FILE}"
    else
        warn "  未获取到 rook-ceph-mon secret(集群可能未就绪); 认领恢复将不可用"
    fi
    if [ -n "${meta}" ] && [ -s "${meta}" ]; then
        scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q \
            "${meta}" "${SSH_USER:-ubuntu}@${FIRST_MASTER}:${BACKUP_DIR}/${ts}/node-disks.txt" 2>/dev/null || true
    fi
    # ★ mon store 备份(2026-09-07 新增, 认领恢复的最后一块拼图):
    #   Rook 认领旧 OSD 数据仅靠 secret(fsid)不够 —— OSD 本地 bluestore 里缓存的 osdmap epoch
    #   远高于新 mon 重建后的 epoch(旧 174 vs 新 20), OSD boot 时 mon 认为 OSD map 更新、拒绝处理
    #   (osd_boot 卡死, OSD 永远 down)。**mon store 里保存了 osdmap/PG map**, 恢复 mon store 后
    #   新 mon 的 osdmap epoch 与 OSD 一致 → OSD 正常 boot。
    #   因此 save 必须同时备份每个节点 /var/lib/rook/mon-*(mon store), 恢复流程见 restore-monstore。
    #   ⚠ mon failover 后 mon 可能不在原节点(如 mon-c→mon-d 换节点): 每轮 save 按**当前**实际
    #   分布打包; 无 mon 目录的节点删除该节点旧 tar, 避免恢复时用过时 store(mon 布局已变)。
    _MON_SAVED=0
    for _line in "${NODES[@]:-}"; do
        [ -z "${_line}" ] && continue
        node_parse "${_line}"
        [ -n "${NODE_IP}" ] || continue
        _MONS="$( (ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "${NODE_USER:-ubuntu}@${NODE_IP}" "sudo ls -d /var/lib/rook/mon-* 2>/dev/null | head -5" || true) )"
        if [ -z "${_MONS}" ]; then
            # 该节点当前无 mon: 删除历史 tar(过时布局), 防止 restore 误用
            SSH "rm -f ${BACKUP_DIR}/current/monstore-${NODE_HOSTNAME}.tar.gz ${BACKUP_DIR}/${ts}/monstore-${NODE_HOSTNAME}.tar.gz" 2>/dev/null || true
            continue
        fi
        # 打包该节点全部 mon-* 目录(store.db 等), 按节点 hostname 命名存到备份机
        # ⚠ 通配符展开按 shell 当前目录, 必须先 cd 到 /var/lib/rook 再 tar(否则 mon-* 不展开)
        # ★ 间歇性 SSH 失败(网络抖动/连接数限制)会导致单节点缺 tar → 重试 2 次
        _OK=0
        for _try in 1 2 3; do
            if ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${NODE_USER:-ubuntu}@${NODE_IP}" \
                "sudo bash -c 'cd /var/lib/rook && tar czf /tmp/rook-monstore-${NODE_HOSTNAME}.tar.gz mon-* 2>/dev/null' && sudo chown \$(id -un) /tmp/rook-monstore-${NODE_HOSTNAME}.tar.gz" \
                && scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q \
                    "${NODE_USER:-ubuntu}@${NODE_IP}:/tmp/rook-monstore-${NODE_HOSTNAME}.tar.gz" "/tmp/rook-monstore-${NODE_HOSTNAME}.tar.gz" \
                && scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q \
                    "/tmp/rook-monstore-${NODE_HOSTNAME}.tar.gz" "${SSH_USER:-ubuntu}@${FIRST_MASTER}:${BACKUP_DIR}/${ts}/monstore-${NODE_HOSTNAME}.tar.gz" \
                && SSH "cp ${BACKUP_DIR}/${ts}/monstore-${NODE_HOSTNAME}.tar.gz ${BACKUP_DIR}/current/monstore-${NODE_HOSTNAME}.tar.gz"; then
                _OK=1; break
            fi
            [ "${_try}" -lt 3 ] && warn "  ${NODE_HOSTNAME} mon store 第 ${_try} 次失败, 重试..."
            sleep 2
        done
        if [ "${_OK}" = "1" ]; then
            _MON_SAVED=1
        else
            _MON_FAIL="${_MON_FAIL:-}${_MON_FAIL:+ }${NODE_HOSTNAME}"
            warn "  ${NODE_HOSTNAME} mon store 备份失败(3 次; 认领恢复将缺该节点 mon)"
        fi
        rm -f "/tmp/rook-monstore-${NODE_HOSTNAME}.tar.gz"
        ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${NODE_USER:-ubuntu}@${NODE_IP}" \
            "sudo rm -f /tmp/rook-monstore-${NODE_HOSTNAME}.tar.gz" 2>/dev/null || true
    done
    if [ -n "${_MON_FAIL:-}" ]; then
        err "mon store 备份不完整, 失败节点: ${_MON_FAIL}(重跑 save 或手工打包该节点 mon-*); 恢复将缺这些节点 mon"
    fi
    [ "${_MON_SAVED}" = "1" ] && ok "  已备份 mon store(各节点 /var/lib/rook/mon-*, 含 osdmap/PG map, 认领恢复必需)" \
        || warn "  未备份到任何 mon store(节点无 mon-*? 或 SSH 失败); 整 ns 重建后将无法认领旧 OSD"
    # 轮转清理
    SSH "bash -s" < <(gen_rotate_script "${RETENTION}") || true
    ok "Ceph 备份完成: ${BACKUP_DIR}/current/cephcluster-backup.yaml(历史 ${ts})"
}

# ---- restore-secret: 从节点备份恢复 rook-ceph-mon secret(整 ns 重建后认领旧 OSD 数据) ----
# 恢复路径: current/rook-ceph-mon-secret.yaml → 无则历史时间戳目录取最新。
# 幂等: namespace 已有该 secret 则跳过(避免覆盖运行中集群)。
cmd_restore_secret() {
    say "从节点备份恢复 rook-ceph-mon secret → namespace ${CEPH_NAMESPACE} ..."
    # 已存在则跳过(认领已就绪)
    if SSH "${K} -n ${CEPH_NAMESPACE} get secret rook-ceph-mon --no-headers" 2>/dev/null | grep -q .; then
        ok "  namespace 已有 rook-ceph-mon secret, 无需恢复"
        return 0
    fi
    # 备份文件: current 优先, 历史时间戳兜底
    _SRC=""
    if SSH "test -s ${BACKUP_DIR}/current/rook-ceph-mon-secret.yaml" 2>/dev/null; then
        _SRC="${BACKUP_DIR}/current/rook-ceph-mon-secret.yaml"
    else
        _TS="$( (SSH "ls -1d ${BACKUP_DIR}/[0-9]*_* 2>/dev/null | sort | tail -1" || true) )"
        if [ -n "${_TS}" ] && SSH "test -s ${_TS}/rook-ceph-mon-secret.yaml" 2>/dev/null; then
            _SRC="${_TS}/rook-ceph-mon-secret.yaml"
        fi
    fi
    [ -n "${_SRC}" ] || { err "节点备份目录无 rook-ceph-mon-secret.yaml(${FIRST_MASTER}:${BACKUP_DIR}) —— 需先在有 secret 时执行 ceph-backup.sh save"; return 1; }
    # 拉回本地 → kubectl apply 恢复(secret 的 data 是 base64, 直接 apply 即可)
    _TMP="/tmp/rook-ceph-mon-restore.yaml"
    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q \
        "${SSH_USER:-ubuntu}@${FIRST_MASTER}:${_SRC}" "${_TMP}" || { err "拉取备份 secret 失败"; return 1; }
    if SSH "kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f -" < "${_TMP}" 2>/dev/null; then
        _FSID="$( (SSH "${K} -n ${CEPH_NAMESPACE} get secret rook-ceph-mon -o jsonpath='{.data.fsid}' 2>/dev/null" || true) | base64 -d 2>/dev/null )"
        ok "  rook-ceph-mon secret 已恢复(fsid=${_FSID:-?}); Rook 将凭它认领旧 OSD 数据"
        rm -f "${_TMP}"
        return 0
    fi
    # 回退: scp 拉回失败或 apply 失败 → 直接在节点上用 SSH_CMD 读远端文件 apply
    if SSH "sudo sh -c 'cat ${_SRC} | kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f -'" 2>/dev/null; then
        ok "  rook-ceph-mon secret 已恢复(节点侧 apply)"
        rm -f "${_TMP}"
        return 0
    fi
    err "  恢复 secret 失败; 可手工: kubectl apply -f ${_TMP} 后重跑"
    return 1
}

# ---- restore-monstore: 从备份恢复各节点 mon store(整 ns 重建后, 在 mon 启动前执行) ----
# 背景: OSD 认领旧数据后, OSD 本地 bluestore 缓存的 osdmap epoch 远高于新 mon(旧 174 vs 新 20),
#       mon 拒绝处理 OSD 的 osd_boot(认为 OSD map 更新) → OSD 永远 down。
#       mon store 内含 osdmap/PG map(epoch 174), 恢复到各节点 /var/lib/rook/mon-* 后,
#       新 mon 以旧 store 启动 → osdmap epoch 与 OSD 一致 → OSD 正常 boot。
# 备份文件: backup/current/monstore-<hostname>.tar.gz(save 时按节点生成), 历史时间戳兜底。
# 用法:
#   restore-monstore            # 幂等: 节点已有 mon-* 则跳过(健康集群保护, 绝不覆盖运行中集群)
#   restore-monstore --force    # 强制恢复: 清掉节点全部残留 mon-*, 再从备份解包(整 ns 重建认领场景)
cmd_restore_monstore() {
    local FORCE=0
    [ "${1:-}" = "--force" ] && FORCE=1
    say "从节点备份恢复 mon store → 各节点 /var/lib/rook/mon-* ${FORCE:+[--force 清残留]} ..."
    # 找备份时间戳目录(current 优先, 兜底历史最新)
    _TS_DIR=""
    if SSH "test -d ${BACKUP_DIR}/current" 2>/dev/null; then _TS_DIR="${BACKUP_DIR}/current"; fi
    if [ -z "${_TS_DIR}" ]; then
        _TS_DIR="$( (SSH "ls -1d ${BACKUP_DIR}/[0-9]*_* 2>/dev/null | sort | tail -1" || true) )"
    fi
    [ -n "${_TS_DIR}" ] || { err "节点备份目录不存在(${FIRST_MASTER}:${BACKUP_DIR}), 无法恢复 mon store"; return 1; }
    # 遍历全部节点, 找到对应 hostname 的 monstore tar 并解包
    _RESTORED=0
    for _line in "${NODES[@]:-}"; do
        [ -z "${_line}" ] && continue
        node_parse "${_line}"
        [ -n "${NODE_IP}" ] || continue
        _TAR="${_TS_DIR}/monstore-${NODE_HOSTNAME}.tar.gz"
        if ! SSH "test -s ${_TAR}" 2>/dev/null; then
            # 无该节点 tar: 可能是 mon failover 后该节点已无 mon, 或本轮 save 未打包 ——
            # **不 fallback 到历史 tar**(mon 布局可能已变, 旧 store 会误导恢复), 跳过即可。
            warn "  ${NODE_HOSTNAME}: current/ 无 monstore-${NODE_HOSTNAME}.tar.gz, 跳过(该节点当前无 mon 或本轮未备份)"
            continue
        fi
        # 幂等/安全判断: 非 force 时, 节点已有 mon-* 目录 → 已恢复或集群在运行, **绝不覆盖**
        #   (否则毁掉运行中集群)。--force(整 ns 重建认领场景)则清残留再恢复。
        if [ "${FORCE}" = "0" ] && SSH "test -d /var/lib/rook/mon-a -o -d /var/lib/rook/mon-b -o -d /var/lib/rook/mon-c" 2>/dev/null; then
            ok "  ${NODE_HOSTNAME}: 已有 mon store(/var/lib/rook/mon-*), 跳过恢复(避免覆盖运行中集群)"
            _RESTORED=1
            continue
        fi
        # ⚠ force 模式下, 节点残留的 mon-*(epoch 可能与备份不一致, 如本次重装的错误 store)
        #   **必须清掉**再解包 —— 否则新 mon 仍用残留 store(epoch 10), OSD(epoch 139)仍卡 boot。
        if [ "${FORCE}" = "1" ]; then
            ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${NODE_USER:-ubuntu}@${NODE_IP}" \
                "sudo rm -rf /var/lib/rook/mon-*" 2>/dev/null || true
            say "  ${NODE_HOSTNAME}: 已清残留 mon-*(--force)"
        fi
        # 拉回本地 → 分发到节点解包到 /var/lib/rook/(保留 mon-* 目录名)
        scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q \
            "${SSH_USER:-ubuntu}@${FIRST_MASTER}:${_TAR}" "/tmp/monstore-${NODE_HOSTNAME}.tar.gz" \
            || { warn "  ${NODE_HOSTNAME}: 拉取 mon store 备份失败"; continue; }
        # 先清旧 mon-*(避免新旧混用), 再解包到 /var/lib/rook
        if ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${NODE_USER:-ubuntu}@${NODE_IP}" \
            "sudo bash -c 'rm -rf /var/lib/rook/mon-* && mkdir -p /var/lib/rook && cd /var/lib/rook && tar xzf -'" < "/tmp/monstore-${NODE_HOSTNAME}.tar.gz" \
            && ok "  ${NODE_HOSTNAME}: mon store 已恢复(/var/lib/rook/mon-*)"; then
            _RESTORED=1
        else
            warn "  ${NODE_HOSTNAME}: mon store 解包失败"
        fi
        rm -f "/tmp/monstore-${NODE_HOSTNAME}.tar.gz"
    done
    [ "${_RESTORED}" = "1" ] && ok "mon store 恢复完成(新 mon 将以旧 osdmap epoch 启动, OSD 可正常 boot)" \
        || warn "  未恢复任何 mon store(备份缺失或全部失败) → 认领恢复仍会卡 OSD boot"
    return 0
}

# ---- fetch-fsid: 从第一个 master 备份目录读最新 fsid(恢复用; 只输出 fsid 到 stdout, 供命令替换) ----
# 读取顺序: ① latest.yaml(部署/定时刷新写入) ② current/cephcluster-backup.yaml
#           ③ 历史时间戳目录中最新的 cephcluster-backup.yaml(latest 被清盘重装覆盖后兜底)
cmd_fetch_fsid() {
    local fsid src=""
    # ① ② 最新/current
    for _p in "latest.yaml" "current/cephcluster-backup.yaml"; do
        src="$( (SSH "cat ${BACKUP_DIR}/${_p} 2>/dev/null" || true) )"
        [ -n "${src}" ] && break
    done
    # ③ 历史时间戳目录(按名字排序取最新一份)
    if [ -z "${src}" ]; then
        _ts="$( (SSH "ls -1d ${BACKUP_DIR}/[0-9]*_* 2>/dev/null | sort | tail -1" || true) )"
        [ -n "${_ts}" ] && src="$( (SSH "cat ${_ts}/cephcluster-backup.yaml 2>/dev/null" || true) )"
    fi
    fsid="$(printf '%s\n' "${src}" | awk '/^status:/{f=1} f&&/fsid:/{print $2; exit}')"
    if [ -n "${fsid}" ]; then
        say "从节点备份读取到旧 fsid: ${fsid}" >&2
        printf '%s\n' "${fsid}"
    else
        warn "节点备份目录无可用备份(${FIRST_MASTER}:${BACKUP_DIR})" >&2
        return 1
    fi
    unset _p _ts
}

# ---- install-cron: 在第一个 master 安装 systemd timer, 定期刷新 current/ ----
# 说明: 节点可能无 crontab(基础镜像裁剪), 统一用 systemd timer(每小时, 随机延迟避免整点齐刷)。
cmd_install_cron() {
    say "安装 systemd timer 定期刷新 Ceph 备份(每小时, master=${FIRST_MASTER})..."
    # 先写入 master 端刷新脚本
    cat <<EOF > /tmp/ceph-backup-refresh.sh
#!/bin/bash
# ceph-backup 定期刷新(由 ceph-backup.sh install-cron 安装的 systemd timer 调用)
BACKUP_DIR="${BACKUP_DIR}"
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"
[ -d "\${BACKUP_DIR}/current" ] || sudo mkdir -p "\${BACKUP_DIR}/current"
TS="\$(date +%Y%m%d_%H%M%S)"
# 集群可达才刷新(崩溃时保留旧备份)
if \${K} -n rook-ceph get cephcluster rook-ceph -o yaml > "\${BACKUP_DIR}/\${TS}.yaml" 2>/dev/null && [ -s "\${BACKUP_DIR}/\${TS}.yaml" ]; then
    sudo mkdir -p "\${BACKUP_DIR}/\${TS}"
    sudo mv "\${BACKUP_DIR}/\${TS}.yaml" "\${BACKUP_DIR}/\${TS}/cephcluster-backup.yaml"
    sudo cp "\${BACKUP_DIR}/\${TS}/cephcluster-backup.yaml" "\${BACKUP_DIR}/current/cephcluster-backup.yaml"
    sudo cp "\${BACKUP_DIR}/\${TS}/cephcluster-backup.yaml" "\${BACKUP_DIR}/latest.yaml"
    printf 'backup_time: %s\nfsid: %s\n' "\${TS}" "\$(awk '/^status:/{f=1} f&&/fsid:/{print \$2; exit}' "\${BACKUP_DIR}/\${TS}/cephcluster-backup.yaml")" | sudo tee "\${BACKUP_DIR}/\${TS}/meta.txt" >/dev/null
    # 轮转
    ls -1d "\${BACKUP_DIR}"/[0-9]*_* 2>/dev/null | sort -r | tail -n +$((RETENTION+1)) | xargs -r sudo rm -rf
fi
EOF
    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q \
        /tmp/ceph-backup-refresh.sh "${SSH_USER:-ubuntu}@${FIRST_MASTER}:/tmp/ceph-backup-refresh.sh"
    SSH "sudo mkdir -p ${BACKUP_DIR}/scripts && sudo cp /tmp/ceph-backup-refresh.sh ${BACKUP_DIR}/scripts/refresh.sh && sudo chmod +x ${BACKUP_DIR}/scripts/refresh.sh && \
         sudo tee /etc/systemd/system/ceph-backup-refresh.service >/dev/null <<'EOS'
[Unit]
Description=Ceph backup refresh
After=network.target
[Service]
Type=oneshot
ExecStart=${BACKUP_DIR}/scripts/refresh.sh
EOS
         sudo tee /etc/systemd/system/ceph-backup-refresh.timer >/dev/null <<'EOS'
[Unit]
Description=Hourly Ceph backup refresh
[Timer]
OnCalendar=hourly
RandomizedDelaySec=300
Persistent=true
[Install]
WantedBy=timers.target
EOS
         sudo systemctl daemon-reload && sudo systemctl enable --now ceph-backup-refresh.timer && \
         systemctl list-timers ceph-backup-refresh.timer --no-pager | head -2"
    rm -f /tmp/ceph-backup-refresh.sh
    ok "systemd timer 已安装(master=${FIRST_MASTER}, 每小时刷新 ${BACKUP_DIR}/current/, 防整点齐刷延迟 5min)"
}

# ---- run-cron: master 端手动执行一次刷新(调试/手动触发) ----
cmd_run_cron() {
    [ -f "${BACKUP_DIR}/scripts/refresh.sh" ] || { err "master 端刷新脚本不存在(先 install-cron)"; exit 1; }
    SSH "sudo bash ${BACKUP_DIR}/scripts/refresh.sh && ls -l ${BACKUP_DIR}/current/ | tail -3"
}

# ---------------- main ----------------
case "${1:-}" in
    save)          cmd_save "${2:-}" "${3:-}" ;;
    fetch-fsid)    cmd_fetch_fsid ;;
    restore-secret) cmd_restore_secret ;;
    restore-monstore) cmd_restore_monstore ;;
    install-cron)  cmd_install_cron ;;
    run-cron)      cmd_run_cron ;;
    *) echo "用法: $0 {save <cr.yaml> [meta.txt] | fetch-fsid | restore-secret | restore-monstore | install-cron | run-cron}"; exit 1 ;;
esac
