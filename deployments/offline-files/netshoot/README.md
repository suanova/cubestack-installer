# offline-files/netshoot/

网络/RDMA **诊断 pod** 的离线镜像 tar（模块 `35_netshoot.sh` 消费）。

2.1 起镜像统一从 public Harbor 获取，本目录的 tar 由下游物化生成：

| tar | 来源 |
|---|---|
| `netshoot-rdma-<tag>.tar` | release `fetch-base-sources`（skopeo）或开源 `install-online.sh` 从 Harbor 物化 |
| `../../os/netshoot.tar` | 上游 netshoot 回退镜像；无 `ibv_*`/perftest，仅作降级 |

构建/推送镜像不再写 tar：

```bash
make netshoot-rdma NETSHOOT_RDMA_TAG=26.04.17
make netshoot-rdma NETSHOOT_RDMA_TAG=26.04.17 NETSHOOT_RDMA_PUSH=1
```

CI 入口：`.github/workflows/build-netshoot-rdma.yml`。

- 版本真相：`cluster.conf` 的 `NETSHOOT_RDMA_VERSION`（镜像 tag）
- 基础镜像：由 `NETSHOOT_RDMA_BASE_IMAGE` 指定；2.1 应固定在 public mirror 的 tag/digest
- 镜像内容变化必须使用新 tag（如 `26.04.17-r2`），禁止覆盖已有 tag

## 谁消费

`deployments/scripts/modules/03_addon/35_netshoot.sh` —— 把 tar 推入**集群内置 registry** 后起诊断 pod
（默认命名空间 `default`，pod 名 `cubestack-netshoot`）；节点只从内置 registry 拉取，不访问公网。
RDMA 资源（`rdma/ib_shared_devices`）**注册了才申请**，没注册自动降级为通用网络诊断 pod。

> ⚠ 本目录下的 `*.tar` 已在 `.gitignore` 中忽略（tar 不入库）；只有本 README 受版本控制。
