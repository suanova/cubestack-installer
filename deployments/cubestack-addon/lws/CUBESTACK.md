# LWS — CubeStack 适配说明

本目录为 **LeaderWorkerSet v0.10.0** 的离线安装物料, 供 `modules/03_addon/05_gpu_lws.sh` 部署使用。
**默认安装方式 = 官方 `manifests.yaml` bundle(`kubectl apply --server-side`)**, helm chart 保留在 `charts/`
子目录, 供未来 cert-manager 模式 / 自定义 values 使用。

## 目录内容

```
deployments/cubestack-addon/lws/
├── manifests.yaml               # ★ 官方 v0.10.0 单文件 bundle(默认安装源, 2.86MB)
│                                #   含 namespace lws-system + 3 CRD + RBAC + controller + webhook
│                                #   (控制器自签证书=internal; 含 DisaggregatedSet)。离线 vendoring。
├── CUBESTACK.md                 # 本文件(项目适配说明)
└── charts/                      # 官方 Helm Chart(完整发布包, helm 方式 / cert-manager 模式用)
    ├── Chart.yaml               # version: v0.10.0, appVersion: v0.10.0
    ├── values.yaml              # 官方可配置项(enableCertManager / enableDisaggregatedSet / image.manager.*)
    ├── crds/                    # 官方完整 CRD(leaderworkersets / disaggregatedsets / disaggregatedsetrolescalers)
    ├── templates/               # 官方模板(certmanager / manager / rbac / webhook / prometheus)
    ├── lws-chart-v0.10.0.tgz    # 官方发布包(helm install 直接用 tgz)
    ├── .helmignore              # 含 crds/(CRD 过大, 不进 helm release Secret, 由 kubectl 单独 apply)
    └── README.md                # 官方 README(官方安装/配置说明)
```

## 安装方式(双模式, `LWS_INSTALL_MODE`)

| 模式 | 机制 | 适用 | 命令/配置 |
|---|---|---|---|
| **bundle**(默认, 推荐) | 官方 `manifests.yaml` 单文件, `kubectl apply --server-side` 整体下发; 逐资源应用不受 helm release Secret 1MiB 上限 | 离线、internal 证书、求简; 官方推荐 | `LWS_INSTALL_MODE=bundle`(默认)+ `LWS_MANIFEST=.../lws/manifests.yaml` |
| **helm** | 本地 chart `charts/`; CRD 超大 → `charts/.helmignore` 排除, CRD 由 kubectl 逐文件 apply | cert-manager 模式 / 自定义 values | `LWS_INSTALL_MODE=helm` + `LWS_CERT_MODE=internal\|cert-manager` + `LWS_CHART_SOURCE=dir\|tgz\|oci` |

> 注意: `LWS_CERT_MODE=cert-manager` 时自动切到 helm(bundle 固定 internal, 无 cert-manager)。
> bundle 方式已含 DisaggregatedSet(默认 true); helm 方式由 `enableDisaggregatedSet` values 控制。

### helm 方式的 chart 源(`LWS_CHART_SOURCE`, 仅 helm 模式)

| 源 | 配置 | 说明 |
|---|---|---|
| **dir**(默认) | `LWS_CHART_DIR=deployments/cubestack-addon/lws/charts` | 本地解包目录, 离线友好 |
| **tgz** | `LWS_CHART_TGZ=.../lws/charts/lws-chart-v0.10.0.tgz` | 本地发布包 |
| **oci** | `LWS_CHART_OCI=oci://registry.k8s.io/lws/charts/lws` + `LWS_CHART_VERSION` | 官方 OCI, 需联网 |

## 关键 values(helm 方式, 由部署脚本注入, 也可手工 --set)

| values 键 | 默认 | 说明 |
|---|---|---|
| `enableCertManager` | `false` | `false`=controller 内置证书(internal); `true`=外部 cert-manager |
| `enableDisaggregatedSet` | `false` | `true`=安装 DisaggregatedSet editor/viewer/admin 角色 + 校验 webhook |
| `image.manager.repository` | `registry.k8s.io/lws/lws` | controller 镜像仓库(离线改集群内置 registry) |
| `image.manager.tag` | `v0.10.0` | 镜像 tag |
| `image.manager.pullPolicy` | `IfNotPresent` | 镜像拉取策略 |

## 项目集成

- 部署脚本: `modules/03_addon/05_gpu_lws.sh`(`--steps gpu_lws` 立即部署; `LWS_ENABLED=true` 随全量)
- 证书模式: `LWS_CERT_MODE=internal|cert-manager`(默认 internal; cert-manager 需 helm 模式 + 集群已装 cert-manager)
- 端到端验证: `--steps verify_lws`(见 `modules/03_addon/24_verify_lws.sh`)
- 使用文档: `docs/lws.md`; 故障排查: `docs/troubleshooting.md` §三.4

## 升级到新版本

1. **bundle(默认)**: 联网机下载官方 manifests.yaml 替换本目录(保留 CUBESTACK.md):
   ```bash
   VERSION=<新版>
   curl -fL -o deployments/cubestack-addon/lws/manifests.yaml \
       "https://github.com/kubernetes-sigs/lws/releases/download/${VERSION}/manifests.yaml"
   # 同时更新 cluster.conf: LWS_CHART_VERSION / LWS_IMAGE_TAG
   ```
2. **helm chart(charts/)**: 同步替换官方发布包:
   ```bash
   helm pull oci://registry.k8s.io/lws/charts/lws --version <新版> --untar --untardir /tmp
   cp -r /tmp/lws/* deployments/cubestack-addon/lws/charts/   # 保留 .helmignore(含 crds/)
   ```
