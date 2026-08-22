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
- 把该服务的 webhook pod 钉到首控制面(如 metallb controller 加 `nodeSelector: kubernetes.io/hostname: <首master>`),webhook 走同节点,不依赖 4789 回包。
- ✅ **能解决**: 该服务的 webhook 调用、以及**部署流程**(如 metallb 池子 apply)恢复正常。
- ⚠️ **不能解决**: 跨节点负载均衡数据面 —— 若后端 pod 在其它节点,LB VIP 回包仍需 4789 进首控制面,网络不放行则 LB 不可达。**要彻底可用必须网络侧放行 UDP 4789。**

**相关命令**
```bash
ip -s link show vxlan.calico | grep -A1 RX:    # RX=0 → 跨节点收包坏
sudo timeout 8 tcpdump -ni manage0 "udp port 4789"   # 本机 4789 是否到达
# 对照(本机能收 40002 → 主机 UDP 正常, 是 4789 被网络拦):
sudo nc -l -u 40002 &  ;  echo test | nc -u <本机IP> 40002
```

---

### 2. kubespray 部署在 MetalLB "Create address pools configuration" 失败: webhook "context deadline exceeded"(即使加重试也失败)

**症状**
```
TASK [kubernetes-apps/metallb : MetalLB | Create address pools configuration]
fatal: failed calling webhook "ipaddresspoolvalidationwebhook.metallb.io":
  Post "https://webhook-service.metallb-system.svc:443/...": context deadline exceeded
```
重试(10×5s)耗尽仍失败。metallb pods 显示 Running,但池子永远建不出来。

**根因(串成一条链)**
> ⚠ **首要持久根因见第 1 条:网络丢弃「进入首控制面的 UDP 4789」** —— 它跨重装依然存在(RX=0)。本条的 MTU 抖动与 CRD 竞态是**加剧因素**,但即使修好,4789 被网络丢弃时跨节点 webhook 仍会失败。
1. **Calico VXLAN MTU 自动检测误判**(首要根因):
   裸金属机有 InfiniBand 网卡(`ibs2/ibs3`, MTU=**2044**)。Felix 自动检测 underlay MTU 读到 2044,想把 `vxlan.calico` 隧道 MTU 设成 **2044−50=1994**,但隧道实际绑在 `manage0`(MTU 1500),内核拒绝 `mtu: invalid argument`(合法上限 1500−50=**1450**)。
   → Felix 每 10s 重试一次,隧道持续抖动。
   → 日志特征:`felix/vxlan_mgr.go 727: VXLAN device MTU needs to be updated new=1994 old=1450 ... Failed to set vxlan tunnel device MTU error=invalid argument`。
2. **跨节点 host→pod 路由断裂**:隧道抖动 → apiserver(首 master)访问其他节点上的 pod 100% 丢包。判定:从首 master `ping <远端 pod IP>` 100% loss;`ip -s link show vxlan.calico` 的 **RX=0**(一个包都收不到)而 TX 正常。
3. metallb controller 被调度到**远端 worker**,apiserver→webhook ClusterIP 必须跨节点 → 走断裂的 VXLAN → `context deadline exceeded`。

**解法(根治,按优先级)**
- `k8s-net-calico.yml` 显式固定 `calico_mtu: 1450`(VXLAN 模式 = 物理网卡 1500 − 50)。避免 Felix 自动检测踩 IB 2044。**下次全新安装不再复现。**
- 已坏集群无法回溯修复:把 **metallb controller 钉到首个 master**(与 apiserver 同节点),webhook 走同节点本地 pod 网络,不依赖 VXLAN:
  ```bash
  kubectl -n metallb-system patch deployment controller --type=merge \
    -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"<首个master主机名>"}}}}}'
  ```
  此默认已写入 `sync-kubespray-config.sh`(`METALLB_PIN_CONTROLLER_FIRST_MASTER=1`,默认开)。
- metallb 角色已加:等 `crd/ipaddresspools.metallb.io` `Established` 后 `rollout restart` controller,再 apply 池子(消除 CRD 建立与 informer 启动的竞态)。

**验证**
- `kubectl -n metallb-system get ipaddresspools` 出现池子;`get l2advertisements` 出现 primary。
- 建个 LoadBalancer Service → 事件 `IPAllocated`,EXTERNAL-IP 落在池内;
- `ping <LB VIP>` 出现 `Redirect Host(New nexthop: <VIP>)` = L2 ARP 通告已生效;
- `sudo ./deploy-cluster.sh --steps verify_metallb` 端到端通过(分配 VIP + 池内校验 + curl 可达)。

**相关命令(排查三板斧)**
```bash
# 1) felix MTU 抖动
kubectl -n kube-system logs ds/calico-node | grep -E "vxlan.*mtu|Failed to set"
# 2) 本机 VXLAN 收包是否正常(0 = 接收路径坏)
ip -s link show vxlan.calico | grep -A1 RX:
# 3) 跨节点 host→pod 连通性
ping -c3 <远端 pod IP>
# 4) metallb 是否认识池子(CRD 竞态时 controller 会报)
kubectl -n metallb-system logs deploy/controller | grep -E "no matches for kind"
```

---

### 2. 已写满一条即可,后续按此模板追加

> 占位提示:新问题解决后,把这条替换/追加为真实条目。

---

## 二、时间同步

> (示例占位) setup-ntp.sh 时钟偏差误报 —— 见该脚本注释与 git 历史;后续问题按模板追加。

---

## 三、集群组件

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
`inventory/<集群>/group_vars/k8s_cluster/addons.yml` 中 `metallb_config.controller.nodeselector` 残留了**上一环境(裸金属)的主机名**。当前 VM 集群没有该主机名节点 → controller **永远调度不上**(一直 Pending)。
**连锁效应**: controller 从不启动 → 不会在启动时自动创建 `memberlist` secret(MetalLB v0.13.x 由 controller 自动创建, 无需写进模板)→ speaker 因 `secret "memberlist" not found` 全部 CreateContainerConfigError。
> ⚠ `memberlist` secret 缺失是**结果不是根因**; 不要往模板里加该 Secret —— 上游 kubespray 模板即依赖 controller 自建(controller Role 已有 secrets CRUD 权限)。

**解法(根治)**
- 删掉 addons.yml 中 controller.nodeselector 里残留的 `kubernetes.io/hostname` 行(环境已非裸金属时);
- `sync-kubespray-config.sh` 4.0 段是**幂等双向同步**: `METALLB_PIN_CONTROLLER_FIRST_MASTER=1` 时确保 hostname=当前首个 master(值不对会替换); 未启用时**移除**任何残留 hostname —— 否则换环境重装会再次踩坑(旧代码只加不删)。
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

### 2. verify_metallb 失败: LoadBalancer 分到 `.0/.255` 网络/广播地址(METALLB_POOL 用了整段 CIDR)

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

## 四、离线部署

> (示例占位) 按模板追加。
