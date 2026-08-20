from datetime import datetime

from sqlalchemy import Boolean, DateTime, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from ..db.base import Base, utcnow as _utcnow


class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    username: Mapped[str] = mapped_column(String(50), unique=True, index=True)
    email: Mapped[str] = mapped_column(String(120), unique=True, index=True)
    hashed_password: Mapped[str] = mapped_column(String(255))
    full_name: Mapped[str | None] = mapped_column(String(100), nullable=True)
    role: Mapped[str] = mapped_column(String(20), default="user")  # admin | user
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)


class Host(Base):
    """宿主机(物理服务器 / 被纳管的服务器)。"""

    __tablename__ = "hosts"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    name: Mapped[str] = mapped_column(String(80), unique=True, index=True)
    ip: Mapped[str] = mapped_column(String(64))
    ssh_user: Mapped[str] = mapped_column(String(50), default="ubuntu")
    ssh_port: Mapped[int] = mapped_column(Integer, default=22)
    status: Mapped[str] = mapped_column(String(20), default="unknown")  # online|offline|unknown
    cpu_cores: Mapped[int | None] = mapped_column(Integer, nullable=True)
    memory_gb: Mapped[int | None] = mapped_column(Integer, nullable=True)
    disk_gb: Mapped[int | None] = mapped_column(Integer, nullable=True)
    # 环境检测结果
    os_name: Mapped[str | None] = mapped_column(String(120), nullable=True)
    # 如 "Ubuntu 22.04.4 LTS"
    os_ok: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
    # 操作系统是否为 Ubuntu 22.04
    libvirt_ready: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
    # libvirt 依赖是否齐全
    check_report: Mapped[str | None] = mapped_column(Text, nullable=True)
    # 检测报告(JSON 字符串)
    last_checked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    is_demo: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)


class VirtualMachine(Base):
    """宿主机上创建的虚拟机(KVM/libvirt)。"""

    __tablename__ = "vms"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    name: Mapped[str] = mapped_column(String(80), unique=True, index=True)
    host_id: Mapped[int] = mapped_column(Integer, index=True)
    cpu: Mapped[int] = mapped_column(Integer, default=2)
    memory_gb: Mapped[int] = mapped_column(Integer, default=4)
    disk_gb: Mapped[int] = mapped_column(Integer, default=40)
    image: Mapped[str] = mapped_column(String(120))  # 云镜像名称
    ip: Mapped[str | None] = mapped_column(String(64), nullable=True)
    provider: Mapped[str] = mapped_column(String(20), default="libvirt")
    # libvirt | kubevirt
    namespace: Mapped[str | None] = mapped_column(String(80), nullable=True)
    # KubeVirt 命名空间(仅 provider=kubevirt)
    status: Mapped[str] = mapped_column(String(20), default="pending")
    # pending|creating|running|stopped|error
    is_demo: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)


class K8sCluster(Base):
    """K8s 集群(Kubespray 部署)。"""

    __tablename__ = "clusters"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    name: Mapped[str] = mapped_column(String(80), unique=True, index=True)
    k8s_version: Mapped[str] = mapped_column(String(20), default="v1.28.13")
    network_plugin: Mapped[str] = mapped_column(String(20), default="calico")
    kubespray_version: Mapped[str] = mapped_column(String(30), default="v2.25.0")
    run_node_host_id: Mapped[int | None] = mapped_column(Integer, nullable=True)
    # Kubespray 运行节点(宿主机 ID,None=平台管理机本机执行)
    ssh_key: Mapped[str | None] = mapped_column(Text, nullable=True)
    # API Server 地址(如 https://192.168.122.24:6443),安装成功后从 kubeconfig 提取
    api_server: Mapped[str | None] = mapped_column(String(255), nullable=True)
    # 集群 kubeconfig(admin.conf)全文,安装成功后从运行节点取回入库,供展示与下载
    kubeconfig: Mapped[str | None] = mapped_column(Text, nullable=True)
    status: Mapped[str] = mapped_column(String(20), default="pending")
    # pending|installing|ready|failed
    is_demo: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)


class ClusterNode(Base):
    """集群节点快照(创建集群时从选中的虚拟机生成)。"""

    __tablename__ = "cluster_nodes"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    cluster_id: Mapped[int] = mapped_column(Integer, index=True)
    vm_id: Mapped[int | None] = mapped_column(Integer, nullable=True)
    name: Mapped[str] = mapped_column(String(80))
    ip: Mapped[str | None] = mapped_column(String(64), nullable=True)
    role: Mapped[str] = mapped_column(String(20))  # control_plane | worker


class DeployTask(Base):
    """异步部署任务(创建虚拟机 / 安装集群)。"""

    __tablename__ = "deploy_tasks"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    type: Mapped[str] = mapped_column(String(20))  # vm_create | cluster_install
    target_id: Mapped[int] = mapped_column(Integer)
    target_name: Mapped[str] = mapped_column(String(80))
    status: Mapped[str] = mapped_column(String(20), default="pending")
    # pending|running|success|failed
    progress: Mapped[int] = mapped_column(Integer, default=0)
    log_text: Mapped[str] = mapped_column(Text, default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)
    started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
