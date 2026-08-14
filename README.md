# CubeStackInstaller 使用文档

## 一、系统概述

CubeStackInstaller 是一套面向基础设施自动化的管理平台,用于在宿主机上创建 KVM 虚拟机,并基于 Kubespray 完成 Kubernetes 集群的部署与管理。平台由后端服务与前端控制台两部分组成,界面采用双树形导航结构,分别对应“虚拟机安装”与“K8s 集群安装”两大业务流程。

系统具备以下能力:

- 宿主机纳管:支持对物理服务器的添加、删除及 SSH 连通性检测
- 虚拟机管理:支持 KVM 虚拟机的创建、启动、停止、重启及删除
- 集群管理:支持基于 Kubespray 的 Kubernetes 集群部署
- 任务管理:提供异步部署任务流,支持实时日志与进度展示
- 账号管理:支持用户注册、登录及管理员权限控制

系统默认管理员账号为 admin / admin@123(首次启动时自动创建)。管理员初始密码可通过启动参数 --admin-password 或环境变量 ADMIN_INITIAL_PASSWORD 指定,详见 3.5 节。

## 二、系统组成

| 组件 | 技术栈 | 说明 |
| --- | --- | --- |
| 后端服务 | Python 3、FastAPI、SQLAlchemy、JWT | 提供 REST API 及异步部署任务引擎 |
| 前端控制台 | JavaScript、React 18、Vite、React Router | 提供图形化管理界面 |
| 界面特性 | — | 专业配色、深色/浅色双主题、中英文双语切换(偏好持久化于本地存储) |

## 三、快速部署

### 3.1 一键启动

执行以下命令可同时启动后端服务与前端控制台:

```bash
bash scripts/dev.sh        # 或 make dev
```

### 3.2 分别启动

```bash
# 后端服务(FastAPI,监听 8000 端口,依赖管理采用 uv)
make installer            # 或 cd installer && uv run cubestack-installer-installer

# 前端控制台(Vite,监听 5173 端口)
make ui                   # 或 cd ui && npm run dev
```

启动完成后,可通过以下地址访问:

- 前端控制台: http://localhost:5173(使用 admin / admin@123 登录)
- 接口文档(Swagger): http://127.0.0.1:8000/docs

### 3.3 常用命令

| 命令 | 说明 |
| --- | --- |
| make build | 构建前端生产包及后端发行包 |
| make test | 运行后端测试(pytest) |
| make stop | 停止全部服务 |

### 3.4 后端依赖管理(uv)

后端依赖采用 uv 管理,常用操作如下:

```bash
cd installer
uv sync                    # 安装依赖并生成 uv.lock
uv add <包名>               # 新增依赖
uv run pytest              # 运行测试
uv run cubestack-installer-installer   # 启动后端服务
uv build                   # 构建 wheel 与 sdist 发行包
```

说明:Python 依赖版本由 uv.lock 锁定,默认使用清华镜像源;前端依赖使用 npmmirror 镜像源。

### 3.5 管理员初始密码

系统首次启动时自动创建管理员账号 admin,初始密码默认为 admin@123。可通过以下方式指定初始密码:

```bash
# 方式一:启动参数(推荐)
uv run cubestack-installer-installer --admin-password '自定义密码'

# 方式二:环境变量
ADMIN_INITIAL_PASSWORD='自定义密码' uv run cubestack-installer-installer
```

说明:初始密码仅在首次创建 admin 账号时生效;账号已存在时,修改密码不影响既有账号。

## 四、部署模式

### 4.1 单端口部署(前后端一体化)

执行 make package 可将前端构建产物打包至后端静态目录,由后端统一托管,仅需启动一个服务即可同时提供页面与接口:

```bash
make package
cd installer && uv run cubestack-installer-installer
```

打包流程为:构建前端生产包 → 将产物复制至 installer/app/static → 生成包含前端产物的发行包。

部署后的路由规则如下:

- `/`:返回前端页面
- `/assets/*`:提供静态资源
- `/api/*`:提供接口服务
- 前端路由(如 /hosts)自动回退至 index.html;Swagger 接口文档不受影响

### 4.2 容器化部署(podman)

根目录 Dockerfile 采用多阶段构建:第一阶段使用 Node 构建前端产物,第二阶段使用 uv 安装后端全部依赖并将前端产物纳入镜像,最终生成自包含镜像。该镜像与 docker 完全兼容。

镜像名:harbor.isuanova.com/cubestack/cubestack-installer:latest

```bash
make image                 # 构建并启动容器
make image-push            # 推送镜像至 Harbor(需预先执行 podman login)

podman build --format docker -t harbor.isuanova.com/cubestack/cubestack-installer:latest .
podman run -d -p 8000:8000 -v csi-data:/app/data --name cubestack-installer harbor.isuanova.com/cubestack/cubestack-installer:latest
podman logs -f cubestack-installer
```

镜像特性:

- 内置全部 Python 依赖(版本由 uv.lock 锁定)及前端构建产物
- 提供健康检查(HEALTHCHECK)
- 容器启动后由 FastAPI 统一托管前端页面与接口
- 数据持久化:建议将数据卷挂载至 /app/data(SQLite 数据文件为 userhub.db);rootless 模式下无需 sudo

说明:使用 docker 时,将上述命令中的 podman 替换为 docker 即可;多服务编排亦可执行 podman compose up -d 或 docker compose up -d 使用根目录 docker-compose.yml。

## 五、宿主机环境检测

添加宿主机或执行环境检测时,平台将通过 SSH 对宿主机执行环境体检,检测项如下:

| 检查项 | 要求 | 校验方式 |
| --- | --- | --- |
| SSH 连通性 | 可登录 | ssh BatchMode + ConnectTimeout=5 |
| 操作系统 | Ubuntu 22.04(ID=ubuntu 且 VERSION_ID 以 22.04 开头) | 解析 /etc/os-release |
| libvirt 依赖 | virt-install / virsh / qemu-img / qemu-kvm / cloud-localds 均需存在 | command -v + dpkg 兜底 |
| libvirtd 服务 | 运行中 | systemctl is-active libvirtd |
| /dev/kvm | 存在(硬件加速) | test -e /dev/kvm |

检测结果以报告形式保存至宿主机记录,包含逐项通过或缺失状态。新增宿主机接口(POST /api/hosts)会自动执行环境检测并返回结果。仿真模式下(DEPLOY_MODE=sim 或无 ssh 工具)返回模拟通过报告,并标注“仿真检测”。

### 5.1 宿主机初始化命令

添加宿主机时,平台提供可复制的初始化脚本,用于在管理机上完成免密配置与依赖安装,执行顺序如下:

1. 通过 ssh-copy-id 将管理机公钥复制至宿主机,实现免密登录
2. 通过 apt-get 安装 libvirt 相关依赖(virtinst / libvirt-clients / qemu-utils / qemu-kvm / cloud-image-utils)
3. 通过 systemctl 启动 libvirtd 服务并设置开机自启
4. 校验 /dev/kvm 是否可用(硬件加速)

脚本根据表单输入的 IP、SSH 用户及端口实时生成;脚本以 ssh-copy-id 为首步,并校验免密配置生效后方执行后续步骤。

## 六、虚拟化后端(Provider 插件化)

平台支持两种虚拟机启动方式,创建虚拟机时可选择后端,由 Provider 工厂按类型分发:

| Provider | 连接方式 | 操作实现 |
| --- | --- | --- |
| Libvirt (virsh) | 宿主机本机 libvirt | virt-install / virsh start/stop/reboot |
| KubeVirt | kubectl + kubeconfig | VirtualMachine CRD:apply / patch /spec/running / delete |

架构说明:

- engine/providers/ 目录定义统一的 VMProvider 接口(create / action / delete / info),通过 get_provider() 工厂按需路由;任务引擎、日志记录及仿真回退机制在各 Provider 间复用
- KubeVirt 配置通过环境变量指定:KUBECONFIG_PATH(默认 ~/.kube/config)、KUBEVIRT_NAMESPACE(默认 default,亦可在创建虚拟机时按虚拟机指定)
- KubeVirt 为每个虚拟机生成 VirtualMachine CRD 清单(含 DataVolume、ContainerDisk 与 PVC),镜像名自动映射至容器磁盘地址,亦支持 docker:// 直连地址
- 未检测到 kubectl/kubeconfig 或执行失败时,自动回退至仿真模式;真实模式受 DEPLOY_MODE 控制

## 七、部署引擎运行模式

后端引擎自动检测宿主机工具链,支持以下两种模式:

| 模式 | 触发条件 | 行为 |
| --- | --- | --- |
| 真实模式 | 检测到 virt-install / ansible-playbook 及 KUBESPRAY_DIR | 调用真实命令创建虚拟机、执行 Kubespray playbook |
| 仿真模式 | 工具缺失或 DEPLOY_MODE=sim | 完整模拟流程步骤与日志,便于开发与演示 |

- DEPLOY_MODE 支持 sim、real、auto 三值,默认 auto
- 真实执行任一步骤失败时,自动回退至仿真模式并记录警告,任务不会中断
- 集群安装过程生成并展示 inventory.ini、组变量及 kubeconfig 输出
- 工作目录为 installer/workspace/(真实模式生成的清单)

## 八、接口规范

除登录与注册外,所有接口请求头需携带 Authorization: Bearer <token>;写操作(创建、删除、部署)需管理员权限。

### 8.1 认证

| 方法 | 路径 | 输入 | 输出 |
| --- | --- | --- | --- |
| POST | /api/auth/register | `{"username","email","password","full_name?"}` | 201 用户对象 |
| POST | /api/auth/login | `{"account","password"}`(用户名或邮箱) | 200 `{"access_token","token_type","user"}` |
| GET | /api/auth/me | - | 200 当前用户 |

### 8.2 宿主机

| 方法 | 路径 | 输入 | 输出 |
| --- | --- | --- | --- |
| GET | /api/hosts | - | 200 主机数组 |
| POST | /api/hosts | `{"name","ip","ssh_user?","ssh_port?","cpu_cores?","memory_gb?","disk_gb?"}` | 201 主机对象(含环境检测结果) |
| POST | /api/hosts/{id}/check | - | 200 主机(状态更新为 online/offline) |
| DELETE | /api/hosts/{id} | - | 200 `{"message"}` |

### 8.3 虚拟机

| 方法 | 路径 | 输入 | 输出 |
| --- | --- | --- | --- |
| GET | /api/vms | - | 200 虚拟机数组(含宿主机信息) |
| POST | /api/vms | `{"name","host_id","cpu","memory_gb","disk_gb","image","auto_ip","ip?"}` | 202 `{"task_id","vm"}`(启动异步任务) |
| POST | /api/vms/{id}/action | `{"action":"start|stop|reboot"}` | 200 虚拟机 |
| DELETE | /api/vms/{id} | - | 200 `{"message"}` |

### 8.4 K8s 集群

| 方法 | 路径 | 输入 | 输出 |
| --- | --- | --- | --- |
| GET | /api/clusters | - | 200 集群数组(含节点统计) |
| POST | /api/clusters | `{"name","k8s_version","network_plugin","kubespray_version","control_plane_vm_ids","worker_vm_ids","ssh_key?"}` | 201 集群对象 |
| GET | /api/clusters/{id} | - | 200 `{"cluster","nodes","last_task"}` |
| POST | /api/clusters/{id}/deploy | - | 202 `{"task_id"}`(启动安装任务) |
| DELETE | /api/clusters/{id} | - | 200 `{"message"}` |

### 8.5 部署任务

| 方法 | 路径 | 输入 | 输出 |
| --- | --- | --- | --- |
| GET | /api/tasks | - | 200 任务数组(含进度与日志摘要) |
| GET | /api/tasks/{id} | - | 200 任务详情(完整日志流) |

### 8.6 用户管理

| 方法 | 路径 | 输入 | 输出 |
| --- | --- | --- | --- |
| GET | /api/users | - | 200 用户数组 |
| PATCH | /api/users/{id} | `{"role"?,"is_active"?,"full_name"?}` | 200 用户 |
| DELETE | /api/users/{id} | - | 200 `{"message"}` |

完整接口输入/输出示例详见 docs/api.md 及应用内“接口参考”页面。

## 九、项目结构

```
cubestack-installer/
├── installer/                     # 后端服务(FastAPI)
│   ├── app/
│   │   ├── main.py                 # 入口及种子数据
│   │   ├── core/                   # config(环境变量) / security(PBKDF2+JWT)
│   │   ├── db/                     # session / base(数据库与会话)
│   │   ├── models/                 # 数据模型(用户/宿主机/虚拟机/集群/节点/任务)
│   │   ├── schemas/                # Pydantic 输入输出契约
│   │   ├── api/                    # deps(鉴权) + routes(业务路由)
│   │   └── engine/                 # 部署引擎
│   │       ├── executor.py         # 异步任务执行器(线程 + 日志流)
│   │       ├── services/           # hostops(环境检测) / kubespray(集群安装)
│   │       └── providers/          # 虚拟化后端:libvirt / kubevirt
│   ├── tests/                      # pytest 冒烟测试
│   ├── app/run.py                  # uv 入口(console script)
│   ├── Dockerfile / pyproject.toml / uv.lock
│   └── requirements.txt            # pip 兼容参考
├── ui/                             # 前端控制台(Vite)
│   ├── src/
│   │   ├── api/                    # API 客户端
│   │   ├── components/             # 侧边栏/弹窗/命令块/Toast 等组件
│   │   ├── pages/                  # 概览/宿主机/虚拟机/集群/任务/接口参考/用户
│   │   ├── context/                # AuthContext
│   │   ├── i18n.jsx / theme.jsx    # 中英文案 / 深浅主题
│   │   └── index.css               # 设计系统
│   ├── Dockerfile + nginx.conf
│   └── vite.config.js
├── scripts/                        # 启动脚本(dev / start-backend / start-frontend)
├── docs/                           # api.md / architecture.md
├── Makefile
├── docker-compose.yml
└── .env.example
```

## 十、CI/CD 流水线

项目根目录提供 .gitlab-ci.yml,代码提交至 GitLab 后自动执行测试:

| 阶段 | 任务 | 说明 |
| --- | --- | --- |
| test | backend-test | 基于 uv 执行后端测试(pytest) |
| test | frontend-build | 执行前端生产构建校验(npm run build) |

说明:流水线当前仅包含测试与构建校验阶段,镜像构建未启用。

## 十一、工程规范

- 包管理:后端依赖采用 uv 管理(uv sync / uv run / uv build),版本由 uv.lock 锁定
- 测试:后端提供 pytest 冒烟测试(make test),覆盖健康检查、注册登录、鉴权及任务流
- 容器化:支持 podman / docker 构建单镜像,亦支持 docker-compose 多服务编排
- 配置:全部环境变量集中声明于 .env.example 与 installer/app/core/config.py
- 文档:docs/api.md(接口契约)与 docs/architecture.md(架构设计)

## 十二、安全设计

- 密码以 PBKDF2-HMAC-SHA256(60 万次迭代 + 随机盐)哈希存储
- 鉴权采用 JWT(HS256,有效期 24 小时);未登录返回 401,越权访问返回 403
- 管理员账号不可被删除、禁用或降级;普通用户不具写操作权限

## 十三、生产部署注意事项

- 须设置 SECRET_KEY 环境变量;管理机安装 libvirt、ansible 及 kubespray 后,系统自动进入真实模式
- 生产环境建议将 SQLite 替换为 PostgreSQL(通过 DATABASE_URL 环境变量指定)
- 前端生产包可由后端直接托管,亦可由 Nginx 代理,并将 /api 反向代理至后端服务
- 容器部署时,建议将数据卷挂载至 /app/data,以保证数据持久化

