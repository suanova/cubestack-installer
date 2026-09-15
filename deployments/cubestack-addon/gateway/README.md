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
- **路由**: `routes/<ns>.yaml`(每服务一条 HTTPRoute, 可整体 apply/delete)。
- **访问**: `curl -H "Host: <svc>.cubestack.io" http://<节点IP>:<NodePort>/`

## 部署

```bash
# 1. 基座(命名空间 + Gateway)
kubectl apply -f base-gateway.yaml

# 2. 数据面暴露到节点 NodePort
#    (base-gateway.yaml 已用 service-type=NodePort 注解持久声明; nodePort 自动分配)
#    若需固定 NodePort, 跑一趟 gateway-nodeport.sh 建固定别名 <gw>-external(默认 30880):
deployments/scripts/tools/lb/gateway-nodeport.sh cubestack-gateway

# 3. 各服务路由(m ⊃ 示例: monitoring 的 Grafana/Prometheus)
kubectl apply -f routes/monitoring.yaml

# 4. 查状态(应 True/True/True)
kubectl get httproute -A
kubectl get gateway cubestack-gateway -n cubestack-gateway-system -o jsonpath='{.status.listeners[0].conditions[?(@.type=="Programmed")].status}'
```

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
| AI 推理/API(示例) | `api.cubestack.io` | 待接入 | ⏳ |
| 开发/测试环境 | `<svc>.cubestack.io` | 按需 | ⏳ |

## 备注

- 复用 `GatewayClass eg`, **不要重复创建**其他 GatewayClass(如教程/示例的 `envoy-gateway-class`)。
- Gateway 放 `cubestack-gateway-system`(基础设施), 不混入 `envoy-gateway-system` / `default`。
- 数据面 svc 名带 hash(`envoy-<ns>-<gw>-<hash>`), 由控制器拥有、**不要手改/manual patch type**(会被 reconcile 回); 固定端口用 `gateway-nodeport.sh` 建 `<gw>-external` 别名。
- hostname `*.cubestack.io` 是可改约定; 本地验证用 `-H "Host:"`, 生产配 DNS / 源站。