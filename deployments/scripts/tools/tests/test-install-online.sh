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

# OS package installation is opt-in: default off, no installer invoked.
out="$(CLUSTER_CONF="${CONF}" bash "${SCRIPTS}/modules/02_k8s/12_node_pkgs.sh" 2>&1)"
grep -q "NODE_PKGS_ENABLED=false" <<<"${out}" || fail "node_pkgs default-off guard missing"
grep -qE 'reconcile-node-packages' <<<"${out}" && fail "node_pkgs ran the installer while disabled"
pass "node package install is opt-in (default off)"

out="$(CLUSTER_CONF="${CONF}" bash "${SCRIPTS}/modules/02_k8s/02_k8s_workerbm.sh" 2>&1)"
grep -q "WORKER_PKGS_ENABLED=false" <<<"${out}" || fail "k8s_workerbm default-off guard missing"
grep -qE 'install-worker-packages' <<<"${out}" && fail "k8s_workerbm ran the installer while disabled"
pass "worker package install is opt-in (default off)"

# The opt-in installers are restored and wired to their module switches.
for f in "${SCRIPTS}/tools/node/install-worker-packages.sh" \
         "${SCRIPTS}/tools/node/reconcile-node-packages.sh"; do
    [ -x "${f}" ] || fail "missing OS package installer: ${f}"
done
grep -q 'TOGGLE: NODE_PKGS_ENABLED' "${SCRIPTS}/modules/02_k8s/12_node_pkgs.sh" \
    || fail "node_pkgs TOGGLE missing"
grep -q 'TOGGLE: WORKER_PKGS_ENABLED' "${SCRIPTS}/modules/02_k8s/02_k8s_workerbm.sh" \
    || fail "k8s_workerbm TOGGLE missing"
grep -q 'CUBESTACK_OS_CHECK_DONE' "${SCRIPTS}/modules/02_k8s/14_pre_install_check.sh" \
    || fail "pre_install_check online pre-check guard missing"
pass "OS package installers are opt-in and wired to their switches"

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

# The mirror index URL comes from the baseline pin, not a hardcoded main ref.
mkdir -p "${TMP}/bin" "${TMP}/offline"
cat > "${TMP}/bin/curl" <<'EOF'
#!/bin/bash
url="" out=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
printf '%s\n' "${url}" >> "${CURL_LOG:?}"
printf '{"schema":1,"images":[]}\n' > "${out:?}"
EOF
chmod +x "${TMP}/bin/curl"
out="$(cd "${ROOT}" && env -u CUBESTACK_MIRROR_INDEX -u CUBESTACK_MIRROR_INDEX_URL \
    CLUSTER_CONF="${CONF}" CURL_LOG="${TMP}/curl.log" PATH="${TMP}/bin:${PATH}" \
    bash "${SCRIPTS}/install-online.sh" \
    --offline-root "${TMP}/offline" --no-materialize --dry-run --no-check-os-packages 2>&1)"
grep -q "mirror index pinned by baseline:" <<<"${out}" || fail "pinned index message missing"
mirror_repo="$(sed -n 's/^  repo: //p' "${ROOT}/versions/base.yaml" | head -1)"
mirror_commit="$(sed -n 's/^  commit: //p' "${ROOT}/versions/base.yaml" | head -1)"
grep -q "${mirror_repo}/${mirror_commit}/index.json" \
    "${TMP}/curl.log" || fail "mirror index was not fetched from the baseline pin"
[ ! -e "${TMP}/offline/mirror" ] || fail "dry-run persisted the mirror index"
pass "install-online fetches the mirror index at the baseline pin"

# The baseline is authoritative: a profile/cluster override must fail loudly.
sed 's/K8S_VERSION: v1.35.8/K8S_VERSION: v9.9.9/' "${ROOT}/versions/base.yaml" > "${TMP}/base-bad.yaml"
if out="$(cd "${ROOT}" && CLUSTER_CONF="${CONF}" \
    bash "${SCRIPTS}/install-online.sh" \
    --baseline "${TMP}/base-bad.yaml" --index "${TMP}/index.json" \
    --no-materialize --dry-run --no-check-os-packages 2>&1)"; then
    fail "baseline/profile mismatch was accepted"
fi
grep -q "baseline env and effective config disagree" <<<"${out}" \
    || fail "baseline/profile mismatch did not explain the failure"
grep -q "K8S_VERSION: baseline=v9.9.9" <<<"${out}" \
    || fail "baseline/profile mismatch did not name the key"
pass "install-online rejects profile overrides that disagree with the baseline"

echo "all install-online tests passed"
