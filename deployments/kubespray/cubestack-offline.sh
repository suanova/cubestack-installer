#!/bin/bash
set -euo pipefail

BASE_DIR="/opt/cubestack-installer"
KUBESPRAY_DIR="${BASE_DIR}/kubespray"
LOCAL_REPO_BASE="${BASE_DIR}/repository"
INVENTORY_BASE="${BASE_DIR}/inventory"
REMOTE_USER="${CUBESTACK_REMOTE_USER:-ubuntu}"
CONTAINER_RUNTIME="containerd"
KUBESPRAY_VERSION="v2.28.0"
KUBESPRAY_REPO="https://github.com/kubernetes-sigs/kubespray.git"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()       { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()      { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()       { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
highlight() { echo -e "${CYAN}>>> $*${NC}"; }

usage() {
    echo "用法: $0 <命令> [集群名称] [选项]"
    echo ""
    echo "  集群名称可选，默认为 cubestack-cluster"
    echo "  也可通过环境变量 CUBESTACK_CLUSTER 指定"
    echo ""
    echo "命令:"
    echo "  init       [名称]           初始化环境"
    echo "  download   [名称]           下载离线资源（使用 download-hosts.yml，本地 root）"
    echo "  install    [名称] [选项]    执行集群安装（使用 hosts.yml，目标节点 ubuntu）"
    echo "  scale      [名称] [选项]    扩容集群 — 添加新节点到已有集群"
    echo "  check      [名称]           预检资源与连通性"
    echo ""
    echo "选项:"
    echo "  --limit <group>   限制目标组，可选值:"
    echo "                      kube_control_plane  — 仅部署 master 节点"
    echo "                      kube_node           — 仅部署 worker 节点"
    echo "                      etcd                — 仅部署 etcd 节点"
    echo ""
    echo "示例:"
    echo "  $0 install mycluster --limit kube_control_plane   # 仅部署 master"
    echo "  $0 install mycluster --limit kube_node            # 仅部署 worker"
    echo "  $0 scale   mycluster --limit kube_node            # 扩容加入新 worker"
    echo "  $0 scale   mycluster --limit kube_control_plane   # 扩容加入新 master"
    exit 0
}

resolve_cluster_name() {
    local cmd="$1"
    local arg="$2"
    if [ -n "$arg" ]; then
        echo "$arg"
    elif [ -n "${CUBESTACK_CLUSTER:-}" ]; then
        echo "${CUBESTACK_CLUSTER}"
    else
        echo "cubestack-cluster"
    fi
}

detect_runtime() {
    if command -v nerdctl >/dev/null 2>&1; then
        echo "nerdctl"
    elif command -v docker >/dev/null 2>&1; then
        echo "docker"
    elif command -v podman >/dev/null 2>&1; then
        echo "podman"
    else
        err "未找到容器运行时 (nerdctl/docker/podman)"
    fi
}

# 返回对应运行时的 pull 命令（含参数）
get_pull_cmd() {
    case "$1" in
        nerdctl) echo "nerdctl -n k8s.io pull --quiet" ;;
        docker)  echo "docker pull" ;;
        podman)  echo "podman pull" ;;
        *)       err "未知运行时: $1" ;;
    esac
}

# 返回对应运行时的 save 命令（不含输出文件参数，调用方自行追加 -o <dest>）
get_save_cmd() {
    case "$1" in
        nerdctl) echo "nerdctl -n k8s.io save" ;;
        docker)  echo "docker save" ;;
        podman)  echo "podman save" ;;
        *)       err "未知运行时: $1" ;;
    esac
}

ensure_kubespray() {
    if [ -d "${KUBESPRAY_DIR}/.git" ] || [ -f "${KUBESPRAY_DIR}/cluster.yml" ]; then
        log "✅ Kubespray 源码已就绪: ${KUBESPRAY_DIR}"
    else
        highlight "正在克隆 Kubespray ${KUBESPRAY_VERSION}..."
        git clone --depth 1 --branch "${KUBESPRAY_VERSION}" "${KUBESPRAY_REPO}" "${KUBESPRAY_DIR}" || err "Git clone 失败，请检查网络或版本号"
        log "✅ Kubespray 源码克隆完成"
    fi
}

ensure_venv() {
    cd "${KUBESPRAY_DIR}"
    if [ ! -d ".venv" ]; then
        highlight "创建 Python 虚拟环境并安装依赖..."
        python3 -m venv .venv
        source .venv/bin/activate
        pip install -r requirements.txt -q
        log "✅ 虚拟环境就绪"
    else
        source .venv/bin/activate
        log "✅ 虚拟环境已激活"
    fi
}

ensure_cluster_dirs() {
    mkdir -p "${LOCAL_REPO_DIR}/images"
    mkdir -p "${INVENTORY_DIR}/group_vars/all"
    mkdir -p "${INVENTORY_DIR}/group_vars/k8s_cluster"
    log "✅ 集群目录已就绪: ${CLUSTER_NAME}"
}

cmd_init() {
    highlight "初始化集群 [${CLUSTER_NAME}] 部署环境..."
    ensure_kubespray
    ensure_venv
    ensure_cluster_dirs
    if [ ! -f "${INVENTORY_DIR}/hosts.yml" ]; then
        if [ -d "${KUBESPRAY_DIR}/inventory/sample" ]; then
            cp -rn "${KUBESPRAY_DIR}/inventory/sample/"* "${INVENTORY_DIR}/" 2>/dev/null || true
            log "✅ 已从 sample 生成 Inventory 模板"
        fi
        # 覆盖生成 hosts.yml 模板（含 scale 注释说明）
        cat > "${INVENTORY_DIR}/hosts.yml" << 'HOSTS_EOF'
# ============================================================
# 集群节点清单 — install / scale 共用
# ============================================================
# • install: 按组定义所有节点，全量部署
# • scale:   在已有组中追加新节点，然后执行 scale --limit <group>
#
# ── 使用说明 ──
# 1. 初始部署: 编辑下方节点，执行 install
# 2. 扩容 worker: 在 [kube_node] 下追加新节点，执行 scale --limit kube_node
# 3. 扩容 master: 在 [kube_control_plane] 下追加新节点，执行 scale --limit kube_control_plane
# ============================================================

[kube_control_plane]
# 初始 master 节点
node1 ansible_host=10.0.0.1 ansible_user=ubuntu
# 扩容 master 时取消下行注释并填入新节点
# node2 ansible_host=10.0.0.2 ansible_user=ubuntu

[etcd:children]
kube_control_plane

[kube_node]
# 初始 worker 节点
node1 ansible_host=10.0.0.1 ansible_user=ubuntu
# 扩容 worker 时取消下行注释并填入新节点
# node3 ansible_host=10.0.0.10 ansible_user=ubuntu
# node4 ansible_host=10.0.0.11 ansible_user=ubuntu

[k8s_cluster:children]
kube_control_plane
kube_node
HOSTS_EOF
        log "✅ 已生成 hosts.yml 模板"
    else
        log "✅ 安装 Inventory 已存在 (hosts.yml)"
    fi

    # 生成 scale 场景示例文件（仅供参考，实际 scale 直接编辑 hosts.yml）
    mkdir -p "${INVENTORY_DIR}/_examples"
    cat > "${INVENTORY_DIR}/_examples/hosts-scale-add-worker.yml" << 'SCALE_WORKER_EOF'
# ============================================================
# Scale 示例: 向已有集群加入新 worker 节点
# ============================================================
# 使用方式:
#   1. 将此文件中新增节点的部分合并到 ../hosts.yml 对应组下
#   2. 执行: ./cubestack-offline.sh scale mycluster --limit kube_node
# ============================================================
#
# 假设原 hosts.yml 已有:
#   [kube_control_plane]
#   master1 ansible_host=10.0.0.1 ansible_user=ubuntu
#
#   [kube_node]
#   worker1 ansible_host=10.0.0.10 ansible_user=ubuntu

[kube_node]
# --- 已有节点（保持不变）---
worker1 ansible_host=10.0.0.10 ansible_user=ubuntu
# --- 新增节点 ---
worker2 ansible_host=10.0.0.11 ansible_user=ubuntu
worker3 ansible_host=10.0.0.12 ansible_user=ubuntu

[k8s_cluster:children]
kube_control_plane
kube_node
SCALE_WORKER_EOF

    cat > "${INVENTORY_DIR}/_examples/hosts-scale-add-master.yml" << 'SCALE_MASTER_EOF'
# ============================================================
# Scale 示例: 向已有集群加入新 master 节点
# ============================================================
# 使用方式:
#   1. 将此文件中新增节点的部分合并到 ../hosts.yml 对应组下
#   2. 执行: ./cubestack-offline.sh scale mycluster --limit kube_control_plane
# ============================================================
#
# 假设原 hosts.yml 已有:
#   [kube_control_plane]
#   master1 ansible_host=10.0.0.1 ansible_user=ubuntu
#
#   [kube_node]
#   worker1 ansible_host=10.0.0.10 ansible_user=ubuntu

[kube_control_plane]
# --- 已有节点（保持不变）---
master1 ansible_host=10.0.0.1 ansible_user=ubuntu
# --- 新增节点 ---
master2 ansible_host=10.0.0.2 ansible_user=ubuntu
master3 ansible_host=10.0.0.3 ansible_user=ubuntu

[etcd:children]
kube_control_plane

[k8s_cluster:children]
kube_control_plane
kube_node
SCALE_MASTER_EOF
    log "✅ 已生成 Scale 示例文件: ${INVENTORY_DIR}/_examples/"
    if [ ! -f "${INVENTORY_DIR}/download-hosts.yml" ]; then
        cat > "${INVENTORY_DIR}/download-hosts.yml" << 'DOWNLOAD_EOF'
# Download-only inventory — localhost with root
# Used by generate_list.sh, no SSH to nodes required.
[kube_control_plane]
node1 ansible_host=localhost ansible_user=root

[etcd:children]
kube_control_plane

[kube_node]
node1 ansible_host=localhost ansible_user=root

[k8s_cluster:children]
kube_control_plane
kube_node
DOWNLOAD_EOF
        log "✅ 已生成 download-hosts.yml（本地 root，用于下载离线资源）"
    fi
    log "🎉 集群 [${CLUSTER_NAME}] 初始化完成! 下一步: 编辑 hosts.yml → $0 download ${CLUSTER_NAME}"
}

build_extra_vars() {
    EXTRA_VARS_STR=""
    for vars_file in \
        "${INVENTORY_DIR}/group_vars/all/offline.yml" \
        "${INVENTORY_DIR}/group_vars/all/all.yml" \
        "${INVENTORY_DIR}/group_vars/k8s_cluster/k8s-cluster.yml" \
        "${INVENTORY_DIR}/group_vars/k8s_cluster/addons.yml"; do
        if [ -f "$vars_file" ]; then
            # 跳过全注释/空文件/YAML文档分隔符文件，避免 ansible -e @ 解析失败
            # 使用 || true 避免 pipefail + local 触发 errexit
            local content
            content=$(grep -vE '^\s*(#|---|\.\.\.)' "$vars_file" | grep -v '^\s*$' | head -1) || true
            if [ -z "$content" ]; then
                warn "    跳过纯注释文件: $vars_file"
                continue
            fi
            EXTRA_VARS_STR="${EXTRA_VARS_STR} -e @${vars_file}"
            log "    加载变量文件: $vars_file"
        fi
    done
}

lookup_dest_from_map() {
    local search_url="$1"
    local map_file="$2"
    if [ -f "$map_file" ]; then
        grep -F "$search_url " "$map_file" 2>/dev/null | head -1 | awk '{print $2}'
    fi
}

cmd_download() {
    highlight "下载集群 [${CLUSTER_NAME}] 离线资源..."
    ensure_kubespray
    ensure_venv
    ensure_cluster_dirs

    DOWNLOAD_HOSTS_FILE="${DOWNLOAD_HOSTS:-${INVENTORY_DIR}/download-hosts.yml}"
    [ -f "${DOWNLOAD_HOSTS_FILE}" ] || err "Download hosts 不存在: ${DOWNLOAD_HOSTS_FILE}"

    runtime=$(detect_runtime)
    pull_cmd=$(get_pull_cmd "$runtime")
    save_cmd=$(get_save_cmd "$runtime")
    log "容器运行时: ${runtime}"

    build_extra_vars

    log "[1/4] 生成离线资源清单..."
    cd "${OFFLINE_CONTRIB}"
    bash generate_list.sh -i "${DOWNLOAD_HOSTS_FILE}" ${EXTRA_VARS_STR}
    [ -s "temp/images.list" ] || err "images.list 为空"
    [ -s "temp/files.list" ] || err "files.list 为空"

    log "    生成文件命名映射..."
    cd "${KUBESPRAY_DIR}"
    cat > /tmp/cubestack_map_dest.yml << 'PLAYBOOK_EOF'
- hosts: localhost
  become: false
  roles:
    - role: kubespray_defaults
      when: false
    - role: download
      when: false
  tasks:
    - name: Generate URL-to-dest mapping
      copy:
        content: |
          {% for key, dl in downloads.items() %}
          {% if not (dl.container | default(false)) and dl.url is defined and dl.dest is defined and dl.dest is not none %}
          {{ dl.url }} {{ dl.dest | basename }}
          {% endif %}
          {% endfor %}
        dest: "{{ mapping_file }}"
PLAYBOOK_EOF
    ansible-playbook --connection=local -i localhost, /tmp/cubestack_map_dest.yml \
        -e "mapping_file=${OFFLINE_CONTRIB}/temp/url_dest.map" \
        ${EXTRA_VARS_STR} || warn "URL→dest 映射生成有警告，继续..."
    rm -f /tmp/cubestack_map_dest.yml
    cd "${OFFLINE_CONTRIB}"
    [ -s "temp/url_dest.map" ] || warn "URL→dest 映射为空，将使用 URL basename"

    total_images=$(wc -l < "temp/images.list" | tr -d ' ')
    total_files=$(wc -l < "temp/files.list" | tr -d ' ')
    log "    镜像清单: ${total_images} 个, 文件清单: ${total_files} 个"

    log "[2/4] 下载容器镜像..."
    mkdir -p "${LOCAL_REPO_DIR}/images"

    count=0
    while IFS= read -r image; do
        [ -z "$image" ] && continue
        # 与 kubespray set_container_facts.yml 保持一致的文件名规则:
        # image_reponame | regex_replace('/|\0|:', '_') + '.tar'
        filename=$(echo "$image" | sed 's#/#_#g; s#:#_#g').tar
        dest="${LOCAL_REPO_DIR}/images/${filename}"
        count=$((count + 1))

        if [ -f "$dest" ]; then
            log "  [${count}/${total_images}] 已缓存: $image"
            continue
        fi

        log "  [${count}/${total_images}] 拉取: $image"
        retry=0
        while [ $retry -lt 5 ]; do
            if sudo $pull_cmd "$image" 2>&1; then
                break
            fi
            retry=$((retry + 1))
            warn "    重试 ${retry}/5: $image"
            if [ $retry -ge 5 ]; then
                err "镜像拉取失败: $image"
            fi
        done

        sudo $save_cmd -o "$dest" "$image"
        log "    保存: $filename"
    done < "temp/images.list"

    log "    镜像下载完成: $(ls "${LOCAL_REPO_DIR}/images/" | wc -l) 个"

    log "[3/4] 下载二进制文件..."
    url_dest_map="${OFFLINE_CONTRIB}/temp/url_dest.map"

    count=0
    while IFS= read -r url; do
        [ -z "$url" ] && continue
        count=$((count + 1))

        mapped_dest=$(lookup_dest_from_map "$url" "$url_dest_map")
        if [ -n "$mapped_dest" ]; then
            filename="$mapped_dest"
        else
            filename=$(basename "$url" | sed 's/[?#].*//')
            warn "    未找到映射: $filename，使用 URL basename"
        fi
        dest="${LOCAL_REPO_DIR}/${filename}"

        if [ -f "$dest" ]; then
            log "  [${count}/${total_files}] 已缓存: $filename"
            continue
        fi

        log "  [${count}/${total_files}] 下载: $filename"
        wget -q --show-progress -O "$dest" "$url" || err "下载失败: $url"
    done < "temp/files.list"

    log "    文件下载完成: $(find "${LOCAL_REPO_DIR}" -maxdepth 1 -type f | wc -l) 个"

    log "[4/4] 验证资源..."
    img_cnt=$(ls "${LOCAL_REPO_DIR}/images/" 2>/dev/null | wc -l)
    file_cnt=$(find "${LOCAL_REPO_DIR}" -maxdepth 1 -type f 2>/dev/null | wc -l)
    log "    镜像: ${img_cnt} 个, 文件: ${file_cnt} 个"
    log "🎉 集群 [${CLUSTER_NAME}] 离线资源下载完成!"
    log "   仓库: ${LOCAL_REPO_DIR}"
    log "   结构: images/ + 二进制文件（kubespray download_cache_dir 格式）"
}

# 预加载离线镜像到目标节点(all / kube_control_plane / kube_node)
# 必须先于 playbook 加载镜像: kubelet 启动 pod 时会尝试拉镜像,
# 离线环境下必须先 load 到 containerd, 否则 ImagePullBackOff / 启动慢
# 用 rsync 逐台同步 + 逐个镜像验证加载, 失败会重试并报告, 避免静默丢失
preload_images() {
    local target="${1:-all}"
    log "预加载离线镜像到 ${target} 节点..."

    # 解析节点清单(含连接信息): 输出 "node|host|user|key" 每行
    local nodes_str
    nodes_str=$(ansible-inventory -i "${INVENTORY_DIR}/hosts.yml" --list 2>/dev/null | python3 -c '
import sys, json
inv = json.load(sys.stdin)
meta = inv.get("_meta", {}).get("hostvars", {})
target = "'"${target}"'"
groups = ["kube_control_plane", "kube_node"] if target == "all" else [target]
seen = set()
for g in groups:
    for h in inv.get(g, {}).get("hosts", []):
        if h in seen or h not in meta:
            continue
        seen.add(h)
        hv = meta[h]
        print("%s|%s|%s|%s" % (
            h,
            hv.get("ansible_host", h),
            hv.get("ansible_user", "ubuntu"),
            hv.get("ansible_ssh_private_key_file", "~/.ssh/cubestack_k8s"),
        ))
')

    local node host user key total=0 ok_sum=0 fail_nodes=0
    while IFS='|' read -r node host user key; do
        [ -z "${node}" ] && continue
        total=$((total + 1))
        log "  → [${node}](${host}) 同步并加载镜像 ..."

        # 1. rsync 同步整个 images 目录(比 ansible copy 可靠)
        rsync -az --timeout=300 -e "ssh -i ${key} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
            "${LOCAL_REPO_DIR}/images/" "${user}@${host}:/tmp/cubestack-images/" 2>/dev/null || {
            warn "  ${node}: rsync 同步失败,跳过"
            fail_nodes=$((fail_nodes + 1))
            continue
        }

        # 2. 逐个加载镜像并验证(失败重试一次)
        local loaded
        loaded=$(ssh -i "${key}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "${user}@${host}" "sudo bash -c '
                n=0
                for f in /tmp/cubestack-images/*.tar; do
                    [ -f \"\$f\" ] || continue
                    if ! ctr -n k8s.io image import \"\$f\" >/dev/null 2>&1; then
                        sleep 2
                        ctr -n k8s.io image import \"\$f\" >/dev/null 2>&1
                    fi
                    n=\$((n + 1))
                done
                rm -rf /tmp/cubestack-images
                echo \$n
            '" 2>/dev/null || echo 0)
        ok_sum=$((ok_sum + loaded))
        log "  → ${node}: 处理 ${loaded} 个镜像"
    done <<< "${nodes_str}"

    if [ "${total}" -eq 0 ]; then
        warn "预加载: 未解析到节点(inventory 可能为空)"
    else
        log "✅ 离线镜像预加载完成: ${total} 台节点, 失败 ${fail_nodes} 台"
    fi
}

# 修复 artifacts 目录权限问题(kubectl_localhost/kubeconfig_localhost 用)
# 根因: kubespray 的 client role 用 `delegate_to: localhost + connection: local + become: false`
#       创建 artifacts 目录(mode 0750), 但在 play 全局 --become 下实际以 root 创建,
#       导致后续 fetch kubectl(become: false, 本地用户) 写目录时 Permission denied。
# 根治: patch kubespray 的 Create kube artifacts dir 任务 mode → 0777, 无论谁创建都可写。
fix_artifacts_perms() {
    # 1. patch kubespray client role: mode 0750 → 0777 (幂等, 只 patch 一次)
    local client_role="${KUBESPRAY_DIR}/roles/kubernetes/client/tasks/main.yml"
    if [ -f "${client_role}" ]; then
        if grep -q 'mode: "0777"' "${client_role}"; then
            log "✅ kubespray artifacts 权限已 patch(0777)"
        elif grep -q 'mode: "0750"' "${client_role}"; then
            sed -i 's/mode: "0750"/mode: "0777"/' "${client_role}"
            log "✅ 已 patch kubespray client role: artifacts 目录 mode 0750 → 0777"
        fi
    fi

    # 2. 清理旧 artifacts(避免 root 残留)
    local artifacts_dir="${INVENTORY_DIR}/artifacts"
    rm -rf "${artifacts_dir}" 2>/dev/null || sudo rm -rf "${artifacts_dir}" 2>/dev/null || true
    mkdir -p "${artifacts_dir}" 2>/dev/null || sudo mkdir -p "${artifacts_dir}" 2>/dev/null || true
    chmod 777 "${artifacts_dir}" 2>/dev/null || sudo chmod 777 "${artifacts_dir}" 2>/dev/null || true
    # 确保 inventory 目录可读写
    chmod -R u+rwX "${INVENTORY_DIR}" 2>/dev/null || true
}

cmd_install() {
    highlight "安装集群 [${CLUSTER_NAME}]..."
    ensure_kubespray
    ensure_venv
    cmd_check
    log "注入离线安装变量..."
    OFFLINE_VARS="${INVENTORY_DIR}/group_vars/all/offline.yml"
    {
        echo "---"
        echo "# 离线安装变量（由 cubestack-offline.sh 自动生成）"
        echo ""
        echo "## 下载控制"
        echo "download_run_once: true"
        echo "download_localhost: true"
        echo "download_force_cache: true"
        echo "download_always_pull: false"
        echo ""
        echo "## 缓存目录"
        echo "download_cache_dir: \"${LOCAL_REPO_DIR}\""
        echo "local_release_dir: \"${LOCAL_REPO_DIR}\""
        echo ""
        echo "## 容器运行时"
        echo "container_manager: \"${CONTAINER_RUNTIME}\""
        echo "container_manager_on_localhost: \"${CONTAINER_RUNTIME}\""
        echo ""
        echo "## 连接"
        echo "ansible_user: \"${REMOTE_USER}\""
        echo "ansible_become: true"
        echo "ansible_become_method: sudo"
        echo ""
        echo "## 离线环境 — 跳过不必要的检查"
        echo "ping_access_ip: false"
        echo ""
        echo "## 离线环境 API server 冷启动慢, 加大 kubeadm init 等待超时(默认300s)"
        echo "kubeadm_init_timeout: 900s"
    } > "${OFFLINE_VARS}"

    # 预加载离线镜像到所有节点(含 master), 避免 kubeadm wait-control-plane 超时
    preload_images "all"

    # 修复 artifacts 目录权限(kubectl_localhost/kubeconfig_localhost 用)
    fix_artifacts_perms

    log "执行 Kubespray 离线安装..."
    if [ -n "$LIMIT_GROUP" ]; then
        log "  ▶ 限定目标组: ${LIMIT_GROUP}"
    fi
    cd "${KUBESPRAY_DIR}"

    # 当使用 --limit 时,预先收集全节点 facts (排除的节点也需要 facts 缓存)
    if [ -n "$LIMIT_GROUP" ]; then
        log "预收集全节点 facts (为 --limit 做准备)..."
        ansible-playbook playbooks/facts.yml \
            -i "${INVENTORY_DIR}/hosts.yml" \
            --become --become-user=root \
            -e @${OFFLINE_VARS} \
            --skip-tags system-packages,kube-proxy \
            -v 2>&1 | tee "/tmp/${CLUSTER_NAME}-facts.log" || true
        log "✅ Facts 收集完成"
    fi

    ansible-playbook cluster.yml \
        -i "${INVENTORY_DIR}/hosts.yml" \
        --become --become-user=root \
        ${LIMIT_FLAG} \
        -e @${OFFLINE_VARS} \
        --skip-tags system-packages,kube-proxy \
        -vv 2>&1 | tee "/tmp/${CLUSTER_NAME}-install.log"
    log "🎉 集群 [${CLUSTER_NAME}] 安装完成! 日志: /tmp/${CLUSTER_NAME}-install.log"
}

cmd_scale() {
    highlight "扩容集群 [${CLUSTER_NAME}] — 添加新节点..."
    ensure_kubespray
    ensure_venv
    cmd_check

    # 确保离线变量文件存在
    OFFLINE_VARS="${INVENTORY_DIR}/group_vars/all/offline.yml"
    if [ ! -f "${OFFLINE_VARS}" ]; then
        warn "离线变量文件不存在，正在生成..."
        {
            echo "---"
            echo "# 离线安装变量（由 cubestack-offline.sh 自动生成）"
            echo ""
            echo "## 下载控制"
            echo "download_run_once: true"
            echo "download_localhost: true"
            echo "download_force_cache: true"
            echo "download_always_pull: false"
            echo ""
            echo "## 缓存目录"
            echo "download_cache_dir: \"${LOCAL_REPO_DIR}\""
            echo "local_release_dir: \"${LOCAL_REPO_DIR}\""
            echo ""
            echo "## 容器运行时"
            echo "container_manager: \"${CONTAINER_RUNTIME}\""
            echo "container_manager_on_localhost: \"${CONTAINER_RUNTIME}\""
            echo ""
            echo "## 连接"
            echo "ansible_user: \"${REMOTE_USER}\""
            echo "ansible_become: true"
            echo "ansible_become_method: sudo"
            echo ""
            echo "## 离线环境 — 跳过不必要的检查"
            echo "ping_access_ip: false"
            echo ""
            echo "## 离线环境 API server 冷启动慢, 加大 kubeadm init 等待超时(默认300s)"
            echo "kubeadm_init_timeout: 900s"
        } > "${OFFLINE_VARS}"
    fi

    if [ -n "$LIMIT_GROUP" ]; then
        log "  ▶ 限定目标组: ${LIMIT_GROUP}"

        # Kubespray 要求 --limit 排除的节点也必须有 facts 缓存
        # 先不带 --limit 跑一次 facts.yml 收集全量 facts
        log "预收集全节点 facts (为 --limit 做准备)..."
        cd "${KUBESPRAY_DIR}"
        ansible-playbook playbooks/facts.yml \
            -i "${INVENTORY_DIR}/hosts.yml" \
            --become --become-user=root \
            -e @${OFFLINE_VARS} \
            --skip-tags system-packages,kube-proxy \
            -v 2>&1 | tee "/tmp/${CLUSTER_NAME}-facts.log"
        log "✅ Facts 收集完成"
    fi

    # ── 预加载离线镜像到目标节点 ──
    # 必须先于 scale.yml 加载镜像: kubelet 启动 kube-proxy 时会尝试拉镜像,
    # 离线环境下必须先 load 到 containerd, 否则 ImagePullBackOff
    preload_images "kube_node"

    log "执行 Kubespray 扩容 (scale.yml)..."
    cd "${KUBESPRAY_DIR}"
    ansible-playbook scale.yml \
        -i "${INVENTORY_DIR}/hosts.yml" \
        --become --become-user=root \
        ${LIMIT_FLAG} \
        -e @${OFFLINE_VARS} \
        --skip-tags system-packages,kube-proxy \
        -vv 2>&1 | tee "/tmp/${CLUSTER_NAME}-scale.log" || {
            err "Kubespray 扩容失败,日志: /tmp/${CLUSTER_NAME}-scale.log"
            return 1
        }

    # ── 扩容后置处理 ──
    log "扩容后置处理..."

    # 1. 修复 Calico ClusterRole RBAC：Calico v3.29+ 需要 ipamconfigs 等 CRD 权限
    log "  [1/2] 修复 Calico ClusterRole RBAC..."
    MISSING_CALICO_RESOURCES="ipamconfigs kubecontrollersconfigurations"
    for res in $MISSING_CALICO_RESOURCES; do
        ansible kube_control_plane[0] -i "${INVENTORY_DIR}/hosts.yml" \
            --become --become-user=root \
            -m shell \
            -a "
              if kubectl get clusterrole calico-node -o json 2>/dev/null | \
                 jq -e '.rules[] | select(.apiGroups | index(\"crd.projectcalico.org\")) | .resources' 2>/dev/null | \
                 grep -q '\"${res}\"'; then
                echo '  calico-node ClusterRole 已包含 ${res}，跳过'
              else
                kubectl patch clusterrole calico-node --type='json' \
                  -p='[{\"op\": \"add\", \"path\": \"/rules/3/resources/-\", \"value\": \"${res}\"}]' 2>/dev/null && \
                echo '  ✅ 已添加 ${res} 到 calico-node ClusterRole'
              fi
            " \
            >/dev/null 2>&1 || true
    done
    log "  ✅ Calico RBAC 修复完成"

    # 2. 若 Calico pods CrashLoopBackOff，删除让其用新权限重建
    log "  [2/2] 重建异常的 Calico pods..."
    ansible kube_control_plane[0] -i "${INVENTORY_DIR}/hosts.yml" \
        --become --become-user=root \
        -m shell \
        -a "
          kubectl -n kube-system get pods -l k8s-app=calico-node 2>/dev/null | \
          awk '/CrashLoopBackOff|Error/{print \$1}' | \
          xargs -r kubectl -n kube-system delete pod 2>/dev/null || true
        " \
        >/dev/null 2>&1 || true

    log "🎉 集群 [${CLUSTER_NAME}] 扩容完成! 日志: /tmp/${CLUSTER_NAME}-scale.log"
}

cmd_check() {
    highlight "预检集群 [${CLUSTER_NAME}]..."
    if [ ! -d "${LOCAL_REPO_DIR}/images" ] || [ -z "$(ls -A "${LOCAL_REPO_DIR}/images" 2>/dev/null)" ]; then
        err "镜像目录为空: ${LOCAL_REPO_DIR}/images"
    fi
    if [ -z "$(find "${LOCAL_REPO_DIR}" -maxdepth 1 -type f 2>/dev/null | head -1)" ]; then
        err "未找到离线二进制文件: ${LOCAL_REPO_DIR}"
    fi
    log "✅ 离线资源完整"

    cd "${KUBESPRAY_DIR}"
    source .venv/bin/activate 2>/dev/null || true

    # ── 终极修复：将 Python 逻辑写入临时文件，$() 内只做简单调用 ──
    local py_script="/tmp/.cubestack_count_hosts.py"
    cat > "$py_script" << 'PYEOF'
import sys, json
try:
    d = json.load(sys.stdin)
    print(len(d.get("_meta", {}).get("hostvars", {})))
except Exception:
    print(0)
PYEOF

    local inv_json
    inv_json=$(ansible-inventory -i "${INVENTORY_DIR}/hosts.yml" --list 2>/dev/null || echo "{}")

    HOST_COUNT=$(echo "$inv_json" | python3 "$py_script")
    rm -f "$py_script"

    [ "${HOST_COUNT}" -gt 0 ] || err "Inventory 解析失败: ${INVENTORY_DIR}/hosts.yml"
    log "✅ Inventory 有效，共 ${HOST_COUNT} 台主机"

    ansible all -i "${INVENTORY_DIR}/hosts.yml" -m ping -u "${REMOTE_USER}" --become >/dev/null 2>&1 \
        || warn "部分主机 SSH/sudo 异常"
    log "✅ 预检通过"
}

# ──────────────────────────────────────────────────────────
# 主入口 — 参数解析
# ──────────────────────────────────────────────────────────
LIMIT_GROUP=""
COMMAND=""
CLUSTER_ARG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --limit)
            [ -z "${2:-}" ] && err "--limit 需要指定一个组名 (kube_control_plane, kube_node, etcd)"
            LIMIT_GROUP="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            if [ -z "$COMMAND" ]; then
                COMMAND="$1"
            elif [ -z "$CLUSTER_ARG" ]; then
                CLUSTER_ARG="$1"
            else
                err "未知参数: $1"
            fi
            shift
            ;;
    esac
done

[ -z "$COMMAND" ] && usage

CLUSTER_NAME=$(resolve_cluster_name "${COMMAND}" "${CLUSTER_ARG}")
OFFLINE_CONTRIB="${KUBESPRAY_DIR}/contrib/offline"
INVENTORY_DIR="${INVENTORY_BASE}/${CLUSTER_NAME}"
LOCAL_REPO_DIR="${LOCAL_REPO_BASE}/${CLUSTER_NAME}"

# ── 环境变量覆盖(让调用方如 deploy-cluster.sh 可传入项目路径) ──
KUBESPRAY_DIR="${CUBESTACK_KUBESPRAY_DIR:-${KUBESPRAY_DIR}}"
INVENTORY_DIR="${CUBESTACK_INVENTORY_DIR:-${INVENTORY_DIR}}"
LOCAL_REPO_DIR="${CUBESTACK_LOCAL_REPO_DIR:-${LOCAL_REPO_DIR}}"
OFFLINE_CONTRIB="${KUBESPRAY_DIR}/contrib/offline"

# 构建 ansible-playbook 通用 limit 参数
LIMIT_FLAG=""
[ -n "$LIMIT_GROUP" ] && LIMIT_FLAG="--limit ${LIMIT_GROUP}"

case "${COMMAND}" in
    init)     cmd_init ;;
    download) cmd_download ;;
    install)  cmd_install ;;
    scale)    cmd_scale ;;
    check)    cmd_check ;;
    preload)  preload_images "${LIMIT_GROUP:-all}" ;;   # 单独预加载镜像(补镜像/修复)
    *)        usage ;;
esac

