# 调试状态记录: verify_envoy_gateway / verify_envoy_ai_gateway (2026-08-31, 已完成代码修复)

> 现场: 10-66-3-43 宿主机 + `cubestack-install` 容器(`docker exec -it cubestack-install bash`, 仓库在容器内
> `/opt/cubestack-installer`, 与宿主 `/home/supperadm/cubestack-installer` 是**同 md5 拷贝**, 改宿主后需 docker cp 同步;
> `deployments/offline-files` 为 bind mount 勿动)。集群单节点 mxgpu-1-232, MetalLB VIP 池 10.66.1.131-132。

## 已修复并验证: 25_verify_envoy_gateway.sh(原失败模块)

**根因**: ④ 步只等 "Gateway 拿到 VIP + 后端 Ready" 就 break, 但 `status.addresses` 在 Service 分到 IP 时**立即**出现,
数据面 Envoy pod 需 ~11s 才 Ready(实测计时)。此期间 MetalLB L2 不通告 VIP(无 Ready 端点) → ⑤ 步单次立即 curl → HTTP 000。

**修复**(已改宿主文件 + docker cp 进容器, 单模块与全量 `--steps verify` 均跑通, HTTP 200 `envoy-gateway-verify-ok`):
- ④ 步增加等待: 数据面 pod 2/2 Running(先查 `${ENVOY_EG_NAMESPACE}` 再兜底 `${TEST_NS}`, 数据面默认落在
  `envoy-gateway-system`)+ Gateway `Programmed=True` + 原 VIP/后端条件。
- ⑤ 步 curl 重试 6 次(3s 间隔), 吸收 L2 通告尾延迟。
- nodeport 分支同样修了命名空间(数据面 svc 默认在 envoy-gateway-system, 原只查 TEST_NS 会漏)。

**关键坑(jsonpath 多层引号)**: SSH 字符串里的 kubectl jsonpath, 字符串字面量必须写 `\"Programmed\"`(转义双引号),
裸 `"` 会在 shell 层被吞 → 返回空。

## 已修复(代码): AI Gateway v1.1.0 全链适配(26/09/10/工具/文档)

现场诊断链(全部代码修复已完成, 见 git diff):
1. **26_verify_envoy_ai_gateway.sh**:
   - 版本推导 bug(原有): `AI_APIVER="$( (SSH "...tail -1)" ...)"` 里 SSH 字符串吞了一个 `)`
     → 远端命令尾带 `)` 语法错误 → 恒走兜底 v1alpha1。已改: 用 storage 版本, 兜底 served 末位, 再兜底 v1beta1。
   - v1.x YAML 换 v1.1.0 schema(旧 `type/apiKey/url` strict decode 被拒):
     - 新增 EG Backend(gateway.envoyproxy.io/v1alpha1, `endpoints[].fqdn:{hostname,port}`, **不是 `url`**);
     - AIServiceBackend: `backendRef:{group: gateway.envoyproxy.io, kind: Backend}` + `schema:{name: OpenAI, prefix: /v1}`;
     - AIGatewayRoute: `parentRefs`(非 gatewayRefs), `rules[].matches` 只支持 headers(`x-ai-eg-model: mock`,
       AI filter 从 body 提取 model 注入), backendRefs→AIServiceBackend;
     - 删 dummy APIKey Secret(新 schema 不再引用); 修 backend `mkdir` 缺 `/chat`(v1.x + v0.x 两处)。
2. **09_envoy_gateway.sh**: helm 增加 `--set config.envoyGateway.extensionApis.enableBackend=true`。
   EG Backend API 默认禁用(安全原因, CVE-2021-25740), AIG v1.1 的 AIServiceBackend 必须引用它;
   不启用则 HTTPRoute 报 "Backend is disabled in Envoy Gateway configuration"(ResolvedRefs=False)。
3. **10_envoy_ai_gateway.sh**: 推送逻辑重构为 `push_ai_image` 函数, 增加 **`ai-gateway-extproc`** 推送;
   helm 增加 `--set extProc.image.repository/tag`(控制器 `--extProcImage` 参数, 决定注入数据面的
   extProc sidecar 镜像; 漏改 → 数据面 pod 2/3 ImagePullBackOff(拉 docker.io 超时), AI 路由 404)。
4. **tools/images/envoy-save-images.sh**: 默认镜像清单增加 `docker.io/envoyproxy/ai-gateway-extproc:<AI_VERSION>`。
5. **skills/cubestack-deploy-scripts/SKILL.md** + **docs/envoy-gateway.md**: 镜像清单加 extproc、
   enableBackend 要点、版本更正(v1.9.1 / v1.1.0)、§4.2 示例换新 schema。

## 现场手工验证结论(已完成的链路验证)

- EG Backend 改 fqdn 后 apply OK; EG config 手工加 `enableBackend: true` + rollout restart 后,
  HTTPRoute `ResolvedRefs=True`("Resolved all the Object references for the Route")。
- AIServiceBackend → `Accepted=True`("AIServiceBackend reconciled successfully"); AIGatewayRoute → 调和出 HTTPRoute。
- mock 后端 mkdir 修好后 1/1 Running; mock 调用到达 AI filter(404 为 route-not-found 兜底规则响应),
  唯一剩余阻断 = extProc sidecar 镜像拉不到(现场无 tar、无 docker 缓存、docker.io 不可达)。

## 未完成(环境受限, 需离线备料后补验)

- **现场无法验证的部分**: 本机所有环境均无法访问 docker.io, 且 `/data/offline-files/envoy/` 缺
  `ai-gateway-extproc` tar → 现场无法推送 extproc 镜像完成 verify_envoy_ai_gateway 的最终 200 验证。
  待用户在联网机重新跑 `tools/images/envoy-save-images.sh`(现在会多下载 extproc), 把新 tar 放入
  `/data/offline-files/envoy/`, 然后:
  ```bash
  # 1. 推送缺失镜像(或直接重跑 10 模块/--fresh 重装 AI)
  sudo ./deployments/scripts/tools/images/envoy-load-images.sh
  # 2. 重跑全量验证
  sudo ./deploy-cluster.sh --steps verify
  ```
- **待清理**: 测试 ns `verify-aig-new` / `verify-aig-manual`(手工验证遗留), 可在验证通过后删。
- **待提交**: git commit(25/26/09/10 模块 + envoy-save-images.sh + skill + docs)。

## 环境事实(已核实, 供后续)
- EG v1.9.1(helm, GatewayClass `eg`, 数据面 pod 2 容器 2/2, 就绪 ~11s; AI 网关数据面 pod = 3 容器: +extProc sidecar)。
- AI Gateway v1.1.0: ai-gateway-controller 1/1; CRD 都 serve v1alpha1+v1beta1, **storage=v1beta1**;
  `--extProcImage` 由 chart 值 `extProc.image.*` 决定; GatewayConfig 的 extProc.kubernetes 也能覆盖。
- 镜像: registry.local:5000/envoyproxy/envoy:distroless-v1.39.1 / gateway:v1.9.1 / verify/nginx:latest(节点已缓存);
  registry 缺 `ai-gateway/ai-gateway-extproc`。
- 原失败数据面 pod 事件: FailedMount(sds configmap 瞬时不存在, kubelet 重试后正常)+ readiness 19003 拒绝 —— 均为启动期瞬时态。
- 调试脚本注意: `SSH()` 函数调用不要写 `$SSH`; heredoc 里 `$(SSH "...")` 的字符串闭合 `"` 必须在右括号前。
