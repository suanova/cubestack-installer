# Rook-Ceph 存储供给层资源(CubeStack 适配)

本目录存放 **ceph_csi 模块(03_addon/03_ceph_csi.sh)apply 的存储供给层 YAML**(§7 资源设计),
与 `docs/ceph-rook.md` / `docs/ceph-backup-restore.md` 对齐。文件由 03 模块读取后
经 `sed` 替换 `__NAMESPACE__ / __REPLICAS__ / __MIN_SIZE__` 模板变量再 apply。

```
deployments/cubestack-addon/rook/
├── rbd/        # CephBlockPool rbd-pool + RBD StorageClass 三变体(§7.1/§7.4-7.6)
│   ├── 01-cephblockpool-rbd-pool.yaml
│   └── 02-storageclass-rbd.yaml      # ceph-rbd-ephemeral / -immediate / -durable
├── cephfs/     # CephFilesystem cephfs + CephFS StorageClass 两变体 + subvolume groups(§7.2/§7.7-7.8/§9)
│   ├── 01-cephfilesystem.yaml
│   ├── 02-storageclass-cephfs.yaml   # cephfs-ephemeral / cephfs-durable
│   └── 03-subvolumegroups.yaml       # ephemeral / durable group(§9.1)
└── rgw/        # CephObjectStore s3-store / RGW + Model 仓库用户与桶策略(§7.3/§10)
    ├── 01-cephobjectstore-s3-store.yaml
    ├── 02-cephobjectstoreuser-model.yaml  # rgw-model-admin / rgw-model-reader(§10.4)
    └── reader-policy.json                 # 桶只读策略模板(§10.3)
```

## 用途对照(§7)

| 文件 | 资源 | 用途(§) |
|---|---|---|
| `rbd/01-*` | CephBlockPool `rbd-pool` | 块存储 pool(3 副本/host 故障域/min_size 2)§7.1 |
| `rbd/02-*` | `ceph-rbd-ephemeral`(WFFC/Delete, 默认) | VM 盘/Golden Image 默认块 SC §7.4 |
| `rbd/02-*` | `ceph-rbd-ephemeral-immediate`(Immediate/Delete) | 先建卷后挂载(CDI 预创建)§7.5 |
| `rbd/02-*` | `ceph-rbd-durable`(WFFC/Retain) | 长期保留块数据(TSDB/Harbor DB)§7.6 |
| `cephfs/01-*` | CephFilesystem `cephfs` | 共享文件系统(MDS 双活跃 + 防误删)§7.2 |
| `cephfs/02-*` | `cephfs-ephemeral`(Delete/Immediate) | 工作区动态 CephFS PVC §7.7 |
| `cephfs/02-*` | `cephfs-durable`(Retain/Immediate) | 平台共享资产 §7.8 |
| `rgw/01-*` | CephObjectStore `s3-store` | 对象存储/Model 仓库(preservePoolsOnDelete)§7.3 |
| `cephfs/03-*` | CephFilesystemSubVolumeGroup `ephemeral`/`durable` | 工作区/平台共享生命周期划分(§9.1) |
| `rgw/02-*` | CephObjectStoreUser `rgw-model-admin`/`rgw-model-reader` | Model 仓库两个全局角色(§10.4) |
| `rgw/reader-policy.json` | 桶只读策略模板 | per-model 桶授权给 reader(§10.3) |

> 手工 apply 亦可(`kubectl apply -f <file>`, 先替换 `__NAMESPACE__` 等为实际值),
> 正常部署走 03_ceph_csi.sh 自动完成。

> PVC/DataVolume 模板见 `rbd/pvc-templates/`(Golden Image / VM Disk / Prometheus TSDB / Harbor DB, §8)。
