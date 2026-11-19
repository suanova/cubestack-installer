#!/bin/bash
set -euo pipefail

# Regression tests for the mirror pin PR validator used by pin-automerge.
# The validator must accept a commit-only move and reject every other change.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TOOL="${ROOT}/deployments/scripts/tools/online/check-mirror-pin-diff.py"
TMP="$(mktemp -d -t cubestack-mirror-pin-diff-test.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

cat > "${TMP}/base.yaml" <<'EOF'
schema: 1
mirror:
  repo: suanova/container-image-mirror
  commit: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  path: index.json
env:
  FOO: bar
EOF

expect_ok() {
    local name="$1" file="$2"
    if ! python3 "${TOOL}" "${TMP}/base.yaml" "${file}" >/dev/null 2>&1; then
        fail "${name}: expected acceptance"
    fi
    pass "${name}"
}

expect_reject() {
    local name="$1" file="$2" pattern="$3"
    if python3 "${TOOL}" "${TMP}/base.yaml" "${file}" \
        >/dev/null 2>"${TMP}/err"; then
        fail "${name}: expected rejection"
    fi
    grep -qi "${pattern}" "${TMP}/err" || {
        echo "stderr was:" >&2
        cat "${TMP}/err" >&2
        fail "${name}: error does not mention ${pattern}"
    }
    pass "${name}"
}

sed 's/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/' \
    "${TMP}/base.yaml" > "${TMP}/commit-only.yaml"
expect_ok "commit-only change" "${TMP}/commit-only.yaml"

sed 's#suanova/container-image-mirror#suanova/other-mirror#' \
    "${TMP}/base.yaml" > "${TMP}/repo-change.yaml"
expect_reject "repository change" "${TMP}/repo-change.yaml" "mirror.repo"

sed 's#path: index.json#path: other.json#' \
    "${TMP}/base.yaml" > "${TMP}/path-change.yaml"
expect_reject "path change" "${TMP}/path-change.yaml" "mirror.path"

sed -e 's/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/' \
    -e 's/FOO: bar/FOO: baz/' "${TMP}/base.yaml" > "${TMP}/env-change.yaml"
expect_reject "env change" "${TMP}/env-change.yaml" "outside mirror.commit"

cp "${TMP}/base.yaml" "${TMP}/same-commit.yaml"
expect_reject "unchanged commit" "${TMP}/same-commit.yaml" "did not move"

sed 's/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/not-a-sha/' \
    "${TMP}/base.yaml" > "${TMP}/bad-commit.yaml"
expect_reject "invalid commit" "${TMP}/bad-commit.yaml" "hex commit"

sed 's|  commit: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|  commit: cccccccccccccccccccccccccccccccccccccccc  # moved|' \
    "${TMP}/base.yaml" > "${TMP}/comment-change.yaml"
expect_reject "comment change" "${TMP}/comment-change.yaml" "outside mirror.commit"

cat > "${TMP}/no-mirror.yaml" <<'EOF'
schema: 1
env:
  FOO: bar
EOF
expect_reject "missing mirror block" "${TMP}/no-mirror.yaml" "mirror pin"

echo "all mirror pin diff tests passed"
