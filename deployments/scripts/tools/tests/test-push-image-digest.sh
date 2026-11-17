#!/usr/bin/env bash
# push_image_digest: digest-pinned output, idempotent push, argument validation.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIB="${ROOT}/deployments/scripts/lib-common.sh"
TMP="$(mktemp -d -t cubestack-push-digest-test.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }
chk() { [ "$2" = "$3" ] || fail "$1: expected [$3] got [$2]"; pass "$1"; }

DEST_DIGEST="sha256:$(printf '%064d' 1)"
export FAKE_LOG="${TMP}/skopeo.log"
export FAKE_PUSHED="${TMP}/pushed"

cat > "${TMP}/cluster.conf" <<'EOF'
NODES=()
SSH_USER="root"
KUBESPRAY_PROFILE="none"
EOF

cat > "${TMP}/config.json" <<EOF
{"schemaVersion":2,"config":{"digest":"sha256:$(printf '%064d' 2)"}}
EOF
cat > "${TMP}/manifest.json" <<'EOF'
{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","layers":[]}
EOF

mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/skopeo" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "${FAKE_LOG}"
ref="${!#}"
case "$*" in
    *"inspect --raw"*)
        case "${ref}" in
            docker-archive:*)
                [ "${FAKE_NO_CONFIG:-0}" = "1" ] && { cat "${FAKE_MANIFEST}"; exit 0; }
                cat "${FAKE_CONFIG}"; exit 0 ;;
            docker://*)
                if [ -f "${FAKE_PUSHED}" ] || [ "${FAKE_DST_EXISTS:-0}" = "1" ]; then
                    [ "${FAKE_NO_CONFIG:-0}" = "1" ] && { cat "${FAKE_MANIFEST}"; exit 0; }
                    cat "${FAKE_CONFIG}"; exit 0
                fi
                exit 0 ;;
        esac ;;
    *"inspect --format"*)
        [ -n "${FAKE_DIGEST:-}" ] && printf '%s\n' "${FAKE_DIGEST}"
        exit 0 ;;
    *"copy"*)
        [ "${FAKE_COPY_FAIL:-0}" = "1" ] && exit 1
        : > "${FAKE_PUSHED}"
        exit 0 ;;
esac
exit 0
FAKE
chmod +x "${TMP}/bin/skopeo"
export PATH="${TMP}/bin:${PATH}"
export FAKE_CONFIG="${TMP}/config.json"
export FAKE_MANIFEST="${TMP}/manifest.json"
export FAKE_DIGEST="${DEST_DIGEST}"

export CLUSTER_CONF="${TMP}/cluster.conf"
# shellcheck source=lib-common.sh
source "${LIB}" >/dev/null 2>&1
load_config >/dev/null 2>&1

reset_state() { : > "${FAKE_LOG}"; rm -f "${FAKE_PUSHED}"; }
copy_count() { grep -c '^copy ' "${FAKE_LOG}" 2>/dev/null || true; }

echo "== ① first push prints repo@digest =="
reset_state
out="$(push_image_digest docker-archive:/tmp/app.tar reg.example/team/app anchor-1 2>/dev/null)"
chk "digest ref" "${out}" "reg.example/team/app@${DEST_DIGEST}"
chk "one copy" "$(copy_count)" "1"
grep -qF 'docker-archive:/tmp/app.tar docker://reg.example/team/app:anchor-1' "${FAKE_LOG}" \
    || fail "copy source/target not found in: $(cat "${FAKE_LOG}")"
pass "pushes to the anchor and prints the digest ref"

echo "== ② identical content skips the push =="
out="$(push_image_digest docker-archive:/tmp/app.tar reg.example/team/app anchor-1 2>/dev/null)"
chk "same digest ref" "${out}" "reg.example/team/app@${DEST_DIGEST}"
chk "no extra copy" "$(copy_count)" "1"

echo "== ③ extra skopeo args are passed through =="
reset_state
push_image_digest docker-archive:/tmp/app.tar reg.example/team/app anchor-2 \
    --retry-times 5 --dest-precompute-digests >/dev/null 2>&1
grep -qF -- '--retry-times 5' "${FAKE_LOG}" || fail "missing --retry-times"
grep -qF -- '--dest-precompute-digests' "${FAKE_LOG}" || fail "missing --dest-precompute-digests"
pass "forwards extra copy args"

echo "== ④ argument validation =="
if push_image_digest docker-archive:/tmp/app.tar reg.example/team/app latest >/dev/null 2>&1; then
    fail "latest anchor should be rejected"
fi
if push_image_digest docker-archive:/tmp/app.tar reg.example/team/app 2.1-latest >/dev/null 2>&1; then
    fail "channel anchor should be rejected"
fi
if push_image_digest docker-archive:/tmp/app.tar reg.example/team/app bad/tag >/dev/null 2>&1; then
    fail "invalid tag should be rejected"
fi
if push_image_digest docker-archive:/tmp/app.tar reg.example/team/app >/dev/null 2>&1; then
    fail "missing anchor should be rejected"
fi
if push_image_digest "" reg.example/team/app anchor >/dev/null 2>&1; then
    fail "empty source should be rejected"
fi
if push_image_digest docker-archive:/tmp/app.tar reg.example/team/app:tag anchor >/dev/null 2>&1; then
    fail "repo with a tag should be rejected"
fi
pass "rejects empty args, channel tags, and invalid tags"

echo "== ⑤ digest resolution failure fails loudly =="
reset_state
export FAKE_DST_EXISTS=1
export FAKE_DIGEST=""
if push_image_digest docker-archive:/tmp/app.tar reg.example/team/app anchor-3 >/dev/null 2>&1; then
    fail "missing target digest should fail"
fi
out="$(push_image_digest docker-archive:/tmp/app.tar reg.example/team/app anchor-3 2>/dev/null || true)"
chk "no partial output" "${out}" ""
unset FAKE_DST_EXISTS FAKE_DIGEST
export FAKE_DIGEST="${DEST_DIGEST}"

echo "== ⑥ manifest-digest fallback still skips identical content =="
reset_state
export FAKE_NO_CONFIG=1
out="$(push_image_digest docker-archive:/tmp/app.tar reg.example/team/app anchor-4 2>/dev/null)"
chk "fallback digest ref" "${out}" "reg.example/team/app@${DEST_DIGEST}"
chk "fallback first push" "$(copy_count)" "1"
push_image_digest docker-archive:/tmp/app.tar reg.example/team/app anchor-4 >/dev/null 2>&1
chk "fallback skips" "$(copy_count)" "1"
unset FAKE_NO_CONFIG

echo "== ⑦ docker:// repo prefix is normalized =="
reset_state
out="$(push_image_digest docker-archive:/tmp/app.tar docker://reg.example/team/app anchor-5 2>/dev/null)"
chk "normalized ref" "${out}" "reg.example/team/app@${DEST_DIGEST}"

echo "all push_image_digest tests passed"
