"""测试夹具:隔离数据库(临时文件)+ 仿真模式 + TestClient。"""
import os
import tempfile

_fd, _path = tempfile.mkstemp(suffix=".db")
os.close(_fd)
os.environ["DATABASE_URL"] = "sqlite:///" + _path
os.environ["DEPLOY_MODE"] = "sim"

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from app.main import app  # noqa: E402


@pytest.fixture(scope="session")
def client():
    with TestClient(app) as c:
        yield c
