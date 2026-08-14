"""集中式配置:全部环境变量在此声明,便于部署与文档化。"""
import os


def _env(key: str, default: str) -> str:
    return os.environ.get(key, default)


# 安全
SECRET_KEY = _env("SECRET_KEY", "cubestackinstaller-dev-secret-change-me-in-prod")
TOKEN_EXPIRE_MINUTES = int(_env("TOKEN_EXPIRE_MINUTES", "1440"))

# 数据库
DATABASE_URL = _env("DATABASE_URL", "sqlite:///./userhub.db")

# 部署引擎
DEPLOY_MODE = _env("DEPLOY_MODE", "auto")  # auto | real | sim

# KubeVirt 接入
KUBECONFIG_PATH = _env("KUBECONFIG_PATH", os.path.expanduser("~/.kube/config"))
KUBEVIRT_NAMESPACE = _env("KUBEVIRT_NAMESPACE", "default")
