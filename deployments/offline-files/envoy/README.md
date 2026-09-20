# offline-files/envoy/

Envoy Gateway 控制面 + 数据面 + AI Gateway 的**离线镜像 tar**,共 4 个。

| 镜像 ref | 版本变量(`cluster.conf`) |
|---|---|
| `docker.io/envoyproxy/gateway` | `ENVOY_EG_VERSION`(默认 `v1.9.1`) |
| `docker.io/envoyproxy/envoy` | `ENVOY_PROXY_VERSION`(默认 `distroless-v1.39.1`) |
| `docker.io/envoyproxy/ai-gateway-controller` | `ENVOY_AI_VERSION`(默认 `v1.1.0`) |
| `docker.io/envoyproxy/ai-gateway-extproc` | `ENVOY_AI_VERSION` |

- tar 名: 按上游 ref 自动派生(`/` 与 `:` → `_`),如 `docker.io_envoyproxy_ai-gateway-controller_v1.1.0.tar`
- 目录变量: `cluster.conf` 的 `ENVOY_SAVE_DIR`(默认指本目录)
- 取镜像:

  ```bash
  sudo ./deployments/scripts/tools/images/envoy-save-images.sh     # 该组件专用工具
  sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group envoy   # 或走统一 Harbor 源
  ```

- 谁消费: `modules/03_addon/15_envoy_gateway.sh`(EG 控制面 + 数据面)、
  `modules/03_addon/16_envoy_ai_gateway.sh`(AI Gateway)
- 载入(部署机侧): `tools/images/envoy-load-images.sh`
- 升级: 改版本变量 → 重拉 tar → `--steps envoy_gateway` / `--steps envoy_ai_gateway`

> ⚠ 本目录下的 `*.tar` 已在 `.gitignore` 中忽略(tar 不入库); 只有本 README 受版本控制。
