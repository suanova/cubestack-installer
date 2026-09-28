# kubespray v2.32.0 升级 + 插件集成 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 vendored kubespray 从 v2.28.0 升到 v2.32.0(并让"下次升级"可复用),三个既有插件按"能交上游就交上游"落地,新增 LVP/NFD 接线(默认关),镜像全程走 CI→Harbor→tar。

**Architecture:** 树本体 = 纯净上游 tag + 一层**文件化补丁**(`cubestack-patches/*.patch`)+ 幂等重放脚本 + 自检;升级流程本身固化成 `docs/kubespray-upgrade.md`(与版本无关)+ `cubestack-kubespray-upgrade.sh <tag>`。kube-vip 保持"渲染器自持 + 单写入者契约",multus 保持自持 thick(只钉 tag),metallb 继续用上游 role(竞态修复进补丁层)。LVP/NFD 只做接线,开关默认 false。

**Tech Stack:** bash + ansible(vendored kubespray)/ python3(jinja2 渲染器)/ patch(1) / docker+skopeo(Harbor 镜像管道)/ GitHub Actions(CI 同步)

**Spec:** `docs/kubespray-v2.32/design.md`(所有决策 D0–D8、现状证据、11 处改动处置表都在那里;本计划只讲**怎么做**,不重复论证)

## Global Constraints

- 目标版本(逐字,勿改): kubespray **v2.32.0**、k8s **v1.35.8**、calico **v3.31.7**、etcd **v3.6.14**、multus **4.2.2**(我们钉 `v4.2.2-thick`)、metallb **v0.13.9**、kube-vip **v1.0.3**、LVP **2.5.0**、NFD **0.19.0**、ansible(经上游 requirements.txt)**12.3.0**。
- 基线分支:`feat/kubespray-v2.32`(基于 api-ha 线;api-ha 合并后再 rebase 到 main)。工作区必须干净再开始每个任务。
- **commit 不以 `Co-Authored-By:` 结尾**(用户明令,见记忆 `no-coauthor-trailer`)。
- **镜像只在"能连 Harbor 的机器"上操作**;部署机不直连 docker.io/上游(用户明令)。所有镜像先经 `images.manifest` → CI/Harbor → `harbor-save-images.sh` → `offline-files/*.tar`。
- `PRELOAD_IMAGE_PATTERNS` 有**四处副本**(`cluster.conf`、`cluster.conf.example`、`tools/offline/trim-offline-files.sh`、`kubespray/cubestack-offline.sh` 内嵌默认),改动必须四处逐字节一致 —— `check-modules.sh` 第 ⑭ 项会断言。
- **不改**已定的策略:kube-vip `kube_vip_enabled` 恒 false(单一写入者)、`kube_vip_services_enabled=false`、`kube_vip_lb_enable=false`、`KUBE_VIP_CP_DETECT` 默认 true;multus 自持(不用上游 role);LVP/NFD 不自研模块。
- 每个任务的验证命令必须**真的跑**,贴出实际输出;不通过不许提交。

---

## 文件结构(先定边界)

| 文件 | 职责 | 动作 |
|---|---|---|
| `deployments/kubespray/cubestack-patches/*.patch` | 我们对上游的每处改动(带元数据头) | 新建 |
| `deployments/kubespray/cubestack-patches/README.md` | 逐条: 改了什么/为什么/上游吸收判据/上游化建议 | 新建 |
| `deployments/kubespray/cubestack-patch-apply.sh` | 幂等重放(`--apply/--check/--check-retired/--list`) | 新建 |
| `deployments/kubespray/cubestack-kubespray-upgrade.sh` | 通用升级入口(取树/备份/换树/调 apply/打印下一步;`--root` 支持 /tmp 演练) | 新建 |
| `docs/kubespray-upgrade.md` | **稳定路径**: SOP + 历次升级记录 | 新建 |
| `deployments/scripts/tools/tests/test-kubespray-patches.sh` | 补丁层三态 + 退役判定的离线回归 | 新建 |
| `deployments/scripts/tools/tests/test-render-kube-vip.sh` | 渲染器对 v2.32 模板的离线断言 | 新建 |
| `deployments/scripts/tools/k8s/render-kube-vip-manifest.py` | 渲染器: 支持 `version()` test / 新变量 | 改 |
| `deployments/scripts/tools/check-modules.sh` | 新增 ⑮(补丁在位)/⑯(版本钉子 vs 上游表一致) | 改 |
| `deployments/config/cluster.conf` + `.example` | 版本组、LVP/NFD 开关与版本、PRELOAD 副本 | 改 |
| `deployments/config/images.manifest` | kube-vip/multus tag;LVP/NFD 登记 | 改 |
| `deployments/cubestack-addon/multus/multus-daemonset-thick.yml` + `CUBESTACK.md` | 两处硬编码镜像 ref + 偏离说明 | 改 |
| `deployments/kubespray/kubespray/**` | 树本体(整棵替换为 v2.32.0) | 替换 |
| `docs/kubespray-v2.32/manual-download-list.md` | 缺口清单(交付给用户手动下载) | 新建 |

---

# 子项① 升级脚手架与补丁层(T1–T6)

### Task 1: 把现有 11 处改动导出成补丁层

**Files:**
- Create: `deployments/kubespray/cubestack-patches/README.md`、`deployments/kubespray/cubestack-patches/0N-<name>.patch`(N 与 spec §2.2 表一致)
- 依赖: 纯净 v2.28.0 树(若 `/tmp/kubespray-2.28` 已被清理, 先 `git clone --depth 1 --branch v2.28.0 https://github.com/kubernetes-sigs/kubespray.git /tmp/kubespray-2.28`;不可达则跳过本任务的最后一步验证, 在 PR 说明里标注)

**Interfaces:**
- Produces: 补丁文件命名 `<N>-<slug>.patch`, N = spec §2.2 的行号(如 `04-download-container-mkdir.patch`);每个文件**首部必须是**元数据注释块,格式:

```
# patch: 10-metallb-crd-race.patch
# 目标: roles/kubernetes-apps/metallb/tasks/main.yml
# 加入: 2026-09-28(随 v2.28.0 → v2.32.0 迁移)
# 原因: <一句话;写清丢了会怎样>
# 上游吸收判据: <在新上游树上怎么判断可以删>
# 上游化: 建议提 PR / 不提(写明原因)
# ------------------------------------------------------------
--- a/roles/kubernetes-apps/metallb/tasks/main.yml
+++ b/roles/kubernetes-apps/metallb/tasks/main.yml
```

- [ ] **Step 1: 生成 7 个"保留为补丁"文件的 diff**

```bash
cd /home/supperadm/cubestack-installer/deployments/kubespray
mkdir -p cubestack-patches
gen() {   # <编号-slug> <仓库内相对路径>
  diff -u --label "a/$2" --label "b/$2" "/tmp/kubespray-2.28/$2" "kubespray/$2" > "cubestack-patches/$1" || true
  echo "生成 cubestack-patches/$1"
}
gen 01-download-container-mkdir.patch        roles/download/tasks/download_container.yml
gen 02-client-kubeconfig-mode.patch          roles/kubernetes/client/tasks/main.yml
gen 03-kubeadm-fix-apiserver-stat.patch      roles/kubernetes/control-plane/tasks/kubeadm-fix-apiserver.yml
gen 04-kubeadm-setup-san.patch               roles/kubernetes/control-plane/tasks/kubeadm-setup.yml
gen 05-apps-meta-registry-order.patch        roles/kubernetes-apps/meta/main.yml
gen 06-metallb-crd-race.patch                roles/kubernetes-apps/metallb/tasks/main.yml
gen 07-download-yml-k8s-cluster-group.patch  roles/kubespray_defaults/defaults/main/download.yml
ls -l cubestack-patches/
```
预期: 生成 7 个 `.patch`(编号与 spec §2.2 表一一对应,上面这 7 个名字就是最终命名)。

- [ ] **Step 2: 给每个补丁加元数据头**(按上面 Interfaces 的格式逐个人工填写,原因/吸收判据照抄 spec §2.2 与 §3.5)

- [ ] **Step 3: 验证补丁与当前树一致(反打必须干净)**

```bash
cd /home/supperadm/cubestack-installer/deployments/kubespray/kubespray
for p in ../cubestack-patches/*.patch; do
  patch -p1 -R --dry-run < "$p" >/dev/null 2>&1 && echo "✅ 可反打(与现状一致): $(basename "$p")" || echo "❌ 对不上: $(basename "$p")"
done
```
预期: 7 个全部 ✅(反打干净 = 补丁描述的正是"现状 − 纯净树"的差)。

- [ ] **Step 4: 写 `cubestack-patches/README.md`**
内容: 表格(补丁 / 目标文件 / 一句话原因 / 上游吸收判据 / 上游化),外加三行说明:①机制 A(cluster.yml/scale.yml 的 import 行 + `patch-playbooks/` 由 `cubestack-offline.sh` 内嵌重建,**不在本目录**);②已作废: `ansible_version.yml`(v2.32 要求 ≥2.19,我们的 2.17→2.18 不再需要);③手工项: `kubeadm-secondary.yml`(见 Task 5)。

- [ ] **Step 5: 提交**

```bash
cd /home/supperadm/cubestack-installer
git add deployments/kubespray/cubestack-patches
git commit -m "chore(kubespray): 固化补丁层 —— 7 处上游改动导出为带元数据的 patch + README"
```

### Task 2: `cubestack-patch-apply.sh` 幂等重放器 + 离线回归

**Files:**
- Create: `deployments/kubespray/cubestack-patch-apply.sh`、`deployments/scripts/tools/tests/test-kubespray-patches.sh`

**Interfaces:**
- Produces: `cubestack-patch-apply.sh [--root <kubespray 树根>] {--apply|--check|--check-retired|--list}`;退出码 0=成功/全部在位, 1=有冲突或缺失;**输出三态** `APPLY/SKIP/CONFLICT`(每行一个补丁)。

- [ ] **Step 1: 先写失败的测试(fixture 三态 + 退役判定)**

`deployments/scripts/tools/tests/test-kubespray-patches.sh`(骨架,按仓库既有 tests 风格):

```bash
#!/bin/bash
# 离线回归: cubestack-patch-apply.sh 的三态与退役判定(不联网, 用 fixture 树)
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../../../.." && pwd)"
APPLY="${REPO_ROOT}/deployments/kubespray/cubestack-patch-apply.sh"
PASS=0; FAIL=0
ok(){ echo "  ok  $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

mk_fixture() {   # $1=目标目录; 造一个"纯净树 + 我们的补丁"的最小 fixture
    local d="$1"; rm -rf "$d"; mkdir -p "$d/target"
    printf 'line1\nline2\n' > "$d/target/f.txt"
    mkdir -p "$d/patches"
    printf '# patch: 01-demo.patch\n# 目标: target/f.txt\n--- a/target/f.txt\n+++ b/target/f.txt\n@@ -1,2 +1,2 @@\n line1\n-line2\n+line2-changed\n' > "$d/patches/01-demo.patch"
}

# 未打 → APPLY
mk_fixture /tmp/pt-unapplied
out="$("$APPLY" --root /tmp/pt-unapplied --apply 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q 'APPLY.*01-demo' <<<"$out" && ok "未打 → APPLY, 退出 0" || bad "未打场景: rc=$rc out=$out"
grep -q 'line2-changed' /tmp/pt-unapplied/target/f.txt && ok "内容确实变了" || bad "内容没变"

# 已打 → SKIP
out="$("$APPLY" --root /tmp/pt-unapplied --apply 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q 'SKIP.*01-demo' <<<"$out" && ok "已打 → SKIP(幂等)" || bad "幂等场景: rc=$rc out=$out"

# 冲突 → CONFLICT + 非 0
mk_fixture /tmp/pt-conflict
printf 'line1\nline2-DIFFERENT\n' > /tmp/pt-conflict/target/f.txt
out="$("$APPLY" --root /tmp/pt-conflict --apply 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'CONFLICT.*01-demo' <<<"$out" && ok "冲突 → CONFLICT + 非 0" || bad "冲突场景: rc=$rc out=$out"

# 退役: 上游已等于"打过之后"的样子 → 该补丁应被列为可退休
mk_fixture /tmp/pt-retired
printf 'line1\nline2-changed\n' > /tmp/pt-retired/target/f.txt
out="$("$APPLY" --root /tmp/pt-retired --check-retired 2>&1)"
grep -q 'RETIRE.*01-demo' <<<"$out" && ok "已被上游吸收 → RETIRE" || bad "退役场景: out=$out"

echo "---------------------------------------------"
[ "$FAIL" = 0 ] && { echo "✅ 全部 ${PASS} 项通过"; exit 0; } || { echo "❌ ${FAIL} 项失败"; exit 1; }
```

- [ ] **Step 2: 跑它,确认失败**

Run: `bash deployments/scripts/tools/tests/test-kubespray-patches.sh`
预期: 报错/FAIL(脚本尚不存在)。

- [ ] **Step 3: 实现 `cubestack-patch-apply.sh`**

要点(照抄进脚本,不要"类似 Task N"):
```bash
#!/bin/bash
# 幂等重放 cubestack-patches/*.patch 到 kubespray 树。
# 三态: APPLY(新打) / SKIP(已在位) / CONFLICT(打不上, 点名文件并退出非 0)
# 退役判定(--check-retired): 若在**纯净树**上反向应用成功, 说明上游已等于"我们打完的样子" → RETIRE
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SELF_DIR}/kubespray"; PATCH_DIR="${SELF_DIR}/cubestack-patches"
MODE="--check"
while [ $# -gt 0 ]; do case "$1" in --root) ROOT="$2"; shift 2;; --apply|--check|--check-retired|--list) MODE="$1"; shift;; *) echo "未知参数: $1" >&2; exit 2;; esac; done
rc=0
for p in "${PATCH_DIR}"/*.patch; do
    name="$(basename "$p")"
    if [ "${MODE}" = "--list" ]; then echo "  ${name}"; continue; fi
    # 在位判定: 反向应用能干净过 → 树已是"打过之后"
    if (cd "${ROOT}" && patch -p1 -R --dry-run -s -f < "${p}" >/dev/null 2>&1); then
        if [ "${MODE}" = "--check-retired" ]; then echo "  RETIRE  ${name}"; else [ "${MODE}" = "--check" ] || echo "  SKIP    ${name}"; fi
        continue
    fi
    if [ "${MODE}" = "--check" ]; then echo "  MISSING ${name}"; rc=1; continue; fi
    if [ "${MODE}" = "--check-retired" ]; then echo "  KEEP    ${name}"; continue; fi
    if (cd "${ROOT}" && patch -p1 -s -f < "${p}" >/dev/null 2>&1); then echo "  APPLY   ${name}"
    else echo "  CONFLICT ${name} → $(grep -m1 '^# 目标:' "$p" | sed 's/^# 目标: //')"; rc=1; fi
done
exit "${rc}"
```
⚠ 实现时**注意**: `--check` 模式下 `SKIP` 不打印(只要静默通过),`MISSING` 要打印;`--apply` 下冲突要能看到"哪个文件"。

- [ ] **Step 4: 跑测试,全绿**

Run: `bash deployments/scripts/tools/tests/test-kubespray-patches.sh`
预期: `✅ 全部 5 项通过`(5 = APPLY/内容变/SKIP/冲突/RETIRE)。

- [ ] **Step 5: 在真树上验证并存**

```bash
cd /home/supperadm/cubestack-installer/deployments/kubespray
bash cubestack-patch-apply.sh --check; echo "check rc=$?"     # 期望 0(7 处都在位)
bash cubestack-patch-apply.sh --check-retired                  # 期望 7 个 KEEP
```
- [ ] **Step 6: 提交**

```bash
git add deployments/kubespray/cubestack-patch-apply.sh deployments/scripts/tools/tests/test-kubespray-patches.sh
git commit -m "feat(kubespray): 补丁幂等重放器(三态 + 退役判定) + 离线回归"
```

### Task 3: 通用升级入口 `cubestack-kubespray-upgrade.sh`(支持 /tmp 演练)

**Files:**
- Create: `deployments/kubespray/cubestack-kubespray-upgrade.sh`

**Interfaces:**
- Produces: `cubestack-kubespray-upgrade.sh <tag> [--root DIR] [--tree-src DIR] [--no-fetch]`;`--root` 默认仓库内树;打印 9 步 SOP 的进度与"下一步该人做什么";**任何破坏性动作前先打 tag 备份**。

- [ ] **Step 1: 实现脚本**(核心逻辑,按此写)

```
1) 前置: git 工作区干净?  → 否则退出
2) 备份: git tag "kubespray-<当前galaxy.yml版本>-cubestack" (已存在则跳过); 记 tree hash
3) 取树: --tree-src 给了就用它; 否则 git clone --depth 1 --branch <tag> 到临时目录
         (失败 → 提示"本机不可达, 改用 --tree-src 由联网机取后拷入")
4) 核验: galaxy.yml 版本 == <tag>; checksums.yml 里必须有 cluster.conf 当前 K8S_VERSION(去掉 v 前缀)
         → 没有就**停下**并提示该 tag 支持的 k8s 版本范围
5) 换树: 删除 root/kubespray 下除 inventory/ 之外的内容(保留 inventory), rsync 新树进来,
         排除 .github/.gitlab-ci/.gitattributes/.gitignore/.gitmodules
6) 重放: 调 cubestack-patch-apply.sh --root <root>/kubespray --apply → 三态输出;
         CONFLICT 即**停下**(退出 1)并打印"人工处置后, 更新对应 .patch 再重跑"
7) 退役: cubestack-patch-apply.sh --check-retired → 打印 RETIRE 清单(人工决定删哪些)
8) 打印后续人工步骤: 版本面核对(⑯)/渲染器对拍/离线缺口/回归(指向 docs/kubespray-upgrade.md §8)
```

- [ ] **Step 2: 在 /tmp 演练一次(v2.30.0 靶子)**

```bash
cd /home/supperadm/cubestack-installer/deployments/kubespray
rm -rf /tmp/up-rehearsal && mkdir -p /tmp/up-rehearsal && cp -a kubespray /tmp/up-rehearsal/kubespray
bash cubestack-kubespray-upgrade.sh v2.30.0 --root /tmp/up-rehearsal --tree-src /tmp/kubespray-2.30 2>&1 | tail -25
echo "rc=$?"
```
预期(与 spec §2.2 dry-run 一致): 换树成功;`APPLY` 7 处里 **5 处成功**、`CONFLICT` **2 处**(`kubeadm-secondary`、以及 `download.yml`/`cluster.yml` 中实际冲突者),脚本**停下并点名文件**;仓库内树未被触碰(`git -C /home/supperadm/cubestack-installer status --short` 只有新文件)。

- [ ] **Step 3: 二次演练(v2.31.0)+ 差异记录**
同 Step 2 换成 `v2.31.0`(需先 `git clone --depth 1 --branch v2.31.0 … /tmp/kubespray-2.31`);把两次演练的"冲突清单/退休清单"差异写进 `docs/kubespray-upgrade.md` 的 §演练记录 —— **这就是"下次升级不用人肉记忆"的验收证据**。

- [ ] **Step 4: 提交**

```bash
git add deployments/kubespray/cubestack-kubespray-upgrade.sh
git commit -m "feat(kubespray): 通用升级入口(取树/备份/换树/重放/退休, 支持 /tmp 演练) + v2.30/v2.31 演练记录"
```

### Task 4: 换真树到 v2.32.0 + 处置冲突

**Files:**
- Modify: `deployments/kubespray/kubespray/**`(整树)、`deployments/kubespray/cubestack-patches/*.patch`(冲突者更新)

- [ ] **Step 1: 拉纯净 v2.32.0 树**(本机可达时;不可达则由联网机取后拷入, 用 `--tree-src`)

```bash
[ -d /tmp/kubespray-2.32 ] || git clone --depth 1 --branch v2.32.0 https://github.com/kubernetes-sigs/kubespray.git /tmp/kubespray-2.32
grep -m1 'version:' /tmp/kubespray-2.32/galaxy.yml
```
预期: `version: 2.32.0`。

- [ ] **Step 2: 跑升级入口(真树)**

```bash
cd /home/supperadm/cubestack-installer/deployments/kubespray
bash cubestack-kubespray-upgrade.sh v2.32.0 --tree-src /tmp/kubespray-2.32 2>&1 | tail -30
```
预期: 停在 CONFLICT —— 预计 **1 处必须人工**(`kubeadm-secondary.yml`,6 处 hunk)± 若干。逐个记录。

- [ ] **Step 3: 人工处置 `kubeadm-secondary.yml`(我们的意图照着重做)**
意图(照抄 spec 与现状):**"是否已 join 成功"要以 `admin.conf` 是否存在为准, 不只看 kubeadm 的标记文件** —— 在文件顶部加一个 stat 任务, 并把 4 处 gate 改成 `… or not admin_conf_stat.stat.exists`:

```yaml
- name: Check if admin.conf exists (indicating successful join)
  stat:
    path: "{{ kube_config_dir }}/admin.conf"
    get_attributes: false
    get_checksum: false
    get_mime: false
  register: admin_conf_stat
```
把 v2.32 版文件中所有 `- not kubeadm_already_run.stat.exists` 与 `- kubeadm_already_run is not defined or not kubeadm_already_run.stat.exists` 的门,按语义改成带 `or not admin_conf_stat.stat.exists`(逐处核:v2.32 若有重构过的新写法, 以"等价语义"为准, 并在补丁元数据头里注明差异)。
验证: `cd kubespray && bash ../cubestack-patch-apply.sh --check`(更新完 patch 后应全绿) + `ansible-playbook --syntax-check` 不需要(树不是 play 入口),改跑 `bash -n` 不适用 → **验证用 YAML 解析**:`python3 -c "import yaml,sys;yaml.safe_load(open('roles/kubernetes/control-plane/tasks/kubeadm-secondary.yml'))"`。

- [ ] **Step 4: 其余冲突逐个处置并回写 `.patch`**(每个都要在元数据头补一行 `# v2.32 冲突处置: <做了什么>`)

- [ ] **Step 5: 树 diff 复核(只应剩有意补丁)**

```bash
cd /home/supperadm/cubestack-installer/deployments/kubespray
diff -rq --exclude=.git kubespray /tmp/kubespray-2.32 | grep -v '^Only in kubespray: \(inventory\|cubestack-patches\|\.venv\)' | head -20
```
预期: 只剩我们的 7 个补丁文件 + `kubeadm-secondary.yml` 等人工项,且**没有**"只在纯净树里有"的意外删除(除 dotfile)。

- [ ] **Step 6: 提交**

```bash
git add -A deployments/kubespray
git commit -m "chore(kubespray): 树升级 v2.28.0 → v2.32.0(补丁全部重放/重写, kubeadm-secondary 手工重做)"
```

### Task 5: 稳定文档 + 补丁自检进 check-modules

**Files:**
- Create: `docs/kubespray-upgrade.md`
- Modify: `deployments/scripts/tools/check-modules.sh`(新增 ⑮;项数 14 → 15)

- [ ] **Step 1: 写 `docs/kubespray-upgrade.md`**
结构: §1 SOP(照抄 spec §3.4 的 9 步,补上每条的实际命令) / §2 历次升级记录(首条 = 本次: v2.28.0→v2.32.0、k8s 1.32.5→1.35.8、冲突与处置、踩的坑) / §3 待上游化清单(首批 metallb 4 处) / §4 演练记录(v2.30.0/v2.31.0) / §5 **回退**(旧树 tag `kubespray-v2.28.0-cubestack` 恢复 + 补丁层整层不应用 + ⚠ k8s 版本变量**不能单独回退**到 1.32:v2.32 表里没有 1.32, 回退必须连同树一起)。

- [ ] **Step 2: check-modules 新增 ⑮(补丁在位)**

在 `check-modules.sh` 现有第 ⑭ 项之后插入(命名与风格照 ⑭):
```bash
# ---------- ⑮ kubespray 补丁在位(树被换/被覆盖过就能查出来) ----------
say "[15/15] kubespray 补丁在位 ..."
if [ -x "${REPO_ROOT}/deployments/kubespray/cubestack-patch-apply.sh" ]; then
    if _out="$(bash "${REPO_ROOT}/deployments/kubespray/cubestack-patch-apply.sh" --check 2>&1)"; then
        ok "  ⑮ kubespray 补丁全部在位"
    else
        ck_fail "⑮ kubespray 补丁缺失/不匹配:" "$(printf '%s' "${_out}" | grep -E 'MISSING|CONFLICT' | head -5)"
    fi
else
    warn "  跳过 ⑮(未找到 cubestack-patch-apply.sh)"
fi
```
同时把文件里所有 `[N/14]` 文案改成 `[N/15]`(注意: ⑭ 的标题行也是 `[14/14]` → 变 `[14/15]`)。

- [ ] **Step 3: 验证**

```bash
bash deployments/scripts/tools/check-modules.sh 2>&1 | tail -6
```
预期: ⑮ 绿;全脚本只剩**既有** ⑪-B 红项(main 上同样红);退出码 1(与现状一致)。

- [ ] **Step 4: 提交**

```bash
git add docs/kubespray-upgrade.md deployments/scripts/tools/check-modules.sh
git commit -m "docs+check(kubespray): 升级 SOP/记录文档 + check-modules ⑮(补丁在位自检)"
```

---

# 子项② 三个插件(T6–T8)

### Task 6: kube-vip → v1.0.3(渲染器适配 + 离线断言)

**Files:**
- Modify: `deployments/scripts/tools/k8s/render-kube-vip-manifest.py`、`deployments/config/cluster.conf`、`deployments/config/images.manifest`、`deployments/scripts/modules/02_k8s/09_kube_vip.sh`(兜底默认值)
- Create: `deployments/scripts/tools/tests/test-render-kube-vip.sh`

**Interfaces:**
- Produces: 渲染器新增 `--kube-vip-version` 语义(默认 `1.0.3`, 同时驱动 `vip_subnet` 分支)+ 新增变量 `kube_vip_metrics_enabled=False`;`jinja2` 环境注册 `version` test。

- [ ] **Step 1: 先写失败的渲染断言**

`deployments/scripts/tools/tests/test-render-kube-vip.sh`:
```bash
#!/bin/bash
# 离线断言: 渲染器能吃下 v2.32 的 kube-vip 模板, 并对 1.0.3 发 vip_subnet
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "${SELF_DIR}/../../../.." && pwd)"
R="${ROOT}/deployments/scripts/tools/k8s/render-kube-vip-manifest.py"
T="${ROOT}/deployments/kubespray/kubespray/roles/kubernetes/node/templates/manifests/kube-vip.manifest.j2"
out="$(python3 "$R" --nodename n1 --vip 10.0.0.9 --template "$T" --image-tag v1.0.3 2>&1)"; rc=$?
[ "$rc" = 0 ] || { echo "  FAIL 渲染失败: $out"; exit 1; }
grep -q 'name: vip_subnet' <<<"$out" && echo "  ok  env = vip_subnet" || { echo "  FAIL 没有 vip_subnet"; exit 1; }
! grep -qE 'name: vip_cidr$' <<<"$out" && echo "  ok  不再发 vip_cidr" || { echo "  FAIL 仍在发 vip_cidr"; exit 1; }
grep -q 'nodename' <<<"$out" && echo "  ok  vip_nodename 在位" || { echo "  FAIL 缺 vip_nodename"; exit 1; }
out2="$(python3 "$R" --nodename n2 --vip 10.0.0.9 --template "$T" --image-tag v1.0.3 2>&1)"
[ "$(grep -c 'value: "n1"' <<<"$out")" = 1 ] && [ "$(grep -c 'value: "n2"' <<<"$out2")" = 1 ] && echo "  ok  逐节点渲染不同(防脑裂)" || { echo "  FAIL 逐节点渲染异常"; exit 1; }
echo "✅ 渲染断言全过"
```

- [ ] **Step 2: 跑,确认失败**
Run: `bash deployments/scripts/tools/tests/test-render-kube-vip.sh`
预期: FAIL(模板里 `is version(...)` 未定义 → jinja2 报错,以及/或 `vip_subnet` 缺失)。

- [ ] **Step 3: 改渲染器(具体改动)**
1. 注册 ansible 同语义的 `version` test(模板只用 `>=`/`<` 两种):
```python
def ansible_version_test(value, other, operator="=="):
    def norm(s):
        return [int(p) if p.isdigit() else p for p in str(s).lstrip("v").split(".")]
    a, b = norm(value), norm(other)
    return {"<": a < b, "<=": a <= b, "==": a == b,
            ">=": a >= b, ">": a > b, "!=": a != b}[operator]
env.tests["version"] = ansible_version_test
```
2. `variables` 增加三项:
```python
"kube_vip_version": args.image_tag.lstrip("v"),   # 模板用它做 version() 比较(需纯数字形态)
"kube_vip_metrics_enabled": False,                # 与 D1/D4 一致: 不开指标端口(可观测栈已移除)
"kube_vip_bgp_sourceip": "", "kube_vip_bgp_sourceif": "",   # v2.32 模板用 default('', true), 显式给空更稳
```
3. `--image-tag` 默认值 `v0.8.9` → **`v1.0.3`**;同时把渲染器头的注释里版本示例同步。

- [ ] **Step 4: 跑测试 → 全绿**;若 StrictUndefined 报其它缺变量,**逐个补进 variables**(这是模板演进时的常规动作, 补完重跑)。

- [ ] **Step 5: 配置与镜像 tag 三处一起改**

```bash
cd /home/supperadm/cubestack-installer
sed -i 's|KUBE_VIP_VERSION="${KUBE_VIP_VERSION:-v0.8.9}"|KUBE_VIP_VERSION="${KUBE_VIP_VERSION:-v1.0.3}"|' deployments/config/cluster.conf deployments/config/cluster.conf.example
grep -rn 'v0.8.9' deployments/config/cluster.conf deployments/config/cluster.conf.example deployments/config/images.manifest deployments/scripts/modules/02_k8s/09_kube_vip.sh deployments/scripts/tools/k8s/render-kube-vip-manifest.py
```
预期: 最后一条只剩**注释里的历史说明**(若有)或空;任何**活值**残留都要改掉。

- [ ] **Step 6: 提交**

```bash
git add deployments/scripts/tools/k8s/render-kube-vip-manifest.py deployments/scripts/tools/tests/test-render-kube-vip.sh deployments/config/cluster.conf deployments/config/cluster.conf.example deployments/config/images.manifest deployments/scripts/modules/02_k8s/09_kube_vip.sh
git commit -m "feat(kube-vip): 升 v1.0.3 并适配 v2.32 模板(vip_subnet/version test/metrics 变量)+ 离线渲染断言"
```

### Task 7: multus 钉 `v4.2.2-thick`

**Files:**
- Modify: `deployments/config/cluster.conf` / `.example`(MULTUS_IMAGE_TAG)、`deployments/config/images.manifest`、`deployments/cubestack-addon/multus/multus-daemonset-thick.yml`(两处 image)、`deployments/cubestack-addon/multus/CUBESTACK.md`

- [ ] **Step 1: 四处改动**

```bash
cd /home/supperadm/cubestack-installer
sed -i 's|MULTUS_IMAGE_TAG="${MULTUS_IMAGE_TAG:-snapshot-thick}"|MULTUS_IMAGE_TAG="${MULTUS_IMAGE_TAG:-v4.2.2-thick}"|' deployments/config/cluster.conf deployments/config/cluster.conf.example
sed -i 's|k8snetworkplumbingwg/multus-cni:snapshot-thick|k8snetworkplumbingwg/multus-cni:v4.2.2-thick|g' deployments/cubestack-addon/multus/multus-daemonset-thick.yml
grep -rn 'snapshot-thick' deployments/ | grep -v '\.git'   # 期望: 只剩 CUBESTACK.md 里"历史"字样(若有)
```

- [ ] **Step 2: CUBESTACK.md 偏离表加两行**
①"tag 钉 `v4.2.2-thick`(官方 thick quickstart 默认是浮动 `snapshot-thick`——内容会变,与仓库'防漂移'原则冲突)";②"不用 kubespray 的 multus role:上游是 thin 模式、不建 NAD、不等 CRD Established、资源 100m/90Mi 硬顶(v2.32 仍是),我们 thick + NAD + 等待 + 128Mi/512Mi"。

- [ ] **Step 3: 验证**

```bash
bash deployments/scripts/tools/images/check-image-manifest.sh 2>&1 | tail -3
grep -n 'multus' deployments/config/images.manifest
```
预期: 静态校验通过;manifest 里 multus 的 tag 展开为 `v4.2.2-thick`。

- [ ] **Step 4: 提交**

```bash
git add deployments/config/cluster.conf deployments/config/cluster.conf.example deployments/config/images.manifest deployments/cubestack-addon/multus/
git commit -m "chore(multus): 镜像 tag 由浮动 snapshot-thick 钉到 v4.2.2-thick(与上游 4.2.2 同版本, 变体 thick)"
```

### Task 8: metallb 补丁标注"待上游化"

**Files:**
- Modify: `deployments/kubespray/cubestack-patches/*metallb*.patch`(元数据头)、`docs/kubespray-upgrade.md` §3

- [ ] **Step 1: 在 metallb 补丁头补两行**

```
# 上游吸收判据: roles/kubernetes-apps/metallb/tasks/main.yml 里出现 "Established" 等待或 apply retries
# 上游化: ★ 建议提 PR(裸金属新集群首装竞态是通病); 合入后从本目录删除, 并记入 docs/kubespray-upgrade.md
```
- [ ] **Step 2: 把"首批上游化 = metallb 4 处"写进 `docs/kubespray-upgrade.md` §3**
- [ ] **Step 3: 提交**

```bash
git add deployments/kubespray/cubestack-patches docs/kubespray-upgrade.md
git commit -m "docs(kubespray): metallb 竞态补丁标注上游吸收判据与上游化建议"
```

---

# 子项③ LVP/NFD 接线(T9–T10)

### Task 9: 开关与 inventory 同步(默认 false)

**Files:**
- Modify: `deployments/config/cluster.conf` / `.example`、`deployments/scripts/tools/k8s/sync-addons-config.sh`

**Interfaces:**
- Produces: `cluster.conf` 新增 `LOCAL_VOLUME_PROVISIONER_ENABLED`(默认 `false`)、`NFD_ENABLED`(默认 `false`)、`LOCAL_VOLUME_PROVISIONER_VERSION="2.5.0"`、`NFD_VERSION="0.19.0"`;`sync-addons-config.sh` 写出 `local_volume_provisioner_enabled` / `node_feature_discovery_enabled`。

- [ ] **Step 1: 加开关(注意 TOGGLE 声明区惯例: `.example` 里必须声明,否则 check-modules ⑦ 会红)**

```bash
# .example 的组件开关区(与 METALLB_ENABLED 同段)加两行:
LOCAL_VOLUME_PROVISIONER_ENABLED="${LOCAL_VOLUME_PROVISIONER_ENABLED:-false}"   # kubespray addon: 本地卷静态供给(2.5.0); 默认关, 需要时置 true
NFD_ENABLED="${NFD_ENABLED:-false}"                                             # kubespray addon: node-feature-discovery(0.19.0); 默认关, 需要时置 true
# .example 的"镜像版本"段加:
LOCAL_VOLUME_PROVISIONER_VERSION="${LOCAL_VOLUME_PROVISIONER_VERSION:-2.5.0}"
NFD_VERSION="${NFD_VERSION:-0.19.0}"
```
(真 `cluster.conf` 同样加四行, 值保持默认 false。)

- [ ] **Step 2: sync-addons-config.sh 加两行**(插在 metallb 那两行之后, 同款写法)

```bash
set_key local_volume_provisioner_enabled "$(bool "${LOCAL_VOLUME_PROVISIONER_ENABLED:-false}")"
set_key node_feature_discovery_enabled   "$(bool "${NFD_ENABLED:-false}")"
```

- [ ] **Step 3: 验证(变异验证走临时 inventory;真实 inventory 只在最后写一次并提交)**

`sync-addons-config.sh` 无 CLI 参数,但认环境变量 `KUBESPRAY_INV_DIR`(`sync-addons-config.sh:18`),所以:

```bash
cd /home/supperadm/cubestack-installer
# a) 变异验证(不碰真 inventory): 全在临时拷贝上做
cp -a deployments/kubespray/inventory/cubestack-cluster /tmp/inv-test
KUBESPRAY_INV_DIR=/tmp/inv-test bash deployments/scripts/tools/k8s/sync-addons-config.sh >/dev/null 2>&1
grep -nE 'local_volume_provisioner_enabled|node_feature_discovery_enabled' /tmp/inv-test/group_vars/k8s_cluster/addons.yml   # 期望: 两键=false
sed -i 's|^NFD_ENABLED="${NFD_ENABLED:-false}"|NFD_ENABLED="${NFD_ENABLED:-true}"|' deployments/config/cluster.conf
KUBESPRAY_INV_DIR=/tmp/inv-test bash deployments/scripts/tools/k8s/sync-addons-config.sh >/dev/null 2>&1
grep -n 'node_feature_discovery_enabled' /tmp/inv-test/group_vars/k8s_cluster/addons.yml                              # 期望: true(证明开关真的通)
sed -i 's|^NFD_ENABLED="${NFD_ENABLED:-true}"|NFD_ENABLED="${NFD_ENABLED:-false}"|' deployments/config/cluster.conf     # 改回

# b) 真实 inventory 写一次(这就是本任务要提交的内容), 并确认回到 false
bash deployments/scripts/tools/k8s/sync-addons-config.sh >/dev/null 2>&1
grep -nE 'local_volume_provisioner_enabled|node_feature_discovery_enabled' \
  deployments/kubespray/inventory/cubestack-cluster/group_vars/k8s_cluster/addons.yml                                 # 期望: 两键=false
```
⚠ 提交前必须确认真 `addons.yml` 里两键是 `false`(与"默认关"一致),否则等于我们悄悄把 NFD 打开了。

- [ ] **Step 4: 提交**

```bash
git add deployments/config/cluster.conf deployments/config/cluster.conf.example deployments/scripts/tools/k8s/sync-addons-config.sh
git commit -m "feat(addons): 接线 LVP 2.5.0 / NFD 0.19.0 开关(默认 false)+ sync 写入 inventory"
```

### Task 10: 镜像登记 + 预载四处副本

**Files:**
- Modify: `deployments/config/images.manifest`、`deployments/config/cluster.conf` / `.example`、`deployments/scripts/tools/offline/trim-offline-files.sh`、`deployments/kubespray/cubestack-offline.sh`

- [ ] **Step 1: manifest 登记两条(k8s-base 组, 紧跟 pause/coredns 那批之后)**

```
k8s-base  registry.k8s.io/sig-storage/local-volume-provisioner:v${LOCAL_VOLUME_PROVISIONER_VERSION}
k8s-base  registry.k8s.io/nfd/node-feature-discovery:v${NFD_VERSION}
```

- [ ] **Step 2: PRELOAD 四处副本各加两个 token**

在每份 `PRELOAD_IMAGE_PATTERNS` 的值里(放在 `pause` 之后、保持同一顺序)加:
`local-volume-provisioner node-feature-discovery`
四处 = `cluster.conf`、`cluster.conf.example`、`trim-offline-files.sh`、`kubespray/cubestack-offline.sh`(内嵌默认)。

- [ ] **Step 3: 验证(③ 与 ⑭ 会一起抓)**

```bash
bash deployments/scripts/tools/images/check-image-manifest.sh --kubespray 2>&1 | tail -4
bash deployments/scripts/tools/check-modules.sh 2>&1 | grep -E '⑭|⑮|PRELOAD'
```
预期: `--kubespray` 交叉核对通过(新 token 已被 manifest 覆盖);⑭ 报"4 份副本逐字节一致"。

- [ ] **Step 4: offline-files README**(按仓库规则: `offline-files/kubespray/images/README.md` 里补两条镜像说明与获取命令)

- [ ] **Step 5: 提交**

```bash
git add deployments/config/images.manifest deployments/config/cluster.conf deployments/config/cluster.conf.example deployments/scripts/tools/offline/trim-offline-files.sh deployments/kubespray/cubestack-offline.sh deployments/offline-files/kubespray/images/README.md
git commit -m "feat(images): 登记 LVP/NFD 镜像 + PRELOAD 四处副本同步"
```

---

# 子项④ 版本面与离线(T11–T14)

> ⚠ **停靠点(执行到 T11 之后必须停)**:T11 一落地, 任何对**现有集群 A/B** 的全量部署都会把它们从
> 1.32.5 升到 1.35.8。T14 只允许在**全新集群**上验证;对 A/B 的部署/升级另行择期、且需用户当场确认
> (spec §11.1)。

### Task 11: k8s 基座组换 v2.32 表值 + 一致性断言

**Files:**
- Modify: `deployments/config/cluster.conf` / `.example`、`deployments/scripts/tools/check-modules.sh`(新增 ⑯, 项数 15 → 16)

- [ ] **Step 1: 从 v2.32 树机械抄值(不要手打)**

```bash
B=/tmp/kubespray-2.32/roles/kubespray_defaults
grep -nE '^(multus_version|metallb_version|kube_vip_version|local_volume_provisioner_version|node_feature_discovery_version|dnsautoscaler_version):' $B/defaults/main/download.yml
grep -oE '^\s+1\.35\.[0-9]+:' $B/vars/main/checksums.yml | sort -uV | tail -1     # k8s 最新补丁
awk '/^calicoctl_binary_checksums:/{f=1} f&&/^  amd64:/{a=1;next} a&&/^    [0-9]/{print; exit}' $B/vars/main/checksums.yml
```
把 `K8S_VERSION=v1.35.8`、`CALICO_VERSION=v3.31.7`、`ETCD_VERSION=v3.6.14` 等**写入 cluster.conf/.example**;`COREDNS/PAUSE/CNI/METRICS_SERVER/CPA` 同样抄表值(spec §4.1)。

- [ ] **Step 2: check-modules 新增 ⑯(我们的钉子 vs 上游表)**
断言方式: 读 `deployments/kubespray/kubespray/roles/kubespray_defaults/{download.yml,checksums.yml}` 抽出上游值,与 `cluster.conf(.example)` 的对应变量比;**不一致就红**。仿 ⑪-C 的"只判一致、不写死值"原则。同时把全部 `[N/15]` 文案改 `[N/16]`。

- [ ] **Step 3: 变异验证(必须做:证明这条断言不是松弛的)**

```bash
python3 - <<'PY'
import re
p='deployments/config/cluster.conf'
s=open(p).read()
open('/tmp/cc.bak','w').write(s)
open(p,'w').write(s.replace('K8S_VERSION="${K8S_VERSION:-v1.35.8}"','K8S_VERSION="${K8S_VERSION:-v1.34.13}"'))
PY
bash deployments/scripts/tools/check-modules.sh 2>&1 | grep -E '⑯' ; cp /tmp/cc.bak deployments/config/cluster.conf
```
预期: 改坏后 ⑯ 报红并点名;还原后绿。

- [ ] **Step 4: 提交**

```bash
git add deployments/config/cluster.conf deployments/config/cluster.conf.example deployments/scripts/tools/check-modules.sh
git commit -m "chore(versions): k8s 基座组对齐 v2.32 表值(1.35.8/calico 3.31.7/etcd 3.6.14…)+ check-modules ⑯ 一致性断言"
```

### Task 12: ansible 12.3.0 落地(CLI 镜像)

**Files:**
- Modify: 无源码改动(requirements.txt 随换树已变);**动作** = 重建 CLI 镜像

- [ ] **Step 1: 确认 requirements 已随换树更新**

```bash
grep -m1 '^ansible==' deployments/kubespray/kubespray/requirements.txt
```
预期: `ansible==12.3.0`。

- [ ] **Step 2: 重建 CLI 镜像**(构建机需能访问 PyPI 镜像;按仓库既有 CLI 镜像构建流程)

```bash
cd /home/supperadm/cubestack-installer
# 命令以仓库既有流程为准(见 Dockerfile-cli 头部注释 / deployments/README.md);典型:
docker build -f Dockerfile-cli -t cubestack-cli:kubespray-v2.32 .
```
- [ ] **Step 3: 验证**

```bash
docker run --rm cubestack-cli:kubespray-v2.32 bash -lc 'ansible --version | head -2; ansible-galaxy --version | head -1'
```
预期: `ansible [core 2.19.x]`,bundle 12.3.0。

- [ ] **Step 4: 裸机回退路径 `.venv_wheels/`**(若你们的裸机流程仍要用)
按 `cubestack-offline.sh:163-168` 的用法,刷新 wheel 缓存:
```bash
cd deployments/kubespray && python3 -m pip download -d .venv_wheels -r kubespray/requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple
ls .venv_wheels | wc -l && ls .venv_wheels | grep -m1 '^ansible-12'
```
预期: 缓存里有 `ansible-12.3.0*` 与它的一堆依赖。
- [ ] **Step 5: 提交(仅当有入库内容;`.venv_wheels/` 若按现有规则不入库, 就只在本任务记录里注明"已刷新")**

### Task 13: 离线备料 + 缺口清单 → 人工下载清单

**Files:**
- Create: `docs/kubespray-v2.32/manual-download-list.md`

- [ ] **Step 1: 触发 Harbor 同步**(二选一, 按 spec §11.2 的决定)
  - 合并到 main 后由 push 自动触发;或
  - 在本分支上手动(入参已按工作流文件核对:`groups`/`exclude_groups`/`force`/`platform`/`dry_run`):

```bash
gh workflow run sync-images-to-harbor.yml -r feat/kubespray-v2.32 -f groups=k8s-base,multus -f platform=all
sleep 10 && gh run list --workflow=sync-images-to-harbor.yml --limit 3
```
- [ ] **Step 2: 出 tar 并汇总失败项(在能连 Harbor 的机器上)**

```bash
cd /home/supperadm/cubestack-installer/deployments/scripts/tools/images
sudo ./harbor-save-images.sh 2>&1 | tee /tmp/save.log | tail -20
grep -iE 'fail|失败|missing|未找到' /tmp/save.log | sort -u
```
- [ ] **Step 3: 把失败项 + 非镜像制品写进 `manual-download-list.md`**
每条格式(照 spec §7.3):
```
- [ ] registry.k8s.io/nfd/node-feature-discovery:v0.19.0
      → deployments/offline-files/kubespray/images/nfd_node-feature-discovery_v0.19.0.tar
      手动: docker pull <ref> && docker save <ref> -o <上表路径>(或 skopeo copy)
      校验: sha256=<…>(用 skopeo inspect --raw 或 docker inspect 取)
```
**非镜像制品清单**(同样逐条给 URL 与目标路径):`kubelet`/`kubectl`(dl.k8s.io)、`calicoctl`(GitHub release)、`etcd` 二进制、CNI 插件、`crictl`、helm、以及 spec §7.2 里 kubespray 会下载的其它项 —— **上游 URL 从 v2.32 的 `roles/kubespray_defaults/defaults/main/download.yml` 的 `*_download_url` 变量抄, 不要凭记忆写**。

- [ ] **Step 4: 提交**

```bash
git add docs/kubespray-v2.32/manual-download-list.md
git commit -m "docs(kubespray): 离线缺口与人工下载清单(v2.32 / k8s 1.35.8)"
```

### Task 14: 实机验证(全新集群, 需用户在场)

- [ ] **Step 1: 全新集群全量部署**

```bash
bash deployments/scripts/deploy-cluster.sh --fresh            # 在部署容器内, 按既有流程
```
判据: 部署成功;k8s 1.35.8(`kubectl version`);calico 3.31.7;metallb 0.13.9(controller/speaker Running);multus DaemonSet Ready(镜像 `v4.2.2-thick`);kube-vip 静态 Pod 用 v1.0.3 且渲染产物与本机渲染一致。
- [ ] **Step 2: LVP/NFD 开→关 各跑一次**

```bash
# 打开
NFD_ENABLED=true bash deployments/scripts/deploy-cluster.sh --steps nfd   # 实际步骤名以模块列表为准(上游 addon 由 k8s_deploy 阶段带出 → 见下注)
```
注:LVP/NFD 是 **kubespray addon**(不是我们的模块), 开关生效路径 = `sync-addons-config` 写 inventory → **重跑 `k8s_deploy` 阶段**(模块 key 就是 `k8s_deploy`, 见 `02_k8s/06_k8s_deploy.sh:3`)才会装上。故:置开关 → `bash deployments/scripts/deploy-cluster.sh --steps k8s_deploy` → 验 `kubectl get ds -n node-feature-discovery` / `-n local-volume-provisioner`(LVP 是 DaemonSet, NFD 是 master Deployment + worker DaemonSet);再置回 false → 重跑 → 验**残留是否被清**(若 kubespray 只"不再装"而不清理,属上游行为,在文档里写明"关=不再由 ansible 管理,残留需手工删")。
- [ ] **Step 3: 把实机结果写回 `docs/kubespray-v2.32/design.md` §8 与 `docs/kubespray-upgrade.md` 记录条**

---

## 收尾检查(计划自审)

- [ ] spec §2.2 的 11 处改动:T1(7 处补丁)+ T4(#7 手工)+ 作废 #1 + 机制 A #2/#3 ✅ 全覆盖
- [ ] spec D0–D8:版本(T4/T11)、补丁机制(T1–T3)、multus(T7)、metallb(T8)、kube-vip(T6)、LVP/NFD(T9/T10)、镜像路径(T13)、人工清单(T13)✅
- [ ] spec §8 验证:T5(⑮)/T11(⑯)/T6(渲染断言)/T2(补丁回归)/T13(缺口清单)/T14(实机)✅
- [ ] spec §3.4 SOP 的 9 步:T3 脚本 + T5 文档 ✅;演练:T3 Step 3 ✅
- [ ] 命名一致性:`cubestack-patch-apply.sh`(--apply/--check/--check-retired/--list)、`cubestack-kubespray-upgrade.sh <tag> [--root --tree-src --no-fetch]`、`docs/kubespray-upgrade.md` 在 T1–T5 与 check-modules ⑮ 里用的是同一套名字 ✅
