# 版本树与发布边界（2.1+）

> 适用范围：`release-2.1` 及后续版本。
> 发布打包已迁到外部发布流程。本仓库不再产出发布包，只负责**部署**。

## 职责划分

| 仓库 | 职责 |
|---|---|
| 外部发布流程 | 组件/base pin、发布锁、镜像清单、拉源制品、打包、MinIO 发布、streams、`materialize` / `merge-tree` |
| cubestack-installer | 部署引擎、公共模块、私有平台模块（由版本树 `modules/` 提供）、完整性校验、CLI 镜像构建 |

## 安装树的形状

外部流程物化后的版本树：

```text
<root>/<version>/
  cubestack-installer-cli.tar        # CLI 镜像 tar
  modules/                           # 平台模块（含 03_addon/）
  offline-files/
    release.env                      # RELEASE_VERSION / KUBESPRAY_VERSION / 组件版本变量
    release.yaml
    release.json
    tree.tsv                         # blob → 安装路径
    SHA256SUMS
    _SUCCESS
    base/                            # base 包元数据
    <组件>/                          # 镜像/chart tar
```

installer 只读这棵树，不关心它由哪种打包流程生成。

## 部署

```bash
# 方式一：版本树放在 <root>/<version>/
sudo ./deploy-cluster.sh --release 2.1.0
# 等价于 cluster.conf: CUBESTACK_RELEASE="2.1.0"（+ 可选 CUBESTACK_RELEASE_ROOT）

# 方式二：直接把版本树的 offline-files/ 挂到默认位置
#   deployments/offline-files/release.env 存在即自动进入 release 模式
sudo ./deploy-cluster.sh --with-cubestack
```

`load_config` 会读取 `release.env`，并把所有 `offline-files/<组件>` 路径重定向到版本树。
切回 dev 模式：移除 `release.env`，或设 `CUBESTACK_RELEASE_AUTO="false"`。

## 完整性

- `release.env` 在 `source` 前用 `SHA256SUMS` 预校验；
- 部署前门禁调用 `verify-offline-files.sh` 校验整树（`_SUCCESS` 绑定、清单、哈希）；
- 版本树不完整时直接失败，不会静默降级。

回归：`bash deployments/scripts/tools/tests/test-release-mode.sh`

## 本仓库不再负责

- 组件/base 打包与发布锁（外部发布流程）
- 私有平台镜像清单（版本树的 `tree.tsv`）
- MinIO 下载/上传与旧 `--release` fetch 布局
- release/sync/refresh 流水线

第三方镜像的 Harbor 同步由 `container-image-mirror` 仓库负责；
本仓库不再维护镜像清单或同步流水线。
