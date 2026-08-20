"""数据库引擎与会话(支持 DATABASE_URL 环境变量覆盖)。"""
import os

import sqlalchemy as sa
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from .base import Base

DATABASE_URL = os.environ.get("DATABASE_URL", "sqlite:///./userhub.db")

_connect_args = {"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {}
engine = create_engine(DATABASE_URL, connect_args=_connect_args)
SessionLocal = sessionmaker(bind=engine, autocommit=False, autoflush=False)


def _migrate() -> None:
    """轻量迁移:为已存在的表补齐新增列。"""
    with engine.connect() as conn:
        vm_cols = [row[1] for row in conn.execute(sa.text("PRAGMA table_info(vms)"))]
        if "provider" not in vm_cols:
            conn.execute(sa.text("ALTER TABLE vms ADD COLUMN provider VARCHAR(20) DEFAULT 'libvirt'"))
        if "namespace" not in vm_cols:
            conn.execute(sa.text("ALTER TABLE vms ADD COLUMN namespace VARCHAR(80)"))
        host_cols = [row[1] for row in conn.execute(sa.text("PRAGMA table_info(hosts)"))]
        for col, ddl in [
            ("os_name", "ALTER TABLE hosts ADD COLUMN os_name VARCHAR(120)"),
            ("os_ok", "ALTER TABLE hosts ADD COLUMN os_ok BOOLEAN"),
            ("libvirt_ready", "ALTER TABLE hosts ADD COLUMN libvirt_ready BOOLEAN"),
            ("check_report", "ALTER TABLE hosts ADD COLUMN check_report TEXT"),
            ("last_checked_at", "ALTER TABLE hosts ADD COLUMN last_checked_at DATETIME"),
        ]:
            if col not in host_cols:
                conn.execute(sa.text(ddl))
        cnode_cols = [row[1] for row in conn.execute(sa.text("PRAGMA table_info(cluster_nodes)"))]
        if "node_type" not in cnode_cols:
            conn.execute(sa.text("ALTER TABLE cluster_nodes ADD COLUMN node_type VARCHAR(10) DEFAULT 'vm'"))
        if "host_id" not in cnode_cols:
            conn.execute(sa.text("ALTER TABLE cluster_nodes ADD COLUMN host_id INTEGER"))
        user_cols = [row[1] for row in conn.execute(sa.text("PRAGMA table_info(users)"))]
        if "status" not in user_cols:
            conn.execute(sa.text("ALTER TABLE users ADD COLUMN status VARCHAR(20) DEFAULT 'active'"))
            conn.execute(sa.text("UPDATE users SET status='disabled' WHERE is_active=0 AND status='active'"))
        cluster_cols = [row[1] for row in conn.execute(sa.text("PRAGMA table_info(clusters)"))]
        if "run_node_host_id" not in cluster_cols:
            conn.execute(sa.text("ALTER TABLE clusters ADD COLUMN run_node_host_id INTEGER"))
        if "api_server" not in cluster_cols:
            conn.execute(sa.text("ALTER TABLE clusters ADD COLUMN api_server VARCHAR(255)"))
        if "kubeconfig" not in cluster_cols:
            conn.execute(sa.text("ALTER TABLE clusters ADD COLUMN kubeconfig TEXT"))
        conn.commit()


def init_db() -> None:
    """创建所有数据表(幂等)+ 轻量迁移。"""
    Base.metadata.create_all(bind=engine)
    _migrate()
