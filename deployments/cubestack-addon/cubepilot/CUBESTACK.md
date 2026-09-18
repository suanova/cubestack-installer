# CubePilot — CubeStack 安装器接入说明

本目录存放 **CubePilot AI Agent 平台**(上游 `suanova/cubepilot`)的安装适配说明,
供 `modules/03_addon/31_cubepilot.sh` 安装、`modules/03_addon/32_verify_cubepilot.sh` 验证。

> **统一制品流向**:不论哪种模式,**节点只从集群内置 registry 拉镜像,部署机 helm 装本地 chart tgz**。
> `CUBEPILOT_MODE` 只决定**部署前要不要先从私服同步一次制品**:
> **默认 `online`**(当前为测试节点)—— 注意这与仓库其它组件(metax/envoy/lws)的"离线优先"**相反**。

| | `online`(默认) | `offline` |
|---|---|---|
| 同步 | 部署前从私服拉 chart + 4 镜像**落盘到本地** | **不碰外网**,直接用盘上已有制品 |
| chart 来源 | 同步落盘 `cubestack-addon/cubepilot/cubepilot-<ver>.tgz` | 同左(同一路径) |
| 镜像来源 | **集群内置 registry** `<REGISTRY_DOMAIN>:<PORT>/suanova/cubepilot-*` | 同左(同一路径) |
| 部署路径 | **与 offline 完全相同**(同一段代码) | — |
| 外网依赖 | 仅**部署机**需可达 `harbor.isuanova.com`(节点不需要) | 无 |
| 凭据 | **不需要**(私服公开只读;私有化后才需 `CUBEPILOT_HARBOR_USER/PASSWORD`) | 不需要 |
| 适用 | 联网环境 / 在线测试 | 生产 / 隔离 / 离线集群 |

**两条关键性质:**

- **online 跑过一次后,制品已在盘上 → 改 `CUBEPILOT_MODE=offline` 即可切纯离线**,无需任何额外准备。
- **online 在私服不可达时自动降级**:拉不到就退回本地已有制品(告警不中断);本地也没有才报错。

本目录**不存 manifest / 镜像 tar**:online 由模块在部署时同步,offline 的产物由下方工具在联网机生成后放置。

---

## 1. 制品(Artifacts):它们在哪

发布流水线把制品推到 **Harbor `harbor.isuanova.com/suanova`**(与本项目自身镜像、MetaX 镜像同源)。
该项目**公开只读(anonymous pull)**,通常**无需任何凭据**。

| 发布来源 | 镜像 tag | Helm chart(OCI) |
|---|---|---|
| push 到 main | `:latest` | `oci://harbor.isuanova.com/suanova/cubepilot-chart:0.1.0-latest` |
| 打 tag vX.Y.Z | `:X.Y.Z` | `oci://harbor.isuanova.com/suanova/cubepilot-chart:X.Y.Z` |

> ⚠ **chart 仓库名是 `cubepilot-chart`(带 `-chart` 后缀),不是 `cubepilot`** —— 后者根本不存在。
> 模块曾经写错成后者,已修正。

四个镜像(与 chart 的 values 键一一对应):

| 镜像 | values 键 |
|---|---|
| `harbor.isuanova.com/suanova/cubepilot-openclaw` | `agents.image` |
| `harbor.isuanova.com/suanova/cubepilot-operator` | `operator.image` |
| `harbor.isuanova.com/suanova/cubepilot-api` | `api.image` |
| `harbor.isuanova.com/suanova/cubepilot-web` | `web.image`(仅内置 Portal 启用时需要) |

**版本联动规则**(模块自动派生,无需手工对齐):

- chart 版本以 `-latest` 结尾(如 `0.1.0-latest`)→ 镜像 tag 取 `latest`;
- 否则镜像 tag **等于** chart 版本(即 `CUBEPILOT_VERSION=0.1.0` → 镜像 `:0.1.0`)。
- 显式设 `CUBEPILOT_IMAGE_TAG` 可覆盖。

> ⚠ **chart 各镜像默认 tag 是 `:latest`,会跟上游漂移**。模块**恒定显式传**四个镜像 ref,
> 把版本钉死在 chart 版本上,并统一指向内置 registry —— 节点永远不会去拉 `:latest` 的原值。

### CRD 归属(两类,别混淆)

| CRD 组 | 是否在 chart 内 | 装法 |
|---|---|---|
| `ai.cubestack.io`(AgentInstance 等 **6 个**) | ✅ 在 chart 的 `crds/` 目录 | `helm install` 时自动装上,无需干预 |
| CubeStack 平台 CRD(DevEnvironment / InferenceService / ...) | ❌ chart **不含** | 默认**不装**;仅在"内置 skills/chat 需要"时开启,见 §6 |

---

## 2. 制品同步(online)与联网机预置(offline)

### 2.1 online:模块自动同步(默认路径)

部署机上 `--steps cubepilot` 时自动完成,**无需人工介入**:

1. `helm pull oci://harbor.isuanova.com/suanova/cubepilot-chart --version <ver>`
   → 成功即**覆盖** `deployments/cubestack-addon/cubepilot/cubepilot-<ver>.tgz`;失败则**回退用本地 tgz**。
2. 4 个镜像:先 `skopeo inspect` 取私服上该 tag 的 **digest**,与本地 `<tar>.digest` 边车比对 ——
   **相同且 tar 在 → 跳过下载**;不同或缺失 → `skopeo copy` 重新落盘
   `deployments/offline-files/cubepilot/<repo>_<tag>.tar`,并写回边车。
3. 把 tar **推入集群内置 registry**(幂等:`reg_has_tag` 命中则跳过)。

想**强制重拉**:删掉对应 tar(或它的 `.digest` 边车)即可。

> digest 存**边车文件**(`<tar>.digest`)而非集中清单 —— 制品拷到别的机器时 digest 跟着走;
> 无边车视为"未知"→ 重新下载(安全默认)。

### 2.2 offline:联网机预置

**仅当部署机无法访问私服时**才需要。在一台**联网机**执行两个工具,产物拷到部署机:

```bash
# ① chart tgz → deployments/cubestack-addon/cubepilot/cubepilot-<ver>.tgz
./deployments/scripts/tools/images/cubepilot-fetch-charts.sh
#   指定版本:    CUBEPILOT_VERSION=0.1.0 ./cubepilot-fetch-charts.sh
#   私有化后:    CUBEPILOT_HARBOR_USER=<bot> CUBEPILOT_HARBOR_PASSWORD=<pw> ./cubepilot-fetch-charts.sh

# ② 4 个镜像 → deployments/offline-files/cubepilot/<repo>_<tag>.tar
sudo ./deployments/scripts/tools/images/cubepilot-save-images.sh
sudo ./deployments/scripts/tools/images/cubepilot-save-images.sh --list    # 只看清单
sudo ./deployments/scripts/tools/images/cubepilot-save-images.sh --force   # 强制重下
```

镜像 tar 文件名规则与其它组件一致(`/` 与 `:` → `_`):

```
harbor.isuanova.com_suanova_cubepilot-openclaw_latest.tar
harbor.isuanova.com_suanova_cubepilot-operator_latest.tar
harbor.isuanova.com_suanova_cubepilot-api_latest.tar
harbor.isuanova.com_suanova_cubepilot-web_latest.tar
```

> 模块按 **① 规范文件名 → ② 文件名含组件名 → ③ tar 内 `manifest.json` 内容兜底**三级查找,
> 兼容改名;并且**推之前会用 tar 内实际 ref 复核**,防止"文件名像、内容不是"推错镜像。

---

## 3. 安装路径(目标集群上的确切位置)

```
命名空间            cubepilot              (CUBEPILOT_NAMESPACE)
helm release        cubepilot              (CUBEPILOT_RELEASE)
chart 来源          deployments/cubestack-addon/cubepilot/cubepilot-<ver>.tgz   (两种模式同一路径)
镜像                <REGISTRY_DOMAIN>:<PORT>/suanova/cubepilot-*               (两种模式同一路径)
PVC                 cubepilot-api-data          (元数据; api.storageClassName)
                    cubepilot-api-skill-repo    (共享技能仓; api.skillRepo.storageClassName)
Secret              cubepilot-llm          (仅预置 LLM 时创建; operator watch 此名)
```

一条命令安装:

```bash
sudo ./deploy-cluster.sh --steps cubepilot          # 或 cluster.conf 置 CUBEPILOT_ENABLED=true
sudo ./deploy-cluster.sh --steps verify_cubepilot   # 端到端验证
```

模块步骤(`31_cubepilot.sh`):

1. `[1/7]` 前置检查 + **制品就绪**(online 先同步 chart/镜像,再统一推入内置 registry)
2. `[2/7]` 命名空间
3. `[3/7]` LLM 预置(可选,§5)
4. `[4/7]` CubeStack 平台 CRD(可选,默认关,§6)
5. `[5/7]` `helm upgrade --install`(本地 tgz + 四镜像钉版 + SC + web.enabled)
6. `[6/7]` 等 operator rollout + 检查 `ai.cubestack.io` CRD 与 AgentInstance
7. `[7/7]` 汇总(模式 / 访问方式 / 验证命令 / 卸载命令)

---

## 4. 凭据与镜像拉取

### 4.1 不需要任何凭据(默认)

Harbor 的 `suanova` 项目**公开只读**,`skopeo` / `helm` 匿名即可拉。模块默认不带凭据。
若将来收紧为私有项目,再在 `cluster.conf` 填 `CUBEPILOT_HARBOR_USER` / `CUBEPILOT_HARBOR_PASSWORD`
(helm 与 skopeo 两侧都会带上)。私服自签证书时置 `CUBEPILOT_HARBOR_INSECURE=true`。

### 4.2 节点侧:零配置

**节点不访问私服**,只访问集群内置 registry(免认证且节点已信任),因此:

- **不需要** 节点级 `containerd certs.d` 凭据;
- **不需要** `imagePullSecret`。

这一条同时根治了旧设计的老问题:CubePilot 的 operator 会**为每个用户运行时铸造 ServiceAccount**,
给每个 SA 挂 `imagePullSecret` 既挂不全(SA 是运行时产生的)、也随时可能被 operator 覆盖。
统一走内置 registry 后,运行时铸造的 SA 与普通 Pod 拉取路径一致,**不需要任何额外配置**。

> 旧版 `online`(节点直连私服)曾需要给所有节点下发
> `/etc/containerd/certs.d/harbor.isuanova.com/hosts.toml`,`CUBEPILOT_NODE_REGISTRY_AUTH` 开关即控制它 ——
> 该机制已随本次改造**整体移除**。

---

## 5. LLM(默认无心智模型)

默认安装**不假设平台已有 LLM**,装完在 Portal 的 **Agent Config → LLM Config** 里添加。

要在安装时预置平台默认模型,在 `cluster.conf` 配:

```bash
CUBEPILOT_LLM_ENDPOINT="https://api.deepseek.com"
CUBEPILOT_LLM_MODEL="deepseek-v4-flash"
CUBEPILOT_LLM_API_KEY="sk-..."
```

模块会传 `agents.llmEndpoint` / `agents.llmModel`,并创建 Secret
`cubepilot-llm`(key = `apiKey`)。**与 operator 的先后顺序无关** —— operator 会 watch 该 Secret,
装完后再建也认。

---

## 6. CubeStack 平台 CRD(可选,默认关)

chart 只带 `ai.cubestack.io` 的 6 个 CRD。若 CubePilot 内置 skills/chat 需要操作 CubeStack 平台
资源(DevEnvironment / InferenceService / ...),需另装平台 CRD:

```bash
# 1) 从 cubepilot 源仓库取 CRD(联网机)
#    suanova/cubepilot → test/e2e/framework/testdata/cubestack-crds/*.yaml
#    拷到 deployments/cubestack-addon/cubepilot/cubestack-crds/(本仓库**未 vendored**)
# 2) cluster.conf 置 CUBEPILOT_PLATFORM_CRDS_ENABLED=true 后重跑
sudo ./deploy-cluster.sh --steps cubepilot --fresh   # --steps 只跑该组件; --fresh 清断点状态
```

目录为空时模块**只警告不报错**(多数部署不需要这些 CRD)。

---

## 7. 对外访问

> ⚠ **平台网关方式已移除(2026-09-18)**: 原先的两条 HTTPRoute
> (`deployments/cubestack-addon/gateway/routes/cubepilot{,-portal}.yaml` + 模块 `33_cubestack_gateway.sh`)
> 已随平台网关模块一并删除 —— 网关(Gateway)与路由(HTTPRoute)统一改由**专门的网关模块**创建(尚在重构中)。
> 该模块落地后, 本节会重新给出 `cubepilot-api.cubestack.io` / `cubepilot.cubestack.io` 两条路由的接入方式
> (要点记档, 供新模块落地时复用):
>
> | hostname | 后端 | 条件 |
> |---|---|---|
> | `cubepilot-api.cubestack.io` | `svc/cubepilot-api:8080`(REST/SSE API, **恒存在**; 探活 `/healthz` → 200) | CubePilot 已部署 |
> | `cubepilot.cubestack.io` | `svc/cubepilot:8080`(内置 Portal 的 nginx: SPA + `/api` 反代) | 另需 `CUBEPILOT_WEB_ENABLED=true` |
>
> ⚠ **两个后端不要写混**(2026-09-17 修): `svc/cubepilot` 是**内置 Portal 的 nginx 入口**, 只在
> `web.enabled=true` 时有; 纯 API 入口是 `svc/cubepilot-api`。历史版本路由文件写成 `svc/cubepilot:8080`,
> 在"关闭 Portal"的部署里后端根本不存在(→ `ResolvedRefs=False`)。

### 当前入口: port-forward

```bash
kubectl -n cubepilot port-forward svc/cubepilot     8080:8080   # Portal(SPA + /api)
kubectl -n cubepilot port-forward svc/cubepilot-api 8080:8080   # 仅 API(/healthz)
```

---

## 8. 内置 Portal 与 StorageClass

- **内置 Portal(`cubepilot-web`)默认启用**(`CUBEPILOT_WEB_ENABLED=true`):chart 自带的 React
  门户(nginx:SPA 页面 + `/api` 反代给 `cubepilot-api`),装完即可用 —— `port-forward svc/cubepilot`(见 §7)。
  置 `CUBEPILOT_WEB_ENABLED=false`(如已有统一 UI 接管前端)则不创建 `cubepilot-web` Deployment
  与相关 Service;同步与推送阶段也**不会处理** `cubepilot-web` 镜像(没人会拉它,不白传流量),
  此时只剩 API 入口(`svc/cubepilot-api`; 平台网关路由待专门模块落地后接入, 见 §7)。
- **两个 PVC 的 StorageClass** 由 `CUBEPILOT_STORAGE_CLASS` 控制,默认**自动派生**:

  | 场景 | 取值 |
  |---|---|
  | Ceph 体系启用(`CEPH_ENABLED` / `CEPH_CSI_ENABLED` 任一 true) | `ceph-block` |
  | 否则 | 留空 → PVC 回落**集群默认 StorageClass** |

  ⚠ chart 语义是"**storageClassName 非空才生效**",故留空时模块**不传**该参数(传空串反而可能
  被当作显式空值)。纯 local-path 集群请确认默认 SC 是否为 local-path —— 它是单节点本地盘,
  节点故障即丢数据。

---

## 9. 验证与故障排查

```bash
sudo ./deploy-cluster.sh --steps verify_cubepilot
```

验证链:helm release `deployed` → Deployment 全可用 → `ai.cubestack.io` CRD 已注册 →
**AgentInstance 已创建**(证明 operator 真在调和,而非只是 Pod Running)→ pods Running →
Service 有 Ready Endpoints → HTTP 探针(master 上 port-forward 回环探测,失败仅告警)。

> **验证边界(如实标注)**:以上**不含** Portal 鉴权与 LLM 对话的端到端验收 ——
> 那需要真实 LLM API Key。对话链路请在 Portal 配置模型后人工验收。

| 现象 | 排查方向 |
|---|---|
| `ImagePullBackOff` | 镜像没推进内置 registry:重跑 `--steps cubepilot --fresh` 看推送日志;或节点未信任/无法解析内置 registry(见 `05_k8s_registry.sh`) |
| 拉取/推送私服失败 | 部署机可达性:`curl -I https://harbor.isuanova.com/v2/`(公开只读应返回 **401**,证明服务在);`skopeo inspect docker://harbor.isuanova.com/suanova/cubepilot-api:latest` |
| chart 拉取失败 | chart 仓库名是否写成 `cubepilot`(应为 **`cubepilot-chart`**);版本号是否已发布:`helm show chart oci://harbor.isuanova.com/suanova/cubepilot-chart --version <ver>` |
| 报"chart tgz 不存在" | 私服不可达且本地也无 tgz:在联网机跑 `cubepilot-fetch-charts.sh` 并放入 `deployments/cubestack-addon/cubepilot/` |
| 报"离线镜像缺失" | 私服不可达且本地也无 tar:在联网机跑 `cubepilot-save-images.sh` 并放入 `deployments/offline-files/cubepilot/` |
| 想强制刷新制品 | 删掉 `offline-files/cubepilot/` 下的 tar 与 `.digest` 边车后重跑 |
| PVC 一直 `Pending` | `CUBEPILOT_STORAGE_CLASS` 指定的 SC 不存在(如纯 local-path 集群却指定了 `ceph-block`) |
| 无 AgentInstance | operator 日志:`kubectl -n cubepilot logs deploy/<operator>`;CRD 是否齐全 |

**切换模式**:改 `CUBEPILOT_MODE` 后 `sudo ./deploy-cluster.sh --steps cubepilot --fresh`(--steps 只跑该组件)。
由 online 切 offline **不需要任何额外准备**(制品已在盘上);由 offline 切 online 也无额外准备。
**升级**:改 `CUBEPILOT_VERSION` 后同上(online 会自动拉新版本;offline 需先备好对应版本制品)。
**卸载**:`helm uninstall cubepilot -n cubepilot`(平台 CRD 不会自动清理)。

---

## 10. 上游来源

- 仓库:`suanova/cubepilot`(接入 issue:`cubestack-installer#28`)
- 制品:私服 Harbor `harbor.isuanova.com/suanova`(发布流水线推送;chart 仓库名 `cubepilot-chart`)
- 相关设计变更:`suanova/cubepilot` issue #117 / PR #119(chart 渲染的 agent-kubeconfig Secret、
  admin 默认身份、`ModelConfigured` 状态与 Portal 提示、values 驱动的 model-less 默认)。
