# offline-files/netshoot/

网络/RDMA **诊断 pod** 的离线镜像 tar(模块 `35_netshoot.sh` 消费)。

两种 tar 都放这里, 模块**优先自建**:

| tar | 是什么 | 怎么来 |
|---|---|---|
| `netshoot-rdma-<perftest版本>.tar` | **自建镜像**(推荐): netshoot + rdma-core(ibv_devices/ibv_devinfo) + perftest(ib_write_bw/ib_read_bw…) | 联网机跑 `sudo ./deployments/scripts/tools/images/netshoot-rdma-build.sh` |
| (回退) `../../os/netshoot.tar` | 上游 netshoot 原样 | 已有备料; 模块在自建 tar 缺失时回退用它, **无 ibv_*/perftest**(会告警) |

- 版本真相: `cluster.conf` 的 `NETSHOOT_RDMA_VERSION`(值 = perftest 版本, 默认 `26.04.17`, 也是镜像 tag)
- 基础镜像: `docker.io/nicolaka/netshoot:latest`(登记在 `config/images.manifest` 的 `netshoot` 组)

## 为什么自建(上游 netshoot 不够用)

- 上游 netshoot **不含 rdma-core** → 没有 `ibv_devices`/`ibv_devinfo`(实测镜像内无 libibverbs、无 `rdma` 二进制, 其 `ip` 也没有 `rdma` 子命令);
- Alpine 社区源**没有 perftest 包** → 只能源码编译(见 `tools/images/netshoot-rdma.Dockerfile` 的两阶段构建);
- 离线集群没软件源 → pod 里 `apk add` 跑不通, **必须构建期装好**。

## 构建(联网机)

```bash
sudo ./deployments/scripts/tools/images/netshoot-rdma-build.sh          # 构建 + 自检 + 保存 tar(已有则跳过)
sudo ./deployments/scripts/tools/images/netshoot-rdma-build.sh --force  # 换版本/重编
sudo PERFTEST_VERSION=26.04.17 ./deployments/scripts/tools/images/netshoot-rdma-build.sh --force   # 指定版本
```

脚本会: 载入基础镜像(优先用 `offline-files/os/netshoot.tar`, 不依赖 Docker Hub)→ 两阶段构建 →
**容器内自检**(缺 `ibv_*`/`ib_write_bw`/`tcpdump` 就直接失败, 不产出残缺 tar)→ `docker save` 到本目录。

## 升级

改 `cluster.conf` 的 `NETSHOOT_RDMA_VERSION` → `netshoot-rdma-build.sh --force` 重建 →
`sudo ./deploy-cluster.sh --steps netshoot`(模块把新 tar 推进集群内置 registry 并重建 pod)。

## 谁消费

`deployments/scripts/modules/03_addon/35_netshoot.sh` —— 推入**集群内置 registry** 后起诊断 pod
(默认命名空间 `default`, pod 名 `cubestack-netshoot`); 节点只从内置 registry 拉取, 不访问公网。
RDMA 资源(`rdma/hca_shared_devices`)**注册了才申请**, 没注册自动降级为通用网络诊断 pod。

> ⚠ 本目录下的 `*.tar` 已在 `.gitignore` 中忽略(tar 不入库); 只有本 README 受版本控制。
