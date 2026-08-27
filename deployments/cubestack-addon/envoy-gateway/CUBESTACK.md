# Envoy Gateway / Envoy AI Gateway Helm Charts — CubeStack 适配说明

本目录为 **Envoy Gateway**(`gateway-helm`)与 **Envoy AI Gateway**(`ai-gateway-crds-helm` + `ai-gateway-controller-helm`)
的**离线 chart 存放目录**, 供 `modules/03_addon/09_envoy_gateway.sh` / `10_envoy_ai_gateway.sh` 离线部署使用。

> ⚠ **chart 文件不在仓库内**(体积大、需联网 helm pull): 首次使用先在**联网机**执行
> `deployments/scripts/tools/images/envoy-fetch-charts.sh` 下载解包到本目录, 再拷到部署机。
> 部署模块检测到 chart 缺失时会报错并给出指引, 不会静默跳过。

## 目录内容(联网机执行 fetch 后生成)

```
deployments/cubestack-addon/envoy-gateway/
├── CUBESTACK.md                # 本文件(项目适配说明)
├── eg/                         # Envoy Gateway: gateway-helm(官方 helm repo / OCI)
│   ├── Chart.yaml              #   version: 1.9.0(随 ENVOY_EG_VERSION)
│   ├── values.yaml             #   image.*(控制面) / envoyGateway.image.*(数据面) 等
│   ├── crds/                   #   Gateway API CRDs(gateway.networking.k8s.io)
│   └── templates/              #   控制面 Deployment/ConfigMap/Service/RBAC
└── ai/                         # Envoy AI Gateway: 两个官方 OCI chart
    ├── ai-gateway-crds-helm/       #   AI CRDs(aigateway.envoyproxy.io: AIGateway/Backend/...)
    │   ├── Chart.yaml
    │   └── crds/
    └── ai-gateway-controller-helm/ #   AI 控制器(含 Extension Server 服务/证书)
        ├── Chart.yaml
        └── templates/
```

## 下载命令(联网机)

```bash
# 默认版本(cluster.conf 的 ENVOY_EG_VERSION / ENVOY_AI_VERSION)
sudo ./deployments/scripts/tools/images/envoy-fetch-charts.sh
# 或指定版本
ENVOY_EG_VERSION=v1.9.0 ENVOY_AI_VERSION=v1.0.0 sudo ./deployments/scripts/tools/images/envoy-fetch-charts.sh
# 离线镜像(同一台联网机)
sudo ./deployments/scripts/tools/images/envoy-save-images.sh
```

## 关键 values(由部署脚本注入, 也可手工 --set)

| chart | values 键 | 默认 | 离线改写 |
|---|---|---|---|
| gateway-helm | `image.repository` / `image.tag` | `docker.io/envoyproxy/gateway` | `${REGISTRY_DOMAIN}:${REGISTRY_PORT}/envoyproxy/gateway`(控制面) |
| gateway-helm | `envoyGateway.image.repository` / `image.tag` | `docker.io/envoyproxy/envoy` | 同上 `/envoyproxy/envoy`(**数据面**, 离线关键) |
| gateway-helm | `config.envoyGateway.extensionManager.*` | 空 | AI 模块注入(Extension Server 注册) |
| ai-gateway-controller-helm | `image.repository` / `image.tag` | `ghcr.io/envoyproxy/ai-gateway/ai-gateway-controller` | `${REGISTRY_DOMAIN}:${REGISTRY_PORT}/ai-gateway/ai-gateway-controller` |

## 项目集成

- 部署: `modules/03_addon/09_envoy_gateway.sh`(`ENVOY_GATEWAY_ENABLED=true` 或 `--enable envoy_gateway`)
  + `modules/03_addon/10_envoy_ai_gateway.sh`(`ENVOY_AI_GATEWAY_ENABLED=true`, 依赖 EG 先装)
- 离线镜像: `tools/images/envoy-save-images.sh`(默认 `deployments/offline-files/envoy`)
- 端到端验证: `--steps verify_envoy_gateway` / `--steps verify_envoy_ai_gateway`
- 分析/使用文档: `docs/envoy-gateway.md`; 故障排查: `docs/troubleshooting.md` §四

## 升级到新版本

```bash
# 联网机: 更新版本后重新拉取(目录内容整体替换, 保留本文件)
ENVOY_EG_VERSION=<新版本> ENVOY_AI_VERSION=<新版本> sudo ./deployments/scripts/tools/images/envoy-fetch-charts.sh
# 同时更新 cluster.conf: ENVOY_EG_VERSION / ENVOY_AI_VERSION / ENVOY_AI_API_VERSION / 镜像 tag
```
