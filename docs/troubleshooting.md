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

### 1. 【2026-09-08 事故】k8s_ntp 失败: 个别节点偏差稳定 ~2s 不收敛, 其余节点 ~1s 但"通过"

**症状**: 新集群部署, `k8s_ntp` 模块失败 —— master12 偏差 2018ms→复测 2017ms 稳定不收敛(>2000ms 阈值);
master13/worker11/worker12 偏差 995~1239ms 但"通过"; 权威 master11 "chrony 服务端已就绪" 显示成功。

**根因**(证据链, 详见 git 提交/setup-ntp.sh 注释):
1. **权威 chronyd 从未加载部署配置**: 各节点 `chronyc sources` 全部 `^? 10.244.1.31  Reach 0 / stratum 0`;
   master11 `ss -ulnp` 只有 `127.0.0.1:323`(命令 socket), **无 `0.0.0.0:123` NTP 端口监听**;
   `systemctl status chrony` 显示进程自开机起运行, **journal 无部署时的 restart 记录**(配置 mtime 晚于进程启动)。
2. **代码 bug**: `node_cmd` 的 `full="sudo $*"` **只给命令链的第一个命令(cp)加 sudo**; 旧 `master_chrony_setup`
   把整条 `cp && ... && systemctl restart chrony && chronyc makestep` 链传给 node_cmd →
   链中 `systemctl enable/restart`、`chronyc makestep` 全部以 ubuntu 用户执行 → **静默失败**
   (`>/dev/null 2>&1 || true` 吞掉, `|| true` 使链恒返回 0) → "已就绪" 假阳性。
3. 全集群客户端只有一次性 `date -s` 硬对齐兜底(偏差残留 ~1s), 无真正 NTP 收敛。

**解法(根治, 2026-09-08)**:
- `master_chrony_setup` 重写: 配置+重启+自检全部放入**远程脚本**, 经「单个 `sudo bash`」执行(整脚本 root,
  与客户端侧 NODE_SCRIPT 同模式); 脚本内置自检(`ss -ulnp | grep ':123 '`), 未监听 123 即 `exit 1` →
  模块硬失败, 不再假阳性。
- 修复后二次确认: 权威 `chronyc tracking` stratum 应为 10(local)。
- `verify_clocks` AUTO_SYNC 重对齐基准改用**权威时钟**(原取部署机时钟, 偏差可达数百 ms)。
- 客户端侧: `chronyc -a makestep` 重试 3 次(间隔 2s)—— 刚重启的 chronyd 首轮 iburst 前 makestep 必失败。

**验证**: 修复后重跑 `setup-ntp.sh apply` → "已就绪(监听 123, local stratum 10)"; 全节点偏差
2018ms→**301~313ms**(真正 chrony 同步, 非硬对齐残留); `verify_clocks` 全绿。

**相关命令**:
```bash
# 权威是否监听 NTP 端口(关键判据)
sudo ss -ulnp | grep ':123 '
# 客户端是否真正同步
chronyc sources; chronyc tracking
# 强制重启权威 chrony(手工抢救)
sudo systemctl restart chrony; sleep 2; chronyc tracking | head -4
```

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
docker save <img> -o /tmp/x.tar && skopeo copy docker-archive:/tmp/x.tar docker://registry.cubestack.io:5000/metax/<name>:<tag> --dest-tls-verify=false --dest-no-creds
```

#### 3.4 `metax-k8s-images.<ver>.run push` 报 `ctr: image "--plain-http": not found`

**根因** 工具的 ctr 分支把 `--plain-http` 放在镜像 ref **之后**(`push <ref> --plain-http`), 新版 ctr 把 flag 当镜像名。

**解法(根治)** 不用工具自带 push: `.run ctr load` 把内嵌镜像加载进宿主 ctr, 再逐组件
`ctr -n k8s.io images tag <src> registry.cubestack.io:5000/metax/<comp>:<ver>` + `ctr -n k8s.io images push --plain-http <dst>`(flag 在前)。

#### 3.5 宿主机 curl `registry.cubestack.io:5000` / helm 连 `k8s-api.cubestack.io` 失败(EOF / no route to host)

**根因** 宿主机 /etc/hosts 残留旧 IP(如 `10.66.3.37` = 宿主机自身)或 DNAT 被历史规则遮蔽(两条规则指向 10.244.2.100 与 10.66.1.130, 旧规则先命中)。

**解法(根治)** 每次部署由模块修正 /etc/hosts:
```
registry.cubestack.io → REGISTRY_IP(集群 registry VIP, 如 10.66.1.130)
k8s-api.cubestack.io → API_IP(全裸金属=第一个 master, 如 10.66.1.232)
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
| `15_envoy_gateway.sh` 报 "EG chart 目录不存在/缺 Chart.yaml" | 离线 chart 未备料(联网机未跑 fetch 工具) | 联网机执行 `tools/images/envoy-fetch-charts.sh`(或手动 helm pull gateway-helm 解包)后拷到 `deployments/cubestack-addon/envoy-gateway/eg/` |
| 部署报 "未找到 envoyproxy/gateway:... 镜像" | 离线镜像未备料 | 联网机执行 `tools/images/envoy-save-images.sh`, tar 放入 `deployments/offline-files/envoy/`(或本地 docker daemon 先 docker pull); 已备 tar 可单独跑 `tools/images/envoy-load-images.sh` 预加载 |
| 部署后控制面/certgen 或数据面 pod `ImagePullBackOff`(docker.io 不可达) | chart 镜像未改写为集群内置 registry(gateway-helm v1.9.1 正确路径: 控制面/certgen `deployment.envoyGateway.image.repository/tag`, 数据面 `global.images.envoyProxy.image`; 旧写法 `image.repository` / `envoyGateway.image.*` 顶层不存在, 无效果) | 确认 15 模块 helm 安装已注入上述正确 `--set`; 已装错可 `helm upgrade eg <chart> --set deployment.envoyGateway.image.repository=registry.cubestack.io:5000/envoyproxy/gateway --set deployment.envoyGateway.image.tag=v1.9.1 --set global.images.envoyProxy.image=registry.cubestack.io:5000/envoyproxy/envoy:distroless-v1.39.1` 修复(certgen Job 会随模板变化重建), 或直接重跑 15 模块(内部先 delete ns) |
| 创建 Gateway 后数据面 pod `CrashLoopBackOff`, 日志 `PARSE ERROR: Argument: --cpuset-threads` | **数据面 envoy 镜像 tag 用错**(用了 EG 版本号如 `envoy:v1.9.1`, 拉到远古 Envoy; EG 1.9.x 配套数据面 tag 应为 `ENVOY_PROXY_VERSION`=distroless-v1.39.1, 用 `kubectl exec deploy/envoy-gateway -- envoy-gateway version` 核对) | 15 模块已改为 `push_one envoy ... ${ENVOY_PROXY_VERSION}` + helm `global.images.envoyProxy.image` 用 ENVOY_PROXY_VERSION; 已错: 在联网机用 envoy-save-images.sh(已修)重新 save `envoyproxy/envoy:distroless-v1.39.1`, 离线推入 registry 后重跑 15 模块 |
| `GatewayClass eg` 未 Accepted | 控制面未就绪 / controllerName 不匹配 | `kubectl -n envoy-gateway-system logs deploy/eg --tail=50`; GatewayClass 的 `spec.controllerName` 必须是 `gateway.envoyproxy.io/gatewayclass-controller` |
| Gateway 一直没 VIP(ADDRESS 空) | MetalLB 池耗尽/网段冲突, 或数据面未起来 | `kubectl describe gateway` 看条件; `kubectl get svc -n <gw-ns>` 看 LoadBalancer pending 原因(参考 §三.1/§三.2) |
| `16_envoy_ai_gateway.sh` 报 "未检测到 Envoy Gateway(GatewayClass eg 未 Accepted)" | AI 依赖 EG, 但 EG 未装/未就绪 | 先 `ENVOY_GATEWAY_ENABLED=true` 部署模块 `envoy_gateway`, 再装 AI |
| AI 控制器 pod CrashLoop / webhook 不生效(v1.x) | `envoyGateway.namespace` 未指向 EG 命名空间 / EG 版本不匹配(AI 与 EG 版本兼容矩阵) | 确认模块 16 helm 安装注入 `--set envoyGateway.namespace` = `envoy-gateway-system`(`kubectl -n ai-gateway-system get deploy ai-gateway-controller -o yaml \| grep envoyGatewayNamespace`); 核对 AI↔EG 版本兼容矩阵 |
| AI CRD apply 报 `no matches for kind "AIGateway"` | v1.x 无 AIGateway/Backend CRD(改为 AIServiceBackend/AIGatewayRoute); 或 CRD 未装 | `kubectl get crd \| grep aigateway`; 按 `docs/envoy-gateway.md` §4.2 / 官方 `examples/basic/basic.yaml` 使用 v1.x 资源 |
| 部署报 "未找到 skopeo" | 推送镜像到集群内置 registry 需要 `skopeo` | 宿主机安装 `skopeo`(如 `apt install skopeo`), 或使用项目 CLI 镜像(`tools/docker/build-cli-context.sh` 内置 skopeo-1.16.1-amd64) |
| `Gateway` 长期 `Programmed=False (AddressNotAssigned)`, 数据面 Service 是 `LoadBalancer` 且 `EXTERNAL-IP <pending>`, 但 NodePort 别名能访问 | Gateway 注解 `gateway.envoyproxy.io/service-type: NodePort` 在 **EG v1.9.1 未生效**(实测: 注解在, 控制器仍建 LoadBalancer 类型数据面; 集群无 MetalLB → 永远无地址 → 条件不转 True) | 访问不受影响(入口 = `tools/lb/gateway-nodeport.sh` 建的固定别名 `<gw>-external`)。要让状态转绿: 跑一次 `tools/lb/gateway-nodeport.sh <gw>` —— 它把数据面 Service 转成 NodePort 后 EG 立即置 `Programmed=True`(2026-09-17 实测)。**别只信注解** |
| HTTPRoute `ResolvedRefs=False`, 经网关访问 404/500 | backendRef 指向的 Service 不存在 | 核对 `kubectl -n <ns> get svc`。典型踩坑: CubePilot 写 `svc/cubepilot` —— 那是**内置 Portal 的 nginx 入口**, 仅 `web.enabled=true` 时才渲染; 关 Portal 的部署里只有 `svc/cubepilot-api`(两条路由需各自门控: API `cubepilot-api:8080` 恒有 / Portal `cubepilot:8080` 需 `CUBEPILOT_WEB_ENABLED=true`) |

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

### 6. Ceph / Rook 部署故障速查

> 设计与离线流程见 `docs/ceph-rook.md`。

**症状/排查对照**

| 症状 | 根因 | 解法(根治) |
|---|---|---|
| OSD Prepare 失败 / osd Pod CrashLoop | 裸盘残留文件系统/LVM/分区签名, Rook 视为"已使用" | 只在**确认空闲的数据盘**上清盘: `wipefs --all -f /dev/<盘>; sgdisk --zap-all /dev/<盘>; rm -rf /var/lib/rook`; 勿碰系统盘(先 `lsblk` 核对) |
| 节点重启后 OSD 逻辑卷无法激活 | **lvm2 未安装**(Rook OSD 依赖 lvm 激活 LVM 卷) | 离线包放入 `offline-files/kubespray/packages`(联网机 `tools/offline/fetch-lvm-packages.sh`)后 `dpkg -i`; 或 apt 安装 lvm2 后重启 OSD |
| ceph 镜像 ImagePullBackOff | 节点 containerd 无镜像(离线) | `tools/images/ceph-save-images.sh`(联网机, `--platform linux/amd64` 单架构)生成 tar → `ceph-sync-images.sh` 同步并 `ctr -n k8s.io images import --no-unpack` |
| ctr import 报 "content digest not found" | 多架构(manifest-list)tar | 拉取用 `--platform linux/amd64` 单架构; import 加 `--no-unpack` |
| `ceph -s` HEALTH_WARN clock skew | 存储节点时钟漂移(离线无上游) | 部署前 NTP 模块对齐; 生产存储节点用 chrony, `chronyc makestep`, offset<20ms |
| registry PVC 一直 Pending | `REGISTRY_STORAGE_CLASS=ceph-block` 但 `ceph-block` SC 未创建 | 先部署 ceph_csi 模块(建 rbd-pool + SC); PVC 会自动绑定; 老 PVC 删除后 registry 重建即切换 |
| mon/osd 未调度到目标节点 / 一直在 Pending | 节点缺 label 或 CEPH_NODES 与预期不符 | `kubectl get node --show-labels | grep ceph-storage`; 模块自动打 `CEPH_NODE_LABEL`; 核对 CEPH_NODES |
| 部署模块报"所有存储节点均未检测到裸盘" | VM 未附加数据盘 / 盘已被分区 | VM: `vm-nodes.conf` 设 `VM_DATA_DISKS=3 VM_DATA_DISK_SIZE=200` 后重建 VM; 裸金属: 挂新盘; 或显式 `CEPH_DATA_DISKS="node:/dev/vdb,…"` |
| 预检显示全节点裸盘 `<未检测到>` 但节点 `lsblk` 确有裸盘(如 vdb/vdc/vdd) | `ceph-detect-disks.sh` 仅用 `ssh -i` 密钥认证: 全新环境 k8s_passwordless 未分发密钥 / 容器未挂载密钥 → 全部节点 SSH 失败; 且预检 `2>/dev/null` 吞掉"无法读取 lsblk"原因 | **2026-09-07 已修复**: 脚本密钥缺失不再硬退出, 新增**密码回退**(SSHPASS + NODES 第5字段密码, 与 setup-passwordless.sh 同款; 密钥优先、失败回退密码); 预检 stderr 透传显示真实原因。验证: `bash deployments/scripts/tools/k8s/ceph-detect-disks.sh -m` 应输出各节点 `/dev/vdb,...` |
| CephCluster 删不掉/卡 Terminating | 未设 cleanupPolicy | `kubectl -n rook-ceph patch cephcluster rook-ceph --type merge -p '{"spec":{"cleanupPolicy":{"confirmation":"yes-really-destroy-data"}}}'` 后再 delete |
| **CEPH_MODE=external 部署卡在 ceph_csi [1/4] 等 CSI 插件 240s** / 未部署任何 ceph-csi-operator | ① ceph 模块**未被调度**: `TOGGLE: CEPH_ENABLED`(false)而模块自身 external 分支实际由 `CEPH_CSI_ENABLED` 放行 → rook operator/csi-operator 从未安装; ② 排序缺陷: 默认模式 `k8s_deploy` 由 enable 循环追加在 RUN_STEPS 末尾, `ceph_csi` 仅声明 `REQUIRES: ceph`(不在运行列表→视为满足)被拓扑排序**浮到 k8s_deploy 之前**, 直接 SSH 到未部署/未就绪集群; ③ k8s 阶段 ceph 镜像预加载仅看 `CEPH_ENABLED=true`, external 模式不预载 rook/csi 镜像 → 离线 operator ImagePullBackOff | **2026-09-08 已修复(3 处)**: ① `TOGGLE` 支持空格分隔多变量(OR), 02_ceph 改 `TOGGLE: CEPH_ENABLED CEPH_CSI_ENABLED` → external 模式自动调度装 operator/csi-operator(不建 CephCluster); ② 03_ceph_csi `REQUIRES: ceph k8s_deploy` → 永远排在 k8s_deploy 之后; ③ 06_k8s_deploy 传给 cubestack-offline.sh 的 CEPH_ENABLED 取派生值(CEPH_ENABLED 或 CEPH_CSI_ENABLED true 即 true) → external 模式也预载 rook/csi 镜像。**验证边界**: 调度层已复现验证(容器内 `--list` 顺序 = k8s_deploy→ceph→ceph_csi, 15 模块), check-modules 全绿; **未实机跑通全流程** |
| 运行 `tools/offline/sync-to-container.sh` 后外部 Ceph 认证失败 | 旧版脚本第 2 步会把**本地 cluster.conf 整体 docker cp 进容器**, 本地占位 keyring(`<占位: 如 AQxxx==>`)覆盖容器内真实 key | **2026-09-08 已修复**: sync-to-container.sh **默认不推送 cluster.conf**(容器内保留真实 keyring, 仅显示当前 ceph 配置), 需要强制推送用 `SYNC_CONF=1`(推送前备份 .bak.ceph); 真实 key 只放 gitignore 的 `cluster.conf`(已验证被忽略, 可安全填写), 不要放 `cluster.conf.example` |
| external 模式 ceph_csi 执行失败: `error: unable to decode "/tmp/ceph-ext-rbd.yaml": json: cannot unmarshal bool into Go struct field ObjectMeta.metadata.annotations of type string` | 03_ceph_csi.sh 内嵌 YAML 字符串中 `storageclass.kubernetes.io/is-default-class: "true"` 的引号在 **bash 双引号字符串内未转义**, 被词拼接(adjacent word concatenation)吞掉 → 生成 YAML 变成裸 `true`(bool), kubectl 解码 `metadata.annotations` 失败; 该文档(`ceph-rbd-ephemeral`, 默认 SC)及其后的 apply 全部中止(前面 10 个文档已 apply 成功) | **2026-09-09 已修复**: 改为 `\"true\"`(bash 内转义, 渲染出带引号字符串 `"true"`); 已用 stub 渲染 + python yaml 校验 11 文档全通过; 幂等重跑自动补齐缺失的 `ceph-rbd-ephemeral` SC。⚠ 同类隐患: bash 双引号字符串内嵌 YAML 的值, 引号一律 `\"` 转义 |
| external 模式 registry 卡死: k8s_registry 报 `节点 NodePort 31148/v2/ 90s 内不可达`; registry-pvc 永久 Pending; provisioner 日志 `failed to fetch monitor list using clusterID (ceph-connection): open /etc/ceph-csi-config/config.json: no such file or directory` | **缺 ClientProfile CR**: ceph-csi-operator 由 `ClientProfile`(名字=clusterID) + `CephConnection`(monitors) 自动生成 `ceph-csi-config` ConfigMap(config.json); ceph_csi external 分支只建了 CephConnection+SC, 没建 ClientProfile → config map 空(operator 日志 "CSI Config Map is already up to date" 且 data 为空)→ provisioner 无法解析 clusterID → PVC 永久 Pending → registry pod Pending → NodePort 无后端。注: `spec.clusterName` 打在 CephDriver 上**无效**(不是配置来源); 手动注入 CM 会被 operator 调和平掉 | **2026-09-09 已修复(已实机验证)**: 03_ceph_csi.sh external 分支的 _EXT_YAML 增加 ClientProfile 文档(`name: ceph-connection` + `spec.cephConnectionRef.name: ceph-connection`, profile 名=SC 的 clusterID), apply 后新增**等待 ceph-csi-config 生成(60s, 超时硬失败)**防线。实测: 创建 profile 后 config map 自动填充 `{"clusterID":"ceph-connection","monitors":[...]}`。恢复: 旧 PVC 带 `addonmanager.kubernetes.io/mode: Reconcile` 标签 — `kubectl -n kube-system delete pvc registry-pvc` 后 addon-manager 自动重建(新 UID 绕过 provisioner 的 infeasible-error 退避缓存) |
| ceph [1/8] 裸盘检测**无限卡死**(交互终端): 卡在"检测节点裸盘"后无输出; ssh 子进程状态 T(stopped) | `ceph-detect-disks.sh` 密钥分支 `ssh -i` 无 BatchMode: `timeout` 会给命令**新开进程组**(后台于终端 fg 组), 公钥认证瞬间失败(如 kubespray 刚收尾 authorized_keys 未就绪)时 ssh 回退密码提示 → **读 /dev/tty → SIGTTIN → 永久 stopped**(do_signal_stop), timeout 的 SIGTERM 也杀不死它 → 部署无限挂起 | **2026-09-09 已修复**: 密钥分支加 `-o BatchMode=yes` + `</dev/null`(密钥失败立即返回、不读 tty, 自然落到 sshpass 密码分支; sshpass 自带 pty 无此问题); lib-common 三处 `ssh -i`(sync_kubeconfig / SSH() / SSH_CMD)同步加 BatchMode。证据链: /proc 显示 ssh `State:T` + `wchan:do_signal_stop` + `fd/0→/dev/pts/1` + `pgid≠tpgid`(25226 vs 4363); 对照实验: 同容器 `timeout 3 ssh ... sleep 100` 3s 正常击杀。验证: 修复后 `ceph-detect-disks.sh -m` **2.2s 完成**, 5 节点全检出 /dev/vdb,vdc,vdd(master 走公钥, worker 走 sshpass 密码回退) |
| external 模式 ceph_csi 报 `ceph-csi-config 60s 内未生成` 但 CM 实际存在且内容正确(clusterID=ceph-connection) | 判定用 `-o jsonpath='{.data}'`: kubectl 对 map 输出会把 config.json 值内双引号**转义**为 `\"clusterID\":\"ceph-connection\"` → 未转义模式的 grep 永远不匹配 → **假阴性**(CM 早已由 operator 生成) | **2026-09-09 已修复**: 判定改 `-o yaml`(yaml 里 config.json 是单引号标量, 双引号为字面字符, grep 直接匹配); 顺带补 `_EXT_NUM`(完成提示此前显示"个 StorageClass"缺数字)。验证: 容器 b 实机重跑 03_ceph_csi.sh → 首次迭代即命中, 模块完成 ✓ |
| 重装后 registry-pvc 长时间 Pending/无 PV; provisioner 报 `InvalidArgument ... open /etc/ceph-csi-config/config.json: no such file or directory`, 且后续重试全是 `skipping volume provisioning ... previously failed with infeasible error` | **kubelet CM 投递竞态**: ceph_csi 检查 CM data 就绪 ≠ provisioner pod 可见(投递有 ~1min 延迟)→ 首次 provision 撞上文件未挂载 → InvalidArgument 被 csi-provisioner 判为 **infeasible**(永久)→ 退避翻倍到 256s 级, 数分钟后才真正重试成功(实机: 06:50:17 失败 → 06:58:49 ProvisioningSucceeded)→ k8s_registry 的 90s 等待提前超时中断部署 | **2026-09-09 已修复**: 03_ceph_csi external 分支在 CM data 就绪后**再等 config.json 投递进 provisioner pod**(`kubectl exec ... test -f /etc/ceph-csi-config/config.json`, 最长 60s, 超时仅告警不硬失败)→ registry 首次 provision 即成功, 不再走 infeasible 退避。验证: 容器 b 重跑模块, 投递检查首次迭代即命中 ✓ |
| 提供方 HEALTH_ERR `1 filesystem is offline` / 消费方 cephfs-* SC provision 失败(外部 CephFS `cubestack-ext-fs` 无 MDS; **RBD 不受影响**) | `ceph-expose-external.sh` 用 `ceph fs new`(CLI)建外部 fs —— CLI 建的 fs **没有 MDS 守护进程**(MDS 只由 Rook 依据 CephFilesystem CR 部署)→ fs 永久 offline | **2026-09-09 已修复**: 新增 `rook/external/03-cephfilesystem-external.yaml` 模板(activeCount 1 + activeStandby false + preservePoolsOnDelete), 工具改 apply CR + 等 MDS active(≤300s); 已存在同名 fs/pool(历史 CLI 建的)时 Rook 自动接管, 幂等。验证: 提供方 apply 后 `cubestack-ext-fs:1 up:active`, ceph -s **HEALTH_ERR → HEALTH_OK** |
| cluster.conf 里 `grep CEPH_MODE` 出现两处赋值, 默认配置静默变 external 模式 / CEPH_MONITORS、CEPH_KEYRING 被示例值覆盖 | cluster.conf.example 底部【示例】块曾是**活配置**(11 行未注释): source 时 `CEPH_MODE="external"` 覆盖上方唯一开关行 `CEPH_MODE="${CEPH_MODE:-internal}"`(bash 最后赋值生效)→ 默认配置变 external + 占位 key | **2026-09-09 已修复**: 示例块全部注释为纯模板(不生效); CEPH_MODE 全文件只保留开关行一处(`CEPH_MODE="${CEPH_MODE:-internal}"`, 切 external 只改这一处)。存量 cluster.conf(容器内/用户自持, gitignored)手工处理: 注释或删除示例块 11 行; 若外部接入配置本来就写在示例块里, 把值移到上方真实声明段(CEPH_MONITORS/CEPH_USER/CEPH_KEYRING/CEPHFS_*)。验证: `bash -c 'source deployments/config/cluster.conf.example; echo $CEPH_MODE'` → internal; check-modules 全绿 |
| external 模式 ceph_csi 失败: `error: error parsing /tmp/ceph-ext-import.yaml: error converting YAML to JSON: yaml: line 10: could not find expected ':'`(日志里 secret/rook-ceph-mon + CM 已 created, 但后续 CSI secret 全部未建) | 03_ceph_csi.sh 的 `external-cluster-user-command` CM 构造里 `args: |-` block scalar 只给 ARGS **首行**加了 4 空格缩进: 提供方导出的 ARGS 是**多行**内容(export 带 `--config-file` 时写入 `[Configurations]` + `key = value` 块), 后续行落在第 0 列 → block scalar 提前终止, `rgw-pool-prefix = default` 等裸标量被当成新 YAML 节点 → "could not find expected ':'"(第 10 行正是 `rgw-pool-prefix`)。kubectl 流式解析先成功 apply 前 2 个文档, 到第 3 个文档报错中止 | **2026-09-11 已修复**: 嵌入前用 `printf '%s\n' "${ARGS}" | sed 's/^/    /'` **逐行加 4 空格缩进**成 `_ARGS_BLOCK` 再拼接(`args: |-\n${_ARGS_BLOCK}`)。验证: 以真实多行 ARGS 本地复现, 修复前 kubectl 报错与线上逐字一致(line 10); 修复后 kubectl 解析通过 + pyyaml 往返校验内容逐行等于 ARGS、无失真; check-modules 全绿。实机: 容器 b 重跑后 8 个资源(secret×5+CM×2+rbd secret 组)全部 created, 外部 CephCluster Connected —— **ARGS 段已实机验证通过** |
| external 模式 ceph_csi **官方导入路径**冒烟失败: `RBD 1Gi scratch PVC 180s 内未 Bound`(前面 import 1-4 全绿: secret/CM/Connected/csi-config 均正常, SC/RGW 也建好) | **kubelet CM 投递竞态在官方导入路径复发**(同 2026-09-09 手填路径事故, 但官方路径**缺那道防线**): ceph-csi-config CM 03:35:12 生成, ctrlplugin pod 03:35:14 启动 —— 启动时 kubelet 挂载的 CM 还是旧/空 → 首次 CreateVolume 03:35:32 撞 `open /etc/ceph-csi-config/config.json: no such file or directory` → InvalidArgument 被 csi-provisioner 判 **infeasible(永久)** → 日志 `skipping volume provisioning ... previously failed with infeasible error`, PVC 永不 Bound → 冒烟 180s 超时。手填路径(827-857 行)有 rollout restart + config.json 挂载检查, **官方导入路径没有** | **2026-09-11 已修复**: 抽出公共函数 `_ext_wait_csi_config_ready()`(rollout restart provisioner + 等 rollout + `kubectl exec test -f config.json` 挂载确认, 挂载失败硬失败), 官方路径 csi-config 检查后立即调用。验证: 根因证据链完整(provisioner 日志 InvalidArgument + infeasible); check-modules 全绿; 已同步容器 b, 重跑 --steps ceph_csi 实机验证进行中 |

**验证**
```bash
sudo ./deploy-cluster.sh --steps verify_ceph          # 端到端: operator/CSI + phase=Ready + ceph -s + RBD 块 I/O
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s
kubectl -n rook-ceph get cephcluster,cephblockpool; kubectl get sc ceph-block
```

---

### 7. 平台统一网关(原 cubestack-gateway)—— 模块已移除

> ⚠ **2026-09-18: 模块 `33_cubestack_gateway.sh` 与 `deployments/cubestack-addon/gateway/`
> (基座 `base-gateway.yaml` + `routes/*.yaml` + README)已从仓库删除。**
> 网关(Gateway)与路由(HTTPRoute)统一改由**专门的网关模块**创建(尚在重构中), 各组件模块不再自建网关与路由。
>
> - 与模块无关的两条**通用 EG 现象**(`Programmed=False (AddressNotAssigned)` / `ResolvedRefs=False`)
>   已上移到 **§三.5 Envoy Gateway 故障速查**;
> - 设计要点(单入口多 hostname、路由须晚于后端组件下发、固定别名入口等)保留在
>   `docs/envoy-gateway.md` §2.1b, 供新模块落地时参考;
> - 历史实现与当时的排查过程见 git: `1cfbcf0`(引入)/ `45afb4a`(修路由静默缺失 + 模块重排 18→33)。
>
> ⚠ 已部署过旧模块的集群: 网关资源**不会被自动删除**(模块只是不再被调度), 需要时手工清:
> `kubectl delete gateway cubestack-gateway -n cubestack-gateway-system; kubectl delete ns cubestack-gateway-system`。

---

### 8. CubeStack 可观测性落地(kube-prometheus-stack values / recording rules / dashboards / mx-exporter / BMC)

**背景:** 按 `suanova/cubestack` 的 `observability/docs/installer-requirements.md` 把 recording rules、
dashboard、mx-exporter、BMC exporter 落到安装环境。实现细节与需求对照见
**`docs/prometheus-observability.md`**; 这里只沉淀**故障模式**(全部是"静默失效"类 ——
不报错、不失败, 只是功能不生效)。

#### 8.1 `kubectl get prometheusrule` 有 CR, 但 `/api/v1/rules` 里没有 cubestack 规则

**症状:** 6 个 PrometheusRule 对象都建出来了, `kubectl get prometheusrule -n monitoring | grep cubestack`
看得到, 但 Prometheus 里查不到对应规则组 —— **没有任何报错**。

**根因:** **CR 存在 ≠ 规则被加载**。加载与否取决于 Prometheus CR 的 `ruleSelector` 能否选中该 CR。
两种典型写法都会踩:
- 按需求文档 §1.2 字面写 `ruleSelector.matchLabels: {app.kubernetes.io/part-of: cubestack-observability}`
  → 能选中 CubeStack 规则, **但会把 chart 自带的 35 个 PrometheusRule 一起丢掉**
  (它们带的是 `release: <release名>` + `part-of: kube-prometheus-stack`);
- 只给 CubeStack 规则打 `release` 标签、不动 selector → 反过来只有默认规则在。

**解法:** 用 `matchExpressions` 取**并集**(`In [cubestack-observability, kube-prometheus-stack]`),
即同时覆盖两边。`08_prometheus.sh` 已如此实现, 并且**额外**给 CubeStack 规则补 `release` 标签作冗余
(静默失效代价太大, 值这一层保险)。详见 `docs/prometheus-observability.md` §2.2。

**验证:** 别用 `kubectl get prometheusrule` 判断 —— 用 `/api/v1/rules` 逐组断言,
或直接 `--steps verify_prometheus`(⑥ 段就是干这个的)。

#### 8.2 写了 `serviceMonitorSelector: {}` 却没生效, 跨 ns 的 ServiceMonitor 全丢

**症状:** values 里明明写了 `serviceMonitorSelector: {}`(想全选), 但 `kubectl get prometheus -o jsonpath='{.spec.serviceMonitorSelector}'`
输出的是 `{"matchLabels":{"release":"kube-prometheus"}}` —— 跨 namespace 的 ServiceMonitor
(如 metax-operator 里的 mx-exporter)因此全被忽略。

**根因:** chart 的 `prometheus.yaml` 模板是 `if selector → else if *NilUsesHelmValues → else {}`,
而 `serviceMonitorSelectorNilUsesHelmValues` **默认 true** → 空 `{}` 被**改写**成 `release: <release名>`。
**"写 `{}` 并不等于全选"**, `ruleSelector` / `scrapeConfigSelector` 同理。

**解法:** 要全选必须**同时**置对应的 `*SelectorNilUsesHelmValues: false`。
三组 selector 与配套开关见 `docs/prometheus-observability.md` §2.3。

#### 8.3 KSM label allowlist 不生效(所有 `kube_pod_labels` join 全空)

**症状:** recording rule 的 `* on(namespace,pod) group_left(label_ai_cubestack_io_*) kube_pod_labels{...}`
结果为空, 但 KSM pod 正常、`kube_pod_labels` 本身有数据。

**根因:** allowlist 没配上(或被 `--set` 切断)。这个值**含逗号**:
`pods=[a,b,c],statefulsets=[d]` —— 逗号既是值的分隔符也是 `--set` 的键分隔符,
用 `--set` 传必被切成畸形键, 静默为空。

**解法:** 走 **values 文件**(`-f`)而不是 `--set`; 并核对 KSM pod 的 args 里那串是完整的:
```bash
kubectl -n monitoring get deploy <KSM名> -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -c 'part-of'
```
**另有一条实测结论:** allowlist **只作用于 `<resource>_labels` 指标**,
**不会**加到 `kube_statefulset_replicas` / `kube_pod_status_ready` 这类指标上
(2026-09-20 用 KSM v2.20.0 实机确认)。所以要那些指标带 label 时必须走 join ——
本仓库的 recording rules 已全部按 join 实现。源仓库 `docs/dependencies.md` §2.1 里
`count(kube_statefulset_replicas{label_ai_cubestack_io_dev_environment!=""})` 那种直接过滤的写法
会返回空(其 recording rules 实际并未这么写, 是散文与实现的偏差)。

#### 8.4 node-exporter 的 `--collector.infiniband` 加上去了, RDMA 指标还是空

**症状:** `node_infiniband_*` 一个都没有, RDMA dashboard 无数据。

**根因(两种):**
1. 覆盖 `extraArgs` 时**只写了新增的那一条** —— Helm 对 **list 是整体替换不是合并**,
   chart 默认的两条 filesystem 过滤被一起删掉(这个会顺带让 `node_filesystem_*` 指标爆炸);
   反过来说, 如果连默认两条都没了, 说明覆盖写法本身就错了。
2. 误以为要额外挂载 `/sys/class/infiniband` —— **不需要**: chart 已把宿主 `/sys` 挂到 `/host/sys`
   并传了 `--path.sysfs=/host/sys`, infiniband collector 走的就是 sysfsPath。
   (与 §三.6/`10_rdma` 那次"无 IB 设备节点挂 `/sys/class/infiniband` 报 operation not permitted"
   是两回事, 别混。)

**解法:** 覆盖 `extraArgs` 时把 chart 默认两条**原样带上**, 第三条才是 `--collector.infiniband`。
`08_prometheus.sh` 已如此实现并注释了原因。

#### 8.5 BMC exporter 起来了、target 是 up, 但指标全空

> ⚠ **先破除一个误导: `up{job="bmc-oem-exporter"} == 1` 不代表 BMC 是通的。**
> 该 exporter 走 `/probe?target=<ip>` 的**多目标**模式 —— 目标 BMC 不可达/凭据错时,
> 它只是返回"探测失败", **exporter 自己仍然 `up=1`**。真正的目标健康在
> **`bmc_pcie_scrape_success`**(0/1, 每 BMC 一条)。
> (`idrac-exporter` 走 `/metrics?target=` 则是另一种: 目标不可达时**抓取直接失败 → up=0**。
>  两个 exporter 模式不同, 别用同一套判断。)
>
> 2026-09-20 实测: 指向不可达 IP 时 4 条 `up` 序列里有 2 条为 1,
> 而 `bmc_pcie_scrape_success` 全为 0 —— **只看 `up` 会得到假绿灯**。

**症状:** exporter pod Running, `up` 有值, 但 BMC 相关指标没有数据
(或 `bmc_pcie_scrape_success == 0`)。

**根因(按概率):**
1. **`BMC_HOSTS` 里的 IP 不是该环境的真实 BMC** —— 主机 ↔ BMC **不是按末位对应的**,
   按规律推会连到别的机器/连不通;
2. 节点到 BMC 管理网段不通(部署机探不到 BMC 网段, 必须在**节点侧**测);
3. `BMC_HOSTS` 没设或口令错 → 早已被模块的硬校验拦下, 不会走到这一步
   (但**口令错但格式对**不会被拦, 表现为 scrape 失败 —— 这时看 exporter 日志的 401);
4. ScrapeConfig 的 `release` 标签与 Prometheus CR 的 `scrapeConfigSelector` 不匹配
   → **ScrapeConfig 根本不生效**(但不会报错)。

**解法/排查:**
```bash
kubectl -n monitoring get scrapeconfig | grep bmc                  # 有对象吗
kubectl -n monitoring get deploy | grep bmc                        # 两个 deployment 都 Ready 吗
# 查**目标层**健康, 而不是 up:
#   bmc_pcie_scrape_success == 0        → BMC 没通/凭据错
#   up{job="idrac-exporter"} == 0       → 同上(这个 exporter 的抓取本身就失败)
kubectl -n monitoring logs deploy/cubestack-bmc-exporter-bmc-oem-exporter | tail -20   # 看 401/timeout
# 从**节点**侧测 BMC 可达性(不是从部署机):
ssh <master> "timeout 5 bash -c '</dev/tcp/<BMC_IP>/443' && echo ok"
```
模块部署时会自动从**节点侧**探测每个 BMC 的 443 并给出告警 —— 出现告警就别急着看 dashboard。

#### 8.6 新增配置项后, 宿主机 `check-modules.sh` 通过、容器内报 `TOGGLE 未声明`

**症状:** 加了一个带 `TOGGLE` 的新模块, 宿主机 `bash deployments/scripts/tools/check-modules.sh` 全绿,
同步进部署容器后容器内校验报 `TOGGLE=XXX 未在 cluster.conf.example 中声明默认值`。

**根因:** `tools/sync-to-container.sh` 的默认同步范围**刻意不含 `deployments/config/`**
(避免覆盖容器里那份**环境实际**的 `cluster.conf`)—— 但 `cluster.conf.example` 是**模板不是环境配置**,
它不跟着同步就会与源码脱节, 而 `check-modules.sh` 的 TOGGLE 检查读的正是模板。

**解法:** 该工具的 `DEFAULT_PATHS` 已加入 `deployments/config/cluster.conf.example`(2026-09-20)。
**live `cluster.conf` 仍然不参与同步** —— 那才是各环境独立的配置。
存量容器若仍报此错, 手工补一次:
```bash
docker cp deployments/config/cluster.conf.example <容器>:/opt/cubestack-installer/deployments/config/
```

#### 8.7 大 dashboard 导入失败: `metadata.annotations: Too long: may not be more than 262144 bytes`

**症状:** 11 个 Grafana 看板里**只有 `node-exporter-1860` 一个**导入失败(其余 10 个正常),
`kubectl get cm -l grafana_dashboard=1` 少一个, 但 Grafana 里只表现为"少了那个看板"。

**根因:** 客户端 `kubectl apply` 会把**整个配置**存进
`kubectl.kubernetes.io/last-applied-configuration` 注解, 该注解有 **256KiB 硬上限**。
`node-exporter-1860.json` 460KB → 生成的 ConfigMap 约 522KB → 必超。
**与 ConfigMap 自身 1MiB 的容量上限无关** —— 卡的是注解, 不是对象大小, 所以"才 522KB 怎么会超"
的直觉是错的。只有它失败正是因为只有它过了这条线。

**解法:** 大对象一律用 **`kubectl apply --server-side`**(服务端 apply 不走该注解):

```bash
kubectl create configmap <名> -n monitoring --from-file=<文件> --dry-run=client -o yaml \
  | kubectl apply --server-side -f -
```
`08_prometheus.sh` 的看板块已改用 `--server-side`(实机验证 522KB 正常创建, label 与 data 完整)。

**通用教训:** 任何可能超过 256KiB 的 ConfigMap / Secret 都不要用客户端 apply。
另外, **模块里管道 apply 时别把 stderr 全 `2>/dev/null` 吞掉** —— 这条错误信息就这么被吞过,
只剩一句"导入失败", 排查时得手工重放才知道是注解超限。

#### 8.8 `--steps prometheus` 每次都报 "operator 180s 内未 Ready", 但 operator 明明是 Running

**症状:** 模块第 4 步稳定输出 `⚠ operator 180s 内未 Ready`, 而 `kubectl -n monitoring get deploy`
显示 operator 1/1 Running 已很久。

**根因:** 模块原来查的是 `rollout status deploy ${RELEASE}-operator`, 但 chart 生成的
operator Deployment 名是 **`<release>-kube-prome-operator`**(kube-prometheus-stack 对子组件
加了 `kube-prome-` 中缀)。名字对不上 → `NotFound` → `rollout status` 恒非零 → 恒报未就绪。
**这条告警从来没成功过**, 属于"永久假告警"。

**解法:** 不硬编码名字, 按名字动态查(与 `31_cubepilot.sh` 同款):
```bash
_OP_DEPLOY="$( (SSH "${K}" -n "${NS}" get deploy -o name) | sed -n 's#.*/##p' | grep -m1 'operator' )"
```
已在 `08_prometheus.sh` 修复(2026-09-20)。

**为什么要修这种"无害"的假告警:** 它会训练所有人忽略这条告警 —— 真出问题时没人看。
排查成本最低的正是这类"一直都有, 不用管"的输出。

---

### 9. RDMA 共享设备插件: pool 模式 selectors.ifNames 只剩第一块网卡(其余卡静默不匹配)

**症状**
`RDMA_HCA_MODE=pool` + 自动检测时, 日志里检测到 N 块 RDMA 网卡, 但生成的 ConfigMap 里
`selectors.ifNames` **只有第一块**网卡的网卡名:

```
→      10.244.1.11: 检测到 RDMA 设备 → ibs2:ibs2:32:ACTIVE ibs3:ibs3:32:ACTIVE ens1np0:ens1np0:1:ACTIVE
→    自动检测结果: ibs2:ibs2:32:ACTIVE,ibs3:ibs3:32:ACTIVE,ens1np0:ens1np0:1:ACTIVE
→    pool 模式 ifNames: ibs2            ← 只有第一块(应为 ibs2,ibs3,ens1np0)
```
后果: 某节点只有 ibs3(没有 ibs2)时该资源**不注册** → 那台节点 `allocatable` 里没有 RDMA 资源,
按资源名调度的 Pod 落不上去。插件与模块**都不报错**, 属静默故障。

**根因**
`10_rdma_shared_dev_plugin.sh` 的 pool 分支把「设备三元组」单行逗号串直接 `cut -d: -f2`:
`DETECTED_HCAS` 是**一行**(逗号分隔, 串内无换行), `cut` 按整行切分 → 只取到第一个冒号后的字段;
前面的 `tr '\n' ','` 是空操作。→ 取到的永远只是第一个设备的网卡名。

> **同类的第二处(同日修复, 只影响日志)**: per-hca 分支用 `${_rest##*:}` 取链路类型, 而三元组是
> `<设备名>:<网卡名>:<类型>[:<状态>]` → 取到的是末尾的**状态**(`ACTIVE`), `32|1` 永远匹配不上,
> 部署日志里 IB/RoCE 提示恒为 `?`。修法是先 `${_rest#*:}` 跳过网卡名再 `${_rest%%:*}` 取首段。

**解法(根治)**
先按逗号拆成多行再 `cut`(2026-09-21 已修):
```bash
IF_NAMES="$(echo "${DETECTED_HCAS}" | tr ',' '\n' | cut -d: -f2 | sort -u | tr '\n' ',')"
IF_NAMES="${IF_NAMES%,}"
```
`per-hca` / `by-link` 不走这条路径(前者用 `_dev_nets` 逐设备映射, 后者按链路类型归池), 不受影响。

**验证**
本地打桩自检(**不碰集群**: 打桩 ssh/skopeo/curl 跑真模块, 再解析生成的 ConfigMap):
输入 3 块卡(2 IB + 1 RoCE) → `ifNames: ["ens1np0","ibs2","ibs3"]`; 修复前为 `["ibs2"]`。
regression: per-hca 自动检测 3 资源、pool 显式名单单资源均不变。

**相关命令**
```bash
kubectl -n kube-system get cm rdma-devices -o go-template='{{index .data "config.json"}}'
```

---

### 10. RDMA 资源名与真实 GPU 集群不一致 → Pod 申请 `rdma/hca_shared_devices` 永久 Pending

**症状**
同一份 Pod 清单在真实 GPU 集群能跑, 在本安装器部署的集群上 Pending:
`0/N nodes are available: ... Insufficient rdma/hca_shared_devices`。集群本身"部署成功"。

**根因**
两端资源名不同源: 真实集群的插件由 metax 侧以 `--rdma-ib-resource` / `--rdma-roce-resource`
配置(实测 `cm rdma-devices` 里为 `hca_shared_devices` / `roce_hca_shared_devices`, 前缀 `rdma`),
而本安装器默认走 per-hca(`nvidia.com/<设备名>`)/ pool(`nvidia.com/mlx5_0`)—— 名字对不上时
Pod 申请的资源名在集群里**根本不存在**, 且报错只出现在 Pod 事件里, 部署日志一片绿。

**解法(根治)**
`RDMA_HCA_MODE=by-link`(**cluster.conf.example 默认值**, 2026-09-21 起): 按链路类型分成两池,
资源名取 `RDMA_IB_RESOURCE`(默认 `rdma/hca_shared_devices`)/ `RDMA_ROCE_RESOURCE`
(默认 `rdma/roce_hca_shared_devices`), 与真实集群对齐; 名字可在 cluster.conf 改(插件侧对应
`--rdma-ib-resource` / `--rdma-roce-resource`)。
⚠ 显式 `RDMA_IF_NAMES` 且未写类型时无法判定链路类型 → 归 RoCE 池并告警, 要精确分类写
`<设备名>:<网卡名>:<类型>`(32=IB / 1=RoCE); 某类型无卡则不生成该池条目。

**验证**
本地打桩自检 ①: 2 IB + 1 RoCE → 恰好两条 `rdma/hca_shared_devices`(ifNames 2 张 IB 卡)+
`rdma/roce_hca_shared_devices`(1 张 RoCE 卡); ④ 占位模式两池 + `rdma-placeholder=true` 标注不变。

**相关命令**
```bash
kubectl -n kube-system get cm rdma-devices -o yaml        # 真实集群/本集群的实际资源名
kubectl describe node <节点> | grep -A5 rdma/             # 节点上真正注册了哪些资源
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

### 2. 部署容器同步后 `check-modules.sh` 报 `MODULE key 重复: xxx (NN_old.sh 与 NN_new.sh)`

**症状:** `tools/sync-to-container.sh` 同步到部署容器后, 容器内静态校验报同一个 MODULE key 出现两份。

**根因:** 该工具用 `docker cp` **合并式**同步 —— 容器里不存在"源已删则目标也删"的语义;
模块**改名/改序号/删除**后旧文件残留在容器里(例: `33_cubestack_gateway.sh` 删除后, 容器里那份还在)。

**解法:** 容器里删掉旧文件后重跑校验:
```bash
docker exec <容器> rm -f /opt/cubestack-installer/deployments/scripts/modules/03_addon/NN_old.sh
```
同步工具末尾的"容器内静态校验"就是用来拦这个的 —— **报错务必处理, 别当噪音**。

### 3. Harbor 统一镜像源(上游→Harbor→离线 tar)工具链的 5 个坑

**背景:** `docs/harbor-mirror.md` 的统一镜像源工具(`tools/images/harbor-{sync,save}-images.sh`、
`check-image-manifest.sh`)实现时踩到的坑。都不报"明显错误", 而是**静默失效**, 特此沉淀。

#### 3.1 skopeo 连公开镜像都 fatal: `reading JSON file "/run/containers/<uid>/auth.json": permission denied`

**症状:** 拉公开镜像(无需任何凭据)也失败, 报读不到默认 auth 文件。
**根因:** skopeo 默认 auth 文件路径是 `${XDG_RUNTIME_DIR}/containers/auth.json`, 未设该变量时
退到 `/run/containers/<uid>/auth.json` —— **容器内 / 非 root 场景该目录普遍不可读**, skopeo 直接 fatal。
**解法(根治):** 显式指定自建 auth 文件, 不让 skopeo 猜默认路径:
```bash
AUTH=$(mktemp); chmod 600 "$AUTH"; printf '{"auths":{}}' > "$AUTH"
export REGISTRY_AUTH_FILE="$AUTH"        # 有凭据时写入 {"auths":{"<host>":{"auth":"<base64 u:p>"}}}
```
顺带好处: 凭据写文件而非 `--src-creds/--dest-creds`, **不进 argv / 不进 ps / 不进 CI 日志**。
**验证:** `REGISTRY_AUTH_FILE=$AUTH skopeo inspect docker://registry.k8s.io/pause:3.10` 能返回 digest。

#### 3.2 `skopeo inspect` 报 `unknown flag: --src-tls-verify` 被 2>/dev/null 吞掉 → 幂等静默失效

**症状:** 同步工具每次都全量重传, "digest 未变则跳过"从不生效。
**根因:** `copy` 与 `inspect` 的 TLS 旗标名**不同**: `copy` 用 `--src-tls-verify`/`--dest-tls-verify`,
**`inspect` 用 `--tls-verify`(单数)**。传错 → 命令失败 → 被 `2>/dev/null || true` 吞成"取不到 digest"
→ 退化成"跳过比对直接同步" → 每次全传。
**解法(根治):** 两套参数**分开维护**(`SKOPEO_SRC_OPTS` vs `INSPECT_SRC_OPTS`)。
**验证:** 连跑两次 `harbor-sync-images.sh --group rdma`, 第二次必须打印 `digest 未变, 跳过`。
> 教训: `2>/dev/null` 会把"参数写错"伪装成"环境问题"。关键判据(这里=digest)取空时要有
> 独立的告警, 不能只当"无数据"处理。

#### 3.3 Harbor 漂移检查把**已存在**的镜像全报"缺失"

**症状:** `check-image-manifest.sh --harbor` 把 63 个镜像全报缺失, 但 Harbor 上确实有。
**根因:** Harbor API `GET /projects/{p}/repositories/{repo}/artifacts/{ref}` 有两条硬规则:
① repository 名要**双重 URL 编码**(`/` → `%252F`, 单重 `%2F` 一律 404);
② 路径里的 repository 名**不含项目前缀**(项目已在路径段里)。
**解法(根治):**
```bash
path="${dst#<host>/<project>/}"; tag="${path##*:}"; repo="${path%:*}"
enc_repo="$(printf '%s' "$repo" | sed 's#/#%252F#g')"
curl -u u:p "$API/api/v2.0/projects/<project>/repositories/${enc_repo}/artifacts/${tag}"
```
**验证:** 该端点对已存在镜像返回 200, 不存在返回 404。

#### 3.4 离线 tar 的 `RepoTags` 为空 → 模块识别不出 tar 内容

**症状:** 用 skopeo 生成的 tar, `tar -xOf x.tar manifest.json` 看到 `"RepoTags": []`;
`lib-common.sh` 的 `tar_first_image_tag` 返回空 → 依赖内容匹配的逻辑(cubepilot 推送兜底、
`ensure_registry_nginx`)全部失效。
**根因:** `skopeo copy ... docker-archive:<file>` **末尾不带 `:<ref>` 时 skopeo 不写 RepoTags**
(docker save 会写, 所以老的 tar 都正常)。
**解法(根治):** 目标写成 `docker-archive:<file>:<上游 ref>`, 且 ref 用**上游 ref**
(与 docker save 产出一致, 既有模块的通配/内容匹配都不用改)。
**验证:** `bash -c 'source deployments/scripts/lib-common.sh; tar_first_image_tag <tar>'`
应打印 `quay.io/prometheus/node-exporter:v1.12.1`。

#### 3.5 Harbor 项目不存在导致 push 失败(仓库会自动建, 项目不会)

**症状:** `skopeo copy` 推到 `harbor.isuanova.com/mirrors/...` 报项目不存在/未授权。
**根因:** Harbor 只在首次 push 时自动创建**仓库(repository)**; **项目(project)必须预先存在**,
且**创建项目需要登录**(匿名建项 401)。
**解法(根治):** 同步工具先探测项目(HTTP 200?), 不存在则用凭据 POST 创建(公开只读,
便于部署机匿名拉取); 无凭据时给出明确指引而不是让 push 以一个含糊错误失败。
**验证:** `curl -u u:p -X POST "$API/api/v2.0/projects" -d '{"project_name":"mirrors","metadata":{"public":"true"}}'`
返回 201(已存在则 409)。

> 另: Harbor 上 `clquan` **不是 sysadmin**, 但仍可创建项目(实测 201)——
> 判断"能不能建"要实测, 不要凭 `sysadmin_flag` 推断。
#### 3.6 CI 登录 Harbor 报 `unauthorized` —— `gh secret set --body -` 把字面量 `-` 存成了密钥值

**症状:** GitHub Actions 工作流在 `docker/login-action` 步骤失败:
`Error response from daemon: Get "https://harbor.isuanova.com/v2/": unauthorized:`;
但同一组用户名/密码用 `curl -u` 在本机验证完全正常。

**根因:** 设密钥时用了 `printf '%s' 'EErMChQa123' | gh secret set NAME --body -`。
`gh secret set` 的 `-b/--body` 是"**直接给出值**", 不是"从 stdin 读"的标记 ——
传 `-` 会把**字面量 `-`** 存成密钥值。要走 stdin 必须**省略 `--body`**。
(密钥一旦写入无法读回校验, 所以只能从"登录失败 + 本机 curl 正常"这个矛盾反推出来。)

**解法(根治):**
```bash
gh secret set HARBOR_MIRROR_USER     --repo <owner>/<repo>   # ← 不写 --body, 管道喂 stdin
gh secret set HARBOR_MIRROR_PASSWORD --repo <owner>/<repo>
```
**验证:** 重跑工作流, 日志里 `HARBOR_MIRROR_PASSWORD` 显示为 `***` 且登录成功。

> ⚠ **附带教训(本项目实测踩到)**: 凭证自检步骤**不要回显密码长度**。
> 仓库是 public 时工作流日志公开可见, 长度属可被利用的旁路信息。只回显用户名即可。
#### 3.7 【已解决】registry.k8s.io/pause:3.10 每次同步都被整包重传(~552 MB / 64s)

**症状:** CI 全量同步里 46/47 命中 `digest 未变, 跳过`, 只有 `registry.k8s.io/pause:3.10`
每次都被完整重传(实测 08:32:39 → 08:33:43, 约 64 秒; 镜像 552 MB)。

**根因:** `skopeo copy` 在搬运多架构镜像时会**重写 manifest list 的序列化**, 落地 digest
因此 ≠ 源 digest ⇒ digest 比对永远不相等 ⇒ **每次同步都整包重传**。

**关键证据(如何判定"是重写而非上游变化"):**
- 源 digest `sha256:ee6521f290b2168b...` 与库 digest `sha256:e9622b01071c38e4...`
  在连续 3 次运行中**各自稳定、始终不等** —— 上游真换了内容的话, 变化的是**源侧** digest。
- 对照: 同批 `quay.io/prometheus/node-exporter:v1.12.1`(6 平台 docker manifest list)
  源/库 digest 完全一致、正常跳过 ⇒ **特定镜像触发, 不是所有多架构镜像都这样**。

**解法(根治):** `skopeo copy` 加 `--preserve-digests`(要求原样保留源侧 manifest/list 的
digest —— 这本就是"镜像"应有的语义)。已落到 `tools/images/harbor-sync-images.sh`。

**验证(⚠ 时机是关键, 第一轮曾据此误判):**
```bash
# 库 digest 应变成与源一致(不再是自己重写后的值)
skopeo inspect --format '{{.Digest}}' docker://harbor.isuanova.com/mirrors/registry.k8s.io/pause:3.10
#   修复前: sha256:e9622b01071c38e4...   (≠ 源)
#   修复后: sha256:ee6521f290b2168b...   (= 源) ✅
# 下一轮全量同步应全部跳过
#   ✅ 同步完成: 新同步 0 个, digest 未变跳过 47 个, 失败 0 个
```

> ⚠ **踩坑: 别在"做重传的那一轮"里判断修复有没有生效。**
> 加旗标后的**第一轮**运行必然仍然打印 `digest 不一致, 重新同步` —— 因为那一轮的 digest 比对
> 读到的是**加旗标之前落地的旧制品**, 然后才用新旗标重传。必须看**再下一轮**是否变成
> `digest 未变, 跳过`。本项目第一轮据此把已生效的修复误判为"无效"并写进了文档, 第二轮才纠正。

