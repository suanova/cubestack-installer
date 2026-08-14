import os
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from .api import api_router
from .db.session import SessionLocal, init_db
from .models import Host, User, VirtualMachine
from .core.security import hash_password


def seed_data() -> None:
    """首次启动种子数据:默认管理员 + 演示宿主机与虚拟机。"""
    db = SessionLocal()
    try:
        if db.query(User).filter(User.username == "admin").first() is None:
            db.add(
                User(
                    username="admin",
                    email="admin@example.com",
                    full_name="系统管理员",
                    hashed_password=hash_password("admin123"),
                    role="admin",
                )
            )
        if db.query(Host).count() == 0:
            import json as _json
            from datetime import datetime, timezone as _tz
            _sim = {
                "simulated": True,
                "ssh": "ok",
                "os": {"detected": "Ubuntu 22.04.4 LTS (仿真)", "ok": True},
                "packages": {
                    "required": ["virt-install", "virsh", "qemu-img", "qemu-kvm", "cloud-localds"],
                    "installed": ["virt-install", "virsh", "qemu-img", "qemu-kvm", "cloud-localds"],
                    "missing": [],
                    "ok": True,
                },
                "libvirtd": {"active": True, "detail": "libvirtd.service active (running) [仿真]"},
                "kvm": {"present": True, "detail": "/dev/kvm 存在 [仿真]"},
            }
            _now = datetime.now(_tz.utc)
            db.add_all([
                Host(name="node1", ip="192.168.10.11", ssh_user="ubuntu", ssh_port=22,
                     status="online", cpu_cores=16, memory_gb=64, disk_gb=1024, is_demo=True,
                     os_name="Ubuntu 22.04.4 LTS (仿真)", os_ok=True, libvirt_ready=True,
                     check_report=_json.dumps(_sim, ensure_ascii=False), last_checked_at=_now),
                Host(name="node2", ip="192.168.10.12", ssh_user="ubuntu", ssh_port=22,
                     status="online", cpu_cores=32, memory_gb=128, disk_gb=2048, is_demo=True,
                     os_name="Ubuntu 22.04.4 LTS (仿真)", os_ok=True, libvirt_ready=True,
                     check_report=_json.dumps(_sim, ensure_ascii=False), last_checked_at=_now),
            ])
        if db.query(VirtualMachine).count() == 0:
            db.add_all([
                VirtualMachine(name="k8s-master-1", host_id=1, cpu=4, memory_gb=8, disk_gb=40,
                               image="ubuntu-22.04-cloud.qcow2", ip="192.168.10.101",
                               status="running", is_demo=True),
                VirtualMachine(name="k8s-node-1", host_id=1, cpu=8, memory_gb=16, disk_gb=80,
                               image="ubuntu-22.04-cloud.qcow2", ip="192.168.10.102",
                               status="running", is_demo=True),
                VirtualMachine(name="k8s-node-2", host_id=2, cpu=8, memory_gb=16, disk_gb=80,
                               image="ubuntu-22.04-cloud.qcow2", ip="192.168.10.103",
                               status="running", is_demo=True),
            ])
        db.commit()
    finally:
        db.close()


@asynccontextmanager
async def lifespan(_: FastAPI):
    init_db()
    seed_data()
    yield


app = FastAPI(
    title="CubeStackInstaller API",
    description="虚拟机安装 + Kubespray 部署 K8s 集群 平台",
    version="2.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(api_router)


@app.get("/api/health", tags=["meta"])
def health() -> dict:
    return {"status": "ok", "service": "cubestackinstaller-api"}


# ---- 单端口托管:承载打包进来的前端静态资源(SPA) ----
STATIC_DIR = os.path.join(os.path.dirname(__file__), "static")
_has_static = os.path.isdir(os.path.join(STATIC_DIR, "assets"))

if _has_static:
    app.mount("/assets", StaticFiles(directory=os.path.join(STATIC_DIR, "assets")), name="assets")

    @app.get("/{full_path:path}", include_in_schema=False)
    def serve_spa(full_path: str):
        # 命中真实文件(如 favicon)则直接返回,否则回退到 index.html 支持前端路由
        candidate = os.path.join(STATIC_DIR, full_path) if full_path else ""
        if full_path and os.path.isfile(candidate):
            return FileResponse(candidate)
        return FileResponse(os.path.join(STATIC_DIR, "index.html"))
