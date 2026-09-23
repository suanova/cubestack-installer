# Harbor 统一镜像源(mirrors)

> **一句话**: 本仓库部署所需的**全部上游原始镜像**统一收敛到 `harbor.isuanova.com/mirrors/**`;
> 部署机只认 Harbor 一个源, 由它拉成离线 tar 再推入集群内置 registry —— 集群**永远不需要访问公网**。

---

## 1. 为什么要这样做

在此之前, 每个组件各有一套 `*_save-images.sh`, **各自直连上游**:

| 问题 | 表现 |
|---|---|
| 上游可达性不可控 | `registry.k8s.io` 会 302 到 `pkg.dev`, 国内网络经常超时; `docker.io` 间歇性不可达 |
| 上游 tag 会漂移 | `:latest` / `0.1.0-latest` 类 tag 内容随时可能变, 昨天的 tar 今天对不上 |
| 上游会删 tag / 迁仓库 | RDMA 插件从 Docker Hub 迁到 `ghcr.io/mellanox`; 老脚本 5 次重试全 404 |
| 限流 | Docker Hub 匿名拉取有速率限制, CI 里批量拉容易 429 |
| 离线机无法复现 | 想在完全隔离的机器上重新备料, 得先把七八个脚本的源都改一遍 |

**解法**: 用一台内网 Harbor 做**唯一中介**。上游怎么变都只影响 CI 那一段;
部署机与集群只跟 Harbor 打交道, 且 Harbor 上的路径**由清单机械推导**, 不会歧义。

---

## 2. 制品流向(全链)

```
         ┌──────────────┐   ①harbor-sync-images.sh   ┌───────────────────────────┐
上游镜像  │ docker.io    │ ─────────────────────────▶ │ harbor.isuanova.com       │
         │ quay.io      │   (CI / 联网机; 增量按digest) │   /mirrors/<注册域>/<路径>  │
         │ registry.k8s.io│                          └───────────────────────────┘
         │ ghcr.io      │                                          │
         └──────────────┘                                          │ ②harbor-save-images.sh
                                                                   │   (联网机 / 部署机)
                                                                   ▼
                                                     ┌───────────────────────────┐
                                                     │ deployments/offline-files/ │
                                                     │   <group>/<repo>_<tag>.tar │
                                                     └───────────────────────────┘
                                                                   │ ③部署模块 (skopeo push)
                                                                   ▼
                                                     ┌───────────────────────────┐
                                                     │ 集群内置 registry           │
                                                     │  registry.cubestack.io:5000│
                                                     └───────────────────────────┘
                                                                   │ ④节点 containerd pull
                                                                   ▼
                                                              K8s 工作负载
```

- **①上游 → Harbor**: 只在 CI 或联网准备机发生。跑一次之后, 后续部署再不需要上游。
- **②Harbor → 离线 tar**: `offline-files/` 下的 tar 就是"可以拷来拷去的离线包"。
- **③推入内置 registry**: 由各部署模块负责(见各模块 `skopeo copy docker-archive:`), 节点只从这里拉。
- **④**: 节点侧无需任何 Harbor 凭据。

---

## 3. Harbor 路径规范

**唯一规则**(实现在 `lib-image-manifest.sh` 的 `image_mirror_ref`):

| 上游 ref | Harbor 目标 |
|---|---|
| `docker.io/rook/ceph:v20.2.2` | `harbor.isuanova.com/mirrors/docker.io/rook/ceph:v20.2.2` |
| `quay.io/ceph/ceph:v20.2.2` | `harbor.isuanova.com/mirrors/quay.io/ceph/ceph:v20.2.2` |
| `registry.k8s.io/pause:3.10` | `harbor.isuanova.com/mirrors/registry.k8s.io/pause:3.10` |
| `harbor.isuanova.com/metax/gpu-label:x` | `harbor.isuanova.com/mirrors/metax/gpu-label:x` ⟵ 同台 Harbor, 去掉域名前缀 |

**为什么要保留注册域**(而不是把 `docker.io/rook/ceph` 压成 `rook/ceph`):

1. **零歧义**: 上游 ref 是 Harbor 路径的**后缀**, 因此"离线 tar 按上游 ref 命名"这个约定
   (既有模块靠 `*<repo>_<tag>.tar` 通配查找)可以**零改动**沿用;
2. **不撞车**: 不同注册域下的同名仓库(如 `docker.io/rook/ceph` 与 `quay.io/rook/ceph`)各占独立路径。

> 项目名固定 `mirrors`(`HARBOR_MIRROR_PROJECT`)。仓库(repository)在首次 push 时由 Harbor
> 自动创建; **项目**(project)必须预先存在 —— `harbor-sync-images.sh` 会自动建(公开只读,
> 便于部署机匿名拉取)。

### ⚠ 特例: "上游就是本台 Harbor"的组不镜像

`metax-gpu`(12 个)的**上游就是这台 Harbor 本身** (`harbor.isuanova.com/metax/` 项目),
属于**同台复制**。它的部署模块现在就直接从那个项目拉取 —— 也就是说,
**"集群不访公网"这个目标对它已经达成**, 不需要任何改动。

再复制一份到 `mirrors/` 只会:

- 多占一份存储(实测 **8.4 GB**, 其中 `maca` 5.3 GB、`driver-image` 1.15 GB);
- 每次升级 metax 版本都要重跑一次复制;
- 若走 CI(GitHub runner)还要把 GB 级镜像先下载到 runner 再传回同一台 Harbor, 纯浪费带宽。

因此**默认跳过**。判据是**推导**出来的(该 ref 的注册域 == `HARBOR_MIRROR_REGISTRY`),
不是硬编码名单 —— 将来某个组件改成从公网拉, 它会自动重新进入镜像范围。

跳过是**显式报告**的(汇总里逐个列出), 不会造成"看起来全同步了"的错觉。
真要那份副本:

```bash
./harbor-sync-images.sh --include-same-harbor --group metax-gpu
```

> 它仍**列在清单里** —— 清单同时承担"本仓库用到哪些镜像"的登记职责,
> 只是不会被镜像到 `mirrors/`。`check-image-manifest.sh --harbor` 同样跳过它,
> 否则每次漂移检查都会把 12 个"永远不该出现"的镜像报成缺失, 噪声淹没真问题。

---

## 4. 镜像清单(唯一数据源)

**`deployments/config/images.manifest`** —— 本仓库所有需下载镜像的**唯一**声明处。

```
<group>   <上游镜像 ref>   [tar 文件名覆盖]
```

- 第 1 列 `group` → 离线目录 `deployments/offline-files/<group>/`
  (例外: `k8s-base` 与 `ceph` → `offline-files/kubespray/images/`, 因为节点走 kubespray 预加载);
- 第 2 列 ref 支持 `${VAR}` 占位, **变量取值来自 `cluster.conf`**
  (CI 上没有 `cluster.conf` 时自动回退 `cluster.conf.example` 的内置默认值);
- 第 3 列可选, 仅用于"历史短名"镜像(`busybox.tar` / `nginx.tar` —— 既有模块按字面文件名读取),
  这类 tar 不能按 ref 改名。

### 加一个新镜像要改哪里

1. `cluster.conf.example` 声明版本变量(如 `MYAPP_VERSION="${MYAPP_VERSION:-v1.2.3}"`);
2. `images.manifest` 加一行: `myapp  docker.io/acme/myapp:${MYAPP_VERSION}`;
3. `bash tools/images/check-image-manifest.sh` 过一遍静态校验;
4. 跑一次同步(CI 或 `harbor-sync-images.sh`)即可。

**不需要**改任何部署模块的镜像匹配逻辑 —— 文件名后缀规则保证了兼容。

---

## 5. 三个工具

都在 `deployments/scripts/tools/images/`。

### `harbor-sync-images.sh` — 上游 → Harbor(CI / 联网机)

```bash
./harbor-sync-images.sh                      # 全部(增量: digest 相同则跳过)
./harbor-sync-images.sh --list               # 只列清单(不联网)
./harbor-sync-images.sh --group ceph,rdma
./harbor-sync-images.sh --exclude-group metax-gpu
./harbor-sync-images.sh --include-same-harbor # 连"上游就是本台 Harbor"的也镜像(默认不镜像, 见 §3)
./harbor-sync-images.sh --platform amd64     # 单架构(默认 --all 保留多架构 manifest list)
./harbor-sync-images.sh --force              # 忽略 digest 强制重传
```

凭据: `HARBOR_MIRROR_USER` / `HARBOR_MIRROR_PASSWORD`
(不传则匿名 —— 但**建项目必须登录**)。凭据会写进 600 权限的临时 auth 文件, 退出即删,
**不进 argv、不进日志**。

### `harbor-save-images.sh` — Harbor → 离线 tar(联网机 / 部署机)

```bash
sudo ./harbor-save-images.sh                 # 全部 → 各组件 offline-files 子目录
sudo ./harbor-save-images.sh --group ceph
sudo ./harbor-save-images.sh --force         # 覆盖已有 tar
sudo ./harbor-save-images.sh --from-upstream # 绕过 Harbor, 直连上游(应急)
```

- 默认匿名(项目公开只读), 不需要在部署机分发凭据;
- 已有 tar 默认**跳过**, 只补缺;
- 镜像源由 `cluster.conf` 的 `HARBOR_MIRROR_ENABLED` 控制(默认 `true`)。

### `check-image-manifest.sh` — 清单校验(CI 门禁)

```bash
bash ./check-image-manifest.sh                # 静态: 格式/变量/重复/目录(离线, 快)
bash ./check-image-manifest.sh --kubespray    # 额外: 与 PRELOAD_IMAGE_PATTERNS 交叉核对
bash ./check-image-manifest.sh --harbor       # 额外: 比对 Harbor 现状, 列出漂移项
```

> ⚠ 第 ④ 项是**拼路径**检查: 只验证"能从 group 推出离线目录路径",**不检查目录是否存在**
> (目录要跑过 `harbor-save-images.sh` 才出现, 拿存在性当硬门禁会误伤部署机/CI)。
> 目录与 README 的真实就位情况由 **④b 软检查**提示(只 `warn`, 不影响退出码),
> 规则见 [`scripts-development-spec.md` §2.5](scripts-development-spec.md)。

`--kubespray` 那一项**真的抓到过问题**: `nginx` 曾被放进 `k8s-base` 组, 而它不在
`tools/offline/trim-offline-files.sh` 的 `PRELOAD_IMAGE_PATTERNS` 里 → 备料后会被 trim
静默删掉。两个列表**必须同步**。

---

## 6. CI 工作流与凭据(加密存储)

`.github/workflows/sync-images-to-harbor.yml`

| 触发 | 说明 |
|---|---|
| `push` 到 main 且改动清单/版本/工具 | 自动增量同步 |
| `workflow_dispatch` | 可指定分组 / 强制 / 单架构 / dry-run |
| `schedule`(每周一 03:23 UTC) | 兜底刷新, 捕获 `:latest` 类浮动 tag 的上游更新 |

### 配置凭据(必须, 否则工作流第一步就失败)

仓库 **Settings → Secrets and variables → Actions**:

| 名称 | 类型 | 值 |
|---|---|---|
| `HARBOR_MIRROR_PASSWORD` | **Secret**(加密) | Harbor 密码/token |
| `HARBOR_MIRROR_USER` | Secret 或 Variable | Harbor 用户名 |

> 密码**只放 Secrets**(加密存储、日志自动脱敏)。用户名非敏感, 放 Variable 亦可。
> 凭据不出现在工作流文件、不进仓库、不进 argv(脚本内写 600 权限临时 auth 文件)。

工作流有两个 job:

1. `validate` —— 跑 `check-image-manifest.sh --kubespray`(**不联网**), 清单错了根本不浪费带宽;
2. `sync` —— 校验 → 确认凭据 → `docker/login-action` 登录(参考 `suanova/cuberouter` 的
   `release.yml`: 提前登录, 凭据错在这里明确失败) → 装 skopeo → 同步 → 复查漂移写进 Job Summary。

---

## 7. ★ 升级怎么做(设计要点)

**目标: 版本只有一处真相, 升级是一条直线。**

### 设计

```
cluster.conf  ──(唯一版本真相)──▶  images.manifest ${VAR}  ──▶  三个工具 + CI
   ▲                                                                    │
   └──────────────── 改这里一处, 下游全部自动跟随 ◀────────────────────┘
```

- 版本**只声明在 `cluster.conf`**(`CEPH_VERSION`、`LWS_CHART_VERSION`、`K8S_VERSION` …);
- `images.manifest` 用 `${VAR}` 引用, 不重复写死版本;
- 三个工具与 CI 都从清单读 —— 所以**改一处, 全链跟随**;
- 新增的版本变量集中在 `cluster.conf.example` 的 **3.3 节「镜像版本(★ 升级入口)」**。

### 升级某个组件(以 ceph 为例)

```bash
# ① 改版本(cluster.conf 一处)
#    CEPH_VERSION="v20.2.3"
# ② 校验清单仍自洽
bash deployments/scripts/tools/images/check-image-manifest.sh --kubespray
# ③ 同步到 Harbor(CI 会随 push 自动做; 也可本地跑)
./deployments/scripts/tools/images/harbor-sync-images.sh --group ceph
# ④ 拉成离线 tar
sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group ceph --force
# ⑤ 重新部署(模块同步新 tar 到存储节点并 ctr import + apply manifest)
sudo ./deploy-cluster.sh --steps ceph,ceph_csi
# ⑥ 验证存储真的可用
sudo ./deploy-cluster.sh --steps verify_ceph
```

第 ④ 步的 `--force` 是必要的: 文件名按 `<repo>_<tag>.tar` 生成, **tag 变了文件名就变**,
正常情况下不会撞名; 但若你**原地改 tag 内容**(同 tag 换内容, 只有浮动 tag 才会这样),
必须 `--force` 才不会命中"已存在"跳过。

### 升级 K8s 基座

`K8S_VERSION`、`CALICO_VERSION`、`ETCD_VERSION` 等一组变量在 `cluster.conf.example` 3.3 节。
⚠ 这些**必须与 kubespray 实际解析出的版本一致** —— 改了必须重跑 `k8s_deploy`,
并同步 `tools/offline/trim-offline-files.sh` 的 `PRELOAD_IMAGE_PATTERNS`
(用 `check-image-manifest.sh --kubespray` 兜底检查)。

### 浮动 tag 的处理

`:latest`、`0.1.0-latest` 这类 tag **内容会变而 tag 不变**:

- `harbor-sync-images.sh` **默认就会比 digest**, 变了自动重传(不需要 `--force`);
- 每周定时工作流专门兜底刷新这类 tag;
- 但离线 tar 的**文件名不变** → 第 ④ 步必须 `--force` 才能覆盖旧 tar。

---

## 8. 踩过的坑(实现时务必注意)

| 症状 | 根因 | 处理 |
|---|---|---|
| skopeo 连公开镜像都 fatal `reading JSON file "/run/containers/<uid>/auth.json": permission denied` | skopeo 默认 auth 文件路径在容器内/非 root 下不可读 | 显式设 `REGISTRY_AUTH_FILE` 指向自己可控的 600 文件(工具已内建) |
| `skopeo inspect` 报 `unknown flag: --src-tls-verify` 且被 `2>/dev/null` 吞掉 → digest 永远取不到, 每次全量重传 | `copy` 用 `--src-tls-verify`/`--dest-tls-verify`, **`inspect` 用 `--tls-verify`(单数)** | 两套参数分开维护(工具已内建) |
| Harbor 漂移检查把**已存在**的镜像全报"缺失" | Harbor API 的 repository 名要**双重 URL 编码**(`%252F`), 且路径里**不含项目前缀** | 见 `check-image-manifest.sh` 的 `enc_repo` |
| 离线 tar 的 `RepoTags` 为空 → 模块的 `tar_first_image_tag` 识别不出内容 | `skopeo copy ... docker-archive:<file>` **末尾必须带 `:<ref>`**, 否则不写 RepoTags | 工具写 `docker-archive:<file>:<上游 ref>` |
| Harbor 项目不存在, push 失败 | Harbor 只在 push 时自动建**仓库**, **项目**必须预建 | `harbor-sync-images.sh` 自动建(需凭据; 匿名会 401) |
| 清单里的镜像被 `trim-offline-files.sh` 静默删掉 | 与 `PRELOAD_IMAGE_PATTERNS` 不同步 | `check-image-manifest.sh --kubespray` 交叉核对 |

---

## 9. 实测记录(2026-09-18)

在 `suanova/cubestack-installer` 的 GitHub Actions 上跑通, **Harbor 现状由独立代码路径复核**
(直接查 Harbor API, 不看同步脚本自己的输出):

| Run | 模式 | 结果 |
|---|---|---|
| `35318517294` | push | ❌ 卡在 Harbor 登录 —— 密钥值错误(见下"踩坑") |
| `35318757075` | 手动 `groups=lws,multus` | ✅ 4m16s, 2 个镜像真实落库 |
| `35319233170` | push(全量) | ✅ 43 min,**新同步 43 个 / digest 未变跳过 4 个 / 失败 0**, 另 16 个同台复制按预期跳过 |
| `35323314387` | push | ✅ 5m45s,**跳过 46 / 新同步 1** —— 仍是 pause:3.10 被重传 |
| `35324836924` | push(`--preserve-digests`) | ✅ 仍有 1 次重传(= 用新旗标重新落地的那一次, **属预期**) |
| `35325640510` | push | ✅ **新同步 0 个, 全部 47 个 digest 未变跳过** ⇒ 幂等达成 |

最终态(用 `check-image-manifest.sh --harbor` 复核):

```
✅ Harbor 已含清单内全部应镜像的 35 个镜像(无漂移)
   已跳过 12 个"本就在本台 Harbor 上"的镜像(metax; 预期不镜像)
```

> ⚠ 上表是当时的 CI 实测记录(Run ID 可查), 其中"47 / 16"对应当次运行时的清单规模;
> 清单后续有增减(组件上架/下架), 当前值以实际运行输出为准。

**关键旁证**: `registry.k8s.io/pause:3.10` 从本机同步**失败**(该域名会 302 到
`europe-west3-docker.pkg.dev`, 本机不可达), 但 GitHub runner **成功了** ——
这正是"把镜像准备搬到一个可达的环境里做"的价值所在。

**过程中修掉的两个真问题**(详见 `docs/troubleshooting.md` §四.3.6 / §四.3.7):

1. **密钥设错**: `gh secret set --body -` 会把字面量 `-` 存成密钥值(见下)。
2. **多架构镜像被重写导致每次重传**: `skopeo copy` 搬运多架构镜像时会重写 manifest list 的
   序列化, 落地 digest ≠ 源 digest ⇒ 比对永不相等 ⇒ 每次整包重传(受害者
   `registry.k8s.io/pause:3.10`, 552 MB / 每次 64 秒)。加 `--preserve-digests` 根治,
   库 digest 由 `e9622b01…` 变为源的 `ee6521f2…`。
   > ⚠ **验证时机**: 要在**加了旗标那轮重传之后的下一轮**看结果。做重传的那一轮必然仍打印
   > "不一致"(它读的是旧制品), 第一轮曾据此误判为无效。同理, 幂等性不能只看一轮。


### 配置步骤(一次性)

```bash
gh secret set HARBOR_MIRROR_USER     --repo suanova/cubestack-installer   # 从 stdin 读
gh secret set HARBOR_MIRROR_PASSWORD --repo suanova/cubestack-installer
# 或: GitHub 网页 → Settings → Secrets and variables → Actions → New repository secret
```

⚠ **`gh secret set --body -` 不会读 stdin**: `-b/--body` 是"直接给值",
传 `-` 会把字面量 `-` 存成密钥值(本项目首轮 CI 失败就是这么来的)。
要走 stdin 就**省略 `--body`**。

---

## 10. 相关文档

- 镜像清单: `deployments/config/images.manifest`
- 版本变量(升级入口): `deployments/config/cluster.conf.example` §3.3
- 部署脚本规范: `docs/scripts-development-spec.md`
- 故障沉淀: `docs/troubleshooting.md`
