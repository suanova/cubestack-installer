# CubeStack Operator 部署(25_cubestack_operator)

> 组件: **CubeStack 平台 Operator**(一个 CR `CubeStackCluster` 描述整个平台, operator 按组件目录把
> 各组件渲染并 apply 进集群, 管理健康与卸载)。
> 上游: <https://github.com/suanova/cubestack-operator>(私有) · chart:
> `oci://harbor.isuanova.com/suanova-private/cubestack-operator-chart`
> 模块: `deployments/scripts/modules/03_addon/25_cubestack_operator.sh`(部署)
> + `26_verify_cubestack_operator.sh`(端到端验证)
> 开关: `CUBESTACK_OPERATOR_ENABLED`(**默认 true**, 2026-10-08 起) · 用法: `--steps cubestack_operator` / `--steps verify_cubestack_operator`

本文既是**设计说明**(为什么这么做), 也是**操作手册**(怎么做)。文中标注实测/未实测的部分。

---

## 1. 它是什么、本模块管到哪里

operator 自己用一个 `CubeStackCluster` CR 描述"平台要装哪些组件"(lws / envoy-gateway / ai-gateway /
prometheus / perses / cuberouter / cubepilot / portal / observability / model-bundles…),
然后按 catalog 顺序逐个渲染 chart → SSA apply → 健康检查。**operator 不管自己** —— 它由独立的
helm chart 安装, 也就是本模块做的事。

```
本模块的边界(#): 只在 # 里的部分
────────────────────────────────────────────────────────────
  Harbor(suanova-private)                    K8s 集群
  ┌──────────────────────┐                  ┌──────────────────────────────┐
  │ cubestack-operator-  │  ①helm pull      │  registry.cubestack.io:5000  │
  │ chart(1.0.0-latest)  ├─────────────┐    │  (集群内置 registry)          │
  │                      │             │    │      ▲                       │
  │ cubestack-operator   │  ③镜像推入   │    │      │ ④节点从这里拉          │
  │ :latest(镜像)        ├─────────────┼───▶│  suanova-private/            │
  └──────────────────────┘             │    │      cubestack-operator:latest│
                                       │    │      │                       │
  # ① chart 落 vendored 副本(离线用)    │    │      ▼                       │
  # ② helm template 渲染 → 提取镜像清单 ─┘    │  # ⑤ operator Deployment      │
  # ③ 推镜像进集群 registry                   │    (cubestack-system)        │
  # ④ 节点只从集群 registry 拉                │      │                       │
  # ⑤ 恒用本地 chart 安装                     │      ▼                       │
                                            │  CubeStackCluster CR → 平台组件│
                                            │  (★ 不在本模块范围内, 默认不装) │
                                            └──────────────────────────────┘
```

**范围更新(2026-10-08)**: `clusterCR.enabled=true` 时, 平台组件(lws/envoy-gateway/prometheus/perses/
cuberouter/cubepilot/portal/observability…)的**离线镜像链路已由本模块承接**(见 §3.4b):
模块把 `offline-files/cubestack-operator/` 的全部组件 tar 推入集群内置 registry, 并把 CR 的
全局镜像源(imageRegistry / externalImageRegistryPrefix)注入为集群 registry —— 节点不访问 Harbor。
默认裁剪(可经 `CUBESTACK_OPERATOR_CR_VALUES_FILE` 覆盖): 模型 bundles 清空 + modelBundles/bmc 关闭。

---

## 2. chart 分析(实测结论, 不是推测)

`helm pull oci://harbor.isuanova.com/suanova-private/cubestack-operator-chart --version 1.0.0-latest`
拿到 9.2 KB 的 chart, `helm template` 实测:

| 渲染出的对象 | 说明 |
|---|---|
| `Deployment/cubestack-operator` | operator 本体(replicas=1; `--leader-elect`, 可热备) |
| `ServiceAccount` + `ClusterRole` + `ClusterRoleBinding` | RBAC(ClusterRole 含 `apiGroups:["*"]` 全量动词, 上游设计文档 §6.7 已接受) |
| `crds/…cubestackclusters.yaml` | CRD `cubestackclusters.operator.cubestack.io`(短名 `csc`, **29 KB** → 无 helm Secret 1MiB 问题, 可以走 helm) |
| `Service`(metrics) | `service.enabled=false` 默认关 |
| `CubeStackCluster` | `clusterCR.enabled=false` 默认关 |

**镜像只有一个**(`templates/manager.yaml`):

```
image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
     = harbor.isuanova.com/suanova-private/cubestack-operator:latest
```

它是**多架构 OCI index**(Harbor 上 amd64 条目 = `sha256:2c3f026c…`), 但我们**按单架构推**
(与本仓库其它组件一致, 省掉 arm64 那份存储)。

**chart 版本形态**: `version: 1.0.0-latest`, `appVersion: latest` —— 滚动版本, 与滚动镜像配套。
这意味着**不能**把它当成一次性安装: 每次部署都可能是"新 chart + 新镜像"。

---

## 3. 设计(需求 → 落地)

### 3.1 离线 / 在线(需求 1)

`CUBESTACK_OPERATOR_CHART_SYNC=auto|online|offline`(默认 **auto**):

| 模式 | 行为 |
|---|---|
| `auto` | 探测 `https://harbor.isuanova.com/v2/` 可达(HTTP 非 000) → 走 online; 否则走 offline。**离线机不会发起任何 chart 拉取**(只多一次 6 秒超时的探测) |
| `online` | 尝试 `helm pull` 比对 digest(见 3.3); 拉取失败**降级回退本地副本**(告警不中断) |
| `offline` | 完全不联网; 直接校验本地副本存在性 |

镜像侧同理: `CUBESTACK_OPERATOR_IMAGE_SOURCE=auto|harbor|tar|docker`(默认 auto =
在线优先 Harbor → 离线 tar → 本地 docker daemon)。

### 3.2 chart 落位(需求 2)

```
deployments/cubestack-addon/cubestack-operator/
├── cubestack-operator-chart-1.0.0-latest.tgz          # 随 git 分发的离线副本
├── cubestack-operator-chart-1.0.0-latest.tgz.digest   # Digest 边车(helm 报告的 "Digest:" 行)
└── CUBESTACK.md
```

**安装恒用这份本地副本**(`helm upgrade --install <本地 tgz>`), 线上拉到的东西不直接装 ——
与 `docs/scripts-development-spec.md` §2.4 的全仓约定一致。`check-modules.sh` 第 ⑩ 项强制校验。

### 3.3 在线时每次刷新 chart(需求 3)

复用共享助手 `helm_chart_ensure`(lib-common.sh):

```
online: helm pull → 取远端 "Digest:" 与 .digest 边车比对
          相同   → 丢弃刚拉的文件, 继续用本地副本(仓库保持干净)
          不同   → 覆盖本地副本 + 更新边车 + 提示 git add/commit 固化
          拉取失败 → 回退本地副本(告警, 不中断部署)
offline: 不联网, 直接用本地副本
```

⚠ 两个实测坑(写进代码注释与 CUBESTACK.md):

1. **`.digest` 的值必须是 helm 报告的 `Digest:` 行**。对 OCI chart 它是 **manifest 摘要**
   (`sha256:06f0318d…`), **不是** tgz 文件的 sha256(`sha256:c8e94925…`)。自己 `sha256sum` 算出来的
   值永远比不相等 → 每次都误判"远端有更新"并覆盖仓库文件。
2. 私有项目要凭据: 模块用 `helm registry login … --password-stdin`(密码不进 ps)。
   无凭据时 `helm pull` 401 → 自动回退本地副本(部署不受影响)。

### 3.4 镜像: 动态提取 → tar → 集群 registry(需求 4)

镜像清单**不写死**, 部署时从 chart 渲染结果里提取:

```bash
helm template <release> <本地tgz> -n <ns> | sed -n 's/^[[:space:]]*image:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' | sort -u
```

> 为什么动态提取而不是列一份静态清单: 滚动 chart 哪天加了第 2 个镜像(例如 sidecar),
> 静态清单会**静默漏掉**它, 表现为离线集群里那个容器 `ImagePullBackOff`。动态提取 + 渲染自检
> (见 3.5)能在部署当场响亮失败。

镜像搬运路径(离线机):

```
Harbor(suanova-private) ──harbor-save-images.sh --group cubestack-operator──▶
  deployments/offline-files/cubestack-operator/<上游ref>.tar ──模块──▶ 集群内置 registry
```

- 登记: `deployments/config/images.manifest` 的 `cubestack-operator` 组(tag 写
  `${CUBESTACK_OPERATOR_IMAGE_TAG}`, 升级只改 cluster.conf 一处)
- 离线目录: `deployments/offline-files/cubestack-operator/`(+README; tar 不入库)
- ⚠ 该组**不镜像到 `mirrors/`**(上游就是本台 Harbor 的私有项目, 与 metax-gpu 同一处理)。
  为此给 `harbor-save-images.sh` 补了同源分支: 同源组**直接用原始 ref** 拉(skip 的
  `mirrors/<路径>` 那副本本来就不存在)。

### 3.4b 平台组件镜像推送 + CR 全局注入(2026-10-08 实机落地, CR 模式)

`clusterCR.enabled=true` 时, [4b/6] 把 `offline-files/cubestack-operator/` 下**全部 tar** 推入集群
registry(幂等 digest 比对), 目标路径与 [3/6] 注入的两条前缀**一一对应**:

| tar 内镜像 | registry 目标路径 | CR 侧字段 |
|---|---|---|
| `harbor.isuanova.com/suanova/<name>:tag`(自研) | `<REG>/suanova/<name>:tag` | `spec.global.imageRegistry` |
| `<上游ref>`(docker.io/quay.io/ghcr.io/registry.k8s.io…) | `<REG>/mirrors/<上游ref>` | `spec.global.externalImageRegistryPrefix` |

- **目标 ref 以 tar 文件名为权威**(文件名 = 上游 ref 的 `/`/`:` → `_`), tar 内 RepoTags 仅作尾部校验
  —— 早期 tar 的 RepoTags 可能是短式(缺 docker.io 域), 按它推会与节点拉取路径不一致(实机 not found)。
- 组件镜像集与 operator 镜像内 `assets/charts` 的**渲染对账**而来(36 个 tar): 见
  `offline-files/cubestack-operator/README.md`(含清单来源与维护方法)。
- **默认裁剪**(`CUBESTACK_OPERATOR_CR_VALUES_FILE` 可覆盖): `spec.bundles=[]` + modelBundles 关
  (模型推理 Pod/GPU 需求, 非平台服务必需)+ bmc 关(需管理员先建 `cubestack-bmc-credentials` Secret)。
- **imagePullSecrets 注入为空**: 集群 registry 匿名可拉; 留默认值(harbor-credentials)而 Secret
  不存在会让所有组件 ImagePullBackOff。
- **已知缺口**: `docker.io/envoyproxy/ratelimit:8fe6ea42`(EG 的 RateLimit 配置值, 非默认拉起;
  本网络到 docker.io 不通)。补料: 在可访问 docker.io 的机器 pull/save 后放入 offline-files。

**实机验证(2026-10-08)**: 全链路(推 36 镜像 → CR → 9 组件调谐)一次通过, `CR Ready=True`
(lws/envoy-gateway/controller-manager/prometheus/perses/cuberouter/cubepilot/portal/observability
全部 Ready, monitoring 13 pod / cuberouter 家族含 cnpg-postgres 全 Running)。

**环境前提(踩坑记录)**: 本集群**无外部 DNS**(节点到公共/网关 UDP 53 不可达)。kubespray 的
`upstream_dns_servers` 为空时 nodelocaldns 渲染 `forward . /etc/resolv.conf` ⇒
nodelocaldns → resolv(stub) → systemd-resolved → 169.254.25.10(nodelocaldns 自己)**回环** ⇒
coredns loop 插件 FATAL 自杀(kube-system coredns CrashLoopBackOff, cluster 域解析全断)。
已修: `sync-kubespray-config.sh` 写 `upstream_dns_servers: [127.0.0.1]`(cluster.conf 的
`UPSTREAM_DNS_SERVERS` 可改; 接入真实 DNS 时改之); 外部域名解析维持失败(与无上游语义一致)。

### 3.5 安装: 本地 chart + 集群 registry 镜像(需求 5)

```bash
helm upgrade --install cubestack-operator <本地tgz> -n cubestack-system --create-namespace \
  --set image.repository=<REGISTRY_DOMAIN>:<port>/suanova-private/cubestack-operator \
  --set image.tag=latest --set image.pullPolicy=Always \
  --set podAnnotations.cubestack\.io/image-digest=<刚推入镜像的 digest> ...
```

**渲染自检**: 覆盖后再渲染一次, 逐个断言镜像 ref 落在 `${REG_BASE}/` 之下; 有漏网的就 `err` 退出
(而不是静默从 Harbor 拉, 让离线集群 ImagePullBackOff)。

**CRD 预应用**: helm 只在"CRD 不存在"时装 `crds/`, 升级时旧 CRD 会剪掉新字段(上游 README 明确
提醒)。模块每次部署都先 `kubectl apply --server-side --force-conflicts -f <chart>/crds/*.yaml`,
所以不需要人工记住这条。

### 3.6 滚动 `:latest` 的三个坑(本模块的设计核心)

| 坑 | 表现 | 处理 |
|---|---|---|
| **节点缓存冻结** | 镜像 ref 恒为 `:latest`, `IfNotPresent` 下 kubelet 认为"有缓存"→ 永远跑旧镜像 | 默认 `image.pullPolicy=Always`(与上游 README 对滚动构建的建议一致) |
| **不滚动** | 镜像内容变了但 Deployment spec 没变 → ReplicaSet 不变 → 新镜像永远不会被拉起来 | 把刚推入镜像的 **digest** 写进 `podAnnotations` → 内容变则模板变 → 自动滚动 |
| **误判"没变"** | `latest` 这种 tag "存在即跳过"的幂等判据会永远跳过推送 | 幂等判据用 **digest 比对**(`_digest()` 解析 `skopeo inspect --raw`: index 取 amd64 条目 / 单架构取清单字节 sha256), 取不到就**保守重推** |

> `REPEAT: 1`(每次执行)也是为此: 安装类模块通常用 `REPEAT: 0` 断点跳过, 但那样会让本模块
> 永远停在首次拉到的 chart/镜像版本。

### 3.7 端到端验证(`26_verify_cubestack_operator.sh`)

| 步 | 断言 | 为什么 |
|---|---|---|
| ① | operator Deployment Ready / CRD 已注册 | 基本盘 |
| ② | **pod 的 `image` 前缀 = 集群内置 registry** | 直接证据: 节点不访问 Harbor(离线前提成立)。"pod Running" 区分不了这件事 |
| ③ | 建冒烟 `CubeStackCluster`(全组件禁用) → `status.conditions[Ready]=True` | 验证 operator 的**真实调和链路**(watch → 渲染 → apply → status), 而不是只看 pod 活着。CRD 文档: 无启用组件时 Ready 平凡为 True, 故秒级 |
| ④ | 无 `Degraded` 组件 + 清理 CR(trap 兜底) | 不留垃圾 |

---

## 4. 操作

```bash
# 部署(自动带基座; 只在指定模块)
sudo ./deploy-cluster.sh --steps cubestack_operator
# 端到端验证
sudo ./deploy-cluster.sh --steps verify_cubestack_operator
# 预启用(写 cluster.conf, 下次全量部署生效)
sudo ./deploy-cluster.sh --enable cubestack_operator
```

**离线备料(联网机)**:

```bash
# cluster.conf 设 CUBESTACK_OPERATOR_HARBOR_USER/PASSWORD(或 HARBOR_MIRROR_USER/PASSWORD)
sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group cubestack-operator --force
# 把 offline-files/ 拷到部署机(见 docs/offline-readiness.md / tools/offline/)
```

**状态**:

```bash
kubectl get csc -n cubestack-system                       # 平台实例(本模块默认不建)
kubectl -n cubestack-system get deploy,pods -o wide       # operator 自身
kubectl -n cubestack-system logs deploy/cubestack-operator
```

---

## 5. 边界与未验证项(如实标注)

- **operator 本体 + CR 平台组件 已于 2026-10-08 实机端到端验证**(在线 / 离线两路; 见 §3.4b);
  在线模式(chart 刷新 + Harbor 拉镜像)与离线模式(chart 本地副本 + tar 源)均实机通过。
- **凭据**: 拉 `suanova-private` 需要账号(2FA 账号请用「CLI Secret」)。凭据只用于**在线刷新
  chart / 在线拉镜像 / 备料 save**, 部署路径本身(本地 chart + 集群 registry)不需要。
- **平台实例(CR)**: `CUBESTACK_OPERATOR_CLUSTER_CR_ENABLED=true` 时默认裁剪模型 bundles 与
  bmc(见 §3.4b); 开启项经 `CUBESTACK_OPERATOR_CR_VALUES_FILE` 覆盖。
- **多镜像扩展**: chart 若新增镜像, `[6/6]` 的渲染自检会报"未覆盖"并要求在本模块补 `--set`。
- **chart 分发**: cubestack-operator 滚动 chart 暂不入 git(构建上下文进 CLI 镜像 + 部署机本地保留;
  check-modules ⑩ 有 gitignore 豁免); 干净 checkout 属预期缺省。

## 6. 故障排查

| 症状 | 根因 / 处理 |
|---|---|
| `[1/6]` 报"离线 chart 缺失" | vendored 副本不在(没提交/被删)。`helm pull` 拉一份放进 `cubestack-addon/cubestack-operator/` 并提交 |
| 每次部署都告警"远端有更新"并覆盖本地副本 | `.digest` 边车值不对(常见: 自己 `sha256sum` 算的)。重取 helm pull 输出的 `Digest:` 行 |
| `[4/6]` 报"可用源都不成立" | 离线机没 tar / 没凭据 / Harbor 不可达。跑 save 工具, 或配凭据 |
| pod `ImagePullBackOff` 且 image 还是 `harbor.isuanova.com/...` | 有人手工 `helm install` 绕过了本模块(没走 `--set image.repository`)。用 `--steps cubestack_operator` 重装 |
| 部署成功但跑的还是旧镜像 | 节点缓存: 确认 `image.pullPolicy=Always` 且 digest 注解在位(`kubectl -n cubestack-system get deploy cubestack-operator -o jsonpath='{.spec.template.metadata.annotations}'`) |
| CR 卡在 finalizer | operator 没在跑(删 CR 前先确认 operator Deployment Ready), 或手工 `kubectl patch csc <name> --type=merge -p '{"metadata":{"finalizers":null}}'` |
