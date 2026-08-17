"""Libvirt(virsh) 虚拟机 Provider。

- 真实模式:SSH 到宿主机,由 vmprovision 执行 qemu-img / virt-install / virsh(基于模板镜像)
- 仿真模式:宿主机为演示数据或 SSH 不可达时自动回退,完整模拟流程与日志
"""
import os
import shutil
import time

from ...models import DeployTask, Host, VirtualMachine
from .base import ProviderInfo, VMProvider

IMAGES_DIR = "/var/lib/libvirt/images"


class LibvirtProvider(VMProvider):
    key = "libvirt"
    name = "Libvirt (virsh)"

    def _detect_mode(self) -> str:
        m = os.environ.get("DEPLOY_MODE", "auto").lower()
        if m in ("sim", "simulation"):
            return "sim"
        if m == "real":
            return "real"
        return "real" if shutil.which("virt-install") else "sim"

    def info(self) -> ProviderInfo:
        mode = self._detect_mode()
        real = mode == "real"
        return ProviderInfo(
            key=self.key,
            name=self.name,
            available=real,
            mode=mode,
            detail="virt-install/virsh 工具链" + ("可用" if real else "不可用(将使用仿真)"),
        )

    def _load_host(self, host_id: int | None) -> Host | None:
        from ...db.session import SessionLocal
        db = SessionLocal()
        try:
            return db.get(Host, host_id) if host_id else None
        finally:
            db.close()

    def _next_ip(self, vm: VirtualMachine) -> str:
        return "192.168.10." + str(100 + vm.id)

    def _host_real(self, host: Host, log) -> bool:
        """真实模式判断:宿主机可 SSH 且已装 virt-install。"""
        from ..services.vmprovision import _ssh
        rc, out, _ = _ssh(host, "command -v virt-install >/dev/null 2>&1 && echo ok")
        if rc == 0 and out.strip() == "ok":
            return True
        log("      [提示] 宿主机 SSH/工具不可用,回退仿真模式")
        return False

    # ---------- 创建 ----------
    def create(self, task: DeployTask, vm: VirtualMachine, db, log) -> None:
        host = self._load_host(vm.host_id)
        use_real = bool(host is not None and not host.is_demo and self._host_real(host, lambda s: log(task, db, s)))

        log(task, db, "==== 虚拟机创建任务(Libvirt) ====")
        log(task, db, "目标虚拟机: " + vm.name)
        log(task, db, "宿主机 ID: " + str(vm.host_id))
        log(task, db, "规格: " + str(vm.cpu) + " vCPU / " + str(vm.memory_gb) + " GB / " + str(vm.disk_gb) + " GB")
        log(task, db, "镜像: " + vm.image)
        if use_real:
            log(task, db, "[模式] 真实模式(SSH -> 宿主机 virt-install)")
        else:
            log(task, db, "[模式] 仿真模式")
        vm.status = "creating"
        db.commit()
        task.progress = 8
        db.commit()

        if use_real:
            from ..services.vmprovision import provision_vm
            ok, info = provision_vm(host, vm, lambda s: log(task, db, s))
            if not ok:
                vm.status = "error"
                db.commit()
                raise RuntimeError("虚拟机创建失败: " + info)
            vm.ip = info or vm.ip
            vm.status = "running"
            db.commit()
            log(task, db, "")
            log(task, db, "✅ 虚拟机 " + vm.name + " 创建成功(Libvirt),运行中")
            log(task, db, "   IP: " + (info or "(待 DHCP)") + "  |  virsh list --all")
            task.progress = 100
            db.commit()
            return

        # ---------- 仿真流程 ----------
        log(task, db, "[1/6] 准备存储卷 " + vm.name + ".qcow2 (" + str(vm.disk_gb) + "G, qcow2) ...")
        time.sleep(0.6)
        log(task, db, "      存储卷就绪 ✓")
        task.progress = 25
        db.commit()

        log(task, db, "[2/6] 下载 / 校验云镜像 " + vm.image + " ...")
        time.sleep(0.6)
        log(task, db, "      镜像校验通过 ✓")
        task.progress = 40
        db.commit()

        log(task, db, "[3/6] 定义虚拟机 domain(" + vm.name + ") ...")
        time.sleep(0.5)
        log(task, db, "      domain 定义完成 ✓")
        task.progress = 55
        db.commit()

        ip = vm.ip or self._next_ip(vm)
        log(task, db, "[4/6] 配置网络,分配 IP ...")
        time.sleep(0.5)
        vm.ip = ip
        db.commit()
        log(task, db, "      IP 地址: " + ip + " ✓")
        task.progress = 70
        db.commit()

        log(task, db, "[5/6] 注入 cloud-init 配置(SSH 密钥 / 主机名) ...")
        time.sleep(0.6)
        log(task, db, "      cloud-init 配置注入完成 ✓")
        task.progress = 85
        db.commit()

        log(task, db, "[6/6] 启动虚拟机 " + vm.name + " ...")
        time.sleep(0.8)
        vm.status = "running"
        db.commit()
        log(task, db, "")
        log(task, db, "✅ 虚拟机 " + vm.name + " 创建成功(Libvirt 仿真),运行中")
        log(task, db, "   IP: " + ip + "  |  virsh list --all")
        task.progress = 100
        db.commit()

    # ---------- 电源操作 ----------
    def action(self, vm: VirtualMachine, action: str) -> None:
        host = self._load_host(vm.host_id)
        if host is not None and not host.is_demo:
            from ..services.vmprovision import virsh_action
            if virsh_action(host, vm.name, action):
                time.sleep(0.4)
                if action == "start":
                    vm.status = "running"
                elif action == "stop":
                    vm.status = "stopped"
                else:
                    vm.status = "running"
                return
        time.sleep(0.4)
        if action == "start":
            vm.status = "running"
        elif action == "stop":
            vm.status = "stopped"
        else:
            vm.status = "running"

    # ---------- 删除 ----------
    def delete(self, vm: VirtualMachine) -> None:
        host = self._load_host(vm.host_id)
        if host is not None and not host.is_demo:
            from ..services.vmprovision import virsh_delete
            virsh_delete(host, vm.name)
            return
        time.sleep(0.3)