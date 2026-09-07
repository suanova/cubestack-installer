# RBD PVC/DataVolume 模板(§8 对齐)

本目录存放 **RBD 卷使用模板**(Golden Image / VM Disk / 可观测性 / Harbor DB),
对应 `docs/ceph-rook.md` §8。需要时手工 `kubectl apply -f <file>`(先按需改 namespace/容量)。

| 文件 | 用途 | SC | 关键属性 |
|---|---|---|---|
| `01-golden-image-datavolume.yaml` | Golden Image 上传(§8.1) | `ceph-rbd-ephemeral-immediate` | RWO/Block/Immediate, 只读 clone 源 |
| `02-vm-disk-datavolume.yaml` | VM 根盘 + 数据盘(§8.2/§8.3) | `ceph-rbd-ephemeral` | RWX/Block/WFFC, 从 Golden Image 克隆 |
| `03-prometheus-tsdb-pvc.yaml` | Prometheus 本地 TSDB(§8.5) | `ceph-rbd-durable` | RWO/Filesystem/Retain, 100Gi |
| `04-harbor-db-pvc.yaml` | Harbor PostgreSQL/Redis(§8.6, 可选) | `ceph-rbd-durable` | RWO/Filesystem/Retain, 50Gi/10Gi |
| `07-image-registry-pvc.yaml` | Image Registry 数据目录(§11.9) | `ceph-rbd-durable` | RWO/Filesystem/Retain, 2Ti(WFFC) |

## 设计要点(§8)

- **Golden Image**(§8.1): RBD Block + RWO + 只读源, 只作 clone 源不直接挂 VM;
  秒级 clone 到各 VM 根盘(写时分配)。
- **VM Disk**(§8.2/§8.3): RBD Block + **RWX**(热迁移前提)+ `ceph-rbd-ephemeral`(Delete,
  数据生命周期随 VM 结束, §8.4)。
- **Prometheus TSDB**(§8.5): 单写者 + WAL/compaction 延迟敏感 → RBD 块 + 本地文件系统
  (Filesystem), 不用 CephFS(共享语义无收益)/ 对象存储(仅远程归档)。
- **Harbor DB**(§8.6, 可选): 与 TSDB 同 SC `ceph-rbd-durable`(Retain 防误删),
  数据量小 ~50Gi 级, RBD 快照即备份。
