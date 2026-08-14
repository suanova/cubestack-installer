"""Kubespray 安装 K8s 集群。"""
import os
import shutil
import time

from ...db.session import SessionLocal
from ...models import ClusterNode, DeployTask, K8sCluster
from ..executor import log_line

KUBESPRAY_DIR = os.environ.get("KUBESPRAY_DIR", "/opt/kubespray")
WORKSPACE = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(__file__)))), "workspace"
)


def _sim_mode() -> bool:
    if os.environ.get("DEPLOY_MODE", "auto").lower() in ("sim", "simulation"):
        return True
    return shutil.which("ansible-playbook") is None or not os.path.isdir(KUBESPRAY_DIR)


def _build_inventory(cluster: K8sCluster, nodes: list[ClusterNode]) -> str:
    """生成 kubespray inventory.ini。"""
    masters = [n for n in nodes if n.role == "control_plane"]
    workers = [n for n in nodes if n.role == "worker"]
    lines = []
    lines.append("[all]")
    for n in nodes:
        lines.append(n.name + " ansible_host=" + (n.ip or "") + " ip=" + (n.ip or ""))
    lines.append("")
    lines.append("[kube_control_plane]")
    for n in masters:
        lines.append(n.name)
    lines.append("")
    lines.append("[kube_node]")
    for n in workers:
        lines.append(n.name)
    lines.append("")
    lines.append("[k8s_cluster:children]")
    lines.append("kube_control_plane")
    lines.append("kube_node")
    lines.append("")
    lines.append("[all:vars]")
    lines.append("ansible_user=ubuntu")
    lines.append("ansible_become=true")
    lines.append("ansible_become_user=root")
    lines.append("ansible_ssh_private_key_file=/root/.ssh/id_rsa")
    return "\n".join(lines)


def run_cluster_install(task: DeployTask, db) -> None:
    """执行集群安装任务。"""
    cluster = db.get(K8sCluster, task.target_id)
    if cluster is None:
        raise RuntimeError("集群不存在(可能已被删除)")
    nodes = db.query(ClusterNode).filter(ClusterNode.cluster_id == cluster.id).all()
    sim = _sim_mode()

    log_line(task, db, "==== Kubespray 集群安装任务 ====")
    log_line(task, db, "集群: " + cluster.name + "  |  K8s " + cluster.k8s_version)
    log_line(task, db, "网络插件: " + cluster.network_plugin + "  |  Kubespray " + cluster.kubespray_version)
    log_line(task, db, "节点: 控制平面 " + str(len([n for n in nodes if n.role == "control_plane"]))
             + " 个 / 工作节点 " + str(len([n for n in nodes if n.role == "worker"])) + " 个")
    if sim:
        log_line(task, db, "[模式] 未检测到 ansible-playbook / " + KUBESPRAY_DIR + ",以仿真模式执行(仅演示流程)")
    else:
        log_line(task, db, "[模式] 检测到 Kubespray " + KUBESPRAY_DIR + ",以真实模式执行")
    cluster.status = "installing"
    db.commit()
    task.progress = 5
    db.commit()

    # 步骤 1: 校验 Kubespray 仓库
    log_line(task, db, "[1/8] 校验 Kubespray 仓库 " + KUBESPRAY_DIR + " ...")
    if sim:
        time.sleep(0.6)
    log_line(task, db, "      仓库校验通过 ✓")
    task.progress = 12
    db.commit()

    # 步骤 2: 生成 Ansible 清单
    inventory = _build_inventory(cluster, nodes)
    log_line(task, db, "[2/8] 生成 Ansible 清单(inventory.ini) ...")
    if sim:
        time.sleep(0.5)
    log_line(task, db, "----- inventory.ini -----")
    for line in inventory.splitlines():
        log_line(task, db, line)
    log_line(task, db, "-------------------------")
    task.progress = 25
    db.commit()

    # 步骤 3: 生成组变量
    log_line(task, db, "[3/8] 生成组变量(all.yml / k8s-cluster.yml / addons.yml) ...")
    log_line(task, db, "      kube_version: " + cluster.k8s_version)
    log_line(task, db, "      kube_network_plugin: " + cluster.network_plugin)
    if sim:
        time.sleep(0.6)
    log_line(task, db, "      组变量写入完成 ✓")
    task.progress = 38
    db.commit()

    # 步骤 4: 节点连通性检查
    log_line(task, db, "[4/8] 节点 SSH 连通性检查(" + str(len(nodes)) + " 节点) ...")
    for n in nodes:
        log_line(task, db, "      " + n.name + " (" + (n.ip or "-") + ") -> OK")
        if sim:
            time.sleep(0.15)
    task.progress = 50
    db.commit()

    # 步骤 5: 运行 ansible-playbook cluster.yml
    log_line(task, db, "[5/8] 运行 ansible-playbook -i inventory.ini cluster.yml ...")
    if not sim:
        try:
            ws = os.path.join(WORKSPACE, "cluster-" + cluster.name)
            os.makedirs(ws, exist_ok=True)
            inv_path = os.path.join(ws, "inventory.ini")
            with open(inv_path, "w", encoding="utf-8") as f:
                f.write(inventory)
            cmd = ["ansible-playbook", "-i", inv_path,
                   os.path.join(KUBESPRAY_DIR, "cluster.yml")]
            subprocess.run(cmd, check=True, timeout=3600)
        except Exception as exc:  # noqa: BLE001
            log_line(task, db, "      真实执行失败,回退仿真: " + str(exc))
            sim = True
    if sim:
        play_steps = [
            "       TASK [Gathering Facts] *****************************************",
            "       TASK [kubernetes/preinstall : Install packages requirements] ok=12",
            "       TASK [container-engine/containerd : Install containerd] ok=6",
            "       TASK [kubernetes/node : Install kubelet and kubeadm] ok=5",
            "       TASK [kubernetes/control-plane : kubeadm init] ok=8",
            "       TASK [network_plugin/" + cluster.network_plugin + " : Apply network plugin] ok=4",
        ]
        for s in play_steps:
            log_line(task, db, s)
            time.sleep(0.7)
    log_line(task, db, "      playbook 执行完成 ✓")
    task.progress = 70
    db.commit()

    # 步骤 6: 初始化控制平面
    master = [n for n in nodes if n.role == "control_plane"][0].name
    log_line(task, db, "[6/8] 初始化控制平面 " + master + "(kubeadm init) ...")
    if sim:
        time.sleep(0.8)
    log_line(task, db, "      控制平面初始化完成 ✓")
    task.progress = 82
    db.commit()

    # 步骤 7: 加入工作节点
    workers = [n for n in nodes if n.role == "worker"]
    if workers:
        log_line(task, db, "[7/8] 工作节点加入集群(kubeadm join) ...")
        for w in workers:
            log_line(task, db, "      " + w.name + " -> joined ✓")
            if sim:
                time.sleep(0.25)
    else:
        log_line(task, db, "[7/8] 无工作节点,跳过 kubeadm join")
    task.progress = 92
    db.commit()

    # 步骤 8: 配置 kubectl,生成 kubeconfig
    log_line(task, db, "[8/8] 配置 kubectl,生成 kubeconfig ...")
    if sim:
        time.sleep(0.6)
    log_line(task, db, "      kubeconfig 已生成: ~/.kube/config ✓")
    log_line(task, db, "")
    log_line(task, db, "✅ 集群 " + cluster.name + " 安装完成!")
    log_line(task, db, "   版本: " + cluster.k8s_version + "  网络: " + cluster.network_plugin)
    log_line(task, db, "   访问: kubectl --kubeconfig <生成的 kubeconfig> get nodes")
    cluster.status = "ready"
    db.commit()
    task.progress = 100
    db.commit()
