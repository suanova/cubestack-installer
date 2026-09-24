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
#   / 本轮 6 个脚本都漏过, 后果是"以为同步了、容器里其实没变")。只有 kubespray 树与
#   cubestack-addon manifests 仍走显式清单 + 目录同步之后的 md5 整树复核(不一致会点名)。
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
#   整目录 copy 之后, 新增/修改脚本无需再动这里; kubespray 树(巨大, 只同步仓库真改过的少数
#   文件)与 cubestack-addon manifests(按需)仍走下面的显式 FILES 清单。
DIRS=(
    deployments/scripts        # 模块 + 工具 + 公共库 + 离线回归测试, 整棵树
    # ★ 2026-09-24: vendored 资产也改整目录 —— 原来只列了 10 个 addon 条目(实际 111 个 yaml),
    #   于是"改了 vendored manifest 却没进容器"必然发生(multus 资源限额修复就落在清单外)。
    #   体积仅 ~10M/158 文件, 整拷代价可忽略。kubespray 树仍走下面的显式 FILES(那个太大)。
    deployments/cubestack-addon
)
for d in "${DIRS[@]}"; do
    [ -d "${REPO}/${d}" ] || { echo "  ⚠ 跳过(仓库无此目录): ${d}"; continue; }
    docker exec "${CONTAINER}" mkdir -p "$(dirname "${CT}/${d}")" 2>/dev/null || true
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
    echo "  容器内当前 ceph 配置:"; docker exec "${CONTAINER}" bash -c 'grep -nE "^(CEPH_MODE|CEPH_CSI_ENABLED|CEPH_MONITORS|CEPH_KEYRING|CEPHFS_KEYRING)=" '"${CT_CONF}" | sed 's/^/    /'
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
  echo "  lvm 离线包:"; ls '"${CT}"/deployments/offline-files/kubespray/packages/lvm2_'*.deb 2>/dev/null | wc -l
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
        diff <(printf '%s\n' "${_repo_md5}") <(printf '%s\n' "${_ct_md5}") | head -15 | sed 's/^/      /'
        _bad=$((_bad + 1))
    fi
done
for f in "${FILES[@]}"; do
    [ -f "${REPO}/${f}" ] || continue
    docker exec "${CONTAINER}" cat "${CT}/${f}" 2>/dev/null | diff -q - "${REPO}/${f}" >/dev/null 2>&1 \
        || { echo "  ❌ 内容不一致: ${f}"; _bad=$((_bad + 1)); }
done
if [ "${_bad}" = "0" ]; then
    echo "  ✅ 单文件清单亦全部一致(共 ${#FILES[@]} 个)"
else
    echo "  ⚠ 共 ${_bad} 处不一致 —— 别急着部署, 先查为什么(上方已点名)"
fi

echo ""
echo "同步完成。接下来在容器内重新部署(建议):"
echo "  sudo docker exec -it cubestack-install bash"
echo "  cd /opt/cubestack-installer && sudo ./deployments/scripts/deploy-cluster.sh --fresh"
echo "⚠ 若 registry 之前用 local-path 建过 PVC, 重装后新 PVC 自动走 ceph-block;"
echo "  旧集群节点数据不影响 ceph 全新部署。"
