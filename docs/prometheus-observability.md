# CubeStack 可观测性落地(installer 侧)

> **一句话**: 把 cubestack 源仓库 `observability/` 定义的可观测性落地到安装环境 ——
> kube-prometheus-stack 的**专属 values**、6 个 **recording rule**、11 个 **Grafana dashboard**、
> MetaX **mx-exporter**、BMC **带外监控 exporter**。需求源是
> `suanova/cubestack` 的 `observability/docs/installer-requirements.md`。

对应实现:
| 位置 | 内容 |
|---|---|
| `modules/03_addon/08_prometheus.sh` | values(§1) + recording rules(§2) + dashboards(§3) + mx-exporter(§7.1) |
| `modules/03_addon/33_bmc_exporter.sh` | BMC 带外监控(§7.2) |
| `modules/03_addon/06_gpu_operator.sh` | 一行 helm value: 打开 metax `dataExporter`(§7.1 的另一半) |
| `modules/03_addon/28_verify_prometheus.sh` | ⑥⑦⑧ 段: 规则真的加载 / 看板真的导入 / 各 exporter 真的被采集 |
| `cubestack-addon/observability/cubestack/` | recording rules + dashboards 的 vendored 副本 |
| `tools/observability/fetch-observability-assets.sh` | 从源仓库刷新上面的副本 |
| `tools/images/bmc-save-images.sh` | BMC 两个镜像的离线备料 |

---

## 1. 需求 → 实现对照

| 需求(installer-requirements) | 实现 | 备注 |
|---|---|---|
| §1.1 KSM label allowlist | values `kube-state-metrics.extraArgs` | ⚠ 值里含**逗号**, 不能用 `--set`(见 §2.1) |
| §1.2 4 组 Prometheus selector | values `prometheus.prometheusSpec.*` | ⚠ 两处与文档原文**不同**, 见 §2.2 / §2.3 |
| §1.3 node-exporter IB + node label | values `prometheus-node-exporter.*` | ⚠ 数组是**整体替换**, 见 §2.4 |
| §1.4 scrape/evaluation interval | values, 由 `PROMETHEUS_*_INTERVAL` 控制 | 默认 30s / 60s |
| §2 recording rules | 模块第 5 步 apply + 补 `release` 标签 | namespace 重写见 §2.5 |
| §3 Grafana dashboard | 模块第 6 步: 每看板一个 ConfigMap | 走 sidecar, 不用 Grafana API |
| §4 Grafana 口令 | 模块第 1 步**硬失败校验** + 临时 values 文件 | 口令不进 argv |
| §5 离线打包目录 | 三级回退: 变量 > `/opt/cubestack/observability` > 仓库内 vendored | 实际用了哪个会打印出来 |
| §7.1 MetaX mx-exporter | 06 传 `dataExporter.deploy=true` + 08 建 ServiceMonitor | 见 §4 |
| §7.2 BMC exporter | 独立模块 33, 与 cubepilot 同构 online/offline | 见 §5 |

---

## 2. ⚠ 四个会导致**静默失效**的陷阱

这一节是本文件存在的主要理由。下面每一条都是**实测出来的**, 且共同特征是
**不报错、不失败, 只是功能不生效** —— 事后排查成本极高。

### 2.1 `--set` 会切断含逗号的 allowlist 值

KSM 的 allowlist 值是 `pods=[a,b,c],statefulsets=[d]` —— **逗号既是值的分隔符,
也是 `--set` 的键分隔符**。写成 `--set kube-state-metrics.extraArgs[0]=pods=[a,b,c],...`
会被切成多个畸形键, 结果是 allowlist 静默为空, 所有 `kube_pod_labels` join 失效。

**做法**: 所有 CubeStack values 走**临时 values 文件**(`mktemp` + `umask 077`), 不用 `--set`。
顺带的好处: `helm template -f <该文件>` 可以离线断言渲染结果(见 §6)。

### 2.2 `ruleSelector` 按文档原文写会**丢掉 chart 自己的 40+ 组默认规则**

`installer-requirements` §1.2 写的是:

```yaml
ruleSelector:
  matchLabels:
    app.kubernetes.io/part-of: cubestack-observability
```

但 kube-prometheus-stack **自带的** PrometheusRule 带的是
`release: <release名>` + `app.kubernetes.io/part-of: kube-prometheus-stack`
(见 chart 的 `templates/_helpers.tpl`, `kube-prometheus-stack.labels` 定义, 其中
`release: {{ $.Release.Name }}`)。

按上面那样写, 选择器**只认 cubestack-observability** → `k8s.rules` / `node.rules` /
`kubernetes-apps` 等**全部默认规则一起不加载**, 且没有任何报错。

**做法**: 用 `matchExpressions` 取**并集**:

```yaml
ruleSelector:
  matchExpressions:
    - key: app.kubernetes.io/part-of
      operator: In
      values: [cubestack-observability, kube-prometheus-stack]
```

实测(2026-09-20, chart 90.0.0): chart 自带 **35 个** PrometheusRule 全部带
`part-of: kube-prometheus-stack`, 因此并集选择器两边都能选中。

### 2.3 写 `{}` 并不等于"全选"

chart 的 `prometheus.yaml` 模板逻辑是:

```
{{- if .Values.prometheus.prometheusSpec.ruleSelector }}       ← 非空才用你写的
{{- else if ...ruleSelectorNilUsesHelmValues }}                ← 默认 true
  ruleSelector:
    matchLabels:
      release: <release名>                                     ← 你的 {} 被改写成这个
{{- else }}   ruleSelector: {}                                 ← 只有这个分支才是真"全选"
```

`ruleSelectorNilUsesHelmValues` 默认 `true`, 所以 values 里写 `serviceMonitorSelector: {}`
**仍会被渲染成 `release: <release名>`** —— 跨 namespace 的 ServiceMonitor
(如 metax-operator 的 mx-exporter)会全部丢。

**做法**: 想要"全选"必须**同时**把对应的 `*NilUsesHelmValues` 显式置 `false`:

| selector | 值 | 配套开关 |
|---|---|---|
| `serviceMonitorSelector` | `{}` | `serviceMonitorSelectorNilUsesHelmValues: false` |
| `ruleSelector` | 见 §2.2 | `ruleSelectorNilUsesHelmValues: false` |
| `scrapeConfigSelector` | 见 §2.2 | `scrapeConfigSelectorNilUsesHelmValues: false` |

(实机验证: 改造前 `kubectl get prometheus -o jsonpath='{.spec.ruleSelector}'` 输出
`{"matchLabels":{"release":"kube-prometheus"}}` —— 就是这条把 `{}` 改写掉的。)

### 2.4 node-exporter 的 `extraArgs` 是**整体替换**, 不是追加

chart 默认 `prometheus-node-exporter.extraArgs` 有**两条** filesystem 过滤:

- `--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|run/containerd/.+|...)...`
- `--collector.filesystem.fs-types-exclude=^(autofs|binfmt_misc|...)$`

Helm 对 **list 是整体替换**(不是合并)。只写 `extraArgs: [--collector.infiniband]`
会把这两条**一起删掉** → `node_filesystem_*` 系列指标爆炸(采集容器内所有 mountpoint)。

**做法**: 覆盖时把默认两条**原样带上**, 第三条才是新增的 `--collector.infiniband`。

附: **不需要额外挂载** `/sys/class/infiniband`。chart 已把宿主 `/sys` 挂到 `/host/sys`
并传了 `--path.sysfs=/host/sys`, infiniband collector 正是走 sysfsPath
(与 `10_rdma` 那次"无 IB 设备节点挂 `/sys/class/infiniband` 报 operation not permitted"
是两回事)。

### 2.5 规则文件里写死 `namespace: monitoring`

vendored 的 6 个规则 YAML 里 `metadata.namespace` 硬编码为 `monitoring`。
`kubectl apply` 对 manifest 内的显式 namespace 是**以文件为准** —— 即使加了 `-n <别的ns>`,
对象仍会被建到 `monitoring`。若 `PROMETHEUS_NAMESPACE` 不是 `monitoring`, 规则就"消失"了
(Prometheus 在另一个 ns, 选不中)。

**做法**: apply 前用 sed 把 `metadata` 下的 `namespace:` 重写到 `PROMETHEUS_NAMESPACE`。

### 2.6 大 dashboard 用 `kubectl apply` 会失败在 256KiB 注解上限

**症状**: 11 个看板里只有 `node-exporter-1860` 导入失败(其余 10 个正常),
错误(`kubectl apply` 才看得到, 模块默认吞了 stderr)是:

```
The ConfigMap "cubestack-node-exporter-1860" is invalid:
metadata.annotations: Too long: may not be more than 262144 bytes
```

**根因**: 客户端 `kubectl apply` 会把**整个配置**存进
`kubectl.kubernetes.io/last-applied-configuration` 注解, 而该注解有 **256KiB 硬上限**。
`node-exporter-1860.json` 是 460KB, 生成的 ConfigMap 约 522KB → 必然超。
**与 ConfigMap 本身 1MiB 的容量上限无关** —— 卡的是注解, 不是对象。

**做法**: 看板 ConfigMap 一律用 **`kubectl apply --server-side`**(服务端 apply 不走该注解)。
实机验证 522KB 正常创建、label 与 data 完整。

> 这是"大 JSON 配置"的通用坑: 任何超过 256KiB 的 ConfigMap/Secret 用客户端 apply 都会中招。
> 挑一个看板失败而其它成功, 正是因为只有它过了这条线。

---

## 3. 资产(vendored)与刷新

`cubestack-addon/observability/cubestack/` 是源仓库 `observability/` 下资产的**只读副本**:

```
recording-rules/*.yaml        6 个 PrometheusRule(gpu / gpu-nvidia / infra / inference /
                              inference-vllm / devenv)
dashboards/grafana/*.json     11 个 Grafana dashboard
SOURCE.txt                    本次拉取的 source repo@commit(版本锚点, 工具生成)
```

**为什么 vendored**: 部署机通常不能访问 GitHub —— 与 `cubestack-addon/` 下其它 chart
同一约定, 资产必须随仓库走。升级资产 = 重跑刷新脚本 + 提交, **不是**让部署流程去联网。

```bash
# 刷新(默认写回仓库内 vendored 目录)
bash deployments/scripts/tools/observability/fetch-observability-assets.sh

# 刷到节点的离线包目录(installer-requirements §5 的约定路径)
bash deployments/scripts/tools/observability/fetch-observability-assets.sh --dir /opt/cubestack/observability
```

工具的拉取方式: `gh api` → `curl(raw)` → `git sparse-checkout`(限时兜底)。
**为什么不默认用 git**: 实测本环境 `github.com:443` 的 git 协议 TCP 能连上但握手卡死到
130s+ 超时, 而 `api.github.com` / `raw.githubusercontent.com` 正常。
`CUBESTACK_FETCH_MODE=gh|curl|git` 可强制指定某一条。

### 目录解析(模块内三级回退)

`08_prometheus.sh` 按顺序选, 并会 `say` 出**实际用了哪个**(不静默):

1. `CUBESTACK_OBSERVABILITY_DIR`(非空即用) —— 显式配置 / 离线包场景
2. `/opt/cubestack/observability`(存在 `recording-rules/` 时) —— installer-requirements §5 的约定
3. 仓库内 vendored(默认)

---

## 4. MetaX mx-exporter(§7.1)

MetaX operator 的 `dataExporter` 默认**不部署**(ClusterOperator CR `spec.dataExporter.deploy: false`),
而 GPU dashboard 的数据源正是它起的 `mx-exporter` DaemonSet。

**打开方式选了 helm value 而不是 patch CR**:

- `06_gpu_operator.sh` 传 `--set dataExporter.deploy=true`(`MX_EXPORTER_ENABLED=true` 时, 默认 true)
- `08_prometheus.sh` 里另有一次 **patch CR 兜底**

为什么两者都要: 06 是 `REPEAT:0`(装过就不再跑), 而 metax 每次 `helm upgrade` 都会
**重新渲染** ClusterOperator CR。若只 patch, 下次升级 metax 时 CR 被冲回 chart 默认的
`false`, 表现为"装完好了, 升级后又没了"。设成 helm value 则与 upgrade 天然一致;
patch 则覆盖"用旧版脚本装过、没带这个 value"的存量集群。

ServiceMonitor(`cubestack-mx-exporter`, 建在 `metax-operator` ns)按 §7.1 用
`app: metax-data-exporter` 选 operator 建的 Service。**job 名是 Service 名不是
ServiceMonitor 名**, 验证时用前缀匹配 `job=~"metax-data-exporter.*"`。

未部署 MetaX 的集群会**自动跳过**(判据是 CR 不存在, 不是看配置开关), 不报错。

---

## 5. BMC 带外监控(§7.2)

独立模块 `33_bmc_exporter.sh`(`TOGGLE: BMC_EXPORTER_ENABLED`, **默认 false**,
`REQUIRES: prometheus`)。

部署形态 = chart `cubestack-bmc-exporter-chart`(Deployment×2 + Service×2 +
ScrapeConfig×2 + Secret×2) + 两个镜像, 全部由 CI 发布到私服
`harbor.isuanova.com/suanova`(**公开只读, 免凭据**)。

### 与 cubepilot 完全同构的 online/offline

```
online  = 先从私服同步制品(chart → addon/bmc-exporter/, 镜像 → offline-files/bmc/*.tar)
          再推入集群内置 registry, 之后与 offline **同路**部署
offline = 不碰外网, 用盘上已有制品推入内置 registry 后部署
```

两种模式的**部署路径是同一段代码**, 差别只在"开头要不要联网同步"。
online 跑过一次后制品已在盘上, **改 `BMC_EXPORTER_MODE=offline` 即可切纯离线**。
online 私服不可达时自动降级到本地制品(告警不中断), 本地也没有才报错。

### 与源仓库文档的一处**有意差异**(不照抄)

`installer-requirements` §7.2 给的离线路径是: 在**节点上**用 buildah 多阶段构建
`bmc-oem-exporter`(需本地先有 `golang:1.26` 基础镜像)+ `ctr -n k8s.io images import`。

本模块**没有采用**, 改用上面那条"私服 → tar → 内置 registry"。原因: 前者要求
每个部署节点都装 buildah + Go 工具链并预置基础镜像, 与本仓库其它组件(envoy / lws /
metax / cubepilot)的做法都不一致且脆弱。后者只需在**联网机**跑一次
`tools/images/bmc-save-images.sh` 备好两个 tar, 节点侧零工具链依赖。
(若确实需要节点本地构建, 源仓库的 `observability/deploy/bmc/deploy-bmc.sh` 仍在, 不冲突。)

### 凭据与调度

- 口令/用户名可能含 `:` `"` `#` `,` 等字符 → values 文件由 **python3 `yaml.safe_dump`
  生成**(手拼字符串会表现为 helm 报 `could not find expected ':'`, 用户很难联想到是口令里的字符);
- 凭据**只经 values 文件**(600, helm 装完立即删除), **不进 argv**;
- 未设置 `BMC_HOSTS` / 用户名 / 口令、或口令仍是 `CHANGE_ME` → 模块在**推镜像之前**就硬失败退出;
- 钉 `control-plane` 节点时**必须**同时给 tolerations, 否则 NoSchedule 污点让 pod 永远 Pending
  (2026-09-14 实测)。`BMC_EXPORTER_TOLERATE_CONTROL_PLANE` 默认 `true` 就是干这个的;
- 模块会从**节点侧**探测每个 BMC 的 443 是否可达(部署机探不到 BMC 网段), 不可达时给排查方向 ——
  因为那种情况表现为"target up 但指标为空", 很难反推。

---

## 6. 验证

### 6.1 不依赖集群: `render-check-prometheus.sh`

values 全在文件里(而不是散落的 `--set`), 所以可以直接渲染检查。这是**性价比最高**的一层 ——
§2.1 / §2.2 / §2.3 / §2.4 四个陷阱都能在这里当场抓住:

```bash
# 宿主没装 helm 时(部署容器里有), 用 HELM 包一层
sudo docker exec <部署容器> bash /opt/cubestack-installer/deployments/scripts/tools/observability/render-check-prometheus.sh
# 或 HELM="docker exec cubestack-install-c helm" bash .../render-check-prometheus.sh
```

工具做的事: 从 `08_prometheus.sh` 里**抽出真实的 values 生成段**执行(而不是抄一份,
保证测的就是模块的代码) → `helm template` 渲染 → 断言:

| 断言 | 抓的是哪个陷阱 |
|---|---|
| `ruleSelector` 是 `matchExpressions ... In [cubestack-observability, kube-prometheus-stack]` | §2.2 |
| chart 自带 PrometheusRule 的 `part-of` 确实是 `kube-prometheus-stack`(**并集选择器的前提**) | §2.2 |
| values 里三组 `*SelectorNilUsesHelmValues` 显式 `false` | §2.3 |
| 渲染出的 `serviceMonitorSelector` 是 `{}`(不是 `release: ...`)、rule/scrapeConfig 是并集 | §2.3 |
| KSM `--metric-labels-allowlist` 完整(4 个 pod label + statefulsets) | §2.1 |
| node-exporter args **同时**含 `--collector.infiniband` **和**默认的两条 filesystem 过滤 | §2.4 |
| node-exporter ServiceMonitor 有 `targetLabel: node` 的 relabeling | §1.3 |
| grafana 口令落到 Secret 的 `admin-password` | §4 |

> ⚠ 断言分两处: `*SelectorNilUsesHelmValues` 是 **Helm values 键**, 不是 Prometheus CR 的字段,
> 渲染出来的 CR 里根本不会有 —— 那三项断言的是**生成的 values 文件**; selector 的**实际渲染值**
> 才断言 CR。本工具早期版本搞混过, 会给出假失败。

> ⚠ `helm template` **离线**渲染 BMC chart 时 `kind: ScrapeConfig` 不会出现 ——
> chart 用 `.Capabilities.APIVersions.Has "monitoring.coreos.com/v1alpha1"` 做守卫,
> 离线渲染看不到 CRD。要看到它们需加 `--api-versions monitoring.coreos.com/v1alpha1`,
> 或直接看真实 `helm upgrade`(它会连集群)。**这是渲染工具的局限, 不是配置错误**。

### 6.2 实机端到端: `--steps verify_prometheus`

模块 `28_verify_prometheus.sh` 在原有①~⑤(采集→存储→查询)之后新增三段:

- **⑥ recording rules 实际加载** —— 逐组断言 vendored 文件里**每个 group 名**都出现在
  `GET /api/v1/rules`。为什么不用 `kubectl get prometheusrule`: **CR 建成功 ≠ 规则被加载**,
  后者取决于 `ruleSelector` 能否选中, 选不中时**无任何报错**。
  逐组断言比"共 N 条"更抗震(上游增删规则不误报, 少任何一个 group 都报)。
- **⑦ Grafana dashboard 已导入** —— `GET /api/search` 断言 11 个看板 uid 都在
  (uid 从各 JSON 里读, 不按文件名猜)。侧车扫描有 10-60s 延迟, 刚装完需稍等。
- **⑧ 附加 exporter 采集** —— mx-exporter / BMC 各自启用时断言。BMC 期望
  `BMC_HOSTS 个数 × 2`(每 BMC 一个 bmc-oem + 一个 idrac), 但**不是只数 `up` 序列**(见下)。

> ⚠ **`up == 1` 不等于"目标 BMC 可用"**(2026-09-20 实测, 差点写成假绿灯):
> 两个 exporter 的抓取模式不同, `up` 的含义也不同 ——
>
> | exporter | 抓取路径 | 目标不可达时 `up` | 目标健康指标 |
> |---|---|---|---|
> | `bmc-oem-exporter` | `/probe?target=<ip>` | **仍然是 1**(它只是返回"探测失败") | `bmc_pcie_scrape_success`(0/1) |
> | `idrac-exporter` | `/metrics?target=<ip>` | 0(抓取本身失败) | — |
>
> 所以"count(up) == 期望数"会**通过**: 不可达的 BMC 照样占一条 `up` 序列。
> ⑥⑦⑧ 的 BMC 断言因此分两层: **抓取层** `up == 1`(管住 idrac)+ **目标层**
> `bmc_pcie_scrape_success == 1`(管住 bmc-oem)。只查前者会在 BMC 全不可达时给出绿灯。
>
> 通用教训: 多目标 exporter(`?target=` 模式)的 `up` 描述的是**exporter 自身**是否可抓,
> 不是目标是否可用 —— 目标健康一定另有指标。

⑥⑦⑧ 与④ 共用 `VERIFY_MONITORING_STRICT`(默认 `true`=失败即退出;
置 `false` 降级为告警)。**⑥ 默认也严格**: 规则不加载本身就是静默故障, 不查出来等于没验证。

**不适用时正确跳过、而不是假失败**(同为 2026-09-20 实机教训): mx-exporter 的 DaemonSet
带 `metax-tech.com/gpu.installed=true` nodeSelector, **没有 GPU 节点的集群期望副本=0** ——
此时"无 target"是正常的。判据用 DaemonSet 期望副本数(而不是配置开关或"有没有 ClusterOperator"),
否则每个无 GPU 集群都会永久报红, 和"operator 永远报未就绪"是同一类错误。

```bash
sudo ./deploy-cluster.sh --steps verify_prometheus
```

### 6.3 手工查规则是否加载

```bash
kubectl -n monitoring get prometheusrule | grep cubestack        # 只证明 CR 在, 不证明加载了
# 真正判据(在能访问 pod 网段的节点上执行):
curl -s http://<prometheus-pod-ip>:9090/api/v1/rules | python3 -c "
import json,sys
for g in json.load(sys.stdin)['data']['groups']:
    if 'cubestack' in g['name']: print(g['name'], '-', len(g['rules']), 'rules')"
```

---

## 7. 配置项

见 `cluster.conf.example`:
- **顶部核心必改项 ④**: `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD`(出厂默认 admin/admin;
  下方 PROMETHEUS 段只做引用, 保持唯一事实来源 —— 与 `METALLB_POOL` 同款写法)
- **PROMETHEUS 段附近**: `PROMETHEUS_SCRAPE_INTERVAL` / `PROMETHEUS_EVALUATION_INTERVAL` /
  `CUBESTACK_OBSERVABILITY_DIR` / `MX_EXPORTER_ENABLED`
- **4.9 段**: `BMC_EXPORTER_ENABLED`(默认 false)/ `BMC_EXPORTER_MODE` / `BMC_HOSTS` /
  `BMC_USERNAME` / `BMC_PASSWORD` / `BMC_TLS_INSECURE` / `BMC_EXPORTER_*`

⚠ `GRAFANA_ADMIN_PASSWORD` **出厂默认 admin**(用户名也是 admin, 2026-09-21 起), 开箱即可部署/登录;
用默认值部署时模块只**告警**不阻断 —— 监控入口常对外暴露(NodePort/LoadBalancer), 请尽快改掉。

仍会被**硬失败拒绝**的只有两种: ① 留空/未设置(helm 会随机生成口令存进 secret, 用户拿不到,
实测环境因此手工重置过); ② 仍是 `CHANGE_ME` 之类的占位符。

---

## 8. 常用命令

```bash
sudo ./deploy-cluster.sh --steps prometheus            # 装/重跑监控栈 + 规则 + 看板 + mx-exporter
sudo ./deploy-cluster.sh --steps verify_prometheus     # 端到端验证(含⑥⑦⑧)
sudo ./deploy-cluster.sh --enable bmc_exporter         # 预启用 BMC(写入 cluster.conf, 不部署)
sudo ./deploy-cluster.sh --steps bmc_exporter          # 立即装 BMC(自动带上 prometheus)

# 刷新 observability 资产(联网机)
bash deployments/scripts/tools/observability/fetch-observability-assets.sh

# BMC 离线备料(联网机) → 拷到部署机 → 改 BMC_EXPORTER_MODE=offline
sudo bash deployments/scripts/tools/images/bmc-save-images.sh
```

**卸载**: `helm uninstall` 不会删 dashboard 的 ConfigMap(它不是 helm 管的), 需手工:

```bash
kubectl -n monitoring delete cm -l app.kubernetes.io/part-of=cubestack-observability
kubectl -n monitoring delete prometheusrule -l app.kubernetes.io/part-of=cubestack-observability
```
