#!/bin/bash
set -euo pipefail

# 自动检测: 脚本所在目录 = deployments/kubespray/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 离线资源根目录: 优先级:
#   1. CUBESTACK_BASE_DIR 环境变量(由 deploy-cluster.sh 10_k8s_deploy 模块通过 env 传入)
#   2. 脚本所在目录(本项目结构: SCRIPT_DIR = deployments/kubespray/)
#   3. 回退 /opt/cubestack-installer(standalone 模式)
BASE_DIR="${CUBESTACK_BASE_DIR:-${SCRIPT_DIR}}"
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

# 日志文件(全局, 由 start_log_tee 设置): 所有输出函数同时写入该文件
LOG_FILE="${LOG_FILE:-}"
_log_file() { [ -n "${LOG_FILE}" ] && echo -e "$*" >> "${LOG_FILE}" 2>/dev/null || true; }
log()       { local m="[INFO] $*";  echo -e "${GREEN}${m}${NC}"; _log_file "${m}"; }
warn()      { local m="[WARN] $*";  echo -e "${YELLOW}${m}${NC}"; _log_file "${m}"; }
err()       { local m="[ERROR] $*"; echo -e "${RED}${m}${NC}" >&2; _log_file "${m}"; exit 1; }
highlight() { local m=">>> $*";     echo -e "${CYAN}${m}${NC}"; _log_file "${m}"; }

# 启动日志: 设置 LOG_FILE, 后续 log/warn/err/highlight 及 ansible 日志都写入该文件
# 同时输出到终端 + 写文件, 不使用 exec > >(tee)(会导致 Python subprocess 调用死锁)
start_log_tee() {
    local log="$1"
    # 若文件存在但当前用户不可写: 优先删除(自己创建的), 否则放开权限
    if [ -e "${log}" ] && [ ! -w "${log}" ]; then
        rm -f "${log}" 2>/dev/null || chmod 666 "${log}" 2>/dev/null || true
    fi
    if touch "${log}" 2>/dev/null; then
        LOG_FILE="${log}"
    else
        warn "无法写入日志 ${log}, 本次仅输出到终端, 不记录日志文件"
        LOG_FILE=""
    fi
    echo ">>> 日志: 同时显示终端 + 写入 ${LOG_FILE}"
    echo ">>> 可实时查看: tail -f ${LOG_FILE}"
}

# 运行 ansible-playbook, 日志输出到文件 + 可选终端
# 环境变量 ANSIBLE_LOG_TERMINAL(默认 1): 1=同时终端+文件, 0=仅文件
# 用法: run_ansible_playbook <日志文件> <ansible-playbook 参数...>
run_ansible_playbook() {
    local log_file="$1"; shift
    if [ "${ANSIBLE_LOG_TERMINAL:-1}" = "1" ]; then
        ansible-playbook "$@" 2>&1 | tee -a "${log_file}"
    else
        ansible-playbook "$@" 2>&1 >> "${log_file}"
    fi
    return "${PIPESTATUS[0]}"
}

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
# 仅同步"部署 kubespray 最小镜像集合"(PRELOAD_IMAGE_PATTERNS 配置, 空=全量),
# 避免全量 rsync 大量无关镜像(cilium/flannel/ingress 等)拖慢部署
# 匹配规则: 条目含 ".tar" 为精确文件名匹配, 否则为文件名包含匹配
# 用 rsync 逐台同步(仅匹配镜像, --delete-excluded 清理目标残留) + 逐个镜像验证加载
# 解析预加载镜像文件清单(按 PRELOAD_IMAGE_PATTERNS 规则过滤 LOCAL_REPO_DIR/images/*.tar)
# 结果: 全局数组 PRELOAD_IMAGE_FILES; 同时写入 inventory/preload-images.lst,
# 供 cluster.yml/scale.yml 内置的镜像预加载 play 读取(空文件=无镜像可同步)
resolve_preload_image_files() {
    local patterns=(${PRELOAD_IMAGE_PATTERNS:-})
    PRELOAD_IMAGE_FILES=()
    local f p base matched
    if [ "${#patterns[@]}" -eq 0 ]; then
        # 全量同步(向后兼容): images/ 下所有 *.tar
        for f in "${LOCAL_REPO_DIR}"/images/*.tar; do
            [ -f "${f}" ] && PRELOAD_IMAGE_FILES+=("$(basename "${f}")")
        done
        log "  同步集合: 全量 ${#PRELOAD_IMAGE_FILES[@]} 个镜像(未配置 PRELOAD_IMAGE_PATTERNS)"
    else
        for f in "${LOCAL_REPO_DIR}"/images/*.tar; do
            [ -f "${f}" ] || continue
            base="$(basename "${f}")"
            matched=0
            for p in "${patterns[@]}"; do
                if [[ "${p}" == *".tar"* ]]; then
                    [ "${p}" = "${base}" ] && { matched=1; break; }
                else
                    [[ "${base}" == *"${p}"* ]] && { matched=1; break; }
                fi
            done
            [ "${matched}" = "1" ] && PRELOAD_IMAGE_FILES+=("${base}")
        done
        log "  同步集合: ${#PRELOAD_IMAGE_FILES[@]} 个镜像(最小集合: ${patterns[*]})"
    fi

    # 写入 inventory 目录: 每行一个 tar 文件名; 空文件表示无镜像可同步
    # (playbook 仅在清单文件不存在时才回退为全量同步)
    {
        if [ "${#PRELOAD_IMAGE_FILES[@]}" -gt 0 ]; then
            printf '%s\n' "${PRELOAD_IMAGE_FILES[@]}"
        fi
    } > "${INVENTORY_DIR}/preload-images.lst" 2>/dev/null || \
        warn "无法写入镜像清单 ${INVENTORY_DIR}/preload-images.lst(playbook 预加载将回退为全量同步)"
}

preload_images() {
    local target="${1:-all}"
    log "预加载离线镜像到 ${target} 节点..."

    # ── 1. 解析预加载镜像文件列表(过滤 images/ 目录) ──
    resolve_preload_image_files
    local image_files=("${PRELOAD_IMAGE_FILES[@]}")

    if [ "${#image_files[@]}" -eq 0 ]; then
        warn "预加载: 未匹配到任何镜像(检查 PRELOAD_IMAGE_PATTERNS 或 ${PRELOAD_CONF})"
        return 0
    fi

    # 构建 rsync 过滤参数: 仅同步匹配镜像 + --delete-excluded 清理目标残留(断点续跑场景)
    local rsync_filter=()
    for f in "${image_files[@]}"; do
        rsync_filter+=(--include="${f}")
    done
    rsync_filter+=(--exclude='*')

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

    local total=0 ok_sum=0 fail_nodes=0
    # 用 for 循环遍历(while read + 内部 ssh/rsync 会吞 stdin 导致只处理首行)
    local oldifs="${IFS}"
    IFS=$'\n'
    for line in ${nodes_str}; do
        IFS='|' read -r node host user key <<< "${line}"
        [ -z "${node}" ] && continue
        total=$((total + 1))
        log "  → [${node}](${host}) 同步并加载 ${#image_files[@]} 个镜像 ..."

        # 0. 确保节点侧 repository/images 目录存在(幂等)。
        #    根因: kubespray download role 的 "Upload image to node" 用
        #    ansible.posix.synchronize(rsync --rsync-path='sudo -u root rsync')
        #    把镜像 push 到节点 ${LOCAL_REPO_DIR}/images/, 但该目录不会被 playbook 自动创建;
        #    全新节点(scale 新 worker / 裸金属 worker)上不存在 → rsync 报
        #    "change_dir failed: No such file or directory" → 镜像没有全部同步成功。
        ssh -i "${key}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "${user}@${host}" "sudo mkdir -p '${LOCAL_REPO_DIR}/images'" >/dev/null 2>&1 || {
            warn "  ${node}: 创建节点侧仓库目录失败(${LOCAL_REPO_DIR}/images),跳过"
            fail_nodes=$((fail_nodes + 1))
            continue
        }

        # 1. rsync 仅同步匹配镜像(比 ansible copy 可靠)
        rsync -az --delete --delete-excluded --timeout=300 "${rsync_filter[@]}" \
            -e "ssh -i ${key} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
            "${LOCAL_REPO_DIR}/images/" "${user}@${host}:/tmp/cubestack-images/" 2>&1 || {
            warn "  ${node}: rsync 同步失败,跳过(见上方错误)"
            fail_nodes=$((fail_nodes + 1))
            continue
        }

        # 2. 逐个 import 所有 tar 并校验: 只统计真正导入成功的镜像,
        #    失败镜像单独告警(避免之前"按文件数计数"虚报成功导致部分镜像缺失)
        #    全新 VM 上 containerd 尚未安装(kubespray 下载角色才安装)时返回 SKIP, 优雅跳过
        local loaded
        loaded=$(ssh -i "${key}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "${user}@${host}" "sudo bash -c '
                command -v ctr >/dev/null 2>&1 || { rm -rf /tmp/cubestack-images; echo SKIP; exit 0; }
                ok=0; fail=0
                for f in /tmp/cubestack-images/*.tar; do
                    [ -f \"\$f\" ] || continue
                    if ctr -n k8s.io image import \"\$f\" >/dev/null 2>&1; then
                        ok=\$((ok + 1))
                    elif sleep 1 && ctr -n k8s.io image import \"\$f\" >/dev/null 2>&1; then
                        ok=\$((ok + 1))
                    else
                        fail=\$((fail + 1))
                        echo \"[FAIL] 导入失败: \$(basename \"\$f\")\" >&2
                        # 尝试获取失败原因(如磁盘空间不足/镜像名冲突)
                        ctr -n k8s.io image import \"\$f\" 2>&1 | head -3 >&2
                    fi
                done
                rm -rf /tmp/cubestack-images
                echo \$ok
            '" || echo 0)
        if [ "${loaded}" = "SKIP" ]; then
            warn "  ${node}: 节点上 containerd 未安装, 跳过镜像预加载(将由 kubespray 下载角色安装 containerd 并加载镜像)"
            continue
        fi
        ok_sum=$((ok_sum + loaded))
        log "  → ${node}: 成功加载 ${loaded} 个镜像"
    done
    IFS="${oldifs}"

    if [ "${total}" -eq 0 ]; then
        warn "预加载: 未解析到节点(inventory 可能为空)"
    else
        log "✅ 离线镜像预加载完成: ${total} 台节点, 失败 ${fail_nodes} 台, 共加载 ${ok_sum} 个镜像"
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

# 确保 cluster.yml/scale.yml 已挂载镜像预加载 play(幂等)
# 背景: 预加载 play 位于 kubespray/patch-playbooks/(kubespray 升级/重新 clone 会丢失),
#       本函数在文件缺失时从内置内容重新生成, 并把 import 重新插回 playbook,
#       保证镜像同步逻辑在升级后依然生效(插入标记取自各版本稳定的 play 名称)
ensure_preload_play() {
    local preload_file="${KUBESPRAY_DIR}/patch-playbooks/cubestack-preload.yml"
    if [ ! -f "${preload_file}" ]; then
        log "重新生成 ${preload_file}(kubespray 升级后恢复)..."
        mkdir -p "$(dirname "${preload_file}")" 2>/dev/null || true
        cat > "${preload_file}" << 'PRELOAD_EOF' 2>/dev/null || true
---
# ═══════════════════════════════════════════════════════════════════════════
# cubestack-installer: 离线镜像预加载 play(cluster.yml / scale.yml 共用)
#
# 在 containerd 安装完成后, 将离线镜像从部署机缓存同步到目标节点并 load 进 containerd,
# 解决新节点 kube-proxy/calico 等镜像缺失问题。不硬编码任何路径或集群名:
#   · 镜像缓存目录: download_cache_dir / local_release_dir(入口脚本写入 offline.yml)
#   · 同步文件清单: {{ inventory_dir }}/preload-images.lst(入口脚本生成, 每行一个 tar 名)
#     清单不存在 → 回退为同步缓存目录下全部 *.tar; 空文件 → 无镜像可同步(跳过)
#
# 同步机制与 kubespray download role 的镜像上传一致: synchronize(use_ssh_args, push)
# 保证完全同步并 load 成功: 每个清单文件必须存在于节点且 ctr import 成功(最多重试 3 次),
# 任一镜像缺失或导入失败 → play 失败, 不会被静默跳过
# ═══════════════════════════════════════════════════════════════════════════
- name: Preload offline images to target nodes
  hosts: "{{ preload_target | default('k8s_cluster') }}"
  gather_facts: false
  environment: "{{ proxy_disable_env }}"
  roles:
    - { role: kubespray_defaults }
  tasks:
    - name: Preload | Resolve image file list (lst file or all tars in cache)
      set_fact:
        preload_image_files: >-
          {%- set raw = lookup('file', inventory_dir + '/preload-images.lst', errors='ignore') -%}
          {%- set lst = (raw if raw is string else '').splitlines() | select() | list -%}
          {%- if raw is string -%}
          {{ lst }}
          {%- else -%}
          {{ query('fileglob', download_cache_dir + '/images/*.tar') | map('basename') | sort | list }}
          {%- endif -%}

    - name: Preload | Build rsync include filter
      set_fact:
        preload_rsync_opts: "{{ preload_image_files | map('regex_replace', '^(.*)$', '--include=\\1') | list + ['--exclude=*'] }}"
      when: preload_image_files | length > 0

    - name: Preload | Ensure node-side images directory
      file:
        path: "{{ local_release_dir }}/images"
        state: directory
        recurse: true
      when: preload_image_files | length > 0

    - name: Preload | Sync image tars from cache to node
      ansible.posix.synchronize:
        src: "{{ download_cache_dir }}/images/"
        dest: "{{ local_release_dir }}/images/"
        mode: push
        use_ssh_args: true
        rsync_opts: "{{ preload_rsync_opts }}"
      register: preload_sync
      until: preload_sync is succeeded
      retries: 2
      delay: 5
      when: preload_image_files | length > 0

    - name: Preload | Load images into containerd (逐镜像校验, 失败重试 3 次)
      shell: |
        set -euo pipefail
        files="{{ preload_image_files | join(' ') }}"
        total=$(wc -w <<< "${files}")
        ok=0
        rc=0
        i=0
        for f in ${files}; do
          i=$((i + 1))
          img="{{ local_release_dir }}/images/$f"
          if [ ! -f "$img" ]; then
            echo "  ✗ [$i/$total] $f: 节点缺少镜像文件(同步未完成或清单过期, 请重新运行入口脚本)"
            rc=1
            continue
          fi
          imported=0
          for attempt in 1 2 3; do
            if ctr -n k8s.io images import "$img" >/dev/null 2>&1; then
              imported=1
              break
            fi
            sleep $((attempt * attempt))
          done
          if [ "$imported" = "1" ]; then
            ok=$((ok + 1))
            echo "  ✓ [$i/$total] $f"
          else
            echo "  ✗ [$i/$total] $f: 3 次导入均失败"
            rc=1
          fi
        done
        echo "  预加载结果: ${ok}/${total} 个镜像导入成功"
        exit $rc
      args:
        executable: /bin/bash
      changed_when: false
      when: preload_image_files | length > 0
PRELOAD_EOF
        [ -f "${preload_file}" ] || { warn "无法生成 ${preload_file}, 跳过预加载 play 挂载"; return 0; }
    fi

    local py name
    for py in "${KUBESPRAY_DIR}/playbooks/cluster.yml" "${KUBESPRAY_DIR}/playbooks/scale.yml"; do
        [ -f "${py}" ] || continue
        name="$(basename "${py}")"
        if grep -q "cubestack-preload.yml" "${py}"; then
            log "✅ ${name} 已挂载镜像预加载 play"
            continue
        fi
        python3 - "${py}" "${name}" << 'PYEOF'
import sys
path, name = sys.argv[1], sys.argv[2]
src = open(path).read()
marker = {
    "cluster.yml": "- name: Install etcd",
    "scale.yml": '- name: Target only workers to get kubelet installed and checking in on any new nodes(node)',
}.get(name)
if not marker or marker not in src:
    print("marker not found, skip")
    sys.exit(0)
block = (
    "# ──────────────────────────────────────────────────────────────────────\n"
    "# 在 containerd 安装完成后, 预加载离线镜像到目标节点(解决新节点 kube-proxy/\n"
    "# calico 等镜像缺失问题)。同步/加载逻辑见 patch-playbooks/cubestack-preload.yml;\n"
    "# 镜像目录由入口脚本写入 offline.yml, 文件清单由入口脚本生成(preload-images.lst)。\n"
    "# 本 import 由入口脚本 ensure_preload_play 自动维护(kubespray 升级后重新挂载)\n"
    "# ──────────────────────────────────────────────────────────────────────\n"
)
if name == "scale.yml":
    block += (
        "- name: Preload offline images to scale nodes\n"
        "  vars:\n"
        "    preload_target: kube_node\n"
        "  import_playbook: ../patch-playbooks/cubestack-preload.yml\n"
    )
else:
    block += (
        "- name: Preload offline images to cluster nodes\n"
        "  import_playbook: ../patch-playbooks/cubestack-preload.yml\n"
    )
open(path, "w").write(src.replace(marker, block + "\n" + marker, 1))
print("patched")
PYEOF
        if grep -q "cubestack-preload.yml" "${py}"; then
            log "✅ 已挂载镜像预加载 play 到 ${name}"
        else
            warn "无法挂载镜像预加载 play 到 ${name}(未找到插入标记, kubespray 版本结构可能已变化)"
        fi
    done
}

# 将内置 registry 域名解析 play 注入 cluster.yml/scale.yml(幂等, 与 ensure_preload_play 同机制)
# 作用: 在节点 /etc/hosts 写入 "REGISTRY_IP REGISTRY_DOMAIN", 配合 containerd certs.d 信任,
#       实现集群内节点拉取 registry.local:5000 镜像。变量由 group_vars/all/registry.yml 提供。
ensure_registry_play() {
    local py name
    for py in "${KUBESPRAY_DIR}/playbooks/cluster.yml" "${KUBESPRAY_DIR}/playbooks/scale.yml"; do
        [ -f "${py}" ] || continue
        name="$(basename "${py}")"
        if grep -q "cubestack-registry.yml" "${py}"; then
            log "✅ ${name} 已挂载 registry 节点 hosts play"
            continue
        fi
        python3 - "${py}" "${name}" << 'PYEOF'
import sys
path, name = sys.argv[1], sys.argv[2]
src = open(path).read()
marker = {
    "cluster.yml": "- name: Install etcd",
    "scale.yml": '- name: Target only workers to get kubelet installed and checking in on any new nodes(node)',
}.get(name)
if not marker or marker not in src:
    print("marker not found, skip")
    sys.exit(0)
block = (
    "# ──────────────────────────────────────────────────────────────────────\n"
    "# 在内置 registry(LoadBalancer)就绪前, 在节点 /etc/hosts 写入 registry 域名解析,\n"
    "# 配合 containerd certs.d HTTP 信任, 实现集群内节点拉取 registry.local 镜像。\n"
    "# 本 import 由入口脚本 ensure_registry_play 自动维护(kubespray 升级后重新挂载)\n"
    "# ──────────────────────────────────────────────────────────────────────\n"
    "- name: Configure nodes /etc/hosts for internal registry\n"
    "  import_playbook: ../patch-playbooks/cubestack-registry.yml\n"
)
open(path, "w").write(src.replace(marker, block + "\n" + marker, 1))
print("patched")
PYEOF
        if grep -q "cubestack-registry.yml" "${py}"; then
            log "✅ 已挂载 registry 节点 hosts play 到 ${name}"
        else
            warn "无法挂载 registry 节点 hosts play 到 ${name}(未找到插入标记, kubespray 版本结构可能已变化)"
        fi
    done
}

# 将"重启 containerd + kubelet 确保 CNI 初始化"play 注入 cluster.yml/scale.yml(幂等)
# 作用: 在 Kubernetes+CNI 部署完成后、metallb 等 operator 安装前重启节点容器运行时,
#       解决 containerd 因残留/缺失 /etc/cni/net.d 而标记 CNI 未初始化导致的节点
#       NotReady(表现为 apiserver 访问其他节点 pod 超时 → admission webhook 失败)。
ensure_cni_restart_play() {
    local restart_file="${KUBESPRAY_DIR}/patch-playbooks/cubestack-cni-restart.yml"
    if [ ! -f "${restart_file}" ]; then
        log "重新生成 ${restart_file}(kubespray 升级后恢复)..."
        mkdir -p "$(dirname "${restart_file}")" 2>/dev/null || true
        cat > "${restart_file}" << 'CNI_EOF' 2>/dev/null || true
---
# ═══════════════════════════════════════════════════════════════════════════
# cubestack-installer: 重启 containerd + kubelet, 确保 CNI 插件初始化
#
# 在 Kubernetes 部署完成(CNI 已安装)、metallb 等 operator 安装之前执行, 保证
# 集群跨节点网络正常。根因: 节点 NotReady / apiserver 无法访问其他节点 pod 时,
# 各类 admission webhook 调用会超时(如 MetalLB "context deadline exceeded")。
#
# 根因: containerd 启动时读取 /etc/cni/net.d 初始化 CNI 插件; 若 reset 删除过
#       该目录(或首次部署时 CNI 未就绪), containerd 标记 CNI 未初始化,
#       calico 之后创建配置也不会重新加载 → 节点 NotReady。
#
# 挂载位置: cluster.yml / scale.yml 中"安装 Kubernetes + CNI"之后、
#           "Install Kubernetes apps"(metallb 等 operator)之前。
# 由入口脚本 ensure_cni_restart_play 自动维护(kubespray 升级后重新挂载)。
#
# 顺序: 先重启 worker 再串行重启 control-plane(尽量缩短 apiserver 中断窗口),
#       结束时等待 apiserver 就绪, 保证后续 kubernetes-apps 正常执行。
# ═══════════════════════════════════════════════════════════════════════════
- name: Restart containerd + kubelet on worker nodes (re-init CNI)
  hosts: kube_node
  gather_facts: false
  any_errors_fatal: false
  environment: "{{ proxy_disable_env }}"
  roles:
    - { role: kubespray_defaults }
  tasks:
    - name: Restart kubelet then containerd (re-init CNI plugins)
      ansible.builtin.shell: |
        systemctl restart kubelet
        sleep 5
        systemctl restart containerd
      args:
        executable: /bin/bash
      register: cni_restart_worker
      ignore_errors: true
      changed_when: false
    - name: Warn if worker restart failed
      ansible.builtin.debug:
        msg: "节点 {{ inventory_hostname }} kubelet/containerd 重启失败(rc={{ cni_restart_worker.rc | default('N/A') }}), 可手动执行: systemctl restart containerd && systemctl restart kubelet"
      when: cni_restart_worker is failed

- name: Restart containerd + kubelet on control-plane nodes (re-init CNI)
  hosts: kube_control_plane
  serial: 1
  gather_facts: false
  any_errors_fatal: false
  environment: "{{ proxy_disable_env }}"
  roles:
    - { role: kubespray_defaults }
  tasks:
    - name: Restart kubelet then containerd (re-init CNI plugins)
      ansible.builtin.shell: |
        systemctl restart kubelet
        sleep 5
        systemctl restart containerd
      args:
        executable: /bin/bash
      register: cni_restart_master
      ignore_errors: true
      changed_when: false
    - name: Warn if control-plane restart failed
      ansible.builtin.debug:
        msg: "节点 {{ inventory_hostname }} kubelet/containerd 重启失败(rc={{ cni_restart_master.rc | default('N/A') }}), 可手动执行: systemctl restart containerd && systemctl restart kubelet"
      when: cni_restart_master is failed

- name: Wait for kube-apiserver to be healthy after node restarts
  hosts: kube_control_plane[0]
  gather_facts: false
  any_errors_fatal: false
  environment:
    KUBECONFIG: "{{ kube_config_dir }}/admin.conf"
  roles:
    - { role: kubespray_defaults }
  tasks:
    - name: Wait for apiserver readyz (up to 5 minutes)
      ansible.builtin.shell: |
        for i in $(seq 1 60); do
          {{ bin_dir }}/kubectl get --raw /readyz >/dev/null 2>&1 && exit 0
          sleep 5
        done
        echo "apiserver 在 5 分钟内未恢复就绪" >&2
        exit 1
      args:
        executable: /bin/bash
      register: cni_apiserver_wait
      changed_when: false
CNI_EOF
        [ -f "${restart_file}" ] || { warn "无法生成 ${restart_file}, 跳过 CNI 重启 play 挂载"; return 0; }
    fi

    local py name
    for py in "${KUBESPRAY_DIR}/playbooks/cluster.yml" "${KUBESPRAY_DIR}/playbooks/scale.yml"; do
        [ -f "${py}" ] || continue
        name="$(basename "${py}")"
        if grep -q "cubestack-cni-restart.yml" "${py}"; then
            log "✅ ${name} 已挂载 CNI 重启 play"
            continue
        fi
        python3 - "${py}" "${name}" << 'PYEOF'
import sys
path, name = sys.argv[1], sys.argv[2]
src = open(path).read()
marker = {
    "cluster.yml": "- name: Install Kubernetes apps",
    "scale.yml": "- name: Apply resolv.conf changes now that cluster DNS is up",
}.get(name)
if not marker or marker not in src:
    print("marker not found, skip")
    sys.exit(0)
block = (
    "# ──────────────────────────────────────────────────────────────────────\n"
    "# 在 Kubernetes + CNI 部署完成后、metallb 等 operator 安装之前, 重启\n"
    "# containerd + kubelet, 确保 CNI 插件初始化(解决节点 NotReady / webhook 超时)。\n"
    "# 逻辑见 patch-playbooks/cubestack-cni-restart.yml; 由入口脚本\n"
    "# ensure_cni_restart_play 自动维护(kubespray 升级后重新挂载)。\n"
    "# ──────────────────────────────────────────────────────────────────────\n"
    "- name: Restart containerd + kubelet to (re)init CNI plugins\n"
    "  import_playbook: ../patch-playbooks/cubestack-cni-restart.yml\n"
)
open(path, "w").write(src.replace(marker, block + "\n" + marker, 1))
print("patched")
PYEOF
        if grep -q "cubestack-cni-restart.yml" "${py}"; then
            log "✅ 已挂载 CNI 重启 play 到 ${name}"
        else
            warn "无法挂载 CNI 重启 play 到 ${name}(未找到插入标记, kubespray 版本结构可能已变化)"
        fi
    done
}

# 修复 kubespray download role 镜像上传同步缺目录问题(幂等)
# 根因: download_container.yml 的 "Upload image to node" 用 ansible.posix.synchronize(rsync)
#       把镜像 push 到节点 ${local_release_dir}/images/, 但该目录不会被自动创建,
#       全新节点(scale 新 worker / 裸金属 worker)上 rsync 报 "change_dir failed:
#       No such file or directory" → 镜像没有全部同步成功。
# 根治: 在 Upload 任务前插入 "Create dest directory" 任务(与 download_file.yml 一致),
#       使 ansible-playbook 自身就能全量同步, 不依赖 preload 预建目录。
fix_download_sync_dirs() {
    local dcf="${KUBESPRAY_DIR}/roles/download/tasks/download_container.yml"
    [ -f "${dcf}" ] || { warn "未找到 ${dcf},跳过 patch"; return 0; }
    if grep -q "Download_container | Create dest directory for image upload" "${dcf}"; then
        log "✅ kubespray download_container 已 patch(上传前创建目标目录)"
        return 0
    fi
    python3 - "${dcf}" << 'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
marker = "    - name: Download_container | Upload image to node if it is cached"
if "Download_container | Create dest directory for image upload" in src:
    sys.exit(0)
assert marker in src, f"marker not found in {path}"
insert = (
    "    - name: Download_container | Create dest directory for image upload\n"
    "      file:\n"
    "        path: \"{{ image_path_final | dirname }}\"\n"
    "        state: directory\n"
    "        recurse: true\n"
    "      when:\n"
    "        - pull_required\n"
    "        - download_force_cache\n"
    "\n"
)
open(path, "w").write(src.replace(marker, insert + marker, 1))
print("patched")
PYEOF
    log "✅ 已 patch kubespray download_container.yml: 镜像上传前创建目标目录"
}

# 修复 kubespray download 角色中 dnsautoscaler / metrics_server 镜像的 groups 配置(幂等)
# 根因: 这两个镜像的 group 仅包含 kube_control_plane(master 节点), 不包含 k8s_cluster,
#       导致 kubespray 的 download role 只把镜像推到 master, 不推 worker 节点。
#       当 pod 调度到 worker 时, 镜像不存在 → kubelet 尝试外网拉取 → 离线环境超时 → ImagePullBackOff。
# 根治: 在 groups 中追加 k8s_cluster, 使 playbook 将镜像推送到所有节点。
fix_download_groups() {
    local dcf="${KUBESPRAY_DIR}/roles/kubespray_defaults/defaults/main/download.yml"
    [ -f "${dcf}" ] || { warn "未找到 ${dcf},跳过 patch"; return 0; }
    local result
    result=$(python3 - "${dcf}" << 'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
changed = False
for key in ("dnsautoscaler", "metrics_server"):
    marker = f"  {key}:"
    idx = src.find(marker)
    if idx < 0:
        continue
    # 检查 groups 块中是否已有 k8s_cluster(幂等)
    groups_pos = src.find("    groups:", idx)
    if groups_pos < 0:
        continue
    # 从 groups 行之后到下一个顶层 key 之间查找
    blk_start = src.find("\n", groups_pos) + 1
    blk_end = src.find("\n\n  ", blk_start)  # 空行 + 下一个顶层 key
    if blk_end < 0:
        blk_end = len(src)
    groups_block = src[blk_start:blk_end]
    if "k8s_cluster" in groups_block:
        continue  # 已包含, 跳过
    if "kube_control_plane" in groups_block:
        insert_pos = src.find("      - kube_control_plane", groups_pos)
        if insert_pos >= 0:
            nl = src.find("\n", insert_pos)
            src = src[:nl+1] + "      - k8s_cluster\n" + src[nl+1:]
            changed = True
if changed:
    open(path, "w").write(src)
    print("patched")
else:
    print("no change needed")
PYEOF
) 2>/dev/null
    case "${result}" in
        *patched*) log "✅ kubespray download groups 已 patch(dnsautoscaler/metrics_server 追加 k8s_cluster)" ;;
        *) log "✅ kubespray download groups 已包含 k8s_cluster(幂等跳过)" ;;
    esac
}

# ============================================================
# 依据 hosts.yml 自动同步 kubespray group_vars 中的环境 IP(与 inventory 同源)
#   group_vars/all/all.yml
#     loadbalancer_apiserver.address            = 第一个 master 节点 IP
#     apiserver_loadbalancer_domain_name        = 保持 all.yml 现有值(默认 lb.k8s.local)
#     supplementary_addresses_in_ssl_keys       = API 域名 + 全部 master 节点 IP
#   group_vars/k8s_cluster/k8s-cluster.yml
#     kube_apiserver_extra_args.advertise-address = 第一个 master 节点 IP
#   group_vars/k8s_cluster/k8s-net-calico.yml
#     calico_ip_auto_method: can-reach=<第一个 worker IP>(无 worker 时回退第一个 master)
# 数据源: 全部节点 IP 来自 hosts.yml(kube_control_plane / kube_node 组), 随 inventory 自动更新
# ============================================================
update_loadbalancer_all_yml() {
    local inv="${INVENTORY_DIR}/hosts.yml"
    local all_yml="${INVENTORY_DIR}/group_vars/all/all.yml"
    [ -f "${inv}" ] || { warn "未找到 ${inv}, 跳过 hosts.yml 同步"; return 0; }

    # 收集 kube_control_plane(master) 与 kube_node(worker) 节点 IP(优先 access_ip, 兜底 ip), 去重
    local master_ips=() worker_ips=()
    mapfile -t master_ips < <(awk '
        /^[A-Za-z0-9_]+:/ { in_cp = ($0 ~ /^kube_control_plane:/) ? 1 : 0; next }
        in_cp && /^[[:space:]]*access_ip:[[:space:]]*[0-9.]+/ { if (!seen[$2]++) print $2; next }
        in_cp && /^[[:space:]]*ip:[[:space:]]*[0-9.]+/         { if (!seen[$2]++) print $2 }
    ' "${inv}")
    mapfile -t worker_ips < <(awk '
        /^[A-Za-z0-9_]+:/ { in_w = ($0 ~ /^kube_node:/) ? 1 : 0; next }
        in_w && /^[[:space:]]*access_ip:[[:space:]]*[0-9.]+/ { if (!seen[$2]++) print $2; next }
        in_w && /^[[:space:]]*ip:[[:space:]]*[0-9.]+/         { if (!seen[$2]++) print $2 }
    ' "${inv}")
    [ "${#master_ips[@]}" -gt 0 ] || { warn "hosts.yml 中无 master 节点(kube_control_plane), 跳过同步"; return 0; }

    local api_ip="${master_ips[0]}"
    local calico_ip="${worker_ips[0]:-${api_ip}}"   # 无 worker 时回退第一个 master

    # ---------- 1. all.yml: API 负载均衡 + SAN ----------
    if [ -f "${all_yml}" ] && grep -qE '^loadbalancer_apiserver:' "${all_yml}" && grep -qE '^supplementary_addresses_in_ssl_keys:' "${all_yml}"; then
        local domain port
        domain="$(sed -nE 's/^apiserver_loadbalancer_domain_name:[[:space:]]*"?([^" ]+)"?.*/\1/p' "${all_yml}" | tail -1)"
        [ -n "${domain}" ] || domain="lb.k8s.local"
        port="$(awk '/^loadbalancer_apiserver:/{f=1} f&&/port:/{print $2; exit}' "${all_yml}")"
        [ -n "${port}" ] || port="6443"

        awk -v api="${api_ip}" -v domain="${domain}" -v port="${port}" -v masters="${master_ips[*]}" '
            BEGIN { n = split(masters, m, " ") }
            /^apiserver_loadbalancer_domain_name:/ {
                printf "apiserver_loadbalancer_domain_name: \"%s\"\n", domain
                next
            }
            /^loadbalancer_apiserver:/ { print; in_lb = 1; next }
            in_lb {
                if ($0 ~ /^[[:space:]]+address:/) { printf "  address: %s   # 第一个 master 节点 IP(由 hosts.yml 自动同步)\n", api; next }
                if ($0 ~ /^[[:space:]]+port:/)     { printf "  port: %s\n", port; next }
                in_lb = 0
            }
            /^supplementary_addresses_in_ssl_keys:/ { print; in_san = 1; next }
            in_san {
                if ($0 ~ /^[[:space:]]*-/) { next }
                printf "  - %s\n", domain
                for (i = 1; i <= n; i++) printf "  - %s\n", m[i]
                in_san = 0
            }
            { print }
        ' "${all_yml}" > "${all_yml}.tmp" && mv "${all_yml}.tmp" "${all_yml}"
        log "✅ 已依据 hosts.yml 同步 ${all_yml}: API=${api_ip}:${port}, SAN=[${master_ips[*]}]"
    else
        warn "all.yml 中未找到 loadbalancer_apiserver / supplementary_addresses_in_ssl_keys 区块(可能仍为注释), 跳过 all.yml 同步"
    fi

    # ---------- 2. k8s-cluster.yml: kube_apiserver_extra_args.advertise-address ----------
    local cluster_yml="${INVENTORY_DIR}/group_vars/k8s_cluster/k8s-cluster.yml"
    if [ -f "${cluster_yml}" ]; then
        if grep -qE '^[[:space:]]+advertise-address:[[:space:]]*"' "${cluster_yml}"; then
            sed -i -E "s/^(\s+advertise-address:)\s+\"[0-9.]+\"/\1 \"${api_ip}\"/" "${cluster_yml}"
        else
            sed -i -E "/^kube_apiserver_extra_args:/a\  advertise-address: \"${api_ip}\"" "${cluster_yml}"
        fi
        log "✅ 已依据 hosts.yml 同步 ${cluster_yml}: advertise-address=${api_ip}"
    else
        warn "未找到 ${cluster_yml}, 跳过 advertise-address 同步"
    fi

    # ---------- 3. k8s-net-calico.yml: calico_ip_auto_method can-reach ----------
    local calico_yml="${INVENTORY_DIR}/group_vars/k8s_cluster/k8s-net-calico.yml"
    if [ -f "${calico_yml}" ]; then
        if grep -qE '^calico_ip_auto_method:' "${calico_yml}"; then
            sed -i -E "s/^calico_ip_auto_method:.*/calico_ip_auto_method: \"can-reach=${calico_ip}\"/" "${calico_yml}"
        else
            echo "calico_ip_auto_method: \"can-reach=${calico_ip}\"" >> "${calico_yml}"
        fi
        log "✅ 已依据 hosts.yml 同步 ${calico_yml}: calico can-reach=${calico_ip}"
    else
        warn "未找到 ${calico_yml}, 跳过 calico can-reach 同步"
    fi
}

# 在真正部署前, 通过 SSH 检查并重置目标节点上的旧 Kubernetes 状态
# 检测到残留 → 醒目警告 + sleep 60 → kubeadm reset -f + IPVS 清理
# 未检测到 → 直接部署, 不执行 reset
# 用法: reset_kubernetes_if_needed
# 返回: 始终 0(不因 reset 失败中断部署)
# 检查并重置节点上的旧 Kubernetes 状态(部署/扩容前清理残留)
# 参数 scope:
#   all — 检查并重置全部有残留的节点(全新部署场景, 旧集群将被整体替换)
#   new — 仅检查并重置"未加入运行中集群"的新节点(扩容场景, 绝不重置旧集群节点):
#         通过首个 master 的 kubectl 获取集群现有节点(名称+InternalIP), 按清单名/
#         ansible_host/远端 hostname 三重匹配排除旧节点; 无法获取集群状态时,
#         为安全起见跳过全部 reset(宁可不清理, 也不误重置运行中的集群)
reset_kubernetes_if_needed() {
    local scope="${1:-all}"

    # 解析节点清单(host+user+key) 从 hosts.yml 获取
    local nodes_str
    nodes_str=$(ansible-inventory -i "${INVENTORY_DIR}/hosts.yml" --list 2>/dev/null | python3 -c '
import sys, json
inv = json.load(sys.stdin)
meta = inv.get("_meta", {}).get("hostvars", {})
seen = set()
for g in ["kube_control_plane", "kube_node"]:
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
    [ -n "${nodes_str}" ] || { warn "无法解析节点清单(${INVENTORY_DIR}/hosts.yml), 跳过 reset 检查"; return 0; }

    # 扩容场景: 从运行中的集群获取现有节点列表(名称 + InternalIP), 用于排除旧节点
    local existing_nodes=""
    if [ "${scope}" = "new" ]; then
        local mstr
        mstr=$(ansible-inventory -i "${INVENTORY_DIR}/hosts.yml" --list 2>/dev/null | python3 -c '
import sys, json
inv = json.load(sys.stdin)
meta = inv.get("_meta", {}).get("hostvars", {})
cp = inv.get("kube_control_plane", {}).get("hosts", [])
if not cp:
    sys.exit(0)
hv = meta.get(cp[0], {})
print("%s|%s|%s" % (
    hv.get("ansible_host", cp[0]),
    hv.get("ansible_user", "ubuntu"),
    hv.get("ansible_ssh_private_key_file", "~/.ssh/cubestack_k8s"),
))
')
        if [ -n "${mstr}" ]; then
            local mhost muser mkey
            IFS='|' read -r mhost muser mkey <<< "${mstr}"
            # 获取集群现有节点: 名称 + InternalIP + ExternalIP, 并归一化为单行空格分隔
            # (多行输出时 token 前后是换行而非空格, 会导致除首行名称/末行 IP 外的条目匹配失败)
            existing_nodes=$(ssh -i "${mkey}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
                "${muser}@${mhost}" \
                "sudo kubectl get nodes --no-headers -o wide 2>/dev/null | awk '{print \$1, \$6, \$7}'" 2>/dev/null | tr '\n' ' ' || true)
        fi
        if [ -z "${existing_nodes}" ]; then
            warn "无法获取运行中集群的节点列表, 为安全起见跳过全部 reset(避免误重置旧集群节点)"
            return 0
        fi
        log "扩容场景: 已获取集群现有节点列表($(wc -w <<< "${existing_nodes}" | tr -d ' ') 个标识), reset 仅作用于未加入集群的新节点"
    fi

    # 逐个节点检查是否已有 Kubernetes 残留(kubelet 运行 / etcd 数据 / /etc/kubernetes 等)
    # 并记录需要重置的节点(仅重置有残留的节点, 不影响干净节点)
    local found=0
    local reset_targets=()
    local oldifs="${IFS}"
    IFS=$'\n'
    for line in ${nodes_str}; do
        IFS='|' read -r node host user key <<< "${line}"
        [ -z "${node}" ] && continue

        # 探针: 首行为远端 hostname, 其后为 YES(有残留)/NO(干净)
        local probe
        probe=$(ssh -i "${key}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
            "${user}@${host}" \
            "sudo bash -c '
                hostname
                systemctl is-active kubelet 2>/dev/null | grep -qx active && { echo YES; exit 0; }
                [ -d /etc/kubernetes ] && [ -n \"\$(ls -A /etc/kubernetes 2>/dev/null)\" ] && { echo YES; exit 0; }
                [ -d /var/lib/etcd/member ] && { echo YES; exit 0; }
                [ -d /var/lib/kubelet ] && [ -n \"\$(ls -A /var/lib/kubelet 2>/dev/null)\" ] && { echo YES; exit 0; }
                echo NO
            '" 2>/dev/null || true)

        # 扩容: 已属于运行中集群的节点绝不重置(清单名/ansible_host/远端 hostname 匹配)
        if [ "${scope}" = "new" ]; then
            local remote_name in_cluster=0
            remote_name=$(head -1 <<< "${probe}")
            case " ${existing_nodes} " in
                *" ${node} "*|*" ${host} "*) in_cluster=1 ;;
            esac
            if [ -n "${remote_name}" ]; then
                case " ${existing_nodes} " in
                    *" ${remote_name} "*) in_cluster=1 ;;
                esac
            fi
            if [ "${in_cluster}" = "1" ]; then
                log "  → [${node}](${host}) 已属于运行中的集群, 跳过 reset"
                continue
            fi
        fi

        if grep -qx "YES" <<< "${probe}"; then
            log "  → [${node}](${host}) 检测到旧 Kubernetes 残留"
            found=1
            reset_targets+=("${line}")
        fi
    done
    IFS="${oldifs}"

    if [ "${found}" = "0" ]; then
        log "未检测到需要清理的旧 Kubernetes 状态, 直接部署"
        return 0
    fi

    # 检测到残留 → 醒目警告 + sleep 60
    echo ""
    highlight "╔══════════════════════════════════════════════════════════╗"
    highlight "║   ⚠️  检测到节点上已有 Kubernetes 部署! ⚠️                 ║"
    highlight "║                                                          ║"
    highlight "║  将在 60 秒后自动清理这些节点上的旧 Kubernetes 状态      ║"
    highlight "║  如需中断, 请按 Ctrl+C 退出                              ║"
    highlight "╚══════════════════════════════════════════════════════════╝"
    echo ""
    local countdown=60
    while [ "${countdown}" -gt 0 ]; do
        printf "\r  ⏳ 倒计时 %3d 秒后自动清理并继续部署..." "${countdown}"
        sleep 1
        countdown=$((countdown - 1))
    done
    printf "\r  ✅ 继续部署...                          \n"
    echo ""

    # 执行 reset: kubeadm reset -f + IPVS 清理 + 删除残留(仅重置检测到残留的节点)
    log "清理节点上的旧 Kubernetes 状态(kubeadm reset -f + IPVS 清理)..."
    local reset_ok=0 reset_fail=0
    for line in "${reset_targets[@]}"; do
        IFS='|' read -r node host user key <<< "${line}"
        [ -z "${node}" ] && continue
        log "  → [${node}](${host}) 清理中..."
        if ssh -i "${key}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
            "${user}@${host}" \
            "sudo bash -c '
                kubeadm reset -f 2>/dev/null;
                # 清理 IPVS 规则与 kube-ipvs0 虚拟接口
                ipvsadm -C 2>/dev/null;
                ip link del kube-ipvs0 2>/dev/null;
                rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd 2>/dev/null;
                systemctl stop kubelet 2>/dev/null || true;
                systemctl stop etcd 2>/dev/null || true;
                rm -f /etc/etcd.env /etc/systemd/system/etcd.service 2>/dev/null;
                true
            '" >/dev/null 2>&1; then
            reset_ok=$((reset_ok + 1))
        else
            warn "  ${node}: 清理失败, 跳过"
            reset_fail=$((reset_fail + 1))
        fi
    done
    log "✅ 清理完成: ${reset_ok} 台成功, ${reset_fail} 台失败"
}

cmd_install() {
    highlight "安装集群 [${CLUSTER_NAME}]..."
    ensure_kubespray
    ensure_venv
    cmd_check
    # 依据 hosts.yml 自动同步 all.yml 的 API 负载均衡/SAN 配置
    update_loadbalancer_all_yml
    # 部署前: 检查并重置旧 Kubernetes 状态(检测到残留才 reset; 全新部署覆盖全部节点)
    reset_kubernetes_if_needed all
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

    # 生成镜像文件清单(inventory/preload-images.lst), 供 cluster.yml 内置预加载 play 使用
    # (实际同步+加载由 cluster.yml 在 containerd 安装完成后完成;
    #  全新节点此时尚无 containerd, 入口脚本直接预加载会跳过)
    resolve_preload_image_files

    # 修复 artifacts 目录权限(kubectl_localhost/kubeconfig_localhost 用)
    fix_artifacts_perms

    # 修复 download role 镜像上传缺目录问题(使 ansible-playbook 自身可全量同步镜像)
    fix_download_sync_dirs

    # 修复 download role 镜像 groups 配置(使 dnsautoscaler/metrics-server 镜像推送到全节点)
    fix_download_groups

    # 确保 cluster.yml 已挂载镜像预加载 play(kubespray 升级后自动重新挂载)
    ensure_preload_play

    # 确保 cluster.yml 已挂载 registry 节点 hosts play(域名解析, 配合 containerd certs.d)
    ensure_registry_play

    # 确保 cluster.yml 已挂载 CNI 重启 play(K8s+CNI 之后、operator 之前重启 containerd+kubelet)
    ensure_cni_restart_play

    # ansible 日志: tee 同时写入文件 + 输出到终端
    INSTALL_LOG="/tmp/${CLUSTER_NAME}-install.log"
    log "执行 Kubespray 离线安装..."
    log "ansible 日志: 同时显示终端 + 写入 ${INSTALL_LOG}"
    [ "${ANSIBLE_LOG_TERMINAL:-1}" != "1" ] && log "ansible 日志: 仅写入文件(ANSIBLE_LOG_TERMINAL=0, 终端不显示)"
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

    run_ansible_playbook "${INSTALL_LOG}" cluster.yml \
        -i "${INVENTORY_DIR}/hosts.yml" \
        --become --become-user=root \
        ${LIMIT_FLAG} \
        -e @${OFFLINE_VARS} \
        --skip-tags system-packages,kube-proxy \
        -vv

    # 安装后兜底预加载: 补加载附加组件镜像, 同时重新生成镜像清单(供后续扩容使用)
    preload_images "all"

    # CNI 插件初始化重启(containerd + kubelet)已移入 kubespray
    # patch-playbooks/cubestack-cni-restart.yml: 在 K8s+CNI 部署完成后、operator 安装前
    # 由 ensure_cni_restart_play 自动挂载到 cluster.yml, 此处不再单独重启

    # 安装后预加载: playbook 前 containerd 可能未安装(preload 跳过), playbook 后 containerd 已就绪,
    # 补加载 playbook 未推到所有节点的镜像(如 dns-autoscaler/ metrics-server 等附加组件镜像)
    preload_images "all"

    log "🎉 集群 [${CLUSTER_NAME}] 安装完成!"
    log "完整 ansible 日志: ${INSTALL_LOG} (终端已同步显示)"
}

cmd_scale() {
    highlight "扩容集群 [${CLUSTER_NAME}] — 添加新节点..."
    ensure_kubespray
    ensure_venv
    cmd_check
    # 依据 hosts.yml 自动同步 all.yml 的 API 负载均衡/SAN 配置
    update_loadbalancer_all_yml
    # 扩容前: 仅检查并重置"新加入"节点上的旧 Kubernetes 状态
    # (已在运行集群中的节点绝不重置; 无法获取集群状态时跳过全部 reset)
    reset_kubernetes_if_needed new

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

    # 自动检测 hosts.yml 中是否有扩容专用组(名由 SCALE_GROUP_NAME 控制, 默认 new_node)
    # 存在时自动 --limit 该组, 仅对新增节点执行扩容, 避免对已有节点重复操作
    local scale_group="${SCALE_GROUP_NAME:-new_node}"
    if [ -z "$LIMIT_GROUP" ] && grep -q "^${scale_group}:" "${INVENTORY_DIR}/hosts.yml" 2>/dev/null; then
        LIMIT_GROUP="${scale_group}"
        LIMIT_FLAG="--limit ${LIMIT_GROUP}"
        log "检测到 hosts.yml 中 ${scale_group} 组, 自动 --limit ${scale_group}(仅扩容新增节点)"
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

    # ── 镜像预加载方案 ──
    # 必须先于 scale.yml 加载镜像: kubelet 启动 kube-proxy 时会尝试拉镜像,
    # 离线环境下必须先 load 到 containerd, 否则 ImagePullBackOff
    # 新 worker 节点可能尚未安装 containerd(入口脚本直接预加载会跳过)
    # 解决方案: 先跑一次 scale.yml 的前半段(仅安装 containerd + 下载镜像),
    # 然后生成镜像清单 inventory/preload-images.lst, 由 scale.yml 内置的
    # 预加载 play 在 containerd 装完后完成同步+加载
    log "预安装 containerd 到新节点(为镜像预加载做准备)..."
    cd "${KUBESPRAY_DIR}"
    run_ansible_playbook "/tmp/${CLUSTER_NAME}-prescale.log" scale.yml \
        -i "${INVENTORY_DIR}/hosts.yml" \
        --become --become-user=root \
        ${LIMIT_FLAG} \
        -e @${OFFLINE_VARS} \
        --skip-tags system-packages,kube-proxy \
        --tags container-engine,download \
        -v 2>&1 || warn "containerd 预安装部分节点可能失败(首次 scale 可忽略)"
    log "✅ containerd 预安装完成"

    # 生成镜像文件清单(inventory/preload-images.lst), 供 scale.yml 内置预加载 play 使用
    # (实际同步+加载由 scale.yml 完成, 入口脚本不再重复预加载)
    resolve_preload_image_files

    # 修复 download role 镜像上传缺目录问题(使 scale.yml 对新 worker 也能全量同步镜像)
    fix_download_sync_dirs

    # 确保 scale.yml 已挂载镜像预加载 play(kubespray 升级后自动重新挂载)
    ensure_preload_play

    # 确保 scale.yml 已挂载 CNI 重启 play(新节点 K8s+CNI 之后重启 containerd+kubelet)
    ensure_cni_restart_play

    log "执行 Kubespray 扩容 (scale.yml)..."
    log "ansible 日志: 同时显示终端 + 写入 /tmp/${CLUSTER_NAME}-scale.log"
    [ "${ANSIBLE_LOG_TERMINAL:-1}" != "1" ] && log "ansible 日志: 仅写入文件(ANSIBLE_LOG_TERMINAL=0, 终端不显示)"
    cd "${KUBESPRAY_DIR}"
    run_ansible_playbook "/tmp/${CLUSTER_NAME}-scale.log" scale.yml \
        -i "${INVENTORY_DIR}/hosts.yml" \
        --become --become-user=root \
        ${LIMIT_FLAG} \
        -e @${OFFLINE_VARS} \
        --skip-tags system-packages,kube-proxy \
        -vv || {
            err "Kubespray 扩容失败,完整日志: /tmp/${CLUSTER_NAME}-scale.log"
            return 1
        }

    # 扩容后兜底预加载: 补加载附加组件镜像(如 dns-autoscaler/metrics-server),
    # 同时重新生成镜像清单(供下次扩容或独立运行 scale.yml 使用)
    preload_images "${LIMIT_GROUP:-kube_node}"

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

    # CNI 插件初始化重启(containerd + kubelet)已移入 kubespray
    # patch-playbooks/cubestack-cni-restart.yml: 在新节点 K8s+CNI 部署完成后自动执行,
    # 由 ensure_cni_restart_play 自动挂载到 scale.yml, 此处不再单独重启

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

    # 预检连通性: 加超时防卡死。ansible ping 默认无 SSH 连接超时, 节点关机/不可达时会无限挂起
    # (曾出现: 全部 VM 关机 → 部署卡在预检不动)。timeout 60 兜底 + ConnectTimeout 让单节点快速失败。
    # 注意: ansible -e key=value 的值含空格时会被解析器按空格拆成多个 var, 必须在值外层再包一层引号,
    #       否则 ansible_ssh_common_args 只拿到 "-o", ssh 报 "no argument after keyword -o", 预检恒失败。
    timeout 60 ansible all -i "${INVENTORY_DIR}/hosts.yml" -m ping -u "${REMOTE_USER}" --become \
        -e "ansible_ssh_common_args='-o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2'" \
        >/dev/null 2>&1 || warn "部分主机 SSH/sudo 异常或不可达(预检连通性超时 60s)"
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

# ── 预加载镜像集合配置(仅同步部署 kubespray 所需的最小镜像集合) ──
# 优先级: CUBESTACK_PRELOAD_IMAGE_PATTERNS 环境变量(含空串) > inventory 下 preload-images.conf > PRELOAD_IMAGE_PATTERNS 环境变量 > 内置默认最小集合
# 匹配规则: 条目含 ".tar" 为精确文件名匹配(如 quay.io_calico_node_v3.29.3.tar), 否则为文件名包含匹配(如 calico)
# 任一来源显式置空(如 preload-images.conf 中 PRELOAD_IMAGE_PATTERNS="") = 全量同步 images/ 目录
PRELOAD_CONF="${INVENTORY_DIR}/preload-images.conf"
if [ -n "${CUBESTACK_PRELOAD_IMAGE_PATTERNS+x}" ]; then
    # 环境变量显式传递(deploy-cluster.sh 透传 cluster.conf 配置, 空串=全量同步)
    PRELOAD_IMAGE_PATTERNS="${CUBESTACK_PRELOAD_IMAGE_PATTERNS}"
    log "预加载镜像集合(环境变量): ${PRELOAD_IMAGE_PATTERNS:-<空=全量>}"
elif [ -f "${PRELOAD_CONF}" ]; then
    # shellcheck disable=SC1090
    source "${PRELOAD_CONF}"
    log "预加载镜像集合(preload-images.conf): ${PRELOAD_IMAGE_PATTERNS:-<空=全量>}"
elif [ -z "${PRELOAD_IMAGE_PATTERNS:-}" ]; then
    # 内置默认最小集合: kubespray 默认部署 + calico 网络插件 + metallb/registry/local-path 附加组件所需镜像
    # (排除 cilium/flannel/ingress-nginx/dashboard 等未启用组件的镜像)
    PRELOAD_IMAGE_PATTERNS="calico_cni calico_kube-controllers calico_node etcd kube-apiserver kube-controller-manager kube-proxy kube-scheduler coredns cluster-proportional-autoscaler k8s-dns-node-cache metrics-server pause metallb library_registry local-path-provisioner busybox"
    log "预加载镜像集合(内置默认最小集合): ${PRELOAD_IMAGE_PATTERNS}"
fi
export PRELOAD_IMAGE_PATTERNS

# 构建 ansible-playbook 通用 limit 参数
LIMIT_FLAG=""
[ -n "$LIMIT_GROUP" ] && LIMIT_FLAG="--limit ${LIMIT_GROUP}"

case "${COMMAND}" in
    init)     cmd_init ;;
    download) cmd_download ;;
    install)
        # 整个安装过程所有日志(含 ansible): 同时显示终端 + 写入日志文件
        # 每次执行前清理旧日志: 旧文件可能被上次 root/sudo 运行占用导致 tee 写失败(Permission denied),
        # 非 root 时用 sudo 删除; start_log_tee 仍作为最终兜底(回退 HOME 日志/仅终端), 不中断安装
        LOG_FILE="/tmp/${CLUSTER_NAME}-install.log"
        [ -e "${LOG_FILE}" ] && { rm -f "${LOG_FILE}" 2>/dev/null || sudo rm -f "${LOG_FILE}" 2>/dev/null || true; }
        start_log_tee "${LOG_FILE}"
        cmd_install
        ;;
    scale)
        LOG_FILE="/tmp/${CLUSTER_NAME}-scale.log"
        [ -e "${LOG_FILE}" ] && { rm -f "${LOG_FILE}" 2>/dev/null || sudo rm -f "${LOG_FILE}" 2>/dev/null || true; }
        start_log_tee "${LOG_FILE}"
        cmd_scale
        ;;
    check)    cmd_check ;;
    preload)  preload_images "${LIMIT_GROUP:-all}" ;;   # 单独预加载镜像(补镜像/修复)
    *)        usage ;;
esac
