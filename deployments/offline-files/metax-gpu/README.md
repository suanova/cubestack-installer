# offline-files/metax-gpu/

沐曦(MetaX)GPU Operator 的**离线镜像 tar** + **GPU 资源包**。

镜像共 12 个,全部来自本台 Harbor 的 `metax/` 项目(`${METAX_HARBOR}/${METAX_PROJECT}/…`,默认 `harbor.isuanova.com/metax/`):

| 组件 | 版本变量(`cluster.conf`) |
|---|---|
| `gpu-label` `gpu-device` `gpu-aware` `topo-master` `topo-worker` `operator-controller` `container-runtime` `driver-manager` `gpu-scheduler` `mx-exporter` | `METAX_VERSION`(默认 `0.15.3`,tag 形如 `0.15.3-amd64`) |
| `driver-image` | `METAX_DRIVER_VERSION`(默认 `3.8.1.6-amd64`) |
| `maca`(MXMACA SDK 镜像) | `METAX_MACA_IMAGE`(默认 `maca:3.8.1.2-ubuntu22.04-amd64`) |

- tar 名: 按上游 ref 自动派生 → 如 `harbor.isuanova.com_metax_container-runtime_0.15.3-amd64.tar`
- 目录变量: `cluster.conf` 的 `METAX_OFFLINE_DIR`(`METAX_PKG_DIR` 同默认值)
- 取镜像/资源包:

  ```bash
  sudo ./deployments/scripts/tools/images/metax-save-images.sh    # 镜像 → 本目录
  #  匹配/排除规则见 cluster.conf: METAX_SAVE_PATTERN=^harbor\.isuanova\.com/metax/  METAX_SAVE_EXCLUDE=sglang
  sudo ./deployments/scripts/tools/images/metax-load-images.sh    # 部署机侧载入
  ```

- 本目录还放 **GPU 资源包**: `metax-gpu-k8s-package.${METAX_VERSION}.tar.gz`(文件名变量 `METAX_PKG_TGZ`)
- 谁消费: `modules/03_addon/06_gpu_operator.sh`(`METAX_IMAGE_MODE=tar` 时从本目录取 tar)
- 与清单的关系: 本组上游就是本台 Harbor,`harbor-sync-images.sh` **默认不把它镜像到 `mirrors/**`**
  (判据是推导的: 注册域 == `HARBOR_MIRROR_REGISTRY`);真需要那份副本用 `--include-same-harbor`
- 升级: 改 `METAX_VERSION` / `METAX_DRIVER_VERSION` / `METAX_MACA_IMAGE` → 重拉镜像与资源包 → `--steps gpu_operator`

> ⚠ 本目录下的 `*.tar` / `*.tar.gz` 已在 `.gitignore` 中忽略(制品不入库); 只有本 README 受版本控制。
