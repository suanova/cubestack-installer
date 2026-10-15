# 优雅覆盖安装（登记 + 反序卸载）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `--fresh`（及一切真正覆盖的场景）在执行 ceph 清理与 K8s 覆盖前，先读取集群内"安装登记"，按首装顺序**反序**逐个**优雅卸载**已装组件。

**Architecture:** 方案 A（模块自持卸载段）：① lib-common 新登记函数把每次安装成功写入集群内 ConfigMap `cubestack-install-record`；② 每个可卸载组件模块头部声明 `# UNINSTALL: 1` 并在 TOGGLE 跳过**之前**实现 `CUBESTACK_MODULE_ACTION=uninstall` 卸载分支；③ 新编排工具 `tools/k8s/cluster-teardown.sh` 读登记→算拆序（seq 降序 + ceph 压轴）→逐组件子进程调用→汇总；④ deploy-cluster.sh（挂点 A）与 lib-module.sh（挂点 B）在 k8s_deploy 实际将执行且集群可达时触发。

**Tech Stack:** Bash（`set -euo pipefail` 模块 / `set -uo pipefail` 工具）、python3（JSON 合并）、SSH 远端 kubectl（`init_remote_kubectl` 的 `SSH`/`K`）、helm/kubectl、ConfigMap 登记。

**Spec:** `docs/graceful-overwrite/design.md`（已提交 27fa833）—— 执行前先读它；本计划是其逐任务展开。

## Global Constraints

- **提交不带 `Co-Authored-By` trailer**（用户明确要求，见记忆 no-coauthor-trailer）。
- 全部注释/提交信息用中文；提交信息格式 `feat(graceful-overwrite): ...` 等（见各任务）。
- 仓库根 `REPO_ROOT=/home/supperadm/cubestack-installer`，当前分支 `integrated-cubestack-operator`。所有命令在仓库根执行。
- **不得破坏既有行为**：`ceph-cleanup.sh --delete-cluster` 语义不变；`check-modules.sh` 既有 18 项必须保持全绿；`--fresh` 现有语义（清状态）不变。
- 模块卸载分支**必须放在该模块 TOGGLE 跳过检查之前**（开关关闭时也要能卸载旧组件）。
- 卸载段内**自带** `init_remote_kubectl` 与所需变量派生（不依赖安装路径的变量块）；幂等（`--ignore-not-found` / 存在性检查）、有界（不用无限等待）、**告警不中止**。
- 登记写入失败**绝不阻断部署**（`warn` 即可）。
- 嵌入远端命令的引号规则（血泪教训，见记忆）：远端载荷里 `echo` 禁裸 ASCII 括号与单引号；本计划新增的 SSH 载荷全部照抄相邻既有模块的写法，不发明新引号风格。
- 每个任务收尾：`bash -n <改动文件>` + `bash deployments/scripts/tools/check-modules.sh --quiet`（既有项全绿）后再提交。

---

### Task 1: 登记函数（lib-common.sh）+ 夹具测试

**Files:**
- Modify: `deployments/scripts/lib-common.sh`（在 `init_remote_kubectl` 定义**之前**的合适位置插入，建议放"断点续跑状态文件"段落之后、输出函数段之前；或文件尾部 `addon_stub` 之前）
- Create: `deployments/scripts/tools/tests/test-cluster-teardown.sh`（本任务建文件，只含 ①② 组用例；Task 9 扩展 ③④ 组）

**Interfaces:**
- Consumes: `SSH`/`K`（`init_remote_kubectl` 提供）、`warn`、`CLUSTER_NAME`（cluster.conf 可选）。
- Produces（后续任务依赖，签名不可变）：
  - `_record_merge_json <key> [status]`：纯函数，stdin=当前 record JSON（可为空/坏），stdout=合并后的新 record JSON。新组件 `seq=现存max+1`；已存在保留 seq、更新 `lastSeenAt`/`status`。
  - `record_installed_component <key>`：读 CM → 合并 → `SSH "${K} apply -f -"` 回写；任何失败仅 warn；`_INIT_REMOTE_KUBECTL!=1` 时 warn+跳过。
  - 常量 `RECORD_CM_NS="kube-system"`、`RECORD_CM_NAME="cubestack-install-record"`。

- [ ] **Step 1: 写失败测试（record 组用例）**

创建 `deployments/scripts/tools/tests/test-cluster-teardown.sh`：

```bash
#!/bin/bash
# 桩式测试: 优雅覆盖链路 —— ① 登记合并(纯函数) ② 登记写回(假 SSH) ③ 引擎拆序/降级/离线 dry-run(Task 9 扩展)
# 隔离手段(与 test-sync-api-entry.sh 同风格):
#   ① CLUSTER_CONF 指向临时配置(load_config 只读它, 不碰真 cluster.conf)
#   ② init_remote_kubectl 之后用假 SSH 覆盖(记录调用; get cm → $FAKE_CM; apply -f - → 存 $FAKE_APPLY)
#   ③ 引擎用 CUBESTACK_TEARDOWN_TEST_INVENTORY 夹具 JSON 走离线路径(不连任何集群)
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
ENGINE="${REPO_ROOT}/deployments/scripts/tools/k8s/cluster-teardown.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
jget() { python3 -c "import json,sys;d=json.loads(sys.argv[1]);print($2)" "$1"; }

# 桩配置(最小 NODES; 其余 load_config 走默认)
cat > "${TMP}/cluster.conf" <<'EOF'
NODES=("master,m1,10.0.0.1,ubuntu,p" "master,m2,10.0.0.2,ubuntu,p" "worker,w1,10.0.0.11,ubuntu,w")
EOF

# libfn: source lib-common + load_config + init_remote_kubectl(先), 再覆盖假 SSH(后, 防被 init 覆盖);
#         stdin 原样透传给 eval 的表达式(可写 `printf ... | _record_merge_json key`)
libfn() {  # libfn <表达式>
    (
        export CLUSTER_CONF="${TMP}/cluster.conf"
        set +u
        source "${REPO_ROOT}/deployments/scripts/lib-common.sh" >/dev/null 2>&1
        load_config >/dev/null 2>&1
        init_remote_kubectl >/dev/null 2>&1 || true
        SSH() {
            printf '%s\n' "$*" >> "${FAKE_LOG:-/dev/null}" 2>/dev/null || true
            case "$*" in
                *"get cm"*) [ -n "${FAKE_CM:-}" ] && [ -f "${FAKE_CM}" ] && cat "${FAKE_CM}"; return 0 ;;
                *"apply -f -"*) [ -n "${FAKE_APPLY:-}" ] && cat > "${FAKE_APPLY}"; return 0 ;;
            esac
            return 0
        }
        eval "$1"
    )
}

# ============================================================
echo "== ① 登记合并(纯函数 _record_merge_json) =="
J1="$(libfn 'printf "%s" "{\"schema\":1,\"components\":[]}" | _record_merge_json metallb')"
chk "① 新组件 seq=1" "1" "$(jget "${J1}" 'd["components"][0]["seq"]')"
chk "① key 正确" "metallb" "$(jget "${J1}" 'd["components"][0]["key"]')"
chk "① status=done" "done" "$(jget "${J1}" 'd["components"][0]["status"]')"

J2="$(printf '%s' "${J1}" | libfn '_record_merge_json ceph')"
chk "① 第二组件 seq=2" "2" "$(jget "${J2}" 'next(c["seq"] for c in d["components"] if c["key"]=="ceph")')"

J3="$(printf '%s' "${J2}" | libfn '_record_merge_json metallb')"
chk "① 重跑不改变首装序(metallb 仍 1)" "1" "$(jget "${J3}" 'next(c["seq"] for c in d["components"] if c["key"]=="metallb")')"
chk "① 重跑不追加重复条目" "2" "$(jget "${J3}" 'len(d["components"])')"

J4="$(printf '%s' 'not-json-at-all' | libfn '_record_merge_json netshoot')"
chk "① 坏 JSON 容错(重建空登记)" "1" "$(jget "${J4}" 'd["components"][0]["seq"]')"
chk "① 坏 JSON 容错 key" "netshoot" "$(jget "${J4}" 'd["components"][0]["key"]')"

echo "== ② 登记写回(record_installed_component + 假 SSH) =="
FAKE_APPLY="${TMP}/apply1.json" libfn 'record_installed_component github_registry' >/dev/null
chk "② apply 收到 ConfigMap" "ConfigMap" "$(jget "$(cat "${TMP}/apply1.json")" 'd["kind"]')"
chk "② CM 名" "cubestack-install-record" "$(jget "$(cat "${TMP}/apply1.json")" 'd["metadata"]["name"]')"
chk "② CM ns" "kube-system" "$(jget "$(cat "${TMP}/apply1.json")" 'd["metadata"]["namespace"]')"
chk "② record.json 内含组件" "github_registry" \
    "$(jget "$(cat "${TMP}/apply1.json")" 'json.loads(d["data"]["record.json"])["components"][0]["key"]')"

# 已有 CM(含旧登记) → 合并保留旧 seq
cat > "${TMP}/cm.json" <<EOF
{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"cubestack-install-record","namespace":"kube-system"},
 "data":{"record.json":"{\"schema\":1,\"components\":[{\"key\":\"metallb\",\"seq\":1,\"status\":\"done\"}]}"}}
EOF
FAKE_CM="${TMP}/cm.json" FAKE_APPLY="${TMP}/apply2.json" libfn 'record_installed_component ceph' >/dev/null
chk "② 合并后 metallb seq 保持" "1" \
    "$(jget "$(cat "${TMP}/apply2.json")" 'next(c["seq"] for c in json.loads(d["data"]["record.json"])["components"] if c["key"]=="metallb")')"
chk "② 合并后 ceph seq=2" "2" \
    "$(jget "$(cat "${TMP}/apply2.json")" 'next(c["seq"] for c in json.loads(d["data"]["record.json"])["components"] if c["key"]=="ceph")')"

[ "${fail}" = "0" ] && { echo "全部通过"; exit 0; } || { echo "有失败项"; exit 1; }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bash deployments/scripts/tools/tests/test-cluster-teardown.sh`
Expected: 报 FAIL（`_record_merge_json: command not found` 等），退出码 1。

- [ ] **Step 3: 实现 lib-common.sh 登记段**

在 `lib-common.sh` 中插入（建议紧挨 `clear_state`/`is_state_completed` 段之后）：

```bash
# ---------------- 优雅覆盖: 安装登记(写集群内 ConfigMap) ----------------
# 设计: docs/graceful-overwrite/design.md(方案 A)。--fresh 等覆盖场景由 cluster-teardown.sh
# 读这份登记 → 按**首装序**反序调用各模块卸载段(模块头部 `# UNINSTALL: 1`)。
# 写失败**绝不阻断部署**(warn 即可; 覆盖时自会走探测降级路径)。
# 用法: record_installed_component <key>   (模块在安装成功点调用; 需已 init_remote_kubectl)
RECORD_CM_NS="kube-system"
RECORD_CM_NAME="cubestack-install-record"

# 纯函数: stdin=当前 record JSON(可空/可坏) → stdout=合并后的新 record JSON
#   · 新组件: seq = 现存 max+1(首装序 —— 反序卸载的排序键);
#   · 已存在: seq 保留(REPEAT:1 模块重跑不改变首装序), 只更新 lastSeenAt/status。
_record_merge_json() {
    local key="$1" status="${2:-done}"
    KEY="${key}" STATUS="${status}" CLUSTER_NAME="${CLUSTER_NAME:-unknown}" python3 -c '
import json, os, sys
from datetime import datetime, timezone
key = os.environ["KEY"]
try:
    rec = json.load(sys.stdin)
    if not isinstance(rec.get("components"), list):
        rec = {"schema": 1, "components": []}
except Exception:
    rec = {"schema": 1, "components": []}
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
hit = None
for c in rec["components"]:
    if isinstance(c, dict) and c.get("key") == key:
        hit = c; break
if hit is None:
    seqs = [c.get("seq", 0) for c in rec["components"] if isinstance(c, dict)]
    hit = {"key": key, "seq": (max(seqs) if seqs else 0) + 1, "firstInstalledAt": now}
    rec["components"].append(hit)
hit["lastSeenAt"] = now
hit["status"] = os.environ["STATUS"]
rec["schema"] = rec.get("schema", 1)
rec.setdefault("cluster", os.environ.get("CLUSTER_NAME", "unknown"))
print(json.dumps(rec, ensure_ascii=False))
'
}

# record JSON → 完整 ConfigMap JSON(apply 用)
_record_cm_json() {
    CM_NAME="${RECORD_CM_NAME}" CM_NS="${RECORD_CM_NS}" python3 -c '
import json, os, sys
rec = json.load(sys.stdin)
cm = {"apiVersion": "v1", "kind": "ConfigMap",
      "metadata": {"name": os.environ["CM_NAME"], "namespace": os.environ["CM_NS"],
                   "labels": {"app.kubernetes.io/managed-by": "cubestack-installer"}},
      "data": {"record.json": json.dumps(rec, ensure_ascii=False)}}
print(json.dumps(cm, ensure_ascii=False))
'
}

record_installed_component() {   # <key>
    local key="$1" cur merged
    [ -n "${key}" ] || return 0
    if [ "${_INIT_REMOTE_KUBECTL:-0}" != "1" ]; then
        warn "登记跳过(远端 kubectl 未初始化): ${key}"
        return 0
    fi
    # 读现有登记(CM 不存在/读失败 → 空登记起步)
    cur="$( (SSH "${K} -n ${RECORD_CM_NS} get cm ${RECORD_CM_NAME} -o json 2>/dev/null") || true)"
    if [ -n "${cur}" ]; then
        cur="$(printf '%s' "${cur}" | python3 -c 'import json,sys
try: print(json.loads(sys.stdin.read()).get("data",{}).get("record.json") or "{}")
except Exception: print("{}")')"
    fi
    merged="$(printf '%s' "${cur:-{\}}" | _record_merge_json "${key}" done)" \
        || { warn "登记合并失败: ${key}(不影响部署)"; return 0; }
    printf '%s' "${merged}" | _record_cm_json | SSH "${K} apply -f -" >/dev/null 2>&1 \
        || warn "登记写入失败: ${key}(不影响部署; 覆盖时将走探测降级路径)"
    return 0
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash deployments/scripts/tools/tests/test-cluster-teardown.sh`
Expected: 全部 ok，`全部通过`，退出码 0。

- [ ] **Step 5: 静态校验 + 提交**

Run: `bash -n deployments/scripts/lib-common.sh && bash deployments/scripts/tools/check-modules.sh --quiet && echo CHECK_OK`
Expected: 无输出违规 + `CHECK_OK`（新测试尚未接线 ⑲，本任务只保证不回归）。

```bash
git add deployments/scripts/lib-common.sh deployments/scripts/tools/tests/test-cluster-teardown.sh
git commit -m "feat(graceful-overwrite): 安装登记函数 record_installed_component(集群内 ConfigMap) + 夹具测试"
```

---

### Task 2: ceph-cleanup.sh —— ⓪ 停消费者提取为 `--stop-consumers`

**Files:**
- Modify: `deployments/scripts/tools/k8s/ceph-cleanup.sh`（工作区已有未提交的 delrs/delcr 修复，见 Step 0/1）
- Test: 现有 `tools/tests/` 的 ceph 磁盘链路回归由 check-modules ⑫ 跑；本任务加 bash -n + 行为镜检

**Interfaces:**
- Produces: `ceph-cleanup.sh --stop-consumers` —— 只做"⓪ 停消费者 + ① 删 Bound ceph PVC(unmap)+ ② 删 rbd nodeplugin"，**不动** cleanupPolicy、不删 pool/cluster、不擦盘。`--delete-cluster` 行为不变（内部改为先调 `stop_consumers`）。
- 供 Task 8（ceph 模块卸载段）与后续复用。

- [ ] **Step 0: 先单独提交工作区未提交的 delrs/delcr 修复**

```bash
git add deployments/scripts/tools/k8s/ceph-cleanup.sh
git commit -m "fix(ceph): 覆盖清理消费者扫描 —— 裸 RS 删本体(删 Pod 会被重建)/ CR 直管 Pod 删 CR 级联"
```

- [ ] **Step 1: 提取 stop_consumers 函数**

在 `ceph-cleanup.sh` 中，把 `delete_cluster()` 内从 `say "  ⓪ 停用持有 ceph 卷的工作负载..."` 到 `rm -f "${_vj}" "${_pj}" "${_rj}" "${_sj}"`（含 ①② PVC 删除与 nodeplugin 删除段，至 `say "  ② 删除 rbd csi nodeplugin..."` 后的 `sleep 5`）**整段**移出，成为独立函数：

```bash
# ---------------- ⓪① ② 停消费者 + 触发 unmap(可独立调用; --delete-cluster 的先导步) ----------------
# 目的(2026-10-10 用户口径): ① 消灭在飞 IO(防写死死设备/内核毒化) ② 让 CSI 自然
# NodeUnpublish→Unstage(节点内核 rbd unmap) ③ 防"删了 PVC/集群, 控制器又重建 Pod"的竞态。
# 只停**消费者**并删 Bound 的 ceph PVC(触发 unmap), 不删 registry-pvc; 不销毁集群/数据。
stop_consumers() {
    # ⚠ 原 delete_cluster 内 ⓪/①/② 三段原样搬入(含注释), 逐行保留:
    say "  ⓪ 停用持有 ceph 卷的工作负载(消灭在飞 IO; PVC 对象保留)..."
    # ⚠ 此处 原第 59~164 行、166~208 行内容原样(逐行不改; 本块为搬移示意)
    sleep 5
}
```

同时 `delete_cluster()` 改为：

```bash
delete_cluster() {
    say "删除现有 CephCluster(cleanupPolicy yes-really-destroy-data, Rook 擦盘)..."
    _exists="$( (SSH "${K} -n ${CEPH_NAMESPACE} get cephcluster --no-headers 2>/dev/null" || true) )"
    [ -z "${_exists}" ] && { ok "  无现有 CephCluster, 跳过"; return 0; }
    stop_consumers
    SSH "${K} -n ${CEPH_NAMESPACE} patch cephcluster rook-ceph --type merge \
        -p '{"spec":{"cleanupPolicy":{"confirmation":"yes-really-destroy-data"}}}' >/dev/null 2>&1" || true
    # ⚠ 此处 原 211~224 行: delete pool/cluster + 300s 等待, 原样保留(逐行不改; 本块为搬移示意)
}
```

⚠ 提取是**纯搬移**：被搬代码逐行不改（含 delrs/delcr 分支）；唯一变化是缩进与函数边界。`patch cephcluster` 与 `delete cephblockpool/cephcluster` 留在 `delete_cluster`。

- [ ] **Step 2: 增加 --stop-consumers 动作与用法**

usage 的 `cat <<'USAGE'` 中加一行：

```
  ceph-cleanup.sh --stop-consumers                    # 只停消费者 + 触发 unmap(不删集群/不擦盘)
```

参数解析 `case` 中加 `--stop-consumers)   ACTION=stop-consumers; shift ;;`；main 的 `case "${ACTION}" in` 中加：

```bash
case "${ACTION}" in
    # ...(其余 arm 不变)
    stop-consumers) stop_consumers ;;
esac
```

- [ ] **Step 3: 验证**

Run:
```bash
bash -n deployments/scripts/tools/k8s/ceph-cleanup.sh
bash deployments/scripts/tools/check-modules.sh --quiet && echo CHECK_OK
grep -n "stop_consumers\|stop-consumers" deployments/scripts/tools/k8s/ceph-cleanup.sh | head
```
Expected: 语法通过；check 全绿；函数定义 1 处、`--delete-cluster` 调用 1 处、action 1 处。

- [ ] **Step 4: 提交**

```bash
git add deployments/scripts/tools/k8s/ceph-cleanup.sh
git commit -m "feat(ceph): ceph-cleanup 停消费者+unmap 提取为 stop_consumers/--stop-consumers(--delete-cluster 先导步, 语义不变)"
```

---

### Task 3: 模块组 A —— metallb / local_path 登记 + k8s_registry 登记与卸载段

**Files:**
- Modify: `deployments/scripts/modules/03_addon/01_metallb.sh`（EOF 加登记）
- Modify: `deployments/scripts/modules/03_addon/04_local_path.sh`（EOF 加登记）
- Modify: `deployments/scripts/modules/03_addon/05_k8s_registry.sh`（头部 `# UNINSTALL: 1`；load_config 后加卸载分支；EOF 加登记）

**Interfaces:**
- Consumes: `record_installed_component`（Task 1）；`init_remote_kubectl`/`SSH`/`K`（lib-common）。
- Produces: 登记键 `metallb` / `local_path` / `k8s_registry`；registry 卸载段（scale 0）。

- [ ] **Step 1: 01_metallb.sh 末尾（第 68 行 ok 之后）追加**

```bash
# 优雅覆盖登记(安装/校验成功才登记; --fresh 覆盖时按登记反序卸载, 见 docs/graceful-overwrite/)
record_installed_component "metallb"
```

（metallb 为 kubespray 资产，**不设卸载段** —— 随 K8s 覆盖消亡，登记仅作信息。）

- [ ] **Step 2: 04_local_path.sh 末尾（第 46 行 ok 之后）追加**

```bash
# 优雅覆盖登记(同 01_metallb; local_path 为 kubespray 资产, 无独立卸载动作)
record_installed_component "local_path"
```

- [ ] **Step 3: 05_k8s_registry.sh 加元数据 + 卸载分支 + 登记**

头部元数据（`# TOGGLE: REGISTRY_ENABLED` 行后）加一行：
```
# UNINSTALL: 1
```

`load_config`（第 31 行）之后、REGISTRY_ENABLED 检查（第 34 行）**之前**插入：

```bash
# 卸载分支(优雅覆盖): registry 是 ceph PVC 消费者之一 —— K8s 覆盖前先优雅停机
# (scale 0; registry-pvc 受保护不动, kubespray 重装自动拉起新 registry)。
# ⚠ 位于 TOGGLE 检查之前: 本次配置关掉 REGISTRY_ENABLED 时, 旧集群里的 registry 也要能停。
if [ "${CUBESTACK_MODULE_ACTION:-install}" = "uninstall" ]; then
    init_remote_kubectl || exit 1
    if SSH "${K} -n kube-system get deploy registry --no-headers 2>/dev/null | grep -q ."; then
        say "  registry: 优雅停机(scale 0; registry-pvc 保留, 不删声明)"
        SSH "${K} -n kube-system scale deploy registry --replicas=0 >/dev/null 2>&1 || true"
    else
        say "  registry: 不存在, 跳过"
    fi
    exit 0
fi
```

末尾（第 101 行 `ok "内置 registry 配置完成"` 之后）追加：

```bash
# 优雅覆盖登记(registry 就绪才登记)
record_installed_component "k8s_registry"
```

- [ ] **Step 4: 验证**

Run:
```bash
bash -n deployments/scripts/modules/03_addon/01_metallb.sh \
  && bash -n deployments/scripts/modules/03_addon/04_local_path.sh \
  && bash -n deployments/scripts/modules/03_addon/05_k8s_registry.sh \
  && bash deployments/scripts/tools/check-modules.sh --quiet && echo CHECK_OK
grep -n "CUBESTACK_MODULE_ACTION" deployments/scripts/modules/03_addon/05_k8s_registry.sh
```
Expected: 全通过；`CUBESTACK_MODULE_ACTION` 行号 < `REGISTRY_ENABLED` 条件判断行号。

- [ ] **Step 5: 提交**

```bash
git add deployments/scripts/modules/03_addon/01_metallb.sh deployments/scripts/modules/03_addon/04_local_path.sh deployments/scripts/modules/03_addon/05_k8s_registry.sh
git commit -m "feat(graceful-overwrite): metallb/local_path/registry 安装登记 + registry 优雅停机卸载段"
```

---

### Task 4: 模块组 B —— netshoot / multus / rdma 登记与卸载段

**Files:**
- Modify: `deployments/scripts/modules/03_addon/35_netshoot.sh`
- Modify: `deployments/scripts/modules/03_addon/09_multus.sh`
- Modify: `deployments/scripts/modules/03_addon/10_rdma_shared_dev_plugin.sh`

**Interfaces:**
- Consumes: `record_installed_component`（Task 1）。
- Produces: 登记键 `netshoot` / `multus` / `rdma_shared_dev_plugin`；三个卸载段（删 Pod+CM / 删 manifest+NAD / 删 DS+CM）。

- [ ] **Step 1: 35_netshoot.sh**

头部元数据加 `# UNINSTALL: 1`（`# TOGGLE: NETSHOOT_ENABLED` 行后）。

`load_config`（第 41 行）之后、`NETSHOOT_ENABLED` 检查（第 43 行）**之前**插入：

```bash
# 卸载分支(优雅覆盖): 删 Pod + ConfigMap(与"开关=false 清理路径"同款语义)。
# ⚠ 位于 TOGGLE 检查之前: 本次关掉 NETSHOOT_ENABLED 时, 集群里旧 pod 也要能清。
if [ "${CUBESTACK_MODULE_ACTION:-install}" = "uninstall" ]; then
    init_remote_kubectl || exit 1
    _ns="${NETSHOOT_NAMESPACE:-default}"
    _pod="${NETSHOOT_POD_NAME:-cubestack-netshoot}"
    _cm="${NETSHOOT_POD_NAME:-cubestack-netshoot}-diag"
    say "  netshoot: 删除 pod/${_pod} + cm/${_cm}(ns=${_ns})..."
    SSH "${K} -n ${_ns} delete pod ${_pod} --ignore-not-found=true --wait=false >/dev/null 2>&1 || true"
    SSH "${K} -n ${_ns} delete cm ${_cm} --ignore-not-found=true >/dev/null 2>&1 || true"
    ok "  netshoot 已清理"
    exit 0
fi
```

文件末尾（第 339 行 `删除: ...` echo 之后）追加：

```bash
# 优雅覆盖登记(仅 ON 路径到达此处; OFF 路径此前已 exit)
record_installed_component "netshoot"
```

- [ ] **Step 2: 09_multus.sh**

头部元数据加 `# UNINSTALL: 1`（`# TOGGLE: MULTUS_ENABLED` 行后）。

`load_config`（第 35 行）之后、`MULTUS_ENABLED` 检查（第 38 行）**之前**插入：

```bash
# 卸载分支(优雅覆盖): 删 vendored manifest 全部资源(DS/CRD/RBAC/SA, delete -f 镜像 apply 语义)
# + 本模块创建的示例 NAD。⚠ 位于 TOGGLE 检查之前。
if [ "${CUBESTACK_MODULE_ACTION:-install}" = "uninstall" ]; then
    init_remote_kubectl || exit 1
    _nad_ns="${NAD_NAMESPACE:-kube-system}"
    _manifest="${REPO_ROOT}/deployments/cubestack-addon/multus/multus-daemonset-thick.yml"
    if [ -f "${_manifest}" ]; then
        say "  multus: 删除 DaemonSet/CRD/RBAC(delete -f vendored manifest)..."
        SSH "${K} delete --ignore-not-found -f -" < "${_manifest}" >/dev/null 2>&1 || true
    else
        warn "  multus: 未找到 manifest ${_manifest}, 退化为只删 DS/CRD"
        SSH "${K} -n kube-system delete ds kube-multus-ds --ignore-not-found=true >/dev/null 2>&1 || true"
        SSH "${K} delete crd network-attachment-definitions.k8s.cni.cncf.io --ignore-not-found=true >/dev/null 2>&1 || true"
    fi
    say "  删除示例 NAD ${_nad_ns}/${MULTUS_NAD_NAME:-multus-nad}..."
    SSH "${K} -n ${_nad_ns} delete network-attachment-definitions "${MULTUS_NAD_NAME:-multus-nad}" --ignore-not-found=true >/dev/null 2>&1 || true"
    ok "  multus 已卸载(ds/CRD/RBAC/示例 NAD)"
    exit 0
fi
```

文件末尾（第 186 行 `卸载的声明: ...` echo 之后）追加：

```bash
# 优雅覆盖登记
record_installed_component "multus"
```

- [ ] **Step 3: 10_rdma_shared_dev_plugin.sh**

头部元数据加 `# UNINSTALL: 1`（`# TOGGLE: RDMA_ENABLED` 行后）。

`load_config` 之后、`RDMA_ENABLED` 检查（第 61 行）**之前**插入（DS/CM 名以模块派生变量为准，即第 126-127 行的 `rdma-shared-dp-ds` / `rdma-devices`）：

```bash
# 卸载分支(优雅覆盖): 删 DaemonSet + ConfigMap(即模块末尾打印的两条清理命令)。
# ⚠ 位于 TOGGLE 检查之前。
if [ "${CUBESTACK_MODULE_ACTION:-install}" = "uninstall" ]; then
    init_remote_kubectl || exit 1
    _ns="${RDMA_NAMESPACE:-kube-system}"
    say "  rdma: 删除 ds/rdma-shared-dp-ds + cm/rdma-devices(ns=${_ns})..."
    SSH "${K} -n ${_ns} delete ds rdma-shared-dp-ds --ignore-not-found=true >/dev/null 2>&1 || true"
    SSH "${K} -n ${_ns} delete cm rdma-devices --ignore-not-found=true >/dev/null 2>&1 || true"
    ok "  RDMA 共享设备插件已卸载"
    exit 0
fi
```

⚠ 实现时打开该模块核对 DS_NAME/CM_NAME 的实际赋值行（约 126-127 行）；若实际是可配置变量则替换为同源变量表达式，保持与安装路径一致。

文件末尾（第 573 行 `清理: ...` echo 之后）追加：

```bash
# 优雅覆盖登记
record_installed_component "rdma_shared_dev_plugin"
```

- [ ] **Step 4: 验证**

Run:
```bash
for f in 35_netshoot 09_multus 10_rdma_shared_dev_plugin; do bash -n "deployments/scripts/modules/03_addon/${f}.sh" || echo "ERR ${f}"; done
bash deployments/scripts/tools/check-modules.sh --quiet && echo CHECK_OK
grep -n "UNINSTALL: 1" deployments/scripts/modules/03_addon/{35_netshoot,09_multus,10_rdma_shared_dev_plugin}.sh
grep -n "CUBESTACK_MODULE_ACTION" deployments/scripts/modules/03_addon/{35_netshoot,09_multus,10_rdma_shared_dev_plugin}.sh | cut -d: -f1-2
```
Expected: 三个 `UNINSTALL: 1` 命中；`CUBESTACK_MODULE_ACTION` 行号分别 < 各自 TOGGLE 判断行号（43/38/61）；check 全绿。

- [ ] **Step 5: 提交**

```bash
git add deployments/scripts/modules/03_addon/35_netshoot.sh deployments/scripts/modules/03_addon/09_multus.sh deployments/scripts/modules/03_addon/10_rdma_shared_dev_plugin.sh
git commit -m "feat(graceful-overwrite): netshoot/multus/rdma 安装登记 + 卸载段"
```

---

### Task 5: 模块组 C —— gpu_operator（metax）残留清理提函数 + 卸载段 + 登记

**Files:**
- Modify: `deployments/scripts/modules/03_addon/06_gpu_operator.sh`

**Interfaces:**
- Consumes: `record_installed_component`（Task 1）；`helm`、`sync_kubeconfig`（lib-common）、`SSH`/`K`。
- Produces: 登记键 `gpu_operator`；函数 `_metax_cleanup_residual()`（安装/卸载共用）。

- [ ] **Step 1: 把现有"清理残留"序列提为函数**

现第 376-390 行（`say "  清理上次残留..."` 起到 `sleep 3` 止）整体上移为函数 `_metax_cleanup_residual()`，定义放在 `load_config`（第 39 行）之后（**必须在卸载分支调用之前可执行**——bash 函数须先定义后调用）：

```bash
# 清理 metax operator 残留(CR / CRD / 命名空间 / default 旧资源 / 集群级 RBAC)。
# 安装路径(重装前清场)与卸载段(cluster-teardown)共用同一序列, 幂等。
_metax_cleanup_residual() {
    local _mns="${METAX_NAMESPACE:-metax-operator}" _mrel="${METAX_RELEASE_NAME:-metax-gpu-operator}"
    say "  清理残留(CR / CRD / ${_mns} 命名空间 / default 旧资源)..."
    SSH "${K} delete clusteroperator -n ${_mns} cluster-operator --ignore-not-found >/dev/null 2>&1" || true
    # ⚠ 此处 原 377-390 行逐行原样, 其中 ${METAX_NAMESPACE}/${METAX_RELEASE_NAME} 的引用保持不变(逐行不改; 本块为搬移示意)
}
```

原第 375-390 行位置替换为一行调用 `_metax_cleanup_residual`。

- [ ] **Step 2: 头部元数据 + 卸载分支**

头部加 `# UNINSTALL: 1`（`# TOGGLE: GPU_OPERATOR_ENABLED` 行后）。

在 `load_config` 与 `_metax_cleanup_residual` 定义**之后**、`METAX_LIST_IMAGES` 提前退出块（第 42 行）**之前**插入：

```bash
# 卸载分支(优雅覆盖): 存在性检查 → helm uninstall(尽力) → 残留清理序列(与安装前清场同款)。
# ⚠ 位于 TOGGLE 检查之前: GPU_OPERATOR_ENABLED=false 时旧 operator 也要能卸。
if [ "${CUBESTACK_MODULE_ACTION:-install}" = "uninstall" ]; then
    init_remote_kubectl || exit 1
    _mns="${METAX_NAMESPACE:-metax-operator}"
    _mrel="${METAX_RELEASE_NAME:-metax-gpu-operator}"
    _have=0
    SSH "${K} -n ${_mns} get deploy ${_mrel}-metax-operator --no-headers >/dev/null 2>&1" && _have=1
    SSH "${K} get ns ${_mns} >/dev/null 2>&1" && _have=1
    SSH "${K} get crd clusteroperators.gpu.metax-tech.com >/dev/null 2>&1" && _have=1
    if [ "${_have}" = "0" ]; then
        say "  metax GPU operator 不存在, 跳过"
        exit 0
    fi
    if command -v helm >/dev/null 2>&1 && sync_kubeconfig >/dev/null 2>&1; then
        say "  metax: helm uninstall ${_mrel}(ns=${_mns})..."
        helm uninstall "${_mrel}" -n "${_mns}" --wait --timeout 180s >/dev/null 2>&1 \
            || warn "  helm uninstall 未完成(残留由清理序列兜底)"
    else
        warn "  helm 不可用 / kubeconfig 同步失败 → 跳过 helm uninstall, 直接残留清理"
    fi
    _metax_cleanup_residual
    ok "  metax GPU operator 已卸载"
    exit 0
fi
```

- [ ] **Step 3: 登记**

文件末尾（安装路径最后的汇总 ok 之后）追加：

```bash
# 优雅覆盖登记(仅安装路径到达此处)
record_installed_component "gpu_operator"
```

- [ ] **Step 4: 验证**

Run:
```bash
bash -n deployments/scripts/modules/03_addon/06_gpu_operator.sh && bash deployments/scripts/tools/check-modules.sh --quiet && echo CHECK_OK
grep -n "_metax_cleanup_residual\|CUBESTACK_MODULE_ACTION\|UNINSTALL: 1" deployments/scripts/modules/03_addon/06_gpu_operator.sh
```
Expected: 函数定义 1 处；调用 2 处（安装路径 + 卸载分支）；`CUBESTACK_MODULE_ACTION` 行号 < `GPU_OPERATOR_ENABLED` 判断行号（66）；check 全绿。

- [ ] **Step 5: 提交**

```bash
git add deployments/scripts/modules/03_addon/06_gpu_operator.sh
git commit -m "feat(graceful-overwrite): gpu_operator 卸载段(残留清理提为函数, 安装/卸载共用) + 登记"
```

### Task 7: 模块组 E —— cubestack_operator 卸载段 + 登记

**Files:**
- Modify: `deployments/scripts/modules/03_addon/25_cubestack_operator.sh`

**Interfaces:**
- Consumes: `record_installed_component`（Task 1）；`helm`、`sync_kubeconfig`。
- Produces: 登记键 `cubestack_operator`；卸载段（删 clusterCR 级联 → helm uninstall → ns/CRD 残留清理）。

- [ ] **Step 1: 头部元数据 + 卸载分支**

头部加 `# UNINSTALL: 1`（`# TOGGLE: CUBESTACK_OPERATOR_ENABLED` 行后）。

`load_config`（第 41 行）之后、`CUBESTACK_OPERATOR_ENABLED` 检查（第 44 行）**之前**插入：

```bash
# 卸载分支(优雅覆盖): ① 删平台实例 CR(clusterCR) → operator 级联优雅收掉 9 个平台组件
#   (含 ceph PVC 消费者, 等在飞 IO 收敛) ② helm uninstall operator(尽力; 需宿主机 kubeconfig)
#   ③ 命名空间/CRD 残留清理。⚠ 位于 TOGGLE 检查之前。
if [ "${CUBESTACK_MODULE_ACTION:-install}" = "uninstall" ]; then
    init_remote_kubectl || exit 1
    _ns="${CUBESTACK_OPERATOR_NAMESPACE:-cubestack-system}"
    _rel="${CUBESTACK_OPERATOR_RELEASE:-cubestack-operator}"
    _have=0
    SSH "${K} -n ${_ns} get deploy ${_rel} --no-headers >/dev/null 2>&1" && _have=1
    SSH "${K} -n ${_ns} get csc --no-headers >/dev/null 2>&1" && _have=1
    SSH "${K} get ns ${_ns} >/dev/null 2>&1" && _have=1
    if [ "${_have}" = "0" ]; then
        say "  cubestack-operator 不存在, 跳过"
        exit 0
    fi
    # ① 删平台实例 CR(级联收组件: 先 CR 后 operator —— CR 的 finalizer 需要 operator 活着处理)
    _crs="$( (SSH "${K} -n ${_ns} get csc -o name 2>/dev/null") || true)"
    if [ -n "${_crs}" ]; then
        say "  ① 删除平台实例 CR(级联收组件)..."
        while IFS= read -r _cr; do
            [ -n "${_cr}" ] && SSH "${K} -n ${_ns} delete "${_cr}" --wait=false >/dev/null 2>&1" || true
        done <<< "${_crs}"
        # 有界等待组件收敛(≤120s; 不收敛告警继续, 不阻塞)
        for _wi in $(seq 1 12); do
            _nleft=0
            while IFS= read -r _pl; do
                [ -n "${_pl}" ] || continue
                case "${_pl}" in *" Running "*|*" Completed "*) ;; *) _nleft=$((_nleft+1)) ;; esac
            done <<< "$( (SSH "${K} -n ${_ns} get pods --no-headers 2>/dev/null") || true )"
            [ "${_nleft}" = "0" ] && break
            sleep 10
        done
        [ "${_nleft}" = "0" ] || warn "  平台组件未在 120s 内全部退出(${_nleft} 个仍在) —— 继续"
    fi
    # ② helm uninstall operator(尽力)
    if command -v helm >/dev/null 2>&1 && sync_kubeconfig >/dev/null 2>&1; then
        say "  ② helm uninstall ${_rel}(ns=${_ns})..."
        helm uninstall "${_rel}" -n "${_ns}" --wait --timeout 180s >/dev/null 2>&1 \
            || warn "  helm uninstall 未完成(残留由命名空间清理兜底)"
    else
        warn "  helm 不可用 / kubeconfig 同步失败 → 跳过 helm uninstall"
    fi
    # ③ 命名空间 / CRD 残留清理(幂等; CRD 随 K8s 覆盖也会消亡, 这里完整卸载顺手清)
    SSH "${K} patch ns ${_ns} --type=merge -p '{\"metadata\":{\"finalizers\":null}}' >/dev/null 2>&1" || true
    SSH "${K} delete ns ${_ns} --ignore-not-found --force --grace-period=0 >/dev/null 2>&1" || true
    for _crd in $( (SSH "${K} get crd -o name 2>/dev/null") | grep -i cubestack || true); do
        SSH "${K} delete ${_crd} --ignore-not-found >/dev/null 2>&1" || true
    done
    ok "  cubestack-operator 已卸载(CR 级联 + helm uninstall + 残留清理)"
    exit 0
fi
```

⚠ `patch ns ... '{\"metadata\":...}'` 写法照抄本仓库既有模块（如 06/07 的同类行），不要改写引号。

- [ ] **Step 2: 登记**

文件末尾（第 418 行 `状态查看: ...` echo 之后）追加：

```bash
# 优雅覆盖登记(仅安装路径到达此处; 本模块 REPEAT:1, 重跑只更新 lastSeenAt, seq 保持首装序)
record_installed_component "cubestack_operator"
```

- [ ] **Step 3: 验证**

Run:
```bash
bash -n deployments/scripts/modules/03_addon/25_cubestack_operator.sh && bash deployments/scripts/tools/check-modules.sh --quiet && echo CHECK_OK
grep -n "CUBESTACK_MODULE_ACTION\|UNINSTALL: 1" deployments/scripts/modules/03_addon/25_cubestack_operator.sh
```
Expected: `CUBESTACK_MODULE_ACTION` 行号 < `CUBESTACK_OPERATOR_ENABLED` 判断行号（44）；check 全绿。

- [ ] **Step 4: 提交**

```bash
git add deployments/scripts/modules/03_addon/25_cubestack_operator.sh
git commit -m "feat(graceful-overwrite): cubestack_operator 卸载段(clusterCR 级联 + helm uninstall + 残留清理) + 登记"
```

---

### Task 8: 模块组 F —— ceph 卸载段 + ceph/ceph_csi 登记

**Files:**
- Modify: `deployments/scripts/modules/03_addon/02_ceph.sh`
- Modify: `deployments/scripts/modules/03_addon/03_ceph_csi.sh`

**Interfaces:**
- Consumes: `record_installed_component`（Task 1）；`ceph-cleanup.sh --stop-consumers` / `--delete-cluster`（Task 2）。
- Produces: 登记键 `ceph` / `ceph_csi`；ceph 卸载段（**活态判定**：内部模式才动 ceph 集群；`CEPH_PRE_CLEANUP_EXISTING` 决定"销毁"还是"只停消费者+unmap"）。

- [ ] **Step 1: 02_ceph.sh 头部元数据 + 卸载分支**

头部加 `# UNINSTALL: 1`（`# TOGGLE: CEPH_ENABLED CEPH_CSI_ENABLED` 行后）。

`load_config`（时间点在第 51 行附近）之后、`CEPH_MODE` 开关块（第 59 行 `if [ "${CEPH_MODE:-internal}" = "external" ]; then`）**之前**插入：

```bash
# 卸载分支(优雅覆盖): **活态判定** —— 集群内有无 CephCluster 决定动作(不看本次配置的
# CEPH_MODE, 防"旧集群是内部 ceph、新配置切成 external"时漏清理)。
#   · 无 CephCluster → 不动(外部 ceph 的数据非本安装器资产, 绝不触碰);
#   · 有 + CEPH_PRE_CLEANUP_EXISTING=true(默认) → 完整官方安全序(停消费者→unmap→销毁);
#   · 有 + false(恢复/认领路径) → 只停消费者+unmap, **保留数据**。
# ⚠ 位于 TOGGLE 检查之前; ceph-cleanup.sh 自带 load_config/init。
if [ "${CUBESTACK_MODULE_ACTION:-install}" = "uninstall" ]; then
    init_remote_kubectl || exit 1
    _cns="${CEPH_NAMESPACE:-rook-ceph}"
    _cc="$( (SSH "${K} -n ${_cns} get cephcluster --no-headers 2>/dev/null") || true)"
    if [ -z "${_cc}" ]; then
        say "  ceph: 集群内无 CephCluster(未装/internal 已删/external 模式), 跳过"
        exit 0
    fi
    if [ "${CEPH_PRE_CLEANUP_EXISTING:-true}" = "true" ]; then
        say "  ceph: 完整安全序卸载(停消费者→unmap→删集群; OSD 数据销毁)"
        bash "${SCRIPT_DIR}/tools/k8s/ceph-cleanup.sh" --delete-cluster \
            || warn "  ceph 卸载未完全收敛(擦盘兜底交给重装路径 7a)"
    else
        say "  ceph: CEPH_PRE_CLEANUP_EXISTING=false → 只停消费者+unmap, 保留数据(恢复/认领路径)"
        bash "${SCRIPT_DIR}/tools/k8s/ceph-cleanup.sh" --stop-consumers \
            || warn "  ceph 停消费者未完全收敛(继续)"
    fi
    exit 0
fi
```

- [ ] **Step 2: 02_ceph.sh 登记**

文件末尾（第 941 行 `卸载: ...` echo 之后）追加：

```bash
# 优雅覆盖登记(到达此处=集群内 ceph 体系部署/`external 接入)成功)
record_installed_component "ceph"
```

- [ ] **Step 3: 03_ceph_csi.sh 登记（无卸载段）**

头部不加 `# UNINSTALL:`（StorageClass 等对象随 K8s 覆盖消亡，仅登记作信息）。

文件末尾（最后一条 `卸载: kubectl delete sc ceph-block; ...` echo 之后）追加：

```bash
# 优雅覆盖登记(仅登记; SC 等对象随 K8s 覆盖消亡, 无独立卸载动作 —— 设计 §3.2)
record_installed_component "ceph_csi"
```

- [ ] **Step 4: 验证**

Run:
```bash
bash -n deployments/scripts/modules/03_addon/02_ceph.sh && bash -n deployments/scripts/modules/03_addon/03_ceph_csi.sh \
  && bash deployments/scripts/tools/check-modules.sh --quiet && echo CHECK_OK
grep -n "CUBESTACK_MODULE_ACTION\|UNINSTALL: 1" deployments/scripts/modules/03_addon/02_ceph.sh
```
Expected: `CUBESTACK_MODULE_ACTION` 行号 < `CEPH_MODE`/`CEPH_ENABLED` 首个条件判断行号（59）；check 全绿。

- [ ] **Step 5: 提交**

```bash
git add deployments/scripts/modules/03_addon/02_ceph.sh deployments/scripts/modules/03_addon/03_ceph_csi.sh
git commit -m "feat(graceful-overwrite): ceph 卸载段(活态判定 + PRE_CLEANUP 语义, 复用 ceph-cleanup 安全序) + ceph/ceph_csi 登记"
```

---

### Task 9: 引擎 tools/k8s/cluster-teardown.sh + 测试扩展（③④ 组）

**Files:**
- Create: `deployments/scripts/tools/k8s/cluster-teardown.sh`
- Modify: `deployments/scripts/tools/tests/test-cluster-teardown.sh`（追加 ③④ 组用例）

**Interfaces:**
- Consumes: lib-common（`load_config`/`init_remote_kubectl`/`SSH`/`K`/`err`/`warn`/`ok`/`say`/`SCRIPT_DIR`）+ lib-module（`discover_modules`/`module_meta`/`MODULES_DIR`/`MODULE_KEY`/`MODULE_SCRIPT`）。
- Produces（给 Task 10/11/12 与运维使用）：
  - CLI：`--list [--raw]`、`--uninstall [--yes]`；`--yes` 或 env `CUBESTACK_ASSUME_YES=1` 免倒计时；env `CUBESTACK_TEARDOWN_TEST_INVENTORY=<file>` = 离线夹具（`--uninstall` 变为只打印不执行）；env `TEARDOWN_CONFIRM_SLEEP`（默认 30）、`TEARDOWN_COMPONENT_TIMEOUT`（默认 600）。
  - 拆序规则：登记 seq 降序 → 未登记 UNINSTALL 组件按模块文件序反排插后 → `ceph` 强制压轴。
  - 组件调用协议：`CUBESTACK_MODULE_ACTION=uninstall timeout -k 15 <T> bash <模块脚本>`；成功后把登记内该组件标 `status=uninstalled`（仅非夹具模式）。

- [ ] **Step 1: 写引擎（完整文件）**

```bash
#!/bin/bash
# ============================================================
# TOOL: cluster-teardown —— 优雅覆盖: 按安装登记"反序"卸载集群内已装组件
# 设计: docs/graceful-overwrite/design.md(方案 A: 模块自持卸载段)
#   · 候选 = 声明 `# UNINSTALL: 1` 的模块 ∪ 登记(ConfigMap cubestack-install-record)中的组件;
#   · 拆序 = 登记 seq 降序 → 未登记者按模块文件序反排插后 → ceph 强制压轴(安全不变量);
#   · 逐组件以 CUBESTACK_MODULE_ACTION=uninstall 调用其模块脚本(模块内存在性检查, 幂等);
#   · 失败/超时 → 告警不中止(后续 ceph 安全序与 kubeadm reset 兜底); 收尾汇总。
# 用法:
#   cluster-teardown.sh --list               # 只读: 打印登记表 + 计划拆序(--raw 输出 TSV 供测试)
#   cluster-teardown.sh --uninstall [--yes]  # 执行反序优雅卸载(--yes / CUBESTACK_ASSUME_YES=1 免倒计时)
#   · 非交互且未 --yes → 跳过卸载并醒目警告(节点旧集群 reset 前置会再次要求 --yes);
#   · 测试钩子: CUBESTACK_TEARDOWN_TEST_INVENTORY=<file> 以夹具 JSON 代替读集群(离线夹具用)。
# 数据源: cluster.conf (NODES 等) + 集群内 ConfigMap cubestack-install-record(kube-system)
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "${SCRIPT_DIR}/../../lib-common.sh"
# shellcheck source=lib-module.sh
# ★ lib-common 被 source 时会以自身目录覆盖 SCRIPT_DIR, 故此处内联定位(与 deploy-cluster.sh 同款)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-module.sh"
load_config
discover_modules   # MODULE_KEY/MODULE_SCRIPT(文件序)供候选枚举

CM_NS="kube-system"
CM_NAME="cubestack-install-record"
COMPONENT_TIMEOUT="${TEARDOWN_COMPONENT_TIMEOUT:-600}"
CONFIRM_SLEEP="${TEARDOWN_CONFIRM_SLEEP:-30}"
TEST_INV="${CUBESTACK_TEARDOWN_TEST_INVENTORY:-}"

ACTION=""; ASSUME_YES="${CUBESTACK_ASSUME_YES:-0}"; RAW=0
while [ $# -gt 0 ]; do
    case "$1" in
        --list)      ACTION=list; shift ;;
        --uninstall) ACTION=uninstall; shift ;;
        --raw)       RAW=1; shift ;;
        --yes|-y)    ASSUME_YES=1; shift ;;
        -h|--help)   sed -n '3,15p' "$0"; exit 0 ;;
        *) err "未知参数: $1(用法: $0 --list [--raw] | --uninstall [--yes])"; exit 1 ;;
    esac
done
[ -n "${ACTION}" ] || { err "用法: $0 --list [--raw] | --uninstall [--yes]"; exit 1; }

# ---------------- 读登记(读不到 → 空登记, 调用方走全量探测降级) ----------------
read_inventory() {
    if [ -n "${TEST_INV}" ]; then
        [ -f "${TEST_INV}" ] || { printf '{"schema":1,"components":[]}'; return 0; }
        cat "${TEST_INV}"; return 0
    fi
    init_remote_kubectl >/dev/null 2>&1 || { printf '{"schema":1,"components":[]}'; return 0; }
    local j
    j="$( (SSH "${K} -n ${CM_NS} get cm ${CM_NAME} -o json 2>/dev/null") || true)"
    if [ -z "${j}" ]; then printf '{"schema":1,"components":[]}'; return 0; fi
    printf '%s' "${j}" | python3 -c '
import json, sys
try:
    cm = json.load(sys.stdin)
    rec = json.loads((cm.get("data") or {}).get("record.json") or "{}")
    if not isinstance(rec.get("components"), list):
        rec = {"schema": 1, "components": []}
except Exception:
    rec = {"schema": 1, "components": []}
print(json.dumps(rec, ensure_ascii=False))
'
}

# ---------------- 拆序 ----------------
# <inventory_json_file> → stdout: <key>\t<record|probe>\t<模块相对路径>(按拆序)
compute_order() {   # <inventory_json_file>
    local invf="$1" _mf _i _un
    _mf="$(mktemp)"
    for _i in "${!MODULE_KEY[@]}"; do
        _un="$(module_meta "${MODULES_DIR}/${MODULE_SCRIPT[$_i]}" UNINSTALL)"
        [ "${_un}" = "1" ] || continue
        printf '%s\t%s\n' "${MODULE_KEY[$_i]}" "${MODULE_SCRIPT[$_i]}" >> "${_mf}"
    done
    python3 - "${_mf}" "${invf}" <<'PY'
import json, sys
mods = {}   # key -> script(插入序 = 模块文件序)
for line in open(sys.argv[1]):
    k, s = line.rstrip("\n").split("\t")
    mods[k] = s
try:
    rec = json.load(open(sys.argv[2]))
except Exception:
    rec = {}
comps = {}
for c in (rec.get("components") or []):
    if isinstance(c, dict) and c.get("key"):
        comps[c["key"]] = c
# 主序: 有登记 seq 的按 seq 降序; 次序: 其余 UNINSTALL 模块按文件序反排; ceph 强制压轴
recorded = [k for k in mods if k in comps and isinstance(comps[k].get("seq"), int)]
recorded.sort(key=lambda k: comps[k]["seq"], reverse=True)
rest = [k for k in mods if k not in recorded][::-1]
seq = recorded + rest
if "ceph" in seq:
    seq.remove("ceph")
    seq.append("ceph")
for k in seq:
    print("%s\t%s\t%s" % (k, "record" if k in recorded else "probe", mods[k]))
PY
    rm -f "${_mf}"
}

print_inventory() {   # <inventory_json_file>(全部登记组件; 含无卸载动作的 base 组件 — 仅信息)
    python3 - "$1" <<'PY'
import json, sys
try:
    rec = json.load(open(sys.argv[1]))
except Exception:
    rec = {}
comps = rec.get("components") or []
if not comps:
    print("  <登记为空: 无记录组件(存量集群将走全量探测降级路径)>")
for c in sorted(comps, key=lambda c: c.get("seq", 0)):
    print("  seq=%-3s %-24s 首装=%s  状态=%s" % (
        c.get("seq", "?"), c.get("key", "?"),
        c.get("firstInstalledAt", "?"), c.get("status", "?")))
PY
}

print_order() {   # <inventory_json_file>
    compute_order "$1" | awk -F'\t' '{printf "  %2d. %-24s [%s]\n", NR, $1, ($2=="record" ? "登记" : "探测降级")}'
}

# ---------------- 执行 ----------------
# 组件卸载后把登记里该组件标 uninstalled(审计 + 中断可续; 失败仅告警)
mark_uninstalled() {   # <key>
    [ -n "${TEST_INV}" ] && return 0
    [ -n "${K:-}" ] || return 0
    local key="$1" j new
    j="$( (SSH "${K} -n ${CM_NS} get cm ${CM_NAME} -o json 2>/dev/null") || true)"
    [ -n "${j}" ] || return 0
    new="$(printf '%s' "${j}" | KEY="${key}" python3 -c '
import json, os, sys
key = os.environ["KEY"]
cm = json.load(sys.stdin)
try:
    rec = json.loads((cm.get("data") or {}).get("record.json") or "{}")
except Exception:
    rec = {}
for c in (rec.get("components") or []):
    if isinstance(c, dict) and c.get("key") == key:
        c["status"] = "uninstalled"
cm.setdefault("data", {})["record.json"] = json.dumps(rec, ensure_ascii=False)
print(json.dumps(cm))
')" || return 0
    printf '%s' "${new}" | SSH "${K} apply -f -" >/dev/null 2>&1 \
        || warn "  登记状态更新失败: ${key}(不影响卸载)"
}

run_component() {   # <key> <script_rel>  → 0=卸了; 1=失败/超时
    local key="$1" rel="$2" mod="${MODULES_DIR}/${rel}"
    [ -f "${mod}" ] || { warn "  模块脚本缺失: ${mod}(跳过 ${key})"; return 1; }
    say "  ▶ 卸载 ${key}(${rel})"
    if CUBESTACK_MODULE_ACTION=uninstall timeout -k 15 "${COMPONENT_TIMEOUT}" bash "${mod}"; then
        ok "  ✔ ${key} 已卸载"
        mark_uninstalled "${key}"
        return 0
    fi
    warn "  ✖ ${key} 卸载失败/超时(${COMPONENT_TIMEOUT}s) —— 继续(后续 ceph 安全序与 k8s 覆盖兜底)"
    return 1
}

# ---------------- main ----------------
_invf="$(mktemp)"
trap 'rm -f "${_invf}"' EXIT
read_inventory > "${_invf}"

case "${ACTION}" in
    list)
        if [ "${RAW}" = "1" ]; then
            compute_order "${_invf}"
            exit 0
        fi
        say "==== 安装登记(ConfigMap ${CM_NAME} @ ${CM_NS}) ===="
        print_inventory "${_invf}"
        echo ""
        say "==== 计划拆序(反序优雅卸载; 仅列可调用组件) ===="
        print_order "${_invf}"
        ;;
    uninstall)
        _order="$(compute_order "${_invf}")"
        if [ -z "${_order}" ]; then
            say "无需卸载(登记为空且无可行卸载组件)"
            exit 0
        fi
        say "==== 优雅覆盖: 按安装顺序反序卸载已装组件(候选 $(printf '%s\n' "${_order}" | wc -l) 个) ===="
        print_inventory "${_invf}"
        echo ""
        print_order "${_invf}"
        # 登记了但无卸载动作的组件(如 base) → 明确告知(不算失败)
        _noact="$(python3 - "${_invf}" "${_order}" <<'PY'
import json, sys
try:
    rec = json.load(open(sys.argv[1]))
except Exception:
    rec = {}
in_order = set(l.split("\t")[0] for l in sys.argv[2].splitlines() if l.strip())
out = [c.get("key", "?") for c in (rec.get("components") or []) if c.get("key") not in in_order]
print(" ".join(out))
PY
)"
        [ -n "${_noact}" ] && say "  (登记中无卸载动作的组件, 随 K8s 覆盖消亡: ${_noact})"
        if [ -n "${TEST_INV}" ]; then
            warn "  测试钩子生效(CUBESTACK_TEARDOWN_TEST_INVENTORY): 仅打印, 不实际执行"
            exit 0
        fi
        if [ "${ASSUME_YES}" != "1" ]; then
            if [ -t 0 ]; then
                say "将逐个调用以上组件的卸载逻辑(存在性检查→优雅停→卸载)。${CONFIRM_SLEEP}s 后继续(Ctrl-C 中止)..."
                _c="${CONFIRM_SLEEP}"
                while [ "${_c}" -gt 0 ]; do printf "\r  ⏳ %2d 秒" "${_c}"; sleep 1; _c=$((_c - 1)); done
                printf "\r  %s\n" "开始卸载..."
            else
                warn "非交互且未 --yes: 跳过优雅卸载(继续覆盖流程; 节点旧集群 reset 前置会再次要求 --yes)"
                exit 0
            fi
        fi
        init_remote_kubectl || { err "集群不可达(SSH 初始化失败), 无法执行卸载"; exit 1; }
        SSH "${K} get ns ${CM_NS} >/dev/null 2>&1" || { err "集群不可达(远端 kubectl 探测失败), 无法执行卸载"; exit 1; }
        _n_ok=0; _n_fail=0
        while IFS=$'\t' read -r _key _src _rel; do
            [ -n "${_key}" ] || continue
            if run_component "${_key}" "${_rel}"; then _n_ok=$((_n_ok + 1)); else _n_fail=$((_n_fail + 1)); fi
        done <<< "${_order}"
        echo ""
        say "优雅卸载完成: 成功 ${_n_ok} 个, 失败/跳过 ${_n_fail} 个"
        if [ "${_n_fail}" -gt 0 ]; then
            warn "有组件未完全卸净 —— 后续 ceph 安全序(⓪ 泛化扫描)与 kubeadm reset 将兜底"
        fi
        exit 0
        ;;
esac
```

⚠ bash 引号自查：**没有** `bash -c "..."` 内嵌载荷；无单引号包裹的远端命令（照抄模块内既有形式）。

- [ ] **Step 2: 扩展测试文件（③④ 组）+ 先跑失败**

在 `test-cluster-teardown.sh` 的 `[ "${fail}" = "0" ] && ...` 收尾行**之前**插入：

```bash
echo "== ③ 引擎拆序(夹具登记; 离线) =="
INV="${TMP}/inv.json"
cat > "${INV}" <<'EOF'
{"schema":1,"components":[
 {"key":"metallb","seq":1,"status":"done"},
 {"key":"k8s_registry","seq":2,"status":"done"},
 {"key":"ceph","seq":3,"status":"done"},
 {"key":"multus","seq":5,"status":"done"},
 {"key":"cubestack_operator","seq":9,"status":"done"}
]}
EOF
ORDER="$(CLUSTER_CONF="${TMP}/cluster.conf" CUBESTACK_TEARDOWN_TEST_INVENTORY="${INV}" bash "${ENGINE}" --list --raw 2>/dev/null)"
chk "③ ceph 压轴(最后一行)" "ceph" "$(printf '%s\n' "${ORDER}" | tail -1 | cut -f1)"
chk "③ 登记 seq 降序生效(operator 在 ceph 前)" "cubestack_operator" "$(printf '%s\n' "${ORDER}" | sed -n '1p' | cut -f1)"
chk "③ 登记 seq 降序判别(multus seq5 先于 registry seq2)" "1" "$(printf '%s\n' "${ORDER}" | awk -F'\t' '
  { n++; if ($1=="multus") a=n; if ($1=="k8s_registry") b=n }
  END { print (a>0 && b>0 && a<b) ? 1 : 0 }')"
chk "③ metallb 无 UNINSTALL → 不进拆序" "0" "$(printf '%s\n' "${ORDER}" | cut -f1 | grep -cx 'metallb')"
chk "③ ceph_csi 无 UNINSTALL → 不进拆序" "0" "$(printf '%s\n' "${ORDER}" | cut -f1 | grep -cx 'ceph_csi')"
chk "③ 探测降级组(netshoot)在登记组之后" "1" "$(printf '%s\n' "${ORDER}" | awk -F'\t' '
  { n++; if ($1=="cubestack_operator") a=n; if ($1=="netshoot") b=n }
  END { print (a>0 && b>0 && b>a) ? 1 : 0 }')"
chk "③ netshoot 来源=probe" "probe" "$(printf '%s\n' "${ORDER}" | awk -F'\t' '$1=="netshoot"{print $2}')"

echo "== ④ 引擎离线 dry-run(--uninstall + 夹具 → 只打印不执行) =="
OUT4="$(CLUSTER_CONF="${TMP}/cluster.conf" CUBESTACK_TEARDOWN_TEST_INVENTORY="${INV}" bash "${ENGINE}" --uninstall 2>&1)"
RC4=$?
chk "④ 退出码 0" "0" "${RC4}"
chk "④ 提示测试钩子" "1" "$(printf '%s' "${OUT4}" | grep -c '测试钩子生效' || true)"
chk "④ 未实际执行组件(无 ▶ 卸载 行)" "0" "$(printf '%s' "${OUT4}" | grep -c '▶ 卸载' || true)"
```

Run: `bash deployments/scripts/tools/tests/test-cluster-teardown.sh`
Expected: ③④ 组 FAIL（引擎文件不存在）或全 FAIL。

- [ ] **Step 3: 跑测试确认通过**

Run: `bash deployments/scripts/tools/tests/test-cluster-teardown.sh`
Expected: `全部通过`，退出码 0。（③ 组依赖 Task 3-8 已给模块加 `UNINSTALL: 1`；若此前任务未完成会失败——任务顺序不可调换。）

- [ ] **Step 4: 验证 + 提交**

Run:
```bash
bash -n deployments/scripts/tools/k8s/cluster-teardown.sh && bash deployments/scripts/tools/check-modules.sh --quiet && echo CHECK_OK
CLUSTER_CONF=deployments/config/cluster.conf bash deployments/scripts/tools/k8s/cluster-teardown.sh --list 2>/dev/null | head -20 || true
```
Expected: 语法/检查通过；`--list` 打印登记表+拆序（本机连不到集群时登记为空，拆序仍列出探测降级组）。

```bash
git add deployments/scripts/tools/k8s/cluster-teardown.sh deployments/scripts/tools/tests/test-cluster-teardown.sh
git commit -m "feat(graceful-overwrite): cluster-teardown 引擎(拆序 + 逐组件卸载调用 + 汇总; 夹具 ③④ 组)"
```

---

### Task 10: deploy-cluster.sh 挂点 A + 帮助文本

**Files:**
- Modify: `deployments/scripts/deploy-cluster.sh`

**Interfaces:**
- Consumes: 引擎（Task 9）；`cluster_exists`/`get_state`（lib-module）；`SCRIPT_DIR`。
- Produces: 导出 `CUBESTACK_TEARDOWN_DONE=1`（Task 11 的挂点 B 靠它防双跑）。

- [ ] **Step 1: 插入挂点 A**

在 `print_plan`（第 370 行）调用**之后**、ceph 预检块注释（第 372 行 `# ⚠ Ceph 部署前强制确认...`）**之前**插入：

```bash
# ★ 优雅覆盖(2026-10-11 用户口径, 设计 docs/graceful-overwrite/): K8s 覆盖**实际将发生**时
#   (RUN_STEPS 含 k8s_deploy 且其实状态非 done —— --fresh 清状态后天然成立), 且集群可达时:
#   先读安装登记 → 按首装序反序优雅卸载已装组件(卸载段在各自模块内), 之后 ceph 预检块
#   自然看到"无 CephCluster"(其删除分支空转)。⚠ 新容器此刻可能还没有 SSH 密钥 →
#   cluster_exists 判不出集群 → 由挂点 B(执行 k8s_deploy 前, lib-module.sh)兜底。
if [ "$(get_state k8s_deploy)" != "done" ]; then
    _OVERWRITE_PENDING=0
    for _ok_k in "${RUN_STEPS[@]:-}"; do
        [ "${_ok_k}" = "k8s_deploy" ] && _OVERWRITE_PENDING=1
    done
    unset _ok_k
    if [ "${_OVERWRITE_PENDING}" = "1" ] && cluster_exists; then
        _te_args=()
        [ "${ASSUME_YES}" = "1" ] && _te_args=(--yes)
        say "检测到集群已存在且本次将覆盖重装 → 先执行「优雅覆盖」: 按安装登记反序卸载已装组件"
        bash "${SCRIPT_DIR}/tools/k8s/cluster-teardown.sh" --uninstall "${_te_args[@]}" \
            || warn "优雅卸载未完成(继续; ceph 安全序与 k8s 覆盖流程兜底)"
        export CUBESTACK_TEARDOWN_DONE=1
    fi
    unset _OVERWRITE_PENDING
fi
```

⚠ `_te_args=()` 空数组在 `set -u` + 旧 bash 下 `"${_te_args[@]}"` 展开为空串参数的问题：本仓库 CLI 镜像 bash ≥5.1（既有代码同款用法，见 deploy-cluster.sh 第 526 行 `_DETECT_ARGS+=(...)` 用法），安全。

- [ ] **Step 2: 更新 usage 帮助文本**

`usage()` 的"三种使用方式"② 段（第 93-95 行）后补一行：

```
     · **优雅覆盖**(2026-10-11): K8s 覆盖实际将执行且集群可达时, 会先读集群内安装登记
       (ConfigMap cubestack-install-record)按首装序**反序优雅卸载**已装组件(先停消费者/CR 级联/
       helm uninstall, 再动 Ceph, 最后 K8s 覆盖) —— 非暴力重置。倒计时 TEARDOWN_CONFIRM_SLEEP
       (默认 30s)可 Ctrl-C; --yes 免交互。手动查看: tools/k8s/cluster-teardown.sh --list
       设计: docs/graceful-overwrite/design.md
```

- [ ] **Step 3: 验证**

Run:
```bash
bash -n deployments/scripts/deploy-cluster.sh && bash deployments/scripts/tools/check-modules.sh --quiet && echo CHECK_OK
bash deployments/scripts/deploy-cluster.sh --help 2>/dev/null | grep -A3 "优雅覆盖" | head -6
```
Expected: 语法/检查通过；帮助文本出现新段落。

- [ ] **Step 4: 提交**

```bash
git add deployments/scripts/deploy-cluster.sh
git commit -m "feat(graceful-overwrite): deploy-cluster 挂点 A —— 覆盖实际将发生时先反序优雅卸载"
```

---

### Task 11: lib-module.sh 挂点 B（新容器场景兜底）

**Files:**
- Modify: `deployments/scripts/lib-module.sh`

**Interfaces:**
- Consumes: 引擎（Task 9）；`cluster_exists`/`get_state`/`warn`；`CUBESTACK_TEARDOWN_DONE`（Task 10 导出）。
- Produces: `teardown_before_overwrite()`（幂等；恒返回 0）。

- [ ] **Step 1: 定义挂点函数**

在 `notify_base_redeploy()` 定义之后插入：

```bash
# ---------------- 优雅覆盖挂点 B(执行 k8s_deploy 之前) ----------------
# 与 notify_base_redeploy 同位的**动作版**: 新容器场景挂点 A(deploy-cluster.sh 预检)因还没有
# SSH 密钥探测不到集群 → 到这里(vm_sshkey/k8s_passwordless 已跑完)密钥就绪, 补齐"优雅覆盖":
# 按安装登记反序卸载已装组件(含 ceph 压轴)。CUBESTACK_TEARDOWN_DONE 防与挂点 A 双跑。
# 恒返回 0(不拦停); 失败仅警告 —— 后续 ceph 安全序与 kubeadm reset 兜底。
teardown_before_overwrite() {
    [ "${CUBESTACK_TEARDOWN_DONE:-0}" = "1" ] && return 0
    [ "$(get_state k8s_deploy)" = "done" ] && return 0   # 断点续跑完成 → 不会执行 → 不涉及(冗余防御)
    local _te="${SCRIPT_DIR}/tools/k8s/cluster-teardown.sh"
    [ -f "${_te}" ] || return 0
    cluster_exists || return 0
    warn "检测到集群已存在 → 先执行「优雅覆盖」: 按安装登记反序卸载已装组件(设计 docs/graceful-overwrite/)"
    bash "${_te}" --uninstall || warn "优雅卸载未完成(继续; ceph 安全序与 k8s 覆盖流程兜底)"
    export CUBESTACK_TEARDOWN_DONE=1
    return 0
}
```

- [ ] **Step 2: 在 run_module 里接线**

`run_module()` 中现有行（第 431 行）：

```bash
    [ "${key}" = "k8s_deploy" ] && notify_base_redeploy
```

其后追加一行：

```bash
    [ "${key}" = "k8s_deploy" ] && teardown_before_overwrite
```

- [ ] **Step 3: 验证**

Run:
```bash
bash -n deployments/scripts/lib-module.sh && bash deployments/scripts/tools/check-modules.sh --quiet && echo CHECK_OK
grep -n "teardown_before_overwrite" deployments/scripts/lib-module.sh
```
Expected: 定义 1 处 + 调用 1 处；check 全绿。

- [ ] **Step 4: 提交**

```bash
git add deployments/scripts/lib-module.sh
git commit -m "feat(graceful-overwrite): lib-module 挂点 B —— k8s_deploy 执行前补齐优雅卸载(新容器场景)"
```

---

### Task 12: check-modules.sh 新增 ⑲（UNINSTALL 声明 ↔ 分支位置）+ 接线夹具

**Files:**
- Modify: `deployments/scripts/tools/check-modules.sh`

**Interfaces:**
- Consumes: 元数据解析 `meta()`（本文件已有）、各模块 `# UNINSTALL: 1`（Task 3-8 已加）、夹具测试（Task 1/9）。
- Produces: ⑲ 校验 —— 声明 `UNINSTALL` 的模块必须有卸载分支、且分支位于 TOGGLE 判断之前；并在 ⑲ 顺手跑夹具测试（防"写了没人跑"—— 记忆教训）。

- [ ] **Step 1: 全文件分母 18→19 + 头部注释**

```bash
sed -i 's|/18\]|/19]|g' deployments/scripts/tools/check-modules.sh
```

头部注释块在 ⑱ 说明行（`#   ⑱ 版本目录 ↔ 档案闭合:...`）后加：

```
#   ⑲ 优雅覆盖: 声明 `# UNINSTALL: 1` 的模块必须含 CUBESTACK_MODULE_ACTION 卸载分支, 且分支
#      位于 TOGGLE 判断之前(开关关闭时也要能卸载旧组件); 并跑 tools/tests/test-cluster-teardown.sh
#      (设计 docs/graceful-overwrite/design.md)
```

同时把 `# CI: .github/workflows/ci-validate.yml ... (全 17 项)` 的 `全 17 项` 改为 `全 19 项`（该行分母历史漂移，顺手校正）。

- [ ] **Step 2: 文件末尾（⑱ 之后、`FAIL` 汇总输出之前）追加 ⑲**

先查看文件末尾实际收尾结构（`[ "${FAIL}" = "0" ]` 汇总打印段），在其**之前**插入：

```bash
# ---------- ⑲ 优雅覆盖: UNINSTALL 元数据 ↔ 卸载分支位置(docs/graceful-overwrite/design.md) ----------
# 约定: 模块头部声明 `# UNINSTALL: 1` 即参与 cluster-teardown.sh 反序卸载; 必须:
#   ① 存在 CUBESTACK_MODULE_ACTION 卸载分支(含 exit 0);
#   ② 分支行号 < 模块内 TOGGLE 变量首次被条件判断的行号 —— 模块被关掉(TOGGLE=false)但集群里
#      装着旧版时, 卸载必须仍然可达(否则永远卸不掉)。
say "[19/19] UNINSTALL 元数据 ↔ 卸载分支位置 ..."
UN_FAIL=0
while IFS= read -r -d '' f; do
    rel="${f#$MODULES_DIR/}"
    [ "$(meta "$f" UNINSTALL)" = "1" ] || continue
    _ml="$(grep -n 'CUBESTACK_MODULE_ACTION' "$f" 2>/dev/null | head -1 | cut -d: -f1)"
    if [ -z "${_ml}" ]; then ck_fail "⑲ ${rel}: 声明 UNINSTALL 但无 CUBESTACK_MODULE_ACTION 卸载分支"; UN_FAIL=1; continue; fi
    if ! grep -q 'exit 0' "$f"; then ck_fail "⑲ ${rel}: 卸载分支缺 exit 0"; UN_FAIL=1; fi
    _tgv="$(meta "$f" TOGGLE)"
    if [ -n "${_tgv}" ]; then
        _tv_re="$(printf '%s' "${_tgv}" | tr ' ' '|')"
        _tl="$(grep -nE "^[[:space:]]*(if|\[)[^#]*\\\$\{(${_tv_re})" "$f" 2>/dev/null | head -1 | cut -d: -f1)"
        if [ -n "${_tl}" ] && [ "${_ml}" -ge "${_tl}" ]; then
            ck_fail "⑲ ${rel}: 卸载分支(行 ${_ml})必须在 TOGGLE 判断(行 ${_tl})之前 —— 开关关闭时也要能卸载"
            UN_FAIL=1
        fi
    fi
done < <(find "${MODULES_DIR}" -name '*.sh' -print0)
# 夹具测试接线(防"写了没人跑"): 优雅覆盖链路夹具(登记合并/拆序/离线 dry-run)
if ! bash "${SCRIPT_DIR}/tests/test-cluster-teardown.sh" >/dev/null 2>&1; then
    ck_fail "⑲ 夹具测试失败: tools/tests/test-cluster-teardown.sh(单独运行查看详情)"
    UN_FAIL=1
fi
[ "${UN_FAIL}" = "0" ] && ok "UNINSTALL 声明与分支位置合规 + 夹具通过"
```

（`SCRIPT_DIR` 为 check-modules.sh 自身脚本目录 = `tools/`，tests 在 `tools/tests/`。）

- [ ] **Step 3: 正反校验**

Run:
```bash
bash deployments/scripts/tools/check-modules.sh && echo ALL_GREEN
```
Expected: 全部 19 项通过。

反证（确认 ⑲ 真在生效）：
```bash
# 反证(证明 ⑲ 真会红; 三臂各验一次; 每臂用 git restore 还原, 不要用 /tmp 备份):
# 臂A(缺分支): 把 25 模块里的 CUBESTACK_MODULE_ACTION 子串替换掉
#   ⚠ 只加后缀改名无效 —— 检查用子串 grep, 后缀会保留子串; 必须去掉子串本身
sed -i 's/CUBESTACK_MODULE_ACTION/ACTION_XMARK/g' deployments/scripts/modules/03_addon/25_cubestack_operator.sh
bash deployments/scripts/tools/check-modules.sh --quiet; RC_A=$?   # 期望非 0 且含 "声明 UNINSTALL 但无 CUBESTACK_MODULE_ACTION 卸载分支"
git restore deployments/scripts/modules/03_addon/25_cubestack_operator.sh
# 臂B(次序): 在 25 模块卸载分支行之前插入一行 TOGGLE 判断(bash -n 仍过)
sed -i '/CUBESTACK_MODULE_ACTION:-install/ i [ "${CUBESTACK_OPERATOR_ENABLED:-false}" = "true" ] || true' deployments/scripts/modules/03_addon/25_cubestack_operator.sh
bash deployments/scripts/tools/check-modules.sh --quiet; RC_B=$?   # 期望非 0 且含 "必须在 TOGGLE 判断(行 ...)之前"
git restore deployments/scripts/modules/03_addon/25_cubestack_operator.sh
# 臂C(夹具接线, 防"写了没人跑"): 临时改夹具断言
sed -i 's/chk "④ 退出码 0" "0"/chk "④ 退出码 0" "9"/' deployments/scripts/tools/tests/test-cluster-teardown.sh
bash deployments/scripts/tools/check-modules.sh --quiet; RC_C=$?   # 期望非 0 且含 "夹具测试失败"
git restore deployments/scripts/tools/tests/test-cluster-teardown.sh
echo "反证退出码: A=${RC_A} B=${RC_B} C=${RC_C}(均期望非 0); 还原后 git status 应 clean"
```
Expected: 反证运行输出 ⑲ 违规、退出码非 0；还原后 `check-modules.sh --quiet` 再次全绿。

（更直接的反证方式二选一即可：① 上述"缺分支"篡改；② 把 `grep -n CUBESTACK_MODULE_ACTION` 分支行手动下移到 TOGGLE 之后 —— 用编辑器临时改再还原。目的只有一个：**亲眼看到 ⑲ 会红**。）

- [ ] **Step 4: 提交**

```bash
git add deployments/scripts/tools/check-modules.sh
git commit -m "feat(graceful-overwrite): check-modules ⑲ —— UNINSTALL 声明/分支位置静态校验 + 夹具接线"
```

---

### Task 13: 文档 —— 用户文档 README.md + 开发规范更新

**Files:**
- Create: `docs/graceful-overwrite/README.md`
- Modify: `docs/scripts-development-spec.md`

**Interfaces:**
- Consumes: 设计（design.md）、已实现行为（Task 1-12）。
- Produces: 面向用户/开发者的操作与规范文档（与实现一致；实现若有微调，以代码为准并回写本文档）。

- [ ] **Step 1: 写 docs/graceful-overwrite/README.md**

内容结构（编写时对照已实现代码逐条核实）：

```markdown
# 优雅覆盖安装(登记 + 反序卸载)

> 设计: design.md  · 实施计划: plan.md  · 落地: 2026-10-11

## 这是什么
`--fresh`(及一切"K8s 覆盖实际将发生"的运行)不再直接推平: 先读**集群内安装登记**, 按
**首装顺序反序**逐个优雅卸载已装组件(先停消费者/CR 级联/helm uninstall), **再**走
ceph 安全序, **最后** K8s 覆盖 —— 取代"暴力卸载+覆盖"。

## 登记(装了什么、什么顺序、什么状态)
- 载体: ConfigMap `cubestack-install-record` @ kube-system(随集群消亡, 无跨代残留)。
- 字段: key / seq(首装序; 重跑不变) / firstInstalledAt / lastSeenAt / status。
- 写入: 各模块安装成功点调用 `record_installed_component`(见 lib-common.sh); 写失败不影响部署。
- 查看: tools/k8s/cluster-teardown.sh --list

## 反序卸载规则(设计 §3.3)
1. 登记 seq 降序;
2. 无登记组件(存量集群降级路径)按模块文件序反排插后; 各模块自带存在性检查, 不存在即跳过;
3. ceph 强制压轴(所有消费者先停才动 ceph);
4. metallb/local_path/ceph_csi 无独立卸载动作(随 K8s 覆盖消亡, 仅登记)。

## 触发时机与两个挂点
- 判定: RUN_STEPS 含 k8s_deploy 且其实状态非 done(即覆盖实际将发生)。
- 挂点 A(deploy-cluster.sh, 计划打印后): 密钥已在 → 直接执行;
- 挂点 B(lib-module.sh, 执行 k8s_deploy 前): 新容器场景(挂点 A 时无密钥, 探测不到)兜底;
- 非交互且无 --yes: 跳过卸载并警告(节点旧集群 reset 前置会再要求 --yes)。

## 手动使用
bash deployments/scripts/tools/k8s/cluster-teardown.sh --list      # 只看: 登记表 + 计划拆序
bash deployments/scripts/tools/k8s/cluster-teardown.sh --uninstall # 手动执行(30s 倒计时)
... --uninstall --yes                                              # 免倒计时

## Ceph 的两种卸载深度
- CEPH_PRE_CLEANUP_EXISTING=true(默认): 完整安全序(停消费者→unmap→删集群, 数据销毁);
- =false(恢复/认领路径): 只停消费者+unmap, 保留数据;
- external 模式(集群内无 CephCluster): 不动(外部 ceph 数据非本安装器资产)。

## 失败语义
单组件失败/超时 → 告警不中止(后续 ceph ⓪ 泛化扫描与 kubeadm reset 兜底); 登记 status 记录
进度, 重跑幂等续跑。退出码: 0=完成(含个别失败告警)。

## 排障
- 登记为空(存量集群): 走探测降级(全量 UNINSTALL 模块反排), 属预期; 覆盖一次后登记自然建立。
- 某组件跳过卸载: 模块内存在性检查未命中(不存在)属正常; 见该组件日志行。
- 手工装过组件但没登记: 会走探测降级被识别(若其模块声明了 UNINSTALL)。
```

- [ ] **Step 2: 更新 docs/scripts-development-spec.md**

① §2.2 模块元数据头的示例块（第 90-100 行代码块）在 `# REQUIRES:` 行后加：

```
# UNINSTALL: 1                # (可选) 声明该模块可被 cluster-teardown 反序优雅卸载
```

并在该节文字说明中补一句：声明 `# UNINSTALL: 1` 的模块必须实现 `CUBESTACK_MODULE_ACTION=uninstall` 卸载分支，且**位于 TOGGLE 跳过检查之前**（check-modules ⑲ 静态校验）；卸载段要求见 `docs/graceful-overwrite/design.md` §3.2。

② §4「新增模块的标准流程(6 步)」在最后一步后补两条：

```
7. (装进集群的组件) 在安装成功点调用 `record_installed_component "<key>"` 登记(优雅覆盖用);
8. (可卸载的组件) 头部声明 `# UNINSTALL: 1` + 实现卸载分支(TOGGLE 检查之前; 幂等/有界/告警不中止),
   供 cluster-teardown 反序优雅卸载 —— 设计见 docs/graceful-overwrite/design.md。
```

- [ ] **Step 3: 验证 + 提交**

Run:
```bash
bash deployments/scripts/tools/check-modules.sh --quiet && echo CHECK_OK
grep -n "UNINSTALL" docs/scripts-development-spec.md | head
```
Expected: check 全绿（文档改动不触发校验）；spec 出现 UNINSTALL 行。

```bash
git add docs/graceful-overwrite/README.md docs/scripts-development-spec.md
git commit -m "docs(graceful-overwrite): 用户文档 + 开发规范(UNINSTALL 元数据/登记约定)"
```

---

### Task 14: 收尾验证 + 同步部署容器（无代码改动，若有修复则单独提交）

**Files:**
- 无（验证与容器同步；如需修复则回到对应任务补 commit）

**Interfaces:**
- Consumes: 全部前序任务产物。
- Produces: 全绿证据 + 容器 b/c 对齐（记忆：容器离线件真身=`/data/offline-files`；`sync-to-container.sh` 同步的是 FILES 清单，注意用 `CONTAINER=` 指明容器）。

- [ ] **Step 1: 全量静态验证**

Run:
```bash
bash deployments/scripts/tools/check-modules.sh && echo ALL_19_GREEN
for f in deployments/scripts/lib-common.sh deployments/scripts/lib-module.sh deployments/scripts/deploy-cluster.sh \
         deployments/scripts/tools/k8s/ceph-cleanup.sh deployments/scripts/tools/k8s/cluster-teardown.sh; do bash -n "$f" || echo "ERR $f"; done
bash deployments/scripts/tools/tests/test-cluster-teardown.sh && echo FIXTURE_GREEN
bash deployments/scripts/tools/tests/test-sync-api-entry.sh 2>&1 | tail -1
bash deployments/scripts/tools/tests/test-kubespray-patches.sh 2>&1 | tail -1
bash deployments/scripts/tools/tests/test-update-kube-vip-addons.sh 2>&1 | tail -1
```
Expected: 19 项全绿；语法全过；夹具全过；既有回归套件不回归（前次运行基线一致）。

- [ ] **Step 2: 离线面镜子测试（可选但推荐）**

`deploy-cluster.sh --list` 与 `cluster-teardown.sh --list` 在**无集群**环境可执行且不报错（只读路径不探测集群/或探测失败降级）：

Run: `bash deployments/scripts/deploy-cluster.sh --list 2>&1 | tail -5; bash deployments/scripts/tools/k8s/cluster-teardown.sh --list 2>&1 | tail -5`
Expected: 均正常结束（涉及集群的探测允许降级提示，不 crash）。

- [ ] **Step 3: 同步部署容器**

按仓库既有流程（记忆 container-offline-files-live-source / sync-to-container）：
```bash
# 先确认部署容器名(勿凭空猜): docker ps --format '{{.Names}}' | grep -i cubestack
CONTAINER=<上面查到的部署容器名> bash deployments/scripts/tools/sync-to-container.sh
# 按脚本输出确认本次改动的文件已全部同步(脚本按 FILES[] 清单推送, 逐条核对本计划涉及的文件)
```
Expected: 输出中本计划全部文件（lib-common/lib-module/deploy-cluster/ceph-cleanup/cluster-teardown/各模块/测试/文档）均为已同步。

- [ ] **Step 4: 汇总报告**

给用户汇总：任务清单完成状态、全绿证据、容器同步结果、**真机验证计划**（下轮实机覆盖时按 design.md §3.5 三段：同容器 --fresh / 新容器默认全量 / 无登记存量集群），以及未验证项（真机行为）的诚实声明。

---

## Self-Review（写计划后的自查记录）

- **Spec 覆盖**：design.md §3.1→Task 1；§3.2→Task 3-8（ceph-cleanup 配套→Task 2）；§3.3→Task 9；§3.4→Task 10/11；§3.5→Task 12/13/14；§4 边界→各卸载段的 PRE_CLEANUP/external/告警不中止均已落到代码。✅
- **占位符扫描**：`...(原第 xx 行内容原样)...` 仅为"纯搬移"标注（Task 2/5），执行者打开文件即可逐行核对；无 TBD/TODO。✅
- **类型/命名一致性**：`record_installed_component`（Task1）= 各模块调用名；`CUBESTACK_MODULE_ACTION`（Task3-9 一致）；`RECORD_CM_NS/NAME`（Task1 定义）vs 引擎 `CM_NS/CM_NAME`（Task9 独立定义，值一致 `kube-system`/`cubestack-install-record`）；`compute_order` 输出三列 `key\t来源\t脚本`（Task9 定义 + 测试解析 `cut -f1/-f2` 一致）；`CUBESTACK_TEARDOWN_DONE`（Task10 导出 / Task11 消费）。✅
- **任务顺序**：③④ 组测试依赖 Task 3-8 的 UNINSTALL 声明 → 测试扩展放 Task 9 且注明顺序不可换。✅
