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
| `docker.io/grafana/grafana:13.2.1` | `harbor.isuanova.com/mirrors/docker.io/grafana/grafana:13.2.1` |
| `quay.io/prometheus/node-exporter:v1.12.1` | `harbor.isuanova.com/mirrors/quay.io/prometheus/node-exporter:v1.12.1` |
| `registry.k8s.io/pause:3.10` | `harbor.isuanova.com/mirrors/registry.k8s.io/pause:3.10` |
| `harbor.isuanova.com/metax/gpu-label:x` | `harbor.isuanova.com/mirrors/metax/gpu-label:x` ⟵ 同台 Harbor, 去掉域名前缀 |
| `harbor.isuanova.com/suanova/cubepilot-api:latest` | `harbor.isuanova.com/mirrors/suanova/cubepilot-api:latest` |

**为什么要保留注册域**(而不是把 `docker.io/grafana/grafana` 压成 `grafana/grafana`):

1. **零歧义**: 上游 ref 是 Harbor 路径的**后缀**, 因此"离线 tar 按上游 ref 命名"这个约定
   (既有模块靠 `*<repo>_<tag>.tar` 通配查找)可以**零改动**沿用;
2. **不撞车**: 不同注册域下的同名仓库(如多来源的 `prometheus/node-exporter`)各占独立路径。

> 项目名固定 `mirrors`(`HARBOR_MIRROR_PROJECT`)。仓库(repository)在首次 push 时由 Harbor
> 自动创建; **项目**(project)必须预先存在 —— `harbor-sync-images.sh` 会自动建(公开只读,
> 便于部署机匿名拉取)。

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
./harbor-sync-images.sh --group prometheus,envoy
./harbor-sync-images.sh --exclude-group metax-gpu   # 沐曦 driver/maca 体积大
./harbor-sync-images.sh --platform amd64     # 单架构(默认 --all 保留多架构 manifest list)
./harbor-sync-images.sh --force              # 忽略 digest 强制重传
```

凭据: `HARBOR_MIRROR_USER` / `HARBOR_MIRROR_PASSWORD`
(不传则匿名 —— 但**建项目必须登录**)。凭据会写进 600 权限的临时 auth 文件, 退出即删,
**不进 argv、不进日志**。

### `harbor-save-images.sh` — Harbor → 离线 tar(联网机 / 部署机)

```bash
sudo ./harbor-save-images.sh                 # 全部 → 各组件 offline-files 子目录
sudo ./harbor-save-images.sh --group kube-state-metrics
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

- 版本**只声明在 `cluster.conf`**(`PROMETHEUS_IMAGE_KSM`、`ENVOY_EG_VERSION`、`K8S_VERSION` …);
- `images.manifest` 用 `${VAR}` 引用, 不重复写死版本;
- 三个工具与 CI 都从清单读 —— 所以**改一处, 全链跟随**;
- 新增的版本变量集中在 `cluster.conf.example` 的 **3.3 节「镜像版本(★ 升级入口)」**。

### 升级某个组件(以 kube-state-metrics 为例)

```bash
# ① 改版本(cluster.conf 一处)
#    PROMETHEUS_IMAGE_KSM="v2.21.0"
# ② 校验清单仍自洽
bash deployments/scripts/tools/images/check-image-manifest.sh --kubespray
# ③ 同步到 Harbor(CI 会随 push 自动做; 也可本地跑)
./deployments/scripts/tools/images/harbor-sync-images.sh --group kube-state-metrics
# ④ 拉成离线 tar
sudo ./deployments/scripts/tools/images/harbor-save-images.sh --group kube-state-metrics --force
# ⑤ 重新部署(模块推新 tar 进内置 registry + helm upgrade)
sudo ./deploy-cluster.sh --steps prometheus
# ⑥ 验证数据源真的有数据
sudo ./deploy-cluster.sh --steps verify_prometheus
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

## 9. 相关文档

- 镜像清单: `deployments/config/images.manifest`
- 版本变量(升级入口): `deployments/config/cluster.conf.example` §3.3
- 监控三件套: `deployments/cubestack-addon/observability/{kube-state-metrics,node-exporter,kubelet-cadvisor}/README.md`
- 部署脚本规范: `docs/scripts-development-spec.md`
- 故障沉淀: `docs/troubleshooting.md`
