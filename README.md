# CubeStack Installer

CubeStack 的公共部署引擎：负责 Kubernetes 基座、公共 addon、在线安装和版本树部署。
它不负责产品打包；商业版本树由外部发布流程生成。

## 使用方式

### 开源在线安装

```bash
cp deployments/config/cluster.conf.example deployments/config/cluster.conf
vim deployments/config/cluster.conf        # 填写 NODES / 密码 / MetalLB 等

sudo ./deployments/scripts/install-online.sh

# 可选：物化 optional base 镜像（例如 netshoot）；检查/要求 MetaX 厂商物料并物化 MetaX 镜像
sudo ./deployments/scripts/install-online.sh --include-optional
sudo ./deployments/scripts/install-online.sh --check-materials
sudo ./deployments/scripts/install-online.sh --with-metax
```

在线安装从 public Harbor 物化 `versions/base.yaml` 中声明的镜像，并在安装时下载
k8s 二进制。镜像目录按 `versions/base.yaml` 的 `mirror` pin 拉取，不在脚本里写死分支。
节点前置包（lvm2/chrony/curl 等）由 OS 镜像/运维预装；installer 默认只做只读体检
（warn-only），不安装 OS 包。需要离线安装时，在 cluster.conf 置
`NODE_PKGS_ENABLED=true` / `WORKER_PKGS_ENABLED=true`（`.deb` 放
`offline-files/os/packages/`）；chrony 专用安装集（`offline-files/os/packages/chrony/`）
可用独立可选模块 `CHRONY_PKGS_ENABLED=true` 安装 —— 装包可选，NTP 同步（`k8s_ntp`）始终必选。

在线安装主机需要：`python3` + PyYAML、`jq`、`skopeo`、`curl`。

### 商业/离线版本树

```bash
sudo ./deployments/scripts/deploy-cluster.sh --release 2.1.0
# 或把版本树 offline-files/ 挂到 deployments/offline-files，自动识别 release.env
```

版本树由 release 打包，包含镜像 tar、chart、k8s 资产、modules 和校验文件。
installer 只消费本地树，不访问 MinIO/Harbor。

版本树的 `modules/` 必须与 `offline-files/` **同级**；容器运行时要同时挂载两者
（见 [CLI 容器](#cli-容器)）：

```text
<版本树根>/
  offline-files/     → /opt/cubestack-installer/deployments/offline-files
  modules/           → /opt/cubestack-installer/deployments/modules   (只读)
  cubestack-installer-cli.tar
```

### 直接部署

```bash
sudo ./deployments/scripts/deploy-cluster.sh                    # 默认全量
sudo ./deployments/scripts/deploy-cluster.sh --with-k8s         # 仅 kubespray 基座
sudo ./deployments/scripts/deploy-cluster.sh --steps metax_gpu    # 只装该组件(精确)
sudo ./deployments/scripts/deploy-cluster.sh --enable metax_gpu   # 全量 + 启用该组件(同时写配置)
```

## 关键配置

`deployments/config/cluster.conf` 是唯一配置源：

- `NODES`：节点列表；裸金属必须手动填写；
- `SSH_DEFAULT_PASSWORD` / 节点独立密码；
- `METALLB_POOL`：裸金属必须填写节点同网段空闲地址；
- 组件开关：`CEPH_MODE=none|external|internal`、`MULTUS_ENABLED`、`RDMA_ENABLED`、`METAX_GPU_ENABLED` 等。

首次使用先复制模板：

```bash
cp deployments/config/cluster.conf.example deployments/config/cluster.conf
```

## CLI 容器

镜像（CI 每次合并构建 `sha-<commit>`；release 版本树以 `release.env` 的
`CUBESTACK_CLI_IMAGE` digest 为准）：

```text
harbor.isuanova.com/suanova/cubestack-installer-cli:sha-<commit>
```

`sha-<commit>` 由 `rebuild-cli-image.yml` 以合并提交的短 SHA 生成；本地
`build-cli-image.sh` 默认也使用 `sha-$(git rev-parse --short HEAD)`。
不存在 CLI 的 `<line>-latest` 通道；release 直接使用版本树 `release.env` 里的
`CUBESTACK_CLI_IMAGE`（`@sha256:...`）。

构建/推送：

```bash
sudo ./deployments/scripts/tools/docker/build-cli-image.sh --build
sudo ./deployments/scripts/tools/docker/build-cli-image.sh --push
```

运行：

**版本树包含 `modules/`：按完整 phase 路径比较，只挂载镜像缺失的模块**

```bash
set -euo pipefail

OFFLINE_ROOT=/data/offline-files
MODULES_DIR=/data/modules
EXTRA_MODULES=/tmp/cubestack-modules-extra
CLI_IMAGE="harbor.isuanova.com/suanova/cubestack-installer-cli:sha-<commit>"

[ -d "${MODULES_DIR}" ] || { echo "modules not found: ${MODULES_DIR}"; exit 1; }

# 1) 版本树 modules/<NN_*> 的模块清单（保留相对 phase 路径）
( cd "${MODULES_DIR}" && find . -mindepth 2 -maxdepth 2 -type f -name '*.sh' \
    -path './[0-9][0-9]_*/*' -printf '%P\n' | sort ) > /tmp/release-modules.txt
# 2) 镜像内置 deployments/scripts/modules/<NN_*> 的模块清单
#    与最终启动命令使用同样的 Docker 访问方式；set -e 保证清单失败即中止
sudo docker run --rm --entrypoint sh "${CLI_IMAGE}" -c \
  'cd /opt/cubestack-installer/deployments/scripts/modules && find . -mindepth 2 -maxdepth 2 -type f -name "*.sh" -path "./[0-9][0-9]_*/*" -printf "%P\n" | sort' \
  > /tmp/image-modules.txt
# 3) 版本树有、镜像没有的模块
comm -23 /tmp/release-modules.txt /tmp/image-modules.txt > /tmp/release-only-modules.txt

# 4) 只把缺失模块复制到独立 overlay；镜像已有的同名模块不进入
rm -rf "${EXTRA_MODULES}"
while IFS= read -r rel; do
  mkdir -p "${EXTRA_MODULES}/$(dirname "${rel}")"
  cp -a "${MODULES_DIR}/${rel}" "${EXTRA_MODULES}/${rel}"
done < /tmp/release-only-modules.txt

# 5) 有缺失模块才双挂载；没有则只挂 offline-files
if [ -s /tmp/release-only-modules.txt ]; then
  MODULES_MOUNT=(-v "${EXTRA_MODULES}":/opt/cubestack-installer/deployments/modules:ro)
else
  MODULES_MOUNT=()
fi

sudo docker run --rm -it --network host \
  -v "${OFFLINE_ROOT}":/opt/cubestack-installer/deployments/offline-files \
  ${MODULES_MOUNT[@]+"${MODULES_MOUNT[@]}"} \
  -v $PWD/deployments/config/cluster.conf:/opt/cubestack-installer/deployments/config/cluster.conf \
  -v $HOME/.ssh:/root/.ssh \
  "${CLI_IMAGE}"
```

**公开 release 没有 `modules/` 时只用单挂载：**

```bash
OFFLINE_ROOT=/data/offline-files
CLI_IMAGE="harbor.isuanova.com/suanova/cubestack-installer-cli:sha-<commit>"

sudo docker run --rm -it --network host \
  -v "${OFFLINE_ROOT}":/opt/cubestack-installer/deployments/offline-files \
  -v $PWD/deployments/config/cluster.conf:/opt/cubestack-installer/deployments/config/cluster.conf \
  -v $HOME/.ssh:/root/.ssh \
  "${CLI_IMAGE}"
```

> 不要对不存在的 `modules/` 目录执行 `docker -v`：Docker 会在宿主机创建空目录，
> release 模式会把它当成已挂载的 modules 目录，`cs_merge_modules_dirs` 因其中没有
> `NN_*` 阶段而退出。

> **SSH key 挂载**：只读挂载（`-v $HOME/.ssh:/root/.ssh:ro`）要求**私钥和公钥都已存在**；
> 只读文件系统上 installer 无法补写公钥。缺少 `.pub` 时先在宿主机执行
> `ssh-keygen -y -f <私钥> > <私钥>.pub`，或改用可写目录挂载。**首次安装仍需生成密钥时**
> 要挂可写目录（如 `-v $PWD/.ssh:/root/.ssh`），否则会在 `gen-ssh-key.sh` 处明确报错。

容器内已是 root，直接运行部署脚本。离线文件挂载复用，不进入镜像。

**为什么要挂 `modules/`**：installer 在 release 模式下把
`dirname(OFFLINE_FILES_ROOT)/modules` 作为私有平台模块目录
（`cubestack_operator`、`dev_lab`、`model_images`、`lws`、`envoy_gateway`、
`ai_gateway`、`prometheus`、`perses`、`bmc`、`metax`、`cuberouter` 等）。
只挂 `offline-files/` 时这些模块不会出现在 `--list-steps` 中。

> **重叠规则**：同一 phase 下与镜像同名的 release 模块**不会**进入
> `${EXTRA_MODULES}` overlay，以镜像内置版本为准。`cs_merge_modules_dirs` 先链接
> 镜像模块，遇到同名文件会直接报 `duplicate module file` 并退出；若 release 需要
> 覆盖镜像模块，必须改名或重建镜像，不能通过挂载同名文件实现。

## 目录

```text
deployments/
  scripts/                  # 部署入口、模块框架、工具
  scripts/modules/          # 01_env / 02_k8s / 03_addon
  kubespray/                # kubespray 树、inventory、离线安装入口
  config/                   # cluster.conf 模板和默认值
  offline-files/            # 本地离线件（gitignore，由版本树/物化生成）
  modules/                  # 平台私有模块（版本树提供；与 offline-files 同级，运行时挂载）
versions/
  base.yaml                 # 公共 base 版本真源
  os/                       # 节点前置包体检清单
docs/                       # 设计、运行、排障文档
images/
  installer-cli/            # CLI 镜像（代码层）Dockerfile
  installer-cli-base/       # CLI 镜像（基础层）Dockerfile
  netshoot-rdma/            # RDMA 诊断镜像 Dockerfile
Makefile                    # 辅助构建目标（netshoot-rdma 等）
```

## 文档

- 部署引擎与脚本：`deployments/scripts/README.md`
- 部署套件总览：`deployments/README.md`
- 脚本开发规范：`docs/scripts-development-spec.md`
- 发布边界：`docs/release-management.md`
- 公共 base 基线：`docs/base-baseline.md`
- 排障：`docs/troubleshooting.md`

## 构建检查

```bash
bash deployments/scripts/tools/check-modules.sh
bash deployments/scripts/tools/check-manifests.sh
python3 deployments/scripts/tools/validate-base-baseline.py
```
