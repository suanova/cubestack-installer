from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from ..deps import get_current_user, get_db, require_admin
from ...engine.executor import start_task
from ...engine.providers import get_provider, list_providers
from ...models import DeployTask, Host, User, VirtualMachine
from ...schemas import (
    MessageOut,
    ProviderInfoOut,
    VmActionIn,
    VmCreateIn,
    VmCreateResult,
    VmOut,
)

router = APIRouter(prefix="/api/vms", tags=["vms"])


def _to_out(vm: VirtualMachine, db: Session) -> VmOut:
    out = VmOut.model_validate(vm)
    host = db.get(Host, vm.host_id)
    if host:
        out.host_name = host.name
        out.host_ip = host.ip
    return out


@router.get("/providers", response_model=list[ProviderInfoOut])
def vm_providers(_: User = Depends(get_current_user)):
    """虚拟化后端状态(libvirt / kubevirt 可用性与模式)。"""
    return [ProviderInfoOut.model_validate(p) for p in list_providers()]


@router.get("", response_model=list[VmOut])
def list_vms(db: Session = Depends(get_db), _: User = Depends(get_current_user)) -> list[VmOut]:
    vms = db.query(VirtualMachine).order_by(VirtualMachine.id).all()
    return [_to_out(vm, db) for vm in vms]


@router.post("", response_model=VmCreateResult, status_code=202)
def create_vm(
    payload: VmCreateIn,
    db: Session = Depends(get_db),
    _: User = Depends(require_admin),
) -> VmCreateResult:
    if db.query(VirtualMachine).filter(VirtualMachine.name == payload.name).first():
        raise HTTPException(status_code=409, detail="虚拟机名称已存在")
    if db.get(Host, payload.host_id) is None:
        raise HTTPException(status_code=400, detail="宿主机不存在")
    vm = VirtualMachine(
        name=payload.name,
        host_id=payload.host_id,
        cpu=payload.cpu,
        memory_gb=payload.memory_gb,
        disk_gb=payload.disk_gb,
        image=payload.image,
        provider=payload.provider,
        namespace=payload.namespace,
        ip=payload.ip if (not payload.auto_ip) else None,
        status="pending",
    )
    db.add(vm)
    db.commit()
    db.refresh(vm)

    task = DeployTask(
        type="vm_create", target_id=vm.id, target_name=vm.name, status="pending"
    )
    db.add(task)
    db.commit()
    db.refresh(task)
    start_task(task.id)
    return VmCreateResult(task_id=task.id, vm=_to_out(vm, db))


@router.post("/{vm_id}/action", response_model=VmOut)
def vm_action(
    vm_id: int,
    payload: VmActionIn,
    db: Session = Depends(get_db),
    _: User = Depends(require_admin),
) -> VmOut:
    vm = db.get(VirtualMachine, vm_id)
    if vm is None:
        raise HTTPException(status_code=404, detail="虚拟机不存在")
    if payload.action == "start" and vm.status == "running":
        raise HTTPException(status_code=400, detail="虚拟机已在运行")
    if payload.action == "stop" and vm.status == "stopped":
        raise HTTPException(status_code=400, detail="虚拟机已停止")
    provider = get_provider(vm.provider)
    provider.action(vm, payload.action)
    db.commit()
    db.refresh(vm)
    return _to_out(vm, db)


@router.delete("/{vm_id}", response_model=MessageOut)
def delete_vm(
    vm_id: int,
    db: Session = Depends(get_db),
    _: User = Depends(require_admin),
) -> MessageOut:
    vm = db.get(VirtualMachine, vm_id)
    if vm is None:
        raise HTTPException(status_code=404, detail="虚拟机不存在")
    get_provider(vm.provider).delete(vm)
    db.delete(vm)
    db.commit()
    return MessageOut(message="虚拟机已删除")
