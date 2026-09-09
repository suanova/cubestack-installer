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

### 3.1 双模式: 集群内 Rook-Ceph / 外部已有 Ceph(CEPH_MODE)

`CEPH_MODE` 统一开关二选一(默认 internal, 兼容旧配置自动迁移):

| 模式 | CEPH_MODE | 行为 |
|---|---|---|
| **集群内(默认, 现有实现)** | `internal` | 部署 CephCluster CR + 本地 OSD(裸盘检测/确认/15 OSD), registry 走集群内 ceph-block |
| **外部接入** | `external` | **不创建集群内 CephCluster**, 02 仅部署 rook operator/csi-operator; 03 经 ceph-csi-operator 的 `CephConnection` 连外部已有 Ceph, 建指向外部的 `StorageClass ceph-block` |

**external 模式配置**(cluster.conf):
```bash
CEPH_ENABLED=true
CEPH_CSI_ENABLED=true
CEPH_MODE=external
CEPH_MONITORS="10.66.1.21:6789,10.66.1.22:6789"   # 外部 Ceph monitors(必填)
CEPH_POOL="rbd"                                    # 外部 RBD pool(外部集群已有)
CEPH_USER="admin"                                  # 外部认证用户
CEPH_KEYRING="AQCxxx=="                            # 外部认证 keyring(必填)
REGISTRY_STORAGE_CLASS=ceph-block                  # registry 走外部 ceph-block(与 internal 一致)
```

**external 模式下**:
- `02_ceph.sh` 跳过裸盘检测/覆盖确认/CR 生成, 仅部署 operator + csi-operator 并等 operator Ready
- `03_ceph_csi.sh` 创建 `CephConnection` + `rook-csi-rbd-*` secret + `StorageClass ceph-block`
  (pool/认证指向外部), 跳过集群内 pool/cephfs/rgw 创建
- `deploy-cluster.sh` 预检跳过裸盘/倒计时/已有集群清理, 只提示外部连接
- registry 等下游继续用 `ceph-block` SC(无需改动)

**兼容旧配置**: 仅设了旧变量 `CEPH_EXTERNAL_MONITORS`(旧外部开关)会自动视为 `external`,
并把 `CEPH_EXTERNAL_POOL/USER/KEYRING` 迁移到 `CEPH_POOL/USER/KEYRING`(lib-common load_config 归一化)。

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

### 3.3 对外暴露(供集群外 ceph-csi-operator 接入; 默认开启)

**目标**: 允许**其他 K8s 集群**的 ceph-csi-operator 以 `CEPH_MODE=external` 连接本集群的 CephCluster
(mon 端点 + pool + 认证), 实现跨集群共享存储。

**默认行为**(2026-09-07 YAML 化重构 + 完整预定义): 部署 `ceph_csi` 模块时, 若 `CEPH_EXTERNAL_EXPOSE=true`(默认)
自动完成 4 步(预定义 ceph-csi-operator 连接所需的**全部信息**):

1. **网络层**: 从 `cubestack-addon/rook/external/{01-mon,02-rgw}-external.yaml` 模板生成并 `kubectl apply`
   独立 `*-external` Service(selector 指向 mon/RGW pod, **不碰 Rook 自管 ClusterIP svc** ——
   operator 会调和回滚对自管 svc 的修改, 独立 svc 无回滚/时序问题):
   - `rook-ceph-mon-<a|b|c>-external`(port 6789, 按 `rook-ceph-mon-endpoints` CM 实际 mon 列表展开)
   - `rook-ceph-rgw-s3-store-external`(port 80, `CEPH_RGW_ENABLED=true` 且 RGW 模式非 clusterip 时)
   - nodePort **自动分配**(30000-32767; 显式 6789 超出 `service-node-port-range` 会失败),
     apply 后读取实际端口写入导出配置
2. **资源层**(与集群内资源隔离, 对齐外部 csi 需求): 外部专用 RBD pool `cubestack-ext-rbd-pool`
   (32 PG, application=rbd); `CEPHFS_ENABLED=true` 时另建外部 CephFilesystem
   `cubestack-ext-fs`(meta 16 PG + data 32 PG, application=cephfs)
3. **认证层**: 外部专用用户(profile caps, 非 admin):
   - `cubestack-ext-rbd`: `mon 'profile rbd' osd 'profile rbd pool=cubestack-ext-rbd-pool' mgr 'profile rbd pool=…'`
   - `cubestack-ext-cephfs`: `mon 'allow r' mds 'allow rw fsname=cubestack-ext-fs' osd 'allow rw pool=cubestack-ext-cephfs-data'`
4. **导出**: 写 `deployments/config/ceph-external-access.conf` —— 全部连接信息
   (CEPH_MONITORS=真实可达 ip:port / FSID / RBD: USER+KEYRING+POOL / CephFS: USER+KEYRING+FS+两池 / RGW 端点),
   拷贝到目标集群 `cluster.conf` 设 `CEPH_MODE=external` 即可接入

**暴露模式**(大小写不敏感, 均经 `tr` 转小写归一):
- 跟随 `SERVICE_EXPOSE_MODE`(默认): `nodeport` → NodePort Service / `metallb` → LoadBalancer(MetalLB VIP)
- `CEPH_EXTERNAL_EXPOSE_MODE=nodeport|loadbalancer|metallb|clusterip` 显式覆盖全部;
  `clusterip/off` = 不对外暴露(仅集群内可达)
- `CEPH_RGW_EXPOSE_MODE` 仅覆盖 RGW(mon 仍随主模式); `CEPH_RGW_NODEPORT` 固定 RGW NodePort(空=自动)

**配置**(cluster.conf):
```bash
CEPH_EXTERNAL_EXPOSE=true                       # 总开关(默认 true)
CEPH_EXTERNAL_EXPOSE_MODE=""                    # 空=随 SERVICE_EXPOSE_MODE
CEPH_RGW_EXPOSE_MODE=""                         # RGW 独立覆盖(默认随主模式)
```

**手动操作 / 自检(5 层, 含外部客户端协议级测试)**:
```bash
bash deployments/scripts/tools/k8s/ceph-expose-external.sh apply [--mode nodeport|loadbalancer|metallb|clusterip]  # 重新暴露+预定义(幂等)
bash deployments/scripts/tools/k8s/ceph-expose-external.sh show     # 当前暴露状态
bash deployments/scripts/tools/k8s/ceph-expose-external.sh status   # 5 层自检:
#    [1/5] mon 网络可达(集群外 TCP) [2/5] 认证用户(profile caps) [3/5] 外部资源(pool/fs/app tag)
#    [4/5] fsid+CephFS [5/5] 外部客户端协议级测试(模拟 ceph-csi-operator 从集群外连接:
#    mon msgr 握手 + cephx 认证 + rbd ls/create/rm 写路径; 客户端=Dockerfile-cli 预装 ceph-common)
sudo ./deploy-cluster.sh --steps verify_ceph                        # ⑨ 自动跑 status(含 [5/5])
```
> Dockerfile-cli 已预装 `ceph-common`(部署容器内自带 ceph/rbd 客户端); 旧容器未重建时
> [5/5] 自动回退为 toolbox 内经外部端点测试(连接路径经 kube-proxy DNAT, 与外部一致)。

**接入方集群**(目标集群, 消费本集群 Ceph): `cluster.conf` 设 `CEPH_MODE=external` +
`CEPH_MONITORS/CEPH_POOL/CEPH_USER/CEPH_KEYRING/CEPH_FSID`(值来自 `ceph-external-access.conf`),
详见上表"外部接入"行与 §3.1。

---

### 3.4 两集群 A/B 共享 Ceph 完整流程(2026-09-08)

**场景**: 两套独立 K8s 集群, 共享一套 Ceph 存储。集群 A 自建 Rook-Ceph(internal 模式)并对外暴露;
集群 B 只部署 ceph csi operator(external 模式)接入 A 的 Ceph, **不创建 CephCluster/pool/磁盘**。两集群存储供给层使用**同名同类的 6 个 StorageClass**, 应用/平台可无差别使用。

#### 3.4.1 集群 A(存储提供方, internal)

1. 打开 `cluster.conf`, 确认关键项:
   ```bash
   CEPH_MODE="internal"                        # 集群 A = 自建 Ceph
   CEPH_ENABLED=true
   CEPH_CSI_ENABLED=true
   CEPH_EXTERNAL_EXPOSE=true                # 默认开: 部署完自动对外暴露 + 导出配置
   CEPH_RGW_ENABLED=true                    # 可选: 需要 S3 时
   CEPHFS_ENABLED=true                      # 可选: 需要外部 CephFS 时(给 B 提供 cephfs-ephemeral/durable)
   CEPH_MON_NODEPORT_BASE=30100             # 规律 NodePort(默认; ≤ apiserver range)
   # SERVICE_EXPOSE_MODE 决定对外端口: nodeport(默认)→ IP:30100/30101/30102(规律);
   #                                metallb → VIP:6789 等 Ceph 原生端口
   ```
2. 部署:
   ```bash
   sudo ./deploy-cluster.sh --with-cubestack       # 全量; 或 --steps ceph,ceph_csi(只 Ceph 相关)
   ```
   完成后自动:
   - 创建 mon/RGW *-external Service + 外部专用 pool + 用户(§3.3)
   - 导出外部接入配置 **`deployments/config/ceph-external-access.conf`**
   - 安装末尾总结打印配置路径 + 入口行
3. 自检(5 层, 含外部客户端协议级测试, 模拟 B 的 csi 从集群外连接):
   ```bash
   bash deployments/scripts/tools/k8s/ceph-expose-external.sh status
   ```

#### 3.4.2 集群 B(存储消费方, external)

打开 B 的 `cluster.conf`, 把 A 导出的 `ceph-external-access.conf` 关键值拷入下述字段(只改这些):

```bash
CEPH_MODE=external                          # 切到外部接入
CEPH_ENABLED=true                            # 让 02/03 模块运行(02 会 "仅部署 operator/csi-operator")
CEPH_CSI_ENABLED=true
# --- 以下来自集群 A 的 ceph-external-access.conf(按实际值替换) ---
CEPH_MONITORS="10.244.1.31:30100,10.244.1.31:30101,10.244.1.31:30102"   # A 导出的 mon 端点(规律端口)
CEPH_POOL="cubestack-ext-rbd-pool"          # pool 必须与 A 导出一致
CEPH_USER="cubestack-ext-rbd"
CEPH_KEYRING="AQx...=="                      # A 导出的 RBD key
# --- 可选: CEPHFS(外部 A 有 CephFilesystem 时才需要) ---
CEPHFS_FS="cubestack-ext-fs"
CEPHFS_DATA_POOL="cubestack-ext-cephfs-data"
CEPHFS_USER="cubestack-ext-cephfs"
CEPHFS_KEYRING="AQa...=="                    # A 导出的 CephFS key
# --- 不要设置以下内部部署相关(它们只用于集群 A) ---
# CEPH_NODES CEPH_DATA_DISK_POLICY CEPH_MON_COUNT CEPH_LVM...
```

部署(只跑 Ceph 两个模块, REQUIRES 自动带上 operator):
```bash
sudo ./deploy-cluster.sh --steps ceph,ceph_csi
```

`02_ceph`(external): 不建 CephCluster/不碰磁盘, 只部署 rook operator + csi-operator 并等 Ready;
`03_ceph_csi`(external): 创建 `CephConnection ceph-connection`(clusterID=ceph-connection, monitors=CEPH_MONITORS)
+ RBD secret ×2 + CephFS secret ×2(仅 CEPHFS_FS 时)+ **6 个 StorageClass**(clusterID/pool/fsName/secret 指向外部集):

| StorageClass | 类型 | reclaim | binding | clusterID |
|---|---|---|---|---|
| `ceph-block` | RBD | Delete | WFFC | ceph-connection |
| `ceph-rbd-ephemeral`(default) | RBD | Delete | WFFC | ceph-connection |
| `ceph-rbd-ephemeral-immediate` | RBD | Delete | Immediate | ceph-connection |
| `ceph-rbd-durable` | RBD | Retain | WFFC | ceph-connection |
| `cephfs-ephemeral`* | CephFS | Delete | Immediate | ceph-connection |
| `cephfs-durable`* | CephFS | Retain | Immediate | ceph-connection |
> \\* 仅当 `CEPHFS_FS` 非空时生成; 否则 B 只有 4 个 RBD SC。`CEPHFS_FS` 已设但 `CEPHFS_DATA_POOL` 为空 → 模块硬失败并提示缺字段(避免静默缺 SC)。

#### 3.4.3 切换/回退与安全性
- 两集群使用**同一命名空间 `rook-ceph`**(不再引入 `rook-ceph-external`, 简化)。
- B 的 CephFS/RBD secret 与 SC 全部在 `rook-ceph` 下, clusterID=ceph-connection 是唯一指向 A 的标识。
- A 的导出文件 **包含 `CEPH_FSID`**, 但经 `CephConnection` 接入时 csi-operator 从 monitors 自动读 fsid, 无需手动向 B 提供 fsid; 若 B 需要 fsid(如 `ceph fsid` 检测)可直接由 A 提供。
- **共享注意**: 外部 pool 只能同时被一个 ceph-csi-operator 强一致使用, 若两个集群同时写同一 pool 会有镜像/动态卷冲突 —— 设计上一个 Ceph 集群服务一个 Kubernetes 集群的卷; 若需多集群共享, 用 CephFilesystem 而非 RBD, 且注意 MDS 并发访问语义。

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

### 3.2 条件不足自动回退 local-path(CEPH_FALLBACK_TO_LOCALPATH)

`CEPH_ENABLED=true` 但实际不具备 ceph 安装条件时,默认**硬失败并提示**(防掩盖配置错误)。
设 `CEPH_FALLBACK_TO_LOCALPATH=true` 可让部署**自动降级到 local-path 模式**:

- 预检阶段检测条件(internal: rook manifest / 存储节点≥CEPH_MIN_NODES / 显式 CEPH_DATA_DISKS /
  lvm2 离线包; external: CEPH_MONITORS + CEPH_KEYRING)
- 不足 → 自动置 `REGISTRY_STORAGE_CLASS=local-path` + `LOCAL_PATH_ENABLED=true` + 跳过 ceph/ceph_csi
- registry 等下游用 local-path 正常部署, 部署不中断
- 条件备齐后: 设回 `CEPH_ENABLED=true` + `CEPH_FALLBACK_TO_LOCALPATH=false` 重跑即可

> ⚠ 回退在 k8s_deploy **之前**的预检阶段生效, 保证 local-path-provisioner 随 k8s 一起部署;
> 若 k8s_deploy 已跑过(local-path 未装), 回退后需 `--fresh` 或手工补 local-path SC。

## 9. 新设计指引(§9-§21, 存储资源已文件化)

> 完整设计文档(`docs/ceph-workspace.md` 工作区 + `docs/ceph-backup-restore.md` 备份恢复)与
> 资源 YAML(`deployments/cubestack-addon/rook/{rbd,cephfs,rgw}/`)对齐 §9-§21 规划。
> 本文档 §1-§8 保留基础设计, 新能力汇总如下:

### §9 CephFS subvolume groups(ephemeral / durable)
- 资源: `rook/cephfs/03-subvolumegroups.yaml`(由 03_ceph_csi.sh 自动 apply)
- 动态 SC 路由到 group: `tools/k8s/cephfs-group-route.sh apply`(取 group clusterID → patch SC)

### §10 Model 仓库(RGW / S3)
- `rook/rgw/01-cephobjectstore-s3-store.yaml`(preservePoolsOnDelete)+
  `02-cephobjectstoreuser-model.yaml`(rgw-model-admin / rgw-model-reader)
- per-model 桶只读策略: `rook/rgw/reader-policy.json`(建桶/授权 = Model Controller 职责, §10.3)

### §11 工作区 / 平台共享 / 镜像
- DevEnvironment /workspace(RWX): `cephfs/pvc-templates/05-*`
- Agent(RWO 隔离): `cephfs/pvc-templates/06-*`
- Skill Marketplace(RWX, durable): `cephfs/pvc-templates/07-*`
- Image Registry(RBD Filesystem, Retain): `rbd/pvc-templates/07-*`

### 命令清单(§21.1 对应)
```bash
# 03_ceph_csi.sh 已自动创建: rbd-pool / 5×SC / cephfs+subvolumegroups / s3-store+Model用户
# 部署后补做:
sudo ./deployments/scripts/tools/k8s/cephfs-group-route.sh apply   # SC 路由到 ephemeral/durable group
kubectl apply -f <platform>/image-registry-pvc.yaml               # Image Registry(§11.9)
kubectl apply -f <platform>/skill-marketplace-pvc.yaml            # Skill Marketplace(§11.8)
```
