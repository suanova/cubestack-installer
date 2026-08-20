from fastapi import APIRouter, Depends, HTTPException, Response
from sqlalchemy.orm import Session

from ..deps import get_current_user, get_db, require_admin
from ...engine.executor import start_task
from ...models import ClusterNode, DeployTask, Host, K8sCluster, User, VirtualMachine
from ...schemas import (
    ClusterCreateIn,
    ClusterDetailOut,
    ClusterOut,
    ClusterScaleIn,
    DeployResult,
    MessageOut,
    NodeOut,
    TaskBriefOut,
)

router = APIRouter(prefix="/api/clusters", tags=["clusters"])


def _to_out(cluster: K8sCluster, db: Session) -> ClusterOut:
    out = ClusterOut.model_validate(cluster)
    nodes = db.query(ClusterNode).filter(ClusterNode.cluster_id == cluster.id).all()
    out.control_plane_count = len([n for n in nodes if n.role == "control_plane"])
    out.worker_count = len([n for n in nodes if n.role == "worker"])
    out.has_kubeconfig = bool(cluster.kubeconfig)
    if cluster.run_node_host_id:
        run_host = db.get(Host, cluster.run_node_host_id)
        if run_host is not None:
            out.run_node_name = run_host.name + " (" + run_host.ip + ")"
    return out


def _last_task(cluster_id: int, db: Session) -> DeployTask | None:
    return (
        db.query(DeployTask)
        .filter(DeployTask.target_id == cluster_id, DeployTask.type.in_(["cluster_install", "cluster_scale"]))
        .order_by(DeployTask.id.desc())
        .first()
    )


@router.get("", response_model=list[ClusterOut])
def list_clusters(db: Session = Depends(get_db), _: User = Depends(get_current_user)) -> list[ClusterOut]:
    clusters = db.query(K8sCluster).order_by(K8sCluster.id).all()
    return [_to_out(c, db) for c in clusters]


@router.post("", response_model=ClusterOut, status_code=201)
def create_cluster(
    payload: ClusterCreateIn,
    db: Session = Depends(get_db),
    _: User = Depends(require_admin),
) -> ClusterOut:
    if db.query(K8sCluster).filter(K8sCluster.name == payload.name).first():
        raise HTTPException(status_code=409, detail="集群名称已存在")
    cp_ids = set(payload.control_plane_vm_ids) | set(payload.control_plane_host_ids)
    wk_ids = set(payload.worker_vm_ids) | set(payload.worker_host_ids)
    if len(cp_ids) < 3:
        raise HTTPException(status_code=400, detail="控制平面至少需要 3 个节点")
    if cp_ids & wk_ids:
        raise HTTPException(status_code=400, detail="控制平面与工作节点不能重复选择")
    all_vm_ids = set(payload.control_plane_vm_ids) | set(payload.worker_vm_ids)
    all_host_ids = set(payload.control_plane_host_ids) | set(payload.worker_host_ids)
    vms = db.query(VirtualMachine).filter(VirtualMachine.id.in_(all_vm_ids)).all() if all_vm_ids else []
    if len(vms) != len(all_vm_ids):
        raise HTTPException(status_code=400, detail="存在无效的虚拟机选择")
    hosts = db.query(Host).filter(Host.id.in_(all_host_ids)).all() if all_host_ids else []
    if len(hosts) != len(all_host_ids):
        raise HTTPException(status_code=400, detail="存在无效的宿主机选择")
    taken_vm = db.query(ClusterNode.vm_id).filter(ClusterNode.vm_id.in_(all_vm_ids)).all() if all_vm_ids else []
    taken_host = db.query(ClusterNode.host_id).filter(ClusterNode.host_id.in_(all_host_ids)).all() if all_host_ids else []
    if taken_vm or taken_host:
        raise HTTPException(status_code=400, detail="部分节点已被其他集群纳入管理")
    if payload.run_node_host_id is not None:
        run_host = db.get(Host, payload.run_node_host_id)
        if run_host is None:
            raise HTTPException(status_code=400, detail="Kubespray 运行节点不存在(宿主机 ID 无效)")

    cluster = K8sCluster(
        name=payload.name,
        k8s_version=payload.k8s_version,
        network_plugin=payload.network_plugin,
        kubespray_version=payload.kubespray_version,
        run_node_host_id=payload.run_node_host_id,
        ssh_key=payload.ssh_key,
        status="pending",
    )
    db.add(cluster)
    db.commit()
    db.refresh(cluster)

    for vm in vms:
        role = "control_plane" if vm.id in payload.control_plane_vm_ids else "worker"
        db.add(
            ClusterNode(
                cluster_id=cluster.id,
                vm_id=vm.id,
                node_type="vm",
                name=vm.name,
                ip=vm.ip,
                role=role,
            )
        )
    for h in hosts:
        role = "control_plane" if h.id in payload.control_plane_host_ids else "worker"
        db.add(
            ClusterNode(
                cluster_id=cluster.id,
                host_id=h.id,
                node_type="host",
                name=h.name,
                ip=h.ip,
                role=role,
            )
        )
    db.commit()
    return _to_out(cluster, db)


@router.get("/{cluster_id}", response_model=ClusterDetailOut)
def cluster_detail(
    cluster_id: int,
    db: Session = Depends(get_db),
    _: User = Depends(get_current_user),
) -> ClusterDetailOut:
    cluster = db.get(K8sCluster, cluster_id)
    if cluster is None:
        raise HTTPException(status_code=404, detail="集群不存在")
    nodes = db.query(ClusterNode).filter(ClusterNode.cluster_id == cluster.id).all()
    last = _last_task(cluster_id, db)
    return ClusterDetailOut(
        cluster=_to_out(cluster, db),
        nodes=[NodeOut.model_validate(n) for n in nodes],
        last_task=TaskBriefOut.model_validate(last) if last else None,
    )


@router.get("/{cluster_id}/kubeconfig")
def download_cluster_kubeconfig(
    cluster_id: int,
    db: Session = Depends(get_db),
    _: User = Depends(get_current_user),
) -> Response:
    """下载集群 kubeconfig(admin.conf 内容,已入库)。"""
    cluster = db.get(K8sCluster, cluster_id)
    if cluster is None:
        raise HTTPException(status_code=404, detail="集群不存在")
    if not cluster.kubeconfig:
        raise HTTPException(status_code=404, detail="该集群暂无 kubeconfig(可能未安装成功)")
    return Response(
        content=cluster.kubeconfig,
        media_type="application/yaml",
        headers={"Content-Disposition": 'attachment; filename="kubeconfig-' + cluster.name + '.conf"'},
    )


def _start_cluster_task(cluster_id: int, task_type: str, action_name: str, db: Session) -> DeployTask:
    cluster = db.get(K8sCluster, cluster_id)
    if cluster is None:
        raise HTTPException(status_code=404, detail="集群不存在")
    running = (
        db.query(DeployTask)
        .filter(
            DeployTask.target_id == cluster_id,
            DeployTask.type == task_type,
            DeployTask.status.in_(["pending", "running"]),
        )
        .first()
    )
    if running:
        raise HTTPException(status_code=400, detail=action_name + "任务正在进行中")
    task = DeployTask(
        type=task_type, target_id=cluster.id, target_name=cluster.name, status="pending"
    )
    db.add(task)
    db.commit()
    db.refresh(task)
    start_task(task.id)
    return task


@router.post("/{cluster_id}/prepare", response_model=DeployResult, status_code=202)
def prepare_cluster(
    cluster_id: int,
    db: Session = Depends(get_db),
    _: User = Depends(require_admin),
) -> DeployResult:
    """向导第一步:检查/配置安装机环境(uv + Python3.12 + Ansible)。"""
    cluster = db.get(K8sCluster, cluster_id)
    if cluster is None:
        raise HTTPException(status_code=404, detail="集群不存在")
    if not cluster.run_node_host_id:
        raise HTTPException(status_code=400, detail="请先为集群选择 Kubespray 运行节点(宿主机)")
    task = _start_cluster_task(cluster_id, "cluster_prepare", "环境准备", db)
    return DeployResult(task_id=task.id)


@router.post("/{cluster_id}/sshkey", response_model=DeployResult, status_code=202)
def sshkey_cluster(
    cluster_id: int,
    db: Session = Depends(get_db),
    _: User = Depends(require_admin),
) -> DeployResult:
    """向导第二步:在安装机生成公钥并免密到所有集群节点。"""
    cluster = db.get(K8sCluster, cluster_id)
    if cluster is None:
        raise HTTPException(status_code=404, detail="集群不存在")
    if not cluster.run_node_host_id:
        raise HTTPException(status_code=400, detail="请先为集群选择 Kubespray 运行节点(宿主机)")
    task = _start_cluster_task(cluster_id, "cluster_sshkey", "SSH 免密配置", db)
    return DeployResult(task_id=task.id)


@router.post("/{cluster_id}/scale", response_model=DeployResult, status_code=202)
def scale_cluster(
    cluster_id: int,
    payload: ClusterScaleIn,
    db: Session = Depends(get_db),
    _: User = Depends(require_admin),
) -> DeployResult:
    """向已有集群添加节点(扩容): 记录新节点 -> 生成任务调 scale playbook。"""
    cluster = db.get(K8sCluster, cluster_id)
    if cluster is None:
        raise HTTPException(status_code=404, detail="集群不存在")
    if cluster.status != "ready":
        raise HTTPException(status_code=400, detail="集群未就绪,无法扩容")
    if not cluster.run_node_host_id:
        raise HTTPException(status_code=400, detail="该集群未配置 Kubespray 运行节点,无法扩容")
    if payload.control_plane_vm_ids or payload.control_plane_host_ids:
        raise HTTPException(status_code=400, detail="扩容暂不支持增加控制平面节点,仅支持工作节点")
    cp_vm_ids = set(payload.control_plane_vm_ids)
    cp_host_ids = set(payload.control_plane_host_ids)
    wk_vm_ids = set(payload.worker_vm_ids)
    wk_host_ids = set(payload.worker_host_ids)
    all_vm_ids = cp_vm_ids | wk_vm_ids
    all_host_ids = cp_host_ids | wk_host_ids
    if not all_vm_ids and not all_host_ids:
        raise HTTPException(status_code=400, detail="请至少选择一个要加入集群的节点")
    if cp_vm_ids & wk_vm_ids or cp_host_ids & wk_host_ids:
        raise HTTPException(status_code=400, detail="同一节点不能同时作为控制平面和工作节点")
    vms = db.query(VirtualMachine).filter(VirtualMachine.id.in_(all_vm_ids)).all() if all_vm_ids else []
    if len(vms) != len(all_vm_ids):
        raise HTTPException(status_code=400, detail="存在无效的虚拟机选择")
    hosts = db.query(Host).filter(Host.id.in_(all_host_ids)).all() if all_host_ids else []
    if len(hosts) != len(all_host_ids):
        raise HTTPException(status_code=400, detail="存在无效的宿主机选择")
    # 允许选择已被其他集群/本集群纳管的节点(如状态过期需重新加入); 同集群已有记录自动去重
    for vm in vms:
        role = "control_plane" if vm.id in cp_vm_ids else "worker"
        dup = db.query(ClusterNode).filter(ClusterNode.cluster_id == cluster.id, ClusterNode.vm_id == vm.id).first()
        if dup is None:
            db.add(ClusterNode(cluster_id=cluster.id, vm_id=vm.id, node_type="vm", name=vm.name, ip=vm.ip, role=role))
    for h in hosts:
        role = "control_plane" if h.id in cp_host_ids else "worker"
        dup = db.query(ClusterNode).filter(ClusterNode.cluster_id == cluster.id, ClusterNode.host_id == h.id).first()
        if dup is None:
            db.add(ClusterNode(cluster_id=cluster.id, host_id=h.id, node_type="host", name=h.name, ip=h.ip, role=role))
    db.commit()
    task = _start_cluster_task(cluster_id, "cluster_scale", "扩容", db)
    return DeployResult(task_id=task.id)


@router.post("/{cluster_id}/deploy", response_model=DeployResult, status_code=202)
def deploy_cluster(
    cluster_id: int,
    db: Session = Depends(get_db),
    _: User = Depends(require_admin),
) -> DeployResult:
    cluster = db.get(K8sCluster, cluster_id)
    if cluster is None:
        raise HTTPException(status_code=404, detail="集群不存在")
    task = _start_cluster_task(cluster_id, "cluster_install", "集群安装", db)
    return DeployResult(task_id=task.id)


@router.delete("/{cluster_id}", response_model=MessageOut)
def delete_cluster(
    cluster_id: int,
    db: Session = Depends(get_db),
    _: User = Depends(require_admin),
) -> MessageOut:
    cluster = db.get(K8sCluster, cluster_id)
    if cluster is None:
        raise HTTPException(status_code=404, detail="集群不存在")
    db.query(ClusterNode).filter(ClusterNode.cluster_id == cluster_id).delete()
    db.delete(cluster)
    db.commit()
    return MessageOut(message="集群已删除")
