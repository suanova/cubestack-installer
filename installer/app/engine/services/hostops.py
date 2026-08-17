"""宿主机环境检测。

检查内容(SSH 到宿主机执行):
1. SSH 连通性
2. 操作系统:必须为 Ubuntu 22.04(/etc/os-release 校验 ID=ubuntu 且 VERSION_ID 以 22.04 开头)
3. libvirt 依赖包: virt-install / virsh / qemu-img / qemu-kvm / cloud-localds
4. libvirtd 服务是否运行
5. /dev/kvm 是否存在

模式:
- DEPLOY_MODE=sim 或本机无 ssh 工具 -> 仿真模式,返回模拟通过的报告(标记 simulated)
- 否则执行真实 SSH 检测;主机不可达时返回 offline
"""
import json
import os
import shutil
import subprocess
import time

from ...models import Host

# 创建/管理 libvirt 虚拟机所需的依赖:(显示名, 候选可执行文件, 对应 Ubuntu 包名)
# 说明:Ubuntu 22.04 的 KVM 二进制为 qemu-system-x86_64 / kvm(软链),包名为 qemu-system-x86
REQUIRED_PKGS: list[tuple[str, list[str], str]] = [
    ("virt-install", ["virt-install"], "virtinst"),
    ("virsh", ["virsh"], "libvirt-clients"),
    ("qemu-img", ["qemu-img"], "qemu-utils"),
    ("qemu-kvm", ["qemu-system-x86_64", "kvm"], "qemu-system-x86"),
    ("cloud-localds", ["cloud-localds"], "cloud-image-utils"),
    ("libvirtd", ["libvirtd"], "libvirt-daemon-system"),
    # MinIO 客户端(mc):非 apt 包,由宿主机初始化脚本单独下载安装;用于连接 MinIO 拉取模板镜像
    ("mc", ["mc"], "minio-client"),
]

# 兼容旧引用(仅用于展示/兼容)
REQUIRED_BINS: list[str] = [label for label, _, _ in REQUIRED_PKGS]
REQUIRED_PACKAGES: dict[str, str] = {label: pkg for label, _, pkg in REQUIRED_PKGS}


def _sim_report() -> dict:
    """仿真模式:模拟一台已装好 Ubuntu 22.04 + libvirt 环境的宿主机。"""
    return {
        "simulated": True,
        "ssh": "ok",
        "os": {"detected": "Ubuntu 22.04.4 LTS (仿真)", "ok": True},
        "packages": {
            "required": REQUIRED_BINS,
            "installed": list(REQUIRED_BINS),
            "missing": [],
            "ok": True,
        },
        "libvirtd": {"active": True, "detail": "libvirtd.service active (running) [仿真]"},
        "kvm": {"present": True, "detail": "/dev/kvm 存在 [仿真]"},
    }


def _offline_report() -> dict:
    return {
        "simulated": False,
        "ssh": "unreachable",
        "os": {"detected": None, "ok": False},
        "packages": {"required": REQUIRED_BINS, "installed": [], "missing": list(REQUIRED_BINS), "ok": False},
        "libvirtd": {"active": False, "detail": "无法检测(SSH 不可达)"},
        "kvm": {"present": False, "detail": "无法检测(SSH 不可达)"},
    }


def _ssh(host: Host, cmd: str, timeout: int = 10) -> str | None:
    """在宿主机上执行命令,返回 stdout(失败返回 None)。"""
    try:
        res = subprocess.run(
            [
                "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                "-o", "StrictHostKeyChecking=no", "-p", str(host.ssh_port),
                host.ssh_user + "@" + host.ip, cmd,
            ],
            capture_output=True, text=True, timeout=timeout,
        )
        if res.returncode == 0:
            return res.stdout.strip()
        return None
    except Exception:  # noqa: BLE001
        return None


def check_host_env(host: Host) -> tuple[str, dict]:
    """执行环境检测,返回 (status, report)。status: online | offline"""
    mode = os.environ.get("DEPLOY_MODE", "auto").lower()
    if mode in ("sim", "simulation") or shutil.which("ssh") is None:
        return "online", _sim_report()

    # 1. SSH 连通性
    if _ssh(host, "echo ok") is None:
        return "offline", _offline_report()

    report: dict = {"simulated": False, "ssh": "ok"}

    # 2. 操作系统检测(必须 Ubuntu 22.04)
    osrel = _ssh(host, "cat /etc/os-release")
    detected = None
    os_ok = False
    if osrel:
        kv: dict[str, str] = {}
        for line in osrel.splitlines():
            if "=" in line:
                k, _, v = line.partition("=")
                kv[k.strip()] = v.strip().strip('"')
        if kv.get("PRETTY_NAME"):
            detected = kv["PRETTY_NAME"]
        os_ok = kv.get("ID") == "ubuntu" and str(kv.get("VERSION_ID", "")).startswith("22.04")
    report["os"] = {"detected": detected, "ok": os_ok}

    # 3. libvirt 依赖包(任意候选可执行文件存在,或对应包已安装,即视为就绪)
    installed: list[str] = []
    for label, candidates, pkg in REQUIRED_PKGS:
        found = False
        for c in candidates:
            if _ssh(host, "command -v " + c + " 2>/dev/null"):
                found = True
                break
        if not found and _ssh(host, "dpkg -l " + pkg + " 2>/dev/null | grep -q '^ii' && echo ok") == "ok":
            found = True
        if found:
            installed.append(label)
    missing = [label for label, _, _ in REQUIRED_PKGS if label not in installed]
    report["packages"] = {
        "required": [label for label, _, _ in REQUIRED_PKGS],
        "installed": installed,
        "missing": missing,
        "ok": not missing,
    }

    # 4. libvirtd 服务
    svc = _ssh(host, "systemctl is-active libvirtd 2>/dev/null || service libvirtd status 2>/dev/null | grep -q running && echo active")
    libvirtd_active = svc is not None and "active" in svc
    report["libvirtd"] = {"active": libvirtd_active, "detail": "libvirtd.service active (running)" if libvirtd_active else "libvirtd 未运行"}

    # 5. /dev/kvm
    kvm = _ssh(host, "test -e /dev/kvm && echo present")
    kvm_present = kvm is not None and "present" in kvm
    report["kvm"] = {"present": kvm_present, "detail": "/dev/kvm 存在" if kvm_present else "/dev/kvm 不存在(将无法硬件加速)"}

    return "online", report


def apply_report(host: Host, status: str, report: dict) -> None:
    """把检测报告写入 Host 模型字段。"""
    from datetime import datetime, timezone
    host.status = status
    host.os_name = report.get("os", {}).get("detected")
    host.os_ok = bool(report.get("os", {}).get("ok"))
    host.libvirt_ready = bool(report.get("packages", {}).get("ok"))
    host.check_report = json.dumps(report, ensure_ascii=False)
    host.last_checked_at = datetime.now(timezone.utc)
    time.sleep(0)  # noop,保持模块一致性


def check_host(host: Host) -> str:
    """兼容旧调用:执行检测并落库(供路由使用)。"""
    status, report = check_host_env(host)
    apply_report(host, status, report)
    return status