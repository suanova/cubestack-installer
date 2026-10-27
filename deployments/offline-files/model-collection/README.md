# offline-files/model-collection/

**模型推理镜像**(sglang / vllm-metax)离线资产 —— 镜像集 = [`suanova/model-collection`](https://github.com/suanova/model-collection)
仓库引用的 ref；2026-10-23 收敛为 **2 件 ≈31G**：仅保留 sglang 主版本 + vllm-metax 0.27.0
（原 5 个变体已删除，含 qwen21-dev / h3-patch / vllm py310）。

## 目录结构

| 子目录 | 内容(上游 ref) | Harbor 体积 |
|---|---|---|
| `sglang/` | `harbor.isuanova.com/suanova/sglang:0.5.13-maca.ai3.8.1.3-torch2.10-py310-ubuntu22.04-amd64` | 20.25 GiB |
| `vllm/` | `harbor.isuanova.com/suanova/vllm-metax:0.27.0-maca.ai3.8.2.302-torch2.10-py312-ubuntu22.04-amd64` | 10.97 GiB |

- **清单(单一事实源)**: 本目录 `image-list.tsv`(subdir/file/pull_ref/save_ref; 拉取与推送同源)。
- **tar 命名**: 按上游 ref 派生(`/`、`:` → `_`);**大件压缩存储 `.tar.gz`**(pigz 流式压缩,
  工具与模块均支持 .tar / .tar.gz 双读)。
- 单件更新可经 Harbor→MinIO 保鲜管道(见下)增量进行, 无需全量重拉。
- ⚠ **备料踩坑(2026-10-16 实机)**: `docker save <ref> | pigz > x.tar.gz` 的**裸管道**会把 docker save
  的中途失败**掩蔽**成成功(pigz 退出码为 0)⇒ 产出 1.5KB 空壳档(manifest 列 14 层、实体仅 1 个 config blob)。
  **必须**: `docker save -o <file>`(退出码不被掩蔽)+ **层完整性硬校验**(manifest.Layers ⊆ 档内 blobs)
  + `pigz -c` 二次压缩。

## 消费方

- **部署(推入集群内置 registry, 排最后)**: `modules/03_addon/37_model_images.sh`
  (`MODEL_IMAGES_ENABLED`, 默认 true; 模块排 37 = **dev_lab(36) 之后**, 保证集群与全部 operator
  部署完成才做 ≈31G 的大推送; 缺失 tar 只告警跳过, 不阻断部署);
  目标 ref = `<集群 registry>/<ref 去注册域后的路径>`(`suanova/…` 原样保路径)。
  单独执行: `sudo ./deploy-cluster.sh --steps model_images`; 跳过: `--skip model_images`。
- **同步(Harbor→MinIO 保鲜管道, 内网)**: `tools/images/cubestack-platform-sync.sh`
  (集合名 `model-collection`; 增量: 只对被改动的镜像重拉重传);
  单集合: `… -sync.sh --collection model-collection`。
- **部署机取回**: `tools/offline/fetch-offline-from-minio.sh --sub model-collection`(整集)或
  `--sub model-collection/sglang`(单子目录)。

> ⚠ 本目录 `*.tar` / `*.tar.gz` / `*.digest` 不入库(gitignore); 只有本 README 与 image-list.tsv 受版本控制。
