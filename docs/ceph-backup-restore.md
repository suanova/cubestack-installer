# Ceph 备份与恢复方案(2026-09-07 实测验证)

> 适用:Rook-Ceph 集群的**数据保护**与**整 ns 重建后的认领恢复**。
> 本文档基于 2026-09-04 ~ 09-07 的实测验证(含事故复盘)沉淀,命令均在当前环境跑通。
> ⚠ **2026-09-07 拆分**:备份/恢复已从部署流程(02_ceph.sh / deploy-cluster.sh 预检)移出,
> 改为**独立模块 `ceph_backup` 单独执行**(`--steps ceph_backup`)。部署脚本只保留
> 覆盖安装(`CEPH_PRE_CLEANUP_EXISTING=true` 清盘)与清理旧集群(ceph-cleanup.sh),不再自动备份/恢复。

## 1. 备份什么(三件套,缺一不可)

| 备份项 | 内容 | 为什么必需 | 工具 |
|---|---|---|---|
| **CephCluster CR** | CR yaml(含 status.fsid) | 恢复时了解原集群拓扑/fsid | `ceph-backup.sh save` |
| **rook-ceph-mon secret** | fsid + mon-secret + ceph-secret | Rook v1.20 CRD **无 spec.fsid 字段**,认领旧 OSD 数据唯一途径 = 复用该 secret | `ceph-backup.sh save` |
| **mon store** | 各节点 `/var/lib/rook/mon-*`(store.db,内含 osdmap/PG map) | OSD 本地 bluestore 缓存的 osdmap epoch 远高于新 mon 重建后的 epoch,mon 拒绝处理 OSD 的 osd_boot → **缺它 OSD 永远无法 boot** | `ceph-backup.sh save` |

> ⚠ **只备份 CR + secret 不够**(此前缺失 mon store 导致的完整事故链,见 §4)。
> mon store 里保存了 osdmap/PG map,恢复后新 mon 以旧 epoch 启动,OSD 才能正常 boot。

## 2. 备份命令(部署机执行, 独立模块)

```bash
# 一键备份: 拉取 CR + secret + mon store 全部存入第一个 master 根盘
#    /var/lib/ceph/backup/current/(防 wipe, 时间戳轮转保留 CEPH_BACKUP_RETENTION 份)
sudo ./deployments/scripts/deploy-cluster.sh --steps ceph_backup            # CEPH_BACKUP_ACTION=save 默认
# 等价手工(调试用):
bash deployments/scripts/tools/k8s/ceph-backup.sh save /tmp/cc.yaml
```

**备份产物**(第一个 master `/var/lib/ceph/backup/current/`):

```
cephcluster-backup.yaml            # CR(含 status.fsid)
rook-ceph-mon-secret.yaml          # secret(fsid + keyring)
monstore-<hostname>.tar.gz         # 每节点 mon store(含 osdmap/PG map)
meta.txt                           # backup_time + fsid
```

> ⚠ 部署流程**不再自动备份**(2026-09-07 拆分):集群 HEALTH_OK 后请手动执行一次
> `--steps ceph_backup` 入库新 fsid。可选 `CEPH_BACKUP_ACTION=install-cron` 每小时刷新。

## 3. 恢复命令(整 ns 重建场景, 独立模块)

> 适用:rook-ceph namespace 被删/丢失(模拟完全重建),OSD 磁盘数据完好。
> **不清盘、不 wipe**,走认领恢复。

```bash
# ① 独立模块恢复 secret + mon store(从节点根盘备份)
sudo CEPH_BACKUP_ACTION=restore ./deployments/scripts/deploy-cluster.sh --steps ceph_backup

# ② 保留数据模式重跑 ceph 模块(Rook 凭 secret 认领旧 OSD 数据)
CEPH_PRE_CLEANUP_EXISTING=false CEPH_CONFIRM_SLEEP=0 \
  ./deployments/scripts/deploy-cluster.sh --steps ceph
```

ceph_backup 模块 restore 动作执行:

1. **restore-secret** → namespace 重建 rook-ceph-mon secret(fsid 与旧集群一致)
2. **restore-monstore --force** → 恢复各节点 `/var/lib/rook/mon-*`(新 mon 以旧 osdmap epoch 启动)

随后 02_ceph.sh(PRE_CLEANUP=false)生成 CephCluster CR → Rook 凭 secret 认领旧 OSD 数据
→ 15 OSD boot up(7b 只清不一致残留, 不干扰已恢复的 store)。

**手工等价命令**(调试用):

```bash
bash deployments/scripts/tools/k8s/ceph-backup.sh restore-secret
bash deployments/scripts/tools/k8s/ceph-backup.sh restore-monstore
```

> 幂等安全:restore-monstore 检测到节点已有 mon-* 即跳过,**绝不覆盖运行中集群**。

## 4. 事故复盘(为什么必须有 mon store)

2026-09-07 实测:整 ns 重建后仅恢复 secret,OSD 认领成功(15/15 in,bluestore 数据完好)
但**全部卡在 start_boot,mon 端 osd_boot 卡 3000+ 秒**:

```
OSD 从 bluestore 恢复出旧集群 osdmap(epoch=174)
新 mon 重建后 osdmap 只有 epoch=20
OSD 以为自己是最新(174 > 20), 不向 mon 请求新 map
mon 处理 osd_boot 时发现 OSD map 比自己的新 → 拒绝/等待 → 死锁
OSD 永远 down, 数据在盘上但集群不可用
```

**结论**:mon store(含 osdmap/PG map)是认领恢复的最后一块拼图。
只恢复 secret 能认领磁盘,但 OSD 无法 boot;恢复 mon store 后 osdmap epoch 一致,链路完整。

## 5. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `osd_boot(osd.X ... v174)` slow ops 卡死 | 缺 mon store,osdmap epoch 不匹配 | restore-monstore 后重跑 ceph 模块 |
| mon pod CrashLoopBackOff `AuthMonitor.cc: assert(ret==0)` | mon store 损坏/被误覆盖 | 删该节点损坏的 mon-* 目录,重启 pod,Rook 自动 failover 重建新 mon |
| mon quorum 少一个 | mon failover 中 | 等 Rook 自动重建(mon-a/b 健康时可安全 failover) |
| `RECENT_CRASH` HEALTH_WARN | mon 崩溃记录残留 | `ceph crash archive-all` 清除 |

## 6. 覆盖安装(默认路径,保留在部署脚本内)

- `CEPH_PRE_CLEANUP_EXISTING=true`(默认)= **清盘覆盖**:完整 wipe 旧 OSD 盘 + 清 mon-*/rook-ceph → 全新 fsid
- 与认领恢复(§3)互斥:`true`=覆盖 / `false`=保留数据(配合 §3 认领),两路径互不干扰
- 断点续跑保护:ceph 状态 done 时不执行覆盖(见 deploy-cluster.sh 预检)
- 清理旧集群工具:`tools/k8s/ceph-cleanup.sh --delete-cluster`(幂等卸载, 02_ceph.sh 覆盖安装路径自动调用)

## 7. 验证清单(恢复后)

```bash
# ① 集群健康
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s
#   health: HEALTH_OK, osd: 15 up/15 in, mon: 3 quorum

# ② fsid 与备份一致(证明认领而非新建)
kubectl -n rook-ceph get secret rook-ceph-mon -o jsonpath="{.data.fsid}" | base64 -d

# ③ 数据可读写(rbd 池)
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  bash -c "rbd --pool rbd-pool create v-img --size 10M && rbd --pool rbd-pool rm v-img"

# ④ 池列表完整
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd pool ls
```
