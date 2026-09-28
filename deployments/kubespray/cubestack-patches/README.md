# kubespray 补丁层(cubestack-patches)

我们对上游 kubespray 树的源码改动,凡**不能**用配置(inventory/extra-vars)表达的,一律固化成本目录下的 `.patch`
文件 —— 升级(kubespray 换树)时按序重放即可,不再"直接改树、升级必丢"。

- 基线:纯净上游 **v2.32.0**(2026-09-28 随 `v2.28.0 → v2.32.0` 换树刷新;01–07 原按 v2.28.0 生成,
  换树时逐条按语义重放校验:纯净 v2.32.0 + 全部补丁 == 我们的树**逐字节**)。
- 每个 patch 是"**纯净树 → 我们的树**"的净差;`patch -p1` 前向打 = 重放,**`-R` 反打干净 = 与当前树一致**。
- 每条改动的"原因 / 上游吸收判据 / 上游化"三项写在 **patch 文件头的注释块**里(本 README 的表格是摘要,
  以 patch 头为准);判据用于升级时跑"这个补丁是否已被上游吸收、可以退休"的检查(设计 §3.5)。

## 补丁清单(7 处)

| 补丁 | 目标文件 | 一句话原因(丢了会怎样) | 上游吸收判据 | 上游化 |
|---|---|---|---|---|
| `01-download-container-mkdir.patch` | `roles/download/tasks/download_container.yml` | `download_force_cache`(离线备料)上传镜像前先建目标目录;丢了则目标父目录不存在时 `synchronize` 上传失败, 离线备料中断 | 上游上传任务前自建目标目录(或上传任务容忍目录缺失) | 建议提 PR(通用离线健壮性; 非 §3.5 首批) |
| `02-client-kubeconfig-mode.patch` | `roles/kubernetes/client/tasks/main.yml` | kube artifacts dir 权限 `0750 → 0777` —— 部署容器内非 root 用户要读 kubeconfig;丢了则非 root 用户读不到, 依赖 kubectl 的步骤权限被拒 | 上游不再硬编码 0750(改成可配置变量或默认放宽) | 不提(本环境特有; 0777 对上游默认场景是安全面倒退) |
| `04-kubeadm-setup-san.patch` | `roles/kubernetes/control-plane/tasks/kubeadm-setup.yml` | SAN 检查块前先 `stat` 探测 `apiserver.crt`, 只在证书存在时才比对 SAN;丢了则 kubeadm 已运行但证书缺失时读证书硬失败、play 中断 | 上游 SAN 检查块自带 `apiserver.crt` 存在性守卫 | 建议提 PR(通用幂等健壮性; 非 §3.5 首批) |
| `05-apps-meta-registry-order.patch` | `roles/kubernetes-apps/meta/main.yml` | `kubernetes-apps/registry` 由 metallb **之前**挪到**之后** —— registry 的 LB VIP 依赖 metallb 先就位(`registry_service_type=LoadBalancer` 时);丢了则 registry 的 VIP 一直 pending | 上游 `meta/main.yml` 中 registry role 已排在 metallb 之后 | 不提(本环境特有: 我们把 registry 以 LoadBalancer 暴露; 上游默认 ClusterIP) |
| `06-metallb-crd-race.patch` | `roles/kubernetes-apps/metallb/tasks/main.yml` | 裸金属新集群首装 metallb 的 CRD 注册竞态(Established 等待 + controller `rollout restart` + apply 重试);丢了则池子 CR 不被 controller 处理, LB 永远分不到 VIP | 上游该文件出现 `Established` 等待或 apply `retries` | **建议提 PR**(§3.5 首批上游化项; 见 `docs/kubespray-upgrade.md` 的"待上游化"清单) |
| `07-download-yml-k8s-cluster-group.patch` | `roles/kubespray_defaults/defaults/main/download.yml` | `dnsautoscaler` / `metrics_server` 镜像的下载组补 `- k8s_cluster`(原仅 `kube_control_plane`; 闸门见 `roles/download/tasks/main.yml` 的 `group_names \| intersect(download.groups)`);丢了则 worker 不下载这两个镜像, 离线节点上组件起不来 | 上游这两个条目 `groups` 含 `k8s_cluster` | 不提(会改变上游默认下载面: 全部节点都下载; 本环境离线自持所需) |
| `08-kubeadm-secondary-join-stat.patch` | `roles/kubernetes/control-plane/tasks/kubeadm-secondary.yml` | "是否已 join 成功"以 `admin.conf` 是否存在为准(文件顶部 `stat` + **5 处** gate 加 `or not admin_conf_stat.stat.exists`:4 处 join 前置任务 + **join 任务自身**);丢了则 kubelet config 已存在(上次 join 半途失败)但 admin.conf 未生成时, 前置任务被跳过、join 也被自己的 gate 跳过 → 次 master 卡在"kubelet 已配好但未 join";**补上 join 那处**才能交付"admin.conf 缺 ⇒ 重新 join"(否则前 4 处会先做 `kubeadm reset` 却不重新 join) | 上游该文件出现 `admin.conf` 存在性守卫(stat / `is exists`), 或上游把"是否已 join"的判据从 kubelet config 换成 admin.conf | 建议提 PR(通用幂等健壮性; 非 §3.5 首批) |

### 已退休(1 处,别再加回来)

`03-kubeadm-fix-apiserver-stat.patch` —— **2026-09-28 随 `v2.28.0 → v2.32.0` 退休**。依据:目标文件
`roles/kubernetes/control-plane/tasks/kubeadm-fix-apiserver.yml` 自 **v2.31 起被上游整文件删除**(v2.28/v2.30 还在),
且它守卫的 task(`Update server field in component kubeconfigs`)在 v2.32 全树 grep 无命中 → **改动对象已消失**
(注意:这不是"上游吸收", 是上游删除了整段逻辑)。教训:目标文件消失时 `--check-retired` 只会报 KEEP
(反打不上 ≠ 上游未吸收), 退休必须人工确认。

> 本目录 7 个补丁 = spec §2.2 表的第 4、5、7(=原手工项)、8、9、10、11 行;**第 6 行(补丁 03)已退休**(见上)。

## 不在本目录的 3 处改动(别重复两套)

1. **机制 A(2 处)**:`playbooks/cluster.yml` / `playbooks/scale.yml` 的 4 行
   `import_playbook: patch-playbooks/cubestack-*.yml`,以及 `patch-playbooks/` 目录本身,
   由 `cubestack-offline.sh` 的"**内嵌内容重建**"机制负责(**树里没有就在部署时写进去**);
   本目录**不**含这两个文件,否则会变成两套互相打架的来源。

   **登记(2026-09-28 裁决,别再加回来)**:这 4 行 import 由 `cubestack-offline.sh` 的
   `ensure_*_play` 在**部署时按锚点注入**(preload / registry+single-node / install-packages /
   cni-restart,共覆盖 `patch-playbooks/` 下 5 个 play),**不**做成补丁、也**不**写进仓库树。
   理由(执行级):
   - **四处注入点都带"已存在则跳过"守卫 → 注入幂等,"固化后会双插"的风险不存在**。实测(2026-09-28):
     `ensure_preload_play` @`cubestack-offline.sh:814`、`ensure_registry_play` @L868、
     `ensure_packages_play` @L1031、`ensure_cni_restart_play` @L1171,形如
     `if grep -q "<play 文件名>" "${py}"; then log "✅ …"; continue; fi`(守卫按**文件名** grep,
     所以即使把 import 行固化进树、命中守卫也只是 `continue`,不会重复插入)。
   - **不固化的唯一理由 = 单一来源**:这 4 行由机制在部署时注入;若再固化进仓库树/补丁层,
     同一件事就有两份副本要同步(升级、幂等判定、评审都会纠缠)。
   - 锚点已在 **v2.32.0** 上逐条核对**仍存在**(锚点在 → 机制不会静默失效;锚点缺失时
     `ensure_*_play` 只 `warn` 跳过,不会误插):
     `playbooks/cluster.yml:19 - name: Install etcd`、
     `playbooks/cluster.yml:76 - name: Install Kubernetes apps`、
     `playbooks/scale.yml:43 - name: Target only workers to get kubelet installed and checking in on any new nodes(node)`、
     `playbooks/scale.yml:86 - name: Apply resolv.conf changes now that cluster DNS is up`、
     `roles/download/tasks/download_container.yml:104 - name: Download_container | Upload image to node if it is cached`
     (⚠ 行号口径:**打过本目录补丁 01 之后**的行号;纯净 v2.32.0 里该行在 `:95`)。
   - 注:`patch-playbooks/` 目录**本身**必须留在树里(换树要保留,见 `cubestack-kubespray-upgrade.sh`
     的保留集)—— 机制只在文件**缺失时**才用内置副本重建,而 `cubestack-registry.yml` /
     `cubestack-single-node.yml` 连内置副本都没有。
2. **已作废(1 处)**:`playbooks/ansible_version.yml` 的 `maximal_ansible_version: 2.17 → 2.18`
   —— v2.32.0 要求 ansible ≥2.19、<2.20,我们这处 2.17→2.18 的上限已无意义,**升级时随树丢弃,不迁移**。
3. ~~**手工项(1 处)**:`roles/kubernetes/control-plane/tasks/kubeadm-secondary.yml`~~ —— **2026-09-28 已固化**为
   `08-kubeadm-secondary-join-stat.patch`(见上表),不再走人肉重做。⚠ 原文写的"VIP / SAN / advertise-address
   相关 18 行"与实测不符:该文件对纯净 v2.28.0 的净差只有 `admin.conf` 存在性守卫(新增 8 行 stat 任务 +
   4 处 gate 各改 1 行),与 VIP/SAN 无关 —— 实测见文末"已知的文档偏差"。
   ⚠ 固化到 v2.32 时按评审裁决(Ruling 19)**补了第 5 处 gate**(join 任务自身),故补丁 08 是 **5 处**:
   只保留旧改动的 4 处会"先 `kubeadm reset` 却不重新 join",比不打更糟。

## 如何重放与自检

```bash
cd deployments/kubespray/kubespray                       # 树的根(补丁 -p1 的相对基准)
for p in ../cubestack-patches/*.patch; do                # 反打干净 = 补丁描述的就是"现状 − 纯净树"
  patch -p1 -R --dry-run < "$p" >/dev/null 2>&1 \
    && echo "✅ 可反打: $(basename "$p")" || echo "❌ 对不上: $(basename "$p")"
done
```

换树后前向重放的正确性判据:**纯净 v2.32.0 + 按序前向打分 == 我们的树(逐字节)**。
(2026-09-28 换树后按此口径复验通过,7 个补丁全绿;后续升级脚本 `cubestack-patch-apply.sh` 按同样口径实现 `--check`。)

## §3.3 "能下沉就下沉"判定结论

- **metallb 竞态修复(06)不能下沉**:竞态修复的时序在 role 内部(apply manifest 与 apply pools **之间**),
  移到我们自己的脚本里就失去意义 —— 故保留为补丁(结论出自设计 §3.3)。
- **05 不能下沉**:角色执行顺序写在 `meta/main.yml` 里,只能在树内改。
- **01 / 04 不能下沉**(03 已退休):守卫/建目录必须发生在 role 任务的执行点(目标主机、循环内),外部脚本无从插入。
- **07 保留为补丁**:形式上是 `defaults` 变量,理论上可从 inventory 覆盖,但覆盖路径深且脆弱,不值得。
- **02 是唯一的"可下沉候选"(未实施,记录备考)**:我们的部署模块可在 client role 之后对
  kubeconfig 目录 `chmod 0777`,从而**删掉这个补丁**;本次任务只做"导出",未改模块,记入后续收敛项。

## 已知的文档偏差(本次导出自审发现,供修订 spec 用)

- spec §2.2 第 8 行把 `kubeadm-setup.yml` 的改动记作"`kube_vip_address` 进证书 SAN 等 **14 行**";
  实际净差**只有** `apiserver.crt` 存在性守卫(**+12 行**):`sans_kube_vip_address` 在 v2.28.0 上游**已有**
  (纯净树 `kubeadm-setup.yml` 第 28/48 行与我们的树逐字相同)——即"进 SAN"那部分早已上游化,勿再当作我们的改动。
- spec §2.2 第 4 行记作"+8 行",实际 +9 行(数值漂移,不影响语义)。
- spec §3.5 的示例头写 `04-metallb-crd-race.patch`;本目录的最终命名以实施计划 Task 1 Step 1 为准为
  `06-metallb-crd-race.patch`(前缀 01–07 是**补丁层的顺序号**,不等于 §2.2 的表行号;对照见上表说明)。
- spec §2.2 第 7 行(`kubeadm-secondary.yml`)原记"VIP / SAN / advertise-address 相关 18 行";
  2026-09-28 实测(与纯净 v2.28.0 逐行对比)净差**只有** `admin.conf` 存在性守卫 —— 新增 8 行 stat 任务 +
  4 处 gate 各改 1 行,**不含 VIP/SAN/advertise-address 任何内容**;同日固化为 `08-*.patch`
  (固化时按 Ruling 19 补第 5 处 gate = join 任务自身 —— 旧改动的 4 处会让半 join 节点被 reset 却不重 join)。
- 前缀序号 = 固化时的历史顺序号,**退休不重排**:补丁 03 退休后保留空号,新增项续编 `08`(不补 03 的位),
  以免与既有的升级记录/文档中的编号对不上。
