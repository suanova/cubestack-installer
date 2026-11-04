#!/bin/bash
# ============================================================
# test-offline-incremental-plan.sh — 离线增量下载计划(manifest-plan.py)回归
#
# 覆盖: 缺失→fetch / 一致→不下载 / 同大小内容变化→必须重下(旧 mc mirror 会漏) /
#       多余文件→delete / prefix 过滤 / 哈希缓存命中 / 非法清单与穿越路径→rc=3
# 用法: bash deployments/scripts/tools/tests/test-offline-incremental-plan.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
PLANNER="${REPO_ROOT}/deployments/scripts/tools/offline/manifest-plan.py"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }

[ -f "${PLANNER}" ] || { echo "❌ 缺少 ${PLANNER}"; exit 1; }

ROOT="${TMP}/root"
mkdir -p "${ROOT}/kubespray/v1" "${ROOT}/os"
printf 'aaaa\n' > "${ROOT}/kubespray/v1/a.tar"
printf 'bbbb\n' > "${ROOT}/os/b.deb"

# 远端清单(内容 = 上面两个文件 + 一个本地缺失文件)
(
  cd "${ROOT}" || exit 1
  sha256sum kubespray/v1/a.tar os/b.deb > "${TMP}/sums" 2>/dev/null
  printf '%s  ./metax-gpu/c.tar\n' "$(printf 'cccc\n' | sha256sum | awk '{print $1}')" >> "${TMP}/sums"
)
# 把清单路径改成标准 "./" 前缀, 贴近真实发布树
sed -i 's#  \([a-z]\)#  ./\1#' "${TMP}/sums"

plan_run() {  # <outfile> [extra args...]
    local out="$1"; shift
    python3 "${PLANNER}" --manifest "${TMP}/sums" --root "${ROOT}" --cache "${TMP}/cache.json" --out "${out}" "$@"
}

echo "[1] 一致文件不下载 / 缺失文件下载";
plan_run "${TMP}/p1.tsv" >"${TMP}/s1.json"
chk "只 fetch 缺失的 1 个" "1" "$(grep -c '^fetch' "${TMP}/p1.tsv")"
chk "缺失项正确" "metax-gpu/c.tar" "$(awk -F'\t' '$1=="fetch"{print $2}' "${TMP}/p1.tsv")"
chk "delete 为 0" "0" "$(grep -c '^delete' "${TMP}/p1.tsv" || true)"

echo "[2] 同大小内容变化 → 必须重下(旧 --overwrite 之外的本意)";
printf 'AAAA\n' > "${ROOT}/kubespray/v1/a.tar"     # 同样 5 字节, 内容不同
plan_run "${TMP}/p2.tsv" >"${TMP}/s2.json"
chk "检出同大小变更" "1" "$(awk -F'\t' '$1=="fetch"{print $2}' "${TMP}/p2.tsv" | grep -c 'kubespray/v1/a.tar')"

echo "[3] 多余文件 → delete(.cubestack-* 与 CLI tar 豁免)";
printf 'x\n' > "${ROOT}/os/extra.txt"
printf 'x\n' > "${ROOT}/.cubestack-verified.json"
printf 'x\n' > "${ROOT}/cubestack-installer-cli-v9.9.9.tar"
plan_run "${TMP}/p3.tsv" >"${TMP}/s3.json"
chk "多余项被列出" "1" "$(grep -c '^delete' "${TMP}/p3.tsv")"
chk "多余项正确" "os/extra.txt" "$(awk -F'\t' '$1=="delete"{print $2}' "${TMP}/p3.tsv")"
rm -f "${ROOT}/os/extra.txt" "${ROOT}/.cubestack-verified.json" "${ROOT}/cubestack-installer-cli-v9.9.9.tar"

echo "[4] prefix 过滤(逐子目录增量)";
plan_run "${TMP}/p4.tsv" --prefix kubespray/ >"${TMP}/s4.json"
chk "只处理 kubespray/" "0" "$(grep -c 'metax\|os/' "${TMP}/p4.tsv" || true)"
chk "不会删除 prefix 外文件" "1" "$([ -f "${ROOT}/os/b.deb" ] && echo 1 || echo 0)"

echo "[5] 哈希缓存: 第二次不再读取文件内容";
plan_run "${TMP}/p5.tsv" --prefix kubespray/ >"${TMP}/s5.json"
chk "第二次 hashed=0(cache 命中)" "0" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hashed"])' "${TMP}/s5.json")"
chk "第一次 hashed>0" "1" "$(python3 -c 'import json,sys; print(1 if json.load(open(sys.argv[1]))["hashed"]>0 else 0)' "${TMP}/s1.json")"

echo "[6] 非法清单 / 路径穿越 → rc=3(调用方回退整树 mirror)";
printf 'deadbeef  ./x\n' > "${TMP}/bad1"
python3 "${PLANNER}" --manifest "${TMP}/bad1" --root "${ROOT}" --out "${TMP}/p6.tsv" >/dev/null 2>&1
chk "非法哈希 rc=3" "3" "$?"
printf '%s  ./../escape.txt\n' "$(printf 'e' | sha256sum | awk '{print $1}')" > "${TMP}/bad2"
python3 "${PLANNER}" --manifest "${TMP}/bad2" --root "${ROOT}" --out "${TMP}/p7.tsv" >/dev/null 2>&1
chk "穿越路径 rc=3" "3" "$?"

echo "[7] --hash-list 刷新模式";
printf 'kubespray/v1/a.tar\n' > "${TMP}/refs"
python3 "${PLANNER}" --manifest "${TMP}/sums" --root "${ROOT}" --cache "${TMP}/cache.json" \
    --out /dev/null --hash-list "${TMP}/refs" >/dev/null 2>&1
chk "刷新成功" "0" "$?"
chk "缓存已记录该文件" "1" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(1 if "kubespray/v1/a.tar" in d["files"] else 0)' "${TMP}/cache.json")"

echo "---------------------------------------------"
if [ "${fail}" = "0" ]; then
    echo "✅ 离线增量下载计划回归通过"
    exit 0
else
    echo "❌ 回归失败"
    exit 1
fi
