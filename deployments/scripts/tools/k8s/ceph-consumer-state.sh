#!/bin/bash
# Ceph cleanup/deployment share per-run TSV markers: namespace, deployment, replicas.
# Source after lib-common.sh; never source the state file itself.
ceph_consumers_init() {
    if [ -z "${CEPH_CONSUMER_STATE_FILE:-}" ]; then
        CEPH_CONSUMER_STATE_FILE="$(mktemp)"
        _CEPH_CONSUMER_STATE_OWNED=1
    elif [ ! -f "${CEPH_CONSUMER_STATE_FILE}" ]; then
        # An earlier failed cleanup restored consumers and removed the shared file.
        (umask 077; : > "${CEPH_CONSUMER_STATE_FILE}")
    fi
}

ceph_consumers_stop_deployment() {
    local ns="$1" name="$2" replicas recorded
    ceph_consumers_init
    replicas="$(SSH "${K} -n ${ns} get deploy ${name} -o jsonpath='{.spec.replicas}' 2>/dev/null")" || return 0
    [[ "${replicas}" =~ ^[0-9]+$ ]] || { warn "  无法读取 ${ns}/${name} 副本数, 跳过停用"; return 0; }
    recorded="$(awk -F '\t' -v ns="${ns}" -v name="${name}" '$1 == ns && $2 == name {print $3}' "${CEPH_CONSUMER_STATE_FILE}")"
    # Guard against a concurrent scale between reading and stopping the deployment.
    if SSH "${K} -n ${ns} scale deploy ${name} --current-replicas=${replicas} --replicas=0 >/dev/null 2>&1"; then
        if [ -z "${recorded}" ]; then
            if ! printf '%s\t%s\t%s\n' "${ns}" "${name}" "${replicas}" >> "${CEPH_CONSUMER_STATE_FILE}"; then
                warn "  无法保存 ${ns}/${name} 副本数, 立即恢复"
                SSH "${K} -n ${ns} scale deploy ${name} --replicas=${replicas} >/dev/null 2>&1" || true
                return 1
            fi
        fi
    fi
}

ceph_consumers_restore_deployment() {
    local ns="$1" name="$2" replicas tmp
    [ -f "${CEPH_CONSUMER_STATE_FILE:-}" ] || return 0
    replicas="$(awk -F '\t' -v ns="${ns}" -v name="${name}" '$1 == ns && $2 == name {print $3}' "${CEPH_CONSUMER_STATE_FILE}")"
    [ -n "${replicas}" ] || return 0
    [[ "${replicas}" =~ ^[0-9]+$ ]] || return 1
    if SSH "${K} -n ${ns} scale deploy ${name} --replicas=${replicas} >/dev/null 2>&1"; then
        tmp="$(mktemp "${CEPH_CONSUMER_STATE_FILE}.XXXXXX")"
        awk -F '\t' -v ns="${ns}" -v name="${name}" '$1 != ns || $2 != name' "${CEPH_CONSUMER_STATE_FILE}" > "${tmp}"
        mv "${tmp}" "${CEPH_CONSUMER_STATE_FILE}"
        say "  已恢复 ${ns}/${name} replicas=${replicas}(此前被覆盖预检停用)"
    else
        warn "  无法恢复 ${ns}/${name} replicas=${replicas}"
        return 1
    fi
}

ceph_consumers_finish() {
    local status="$1" ns name replicas
    [ -f "${CEPH_CONSUMER_STATE_FILE:-}" ] || return 0
    if [ "${status}" != "0" ]; then
        # The entrypoint may fail before any module initialized SSH in its process.
        if [ -s "${CEPH_CONSUMER_STATE_FILE}" ] && ! declare -F SSH >/dev/null; then
            init_remote_kubectl || { warn "  无法初始化消费者恢复连接"; rm -f "${CEPH_CONSUMER_STATE_FILE}"; return 0; }
        fi
        while IFS=$'\t' read -r ns name replicas; do
            [ -n "${ns}" ] || continue
            ceph_consumers_restore_deployment "${ns}" "${name}" || true
        done < "${CEPH_CONSUMER_STATE_FILE}"
    fi
    # Successful child cleanup hands its markers to deployment; standalone cleanup
    # retains the existing success behavior (consumers stay stopped).
    if [ "${status}" != "0" ] || [ "${_CEPH_CONSUMER_STATE_OWNED:-0}" = "1" ]; then
        rm -f "${CEPH_CONSUMER_STATE_FILE}"
    fi
}
