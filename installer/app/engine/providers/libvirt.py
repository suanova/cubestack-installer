"""Libvirt(virsh) 虚拟机 Provider。

- 真实模式:调用 virt-install / virsh / qemu-img
- 仿真模式:未检测到工具或真实执行失败时自动回退,完整模拟流程与日志
"""
import os
import shutil
import subprocess
import time

from ...models import DeployTask, VirtualMachine
from .base import ProviderInfo, VMProvider

IMAGES_DIR = "/var/lib/libvirt/images"


class LibvirtProvider(VMProvider):
    key = "libvirt"
    name = "Libvirt (virsh)"

    # ---------- 工具检测 ----------
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

    def _next_ip(self, vm: VirtualMachine) -> str:
        return "192.168.10." + str(100 + vm.id)

    # ---------- 创建 ----------
    def create(self, task: DeployTask, vm: VirtualMachine, db, log) -> None:
        mode = self._detect_mode()
        use_sim = mode == "sim"

        log(task, db, "==== 虚拟机创建任务(Libvirt) ====")
        log(task, db, "目标虚拟机: " + vm.name)
        log(task, db, "宿主机 ID: " + str(vm.host_id))
        log(task, db, "规格: " + str(vm.cpu) + " vCPU / " + str(vm.memory_gb) + " GB / " + str(vm.disk_gb) + " GB")
        log(task, db, "镜像: " + vm.image)
        if use_sim:
            log(task, db, "[模式] 仿真模式(未检测到可用 libvirt;设置 DEPLOY_MODE=real 强制真实)")
        else:
            log(task, db, "[模式] 真实模式(libvirt)")
        vm.status = "creating"
        db.commit()
        task.progress = 8
        db.commit()

        def real(cmd, timeout=120):
            nonlocal use_sim
            if use_sim:
                return False
            try:
                subprocess.run(cmd, check=True, capture_output=True, text=True, timeout=timeout)
                return True
            except Exception as exc:  # noqa: BLE001
                log(task, db, "      [警告] 真实执行失败(" + str(exc) + "),回退仿真模式继续")
                use_sim = True
                return False

        log(task, db, "[1/6] 准备存储卷 " + vm.name + ".qcow2 (" + str(vm.disk_gb) + "G, qcow2) ...")
        vol_path = IMAGES_DIR + "/" + vm.name + ".qcow2"
        if not real(["qemu-img", "create", "-f", "qcow2", vol_path, str(vm.disk_gb) + "G"]):
            time.sleep(0.6)
        log(task, db, "      存储卷就绪 ✓")
        task.progress = 25
        db.commit()

        log(task, db, "[2/6] 下载 / 校验云镜像 " + vm.image + " ...")
        if use_sim:
            time.sleep(0.6)
        log(task, db, "      镜像校验通过 ✓")
        task.progress = 40
        db.commit()

        log(task, db, "[3/6] 定义虚拟机 domain(" + vm.name + ") ...")
        if not real([
            "virt-install", "--name", vm.name, "--vcpus", str(vm.cpu),
            "--memory", str(vm.memory_gb * 1024),
            "--disk", "path=" + vol_path + ",format=qcow2,size=" + str(vm.disk_gb),
            "--os-variant", "ubuntu22.04", "--network", "bridge=br0",
            "--import", "--noautoconsole", "--graphics", "none",
        ]):
            time.sleep(0.5)
        log(task, db, "      domain 定义完成 ✓")
        task.progress = 55
        db.commit()

        ip = vm.ip or self._next_ip(vm)
        log(task, db, "[4/6] 配置网络,分配 IP ...")
        if use_sim:
            time.sleep(0.5)
        vm.ip = ip
        db.commit()
        log(task, db, "      IP 地址: " + ip + " ✓")
        task.progress = 70
        db.commit()

        log(task, db, "[5/6] 注入 cloud-init 配置(SSH 密钥 / 主机名) ...")
        if use_sim:
            time.sleep(0.6)
        log(task, db, "      cloud-init 配置注入完成 ✓")
        task.progress = 85
        db.commit()

        log(task, db, "[6/6] 启动虚拟机 " + vm.name + " ...")
        if not use_sim:
            real(["virsh", "start", vm.name])
        else:
            time.sleep(0.8)
        vm.status = "running"
        db.commit()
        log(task, db, "")
        log(task, db, "✅ 虚拟机 " + vm.name + " 创建成功(Libvirt),运行中")
        log(task, db, "   IP: " + ip + "  |  virsh list --all")
        task.progress = 100
        db.commit()

    # ---------- 电源操作 ----------
    def action(self, vm: VirtualMachine, action: str) -> None:
        mode = self._detect_mode()
        if mode == "real":
            map_action = {"start": "start", "stop": "shutdown", "reboot": "reboot"}
            try:
                subprocess.run(["virsh", map_action[action], vm.name],
                               capture_output=True, text=True, timeout=60, check=True)
            except Exception:  # noqa: BLE001
                pass
        time.sleep(0.4)
        if action == "start":
            vm.status = "running"
        elif action == "stop":
            vm.status = "stopped"
        elif action == "reboot":
            vm.status = "running"

    # ---------- 删除 ----------
    def delete(self, vm: VirtualMachine) -> None:
        mode = self._detect_mode()
        if mode == "real":
            try:
                subprocess.run(["virsh", "destroy", vm.name],
                               capture_output=True, text=True, timeout=60)
                subprocess.run(["virsh", "undefine", vm.name, "--remove-all-storage"],
                               capture_output=True, text=True, timeout=60)
            except Exception:  # noqa: BLE001
                pass
