#!/usr/bin/env bash
# ============================================================
# build-verifier.sh — 构建/检查 verifier zipapp
#
# 源: deployments/scripts/tools/offline/verifier/ (Python 包)
# 产物: deployments/scripts/tools/offline/verify-offline-files.pyz
#
# 用法:
#   bash build-verifier.sh              # 重新构建 pyz
#   bash build-verifier.sh --check      # 检查已提交 pyz 与源码一致(CI)
#   bash build-verifier.sh --update-pin # 构建并更新 config/verify-tool.sha256
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
SRC="${SCRIPT_DIR}/verifier"
OUT="${SCRIPT_DIR}/verify-offline-files.pyz"
PIN="${REPO_ROOT}/deployments/config/verify-tool.sha256"
MODE="build"
case "${1:-}" in
    --check) MODE="check" ;;
    --update-pin) MODE="update-pin" ;;
    "") ;;
    *) echo "用法: $0 [--check|--update-pin]" >&2; exit 2 ;;
esac

command -v python3 >/dev/null 2>&1 || { echo "❌ 需要 python3" >&2; exit 2; }
[ -d "${SRC}" ] || { echo "❌ 缺少源码包: ${SRC}" >&2; exit 2; }

_build_to() {   # <out.pyz>
    local out="$1" stage
    stage="$(mktemp -d)"
    trap 'rm -rf "${stage}"' RETURN
    cp -a "${SRC}" "${stage}/verifier"
    find "${stage}/verifier" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
    python3 -m zipapp "${stage}" -m "verifier.__main__:entry" \
        -p "/usr/bin/env python3" -o "${out}"
    chmod 0755 "${out}"
}

if [ "${MODE}" = "check" ]; then
    [ -f "${OUT}" ] || { echo "❌ 缺少已构建 pyz: ${OUT}" >&2; exit 1; }
    tmp="$(mktemp)"; trap 'rm -f "${tmp}"' EXIT
    _build_to "${tmp}"
    python3 - "${OUT}" "${tmp}" <<'PY'
import sys, zipfile
a = zipfile.ZipFile(sys.argv[1])
b = zipfile.ZipFile(sys.argv[2])
na = sorted(n for n in a.namelist() if n.startswith("verifier/") and n.endswith(".py"))
nb = sorted(n for n in b.namelist() if n.startswith("verifier/") and n.endswith(".py"))
if na != nb:
    print(f"❌ pyz 源码文件列表不一致:\n  committed={na}\n  source={nb}", file=sys.stderr)
    sys.exit(1)
for n in na:
    if a.read(n) != b.read(n):
        print(f"❌ pyz 内容过期: {n}", file=sys.stderr)
        sys.exit(1)
print(f"✅ verifier pyz 与源码一致({len(na)} 个模块)")
PY
    exit 0
fi

_build_to "${OUT}"
echo "✅ 已构建: ${OUT}"
if [ "${MODE}" = "update-pin" ]; then
    sha256sum "${OUT}" | awk '{print $1}' > "${PIN}"
    echo "✅ 已更新 pin: ${PIN}"
fi
