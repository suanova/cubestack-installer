# kubespray v2.32.0 升级 —— 交付清单 / 待办 / 裁决记录

> 生成于 2026-09-28,分支 `feat/kubespray-v2.32`(**38 提交,未推送**)。
> 本文件是收尾清单的**权威落点**(聊天里给过一版,这份是文件化的)。
> 相关文档:`design.md`(spec/决策 D0–D8)、`plan.md`(14 任务 + T13 备料清单)、
> **稳定 SOP**:`../kubespray-upgrade.md`(与版本无关,以后每次升级照它走)。

---

## 一、交付状态

| 项 | 状态 |
|---|---|
| 树本体 | **纯净 v2.32.0**(1629 文件替换);与 `/tmp/kubespray-2.32` 差异恰好 = 7 个补丁目标 + `inventory/local` + 剔除的顶层点文件 |
| 补丁层 | `deployments/kubespray/cubestack-patches/` 7 个(01/02/04/05/06/07/08)+ README;**03 已退休**(上游删了目标文件与被守卫的 task) |
| 工具 | `cubestack-patch-apply.sh`(三态 + 退役判定)、`cubestack-kubespray-upgrade.sh <tag>`(取树/备份/换树/重放/退休,支持 `--root` 演练) |
| 插件 | kube-vip **v1.0.3** + 渲染器适配 v2.32 模板(`vip_subnet` / `version()` test);multus 钉 **`v4.2.2-thick`** + **tar 内容校验**;metallb 继续用上游 role(竞态修复在补丁 06) |
| 新增接线 | LVP 2.5.0 / NFD 0.19.0 接入上游 addon,**`cluster.conf` 默认 disable**;镜像已登记 + PRELOAD 四处副本一致 |
| 版本面 | k8s **1.35.8** / calico **3.31.7** / etcd **3.6.14** / coredns 1.12.4 / pause 3.10.1 / cpa 1.10.3 / nodelocaldns 1.25.0 / metrics 0.9.0 / nginx 1.30.1-alpine |
| 门禁 | check-modules:`⑮`(补丁在位 + **两个离线套件实跑**)`⑯`(钉子 == 表值 == inventory 写入者)全绿;**唯一红 = 既有 ⑪-B**(main 上同样红) |
| 回退 | tag **`kubespray-2.28.0-cubestack`**(=f0342b7,含树 + 旧补丁层)→ 必须**成对回退**:`git checkout kubespray-2.28.0-cubestack -- deployments/kubespray` |

## 二、待办(交回本机/联网机/真机环境执行)

**T12 重建 CLI 镜像** —— 树内 `requirements.txt` 已是 `ansible==12.3.0`;`Dockerfile-cli` 直接 COPY 它。**不重建则任何部署都会撞 ansible 2.19 版本门**(≥2.19 <2.20)。同时 `.venv_wheels/` 缓存若要用于裸机路径需刷新。
⚠ **2026-09-28 实测更正:这不是"机械动作"** —— `ansible==12.3.0`(= ansible-core 2.19.x)**在控制端要求 Python ≥3.11**,而基础镜像/ubuntu 22.04 是 **3.10** ⇒ `python3 -m pip install -r requirements.txt` 直接失败(`Requires-Python >=3.11`)。已修:
`Dockerfile-cli` + `Dockerfile-cli-incremental` 装 **deadsnakes python3.11** 并让 ansible 走它(系统 python3 仍 3.10,不动 python3-libvirt);
`cubestack-offline.sh:ensure_venv` 改为**优先挑 python3.12/3.11**(裸机路径),宿主要装 ≥3.11;
`.venv_wheels/` 已加 gitignore(原机制在、缓存从没产出)。SOP 同步:`docs/kubespray-upgrade.md` 新增第 8 条。

**T13 离线备料** —— ✅ **2026-09-28 已执行**(联网机下载件 → 仓库;不用 Harbor 管道,因为 mirrors 还没同步 1.35 线):
- ✅ 盘上离线 tar 整套换代到 1.35 线(kube-apiserver/controller-manager/proxy/scheduler **1.35.8**、pause 3.10.1、coredns 1.12.4、metrics-server 0.9.0、cpa 1.10.3、etcd 3.6.14、calico 3.31.7;二进制 kubelet/kubectl/kubeadm 1.35.8、cni 1.9.1、calicoctl 3.31.7、containerd 2.3.5、crictl 1.35.0、runc 1.4.3、helm 3.22.0、nerdctl 2.3.5)—— 二进制 sha256 对 `checksums.yml` 全过;
- ✅ `multus-cni:v4.2.2-thick` tar 已产出(`offline-files/multus/`,旧 `snapshot-thick` 移走)→ **硬门禁解除**;
- ✅ `ghcr.io/kube-vip/kube-vip:v1.0.3` tar 已就位;✅ `docker.io_library_nginx_1.30.1-alpine.tar` 已就位;
- ✅ LVP 2.5.0 tar 已就位;⏳ **NFD 0.19.0 tar 仍缺**(新下载件与 Harbor 都没有;`NFD_ENABLED` 默认 false ⇒ 不阻塞);
- ✅ 3 个**残缺**控制面镜像(12288B 空壳)已按上游 manifest 摘要重取并逐层校验(来源:阿里云官方镜像站,digest 与上游一致);
- ✅ 产出 `manual-download-list.md`(含本次"换代执行记录"节);旧件 30 个在 `/data/offline-superseded-20260928/`(可回滚,未删)。

**T14 实机验证**:全新集群全量部署(k8s 1.35.8),再分别开/关 LVP·NFD 各一次。
⚠ **对现有集群 A/B 的部署另行择期**(换树后全量部署会把它从 1.32.5 升到 1.35.8)。

⚠ **2026-09-28 首次实跑暴露的阻断(已修,待重跑验收)**:容器 a 全量部署中断在
`patch-playbooks/cubestack-single-node.yml:34`,mxgpu-3-28 报 `stat /etc/kubernetes/admin.conf: no such file or directory`。
- **根因**:该 play 用 `kubectl`(读 admin.conf)数 control-plane 节点,却和 registry hosts play 一起被
  `ensure_registry_play` 插在 **"Install etcd" 之前** ⇒ 全新集群上控制面还没起,admin.conf 必然不存在。
  `scale.yml` 场景(集群已存在)掩盖了它,直到第一次用它跑**全新集群**才暴露。
- **修法**:拆出 `ensure_single_node_play()`,改用与 `cubestack-cni-restart.yml` **同一组锚点**
  (`- name: Install Kubernetes apps` / scale.yml 的 `- name: Apply resolv.conf changes now that cluster DNS is up`),
  即 **K8s+CNI 就绪之后、addon/operator 之前**;并把"摘旧挂载点 → 重挂"的**迁移逻辑**做进函数里
  (老容器里的旧注入会被自动摘掉,连同它自己的注释块;marker 前空行归一 ⇒ 实测连跑 5 次 md5 不变)。
  已在容器 a 就地执行并复核:cluster.yml 的挂载点从第 36 行(etcd 前)移到第 117 行(Install Kubernetes apps 前),scale.yml 同步。
- **顺带修的同类隐患**:`sync-to-container.sh` 的 FILES 清单**只列了 5 个注入 play 中的 1 个**
  ⇒ 另外 4 个(preload/registry/cni-restart/single-node)改了永远进不去容器(与"树本体不整拷"叠加,
  正是历次"改了没生效"的老坑)。已把 5 个全部列入,本次同步复核为"单文件清单 9 个全部一致"。
- ⚠ 未做:该 play 在**多 control-plane**集群下只做计数不做动作(设计如此);单节点集群(1 cp)的
  taint/uncordon 行为仍需一次真机单节点部署验收。

**四条"部署前必答"**:
1. **生态兼容未核**:metax operator / rook v1.20 / ceph-csi × k8s **1.35**(design.md D1 自写"实施前先核",至今无交付物记录);
2. **容器内 `cluster.conf` 必须含 8 个钉子(值要新的 1.35.8 线)** —— 否则 sync §3.2 的 fail-loud 会停在 `k8s_inventory`(有意设计);
3. **跑 `trim-offline-files.sh` 之前先读本文第五节** —— 它会删 13 个离线 tar;
4. ~~离线 tar 按 T13 重出~~ ✅ 2026-09-28 已完成(见 T13 段);~~唯 multus/kube-vip 两条 fail-closed~~ 两条硬门禁均已满足。

## 三、独立工单(不在本支范围)

0. **2026-09-28 深夜暴露的两类新问题(已修, 见 §T14 之后的"apt 事故"段)**:① 离线 .deb 集与节点已装
   系统包的**版本漂移**打破 dpkg 依赖(新增模块 `12_node_pkgs` + `tools/node/reconcile-node-packages.sh`
   解决, 语义 = 交给 apt 求解器"先摘后装");② **容器读的离线件是 `/data/offline-files`(挂载)**,
   不是仓库 `deployments/offline-files/` ⇒ 两侧曾分叉(`/data` 里新旧混杂), 现已 rsync 对齐;
   以后改离线件**必须两边同步**。

1. **trim 护栏**:`trim-offline-files.sh` 第①步会删 `kubespray/images/` 下未匹配 PRELOAD 的 tar → 实测 **13 个 DROP** = ceph 组全部 11 个交付 tar + `ubuntu_22.04.tar` + 旧 `nginx_1.27.tar`;而 check-modules ⑤ 只覆盖 k8s-base(`check-image-manifest.sh:149` 跳过其它组)→ **ceph 两侧无护栏**。建议:给 ceph 组补 PRELOAD token,或把 ⑤ 扩到 ceph 组,并让 trim 打印 DROP 清单要求 `--yes`。
2. **陈旧引用清理**:`docs/api-ha/02-kubespray-native-lb.md:289/311/317/318`、`docs/kube-vip-api-ha.md:629/728/811`、`cluster.conf.example:144` 与 `multus/CUBESTACK.md:45/59` 的 `16_multus` 旧模块号。(`deployments/offline-files/kubespray/README.md:50/75/91` 的 nginx 1.27.4 陈旧引用 **2026-09-28 已随换代修掉**。)
3. **`.gitignore` 窄化**:第 60 行整目录忽略 `deployments/scripts/tools/tests/` → 现有 5 个套件已跟踪(⑮ 在全新 checkout 不红),但**新增第 6 个套件会被静默忽略**;另 `sync PKG_EOF` 的内嵌 install-packages play 比树内旧(110 vs 157 行)→ 建议:窄化 gitignore + 对齐 PKG_EOF + 给"tar 内容 vs 清单"加一条静态护栏(本链条唯一"看不见"的环节)。

## 四、裁决记录(Rulings,执行期我替你做的决定;逐条穷举)

> 格式:`决定 —— 若判错的代价`。这些决定当时都写进了执行 ledger(临时工作区,已按流程删除),这里是与聊天同源的完整转写。

1. T3 演练预期按实测改为"7 APPLY/0 冲突" —— 判错则演练停在 CONFLICT(可发现)
2. T4 必须把 kubeadm-secondary 重写结果固化成补丁 08 —— 漏则 `--check` 报 MISSING
3. **不建 worktree**,直接在特性分支执行 —— 并行会话动同仓库会互扰(当前无)
4. **执行到 T11 为止**,T12–T14 交回用户(需构建机/联网机/真机 + 对外动作)
5. spec §2.2 行 8 按实测修正(证书 SAN 上游早有,补丁实为 `apiserver.crt` 守卫)—— 仅文案
6. spec §3.5 示例文件名 04-→06- —— 纯文案
7. 02 补丁"可下沉"登记为后续收敛项,本次不做 —— 少收敛 1 个补丁
8. T2 接口新增 `--patches <目录>` —— 不实现则测试误打真补丁
9. 换树保留 `.venv` —— 漏则裸机升级后跑不起来
10. **退休判定前置于 `--apply`** —— 若判错,退休判定空转、补丁永不收敛
11. T3 只写报告、由 T5 建文档 —— 若判错,T5 会漏演练记录
12. T4 必须带 `K8S_VERSION=v1.35.8` 跑 —— 忘则撞版本门(可发现)
13. 保留粒度 = `inventory/local`,上游 `sample` 随新树刷新 —— 若判错会丢本地模板改动
14. dirty 门保留、只改"重跑"措辞 —— 代价:用户多一次 commit
15. 收窄为 `--exclude='/inventory/local'`(reviewer 纠正了我的事实错误:树内 local 不是实盘 inventory)
16. **撤销"补丁 09"**(依据后更正:四处都有去重守卫;真正理由是"单一来源")—— 若判错,少固化一处修复(功能无损)
17. 恢复 `patch-playbooks/` 并加入升级脚本保留集(用户明确要求)
18. *(编号未使用)*
19. 补丁 08 补**第 5 处 gate**(join 任务自身)—— 若判错,某"admin.conf 被删"场景会多跑一次 join(kubeadm 明确报错,不致破坏)
20. 接受在 check-modules 索引里登记 ⑮ 一行 —— 与既有约定一致
21. 回退 = 树 + 补丁层**成对** checkout —— 若判错会得到混合状态(已实测备份 tag 内容)
22. **跳过 T8**(交付物已被 T1/T5 覆盖)—— 最终审查认可
23. ⑦ 空转的证据性缺陷只记 ledger,可执行半转交 T11 —— 若判错,最终审查会重提(可见)
24. LVP/NFD 两条 manifest 改回 `${VAR}` 占位 —— 判错则 `--kubespray` 当场红
25. **挂起 trim 隐患**(第三节工单 1;既有问题,非本支引入)
26. **钉子即配置源**(单开 Task 15 关掉"8 个钉子无写入者")—— 若判错,1.36 线缺 tar(D1 已定 1.35.8)
27. ⑯ 加"钉子暂无写入者"警示注释 + 注释指针 285→261 —— 纯注释
28. 接受顺手修 docs 里另 2 处陈旧版本号(kube-vip / haproxy)—— 判错退两处数字即可
29. 容器 conf 补 8 钉子作为投放注意项(不写代码)—— 判错则用户首次部署停一次并读到可操作报错

## 五、两条必须记住的"静默/硬停"语义

- **trim 的删除是静默的**:按"未匹配 PRELOAD"删,ceph 组无 token → 13 个 tar 会被删;跑之前先 `trim-offline-files.sh` 看它的 dry-run/打印(见工单 1)。
- **硬停(有意)有三处**:①`sync-kubespray-config.sh` §3.2 缺钉子 → 停 `k8s_inventory`;②multus tar 内容不符 → 停 `--steps multus`;③kube-vip 镜像 tar 缺失 → `09_kube_vip` 自检 fail-closed。**它们都是设计,不是故障**;报错文案里都带修法。
