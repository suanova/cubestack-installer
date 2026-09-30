# kubespray 按版本部署 + 离线件版本目录(设计 / spec)

> 状态:**设计已确认(2026-09-30),待实施**。实施计划见同目录 `plan.md`(待产出)。
> 关联:补丁层 `docs/kubespray-upgrade.md`(升级 SOP)、离线链路 `docs/harbor-mirror.md`、
> 规范 `docs/scripts-development-spec.md` §7(CI)。

---

## 0. 决策记录(已确认)

| # | 决策 | 结论 |
|---|---|---|
| D1 | 版本目录是否自带源码树 | **自带 `tree.tar.gz`(预打补丁、预验证)**;仓库只保留当前版本的树 |
| D2 | 版本机制的维度 | **两级**:组件各自选版(组件级) + 套装档案 profile 把一组绑成套(套装级) |
| D3 | 版本目录层级 | **两层**:`offline-files/<组件>/<版本>/`(如 `kubespray/v2.32.0/`);fetch 扩展二级选择 |
| D4 | 本次实证范围 | **v2.32 迁入并入库**(档案进 git、资产上 MinIO);**v2.28 仅作本地验证/临时测试**,不入 git、不传 MinIO |
| D5 | 验证边界 | 验到"版本选择 / 路径推导 / 树物化 / 离线预检 / 钉子↔树表值 / 回归套件";**不用 v2.28 重装现集群** |
| D6 | 升级路线 | **独立**:升级 = 原地换仓库树(`cubestack-kubespray-upgrade.sh`),不经版本目录;版本目录也不依赖升级脚本 |
| D7 | operator 迁移 | 本次只**定规范 + kubespray 落地**;其他 operator 按同一规范按需迁移(不做 18 目录大搬家) |

---

## 1. 目标与非目标

### 1.1 目标

1. 一条开关指定 kubespray 版本(如 `v2.32.0` / `v2.28.0`),部署**该版本的 kubernetes 与 operator 组合**。
2. 离线件按**版本目录**组织:**只下载指定版本的离线文件**(不必拖回所有版本)。
3. 多版本**共存**不互相污染(二进制、镜像、包、树、版本钉子各自成套)。
4. 升级仍是独立路线,**不影响全新部署路径**(D6)。
5. 机制做完后**沉淀为规范/skill**,新 operator 及未来新版本按同一套做法接入(D7)。

### 1.2 非目标(明确不做,避免误判)

- **不做** operator 目录的批量迁移(ceph/metax/lws 等仍保持现状,规范先行)。
- **不做**"用版本目录执行升级"(升级不读版本目录;见 §8)。
- **不做** v2.28 的发布级支持:v2.28 只是本地临时版本,用于证机制(不写档案入库、不上 MinIO、不进文档的"支持版本"表)。
- **不做** 集群重装:v2.28 不用于真装一次集群(D5)。
- **不引入** 新依赖(不引入容器仓库式版本分发;仍走文件系统 + MinIO)。

---

## 2. 现状与证据(实测)

### 2.1 硬约束:`local_release_dir` 的扁平语义(不可动摇)

`cubestack-offline.sh:1918-1924` 生成 `group_vars/all/offline.yml`,把 `LOCAL_REPO_DIR` 交给 kubespray 当
`download_cache_dir` / `local_release_dir`;树内 `roles/kubespray_defaults/defaults/main/download.yml` 的
`dest` 全是**扁平文件名**(`{{ local_release_dir }}/kubeadm-{{ kube_version }}-{{ image_arch }}`、
`etcd-…tar.gz`、`cni-plugins-…tgz` …),且 `cubestack-offline.sh:2191` 用
`find "${LOCAL_REPO_DIR}" -maxdepth 1 -type f` 断言"二进制就在这一层内"。

⇒ **`LOCAL_REPO_DIR` 必须恰好是"裸二进制 + `images/` + `packages/`"的那一层**。版本目录方案
(D3)天然满足:把 `LOCAL_REPO_DIR` 指进版本目录即可,**树内零改动**。

### 2.2 `OFFLINE_FILES_DIR` 有两套相反语义 + `CLUSTER_NAME` 幽灵子目录

| 位置 | 语义 | 实际值 |
|---|---|---|
| `lib-common.sh:460`(全仓多数消费者) | **内层**:kubespray 资产目录 | `…/offline-files/kubespray` |
| `cluster.conf.example:495`、`sync-to-minio.sh:87`、`trim-offline-files.sh:34` | **外层**:offline-files 根 | `…/offline-files` |

另有 `lib-common.sh:461-463` 的 `LOCAL_REPO_DIR="${OFFLINE_FILES_DIR}/${CLUSTER_NAME}"` ——
**仓库布局下这一层并不存在**(磁盘上是扁平的),属扁平 standalone 布局的历史遗留
(`cubestack-offline.sh:38-44` 的 `default_local_repo_dir()` 也保留同一分支)。

⚠ 用户按任一侧直觉设一次 `OFFLINE_FILES_DIR`,另一侧就静默走错目录。本设计**顺手收敛**(§4.3)。

### 2.3 MinIO 链路(现状)

- 远端布局 = 本地 `offline-files` 树的**镜像**(`sync-to-minio.sh:5-7,112-115`);键 =
  `${MINIO_ALIAS}/${MINIO_BUCKET}/${MINIO_REMOTE_DIR}`(默认 `minio/cubestack-installer/offline-files`)。
- **上传**:`mc mirror --overwrite`(`sync-to-minio.sh:118-131`)整棵根,**无过滤**;`--prune` →
  `--remove`,**会删远端本地没有的对象**(多版本共存时危险)。
- **下载**:`fetch-offline-from-minio.sh` 只能选**第一层子目录**(`--sub <名>`,`:261-290`),
  无版本/组过滤;路径里**没有任何版本维度**,版本只体现在文件名里。
- 探测回退:`probe_remote()`(`:169-178`)按 `offline-files` → `kubespray` 顺序试探。

### 2.4 不可经变量覆写的字面路径(改造清单来源)

`.dockerignore:40-64`(逐一列扁平文件名的硬清单)、`tools/node/reconcile-node-packages.sh:54-55`、
`modules/03_addon/02_ceph.sh:163-164`(lvm2 通配)、`modules/03_addon/22_verify_registry_storage.sh:74`
(字面 `busybox.tar`)、`tools/offline/sync-to-container.sh:158`、`tools/docker/build-cli-context.sh:97`。

### 2.5 布局探针用"目录名"判定

`cubestack-offline.sh:25`:`[ "$(basename "$(dirname "${BASE_DIR}")")" = "deployments" ]` ⇒ repo 布局。
`BASE_DIR="${CUBESTACK_BASE_DIR:-${SCRIPT_DIR}}"`,而**当前没有任何模块传 `CUBESTACK_BASE_DIR`**
(`06_k8s_deploy.sh:191-193` / `07_k8s_scale.sh:298-301` 只传 `CUBESTACK_KUBESPRAY_DIR`、
`CUBESTACK_INVENTORY_DIR`、`OFFLINE_FILES_DIR`、`CUBESTACK_LOCAL_REPO_DIR`)。

⇒ 物化树一换位置(如 `deployments/kubespray/versions/<V>/`),探针会判成 flat 并**静默走错目录**。
必须修(§5.3)。

### 2.6 v2.28 可回收性(实证)

- 树 + 该版本补丁层:`git tag kubespray-2.28.0-cubestack`(回退法已文档化:
  `git checkout kubespray-2.28.0-cubestack -- deployments/kubespray`,见 `docs/kubespray-upgrade.md` §5)。
- 1.32 线离线件:本机 `/data/offline-superseded-20260928/`(**1.2 GB,33 个文件**)——
  `kubeadm/kubelet/kubectl 1.32.5`、`etcd 3.5.16`、`calico 3.29.3`(bin+ctl+3 镜像)、`coredns 1.11.3`、
  `pause 3.10`、`crictl 1.32.0`、`containerd 2.0.5`、`cni-plugins 1.4.1`、`runc 1.2.6`、`helm 3.16.4`、
  `local-path 0.0.24`、`metrics-server 0.7.0`、`CPA 1.8.8` 等;缺失项按 v2.28 树表值补齐即可。

### 2.7 `trim-offline-files.sh` 的两处问题

① 路径自相矛盾:`:25` source lib-common(→ `OFFLINE_FILES_DIR` = **内层**),`:34-35` 又按**外层**语义拼
`KUBE_DIR="${OFFLINE_ROOT}/kubespray"` ⇒ 得到 `…/offline-files/kubespray/kubespray`,`:37` 的 `[ -d ]`
必报"未找到"。
② 隐含"每目录单版本"假设:`:41`+`:124-127`(按 `PRELOAD_IMAGE_PATTERNS` 删 `kubespray/images/*.tar`)、
`:67-70`+`:143-146`(metax 只留当前版本 tar)⇒ 多版本共存时它会**把别的版本删掉**。

---

## 3. 版本模型

### 3.1 目录规范(组件级,两层)

```
deployments/offline-files/                     ← OFFLINE_FILES_ROOT(git 只跟踪 README)
├── kubespray/
│   ├── v2.32.0/                              ← 在库版本(入库)
│   │   ├── tree.tar.gz                       ← 预打补丁的整树(不含 .venv / inventory/local)
│   │   ├── images/*.tar                      ← 该版本 k8s 基座镜像
│   │   ├── packages/ (+repair/)              ← 离线系统包
│   │   ├── kubeadm-1.35.8-amd64 …            ← 裸二进制(文件名含版本)
│   │   └── VERSION.profile                   ← 档案副本(自包含)
│   └── v2.28.0/                              ← 本地临时版本(D4:不入 git、不上 MinIO)
│       ├── LOCAL_ONLY                        ← 标记:sync-to-minio 自动跳过(§6.1)
│       └── …(同上,但无档案入库)
├── ceph/                                     ← 组件级规范就位,本次不迁移(D7)
└── …
```

- **版本目录名 = kubespray tag 全名**(`v2.32.0`,与 `galaxy.yml version: 2.32.0`、升级脚本的 `<tag>`
  参数、`git tag` 三处一致)。⚠ 待你在评审时确认:你举例写的是 `v2.32`(短名),本设计建议用全 tag
  —— 短名在将来出现 `v2.32.1` 时会歧义。改为一处常量即可切换。
- 组件级规范(`<组件>/<版本>/`)对 operator 同样适用;operator 目录的资产形态由各自模块决定,
  本次只登记规范,不迁移(D7)。

### 3.2 版本档案(profile)

**入库档案**:`deployments/config/profiles/<版本>.profile`(纯文本,shell 可 source,语法同 cluster.conf 片段)。
字段 = 该版本**全部"版本面"变量**:

```
KUBESPRAY_VERSION=v2.32.0
# k8s 基座组(check-modules ⑯ 已断言其与树内表值一致)
K8S_VERSION=v1.35.8  CALICO_VERSION=v3.31.7  ETCD_VERSION=v3.6.14  COREDNS_VERSION=v1.12.4
PAUSE_VERSION=3.10.1  DNS_NODE_CACHE_VERSION=1.25.0  METRICS_SERVER_VERSION=v0.9.0
CPA_VERSION=v1.10.3   API_LB_NGINX_IMAGE_TAG=1.30.1-alpine
LOCAL_VOLUME_PROVISIONER_VERSION=2.5.0  NFD_VERSION=0.19.0
# 该版本配套的 operator 版本(套装级;未列出的组件仍取 cluster.conf 的值)
KUBE_VIP_VERSION=…  METALLB_VERSION=…  CEPH_VERSION=…  METAX_VERSION=…  LWS_IMAGE_TAG=…
```

- 选用:`cluster.conf` 的 `KUBESPRAY_PROFILE="v2.32.0"`(默认 = 仓库当前树版本)或 CLI
  `--profile v2.32.0`(单次覆盖,不写回 cluster.conf)。
- 优先级:**档案 > cluster.conf 的版本面变量**(选定档案即由档案接管版本面)。
  理由(反例):现网 `cluster.conf` 的钉子区很可能带显式值(如 `K8S_VERSION=v1.35.8`);若让 cluster.conf
  优先,`--profile v2.28.0` 会静默变成"用 v2.28 的资产 + 1.35.8 的钉子",部署期才炸。
  ⇒ 选定档案后,版本面变量一律取档案值;`cluster.conf` 里这些行按注释说明"被档案接管"。
- 逃生阀:要手工钉某一项 → `KUBESPRAY_PROFILE=none`(不使用档案,全部按 cluster.conf,行为等价今天)
  或临时 `--profile none`;单次覆盖单项用 CLI (`--set K8S_VERSION=…` 之类)不入本次范围。
- 版本目录内的 `VERSION.profile` 是**副本**(便于离线自包含与"这台机器没这份档案"时的自检);
  两者不一致时以入库档案为准并报警(§7.1)。

### 3.3 三种版本档位

| 档位 | 档案入库 | 资产在 MinIO | 典型用途 |
|---|---|---|---|
| **在库版本** | ✅ | ✅ | 交付/生产:如 v2.32.0 |
| **本地临时版本** | ❌(不写档案入库) | ❌(`LOCAL_ONLY` 标记) | 本地验证/回归/应急调试:如本次的 v2.28.0 |
| **仓库当前树** | ✅(即当前版本档案) | ✅ | 开发迭代(树随 git 走) |

### 3.4 唯一性约束

同一组件的两个版本目录**互不共享**资产(宁可重复几百 MB,不要隐式依赖);`images/` 内只放该版本
镜像 ⇒ 顺带消除"两个 k8s 线的 tar 同名规则都被 `PRELOAD_IMAGE_PATTERNS` 命中、一起推到节点"的浪费。

---

## 4. 变量与路径推导

### 4.1 变量表

| 变量 | 语义 | 默认值 | 变化 |
|---|---|---|---|
| `OFFLINE_FILES_ROOT` | offline-files **真根** | `${REPO_ROOT}/deployments/offline-files` | **新增** |
| `KUBESPRAY_VERSION` | 版本开关(单一入口) | 仓库当前树版本(从 `galaxy.yml` 派生) | **新增** |
| `KUBESPRAY_PROFILE` | 套装档案名 | `${KUBESPRAY_VERSION}` | **新增** |
| `OFFLINE_FILES_DIR` | **k8s 资产目录**(版本目录) | `${OFFLINE_FILES_ROOT}/kubespray/${KUBESPRAY_VERSION}` | 语义统一(原"内层") |
| `LOCAL_REPO_DIR` | 交给 kubespray 的资产目录 | `= ${OFFLINE_FILES_DIR}` | 收敛(去掉 `${CLUSTER_NAME}`) |
| `KUBESPRAY_DIR` | 源码树目录 | V == 仓库树版本 → 仓库树;否则物化树 | 派生 |
| `KUBESPRAY_BASE_DIR` | cubestack-offline.sh 的运行根 | 物化版本 → `versions/<V>`;否则 `deployments/kubespray` | **新增**(替换名字探针) |

### 4.2 推导链(单一开关 → 全部落点)

```
KUBESPRAY_VERSION=v2.28.0
  ├─ KUBESPRAY_PROFILE=v2.28.0 ──→ deployments/config/profiles/v2.28.0.profile(若在库)
  ├─ OFFLINE_FILES_DIR=${OFFLINE_FILES_ROOT}/kubespray/v2.28.0   (二进制/images/packages)
  ├─ LOCAL_REPO_DIR=${OFFLINE_FILES_DIR}                          (→ offline.yml)
  ├─ KUBESPRAY_DIR=<仓库树> 或 deployments/kubespray/versions/v2.28.0/kubespray
  └─ KUBESPRAY_BASE_DIR=…(同上,供 cubestack-offline.sh)
```

### 4.3 语义收敛(顺带修 2.2)

- `lib-common.sh:460-463`:改为 `OFFLINE_FILES_DIR=${OFFLINE_FILES_ROOT}/kubespray/${KUBESPRAY_VERSION}`、
  `LOCAL_REPO_DIR="${OFFLINE_FILES_DIR}"` —— **删掉 `${CLUSTER_NAME}` 幽灵层**(它在仓库布局下不存在,
  且是"下载成功但部署找不到文件"这类事故的温床)。
- `cluster.conf.example:495` 的推导同步改写;`sync-to-minio.sh` / `trim-offline-files.sh` /
  `cubestack-offline.sh` 的"外层语义"统一改用 `OFFLINE_FILES_ROOT`。
- ⚠ 兼容:`OFFLINE_FILES_DIR` 若被用户**显式设置**(运维脚本/容器挂载),保持最高优先级不覆盖。

---

## 5. 树物化与运行根

### 5.1 两条路

| 场景 | 用哪棵树 |
|---|---|
| 版本 == 仓库当前树版本 | **仓库树**`deployments/kubespray/kubespray`(现状不变,零物化) |
| 版本 ≠ 仓库树版本 | **物化树**:从 `${OFFLINE_FILES_ROOT}/kubespray/<V>/tree.tar.gz` 解到 `deployments/kubespray/versions/<V>/` |

### 5.2 物化树结构

```
deployments/kubespray/versions/v2.28.0/       ← .gitignore 忽略整个 versions/
└── kubespray/                               ← tree.tar.gz 解开(= 树 + patch-playbooks)
    ├── cluster.yml / playbooks/ / roles/ …
    ├── patch-playbooks/                     ← 我们自持的注入 play(随 tar 一起分发)
    └── .venv/                               ← **不在 tar 内**,由 ensure_venv 在物化后按需重建
```

- tar 内**不含** `.venv`(机器相关、体积大)与 `inventory/local`(上层用仓库外置的实盘 inventory)。
- tar 由 `cubestack-version-dir.sh new` 产出:取该 tag 纯净树 → 重放该版本补丁层 → `--check` 通过 → 打包
  并记录 `sha256` 到 `tree.tar.gz.sha256`(自检用)。

### 5.3 修布局探针(必须)

`cubestack-offline.sh` 的"父目录名 == deployments"判定换成**显式变量**:
`KUBESPRAY_BASE_DIR`(默认:仓库树 → `SCRIPT_DIR`;物化树 → `versions/<V>`)+
`CUBESTACK_LAYOUT` 显式覆盖(repo|flat)。模块 `06_k8s_deploy.sh` / `07_k8s_scale.sh` 把
`CUBESTACK_BASE_DIR` 一并传入(今天没人传,靠 `SCRIPT_DIR` 兜着 —— 这正是物化后会静默走错的原因)。

---

## 6. 离线链路(MinIO)

### 6.1 上传

- `sync-to-minio.sh` 增加**本地临时版本排除**:扫 `<组件>/<版本>/LOCAL_ONLY` 标记,自动跳过并在日志
  里点名(直接服务 D4 的"v2.28 不传 MinIO")。
- `--prune`(`--remove`)跨版本互删风险处置:**默认只作用于显式 `--sub <路径>` 的子树**;不带 `--sub`
  的全根 prune 需显式 `--force-full-prune`(并在执行前打印"将删除远端 N 个对象"清单待确认)。

### 6.2 下载

- `fetch-offline-from-minio.sh` 支持**二级/嵌套选择**:把 `--sub` 的"仅第一层精确名"放宽为任意相对路径
  (`mc_has` + `mc mirror` 本就支持嵌套),并新增糖 `--kubespray-version v2.32.0`
  ≡ `--sub kubespray/v2.32.0`;`--list` 输出到二级。
- 保持"只增不删"语义(无 `--remove`)不变。

### 6.3 `trim-offline-files.sh` 修复

① 路径按 §4.3 统一(`OFFLINE_FILES_ROOT` + 版本目录);
② 删除动作**限定在选定版本目录内**(默认 = `KUBESPRAY_VERSION`,新增 `--version <V>`);
③ 若检测到同组件存在多个版本目录,启动时打印告警并列出"本次不会触碰"的版本。
（②③ 同时消除 2.7 的两处隐患。）

### 6.4 `.gitignore`

`deployments/offline-files/*/README.md` → 增加 `!deployments/offline-files/*/*/README.md`
(版本目录内的 README 也要能被跟踪);`deployments/kubespray/versions/` 整目录忽略。

### 6.5 `images.manifest` 的版本感知

清单格式不变(`<group> <ref> [tar]`,`ref` 用 `${VAR}` 引用 cluster.conf/档案的版本变量);
变化在**落点**:`lib-image-manifest.sh` 的 `image_group_dir()` 对 `k8s-base` 组返回
`${OFFLINE_FILES_ROOT}/kubespray/${KUBESPRAY_VERSION}/images`;`check-image-manifest.sh`
新增 `--kubespray-version <V>`(默认取当前档案)用于逐版本核对目录与 README。

---

## 7. 校验与回归

### 7.1 `check-modules.sh` 扩展

- ⑯(**现:钉子 vs 仓库树表值**)→ 升级为**逐版本**:
  - 在库档案 ↔ 仓库树表值(现行为,新增"档案存在时以档案为准"分支);
  - **在场**的每个版本目录(有 `tree.tar.gz` 时解到临时目录;或 `versions/<V>/kubespray` 已物化时直读)
    断言:该版本资产目录里的**二进制/镜像文件名 ↔ 该版本树表值**(如 `kubeadm-${K8S_VERSION}-amd64`
    在目录里存在、`etcd-…` 版本与表一致);
  - 无任何版本目录时**跳过**(CI 常态,不误报)。
- 新增 ⑱:版本目录自检(`tree.tar.gz` 的 sha256 匹配、`VERSION.profile` 与入库档案一致或告警、
  `LOCAL_ONLY` 标记与"是否在 MinIO 目录清单里"不矛盾)。

### 7.2 新回归套件(离线、无集群)

`tools/tests/test-kubespray-version-select.sh`,fixture 驱动:
① 版本开关 → `OFFLINE_FILES_DIR` / `LOCAL_REPO_DIR` / `KUBESPRAY_BASE_DIR` / 树选择推导正确;
② `V == 仓库树` 与 `V ≠ 仓库树` 两条分支各自命中正确树;
③ cluster.conf 的版本面显式值**被档案接管**(不得静默混用);
④ `KUBESPRAY_PROFILE=none` 时完全按 cluster.conf(等价今天的行为);
⑤ 缺版本目录时预检**响亮失败**(不得静默回退到当前版本);
⑥ 档案缺字段时的行为(落到"仓库树表值"默认,而非空值)。
挂进 `check-modules.sh` ⑮ 的套件清单 ⇒ 新 CI 每次 PR 自动跑。

### 7.3 `cubestack-version-dir.sh verify <V>`

tar 指纹、树表值 ↔ 档案、资产齐套(`check_offline_files` 口径)、`LOCAL_ONLY` 一致性 —— 一键给结论。

---

## 8. 升级路线边界(D6)

```
                           ┌─────────────────────────────┐
  全新部署(选版本)  ────► │ 读档案 → 资产目录 → 树 → 安装 │
                           └─────────────────────────────┘
                                       ▲ 互不依赖
                           ┌─────────────────────────────┐
  升级(换版本)      ────► │ cubestack-kubespray-upgrade  │  原地换仓库树 + 重放补丁
                           │ (仓库树 = 目标版本)           │  (docs/kubespray-upgrade.md SOP)
                           └─────────────────────────────┘
```

- **交叉场景**:"v2.28 装的集群要上 v2.32" → 走**升级路线**(换仓库树,Masters 滚动),不是"再选一次版本"。
  升级完成后集群即处于仓库树版本;后续部署沿用该版本档案。
- **为什么不做"用版本目录升级"**:升级的核心风险在**在跑的集群**与补丁层重放,不在资产获取;把资产获取
  与集群变更耦合会让两条路线的失败面互相污染(违背 D6 的"不互相影响")。
- 版本目录方案**不改变**升级 SOP 的任何一步;`cubestack-kubespray-upgrade.sh` 本次**不改**(仅在其文档
  里补一段"与版本目录的关系")。

---

## 9. 版本目录产出流程(将沉淀为 skill)

### 9.1 工具:`deployments/kubespray/cubestack-version-dir.sh`

| 子命令 | 作用 |
|---|---|
| `new <tag> [--local] [--tree-src DIR] [--assets-from DIR]` | 造版本目录:取纯净树 → 重放该版本补丁 → `--check` → 打 `tree.tar.gz`(+sha256) → 建骨架 + `VERSION.profile`(骨架值从该树表值**机械推导**,不靠人抄) → `--local` 时落 `LOCAL_ONLY` |
| `verify <V>` | §7.3 的全部断言 |
| `list` | 列出在场版本目录、档位(在库/本地临时)、资产是否齐套 |
| `materialize <V>` | 解 `tree.tar.gz` 到 `versions/<V>/`(幂等;已存在且指纹一致则跳过) |

### 9.2 一次产出的完整步骤(以未来 v2.33 为例)

1. `cubestack-version-dir.sh new v2.33.0 --tree-src <纯净树>`(或联网取 tag);
2. 按该树表值补齐资产(二进制/包/镜像;`harbor-save-images.sh --group k8s-base --kubespray-version v2.33.0`);
3. `cubestack-version-dir.sh verify v2.33.0` 全绿;
4. 写 `deployments/config/profiles/v2.33.0.profile` 并入库(commit);
5. `sync-to-minio.sh` 上传;
6. `check-modules.sh` 全绿 ⇒ 提 PR(CI 自动跑)。

### 9.3 operator 迁移规范(未来,D7)

对任一 operator:`offline-files/<组件>/<版本>/` + 版本开关变量 + 档案字段 + `images.manifest` 落点 +
`verify_<组件>` 里的资产路径;四条一起改,由 §7 的校验兜底。**本规范将写入 skill**
(`.claude/skills/cubestack-deploy-scripts/`,并新增"新增/迁移一个版本"小节)。

---

## 10. 实施与验证边界

### 10.1 阶段(细化见 `plan.md`)

1. 变量与推导(§4)+ 布局探针(§5.3)+ 回归套件骨架;
2. 树物化与 `cubestack-version-dir.sh`(§5/§9.1);
3. 档案机制(§3.2)与 ⑯ 扩展(§7.1);
4. v2.32 迁入(资产 + 档案入库 + MinIO 上传);
5. v2.28 本地临时版本产出 + 机制验证(D4/D5);
6. 离线链路修复(§6)+ 文档/skill 沉淀(§9.3)。

### 10.2 验证矩阵

| 项 | 怎么验 | 本次是否验 |
|---|---|---|
| 版本推导/选择/优先级 | 回归套件 + 实跑 `--list-steps`/预检 | ✅ |
| 树物化 | `materialize` v2.28 + `--check` 该树补丁在位 | ✅ |
| 资产齐套(两版本) | `verify` + `check_offline_files` 预检 | ✅ |
| 钉子↔树表值(两版本) | check-modules ⑯ 逐版本 | ✅ |
| MinIO 二级下载/排除本地临时版本 | `--list` + dry-run(`--dry-run`) | ✅(真传只有 v2.32) |
| **v2.28 真装一次集群** | — | ❌(D5,不碰现集群) |
| 升级 SOP | `--check` 级(不改升级脚本) | ✅(仅回归) |

### 10.3 风险与回滚

| 风险 | 处置 |
|---|---|
| `OFFLINE_FILES_DIR` 语义切换打破既有调用 | 保留显式设置的最高优先级;⑯/预检覆盖;CI 跑全量静态校验 |
| 物化树被误提交 | `versions/` 整目录 gitignore + ⑦ 类检查(凭据卫生同款断言) |
| 上传 `--prune` 误删远端他版本 | §6.1 的默认收窄 + `--force-full-prune` 显式确认 |
| v2.28 目录被误当"受支持版本" | `LOCAL_ONLY` 标记 + 文档明确(§1.2)+ `list` 标注档位 |
| 回滚 | 变量与档案机制是**新增**,默认值等价今天行为(仓库树 + 当前资产目录);回滚 = 删 `versions/` 与档案,`git revert` 相关提交 |

---

## 11. 影响面清单(改动点)

| 文件 | 改什么 | 依据 |
|---|---|---|
| `config/cluster.conf.example` | 新增 `OFFLINE_FILES_ROOT`/`KUBESPRAY_VERSION`/`KUBESPRAY_PROFILE`;`LOCAL_REPO_DIR` 推导改写 | §4.1 |
| `config/profiles/v2.32.0.profile` | **新增**(入库档案) | §3.2 |
| `scripts/lib-common.sh` | ①`OFFLINE_FILES_DIR` 推导 ②删 `${CLUSTER_NAME}` 幽灵 ③`KUBESPRAY_BASE_DIR` 派生 | §4.3 |
| `scripts/modules/02_k8s/06_k8s_deploy.sh`、`07_k8s_scale.sh` | 传 `CUBESTACK_BASE_DIR`(+档案环境) | §5.3 |
| `kubespray/cubestack-offline.sh` | 布局探针 → 显式变量;`KUBESPRAY_VERSION` 常量(第 43 行 `v2.28.0` 早已过期)改为派生 | §5.3、§2.5 |
| `kubespray/cubestack-version-dir.sh` | **新增**(new/verify/list/materialize) | §9.1 |
| `scripts/tools/offline/sync-to-minio.sh` | `LOCAL_ONLY` 排除;prune 收窄/`--force-full-prune` | §6.1 |
| `scripts/tools/offline/fetch-offline-from-minio.sh` | 嵌套 `--sub` + `--kubespray-version` + `--list` 二级 | §6.2 |
| `scripts/tools/offline/trim-offline-files.sh` | 路径统一 + 限定版本目录 + 多版本告警 | §6.3 |
| `scripts/tools/images/lib-image-manifest.sh`、`check-image-manifest.sh` | `k8s-base` 落点带版本;`--kubespray-version` | §6.5 |
| `scripts/tools/images/harbor-save-images.sh` | 落点跟随版本目录 | §6.5 |
| `scripts/tools/check-modules.sh` | ⑯ 逐版本;新增 ⑱ 版本目录自检;⑮ 挂新套件 | §7.1 |
| `scripts/tools/tests/test-kubespray-version-select.sh` | **新增**回归套件 | §7.2 |
| 字面路径 6 处(§2.4) | 改为经变量;`.dockerignore` 补新路径 | §2.4 |
| `.gitignore` | 两层 README 放行 + `versions/` 忽略 | §6.4 |
| `docs/kubespray-upgrade.md` | 补"与版本目录的关系"一节(不改 SOP) | §8 |
| `docs/scripts-development-spec.md` + skill | 版本规范 + 新 operator 接入步骤 | §9.3 |
| `docs/kubespray-versioning/README.md` | 使用手册(怎么选版本/怎么产出新版本/怎么上 MinIO) | — |

---

## 附:术语

| 词 | 含义 |
|---|---|
| **版本目录** | `offline-files/<组件>/<版本>/`,自包含该版本的资产(可选自带树 tar) |
| **档案(profile)** | 入库的版本值集合文件,`deployments/config/profiles/<版本>.profile` |
| **在库版本** | 档案进 git + 资产在 MinIO |
| **本地临时版本** | 只在本机存在(`LOCAL_ONLY`),用于验证/应急,不入库不上传 |
| **物化树** | 由 `tree.tar.gz` 解出的可运行树,位于 `deployments/kubespray/versions/<V>/` |
