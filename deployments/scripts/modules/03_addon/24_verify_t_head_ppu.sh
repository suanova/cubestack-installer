#!/bin/bash
# ============================================================
# MODULE: verify_t_head_ppu
# DESC: 端到端验证 T-Head PPU device plugin(ACK PoC 或 native fallback):
#       ① DaemonSet pod Running → ② 节点 allocatable 出现 alibabacloud.com/ppu*
#       → ③ 冒烟 Pod 申请一个 PPU 资源, 断言 /dev/alixpu* 已注入; 若挂载了 SAIL SDK
#          再执行 ppu-smi -L。测试命名空间由 trap 清理。
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# REQUIRES: t_head_ppu
# 说明:
#   · 验证模块不设 TOGGLE, 由 --steps verify_t_head_ppu 或 --steps verify 显式执行。
#   · 门禁看实际部署: DS 不存在且 T_HEAD_PPU_ENABLED≠true 才跳过。
#   · 镜像取自集群内 ConfigMap t-head-ppu-config(source/image), 即 16 模块实际使用的镜像;
#     不读取本地 cluster.conf, 防"配置改了、集群还是旧来源"的错配。
#   · 冒烟 Pod 不要求宿主一定有 SDK: /dev 注入是硬断言; ppu-smi 能跑则额外验证,
#     缺失时输出 PPU_SDK_NOT_MOUNTED 仅告警(ACK 镜像自带用户态库, 仍可正常分配)。
#   · 资源名动态选: 优先 alibabacloud.com/ppu; ACK 若只上报切片资源, 取第一个 ppu-* 键。
# 数据源: cluster.conf (T_HEAD_PPU_* / NODES / SSH_KEY_NAME); 实际镜像来自 ConfigMap
# 用法:   sudo ./deploy-cluster.sh --steps verify_t_head_ppu
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

init_remote_kubectl || exit 1

NS="${T_HEAD_PPU_NAMESPACE:-kube-system}"
TEST_NS="verify-t-head-ppu-$$"
TEST_POD="ppu-smoke"
IMAGE=""
RESOURCE="alibabacloud.com/ppu"

_DEPLOYED="$( (SSH "${K}" -n ${NS} get ds ppu-device-plugin --no-headers 2>/dev/null || true) | wc -l )"
if [ "${_DEPLOYED:-0}" -eq 0 ] && [ "${T_HEAD_PPU_ENABLED:-false}" != "true" ]; then
    say "T-Head PPU 插件未部署(DS 不存在且 T_HEAD_PPU_ENABLED≠true), 跳过验证"
    exit 0
fi

cleanup() {
    SSH "${K}" delete ns "${TEST_NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

say "Verify T-Head PPU device plugin..."

say "  ① 检查 ppu-device-plugin pod 状态..."
_pods="$(SSH "${K}" -n ${NS} get pods -l app.kubernetes.io/name=ppu-device-plugin --no-headers 2>/dev/null || true)"
_total="$(printf '%s\n' "${_pods}" | grep -c . || true)"
_running="$(printf '%s\n' "${_pods}" | awk '$2=="1/1" && $3=="Running"{n++} END{print n+0}')"
[ "${_running:-0}" -ge 1 ] || {
    err "ppu-device-plugin 无 Running pod(${_running}/${_total})"
    SSH "${K}" -n ${NS} get pods -l app.kubernetes.io/name=ppu-device-plugin -o wide 2>/dev/null | sed 's/^/    /' || true
    exit 1
}
ok "    pod Running ${_running}/${_total} ✓"

say "  ② 读取实际来源 + 检查节点 allocatable..."
_source="$(SSH "${K}" -n ${NS} get cm t-head-ppu-config -o jsonpath='{.data.source}' 2>/dev/null || true)"
IMAGE="$(SSH "${K}" -n ${NS} get cm t-head-ppu-config -o jsonpath='{.data.image}' 2>/dev/null || true)"
[ -n "${IMAGE}" ] || { err "ConfigMap ${NS}/t-head-ppu-config 缺少 image(先 --steps t_head_ppu)"; exit 1; }
ok "    来源=${_source:-unknown}; 镜像=${IMAGE}"

_ppu_alloc() {
    (SSH "${K}" get nodes -o json 2>/dev/null || true) | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for n in d.get("items", []):
    name=n.get("metadata",{}).get("name","")
    for k,v in (n.get("status",{}).get("allocatable",{}) or {}).items():
        if k.startswith("alibabacloud.com/ppu"):
            try:
                if int(v) > 0:
                    print(name, k, v)
            except Exception:
                pass'
}
ALLOC="$(_ppu_alloc)"
if [ -z "${ALLOC}" ]; then
    if [ "${T_HEAD_PPU_ALLOW_NO_DEVICE:-false}" = "true" ]; then
        warn "    无 alibabacloud.com/ppu* allocatable(T_HEAD_PPU_ALLOW_NO_DEVICE=true → 跳过冒烟)"
        exit 0
    fi
    err "    无 alibabacloud.com/ppu* allocatable; DS 日志/KMD/设备节点需排查"
    exit 1
fi
ok "    节点资源:"
printf '%s\n' "${ALLOC}" | sed 's/^/      /'

# 优先整卡资源; ACK 若只上报切片, 取第一个 ppu-* 键
if printf '%s\n' "${ALLOC}" | awk '{print $2}' | grep -qx 'alibabacloud.com/ppu'; then
    RESOURCE="alibabacloud.com/ppu"
else
    RESOURCE="$(printf '%s\n' "${ALLOC}" | awk '{print $2}' | grep -m1 '^alibabacloud.com/ppu')"
fi
[ -n "${RESOURCE}" ] || { err "无法确定可申请的 PPU 资源名"; exit 1; }

say "  ③ 冒烟 Pod 申请 ${RESOURCE}:1, 断言设备注入..."
SSH "${K}" create ns "${TEST_NS}" >/dev/null 2>&1 || true
_POD_TMP="$(mktemp)"
cat > "${_POD_TMP}" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${TEST_POD}
  namespace: ${TEST_NS}
spec:
  restartPolicy: Never
  containers:
    - name: smoke
      image: ${IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["/bin/sh", "-c"]
      args:
        - |
          set -e
          ls -l /dev/alixpu /dev/alixpu_ctl
          ls -l /dev/alixpu_ppu*
          if [ -x /usr/local/PPU_SDK/bin/ppu-smi ]; then
            export LD_LIBRARY_PATH=/usr/local/PPU_SDK/lib:/usr/local/PPU_SDK/lib64
            /usr/local/PPU_SDK/bin/ppu-smi -L
          else
            echo "PPU_SDK_NOT_MOUNTED"
          fi
      resources:
        limits:
          ${RESOURCE}: "1"
      volumeMounts:
        - name: ppu-sdk
          mountPath: /usr/local/PPU_SDK
          readOnly: true
  volumes:
    - name: ppu-sdk
      hostPath:
        path: /usr/local/PPU_SDK
        type: DirectoryOrCreate
EOF
SSH "${K}" apply -f - < "${_POD_TMP}" >/dev/null || { rm -f "${_POD_TMP}"; err "冒烟 Pod apply 失败"; exit 1; }
rm -f "${_POD_TMP}"

_phase=""
for _i in $(seq 1 36); do
    _phase="$(SSH "${K}" -n ${TEST_NS} get pod ${TEST_POD} -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "${_phase}" in Succeeded|Failed) break ;; esac
    [ "${_i}" -lt 36 ] && sleep 5
done

_logs="$(SSH "${K}" -n ${TEST_NS} logs ${TEST_POD} 2>/dev/null || true)"
[ -n "${_logs}" ] && printf '%s\n' "${_logs}" | sed 's/^/      /'

if [ "${_phase}" != "Succeeded" ]; then
    err "冒烟 Pod 未成功(phase=${_phase:-Unknown}); 资源=${RESOURCE}, 镜像=${IMAGE}"
    exit 1
fi

printf '%s\n' "${_logs}" | grep -q 'alixpu_ppu' \
    || { err "冒烟 Pod 未看到 /dev/alixpu_ppu*; 设备注入失败"; exit 1; }
ok "    /dev/alixpu* 已注入容器 ✓"

if printf '%s\n' "${_logs}" | grep -q 'PPU_SDK_NOT_MOUNTED'; then
    warn "    宿主 /usr/local/PPU_SDK/bin/ppu-smi 不可用; 已跳过容器内 ppu-smi 验证(设备注入已通过)"
else
    ok "    容器内 ppu-smi 已执行(见上方输出) ✓"
fi

ok "T-Head PPU 验证通过(来源=${_source:-unknown}; 资源=${RESOURCE})"
