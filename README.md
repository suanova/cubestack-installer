# CubeStack Installer

CubeStack 的公共部署引擎：负责 Kubernetes 基座、公共 addon、在线安装和版本树部署。
它不负责产品打包；商业版本树由外部发布流程生成。

## 使用方式

### 开源在线安装

```bash
cp deployments/config/cluster.conf.example deployments/config/cluster.conf
vim deployments/config/cluster.conf        # 填写 NODES / 密码 / MetalLB 等

sudo ./deployments/scripts/install-online.sh
```

在线安装从 public Harbor 物化 `versions/base.yaml` 中声明的镜像，并在安装时下载
k8s 二进制。节点前置包（lvm2/chrony/curl 等）由 OS 镜像/运维预装；installer 只做
只读体检，默认 warn-only。

### 商业/离线版本树

```bash
sudo ./deployments/scripts/deploy-cluster.sh --release 2.1.0
# 或把版本树 offline-files/ 挂到 deployments/offline-files，自动识别 release.env
```

版本树由 release 打包，包含镜像 tar、chart、k8s 资产、modules 和校验文件。
installer 只消费本地树，不访问 MinIO/Harbor。

### 直接部署

```bash
sudo ./deployments/scripts/deploy-cluster.sh                    # 默认全量
sudo ./deployments/scripts/deploy-cluster.sh --with-k8s         # 仅 kubespray 基座
sudo ./deployments/scripts/deploy-cluster.sh --steps gpu_operator
sudo ./deployments/scripts/deploy-cluster.sh --enable gpu_operator
```

## 关键配置

`deployments/config/cluster.conf` 是唯一配置源：

- `NODES`：节点列表；裸金属必须手动填写；
- `SSH_DEFAULT_PASSWORD` / 节点独立密码；
- `METALLB_POOL`：裸金属必须填写节点同网段空闲地址；
- 组件开关：`CEPH_ENABLED`、`MULTUS_ENABLED`、`RDMA_ENABLED`、`GPU_OPERATOR_ENABLED` 等。

首次使用先复制模板：

```bash
cp deployments/config/cluster.conf.example deployments/config/cluster.conf
```

## CLI 容器

镜像：

```text
harbor.isuanova.com/suanova/cubestack-installer-cli:latest
```

构建/推送：

```bash
sudo ./deployments/scripts/tools/docker/build-cli-context.sh --build
sudo ./deployments/scripts/tools/docker/build-cli-context.sh --push
```

运行：

```bash
sudo docker run --rm -it --network host \
  -v $PWD/deployments/offline-files:/opt/cubestack-installer/deployments/offline-files \
  -v $PWD/deployments/config/cluster.conf:/opt/cubestack-installer/deployments/config/cluster.conf \
  -v $HOME/.ssh:/root/.ssh \
  harbor.isuanova.com/suanova/cubestack-installer-cli:latest
```

容器内已是 root，直接运行部署脚本。离线文件挂载复用，不进入镜像。

## 目录

```text
deployments/
  scripts/                  # 部署入口、模块框架、工具
  scripts/modules/          # 01_env / 02_k8s / 03_addon
  kubespray/                # kubespray 树、inventory、离线安装入口
  config/                   # cluster.conf 模板和默认值
  offline-files/            # 本地离线件（gitignore，由版本树/物化生成）
versions/
  base.yaml                 # 公共 base 版本真源
  os/                       # 节点前置包体检清单
docs/                       # 设计、运行、排障文档
skills/                     # 维护者技能文档
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
