# offline-files/cubepilot/

CubePilot AI Agent 平台的**离线镜像 tar**,共 4 个。

| 镜像 ref | 版本变量(`cluster.conf`) |
|---|---|
| `${CUBEPILOT_HARBOR}/${CUBEPILOT_PROJECT}/cubepilot-openclaw` | `CUBEPILOT_IMAGE_TAG` |
| `${CUBEPILOT_HARBOR}/${CUBEPILOT_PROJECT}/cubepilot-operator` | `CUBEPILOT_IMAGE_TAG` |
| `${CUBEPILOT_HARBOR}/${CUBEPILOT_PROJECT}/cubepilot-api` | `CUBEPILOT_IMAGE_TAG` |
| `${CUBEPILOT_HARBOR}/${CUBEPILOT_PROJECT}/cubepilot-web` | `CUBEPILOT_IMAGE_TAG` |

默认展开即 `harbor.isuanova.com/suanova/cubepilot-*:<tag>`;
`CUBEPILOT_IMAGE_TAG` 留空时自动派生(`CUBEPILOT_VERSION` 以 `-latest` 结尾 → `latest`,否则 = chart 版本)。

- tar 名: 按上游 ref 自动派生 → `harbor.isuanova.com_suanova_cubepilot-api_latest.tar`
- 目录变量: `cluster.conf` 的 `CUBEPILOT_OFFLINE_DIR`(模块内默认指本目录)
- 取镜像(二选一):

  ```bash
  # ① 该组件专用工具(直接拉 ${CUBEPILOT_HARBOR}/${CUBEPILOT_PROJECT})
  sudo ./deployments/scripts/tools/images/cubepilot-save-images.sh

  # ② 走统一清单 —— ⚠ 必须加 --from-upstream:
  #    本组"上游就是本台 Harbor", 清单里的 ref 已是 harbor.isuanova.com/suanova/**;
  #    harbor-save 默认按 mirrors/<路径> 取源, 而本组**默认不镜像到 mirrors/**, 不加这个旗标会拉不到。
  sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group cubepilot --from-upstream
  ```

- 谁消费: `modules/03_addon/31_cubepilot.sh`
  - `CUBEPILOT_MODE=online`: 部署前先从私服同步镜像到本目录(落 `<tar>` + `.digest` 边车,
    digest 未变则跳过下载); 私服 `suanova` 项目**公开只读免凭据**
  - `CUBEPILOT_MODE=offline`: 只用本目录已有 tar,完全不联网; **两种模式共用同一段部署代码**,
    因此在线跑通过即可一键切纯离线
- ⚠ 本目录**只放镜像 tar**; chart 在 `deployments/cubestack-addon/cubepilot/`
  (`cubepilot-0.1.0-latest.tgz` + `.digest` 边车)
- 升级: 改 `CUBEPILOT_VERSION` → 重拉 chart + tar → `--steps cubepilot`

> ⚠ 本目录下的 `*.tar` 已在 `.gitignore` 中忽略(tar 不入库); 只有本 README 受版本控制。
