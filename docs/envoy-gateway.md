# Envoy Gateway 与 Envoy AI Gateway 分析与离线部署

> 本文档回答两个问题:
> 1. **两者是什么、有什么关系、怎么选**(分析);
> 2. **在 CubeStack 离线集群里如何把两者部署起来**(离线部署落地: chart + 镜像 + 模块 + 验证)。
>
> 配套代码: `deployments/scripts/modules/03_addon/09_envoy_gateway.sh`(Envoy Gateway)、
> `deployments/scripts/modules/03_addon/10_envoy_ai_gateway.sh`(Envoy AI Gateway)、
> `deployments/cubestack-addon/envoy-gateway/`(离线 chart)、`deployments/scripts/tools/images/envoy-save-images.sh`(离线镜像)。
>
> 官方文档: [Envoy Gateway](https://gateway.envoyproxy.io/) / [Envoy AI Gateway](https://aigateway.envoyproxy.io/)
>
> **当前默认版本**(cluster.conf 可覆盖): Envoy Gateway **v1.9.1**(GA)、Envoy AI Gateway **v1.1.0**(GA)、
> AI 控制器镜像 `docker.io/envoyproxy/ai-gateway-controller:v1.1.0`(官方源为 DockerHub, 非 ghcr)。

---

## 一、两者定位与关系(一句话总结)

| | Envoy Gateway | Envoy AI Gateway |
|---|---|---|
| 定位 | **通用** Kubernetes 原生 API 网关(Gateway API 的标准实现) | 面向 **LLM/AI 流量**的网关扩展层, 建立在 Envoy Gateway 之上 |
| 本质 | 独立控制面 + 数据面(完整项目) | **不是独立二进制**: = 特制的 Envoy Gateway 控制面 + 独立的 AI 控制器 + 一组 AI CRD + 转换层 |
| API | 标准 `gateway.networking.k8s.io`(GatewayClass/Gateway/HTTPRoute/...) | 自定义 `aigateway.envoyproxy.io`(AIServiceBackend/AIGatewayRoute/GatewayConfig/...), 数据面用标准 Gateway |
| 关系 | **基座** | **上层扩展**(依赖 Envoy Gateway 提供 xDS/数据面能力) |

> **重要澄清(v1.x 架构)**: Envoy AI Gateway **不是一个独立的网关二进制**,也不是"装个 helm chart 就完事"的普通应用。
> 它由三部分组成, 且**数据面完全复用标准 Envoy Gateway**(AI 控制器通过 **EG extension server 机制**
> 在每次 xDS 翻译时回调注入 AI 过滤器, 见下):
> 1. **标准 Envoy Gateway**(模块 09 安装的 `gateway-helm`, 提供 `eg` GatewayClass 与数据面);
> 2. **AI Gateway 控制器**(`ai-gateway-controller`, 独立 Deployment + MutatingWebhook), 通过 **webhook + extProc 注入**
>    为标准 Gateway 提供 AI 能力(模型路由 / token 统计 / 多供应商转换);
> 3. **EG extensionManager 接线**(模块 10 自动完成): 控制器内嵌 gRPC 扩展服务器(端口 1063), EG 的
>    `envoy-gateway-config` ConfigMap 需声明 `extensionManager.hooks.xdsTranslator` 回调到该服务,
>    EG 每次翻译 xDS 时调用它插入 `ext_proc` / `header_to_metadata` 过滤器。**漏配 → AI 请求 404
>    "No matching route found"**(历史调试曾误判为 extProc 镜像问题)。
> 3. **AI CRD**(`AIServiceBackend` / `AIGatewayRoute` / `GatewayConfig` / `BackendSecurityPolicy` / `QuotaPolicy` 等)。
>
> 因此**离线部署必须先装 Envoy Gateway, 再装 AI Gateway 控制器与 CRD**。

---

## 二、架构对比

### 2.1 Envoy Gateway(通用网关)

```
┌─────────────────────────────────────────────────────┐
│ Kubernetes Cluster                                  │
│                                                     │
│  Gateway API CRDs        Envoy Gateway 控制面       │
│  (GatewayClass/Gateway/  (eg Deployment)            │
│   HTTPRoute/...)───▶  Go Controller                 │
│                             │                       │
│                             │ xDS (gRPC)            │
│                             ▼                       │
│                        Envoy Proxy 数据面           │
│                        (按 Gateway 动态创建          │
│                        的 Deployment)              │
└─────────────────────────────────────────────────────┘
```

- **控制面** `eg`(release 名, Deployment 在 `envoy-gateway-system`): 监听 Gateway API 资源 → 翻译成 xDS(Listener/Route/Cluster/Endpoint)→ gRPC 推送数据面。
- **数据面** Envoy Proxy: 用户创建 `Gateway` 后, 控制器自动在集群内创建 Envoy Proxy Deployment/Service(非 Sidecar), 承担真实流量。
- **入口暴露(metallb 模式, 默认/生产)**: Gateway 的 Listener 通过 MetalLB(本集群)分配 VIP → 外部 URL 可达。
- **入口暴露(nodeport 模式, 测试环境)**: `SERVICE_EXPOSE_MODE=nodeport` 时不部署 MetalLB, 数据面 Service 默认仍创建为 LoadBalancer, 需转 NodePort 才可访问:
  - 创建 Gateway 时加注解(推荐, 持久): `gateway.envoyproxy.io/service-type: NodePort`, 之后数据面自动以 NodePort 暴露;
  - 对已创建、未带注解的 Gateway/AIGateway: 运行 `sudo ./deployments/scripts/tools/lb/gateway-nodeport.sh <gateway名> [namespace]`, 一键 patch 数据面 Service 为 NodePort 并打印 `节点IP:NodePort` 访问地址。
- **扩展**: `ExtensionRef` 外部处理器(ext_proc)、Wasm、Lua; 限流/熔断/重试/超时/故障注入; TLS/mTLS/JWT/OAuth2; Prometheus metrics / OTel。

### 2.2 Envoy AI Gateway(AI 专用扩展)

```
┌──────────────────────────────────────────────────────────────┐
│ Kubernetes Cluster                                           │
│                                                              │
│  AI CRDs                 AI Gateway 控制器                    │
│  (AIServiceBackend/      (ai-gateway-controller Deployment)  │
│   AIGatewayRoute/──▶ 监听 AI CRD + 标准 Gateway:             │
│   GatewayConfig)         · MutatingWebhook 注入 extProc      │
│                          · 模型路由 / token 统计 /            │
│                            多供应商转换                      │
│                                   │                          │
│                                   ▼                          │
│  Envoy Gateway 控制面 ── xDS ──▶ Envoy Proxy 数据面          │
│  (标准 gateway-helm,             (AI 感知过滤器/转换,        │
│   复用, 不再特制)                由 extProc 提供 AI 能力)    │
└──────────────────────────────────────────────────────────────┘
```

- **AI 控制器** 是新增的独立组件: 处理 AI 语义(多模型供应商适配、token 级限流、语义缓存、模型 failover/fallback、prompt guardrail 接入)。
- **注入方式(v1.1)**: 两步协作 —— ① AI 控制器注册 MutatingWebhook, 自动给用户创建的**标准 Gateway**(gatewayClassName=`eg`, 数据面 pod 注入 extProc sidecar + 挂载 filter config); ② EG 通过 **extension server 机制**(模块 10 在 EG 的 `envoy-gateway-config` 里配置 `extensionManager` 回调到 AI 控制器扩展服务器 **1063 端口**, 明文 gRPC)在每次 xDS 翻译时插入 `envoy.filters.http.ext_proc` / `header_to_metadata` 过滤器, 数据面 Envoy 经此完成 AI 语义处理。v0.x 独立的 Extension Server(18090 端口/单独 Deployment)已废弃。
- **协议理解**: 原生理解 `Chat Completions` 等 LLM API 格式, 可把 OpenAI 格式请求翻译为 Anthropic/Gemini/Bedrock 等格式(多供应商统一入口)。
- **可选依赖**: 语义缓存需要向量/Redis 类后端(本仓库默认不启用, 见 `ENVOY_AI_SEMANTIC_CACHE_ENABLED`)。

### 2.3 核心差异对比

| 维度 | Envoy Gateway | Envoy AI Gateway |
|---|---|---|
| 成熟度 | GA / 生产就绪 | Alpha/Beta(快速迭代) |
| 限流粒度 | 请求数 / QPS | input/output **token** 级 |
| 缓存 | HTTP 缓存 | 语义向量缓存(需外部后端) |
| 协议理解 | HTTP/gRPC/TCP | LLM API 格式(Chat Completions 等) |
| 适用场景 | 微服务 / Web 应用 / API 管理 | GenAI 应用 / LLM 代理 / AI Agent |
| 多模型供应商 | 不感知 | 内置 OpenAI/Anthropic/Gemini/Azure/Bedrock 适配 |
| 模型 failover | 不感知 | 支持主备模型自动切换 |

### 2.4 本集群如何选

- **只要统一流量入口 / API 网关**(业务 URL 转发、认证前置、限流)→ 装 **Envoy Gateway** 即可(P1-9 刚需, `ENVOY_GATEWAY_ENABLED=true`)。
- **要暴露 LLM 服务 / 统一多模型供应商 / token 限流 / 语义缓存** → 在 Envoy Gateway 基础上加装 **Envoy AI Gateway**(`ENVOY_AI_GATEWAY_ENABLED=true`, **依赖前者先装**)。
- 两者可同时存在: AI Gateway 数据面**复用** EG 的 `eg` GatewayClass(无需第二个数据面); AI 控制器独立命名空间 `ai-gateway-system`。

---

## 三、离线部署设计

### 3.1 部署全景(两个模块)

| 组件 | 模块 | 开关 | 内容 |
|---|---|---|---|
| Envoy Gateway | `09_envoy_gateway.sh` | `ENVOY_GATEWAY_ENABLED` | helm 离线安装 `gateway-helm` + 默认 GatewayClass `eg` + 示例资源 |
| Envoy AI Gateway | `10_envoy_ai_gateway.sh` | `ENVOY_AI_GATEWAY_ENABLED` | helm 离线安装 AI CRD chart(`ai-gateway-crds-helm`)+ 控制器 chart(`ai-gateway-helm`, 独立控制器, 复用 EG 数据面), 依赖 EG 已装 |

**依赖关系**: `10_envoy_ai_gateway.sh` 前置检查会确认 Envoy Gateway 已就绪(`envoy-gateway-system` 命名空间 / `eg` GatewayClass 存在), 未装则报错并提示先启用 `ENVOY_GATEWAY_ENABLED`。

### 3.2 离线物料清单(联网机准备, 部署机离线)

所有物料由两个工具脚本在**联网机**生成/下载, 拷到部署机即可:

| 物料 | 位置 | 生成工具 |
|---|---|---|
| EG chart tgz(`gateway-helm-<v>.tgz`) | `deployments/cubestack-addon/envoy-gateway/eg/` | `tools/images/envoy-fetch-charts.sh`(helm pull, **只存 tgz**) |
| AI chart tgz(`ai-gateway-crds-helm-<v>.tgz` + `ai-gateway-helm-<v>.tgz`) | `deployments/cubestack-addon/envoy-gateway/ai/` | 同上 |
| 全部镜像 tar | `deployments/offline-files/envoy/` | `tools/images/envoy-save-images.sh` |
| tar→registry 预加载 | 推送至集群内置 registry | `tools/images/envoy-load-images.sh`(独立入口, 幂等) |

> 仓库**只存 chart tgz 压缩包**(不膨胀代码库); 部署模块(09/10)在**部署时把 tgz 临时解压到 `mktemp` 目录**
> 再 `helm install`, 退出自动清理。默认 `ENVOY_*_CHART_SOURCE=tgz`; 手工放好 tgz 即可, 无需解包。
>
> 镜像推送: 部署时 09/10 模块**自动**把 tar 推送到集群内置 registry; 也可在部署前用
> `envoy-load-images.sh` **独立预加载**(幂等, 已存在则跳过; 适合先推镜像再装 chart 的场景)。

**镜像清单**(随版本变化, 以 `envoy-save-images.sh` 输出为准):

- Envoy Gateway: `envoyproxy/gateway`(控制面, tag=`ENVOY_EG_VERSION`)、`envoyproxy/envoy`(数据面, ⚠ tag=`ENVOY_PROXY_VERSION`, 默认 `distroless-v1.39.1` —— 与 EG 版本号**不同**, 用 `kubectl exec deploy/envoy-gateway -- envoy-gateway version` 的 `ENVOY_PROXY_VERSION` 核对); 若启用限流再备 `envoyproxy/ratelimit`、`envoyproxy/envoy-ratelimit`。
- Envoy AI Gateway: `docker.io/envoyproxy/ai-gateway-controller`(控制器, 官方源 DockerHub, 非 ghcr)、**`docker.io/envoyproxy/ai-gateway-extproc`(extProc sidecar, ⚠ 必收: AI 控制器把它注入数据面 pod, 漏收则数据面 2/3 ImagePullBackOff、AI 路由 404)**; AI 数据面复用 EG 的镜像(`envoyproxy/envoy`, tag 同上)。

### 3.3 镜像流向(与 LWS/gpu_operator 同一模式)

1. 联网机: `envoy-save-images.sh` 从官方源 docker pull / skopeo 保存 tar → `deployments/offline-files/envoy/`;
2. 部署机: 模块把 tar 经 skopeo 推送到**集群内置 registry**(`registry.local:5000/envoyproxy/...` 与 `registry.local:5000/ai-gateway/...`);
   2b. 或先单独预加载(幂等): `sudo ./deployments/scripts/tools/images/envoy-load-images.sh`(适合先推镜像再装 chart);
3. helm 安装时用 `--set deployment.envoyGateway.image.*`(控制面/certgen)+ `global.images.envoyProxy.image`(数据面)把 chart 默认镜像改写为集群内置 registry 路径, `pullPolicy=IfNotPresent`;
4. K8s 节点按域名从集群内置 registry 拉取(节点已配 `/etc/hosts` + containerd 信任)。

### 3.4 关键 chart values(离线改写)

| chart | values 键 | 说明 |
|---|---|---|
| gateway-helm | `deployment.envoyGateway.image.repository` / `image.tag` | EG 控制面 Deployment + certgen Job 镜像(chart v1.9.1 经 `eg.image` helper 统一取此路径; 默认 `docker.io/envoyproxy/gateway`) |
| gateway-helm | `global.images.envoyProxy.image` | **数据面** Envoy 镜像(创建 Gateway 时动态拉起, 完整镜像串, 默认 `docker.io/envoyproxy/envoy`; ⚠ tag=`ENVOY_PROXY_VERSION`=distroless-v1.39.1, 勿用 EG 版本号) |
| gateway-helm | `envoyGateway.extensionManager` | **v1.1 AI 必需**(模块 10 注入: `hooks.xdsTranslator` post=[Translation,Cluster,Route] + translation includeAll + `service.fqdn` → AI 控制器扩展服务器 1063; 模块 09 **故意不设**, 否则独立 EG 时 xDS 翻译全失败) |
| gateway-helm | `config.envoyGateway.extensionApis.enableBackend` | **EG Backend API**(默认禁用, 安全原因; AIG v1.1+ 的 AIServiceBackend 必须引用 EG Backend → 09 模块默认设 `true`, 否则 HTTPRoute 报 "Backend is disabled in Envoy Gateway configuration") |
| ai-gateway-crds-helm | — | 纯 CRD chart, 无镜像 |
| ai-gateway-helm | `controller.image.repository` / `controller.image.tag` | AI 控制器镜像(默认 `docker.io/envoyproxy/ai-gateway-controller`; 另 `controller.nameOverride` 定资源名、`envoyGateway.namespace` 指 EG 命名空间) |
| ai-gateway-helm | `extProc.image.repository` / `extProc.image.tag` | **extProc sidecar 镜像**(控制器 `--extProcImage` 参数; 注入数据面 pod, 必须改写为集群内置 registry, 否则离线拉不到 docker.io) |

> 数据面镜像改写是关键: 用户创建 `Gateway` 后控制器动态创建的 Envoy Proxy Deployment 必须能从集群内置 registry 拉镜像(默认 docker.io 在离线集群不可达)。

---

## 四、使用示例

### 4.1 Envoy Gateway: 把业务 URL 转发到后端服务

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: my-gateway
  namespace: default
spec:
  gatewayClassName: eg
  listeners:
    - name: http
      protocol: HTTP
      port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
  namespace: default
spec:
  parentRefs:
    - name: my-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: my-backend-svc
          port: 80
```

访问: `curl http://<Gateway VIP>/`(VIP 由 MetalLB 分配, `kubectl get gateway` 的 ADDRESS 字段)。

### 4.2 Envoy AI Gateway: 统一接入 OpenAI 兼容服务(v1.x: 标准 Gateway + AI 扩展 CRD)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: llm-gateway
  namespace: default
spec:
  gatewayClassName: eg   # 复用 EG 的 GatewayClass(AI 控制器 webhook 自动注入 extProc)
  listeners:
    - name: http
      protocol: HTTP
      port: 80
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: Backend
metadata:
  name: openai-backend
  namespace: default
spec:                              # EG Backend(需 EG extensionApis.enableBackend=true)
  endpoints:
    - fqdn:
        hostname: api.openai.com
        port: 443
---
apiVersion: aigateway.envoyproxy.io/v1beta1
kind: AIServiceBackend
metadata:
  name: openai
  namespace: default
spec:
  backendRef:
    group: gateway.envoyproxy.io
    kind: Backend
    name: openai-backend
  schema:
    name: OpenAI                  # OpenAI/Anthropic/AWSBedrock/...(枚举)
    prefix: /v1                   # chat completions 端点 = <prefix>/chat/completions
---
apiVersion: aigateway.envoyproxy.io/v1beta1
kind: AIGatewayRoute
metadata:
  name: llm-route
  namespace: default
spec:
  parentRefs:
    - name: llm-gateway
  rules:
    - matches:                    # v1.1 只支持 header 匹配(x-ai-eg-model 由 AI filter 从请求 body 提取 model 注入)
        - headers:
            - name: x-ai-eg-model
              value: gpt-4o
      backendRefs:
        - name: openai
```

> ⚠ v1.x 起**没有** `AIGateway`/`Backend`(aigateway.envoyproxy.io 组)CRD(那是 v0.x API); 用上面的标准 Gateway + EG `Backend` + `AIServiceBackend` + `AIGatewayRoute`。
> ⚠ v1.1 起 `AIServiceBackend.spec` 为 `backendRef`(引用 EG Backend)+ `schema`(name/prefix), 旧字段 `type/apiKey/url` 会被 strict decode 拒绝; `AIGatewayRoute.spec` 为 `parentRefs`(非 `gatewayRefs`)。
> 精确字段随版本迭代(Alpha/Beta), 以所装版本官方 `examples/basic/basic.yaml` 为准; 本仓库 verify 模块使用最小可运行子集。

---

## 五、验证与运维

```bash
# 端到端验证 Envoy Gateway: 建测试 Gateway+HTTPRoute → busybox httpd 后端 → curl VIP 200
sudo ./deployments/scripts/deploy-cluster.sh --steps verify_envoy_gateway
# 端到端验证 Envoy AI Gateway: 控制器 Ready → AI CRD 注册 → 按运行时 CRD 版本自动分支
#   (v1.x: 标准 Gateway + AIServiceBackend + AIGatewayRoute, 断言 AIServiceBackend 被控制器调和;
#    v0.x legacy: AIGateway/Backend, 仅告警不阻断)
sudo ./deployments/scripts/deploy-cluster.sh --steps verify_envoy_ai_gateway

# 独立预加载镜像(可选, 幂等): 把 envoy-save-images.sh 生成的 tar 推送到集群内置 registry
sudo ./deployments/scripts/tools/images/envoy-load-images.sh

# 查看
kubectl get gatewayclass,gateway,httproute -A
kubectl get aiservicebackend,aigatewayroute -A
kubectl get pods -n envoy-gateway-system      # EG 控制面
kubectl get pods -n ai-gateway-system         # AI 控制器(AI chart 默认命名空间)
```

## 六、故障排查索引

- 离线集群 `ImagePullBackOff`(docker.io 不可达)→ 数据面/控制面镜像未改写或未推送, 见 §3.3-3.4 与 `docs/troubleshooting.md` §四。
- `GatewayClass` 未 `Accepted` → 控制器未就绪 / controllerName 不匹配, 见 troubleshooting §四。
- AI Gateway 控制器启动失败 → EG 版本不匹配(见 AI 官方兼容矩阵), 或 `envoyGateway.namespace` 未指向 EG 所在命名空间。
