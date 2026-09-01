# 调试状态记录: verify_envoy_gateway / verify_envoy_ai_gateway (2026-08-31 ~ 09-01)

> 现场: 10-66-3-43 宿主机 + `cubestack-install` 容器(`docker exec -it cubestack-install bash`, 仓库在容器内
> `/opt/cubestack-installer`, 与宿主 `/home/supperadm/cubestack-installer` 是**同 md5 拷贝**, 改宿主后需 docker cp 同步;
> `deployments/offline-files` 为 bind mount 勿动)。集群单节点 mxgpu-1-232, MetalLB VIP 池 10.66.1.131-132。
> **容器内无 docs/ 目录**(只同步 deployments/ + skills/); 容器外找文档看宿主 repo。

## 已修复并验证: 25_verify_envoy_gateway.sh(2026-08-31)

**根因**: ④ 步只等 "Gateway 拿到 VIP + 后端 Ready" 就 break, 但 `status.addresses` 在 Service 分到 IP 时**立即**出现,
数据面 Envoy pod 需 ~11s 才 Ready(实测计时)。此期间 MetalLB L2 不通告 VIP(无 Ready 端点) → ⑤ 步单次立即 curl → HTTP 000。
**修复**(已提交 `ec02357`): 等数据面 pod Ready + Gateway Programmed + VIP + curl 重试吸收 L2 通告尾延迟。全绿。

## 已修复(代码): AI Gateway v1.1.0 全链适配(2026-08-31 提交 `8bf3038` + 2026-09-01 补充)

1. **26_verify_envoy_ai_gateway.sh**: 版本推导 bug + v1.1 schema(EG Backend fqdn / AIServiceBackend
   backendRef+schema / AIGatewayRoute parentRefs+headers)+ **GatewayClass 默认 `envoy-gateway` → `eg`**
   (2026-09-01 补; 集群只有 GatewayClass `eg`, 旧默认导致 Gateway 永不 Programmed)。
2. **09_envoy_gateway.sh**: helm `extensionApis.enableBackend=true`(EG Backend API 默认禁用)。
3. **10_envoy_ai_gateway.sh**: 推 extProc 镜像 + helm extProc.image.* 改写。
4. **tools/images/envoy-save-images.sh**: 镜像清单加 `ai-gateway-extproc`。

## ⭐ 真正的根因(2026-09-01 已定位并修复): EG extensionManager 接线缺失

**AI 请求 404 "No matching route found" 的真因不是 extProc 镜像**(此前结论有误), 而是 **EG 从未调用
AI 控制器的扩展服务器 → 数据面根本没有 AI 过滤器**:

- **架构(v1.1)**: AI 控制器进程内跑一个 gRPC 扩展服务器(**端口 1063**, 实现 EG 的
  `EnvoyGatewayExtensionServer` 接口)。EG 必须在其自身 config(`envoy-gateway-config` ConfigMap)里声明
  `extensionManager.hooks.xdsTranslator`(post=[Translation,Cluster,Route] + translation includeAll
  listener/route/cluster/secret)+ `service.fqdn` 指向 `ai-gateway-controller.<ns>.svc.cluster.local:1063`。
  之后 EG **每次 xDS 翻译都回调** AI 控制器, 由其插入 `envoy.filters.http.ext_proc`(extProc 端点选择器)+
  `header_to_metadata` 过滤器。漏配 → 数据面是纯 EG 配置, AI 路由不存在 → 404。
- **官方依据**: ai-gateway 仓库 `manifests/envoy-gateway-values.yaml`(git tag v1.1.0, 已克隆到
  `/home/supperadm/ai-gateway-v1.1.0-src`)。⚠ 官方 docs/basic-usage 没提 extensionManager, 只有
  envoy-gateway-values.yaml 里有; 模块 09/10 旧注释声称 "v1.x 不再用 extensionManager/已废弃" —— **错误**。
- **模块 09 故意不配**(2026-09-01 设计决策): 若 EG 配了 extensionManager 但 AI 控制器不在(独立装 EG 时),
  EG 每次翻译调用 PostTranslate 钩子失败 → **所有 Gateway 翻译失败**(EG 源码:
  `processExtensionPostTranslateHook` 无条件调用, 出错则 `skipped publishing xds resources`)。所以必须在
  **AI 控制器就绪后**(模块 10)补接线 + 重启 EG 控制面。

**修复(2026-09-01, 已改宿主 + docker cp 进容器, 未提交)**: `10_envoy_ai_gateway.sh` 新增 **[5/6] 接线步骤**:
读取 `envoy-gateway-config` CM → python3(pyyaml)注入 extensionManager(幂等, 已有则跳过)→
`kubectl patch` → `kubectl rollout restart deploy/envoy-gateway`(⚠ chart 内 Deployment 名固定
`envoy-gateway`, release 名 `eg` 只是 helm 记录, 勿用 release 名重启)。同时修正模块 10 头部/步骤里
"v1.x 已废弃 extensionManager" 的错误注释与 `GatewayClass envoy-gateway` → `eg`。

**现场已验证(2026-09-01, 接线生效)**:
- AI 控制器日志出现 `envoy-gateway-extension-server inserting AI Gateway extproc filter into listener
  {"listener": "verify-aig-fix/aigw-gw/http"}` + `Added extproc-uds cluster` → **EG 已回调 AI 扩展服务器**。
- 数据面 pod **3/3 Running**(envoy + extProc sidecar + 就绪容器)。
- 清理孤儿数据面 `envoy-verify-aig-dbg-aigw-gw-3fa0c0a0`(占用 VIP 10.66.1.132)后, 新 Gateway 拿到 VIP。
- **mock 后端 405 根因**: nginx 对静态文件拒绝 POST → 405。模块 26 改用 `return 200` 内联 JSON
  (`location = /v1/chat/completions { return 200 '...envoy-ai-gateway-verify-ok...' }`)。

## ✅ 全量验证通过(2026-09-01 晚)

`--steps verify` 全绿(exit 0): verify_metallb / verify_registry_storage / verify_metax_gpu / verify_lws /
**verify_envoy_gateway(HTTP 200)** / **verify_envoy_ai_gateway(HTTP 200, mock LLM 透传成功 ✓)**。
测试资源已由各验证模块 trap 自动清理, 集群无 verify-* 残留命名空间。

## SERVICE_EXPOSE_MODE 一致性检查(2026-09-01, 用户任务, 已修)

用户要求: 暴露方式支持 nodePort 与 metallb, **默认二选一**。核查结论:
- ✅ 互斥已在 addons 层强制: `sync-addons-config.sh` 在 nodeport 模式把 `metallb_enabled=false`
  (无论 METALLB_ENABLED 默认 true), registry→NodePort、ingress→NodePort(30080/30081)。
- ✅ 各消费者按模式分支: deploy-cluster 汇总 / lib-common 归一化(loadbalancer→metallb)+
  REGISTRY_SERVICE_TYPE 派生 / sync-kubespray-config / deploy-registry / setup-registry-expose /
  25/26 verify(数据面转 NodePort)/ gateway-nodeport.sh 工具。
- ❌→✅ **修复 1**: `01_metallb.sh`(部署期就绪检查)与 `21_verify_metallb.sh`(验证)只按
  `METALLB_ENABLED`(默认 true)守卫 → nodeport 模式会假阳性失败。两模块已加
  `SERVICE_EXPOSE_MODE=nodeport → 跳过` 守卫。
- ⚠→✅ **修复 2(自动连通, 用户要求 "nodeport 默认走集群第一个 IP")**: nodeport 模式下节点 /etc/hosts
  的 registry.local → REGISTRY_IP; 但 REGISTRY_IP 原自动取自 METALLB_POOL(无 MetalLB → 无服务监听)
  → 节点拉取会失败。现自动: ① REGISTRY_IP 默认 = **首个 master IP**(lib-common 派生); ② 节点
  containerd hosts.toml 镜像直连 `<master>:REGISTRY_NODEPORT`(客户端侧改写, 绕开 kube-proxy 重置
  节点 iptables 的问题); ③ 宿主机 registry.local:5000 由 deploy-registry.sh 自动 DNAT 到首个 master
  的 REGISTRY_NODEPORT(systemd 持久化)。全部默认生效, 无需手动配置; 显式 REGISTRY_IP 仍可覆盖。

## 待办(已全部完成, 2026-09-01)

1. ✅ 删孤儿数据面 → 新 Gateway 拿 VIP → mock 200(前述)。
2. ✅ 全量 `--steps verify` 全绿。
3. ✅ 提交代码(待 git commit)。
4. ✅ 清理测试资源(全量 verify 已自动清理)。

## 环境事实(已核实, 供后续)

- GitHub 可达(2026-09-01 发现; docker.io 仍不可达): 已克隆
  `/home/supperadm/ai-gateway-v1.1.0-src`(AI Gateway v1.1.0, 55M)。**下次如需查 EG/AIG 源码先看这里**,
  不必重新 clone(/tmp 会被清, 此副本在 home 下)。
- EG v1.9.1: helm release 名 `eg`, **控制面 Deployment 名固定 `envoy-gateway`**, config CM
  `envoy-gateway-system/envoy-gateway-config`(data key `envoy-gateway.yaml`)。数据面按 Gateway 动态创建
  Deployment/Svc 在 **envoy-gateway-system**(名 `envoy-<gw>-<ns>-<hash>`)。
- AI Gateway v1.1.0: 控制器 Deployment `ai-gateway-controller`(ns `ai-gateway-system`), Service 端口
  9443(webhook)/1063(扩展服务器 gRPC, 明文, 无 TLS 配置); `--watchNamespaces=`(全空间)。
- 扩展服务器回调机制(EG 源码): `extensionManager.service.fqdn` 配 hostname+port; 无 `tls:` 段走明文;
  grpc.Dial 非阻塞, 首调失败即翻译失败。钩子: post=[Translation→PostTranslateModify, Cluster→PostClusterModify,
  Route→PostRouteModify]; translation includeAll 决定传给钩子的资源。
- 调试脚本注意: `SSH()` 函数调用勿写 `$SSH`; heredoc `$(...)` 内闭合 `"` 必须在右括号前; python heredoc
  `<<'PYEOF'` 的 `)"` 必须放在 PYEOF 之后。
