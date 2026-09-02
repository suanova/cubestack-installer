# 沐曦 MetaX GPU Operator 部署文档

> 记录**沐曦(MetaX)GPU Operator**的离线部署方案: 需要提前下载哪些文件、如何配置 `cluster.conf`、目录布局、部署流程与验证。
> 已在本集群(9 节点, 3 master + 6 worker, 共 **69 张 MXC500**)端到端验证通过。
> 版本说明: 本文以 `metax-gpu-k8s 0.15.3`、`MXMACA 3.8.1.2`、驱动 `3.8.1.6` 为例; 升级改 `cluster.conf` 的 `METAX_VERSION` / `METAX_MACA_IMAGE` / `METAX_DRIVER_VERSION` 即可, 逻辑通用。

## 0. 架构前提(必读)

- 网络: Calico + IPIP(见 `docs/cluster-architecture.md`), 集群内置 docker registry 用 MetalLB 分配 VIP。
- 镜像仓库: 集群内置 `registry.cubestack.io:5000`(registry.cubestack.io 由宿主机 /etc/hosts → `REGISTRY_IP`), 仓库路径 `metax/<组件>:<tag>`。
- 节点: 已装沐曦内核驱动(`lsmod | grep metax`), 用 `METAX_DRIVER_DEPLOY_POLICY=PreferHost`(宿主机驱动)。
- master 节点也有 GPU: 部署时用 `mx-smi` 检测, 检测到 GPU 的 master 自动移除 control-plane 污点并 uncordon。

---

## 1. 提前下载的文件(部署前准备好)

> 来源: [沐曦软件中心](https://metax-tech.com) 登录后 → 下载 → 软件栈 / 镜像。账号与命令以官网最新为准。
> 全部文件放入 **`deployments/offline-files/metax-gpu/`**(即 `METAX_OFFLINE_DIR`; 已 gitignore, 不入库)。

### 1.1 核心资源包(必下)

| 文件 | 来源 | 说明 |
|---|---|---|
| `metax-gpu-k8s-package.<ver>.tar.gz` | 软件中心 → 云平台工具 → metax-gpu-k8s | 内含 `metax-k8s-images.<ver>.run` + helm charts; **仅 run 模式需要** |
| `metax-k8s-images.<ver>.run` | 上述包内(或单独) | Makeself 自解压, 内嵌 11 个核心组件镜像的 .xz; **run 模式**用 `ctr load` 加载推送 |

> ⚠ **默认 tar 模式不需要上述两个文件**(直接加载离线 tar 镜像), 但建议备齐以便切换 run 模式。

### 1.2 驱动 / SDK(按需)

| 文件/镜像 | 来源 | 说明 |
|---|---|---|
| `metax-k8s-driver-image.<ver>-x86_64.run` | 软件中心 → 驱动 | 内核驱动包(可选; PreferHost 用宿主机驱动则不需要) |
| `cr.metax-tech.com/public-library/maca:<tag>` | 软件中心 → 镜像 → MXMACA | MXMACA SDK 镜像(需 `docker login cr.metax-tech.com`); GPU 任务必需 |
| `cr.metax-tech.com/public-cloud-release/driver-image:<ver>` | 软件中心 → 镜像 → Cloud-Tools | 容器化驱动镜像(PreferCloud 才需要) |

### 1.3 镜像离线 tar(推荐离线路径, 默认方式)

用 `tools/images/metax-save-images.sh` 在**已有这些镜像的机器**(如内网/在线机)上从 docker 一键导出:

```bash
sudo ./deployments/scripts/tools/images/metax-save-images.sh
# 默认枚举 harbor.isuanova.com/metax/* (可在 cluster.conf 改 METAX_SAVE_PATTERN 选 cr.metax-tech.com/cloud/)
# 默认排除 sglang(METAX_SAVE_EXCLUDE); 输出到 METAX_OFFLINE_DIR
```

生成的 tar 共 **27 个(约 19G)**, 含: 核心组件(10 个 × amd64/arm64)、maca(3 个版本)、driver-image(2 个版本)、operator-bundle/catalog。
也可用 `METAX_LIST_IMAGES=true bash modules/03_addon/04_gpu_operator.sh` 打印所需镜像的 `docker pull/save` 命令。

---

## 2. 目录布局

```
deployments/
├── cubestack-addon/metax-gpu-operator/metax-operator/   # 修复后的 helm chart(已修 3 处 bug, 直接 helm 安装; 入库)
├── offline-files/metax-gpu/               # 镜像 tar + 资源包/.run 等大文件(gitignore, 不入库)
│   ├── <image>_<tag>.tar                  # metax-save-images.sh 生成的 27 个 tar
│   ├── metax-gpu-k8s-package.<ver>.tar.gz
│   ├── metax-k8s-images.<ver>.run
│   ├── metax-k8s-driver-image.<ver>.run
│   └── metax-operator-<ver>.tgz / metax-gpu-extensions-<ver>.tgz
└── scripts/
    ├── modules/03_addon/04_gpu_operator.sh       # 部署模块(默认 tar 加载)
    ├── modules/03_addon/23_verify_metax_gpu.sh   # 验证模块(--steps verify 自动纳入)
    └── tools/images/metax-save-images.sh         # 保存镜像 → tar
    └── tools/images/metax-load-images.sh         # 加载 tar → 集群 registry(手动)
    └── tools/k8s/verify-metax-gpu.sh             # 节点 GPU 识别验证脚本
```

---

## 3. 配置变更(`cluster.conf` METAX_* 段)

> 已加入 `cluster.conf` 与 `cluster.conf.example`。关键项:

```bash
GPU_OPERATOR_ENABLED="${GPU_OPERATOR_ENABLED:-false}"   # 总开关, 默认 false; 本集群设为 true → --with-cubestack 即部署; 也可 --steps gpu_operator 立即部署
METAX_VERSION="${METAX_VERSION:-0.15.3}"                 # 版本(决定包名/镜像 tag/Chart)
METAX_OFFLINE_DIR="${METAX_OFFLINE_DIR:-${REPO_ROOT}/deployments/offline-files/metax-gpu}"
METAX_PKG_DIR="${METAX_PKG_DIR:-${METAX_OFFLINE_DIR}}"   # 大文件(.run/资源包)所在目录
METAX_CHART_DIR="${METAX_CHART_DIR:-${REPO_ROOT}/deployments/cubestack-addon/metax-gpu-operator/metax-operator}"  # 修复版 chart
METAX_IMAGE_MODE="${METAX_IMAGE_MODE:-tar}"             # tar(默认, 加载离线 tar) | run(.run 内嵌镜像)
METAX_IMAGE_DIR="${METAX_IMAGE_DIR:-${LOCAL_REPO_DIR}/images}"   # 额外 tar 目录(可配)
METAX_TAR_PATTERN="${METAX_TAR_PATTERN:-metax}"         # tar 匹配文件名
METAX_SAVE_PATTERN="${METAX_SAVE_PATTERN:-^harbor\.isuanova\.com/metax/}"  # 保存源仓库
METAX_SAVE_EXCLUDE="${METAX_SAVE_EXCLUDE:-sglang}"      # 保存排除(sglang 等大推理镜像)
METAX_REGISTRY="${METAX_REGISTRY:-${REGISTRY_DOMAIN}:${REGISTRY_PORT}/metax}"
METAX_NAMESPACE="${METAX_NAMESPACE:-metax-operator}"
METAX_RELEASE_NAME="${METAX_RELEASE_NAME:-metax-gpu-operator}"
METAX_CLUSTER_TYPE="${METAX_CLUSTER_TYPE:-k8s}"          # 必须 k8s(防 operator 探测 OpenShift API 崩溃)
METAX_DRIVER_DEPLOY_POLICY="${METAX_DRIVER_DEPLOY_POLICY:-PreferHost}"  # 默认 PreferHost(用节点已装驱动; PreferCloud 会尝试卸载宿主驱动, 卸载失败 CrashLoop)
METAX_DRIVER_VERSION="${METAX_DRIVER_VERSION:-3.8.1.6-amd64}"   # 需与本地镜像/tar 匹配
METAX_MACA_IMAGE="${METAX_MACA_IMAGE:-maca:3.8.1.2-ubuntu20.04-amd64}"  # MXMACA SDK 镜像(最新 3.8)
METAX_IMAGE_COMPONENTS="..."   # 核心组件列表(run 模式 / 列表打印用)
```

---

## 4. 部署流程

```bash
sudo ./deploy-cluster.sh --with-cubestack   # 全量: 基座 + cluster.conf 中已启用的 operator(本集群 GPU_OPERATOR_ENABLED=true → 部署 gpu_operator)
# 或单独(立即部署): sudo ./deploy-cluster.sh --steps gpu_operator   # 只部署 gpu_operator(自动带基座)
# 或预启用(只写配置, 不部署): sudo ./deploy-cluster.sh --enable gpu_operator   # 下次 --with-cubestack 生效
```

> **断点续跑**: 本模块 `REPEAT:0` —— 安装成功写状态, 重跑部署自动跳过(不重复重装);
> 要重装用 `--fresh`(清所有断点状态, 从零部署)。`--steps gpu_operator` 可单独执行。

模块自动完成(默认 tar 模式):

1. **前置**: 更新宿主机 /etc/hosts(`registry.cubestack.io→REGISTRY_IP`、`k8s-api.cubestack.io→API_IP`, 不留过期 IP)、
   下载 master 的 admin.conf 合并进 `~/.kube/config`(宿主 helm/kubectl 可访问集群)、校验 registry/集群可达。
2. **确认资源**: 修复版 chart(`METAX_CHART_DIR`) + 镜像加载源。
3. **加载镜像 → 集群 registry**:
   - `tar`(默认): 从 `METAX_OFFLINE_DIR` 逐 tar `skopeo docker-archive → registry.cubestack.io:5000/metax/...`;
     **只推当前 operator 需要的版本**(maca 只推 `METAX_MACA_IMAGE`、driver 只推 `METAX_DRIVER_VERSION`,
     核心组件只推本机架构的 `METAX_VERSION`; 其他版本如 maca 3.8.0.11/3.8.1.2、driver 3.2.1.12、
     operator-bundle/catalog 均跳过);
     核心组件去架构后缀(`0.15.3-amd64 → 0.15.3`), 跳过非本机架构; maca/driver 原样。
   - `run`: `.run ctr load` + 逐组件 `ctr tag + push --plain-http`(规避 .run 自带 push 的 flag 顺序 bug)。
4. **清理残留**(CR/CRD/命名空间/default 旧资源/集群级 ClusterRole) → **helm upgrade --install**(修复版 chart)。
5. **等待就绪 + 验证**:
   - 等 DaemonSet 就绪(container-runtime / driver / maca / gpu-label / gpu-device)。
   - **mx-smi 检测 master GPU**: 检测到 GPU 的 master 移除 control-plane/master 污点并 uncordon(可调度);
     无 GPU 的 master 保持不可调度。
   - 验证节点 `metax-tech.com/gpu` allocatable。

> 也可手动加载镜像: `sudo ./deployments/scripts/tools/images/metax-load-images.sh`。

---

## 5. 验证

```bash
sudo ./deploy-cluster.sh --steps verify_metax_gpu   # 或 --steps verify(自动纳入全部 verify 模块)
# 或单独: sudo ./deployments/scripts/tools/k8s/verify-metax-gpu.sh
```

输出每节点 GPU 清单(capacity/allocatable/product/memory/label/可调度)与汇总:

```
GPU 识别节点数: 9  总 GPU(allocatable): 69
```

GPU 任务测试(参考沐曦官方文档 §5, 需 maca 镜像就绪): 建 gpu-task.yaml 申请 `metax-tech.com/gpu: 1`。

---

## 6. 已知问题与修复(已验证)

| 问题 | 根因 | 解法 |
|---|---|---|
| operator CrashLoop 探测 OpenShift API | 未设 `cluster.type=k8s` / 无 ClusterOperator CR | chart 修复(openshift.deploy 默认 false) + `--set cluster.type=k8s` |
| helm 拒绝安装 | 历史 kubectl apply 留下的资源无 Helm 标签 | 模块每次重部署先清理(含集群级 ClusterRole/RoleBinding) |
| skopeo `docker-daemon:` 报 API 版本过旧 | 此 docker 版本 | 改 `docker save` 成 tar + `skopeo docker-archive` 推送 |
| `.run push --plain-http` 报错 | 工具把 flag 置于镜像 ref 之后 | 模块用 `.run ctr load` + 自行 `ctr push --plain-http`(flag 在前) |
| 宿主机 `registry.cubestack.io`/`k8s-api` 连不通 | /etc/hosts 残留旧 IP(10.66.3.37) 或 DNAT 被旧规则遮蔽 | 模块每次部署修正 /etc/hosts 指向正确 IP |
| 镜像不在 .run 包内(driver/maca) | 需单独推送 | 本地 docker(`docker save`+skopeo) / 离线 tar / 在线, 逐级尝试; 模块已实现 |
| master 无 `gpu.installed` 标签 | metax DS 无 control-plane 容忍, 调度不到 master | 部署时 mx-smi 检测到 GPU 的 master 自动移除污点+uncordon(见 §4.5) |

> 更多通用故障见 `docs/troubleshooting.md`。

---

## 7. 相关命令速查

```bash
# 保存镜像为离线 tar(在已有镜像的机器上)
sudo ./deployments/scripts/tools/images/metax-save-images.sh
# 加载 tar 到集群 registry(手动, 与模块 tar 模式等价)
sudo ./deployments/scripts/tools/images/metax-load-images.sh
# 打印所需镜像的 pull/save 命令
METAX_LIST_IMAGES=true bash deployments/scripts/modules/03_addon/04_gpu_operator.sh
# 部署 / 验证
sudo ./deploy-cluster.sh --steps gpu_operator
sudo ./deploy-cluster.sh --steps verify_metax_gpu
# 卸载: 删 metax-operator 命名空间 + CRD 后重跑模块
```
