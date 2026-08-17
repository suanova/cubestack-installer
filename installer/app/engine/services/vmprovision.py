"""基于模板镜像在宿主机(SSH)上创建/管理虚拟机。

创建流程(全部命令在宿主机上通过 SSH 执行,与宿主初始化脚本一致):
  1. 确保模板镜像在宿主机 /var/lib/libvirt/images(缺失则从 MinIO 下载并下发)
  2. qemu-img create 生成 COW 覆盖卷(可按 disk_gb resize)
  3. 写入 cloud-init user-data/meta-data(默认 ubuntu/ubuntu, hostname=虚拟机名)
  4. virt-install --import --cloud-init 创建并启动
  5. 轮询 virsh domifaddr 获取 DHCP 分配的 IP
"""
import base64
import json
import os
import subprocess
import time

from ...models import Host, VirtualMachine

IMAGES_DIR = "/var/lib/libvirt/images"
DEFAULT_USER = "ubuntu"
DEFAULT_PASSWORD = "ubuntu"
VM_NETWORK = "network=default,model=virtio"  # 与宿主机现有 default 网络一致


def _ssh(host: Host, cmd: str, timeout: int = 60) -> tuple[int, str, str]:
    """在宿主机上执行命令,返回 (returncode, stdout, stderr)。"""
    try:
        res = subprocess.run(
            [
                "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                "-o", "StrictHostKeyChecking=no", "-p", str(host.ssh_port),
                host.ssh_user + "@" + host.ip, cmd,
            ],
            capture_output=True, text=True, timeout=timeout,
        )
        return res.returncode, res.stdout, res.stderr
    except Exception:  # noqa: BLE001
        return -1, "", ""


def _os_variant(image: str) -> str:
    n = image.lower()
    if "24.04" in n or "noble" in n:
        return "ubuntu24.04"
    if "22.04" in n or "jammy" in n:
        return "ubuntu22.04"
    if "rocky" in n:
        return "rocky9"
    if "debian" in n:
        return "debian12"
    if "centos" in n:
        return "centos-stream9"
    return "ubuntu22.04"


def _mc_env() -> str:
    """构造宿主机直连内网 MinIO 的 mc 环境变量(MINIO_ENDPOINT/凭据)。"""
    from ...core import config as _cfg
    scheme = "https" if _cfg.MINIO_SECURE else "http"
    url = f"{scheme}://{_cfg.MINIO_ACCESS_KEY}:{_cfg.MINIO_SECRET_KEY}@{_cfg.MINIO_ENDPOINT}"
    return "MC_HOST_minio=" + url


def _mc(host: Host, args: str, timeout: int = 120) -> tuple[int, str, str]:
    """在宿主机上以 mc 操作 MinIO(MC_HOST 环境变量方式,不留配置缓存)。"""
    return _ssh(host, _mc_env() + " mc " + args + " 2>&1", timeout=timeout)


def list_images_via_host(host: Host) -> list[dict]:
    """经宿主机用 mc 列出 MinIO 模板镜像(管理机无法直连 MinIO 时使用)。"""
    rc, out, _ = _mc(host, "ls --json minio/cubestack/installer/vm/", timeout=60)
    if rc != 0 or not out:
        return []
    images: list[dict] = []
    for line in out.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except Exception:  # noqa: BLE001
            continue
        key = obj.get("key", "") or ""
        fname = key.split("/")[-1] if key else ""
        if not fname.lower().endswith((".qcow2", ".img", ".raw")):
            continue
        images.append({
            "name": fname,
            "size": int(obj.get("size", 0) or 0),
            "last_modified": obj.get("lastModified", "") or "",
        })
    images.sort(key=lambda x: x["name"])
    return images


def ensure_image_on_host(host: Host, image: str, log) -> bool:
    """确保模板镜像已存在于宿主机 IMAGES_DIR。

    缺失时由宿主机用 mc 从 MinIO 直接下载(管理机可能无法直连 MinIO)。
    """
    rc, out, _ = _ssh(host, f"test -f {IMAGES_DIR}/{image} && echo yes")
    if rc == 0 and (out or "").strip() == "yes":
        log(f"      [镜像] {image} 已在宿主机就绪")
        return True
    log(f"      [镜像] {image} 不在宿主机,由宿主机 mc 从 MinIO 下载 ...")
    rc, out, err = _mc(
        host,
        f"cp minio/cubestack/installer/vm/{image} /tmp/csi-{image} && "
        f"sudo -n mkdir -p {IMAGES_DIR} && sudo -n mv /tmp/csi-{image} {IMAGES_DIR}/{image} && "
        f"sudo -n chown libvirt-qemu:kvm {IMAGES_DIR}/{image} && sudo -n chmod 644 {IMAGES_DIR}/{image} "
        f"&& echo PUSH_OK",
        timeout=3600,
    )
    if rc != 0 or "PUSH_OK" not in (out or ""):
        log("      [镜像] 宿主机 mc 下载失败: " + (out or err)[:300])
        return False
    log(f"      [镜像] 已由宿主机下载 {image} 到 {IMAGES_DIR}")
    return True


def _user_data(vm: VirtualMachine) -> str:
    return (
        "#cloud-config\n"
        "users:\n"
        f"  - name: {DEFAULT_USER}\n"
        "    sudo: ALL=(ALL) NOPASSWD:ALL\n"
        "    shell: /bin/bash\n"
        "    ssh_pwauth: true\n"
        "    lock_passwd: false\n"
        f"    plain_text_passwd: {DEFAULT_PASSWORD}\n"
        "chpasswd:\n"
        "  expire: false\n"
        "ssh_pwauth: true\n"
    )


def get_vm_ip(host: Host, name: str, wait_seconds: int = 150) -> str | None:
    """轮询 virsh domifaddr 获取 VM 的 DHCP IP。"""
    script = (
        "ip=''; for i in $(seq 1 50); do "
        f"ip=$(sudo -n virsh domifaddr {name} 2>/dev/null | grep ipv4 | awk '{{print $4}}' | cut -d/ -f1); "
        "[ -n \"$ip\" ] && break; sleep 3; done; echo IP_RESULT=$ip"
    )
    rc, out, _ = _ssh(host, script, timeout=wait_seconds + 30)
    for line in (out or "").splitlines():
        if line.startswith("IP_RESULT="):
            val = line.split("=", 1)[1].strip()
            return val or None
    return None


def provision_vm(host: Host, vm: VirtualMachine, log) -> tuple[bool, str]:
    """在宿主机上按模板镜像创建并启动虚拟机。返回 (成功?, IP 或错误信息)。"""
    name = vm.name
    image = vm.image

    log("      [1/4] 确保模板镜像就绪 ...")
    if not ensure_image_on_host(host, image, log):
        return False, "模板镜像未就绪(MinIO 下载或宿主机存在性检查失败)"

    log(f"      [2/4] 创建 COW 覆盖卷 {name}.qcow2 ...")
    rc, out, err = _ssh(
        host,
        f"sudo -n qemu-img create -f qcow2 -F qcow2 -b {image} {IMAGES_DIR}/{name}.qcow2 && "
        f"sudo -n qemu-img resize {IMAGES_DIR}/{name}.qcow2 {vm.disk_gb}G && "
        f"sudo -n chown libvirt-qemu:kvm {IMAGES_DIR}/{name}.qcow2 && "
        f"sudo -n chmod 664 {IMAGES_DIR}/{name}.qcow2 && echo STEP_OK",
        timeout=300,
    )
    if rc != 0 or "STEP_OK" not in (out or ""):
        return False, "qemu-img 创建覆盖卷失败: " + ((out or err)[:300])

    log(f"      [3/4] 写入 cloud-init(默认 {DEFAULT_USER}/{DEFAULT_PASSWORD}, hostname={name}) ...")
    ud64 = base64.b64encode(_user_data(vm).encode("utf-8")).decode()
    md64 = base64.b64encode(
        f"instance-id: {name}\nlocal-hostname: {name}\n".encode("utf-8")
    ).decode()
    rc, out, err = _ssh(
        host,
        f"echo {ud64} | base64 -d > /tmp/csi-ud-{name} && "
        f"echo {md64} | base64 -d > /tmp/csi-md-{name} && echo CFG_OK",
        timeout=30,
    )
    if rc != 0 or "CFG_OK" not in (out or ""):
        return False, "写入 cloud-init 配置失败"

    log(f"      [4/4] virt-install 创建并启动({_os_variant(image)}) ...")
    variant = _os_variant(image)
    cmd = (
        f"sudo -n virsh pool-refresh images 2>/dev/null; "
        f"sudo -n virt-install --name {name} --vcpus {vm.cpu} --memory {vm.memory_gb * 1024} "
        f"--disk path={IMAGES_DIR}/{name}.qcow2,format=qcow2 --os-variant {variant} "
        f"--network {VM_NETWORK} --import --noautoconsole --graphics none "
        f"--cloud-init user-data=/tmp/csi-ud-{name},meta-data=/tmp/csi-md-{name},disable=on "
        f">/tmp/csi-vinst-{name}.log 2>&1; echo VINSTALL_RC=$?; tail -8 /tmp/csi-vinst-{name}.log"
    )
    rc, out, err = _ssh(host, cmd, timeout=600)
    if rc != 0 or "VINSTALL_RC=0" not in (out or ""):
        return False, "virt-install 失败: " + ((out or err)[:500])

    log("      [IP] 等待 DHCP 分配地址 ...")
    ip = get_vm_ip(host, name, wait_seconds=150)
    if ip:
        log("      虚拟机组网完成,IP: " + ip)
    return True, ip or ""


def virsh_action(host: Host, name: str, action: str) -> bool:
    """电源操作:start/stop/reboot,走宿主机 virsh。"""
    mapping = {"start": "start", "stop": "shutdown", "reboot": "reboot"}
    if action not in mapping:
        return False
    rc, _, _ = _ssh(host, f"sudo -n virsh {mapping[action]} {name}", timeout=120)
    return rc == 0


def virsh_delete(host: Host, name: str) -> bool:
    """销毁并删除虚拟机(含存储)。"""
    rc, _, _ = _ssh(
        host,
        f"sudo -n virsh destroy {name} 2>/dev/null; "
        f"sudo -n virsh undefine {name} --remove-all-storage 2>/dev/null; echo done",
        timeout=120,
    )
    return rc == 0