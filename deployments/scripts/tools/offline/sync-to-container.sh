#!/bin/bash
# ============================================================
# sync-to-container.sh — 把宿主机仓库(~/cubestack-installer)的 Ceph 离线部署改动
# 同步进 cubestack-install 容器(/opt/cubestack-installer, standalone 副本, 非 git)
# 用途: 用户用容器 CLI 重新部署集群前, 把本仓库已修改的脚本/playbook/rook manifests 拷进容器。
# 背景: 容器 /opt/cubestack-installer 是独立副本(无 git, 不自动跟随仓库);
#       docker cp 覆盖 overlay 可写层即可。
# 流程(用户要求): 【本地修改完成 → sudo docker cp 到容器】—— 不在容器内跑 sed。
# ★ 2026-09-24 范围变了(重要): `deployments/scripts/` 走**整目录**同步 —— 不再需要"改了哪个文件
#   就往清单里加一行"(那个模型反复漏文件: ceph-cleanup.sh / sync-kubespray-config.sh / tools/tests/
#   / 本轮 6 个脚本都漏过, 后果是"以为同步了、容器里其实没变")。
#   ★ 2026-09-28: cubestack-addon 与 kubespray 补丁层(cubestack-patches/)也走 DIRS;
#   **kubespray 树本体有意不进同步**(整拷会删掉容器内的 inventory/ 与 .venv/)—— 它只能在容器内
#   用 cubestack-kubespray-upgrade.sh 换, 或重建 CLI 镜像; 本工具**只核对**树版本并点名(步骤 5)。
#   cluster.conf: ⚠ **默认不推送**(2026-09-08): 容器内 config 已含真实 Ceph keyring/
#   monitors 等, 本地 cluster.conf 是占位符(`<占位: 如 AQxxx==>`, 防进 git), 推送会覆盖
#   容器内真实密钥导致外部 Ceph 认证失败。需要推送时用 SYNC_CONF=1(推送前备份 .bak.ceph)。
# ⚠ 需 sudo(本机 docker 无普通用户权限)。容器名用 `CONTAINER=`(不是 SYNC_CONTAINER=)。
# 用法: sudo bash deployments/scripts/tools/offline/sync-to-container.sh
#       sudo CONTAINER=cubestack-install-c bash deployments/scripts/tools/offline/sync-to-container.sh
#       sudo SYNC_CONF=1 bash deployments/scripts/tools/offline/sync-to-container.sh  # 强制推送 cluster.conf
# ============================================================
set -euo pipefail

CONTAINER="${CONTAINER:-cubestack-install}"
# 仓库根 = 本脚本 ../../../../..(deployments/scripts/tools/offline/ → 仓库根)
REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
CT="/opt/cubestack-installer"
# 版本目录名(全 tag): 容器内路径检查用。本脚本不 load_config ⇒ 从仓库树 galaxy.yml 派生
_KV="$(awk '/^version:/{print "v"$2; exit}' "${REPO}/deployments/kubespray/kubespray/galaxy.yml" 2>/dev/null || true)"
LOCAL_CONF="${REPO}/deployments/config/cluster.conf"
CT_CONF="${CT}/deployments/config/cluster.conf"

need_root() { [ "$(id -u)" -eq 0 ] || { echo "【错误】需要 root(docker), 请 sudo 执行: sudo bash $0" >&2; exit 1; }; }
need_root

docker ps --filter "name=${CONTAINER}" --format '{{.Names}}' | grep -qx "${CONTAINER}" \
    || { echo "【错误】容器 ${CONTAINER} 未在运行(docker ps -a 查看)"; exit 1; }

echo "── 0. 本地 cluster.conf(默认不推送, 不动 ceph 开关)──"
[ -f "${LOCAL_CONF}" ] || { echo "【错误】本地配置不存在: ${LOCAL_CONF}"; exit 1; }
if [ "${SYNC_CONF:-0}" = "1" ]; then
    echo "  SYNC_CONF=1 → 启用 Ceph(仅翻两个开关行, 其余行不动) ..."
    cp "${LOCAL_CONF}" "${LOCAL_CONF}.bak.ceph"
    sed -E 's|^(CEPH_ENABLED)="\$\{CEPH_ENABLED:-false\}".*|CEPH_ENABLED="\${CEPH_ENABLED:-true}"   # Ceph 存储底座(默认部署; sync-to-container)|; s|^(CEPH_CSI_ENABLED)="\$\{CEPH_CSI_ENABLED:-false\}".*|CEPH_CSI_ENABLED="\${CEPH_CSI_ENABLED:-true}"   # Ceph CSI(默认部署; sync-to-container)|' "${LOCAL_CONF}" > "${LOCAL_CONF}.tmp" \
        && mv "${LOCAL_CONF}.tmp" "${LOCAL_CONF}"
    grep -nE '^(CEPH_ENABLED|CEPH_CSI_ENABLED)=' "${LOCAL_CONF}" | sed 's/^/  /'
    echo "  原配置已备份到 ${LOCAL_CONF}.bak.ceph"
else
    echo "  跳过(默认不推送 config, 保护容器内真实 keyring; 强制推送: SYNC_CONF=1)"
fi

echo ""
echo "── 1. 同步代码文件(repo → 容器 ${CONTAINER}:${CT}) ──"
# ★ 2026-09-24 重构: `deployments/scripts/` 改成**整目录同步**, 不再往手写清单里逐个加行。
#   原来这里是一份**逐文件清单**, 加/改一个文件就得记得补一行 —— 历史上反复漏:
#   ceph-cleanup.sh、sync-kubespray-config.sh、tools/tests/、以及本轮 6 个脚本都漏过。
#   漏同步的后果最坑: **改了、也"跑过同步"了, 但容器里其实没变**(排查时结论必然对不上)。
#   整目录 copy 之后, 新增/修改脚本无需再动这里; 只有树外的少数独立文件走下面的显式 FILES 清单
#   —— kubespray 树本体**有意不同步**, 理由见头注与本数组末尾注释。
DIRS=(
    deployments/scripts        # 模块 + 工具 + 公共库 + 离线回归测试, 整棵树
    # ★ 2026-09-24: vendored 资产也改整目录 —— 原来只列了 10 个 addon 条目(实际 111 个 yaml),
    #   于是"改了 vendored manifest 却没进容器"必然发生(multus 资源限额修复就落在清单外)。
    #   体积仅 ~10M/158 文件, 整拷代价可忽略。
    deployments/cubestack-addon
    # ★ 2026-09-28(评审 I2): 补丁层也整目录同步。它是 kubespray 树的"源码改动的唯一载体"
    #   (换树会丢弃树内手工改动, 只有 .patch 是可复现的), 而本支新增/重放了补丁 —— 漏同步的后果
    #   是"容器里重跑仍用旧补丁层"(容器内 ⑮ 只会 warn 跳过, 没有护栏)。目录很小(~64K)。
    #   ⚠ 树本体**不在这里**(整拷那条路会删掉容器内的 inventory/ 与 .venv/): 树只能按步骤 5 的
    #     指引在容器内换树, 或重建 CLI 镜像。
    deployments/kubespray/cubestack-patches
)
for d in "${DIRS[@]}"; do
    [ -d "${REPO}/${d}" ] || { echo "  ⚠ 跳过(仓库无此目录): ${d}"; continue; }
    # 仅替换仓库管理的代码目录; 保留容器的 config/、offline-files/ 与 kubespray 运行数据。
    docker exec "${CONTAINER}" rm -rf -- "${CT}/${d}"
    docker exec "${CONTAINER}" mkdir -p "$(dirname "${CT}/${d}")"
    _n="$(cd "${REPO}" && find "${d}" -type f -not -path '*__pycache__*' | wc -l)"
    docker cp "${REPO}/${d}" "${CONTAINER}:$(dirname "${CT}/${d}")/" >/dev/null \
        && echo "  ✅ ${d}/(整目录, ${_n} 个文件)"
done
FILES=(
    # ★ cluster.conf.example 必须同步(2026-09-09): 旧模板底部【示例】块是活配置,
    #   CEPH_MODE="external" 覆盖唯一开关行 → 容器内 cp example→conf 会把默认配置
    #   静默变 external。容器内 cluster.conf 本身仍默认不推送(见步骤 2)。
    deployments/config/cluster.conf.example
    deployments/kubespray/cubestack-offline.sh
    # ★ 2026-09-28(评审 I2): 两个入口脚本此前**不在清单里** → 容器里根本没有"换树/重放补丁"
    #   的能力(只有离线入口), 遇到需要重放补丁的场景只能靠人手抄。它们是独立文件(非整树),
    #   也不含运行数据, 走 FILES 逐个同步最稳(树本体见上面 DIRS 的注释)。
    deployments/kubespray/cubestack-patch-apply.sh
    deployments/kubespray/cubestack-kubespray-upgrade.sh
    # ★ 2026-09-28: 5 个注入 play 全部逐个同步 —— 原先只列了 install-packages.yml,
    #   另外 4 个(preload/registry/cni-restart/single-node)改了永远进不去容器
    #   (树本体有意不整拷, 见上面 DIRS 注释; 这几个是**我们自持**的 play, 不是上游树内容)。
    #   代价是修单节点收敛 play 的挂载位置时, 得靠入口脚本的 ensure_* 迁移逻辑(已实现)。
    deployments/kubespray/kubespray/patch-playbooks/cubestack-preload.yml
    deployments/kubespray/kubespray/patch-playbooks/cubestack-registry.yml
    deployments/kubespray/kubespray/patch-playbooks/cubestack-cni-restart.yml
    deployments/kubespray/kubespray/patch-playbooks/cubestack-single-node.yml
    deployments/kubespray/kubespray/patch-playbooks/install-packages.yml
    # (rook 离线 manifests 已由上面 DIRS 的 cubestack-addon 整目录覆盖, 不再逐条列)
)
for f in "${FILES[@]}"; do
    [ -f "${REPO}/${f}" ] || { echo "  ⚠ 跳过(仓库无此文件): ${f}"; continue; }
    docker cp "${REPO}/${f}" "${CONTAINER}:${CT}/${f}"
    echo "  ✅ ${f}"
done

echo ""
echo "── 2. cluster.conf(默认不推送, 保留容器内真实 keyring)──"
if [ "${SYNC_CONF:-0}" = "1" ]; then
    # 先备份容器内原配置
    docker exec "${CONTAINER}" bash -c "cp ${CT_CONF} ${CT_CONF}.bak.ceph 2>/dev/null || true"
    docker cp "${LOCAL_CONF}" "${CONTAINER}:${CT_CONF}"
    echo "  已推送 ${LOCAL_CONF} → ${CT_CONF}(容器原配置备份 .bak.ceph)"
else
    echo "  跳过推送: 容器内 config 保留(本地为占位 keyring, 覆盖会导致外部 Ceph 认证失败)"
    echo "  容器内当前 ceph 配置:"
    # ⚠ 宿主机管道 + set -o pipefail: 容器里 grep 一个都没匹配到(或容器内没有这份 cluster.conf)
    #   就退 1/2, docker exec 把该退出码原样带回 → 整条管道非 0 → set -e 让脚本**死在步骤 2**,
    #   步骤 3/4/5 全都不执行(用户只看到标题后面空着, 还以为容器 conf 是空的)。信息性输出
    #   不该有终止权 → `|| echo` 兜住(与步骤 4 里那些 `|| echo`/`|| true` 同理)。
    docker exec "${CONTAINER}" bash -c 'grep -nE "^(CEPH_MODE|CEPH_CSI_ENABLED|CEPH_MONITORS|CEPH_KEYRING|CEPHFS_KEYRING)=" '"${CT_CONF}" | sed 's/^/    /' || echo "    (未读到: 容器内 cluster.conf 缺失, 或其中没有这几个键)"
fi

echo ""
echo "── 3. 清理断点续跑状态(建议 --fresh 重新部署)──"
docker exec "${CONTAINER}" bash -c 'rm -f /opt/cubestack-installer/deployments/config/.deploy.state 2>/dev/null || true; echo "  已清除 .deploy.state"'

echo ""
echo "── 4. 验证(容器内)──"
docker exec "${CONTAINER}" bash -c '
  echo "  cluster.conf 关键开关:"; grep -nE "^(CEPH_ENABLED|CEPH_CSI_ENABLED|KUBE_VIP_ENABLED|LWS_ENABLED)=" '"${CT_CONF}"' || echo "    (未显式写 = 走脚本内置默认)"
  # ★ 2026-09-24: 容器里的 cluster.conf 与宿主机那份**是两份文件**(本脚本默认不推送, 见步骤 2)。
  #   默认值改过以后(kube-vip / LWS 由默认开改为默认关), 容器里那份仍留旧值 → 重跑仍走开启态
  #   ——"改了没生效", 本仓库反复踩。这里把可疑值直接点出来, 不让用户自己猜。
  #   ⚠ 本段处在宿主机的单引号区内, 载荷里一律不许出现单引号(会提前闭合外层, 把后面的功能性
  #     代码拖进错误的引用状态 —— 曾因此整段语法崩)。要拼宿主机变量, 用本文件既有的
  #     单引号-双引号-单引号三段拼接写法(sed 行末尾那处), 不要图省事直接写裸变量。
  for _k in KUBE_VIP_ENABLED LWS_ENABLED; do
      _v="$(grep -E "^${_k}=" '"${CT_CONF}"' 2>/dev/null | head -1)"
      case "${_v}" in
          *:-true*|*:-1*|*:-yes*|*:-on*)
              echo "  ⚠ 容器内 ${_k} 仍是旧默认(开): ${_v}"
              echo "     仓库默认已改为关 → 不改这里, 重跑仍走开启态"
              echo "     修法(容器内执行): sed -i \"s/${_k}:-true/${_k}:-false/\" '"${CT_CONF}"'" ;;
      esac
  done
  echo "  06_k8s_deploy.sh Ceph 预检:"; grep -c "Ceph 部署前确认" '"${CT}"/deployments/scripts/modules/02_k8s/06_k8s_deploy.sh' || true
  echo "  deploy-cluster 开始前倒计时:"; grep -c "部署开始前最后确认存储节点/裸盘" '"${CT}"/deployments/scripts/deploy-cluster.sh' || true
  echo "  02_ceph.sh 显式盘:"; grep -c "CEPH_DATA_DISKS" '"${CT}"/deployments/scripts/modules/03_addon/02_ceph.sh' || true
  echo "  detect 分类器引用: $(grep -c "ceph-disk-classify.py" '"${CT}"/deployments/scripts/tools/k8s/ceph-detect-disks.sh' || true) 处; 分类器文件: $(test -f '"${CT}"/deployments/scripts/tools/k8s/ceph-disk-classify.py' && echo 在 || echo 缺失)"
  echo "  cleanup --wipe-disks: $(grep -c "wipe-disks" '"${CT}"/deployments/scripts/tools/k8s/ceph-cleanup.sh' || true) 处"
  echo "  kube-vip 默认关: $(grep -c "KUBE_VIP_ENABLED:-false" '"${CT}"/deployments/config/cluster.conf.example' || true) 处(期望 ≥1); 关闭态不推导 VIP: $(grep -c "KUBE_VIP_ENABLED:-false" '"${CT}"/deployments/scripts/tools/k8s/sync-kubespray-config.sh' || true) 处(期望 ≥1)"
  echo "  LWS 默认关: $(grep -c "LWS_ENABLED:-false" '"${CT}"/deployments/config/cluster.conf.example' || true) 处(期望 ≥1)"
  echo "  install-packages offline_dir:"; grep -c "offline_dir" '"${CT}"/deployments/kubespray/kubespray/patch-playbooks/install-packages.yml' || true
  echo "  rook manifests:"; ls '"${CT}"/deployments/cubestack-addon/rook/'*.yaml 2>/dev/null | wc -l
  echo "  lvm 离线包(os/packages):"; ls '"${CT}/deployments/offline-files/os/packages/lvm2_"'*.deb 2>/dev/null | wc -l
  echo "  METALLB_POOL(注意是否与节点同网段):"; grep -E "^METALLB_POOL=" '"${CT_CONF}"' | head -1
'

echo ""
echo "── 5. 复核: 逐文件比对容器与仓库(不靠「应该同步了吧」)──"
# ★ 2026-09-24: 本工具以前是**手写文件清单**, 反复出现"以为同步了、其实漏了", 而漏同步的后果是
#   "拿旧脚本部署 + 排查结论对不上"。现在把事实摆出来: 目录按 md5 清单整树比(能发现内容不同,
#   也能发现容器里多/少文件), 单文件清单逐个 diff。
_bad=0
for d in "${DIRS[@]}"; do
    # ⚠ 两侧都必须 `LC_ALL=C sort`: 宿主机与容器 locale 不同时排序规则不同, 同一份内容会排成
    #   不同的顺序 → 误报"有差异"(本工具第一次跑就踩到)。固定 C 排序保证可比。
    _repo_md5="$(cd "${REPO}" && find "${d}" -type f -not -path '*__pycache__*' -exec md5sum {} + | LC_ALL=C sort -k3)"
    _ct_md5="$(docker exec "${CONTAINER}" bash -c "cd ${CT} && find '${d}' -type f -not -path '*__pycache__*' -exec md5sum {} + 2>/dev/null | LC_ALL=C sort -k3")"
    if [ -n "${_repo_md5}" ] && [ "${_repo_md5}" = "${_ct_md5}" ]; then
        echo "  ✅ ${d}/ 全部一致($(printf '%s\n' "${_repo_md5}" | grep -c .) 个文件)"
    else
        echo "  ❌ ${d}/ 有差异(左=仓库, 右=容器):"
        # ⚠ diff 的退出码 1 = "两边不一样", 正是本分支的预期结果 —— 但 set -euo pipefail 下裸管道
        #   会当场终止整个校验(_bad 不累加、单文件清单不查、末尾汇总不打印); 差异很大时 diff 输出
        #   超过管道缓冲, head 读满 15 行即关管子 → diff 被 SIGPIPE 打断 → 141, 同样自断。
        #   `|| true` 兜住这个预期失败, 让校验跑完(有差异时末尾统一 exit 1)。
        diff <(printf '%s\n' "${_repo_md5}") <(printf '%s\n' "${_ct_md5}") | head -15 | sed 's/^/      /' || true
        _bad=$((_bad + 1))
    fi
done
for f in "${FILES[@]}"; do
    [ -f "${REPO}/${f}" ] || continue
    docker exec "${CONTAINER}" cat "${CT}/${f}" 2>/dev/null | diff -q - "${REPO}/${f}" >/dev/null 2>&1 \
        || { echo "  ❌ 内容不一致: ${f}"; _bad=$((_bad + 1)); }
done

# ★ 2026-09-28(评审 I2): kubespray 树**不在同步清单里**(见文件头), 而它恰恰是本支的头号产物 ——
#   容器里那棵树是哪个版本, 只能"问"出来。不核对的话, 用户看到"同步完成"就去容器里重跑,
#   用的还是旧树(v2.28), 而容器内 ⑮ 找不到补丁层只会 warn 跳过 → 静默降级。
#   ⚠ 本段**只报告不修**(不自动换树): 换树是有 SOP 的破坏性动作(保留 inventory/.venv/
#     patch-playbooks、先退休判定再重放), 必须由人按 docs/kubespray-upgrade.md 走。
_TREE_REL="deployments/kubespray/kubespray/galaxy.yml"
_repo_tree_ver="$(grep -m1 '^version:' "${REPO}/${_TREE_REL}" 2>/dev/null | awk '{print $2}')"
# 容器侧读取整段放在容器里执行(宿主机只取回版本号); `|| true` 兜住"文件不存在/容器没这棵树"
_ct_tree_ver="$(docker exec "${CONTAINER}" bash -c "grep -m1 '^version:' ${CT}/${_TREE_REL} 2>/dev/null | awk '{print \$2}'" 2>/dev/null || true)"
if [ -n "${_ct_tree_ver}" ] && [ "${_ct_tree_ver}" = "${_repo_tree_ver}" ]; then
    echo "  ✅ kubespray 树版本一致: ${_ct_tree_ver}(仓库 == 容器)"
else
    echo "  ❌❌ kubespray 树版本不一致 —— 容器里重跑用的**不是**仓库这棵树:"
    echo "        仓库: ${_repo_tree_ver:-(读不出 ${_TREE_REL})}   容器: ${_ct_tree_ver:-(读不出/容器无此树)}"
    echo "      本工具**不会**同步树(整拷会删掉容器内的 inventory/ 与 .venv/, 有害)。两条修法:"
    echo "      ① 容器内换树: docker exec -it ${CONTAINER} bash"
    echo "           cd /opt/cubestack-installer/deployments/kubespray"
    echo "           K8S_VERSION=<ver> bash cubestack-kubespray-upgrade.sh <tag> --tree-src <容器内纯净树>"
    echo "      ② 重建 CLI 镜像(树是 COPY 进镜像的), 再用新镜像起容器"
    echo "      (SOP 见 docs/kubespray-upgrade.md §1.3/§1.4)"
    _bad=$((_bad + 1))
fi
if [ "${_bad}" = "0" ]; then
    echo "  ✅ 单文件清单亦全部一致(共 ${#FILES[@]} 个)"
else
    # ★ 非 0 退出: 否则包装脚本/CI 拿到 0 会把"没同步全"当成功; 而且末尾那句"同步完成。接下来
    #   在容器内重新部署…"会照常打印 —— 在没同步全时鼓励去部署, 正是本工具要防的事。
    echo "  ⚠ 共 ${_bad} 处不一致 —— 别急着部署, 先查为什么(上方已点名)"
    echo "  ⚠ 同步不完整: 本次以退出码 1 结束(供脚本/CI 判断); 上面每个 ❌ 都是没同步全的文件"
    exit 1
fi

echo ""
echo "同步完成。接下来在容器内重新部署(建议):"
echo "  sudo docker exec -it cubestack-install bash"
echo "  cd /opt/cubestack-installer && sudo ./deployments/scripts/deploy-cluster.sh --fresh"
echo "⚠ 若 registry 之前用 local-path 建过 PVC, 重装后新 PVC 自动走 ceph-block;"
echo "  旧集群节点数据不影响 ceph 全新部署。"
