#!/bin/bash
# ============================================================
# test-image-push-optimize.sh — 大镜像推送加速的离线回归(无需 registry/集群)
# 覆盖:
#   ① image_config_digest_raw: 单架构清单取 .config.digest; 多架构 index 返回空(调用方回退)
#   ② image_push_args_init: 默认参数(层级并发/precompute/retry)与非法值降级
#   ③ push_image_skopeo: 额外参数原样透传给 skopeo copy
#   ④ parallel_run: 有界并发(max=2 时 4 个任务的最大并发恰为 2)
#   ⑤ 36_dev_lab / 37_model_images 已接入 config-digest 幂等 + 并行 runner
#   ⑥ cluster.defaults.conf 默认值声明
# 隔离: CLUSTER_CONF=临时配置 + PATH 前置假 skopeo(纯离线)
# 用法: bash deployments/scripts/tools/tests/test-image-push-optimize.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
M36="${REPO_ROOT}/deployments/scripts/modules/03_addon/36_dev_lab.sh"
M37="${REPO_ROOT}/deployments/scripts/modules/03_addon/37_model_images.sh"
LIB="${REPO_ROOT}/deployments/scripts/lib-common.sh"
DEFAULTS="${REPO_ROOT}/deployments/config/cluster.defaults.conf"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  ok  $1"; else echo "  FAIL $1: [$3] 未包含 [$2]"; fail=1; fi; }

# 临时配置(空 NODES; 关闭版本档案)
cat > "${TMP}/cluster.conf" <<'EOF'
NODES=()
SSH_USER="root"
KUBESPRAY_PROFILE="none"
EOF

# 假 skopeo: inspect --raw 输出夹具; copy 仅记录参数
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/skopeo" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "${FAKE_SKOPEO_LOG:-/dev/null}"
case "$*" in
    *"inspect --raw"*) [ -f "${FAKE_RAW_FILE:-/nonexistent}" ] && cat "${FAKE_RAW_FILE}"; exit 0 ;;
    *"copy"*) exit 0 ;;
esac
exit 0
FAKE
chmod +x "${TMP}/bin/skopeo"
export PATH="${TMP}/bin:${PATH}"
export CLUSTER_CONF="${TMP}/cluster.conf"
export FAKE_SKOPEO_LOG="${TMP}/skopeo.log"
: > "${FAKE_SKOPEO_LOG}"

# shellcheck source=lib-common.sh
source "${LIB}" >/dev/null 2>&1
load_config >/dev/null 2>&1

echo "== ① image_config_digest_raw =="
cat > "${TMP}/single.json" <<'JSON'
{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json","config":{"digest":"sha256:cfg123","mediaType":"application/vnd.docker.container.image.v1+json"},"layers":[]}
JSON
cat > "${TMP}/index.json" <<'JSON'
{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"platform":{"architecture":"amd64","os":"linux"},"digest":"sha256:m1"}]}
JSON
export FAKE_RAW_FILE="${TMP}/single.json"
chk "单架构取 config.digest" "sha256:cfg123" "$(image_config_digest_raw docker://x)"
export FAKE_RAW_FILE="${TMP}/index.json"
chk "多架构 index 返回空" "" "$(image_config_digest_raw docker://x)"
export FAKE_RAW_FILE="${TMP}/does-not-exist"
chk "inspect 无输出返回空" "" "$(image_config_digest_raw docker://x)"

echo "== ② image_push_args_init =="
IMAGE_PUSH_ARGS=()
image_push_args_init
chk "默认参数个数" "5" "${#IMAGE_PUSH_ARGS[@]}"
printf '%s\n' "${IMAGE_PUSH_ARGS[@]}" > "${TMP}/args.txt"
chk_contains "层级并发开关" "--image-parallel-copies" "${TMP}/args.txt"
chk_contains "层级并发默认 4" "4" "${TMP}/args.txt"
chk_contains "precompute 默认开" "--dest-precompute-digests" "${TMP}/args.txt"
chk_contains "retry 默认 5" "--retry-times" "${TMP}/args.txt"
IMAGE_PUSH_PARALLEL_LAYERS=1 IMAGE_PUSH_PRECOMPUTE_DIGESTS=false IMAGE_PUSH_RETRY_TIMES=0 image_push_args_init
chk "全关时参数为空" "0" "${#IMAGE_PUSH_ARGS[@]}"
IMAGE_PUSH_PARALLEL_LAYERS=abc IMAGE_PUSH_PRECOMPUTE_DIGESTS=true IMAGE_PUSH_RETRY_TIMES=xyz image_push_args_init
chk "非法值降级(仅 precompute)" "1" "${#IMAGE_PUSH_ARGS[@]}"

echo "== ③ push_image_skopeo 参数透传 =="
IMAGE_PUSH_PARALLEL_LAYERS=4 IMAGE_PUSH_PRECOMPUTE_DIGESTS=true IMAGE_PUSH_RETRY_TIMES=5 image_push_args_init
: > "${FAKE_SKOPEO_LOG}"
push_image_skopeo docker-archive:/tmp/x.tar docker://reg/x:tag "${IMAGE_PUSH_ARGS[@]}" >/dev/null 2>&1
chk "copy 调用成功" "0" "$?"
chk_contains "透传并行层" "--image-parallel-copies 4" "${FAKE_SKOPEO_LOG}"
chk_contains "透传 precompute" "--dest-precompute-digests" "${FAKE_SKOPEO_LOG}"
chk_contains "透传 retry" "--retry-times 5" "${FAKE_SKOPEO_LOG}"
chk_contains "源/目标在位" "docker-archive:/tmp/x.tar docker://reg/x:tag" "${FAKE_SKOPEO_LOG}"

echo "== ④ parallel_run 有界并发 =="
COUNT_FILE="${TMP}/count"; MAX_FILE="${TMP}/max"; LOCK_FILE="${TMP}/lock"; DONE_FILE="${TMP}/done"
echo 0 > "${COUNT_FILE}"; echo 0 > "${MAX_FILE}"; : > "${DONE_FILE}"
_test_worker() {
    local id="$1"
    (
        flock 9
        cur=$(( $(cat "${COUNT_FILE}") + 1 ))
        echo "${cur}" > "${COUNT_FILE}"
        [ "${cur}" -gt "$(cat "${MAX_FILE}")" ] && echo "${cur}" > "${MAX_FILE}"
        flock -u 9
    ) 9>"${LOCK_FILE}"
    sleep 0.3
    (
        flock 9
        cur=$(( $(cat "${COUNT_FILE}") - 1 ))
        echo "${cur}" > "${COUNT_FILE}"
        flock -u 9
    ) 9>"${LOCK_FILE}"
    echo "${id}" >> "${DONE_FILE}"
}
parallel_run 2 _test_worker 1 2 3 4
chk "最大并发=2" "2" "$(cat "${MAX_FILE}")"
chk "4 个任务全部执行" "4" "$(sort -u "${DONE_FILE}" | wc -l)"

echo "== ⑤ 模块接入 =="
chk_contains "36 使用 config digest 幂等" "image_config_digest_raw" "${M36}"
chk_contains "37 使用 config digest 幂等" "image_config_digest_raw" "${M37}"
chk_contains "36 使用并行 runner" "parallel_run" "${M36}"
chk_contains "37 使用并行 runner" "parallel_run" "${M37}"
chk_contains "36 初始化 push 参数" "image_push_args_init" "${M36}"
chk_contains "37 初始化 push 参数" "image_push_args_init" "${M37}"

echo "== ⑥ 默认值声明 =="
chk_contains "默认层级并发" 'IMAGE_PUSH_PARALLEL_LAYERS="${IMAGE_PUSH_PARALLEL_LAYERS:-4}"' "${DEFAULTS}"
chk_contains "默认镜像并发" 'IMAGE_PUSH_PARALLEL_IMAGES="${IMAGE_PUSH_PARALLEL_IMAGES:-2}"' "${DEFAULTS}"
chk_contains "默认 precompute" 'IMAGE_PUSH_PRECOMPUTE_DIGESTS="${IMAGE_PUSH_PRECOMPUTE_DIGESTS:-true}"' "${DEFAULTS}"
chk_contains "默认 retry" 'IMAGE_PUSH_RETRY_TIMES="${IMAGE_PUSH_RETRY_TIMES:-5}"' "${DEFAULTS}"

echo ""
if [ "${fail}" = "0" ]; then
    echo "✅ test-image-push-optimize: 全部通过"
else
    echo "❌ test-image-push-optimize: 存在失败项"
fi
exit "${fail}"
