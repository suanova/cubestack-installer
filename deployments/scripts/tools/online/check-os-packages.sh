#!/bin/bash
set -euo pipefail

# Node prerequisite package check.
#
# These are packages installed on the k8s nodes by the OS package manager
# (lvm2, chrony, curl, rsync, iptables, ...), not container images or k8s
# binaries. The installer does not download or install them; it only checks
# presence, and fails (or warns with --warn-only) with an explicit list.
#
# Usage:
#   ./check-os-packages.sh [--baseline versions/base.yaml] [--group all|reconcile|chrony]
#                          [--hosts user@ip,user@ip] [--key PATH] [--password PW]
#                          [--strict] [--warn-only] [--dry-run]
#
# With no --hosts, the local host is checked. --strict also compares versions.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
BASELINE="${REPO_ROOT}/versions/base.yaml"
GROUP="all"
HOSTS=""
SSH_KEY="${SSH_KEY_DIR:-${HOME}/.ssh}/${SSH_KEY_NAME:-cubestack_k8s}"
SSH_PASSWORD=""
STRICT=0
WARN_ONLY=0
DRY_RUN=0

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "==> $*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --baseline) BASELINE="${2:?--baseline needs a path}"; shift 2 ;;
        --group) GROUP="${2:?--group needs a value}"; shift 2 ;;
        --hosts) HOSTS="${2:?--hosts needs a list}"; shift 2 ;;
        --key) SSH_KEY="${2:?--key needs a path}"; shift 2 ;;
        --password) SSH_PASSWORD="${2:?--password needs a value}"; shift 2 ;;
        --strict) STRICT=1; shift ;;
        --warn-only) WARN_ONLY=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --help|-h) sed -n '2,18p' "$0"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

case "${GROUP}" in all|reconcile|chrony) ;; *) die "--group must be all|reconcile|chrony" ;; esac
command -v python3 >/dev/null 2>&1 || die "python3 is required"

# Resolve the check manifest from the baseline. Output: group<TAB>package<TAB>version
PACKAGES="$(
python3 - "${BASELINE}" "${GROUP}" <<'PY'
import sys
from pathlib import Path
try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required: python3 -m pip install pyyaml")
baseline = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
entries = baseline.get("os") or []
if not entries:
    sys.exit(f"{sys.argv[1]}: os[] is empty")
entry = entries[0]
lock = Path(entry.get("packages_check", ""))
if not lock.is_absolute():
    lock = Path(sys.argv[1]).resolve().parent.parent / lock
if not lock.is_file():
    sys.exit(f"packages_check not found: {lock}")
data = yaml.safe_load(lock.read_text(encoding="utf-8"))
for group, packages in (data.get("packages") or {}).items():
    if sys.argv[2] != "all" and group != sys.argv[2]:
        continue
    for name, version in packages.items():
        print(f"{group}\t{name}\t{version}")
PY
)"
[ -n "${PACKAGES}" ] || die "no packages selected from ${BASELINE}"

# Build the remote check script once; it is piped to bash on each node.
REMOTE_SCRIPT="$(
python3 - "${STRICT}" <<'PY'
import sys
strict = sys.argv[1] == "1"
print("set -u")
print("rc=0")
print("while IFS=$'\\t' read -r group pkg want; do")
print('  [ -n "${pkg}" ] || continue')
print('  status="$(dpkg-query -W -f=\'${Status}\' "${pkg}" 2>/dev/null || true)"')
print('  case "${status}" in')
print('    *"install ok installed"*) ;;')
print('    *) echo "MISSING ${pkg}"; rc=1; continue ;;')
print('  esac')
if strict:
    print('  got="$(dpkg-query -W -f=\'${Version}\' "${pkg}" 2>/dev/null || true)"')
    print('  [ "${got}" = "${want}" ] || { echo "VERSION ${pkg} want=${want} got=${got}"; rc=1; }')
print("done <<'CUBESTACK_PACKAGES'")
PY
)"

# The package data is embedded as a here-doc so the remote script does not
# consume the script itself from stdin.
REMOTE_SCRIPT="${REMOTE_SCRIPT}
${PACKAGES}
CUBESTACK_PACKAGES
exit \${rc}"

check_host() {
    local host="$1" user ip
    if [[ "${host}" == *@* ]]; then
        user="${host%@*}"; ip="${host#*@}"
    else
        user="root"; ip="${host}"
    fi
    [ -n "${ip}" ] || die "empty host in --hosts"

    local out rc=0
    if [ "${DRY_RUN}" = "1" ]; then
        echo "--- ${user}@${ip}"
        printf '%s\n' "${PACKAGES}" | sed 's/^/  /'
        return 0
    fi

    local ssh_opts=(-i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8)
    if printf '%s\n' "${REMOTE_SCRIPT}" | ssh "${ssh_opts[@]}" -o BatchMode=yes "${user}@${ip}" "bash -s" 2>/dev/null; then
        rc=0
    else
        rc=$?
        if [ -n "${SSH_PASSWORD}" ] && command -v sshpass >/dev/null 2>&1; then
            out="$(printf '%s\n' "${REMOTE_SCRIPT}" | SSHPASS="${SSH_PASSWORD}" sshpass -e ssh \
                -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -o PreferredAuthentications=password -o PubkeyAuthentication=no \
                -o ConnectTimeout=8 "${user}@${ip}" "bash -s" 2>/dev/null)" || rc=$?
            [ -n "${out}" ] && printf '%s\n' "${out}"
        fi
    fi
    return "${rc}"
}

say "baseline: ${BASELINE}"
say "group:    ${GROUP} ($(printf '%s\n' "${PACKAGES}" | wc -l | tr -d ' ') packages)"
say "strict:   ${STRICT}"

failed=0
if [ -z "${HOSTS}" ]; then
    say "host: local"
    if [ "${DRY_RUN}" = "1" ]; then
        printf '%s\n' "${PACKAGES}" | sed 's/^/  /'
    else
        # shellcheck disable=SC2086
        if ! printf '%s\n' "${REMOTE_SCRIPT}" | bash -s; then
            failed=1
        fi
    fi
else
    IFS=',' read -r -a host_list <<<"${HOSTS}"
    for host in "${host_list[@]}"; do
        [ -n "${host}" ] || continue
        say "host: ${host}"
        if ! check_host "${host}"; then
            failed=1
        fi
    done
fi

if [ "${failed}" -ne 0 ]; then
    if [ "${WARN_ONLY}" = "1" ]; then
        echo "WARNING: node prerequisite packages are missing (warn-only; continuing)." >&2
        echo "The installer does not install OS packages; prepare them in the OS image." >&2
        exit 0
    fi
    echo "Node prerequisite package pre-check failed. Install the missing packages" >&2
    echo "on the nodes listed above, then rerun. The installer does not install" >&2
    echo "OS packages." >&2
    exit 1
fi
say "Node prerequisite package pre-check passed"
