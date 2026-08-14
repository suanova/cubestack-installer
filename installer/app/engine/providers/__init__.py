"""虚拟化 Provider 工厂。

设计:
- 每个 Provider 实现统一的 VMProvider 接口(create/action/delete/info)
- 平台通过 get_provider(provider_type) 按需路由
- 当前支持 libvirt(virsh) 与 kubevirt(KubeVirt CRD)
"""
from .base import ProviderInfo, VMProvider
from .kubevirt import KubeVirtProvider
from .libvirt import LibvirtProvider


def get_provider(provider_type: str | None) -> VMProvider:
    """按类型返回 Provider 实例(未知类型回退 libvirt)。"""
    if provider_type == "kubevirt":
        return KubeVirtProvider()
    return LibvirtProvider()


def list_providers() -> list[ProviderInfo]:
    """返回全部已注册 Provider 的状态信息(供前端展示)。"""
    return [LibvirtProvider().info(), KubeVirtProvider().info()]
