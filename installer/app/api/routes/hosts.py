from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from ..deps import get_current_user, get_db, require_admin
from ...engine.services.hostops import apply_report, check_host, check_host_env
from ...models import Host, User
from ...schemas import HostIn, HostOut, MessageOut

router = APIRouter(prefix="/api/hosts", tags=["hosts"])


@router.get("", response_model=list[HostOut])
def list_hosts(db: Session = Depends(get_db), _: User = Depends(get_current_user)) -> list[Host]:
    return db.query(Host).order_by(Host.id).all()


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
