# offline-files/bmc/

BMC 带外监控 exporter 的**离线镜像 tar**,共 2 个。

| 镜像 ref | 版本变量(`cluster.conf`) |
|---|---|
| `${BMC_EXPORTER_HARBOR}/${BMC_EXPORTER_PROJECT}/bmc-oem-exporter` | `BMC_EXPORTER_IMAGE_TAG`(默认 `latest`) |
| `${BMC_EXPORTER_HARBOR}/${BMC_EXPORTER_PROJECT}/idrac-exporter` | `BMC_EXPORTER_IMAGE_TAG` |

默认展开即 `harbor.isuanova.com/suanova/{bmc-oem-exporter,idrac-exporter}:latest`。

- tar 名: 按上游 ref 自动派生 → `harbor.isuanova.com_suanova_bmc-oem-exporter_latest.tar`
- 目录变量: `cluster.conf` 的 `BMC_EXPORTER_OFFLINE_DIR`(模块内默认指本目录)
- 取镜像(二选一):

  ```bash
  # ① 该组件专用工具(直接拉 ${BMC_EXPORTER_HARBOR}/${BMC_EXPORTER_PROJECT})
  sudo ./deployments/scripts/tools/images/bmc-save-images.sh

  # ② 走统一清单 —— ⚠ 必须加 --from-upstream:
  #    本组"上游就是本台 Harbor", 清单里的 ref 已是 harbor.isuanova.com/suanova/**;
  #    harbor-save 默认按 mirrors/<路径> 取源, 而本组**默认不镜像到 mirrors/**, 不加这个旗标会拉不到。
  sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group bmc --from-upstream
  ```

- 谁消费: `modules/03_addon/33_bmc_exporter.sh`
  - `BMC_EXPORTER_MODE=online`: 部署前先从私服同步镜像到本目录(落 `<tar>` + `.digest` 边车);
    上游 `main` 线只发 `latest`,靠边车比对 digest 防漂移
  - `BMC_EXPORTER_MODE=offline`: 只用本目录已有 tar,完全不联网
- ⚠ 本目录**只放镜像 tar**; chart 在 `deployments/cubestack-addon/bmc-exporter/`
  (`cubestack-bmc-exporter-1.0.0.tgz` + `.digest` 边车)
- 升级: 改 `BMC_EXPORTER_IMAGE_TAG` / 图表版本 → 重拉 tar → `--steps bmc_exporter`
  (`BMC_EXPORTER_ENABLED` 默认 **false**,需真实 BMC IP/凭据)

> ⚠ 本目录下的 `*.tar` 已在 `.gitignore` 中忽略(tar 不入库); 只有本 README 受版本控制。
