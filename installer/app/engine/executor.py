"""任务执行器:后台线程运行部署任务,实时写日志与进度。"""
import threading
from datetime import datetime, timezone

from ..db.session import SessionLocal
from ..models import DeployTask

_threads: dict[int, threading.Thread] = {}


def log_line(task: DeployTask, db, line: str) -> None:
    task.log_text = (task.log_text or "") + line + "\n"
    db.commit()


def start_task(task_id: int) -> None:
    """启动一个部署任务(幂等:已在运行则忽略)。"""
    t = _threads.get(task_id)
    if t is not None and t.is_alive():
        return
    worker = threading.Thread(target=_run, args=(task_id,), daemon=True, name="task-" + str(task_id))
    _threads[task_id] = worker
    worker.start()


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _run(task_id: int) -> None:
    db = SessionLocal()
    try:
        task = db.get(DeployTask, task_id)
        if task is None:
            return
        task.status = "running"
        task.started_at = _now()
        db.commit()

        if task.type == "vm_create":
            from ..models import VirtualMachine
            from .providers import get_provider
            vm = db.get(VirtualMachine, task.target_id)
            provider = get_provider(vm.provider if vm else "libvirt")
            provider.create(task, vm, db, log_line)
        elif task.type == "cluster_install":
            from .services.kubespray import run_cluster_install
            run_cluster_install(task, db)
        elif task.type == "cluster_prepare":
            from .services.clusterprep import run_cluster_prepare
            run_cluster_prepare(task, db)
        elif task.type == "cluster_sshkey":
            from .services.clusterprep import run_cluster_sshkey
            run_cluster_sshkey(task, db)
        else:
            raise ValueError("未知任务类型: " + str(task.type))

        task.status = "success"
        task.progress = 100
        task.finished_at = _now()
        db.commit()
    except Exception as exc:  # noqa: BLE001
        try:
            db.rollback()
            task = db.get(DeployTask, task_id)
            if task is not None:
                task.status = "failed"
                task.finished_at = _now()
                task.log_text = (task.log_text or "") + "\n[错误] " + str(exc) + "\n"
                db.commit()
        except Exception:  # noqa: BLE001
            pass
        # 任务失败时,把卡在创建中的虚拟机标记为 error
        if task is not None and task.type == "vm_create":
            from ..models import VirtualMachine
            vm = db.get(VirtualMachine, task.target_id)
            if vm is not None and vm.status == "creating":
                vm.status = "error"
                db.commit()
    finally:
        db.close()
