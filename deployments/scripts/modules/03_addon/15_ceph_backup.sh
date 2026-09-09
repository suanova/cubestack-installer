#!/bin/bash
# ============================================================
# MODULE: ceph_backup
# DESC: Ceph 备份/恢复独立运维模块(不随部署执行, --steps 单独调用):
#       save    → CephCluster CR + rook-ceph-mon secret + 各节点 mon store 备份到 master
#                 根盘 /var/lib/ceph/backup/(时间戳轮转, 防 wipe/防覆盖/防部署机丢失)
#       restore → 整 ns 重建后从节点根盘备份恢复 rook-ceph-mon secret + mon store
#                 (Rook 凭 secret 的 fsid 认领旧 OSD 数据; 恢复后以 PRE_CLEANUP=false 重跑 ceph)
#       fetch-fsid / install-cron / run-cron → 透传 ceph-backup.sh 子命令
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# 说明:
#   · ⚠ 不随部署执行(备份/恢复是运维动作, 需单独 --steps); REPEAT:1 每次执行不写部署状态。
#   · 2026-09-07 拆分: 备份/恢复逻辑从 02_ceph.sh 与 deploy-cluster.sh 预检中移出,
#     部署流程不再自动备份、不再自动恢复 —— 降低部署复杂度;
#     部署脚本只保留: 覆盖安装(CEPH_PRE_CLEANUP_EXISTING=true 清盘)+ 清理旧集群(ceph-cleanup.sh)。
#   · 备份时机建议: 集群 HEALTH_OK 后执行一次 save(新 fsid 入库);
#     重装前若需认领旧数据: 先 restore(恢复 secret+mon store), 再以
#     CEPH_PRE_CLEANUP_EXISTING=false 重跑 --steps ceph,ceph_csi。
#   · 实现: 复用 tools/k8s/ceph-backup.sh(备份信息持久化到节点根盘 + 时间戳轮转 + 可选 cron)。
#   · 参考: docs/ceph-backup-restore.md
# 数据源: cluster.conf (CEPH_BACKUP_ACTION / CEPH_BACKUP_DIR / CEPH_BACKUP_RETENTION / NODES)
# 用法:   sudo ./deploy-cluster.sh --steps ceph_backup                            # 默认 save
#         CEPH_BACKUP_ACTION=restore sudo ./deploy-cluster.sh --steps ceph_backup # 恢复(认领旧 OSD 数据)
#         CEPH_BACKUP_ACTION=install-cron sudo ./deploy-cluster.sh --steps ceph_backup
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

init_remote_kubectl || exit 1

CEPH_NAMESPACE="${CEPH_NAMESPACE:-rook-ceph}"
BACKUP_TOOL="${SCRIPT_DIR}/tools/k8s/ceph-backup.sh"
ACTION="${CEPH_BACKUP_ACTION:-save}"

case "${ACTION}" in
    save)
        say "==== Ceph 备份(save): CR + secret + mon store → ${FIRST_MASTER} 根盘 /var/lib/ceph/backup/ ===="
        _CR_DUMP="$(mktemp)"
        if ( SSH "${K} -n ${CEPH_NAMESPACE} get cephcluster rook-ceph -o yaml" > "${_CR_DUMP}" 2>/dev/null || true ) && [ -s "${_CR_DUMP}" ]; then
            _META="$(mktemp)"
            printf 'backup_time: %s\n' "$(date +%Y%m%d_%H%M%S)" > "${_META}"
            printf 'nodes:\n' >> "${_META}"
            for _line in "${NODES[@]:-}"; do
                [ -z "${_line}" ] && continue
                node_parse "${_line}"
                printf '  %s: %s\n' "${NODE_HOSTNAME}" "${NODE_IP}" >> "${_META}"
            done
            bash "${BACKUP_TOOL}" save "${_CR_DUMP}" "${_META}" \
                || { err "备份失败(手工: ${BACKUP_TOOL} save <cr.yaml> [meta.txt])"; rm -f "${_CR_DUMP}" "${_META}"; exit 1; }
            rm -f "${_META}"
        else
            err "拉取 CephCluster CR 失败(集群未就绪? kubectl -n ${CEPH_NAMESPACE} get cephcluster)"
            rm -f "${_CR_DUMP}"
            exit 1
        fi
        rm -f "${_CR_DUMP}"
        ok "Ceph 备份完成(节点根盘, 时间戳轮转)"
        echo "  重装前如需认领旧数据: 先 CEPH_BACKUP_ACTION=restore --steps ceph_backup, 再 PRE_CLEANUP_EXISTING=false 重跑 ceph"
        ;;
    restore)
        say "==== Ceph 恢复(restore): secret + mon store ← 节点根盘备份 ===="
        say "  [1/2] 恢复 rook-ceph-mon secret(认领旧 OSD 数据的凭据)..."
        bash "${BACKUP_TOOL}" restore-secret \
            || { err "secret 恢复失败(节点备份目录为空? 需先在有集群时执行 save)"; exit 1; }
        say "  [2/2] 恢复各节点 mon store(--force: 清残留后按备份布局解包, 使新 mon osdmap epoch 与 OSD 缓存一致)..."
        bash "${BACKUP_TOOL}" restore-monstore --force \
            || { err "mon store 恢复失败(可重试; 详见 docs/ceph-backup-restore.md)"; exit 1; }
        ok "恢复完成 —— 现在以 CEPH_PRE_CLEANUP_EXISTING=false 重跑 ceph 模块认领旧 OSD 数据:"
        echo "    sudo CEPH_PRE_CLEANUP_EXISTING=false ./deployments/scripts/deploy-cluster.sh --steps ceph,ceph_csi"
        ;;
    fetch-fsid|install-cron|run-cron)
        say "==== ceph-backup ${ACTION}(透传) ===="
        bash "${BACKUP_TOOL}" "${ACTION}"
        ;;
    *)
        err "CEPH_BACKUP_ACTION 未知: ${ACTION}(可用 save | restore | fetch-fsid | install-cron | run-cron)"
        exit 1
        ;;
esac
