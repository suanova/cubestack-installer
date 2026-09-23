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

### 5. Ceph / Rook 部署故障速查

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

### 6. 新增配置项后, 宿主机 `check-modules.sh` 通过、容器内报 `TOGGLE 未声明`

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

### 7. 大 ConfigMap 用客户端 apply 报 `metadata.annotations: Too long: may not be more than 262144 bytes`

**症状:** 批量导入一堆配置(实测: 11 个 Grafana 看板 JSON 中**只有 460KB 的那一个**失败, 其余 10 个正常),
`kubectl get cm -l <label>` 少一个, 但组件侧只表现为"少了那一条", 没有任何报错。

**根因:** 客户端 `kubectl apply` 会把**整个配置**存进
`kubectl.kubernetes.io/last-applied-configuration` 注解, 该注解有 **256KiB 硬上限**。
460KB 的 JSON → 生成的 ConfigMap 约 522KB → 必超。
**与 ConfigMap 自身 1MiB 的容量上限无关** —— 卡的是注解, 不是对象大小, 所以"才 522KB 怎么会超"
的直觉是错的。只有它失败正是因为只有它过了这条线。

**解法:** 大对象一律用 **`kubectl apply --server-side`**(服务端 apply 不走该注解):

```bash
kubectl create configmap <名> -n <ns> --from-file=<文件> --dry-run=client -o yaml \
  | kubectl apply --server-side -f -
```
(实机验证: 522KB 的 ConfigMap 正常创建, label 与 data 完整。)

**通用教训:**
1. 任何可能超过 256KiB 的 ConfigMap / Secret 都不要用客户端 apply;
2. **模块里管道 apply 时别把 stderr 全 `2>/dev/null` 吞掉** —— 上面这条错误信息就这么被吞过,
   只剩一句"导入失败", 排查时得手工重放才知道是注解超限。

### 8. RDMA 共享设备插件: pool 模式 selectors.ifNames 只剩第一块网卡(其余卡静默不匹配)

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

### 9. RDMA 资源名与真实 GPU 集群不一致 → Pod 申请 `rdma/hca_shared_devices` 永久 Pending

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

### 10. kube-vip 控制面负载均衡(`lb_enable`):`lb_fwdmethod: local` 是**静默零效果**,且 ipvs 模式集群上还有一道 kube-proxy 关卡

**症状**
给 kube-vip 的 manifest 加 `lb_enable: true`(其余不动)后**没有任何报错**,日志还会打
`Starting IPVS LoadBalancer`,但:

- `ipvsadm -L -n -t <VIP>:6443` 在 leader 上列出的 3 个后端**全是摆设** —— 所有经 VIP 的连接
  仍然只落在 leader 本机那台 apiserver(masquerade/haproxy 那类"流量分散"完全没发生);**或者**
- 条目确实建起来了,但约 **30 秒后自己消失**(`syncPeriod: 30s`)。

两种表现都是**静默失效** —— 没有 error、没有 CrashLoop,`verify_kube_vip` 现有六项也全部通过
(它验的是"VIP 在、healthz 通",这两件事在 LB 失效时依然成立)。

**根因(两条,互相独立)**

**① `lb_fwdmethod: local` 在内核里等于"不转发"。**
这是 kubespray 的默认值(`kubespray_defaults/defaults/main/main.yml:88`),kube-vip 的 CLI 默认也是它。
`net/netfilter/ipvs/ip_vs_conn.c:1043`:

```c
case IP_VS_CONN_F_LOCALNODE:
    cp->packet_xmit = ip_vs_null_xmit;
```

`ip_vs_xmit.c:722` 的 `ip_vs_null_xmit` 注释直言 `we do not touch skb` —— 包原样交回本机协议栈。
而 kube-vip v0.8.9 的 `NodeWatcher`(`pkg/cluster/clusterLeaderElection.go:308`)确实按
`node-role.kubernetes.io/control-plane` 把**全部**控制面节点登记成了后端 ——
**登记是真的,转发是没有的**。两者合起来就是"看起来配好了、实际零效果"。

> 要真负载均衡只能用 **`masquerade`**。kubespray 官方文档也是这么配对的
> (`docs/ingress/kube-vip.md`:`kube_vip_lb_enable: true` + `kube_vip_lb_fwdmethod: masquerade`)。
> kube-vip 文档里那句 *"with local forwarding method, the API server will be added as a backend only
> if its IP address is present locally on the node"* 说的是同一件事的另一种表述。

**② 本集群 `kube_proxy_mode: ipvs`,kube-proxy 会删掉一切不是它自己建的 IPVS 规则。**
kube-proxy **v1.32.5**(本集群实际版本)`pkg/proxy/ipvs/proxier.go:1972`:

```go
func (proxier *Proxier) cleanLegacyService(activeServices sets.Set[string], currentServices map[string]*VirtualServer) {
	for cs, svc := range currentServices {                      // 内核里现有的全部 IPVS service
		if proxier.isIPInExcludeCIDRs(svc.Address) { continue } // ← 只有排除段内的才放过
		if !activeServices.Has(cs) {
			proxier.ipvs.DeleteVirtualServer(svc)               // ← 不是自己建的 → 删
		}
	}
}
```

唯一解是 `ipvs.excludeCIDRs` 把 VIP 排除掉(kubespray 侧变量 `kube_proxy_exclude_cidrs`)。
⚠ kube-proxy **只在启动时读**该字段 —— 改完 ConfigMap 必须
`kubectl -n kube-system rollout restart daemonset/kube-proxy`,否则改了也不生效(实测:改完 45s 内
`restartCount` 仍为 0,条目照旧)。

**解法(本项目决策:不开)**

D4 保持"纯故障切换"、不开 `lb_enable`。理由是收益/代价不划算,且**破坏"单一配置源"**:

- 开 LB 的额外前提:换 `kube-vip-iptables` 镜像 + privileged 容器 + 改宿主机 sysctl
  (`net.ipv4.ip_forward` / `net.ipv4.vs.conntrack`,由 kube-vip 自己写) + 上述 excludeCIDRs 耦合。
- `excludeCIDRs` 必须与 VIP **长期保持一致**,而本项目 VIP 是**自动推导**的 —— VIP 一漂移,
  排除段忘了跟就会静默失效(又回到"看起来配了其实没生效")。
- 排除 VIP 还有个连带副作用: kube-proxy 从此**不再管理 VIP 上的 NodePort 规则**,已有条目被冻结。
  实测 `10.66.1.139:31680` 的后端被摘掉后不再恢复(本集群 registry 拉镜像走 `registry.cubestack.io`
  → `10.66.1.131`,**不依赖** VIP 的 NodePort,故影响有限,但确实是个反直觉的行为变化)。
- 而"API 入口不单点"这件事,**现状已经做到**(`verify_kube_vip` ⑥ 漂移演练实测通过)。

**若将来仍要开**,唯一推荐做法:由部署模块从**同一个 VIP 变量**同时生成 kube-vip manifest 与
`kube_proxy_exclude_cidrs`,让两处永远一致(把耦合自动化),并按 ① 用 `masquerade`。

**验证(边界必须看清)**

已验证:
- **① 的结论**:内核 `ip_vs_conn.c:1043` + `ip_vs_xmit.c:722` 逐行确认 `local` → `null_xmit`;
  kube-vip v0.8.9 的 `NodeWatcher` 登记全部控制面节点。**这是源码级判定,不是实机跑出来的**
  ("后端登记了但不会被转发"这个结论由两侧代码共同支撑)。
- **② 的结论**:读本集群实际版本 kube-proxy **v1.32.5** 的 `cleanLegacyService` 确认;
  实机配置 `excludeCIDRs` 并重启后,VIP 上的既有 IPVS 条目**保留未被清理**,与代码里的
  `isIPInExcludeCIDRs` 跳过分支一致。
- **本集群现状**:VIP `10.66.1.139` 由 `10.66.1.154` 持有,IPVS 中**无** `10.66.1.139:6443` 条目
  —— 即 LB 未启用(设计如此)。

**未验证(不要当成已验收)**:
- **`masquerade` 的端到端效果从未实测** —— 经 VIP 的请求是否真轮询到三台、单台 apiserver 挂掉后的
  收敛耗时,本次都没测(只做了源码与 kube-proxy 侧验证就按决策回退了)。
- **②的"删除"一幕没有取到反例**:本次是先配排除段、后重启,没有先目击"不配排除段时规则被删"。
  删除行为目前按源码判定(有 kube-vip 官方 known-issue 佐证:
  *"if kube-proxy is configured with ipvs mode, it will monitor all ipvs rules on the Node and remove
  those that are not created by it"*)。

**相关命令**
```bash
# kube-vip 的 LB 条目只会出现在 leader 上(ARP 模式)
ssh <master> sudo ipvsadm -L -n -t <VIP>:6443

# 本机 IPVS 全貌(注意 kube-proxy 建的 NodePort/ClusterIP 也在这里, 别误判成 kube-vip 的)
ssh <master> sudo ipvsadm -L -n

# kube-proxy 的模式与排除段
kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | sed -n '/^ipvs:/,/^kind:/p'

# 改了 kube-proxy 配置后必须滚动重启才生效
kubectl -n kube-system rollout restart daemonset/kube-proxy
```

---

### 11. kube-vip 的三个"以为收敛了其实没有":关开关不清理 / 每轮白重启两次 / 全新集群部署中断

三个问题的根因相邻(都是"目标状态与实际状态不一致,但没有任何东西去发现它"),
于 2026-09-22 一并修复。设计说明见 `docs/kube-vip-api-ha.md` 第 18 节。

#### 11.1 `KUBE_VIP_ENABLED=false` 重跑后,manifest 还在、VIP 还被持有

**症状**
把开关改成 `false` 重跑,日志只有一行 `跳过 kube-vip(配置 KUBE_VIP_ENABLED=true 可启用)`,
但:

```bash
ssh <master> sudo ls /etc/kubernetes/manifests/kube-vip.yml   # ← 文件还在
ssh <master> sudo crictl ps | grep kube-vip                    # ← 容器还在跑
ssh <master> ip -4 -o addr show | grep '<VIP>/'                # ← VIP 还被绑着
```

即"以为关掉了,其实它照跑、照持有 VIP、还继续参与租约选举"。

**根因(两层,第二层才是关键)**
① `09_kube_vip.sh` 里只有 `say "跳过"` + `exit 0`,从来没有删除逻辑 ——
   而文档 §7.4 从设计之初就承诺了"关开关重跑 = 删 static pod manifest"。
② 更根本: **模块根本不会被调度。** 模块框架的规则是"带 `TOGGLE` 的模块,开关为 false 时
   不进 RUN_STEPS"(`lib-module.sh#module_default_on`),而该模块原是 `DEFAULT: 0` ——
   开关一关,脚本连那一行"跳过"都没有打印过。

**解法**
模块改 `DEFAULT: 1`(常驻全量运行)+ 内部按开关分派到"安装/清理";同时
`deploy-cluster.sh` 的 TOGGLE 导出循环加 `! module_default_on` 前置条件 —— 否则它会对
RUN_STEPS 里的任何 TOGGLE 模块无条件 `export KUBE_VIP_ENABLED=true`,把用户写的 `false`
冲掉,清理分支永远不可达。

**相关命令**
```bash
# 关闭态清理(第 3 步起才动文件, 前两步都在拦停)
sudo ./deploy-cluster.sh --steps kube_vip

# 手动确认清干净了(三样都要为空)
for h in <master1> <master2> <master3>; do
  ssh $h "sudo ls /etc/kubernetes/manifests/kube-vip.yml 2>&1; sudo crictl ps | grep kube-vip; ip -4 -o addr show | grep '<VIP>/'"
done
```

> ⚠ **阶段二下不能直接关**:API 入口已经指向 VIP 时删 kube-vip = 全集群 API 立刻失联。
> 模块会**硬拦停**并给出两步走法(先把入口退回 master01 → 再关开关清理)。

#### 11.2 每次全量运行,master01 上的 kube-vip 都会重启两次

**症状**
每跑一次全量部署,`crictl ps` 里 master01 的 kube-vip 容器 `started-at` 都会变
(最直观的是看 `crictl ps -a | grep kube-vip` 的退出记录)。master02/03 不受影响。
如果 master01 正好是 VIP 持有者,这一轮里 VIP 会跟着抖动两次。

**根因: 同一个文件有两个写入者,而它们渲染出来的字节不一样。**

| 写入者 | 首台 master 的 hostPath |
|---|---|
| kubespray(`node/tasks/main.yml:19`,条件 `kube_vip_enabled`) | `/etc/kubernetes/super-admin.conf` |
| `09_kube_vip.sh` | `/etc/kubernetes/admin.conf` |

kubespray 对**首台** CP 会走 `loadbalancer/kube-vip.yml:26-31` 的 `set_fact`,在
"`super-admin.conf` 存在 或 kubeadm 没跑过"时选 `super-admin.conf`;我们的渲染器恒用 `admin.conf`。
于是: kubespray 先写 → 静态 Pod 被 kubelet 重启一次 → 本模块按 sha256 比对发现不一致、写回
→ 再重启一次。

**实测复现(2026-09-22)**: 用真正的 ansible `template` 模块复刻 kubespray 的变量解析后逐台对拍 ——
master02/03 **逐字节一致**,master01 **只差上面那一行**。也就是说**唯一的分歧点就是
`kube_vip_admin_conf`**;`kube_vip_cidr`/`dns_mode`/`leasename`/`leaseduration` 等
(`node/defaults/main.yml:60-84`)与渲染器硬编码的那组值逐条相同。

**解法(单一写入者)**
`addons.yml` 里的 `kube_vip_enabled` **恒写 `false`** —— 含义不是"kube-vip 没启用",
而是"不要让 kubespray 写这个静态 Pod"。写这个值的是 `lib-common.sh#update_kube_vip_addons_yml`。

**不要**试图去复刻 kubespray 的 `super-admin.conf` 判定来"对齐渲染" —— 那是**节点状态相关的
启发式**,复刻它等于把模块重新绑回 inventory 状态机(而模块的立身之本正是不依赖它),
且上游一次改动就会静默复发。

**相关命令**
```bash
# 看 master01 的 manifest 到底用的是哪个 kubeconfig
ssh <master01> "sudo grep -A1 'hostPath' /etc/kubernetes/manifests/kube-vip.yml"

# 确认单一写入者契约成立(应为 false)
grep '^kube_vip_enabled' deployments/kubespray/inventory/*/group_vars/k8s_cluster/addons.yml

# 密码: 全量运行前后各取一次 hash, 应当全程不变
ssh <master01> "sudo sha256sum /etc/kubernetes/manifests/kube-vip.yml"
```

> ⚠ `kube_vip_address` 与上面的开关**无关**,开关关闭时**也要保留** —— 它只喂 apiserver
> 证书 SAN(`kubeadm-setup.yml:48` 的 `sans_kube_vip_address` 只看它是否定义)。删掉它会导致
> 下次开回来时证书重签。

#### 11.3 全新集群部署在 `k8s_deploy` **之前**就中断了

**症状**
全新环境跑全量部署,日志走到 `k8s_ntp` 之后、`k8s_deploy` 之前就报:

```
【错误】集群不可达或尚未部署(首个 master 上列不出 Node)
【错误】kube-vip 需要一个已存在的集群; 请先跑 --steps k8s_deploy
部署中断: 模块 kube_vip 失败 ...
```

"请先跑 k8s_deploy" 这句提示本身自相矛盾 —— 它明明就在计划里,只是**排错了位置**。

**根因**
模块文件序号 `09` > `06` **不足以定序**。`resolve_run_steps` 会按 `REQUIRES` 做稳定拓扑排序
(`lib-module.sh#_topo_sort_requires`),而 `09_kube_vip` 原先**故意不声明 `REQUIRES`** ——
于是它被排在 `k8s_deploy` **之前**。而 `deploy-cluster.sh:611` 是:

```bash
run_module "${key}" || { FAILED=1; break; }
```

模块失败即 `break`,`is_cluster_live` 自检失败 → `exit 1` → **整个部署在装集群之前停住**。
而 `KUBE_VIP_ENABLED` 的默认值就是 `true`。

**解法**
补 `REQUIRES: k8s_deploy`。原先不写它的顾虑是"`--steps kube_vip` 会把整套 kubespray 拉进来",
该顾虑已不成立: ① `--steps` 精确模式下,依赖已完成(`REPEAT≠1` 且 `state=done`)时不拉入执行;
② `k8s_deploy` 在 `BASE_MODULES` 内,未被显式命名时会被剔除。实测 `--steps kube_vip`
仍然只跑 `kube_vip` 一个模块。

**相关命令**
```bash
# 确认执行顺序(应看到 k8s_deploy 在 kube_vip 之前)
sudo ./deploy-cluster.sh --list | grep 本次执行模块

# 确认 --steps 没被 REQUIRES 拖大
sudo ./deploy-cluster.sh --steps kube_vip --list | grep 本次执行模块
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
应打印 `<上游 ref>`, 如 `registry.k8s.io/pause:3.10`(与 tar 名后缀一致)。

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
- 对照: 同批的另一个多架构镜像(6 平台 docker manifest list; 当时取的是
  `quay.io/prometheus/node-exporter:v1.12.1`, 该镜像已随监控栈移除, 此处仅作测量记录)
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

