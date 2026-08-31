# CubeStack 部署 Troubleshooting 手册

> **规范(强制)**:每次解决完一个部署/运行问题,**找到真正的 root cause**,按下面的模板把「症状 → 根因 → 解法 → 验证」更新到本文件(新增一个条目),保持按问题类型分组。这样同类问题下次直接命中根因,不用重新排查。
> 新增条目同时把新知识点/命令沉淀到 `skills/cubestack-deploy-scripts/SKILL.md` 的相应章节。

## 约定

- 每个条目: `### <编号>. <一句话症状>`
- 每条必须写明: **症状 / 根因 / 解法(根治) / 验证 / 相关命令**
- 按问题类别分组: 网络(CNI) / 时间同步 / 集群组件 / 离线部署 / 其它

---

## 一、网络 / CNI

### 1. 【标准排查】任何服务的 admission webhook "context deadline exceeded"(metallb / cert-manager / operator / CRD conversion 通用)

**症状**
```
failed calling webhook "xxxvalidationwebhook.xxx.io": Post "https://<svc>.<ns>.svc:443/...": context deadline exceeded
```
任何服务的 webhook 调用超时(注意:是 timeout 而非 x509 cert 错误)。

**根因(以证据判定,通常在网络层)**
> ⚠ **该问题已确认是裸金属特有**: 物理交换机/管理网段会拦截 VXLAN 端口 4789。已验证 **VM 环境(标准 libvirt/虚拟网桥)无此问题** —— webhook HTTP 200(controller 在远端节点)、LB VIP 可达(后端在远端节点),跨节点全通。
> 若在 VM 环境复现不了,基本可判定为裸金属网络问题(见下方 4789 判定证据)。

所有 webhook 调用路径: `kube-apiserver → webhook-service ClusterIP → kube-proxy(DNAT) → webhook pod`。
- apiserver 运行在**首控制面节点**;若 webhook pod 在**其它节点**,请求与**回包**都要跨节点走 CNI overlay(VXLAN = UDP **4789**);
- 若网络把「进入首控制面节点的 UDP 4789」丢弃,则**回包永远进不来** → 任何远端 webhook 都超时;
- 判定证据(在首控制面节点上):
  1. `ip -s link show vxlan.calico` → **RX=0**(一个包收不到)而 TX 正常;
  2. 其它节点发**原始 UDP** 到 `首控制面IP:4789`,首控制面 `tcpdump -ni manage0 "udp port 4789"` **0 包到达**;
  3. 对照:发 UDP 到首控制面 `:40002` **能收到** → 证明是「端口 4789 到该节点被网络丢弃」,主机 UDP 本身正常。

**解法(根治 = 网络侧)**
- 让网络管理员放行 **UDP 4789(VXLAN)进入所有集群节点,尤其首控制面**;检查:交换机 ingress ACL、管理网段策略、DHCP Snooping / IP Source Guard。
- 放行后跨节点 VXLAN 全通,所有 webhook / LB VIP / pod 互访一次性恢复。

**workaround(已验证: 只解决「部署/安装卡死」, 不解决跨节点 LB 数据面)**
- 把该服务的 webhook pod **钉到首控制面**(如 metallb controller 加 `nodeSelector: kubernetes.io/hostname: <首master>`),webhook 走同节点,不依赖 4789 回包。
- ✅ **能解决**: 该服务的 webhook 调用、以及部署流程(如 metallb 池子 apply)恢复正常。
- ⚠️ **不能解决**: 跨节点负载均衡数据面 —— 若后端 pod 在其它节点,LB VIP 回包仍需 4789 进首控制面,网络不放行则 LB 不可达。要彻底可用必须网络侧放行 UDP 4789。
- ⚠️ **换环境必须清理该 pin**: 该 nodeSelector 按主机名钉死,换到另一批节点(如裸金属 → VM)会残留旧主机名 → controller 永远调度不上(见 §三.1)。
- ℹ️ **该 workaround 已移除(2026-08-22)**: 改用 **Calico IPIP** 数据面后,跨节点 webhook 本身可达,无需再钉 controller(见 `docs/cluster-architecture.md` §5.1)。此处仅留历史记录。

**相关命令**
```bash
ip -s link show vxlan.calico | grep -A1 RX:    # RX=0 → 跨节点收包坏
sudo timeout 8 tcpdump -ni manage0 "udp port 4789"   # 本机 4789 是否到达
# 对照(本机能收 40002 → 主机 UDP 正常, 是 4789 被网络拦):
sudo nc -l -u 40002 &  ;  echo test | nc -u <本机IP> 40002
```

---

### 2. 【裸金属】Calico VXLAN MTU 误判(IB 网卡 2044)→ 跨节点链路断裂 → 部署卡在 MetalLB 池 apply webhook 超时

**症状**
```
TASK [kubernetes-apps/metallb : MetalLB | Create address pools configuration]
fatal: failed calling webhook "ipaddresspoolvalidationwebhook.metallb.io":
  Post "https://webhook-service.metallb-system.svc:443/...": context deadline exceeded
```
重试(10×5s)耗尽仍失败。metallb pods 显示 Running,但池子永远建不出来;从首 master `ping <远端 pod IP>` 100% loss。

**根因(独立于 §一.1 的 4789, 需分别排查)**
> ⚠ 若 `ip -s link show vxlan.calico` **RX=0**,首要根因是 §一.1 的「4789 被网络丢弃」,先处理网络放行;本条 MTU 误判是**另一独立根因**,两者都修才彻底。
1. **Calico VXLAN MTU 自动检测误判**: 裸金属机有 InfiniBand 网卡(`ibs2/ibs3`, MTU=**2044**)。Felix 自动检测 underlay MTU 读到 2044,想把 `vxlan.calico` 隧道 MTU 设成 **2044−50=1994**,但隧道实际绑在 `manage0`(MTU 1500),内核拒绝 `mtu: invalid argument`(合法上限 1500−50=**1450**)。
   → Felix 每 10s 重试一次,隧道持续抖动。日志特征:`felix/vxlan_mgr.go 727: VXLAN device MTU needs to be updated new=1994 old=1450 ... Failed to set vxlan tunnel device MTU error=invalid argument`。
2. **跨节点 host→pod 路由断裂**: 隧道抖动 → apiserver(首 master)访问其他节点上的 pod 100% 丢包。判定:从首 master `ping <远端 pod IP>` 100% loss;`ip -s link show vxlan.calico` 的 **RX=0**(一个包都收不到)而 TX 正常。
3. metallb controller 被调度到**远端 worker**,apiserver→webhook ClusterIP 必须跨节点 → 走断裂的 VXLAN → `context deadline exceeded`。

**解法(根治,按优先级)**
- `k8s-net-calico.yml` 显式固定 `calico_mtu: 1450`(VXLAN 模式 = 物理网卡 1500 − 50)。避免 Felix 自动检测踩 IB 2044。**下次全新安装不再复现。**
- 已坏集群无法回溯修复: 把 **metallb controller 钉到首个 master**(与 apiserver 同节点),webhook 走同节点本地 pod 网络,不依赖 VXLAN(即 §一.1 的 workaround,注意换环境须清理):
  ```bash
  kubectl -n metallb-system patch deployment controller --type=merge \
    -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"<首个master主机名>"}}}}}'
  ```
- metallb 角色已加: 等 `crd/ipaddresspools.metallb.io` `Established` 后 `rollout restart` controller,再 apply 池子(消除 CRD 建立与 informer 启动的竞态)。

**验证**
- `kubectl -n metallb-system get ipaddresspools` 出现池子;`get l2advertisements` 出现 primary;
- 建个 LoadBalancer Service → 事件 `IPAllocated`,EXTERNAL-IP 落在池内;`ping <LB VIP>` 出现 `Redirect Host(New nexthop: <VIP>)` = L2 ARP 通告已生效;
- `sudo ./deploy-cluster.sh --steps verify_metallb` 端到端通过(分配 VIP + 池内校验 + curl 可达)。

**相关命令(排查三板斧)**
```bash
# 1) felix MTU 抖动(本条根因)
kubectl -n kube-system logs ds/calico-node | grep -E "vxlan.*mtu|Failed to set"
# 2) 本机 VXLAN 收包是否正常(RX=0 → 另见 §一.1 的 4789)
ip -s link show vxlan.calico | grep -A1 RX:
# 3) 跨节点 host→pod 连通性
ping -c3 <远端 pod IP>
# 4) metallb 是否认识池子(CRD 竞态时 controller 会报)
kubectl -n metallb-system logs deploy/controller | grep -E "no matches for kind"
```

### 3. 跨节点 pod 全断 / webhook 超时: proxy-ARP 虚拟化 fabric(非真 L2)不路由 pod CIDR —— 用 IPIP 封装

**症状**
- direct 路由(无封装)下跨节点 pod 100% 丢包, 部署卡在 metallb 池 apply webhook `context deadline exceeded`;
- 节点虽同网段(如 10.66.1.0/24), 但跨节点 pod 流量发出去即丢, 同节点 pod 可达。

**根因(以证据判定)**
1. `ip neigh` 发现**所有节点 IP(含网关)的 ARP 都解析到同一个 MAC**(如 `00:01:00:01:00:01`), 而各节点真实 manage0 MAC 各不相同 → 网络是 **proxy-ARP / 按 IP 转发**的虚拟化 fabric,**不是真实 L2**;
2. 该 fabric **只转发节点 IP**(SSH / UDP 40002 / 8472 / IPIP-proto4 都通), **不路由 pod CIDR(如 10.233.x)** → direct 路由直接发 pod 包被丢;
3. 该 fabric **丢弃 UDP 4789**(VXLAN 端口有专门 ACL, 但 40002 / 8472 通)。
→ 结论: 无封装 direct/native 路由在此类网络**不可行**; VXLAN 用 4789 也不可行。

**解法(根治)**
- **用 IPIP 封装(默认)**: `CALICO_DATA_PATH=ipip` → `calico_ipip_mode=Always` + `calico_network_backend=bird` + `mtu=物理-20=1480`。
  外层=节点 IP(IPIP/proto4, fabric 实测放行) → 每节点本地解封装 → 跨节点 pod/webhook/LB 全通。
  实测: 地址池 apply webhook 从超时 → 成功; `verify_metallb` 端到端通过(**pin workaround 可关闭**)。
- VXLAN 可选: `CALICO_DATA_PATH=vxlan` + `CALICO_VXLAN_PORT=8472`(非 4789, fabric 放行)。
- `direct` 仅适用于真实 L2 且网络能路由 pod CIDR 的环境。

**验证**
- `kubectl -n metallb-system apply --force -f /etc/kubernetes/pools.yaml` → 成功(不再 webhook 超时);
- `sudo ./deployments/scripts/deploy-cluster.sh --steps verify_metallb` → VIP 在池内 + curl HTTP 200。

**相关命令**
```bash
ip neigh show | grep 10.66.1     # 多个 IP 同一 MAC = proxy-ARP fabric
ip route get <远端pod IP>         # via 节点(非网关)但丢包 = fabric 不路由 pod CIDR
# 测 fabric 放行哪些 UDP 端口(4789 丢 / 8472 40002 通):
ssh <节点> 'timeout 6 tcpdump -ni manage0 "udp port 8472" &'
echo x | nc -u <节点IP> 8472
```

---

## 二、时间同步

> (示例占位) setup-ntp.sh 时钟偏差误报 —— 见该脚本注释与 git 历史;后续问题按模板追加。

---

## 三、集群组件

### MetalLB 部署故障速查(先对号入座)

MetalLB 部署失败有**三类互不相干**的根因,先按症状定位,避免把网络问题当组件问题排查:

| 症状 | 判定 | 根因 | 见条目 |
|---|---|---|---|
| 部署卡在 pool apply:`webhook context deadline exceeded` | 跨节点 ping 丢包 / `vxlan.calico` RX=0 | **网络**: VXLAN 4789 被丢弃 或 Calico MTU 误判 | §一.1 / §一.2 |
| controller 永久 `Pending`:`0/N nodes didn't match node selector` | `describe` 见 `Node-Selectors` 残留旧主机名 | **配置**: addons.yml 残留 `kubernetes.io/hostname`(旧环境) | 三.1 |
| `verify_metallb`:`VIP 是 .0/.255` | 池是整段 CIDR | **配置**: `METALLB_POOL` 含网络/广播地址 | 三.2 |

### 1. MetalLB controller 永久 Pending(残留旧环境主机名 nodeSelector)+ speaker 全报 secret "memberlist" not found

**症状**
```
TASK [kubernetes-apps/metallb : Kubernetes Apps | Wait for MetalLB controller to be running]
fatal: [cubestack-k8s-master01]: FAILED!  error: timed out waiting for the condition
```
- controller Pod `STATUS= Pending`, 事件: `0/7 nodes are available: 7 node(s) didn't match Pod's node affinity/selector`;
- 所有 speaker Pod `STATUS= CreateContainerConfigError`, 事件: `Error: secret "memberlist" not found`;
- `describe` controller 可见 `Node-Selectors: kubernetes.io/hostname=<旧环境主机名>`(如 `mxgpu-1-232`)。

**根因**
`inventory/<集群>/group_vars/k8s_cluster/addons.yml` 中 `metallb_config.controller.nodeselector` 残留了**上一环境(裸金属)的主机名**(该 pin 本是 §一.1 的 webhook workaround,按主机名钉 controller)。当前环境没有该主机名节点 → controller **永远调度不上**(一直 Pending)。
**连锁效应**: controller 从不启动 → 不会在启动时自动创建 `memberlist` secret(MetalLB v0.13.x 由 controller 自动创建, 无需写进模板)→ speaker 因 `secret "memberlist" not found` 全部 CreateContainerConfigError。
> ⚠ `memberlist` secret 缺失是**结果不是根因**; 不要往模板里加该 Secret —— 上游 kubespray 模板即依赖 controller 自建(controller Role 已有 secrets CRUD 权限)。

**解法(根治)**
- 删掉 addons.yml 中 controller.nodeselector 里残留的 `kubernetes.io/hostname` 行(环境已非裸金属时);
- `sync-kubespray-config.sh` **已移除该 workaround 段(2026-08-22)**: 改用 Calico IPIP 后跨节点 webhook 可达, 不再需要钉 controller; addons.yml 的 `controller.nodeselector` 仅保留 `kubernetes.io/os: linux`。此条仅留历史记录(见 `docs/cluster-architecture.md` §5.1)。
- 已坏集群快速验证/恢复(无需重跑部署):
  ```bash
  kubectl -n metallb-system patch deployment controller --type=json \
    -p='[{"op":"remove","path":"/spec/template/spec/nodeSelector/kubernetes.io~1hostname"}]'
  # controller 起后自动建 memberlist secret, speaker 自动恢复
  ```

**验证**
- `kubectl -n metallb-system get pods` → controller 1/1 Running, 全部 speaker 1/1 Running;
- `kubectl -n metallb-system get secret memberlist` → 存在(controller 启动时自建, age 与 controller 一致);
- 重跑 `sudo ./deploy-cluster.sh --steps k8s_deploy` 通过;`get ipaddresspool / l2advertisement` 出现池子;
- `sudo ./deploy-cluster.sh --steps verify_metallb` 端到端通过。

**相关命令**
```bash
kubectl -n metallb-system describe pod -l app=metallb,component=controller | grep -A2 "Node-Selectors"
kubectl -n metallb-system describe pod -l app=metallb,component=speaker | grep -B1 "memberlist"
```

---

### 2. verify_metallb 失败: LoadBalancer 分到 .0/.255 网络/广播地址(METALLB_POOL 用了整段 CIDR)

**症状**
```
④ 等待 LoadBalancer 分配到池内 VIP...
   已分配 VIP: 10.244.2.0
⑤ 校验 VIP 在 METALLB_POOL=10.244.2.0/24 内...
【错误】VIP 10.244.2.0 是网络/广播地址(.0/.255)...
```
偶发: 同一池子有时分到 `.1`(通过), 有时分到 `.0`(失败)—— 与每次分配顺序有关, 易误判为"不稳定/flaky"。

**根因**
`METALLB_POOL` 默认写成了**整段 CIDR**(如 `10.244.2.0/24`)。MetalLB 对 CIDR 池**不会自动跳过 .0(网络地址)与 .255(广播地址)**, 会原样分配 → 分到不可用的网络地址, LB 实际不可达。
> `cluster.conf` 曾与 `cluster.conf.example` / `sync-kubespray-config.sh` 默认(区间 `10.244.2.1-10.244.2.254`)**不一致**, 是真实集群配置把默认值改回了 CIDR。

**解法(根治)**
- 池写成**起止区间**, 排除 .0/.255:`METALLB_POOL="${METALLB_POOL:-10.244.2.1-10.244.2.254}"`;
- 重新同步并应用: `bash sync-kubespray-config.sh` 更新 addons.yml `ip_range` → `kubectl -n metallb-system patch ipaddresspool primary --type=merge -p '{"spec":{"addresses":["10.244.2.1-10.244.2.254"]}}'`;
- (备选)保留 CIDR 但给池开 `avoidBuggyIPs: true`(`pools.yaml.j2` 已支持 `pool.avoid_buggy_ips`)。

**验证**
- `kubectl -n metallb-system get ipaddresspool primary -o jsonpath='{.spec.addresses}'` → `["10.244.2.1-10.244.2.254"]`;
- `sudo ./deploy-cluster.sh --steps verify_metallb` → VIP 落在区间内(如 .1),curl HTTP 200。

**相关命令**
```bash
kubectl -n metallb-system get ipaddresspool primary -o yaml | grep -A3 addresses
grep -n METALLB_POOL config/cluster.conf
```

---

### 3. 沐曦 MetaX GPU Operator 部署故障速查

> 部署/验证入口与镜像准备见 `docs/metax-gpu-operator.md`。以下问题均已在 9 节点(3 master+6 worker, 69 GPU)端到端验证根治。

#### 3.1 operator 反复 CrashLoop, 日志报 `clusterversions.config.openshift.io "version" is forbidden`

**症状**
```
unable to create controller {"controller": "ClusterOperator", "error":
"failed to get cluster version: clusterversions.config.openshift.io \"version\" is forbidden:
User \"system:serviceaccount:...:metax-operator\" cannot get resource \"clusterversions\" ..."}
```

**根因**
- 未设 `--set cluster.type=k8s`(标准 K8s 上 operator 默认探测 OpenShift API 直接崩溃);
- **或** ClusterOperator CR 未创建(CRD 未 Established 时 apply 会报 `no matches for kind ClusterOperator`,
  operator 无 CR 就没有 cluster.type 配置 → 探测 OpenShift)。

**解法(根治)**
- chart 修复 + helm install 时 `--set cluster.type=k8s --set cluster.version=<K8S版本>`(模块已做);
- CRD 必须先 Established(`kubectl wait --for=condition=Established crd/clusteroperators.gpu.metax-tech.com`)再 apply/helm;
- chart 模板 `openshift.deploy` 默认 false(否则 CRD 要求 `spec.openshift` 有值而渲染为空 → 校验失败)。

**验证**
- `kubectl -n metax-operator get pods | grep metax-gpu-operator` → `1/1 Running`; 日志不再有 OpenShift 探测错误。

**相关命令**
```bash
kubectl -n metax-operator logs -l app.kubernetes.io/component=metax-operator --tail=30
kubectl get crd clusteroperators.gpu.metax-tech.com -o jsonpath='{.status.conditions[?(@.type=="Established")].status}'
```

#### 3.2 helm 安装失败: `ClusterRole "metax-pre-delete" ... exists and cannot be imported ... missing key "app.kubernetes.io/managed-by"`

**症状**
```
Error: unable to continue with install: ClusterRole "metax-pre-delete" ... exists and cannot be imported
into the current release: invalid ownership metadata; missing key "app.kubernetes.io/managed-by": must be set to "Helm" ...
```

**根因**
之前用 `kubectl apply` 装的资源(尤其**集群级** ClusterRole/RoleBinding)没有 Helm 所有权标签, helm 拒绝接管。

**解法(根治)**
- 统一改 **helm 原生安装**(修复 chart 后 `helm upgrade --install`);
- 每次重部署先清理残留: CR/CRD/命名空间/default 旧资源 + **集群级 metax ClusterRole/RoleBinding**(模块已做)。

**验证**
- `helm ls -n metax-operator` 显示 `metax-gpu-operator` deployed。

**相关命令**
```bash
kubectl get clusterrole,clusterrolebinding -o name | grep metax   # 看残留
```

#### 3.3 `skopeo copy docker-daemon:...` 报 `client version 1.22 is too old`

**症状**
```
initializing source docker-daemon:harbor.isuanova.com/metax/maca:...: loading image from docker engine:
Error response from daemon: client version 1.22 is too old. Minimum supported API version is 1.44
```

**根因** 本机 docker 较新, skopeo 的 `docker-daemon:` 传输协商的 API 版本过旧。

**解法(根治)** 改用 `docker save` 成 tar + `skopeo docker-archive` 推送(模块 `push_extra` 已实现):
```bash
docker save <img> -o /tmp/x.tar && skopeo copy docker-archive:/tmp/x.tar docker://registry.local:5000/metax/<name>:<tag> --dest-tls-verify=false --dest-no-creds
```

#### 3.4 `metax-k8s-images.<ver>.run push` 报 `ctr: image "--plain-http": not found`

**根因** 工具的 ctr 分支把 `--plain-http` 放在镜像 ref **之后**(`push <ref> --plain-http`), 新版 ctr 把 flag 当镜像名。

**解法(根治)** 不用工具自带 push: `.run ctr load` 把内嵌镜像加载进宿主 ctr, 再逐组件
`ctr -n k8s.io images tag <src> registry.local:5000/metax/<comp>:<ver>` + `ctr -n k8s.io images push --plain-http <dst>`(flag 在前)。

#### 3.5 宿主机 curl `registry.local:5000` / helm 连 `k8s-api.nova.local` 失败(EOF / no route to host)

**根因** 宿主机 /etc/hosts 残留旧 IP(如 `10.66.3.37` = 宿主机自身)或 DNAT 被历史规则遮蔽(两条规则指向 10.244.2.100 与 10.66.1.130, 旧规则先命中)。

**解法(根治)** 每次部署由模块修正 /etc/hosts:
```
registry.local → REGISTRY_IP(集群 registry VIP, 如 10.66.1.130)
k8s-api.nova.local → API_IP(全裸金属=第一个 master, 如 10.66.1.232)
```
不留 10.66.3.37 这类过期条目。

#### 3.6 driver / maca 镜像拉不到(`ErrImagePull: ... not found`)

**根因** `driver-image` 与 `maca` **不在** `metax-k8s-images.<ver>.run` 包内, 需单独推送; 即使 PreferHost 驱动 DS 的 init 容器也要拉 `driver-image`(解包内核模块)。

**解法(根治)** 模块 `push_extra` 按 本地 docker(`docker save`+skopeo) → 离线 tar(METAX_OFFLINE_DIR) → 在线 逐级推送; `METAX_DRIVER_VERSION` 须与本地可用镜像匹配(如 `3.8.1.6-amd64`)。

#### 3.7 master 节点没有 `metax-tech.com/gpu.installed` 标签 / GPU 用不上

**根因** metax 组件 DS 默认**无 control-plane 容忍**, 调度不到(带 NoSchedule 污点的)master → gpu-label 不给 master 打标。

**解法(根治)** 部署时在宿主机用 `mx-smi` 检测 GPU(`sudo mx-smi | grep "Attached GPUs"`), 检测到 GPU 的 master 自动移除 control-plane/master 污点并 uncordon(模块已实现); 无 GPU 的 master 保持不可调度。

**相关命令**
```bash
sudo mx-smi 2>/dev/null | grep "Attached GPUs"   # count>0 即有沐曦 GPU
sudo ./deploy-cluster.sh --steps verify_metax_gpu   # 看各节点 GPU 识别/可调度清单
```

#### 3.8 driver 容器 CrashLoop: `could not unload metax: resource temporarily unavailable`(policy: prefercloud)

**症状**
```
{"[M]":"State{config..}","level":"info","msg":"metax version: running (3.9.6) target (3.3.12), tag (cloud) policy: prefercloud"}
{"[M]":"State{reload..}","level":"error","msg":"could not unload metax: resource temporarily unavailable"}
resource temporarily unavailable
```

**根因** `METAX_DRIVER_DEPLOY_POLICY` 用了 `PreferCloud`: 驱动管理器尝试**卸载宿主已装的内核驱动**(3.9.x)并安装
容器化 cloud 驱动, 但 GPU 驱动在运行中无法卸载 → reload 失败 → CrashLoop。

**解法(根治)** 本集群节点已有宿主驱动, 用 `PreferHost`:
```
cluster.conf: METAX_DRIVER_DEPLOY_POLICY="${METAX_DRIVER_DEPLOY_POLICY:-PreferHost}"   # 已改默认
```
改后需重跑部署让 CR 更新(`--fresh` 或手动 patch 后重跑)。

**验证** `kubectl -n metax-operator get pods | grep metax-driver` → `1/1 Running`, 日志不再有 `could not unload`。

**相关命令**
```bash
kubectl -n metax-operator logs -l app=metax-driver --tail=20
grep METAX_DRIVER_DEPLOY_POLICY config/cluster.conf
```

---

### 4. LeaderWorkerSet (LWS) 部署故障速查

**症状/排查对照**

| 症状 | 根因 | 解法(根治) |
|---|---|---|
| controller CrashLoop, 日志 `cert dir /tmp/k8s-webhook-server/serving-certs` 不存在 | internal 模式未传 `--webhook-cert-dir` 或 chart 未挂 cert 卷 | chart 的 deployment 模板传 `--webhook-cert-dir` 并挂载 Secret 卷(见 `deployments/cubestack-addon/lws/charts/templates/deployment.yaml`) |
| webhook 证书 x509 错误(cert-manager 模式) | 集群未装 cert-manager, Certificate 未生成 Secret | 改用 `LWS_CERT_MODE=internal`(离线友好)或先装 cert-manager |
| webhook `context deadline exceeded` | 跨节点 fabric 数据面(与 §一.1 通用) | 确认 Calico IPIP 数据面可用(默认已根治, 见 `cluster-architecture.md` §3) |
| 测试 LeaderWorkerSet 一直 Pending | busybox 镜像未预加载 / 节点资源不足 | 确认 `PRELOAD_IMAGE_PATTERNS` 含 busybox 与 `lws_manager`; `kubectl describe pod` 看事件 |
| 部署后 `--steps verify_lws` 报 leader/worker 识别失败 | v0.10 用 `leaderworkerset.sigs.k8s.io/worker-index` 标签(=0 为 leader, >0 为 worker; 旧 `lws.io/role` 已废弃) | `kubectl -n lws-system logs deploy/lws-controller-manager`; 检查 webhook 配置与证书; 用 `tools/k8s/verify-lws.sh` 复跑 |

**验证**
```bash
sudo ./deploy-cluster.sh --steps verify_lws
kubectl -n lws-system get pods
kubectl get crd leaderworkersets.leaderworkerset.x-k8s.io disaggregatedsets.disaggregatedset.x-k8s.io
```

**相关命令**
```bash
kubectl -n lws-system logs deploy/lws-controller-manager --tail=30
kubectl -n lws-system get secret lws-webhook-server-cert   # internal 模式应为存在
kubectl get validatingwebhookconfiguration lws-validating-webhook-configuration -o yaml
```

---

### 5. Envoy Gateway / Envoy AI Gateway 部署故障速查

> 分析/部署/使用详见 `docs/envoy-gateway.md`。

**症状/排查对照**

| 症状 | 根因 | 解法(根治) |
|---|---|---|
| `09_envoy_gateway.sh` 报 "EG chart 目录不存在/缺 Chart.yaml" | 离线 chart 未备料(联网机未跑 fetch 工具) | 联网机执行 `tools/images/envoy-fetch-charts.sh`(或手动 helm pull gateway-helm 解包)后拷到 `deployments/cubestack-addon/envoy-gateway/eg/` |
| 部署报 "未找到 envoyproxy/gateway:... 镜像" | 离线镜像未备料 | 联网机执行 `tools/images/envoy-save-images.sh`, tar 放入 `deployments/offline-files/envoy/`(或本地 docker daemon 先 docker pull); 已备 tar 可单独跑 `tools/images/envoy-load-images.sh` 预加载 |
| 部署后控制面/certgen 或数据面 pod `ImagePullBackOff`(docker.io 不可达) | chart 镜像未改写为集群内置 registry(gateway-helm v1.9.1 正确路径: 控制面/certgen `deployment.envoyGateway.image.repository/tag`, 数据面 `global.images.envoyProxy.image`; 旧写法 `image.repository` / `envoyGateway.image.*` 顶层不存在, 无效果) | 确认 09 模块 helm 安装已注入上述正确 `--set`; 已装错可 `helm upgrade eg <chart> --set deployment.envoyGateway.image.repository=registry.local:5000/envoyproxy/gateway --set deployment.envoyGateway.image.tag=v1.9.1 --set global.images.envoyProxy.image=registry.local:5000/envoyproxy/envoy:distroless-v1.39.1` 修复(certgen Job 会随模板变化重建), 或直接重跑 09 模块(内部先 delete ns) |
| 创建 Gateway 后数据面 pod `CrashLoopBackOff`, 日志 `PARSE ERROR: Argument: --cpuset-threads` | **数据面 envoy 镜像 tag 用错**(用了 EG 版本号如 `envoy:v1.9.1`, 拉到远古 Envoy; EG 1.9.x 配套数据面 tag 应为 `ENVOY_PROXY_VERSION`=distroless-v1.39.1, 用 `kubectl exec deploy/envoy-gateway -- envoy-gateway version` 核对) | 09 模块已改为 `push_one envoy ... ${ENVOY_PROXY_VERSION}` + helm `global.images.envoyProxy.image` 用 ENVOY_PROXY_VERSION; 已错: 在联网机用 envoy-save-images.sh(已修)重新 save `envoyproxy/envoy:distroless-v1.39.1`, 离线推入 registry 后重跑 09 模块 |
| `GatewayClass eg` 未 Accepted | 控制面未就绪 / controllerName 不匹配 | `kubectl -n envoy-gateway-system logs deploy/eg --tail=50`; GatewayClass 的 `spec.controllerName` 必须是 `gateway.envoyproxy.io/gatewayclass-controller` |
| Gateway 一直没 VIP(ADDRESS 空) | MetalLB 池耗尽/网段冲突, 或数据面未起来 | `kubectl describe gateway` 看条件; `kubectl get svc -n <gw-ns>` 看 LoadBalancer pending 原因(参考 §三.1/§三.2) |
| `10_envoy_ai_gateway.sh` 报 "未检测到 Envoy Gateway(GatewayClass eg 未 Accepted)" | AI 依赖 EG, 但 EG 未装/未就绪 | 先 `ENVOY_GATEWAY_ENABLED=true` 部署模块 `envoy_gateway`, 再装 AI |
| AI 控制器 pod CrashLoop / webhook 不生效(v1.x) | `envoyGateway.namespace` 未指向 EG 命名空间 / EG 版本不匹配(AI 与 EG 版本兼容矩阵) | 确认模块 10 helm 安装注入 `--set envoyGateway.namespace` = `envoy-gateway-system`(`kubectl -n ai-gateway-system get deploy ai-gateway-controller -o yaml \| grep envoyGatewayNamespace`); 核对 AI↔EG 版本兼容矩阵 |
| AI CRD apply 报 `no matches for kind "AIGateway"` | v1.x 无 AIGateway/Backend CRD(改为 AIServiceBackend/AIGatewayRoute); 或 CRD 未装 | `kubectl get crd \| grep aigateway`; 按 `docs/envoy-gateway.md` §4.2 / 官方 `examples/basic/basic.yaml` 使用 v1.x 资源 |
| 部署报 "未找到 skopeo" | 推送镜像到集群内置 registry 需要 `skopeo` | 宿主机安装 `skopeo`(如 `apt install skopeo`), 或使用项目 CLI 镜像(`tools/docker/build-cli-context.sh` 内置 skopeo-1.16.1-amd64) |

**验证**
```bash
sudo ./deploy-cluster.sh --steps verify_envoy_gateway      # 控制面 + GatewayClass + VIP + 真实 HTTP 转发
sudo ./deploy-cluster.sh --steps verify_envoy_ai_gateway   # AI 控制器 + CRD + 资源调和(运行时 CRD 版本自动分支)
sudo ./scripts/tools/images/envoy-load-images.sh           # (可选)独立预加载镜像到集群内置 registry
kubectl get gatewayclass,gateway,httproute -A
kubectl get aiservicebackend,aigatewayroute -A
```

**相关命令**
```bash
kubectl -n envoy-gateway-system get pods,cm envoy-gateway    # EG 控制面 + 运行时配置
kubectl -n ai-gateway-system logs deploy/ai-gateway-controller --tail=50
kubectl -n <gw-ns> get deploy -l gateway.envoyproxy.io/owning-gateway-name=<gw> -o jsonpath='{.items[0].spec.template.spec.containers[0].image}'   # 数据面镜像
```

---

## 四、离线部署

### 1. 【单机/重装】`Drain node` → `Remove-node | List nodes` 报 `error: stat /etc/kubernetes/admin.conf: no such file or directory`

**症状:** kubespray `cluster.yml` 跑到 `container-engine/validate-container-engine`
(`tasks/main.yml:112` "Drain node") 后失败:

```
fatal: [cmxgpu-1-232]: FAILED! => {"cmd": ["/usr/local/bin/kubectl", "--kubeconfig",
"/etc/kubernetes/admin.conf", "get", "nodes", ...],
"stderr": "error: stat /etc/kubernetes/admin.conf: no such file or directory"}
```

**根因:** 节点之前用 **docker** 部署过 k8s,残留了 `/etc/systemd/system/kubelet.service`
unit + 正在运行的 docker。本次 `container_manager=containerd`,kubespray 检测到 docker
在运行 → 进入 "Uninstall docker" 流程;但该流程 drain 前的守卫条件是
`kubelet_systemd_unit_exists.stat.exists`(残留 unit 还在 → 误判"节点曾加入集群")。
drain 会 `kubectl get nodes --kubeconfig /etc/kubernetes/admin.conf`,而全新部署/reset 后
admin.conf 尚未生成(由 kubeadm init 在后置任务创建)→ 必失败。

**修复(已并入 `cubestack-offline.sh` 的 `reset_kubernetes_if_needed`):**
- 探针新增检测残留 kubelet unit(`/etc/systemd/system/kubelet.service` 等), 即使
  `/etc/kubernetes`、`/var/lib/kubelet` 等目录已被手动清理也能触发 reset;
- reset 清理命令新增删除 kubelet unit 文件(`/etc/systemd/system/kubelet.service[.d]`、
  `/lib/systemd/system/kubelet.service[.d]`、`/etc/kubernetes/kubelet.env`) +
  `systemctl daemon-reload`。

kubelet unit 移除后,`validate-container-engine` 检测不到 kubelet → 跳过 drain → 直接
卸载 docker(由 kubespray 处理),部署继续。

**手动急救(不想重跑 deploy 前先清理节点):**
```bash
ssh <user>@<node> "sudo bash -c '
systemctl stop kubelet 2>/dev/null || true
rm -f /etc/systemd/system/kubelet.service /etc/systemd/system/kubelet.service.d \\
      /lib/systemd/system/kubelet.service /lib/systemd/system/kubelet.service.d \\
      /etc/kubernetes/kubelet.env
systemctl daemon-reload'"
```
docker 不用手动卸载, 留给 kubespray "Remove Docker" 流程处理。

> 排查线索: 先确认节点是否残留旧容器运行时/kubelet unit ——
> `ssh <user>@<node> "systemctl is-active docker kubelet; ls /etc/systemd/system/kubelet.service"`
