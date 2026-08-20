from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from ..deps import get_current_user, get_db
from ...models import DeployTask, User
from ...schemas import MessageOut, TaskDetailOut, TaskOut

router = APIRouter(prefix="/api/tasks", tags=["tasks"])


def _to_out(task: DeployTask, with_excerpt: bool = True) -> TaskOut:
    out = TaskOut.model_validate(task)
    if with_excerpt and task.log_text:
        out.log_excerpt = task.log_text[-300:]
    return out


@router.get("", response_model=list[TaskOut])
def list_tasks(db: Session = Depends(get_db), _: User = Depends(get_current_user)) -> list[TaskOut]:
    tasks = db.query(DeployTask).order_by(DeployTask.id.desc()).limit(100).all()
    return [_to_out(t) for t in tasks]


@router.get("/{task_id}", response_model=TaskDetailOut)
def task_detail(
    task_id: int,
    db: Session = Depends(get_db),
    _: User = Depends(get_current_user),
) -> TaskDetailOut:
    task = db.get(DeployTask, task_id)
    if task is None:
        raise HTTPException(status_code=404, detail="任务不存在")
    return TaskDetailOut.model_validate(task)


@router.delete("/{task_id}", response_model=MessageOut)
def delete_task(
    task_id: int,
    db: Session = Depends(get_db),
    _: User = Depends(get_current_user),
) -> MessageOut:
    """删除任务(连同日志, 不保留记录)。运行中的任务不允许删除。"""
    task = db.get(DeployTask, task_id)
    if task is None:
        raise HTTPException(status_code=404, detail="任务不存在")
    if task.status in ("pending", "running"):
        raise HTTPException(status_code=400, detail="任务正在运行中,无法删除")
    db.delete(task)
    db.commit()
    return MessageOut(message="任务已删除")
