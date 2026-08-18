"""K8s 安装机向导:环境准备(uv+Python3.12+Ansible)与 SSH 免密配置。"""
import os

from ...db.session import SessionLocal
from ...models import ClusterNode, DeployTask, Host, K8sCluster
from ..executor import log_line
from .vmprovision import _ssh

MINIO_ENDPOINT = os.environ.get("MINIO_ENDPOINT", "10.66.1.207:9000")
MINIO_ACCESS = os.environ.get("MINIO_ACCESS_KEY", "admin")
MINIO_SECRET = os.environ.get("MINIO_SECRET_KEY", "Suanova@123")
MINIO_BUCKET = os.environ.get("MINIO_BUCKET", "cubestack")
UV_TARBALL = "installer/bin/uv.tar.gz"
KUBESPRAY_PREFIX = "installer/ansible/kubespray"
# 运行节点上安装 ansible 用的 PyPI 源(国内可配阿里云/清华镜像)
PIP_INDEX = os.environ.get("CLUSTER_PIP_INDEX", "https://mirrors.aliyun.com/pypi/simple/")
# 集群节点初始密码(ssh-copy-id 用)
NODE_PASSWORD = os.environ.get("CLUSTER_NODE_PASSWORD", "ubuntu")
ANSIBLE_VENV = "/opt/ansible-venv"
KUBESPRAY_DIR = "/opt/kubespray"


def _mc_env() -> str:
    return "MC_HOST_minio=http://" + MINIO_ACCESS + ":" + MINIO_SECRET + "@" + MINIO_ENDPOINT


def _ensure_mc(host: Host, task, db) -> None:
    """确保运行节点上有 mc(minio 客户端)。"""
    rc, out, err = _ssh(host, "command -v mc >/dev/null 2>&1 && echo MC_OK", timeout=20)
    if "MC_OK" not in out:
        log_line(task, db, "      mc 未安装,从 dl.minio.org.cn 下载安装 ...")
        rc, out, err = _ssh(host, "sudo wget -q -O /usr/local/bin/mc https://dl.minio.org.cn/client/mc/release/linux-amd64/mc && sudo chmod +x /usr/local/bin/mc && command -v mc && echo MC_INSTALLED", timeout=180)
        if "MC_INSTALLED" not in out:
            raise RuntimeError("mc 安装失败: " + (err or out))


def run_cluster_prepare(task: DeployTask, db) -> None:
    """向导第一步:检查/配置 K8s 安装机环境(uv -> Python3.12 -> Ansible)。"""
    cluster = db.get(K8sCluster, task.target_id)
    if cluster is None:
        raise RuntimeError("集群不存在(可能已被删除)")
    if not cluster.run_node_host_id:
        raise RuntimeError("未选择 Kubespray 运行节点(宿主机),请先编辑集群")
    host = db.get(Host, cluster.run_node_host_id)
    if host is None:
        raise RuntimeError("Kubespray 运行节点(宿主机)不存在")

    log_line(task, db, "==== 向导 · 第一步:检查/配置 K8s 安装机环境 ====")
    log_line(task, db, "安装机: " + host.name + " (" + host.ip + ")")
    task.progress = 5
    db.commit()

    # 1. 确保 mc
    log_line(task, db, "[1/6] 检查 MinIO 客户端 mc ...")
    _ensure_mc(host, task, db)
    log_line(task, db, "      mc 就绪 ✓")
    task.progress = 15
    db.commit()

    # 2. 从 MinIO 下载 uv
    log_line(task, db, "[2/6] 从 MinIO " + MINIO_ENDPOINT + "/" + MINIO_BUCKET + "/" + UV_TARBALL + " 下载 uv ...")
    rc, out, err = _ssh(host, _mc_env() + " mc cp minio/" + MINIO_BUCKET + "/" + UV_TARBALL + " /tmp/csi-uv.tar.gz && ls -l /tmp/csi-uv.tar.gz", timeout=300)
    if rc != 0 or "/tmp/csi-uv.tar.gz" not in out:
        raise RuntimeError("下载 uv 失败: " + (err or out))
    log_line(task, db, "      uv.tar.gz 下载完成(22MiB)✓")
    task.progress = 30
    db.commit()

    # 3. 解压并安装 uv
    log_line(task, db, "[3/6] 解压并安装 uv 到 /usr/local/bin/uv ...")
    rc, out, err = _ssh(host, "rm -rf /tmp/csi-uv && mkdir -p /tmp/csi-uv && tar -xzf /tmp/csi-uv.tar.gz -C /tmp/csi-uv && sudo install -m 755 /tmp/csi-uv/uv-*/uv /usr/local/bin/uv && uv --version", timeout=120)
    if rc != 0 or "uv" not in out:
        raise RuntimeError("安装 uv 失败: " + (err or out))
    for ln in (out or "").splitlines()[:3]:
        if ln.strip():
            log_line(task, db, "      " + ln.strip())
    task.progress = 45
    db.commit()

    # 4. uv 安装 Python 3.12
    log_line(task, db, "[4/6] 使用 uv 安装 Python 3.12(首次会从远端下载解释器) ...")
    rc, out, err = _ssh(host, "uv python install 3.12", timeout=900)
    if rc != 0:
        raise RuntimeError("uv python install 3.12 失败: " + (err or out) + "\n提示:若下载 GitHub 解释器超时,可在平台环境变量设置 UV_PYTHON_INSTALL_MIRROR 指定国内镜像")
    ver = _ssh(host, "uv run --python 3.12 python --version", timeout=60)[1].strip()
    log_line(task, db, "      Python " + ver + " 安装完成 ✓")
    task.progress = 60
    db.commit()

    # 5. 创建 venv 并安装 Ansible
    log_line(task, db, "[5/6] 创建虚拟环境 /opt/ansible-venv 并安装 Ansible ...")
    if PIP_INDEX:
        index_arg = " --index-url " + PIP_INDEX
    else:
        index_arg = ""
    rc, out, err = _ssh(host, "sudo rm -rf " + ANSIBLE_VENV + " && sudo mkdir -p " + ANSIBLE_VENV + " && sudo chown $(whoami) " + ANSIBLE_VENV + " && uv venv " + ANSIBLE_VENV + " --python 3.12 && uv pip install --python " + ANSIBLE_VENV + index_arg + " 'ansible-core>=2.15'", timeout=900)
    if rc != 0:
        raise RuntimeError("安装 Ansible 失败: " + (err or out))
    log_line(task, db, "      Ansible 依赖安装完成 ✓")
    task.progress = 85
    db.commit()

    # 6. 用 ansible-playbook 验证运行环境
    log_line(task, db, "[6/6] 运行 ansible-playbook --version 验证环境 ...")
    rc, out, err = _ssh(host, ANSIBLE_VENV + "/bin/ansible-playbook --version", timeout=60)
    if rc != 0:
        raise RuntimeError("ansible-playbook 验证失败: " + (err or out))
    for ln in (out or "").splitlines()[:4]:
        if ln.strip():
            log_line(task, db, "      " + ln.strip())
    log_line(task, db, "")
    log_line(task, db, "✅ 第一步完成:安装机环境就绪(uv / Python 3.12 / Ansible)")
    task.progress = 100
    db.commit()


def run_cluster_sshkey(task: DeployTask, db) -> None:
    """向导第二步:在安装机上生成公钥并免密到所有集群节点。"""
    cluster = db.get(K8sCluster, task.target_id)
    if cluster is None:
        raise RuntimeError("集群不存在(可能已被删除)")
    if not cluster.run_node_host_id:
        raise RuntimeError("未选择 Kubespray 运行节点(宿主机)")
    host = db.get(Host, cluster.run_node_host_id)
    if host is None:
        raise RuntimeError("Kubespray 运行节点(宿主机)不存在")
    nodes = db.query(ClusterNode).filter(ClusterNode.cluster_id == cluster.id).all()
    node_ips = [n.ip for n in nodes if n.ip]
    if not node_ips:
        raise RuntimeError("集群没有可用的节点 IP,请先确认集群节点")

    log_line(task, db, "==== 向导 · 第二步:配置安装机到集群节点 SSH 免密 ====")
    log_line(task, db, "安装机: " + host.name + " (" + host.ip + ")  目标节点: " + str(len(node_ips)) + " 个")
    task.progress = 5
    db.commit()

    # 1. 确保 sshpass(ssh-copy-id 输密码用)
    log_line(task, db, "[1/4] 检查 sshpass ...")
    rc, out, err = _ssh(host, "command -v sshpass >/dev/null 2>&1 || (sudo apt-get update -qq && sudo apt-get install -y -qq sshpass)", timeout=300)
    if rc != 0:
        raise RuntimeError("安装 sshpass 失败: " + (err or out))
    log_line(task, db, "      sshpass 就绪 ✓")
    task.progress = 20
    db.commit()

    # 2. 检查/生成公钥
    log_line(task, db, "[2/4] 检查安装机 SSH 公钥 ...")
    rc, out, err = _ssh(host, "if [ -f ~/.ssh/id_rsa.pub ]; then echo HAVE_KEY; else ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa -q; echo KEY_GENERATED; fi", timeout=60)
    if "KEY_GENERATED" in out:
        log_line(task, db, "      未发现公钥,已用 ssh-keygen 生成 ✓")
    else:
        log_line(task, db, "      公钥已存在 ✓")
    task.progress = 40
    db.commit()

    # 3. ssh-copy-id 到所有节点
    log_line(task, db, "[3/4] 使用 ssh-copy-id 推送公钥到各节点(密码: " + NODE_PASSWORD + ") ...")
    for ip in node_ips:
        rc, out, err = _ssh(host, "sshpass -p " + NODE_PASSWORD + " ssh-copy-id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@" + ip + " >/dev/null 2>&1 && echo COPIED", timeout=90)
        log_line(task, db, "      " + ip + " -> " + ("公钥已推送 ✓" if "COPIED" in out else "推送失败 ✗"))
    task.progress = 75
    db.commit()

    # 4. 验证免密
    log_line(task, db, "[4/4] 验证免密登录(BatchMode) ...")
    all_ok = True
    for ip in node_ips:
        rc, out, err = _ssh(host, "ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no ubuntu@" + ip + " 'echo PASSWORDLESS_OK'", timeout=30)
        ok = "PASSWORDLESS_OK" in out
        all_ok = all_ok and ok
        log_line(task, db, "      " + ip + " -> " + ("免密 OK ✓" if ok else "免密失败 ✗(" + (err or out).strip()[:80] + ")"))
    log_line(task, db, "")
    if all_ok:
        log_line(task, db, "✅ 第二步完成:安装机已免密到所有集群节点")
        task.progress = 100
    else:
        log_line(task, db, "⚠ 部分节点免密失败,请检查节点密码或网络后重试")
        task.progress = 100
    db.commit()
