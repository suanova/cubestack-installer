# CubeStack 集群架构与网络设计

> 记录**当下实际部署**的 Kubernetes 集群、网络架构、各 operator 的设计与部署步骤, 以及历史方案的**限制**(避免将来重蹈覆辙)。
> 与 `troubleshooting.md`(问题排查)互补; 本文件是"架构为什么是这样"的权威说明。
> 新增 operator 时, 按 `skills/cubestack-operator-onboarding/SKILL.md` 的标准流程更新脚本与本文件。

---

## 1. 当前部署的集群

本项目用同一套脚本(`deployments/scripts/deploy-cluster.sh`)驱动两种环境的离线部署, 差异仅在 `cluster.conf` 的 `NODES` 与网络配置。

| 环境 | 节点 | 网络 | 用途 |
|---|---|---|---|
| **VM 集群** | master01-03 + worker01-04, 全部 `node_type=vm` | libvirt 桥 `privbr0`, 网段 `10.244.0.0/16`(节点 `10.244.1.x`) | 开发/验证、离线链路自测 |
| **BM 集群** | 9 台裸金属 `mxgpu-*`(3 master + 6 worker), `node_type=bm` | 物理网段 `10.66.1.0/24`, 但底层是 **proxy-ARP 虚拟化 fabric**(见 §2) | 生产目标 |

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
#    (BM 集群: 全部 node_type=bm, METALLB_POOL=10.66.1.130-139)
# 2) 一键部署(含: 节点准备 → NTP → kubespray 离线安装 → metallb 等基座)
sudo ./deployments/scripts/deploy-cluster.sh --with-k8s          # 仅 kubespray 基座(k8s + metallb/local-path/registry)
sudo ./deployments/scripts/deploy-cluster.sh --with-cubestack    # 基座 + cluster.conf 中已启用的 operator(如 GPU_OPERATOR_ENABLED=true → gpu_operator)
#    中途失败: 修复后重跑同一命令(install 会重置残留 k8s 重建); --skip k8s_deploy 可跳过
# 3) 端到端验证
sudo ./deployments/scripts/deploy-cluster.sh --steps verify_metallb
# 4) 扩容 / 组件
sudo ./deployments/scripts/deploy-cluster.sh --with-scale            # 新节点先写 NODES
sudo ./deployments/scripts/deploy-cluster.sh --enable <组件>          # 组件开关
```

**离线要点**: 镜像预加载 `PRELOAD_IMAGE_PATTERNS`(calico 默认 + cilium 备选); 离线文件目录 `${OFFLINE_FILES_DIR}/<集群>/images/`(默认 `deployments/offline-files/kubespray/<集群>/images/`)。

---

## 7. 新增 operator 的标准流程

新增/替换 operator 必须走 `skills/cubestack-operator-onboarding/SKILL.md`:
1. 按现有模块模型写 `deployments/scripts/modules/<PHASE>/NN_<name>.sh`(元数据头 + TOGGLE);
2. 配置进 `cluster.conf`, 由 sync 脚本同步;
3. 写 `verify_<name>.sh` 端到端验证(参考 `21_verify_metallb.sh`);
4. 更新本文件 §5 表 + `troubleshooting.md` + `SKILL.md`。
