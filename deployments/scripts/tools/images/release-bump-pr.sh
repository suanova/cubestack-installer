#!/bin/bash
# ============================================================
# release-bump-pr.sh — 按上游 tag 更新 release 版本定义(不碰 git/MinIO)
# ------------------------------------------------------------
# 只改 deployments/releases/<release>/ 下两个文件:
#   · release-images.tsv: 选中 component 子目录的 first-party 行
#   · release.env: component 含 "." 时改 operator 镜像 tag; --chart-version 改 chart
# first-party 判定: save_ref 在 <harbor>/suanova/ 或 /suanova-private/ 下.
# 用法:
#   release-bump-pr.sh --release 2.0.0 --component release-first-party --image-tag v2.0.0 \
#       [--chart-version 2.0.0] [--source-repo suanova/cubestack-operator] \
#       [--release-dir DIR] [--print-targets] [--dry-run] [--summary-file FILE]
# 退出码: 0=成功/无变化; 1=校验失败
# ============================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../../../.." && pwd)"
HARBOR="${HARBOR_MIRROR_REGISTRY:-harbor.isuanova.com}"

RELEASE=""; COMPONENT=""; IMAGE_TAG=""; CHART_VER=""; SOURCE_REPO=""
RELEASE_DIR=""; PRINT_TARGETS=0; DRY_RUN=0; SUMMARY_FILE=""

die() { echo "【错误】$*" >&2; exit 1; }
say() { printf '\033[36m→  %s\033[0m\n' "$*"; }
ok()  { printf '\033[32m✅ %s\033[0m\n' "$*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --release)       RELEASE="${2:?}"; shift 2 ;;
        --component)     COMPONENT="${2:?}"; shift 2 ;;
        --image-tag)     IMAGE_TAG="${2:?}"; shift 2 ;;
        --chart-version) CHART_VER="${2:?}"; shift 2 ;;
        --source-repo)   SOURCE_REPO="${2:?}"; shift 2 ;;
        --release-dir)   RELEASE_DIR="${2:?}"; shift 2 ;;
        --print-targets) PRINT_TARGETS=1; shift ;;
        --dry-run)       DRY_RUN=1; shift ;;
        --summary-file)  SUMMARY_FILE="${2:?}"; shift 2 ;;
        -h|--help)       sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
done

[ -n "${RELEASE}" ] || die "缺少 --release"
[ -n "${COMPONENT}" ] || die "缺少 --component"
[ -n "${IMAGE_TAG}" ] || die "缺少 --image-tag"
case "${RELEASE}" in ''|*[!0-9A-Za-z._-]*) die "非法 release: ${RELEASE}" ;; esac

RELEASE_DIR="${RELEASE_DIR:-${REPO_ROOT}/deployments/releases/${RELEASE}}"
[ -f "${RELEASE_DIR}/release-images.tsv" ] || die "缺少 ${RELEASE_DIR}/release-images.tsv"
[ -f "${RELEASE_DIR}/release.env" ]        || die "缺少 ${RELEASE_DIR}/release.env"
[ -f "${RELEASE_DIR}/components.tsv" ]     || die "缺少 ${RELEASE_DIR}/components.tsv"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cubestack-release-bump.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

python3 - "${RELEASE_DIR}/release-images.tsv" "${RELEASE_DIR}/release.env" \
    "${RELEASE_DIR}/components.tsv" "${COMPONENT}" "${IMAGE_TAG}" "${CHART_VER}" \
    "${SOURCE_REPO}" "${HARBOR}" "${PRINT_TARGETS}" "${DRY_RUN}" "${WORK}" <<'PY'
import difflib, os, re, sys

(tsv_path, env_path, comp_path, comp_arg, image_tag, chart_ver,
 source_repo, harbor, print_targets, dry_run, work) = sys.argv[1:]
print_targets = print_targets == "1"
dry_run = dry_run == "1"

def die(msg):
    print(f"【错误】{msg}", file=sys.stderr); sys.exit(1)

TAG_RE = re.compile(r'^[0-9A-Za-z][0-9A-Za-z._-]*$')
if not TAG_RE.match(image_tag):
    die(f"非法 image_tag: {image_tag}")
if chart_ver and not TAG_RE.match(chart_ver):
    die(f"非法 chart_version: {chart_ver}")

comps = {}
with open(comp_path, encoding="utf-8") as f:
    for n, line in enumerate(f, 1):
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            die(f"{comp_path}:{n}: 列不足")
        comps[parts[0]] = {"repo": parts[1], "subdirs": parts[2].split()}

selected = [c.strip() for c in comp_arg.split(",") if c.strip()]
if not selected:
    die("--component 为空")

subdirs, chart_only = [], False
for c in selected:
    if c not in comps:
        die(f"未知 component: {c}")
    repo = comps[c]["repo"]
    if source_repo and repo not in ("", "-") and repo != source_repo:
        die(f"component {c} 属于 {repo}, 与 source_repo={source_repo} 不匹配")
    for d in comps[c]["subdirs"]:
        if d == "*":
            die(f"component {c} 不支持 tag bump(通配 subdir)")
        if d == "cli":
            die(f"component {c} 不支持 tag bump(CLI)")
        if d == "-":
            chart_only = True
            continue
        subdirs.append(d)
subdirs = sorted(set(subdirs))

def is_first_party(ref):
    return ref.startswith(harbor + "/suanova/") or ref.startswith(harbor + "/suanova-private/")

def retag(ref):
    base, sep, tag = ref.rpartition(":")
    if not sep or "/" in tag:
        die(f"无法解析带 tag 的 ref: {ref}")
    return f"{base}:{image_tag}"

# ---------- release-images.tsv ----------
with open(tsv_path, encoding="utf-8") as f:
    base_lines = f.readlines()

new_lines, changes, targets = [], [], []
for n, raw in enumerate(base_lines, 1):
    line = raw.rstrip("\n")
    if not line.strip() or line.lstrip().startswith("#"):
        new_lines.append(raw); continue
    parts = line.split("\t")
    if len(parts) < 4:
        die(f"{tsv_path}:{n}: 列不足")
    sub, pull, save = parts[0] or ".", parts[2], parts[3]
    if sub not in subdirs or not is_first_party(save):
        new_lines.append(raw); continue
    nsave = retag(save)
    nfile = nsave.replace("/", "_").replace(":", "_") + ".tar"
    npull = retag(pull) if pull and is_first_party(pull) else pull
    parts[1], parts[2], parts[3] = nfile, npull, nsave
    nline = "\t".join(parts) + "\n"
    targets.append((sub, nsave))
    if nline != raw:
        changes.append((n, raw.rstrip("\n"), nline.rstrip("\n")))
    new_lines.append(nline)

if print_targets:
    for sub, ref in targets:
        print(f"{sub}\t{ref}")
    sys.exit(0)

if not targets and not chart_only:
    die("选中的 component 没有 first-party 镜像行")

# ---------- release.env ----------
with open(env_path, encoding="utf-8") as f:
    env_lines = f.readlines()

def set_env(key, value):
    pat = re.compile(rf'^({re.escape(key)}=)([^\s#]*)(.*)$')
    hits = 0
    for i, raw in enumerate(env_lines):
        line = raw.rstrip("\n")
        m = pat.match(line)
        if not m:
            continue
        nline = f"{m.group(1)}{value}{m.group(3)}\n"
        if nline != raw:
            changes.append((i + 1, line, nline.rstrip("\n")))
        env_lines[i] = nline
        hits += 1
    if hits != 1:
        die(f"{env_path}: key {key} 出现 {hits} 次(期望 1)")

if "." in subdirs:
    set_env("CUBESTACK_OPERATOR_IMAGE_TAG", image_tag)
if chart_ver:
    set_env("CUBESTACK_OPERATOR_CHART_VERSION", chart_ver)

# ---------- 输出 ----------
tsv_new, env_new = "".join(new_lines), "".join(env_lines)
originals = {}
for path, new_text in ((tsv_path, tsv_new), (env_path, env_new)):
    with open(path, encoding="utf-8") as f:
        originals[path] = f.read()

diff = []
for path, new_text in ((tsv_path, tsv_new), (env_path, env_new)):
    if originals[path] != new_text:
        diff.extend(difflib.unified_diff(
            originals[path].splitlines(True), new_text.splitlines(True),
            fromfile=path, tofile=path))

with open(os.path.join(work, "diff.txt"), "w", encoding="utf-8") as f:
    f.writelines(diff)
changed = "1" if diff else "0"
with open(os.path.join(work, "changed.flag"), "w", encoding="utf-8") as f:
    f.write(changed)

if dry_run or changed == "0":
    sys.exit(0)

for path, new_text in ((tsv_path, tsv_new), (env_path, env_new)):
    if originals[path] == new_text:
        continue
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(new_text)
    os.replace(tmp, path)
PY
rc=$?
[ "${rc}" = "0" ] || exit "${rc}"

# --print-targets 只输出目标 ref; 不能混入下面的 diff/no-changes 文本.
[ "${PRINT_TARGETS}" = "1" ] && exit 0

cat "${WORK}/diff.txt"
if [ "$(cat "${WORK}/changed.flag" 2>/dev/null || echo 0)" = "0" ]; then
    ok "no changes (already up to date)"
elif [ "${DRY_RUN}" = "1" ]; then
    ok "dry-run: changes shown above, nothing written"
else
    ok "release definition updated"
fi
if [ -n "${SUMMARY_FILE}" ]; then
    {
        echo "## release bump: ${RELEASE} / ${COMPONENT} -> ${IMAGE_TAG}"
        echo '```diff'
        cat "${WORK}/diff.txt"
        echo '```'
    } > "${SUMMARY_FILE}"
fi
