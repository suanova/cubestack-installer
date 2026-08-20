from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, EmailStr, Field

# ---------- 认证 ----------

class RegisterIn(BaseModel):
    username: str = Field(min_length=3, max_length=50)
    email: EmailStr
    password: str = Field(min_length=6, max_length=128)
    full_name: str | None = Field(default=None, max_length=100)


class LoginIn(BaseModel):
    account: str = Field(description="用户名或邮箱")
    password: str


class UserOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    username: str
    email: str
    full_name: str | None
    role: str
    is_active: bool
    status: str
    created_at: datetime


class TokenOut(BaseModel):
    access_token: str
    token_type: str = "bearer"
    user: UserOut


class UserUpdateIn(BaseModel):
    role: str | None = Field(default=None, pattern="^(admin|user)$")
    is_active: bool | None = None
    status: str | None = Field(default=None, pattern="^(pending|active|disabled)$")
    full_name: str | None = Field(default=None, max_length=100)


class UserCreateIn(BaseModel):
    username: str = Field(min_length=3, max_length=50)
    email: str = Field(max_length=120)
    password: str = Field(min_length=6, max_length=128)
    full_name: str | None = Field(default=None, max_length=100)
    role: str = Field(default="user", pattern="^(admin|user)$")


class MessageOut(BaseModel):
    message: str


# ---------- 宿主机 ----------

class HostIn(BaseModel):
    name: str = Field(min_length=2, max_length=80, description="主机名称")
    ip: str = Field(min_length=7, max_length=64, description="管理 IP 地址")
    ssh_user: str = Field(default="ubuntu", max_length=50, description="SSH 用户名(推荐 ubuntu,后续所有操作均使用该用户)")
    ssh_port: int = Field(default=22, ge=1, le=65535, description="SSH 端口")
    cpu_cores: int | None = Field(default=None, ge=1, description="CPU 核数")
    memory_gb: int | None = Field(default=None, ge=1, description="内存(GB)")
    disk_gb: int | None = Field(default=None, ge=10, description="磁盘(GB)")


class HostOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    name: str
    ip: str
    ssh_user: str
    ssh_port: int
    status: str
    cpu_cores: int | None
    memory_gb: int | None
    disk_gb: int | None
    os_name: str | None
    os_ok: bool | None
    libvirt_ready: bool | None
    check_report: str | None
    last_checked_at: datetime | None
    is_demo: bool
    created_at: datetime


# ---------- 虚拟机 ----------

class VmCreateIn(BaseModel):
    name: str = Field(min_length=2, max_length=80, description="虚拟机名称")
    host_id: int = Field(description="宿主机 ID")
    cpu: int = Field(default=2, ge=1, le=64, description="vCPU 核数")
    memory_gb: int = Field(default=4, ge=1, le=512, description="内存(GB)")
    disk_gb: int = Field(default=40, ge=5, le=2048, description="系统盘(GB)")
    image: str = Field(max_length=120, description="云镜像名称")
    provider: Literal["libvirt", "kubevirt"] = Field(
        default="libvirt", description="虚拟化后端:libvirt(virsh) | kubevirt"
    )
    namespace: str | None = Field(
        default=None, max_length=80, description="KubeVirt 命名空间(仅 provider=kubevirt)"
    )
    auto_ip: bool = Field(default=True, description="是否自动分配 IP")
    ip: str | None = Field(default=None, max_length=64, description="手动指定 IP(可选)")


class VmOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    name: str
    host_id: int
    host_name: str | None = None
    host_ip: str | None = None
    cpu: int
    memory_gb: int
    disk_gb: int
    image: str
    ip: str | None
    provider: str
    namespace: str | None
    status: str
    is_demo: bool
    created_at: datetime


class VmCreateResult(BaseModel):
    task_id: int
    vm: VmOut


class ProviderInfoOut(BaseModel):
    """虚拟化后端状态。"""

    model_config = ConfigDict(from_attributes=True)

    key: str
    name: str
    available: bool
    mode: str
    detail: str


class VmActionIn(BaseModel):
    action: Literal["start", "stop", "reboot"]


class VmImageOut(BaseModel):
    """MinIO 上的虚拟机模板镜像。"""

    name: str
    size: int
    last_modified: str


class VmBatchCreateIn(BaseModel):
    names: list[str] = Field(min_length=1, max_length=20, description="虚拟机名称列表(一次最多 20 台)")
    host_id: int = Field(description="宿主机 ID")
    cpu: int = Field(default=2, ge=1, le=64, description="vCPU 核数(默认 2)")
    memory_gb: int = Field(default=16, ge=1, le=512, description="内存(GB,默认 16)")
    disk_gb: int = Field(default=40, ge=5, le=2048, description="系统盘(GB)")
    image: str = Field(min_length=1, max_length=120, description="模板镜像名称(来自 MinIO cubestack/installer/vm)")
    provider: Literal["libvirt", "kubevirt"] = Field(default="libvirt", description="虚拟化后端")


class VmBatchCreateResult(BaseModel):
    task_ids: list[int]
    vms: list[VmOut]


# ---------- K8s 集群 ----------

class ClusterCreateIn(BaseModel):
    name: str = Field(min_length=2, max_length=80, description="集群名称")
    network_plugin: str = Field(default="calico", max_length=20, description="网络插件")
    k8s_version: str = Field(default="v1.28.13", max_length=20, description="Kubernetes 版本(默认)")
    kubespray_version: str = Field(default="v2.25.0", max_length=30, description="Kubespray 版本(默认)")
    run_node_host_id: int | None = Field(
        default=None, description="Kubespray 运行节点(宿主机 ID,None=平台管理机本机执行)"
    )
    control_plane_vm_ids: list[int] = Field(min_length=1, description="控制平面节点(虚拟机 ID 列表)")
    worker_vm_ids: list[int] = Field(default=[], description="工作节点(虚拟机 ID 列表)")
    ssh_key: str | None = Field(default=None, description="SSH 私钥(可选,留空使用平台密钥)")


class ClusterOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    name: str
    k8s_version: str
    network_plugin: str
    kubespray_version: str
    run_node_host_id: int | None = None
    run_node_name: str | None = None
    status: str
    api_server: str | None = None
    has_kubeconfig: bool = False
    is_demo: bool
    created_at: datetime
    control_plane_count: int = 0
    worker_count: int = 0


class NodeOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    vm_id: int | None
    name: str
    ip: str | None
    role: str


class TaskBriefOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    type: str
    target_name: str
    status: str
    progress: int
    created_at: datetime
    started_at: datetime | None
    finished_at: datetime | None


class ClusterDetailOut(BaseModel):
    cluster: ClusterOut
    nodes: list[NodeOut]
    last_task: TaskBriefOut | None = None


class DeployResult(BaseModel):
    task_id: int


# ---------- 任务 ----------

class TaskOut(TaskBriefOut):
    log_excerpt: str = ""


class TaskDetailOut(TaskOut):
    log_text: str = ""