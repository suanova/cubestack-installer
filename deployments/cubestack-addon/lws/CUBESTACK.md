# LWS Helm Chart — CubeStack 适配说明

本目录为 **LeaderWorkerSet v0.10.0 官方 Helm Chart**(完整发布包, 含 CRD / templates / values), 供
`modules/03_addon/05_gpu_lws.sh` 离线部署使用。官方 README 见同目录 `README.md`。

## 目录内容

```
deployments/cubestack-addon/lws/
├── Chart.yaml                      # version: v0.10.0, appVersion: v0.10.0
├── values.yaml                     # 官方可配置项(enableCertManager / enableDisaggregatedSet / image.manager.*)
├── crds/                           # 官方完整 CRD(leaderworkersets / disaggregatedsets / disaggregatedsetrolescalers)
├── templates/                      # 官方模板(certmanager / manager / rbac / webhook / prometheus)
├── lws-chart-v0.10.0.tgz           # 官方发布包(helm install 直接用 tgz)
├── README.md                       # 官方 README(官方安装/配置说明)
└── CUBESTACK.md                    # 本文件(项目适配说明)
```

## 部署方式(三种 chart 源, `LWS_CHART_SOURCE`)

| 方式 | 命令/配置 | 说明 |
|---|---|---|
| **dir**(默认) | `LWS_CHART_SOURCE=dir` + `LWS_CHART_DIR=deployments/cubestack-addon/lws` | 本地解包目录, 离线友好 |
| **tgz** | `LWS_CHART_SOURCE=tgz` + `LWS_CHART_TGZ=.../lws-chart-v0.10.0.tgz` | 本地发布包 |
| **oci** | `LWS_CHART_SOURCE=oci` + `LWS_CHART_OCI=oci://registry.k8s.io/lws/charts/lws` + `LWS_CHART_VERSION=v0.10.0` | 官方 OCI, 需联网 |

OCI 方式对应官方命令:

```bash
CHART_VERSION=v0.10.0
helm install lws oci://registry.k8s.io/lws/charts/lws \
  --version=$CHART_VERSION \
  --namespace lws-system --create-namespace \
  --set enableDisaggregatedSet=true \
  --wait --timeout 300s
```

## 关键 values(由部署脚本注入, 也可手工 --set)

| values 键 | 默认 | 说明 |
|---|---|---|
| `enableCertManager` | `false` | `false`=controller 内置证书(internal); `true`=外部 cert-manager |
| `enableDisaggregatedSet` | `false` | `true`=安装 DisaggregatedSet editor/viewer/admin 角色 + 校验 webhook |
| `image.manager.repository` | `registry.k8s.io/lws/lws` | controller 镜像仓库(离线改集群内置 registry) |
| `image.manager.tag` | `v0.10.0` | 镜像 tag(留空用 Chart.AppVersion) |
| `image.manager.pullPolicy` | `IfNotPresent` | 镜像拉取策略 |

## 项目集成

- 部署脚本: `modules/03_addon/05_gpu_lws.sh`(`LWS_ENABLED=true` 或 `--enable gpu_lws`)
- 证书模式: `LWS_CERT_MODE=internal|cert-manager`(默认 internal, 对应 enableCertManager)
- DisaggregatedSet: `LWS_DISAGGREGATEDSET_ENABLED=true`(默认, 对应 enableDisaggregatedSet)
- 端到端验证: `--steps verify_lws`(见 `modules/03_addon/24_verify_lws.sh`)
- 使用文档: `docs/lws.md`; 故障排查: `docs/troubleshooting.md` §三.4

## 升级到新版本

联网机下载官方发布包替换本目录(保留 CUBESTACK.md):

```bash
helm pull oci://registry.k8s.io/lws/charts/lws --version <新版> --untar --untardir /tmp
cp -r /tmp/lws/* deployments/cubestack-addon/lws/
# 同时更新 cluster.conf: LWS_CHART_VERSION / LWS_IMAGE_TAG
```
