# Rook-Ceph 离线部署设计(docs/ceph-rook.md)

> 在 Kubernetes 上以 **Rook Operator + Ceph** 提供企业级分布式存储(块 RBD / 文件 CephFS / 对象 RGW)。
> 硬性要求: 存储能承受单节点故障 → `size=3 + failureDomain=host + min_size=2`。
> 本仓库自动化入口: `modules/03_addon/02_ceph.sh`(集群)+ `03_ceph_csi.sh`(CSI 供给层)。

## 0. 组件版本(与参考设计一致)

| 组件 | 版本 | 说明 |
|---|---|---|
| Rook | **v1.20.2** | operator manifest(离线 vendoring: `deployments/cubestack-addon/rook/`) |
| Ceph | **v20.2.2** | `quay.io/ceph/ceph:v20.2.2`(mon/mgr/osd/工具) |
| ceph-csi-operator | **v1.0.4** | rook v1.20 **必须**(csi-operator.yaml), 跳过会静默破坏 CSI Provision |
| cephcsi | **v3.17.0** | CSI RBD/CephFS 驱动 |
| 时间同步 | chrony | Ceph 对时钟亚秒级敏感(仓库 NTP 模块已统一, 生产存储节点建议 chrony) |

## 1. 核心设计决策

| 项 | 值 | 原因 |
|---|---|---|
| 副本模型 | replicated **size=3, min_size=2** | 1 台主机故障池仍可写 |
| failureDomain | **host** | 每主机一份副本, 真正跨主机冗余(≥3 台存储节点) |
| mon | **3**(allowMultiplePerNode=false) | 3 台主机真实法定人数(奇数) |
| 存储节点选择 | `CEPH_NODES` + node label(`CEPH_NODE_LABEL`, 默认 `ceph-storage=rook-ceph`) | 只调度到指定的存储节点(需求: node label 选择部署节点) |
| 裸盘 | **自动检测**未使用裸盘(`tools/k8s/ceph-detect-disks.sh`) | 整盘无分区/格式化/挂载/LVM 且非系统盘; 生成 per-node devices(精确盘名, 不用正则, 防误选) |
| 安全确认 | 部署前红底列出"节点+裸盘", **sleep 60s**(`CEPH_CONFIRM_SLEEP`) | 防覆盖系统盘/在用盘(CI 可 `CEPH_CONFIRM_SLEEP=0`); **k8s 部署阶段**(`k8s_deploy`)也预检一次 |
| 镜像 | 离线 tar → `ctr -n k8s.io import --no-unpack` | 保持原始 ref, 无需改 manifest; 多架构需 `--platform linux/amd64` 单架构拉取 |
| lvm2 | 离线 `.deb`(`offline-files/kubespray/packages`) | 重启后 Rook OSD 逻辑卷需 lvm 激活; **k8s 部署阶段由 install-packages.yml 自动安装**(见 §2) |
| registry 后端 | `REGISTRY_STORAGE_CLASS=ceph-block` | registry PVC 走 ceph RBD, **替代 local-path**(ceph 模块排在 registry 之前; 可 `LOCAL_PATH_ENABLED=false` 彻底不装 local-path) |

## 2. 前置离线物料(联网机准备, 部署机离线)

| 物料 | 工具 | 落到 |
|---|---|---|
| Rook manifests(crds/common/csi-operator/operator/toolbox) | `tools/k8s/rook-fetch-manifests.sh`(ROOK_VERSION=v1.20.2) | `deployments/cubestack-addon/rook/` |
| Ceph 镜像 tar(13 个) | `tools/images/ceph-save-images.sh` | `deployments/offline-files/kubespray/images/`(与 kubespray 镜像同目录, 不再用独立 offline-files/ceph) |
| lvm2 + 依赖 `.deb` | `tools/offline/fetch-lvm-packages.sh` | `deployments/offline-files/kubespray/packages/`(✅ 已就绪: 11 个 lvm 家族 .deb) |
| VM 数据盘 | `vm-nodes.conf` 的 `VM_DATA_DISKS=3`/`VM_DATA_DISK_SIZE=200` | 每台 VM 附加 3×200GB 裸盘(Guest: `/dev/vdb~vdX`) |

```
# 联网机一次性:
sudo ./deployments/scripts/tools/k8s/rook-fetch-manifests.sh
sudo ./deployments/scripts/tools/images/ceph-save-images.sh      # 默认输出仓库内 offline-files/kubespray/images(与 k8s 镜像同目录); 独立拷到联网机任意目录也可运行
sudo ./deployments/scripts/tools/offline/fetch-lvm-packages.sh   # ⚠ 必须先于 ceph 部署: 生成 lvm2 全家桶 .deb
```

> **lvm2 离线包(fetch-lvm-packages.sh)**: 用 `apt-get download` 显式拉取 lvm2 + 依赖
> (dmsetup/dmeventd/thin-provisioning-tools/libdevmapper*/liblvm2cmd2.03/libaio1/libudev1/libreadline8/libedit2,
> 共 11 个)——不用 `--download-only`(本机已装 lvm2 会 0 upgraded 什么都不下载)。
> 每次重跑幂等(已存在跳过)。
> **lvm 部署前预检(02_ceph 模块)**: 部署 ceph 集群前硬校验"packages/ 含 lvm2_*.deb **或** 存储节点已在线装 lvm",
> 均不满足 → 红底硬失败并指引先跑 fetch-lvm-packages.sh —— 杜绝"OSD 因缺 lvm 无法激活"的隐性失败;
> 部署中按节点检测 lvm2, 缺失时从 packages/ 自动 dpkg -i。

## 3. 启用与部署顺序

cluster.conf:
```bash
CEPH_ENABLED=true
CEPH_CSI_ENABLED=true
# CEPH_NODES= "cubestack-k8s-master01,cubestack-k8s-worker01,cubestack-k8s-worker02"  # 空=全部节点(≥3 奇数更佳)
# REGISTRY_STORAGE_CLASS=ceph-block        # registry 后端走 ceph(替代 local-path)
# LOCAL_PATH_ENABLED=false                 # 建议: registry 走 ceph 后彻底不装 local-path
```

部署(03_addon 内按文件序号执行, ceph 在 k8s_registry **之前**; 全量默认 `--with-cubestack --skip-net`):
```bash
sudo ./deployments/scripts/deploy-cluster.sh          # 默认全量(含 ceph/ceph_csi 若已启用)
# 或只部署 ceph 相关:
sudo ./deployments/scripts/deploy-cluster.sh --steps ceph,ceph_csi
```

`02_ceph.sh` 流程: ① 确定存储节点(CEPH_NODES/全部) ② 逐节点自动检测裸盘
③ **红底确认 + sleep CEPH_CONFIRM_SLEEP(60s)** double-check 节点与盘名
④ 节点准备(modprobe rbd 持久化 + lvm2 离线安装 + 打 label `ceph-storage=rook-ceph`)
⑤ `ceph-sync-images.sh` 同步镜像到存储节点并 `ctr import`
⑥ apply rook crds/common/csi-operator/operator, 等 operator Ready
⑦ 生成 CephCluster CR(mon=3, storage.nodes[].devices=检测盘, placement 按 label)并 apply,
   等 `cephcluster phase=Ready` + `ceph -s HEALTH_OK`(最长 600s)⑧ 调优 osd_memory_target。

`03_ceph_csi.sh`: ① 等 ceph-csi 控制器/插件就绪 ② 建 CephBlockPool `rbd-pool` + StorageClass
`ceph-block`(WaitForFirstConsumer) ③ 可选 CephFilesystem+`cephfs`(CEPHFS_ENABLED) ④ 可选 RGW(CEPH_RGW_ENABLED)。

> ⚠ registry 用 ceph: kubespray 的 registry addon 在 k8s 阶段已创建 PVC(指定 storageClass)。
> 设 `REGISTRY_STORAGE_CLASS=ceph-block` 后 PVC 会等待 `ceph-block` SC 出现自动绑定;
> 若 registry 已用 local-path 建好 PVC, 删除旧 PVC(registry 重建)即可切到 ceph。

> ⏱ **顺序与等待**: addon 阶段按文件序号执行 `metallb → ceph → ceph_csi → local_path → registry`,
> 满足"ceph cluster → ceph-csi operator → registry"的依赖链:
> - `02_ceph` 等 `cephcluster phase=Ready` + `ceph -s HEALTH_OK`(最长 600s);
> - `03_ceph_csi` 等 ceph-csi 控制器/插件就绪(最长 240s), 然后创建 `CephBlockPool rbd-pool` + `StorageClass ceph-block`;
> - `05_k8s_registry` 配置完成后**额外等待** `registry-pvc Bound + pod Ready + /v2/ 可达`
>   (默认 `REGISTRY_WAIT_SECONDS=600`, 覆盖首次 RBD 卷创建 + 镜像下载);
>   任一层未就绪即硬失败并给出排查指引 —— 避免后续 push 镜像的模块(gpu_operator/envoy/...)
>   ImagePullBackOff 且难以定位。
>
> 就绪判定链完整覆盖 ceph 集群 → csi → registry 三级依赖, 无需人工 sleep:
> 各模块内部已内建轮询等待(见上), `05_k8s_registry` 是链上最后一道门。

## 4. 裸盘自动检测(需求)

`tools/k8s/ceph-detect-disks.sh [--node <hostname|ip>...] [-m]`
判定未使用裸盘: 顶层 disk、无子设备(未分区)、无 FSTYPE(未格式化)、非系统盘
(排除持有 `/`、`/boot*`、swap、LVM 的盘)且不命中 `CEPH_DETECT_EXCLUDE`(默认 `^(sda|sr0|vda)$`)。
输出 `hostname:/dev/vdb,/dev/vdc`, ceph 模块据此生成 CephCluster `storage.nodes[].devices`。

**VM 测试集群**: `vm-nodes.conf` 设 `VM_DATA_DISKS=3 VM_DATA_DISK_SIZE=200`,
重跑 `tools/vm/create-vms.sh`(仅新 VM 生效)后节点内出现 `/dev/vdb~vdX` 裸盘。

## 5. 手动(参考)安装要点 —— Rook v1.20

若不用模块而要手工验证(在线/已有 manifest), 参考官方步骤:
```bash
kubectl create -f rook/deploy/examples/crds.yaml
kubectl create -f rook/deploy/examples/common.yaml
kubectl create -f rook/deploy/examples/csi-operator.yaml    # ⚠ v1.20 必须
kubectl create -f rook/deploy/examples/operator.yaml
# 等 operator + ceph-csi-controller Running → 创建 CephCluster(mon=3/size=3)…
```
CephCluster 关键字段(与模块生成一致):
```yaml
spec:
  cephVersion: {image: "quay.io/ceph/ceph:v20.2.2"}
  mon: {count: 3, allowMultiplePerNode: false}
  storage: {useAllNodes: false, nodes: [{name: <node>, devices: [{name: "/dev/vdb"}]}]}
```
OSD 内存目标(大盘): `ceph config set osd osd_memory_target 12884901888`(12GiB/7TB 盘; 200G 盘默认 4GiB)。

## 6. 验证(端到端, 对应 verify 思路)

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s      # HEALTH_OK
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree # 每主机 OSD up
kubectl -n rook-ceph get cephcluster,cephblockpool               # Ready
kubectl get sc ceph-block                                        # StorageClass
# 冒烟: 建 PVC(storageClassName: ceph-block, volumeMode: Block)→ dd 读写
```

## 7. 卸载 / 重装(清盘)

```bash
kubectl -n rook-ceph patch cephcluster rook-ceph --type merge -p \
  '{"spec":{"cleanupPolicy":{"confirmation":"yes-really-destroy-data"}}}'
kubectl -n rook-ceph delete cephcluster rook-ceph                # operator 保留, 清理数据
# 各节点: wipefs --all -f /dev/vdX && sgdisk --zap-all /dev/vdX; rm -rf /var/lib/rook
kubectl delete -f deployments/cubestack-addon/rook/operator.yaml  # 完全卸载 operator(可选)
```

## 8. 常见问题速查(详细见 docs/troubleshooting.md)

- OSD 一直 Prepare/CrashLoop: 裸盘残留文件系统签名 → wipefs/sgdisk 清理; 或 lvm2 缺失(重启后逻辑卷无法激活)。
- 镜像 ImagePullBackOff: 未 ctr import 或 import 多架构 tar 报 digest → 用 `--platform linux/amd64` 单架构 + `--no-unpack`;
  或 tar 残缺(如 quay.io/ceph/ceph:v20.2.2 仅 7.6KB 的 index-only 产物)→ 删掉该 tar 重跑 ceph-save-images.sh(已自动校验 <10MB 判残)。
- HEALTH_WARN clock skew: 存储节点时钟 → chrony 对齐(仓库 NTP 模块)。
- registry PVC Pending: 等 `ceph-block` SC 由 03_ceph_csi 创建后自动绑定。
- mon/osd 未调度到目标节点: 检查节点 label `ceph-storage=rook-ceph` 与 CEPH_NODES。

## 9. 关键文件

`deployments/cubestack-addon/rook/`(manifests + CUBESTACK.md)、`02_ceph.sh`、`03_ceph_csi.sh`、
`tools/k8s/ceph-detect-disks.sh`、`tools/images/ceph-save-images.sh`、`tools/images/ceph-sync-images.sh`、
`tools/offline/fetch-lvm-packages.sh`、`tools/k8s/rook-fetch-manifests.sh`、cluster.conf `CEPH_*` 配置段、
`patch-playbooks/install-packages.yml`(lvm2 离线安装, cubestack-offline.sh 自动挂载)。

> 更完整的手工操作手册(池播种/PG 调优/CephFS/RGW/快照/风险)见参考设计文档(按 Rook v1.20.2 官方 + 生产实践编写)。
