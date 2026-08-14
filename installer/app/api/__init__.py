"""API 路由聚合。"""
from fastapi import APIRouter

from .routes import auth, clusters, hosts, tasks, users, vms

api_router = APIRouter()
api_router.include_router(auth.router)
api_router.include_router(users.router)
api_router.include_router(hosts.router)
api_router.include_router(vms.router)
api_router.include_router(clusters.router)
api_router.include_router(tasks.router)
