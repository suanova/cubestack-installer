# 架构设计文档

## 一、总体架构

```
┌──────────────────────────┐
│  前端 React + Vite(:5173) │  SPA + 双树导航 + i18n + 双主题
└───────────┬──────────────┘
            │ /api(开发期 Vite 代理;生产 Nginx 反代)
┌───────────▼──────────────┐
│  FastAPI(:8000)          │
│  app/                    │
│  ├─ api/       路由层     │  deps 鉴权 + 6 组 routes
│  ├─ core/      配置/安全   │  config.py + security.py(PBKDF2+JWT)
│  ├─ db/        数据库     │  SQLAlchemy + SQLite(可换 PG)
│  ├─ models/    数据模型   │  用户/宿主机/虚拟机/集群/节点/任务
│  ├─ schemas/   Pydantic  │  输入输出契约
│  └─ engine/    部署引擎   │
│     ├─ executor.py       │  异步任务执行器(线程 + 日志流)
│     ├─ services/         │  hostops(环境检测) / kubespray(集群安装)
│     └─ providers/        │  虚拟化后端:libvirt / kubevirt
└───────────┬──────────────┘
            │
   ┌────────┴──────────┐
   ▼                   ▼
 宿主机(libvirt)   目标 K8s 集群(KubeVirt)
```

通信方式说明:

- 开发环境下,前端通过 Vite 代理将 /api 请求转发至后端服务
- 生产环境下,可由后端统一托管前端静态资源(单端口部署),亦可由 Nginx 反向代理

单端口部署模式:执行 make package 可将前端构建产物纳入后端静态目录(app/static),由 FastAPI 统一托管,仅需一个服务端口即可同时提供页面与接口。

## 二、核心设计

### 2.1 双虚拟化后端(Provider 插件化)

系统定义统一的 VMProvider 接口(create / action / delete / info),按 provider 字段路由至相应实现:

- Libvirt:基于宿主机本机 virt-install / virsh 实现
- KubeVirt:基于 kubectl 操作 VirtualMachine CRD(含 DataVolume 与 ContainerDisk)

新增虚拟化后端时,仅在 engine/providers/ 目录新增实现类并注册至工厂即可,无需修改其他模块。

### 2.2 仿真/真实双模式

DEPLOY_MODE 环境变量支持 auto、real、sim 三值:

- 检测到工具链时,系统执行真实操作
- 工具缺失或执行失败时,系统自动回退至仿真模式,并在日志中标注 [模式] 与 [警告]

### 2.3 异步任务引擎

虚拟机创建与集群安装任务由后台线程执行,逐步写入 log_text 与 progress 字段;前端通过轮询机制实时展示任务进度与日志。

### 2.4 宿主机环境检测

系统通过 SSH 对宿主机执行环境检查,包括操作系统版本(Ubuntu 22.04)、libvirt 依赖、libvirtd 服务状态及 /dev/kvm 设备,检测结果以 JSON 报告形式入库。

## 三、目录结构

```
cubestack-installer/
├── installer/                # 后端服务(FastAPI)
│   ├── app/
│   │   ├── main.py         # 入口及种子数据
│   │   ├── core/           # config / security
│   │   ├── db/             # session / base
│   │   ├── models/         # 数据模型
│   │   ├── schemas/        # Pydantic 契约
│   │   ├── api/            # deps + routes(6 组)
│   │   └── engine/         # executor / services / providers
│   ├── tests/              # pytest 冒烟测试
│   ├── app/run.py          # uv 入口(console script)
│   ├── Dockerfile
│   ├── pyproject.toml
│   └── uv.lock             # 依赖锁文件
├── ui/                     # 前端控制台(Vite)
│   ├── src/
│   │   ├── api/            # API 客户端
│   │   ├── components/     # 侧边栏/弹窗/命令块/Toast 等组件
│   │   ├── pages/          # 概览/宿主机/虚拟机/集群/任务/接口参考/用户
│   │   ├── context/        # AuthContext
│   │   ├── i18n.jsx        # 中英文案
│   │   └── theme.jsx       # 深浅主题
│   ├── Dockerfile + nginx.conf
│   └── vite.config.js      # /api 代理
├── scripts/                # 开发启动脚本(dev / start-backend / start-frontend)
├── deployments/scripts/    # 部署脚本(14 脚本, 从0到1离线部署 kubespray)
├── docs/                   # api.md / architecture.md
├── Makefile
├── docker-compose.yml
└── .env.example
```

## 四、配置参考

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| SECRET_KEY | dev 默认值 | JWT 签名密钥(生产环境须修改) |
| TOKEN_EXPIRE_MINUTES | 1440 | 令牌有效期(分钟) |
| DATABASE_URL | sqlite:///./userhub.db | 数据库连接地址 |
| DEPLOY_MODE | auto | 部署模式:auto / real / sim |
| KUBECONFIG_PATH | ~/.kube/config | KubeVirt 目标集群 kubeconfig |
| KUBEVIRT_NAMESPACE | default | KubeVirt 默认命名空间 |

