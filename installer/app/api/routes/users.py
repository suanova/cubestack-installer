from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import or_
from sqlalchemy.orm import Session

from ..deps import get_current_user, get_db, require_admin
from ...core.security import hash_password
from ...models import User
from ...schemas import MessageOut, UserCreateIn, UserOut, UserUpdateIn

router = APIRouter(prefix="/api/users", tags=["users"])


@router.get("", response_model=list[UserOut])
def list_users(
    db: Session = Depends(get_db), _: User = Depends(get_current_user)
) -> list[User]:
    """登录用户可查看用户列表。"""
    return db.query(User).order_by(User.id).all()


@router.post("", response_model=UserOut, status_code=201)
def create_user(
    payload: UserCreateIn,
    db: Session = Depends(get_db),
    _: User = Depends(require_admin),
) -> User:
    """管理员直接添加用户(立即激活,无需审核)。"""
    exists = (
        db.query(User)
        .filter(or_(User.username == payload.username, User.email == payload.email))
        .first()
    )
    if exists:
        raise HTTPException(status_code=409, detail="用户名或邮箱已被注册")
    user = User(
        username=payload.username,
        email=payload.email,
        full_name=payload.full_name,
        hashed_password=hash_password(payload.password),
        role=payload.role,
        is_active=True,
        status="active",
    )
    db.add(user)
    db.commit()
    db.refresh(user)
    return user


@router.patch("/{user_id}", response_model=UserOut)
def update_user(
    user_id: int,
    payload: UserUpdateIn,
    db: Session = Depends(get_db),
    admin: User = Depends(require_admin),
) -> User:
    """管理员修改用户角色 / 状态(审核/启用/禁用) / 姓名。"""
    user = db.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="用户不存在")
    if user.id == admin.id and payload.role == "user":
        raise HTTPException(status_code=400, detail="不能撤销自己的管理员权限")
    if user.id == admin.id and (payload.is_active is False or payload.status in ("pending", "disabled")):
        raise HTTPException(status_code=400, detail="不能禁用或置为自己账号的审核状态")
    if payload.role is not None:
        user.role = payload.role
    if payload.status is not None:
        user.status = payload.status
        user.is_active = payload.status == "active"
    elif payload.is_active is not None:
        user.is_active = payload.is_active
        user.status = "active" if payload.is_active else "disabled"
    if payload.full_name is not None:
        user.full_name = payload.full_name
    db.commit()
    db.refresh(user)
    return user


@router.delete("/{user_id}", response_model=MessageOut)
def delete_user(
    user_id: int,
    db: Session = Depends(get_db),
    admin: User = Depends(require_admin),
) -> MessageOut:
    """管理员删除用户。"""
    if user_id == admin.id:
        raise HTTPException(status_code=400, detail="不能删除自己的账号")
    user = db.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="用户不存在")
    db.delete(user)
    db.commit()
    return MessageOut(message="用户已删除")
