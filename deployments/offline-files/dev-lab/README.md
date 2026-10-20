# offline-files/dev-lab/

开发镜像(jupyter / ssh 系列)**离线镜像 tar**(6 个, 均为平台开发环境镜像)。

## 目录结构(2026-10-16 起按家族分子目录)

| 子目录 | 镜像(上游 = 本台 Harbor 的 `suanova` 项目; tag 统一由 `DEV_LAB_IMAGE_TAG` 控制, 默认 `latest`) |
|---|---|
| `jupyter/` | `jupyter-minimal:latest` / `jupyter-maca-pytorch:latest` / `jupyter-cuda-pytorch:latest` |
| `ssh/` | `ssh-ubuntu22.04:latest` / `ssh-maca-pytorch:latest` / `ssh-cuda-pytorch:latest` |

- **清单(单一事实源)**: 本目录 `image-list.tsv`(subdir/file/pull_ref/save_ref)。
- 迁移期模块**双读**(子目录优先, 顶层平铺兼容); fetch 可按子目录单独取:
  `fetch-offline-from-minio.sh --sub dev-lab/jupyter`。
- tar 名: 按**上游 ref** 自动派生(如 `harbor.isuanova.com_suanova_jupyter-minimal_latest.tar`)。
- ★ **大件压缩存储**(2026-10-12 口径, 2026-10-16 推广): `.tar.gz`(pigz/gzip);部署模块与
  `find_offline_tar` **自动识别 .tar / .tar.gz** —— plain 走**内容校验**(毫秒级), `.gz` 走
  **文件名匹配**(tar 文件名为权威; gzip 无法反向寻址而 manifest 在归档末尾, 做内容检查=整卷解压);
  `.gz` 时镜像推送的 digest 跳过退化为"blob 存在性探测"(skopeo 自动跳过已存在层, 成本极小)。
- ⚠ **上游即本台 Harbor(不是公共 registry)**: `harbor-save-images.sh` 对同源组**直接用原始 ref**
  拉取(不拼 `mirrors/`); 需要在能连 Harbor 的机器上执行(容器 CLI 自带 skopeo 与凭据)。
- ⚠ tag 是滚动的 `latest`: 离线 tar 会随上游滚动构建失效 —— **重新部署前重跑 save 工具**
  (模块推送按 digest 比对, 内容变了自动重推, 没变跳过)。
- 版本真相: `cluster.conf` 的 `DEV_LAB_IMAGE_TAG`; 目录变量: `DEV_LAB_SAVE_DIR`(默认指本目录)。

## 取镜像 / 保鲜

```bash
# ① 直接取(联网机; 同源组直连 Harbor):
sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group dev-lab
# ② Harbor→MinIO 保鲜管道(内网定时; 集合名 dev-lab; 增量, 只重拉有变化的):
bash ./deployments/scripts/tools/images/cubestack-platform-sync.sh --collection dev-lab
# ③ 部署机取回: fetch-offline-from-minio.sh --sub dev-lab [--sub dev-lab/jupyter ...]
```

## 消费方

- `modules/03_addon/36_dev_lab.sh` —— 每次默认部署把 tar 推入**集群内置 registry** 的
  `<REG>/suanova/<name>:<tag>`(节点从此拉取, 不访问 Harbor); 缺 tar 的镜像该次 warn 跳过。
- ★ **模块排在全部部署模块末位**(2026-10-13 口径): 开发镜像无依赖 ⇒ ≈45G 的大推送放在
  operator/验证等关键链路**之后**; 开关 `DEV_LAB_ENABLED` 默认 `true`, 跳过用 `--skip dev_lab` 或置 false。
- 升级/刷新: 上游滚动构建后重跑 save(覆盖 tar)或由保鲜管道增量刷新 → 下次部署模块按 digest 自动重推。

> ⚠ 本目录下的 `*.tar` / `*.tar.gz` / `*.digest` 已在 `.gitignore` 中忽略(tar 不入库);
> 只有本 README 与 `image-list.tsv` 受版本控制。
