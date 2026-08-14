"""VM Provider 抽象基类。"""
from dataclasses import dataclass

from ...models import DeployTask, VirtualMachine


@dataclass
class ProviderInfo:
    key: str              # libvirt | kubevirt
    name: str             # 显示名
    available: bool       # 真实工具链是否可用
    mode: str             # real | sim
    detail: str           # 连接/状态说明


class VMProvider:
    """虚拟机生命周期提供方:libvirt / kubevirt 共用同一接口。"""

    key: str = "base"
    name: str = "Base"

    # ---- 元信息 ----
    def info(self) -> ProviderInfo:
        raise NotImplementedError

    # ---- 长任务(创建,由任务引擎调用,需逐步写日志) ----
    def create(self, task: DeployTask, vm: VirtualMachine, db, log) -> None:
        raise NotImplementedError

    # ---- 快速电源操作 ----
    def action(self, vm: VirtualMachine, action: str) -> None:
        raise NotImplementedError

    # ---- 删除 ----
    def delete(self, vm: VirtualMachine) -> None:
        pass

    # ---- 状态同步(可选) ----
    def sync_status(self, vm: VirtualMachine) -> str | None:
        return None
