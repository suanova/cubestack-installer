#!/bin/bash
# test-extra-modules-dirs.sh — CUBESTACK_EXTRA_MODULES_DIRS regression
# Default behavior must stay unchanged; extra roots merge into a temporary
# modules dir; duplicate files/keys must fail.
# Usage: bash deployments/scripts/tools/tests/test-extra-modules-dirs.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIB_COMMON="${REPO_ROOT}/deployments/scripts/lib-common.sh"
LIB_MODULE="${REPO_ROOT}/deployments/scripts/lib-module.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: expected[$2] actual[$3]"; fail=1; fi; }
chk_not() { if [ "$2" != "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: unexpected[$3]"; fail=1; fi; }
chk_contains() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  ok  $1"; else echo "  FAIL $1: [$3] missing [$2]"; fail=1; fi; }

mkdir -p "${TMP}/extra/03_addon"
cat > "${TMP}/extra/03_addon/99_test_extra.sh" <<'EOF'
#!/bin/bash
# MODULE: test_extra
# DESC: extra module test
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
echo "extra_module_lib_common_ok"
EOF

# Default: no merge, no extra key.
out="$(bash -c 'source "$1" >/dev/null 2>&1; source "$2"; discover_modules; module_index test_extra' _ "${LIB_COMMON}" "${LIB_MODULE}")"
chk "default keeps extra module absent" "-1" "${out}"

# Extra root (modules/ with 03_addon/): merged and discoverable.
out="$(bash -c 'CUBESTACK_EXTRA_MODULES_DIRS="$1"; source "$2" >/dev/null 2>&1; source "$3"; discover_modules; module_index test_extra' _ "${TMP}/extra" "${LIB_COMMON}" "${LIB_MODULE}")"
chk_not "extra root discovers module" "-1" "${out}"
merged="$(bash -c 'CUBESTACK_EXTRA_MODULES_DIRS="$1"; source "$2" >/dev/null 2>&1; source "$3"; echo "${MODULES_DIR}"' _ "${TMP}/extra" "${LIB_COMMON}" "${LIB_MODULE}")"
chk_not "extra root changes MODULES_DIR" "${REPO_ROOT}/deployments/scripts/modules" "${merged}"
if [ -L "${merged}/03_addon/99_test_extra.sh" ]; then echo "  ok  extra module is symlinked"; else echo "  FAIL extra module symlink missing"; fail=1; fi
if bash "${merged}/03_addon/99_test_extra.sh" 2>/dev/null | grep -qF "extra_module_lib_common_ok"; then
    echo "  ok  merged module resolves lib-common"
else
    echo "  FAIL merged module cannot resolve lib-common"; fail=1
fi

# Child process (e.g. cluster-teardown.sh) reuses the exported merged root.
out="$(bash -c 'CUBESTACK_MODULES_MERGED="$1"; source "$2" >/dev/null 2>&1; source "$3"; discover_modules; module_index test_extra' _ "${merged}" "${LIB_COMMON}" "${LIB_MODULE}")"
chk_not "child reuses merged root" "-1" "${out}"

# Extra phase dir directly: also accepted.
out="$(bash -c 'CUBESTACK_EXTRA_MODULES_DIRS="$1"; source "$2" >/dev/null 2>&1; source "$3"; discover_modules; module_index test_extra' _ "${TMP}/extra/03_addon" "${LIB_COMMON}" "${LIB_MODULE}")"
chk_not "extra phase dir discovers module" "-1" "${out}"

# Duplicate file name must fail during merge.
mkdir -p "${TMP}/dupfile/03_addon"
cat > "${TMP}/dupfile/03_addon/25_cubestack_operator.sh" <<'EOF'
#!/bin/bash
# MODULE: dup_file
# DESC: duplicate file
# PHASE: addon
EOF
if bash -c 'CUBESTACK_EXTRA_MODULES_DIRS="$1"; source "$2" >/dev/null 2>&1; source "$3"' _ "${TMP}/dupfile" "${LIB_COMMON}" "${LIB_MODULE}" >"${TMP}/dupfile.log" 2>&1; then
    echo "  FAIL duplicate file should fail"; fail=1
else
    echo "  ok  duplicate file rejected"
    chk_contains "duplicate file message" "duplicate module file" "${TMP}/dupfile.log"
fi

# Duplicate module key must fail in discover_modules.
mkdir -p "${TMP}/dupkey/03_addon"
cat > "${TMP}/dupkey/03_addon/98_dupkey.sh" <<'EOF'
#!/bin/bash
# MODULE: ceph
# DESC: duplicate key
# PHASE: addon
EOF
if bash -c 'CUBESTACK_EXTRA_MODULES_DIRS="$1"; source "$2" >/dev/null 2>&1; source "$3"; discover_modules' _ "${TMP}/dupkey" "${LIB_COMMON}" "${LIB_MODULE}" >"${TMP}/dupkey.log" 2>&1; then
    echo "  FAIL duplicate key should fail"; fail=1
else
    echo "  ok  duplicate key rejected"
    chk_contains "duplicate key message" "duplicate module key" "${TMP}/dupkey.log"
fi

exit "${fail}"
