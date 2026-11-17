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

# 2.1 完整包: 如果 <root>/<ver>/cubestack-<ver>.meta.tar.zst 存在,
# deploy 会先解包 meta + 选中的 payload 包, 再走 release 模式。
sudo ./deploy-cluster.sh --release 2.1.0 --with-packages models,dev-lab

# 方式二：直接把版本树的 offline-files/ 挂到默认位置
#   deployments/offline-files/release.env 存在即自动进入 release 模式
sudo ./deploy-cluster.sh --with-cubestack
```

`load_config` 会读取 `release.env`，并把所有 `offline-files/<组件>` 路径重定向到版本树。
切回 dev 模式：移除 `release.env`，或设 `CUBESTACK_RELEASE_AUTO="false"`。

## 包选择

2.1 完整包在 `release.yaml:packages[]` 里列出 payload 包。installer 只读本地
release 树，不访问 private release repo / MinIO / Harbor：

```bash
python3 deployments/scripts/tools/offline/release-packages.py \
  --root <release-tree> --with models,dev-lab \
  --meta <release-tree>/cubestack-<ver>.meta.tar.zst \
  --extract --seal
```

- required 包总是选中；
- optional 包用 `--with` 选择，`--with all` 选全部；
- 每个选中的包都校验本地文件 sha256 和 size；
- `--meta` 解包 meta tar，`--extract` 解包选中 payload，`--seal` 重新封存过滤后的 tree；
- 输出过滤后的 `tree.tsv`，只包含选中 package 的行；
- 没有 `packages[]` 的旧树输出 `legacy`，继续使用完整树。

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

## 正式版镜像

2.1 起没有单独的 `release-images` 入口：

- installer 每次代码合并构建 `cubestack-installer-cli:sha-<commit>`；
- netshoot 源码变化时构建 `netshoot-rdma:sha-<commit>`，并开 PR 更新
  `versions/base.yaml` 的 version + digest，tar 使用中性名 `netshoot-rdma.tar`；
- release 按 `cli.commit` 找到 CLI sha，按 base lock 的 netshoot digest 创建
  产品 tag（`<product>` + `cs-<product>`）；
- CLI 镜像不进 `base.yaml`。

## 镜像构建原则

1. **构建输入只来自仓库或网络**：不读取构建机的 `PATH`、`offline-files/`、
   `bin/` 或本地缓存。代码层以仓库根为上下文；base 层只从仓库取
   `requirements.txt`，工具链按 pinned version + sha256 从上游下载。
2. **网络下载必须钉版本和校验和**：禁止 `latest` URL；版本和 sha256 写在
   Dockerfile 的 `ARG` 里。
3. **base 变化必须连带重建代码层**：代码层永远 `FROM` 一个固定 base；base
   重建后必须重建并推送代码层，否则镜像内容与 Dockerfile 不一致。
4. **镜像 tag 按构建身份隔离**：
   - CLI/netshoot dev 只推 `sha-<commit>`；
   - CLI base 按 `images/installer-cli-base` 的 commit 推 `sha-<commit>`；
   - 不再使用 `<line>-latest` 或 channel；
   - release 从 digest 创建产品 tag。
5. **不可变 tag 不覆盖**：版本 tag 已存在时构建失败，要求换版本或显式处理。
6. **CLI 镜像不写入 `versions/base.yaml`**：它不是集群工作负载。release 在
   发布锁/模板里记录 `cli: {image, digest, commit}`，按 commit 找
   `sha-<commit>`、按 digest 拉取并打包成 `cubestack-installer-cli.tar`；
   不使用 `<line>-latest` 或 channel。
