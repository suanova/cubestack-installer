from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import or_
from sqlalchemy.orm import Session

from ..deps import get_current_user, get_db
from ...models import User
from ...schemas import LoginIn, RegisterIn, TokenOut, UserOut
from ...core.security import create_access_token, hash_password, verify_password

router = APIRouter(prefix="/api/auth", tags=["auth"])


@router.post("/register", response_model=UserOut, status_code=status.HTTP_201_CREATED)
def register(payload: RegisterIn, db: Session = Depends(get_db)) -> User:
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
        is_active=False,
        status="pending",  # 注册账号需管理员审核激活
    )
    db.add(user)
    db.commit()
    db.refresh(user)
    return user


@router.post("/login", response_model=TokenOut)
def login(payload: LoginIn, db: Session = Depends(get_db)) -> TokenOut:
    user = (
        db.query(User)
        .filter(or_(User.username == payload.account, User.email == payload.account))
        .first()
    )
    if user is None or not verify_password(payload.password, user.hashed_password):
        raise HTTPException(status_code=401, detail="用户名或密码错误")
    if user.status == "pending":
        raise HTTPException(status_code=403, detail="账号待管理员审核,请通过后再登录")
    if user.status == "disabled" or not user.is_active:
        raise HTTPException(status_code=403, detail="账号已被禁用,请联系管理员")
    return TokenOut(
        access_token=create_access_token(str(user.id)),
        user=UserOut.model_validate(user),
    )


@router.get("/me", response_model=UserOut)
def me(user: User = Depends(get_current_user)) -> User:
    return user
