"""集中式配置:全部环境变量在此声明,便于部署与文档化。"""
import os


def _env(key: str, default: str) -> str:
    return os.environ.get(key, default)


# 安全
SECRET_KEY = _env("SECRET_KEY", "cubestackinstaller-dev-secret-change-me-in-prod")
TOKEN_EXPIRE_MINUTES = int(_env("TOKEN_EXPIRE_MINUTES", "1440"))

# 数据库
DATABASE_URL = _env("DATABASE_URL", "sqlite:///./userhub.db")

# 管理员初始密码(首次启动创建 admin 时生效;默认 admin@123)
ADMIN_INITIAL_PASSWORD = _env("ADMIN_INITIAL_PASSWORD", "admin@123")

# 部署引擎
DEPLOY_MODE = _env("DEPLOY_MODE", "auto")  # auto | real | sim

# MinIO 对象存储(虚拟机模板镜像源,桶 cubestack 前缀 installer/vm)
MINIO_ENDPOINT = _env("MINIO_ENDPOINT", "10.66.1.207:9000")  # host:port,不含协议(内网 MinIO)
MINIO_ACCESS_KEY = _env("MINIO_ACCESS_KEY", "admin")
MINIO_SECRET_KEY = _env("MINIO_SECRET_KEY", "Suanova@123")
MINIO_BUCKET = _env("MINIO_BUCKET", "cubestack")
MINIO_PREFIX = _env("MINIO_PREFIX", "installer/vm")
MINIO_REGION = _env("MINIO_REGION", "us-east-1")
MINIO_SECURE = _env("MINIO_SECURE", "false").lower() == "true"

# KubeVirt 接入
KUBECONFIG_PATH = _env("KUBECONFIG_PATH", os.path.expanduser("~/.kube/config"))
KUBEVIRT_NAMESPACE = _env("KUBEVIRT_NAMESPACE", "default")