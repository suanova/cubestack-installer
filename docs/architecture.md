# 架构说明

## 总体架构

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

> 单端口部署:make package 将 UI 构建产物打进 installer(app/static),FastAPI 直接托管前端,起一个端口即可兼顾页面(/)与接口(/api)。

## 核心设计

### 1. 双虚拟化后端(Provider 插件化)

统一 `VMProvider` 接口(`create / action / delete / info`),按 `provider` 字段路由:

- **Libvirt**: 宿主机本机 `virt-install / virsh`
- **KubeVirt**: `kubectl` 操作 `VirtualMachine` CRD(DataVolume + ContainerDisk)

新增后端只需在 `engine/providers/` 添加一个类并注册到工厂。

### 2. 仿真/真实双模式

`DEPLOY_MODE=auto|real|sim`:
- 检测到工具链 → 真实执行
- 缺失或执行失败 → 自动回退仿真(日志标注 `[模式]` 与 `[警告]`)

### 3. 异步任务引擎

线程执行 VM 创建 / 集群安装,逐步写 `log_text` 与 `progress`,前端轮询实时展示。

### 4. 宿主机环境检测

SSH 检查:Ubuntu 22.04 + libvirt 依赖 + libvirtd + /dev/kvm,结果入库(JSON 报告)。

## 目录结构

```
cubestack-installer/
├── installer/                # Python 后端
│   ├── app/
│   │   ├── main.py         # FastAPI 入口 + 种子数据
│   │   ├── core/           # config / security
│   │   ├── db/             # session / base
│   │   ├── models/         # 数据模型
│   │   ├── schemas/        # Pydantic 契约
│   │   ├── api/            # deps + routes(6 组)
│   │   └── engine/         # executor / services / providers
│   ├── tests/              # pytest 冒烟测试
│   ├── app/run.py           # uv 入口
│   ├── Dockerfile
│   ├── pyproject.toml
│   └── uv.lock              # uv 依赖锁
├── ui/               # React 前端
│   ├── src/
│   │   ├── api/            # API 客户端
│   │   ├── components/     # 侧边栏/弹窗/命令块/Toast...
│   │   ├── pages/          # 概览/宿主机/虚拟机/集群/任务/接口参考/用户
│   │   ├── context/        # AuthContext
│   │   ├── i18n.jsx        # 中英文案
│   │   └── theme.jsx       # 深浅主题
│   ├── Dockerfile + nginx.conf
│   └── vite.config.js      # /api 代理
├── scripts/                # dev / start-installer / start-ui
├── docs/                   # api.md / architecture.md
├── Makefile
├── docker-compose.yml
└── .env.example
```

## 配置参考

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| SECRET_KEY | dev 默认值 | JWT 签名密钥(生产必改) |
| TOKEN_EXPIRE_MINUTES | 1440 | 令牌有效期(分钟) |
| DATABASE_URL | sqlite:///./userhub.db | 数据库连接 |
| DEPLOY_MODE | auto | auto / real / sim |
| KUBECONFIG_PATH | ~/.kube/config | KubeVirt 目标集群 |
| KUBEVIRT_NAMESPACE | default | KubeVirt 默认命名空间 |

