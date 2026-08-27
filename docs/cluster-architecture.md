# CubeStack 集群架构与网络设计

> 记录**当下实际部署**的 Kubernetes 集群、网络架构、各 operator 的设计与部署步骤, 以及历史方案的**限制**(避免将来重蹈覆辙)。
> 与 `troubleshooting.md`(问题排查)互补; 本文件是"架构为什么是这样"的权威说明。
> 新增 operator 时, 按 `skills/cubestack-operator-onboarding/SKILL.md` 的标准流程更新脚本与本文件。

---

## 1. 当前部署的集群

本项目用同一套脚本(`deployments/scripts/deploy-cluster.sh`)驱动两种环境的离线部署, 差异仅在 `cluster.conf` 的 `NODES` 与网络配置。

| 环境 | 节点 | 网络 | 用途 |
|---|---|---|---|
| **VM 集群** | master01-03 + worker01-04, 在 `tools/vm/vm-nodes.conf` 定义(自动创建并注入 NODES) | libvirt 桥 `privbr0`, 网段 `10.244.0.0/16`(节点 `10.244.1.x`) | 开发/验证、离线链路自测 |
| **BM 集群** | 9 台裸金属 `mxgpu-*`(3 master + 6 worker), 直接在 NODES 填写(不在 vm-nodes.conf) | 物理网段 `10.66.1.0/24`, 但底层是 **proxy-ARP 虚拟化 fabric**(见 §2) | 生产目标 |

> 注: cluster.conf 的 NODES 统一为 5 字段(`role,hostname,ip,ssh_user,ssh_password`), **不区分虚拟机/裸金属**;
> 虚拟机规格(mac/内存/CPU/磁盘)在 `tools/vm/vm-nodes.conf`(10字段)定义, 创建后自动注入 NODES。

**共用配置**(`cluster.conf` / `sync-kubespray-config.sh` 派生):
- 服务网段 `10.233.0.0/18`、Pod 网段 `10.233.64.0/18`、nodelocaldns `169.254.25.10`;
- CNI = **Calico + IPIP**(固定, 见 §3);
- 负载均衡 = **MetalLB**(Layer2, 地址池可配);
- 组件开关统一在 `cluster.conf`, 由 sync 脚本同步到 kubespray `group_vars`(不硬编码)。

---

## 2. 网络架构(重点: BM fabric 的本质)

### 2.1 VM 集群: 真实 L2 桥
`privbr0` 是 libvirt 桥, 节点在同一真实 L2, 任意 IP/UDP 互通 → 任意 CNI 数据面都可用。

### 2.2 BM 集群: proxy-ARP / 按 IP 转发的 fabric(非真实 L2)

实测证据(在任一节点上):
```bash
ip neigh show | grep 10.66.1        # 所有节点 IP(含网关 .254)都解析到同一 MAC: 00:01:00:01:00:01
                                    # 而各节点 manage0 真实 MAC 各不相同 → ARP 被"代理"了
# 数据面行为:
nc -u <节点IP> 4789   # ✗ 到不了(被 fabric 丢弃, VXLAN 端口有专门 ACL)
nc -u <节点IP> 8472   # ✓ 能到
nc -u <节点IP> 40002  # ✓ 能到(对照)
# IPIP(proto 4)       # ✓ 能到(tcpdump 可见)
ping <远端podIP>      # ✗ 100% 丢(direct 无封装时)
```

**结论(fabric 的三个关键性质):**
1. **不是真实 L2**: 所有 IP 的 ARP 由 fabric 统一应答为一个 MAC, 它**按 IP 转发**(类似 L3 交换机 / 虚拟化网关);
2. **只转发节点 IP, 不路由 pod CIDR(10.233.x)**: 所以任何"无封装直连路由"(Calico direct / Cilium native)都发不出跨节点 pod 流量;
3. **丢弃 UDP 4789**(VXLAN 端口), 但放行其他 UDP 与 IPIP(proto 4)。

> ⚠ 若在别处遇到"节点同网段却跨节点不通", 先用 §2.2 的三条命令判定是否同类 fabric, 再决定数据面, 不要直接套本方案。

---

## 3. 为什么网络方案是 Calico + IPIP

### 3.1 三种方案的对比与结论

| 方案 | 配置 | 在本 fabric 是否可行 | 原因 |
|---|---|---|---|
| **Calico IPIP 封装(采用)** | `calico_ipip_mode=Always` + `calico_network_backend=bird` + `mtu=1480` | ✅ **可行(默认)** | 外层=节点 IP(IPIP/proto4), fabric 实测放行; 每节点本地解封装 |
| Calico VXLAN | `vxlan_mode=Always` | ❌ 需换端口 | fabric 丢 UDP 4789; 换非 4789 端口(如 8472)可绕开, 但端口依赖脆弱 |
| Calico direct 无封装 | `ipip=Never` + `vxlan=Never` | ❌ | fabric 不路由 pod CIDR, 直接发 pod 包被丢 |
| Cilium native routing | `tunnel=disabled` | ❌ | 同 direct, 不路由 pod CIDR |
| Cilium VXLAN | `tunnel=vxlan` | ⚠ 待验证 | 需非 4789 端口; 保留配置待验证 |

### 3.2 为什么 IPIP 是"唯一可靠路线"
- 跨节点流量需要**封装**, 使外层成为 fabric 认识的**节点 IP**;
- IPIP 只依赖网络放行 **IP 协议 4**(实测放行), **不依赖任何 UDP 端口** → 没有"端口被 ACL 拦"的脆弱性;
- 同网段下 IPIP 无路由寻址负担(BIRD 已自动建好节点间路由), 简洁可靠。

### 3.3 配套关键参数(每个都不能漏)
- `calico_network_backend: bird` —— **必须与数据面一致**(漏配时 kubespray 默认 `vxlan`, 而 vxlan 又禁用 → 无任何数据面 → 跨节点全断);
- `calico_mtu: 1480` —— IPIP = 物理 1500 − 20; 显式固定, 防 Felix 自动检测到 IB 网卡(MTU 2044)时误设(见 troubleshooting §一.2);
- `calico_ip_auto_method: can-reach=<首 worker>` —— 节点 IP 自动检测, 由 sync 脚本生成。

### 3.4 验证(本方案已实测通过)
```bash
kubectl -n metallb-system apply --force -f /etc/kubernetes/pools.yaml   # webhook 跨节点成功(不再超时)
sudo ./deployments/scripts/deploy-cluster.sh --steps verify_metallb      # VIP 分配 + curl HTTP 200
```

---

## 4. 原来模式的限制(避免重蹈)

> 这些方案**曾经被采用过/尝试过**, 都因 fabric 限制失败; 记录限制以防将来在同类网络重复踩坑。

### 4.1 Calico direct(无封装直连路由)
- **限制**: 要求底层网络**能路由 pod CIDR**(真实 L2 + 交换机可路由, 或配置了 BGP)。
- 本 fabric 不满足 → 跨节点 pod 100% 丢, 部署卡在 metallb 池 apply webhook `context deadline exceeded`。

### 4.2 Calico VXLAN(默认端口 4789)
- **限制**: 依赖网络放行 **UDP 4789**(VXLAN 端口)。
- 本 fabric 有专门 ACL 丢 4789 → VXLAN 隧道起不来, 跨节点断。
- 换端口(8472)可绕开, 但端口依赖脆弱, 不如 IPIP 干净。

### 4.3 Cilium native routing
- **限制**: 与 direct 相同, 需网络路由 pod CIDR; 本 fabric 不可行。
- 若要 Cilium, 需隧道模式 + 非 4789 端口(未验证)。

### 4.4 遗留 bug 教训
- **`calico_network_backend` 漏配**: kubespray 默认 `vxlan`, 与数据面模式不符 → 无数据面。sync 脚本已强制固定。
- **MTU 自动检测误判**: 需显式固定, 不能依赖自动检测(IB 网卡干扰)。

### 4.5 切换网络前必查清单
```bash
ip neigh show | grep <网段>          # 多 IP 同一 MAC = proxy-ARP fabric
nc -u <节点IP> 4789 / 8472 / 40002   # 测哪些 UDP 端口放行
ip route get <远端podIP>             # 无封装时是否 via 节点且可达
```

---

## 5. 当前部署的 Operator(架构 / 原理 / 为何采用 / 部署)

| Operator | 作用 | 架构/原理 | 为何采用 | 部署入口 |
|---|---|---|---|---|
| **Calico** | CNI(容器网络) | IPIP 封装跨节点; BIRD 分发节点间 pod 路由; Felix 数据面 | fabric 兼容性最好(见 §3); 离线镜像齐 | kubespray 内置(`kube_network_plugin=calico`) |
| **MetalLB** | 裸金属 LoadBalancer | Layer2: speaker 用 ARP 通告 VIP; controller 分配地址池 | 无云 LB 的裸金属/VM 环境标准方案; L2 通告与 IPIP 共存 | kubespray 内置 + `verify_metallb` 端到端验证 |
| **metrics-server** | HPA 依赖的指标 | kubelet Summary API 聚合 | kubespray 标准组件, HPA 必需 | `METRICS_SERVER_ENABLED=true` |
| **MetaX GPU Operator** | 沐曦 GPU 驱动/识别/调度 | helm chart + CRD(ClusterOperator)驱动组件 DaemonSet; 内置 registry 存放镜像 | 裸金属沐曦 GPU 必备; 离线 tar 加载 + helm 原生安装; master 有 GPU 时自动解除不可调度 | `GPU_OPERATOR_ENABLED=true` + 见 `docs/metax-gpu-operator.md` |
| **LeaderWorkerSet (LWS)** | LLM/AI 工作负载调度(Leader/Worker 组 + DisaggregatedSet) | 默认官方 manifests.yaml bundle(kubectl apply --server-side); helm chart 保留于 lws/charts; controller 管理 LeaderWorkerSet/DisaggregatedSet; webhook 打 `leaderworkerset.sigs.k8s.io/worker-index` 等标签 | 面向 LLM 推理/训练的组调度; 内建 DisaggregatedSet 解耦推理; 支持 cert-manager/internal 双证书 | `--steps gpu_lws`(立即部署)+ 见 `docs/lws.md` |
| **Envoy Gateway (EG)** | 通用 K8s API 网关(Gateway API 标准实现) | 控制面 `envoy-gateway` 监听 GatewayClass/Gateway/HTTPRoute → xDS 推送按需动态创建的 Envoy Proxy 数据面 Deployment; 入口经 MetalLB 分配 VIP | 统一流量入口(P1-9 刚需): 路由/限流/重试/超时/TLS/JWT 等全走标准 Gateway API; 是 Envoy AI Gateway 的基座 | `ENVOY_GATEWAY_ENABLED=true` + `--enable envoy_gateway` + 见 `docs/envoy-gateway.md` |
| **Envoy AI Gateway (AIG)** | LLM/AI 专用网关(多模型供应商统一入口/token 限流/语义缓存/failover) | 不是独立二进制: = 特制 EG 控制面 + AI 控制器(Extension Server 机制注册进 EG 的 extensionManager)+ AI CRD(AIGateway/Backend/BackendSecurityPolicy); AI 控制器把 AI CRD 翻译为 Gateway/HTTPRoute 交 EG 控制面 | AI 流量语义(token 级限流/多供应商适配/failover/guardrail)EG 本身不感知, 由 AI 层补齐; 依赖 EG 先装 | `ENVOY_AI_GATEWAY_ENABLED=true`(需 EG)+ `--enable envoy_ai_gateway` + 见 `docs/envoy-gateway.md` |

> 详细部署/开关见 `cluster.conf` 组件开关段与 `deployments/scripts/modules/`。
> 后续新增 operator 按 `skills/cubestack-operator-onboarding/SKILL.md` 流程添加并更新本表。

### 5.2 MetaX GPU Operator 架构与原理(沐曦 GPU 识别 / 调度)

- 架构: helm chart 安装 `metax-operator`(operator controller + ClusterOperator CRD); operator 依据
  ClusterOperator CR 创建组件 DaemonSet(`gpu-label` 打标 → `driver` / `container-runtime` / `maca` /
  `gpu-device` 设备插件), 设备插件把 `metax-tech.com/gpu` 注册进 kubelet allocatable。
- 镜像: 全部放集群内置 registry `registry.local:5000/metax/...`(默认 **tar 离线加载**, 也可 `.run` 内嵌推送)。
- 为何采用 helm 原生安装: 官方 chart 有 3 处 bug(deployment 缺 namespace / openshift.deploy 无默认 /
  vendor 字段空值未加引号)会在 kubectl apply 时失败; 修复 chart 后 helm install 自动装 CRD+命名空间, 最稳。
- master 节点: 用 `mx-smi` 在宿主机检测 GPU, 检测到 GPU 的 master 自动移除 control-plane 污点并 uncordon
  (供 PD 分离等 pod 调度); 无 GPU 的 master 保持默认不可调度。
- 部署/验证入口: `docs/metax-gpu-operator.md`。

### 5.3 LeaderWorkerSet (LWS) 架构与原理(LLM/AI 组调度)

- 架构: 默认官方 manifests.yaml bundle 安装 `lws-controller-manager`(Deployment, 2 副本, 内部选主)+ CRD
  (`leaderworkersets.leaderworkerset.x-k8s.io/v1` / `disaggregatedsets.disaggregatedset.x-k8s.io/v1` /
  `disaggregatedsetrolescalers.disaggregatedset.x-k8s.io/v1`)+
  Mutating/Validating Webhook(打 `leaderworkerset.sigs.k8s.io/name/worker-index` 等标签, 校验 LWS/DS 规范)。
- 证书(二选一, `LWS_CERT_MODE`):
  - `cert-manager`: 由外部 cert-manager 的 Certificate/Issuer 签发 webhook 证书(需集群已装 cert-manager);
  - `internal`: controller 内置自签证书(`--webhook-cert-dir`), 离线友好(无需外部组件)。
- DisaggregatedSet: 将 Prefill/Decode 阶段拆分为独立 worker 组(每组独立 LWS), 提升 LLM 推理
  吞吐与 SLO 稳定性; 安装后直接创建 `DisaggregatedSet` CR。
- 为何默认官方 bundle 安装: 官方 `manifests.yaml` 单文件(kubectl apply --server-side)离线 vendoring 于
  `deployments/cubestack-addon/lws/manifests.yaml`, 与内置 registry 镜像全离线; 大 CRD 不受 helm Secret 1MiB 上限。
  (helm chart 保留在 `lws/charts/`, 供 cert-manager 模式 / 自定义 values 用)。
- webhook 跨节点: 与 MetalLB controller 同理, 依赖 **Calico IPIP** 数据面可达(见 §3);
  controller 不 pinned 时默认可达。
- 部署/验证入口: `docs/lws.md`。

### 5.4 Envoy Gateway / Envoy AI Gateway 架构与原理(统一流量入口)

**Envoy Gateway(通用网关基座)**
- 架构: helm chart 安装控制面 `envoy-gateway`(Deployment, `envoy-gateway-system` 命名空间); 用户创建
  `GatewayClass eg` / `Gateway` / `HTTPRoute`(标准 `gateway.networking.k8s.io`)→ 控制面翻译为 xDS →
  gRPC 推送; 每个 Gateway 由控制器**动态创建 Envoy Proxy 数据面 Deployment + Service(LoadBalancer)**,
  MetalLB 分配 VIP → 外部 URL 可达。
- 离线要点: 控制面镜像 `envoyproxy/gateway:<v>` + **数据面镜像 `envoyproxy/envoy:<v>`**(chart values
  `image.*` / `envoyGateway.image.*` 改写为集群内置 registry; 数据面镜像不改写, 离线集群会 ImagePullBackOff)。
- 为何采用: 统一流量入口(P1-9 刚需); 标准 Gateway API 生态, 也是 Envoy AI Gateway 的基座。

**Envoy AI Gateway(AI 专用扩展层)**
- 架构: **不是独立二进制**, = 特制 EG 控制面 + AI 控制器(`ai-gateway-controller`, `ai-gateway-system`
  命名空间)+ AI CRD(`aigateway.envoyproxy.io`: AIGateway / Backend / BackendSecurityPolicy / AIGatewayRoute)。
  AI 控制器通过 EG 的 **Extension Server 机制**(`extensionManager` 注册进 EG 运行时配置)把 AI CRD
  翻译为 Gateway/HTTPRoute 交 EG 控制面; AI 语义(token 计数/模型路由/多供应商转换)由控制器经
  ext_proc/Extension Hook 注入数据面。
- 部署依赖: **必须先装 Envoy Gateway**(模块 09), AI 模块(10)前置检查强制确认 GatewayClass `eg` Accepted;
  随后 helm 装 AI CRD chart + 控制器 chart, 并 helm upgrade eg 注入 `extensionManager` 指向
  `ai-gateway-controller.ai-gateway-system.svc:18090`。
- 为何采用: LLM 流量统一入口(token 级限流/多模型供应商/failover); 与 EG 共数据面, 二件套即可覆盖
  业务 URL 与 AI 两类流量。
- 边界说明(如实标注): AI 项目迭代快(默认 v1.0 GA, API `v1beta1`), AI CRD 字段与 extensionManager
  结构随版本变化; 模块把关键字段全部走 cluster.conf(`ENVOY_AI_*`), 升级版本按官方文档核对
  `docs/envoy-gateway.md`。本仓库验证模块仅做控制面调和 + mock 数据面调用, 真实 LLM 需配置真实
  Backend + API Key(未在离线环境端到端验证过真实模型调用)。
- 部署/验证入口: `docs/envoy-gateway.md`。

### 5.1 MetalLB 架构与原理(裸金属 LoadBalancer)

**架构(两个组件 + CRD 配置)**

| 组件 | 形态 | 职责 |
|---|---|---|
| **controller** | Deployment(1 副本) | 监听 Service: 从 `IPAddressPool` 分配/释放 VIP; 通过 **webhook** 校验地址池/L2 通告 CR(池子 apply 要走它的 webhook); 维护分配状态 |
| **speaker** | DaemonSet(每节点 1) | Layer2 模式: 把 VIP 以 **ARP 应答**通告到节点网卡, 成为该 VIP 在 L2 的"入口"; 进入 VIP 的流量 → 转发给后端 pod |

**配置 CRD**(metallb 角色 apply, 池从 `cluster.conf` 的 `METALLB_POOL` 同步):
- `IPAddressPool`: 地址池, 如 `10.66.1.130-10.66.1.139`;
- `L2Advertisement`: 声明 Layer2 通告并关联池。

**数据面(外部访问流程)**
1. 外部 `curl http://VIP` → 网络 ARP 查 VIP → speaker 所在节点应答(把 VIP 的 MAC 绑到自己);
2. 流量进该节点 → 节点按 Service 规则转发到后端 pod;
3. 若后端 pod 在**另一节点** → 走 **Calico IPIP** 数据面(与 §3 一致)。

**原理(为何这样设计)**
- 裸金属/VM 无云 LoadBalancer → 需要把 VIP"注入"二层让外部能路由进来, MetalLB Layer2 是最简方案(无需 BGP/交换机支持);
- controller 与 speaker 通过 CR 协同, 数据面零耦合;
- **关键依赖**: controller 的 webhook 由 apiserver 调用, 若 controller 在远端节点 → **跨节点**, 必须依赖 IPIP 数据面可达(见 §3)。

**部署**
- kubespray 内置(`metallb_enabled: true`), 地址池由 sync 脚本从 `METALLB_POOL` 写入 `IPAddressPool`;
- 验证: `verify_metallb`(controller/speaker Ready → 池/通告 CR → 建测试 LB → 分 VIP → 池内校验 → curl HTTP 200)。

**历史 workaround(已移除)**
- 曾用 `METALLB_PIN_CONTROLLER_FIRST_MASTER` 把 controller **钉到首 master**(与 apiserver 同节点), 让 webhook 走同节点绕过"跨节点不可达";
- 原因: 当时 VXLAN 数据面在本 fabric 不可达 → 跨节点 webhook 超时;
- **现已由 Calico IPIP 根治**(跨节点数据面通), 该 workaround **已从配置与 sync 脚本移除**, controller 可自由调度。

---

## 6. 部署步骤(以 BM 集群为例)

```bash
# 1) 编辑 deployments/config/cluster.conf: NODES(节点)/ 网络 / 组件开关
#    (BM 集群: NODES 直接填 5 字段节点, vm-nodes.conf 不定义节点, METALLB_POOL=10.66.1.130-139)
# 2) 一键部署(默认 = --with-cubestack: 节点准备 → NTP → kubespray 离线安装 → 基座 + 启用的 operator)
sudo ./deployments/scripts/deploy-cluster.sh          # 全量(基座 + cluster.conf 中已启用的 operator)
sudo ./deployments/scripts/deploy-cluster.sh --with-k8s   # 仅 kubespray 基座(k8s + metallb/local-path/registry)
#    中途失败: 修复后重跑同一命令(install 会重置残留 k8s 重建); --skip k8s_deploy 可跳过
# 3) 端到端验证
sudo ./deployments/scripts/deploy-cluster.sh --steps verify_metallb
# 4) 扩容 / 组件
sudo ./deployments/scripts/deploy-cluster.sh --with-scale            # 新节点先写 NODES
sudo ./deployments/scripts/deploy-cluster.sh --steps <组件>           # 立即部署某个 operator(自动带基座, 只部署指定的)
sudo ./deployments/scripts/deploy-cluster.sh --enable <组件>          # 只写 cluster.conf 预启用(不部署, 下次全量生效)
```

**离线要点**: 镜像预加载 `PRELOAD_IMAGE_PATTERNS`(calico 默认 + cilium 备选); 离线文件目录 `${OFFLINE_FILES_DIR}/<集群>/images/`(默认 `deployments/offline-files/kubespray/<集群>/images/`)。

---

## 7. 新增 operator 的标准流程

新增/替换 operator 必须走 `skills/cubestack-operator-onboarding/SKILL.md`:
1. 按现有模块模型写 `deployments/scripts/modules/<PHASE>/NN_<name>.sh`(元数据头 + TOGGLE);
2. 配置进 `cluster.conf`, 由 sync 脚本同步;
3. 写 `verify_<name>.sh` 端到端验证(参考 `21_verify_metallb.sh`);
4. 更新本文件 §5 表 + `troubleshooting.md` + `SKILL.md`。
