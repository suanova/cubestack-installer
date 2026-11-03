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
EOF

# Default: no merge, no extra key.
out="$(bash -c "source '${LIB_COMMON}' >/dev/null 2>&1; source '${LIB_MODULE}'; discover_modules; module_index test_extra")"
chk "default keeps extra module absent" "-1" "${out}"

# Extra root (modules/ with 03_addon/): merged and discoverable.
out="$(bash -c "CUBESTACK_EXTRA_MODULES_DIRS='${TMP}/extra'; source '${LIB_COMMON}' >/dev/null 2>&1; source '${LIB_MODULE}'; discover_modules; module_index test_extra")"
chk_not "extra root discovers module" "-1" "${out}"
merged="$(bash -c "CUBESTACK_EXTRA_MODULES_DIRS='${TMP}/extra'; source '${LIB_COMMON}' >/dev/null 2>&1; source '${LIB_MODULE}'; echo \"\${MODULES_DIR}\"")"
chk_not "extra root changes MODULES_DIR" "${REPO_ROOT}/deployments/scripts/modules" "${merged}"
if [ -L "${merged}/03_addon/99_test_extra.sh" ]; then echo "  ok  extra module is symlinked"; else echo "  FAIL extra module symlink missing"; fail=1; fi

# Extra phase dir directly: also accepted.
out="$(bash -c "CUBESTACK_EXTRA_MODULES_DIRS='${TMP}/extra/03_addon'; source '${LIB_COMMON}' >/dev/null 2>&1; source '${LIB_MODULE}'; discover_modules; module_index test_extra")"
chk_not "extra phase dir discovers module" "-1" "${out}"

# Duplicate file name must fail during merge.
mkdir -p "${TMP}/dupfile/03_addon"
cat > "${TMP}/dupfile/03_addon/25_cubestack_operator.sh" <<'EOF'
#!/bin/bash
# MODULE: dup_file
# DESC: duplicate file
# PHASE: addon
EOF
if bash -c "CUBESTACK_EXTRA_MODULES_DIRS='${TMP}/dupfile'; source '${LIB_COMMON}' >/dev/null 2>&1; source '${LIB_MODULE}'" >"${TMP}/dupfile.log" 2>&1; then
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
if bash -c "CUBESTACK_EXTRA_MODULES_DIRS='${TMP}/dupkey'; source '${LIB_COMMON}' >/dev/null 2>&1; source '${LIB_MODULE}'; discover_modules" >"${TMP}/dupkey.log" 2>&1; then
    echo "  FAIL duplicate key should fail"; fail=1
else
    echo "  ok  duplicate key rejected"
    chk_contains "duplicate key message" "duplicate module key" "${TMP}/dupkey.log"
fi

exit "${fail}"
