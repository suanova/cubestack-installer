# CubeStack 部署 Troubleshooting 手册

> **规范(强制)**:每次解决完一个部署/运行问题,**找到真正的 root cause**,按下面的模板把「症状 → 根因 → 解法 → 验证」更新到本文件(新增一个条目),保持按问题类型分组。这样同类问题下次直接命中根因,不用重新排查。
> 新增条目同时把新知识点/命令沉淀到 `skills/cubestack-deploy-scripts/SKILL.md` 的相应章节。

## 约定

- 每个条目: `### <编号>. <一句话症状>`
- 每条必须写明: **症状 / 根因 / 解法(根治) / 验证 / 相关命令**
- 按问题类别分组: 网络(CNI) / 时间同步 / 集群组件 / 离线部署 / 其它

### 清理后副本数变化、CSC finalizer 未处理或 RBD 洁净度误报

**症状**: Ceph 覆盖安装将原为 0 或多个副本的 operator / registry 改成 1; 清理失败后消费者保持停用; 平台 CR 仍在就强制删除命名空间; SSH 无结果却报告 RBD 全部清零。

**根因**: 旧恢复块无条件设 `replicas=1`, 未保存停用前状态; Operator 卸载用 Pod phase 作为 CR 删除守卫; RBD 汇总把空查询结果默认成 0。

**解法**: 停机前给对象打注解 `cubestack.io/pre-stop-replicas` 记录原副本数(仅首次, 重复停机不覆盖); 成功路径(ceph 模块 7.9)与异常退出兜底(deploy-cluster.sh EXIT 钩子, 仅非 0 退出且计划含 ceph/k8s_deploy)都**只恢复带注解对象**并清除注解; registry 以裸 ReplicaSet(`rs/registry`)为准。Operator 卸载先等 `csc` 消失(120s 有界), 未消失或查询失败**保留 operator**(finalizer 需要它活着执行)并跳过 helm uninstall、namespace finalizer patch / 强制删除及 CRD 清理(非 0 退出)。RBD 空 / 失败 / 非数字查询计为未知, 仅明确 0 允许报告清零。

**验证边界**: `test-cluster-teardown.sh` ⑤~⑧ 节用假 SSH / 裸 ssh 桩覆盖: 标记登记(含原副本非 1)/重复停机不覆盖/按值恢复/无标记不动、扫荡保留已停机裸 RS、operator CR 终结门(成功/残留两路径)、部署 EXIT 钩子接线、RBD 未知/残留报告三态。未连接真实 Kubernetes / Ceph, 不代表实际卷卸载或 CR finalizer 已端到端验证。

**相关命令**: `bash deployments/scripts/tools/tests/test-cluster-teardown.sh`; `bash deployments/scripts/tools/check-modules.sh`; 集群侧核对 `kubectl get csc -n <operator-namespace>`、`kubectl get rs registry -n kube-system -o jsonpath='{.spec.replicas}'` 及对应对象的 `cubestack.io/pre-stop-replicas` 注解。

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
- 节点虽同网段(如 192.168.100.0/24), 但跨节点 pod 流量发出去即丢, 同节点 pod 可达。

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

- **该 fabric 第二形态: MetalLB VIP 的跨段投递也会时通时断(2026-10-14 实机)**: 部署机 → `192.0.2.221:5000`
  (registry VIP)死(连 ICMP 都回不可达), 而同 registry 的 NodePort(`<master>:30492`)与集群内节点侧 VIP
  均正常 —— 同一天曾正常工作半小时后变死。**缓解已落**: `08_nvidia_gpu_operator.sh` 的 registry 端点
  **自适应降级**(VIP 探测不通 → 查 svc 实际 nodePort → 推送/预检全程走它); 其余模块同类需求可照搬
  (更好归宿 = 下沉 lib-common 的 REGISTRY_DIRECT 派生, 待排)。

### 4. 【2026-10-15 事故】calico-node 全节点 0/1 ⇒ 一切非 hostNetwork pod 访问 ClusterIP 全断 —— calico 3.32.2 自带 RBAC 新规则漏在 kubespray 模板外(403 被 felix 判为 datastore 故障)

**症状(三个层面, 表面故障离根因很远):**
1. `kubectl -n kube-system get pod -l k8s-app=calico-node` —— **全节点 0/1 Running**(bird 侧正常;
   readiness 503, felix 日志 `Reporter is not ready ... name="CalculationGraph"/"InternalDataplaneMainLoop"`);
2. **一切非 hostNetwork 的 pod 访问 ClusterIP 全断**: `https://10.233.0.1:443` → `dial tcp ... i/o timeout`
   (实机: `local-path-provisioner` CrashLoop、`calico-kube-controllers`/`coredns`/`metrics-server` 反复重启);
3. 连锁到部署面: `registry-pvc` 永不 Bound → registry pod Pending → **`k8s_registry` 模块 600s 超时、
   整个部署中断**(本次就这么断的)。

**根因:** calico 3.31.7→**v3.32.2** 升级(补丁 14 同批)后, felix **固定 watch** 的两个资源在
kubespray v2.32.0 的 `calico-node` ClusterRole 模板里**没有授权**:
`policy.networking.k8s.io/clusternetworkpolicies`(calico 3.32 随清单安装的 CNP CRD)与
`kubevirt.io/virtualmachineinstancemigrations` —— 实机 felix 日志各 `cannot list resource ... forbidden`
685 次。关键机理: **felix 把 403 判为"datastore 连接故障"**(持续重试 + readiness 恒 503),
而 **404("CRD 不存在")才是正常跳过** ⇒ 缺 RBAC 不是"少读一个资源", 而是 **felix 永不 Ready ⇒
calico-node 全节点 0/1 ⇒ calico 数据面(策略/规则链)不完整 ⇒ pod 出不了 ClusterIP**。
上游 calico v3.32.2 官方 `manifests/calico.yaml` **自带**这两条规则(kubespray 模板停留在旧版 calico
的规则集; 规则文本可直接对照 `deployments/offline-files/calico/release-v3.32.2.tgz` 内的清单)。
同类(实机逐个暴露): `calico-kube-controllers` 的 policy-name-migrator 缺 `apps/daemonsets`、
策略资源列表、`apiextensions/customresourcedefinitions` 等读权限时**每 5s 刷 forbidden**;
`kubecontrollersconfigurations/status` 是**子资源独立授权**——主资源规则(含 update)不覆盖它。

**解法(根治):** 补丁 **`deployments/kubespray/cubestack-patches/15-calico-3.32.2-rbac.patch`**
(安装/升级由补丁层自动重放; 比对口径 = 按 `(apiGroup, resource)` 归并 verbs 后与上游逐条 diff,
排除 `projectcalico.org` 别名与 `crd.projectcalico.org` 通配的假差):
- `calico-node`: +`policy.networking.k8s.io/clusternetworkpolicies`(watch/list)、
  +`kubevirt.io/virtualmachineinstancemigrations`(get/list/watch);
- `calico-kube-controllers`: +`kubecontrollersconfigurations/status`(get/update)、
  +`apps/{daemonsets,deployments}` 读、+`apiextensions/customresourcedefinitions` 读、
  +`apiregistration/apiservices` 读、+`crd.projectcalico.org` 四个策略资源(**上游同牌动词**);
- `calico-cni-plugin` + `calico-kube-controllers`: kubevirt VM/VMI 读权限(上游对齐)。

**验证(2026-10-15 实机, 通过):**
```bash
# ① 因果验证: 给 calico-node ClusterRole 补两条(等价 patch 15 的 calico-node 部分)后 ~75s:
kubectl -n kube-system get pod -l k8s-app=calico-node   # 全节点 0/1 → 全节点 1/1; felix forbidden=0
# ② 连锁恢复: local-path-provisioner 1/1 → registry-pvc Bound(pvc-50daa5ea…) → registry pod 1/1 Running
# ③ 补丁层: bash deployments/kubespray/cubestack-patch-apply.sh --check   # rc=0(含 15; 容器内同绿)
# ④ 端到端: 容器内重跑被中断的模块: ./deployments/scripts/deploy-cluster.sh --steps k8s_registry(通过)
```
**⚠ 已验证边界(如实标注):**
- calico-node 两条 = **实机因果闭环**(补上即全节点 Ready、数据面恢复);
- kube-controllers 的 `/status`、`daemonsets`、策略读、CRD 读 = 实机逐条验证(403 消失, 日志转静);
  其中**策略资源的写动词**(改名迁移)按上游保留, 本集群为全新(无存量策略)未触发;
- kubevirt 三条 = 上游逐字对齐(本集群未装 kubevirt, 属"防同类再现");
- 与上游仍有**未跟齐项**(本次未纳入, 未观察到故障; 换版时按同法重比): `calico-node` 的
  `ipamconfigurations`; `calico-kube-controllers` 的 `migration.projectcalico.org/datastoremigrations`
  (仅 datastore 迁移用)与 `projectcalico.org` 别名组(etcd datastore 用);
- 本补丁**不改运行中集群** —— 存量集群需按①手动补齐(或重跑 cluster.yml 让模板渲染)。

**相关命令:**
```bash
# 判定 calico-node 0/1 是否属"felix 数据面未就绪":
kubectl -n kube-system logs -l k8s-app=calico-node -c calico-node | \
  grep -oE "cannot list resource \"[a-z]+\" in API group \"[^\"]+\"" | sort | uniq -c
# 取上游自带 RBAC 对照:
tar -xzf deployments/offline-files/calico/release-v3.32.2.tgz -C /tmp release-v3.32.2/manifests/calico.yaml
```

---

### 5. 【2026-10-27 事故】IB 节点 host→本地 Pod 探针全超时(Calico rpfilter 与主机源策略路由冲突)—— coredns/metallb/metrics-server 0/1 无限重启, 部署卡在 MetalLB rollout

**症状**
```
TASK [kubernetes-apps/metallb : Kubernetes Apps | Wait for MetalLB controller to be running]
fatal: [cubestack-k8s-master01]: FAILED! => error: timed out waiting for the condition
```
收尾巡检多个 Pod `Running (READY 0/1)`、重启数百次, 且**只出现在带 IB 网卡的节点**:
- `coredns`(worker08, 137 次重启)、`metallb controller`(worker08, 185 次)、`metrics-server`(worker05, 161 次)、`dns-autoscaler`(worker08, 0/1);
- Pod 事件统一为探针超时:
  `Readiness probe failed: Get "http://10.233.64.2:8181/ready": context deadline exceeded`
  `Liveness probe failed: Get "http://10.233.64.4:7472/metrics": context deadline exceeded`
- 连通性特征: **Pod → 宿主机正常; 宿主机 → 本机 Pod 100% 丢包**; `ping -I <管理IP> <PodIP>` 正常。

**根因(证据链)**
1. 主机镜像 `/etc/netplan/12-ens1np0.yaml` 自带源策略路由(早于部署):
   ```
   32761: from 172.16.1.104 lookup 150 proto static
   table 150: default via 172.16.1.1 dev ens1np0
   ```
2. Calico 给本地 Pod 的设备路由**没有 preferred source**, 内核按接口枚举顺序选源; 该批 g1 机器 IB 网卡(`ens1np0`)枚举早于管理网卡:
   ```
   ip route get 10.233.64.2
   # 坏节点: 10.233.64.2 dev calie9e90a66c4a src 172.16.1.104
   # 正常节点: 10.233.86.193 dev cali1711f3dbf68 src 10.193.78.157
   ```
3. Pod 回包 `10.233.64.2 → 172.16.1.104` 到达宿主机 `cali` 网卡后, Calico raw 表:
   ```
   -A cali-PREROUTING -m rpfilter --validmark --invert -j DROP
   ```
   反向校验用回包**目的地址**(IB)查路由 → 命中 `from 172.16.1.104 lookup 150` → 出接口 `ens1np0` ≠ 入接口 `cali` → **DROP**。
4. 抓包可见回包已到达 `cali`, 但 conntrack 计数为 0; `iptables -t raw -L cali-PREROUTING -nv` 的 DROP 计数与失败 ping 包数一一对应。

**解法(根治): 让 Calico 给每 Pod 设备路由写源地址提示**
- `deployments/config/cluster.defaults.conf` 默认:
  ```
  CALICO_USE_DEFAULT_ROUTE_SRC_IPADDR=true
  ```
- `tools/k8s/sync-kubespray-config.sh` 写入 group_vars:
  ```
  calico_use_default_route_src_ipaddr: true
  ```
  kubespray 渲染 `FELIX_DEVICEROUTESOURCEADDRESS=status.hostIP` → Felix 给每 Pod 设备路由写 `src=<节点 IP>`。
- 之后 host→本地 Pod 的源地址固定为管理 IP; rpfilter 反向查询变成 `from <管理IP>` → main → `cali`, 不再命中 IB 表。
- `06_k8s_deploy.sh` 在 sync 后**硬门禁**: 若配置为 true 但生成 inventory 没有该键, 直接中止(防"配置开了但没写进去"静默退回内核自选源)。
- ⚠ 存量集群需跑一次 `--steps k8s_deploy`(滚动 calico-node)才生效; 只跑预检模块不会改 Calico。

**验证**
```bash
# 修复前(坏节点): src 是 IB 地址, from IB 走 table 150
ip route get <本地 Pod IP>
ip route get <本地 Pod IP> from <IB 地址>

# 修复后: src 应为节点管理 IP; from 管理IP 走 cali
ip route get <本地 Pod IP>
kubectl -n kube-system get ds calico-node -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="FELIX_DEVICEROUTESOURCEADDRESS")]}{.valueFrom.fieldRef.fieldPath}{"\n"}{end}'
# 应输出 status.hostIP(具体值在 pod 内 env 为节点 IP)
```
- 离线回归: `bash deployments/scripts/tools/tests/test-node-net-guard.sh`; 静态校验 `bash deployments/scripts/tools/check-modules.sh`。
- 部署前预检: `node_net_guard` 模块(`--steps node_net_guard`)会逐节点比较 `from <节点IP>` 与每个本地地址的路由; 命中且原生修复开启 → 告警不阻断; 关闭 → 硬失败。

**兜底(仅存量集群/无法改 Calico 时; 可选)**
```bash
# 幂等加规则 + systemd oneshot(只加 Pod 网段, 不加 service 网段)
sudo NODE_NET_GUARD_ACTION=rule ./deployments/scripts/deploy-cluster.sh --steps node_net_guard
# 等价的单节点手动形态(仅临时验证, reboot 后会丢; 持久化请用上面的工具):
sudo ip rule add pref 30000 to <KUBE_PODS_SUBNET> lookup main
```
- 工具: `deployments/scripts/tools/node/node-net-guard.sh --apply-rule`; 持久化 unit:
  `/etc/systemd/system/cubestack-pod-net-routing.service`(脚本 `/usr/local/sbin/cubestack-pod-net-routing`)。
- 清理: `node-net-guard.sh --remove`(只删自己登记过的网段; 手工加的 /16 规则需自行 `ip rule del`)。
  ⚠ `--apply-rule` **不会**自动清除非风险节点上已在位的兜底: 兜底规则本身会把探测结果变成
  "无分歧", 自动删除会让守卫在两次运行间来回翻转; 清理只走显式 `--remove`。
- 改 `NODE_NET_GUARD_RULE_PREF` 后重跑 `--apply-rule`: 工具按
  `/etc/cubestack/pod-net-routing.applied` 记录的 `<PREF> <CIDR>` 删除旧优先级规则, 再按新
  pref 写入; `--remove` 同样按记录清理(旧版"单 CIDR"状态按当前 pref 兼容)。只按新 pref 删除
  会漏掉旧规则, 形成同一网段双优先级。
- ⚠ 为什么只加 **Pod 网段**: ClusterIP 是 `local` 路由(源地址=VIP), rpfilter 反向查询的 `daddr` 是 Pod IP, service CIDR 规则基本无用且增加影响面。
- ⚠ `to <pod> lookup main` 对所有源生效, 可能影响“远端 Pod 回包走 IB”的非对称路径; 因此**默认不做**, 优先用 Calico 原生 source hint。

**相关命令**
```bash
# 反向路径分歧(预检核心判据)
ip route get <pod_probe> from <节点IP>
ip route get <pod_probe> from <本机其他地址>
# Calico rpfilter 计数器(每 2 个失败 ping +2)
iptables -t raw -Z cali-PREROUTING; ping -c2 <PodIP>; iptables -t raw -L cali-PREROUTING -nv | grep rpfilter
# 回包已到 cali 但被丢
tcpdump -ni cali<iface> icmp
conntrack -L | grep <PodIP>      # [UNREPLIED] packets=0
# 本机所有 ip rule(确认 IB 源策略路由)
ip rule show; ip route show table <table>
```
> `<pod_probe>` 必须取**本节点实际 Pod 地址**(`ip route show | awk '$0 ~ /dev cali/'`), 不要用
> Pod 网段首主机: 首主机通常属于别的节点的 /26 block(或未分配), 走 `tunl0`/默认网关, 与本地
> Pod 的 `dev cali*` 路由完全不同(2026-10-28 集群 c 实测: 首主机经默认网关
> `via <网关IP> dev <管理网卡>`, 本地 Pod 走 `dev cali*`)。用首主机探测会掩盖只出现在本地
> Pod 上的源策略分歧。`node-net-guard.sh` 已改为探测本地 Pod 地址; 节点无本地 Pod 时回退网段首主机。

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

### 2. 【2026-10-14 事故】扩容节点 k8s_ntp "偏差超限"(6530ms→重对齐 2493ms)实为 VM 网络接入缺陷: 该节点与权威无 IP 通路

**症状**
- `--with-scale` 扩容新节点(worker13)跑到 k8s_ntp: 首次"时间已同步"→ 校验偏差 6530ms → 自动重对齐复测仍
  2493ms → 模块失败, 报"时钟偏差超限"。
- 该节点(192.0.2.222)上 `timedatectl timesync-status` = `System clock synchronized: no`, 日志反复
  `Timed out waiting for reply from <权威>`(Packet count 0); 权威 `chronyc clients` 里**从来没有它**。

**根因(证据链, 2026-10-14 现场实测)**
1. **该 VM 与集群节点二层转发不可用**(平台网络接入缺陷): worker13 → `.213/.214/.215/.216/.203` ping 全 100%
   丢包(双向); 清 ARP 缓存后它对权威的广播 ARP **应答时有时无**(代理 MAC `00:01:00:01:00:01` / 真实 MAC /
   无应答), 权威侧 tcpdump **完全看不到它的帧**; 而它 → 网关/.211/互联网/部署机全通。
2. **对照组**: 同批创建、同样无 chrony 走 timesyncd 的 .216(原名 cluster-node-1)"Initial
   synchronization to 192.0.2.214" 正常 → 不是 timesyncd/NTP 配置问题, 唯独 worker13 这台接入异常。
3. **代码放大**: `setup-ntp.sh` 当时没有"节点→权威"可达性预检(只有 installer→权威 的 SSH 预检, 那条经
   路由总是通的), 于是一路走"硬对齐兜底 + 复测"——旧版硬对齐基准未补偿链路延迟、复测只等 1s,
   把"网络黑洞"呈现成"偏差 6530→2493ms"的误导链。
   ⚠ 平台知识见 §一.3: 该网络是 proxy-ARP/按 IP 转发的 fabric(所有 IP 可能解析到 `00:01:00:01:00:01`),
   健康节点间 ICMP/NTP 实测可通 —— **单节点全部邻居不可达 + ARP 应答时有时无 = 该 VM 接入/转发状态异常**,
   不是 fabric 常规行为。

**解法(根治)**
- **环境侧(主修, 用户当日已完成)**: 在虚拟化平台把该 VM 的网卡改接到与正常节点相同的虚拟网络/端口组
  (本次实机即扩容 VM 创建时接错网络), 并改址 **192.0.2.204**(原 .222)。判据: 该节点 `ping <权威>`
  与反向 ping 均稳定通 —— 实机重挂后 timesyncd 首次即同步成功(见"验证")。
- **代码侧(已落, 2026-10-14)**: `setup-ntp.sh` 新增**节点→权威 IP 通路预检**(`authority_reachable_from`,
  apply 与 `--check` 两条路径共用): SSH 不通 → "SSH 不可达"; SSH 通但 ping 权威不通 → 明确报"无 IP 通路,
  检查该 VM 虚拟网络接入"并**提前终止**(不再进入重对齐/收敛等待); 特殊口径(仅禁 ICMP)可
  `NTP_REACH_CHECK=0` 关闭。另含硬对齐基准中点半程补偿 + 复测改有界收敛等待(≤6×5s)。
- **配置侧**: 排查中发现 `METALLB_POOL` 曾与节点 IP 重叠(.222 既在池内又是 worker13 节点 IP) —— 池必须
  排除 `NODES` 中所有节点 IP(.221 已被集群侧 LB 占用可作反例佐证)。

**验证(2026-10-14 当日更新)**
- 代码侧(已实测): 修复版 `setup-ntp.sh --check` 在容器 d 对全部 6 节点跑通 —— 正常节点零误报;
  探针判别性经黑洞对照验证(同节点 ping `.99`/旧 `.222` FAIL vs `.204`/`.214` OK ——
  该 fabric 上 ICMP 可真实判别黑洞, 代理 ARP 应答不影响)。
- 环境侧(用户已完成): worker13 的 VM 重挂正确网络并改址 192.0.2.204(原 .222)后,
  `timesyncd` **首次即同步成功**("Initial synchronization to 192.0.2.214", 对比之前全程 timeout),
  同一时刻 `--check` 偏差 164ms ✓ —— 根因确证 + 修复实证。
- 端到端: 重跑 `--with-scale`(k8s_scale)把 worker13 接入集群 —— 待用户执行后补。

**相关命令**
```bash
# 单节点与集群连通性判据(节点上执行)
ping -c2 <权威IP>; ping -c2 <任一正常节点IP>; ip neigh show
# 权威侧看客户端是否真的来过(NTP 层面)
chronyc clients
# 节点时间服务状态(无 chrony 的 timesyncd 节点)
timedatectl timesync-status; journalctl -u systemd-timesyncd --no-pager | tail
# 两侧抓包判定帧是否互通
sudo tcpdump -nei <网卡> '(arp or icmp) and host <对端IP>'
```

---

### 3. 【2026-10-26 事故】全量部署 k8s_ntp 只在 master02 失败(4.1s), standalone 却 256ms; worker05-08 装包报 sudo 需密码

**症状**
- 全量 `--fresh` 跑到 k8s_ntp: master02 偏差 `4108ms → 重对齐 4119ms` 失败; 其余 10 台约 258-272ms,
  worker06 1480ms 通过。
- 同一集群单独 `--steps k8s_ntp`(root 用户)时 master02 仅 **256ms**, 全绿。
- 第一次全量用 `user=ubuntu` 时 worker05-08(10.193.78.101-104)装包报
  `sudo: a terminal is required... / sudo: a password is required`; 切到 `SSH_USER=root` 后装包通过。

**根因(三条线叠加)**
1. **权限**: `k8s_passwordless` 只注入 SSH 公钥, 不写 sudoers; `install-worker-packages.sh` 只用
   `ssh ... "sudo bash -s"`(无密码回退) ⇒ `ubuntu` 无 NOPASSWD 时 dpkg 阶段才报 sudo 密码错误;
   旧 `k8s_workerbm` 只 `warn` 后继续, 把问题拖到 NTP 阶段。
2. **测量口径**: `clock_offset` 用 SSH `date` 差值, 抓了 `hb`/`ha` 却未做 RTT 补偿。全量部署时
   master02 的 SSH/sudo 在负载下慢约 4s, 被直接当成"时钟偏差 4s"; 重对齐仍用同一慢路径采样,
   所以 `4108→4119` 几乎不变。standalone 时负载低, 同一节点只有 256ms。
3. **NTP 有效性检查被弱化**: `chronyc sources` 的 Reach 是第 **5** 列, 旧代码取 `$6`(LastRx),
   阈值判断无意义; 权威 `stratum != 10` 也只 `warn` 后继续。客户端"偏差小但 NTP 没工作"可能漏过。

**修复(2026-10-26)**
- `setup-ntp.sh`:
  - `node_cmd` 对 **root 不再套 sudo**(消除 sudo/PAM/DNS 的数秒延迟); 新增 `node_sudo_ready` 前置,
    apply/verify 对非 root 且 sudo 不可用的节点直接点名失败。
  - **客户端缺 chrony 时自动安装**: apply 把 offline-files 里的 chrony deb 推给缺 chrony 的节点,
    远端脚本用 `install_debs_offline` 安装; 装不上才回退 `systemd-timesyncd`, 并校验其 active。
    离线目录必须是**完整依赖闭包**(chrony + libpam/libaudit/libffi/libpcre2/zlib 等):
    `deployments/scripts/tools/node/chrony-offline-debs.py --check <chrony目录>` 只读自检;
    联网 Ubuntu 22.04 amd64 构建机用 `--fetch <chrony目录>` 补齐缺失 deb。
    setup-ntp 在 apply 前会自动 check 并 warn; 严格离线可设 `NTP_REQUIRE_CHRONY_CLOSURE=1` 直接失败。
  - `clock_offset` **优先 chrony 自身口径**: `System time` + `Leap status=Normal` + `^*` 源 `Reach>=1`;
    不可用时才回退 SSH `date`, 并用两个采样的中点做 RTT 补偿; 权威自身无上游时直接返回 0,
    不再 SSH 自测吃 0.2-0.6s 噪声。同时区分 `chrony 未安装` 与 `chrony 已安装但未选中源/Reach=0`。
  - 权威 `stratum != 10`(无上游时)从 warn 改为**硬失败**, 并打印 `chronyc tracking/sources`、
    `ss -lunp`、`journalctl -u chrony`。
  - 远端节点脚本输出 `SYNC-OK`/`SYNC-FAIL`; **只有时间守护进程 active(chrony/timesyncd)** 且
    chrony makestep/date 对齐成功才 `SYNC-OK`; 无守护进程输出 `NO-TIME-DAEMON` + `SYNC-FAIL`。
  - Reach 改取第 5 列, 并强制 `^*` 源 + `Reach>=1`; Reach<37 只告警"收敛中", 不阻塞部署。
  - verify 阶段无 chrony 且 timesyncd 未运行 → 直接失败, 不再靠一次性 `date -s` 通过。
- `k8s_workerbm`: 非 root 节点先 `sudo -n true` 前置; 装包失败计入 `PKG_FAIL` 并 **exit 1**,
  不再"warn 后继续"。
- 新增离线回归 `deployments/scripts/tools/tests/test-k8s-ntp.sh`(root 无 sudo / chrony 优先 /
  权威自身 0 / 回退 / SYNC 标记 / workerbm 权限门禁), 已挂入 `check-modules.sh`。

**验证**
- `SSH_USER=root` + `--steps k8s_ntp`: 权威 stratum 10; 全节点 259-277ms 通过;
  worker06/07/08 因负载仍在 1.3-1.9s, 但 `chronyc tracking` 的 `System time` 很小 ⇒ 测量噪声而非时钟偏差。
- 命令:
```bash
# 判断 4s 是时钟还是 SSH/sudo 延迟
/usr/bin/time -f 'ssh+date %e s' ssh -i /root/.ssh/cubestack_k8s root@10.193.78.22 'date +%s.%N'
/usr/bin/time -f 'ssh+sudo %e s' ssh -i /root/.ssh/cubestack_k8s root@10.193.78.22 'sudo date +%s.%N'
# 节点 chrony 自身偏移(真正判据)
ssh -i /root/.ssh/cubestack_k8s root@10.193.78.22 'chronyc tracking; chronyc sources -v; uptime; free -h'
# 非 root 用户权限
ssh -i /root/.ssh/cubestack_k8s ubuntu@10.193.78.22 'sudo -n true; echo rc=$?'
```
- 若 `chronyc tracking` 的 `System time` 很小且 `^*`/Reach 377, 不要用 `NTP_MAX_OFFSET_MS` 放宽阈值;
  先查 master02 负载/残留 Pod(本次全量前有 176 个 Terminating/CrashLoopBackOff)。
- 若确实需要 `ubuntu` 用户: 在节点写
  `/etc/sudoers.d/90-cubestack`: `ubuntu ALL=(ALL) NOPASSWD:ALL`(chmod 440 + `visudo -c`),
  或 `SSH_USER=root`。

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
- `describe` controller 可见 `Node-Selectors: kubernetes.io/hostname=<旧环境主机名>`(如 `node-1-232`)。

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

**根因** 宿主机 /etc/hosts 残留旧 IP(如 `192.0.2.37` = 宿主机自身)或 DNAT 被历史规则遮蔽(两条规则指向 10.244.2.100 与 192.168.100.130, 旧规则先命中)。

**解法(根治)** 每次部署由模块修正 /etc/hosts:
```
registry.cubestack.io → REGISTRY_IP(集群 registry VIP, 如 192.168.100.130)
k8s-api.cubestack.io → API_ENTRY_IP(kube-vip 已绑 → VIP; 否则第一个 master)
```
不留 192.0.2.37 这类过期条目。

> ⚠ 两个域名的目标 IP 语义**不同**, 别照抄成同一个变量:
> `REGISTRY_IP` / `API_IP` 是"能通 NodePort 的**节点** IP"(registry 的 containerd mirror、DNAT 判定依赖它),
> 而 API 域名的解析地址是 `api_entry_ip()` —— kube-vip 已绑时取 VIP。把 API 域名指向 `API_IP`
> 会让 kube-vip 的高可用形同虚设(入口仍是单台 master)。详见 `docs/kube-vip-api-ha.md`。

#### 3.6 driver / maca 镜像拉不到(`ErrImagePull: ... not found`)

**根因** `driver-image` 与 `maca` **不在** `metax-k8s-images.<ver>.run` 包内, 需单独推送; 即使 PreferHost 驱动 DS 的 init 容器也要拉 `driver-image`(解包内核模块)。

**解法(根治)** 模块 `push_extra` 按 本地 docker(`docker save`+skopeo) → 离线 tar(METAX_OFFLINE_DIR) → 在线 逐级推送; `METAX_DRIVER_VERSION` 须与本地可用镜像匹配(如 `3.8.1.6-amd64`)。

#### 3.7 master 节点没有 `metax-tech.com/gpu.installed` 标签 / GPU 用不上

**根因** metax 组件 DS 默认**无 control-plane 容忍**, 调度不到(带 NoSchedule 污点的)master → gpu-label 不给 master 打标。

**解法(根治)** 部署时在宿主机用 `mx-smi` 检测沐曦 GPU(`sudo mx-smi | grep "Attached GPUs"`), 检测到沐曦 GPU 的 master 自动移除 control-plane/master 污点并 uncordon(模块已实现); 无沐曦 GPU 的 master 保持不可调度。

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

### 4. Ceph / Rook 部署故障速查

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
| mon/osd 未调度到目标节点 / 一直在 Pending | 节点缺 label 或 CEPH_NODES 与预期不符 | `kubectl get node --show-labels \| grep ceph-storage`; 模块自动打 `CEPH_NODE_LABEL`; 核对 CEPH_NODES |
| 部署模块报"所有存储节点均未检测到裸盘" | VM 未附加数据盘 / 盘已被分区 | VM: `vm-nodes.conf` 设 `VM_DATA_DISKS=3 VM_DATA_DISK_SIZE=200` 后重建 VM; 裸金属: 挂新盘; 或显式 `CEPH_DATA_DISKS="node:/dev/vdb,…"` |
| 显式 `CEPH_DATA_DISKS` 的三块盘**全显示在第一个节点**, 其余节点 `<未检测到>` | 节点之间误用**逗号**: `node0:/dev/vdb,node1:/dev/vdb,node2:/dev/vdb`; 解析器把 `node1:/dev/vdb` 当成 node0 的盘列表(逗号是同一节点多盘的分隔符) | **2026-10-26 已修**: 节点之间必须用**分号 `;`**, 逗号只用于同一节点的多块盘; 或全节点同盘直接写 `/dev/vdb`; 新增 `ceph_validate_explicit_config`(lib-common) 在解析前拒绝该写法, `02_ceph`/`deploy-cluster` 均已接入, 回归 `test-ceph-data-disks.sh` |
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
| external 模式 ceph_csi 失败: `error: error parsing /tmp/ceph-ext-import.yaml: error converting YAML to JSON: yaml: line 10: could not find expected ':'`(日志里 secret/rook-ceph-mon + CM 已 created, 但后续 CSI secret 全部未建) | 03_ceph_csi.sh 的 `external-cluster-user-command` CM 构造里 `args: \|-` block scalar 只给 ARGS **首行**加了 4 空格缩进: 提供方导出的 ARGS 是**多行**内容(export 带 `--config-file` 时写入 `[Configurations]` + `key = value` 块), 后续行落在第 0 列 → block scalar 提前终止, `rgw-pool-prefix = default` 等裸标量被当成新 YAML 节点 → "could not find expected ':'"(第 10 行正是 `rgw-pool-prefix`)。kubectl 流式解析先成功 apply 前 2 个文档, 到第 3 个文档报错中止 | **2026-09-11 已修复**: 嵌入前用 `printf '%s\n' "${ARGS}" \| sed 's/^/    /'` **逐行加 4 空格缩进**成 `_ARGS_BLOCK` 再拼接(`args: \|-\n${_ARGS_BLOCK}`)。验证: 以真实多行 ARGS 本地复现, 修复前 kubectl 报错与线上逐字一致(line 10); 修复后 kubectl 解析通过 + pyyaml 往返校验内容逐行等于 ARGS、无失真; check-modules 全绿。实机: 容器 b 重跑后 8 个资源(secret×5+CM×2+rbd secret 组)全部 created, 外部 CephCluster Connected —— **ARGS 段已实机验证通过** |
| external 模式 ceph_csi **官方导入路径**冒烟失败(★ 该冒烟自 2026-09-24 起**默认关**, 需 `CEPH_EXTERNAL_PROVISION_SMOKE=true` 才会跑; 下表证据是它默认开时期的): `RBD 1Gi scratch PVC 180s 内未 Bound`(前面 import 1-4 全绿: secret/CM/Connected/csi-config 均正常, SC/RGW 也建好) | **kubelet CM 投递竞态在官方导入路径复发**(同 2026-09-09 手填路径事故, 但官方路径**缺那道防线**): ceph-csi-config CM 03:35:12 生成, ctrlplugin pod 03:35:14 启动 —— 启动时 kubelet 挂载的 CM 还是旧/空 → 首次 CreateVolume 03:35:32 撞 `open /etc/ceph-csi-config/config.json: no such file or directory` → InvalidArgument 被 csi-provisioner 判 **infeasible(永久)** → 日志 `skipping volume provisioning ... previously failed with infeasible error`, PVC 永不 Bound → 冒烟 180s 超时。手填路径(827-857 行)有 rollout restart + config.json 挂载检查, **官方导入路径没有** | **2026-09-11 已修复**: 抽出公共函数 `_ext_wait_csi_config_ready()`(rollout restart provisioner + 等 rollout + `kubectl exec test -f config.json` 挂载确认, 挂载失败硬失败), 官方路径 csi-config 检查后立即调用。验证: 根因证据链完整(provisioner 日志 InvalidArgument + infeasible); check-modules 全绿; 已同步容器 b, 重跑 --steps ceph_csi 实机验证进行中 |
| 重装时 `ceph [1/8]`/部署预检显示某几台节点 `裸盘: <未检测到>`(节点 `lsblk` 明明有盘, 且这些盘就是上次 Ceph 用的 OSD 盘); `ceph-cleanup.sh --all` 也清不到它们 | `ceph-detect-disks.sh` 只认"未使用裸盘"(整盘无子设备), 而 Rook/`ceph-volume lvm` 建的 OSD 盘是**有分区/LVM 的** → 被判为"在用"排除: ① CR 的 `storage.nodes[].devices` 漏掉这些盘 → 那几台节点 0 OSD; ② `--all` 拿到的"待清理盘"为空 → **清理空转**(盘上旧 ceph VG/LV 无人解绑, 重装时 osd-prepare 报 "already prepared"); ③ 确认屏只剩 `<未检测到>`, 人工分不清"没盘"还是"被上次部署占着" | **2026-09-24 已修复**: 新增 `tools/k8s/ceph-disk-classify.py` 分类器(只认强证据: bluestore 签名 / ceph 分区 GUID / 分区名 `ceph ` / `ceph-*` VG·`ceph.*` 标签 / `ceph--` dm 名), `ceph-detect-disks.sh` 新增 `--classify`, 盘分 `free`/`ceph`/`inuse`/`mixed` 四类并单独呈现 `ceph` 类; CR 取 `free ∪ ceph`; `ceph-cleanup.sh --wipe-disks`/`--all` 只清 `ceph` 类(新增 `--list` 只读计划); 02_ceph 7a 先调标准清除(解 LVM/dm)再跑原有 dd 签名擦除; `--wipe-node` 默认**拒绝**清 `inuse`/`mixed` 盘(需 `--force`)。⚠ **审查挖出的两类新坑**(都已修, 都是“看着干净”害死人): ① **整盘 LVM PV**(无分区表、无文件系统、VG 未激活时连 dm 子设备都没有)曾被判 `free` → 会被写进 CR 并被 7a 的 dd 清空, 而它可能装着任意业务数据(旧版把 `LVM2_member` 排除在候选外 = inuse, 属**反向回归**) —— 现规则: 见到 `LVM2_member` 或设备本身在 `pvs` 里却认不出归属 → 判 `inuse`(宁可不擦); 且因 `pvs` 不依赖 dm, **未激活的 `ceph-*` VG 也认得出** → 该清的仍清得到; ② `nbd*` 未被排除(默认 `CEPH_DETECT_EXCLUDE` 也不含 nbd)→ 当空闲盘擦会**写穿到背后 RBD 卷**, 现恒判 `inuse`。另: 清盘脚本的 LVM/dm 解除按**目标盘**收敛(不按名字正则扫全节点 —— `... \| grep ceph` 会误伤 `data-vg/cephbackup` 这类卷; `dmsetup remove_all` 已移除), 因 7a 让这段进了默认部署流程, 作用域必须严格。**验证边界: stub `ssh` + 逐节点 lsblk fixture 端到端跑通选盘/护栏/载荷完整性(--all 只擦 ceph 盘、/data 与混合盘被排除、护栏 5 种情形退出码全对、远端载荷语法通过); LVM 收敛逻辑用桩 `pvs/lvs/lvremove/vgremove` 实跑断言(目标盘 VG 选中、无关 `ceph-backup-vg` 零触碰); 分类器 12 用例覆盖整盘 PV/混合/挂载/nbd/空分区; 静态检查全过 —— **仍未在真实集群实机验证** |
| `ceph-detect-disks.sh` 把 `nbd0..nbdN` 当**空闲裸盘**输出(会被写进 CR 当 OSD, 被 `ceph-cleanup.sh` 当 Ceph 盘擦) | 旧版只排除 `loop/ram/zram/sr/rbd` 前缀, **漏了 nbd**; 而 `CEPH_DETECT_EXCLUDE` 默认值 `^(sda\|sr0\|vda)$` 也不含 nbd → 配置兜不住。nbd 是网络块设备, 现场很可能是 `rbd-nbd` 映射(实测部署机上 `nbd0..nbd15`)→ `dd` 会写穿到背后的 RBD 卷, **销毁真实数据** | **2026-09-24 已修复**: `ceph-disk-classify.py` 里 `nbd*` 恒定判为 `inuse`(理由写清"可能是 rbd-nbd 映射, 用 rbd unmap 或重启解除"), 绝不进 CR、绝不清理; 不依赖 `CEPH_DETECT_EXCLUDE`。验证: 对本机真实 `lsblk`(含 nbd0..15, 排除规则只写 `^(sda\|sr0\|vda)$`)运行分类器 → 16 个 nbd 全部 `inuse`, 4 块挂载中 xfs 盘与 sda 也全部 `inuse`, 无一条 `free` |
| k8s 阶段 ansible **长时间无输出**(实测 38 分钟以上), 最后停在 `Copy offline .deb packages to target` / `Install packages from local files`; 日志最后一行是那条 copy 的 profile 行, 之后整段空白 —— 看起来像"卡在拷贝 lvm2 包"; **只有部分节点会卡**(8 台里实测 2 台) | 卡的不是 copy, 是它后面的逐个 `dpkg -i`: `dmsetup`/`lvm2` 的 postinst 触发 `update-initramfs -u` → `mkinitramfs` → `hooks/mdadm` → **`/sbin/mdadm --examine --scan`(遍历所有块设备)** 读到**上一代集群遗留、后端已不可达的 `/dev/rbd0`** → 进程进 **D 状态(不可中断)** 永不返回; 同节点还有 ext4 挂在那块 rbd 上, 其 `jbd2` 线程一并卡死(实测内核线程 `[registry]` D 态 1h37m)。诊断方法: 在卡住的节点上 `ps -eo pid,stat,wchan,cmd \| grep -E '^ *[0-9]+ D'` + `ls -l /proc/<pid>/fd \| grep /dev/` → 看它读的是哪块盘 | **① 代码侧(2026-09-24 已修, `patch-playbooks/install-packages.yml`)**: 安装期间临时置 `update_initramfs=no`(装完恢复)→ 整条 initramfs 链(hooks 会跑 pvscan/vgscan/mdadm 扫设备)根本不被触发; 另加"已装同版本跳过"与"本节点存在内核 rbd 映射"告警。**② 环境侧(必须人工)**: 这类节点**只能重启**清除 —— hung 的 rbd 映射 unmap 会 EBUSY, D 态进程杀不掉; 重启后再部署即可。判据: `ls /sys/bus/rbd/devices` 非空 + 存在 D 态进程 |
| **`node_pkgs` 在第一个节点永久 pending**: 输出停在 `── <IP> ──` + SSH warning; 节点上 `fuser /var/lib/dpkg/lock-frontend` 进程 D 状态 `ceph_mdsc_wait_request`(可挂 30+ 分钟); `findmnt -t ceph` 显示 `/mnt/cephfs/models` 的 mons 是旧集群 | **旧集群 `cephfs_mount` 宿主机挂载残留**(2026-10-19 实机): 集群非优雅拆除(API 已不可达/未走 uninstall)时 `/mnt/cephfs/models` 仍留在宿主机; mons 已不可达 → 内核 ceph 客户端无限重试; `fuser` 遍历 `/proc` 时撞上该挂载 → D 状态永不返回。旧 rbd 映射(`jbd2/rbd0`、`rbd remove`)同理。不是装包慢, 也不是 apt 锁被正常占用 | **2026-10-19 已修**: `tools/node/reconcile-node-packages.sh` 增加**控制器前置探测**(每节点 `timeout 20` 查 ceph/rbd 挂载、`/sys/bus/rbd/devices`、相关 D 状态、`fuser` 超时), 命中即**在分发/装包前失败**并打印重启步骤; 远端脚本同样在 `fuser`/apt 之前检测, `fuser` 带 `timeout 5`, 整轮远端对账带 `RECONCILE_SSH_TIMEOUT`(默认 1800s)。**现场处置(本次 6 台全部命中)**: `systemctl stop kubelet containerd; systemctl reboot -f`(跳过卡死的 ceph 卸载); 重启后 `findmnt -t ceph,rbd` 为空、`ls /sys/bus/rbd/devices` 为空、`timeout 5 fuser ...; echo rc=$?` 为 1, 再重跑部署。回归: `bash deployments/scripts/tools/tests/test-reconcile-node-packages.sh` |

| **覆盖安装 + `CEPH_MODE=external` 失败**: cephfs_mount 报 `/mnt/cephfs/models` 卸载失败; ceph 卸载日志出现 `删除现有 CephCluster(cleanupPolicy yes-really-destroy-data, Rook 擦盘)` | **external 模式的 ceph_csi 会创建 `CephCluster rook-ceph-external`(`spec.external.enable=true`)**; 02_ceph 的“活态判定”只看“有没有 CephCluster”, 把外部接入 CR 误判成 internal 旧集群 → 执行 `ceph-cleanup --delete-cluster`; 同时 cephfs_mount 对**外部** CephFS 做宿主机 umount, 消费者 busy 时必然失败 | **2026-10-26 已修复**: ① 02_ceph uninstall/install 都读取 `spec.external.enable`, 存在 external CR 时**拒绝销毁/幂等清理**(显式 `CEPH_CLEANUP_ALLOW_EXTERNAL=1` 才放行); ② `ceph-cleanup.sh delete_cluster` 自身也拒绝 external CR(防御); ③ cephfs_mount 在 external 模式**保留宿主机挂载**(外部资源, 新部署复用; 不可读时安装前预检再 lazy umount), internal 模式仍严格卸载; ④ 卸载失败日志过滤 SSH warning, 显示真实 umount/findmnt 原因; ⑤ 回归 `test-cephfs-mount.sh` ⑥b + 02_ceph/ceph-cleanup 静态围栏。**验证**: `kubectl -n rook-ceph get cephcluster -o custom-columns=NAME:.metadata.name,EXT:.spec.external.enable`; external 覆盖安装应打印“跳过销毁”且不再尝试 umount `/mnt/cephfs/models` |
| **覆盖安装清理旧 Ceph 卡死 900s+**: 强删日志只出现 4 个对象(durable/cephfs/s3-store/rbd-pool), 随后 `等待 CephCluster 删除... 900s(phase=Deleting)`; Rook 持续报 `will not be deleted until all dependents are removed: CephFilesystem: [cubestack-ext-fs], CephFilesystemSubVolumeGroup: [ephemeral]`(两者已被 `delete --all` 标记删除, finalizer 摘不掉) | `ceph-cleanup.sh` 强删循环把 `</dev/null` 写在 SSH 参数的**双引号内** —— 那是**远端**重定向, 本地 ssh 仍会读取并转发 stdin, 把 `while read` 的 here-string 一次读空 → 循环只处理第一条(实测: `cephfilesystem` 两条只删了 `cubestack-ext-fs` 之前的 `cephfs`, `subvolumegroup` 的 `ephemeral` 同理被漏); 删完不校验残留, 直接删 CephCluster 并等 900s(Rook 因依赖未删除必然拒绝) | **2026-10-27 已修(#73)**: 新增 `SSH_N(){ SSH "$@" </dev/null; }`, 循环内/无需 stdin 的远端调用统一走它(依赖 CR 强删、PVC/PV 强删、消费者停用、PVC 删除、nodeplugin/守护删除等); 依赖 CR 强删后**后置校验**, 仍有残留重试 3 轮, 未收敛置 `_CEPH_ABORT_WIPE=1` 并中止(不再进入 900s 等待); 120s 等待窗口的查询失败由"当作已终结"改为 fail-closed。回归: `test-cluster-teardown.sh` ⑤aa(桩 SSH 从真实文件提取循环, 断言两条都删) + ⑤t/⑤t2 静态围栏。**验证边界: 桩/静态回归通过(check-modules 全绿); 尚未在真实集群复验** |

**验证**
```bash
sudo ./deploy-cluster.sh --steps verify_ceph          # 端到端: operator/CSI + phase=Ready + ceph -s + RBD 块 I/O
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s
kubectl -n rook-ceph get cephcluster,cephblockpool; kubectl get sc ceph-block
```


---

### 5. 新增配置项后, 宿主机 `check-modules.sh` 通过、容器内报 `TOGGLE 未声明`

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

### 6. 大 ConfigMap 用客户端 apply 报 `metadata.annotations: Too long: may not be more than 262144 bytes`

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

### 7. RDMA 共享设备插件: pool 模式 selectors.ifNames 只剩第一块网卡(其余卡静默不匹配)

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

### 8. RDMA 资源名与真实 GPU 集群不一致 → Pod 申请 `rdma/ib_shared_devices` 永久 Pending

**症状**
同一份 Pod 清单在真实 GPU 集群能跑, 在本安装器部署的集群上 Pending:
`0/N nodes are available: ... Insufficient rdma/ib_shared_devices`。集群本身"部署成功"。

**根因**
两端资源名不同源: 真实集群的插件由 metax 侧以 `--rdma-ib-resource` / `--rdma-roce-resource`
配置(实测 `cm rdma-devices` 里为 `ib_shared_devices` / `roce_shared_devices`, 前缀 `rdma`),
而本安装器默认走 per-hca(`nvidia.com/<设备名>`)/ pool(`nvidia.com/mlx5_0`)—— 名字对不上时
Pod 申请的资源名在集群里**根本不存在**, 且报错只出现在 Pod 事件里, 部署日志一片绿。

**解法(根治)**
`RDMA_HCA_MODE=by-link`(**cluster.conf.example 默认值**, 2026-09-21 起): 按链路类型分成两池,
资源名取 `RDMA_IB_RESOURCE`(默认 `rdma/ib_shared_devices`)/ `RDMA_ROCE_RESOURCE`
(默认 `rdma/roce_shared_devices`), 与真实集群对齐; 名字可在 cluster.conf 改(插件侧对应
`--rdma-ib-resource` / `--rdma-roce-resource`)。
⚠ 显式 `RDMA_IF_NAMES` 且未写类型时无法判定链路类型 → 归 RoCE 池并告警, 要精确分类写
`<设备名>:<网卡名>:<类型>`(32=IB / 1=RoCE); 某类型无卡则不生成该池条目。

**验证**
本地打桩自检 ①: 2 IB + 1 RoCE → 恰好两条 `rdma/ib_shared_devices`(ifNames 2 张 IB 卡)+
`rdma/roce_shared_devices`(1 张 RoCE 卡); ④ 占位模式两池 + `rdma-placeholder=true` 标注不变。

**相关命令**
```bash
kubectl -n kube-system get cm rdma-devices -o yaml        # 真实集群/本集群的实际资源名
kubectl describe node <节点> | grep -A5 rdma/             # 节点上真正注册了哪些资源
```

---

### 9. kube-vip 控制面负载均衡(`lb_enable`):`lb_fwdmethod: local` 是**静默零效果**,且 ipvs 模式集群上还有一道 kube-proxy 关卡

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
  实测 `192.168.100.139:31680` 的后端被摘掉后不再恢复(本集群 registry 拉镜像走 `registry.cubestack.io`
  → `192.168.100.131`,**不依赖** VIP 的 NodePort,故影响有限,但确实是个反直觉的行为变化)。
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
- **本集群现状**:VIP `192.168.100.139` 由 `192.168.100.154` 持有,IPVS 中**无** `192.168.100.139:6443` 条目
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

### 10. kube-vip 的几处"以为收敛了其实没有":关开关不清理 / 每轮白重启两次 / 全新集群部署中断 / 关闭态仍扫 VIP / 两套集群抢同一 VIP

前三个问题的根因相邻(都是"目标状态与实际状态不一致,但没有任何东西去发现它"),
于 2026-09-22 一并修复;10.4 / 10.5 是后来追加的两条。设计说明见 `docs/kube-vip-api-ha.md` 第 18 节。

> 🔁 **2026-09-28 收编**: **10.2 的"解法"已反转** —— 静态 Pod 清单改由 **kubespray 自己**渲染
> (`addons.yml` 的 `kube_vip_enabled` **跟随** `KUBE_VIP_ENABLED`),自持渲染器已删除。
> 也就是说: 双写者问题依旧消除,但消除的方向从"关掉上游"改成"**关掉我们自己**"。
> 10.1 / 10.3 / 10.4 的结论**不受影响**(开关语义、清理路径、定序、VIP 推导都还在)。
> 详见 `docs/api-ha/07-kube-vip-upstream-assessment.md` 与 `docs/kube-vip-api-ha.md` §19。

#### 10.1 `KUBE_VIP_ENABLED=false` 重跑后,manifest 还在、VIP 还被持有

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

#### 10.2 每次全量运行,master01 上的 kube-vip 都会重启两次

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

**解法(2026-09-28 收编后: 写入权交还上游)**
`addons.yml` 里的 `kube_vip_enabled` 现在**跟随 `KUBE_VIP_ENABLED`**,静态 Pod 由 **kubespray 自己**
在 `Install Kubernetes nodes` 里渲染 —— 即把另一方(我们自己)彻底关掉,而不是把上游关掉。
写这个值的是 `lib-common.sh#update_kube_vip_addons_yml`(写入后回读校验)。

那份 `super-admin.conf` 分叉**本身是逐节点稳定的**(按 `inventory_hostname == kube_control_plane[0]`
判定,同一节点每次渲染同值),双写者消失后它不再造成重启 —— 这正是可以撤掉契约的理由。

> **历史(2026-09-22 ~ 09-28)**: 当年用的是**反向**解法 —— `kube_vip_enabled` **恒写 `false`**
> ("不要让 kubespray 写这个静态 Pod"),由自持渲染器独占。它同样消除了双写者,代价是维护
> ~430 行渲染器;收编后契约与渲染器一起删除(见 `docs/kube-vip-api-ha.md` §19)。
> 上面那句"**不要**复刻 kubespray 的 `super-admin.conf` 判定来对齐渲染"**仍然成立** ——
> 那正是收编要避免的事: 渲染是上游的职责,我们不再对齐它。

**相关命令**
```bash
# 看 master01 的 manifest 到底用的是哪个 kubeconfig
# 收编后的**正确**结果: 首台 master = super-admin.conf, 其余 = admin.conf（08 的 ①b 哨兵就查这个）
ssh <master01> "sudo grep -A1 'hostPath' /etc/kubernetes/manifests/kube-vip.yml"

# 收编后: kube_vip_enabled 应**跟随** cluster.conf 的 KUBE_VIP_ENABLED(不再恒 false)
grep '^kube_vip_enabled' deployments/kubespray/inventory/*/group_vars/k8s_cluster/addons.yml
grep '^KUBE_VIP_ENABLED' deployments/config/cluster.conf

# 幂等: 全量运行前后各取一次 hash, 应当全程不变
ssh <master01> "sudo sha256sum /etc/kubernetes/manifests/kube-vip.yml"
```

> ⚠ `kube_vip_address` 与上面的开关**无关**,开关关闭时**也要保留** —— 它只喂 apiserver
> 证书 SAN(`kubeadm-setup.yml:48` 的 `sans_kube_vip_address` 只看它是否定义)。删掉它会导致
> 下次开回来时证书重签。

#### 10.3 全新集群部署在 `k8s_deploy` **之前**就中断了

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

#### 10.4 `KUBE_VIP_ENABLED=false` 仍去推导 VIP → 部署中断在 `k8s_inventory`(第 4 个"以为收敛了其实没有")

**症状**
把 `KUBE_VIP_ENABLED` 置 `false` 后重跑,**依然**出现:
```
[DEBUG] 当前入口 192.0.2.28 不是可用 VIP(节点 IP 或落在 MetalLB 池内)→ 重新推导
→  推导 API VIP(起于 192.0.2.210, 逐个探测直至 .254)...
【错误】在 192.0.2.210-192.0.2.254 范围内未找到空闲 VIP(全部被占用/被排除)
【错误】请在 .../cluster.conf 显式指定 K8S_API_VIP=<同网段空闲地址>
【错误】模块 [k8s_inventory] ... 退出码 1 → 部署中断
```

**根因**
`tools/k8s/sync-kubespray-config.sh` 里的 `kube_vip_derive` 调用**是唯一一处没有开关护栏的**
(其余 4 处: 06_k8s_deploy / 08_verify_kube_vip / 09_kube_vip / `kube_vip_resolve_target` 都有),
而且还带 `|| exit 1`:
```bash
_KV_VIP="$(kube_vip_derive)" || exit 1     # ← 不看 KUBE_VIP_ENABLED
```
`kube_vip_derive` 会对每台 master **逐地址扫描**(起于 `.210`, SSH + ICMP + TCP)。于是:
① 关掉 kube-vip 的集群纯白跑一遍昂贵扫描;② 只要整段地址被占用/落在 MetalLB 池内就**硬失败**,
而调用链是 `k8s_inventory → gen-inventory.sh → sync-kubespray-config.sh` —— **整个部署在这里中断**。
(开关开着时同样会失败, 只是没人注意; 关掉开关后本不该有任何 VIP 逻辑, 才暴露出来。)

**解法(根治, 2026-09-24)**
按开关分派, 关闭态**不扫描**: 只取显式配置的 `K8S_API_VIP`(它只喂 apiserver 证书 SAN,
留着可免去将来重新启用时的证书重签; 没配就留空, 该键自然不进 addons.yml):
```bash
if bool_is_true "${KUBE_VIP_ENABLED:-false}"; then
    _KV_VIP="$(kube_vip_derive)" || exit 1
else
    _KV_VIP="${K8S_API_VIP:-}"
fi
```
**验证(对照实验, 决定性)**: 把 `kube_vip_derive` 换成"打标记 + return 1"的探针, 用临时副本
(临时 inventory + 临时 cluster.conf, 不动仓库文件)跑真实脚本:
| 条件 | 退出码 | 探针被触发 |
|---|---|---|
| 修复**前** + `false` | **1**(复现用户报错) | **是** ← 就是它 |
| 修复后 + `false` | 0 | 否 |
| 修复后 + `true`(对照组) | 1 | 是 ← 证明探针确实能测到调用 |
> 对照组不可省: 没有它就无法区分"没调用"与"探针本身失效"。

**相关命令**
```bash
# 当前开关(应为 false)
grep '^KUBE_VIP_ENABLED=' deployments/config/cluster.conf
# 想确认关闭态不会再扫 VIP: 直接跑一次 sync, 应无 "推导 API VIP" 输出
KUBESPRAY_INV_DIR=<inventory 副本> CLUSTER_CONF=<conf 副本> \
  bash deployments/scripts/tools/k8s/sync-kubespray-config.sh
```


#### 10.5 `kubectl` 时好时坏地报 `x509: certificate signed by unknown authority` —— 两套集群抢同一个 API VIP(2026-09-29 实机)

**症状**
同一条 `kubectl` 命令连跑三次: **成功 / 失败 / 失败**; 失败时报
`x509: certificate signed by unknown authority`。
⚠ 关键指纹: 部署脚本里**前一行**的 `curl -sk https://<域名>:6443/healthz` 还说"API 可达",
**后一行** kubectl 就失败 —— 因为 `-k` 跳过了证书校验 ⇒ **病灶在 TLS 层, 不是网络层**。

**根因(实机取证, 不是代码缺陷)**
同网段**两套集群共用同一个 `K8S_API_VIP`** —— 两边的 kube-vip 都持有该地址(各自 ARP 通告),
到 `VIP:6443` 的流量**随机落到任一套集群的 apiserver**。两套集群 CA 不同 ⇒ 落在"另一套"上时,
客户端拿到的服务端证书不由本集群 CA 签发。

⚠ 这种情况**覆盖安装治不了**: 覆盖安装只清 inventory 内节点的旧集群残留, **另一套集群的节点不在其中**。

**判据(自包含, 不需要本机有集群 pki)**
连取 4 次同一地址上的服务端证书指纹, 出现**多个不同**指纹即命中
(命令块见 `docs/api-ha/05-operations.md` §3"这个 VIP 是不是被另一套集群共用")。
旁证: `ssh <master> "ip -4 -o addr show | grep '<VIP>'"` 在**两套**集群里会各有一台节点命中。

**处置(二选一, 都要人工介入)**
① 给两套集群分配不同的 `K8S_API_VIP` + `METALLB_POOL`(`cluster.conf`) —— ⚠ **改 VIP 后必须重装集群**:
   证书 SAN 在 `kubeadm init` 时固化, 现有集群的 SAN 只含旧 VIP;
② 先拆除另一套集群(用它自己的拆除入口, **不是**本仓库的 `--fresh`)。

**代码侧硬化(已落)**
`lib-common.sh#sync_kubeconfig` 的末校验改为: 失败时连取 4 次指纹, `≥2` 种即直接报
"该地址被多个 apiserver 共用"并打印上面两条处置; 指纹稳定则提示"非多集群抢 VIP, 去 master 上核对集群健康"。
`cluster.conf.example` 的 `K8S_API_VIP` 与 `METALLB_POOL` 注释都补了同款警告。

### 11. 【2026-09-23 事故】部署跑 22 分钟后 `kubeadm join` 报 `[ERROR Port-10250]: Port 10250 is in use` —— 节点上的 RKE2 agent 占着端口, 而部署前清理对它"免疫"

**症状**

全量部署跑到 kubespray 的 join 阶段中断, 9 台里**只有一台**失败, 且 0.08 秒就失败:

```
fatal: [node-3-32]: FAILED! => {"cmd": ["timeout","-k","120s","120s","/usr/local/bin/kubeadm","join", ...],
  "delta": "0:00:00.084779",
  "stderr": "error execution phase preflight: [preflight] Some fatal errors occurred:\n\t[ERROR Port-10250]: Port 10250 is in use"}
PLAY RECAP: node-3-32 failed=1, 其余 8 台 failed=0
```

迷惑点: 同一轮部署**开头**刚打印过 `✅ 清理完成: 7 台成功, 0 台失败`。

**根因(两层, 缺一不可)**

① **节点上跑着 RKE2 agent**(`rke2-agent.service`, enabled 且已运行 9 天, 注册到外部 server),
其内嵌 kubelet 监听 `*:10250`。而部署前的清理逻辑是**纯 kubespray 视角**, 对第三方发行版完全无效:

| 清理动作 | 对 RKE2 的效果 |
|---|---|
| `kubeadm reset -f` | 空操作(它不是 kubeadm 集群) |
| `systemctl stop kubelet` | 停不到 —— RKE2 的内嵌 kubelet 由 `rke2-agent.service` 托管, 不叫 `kubelet.service` |
| 删 `/etc/systemd/system/kubelet.service`、`/etc/kubernetes`、`/var/lib/kubelet` | RKE2 的 unit 在 `/usr/local/lib/systemd/system/rke2-agent.service`, 不受影响 |

**为什么只有一台炸**: 另外 4 台也装了 RKE2, 但 `rke2-agent` 已是 disabled + 未运行 → 端口空着, join 正常。
换句话说, 该故障的触发条件是"某台节点上恰好有个**活着的**外来 kubelet", 与节点数量无关。

② **"清理成功"是假信号**: 远端清理脚本以 `true` 收尾 → ssh 退出码恒为 0, 计数逻辑
(`reset_ok/reset_fail`)只能统计 ssh 传输失败, **从没校验过端口是否真的让出**。
于是故障被推迟 22 分钟、在离真因隔了一整个 playbook 的地方才爆出来。

**解法(根治)**

`deployments/kubespray/cubestack-offline.sh` 的 `reset_kubernetes_if_needed()` 重做成三层:

① **检测**: 判据从"kubeadm 残留"扩展为"**任何占着 10250 的东西**"(与发行版无关的硬判据),
加上第三方发行版单元探测(`rke2-agent/rke2-server/k3s/k3s-agent/microk8s`, 区分 `running`/`installed`);
探针第三行回传命中详情, 供告警点名"到底占了什么"。
② **中立化**: 清理前先 `systemctl disable --now` 这些单元(`disable` 防重启后复活重新占端口);
端口仍被占才升级到官方 `rke2-killall.sh`/`k3s-killall.sh` 兜底。
**契约是"让出 10250"而非"卸载别人的集群": 只 stop+disable, `/var/lib/rancher` 等数据目录一律保留。**
③ **复核 + 快速失败**: 以"10250 是否真的空出来"为唯一判据(最多等 10s 让 LISTEN socket 释放);
仍被占则打印**占用者 PID / 启动时间 / 完整命令行**, 脚本非 0 退出 → 函数返回 1 → 调用方 `err` 中止部署。
部署在**开始阶段**就停下来并指名元凶, 而不是 22 分钟后在 kubespray 里抛一句 `Port-10250`。

顺带修掉两个相邻问题: 探测失败的节点不再**静默跳过**(点名告警, 否则它若占着 10250 又要等 20 分钟才暴露);
`sync-to-container.sh` 的默认同步路径补上 `deployments/kubespray/cubestack-offline.sh`
(原来漏同步该文件, 且会静默打印"✅ 同步完成", 详见该文件注释)。

**验证(2026-09-23 实机)**

```bash
# ① 检测层: 9 台真机跑新探针 —— 只有真因节点被点名 rke2-agent:running
#    node-3-32 → port-10250;rke2-agent:running;rke2-server:installed;kubelet-unit;...
#    node-3-33 → port-10250;rke2-agent:installed;kubelet:running;...   ← 装了但没跑
# ② 清理层: 对 3-32 实跑清理脚本
sudo ss -lntp | grep 10250          # 清理前: kubelet(pid=127993) 占着 *:10250
                                    # 清理后: 无监听、无残留 kubelet/rke2 进程
systemctl is-active rke2-agent      # inactive(stopped) ; is-enabled → disabled
sudo du -sh /var/lib/rancher/rke2   # 2.4G 原样保留(未删数据)
# ③ 失败路径: 用 python3 人造一个占用 10250 的未知进程 → 脚本返回 1, 并打印
#    PORT_BUSY: ... + LISTEN ...users:(("python3",pid=685106,fd=3)) + ps 全命令行; 耗时 11.9s(=10s 重试窗口)
# ④ 本地侧四场景 stub 测试: 清理成功/干净节点/清理失败/节点不可达 → 计数与返回码均符合预期
```

**相关命令**

```bash
# 手动判断某节点是否有"外来 kubelet"占着端口(部署前可自查)
ssh <node> 'sudo ss -lntp | grep 10250'
ssh <node> 'systemctl list-unit-files | grep -Ei "rke2|k3s|microk8s"'

# 处置: 让出端口但不卸载对方集群(数据保留)
ssh <node> 'sudo systemctl disable --now rke2-agent'
# 仍占着才需要官方兜底(只杀进程/清 CNI 运行态, 不动 /var/lib/rancher)
ssh <node> 'sudo /usr/local/bin/rke2-killall.sh'
```

### 5. `--steps cubestack_operator` 报成功, 但 operator 仍跑旧镜像(在线/离线)

**症状**: `sudo ./deploy-cluster.sh --steps cubestack_operator` 执行完成、`helm` 与 `rollout status`
都成功; 但 `kubectl -n cubestack-system get deploy cubestack-operator -o jsonpath='{.spec.template.spec.containers[0].image}'`
仍是 `:latest`, Pod AGE 没变; 即使 `imagePullPolicy=Always` 也不生效。

**根因**:
- `Always` 只在**新建 Pod** 时重新解析 tag; 运行中的旧 Pod 不会因为 `Always` 自动重启;
- `helm upgrade --install` 在 chart/values 渲染结果没变时(同 `:latest` tag)不会改 Pod 模板 → 不触发滚动;
- 旧代码只有离线模式写 `podAnnotations.cubestack.io/image-digest`; 在线模式没有 digest 注解;
- `CUBESTACK_OPERATOR_IMAGE_TAG` 没有真正进入 helm 渲染/安装参数, 只依赖 chart 默认 tag。

**解法(2026-10-19 已落地)**:
- 离线/在线**都**把 **operator 镜像 digest** 写进 `podAnnotations.cubestack.io/image-digest`
  (digest 变 → Pod 模板变 → 自动滚动);
- 在线模式取不到 Harbor digest 时, helm 后自动 `rollout restart deployment/${RELEASE}` 兜底;
- `image.tag=${IMG_TAG}` 同时进入 chart 渲染与 helm 安装参数
  (2026-10-22 起改为: **仅显式** `CUBESTACK_OPERATOR_IMAGE_TAG_OVERRIDE` 才传 `image.tag`, 默认由 chart 自带);
- 离线 operator 与 CR 组件 `imagePullPolicy` 都改为 **Always**(每次新建 Pod 从集群 registry 重新解析);
- `CUBESTACK_OPERATOR_IMAGE_PULL_POLICY` 保留兼容但不再生效(强制 Always)。

**验证**:
```bash
kubectl -n cubestack-system get deploy cubestack-operator \
  -o jsonpath='{.spec.template.metadata.annotations}{"\n"}'
kubectl -n cubestack-system get pods -o wide
# 更新镜像/ chart 后重跑 --steps, Pod AGE 应变化; 内容未变则 digest 注解不变、不重启
bash deployments/scripts/tools/tests/test-cubestack-operator-update.sh
```
详见 `docs/cubestack-operator.md` §1.1 / §3.6。

### 6. 【2026-10-19 事故】`verify_cubestack_operator` 的冒烟 CR 删掉了真实 `lws-system` 命名空间

**症状**
- `kubectl -n lws-system get pods` 只有 `lws-controller-manager`, 且 `CrashLoopBackOff`;
  `describe` 报 `configmap "lws-manager-config" not found` / `secret "lws-webhook-server-cert" not found`;
- 日志 `Unauthorized` + `the server has asked for the client to provide credentials`;
- 命名空间里 **没有** `lws-controller-manager` ServiceAccount、ConfigMap、Secret、ClusterRole/Binding;
- 但主 CR `kubectl -n cubestack-system get csc cubestack` 的 `status.components` 仍显示 `lws=Ready`。

**根因(逐项证据)**
1. `26_verify_cubestack_operator.sh` 的冒烟 CR 只写了 `deletePolicy: uninstall`, **省略了
   `spec.components`**。operator 对省略的组件会继承 catalog/chart 默认值; 新版 chart 默认启用
   `lws/envoyGateway/...` ⇒ 冒烟 CR 实际管理了真实组件;
2. 验证结束 trap 删除冒烟 CR, `deletePolicy=uninstall` 触发组件卸载; operator 日志明确:
   `uninstall deleted component namespace {"CubeStackCluster": {"name":"verify-csc"}, "component": "lws",
   "namespace": "lws-system"}` —— 把**主 CR 正在使用的共享命名空间**整个删了;
3. operator 的组件状态按 **desired hash** 比较; 资源被外部删除但 hash 未变时不会重新 apply
   (没有 drift detection) ⇒ 主 CR 状态继续显示 `lws=Ready`, 不会自愈。

**修复(2026-10-19 已落地)**
- 冒烟 CR 显式写**全部** components `enabled: false`(含 `exporters.bmc/metax`)、`bundles: []`,
  并把 `deletePolicy` 改为 **`retain`**(双保险; CRD 默认也是 retain);
- 清理前增加护栏: 读取冒烟 CR 的 `spec.components`, 只要发现任何 `enabled: true` 就中止,
  不执行卸载路径;
- `test-cubestack-operator-update.sh` 增加静态断言(不能出现 `deletePolicy: uninstall`、
  每个组件 key 必须在冒烟 CR 中显式禁用)。

**恢复被误删的组件**(脚本修复后)
```bash
# 强制 operator 重新 apply: 把 lws 关掉再打开(改变 desired hash)
kubectl -n cubestack-system patch csc cubestack --type=merge \
  -p '{"spec":{"components":{"lws":{"enabled":false}}}}'
kubectl -n cubestack-system patch csc cubestack --type=merge \
  -p '{"spec":{"components":{"lws":{"enabled":true}}}}'
# 等待 SA/ConfigMap/Secret/Deployment 重建 + Pod Running + CR phase=Ready
kubectl -n lws-system get sa,cm,secret,deploy,pod
kubectl -n cubestack-system get csc cubestack \
  -o jsonpath='{range .status.components[?(@.name=="lws")]}{.phase}{end}'
```
**验证**: 重新执行 `--steps verify_cubestack_operator`; 结束后 `lws-system` 的 SA/CM/Secret
必须仍在, Pod 仍 Running, 冒烟 CR 已被清理。回归:
`bash deployments/scripts/tools/tests/test-cubestack-operator-update.sh`。

### 12. 【2026-10-22】`SERVICE_EXPOSE_MODE=nodeport` 但 Envoy Gateway 公网 Service 仍是 `LoadBalancer/<pending>`, Web UI 打印私有 ClusterIP

**症状:** 部署汇总显示 NodePort 模式, 但:

```
kubectl -n envoy-gateway-system get services
envoy-envoy-gateway-system-cubestack-gateway-xxxx   LoadBalancer   10.233.20.25   <pending>   80:32078/TCP
CubeStack Web UI (MetalLB): http://10.233.54.28/
```

`10.233.54.28` 是私有网关 `cubestack-ai-private` 的 **ClusterIP**, 只能集群内访问。

**根因:**
1. `CubeStackCluster.spec.global.serviceExposeMode` 只作用于 operator 自己渲染的 Service;
   Envoy Gateway 公网数据面 Service 由 **EnvoyProxy** 决定, 未指定时默认 `LoadBalancer`;
2. 公网 Gateway 没有 `spec.infrastructure.parametersRef` → 使用默认 EnvoyProxy → LoadBalancer;
3. `cubestack-ui-url.sh` 把 Gateway 的 `status.addresses` 一律当作 LoadBalancer 地址,
   于是把私有网关的 ClusterIP 标成了 "MetalLB"。

**解法(已落地):**
- `25_cubestack_operator.sh`: 显式把 `SERVICE_EXPOSE_MODE` 写入 CR
  `spec.global.serviceExposeMode`(`nodeport|loadbalancer`), 并对已有 CR 纠偏;
- operator 就绪后调用 `ensure_envoy_gateway_service_type`(lib-common): 创建/更新
  `EnvoyProxy/cubestack-proxy`(`envoyService.type=NodePort|LoadBalancer`)并挂到公网
  `Gateway/cubestack-gateway` 的 `spec.infrastructure.parametersRef`;
- `cubestack-ui-url.sh`: 只把 LoadBalancer 的地址当 MetalLB; NodePort 用节点 IP + nodePort;
  ClusterIP 不再输出为 Web UI 地址;
- `--steps cubestack_operator` / `--steps envoy_gateway` 每次都会幂等重挂。

**验证:**
```bash
kubectl -n envoy-gateway-system get envoyproxy
kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=cubestack-gateway
bash deployments/scripts/tools/tests/test-cubestack-ui-url.sh        # ⑥ 公网 NodePort + 私有 ClusterIP
bash deployments/scripts/tools/tests/test-cubestack-operator-update.sh # ⑨ serviceExposeMode / Envoy 兜底
```

### 13. 【2026-10-28】单节点 / 无 worker 集群被 node_pool cordon: CoreDNS 滚动或节点重启后永久 Pending

**症状:** 单节点 all-in-one(或只有 master、无 worker)集群部署完成后, CoreDNS / dns-autoscaler
副本一旦滚动、扩缩容或节点重启, 新 Pod 永久 `Pending`, 事件:

```
0/1 nodes are available: 1 node(s) were unschedulable.
```

已有 Pod 仍 Running, 部署汇总看起来正常, 直到下一次 DNS 组件变更/节点重启才爆发(整集群 DNS 失效)。

**根因:**
1. `NODE_POOL_ENABLED` / `NODE_POOL_MASTER_CORDON` 默认都是 `true`, `53_node_pool` 在 addon
   末尾把**所有** master cordon —— 无 worker 时这就是集群里仅有的可调度节点;
2. kubespray 模板的 CoreDNS/dns-autoscaler 只容忍
   `node-role.kubernetes.io/control-plane:NoSchedule`, **没有**
   `node.kubernetes.io/unschedulable:NoSchedule`(scheduler `NodeUnschedulable` 插件检查的隐式
   taint); 默认 `NODE_POOL_PLATFORM_PLACEMENT=false` 也不跑 `master-placement.sh` 补容忍;
3. `patch-playbooks/cubestack-single-node.yml` 在部署早期特意 uncordon 单 control-plane,
   随后被 node_pool 又 cordon 回去。

**解法(已落地):** `tools/node/node-pool.sh` 增加"无 worker 安全护栏":
- `NODES` 中 `role=worker` 数为 0 时, 即使 `NODE_POOL_MASTER_CORDON=true` 也**跳过 cordon**;
- `--apply` 自动回滚**本工具此前创建**(ownership annotation)的 cordon(先有 worker、后来移除
  worker 的场景); 非本工具创建的 cordon 只告警、不动;
- `--check` 在该拓扑下期望 master 可调度, 被 cordon 即报漂移;
- 有 worker 时行为不变。详见 `docs/node-pool.md`「无 worker 拓扑」。

**验证:**
```bash
bash deployments/scripts/tools/tests/test-node-pool.sh   # ⑧⑨⑩: 跳过 cordon / 回滚遗留 cordon / check 漂移
```
边界: "CoreDNS 不带 unschedulable 容忍 → Pending" 机制已在容器 d 验证(见 `docs/node-pool.md`
关键机制); 本修复由离线回归覆盖, 尚未在真实单节点集群跑全量部署复验。

---

## 四、离线部署

### 1. 【单机/重装】`Drain node` → `Remove-node | List nodes` 报 `error: stat /etc/kubernetes/admin.conf: no such file or directory`

**症状:** kubespray `cluster.yml` 跑到 `container-engine/validate-container-engine`
(`tasks/main.yml:112` "Drain node") 后失败:

```
fatal: [node-1-232]: FAILED! => {"cmd": ["/usr/local/bin/kubectl", "--kubeconfig",
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
`lib-common.sh` 的 `tar_first_image_tag` 返回空 → 依赖内容匹配的逻辑(multus/rdma 的 tar 识别、
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


### 4. 【2026-10-15】覆盖安装 reset 被 Calico 一致性检查拦停: 旧集群网络模式 ≠ 新配置(断言 "Your inventory doesn't match the current cluster configuration")

**症状:** 覆盖安装(先 `reset` 旧集群再全量部署)时, `ansible-playbook reset.yml` 在 preinstall 阶段中断:

```
TASK [kubernetes/preinstall : Run calico checks] ***
fatal: [master01]: FAILED! => {"assertion": "not calico_pool_conf.spec.ipipMode is defined or calico_pool_conf.spec.ipipMode == calico_ipip_mode", ...
  "msg": "Your inventory doesn't match the current cluster configuration"}
```

**根因:** `playbooks/reset.yml` 的 "Reset cluster" play 带 `tags:resolvconf` 引入 `kubernetes/preinstall`
(为了还原 resolv.conf)—— 于是 preinstall 的 "Run calico checks" 也执行了。该检查**读活集群**
(`calicoctl get ipPool`, 现网配置)与 **inventory**(新配置)逐项比对;而覆盖安装的典型场景正是
"旧集群网络模式与新配置不同":实机 2026-10-15 为**旧集群 VXLAN(`vxlanMode=Always`/`ipipMode=Never`)
vs 新配置 IPIP(`ipipMode=Always`/`vxlanMode=Never`)⇒ 断言必失败。
该检查语义上只服务于**安装/升级**(防配置漂移),对"即将拆除"的 reset 场景没有意义 —— 却把整个
reset(以及后续覆盖安装)拦死。

**解法(根治):** 补丁 `deployments/kubespray/cubestack-patches/13-skip-calico-checks-on-reset.patch`
(两文件):
- `playbooks/reset.yml`: "Reset cluster" play 级 `vars: { cubestack_skip_calico_checks: true }`;
- `roles/kubernetes/preinstall/tasks/main.yml`: "Run calico checks" 的 `when` 增加
  `not (cubestack_skip_calico_checks | default(false) | bool)`。
⇒ **reset 路径整体跳过该检查; cluster.yml / scale.yml / upgrade_cluster.yml 不带该变量, 检查原样保留**。
补丁层由部署入口自动保障(install/scale 走 `ensure_kubespray`; reset 走 `cmd_reset` 的同款
`_ensure_patches_applied`, 2026-10-15 一并补上 —— reset 直接消费树内 playbook, 存量树缺补丁会再次
中断):缺位自动重放, 无需手工改树。

**⚠ workaround 同步移除:** 临时方案(在 "Run calico checks" 的 `when` 里加 `- false`)是**全局**
跳过(安装期也丢检查),整改后必须删掉 —— 否则树被外部改动, 补丁层的 `--check` 会报 MISSING、
`--apply` 可能 CONFLICT。

**验证:**
```bash
# ① 补丁在位(含 13):
bash deployments/kubespray/cubestack-patch-apply.sh --check     # 全静默 rc=0
# ② 树内两文件的语义(重置才跳过, 安装不跳过):
grep -n "cubestack_skip_calico_checks" deployments/kubespray/kubespray/playbooks/reset.yml
# ③ 端到端(实机): 覆盖安装跑 reset, 应不再出现 "Your inventory doesn't match the current cluster configuration"
```
**已验证边界(如实标注):** ① 机理已由实机验证 —— 用户 2026-10-15 在"Run calico checks"上临时加
`- false` 后 reset/覆盖安装**能继续跑通**(即"重置场景跳过该检查"确为有效解法);② 补丁 13 是本仓库
对同一机理的**正式实现**(范围收窄为 reset 路径),静态层验证已过(`--check` 全在位 / 纯净树前向重放
逐字节一致 / YAML 合法);③ 补丁版的**端到端实机复验**尚待下一轮覆盖安装 —— 跑通后请回来把本行
更新为"已实机验证"。

### 5. 【2026-10-15; 2026-10-16 补"远端重定向"变体】节点脚本 scp / `cat > /tmp` 报 Permission denied: 固定 /tmp 名撞上 sticky /tmp 的 `fs.protected_regular=2`(遗留他人属主文件, **root 也不例外**)

**症状:** root 安装(SSH_USER=root)时, 各模块向节点上传**固定 /tmp 名**脚本失败 —— 同一 run 中
**部分节点失败、其余成功**是本故障的指纹, 报错文案极具误导性(实测凭证/sudo 完全正常):

```
scp: /tmp/cubestack-registry-node.sh: Permission denied
⚠    cubestack-k8s-master11(192.0.2.214): 无法上传配置脚本(检查密钥/密码)   ← deploy-registry.sh
⚠    cubestack-k8s-master12(192.0.2.216): 无法上传脚本(检查密钥/密码)       ← setup-ntp.sh(同类)
```

**变体(2026-10-16, 远端重定向形态, 实机命中):** 报错不在 scp 客户端, 而在**远端 bash 的重定向** ——
同一内核保护对 `cat > /tmp/<固定名>.yaml`(O_CREAT|O_TRUNC 打开既有他人文件)同样生效:

```
bash: line 1: /tmp/ceph-rbd.yaml: Permission denied          ← 03_ceph_csi.sh [2/4] 建 rbd-pool(2026-10-16)
【错误】  创建 rbd-pool/StorageClass 失败 → 模块 ceph_csi 退出 1 → 整次部署中断
```

**根因:** ① 上传目标是**固定 /tmp 文件名**;② 节点 /tmp 是 sticky + world-writable, 且实机
`fs.protected_regular=2`(sysctl 实测)—— 打开**属主非本人**的既有文件会被内核拒为 EACCES;
③ 文件是**历史运行的另一用户**遗留(实机: 昨天 ubuntu 部署留下 `ubuntu:ubuntu` 的
`/tmp/cubestack-registry-node.sh`), 而本次部署用户是 root ⇒ 新用户的 scp(= open(O_CREAT|O_TRUNC))
覆盖既有他人文件 → `Permission denied`。**root 不受豁免**(2026-10-15 实机三态实测:
①覆盖既有他人文件=拒 ②新路径=过 ③先删再传=过)。无遗留文件的节点(实机 worker13, 重建后 /tmp 干净)
走"新建路径" ⇒ 成功 —— 这就是"部分节点失败"的原因, 与密钥/密码/连通性无关。

**解法(根治):** 上传固定 /tmp 名前**先清陈旧目标**(`ssh <user>@<ip> "sudo rm -f '<path>'"`,
目录则 `rm -rf && mkdir -p`), 使 scp 恒为"新建文件"; 新建成功后的属主=本次用户, 后续运行同类安全。
已落地: `setup-ntp.sh`(node_scp)/ `sync-ca.sh` / `rebootstrap-worker.sh` / `install-worker-packages.sh`
(重建 `/tmp/packages`)/ `reconcile-node-packages.sh`(重建 `/tmp/cubestack-debs`)/ `02_ceph.sh` /
`27_verify_ceph.sh`; 2026-10-15 补齐: **`deploy-registry.sh`**(node_scp, 本次实机故障点)+
`21_verify_metallb.sh` / `27_verify_ceph.sh`(固定名 `/tmp/verify-lb.yaml`、`/tmp/verify-ceph-pod.yaml`)+
`30_verify_rdma_shared_dev_plugin.sh`(`/tmp/verify-rdma-pod.yaml`)。

**✅ 同类"远端重定向"点已补齐(2026-10-16 实机命中并修复):** 上述三处 ——
`modules/03_addon/03_ceph_csi.sh::apply_remote` / `tools/k8s/ceph-expose-external.sh::_apply_yaml` /
同文件 CephFilesystem 段(`/tmp/ceph-ext-fs.yaml`)—— 统一改为**同一条远端命令内先清后写**:
`ssh … "sudo rm -f /tmp/<name>.yaml; cat > /tmp/<name>.yaml && ${K} apply -f …"`(一次 ssh 往返;
`sudo rm -f` 在新旧两种身份下都能清, 不引入第二次连接)。命中链条(实机): 10-14 ubuntu 时代遗留
`/tmp/{ceph-rbd,cephfs,cephfs-svgroups,rgw,rgw-users,ceph-ext-fs}.yaml`(属主 ubuntu:ubuntu),
10-15 起部署用户切 root(容器 cluster.conf `SSH_USER=root`)⇒ ceph_csi [2/4] 以 root 打开他人文件被拒。
最小复现: `sh -c "cat > /tmp/ceph-rbd.yaml </dev/null"`(root)→ `Permission denied`。

**★ 双腿口径(2026-10-16 起全链路, 支持 root↔ubuntu **任意方向**切换部署):** **写前预清 + 用完即删**。
⚠ **改权限(chmod)不是通解**: 拦截与"文件属主 + 文件对 group/other 的写位"共同相关 —— 实测 664 的
他人文件 root 也被拒; 而改成 666 只会**必然触发**保护。唯一通用解 = **删除后重建**: 写前
`sudo rm -f`, 用完 `rm -f`(删除可由 sudo/属主完成; 重建后属主=本次用户)。
**"用完即删"落地(2026-10-16):** `03_ceph_csi.sh`(apply 后删 yaml)/ `ceph-expose-external.sh`
(CephFilesystem 段; `_apply_yaml` 原本即删)/ `02_ceph.sh`(cephcluster.yaml)/ `ceph-backup.sh`
(节点侧 refresh.sh 副本 + monstore tar 取回后删)/ `sync-ca.sh`(脚本 + CA 临时件)/
`setup-ntp.sh`(节点脚本三处执行点)/ `deploy-registry.sh`(节点脚本)。原本就"预清+后删"齐备的:
`install-worker-packages.sh` / `reconcile-node-packages.sh` / verify 系列(21/22/27/30; 22 的预清本次补齐)。
**例外(有意保留):** `ceph-sync-images.sh` 的 `/tmp/ceph-images/`(镜像 tar + `.done` 断点复用;
每次运行 `sudo rm -rf && chown` 重建, 跨用户安全); rook-ceph-tools **pod 内** `/tmp`(随 pod 生命周期)。

**验证(2026-10-15 实机, 已通过):**
```bash
# ① 复现(容器内, 对仍有 ubuntu 遗留文件的节点): 覆盖既有文件拒 / 新路径过
scp /tmp/t root@192.0.2.216:/tmp/cubestack-registry-node.sh   # → scp: Permission denied(rc=1)
scp /tmp/t root@192.0.2.216:/tmp/brand-new-path.txt           # → rc=0(证明密钥/通路/权限正常)
# ② 修复后端到端(容器内跑修复版工具): [2/4] 6/6 节点成功(修复前 5/6 失败)
bash /opt/cubestack-installer/deployments/scripts/tools/lb/deploy-registry.sh
#   ✅ 6 台节点 "certs.d 已就绪"; master11 的 /tmp/cubestack-registry-node.sh 变 root:root(新时间戳)
# ③ 2026-10-16 远端重定向修复后复验(容器内): ./deploy-cluster.sh --steps ceph_csi
#   → [2/4] CephBlockPool rbd-pool + 3×SC ✅ / [3/4] CephFS ✅ / [4/4] 校验 ✅ / 模块完成 EXIT=0;
#   全日志无 Permission denied; 节点 /tmp/*.yaml 属主全部变 root:root(复跑新时间戳)
# ④ 2026-10-16 "用完即删"复验(同上再重跑一次): EXIT=0;
#   节点 `ls /tmp/ceph*.yaml` → **全部消失**(预清+后删双保险生效, 不再有任何 ceph 临时件残留)
```
**⚠ 边界(防误归因):** 本条只解决**节点脚本上传**。若 `k8s_registry` 模块仍以
`registry 未在 600s 内就绪 —— 后端 local-path`(PVC 未 Bound)失败, 那是**另一个**故障 ——
2026-10-15 实机链条: `local-path-provisioner` CrashLoop(其日志: 访问
`https://10.233.0.1:443` **i/o timeout**)→ PVC 永不 Bound → registry pod Pending;
叠加背景: calico-node **全节点 0/1**(felix 未就绪)与 apiserver 多次重启 —— 与 scp 无关。

**相关命令:**
```bash
grep -rn "fs.protected_regular" deployments/scripts/   # 已落地的"预清陈旧目标"点
sysctl fs.protected_regular                            # 节点内核口径(2=对 O_CREAT 打开既有文件也生效)
ssh <user>@<ip> "ls -la /tmp/cubestack-*.sh"           # 查遗留文件属主(与本次用户不一致即命中条件)
```

### 6. 【2026-10-22】密码错误被报成"Ceph/RBD 残留, 必须重启": `k8s_passwordless` 只告警不失败 + `node_pkgs` 把 SSH rc=255 当成 Ceph 探测结果

**症状:** cluster.conf 的 SSH 密码错误时, 部署一路跑到 `node_pkgs`, 报:

```
【错误】以下节点存在**不健康**的 Ceph/RBD 残留或不可达 —— 必须先重启后再部署:
  10.6.7.135: Warning: Permanently added '10.6.7.135' (ED25519) to the list of known hosts.
ubuntu@10.6.7.135: Permission denied (publickey,password).
【错误】  处置: ① systemctl stop kubelet containerd
【错误】        ② systemctl reboot -f   # 跳过卡死的 ceph 卸载
```

而更早的 `k8s_passwordless` 只打印 `⚠ 密码注入失败`, 随后仍打印 `✅ SSH 免密配置完成` 并退出 0。

**根因:**
1. `01_k8s_passwordless.sh` 对注入失败只 `warn` 后继续; 且未先检查密钥是否**已经可用**(幂等重跑时密码可能早已轮换, 不应再尝试密码)。
2. `tools/node/reconcile-node-packages.sh` 的前置探测把**任何**非零 SSH 退出码(含 **255 = 连接/认证失败**)都归入"不健康 Ceph/RBD 残留", 处置只给重启 —— 真因(认证失败)被埋掉。

**解法(已落地):**
- `tools/node/setup-passwordless.sh`: 先验证密钥; 密钥不通才尝试密码; 密码被拒 / 网络不通分别给出明确诊断; 任一用户失败则非零退出。`01_k8s_passwordless.sh` 据此**中止部署**(后续模块都依赖免密 SSH), 不再谎报"完成"。
- `tools/node/reconcile-node-packages.sh`: 前置探测按退出码分类 —— `255` → SSH 认证/网络失败(给密码/公钥指引, **不提示重启**); `2`/`124` → Ceph/RBD 僵尸态(才给重启指引); 其他 → 探测执行失败。
- `deploy-cluster.sh` 的异常退出钩子先探测 SSH, 不通则跳过 Ceph 消费者恢复(不再在失败日志末尾刷两条 `Permission denied`)。

**验证:**
```bash
bash deployments/scripts/tools/tests/test-k8s-passwordless.sh         # 密码错→模块非零退出; 密钥已就绪→不碰密码
bash deployments/scripts/tools/tests/test-reconcile-node-packages.sh  # ②d/②e: SSH 认证/网络失败不再提示重启
```

**相关命令:**
```bash
sudo ./deploy-cluster.sh --steps k8s_passwordless   # 修正密码后先单跑复核
```

### 7. 【2026-10-22】`CEPH_ENABLED=false` + `CEPH_CSI_ENABLED=false` 仍执行 `cephfs_mount`: 子开关默认值未跟随 Ceph 总开关

**症状:** Ceph 两个总开关都是 `false`, 但部署计划里仍出现 `cephfs_mount`, 执行到:

```
→  [cephfs_mount] 自动把 CephFS 子目录挂载到**每台节点**的宿主机路径 ...
→  预检 Ceph 集群与 CephFilesystem 'cephfs'...
【错误】CephCluster phase=''(应为 Ready); 先部署/修复 ceph 模块
```

部署因此中断在一个与用户配置(不部署 Ceph)矛盾的模块上。

**根因:** `cluster.defaults.conf` 里 `CEPHFS_ENABLED` / `CEPH_RGW_ENABLED` 无条件默认 `true`,
而 `CEPHFS_MOUNT_ENABLED` 默认跟随 `CEPHFS_ENABLED` ⇒ 即使 `CEPH_ENABLED=false` + `CEPH_CSI_ENABLED=false`,
`cephfs_mount` 仍被 `module_default_on` 判定为启用并排进计划;模块内部只检查 `CEPHFS_ENABLED`,
于是继续去预检一个不存在的 `CephCluster`。

**解法(已落地):**
- `cluster.defaults.conf`: `CEPHFS_ENABLED` / `CEPH_RGW_ENABLED` 改为默认跟随 `CEPH_CSI_ENABLED`
  (`${CEPH_CSI_ENABLED:-false}`)—— Ceph 全关时子能力也关闭;开启 CSI 时仍默认开启(行为不变)。
- `07_cephfs_mount.sh`: internal 模式增加兜底 —— `CEPH_ENABLED` 与 `CEPH_CSI_ENABLED` 都为 false 时
  **直接跳过**(即使 `CEPHFS_MOUNT_ENABLED` 被旧配置/显式误开),不再预检 Ceph。

**验证:**
```bash
bash deployments/scripts/tools/tests/test-cephfs-mount.sh   # ①b 计划不含 cephfs_mount; ②b/②c 不预检/不发 SSH
# 手工核对计划(Ceph 全关应看不到 ceph/ceph_csi/cephfs_mount):
CLUSTER_CONF=<ceph-off.conf> ./deployments/scripts/deploy-cluster.sh --list | grep 本次执行模块
```

---

## 五、存储 / CephFS

### 1. CephFS 宿主机挂载(cephfs_mount): 模块报成功但节点没有挂载 / 反复叠加挂载 / 卸载后挂载残留

**症状**
- `kubectl -n rook-ceph logs ds/cephfs-models-mount` 反复打印
  `目标当前 fstype=ext4(hostPath 自身)` 与 `挂载成功`;节点 `findmnt -T /mnt/cephfs/models` 出现
  **多条相同 ceph 挂载**(挂载栈越叠越高);
- 或模块逐节点验证时报 `NOT_MOUNTED` / `校验失败: ceph`,但节点上其实已有 ceph 挂载;
- 删除 DaemonSet 后,节点 `findmnt -T /mnt/cephfs/models` **仍是 ceph**(卸载不干净)。

**根因(2026-10-19 实机, 逐项证据)**
1. **hostPath 在容器里本身就是 bind mount** ⇒ `mountpoint -q "${TARGET}"` 恒为真。用它判断
   "目标已被其他文件系统挂载"会把 hostPath 自身误判成外部 ext4 挂载并拒绝工作;
2. 同一路径存在**挂载栈**(hostPath 的 ext4 + 历史 ceph 挂载),`findmnt -n -o FSTYPE -T <path>`
   会输出**多行**("ext4\nceph\nceph");把整段多行输出与 `ceph` 比较必然不等 ⇒ 误判未挂载 ⇒
   每 30s 再挂一次,越叠越多;
3. `mountPropagation: Bidirectional` 传播到宿主机的 mount 是**宿主机命名空间里的独立 mount**,
   容器/Pod 退出时**不保证**被卸载(`kubectl delete ds` 后实测仍残留 3~5 层 ceph);
4. CephFS 挂载上执行**全局 `sync` 会挂住**(实测 `sync` 无输出、SSH 一直阻塞;同节点
   `sync -f /mnt/cephfs/models` 与 `dd ... conv=fsync` 均正常);验证脚本里的 `sync` 会让整轮部署卡死;
5. 远端 `kubectl ... -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'`:本地单引号被
   shell 剥掉后,远端 shell 把 `?(`/`(` 当语法符号 ⇒ 语法错误;脚本把空输出误判为 NotReady
   (本次实机曾出现"6 台全部非 Ready, 但模块仍报成功")。

**解法(根治, 已落地)**
- `mounted_ok()` / 验证统一取**最上层**: `findmnt -n -o FSTYPE -T <path> 2>/dev/null | tail -1`;
  **禁止**用 `mountpoint -q` 判断是否已挂载;
- 未挂载时才 `mount -t ceph`;子目录不存在时临时挂 FS 根 → `mkdir` + `chmod` → 再挂子目录;
- uninstall 分支**逐节点显式 umount**(循环最多 20 层, 只卸载 fstype=ceph, 不动 ext4 等);
- 验证探针去掉全局 `sync`(只做写入+读回);逐节点 SSH 加 `timeout 30`, 任何节点都不能拖死整轮;
- 节点 Ready 判断改用 `kubectl get node <name> --no-headers | awk '{print $2}'`,
  避免把含 `?(...)` 的 jsonpath 传给远端 shell;
- **零节点验证必须硬失败**(`没有节点完成挂载校验`), 禁止"全部跳过=成功"的假绿。

**验证(2026-10-19 实机, 已通过)**
```bash
# 部署 + 逐节点写读探针(6/6)
bash deployments/scripts/modules/03_addon/07_cephfs_mount.sh
# 每台节点恰好 1 层 ceph 挂载
ssh <node> "findmnt -n -o FSTYPE -T /mnt/cephfs/models | grep -cx ceph"
# 跨节点共享: master11 写 → worker13 读
ssh <master11> "echo shared > /mnt/cephfs/models/.p; cat /mnt/cephfs/models/.p"
ssh <worker13> "cat /mnt/cephfs/models/.p; rm -f /mnt/cephfs/models/.p"
# 幂等重跑: 第二次仍 6/6, 挂载层数不增加
# 卸载: DS/Secret/cephx 用户消失, 6 台节点 fstype 回到 ext4, 目录保留
CUBESTACK_MODULE_ACTION=uninstall bash deployments/scripts/modules/03_addon/07_cephfs_mount.sh
# 离线回归(无需集群)
bash deployments/scripts/tools/tests/test-cephfs-mount.sh
```
**验证边界**: 未做多节点**并发写**/性能/配额测试; 未做真实节点重启(以删除 Pod 模拟重挂)。
**相关命令**: `kubectl -n rook-ceph logs ds/cephfs-models-mount --tail=50`;
`findmnt -T /mnt/cephfs/models -o TARGET,FSTYPE,SOURCE`;
`kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph auth get client.cubestack-cephfs-models`.

### 2. 【2026-10-19 实机】cubepilot-api 更新后永久 Pending: RWO PVC + RollingUpdate → Multi-Attach

**症状**
- `kubectl -n cubestack-system describe pod cubepilot-api-<new>` 一直 `ContainerCreating`;
  Events: `Multi-Attach error for volume "pvc-..." Volume is already used by pod(s) cubepilot-api-<old>`;
- 同一个 Deployment 下**两个 ReplicaSet 各 1 个 Pod**: 旧 Pod `Running`(另一个节点), 新 Pod
  `Pending`; `status.conditions` 出现 `ProgressDeadlineExceeded`;
- `kubectl get deploy cubepilot-api -o jsonpath='{.spec.strategy}'` 是默认的
  `RollingUpdate{maxSurge:25%,maxUnavailable:25%}`。

**根因**
`cubepilot-api` 使用**单个 `ReadWriteOnce` PVC**。`maxSurge>0` 会先创建新 Pod; 新 Pod 被调度到
另一节点后, RBD 卷仍 attach 在旧 Pod 所在节点, 无法同时挂载(`Multi-Attach`); 而
`maxUnavailable` 取整后为 0, Deployment 又不会先停旧 Pod → 新旧 Pod 互相卡死。
这是 Kubernetes 对 RWO 卷 + RollingUpdate 的经典冲突, 与镜像/网络无关。

**解法(脚本已根治)**
- `lib-common.sh` 新增 `ensure_rwo_deployments_recreate <ns> [selector] [wait]`:
  解析 Deployment + PVC, 只把**引用 RWO PVC** 且策略非 Recreate 的 Deployment merge-patch 成
  `strategy: {type: Recreate}`(无 PVC/RWX 的组件不动; 幂等)。
- `25_cubestack_operator.sh` 的 `[6.5/6]` 在 operator 创建组件后自动执行(等待上界
  `CUBESTACK_OPERATOR_RWO_STRATEGY_WAIT_SECONDS`, 默认 60s)。
- `cubestack-component-update.sh`(`--steps cubepilot` 等)在 `rollout restart` **之前**执行,
  纠正失败会中止滚动(避免把组件滚进 Multi-Attach)。
- 手工即时修复(本次实机已执行, 旧 Pod 30s 内退出、新 Pod 40s 内 Running):
  ```bash
  kubectl -n cubestack-system patch deploy cubepilot-api --type=merge \
    -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'
  kubectl -n cubestack-system rollout status deploy/cubepilot-api --timeout=180s
  ```
- 验证: `kubectl -n cubestack-system get rs -l app=cubepilot-api` 旧 RS 应为 0;
  `kubectl -n cubestack-system get pod -l app=cubepilot-api -o wide` 只应有一个 Running;
  `kubectl -n cubestack-system get pvc cubepilot-api-data -o jsonpath='{.spec.accessModes}'`
  确认为 `["ReadWriteOnce"]`。

**注意**: operator 的 server-side apply 不渲染 `strategy` 字段, 因此本 patch 不会被下一轮
调谐覆盖; 若上游 chart 将来显式加入 `strategy`, 需要上游改成 `Recreate` 或提供 values 开关,
届时本守护会因 `strategy.type != Recreate` 继续纠正。

### 3. 【2026-10-28】更换 `CEPHFS_FS` 后部署报成功, 但宿主机读到的仍是旧文件系统

**症状:** 修改 `CEPHFS_FS`/`CEPHFS_FS_NAME`(或换 external 提供方 FS)后重跑 cephfs_mount,
模块与逐节点校验都通过, 但 `/mnt/cephfs/models` 里的数据仍是旧 FS 的内容;
`findmnt -T /mnt/cephfs/models -o OPTIONS` 显示 `mds_namespace=<旧 FS>`(或没有该选项)。

**根因:**
1. DaemonSet 的 `mounted_ok` 只按 `fstype=ceph` 判断"已挂载"(只读模式额外看 `ro`), **不看
   `mds_namespace`** —— 目标上已有旧 FS 的可读挂载时容器直接进入 `sleep 30` 永不重挂;
2. 模块的安装前预清理只比对只读状态、不比对文件系统; 旧 FS 挂载可读就被"保留复用";
3. 逐节点验证同样只查 fstype + 写读探针 → 旧挂载也通过, 最终报成功。

**解法(已落地):**
- 预清理增加 `mds_namespace` 比对: 现有挂载的 `mds_namespace` ≠ `CEPHFS_FS_NAME`(或缺失)
  与只读状态不一致一样, 走既有的 lazy umount 路径, 由 DS 按当前配置重挂;
- 逐节点最终验证要求 `mds_namespace=<CEPHFS_FS_NAME>`, 不匹配即 `WRONG_FS` 失败;
- 内核 5.15 实测 `findmnt -n -o OPTIONS` 会显示 DS `mount -o mds_namespace=...` 写入的值
  (集群 c 节点: `...,acl,mds_namespace=cephfs`)。

**验证:**
```bash
ssh <node> "findmnt -n -o OPTIONS -T /mnt/cephfs/models | tail -1"   # 应含 mds_namespace=<选定 FS>
bash deployments/scripts/tools/tests/test-cephfs-mount.sh            # ⑪: 旧 FS/缺选项 umount, 匹配保留
```
边界: 离线桩式回归 + 内核选项可见性实机确认; 未做真实"换 FS 覆盖部署"的端到端重挂验证。

---

## 六、发布 / 安装链路(2026-10-25)

### 1. CLI 镜像缺 GNU patch → kubespray 补丁层被静默跳过

**症状**
- `cubestack-offline.sh` 日志出现 `容器内无 patch 命令 → 跳过补丁层自动保障`;
- 全新安装后 Calico RBAC 等 14 个补丁未生效(可能表现为 calico-node 0/1、非 hostNetwork Pod 访问 ClusterIP 失败、coredns forward 异常等)。

**根因**
`Dockerfile-cli-base` 已声明安装 `patch`，但 Harbor 上的 `cubestack-installer-cli-base:latest` 是旧构建(2026-09-30)，镜像里实际没有 `/usr/bin/patch`；代码层 CLI 镜像继承旧 base，补丁层检测失败后**降级跳过**而不是报错。

**解法(已根治)**
- `Dockerfile-cli-base` 增加构建期断言 `command -v patch && patch --version`；
- `Dockerfile-cli` 最终校验链增加 `command -v patch`；
- `rebuild-cli-image.yml` 构建后实际运行镜像校验 `patch`，并在 `ci-validate.yml` 加静态门禁；
- 发布前/重建 base：
  ```bash
  sudo ./deployments/scripts/tools/docker/build-cli-context.sh --base --push
  sudo ./deployments/scripts/tools/docker/build-cli-context.sh --build --push
  docker run --rm --entrypoint bash <cli-image> -lc 'command -v patch'
  ```

**边界**: 补丁层仍建议保持"纯净上游 + patch 层"模型；仅对 Calico 单独做 post-render YAML 补丁不能覆盖其余 playbook 逻辑补丁，且重装会回退。

### 2. nodeport registry 的 containerd `hosts.toml` server 指向 5000 → 新镜像拉取卡住

**症状**
- 新 Pod 长时间 `ContainerCreating`，Events 只有 `Pulling image "registry.cubestack.io:5000/..."`
  且数分钟无进展(2026-10-25 实测: operator / CNPG postgres init / cuberouter 在 node-3 卡 5min+)；
- 从节点 `curl http://<master>:31148/v2/` 与 manifest 都是毫秒级，registry 本身正常。

**根因**
`deploy-registry.sh` 在 nodeport 模式下把 `hosts.toml` 写成:
```toml
server = "http://registry.cubestack.io:5000"
[host."http://<master>:31148"] ...
```
nodeport 模式的 registry **不监听 domain:5000**(只有 NodePort)，containerd 对 `server` 的请求超时/挂起，fallback 并不可靠；镜像已缓存时通常无感，一旦需要真正拉取就会卡住。

**解法(已根治)**
- nodeport 模式 `server` 直接写 `http://<master>:<REGISTRY_NODEPORT>`；
  loadbalancer 模式仍写 `http://<VIP>:5000`；
- 存量集群重跑 `--steps k8s_registry`，然后删除卡住的 Pod 让其重新拉取；
- 验证:
  ```bash
  ssh <node> "sudo cat /etc/containerd/certs.d/registry.cubestack.io:5000/hosts.toml"
  # 期望 server = "http://<master>:31148"
  ```

**边界**: 修改 `hosts.toml` 对**已经在进行中**的拉取不生效，需要删除/重建 Pod；containerd 不必须重启(每次拉取读取配置)。

### 3. operator 在线/离线切换后 model-bundles Degraded: InferenceRuntimeProfile spec immutable

**症状**
- `kubectl -n cubestack-system get csc cubestack` → `Ready=False`，`model-bundles(Degraded)`；
- operator 日志:
  `applying InferenceRuntimeProfile /metax-sglang-dsv4-pd: ... denied request: spec is immutable`。

**根因**
`InferenceRuntimeProfile` CRD 带 ValidatingAdmissionPolicy `oldObject == null || object.spec == oldObject.spec`；
离线模式创建的 profile 镜像前缀是 `registry.cubestack.io:5000`，切在线(Harbor)时 operator 尝试 update
spec 被 admission 拒绝。helm 可能先把 CR 的 `global.imageRegistry` 改成目标值，所以只看 CR 不够。

**解法(已根治)**
- `25_cubestack_operator.sh` 在 CR 纠偏阶段检测: CR registry 变化 **或** profile 内任意 `image`
  前缀不属于目标 registry → 删除 `inferenceruntimeprofiles.ai.cubestack.io --all`，
  让 operator 按新 registry 重建；
- 手工即时恢复:
  ```bash
  kubectl delete inferenceruntimeprofiles.ai.cubestack.io --all --wait=false
  # operator 会自动重建；随后 CSC 应恢复 Ready=True
  ```

**边界 / 代价**: 删除 profile 会让对应模型服务重新调谐(模式切换的一次性操作)；若上游 operator
改为"create-if-not-exists + spec 不变则跳过 update"，本保护可移除。验证:
`kubectl get inferenceruntimeprofiles.ai.cubestack.io -o yaml | grep image:` 应全部指向目标 registry。

### 4. NVIDIA ClusterPolicy repository 双前缀(在线 Harbor → 离线切换)

**症状**
- `kubectl get clusterpolicy cluster-policy -o yaml | grep repository:` 出现
  `registry.cubestack.io:5000/mirrors/harbor.isuanova.com/mirrors/registry.../mirrors/nvcr.io/...`
  这类多重前缀；组件可能 ImagePullBackOff / ClusterPolicy 不 ready。
- 模块自检只判断 `startswith(目标base)`，双前缀值也以目标 base 开头 → 自检假绿。

**根因**
`08_nvidia_gpu_operator.sh` 的 CR 纠偏旧逻辑是"值不以目标 base 开头就 `base + "/" + 原值`"；
从 Harbor 在线切回内置 registry 时，原值已带 `harbor.isuanova.com/mirrors/`，再拼一次就叠加成双前缀。

**解法(已根治)**
- 纠偏逻辑改为：在值中定位已知上游前缀(`nvcr.io/` 或 `registry.k8s.io/`)，重建为
  `<目标base>/<上游路径>`；不再用 `startswith` 早退(双前缀也会以目标 base 开头)。
- 已干净的值重建后不变 → 幂等；无已知上游前缀的值保持不动(避免误改)。
- 手工修复:
  ```bash
  kubectl get clusterpolicy cluster-policy -o yaml | grep repository:   # 确认双前缀
  ./deployments/scripts/deploy-cluster.sh --steps nvidia_gpu_operator   # 重新纠偏
  kubectl get clusterpolicy cluster-policy -o yaml | grep repository: | head
  # 期望 registry.cubestack.io:5000/mirrors/nvcr.io/nvidia/...
  ```

### 5. release-2.0 组件刷新: `_REFRESH_PENDING` / tag 不一致 / `_SUCCESS` 缺失

**症状**
- `fetch --release` 报“发布正在原地刷新(_REFRESH_PENDING)”；
- `release-sync-images.sh` 报 `dispatch tag != release.env` 或 `source_repo 不匹配`；
- 刷新失败后 MinIO 上 `<release>/_REFRESH_PENDING` 残留、`offline-files/_SUCCESS` 不存在。

**根因**
- 组件 dispatch 早于 installer release-2.0 的 `release.env` / `release-images.tsv` 更新；
- 刷新中断（网络/凭据/磁盘）保留了 marker，`_SUCCESS` 已按设计临时删除。

**解法**
1. 先更新 `deployments/releases/<release>/release.env` + `release-images.tsv`（同一 tag）；
2. 用相同 component 重跑（marker 会自动进入恢复模式）：
   ```bash
   bash deployments/scripts/tools/images/release-sync-images.sh \
     --release 2.0.0 --component <same-component>
   ```
3. 若 `_SUCCESS` 被手工删除且无 marker，才需要显式 `--recover`：
   ```bash
   bash deployments/scripts/tools/images/release-sync-images.sh \
     --release 2.0.0 --component all --recover
   ```
4. 确认：
   ```bash
   mc stat minio/cubestack-installer/2.0.0/offline-files/_SUCCESS
   mc stat minio/cubestack-installer/2.0.0/_REFRESH_PENDING   # 应不存在
   mc cat  minio/cubestack-installer/2.0.0/offline-files/SHA256SUMS | sha256sum
   ```

**边界**: marker component/subdirs 与本次不一致时脚本会拒绝（避免半套修复）；必须用覆盖原
scope 的 component 或 `all` 重跑。刷新期间不要手工删 marker。

### 5b. Harbor 与 MinIO 的 CLI digest 不一致

**症状**
- `skopeo inspect --raw .../cubestack-installer-cli:v2.0.0-rc2` 的 digest 与
  MinIO `<release>/_CLI_IMAGE_DIGEST` / `release.json.cli_image_digest` 不同；
- 离线部署（MinIO tar）与在线部署（Harbor tag）实际跑的是两版 CLI。

**根因**
- 旧流程 push `release-2.0` 后由 `rebuild-cli-image.yml` 只推 Harbor，CLI tar 曾依赖
  `sync-release-images.yml` 的 `workflow_run`（该触发已移除，现在同一 job 内同步）；
  历史上默认分支 main 的监听器缺失/滞后，或同步 workflow 失败时，MinIO 就停在旧 tar。

**解法**
1. 先确认差异：
   ```bash
   skopeo inspect --raw docker://harbor.isuanova.com/suanova/cubestack-installer-cli:v2.0.0-rc2 | sha256sum
   mc cat minio/cubestack-installer/2.0.0/_CLI_IMAGE_DIGEST; echo
   mc cat minio/cubestack-installer/2.0.0/offline-files/release.json | jq -r .cli_image_digest
   ```
2. 用 Harbor 上的目标镜像重新生成 tar 并 CLI-only 同步（不碰镜像/chart）：
   ```bash
   docker pull harbor.isuanova.com/suanova/cubestack-installer-cli:v2.0.0-rc2
   docker save -o /tmp/cubestack-installer-cli-v2.0.0.tar \
     harbor.isuanova.com/suanova/cubestack-installer-cli:v2.0.0-rc2
   bash deployments/scripts/tools/images/release-sync-images.sh \
     --release 2.0.0 --component cli \
     --cli-tar /tmp/cubestack-installer-cli-v2.0.0.tar \
     --cli-image-digest sha256:<Harbor registry digest>
   ```
3. 或重新触发 `rebuild-cli-image.yml`（release-2.0）。2026-10-26 起该 workflow 在**同一 job**
   内完成 Harbor → MinIO 同步，并在写 `_SUCCESS` 前断言三方 digest 一致。
4. 刷新期间 `_SUCCESS` 会被临时删除，fetch 会明确失败；完成后复查 `_SUCCESS` 与 marker。

### 6. k8s_deploy 期间修改 cluster.conf 导致 addons 与后续模块不一致

**症状**
- kubespray 部署完成，但 addon 阶段 `01_metallb.sh` 报 `未找到 metallb-system 命名空间`；
- `addons.yml` 里 `metallb_enabled: false`，而 `cluster.conf` 当前是
  `SERVICE_EXPOSE_MODE=metallb` / `METALLB_ENABLED=true`；
- 常见于 `k8s_deploy` 的 30s 倒计时或 kubespray 长时间运行期间修改了 `SERVICE_EXPOSE_MODE`。

**根因**
`k8s_deploy` 在入口一次性 `load_config`，随后用旧变量生成 inventory/addons.yml 并跑 kubespray；
后续 addon 模块会重新 `load_config` 读到新值。两边不一致时，MetalLB 模块要求
`metallb-system`，但 kubespray 按旧 nodeport 配置根本没安装它。

**脚本门禁（2026-10-26 已根治）**
- `lib-common.sh` 新增 `config_fingerprint` / `addons_metallb_enabled`；
- `06_k8s_deploy.sh` 在启动时记录 cluster.conf 指纹，**倒计时后和 kubespray 完成后各校验一次**；
  检测到变更直接中止，并提示重新运行，避免半新半旧；
- `01_metallb.sh` 在连集群前校验 `addons.yml metallb_enabled/metallb_speaker_enabled`；
  不一致时直接给出根因和修复命令，不再只报“未找到命名空间”。

**恢复**
```bash
# 以“当前 cluster.conf 想要的模式”为准
bash deployments/scripts/tools/k8s/gen-inventory.sh

# 若当前是 metallb：按当前配置重跑基座，让 kubespray 安装 MetalLB
sudo ./deploy-cluster.sh --steps k8s_deploy --fresh --yes
sudo ./deploy-cluster.sh

# 若当前实际想用 nodeport：把 cluster.conf 改为
#   SERVICE_EXPOSE_MODE="nodeport"
#   METALLB_ENABLED="false"
# 再 gen-inventory + 正常重跑（metallb 模块会自动跳过）
```

**验证**
- `kubectl get ns metallb-system` 存在，`kubectl -n metallb-system get pods` controller/speaker 1/1；
- `kubectl get ipaddresspools.metallb.io -n metallb-system` 的池 == `METALLB_POOL`；
- 重新运行部署不再出现配置漂移中止。
