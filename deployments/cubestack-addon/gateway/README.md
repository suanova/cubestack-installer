# platform-gateway — 平台统一网关(cubestack-gateway)

CubeStack 对外服务的**单一入口**,基于 Envoy Gateway(复用集群 `eg` GatewayClass)。
单 Gateway + 单 HTTP Listener + **多 hostname**,每个服务一条 HTTPRoute(各自命名空间)跨 ns 绑定。
替代以往"每个组件一个 NodePort `*-external`"的分散暴露方式。

## 链路

```
外部 (任一节点IP:NodePort / 未来 VIP)
  └─> Gateway cubestack-gateway (listener:80, hostname 区分)
        └─> HTTPRoute <svc>-route   (hostnames: <svc>.cubestack.io, ns=服务命名空间)
              └─> 内置 ClusterIP Service → Pods
```

- **基座**: `base-gateway.yaml`(Namespace + Gateway, 一次上手, 长期保留)。
- **路由**: `routes/<服务>.yaml`(每服务一条 HTTPRoute, 可整体 apply/delete)。
- **访问**: `curl -H "Host: <svc>.cubestack.io" http://<节点IP>:<NodePort>/`(固定入口 NodePort 默认 **30080**)

## 部署

```bash
# 0. 一键(推荐): 模块 33_cubestack_gateway.sh 幂等下发基座 + 路由 + 固定入口 + /etc/hosts
sudo ./deploy-cluster.sh --steps cubestack_gateway      # 改完 routes/ 重跑即生效

# 手工等价步骤(排查用):
# 1. 基座(命名空间 + Gateway)
kubectl apply -f base-gateway.yaml

# 2. 数据面暴露到节点 NodePort
#    (base-gateway.yaml 已用 service-type=NodePort 注解持久声明; nodePort 自动分配)
#    固定 NodePort 用 gateway-nodeport.sh 建固定别名 <gw>-external:
#      模块走 CUBESTACK_GATEWAY_NODEPORT(默认 30080);  工具裸跑默认 GATEWAY_EXTERNAL_NODEPORT=30880
deployments/scripts/tools/lb/gateway-nodeport.sh cubestack-gateway

# 3. 各服务路由(示例: monitoring 的 Grafana/Prometheus + CubePilot)
kubectl apply -f routes/monitoring.yaml
kubectl apply -f routes/cubepilot.yaml          # API(需 CUBEPILOT_ENABLED)
kubectl apply -f routes/cubepilot-portal.yaml   # Portal(另需 CUBEPILOT_WEB_ENABLED)

# 4. 查状态(应 True/True/True)
kubectl get httproute -A
kubectl get gateway cubestack-gateway -n cubestack-gateway-system -o jsonpath='{.status.listeners[0].conditions[?(@.type=="Programmed")].status}'
```

> ⚠ **模块序号 33 = 排在所有组件之后**(2026-09-17 起,原名 `18_cubestack_gateway.sh`):
> 路由落在**后端组件自己的命名空间**里, 排在组件之前 apply 会 `namespaces "x" not found` 失败
> → 路由静默缺失(cubepilot 曾因此丢路由)。模块现在有**后端存在性预检**: 命名空间/Service 不存在
> 就明确跳过并在汇总里提示 —— 组件部署完成后**重跑本模块**即补下发。
> 新增组件模块请用**小于 33 的序号**(或在部署后重跑 `--steps cubestack_gateway`)。

## 接入新服务(5 分钟)

只需加一条 HTTPRoute, 网关不动:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <svc>-route
  namespace: <服务命名空间>
spec:
  parentRefs:                    # 绑定平台网关
    - name: cubestack-gateway
      namespace: cubestack-gateway-system
      kind: Gateway
  hostnames:
    - <svc>.cubestack.io        # 对外域名(Host 头)
  rules:
    - backendRefs:
        - name: <svc>           # 既有 ClusterIP Service
          port: 80
```

> 若目标 Service 端口与对外端口不同: HTTPRoute `port` 写 **Service 端口**, EG 自动转发 targetPort。
>
> **两处配套**(缺一不可):
> 1. 路由文件放进 `routes/`(模块 33 会逐文件下发, hostname 自动写入部署机 `/etc/hosts`);
> 2. 在 `33_cubestack_gateway.sh` 的 `case "${_rbase}"` 里加一条**门控**(组件开关为真才下发,
>    否则该 HTTPRoute 会停在 `ResolvedRefs=False` 的噪音状态)。
>
> ⚠ 后端的**命名空间与 Service 必须先存在**: 模块会预检, 不存在就跳过该条并提示
> (组件模块序号要 < 33; 组件部署晚于网关时, 部署完成后重跑本模块即补下发)。

## 验证

```bash
curl -i -H "Host: grafana.cubestack.io"   http://<节点IP>:<NodePort>/
curl -i -H "Host: prometheus.cubestack.io" http://<节点IP>:<NodePort>/
# 期望: 302(重定向登录/query)或 200
```

## 清理

**只撤服务(保留网关)** —— 常用:
```bash
kubectl delete -f routes/           # 或按命名空间删
kubectl delete httproute grafana-route -n monitoring
```
**彻底撤网**(连数据面一并删):
```bash
kubectl delete gateway cubestack-gateway -n cubestack-gateway-system
kubectl delete ns cubestack-gateway-system
```

## 已接入 hostname 约定

| 服务 | hostname | backend | 状态 |
|---|---|---|---|
| Grafana | `grafana.cubestack.io` | `monitoring/kube-prometheus-grafana:80` | ✅ |
| Prometheus | `prometheus.cubestack.io` | `monitoring/kube-prometheus-kube-prome-prometheus:9090` | ✅ |
| CubePilot API | `cubepilot-api.cubestack.io` | `cubepilot/cubepilot-api:8080`(恒存在) | ✅ |
| CubePilot Portal | `cubepilot.cubestack.io` | `cubepilot/cubepilot:8080`(需 `CUBEPILOT_WEB_ENABLED`) | ✅ |
| AI 推理/API(示例) | `api.cubestack.io` | 待接入 | ⏳ |
| 开发/测试环境 | `<svc>.cubestack.io` | 按需 | ⏳ |

> 实测(2026-09-17): `curl -H "Host: cubepilot-api.cubestack.io" http://<节点IP>:30080/healthz` → 200;
> `curl -H "Host: cubepilot.cubestack.io" http://<节点IP>:30080/` → 200(Portal SPA)。

## 备注

- 复用 `GatewayClass eg`, **不要重复创建**其他 GatewayClass(如教程/示例的 `envoy-gateway-class`)。
- Gateway 放 `cubestack-gateway-system`(基础设施), 不混入 `envoy-gateway-system` / `default`。
- 数据面 svc 名带 hash(`envoy-<ns>-<gw>-<hash>`), 由控制器拥有、**不要手改/manual patch type**(会被 reconcile 回); 固定端口用 `gateway-nodeport.sh` 建 `<gw>-external` 别名。
- hostname `*.cubestack.io` 是可改约定; 本地验证用 `-H "Host:"`, 生产配 DNS / 源站。