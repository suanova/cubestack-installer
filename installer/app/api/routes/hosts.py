import json
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from ..deps import get_current_user, get_db, require_admin
from ...engine.services.hostops import apply_report, check_host, check_host_env
from ...models import ClusterNode, Host, User
from ...schemas import HostIn, HostOut, MessageOut

router = APIRouter(prefix="/api/hosts", tags=["hosts"])


class _ProbeHost:
    """瞬态探测对象:仅承载连接信息,不落库。"""

    __slots__ = ("ip", "ssh_user", "ssh_port")

    def __init__(self, ip: str, ssh_user: str, ssh_port: int) -> None:
        self.ip = ip
        self.ssh_user = ssh_user
        self.ssh_port = ssh_port


@router.post("/precheck", response_model=HostOut)
def precheck_host(
    payload: HostIn,
    _: User = Depends(get_current_user),
) -> HostOut:
    """添加向导预检:按输入的连接信息执行环境检测(免密连通性 + Ubuntu/libvirt),不落库。

    用于「添加宿主机」向导的『验证免密』与『环境预检』步骤,
    避免在未完成初始化前就创建宿主机记录。
    """
    probe = _ProbeHost(payload.ip, payload.ssh_user, payload.ssh_port)
    status, report = check_host_env(probe)
    now = datetime.now(timezone.utc)
    return HostOut(
        id=0,
        name=payload.name,
        ip=payload.ip,
        ssh_user=payload.ssh_user,
        ssh_port=payload.ssh_port,
        status=status,
        cpu_cores=payload.cpu_cores,
        memory_gb=payload.memory_gb,
        disk_gb=payload.disk_gb,
        os_name=report.get("os", {}).get("detected"),
        os_ok=bool(report.get("os", {}).get("ok")),
        libvirt_ready=bool(report.get("packages", {}).get("ok")),
        check_report=json.dumps(report, ensure_ascii=False),
        last_checked_at=now,
        is_demo=False,
        created_at=now,
    )


def _to_out(h: Host, db: Session) -> HostOut:
    out = HostOut.model_validate(h)
    out.in_cluster = db.query(ClusterNode.id).filter(ClusterNode.host_id == h.id).first() is not None
    return out


@router.get("", response_model=list[HostOut])
def list_hosts(db: Session = Depends(get_db), _: User = Depends(get_current_user)) -> list[HostOut]:
    return [_to_out(h, db) for h in db.query(Host).order_by(Host.id).all()]


@router.post("", response_model=HostOut, status_code=201)
def create_host(
    payload: HostIn,
    db: Session = Depends(get_db),
    _: User = Depends(require_admin),
) -> Host:
    """添加宿主机并立即执行环境检测(Ubuntu 22.04 + libvirt 依赖)。"""
    if db.query(Host).filter(Host.name == payload.name).first():
        raise HTTPException(status_code=409, detail="主机名称已存在")
    host = Host(
        name=payload.name,
        ip=payload.ip,
        ssh_user=payload.ssh_user,
        ssh_port=payload.ssh_port,
        cpu_cores=payload.cpu_cores,
        memory_gb=payload.memory_gb,
        disk_gb=payload.disk_gb,
        status="unknown",
    )
    db.add(host)
    db.commit()
    db.refresh(host)

    # 自动环境检测(同步执行,SSH 超时约 10s)
    status, report = check_host_env(host)
    apply_report(host, status, report)
    db.commit()
    db.refresh(host)
    return host


@router.post("/{host_id}/check", response_model=HostOut)
def check_host_connectivity(
    host_id: int,
    db: Session = Depends(get_db),
    _: User = Depends(get_current_user),
) -> Host:
    """宿主机环境检测:操作系统(要求 Ubuntu 22.04)+ libvirt 依赖齐全性。"""
    host = db.get(Host, host_id)
    if host is None:
        raise HTTPException(status_code=404, detail="宿主机不存在")
    status, report = check_host_env(host)
    apply_report(host, status, report)
    db.commit()
    db.refresh(host)
    return host


@router.delete("/{host_id}", response_model=MessageOut)
def delete_host(
    host_id: int,
    db: Session = Depends(get_db),
    _: User = Depends(require_admin),
) -> MessageOut:
    host = db.get(Host, host_id)
    if host is None:
        raise HTTPException(status_code=404, detail="宿主机不存在")
    db.delete(host)
    db.commit()
    return MessageOut(message="宿主机已删除")
