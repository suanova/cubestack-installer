# CubeStackInstaller · 虚拟机 + Kubespray 安装 K8s 集群平台

在宿主机上创建 KVM 虚拟机,再通过 **Kubespray** 一键部署生产级 Kubernetes 集群。
左侧**两个树形导航**分别对应两大流程:**虚拟机安装** 与 **K8s集群安装**。

- 🐍 **后端**: Python + FastAPI + SQLAlchemy + JWT + 异步部署任务引擎
- ⚛️ **前端**: JavaScript + React 18 + Vite + React Router
- 🎨 **界面**: 专业蓝灰配色 · 深色/浅色双主题 · 中英文双语切换(顶栏按钮,偏好持久化)

## 功能一览

| 流程 | 功能 | 说明 |
| --- | --- | --- |
| 虚拟机安装 | 宿主机管理 | 纳管物理服务器,SSH 连通性检测,添加/删除 |
| 虚拟机安装 | 虚拟机管理 | 创建 KVM 虚拟机(规格/镜像/IP),启动/停止/重启/删除 |
| K8s集群安装 | 集群管理 | 选择节点创建集群,一键 Kubespray 安装 |
| K8s集群安装 | 部署任务 | 异步任务流,实时日志与进度,自动刷新 |
| 平台 | 概览 / 接口参考 / 用户管理 | 资源统计、API 输入输出文档、账号管理 |

> 默认管理员账号:**admin** / **admin123**(首次启动自动创建)

## 语言与主题

- 顶栏右侧 **EN/中** 按钮切换中英文(记住偏好,刷新不丢)
- 顶栏右侧 **☀/☾** 按钮切换深色/浅色主题(跟随系统偏好,可手动覆盖)
- 主题/语言偏好保存在 localStorage

## 快速开始

### 方式一:一键启动(推荐)

```bash
bash scripts/dev.sh        # 或 make dev
```

### 方式二:分别启动

```bash
# 后端(FastAPI,端口 8000,uv 管理)
make installer              # 或 cd installer && uv run cubestack-installer-installer

# 前端(React + Vite,端口 5173)
make ui             # 或 cd ui && npm run dev
```

- 前端: **http://localhost:5173**(admin / admin123 登录)
- 后端 Swagger: http://127.0.0.1:8000/docs

### 常用命令

```bash
make build    # 前端生产构建 + 后端 uv build 发行包
make test     # 后端 pytest 测试(uv run)
make stop     # 停止全部服务
```

### 后端 uv 工作流

```bash
cd installer
uv sync                 # 安装依赖(生成 .venv 与 uv.lock,走清华镜像)
uv add <包名>           # 新增依赖
uv run pytest           # 运行测试
uv run cubestack-installer-installer   # 启动后端
uv build                # 构建 wheel + sdist(输出 dist/)
```

> Python 依赖由 **uv** 管理(uv.lock 锁定版本,清华镜像);npm 走 npmmirror 镜像。

### 单端口部署(前后端合一)

```bash
make package     # 构建 UI 并打包进后端
cd installer && uv run cubestack-installer-installer
```

### 单镜像容器部署(podman)

根目录 `Dockerfile` 多阶段构建:**Stage 1** 用 Node 构建 UI,**Stage 2** 用 uv 安装后端全部依赖并放入前端产物,生成一个自包含镜像(与 docker 完全兼容):

镜像名:**`harbor.isuanova.com/cubestack/cubestack-installer:latest`**(Harbor 私有仓库):

```bash
make image          # 构建 + 启动(镜像名见 Makefile IMAGE 变量)
make image-push     # 推送到 Harbor(需先 podman login harbor.isuanova.com)

podman build --format docker -t harbor.isuanova.com/cubestack/cubestack-installer:latest .
podman run -d -p 8000:8000 -v csi-data:/app/data --name cubestack-installer harbor.isuanova.com/cubestack/cubestack-installer:latest
podman logs -f cubestack-installer     # 查看日志
# 访问 http://localhost:8000(页面 + /api 单端口)
```

- 镜像内置全部 Python 依赖(uv.lock 锁定)+ 前端构建产物 + 健康检查(HEALTHCHECK)
- ENTRYPOINT 一键启动:FastAPI 同时托管前端页面与 /api 接口
- 数据持久化:挂载卷到 `/app`(SQLite userhub.db);rootless podman 无需 sudo
- 多服务编排:也可用 `podman compose up -d` 使用根目录 docker-compose.yml(podman 4.2+ 内置 compose 支持)

- `make package` 会:`npm run build` 构建 UI → 复制 `ui/dist` 到 `installer/app/static` → `uv build` 生成含前端产物的 wheel
- 后端启动后由 FastAPI 直接托管前端静态资源,**只需 8000 一个端口**:
  - `/` 返回前端页面,`/assets/*` 提供静态资源,`/api/*` 提供接口
  - 前端路由(如 `/hosts`)自动回退 index.html,Swagger `/docs` 不受影响

## 宿主机环境检测

添加宿主机或点击「环境检测」时,平台会 SSH 到宿主机执行环境体检:

| 检查项 | 要求 | 校验方式 |
| --- | --- | --- |
| SSH 连通性 | 可登录 | ssh BatchMode + ConnectTimeout=5 |
| 操作系统 | **Ubuntu 22.04**(ID=ubuntu 且 VERSION_ID 以 22.04 开头) | 解析 /etc/os-release |
| libvirt 依赖 | virt-install / virsh / qemu-img / qemu-kvm / cloud-localds 全部存在 | command -v + dpkg 兜底 |
| libvirtd 服务 | 运行中 | systemctl is-active libvirtd |
| /dev/kvm | 存在(硬件加速) | test -e /dev/kvm |

- 检测报告(逐项通过/缺失)保存到宿主机记录,前端表格「环境」列展示 OS 与 libvirt 徽章,点击「环境检测」查看完整报告
- 新增宿主机接口(POST /api/hosts)会同步执行环境检测并返回结果
- 仿真模式(DEPLOY_MODE=sim / 无 ssh 工具)返回模拟通过报告并标记「仿真检测」;真实模式检测失败如实标记

### 宿主机初始化命令(一键复制)

添加宿主机弹窗(或列表行「配置命令」)内置一段**可复制的 Shell 脚本**,在管理机执行即可完成:

1. `ssh-copy-id` 将管理机公钥复制到宿主机(免密 SSH)
2. `apt-get install` 安装 libvirt 依赖(virtinst / libvirt-clients / qemu-utils / qemu-kvm / cloud-image-utils)
3. `systemctl enable --now libvirtd` 启动服务并设置开机自启
4. 校验 `/dev/kvm` 硬件加速

脚本根据表单输入的 IP / SSH 用户 / 端口实时生成,一键复制后执行,再点击「环境检测」即可看到检测通过。
## 双虚拟化后端(Provider 插件化)

虚拟机支持两种启动方式,通过创建表单「启动方式」选择,后端按 Provider 分发:

| Provider | 连接方式 | 操作实现 | 状态检测 |
| --- | --- | --- | --- |
| **Libvirt (virsh)** | 宿主机本机 libvirt | virt-install / virsh start/stop/reboot | 默认 |
| **KubeVirt** | kubectl + kubeconfig(管理集群) | VirtualMachine CRD:apply / patch /spec/running / delete | 需 kubectl |

- 架构:engine/providers/ 下统一 VMProvider 接口(create/action/delete/info),
  通过 get_provider(provider_type) 工厂按需路由,任务引擎、日志、仿真回退全部复用
- KubeVirt 配置(环境变量):
  - KUBECONFIG_PATH:kubectl 使用的 kubeconfig(默认 ~/.kube/config)
  - KUBEVIRT_NAMESPACE:默认命名空间(默认 default),也可在创建虚拟机时按 VM 指定
- KubeVirt 会为每个 VM 生成 **VirtualMachine CRD 清单**(DataVolume + ContainerDisk + PVC),
  镜像名自动映射到容器磁盘地址,支持 docker:// 直连地址
- 无 kubectl/kubeconfig 或执行失败时自动回退仿真模式;真实模式同样受 DEPLOY_MODE 控制
- 前端虚拟机页顶部显示两个后端的连接状态(已连接·真实模式 / 未连接·仿真模式)
## 部署引擎:仿真与真实模式

后端引擎自动检测宿主机工具,支持两种模式(可在任务日志首行确认):

| 模式 | 触发条件 | 行为 |
| --- | --- | --- |
| **真实模式** | 检测到 `virt-install` / `ansible-playbook` + `KUBESPRAY_DIR` | 调用真实命令创建 VM / 运行 Kubespray playbook |
| **仿真模式** | 工具缺失(或 `DEPLOY_MODE=sim`) | 完整模拟流程步骤与日志,便于开发演示 |

- 环境变量 `DEPLOY_MODE=sim|real|auto`(默认 auto)
- 真实执行任一步失败时**自动回退仿真**并记录警告,任务不会中断
- 集群安装会生成并展示 `inventory.ini`、组变量与 kubeconfig 输出
- 工作目录: `installer/workspace/`(真实模式生成的清单)

## 输入输出(API 约定)

所有接口除登录/注册外,请求头需携带 `Authorization: Bearer <token>`;写操作(创建/删除/部署)需**管理员**权限。

### 认证

| 方法 | 路径 | 输入 | 输出 |
| --- | --- | --- | --- |
| POST | /api/auth/register | `{"username","email","password","full_name?"}` | 201 用户对象 |
| POST | /api/auth/login | `{"account","password"}`(用户名或邮箱) | 200 `{"access_token","token_type","user"}` |
| GET | /api/auth/me | - | 200 当前用户 |

### 宿主机

| 方法 | 路径 | 输入 | 输出 |
| --- | --- | --- | --- |
| GET | /api/hosts | - | 200 主机数组 |
| POST | /api/hosts | `{"name","ip","ssh_user?","ssh_port?","cpu_cores?","memory_gb?","disk_gb?"}` | 201 主机对象 |
| POST | /api/hosts/{id}/check | - | 200 主机(状态更新为 online/offline) |
| DELETE | /api/hosts/{id} | - | 200 `{"message"}` |

### 虚拟机

| 方法 | 路径 | 输入 | 输出 |
| --- | --- | --- | --- |
| GET | /api/vms | - | 200 虚拟机数组(含宿主机信息) |
| POST | /api/vms | `{"name","host_id","cpu","memory_gb","disk_gb","image","auto_ip","ip?"}` | 202 `{"task_id","vm"}`(启动异步任务) |
| POST | /api/vms/{id}/action | `{"action":"start|stop|reboot"}` | 200 虚拟机 |
| DELETE | /api/vms/{id} | - | 200 `{"message"}` |

### K8s 集群

| 方法 | 路径 | 输入 | 输出 |
| --- | --- | --- | --- |
| GET | /api/clusters | - | 200 集群数组(含节点统计) |
| POST | /api/clusters | `{"name","k8s_version","network_plugin","kubespray_version","control_plane_vm_ids","worker_vm_ids","ssh_key?"}` | 201 集群对象 |
| GET | /api/clusters/{id} | - | 200 `{"cluster","nodes","last_task"}` |
| POST | /api/clusters/{id}/deploy | - | 202 `{"task_id"}`(启动安装任务) |
| DELETE | /api/clusters/{id} | - | 200 `{"message"}` |

### 部署任务

| 方法 | 路径 | 输入 | 输出 |
| --- | --- | --- | --- |
| GET | /api/tasks | - | 200 任务数组(含进度与日志摘要) |
| GET | /api/tasks/{id} | - | 200 任务详情(完整日志流) |

### 用户管理

| 方法 | 路径 | 输入 | 输出 |
| --- | --- | --- | --- |
| GET | /api/users | - | 200 用户数组 |
| PATCH | /api/users/{id} | `{"role"?,"is_active"?,"full_name"?}` | 200 用户 |
| DELETE | /api/users/{id} | - | 200 `{"message"}` |

应用内「接口参考」页面展示全部接口的输入/输出 JSON 示例。

## 项目结构

```
cubestack-installer/
├── installer/                     # Python 后端(FastAPI)
│   ├── app/
│   │   ├── main.py              # 入口 + 种子数据
│   │   ├── core/                # config(环境变量) / security(PBKDF2+JWT)
│   │   ├── db/                  # session / base(数据库与会话)
│   │   ├── models/              # 数据模型(用户/宿主机/虚拟机/集群/节点/任务)
│   │   ├── schemas/             # Pydantic 输入输出契约
│   │   ├── api/                 # deps(鉴权) + routes(6 组业务路由)
│   │   └── engine/              # 部署引擎
│   │       ├── executor.py      # 异步任务执行器(线程 + 日志流)
│   │       ├── services/        # hostops(环境检测) / kubespray(集群安装)
│   │       └── providers/       # 虚拟化后端:libvirt / kubevirt
│   ├── tests/                   # pytest 冒烟测试
│   ├── app/run.py               # uv 入口(console script)
│   ├── Dockerfile / pyproject.toml / uv.lock
│   └── requirements.txt         # pip 兼容参考
├── ui/                    # React 前端(Vite)
│   ├── src/
│   │   ├── api/                 # API 客户端
│   │   ├── components/          # Sidebar(双树导航)/Modal/CommandBlock/Toast...
│   │   ├── pages/               # 概览/宿主机/虚拟机/集群/任务/接口参考/用户
│   │   ├── context/             # AuthContext
│   │   ├── i18n.jsx / theme.jsx # 中英文案 / 深浅主题
│   │   └── index.css            # 设计系统
│   ├── Dockerfile + nginx.conf
│   └── vite.config.js
├── scripts/                     # dev / start-installer / start-ui
├── docs/                        # api.md / architecture.md
├── Makefile
├── docker-compose.yml
└── .env.example
```

## 工程化

- **包管理**: 后端由 **uv** 管理(uv sync / uv run / uv build),uv.lock 锁定版本
- **测试**: 后端 pytest 冒烟测试(`make test`),覆盖健康检查/注册登录/鉴权/任务流
- **容器化**: `docker-compose up --build` 一键编排(后端 + Nginx 前端),前端 /api 自动反代
- **配置**: 全部环境变量集中声明于 `.env.example` 与 `installer/app/core/config.py`
- **文档**: `docs/api.md`(接口契约)与 `docs/architecture.md`(架构设计)

## 安全设计

- 密码 PBKDF2-HMAC-SHA256(60 万次迭代 + 随机盐)哈希存储
- JWT(HS256,24h)鉴权,未登录 401、越权 403
- 管理员不能删除/禁用自己;普通用户不可执行写操作

## 生产部署提示

- 设置 `SECRET_KEY` 环境变量;管理机安装 `libvirt` / `ansible` / `kubespray` 后自动进入真实模式
- SQLite 可替换为 PostgreSQL(修改 `database.py`)
- `npm run build` 产物由 Nginx 托管,`/api` 反向代理到后端
