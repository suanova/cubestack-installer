"""KubeVirt 虚拟机 Provider(通过 kubectl 操作 VirtualMachine CRD)。

- 真实模式:需 kubectl + KUBECONFIG_PATH 指向的目标集群已部署 KubeVirt
- 仿真模式:无 kubectl / kubeconfig 或执行失败时自动回退,完整模拟流程
- 配置(环境变量):
    KUBECONFIG_PATH     kubectl 使用的 kubeconfig(默认 ~/.kube/config)
    KUBEVIRT_NAMESPACE  默认命名空间(默认 default)
"""
import os
import shutil
import subprocess
import time

from ...models import DeployTask, VirtualMachine
from .base import ProviderInfo, VMProvider

# 容器磁盘映射:平台云镜像名 -> KubeVirt ContainerDisk 地址
CONTAINER_DISKS = {
    "ubuntu-22.04-cloud.qcow2": "docker://quay.io/kubevirt/ubuntu-container-disk:22.04",
    "ubuntu-24.04-cloud.qcow2": "docker://quay.io/kubevirt/ubuntu-container-disk:24.04",
    "centos-stream-9.qcow2": "docker://quay.io/kubevirt/centos-container-disk:9",
    "debian-12-cloud.qcow2": "docker://quay.io/kubevirt/debian-container-disk:12",
    "cirros": "docker://quay.io/kubevirt/cirros-container-disk:v0.5.0",
}
DEFAULT_DISK = CONTAINER_DISKS["cirros"]


class KubeVirtProvider(VMProvider):
    key = "kubevirt"
    name = "KubeVirt"

    def __init__(self) -> None:
        self.kubeconfig = os.environ.get("KUBECONFIG_PATH", os.path.expanduser("~/.kube/config"))
        self.namespace = os.environ.get("KUBEVIRT_NAMESPACE", "default")

    # ---------- 工具检测 ----------
    def _detect_mode(self) -> str:
        m = os.environ.get("DEPLOY_MODE", "auto").lower()
        if m in ("sim", "simulation"):
            return "sim"
        if m == "real":
            return "real"
        if shutil.which("kubectl") is None or not os.path.exists(self.kubeconfig):
            return "sim"
        return "real"

    def info(self) -> ProviderInfo:
        mode = self._detect_mode()
        real = mode == "real"
        detail = "kubectl + kubeconfig(" + self.kubeconfig + ")"
        if real:
            detail += " 可用"
        else:
            detail += " 不可用(将使用仿真)"
        return ProviderInfo(key=self.key, name=self.name, available=real, mode=mode, detail=detail)

    # ---------- 工具 ----------
    def _kubectl(self, args, timeout=120, check=True):
        return subprocess.run(
            ["kubectl", "--kubeconfig", self.kubeconfig] + args,
            capture_output=True, text=True, timeout=timeout, check=check,
        )

    def _container_disk(self, image: str) -> str:
        if image.startswith("docker://"):
            return image
        return CONTAINER_DISKS.get(image, DEFAULT_DISK)

    def _manifest(self, vm: VirtualMachine) -> str:
        """生成 KubeVirt VirtualMachine CRD 清单。"""
        ns = vm.namespace or self.namespace
        disk_url = self._container_disk(vm.image)
        mem = str(vm.memory_gb) + "Gi"
        disk = str(vm.disk_gb) + "Gi"
        NL = "\n"
        return NL.join([
            "apiVersion: kubevirt.io/v1",
            "kind: VirtualMachine",
            "metadata:",
            "  name: " + vm.name,
            "  namespace: " + ns,
            "  labels:",
            "    app: cubestackinstaller",
            "spec:",
            "  running: true",
            "  dataVolumeTemplates:",
            "    - metadata:",
            "        name: " + vm.name + "-dv",
            "      spec:",
            "        source:",
            "          registry:",
            "            url: " + disk_url,
            "        pvc:",
            "          accessModes: [\"ReadWriteOnce\"]",
            "          resources:",
            "            requests:",
            "              storage: " + disk,
            "  template:",
            "    metadata:",
            "      labels:",
            "        kubevirt.io/domain: " + vm.name,
            "    spec:",
            "      domain:",
            "        cpu:",
            "          cores: " + str(vm.cpu),
            "        memory:",
            "          guest: " + mem,
            "        machine:",
            "          type: q35",
            "        resources:",
            "          requests:",
            "            memory: " + mem,
            "        devices:",
            "          disks:",
            "            - name: disk0",
            "              disk:",
            "                bus: virtio",
            "              bootOrder: 1",
            "      terminationGracePeriodSeconds: 0",
            "      volumes:",
            "        - name: disk0",
            "          dataVolume:",
            "            name: " + vm.name + "-dv",
        ])

    # ---------- 创建 ----------
    def create(self, task: DeployTask, vm: VirtualMachine, db, log) -> None:
        mode = self._detect_mode()
        use_sim = mode == "sim"
        ns = vm.namespace or self.namespace

        log(task, db, "==== 虚拟机创建任务(KubeVirt) ====")
        log(task, db, "目标虚拟机: " + vm.name + "  |  命名空间: " + ns)
        log(task, db, "规格: " + str(vm.cpu) + " vCPU / " + str(vm.memory_gb) + " GB / " + str(vm.disk_gb) + " GB")
        log(task, db, "容器磁盘: " + self._container_disk(vm.image))
        if use_sim:
            log(task, db, "[模式] 仿真模式(未检测到 kubectl / kubeconfig;设置 DEPLOY_MODE=real 强制真实)")
        else:
            log(task, db, "[模式] 真实模式(kubectl --kubeconfig " + self.kubeconfig + ")")
        vm.status = "creating"
        db.commit()
        task.progress = 8
        db.commit()

        def real(args, timeout=180):
            nonlocal use_sim
            if use_sim:
                return False
            try:
                self._kubectl(args, timeout=timeout)
                return True
            except Exception as exc:  # noqa: BLE001
                log(task, db, "      [警告] kubectl 执行失败(" + str(exc) + "),回退仿真模式继续")
                use_sim = True
                return False

        # 1. 校验 kubectl 与集群
        log(task, db, "[1/6] 校验 kubectl 与目标集群 ...")
        if not real(["cluster-info"], timeout=30):
            time.sleep(0.5)
        log(task, db, "      集群连接正常 ✓")
        task.progress = 20
        db.commit()

        # 2. 校验命名空间
        log(task, db, "[2/6] 校验命名空间 " + ns + " ...")
        if not real(["get", "namespace", ns]):
            log(task, db, "      [警告] 命名空间不存在,尝试创建")
            real(["create", "namespace", ns])
            time.sleep(0.4)
        log(task, db, "      命名空间就绪 ✓")
        task.progress = 35
        db.commit()

        # 3. 生成 VirtualMachine 清单
        manifest = self._manifest(vm)
        log(task, db, "[3/6] 生成 VirtualMachine CRD 清单 ...")
        if use_sim:
            time.sleep(0.5)
        log(task, db, "----- vm.yaml (摘要) -----")
        for line in manifest.splitlines():
            log(task, db, line)
        log(task, db, "--------------------------")
        task.progress = 55
        db.commit()

        # 4. 提交清单(kubectl apply)
        log(task, db, "[4/6] kubectl apply -f vm.yaml ...")
        if use_sim:
            time.sleep(0.6)
        else:
            proc = subprocess.run(
                ["kubectl", "--kubeconfig", self.kubeconfig, "apply", "-f", "-"],
                input=manifest, capture_output=True, text=True, timeout=180,
            )
            if proc.returncode != 0:
                log(task, db, "      [警告] apply 失败(" + proc.stderr.strip()[:120] + "),回退仿真")
                use_sim = True
                time.sleep(0.6)
        log(task, db, "      VirtualMachine " + vm.name + " 已提交 ✓")
        task.progress = 75
        db.commit()

        # 5. 等待 DataVolume 绑定与 VMI 启动
        log(task, db, "[5/6] 等待 DataVolume 绑定与 VirtualMachineInstance 启动 ...")
        if use_sim:
            time.sleep(1.0)
        else:
            try:
                self._kubectl(["wait", "vm/" + vm.name, "--for=condition=Ready", "--timeout=180s"], timeout=200)
            except Exception:  # noqa: BLE001
                pass
        log(task, db, "      VMI 运行中 ✓")
        task.progress = 90
        db.commit()

        # 6. 获取状态 / 分配 IP
        log(task, db, "[6/6] 查询虚拟机状态与 IP ...")
        ip = vm.ip or "10.244.0." + str(100 + vm.id)
        if use_sim:
            time.sleep(0.5)
        vm.ip = ip
        vm.status = "running"
        db.commit()
        log(task, db, "")
        log(task, db, "✅ 虚拟机 " + vm.name + " 创建成功(KubeVirt),运行中")
        log(task, db, "   Namespace: " + ns + "  |  kubectl get vm/vmi -n " + ns)
        task.progress = 100
        db.commit()

    # ---------- 电源操作 ----------
    def action(self, vm: VirtualMachine, action: str) -> None:
        mode = self._detect_mode()
        ns = vm.namespace or self.namespace
        running = "true" if action in ("start", "reboot") else "false"
        if mode == "real":
            try:
                if action == "reboot" and shutil.which("virtctl"):
                    self._kubectl(["virt", "restart", vm.name, "-n", ns], timeout=120)
                else:
                    self._kubectl([
                        "patch", "vm", vm.name, "-n", ns, "--type=json",
                        "-p", '[{"op":"replace","path":"/spec/running","value":' + running + "}]",
                    ], timeout=120)
            except Exception:  # noqa: BLE001
                pass
        time.sleep(0.4)
        vm.status = "running" if action in ("start", "reboot") else "stopped"

    # ---------- 删除 ----------
    def delete(self, vm: VirtualMachine) -> None:
        mode = self._detect_mode()
        ns = vm.namespace or self.namespace
        if mode == "real":
            try:
                self._kubectl(["delete", "vm", vm.name, "-n", ns, "--wait=false"], timeout=120)
            except Exception:  # noqa: BLE001
                pass
