# Envoy Gateway / Envoy AI Gateway Helm Charts — CubeStack 适配说明

本目录为 **Envoy Gateway**(`gateway-helm`)与 **Envoy AI Gateway**(`ai-gateway-crds-helm` + `ai-gateway-helm`)
的**离线 chart tgz 存放目录**(**默认路径**), 供 `modules/03_addon/09_envoy_gateway.sh` / `10_envoy_ai_gateway.sh` 离线部署使用。
**仓库只存 tgz 压缩包**(体积小、不膨胀代码库); 部署模块在**部署时把 tgz 临时解压到 `mktemp` 目录**再 `helm install`,
部署机无需联网, 完全离线可用, 临时解压目录退出自动清理。

> ⚠ **chart tgz 不随仓库提交**(需联网下载): 首次需在**联网机**按下方"下载命令"获取并放置到本目录
> (或直接跑 `deployments/scripts/tools/images/envoy-fetch-charts.sh` 一键下载 tgz), 再随仓库/手工拷到部署机。
> 部署模块检测到 tgz 缺失时会报错并给出完整指引(不会静默跳过)。

## 目录内容(tgz-only, 部署时临时解压)

```
deployments/cubestack-addon/envoy-gateway/
├── CUBESTACK.md                          # 本文件(项目适配说明)
├── eg/                                   # Envoy Gateway: gateway-helm(官方 DockerHub OCI)
│   └── gateway-helm-1.9.1.tgz            #   chart 压缩包(随 ENVOY_EG_VERSION, 带 v)
└── ai/                                   # Envoy AI Gateway: 两个官方 chart(docker.io OCI)
    ├── ai-gateway-crds-helm-v1.1.0.tgz   #   AI CRDs chart(aigateway.envoyproxy.io: AIServiceBackend/AIGatewayRoute/GatewayConfig/...)
    └── ai-gateway-helm-v1.1.0.tgz        #   AI 控制器 chart(controller Deployment/Service + MutatingWebhook 自签证书)
```

**tgz 命名规范**: `<chart>-<ENVOY_*_VERSION>.tgz`(**版本带 v**, 与 cluster.conf 的
`ENVOY_EG_VERSION` / `ENVOY_AI_VERSION` 一致), 如 `gateway-helm-v1.9.1.tgz`、`ai-gateway-helm-v1.1.0.tgz`。
部署模块默认 `ENVOY_*_CHART_SOURCE=tgz` 直接读取; `dir` 源(手工解包目录)仍可选用。

## 下载命令(联网机)

> ⚠ **不要用 GitHub 源码仓库的 chart 目录**: `github.com/envoyproxy/gateway` 源码下 `charts/gateway-helm`
> 是发布前源码(Chart.yaml `version=v0.0.0-latest`、只有 `values.tmpl.yaml` 无 `values.yaml`), 不可直接安装。
> **发布版 chart 只能从官方 OCI / GitHub release 下载**:
>   · `gateway-helm`(EG): DockerHub OCI `oci://docker.io/envoyproxy/gateway-helm`(官方唯一发布通道)
>   · `ai-gateway-crds-helm` / `ai-gateway-helm`(AI): DockerHub OCI 同名字段, 或 GitHub release 资产
>     `github.com/envoyproxy/ai-gateway/releases/download/v1.1.0/ai-gateway-helm-v1.1.0.tgz` 等。
>   ⚠ AI chart **不是** ghcr OCI(`oci://ghcr.io/envoyproxy/ai-gateway/charts/...` 会 403 不存在)。

**方式一(推荐): 仓库自带脚本一键下载 tgz 到默认路径**(需 helm 3+ 与联网; **fetch 不需要 sudo**)
```bash
# 默认版本(cluster.conf 的 ENVOY_EG_VERSION / ENVOY_AI_VERSION)
./deployments/scripts/tools/images/envoy-fetch-charts.sh
# 或指定版本(不用 sudo; sudo 会清环境变量)
ENVOY_EG_VERSION=v1.9.1 ENVOY_AI_VERSION=v1.1.0 ./deployments/scripts/tools/images/envoy-fetch-charts.sh
# 离线镜像(同一台联网机, 完全离线还需它; 需要 sudo, 指定版本时 VAR= 写在 sudo 之后)
sudo ./deployments/scripts/tools/images/envoy-save-images.sh
sudo ENVOY_EG_VERSION=v1.9.1 ./deployments/scripts/tools/images/envoy-save-images.sh
```

**方式二: 手动 helm pull 下载 tgz**(同样需要 helm 3+, 网络只需可达对应源; **不要加 `--untar`**)
```bash
# Envoy Gateway: gateway-helm(官方托管在 DockerHub OCI, 带 v; 旧 helm repo 仅兜底)
helm pull oci://docker.io/envoyproxy/gateway-helm --version v1.9.1        # 生成 gateway-helm-1.9.1.tgz
mv gateway-helm-1.9.1.tgz eg/gateway-helm-v1.9.1.tgz                     # 按规范改名(带 v)
#  或(旧官方 helm repo): helm repo add envoy-gateway https://charts.gateway.envoyproxy.io
#      helm pull envoy-gateway/gateway-helm --version 1.9.1

# Envoy AI Gateway: 两个 chart(docker.io OCI, 带 v; ghcr 同名路径不存在)
helm pull oci://docker.io/envoyproxy/ai-gateway-crds-helm --version v1.1.0   # ai-gateway-crds-helm-v1.1.0.tgz(名已规范)
helm pull oci://docker.io/envoyproxy/ai-gateway-helm       --version v1.1.0   # ai-gateway-helm-v1.1.0.tgz(名已规范)
# 无 helm 或 docker.io 被墙: 从 GitHub release 直接下载 tgz(命名已是规范形式)
#   curl -LO https://github.com/envoyproxy/ai-gateway/releases/download/v1.1.0/ai-gateway-helm-v1.1.0.tgz
#   curl -LO https://github.com/envoyproxy/ai-gateway/releases/download/v1.1.0/ai-gateway-crds-helm-v1.1.0.tgz
```

**放置要点**: 只放 tgz 到对应目录即可, **无需解包**(部署模块在部署时临时解压到 mktemp 目录, 退出自动清理)。
若目录里残留旧版脚本留下的解包子目录(如 `eg/gateway-helm/`、`ai/ai-gateway-crds-helm/`), fetch 脚本会自动清除,
手动放置时也可直接删掉(仓库只留 tgz)。
版本对应: `ENVOY_EG_VERSION=v1.9.1` ↔ tgz `gateway-helm-v1.9.1.tgz`(OCI 拉取时带 v: `--version v1.9.1`);
`ENVOY_AI_VERSION=v1.1.0` ↔ tgz `ai-gateway-helm-v1.1.0.tgz`(Chart.yaml 里 version 本身带 v, OCI 拉取 `--version v1.1.0`)。

## 关键 values(由部署脚本注入, 也可手工 --set)

| chart | values 键 | 默认 | 离线改写 |
|---|---|---|---|
| gateway-helm | `image.repository` / `image.tag` | `docker.io/envoyproxy/gateway` | `${REGISTRY_DOMAIN}:${REGISTRY_PORT}/envoyproxy/gateway`(控制面) |
| gateway-helm | `envoyGateway.image.repository` / `image.tag` | `docker.io/envoyproxy/envoy` | 同上 `/envoyproxy/envoy`(**数据面**, 离线关键) |
| ai-gateway-helm | `controller.image.repository` / `controller.image.tag` | `docker.io/envoyproxy/ai-gateway-controller` | `${REGISTRY_DOMAIN}:${REGISTRY_PORT}/ai-gateway/ai-gateway-controller` |
| ai-gateway-helm | `controller.nameOverride` | 空 | `ai-gateway-controller`(让 Deployment/Service 名 = ai-gateway-controller) |
| ai-gateway-helm | `envoyGateway.namespace` | `envoy-gateway-system` | 同 EG 命名空间(AI 控制器在其内建/看 Gateway 资源) |

> v1.x 架构说明: AI Gateway **不再走 v0.x 的 EG extensionManager/Extension Server 机制**(官方 v1.x chart
> 无 18090 端口)。AI 控制器通过 **Mutating Webhook + extProc 注入** 为**标准 Gateway**(gatewayClassName=
> `envoy-gateway`)提供 AI 能力; AI CRD 为 `AIServiceBackend`/`AIGatewayRoute`/`GatewayConfig` 等
> (v1.1 起**没有** `AIGateway`/`Backend` CRD)。

## 项目集成

- 部署: `modules/03_addon/09_envoy_gateway.sh`(`ENVOY_GATEWAY_ENABLED=true` 或 `--enable envoy_gateway`)
  + `modules/03_addon/10_envoy_ai_gateway.sh`(`ENVOY_AI_GATEWAY_ENABLED=true`, 依赖 EG 先装)
- 离线镜像: `tools/images/envoy-save-images.sh`(默认 `deployments/offline-files/envoy`)
- 端到端验证: `--steps verify_envoy_gateway` / `--steps verify_envoy_ai_gateway`
- 分析/使用文档: `docs/envoy-gateway.md`; 故障排查: `docs/troubleshooting.md` §四

## 升级到新版本

```bash
# 联网机: 更新版本后重新下载(目录内容整体替换, 保留本文件; fetch 不需要 sudo)
ENVOY_EG_VERSION=<新版本> ENVOY_AI_VERSION=<新版本> ./deployments/scripts/tools/images/envoy-fetch-charts.sh
# 同时更新 cluster.conf: ENVOY_EG_VERSION / ENVOY_AI_VERSION / ENVOY_AI_API_VERSION / 镜像 tag
```
