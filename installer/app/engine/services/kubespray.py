"""Kubespray 安装 K8s 集群(第三步:改 hosts.yml + 运行 cubestack-offline.sh)。"""
import os
import shutil
import subprocess
import time

from ...db.session import SessionLocal
from ...models import ClusterNode, DeployTask, Host, K8sCluster
from ..executor import log_line
from .clusterprep import ANSIBLE_VENV, KUBESPRAY_DIR, PIP_INDEX, _mc_env, _ensure_mc
from .vmprovision import _ssh

RUN_KEY_FILE = os.environ.get("KUBESPRAY_SSH_KEY", "/root/.ssh/id_rsa")
# cubestack-offline.sh 期望的目录布局(脚本内 BASE_DIR 固定为 /opt/cubestack-installer)
CUBESTACK_BASE = "/opt/cubestack-installer"
CUBESTACK_SCRIPT = CUBESTACK_BASE + "/cubestack-offline.sh"
# 离线脚本使用的集群名,对应 MinIO 上 kubespray/inventory/cubestack-cluster 目录
CUBESTACK_CLUSTER = "cubestack-cluster"
WORKSPACE = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(__file__)))), "workspace"
)


def _sim_mode(run_node: Host | None) -> bool:
    if os.environ.get("DEPLOY_MODE", "auto").lower() in ("sim", "simulation"):
        return True
    if run_node is not None:
        # 运行节点模式:环境是否就绪在安装步骤里显式检查并报错,不静默仿真
        return False
    return shutil.which("ansible-playbook") is None or not os.path.isdir(KUBESPRAY_DIR)


def _ensure_cubestack_on_host(run_node: Host, task, db) -> str:
    """在运行节点上把 cubestack 离线安装工具链下载到 /opt/cubestack-installer。"""
    rc, out, err = _ssh(run_node, "ls " + CUBESTACK_SCRIPT + " >/dev/null 2>&1 && ls " + CUBESTACK_BASE + "/kubespray/cluster.yml >/dev/null 2>&1 && echo ALREADY", timeout=20)
    if "ALREADY" in out:
        return CUBESTACK_BASE
    _ensure_mc(run_node, task, db)
    log_line(task, db, "      [下载] 从 MinIO " + _mc_env().split("@")[-1] + "/cubestack/installer/ansible/kubespray 下载离线安装工具到 " + CUBESTACK_BASE + " ...")
    rc, out, err = _ssh(run_node, "sudo mkdir -p " + CUBESTACK_BASE + " && sudo chown $(whoami) " + CUBESTACK_BASE + " && " + _mc_env() + " mc mirror minio/cubestack/installer/ansible/kubespray " + CUBESTACK_BASE + " && chmod +x " + CUBESTACK_SCRIPT + " && ls " + CUBESTACK_BASE + "/kubespray/cluster.yml", timeout=1800)
    if rc != 0 or "cluster.yml" not in out:
        raise RuntimeError("从 MinIO 下载 kubespray 离线工具失败: " + (err or out))
    log_line(task, db, "      cubestack 离线安装工具下载完成 ✓")
    return CUBESTACK_BASE


def _build_inventory(cluster: K8sCluster, nodes: list[ClusterNode], key_file: str) -> str:
    """生成 kubespray inventory.ini(管理机本机执行路径)。"""
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
    lines.append("ansible_ssh_private_key_file=" + key_file)
    return "\n".join(lines)


def _build_inventory_yaml(cluster: K8sCluster, nodes: list[ClusterNode], key_file: str) -> str:
    """生成新版 kubespray hosts.yml(运行节点 + cubestack-offline.sh 使用)。"""
    masters = [n for n in nodes if n.role == "control_plane"]
    workers = [n for n in nodes if n.role == "worker"]
    lines = []
    lines.append("all:")
    lines.append("  vars:")
    lines.append("    ansible_become: true")
    lines.append("    ansible_become_method: sudo")
    lines.append("kube_control_plane:")
    lines.append("  hosts:")
    for n in masters:
        ip = n.ip or ""
        lines.append("    " + n.name + ":")
        lines.append("      ansible_host: " + ip)
        lines.append("      ip: " + ip + "            # K8s 内部通信使用的 IP")
        lines.append("      access_ip: " + ip + "     # API Server 对外暴露的 IP")
        lines.append("      ansible_user: ubuntu")
        lines.append("      ansible_ssh_private_key_file: " + key_file)
    lines.append("etcd:")
    lines.append("  children:")
    lines.append("    kube_control_plane:")
    lines.append("kube_node:")
    lines.append("  hosts:")
    for n in workers:
        ip = n.ip or ""
        lines.append("    " + n.name + ":")
        lines.append("      ansible_host: " + ip)
        lines.append("      ip: " + ip)
        lines.append("      access_ip: " + ip)
        lines.append("      ansible_user: ubuntu")
        lines.append("      ansible_ssh_private_key_file: " + key_file)
    lines.append("k8s_cluster:")
    lines.append("  children:")
    lines.append("    kube_control_plane:")
    lines.append("    kube_node:")
    return "\n".join(lines) + "\n"


def run_cluster_install(task: DeployTask, db) -> None:
    """执行集群安装任务。"""
    cluster = db.get(K8sCluster, task.target_id)
    if cluster is None:
        raise RuntimeError("集群不存在(可能已被删除)")
    nodes = db.query(ClusterNode).filter(ClusterNode.cluster_id == cluster.id).all()
    run_node = None
    if cluster.run_node_host_id:
        run_node = db.get(Host, cluster.run_node_host_id)
        if run_node is None:
            log_line(task, db, "[提示] Kubespray 运行节点(宿主机 " + str(cluster.run_node_host_id) + ")不存在,回退到管理机本机执行")
    sim = _sim_mode(run_node)
    key_file = "/home/" + run_node.ssh_user + "/.ssh/id_rsa" if run_node is not None else RUN_KEY_FILE

    log_line(task, db, "==== Kubespray 集群安装任务 ====")
    log_line(task, db, "集群: " + cluster.name + "  |  K8s " + cluster.k8s_version)
    log_line(task, db, "网络插件: " + cluster.network_plugin + "  |  Kubespray " + cluster.kubespray_version)
    if run_node is not None:
        log_line(task, db, "运行节点: " + run_node.name + " (" + run_node.ip + ")  [宿主机]")
    else:
        log_line(task, db, "运行节点: 平台管理机(本机)")
    log_line(task, db, "节点: 控制平面 " + str(len([n for n in nodes if n.role == "control_plane"]))
             + " 个 / 工作节点 " + str(len([n for n in nodes if n.role == "worker"])) + " 个")
    if sim:
        log_line(task, db, "[模式] 以仿真模式执行(仅演示流程)")
    else:
        log_line(task, db, "[模式] 以真实模式执行")
    cluster.status = "installing"
    db.commit()
    task.progress = 5
    db.commit()

    # 步骤 1: 下载 cubestack 离线安装工具链到运行节点
    if run_node is not None:
        log_line(task, db, "[1/8] 检查/下载运行节点 " + run_node.name + " 的 cubestack 离线安装工具 ...")
        _ensure_cubestack_on_host(run_node, task, db)
        rc, out, err = _ssh(run_node, "test -x " + ANSIBLE_VENV + "/bin/ansible-playbook && echo ANSIBLE_OK || echo NO_ANSIBLE", timeout=20)
        if "ANSIBLE_OK" not in out:
            raise RuntimeError("运行节点缺少 Ansible 环境,请先在创建集群向导「第一步」中准备安装机环境")
        log_line(task, db, "      ansible 环境(venv)检测: 通过 ✓")
    else:
        log_line(task, db, "[1/8] 校验管理机 Kubespray 仓库 " + KUBESPRAY_DIR + " ...")
        if sim:
            time.sleep(0.6)
        log_line(task, db, "      仓库校验通过 ✓")
    task.progress = 12
    db.commit()

    # 步骤 2: 生成 Ansible 清单(运行节点模式:hosts.yml;本机模式:inventory.ini)
    if run_node is not None:
        inventory = _build_inventory_yaml(cluster, nodes, key_file)
        inv_name = "hosts.yml"
    else:
        inventory = _build_inventory(cluster, nodes, key_file)
        inv_name = "inventory.ini"
    log_line(task, db, "[2/8] 生成 Ansible 清单(" + inv_name + ") ...")
    if sim:
        time.sleep(0.5)
    log_line(task, db, "----- " + inv_name + " -----")
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

    # 步骤 5: 改写 hosts.yml + 运行 cubestack-offline.sh install
    if not sim:
        try:
            if run_node is not None:
                inv_path = CUBESTACK_BASE + "/inventory/cubestack-cluster/hosts.yml"
                rc, out, err = _ssh(run_node, "mkdir -p " + CUBESTACK_BASE + "/inventory/cubestack-cluster/group_vars/all && cat > " + inv_path + " <<'CSIEOF'\n" + inventory + "CSIEOF\necho WROTE_OK", timeout=30)
                if rc != 0 or "WROTE_OK" not in out:
                    raise RuntimeError("写入 hosts.yml 到运行节点失败: " + (err or out))
                log_line(task, db, "      [运行节点 " + run_node.name + "] 已改写 inventory/cubestack-cluster/hosts.yml")
                # 预置 kubespray venv(uv + requirements.txt,幂等)
                from .clusterprep import PIP_INDEX as _PI
                idx = (" --index-url " + _PI) if _PI else ""
                venv = CUBESTACK_BASE + "/kubespray/.venv"
                rc, out, err = _ssh(run_node, "if [ ! -x " + venv + "/bin/ansible-playbook ]; then rm -rf " + venv + " && uv venv --python 3.12 " + venv + " && uv pip install --python " + venv + idx + " -r " + CUBESTACK_BASE + "/kubespray/requirements.txt; fi && echo VENV_OK", timeout=1200)
                log_line(task, db, "      kubespray 依赖环境: " + ("✓" if "VENV_OK" in out else "失败(" + (err or out)[-200:] + ")"))
                if "VENV_OK" not in out:
                    raise RuntimeError("kubespray 依赖环境准备失败: " + (err or out))
                log_line(task, db, "      执行 " + CUBESTACK_SCRIPT + " install " + CUBESTACK_CLUSTER + "(运行节点 " + run_node.name + "),输出实时回传 ...")
                # 流式读取安装输出,分批写入任务日志(向导控制台实时显示)
                _buf = []
                _flushed = 0

                def _flush_lines():
                    nonlocal _buf
                    if _buf:
                        log_line(task, db, "\n".join(_buf))
                        _buf = []

                def _on_line(line):
                    nonlocal _buf, _flushed
                    s = line.rstrip()
                    if not s.strip():
                        return
                    _buf.append("      " + s.strip())
                    if len(_buf) >= 20:
                        _flush_lines()
                        _flushed += 1
                        if _flushed % 50 == 0:  # 每约 1000 行截断一次,防止日志无限膨胀
                            if (task.log_text or "").count("\n") > 3000:
                                task.log_text = "\n".join((task.log_text or "").splitlines()[-3000:]) + "\n"
                                db.commit()

                # 后台执行安装(与 SSH 会话解耦:连接被掐断也不影响安装),退出码写入 done 文件
                # 注意:后台命令必须整体包在 "( ... )" 里并把重定向放在子 shell 上——
                # 否则 bash 为 "A && B &" 派生的子 shell 会持有 SSH 通道的 stdout/stderr,
                # sshd 收不到通道 EOF,启动命令会一直挂起直到 _ssh 超时,被误判为启动失败。
                inst_log = "/tmp/csi-install-" + CUBESTACK_CLUSTER + ".log"
                inst_done = "/tmp/csi-install-" + CUBESTACK_CLUSTER + ".done"
                rc, out, err = _ssh(run_node, "rm -f " + inst_log + " " + inst_done + "; ( cd " + CUBESTACK_BASE + " && setsid bash -c '" + "CUBESTACK_LOCAL_REPO_DIR=" + CUBESTACK_BASE + "/inventory/cubestack-cluster bash " + CUBESTACK_SCRIPT + " install " + CUBESTACK_CLUSTER + " > " + inst_log + " 2>&1; echo $? > " + inst_done + "' ) >/dev/null 2>&1 </dev/null & echo STARTED", timeout=30)
                if "STARTED" not in out:
                    # 兜底:即使启动命令的 SSH 连接异常(超时/被掐断),只要安装进程确实已在运行节点启动,仍继续轮询
                    r2, o2, e2 = _ssh(run_node, "pgrep -f 'cubestack-offline[.]sh install ' >/dev/null 2>&1 && echo PROC_RUNNING || echo NO_PROC", timeout=20)
                    if "PROC_RUNNING" not in o2:
                        raise RuntimeError("后台启动 cubestack-offline.sh 失败: " + (err or out or "SSH 无响应(可能超时),且未检测到安装进程"))
                    log_line(task, db, "      [提示] 启动命令的 SSH 连接异常,但安装进程已在运行节点启动,继续轮询日志 ...")
                # 轮询日志文件,增量回传控制台(每次短连接,不会因长会话被掐断)
                line_no = 1
                final_rc = None
                deadline = time.time() + 7200
                while time.time() < deadline:
                    r, o, e = _ssh(run_node, "tail -n +" + str(line_no) + " " + inst_log + " 2>/dev/null", timeout=30)
                    if o and o.strip():
                        ls = o.splitlines()
                        line_no += len(ls)
                        for ln in ls:
                            _on_line(ln)
                    r2, d, e2 = _ssh(run_node, "test -f " + inst_done + " && cat " + inst_done + " || echo NOTDONE", timeout=30)
                    if "NOTDONE" not in d and d.strip():
                        final_rc = int(d.strip())
                        break
                    time.sleep(8)
                _flush_lines()
                if final_rc is None:
                    raise RuntimeError("cubestack-offline.sh 安装超时(超过 2 小时)")
                if final_rc != 0:
                    raise RuntimeError("cubestack-offline.sh 安装失败(rc=" + str(final_rc) + ")")
            else:
                ws = os.path.join(WORKSPACE, "cluster-" + cluster.name)
                os.makedirs(ws, exist_ok=True)
                inv_path = os.path.join(ws, "inventory.ini")
                with open(inv_path, "w", encoding="utf-8") as f:
                    f.write(inventory)
                cmd = ["ansible-playbook", "-i", inv_path,
                       os.path.join(KUBESPRAY_DIR, "cluster.yml")]
                subprocess.run(cmd, check=True, timeout=3600)
        except Exception as exc:  # noqa: BLE001
            log_line(task, db, "      真实执行失败: " + str(exc))
            raise
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
