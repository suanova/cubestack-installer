#!/bin/bash
set -euo pipefail

# Regression tests for the online install entry point and its online-mode guards.
# These tests do not need a cluster, skopeo or network.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SCRIPTS="${ROOT}/deployments/scripts"
CONF="${ROOT}/deployments/config/cluster.conf.example"
TMP="$(mktemp -d -t cubestack-install-online-test.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

[ -f "${CONF}" ] || fail "missing ${CONF}"

# Syntax gate for the new entry point and modules.
for f in \
    "${SCRIPTS}/install-online.sh" \
    "${SCRIPTS}/modules/02_k8s/15_k8s_asset_prefetch.sh" \
    "${SCRIPTS}/modules/02_k8s/02_k8s_workerbm.sh" \
    "${SCRIPTS}/modules/02_k8s/12_node_pkgs.sh"; do
    bash -n "${f}" || fail "syntax: ${f}"
done
pass "online entry point and modules parse"

# Offline deployments must not prefetch k8s assets.
out="$(CLUSTER_CONF="${CONF}" CUBESTACK_ONLINE=0 \
    bash "${SCRIPTS}/modules/02_k8s/15_k8s_asset_prefetch.sh" 2>&1)"
grep -q "非在线模式" <<<"${out}" || fail "offline asset prefetch did not exit"
pass "asset prefetch is a no-op offline"

# node_pkgs skips when the online entry point already ran the pre-check.
out="$(CLUSTER_CONF="${CONF}" CUBESTACK_OS_CHECK_DONE=1 \
    bash "${SCRIPTS}/modules/02_k8s/12_node_pkgs.sh" 2>&1)"
grep -q "已由在线安装预检" <<<"${out}" || fail "node_pkgs online pre-check guard missing"
pass "node package check is skipped after the online pre-check"

# Modules must not fall back to the deleted OS package installers.
for f in "${SCRIPTS}/modules/02_k8s/02_k8s_workerbm.sh" \
         "${SCRIPTS}/modules/02_k8s/12_node_pkgs.sh"; do
    if grep -qE 'install-worker-packages|reconcile-node-packages' "${f}"; then
        fail "OS package installer reference remains: ${f}"
    fi
done
[ ! -e "${SCRIPTS}/tools/node/install-worker-packages.sh" ] \
    || fail "install-worker-packages.sh still exists"
[ ! -e "${SCRIPTS}/tools/node/reconcile-node-packages.sh" ] \
    || fail "reconcile-node-packages.sh still exists"
pass "OS package installers are gone"

# The online entry point must not install OS packages.
if grep -nE '(^|[^#])\b(apt-get[[:space:]]+install|dpkg[[:space:]]+-i)\b' \
    "${SCRIPTS}/install-online.sh" >/dev/null; then
    fail "install-online.sh contains an OS package install command"
fi
pass "install-online.sh has no OS package install command"

# Dry-run: image materialization is skipped, and the node prerequisite check
# runs in warn-only mode by default.
printf '{}\n' > "${TMP}/index.json"
out="$(cd "${ROOT}" && CLUSTER_CONF="${CONF}" \
    bash "${SCRIPTS}/install-online.sh" \
    --index "${TMP}/index.json" --no-materialize --dry-run --with-k8s 2>&1)"
grep -q "skipping image materialization" <<<"${out}" || fail "dry-run did not skip materialization"
grep -q "node prerequisite pre-check (warn-only)" <<<"${out}" || fail "dry-run did not run warn-only pre-check"
grep -q "would exec: .*deploy-cluster.sh --with-k8s" <<<"${out}" || fail "dry-run did not print deploy command"
pass "install-online dry-run skips materialization and warns on prerequisites"

# The pre-check can be skipped explicitly.
out="$(cd "${ROOT}" && CLUSTER_CONF="${CONF}" \
    bash "${SCRIPTS}/install-online.sh" \
    --index "${TMP}/index.json" --no-materialize --dry-run \
    --no-check-os-packages 2>&1)"
grep -q "skipped (--no-check-os-packages)" <<<"${out}" || fail "pre-check skip flag not honored"
pass "install-online can skip the prerequisite pre-check"

# Blocking pre-check can be enabled without touching the nodes in dry-run.
out="$(cd "${ROOT}" && CLUSTER_CONF="${CONF}" \
    bash "${SCRIPTS}/install-online.sh" \
    --index "${TMP}/index.json" --no-materialize --dry-run --check-os-packages 2>&1)"
grep -q "pre-check passed" <<<"${out}" || fail "enabled pre-check dry-run did not pass"
pass "install-online can enable the blocking prerequisite pre-check"

echo "all install-online tests passed"
