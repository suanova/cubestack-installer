# 网络 / RDMA 诊断 pod(netshoot)

集群里常驻一台"网络工具箱":`kubectl exec` 进去就能用 `tcpdump` / `ip` / `ss` / `ethtool` / `mtr` /
`ping` / `nslookup`;镜像里另装了 **rdma-core**(`ibv_devices` / `ibv_devinfo`)与 **perftest**
(`ib_write_bw` / `ib_read_bw` / `ib_write_lat` …),用于 RDMA(IB/RoCE)链路诊断与带宽/时延实测。

- 模块: `deployments/scripts/modules/03_addon/35_netshoot.sh`(key `netshoot`)
- 镜像物料: `deployments/offline-files/netshoot/`(自建 tar;回退用 `offline-files/os/netshoot.tar`)
- 默认命名空间 `default`,pod 名 `cubestack-netshoot`(固定名,便于 exec)

---

## 1. 为什么要自建镜像

上游 `nicolaka/netshoot`(Alpine)**不含 RDMA 用户态工具**:

- 镜像里没有 libibverbs、没有 `ibv_*`、也没有 `rdma` 二进制(实测它的 `ip` 不带 `rdma` 子命令);
- ⚠ **Alpine 的 iproute2 是拆包的**: 默认只有 `iproute2-minimal`(ip)/`-ss`/`-tc`,
  `/sbin/rdma` 在独立包 **`iproute2-rdma`** 里 —— 不显式装就会遇到
  `rdma: command not found`,容易被误判成"pod 里没有 RDMA"(2026-09-22 实机踩坑);
- Alpine 社区源**没有 perftest 包** → 只能源码编译;
- 离线集群按设计不带软件源 → RDMA 工具**必须构建期装好**(实测某集群 pod 能连 apk 源,
  但离线交付不能依赖这点)。

于是有了 `tools/images/netshoot-rdma.Dockerfile`(两阶段构建)+ `tools/images/netshoot-rdma-build.sh`
(联网机执行)。构建与踩坑见 §4。

## 2. 部署与使用

```bash
# 部署(默认不随全量部署安装; TOGGLE 默认 false)
sudo ./deploy-cluster.sh --steps netshoot          # 或 cluster.conf 设 NETSHOOT_ENABLED=true

# 用法
kubectl -n default exec -it cubestack-netshoot -- bash
ls; cat motd                                             # 入口提示(挂载的 motd: RDMA/网络速查)
kubectl -n default logs cubestack-netshoot                       # 启动时的设备视图
kubectl -n default exec cubestack-netshoot -- sh /diag/diag.sh   # 重跑设备视图
```

容器里常用:

```bash
tcpdump -i any -nn                       # 抓包
ip addr; ip route; ss -tunap             # 地址/路由/连接
ethtool eth0; ethtool -S eth0            # 网卡速率/统计
mtr -rw <host>; ping <host>              # 链路质量
rdma link show; rdma dev                 # RDMA 链路状态(state/physical_state)
ibv_devices; ibv_devinfo                 # RDMA 卡与端口(verbs 视角)
ib_write_bw -d mlx5_0 -a                 # 带宽实测(对端要同步起 ib_write_bw 服务端)
```

删除: `kubectl -n default delete pod cubestack-netshoot configmap cubestack-netshoot-diag`

## 3. RDMA 资源自动降级(为什么 pod 在无卡集群也能起)

模块部署前会查节点 `allocatable` 里有没有 `rdma/hca_shared_devices`(即 `10_rdma` 的 by-link IB 池;
可用 `NETSHOOT_RDMA_RESOURCE` 改):

| 集群状态 | 模块行为 |
|---|---|
| 已注册该资源 | pod 申请 `limits: rdma/hca_shared_devices: 1` → 调度到有卡节点, 容器里能看到 `/dev/infiniband/uverbsN` |
| 未注册(未装 RDMA 插件 / 占位模式 / 无卡) | **不申请**, pod 照常起, 只做通用网络诊断(日志里写明原因) |

> 不降级的后果很直接: 无卡集群里 pod 永远 `Pending` —— "诊断工具"自己先挂了。

## 4. 镜像构建(联网机)

```bash
sudo ./deployments/scripts/tools/images/netshoot-rdma-build.sh            # 构建 + 自检 + 保存 tar
sudo APK_MIRROR=https://mirrors.aliyun.com/alpine \
     ./deployments/scripts/tools/images/netshoot-rdma-build.sh --force    # 慢网络: 换 apk 源
```

脚本流程: 载入基础镜像(优先 `offline-files/os/netshoot.tar`,**不依赖 Docker Hub**)→ 宿主机下载
perftest 源码 → 两阶段构建 → **容器内自检**(缺 `ibv_*`/`ib_write_bw`/`tcpdump` 直接失败, 不产出残缺 tar)
→ `docker save` 到 `offline-files/netshoot/netshoot-rdma-<版本>.tar`。

构建踩过的坑(都已固化进脚本/Dockerfile):

| 现象 | 根因 | 处理 |
|---|---|---|
| `apk add build-base` 像卡死(十几分钟无输出) | 上游 Alpine CDN 实测 ~70 KB/s | `APK_MIRROR=https://mirrors.aliyun.com/alpine`(实测 ~3 MB/s) |
| 容器内 `wget github.com` 报 `Resource temporarily unavailable` | 容器出网受限(宿主机正常) | 源码改由**宿主机下载**后 COPY 进构建上下文 |
| `configure: error: pciutils header files not found` | perftest 要 pciutils 头 | builder 装 `pciutils-dev`,runtime 装 `pciutils-libs` |
| `error: '_SC_LEVEL1_DCACHE_LINESIZE' undeclared` | 该常量是 glibc 扩展, **musl 没有** | Dockerfile 里 `sed` 替换为常量 64(仅用于缓冲区对齐, 不影响测量) |
| 下载 perftest 源码 SSL 断流 | 到 GitHub 的 TLS 间歇性失败 | 脚本 3 次重试; 或 `PERFTEST_TARBALL=<已下好的包>` 直接喂 |

升级 perftest: 改 `cluster.conf` 的 `NETSHOOT_RDMA_VERSION`(= 镜像 tag = perftest 版本)后重建镜像。

> ⚠ **改了镜像内容(加包/打补丁)必须换新 tag** —— 同 tag 重建到不了集群: 模块 35 见 registry
> 已有同名 tag 会**跳过推送**, 且 pod `imagePullPolicy: IfNotPresent` 会命中节点旧缓存。
> 约定 `<perftest 版本>-r<N>`(如 `26.04.17-r2`):
> ```bash
> sudo IMAGE_TAG=26.04.17-r2 ./deployments/scripts/tools/images/netshoot-rdma-build.sh --force
> # 再把 cluster.conf 的 NETSHOOT_RDMA_VERSION 改成 26.04.17-r2, 重跑 --steps netshoot
> ```

## 5. 容器里怎么看 RDMA 设备(设备视图)

`kubectl logs` 输出的视图由 `/diag/diag.sh` 生成(进 pod 后 `cat motd` 是精简版速查):

```
[/dev/infiniband]       ← 设备插件**实际授予本容器**的: uverbsN / rdma_cm/umad/issm(为空 = 没申请到/集群无卡)
[/sys/class/infiniband] ← 宿主全部 HCA(只读): ★ mlx5_0 [InfiniBand] 400 Gb/sec 4:ACTIVE verbs=[uverbs0]
                           ★ = 本容器实际拿到的(其 uverbsN 出现在上面 /dev/infiniband 里)
[RDMA 链路]             ← rdma link show(容器 netns 视角): 列全部 HCA 的 state/physical_state
[网络接口] + [工具在位清单] + [ibv_devinfo -l] + [常用命令]
```

⚠ 两个名字不是一回事: `mlx5_2` 是 **RDMA 设备名**,`ibs2` 是它的 **netdev 名**,**编号不通用**
(实测某节点 `mlx5_0 → ibs2`、`mlx5_1 → ibs3`)。要确认映射,看视图里 `verbs=[uverbsN]` 与
`/dev/infiniband/` 下的 `uverbsN` 是否对上。

## 6. 边界(如实标注)

- 本 pod 提供**诊断能力**(设备可见性 + 工具在手 + 可跑 verbs/带宽),**不证明** RDMA 数据面可用 ——
  那需要两端各起 `ib_write_bw` 实测;
- 无卡集群上 `ibv_devinfo` 报 `0 HCAs found` 是**预期**(工具在位,只是没有设备);
- 镜像是**本地衍生**镜像(上游 netshoot + 自编译 perftest),不进 Harbor 上游同步链路;
- 相关模块: `10_rdma_shared_dev_plugin`(设备插件)、`30_verify_rdma_shared_dev_plugin`(自动化验证);
  设备命名与 by-link 池的关系见 `deployments/cubestack-addon/rdma/CUBESTACK.md`。
