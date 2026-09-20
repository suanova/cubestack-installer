# Perses 云原生看板(CubeStack 部署说明)

> 对应模块: `deployments/scripts/modules/03_addon/18_perses.sh`(安装) +
> `34_verify_perses.sh`(验证) · 开关 `PERSES_ENABLED`(**默认 true**)
>
> 需求来源: `docs/cluster-components-plan.md` P1-3「部署 kube-state-metrics、Perses 可视化组件」。
> 本仓库的选择是**在 Prometheus 之外并存新增 Perses**,Grafana 与既有 11 个看板完全不动 ——
> 两者共用同一个 Prometheus,互不干扰。

## 1. 它是什么

Perses 是 CNCF 的云原生看板/可视化平台,来自 Prometheus 生态。相对 Grafana 的特点:

- 看板与数据源都是**声明式 YAML 资源**(Dashboard / Datasource / GlobalDatasource / Project),
  可 GitOps 管理,而不是存在应用数据库里的 JSON blob;
- 原生面向 Prometheus 数据模型(没有"插件市场"那层包袱);
- 本仓库只把它作为**新增的可视化入口**,不承担替换 Grafana 的职责。

## 2. 制品流向(与 cubepilot / bmc-exporter 同构)

```
上游 docker.io/persesdev/perses:v0.54.0
   │  CI: .github/workflows/sync-images-to-harbor.yml → tools/images/harbor-sync-images.sh
   ▼
harbor.isuanova.com/mirrors/docker.io/persesdev/perses:v0.54.0
   │  ① online 模式: 部署时拉到本地 tar(<tar>.digest 边车比对, 未变则跳过下载)
   ▼
deployments/offline-files/perses/persesdev_perses_v0.54.0.tar
   │  ② 模块推入集群内置 registry(skopeo 直连端点)
   ▼
registry.cubestack.io:5000/persesdev/perses:v0.54.0
   │  helm --set-string image.registry / image.name
   ▼
集群节点(只认内置 registry,零凭据、零公网)

chart: deployments/cubestack-addon/perses/perses-0.23.2.tgz   ← **vendored,随 git 分发**
       online 时先拿远端 digest 与 .digest 边车比对;有更新才覆盖,拉取失败直接回退本地
```

**两种模式(online / offline)的部署路径是同一段代码**,差别只在开头要不要联网同步制品。

### 为什么 chart 必须 vendored

模块**安装时恒用仓库里那份离线副本**,online 只负责"比对后决定要不要刷新"。这是全仓库的统一约定
(见 `docs/scripts-development-spec.md` §2.4)。理由很直接:`31_cubepilot` / `33_bmc_exporter`
原本就有"拉取失败回退本地 chart"的代码,但仓库里**根本没有那份文件**,所以私服一抖动回退就是空转。
Perses 从一开始就把副本放进仓库。

刷新 chart:

```bash
./deployments/scripts/tools/images/perses-fetch-charts.sh                 # 默认 0.23.2
PERSES_CHART_VERSION=0.24.0 ./deployments/scripts/tools/images/perses-fetch-charts.sh
```

该脚本会同时写出 `<tgz>.digest` 边车。**改完记得提交** —— 不提交等于没刷新。

刷新镜像(联网机,读 images.manifest):

```bash
./deployments/scripts/tools/images/harbor-save-images.sh --group perses
```

## 3. 部署

```bash
# 默认: 全量部署时会自动安装(因为 PERSES_ENABLED 默认 true)
sudo ./deploy-cluster.sh

# 或单独装(只跑 perses + 其硬依赖 k8s_registry)
sudo ./deploy-cluster.sh --steps perses

# 验证(含数据面)
sudo ./deploy-cluster.sh --steps verify_perses
```

## 4. 安装后是什么形态

| 项 | 值 | 说明 |
|---|---|---|
| 工作负载 | **StatefulSet** `perses` | chart 在 `config.database.file` 下渲染 StatefulSet;设 `config.database.sql` 才是 Deployment |
| 持久化 | PVC `perses`,`8Gi` @ 自动派生 SC | ceph 体系 → `ceph-block`;否则用集群默认 SC |
| 数据源 | `GlobalDatasource/prometheus` | 由 sidecar 从带标签的 ConfigMap 自动供给 |
| 自监控 | ServiceMonitor | 集群 Prometheus 是 `serviceMonitorSelector: {}` 全选,无需额外标签 |
| 入口 | ClusterIP(默认) | 见下节 |

`config.provisioning.interval` 被收到 **1m**(上游默认 10m)—— 否则装完要干等十分钟才出现数据源。

### 访问

```bash
kubectl -n perses port-forward svc/perses 8080:8080     # http://127.0.0.1:8080
```

需要集群外直达时设 `PERSES_EXPOSE_MODE=nodeport`(NodePort 基址 `PERSES_NODEPORT_BASE`,默认 **31010**,
避开 Prometheus 的 31000/31001)或 `loadbalancer`。

> ⚠ 按 2026-09-18 定案,本模块**不创建 Gateway / HTTPRoute / Ingress** —— chart 自带的
> `gateway.enabled` / `ingress.enabled` 被显式置 false。对外路由应由**专门的网关模块**统一下发。

## 5. 数据源为什么走代理而不是 directUrl

生成的 `GlobalDatasource` 是:

```yaml
kind: GlobalDatasource
metadata:
  name: prometheus
spec:
  default: true
  plugin:
    kind: PrometheusDatasource
    spec:
      proxy:
        kind: HTTPProxy
        spec:
          url: http://<prometheus-svc>.<ns>.svc.cluster.local:9090
```

**故意不设 `directUrl`**。设了它,浏览器就必须能直连 Prometheus —— 而 port-forward 场景下
`*.svc.cluster.local` 在浏览器侧解析不了,UI 必然报错。走 `proxy` 则查询由 Perses 服务端转发,
访客只要能访问 Perses 自身就行。

Prometheus 地址默认**自动发现**(在该命名空间里找名字含 `prometheus`、非 headless、带 9090 端口的
Service)—— 不硬编码服务名,因为它由 release 名 + chart 规则派生(kube-prometheus-stack 会截断)。
需要时用 `PERSES_PROMETHEUS_URL` 显式覆盖。

## 6. 验证边界(如实标注)

`verify_perses` 断言:

1. helm release `deployed`
2. 工作负载(StatefulSet/Deployment,按实际发现)全部 Ready
3. Service 有 Ready Endpoints
4. `GET /api/v1/health` 返回 200;UI 根路径可达
5. `GET /api/v1/globaldatasources` 中存在 `prometheus`
6. **`GET /proxy/globaldatasources/prometheus/api/v1/query?query=count(up)` 取回真实数据点**

第 6 条是这条链的价值所在:它一次性证明 **Perses → Prometheus 的 DNS / 端口 / 数据源 URL / proxy 配置**
整条链路通,且 Prometheus 里确实有指标。只探 HTTP 状态码是证明不了这些的。

**未覆盖**:看板本身(默认不预置任何 dashboard)。要断言看板需先另行 provision。

**软依赖**:Prometheus 未部署时,第 5/6 条会 `warn` 并明确标注"数据面验证未覆盖",
而不是报一个看不懂的断言失败 —— 安装模块与验证模块在这点上语义一致。

## 7. 常见问题

**Q: 装完 UI 里一个数据源都没有**
逐层查:
```bash
kubectl -n perses get cm -l perses.dev/resource=true                 # ① ConfigMap 在不在
kubectl -n perses logs statefulset/perses -c perses-provisioning-sidecar   # ② sidecar 有没有写进去
kubectl -n perses exec perses-0 -- ls /etc/perses/provisioning       # ③ 文件到没到 Perses 侧
```
②失败通常是 RBAC(`allNamespaces: true` 需要 ClusterRole,chart 会自建)或 ConfigMap 缺标签。

**Q: PVC 一直 Pending**
`persistence.storageClass` 留空且集群没有默认 StorageClass 时会这样。本模块在 ceph 体系下自动传
`ceph-block`;纯 local-path 集群请确认 `LOCAL_PATH_ENABLED=true` 或显式设 `PERSES_STORAGE_CLASS`。

**Q: 重启后看板全没了**
`persistence.enabled` 被置成 false 了 —— chart 此时用 `emptyDir`,Pod 重建即丢。本模块恒置 true,
但若手工改过 values 请改回。

**Q: 数据面断言 5/6 失败,日志显示代理 502/404**
数据源的 `url` 指向的 Prometheus 不可达,或数据源压根没加载。先按上面 Q1 三层查,再确认
`PERSES_PROMETHEUS_URL` 是否能从 Perses Pod 里 curl 通。

**Q: 卸载后数据还在吗**
`helm uninstall` **不会**删 PVC。要彻底清干净:
```bash
helm uninstall perses -n perses
kubectl -n perses delete pvc perses
```

## 8. 已知上游 chart 问题(不是本模块引入的)

**`statefulset.yaml` 引用了一个从不创建的 Service。** chart 的 StatefulSet 写了
`spec.serviceName: perses-headless`,但 templates 里**没有任何地方创建这个名字的 Service**
(只有 `service.yaml` 创建的 `perses`)。

实测影响面 = 0:

- StatefulSet 的 governing service 只用于 Pod 的稳定 DNS(`perses-0.<svc>.…`);Perses 单副本,
  对外一律走 `svc/perses`,那条 DNS 没有任何地方用到;
- `kubectl rollout status statefulset/perses` 看的是 `.status`,不查这个 Service,照常工作;
- `verify_perses` 选 Service 时会跳过 `*headless`/`*-external` 名字,不受影响。

上游升版后若补上了这个 Service,无需改动本仓库任何东西。**别为此手工去建它** —— 建了反而会在
升级时造成归属混乱(它不在 helm 的 release 清单里)。

