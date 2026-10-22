#!/bin/bash
# ============================================================
# TOOL: cubestack-component-update
# DESC: 单独更新 CubeStack 平台的一个组件(只推该组件镜像 + patch CR + 滚动该组件;
#       **不重跑 cubestack_operator 模块、不执行 helm upgrade**)
# 背景(2026-10-19 用户口径):
#   · 默认全量部署仍由 cubestack_operator 负责 operator + CR + 全部组件;
#   · 集群/operator 就绪后, 用户希望 `--steps lws` / `--steps cube-pilot` 只更新指定组件,
#     不再每次重跑完整 operator。
# 工作内容:
#   ① 校验 CubeStackCluster CR 存在(operator 已装; 否则提示先跑 --steps cubestack_operator)
#   ② 只推送 offline-files/cubestack-operator/<组件>/ 下该组件的镜像 tar
#      (config-digest 幂等 + IMAGE_PUSH_* 层并行/precompute; 不碰 operator 镜像)
#   ③ 可选 patch CR spec.components.<key>.version / values
#   ④ 按 label cubestack.io/component=<组件> 找到组件 Deployment 并 rollout restart,
#      确保新 Pod 真的从集群 registry/Harbor 重新拉取
# 环境变量(都可选):
#   CUBESTACK_COMPONENT_VERSION       覆盖 CR spec.components.<key>.version
#   CUBESTACK_COMPONENT_VALUES_FILE   组件 values(YAML/JSON), 合并到 CR spec.components.<key>.values
#   CUBESTACK_COMPONENT_PULL_POLICY   第三方组件 image.pullPolicy(默认 Always; 自研组件由 CR global 管)
#   CUBESTACK_COMPONENT_ENABLED       true/false: 覆盖 CR spec.components.<key>.enabled
#   CUBESTACK_COMPONENT_BUNDLES       model-bundles 专用: 逗号分隔的 bundle 名列表 → spec.bundles
#   CUBESTACK_COMPONENT_RESTART       1=rollout restart 组件 Deployment(默认) / 0=不重启
#   CUBESTACK_COMPONENT_RWO_STRATEGY_WAIT_SECONDS
#                                     滚动前等待 Deployment 出现并纠正 RWO 单卷策略的上界(默认 15s)
#                                     引用 ReadWriteOnce PVC 的 Deployment 会先改成 Recreate,
#                                     否则新 Pod 先起会 Multi-Attach(卷被旧 Pod 占用)卡死
#   CUBESTACK_OPERATOR_OFFLINE_DIR    离线 tar 根目录(默认 <repo>/deployments/offline-files/cubestack-operator)
#   CUBESTACK_OPERATOR_NAMESPACE      operator/CR 命名空间(默认 cubestack-system)
# 用法: bash cubestack-component-update.sh <component>
#       component: lws|envoy_gateway|ai_gateway|cubestack_controller_manager|model_bundles|
#                  prometheus|perses|bmc|metax|cuberouter|cubepilot|cubestack_portal|observability
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

COMP="${1:-}"
[ -n "${COMP}" ] || { err "用法: bash $0 <component>"; exit 1; }

# 组件映射: step key → CR key(camelCase) / catalog name(label/目录) / 是否第三方
case "${COMP}" in
    lws)                              _cr="lws";                        _catalog="lws";                       _third=1 ;;
    envoy_gateway|envoy-gateway)      _cr="envoyGateway";               _catalog="envoy-gateway";             _third=1 ;;
    ai_gateway|ai-gateway)            _cr="aiGateway";                  _catalog="ai-gateway";                _third=1 ;;
    cubestack_controller_manager|cubestack-controller-manager|controller_manager)
                                      _cr="cubestackControllerManager";  _catalog="cubestack-controller-manager"; _third=0 ;;
    model_bundles|model-bundles)      _cr="modelBundles";               _catalog="model-bundles";             _third=0 ;;
    prometheus)                       _cr="prometheus";                 _catalog="prometheus";                _third=1 ;;
    perses)                           _cr="perses";                     _catalog="perses";                    _third=1 ;;
    bmc)                              _cr="bmc";                        _catalog="bmc";                       _third=0 ;;
    metax)                            _cr="metax";                      _catalog="metax";                     _third=0 ;;
    cuberouter)                       _cr="cuberouter";                 _catalog="cuberouter";                _third=0 ;;
    cubepilot)                        _cr="cubepilot";                  _catalog="cubepilot";                 _third=0 ;;
    cubestack_portal|cubestack-portal|portal)
                                      _cr="cubestackPortal";            _catalog="cubestack-portal";          _third=0 ;;
    observability)                    _cr="observability";              _catalog="observability";             _third=0 ;;
    *) err "未知组件: ${COMP}"
       err "  可用: lws envoy_gateway ai_gateway cubestack_controller_manager model_bundles prometheus perses bmc metax cuberouter cubepilot cubestack_portal observability"
       exit 1 ;;
esac

NS="${CUBESTACK_OPERATOR_NAMESPACE:-cubestack-system}"
OFFLINE_DIR="${CUBESTACK_OPERATOR_OFFLINE_DIR:-${REPO_ROOT}/deployments/offline-files/cubestack-operator}"
HARBOR_HOST="${CUBESTACK_OPERATOR_HARBOR_HOST:-${HARBOR_MIRROR_REGISTRY:-harbor.isuanova.com}}"
REG_BASE="${REGISTRY_DOMAIN:-${REGISTRY_IP}}:${REGISTRY_PORT:-5000}"
REG_DIRECT="${REGISTRY_DIRECT:-${REGISTRY_IP:-$(first_master_ip)}:${REGISTRY_PORT:-5000}}"

init_remote_kubectl || exit 1

# ⓪ 校验 operator/CR 已存在(本工具**不**负责安装 operator)
CR_NAME="$( (SSH "${K}" -n "${NS}" get csc -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true )"
if [ -z "${CR_NAME}" ]; then
    err "未找到 CubeStackCluster CR(ns=${NS}) —— cubestack_operator 尚未部署"
    err "  先执行: sudo ./deploy-cluster.sh --steps cubestack_operator"
    exit 1
fi
say "单组件更新: ${COMP}(CR=${NS}/${CR_NAME}, catalog=${_catalog}, $( [ "${_third}" = "1" ] && echo 第三方 || echo 自研 ))"

# ① 只推该组件的离线镜像 tar(不碰 operator 镜像)
skopeo_require "cubestack_component"
wait_registry_ready "http://${REG_DIRECT}/v2/" 30 \
    || { err "集群内置 registry ${REG_DIRECT}/v2/ 30s 内不可达"; exit 1; }
image_push_args_init

COMP_DIR="${OFFLINE_DIR}/${_catalog}"
_n_push=0; _n_skip=0; _n_tar=0
if [ -d "${COMP_DIR}" ]; then
    for _tarfile in "${COMP_DIR}"/*.tar; do
        [ -f "${_tarfile}" ] || continue
        _n_tar=$((_n_tar + 1))
        # 目标 ref 以 tar 文件名为权威(与 25_cubestack_operator.sh [4b/6] 同一口径):
        #   <域>_<路径段…>_<tag> ⇒ <域>/<路径>:<tag>; RepoTags 仅作尾部校验。
        _base="$(basename "${_tarfile}" .tar)"
        _domain="${_base%%_*}"
        _tag="${_base##*_}"
        _mid="${_base%_*}"; _mid="${_mid#*_}"
        _src_ref="${_domain}/$(printf '%s' "${_mid}" | tr '_' '/')${_tag:+:${_tag}}"
        _tra="$(tar -xOf "${_tarfile}" manifest.json 2>/dev/null \
            | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["RepoTags"][0])' 2>/dev/null || true)"
        if [ -n "${_tra}" ]; then
            case "${_tra}" in
                *"${_src_ref#*/}") : ;;
                *) warn "  $(basename "${_tarfile}") 文件名解析(${_src_ref})与 RepoTags(${_tra})不符, 跳过"; continue ;;
            esac
        fi
        case "${_src_ref}" in
            "${HARBOR_HOST}"/suanova/*|"${HARBOR_HOST}"/mirrors/*) _dst_path="${_src_ref#${HARBOR_HOST}/}" ;;
            *) _dst_path="mirrors/${_src_ref}" ;;
        esac
        _dst="docker://${REG_DIRECT}/${_dst_path}"
        # config digest 幂等(push 会重压缩层, manifest digest 会变; config digest 稳定)
        _c_dst="$(image_config_digest_raw "${_dst}")"
        _c_src="$(image_config_digest_raw "docker-archive:${_tarfile}")"
        if [ -n "${_c_dst}" ] && [ "${_c_dst}" = "${_c_src}" ]; then
            ok "  ${_dst_path} 内容未变(config digest ${_c_dst:0:19}...), 跳过推送"
            _n_skip=$((_n_skip + 1)); continue
        fi
        _d_dst="$(image_digest_raw "${_dst}")"
        _d_src="$(image_digest_raw "docker-archive:${_tarfile}")"
        if [ -n "${_d_dst}" ] && [ "${_d_dst}" = "${_d_src}" ]; then
            ok "  ${_dst_path} 内容未变(manifest digest ${_d_dst:0:19}...), 跳过推送"
            _n_skip=$((_n_skip + 1)); continue
        fi
        if push_image_skopeo "docker-archive:${_tarfile}" "${_dst}" ${IMAGE_PUSH_ARGS[@]+"${IMAGE_PUSH_ARGS[@]}"}; then
            ok "  ${_dst_path} 已推送(源 $(basename "${_tarfile}"))"
            _n_push=$((_n_push + 1))
        else
            err "  ${_dst_path} 推送失败(检查 registry 可达/磁盘空间)"
            exit 1
        fi
    done
fi
if [ "${_n_tar}" -eq 0 ]; then
    say "  ${COMP_DIR} 下没有镜像 tar —— 该组件为 assets/CR-only 更新(不推镜像)"
fi

# ② 可选 CR patch: version / values / 第三方 pullPolicy
_ver="${CUBESTACK_COMPONENT_VERSION:-}"
_enabled="${CUBESTACK_COMPONENT_ENABLED:-}"
_bundles="${CUBESTACK_COMPONENT_BUNDLES:-}"
_values_json=""
if [ -n "${CUBESTACK_COMPONENT_VALUES_FILE:-}" ]; then
    [ -f "${CUBESTACK_COMPONENT_VALUES_FILE}" ] \
        || { err "CUBESTACK_COMPONENT_VALUES_FILE 不存在: ${CUBESTACK_COMPONENT_VALUES_FILE}"; exit 1; }
    _values_json="$(python3 - "${CUBESTACK_COMPONENT_VALUES_FILE}" <<'PY'
import json, sys
try:
    import yaml
    with open(sys.argv[1]) as f:
        data = yaml.safe_load(f)
except ImportError:
    with open(sys.argv[1]) as f:
        data = json.load(f)
print(json.dumps(data or {}, separators=(",", ":")))
PY
)" || { err "解析 values 文件失败(需 PyYAML 或 JSON): ${CUBESTACK_COMPONENT_VALUES_FILE}"; exit 1; }
fi
_pull_policy="${CUBESTACK_COMPONENT_PULL_POLICY:-}"
if [ -z "${_pull_policy}" ] && [ "${_third}" = "1" ]; then
    _pull_policy="Always"   # 第三方组件不受 CR global.imagePullPolicy 影响; 默认尝试 Always
fi
_patch_json="$(python3 - "${_cr}" "${_ver}" "${_values_json}" "${_pull_policy}" "${_enabled}" "${_bundles}" <<'PY'
import json, sys
cr, ver, vals, pol, enabled, bundles = sys.argv[1:7]
comp = {}
if ver:
    comp["version"] = ver
if enabled != "":
    comp["enabled"] = enabled.lower() in ("true", "1", "yes", "on")
if vals:
    try:
        v = json.loads(vals)
    except Exception:
        v = {}
    if isinstance(v, dict) and v:
        comp["values"] = v
if pol:
    v = comp.setdefault("values", {})
    img = v.get("image")
    if not isinstance(img, dict):
        img = {}
        v["image"] = img
    img["pullPolicy"] = pol
out = {"spec": {"components": {cr: comp}}}
if bundles and cr == "modelBundles":
    out["spec"]["bundles"] = [x.strip() for x in bundles.split(",") if x.strip()]
print(json.dumps(out, separators=(",", ":")))
PY
)"
if [ "${_patch_json}" != '{"spec":{"components":{}}}' ] && [ -n "${_ver}${_values_json}${_pull_policy}${_enabled}${_bundles}" ]; then
    say "  patch CR: spec.components.${_cr}(version=${_ver:-<不变>}, enabled=${_enabled:-<不变>}, values=$([ -n "${_values_json}" ] && echo 有 || echo 无), pullPolicy=${_pull_policy:-<不变>}$([ -n "${_bundles}" ] && echo ", bundles=${_bundles}" || true))"
    printf '%s' "${_patch_json}" | ssh -i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
        "${FIRST_MASTER_USER}@${FIRST_MASTER}" \
        "${K} -n ${NS} patch csc ${CR_NAME} --type=merge --patch-file=/dev/stdin" >/dev/null \
        || { err "patch CR 失败(检查 CRD 字段/operator 状态)"; exit 1; }
    if [ "${_third}" = "1" ] && [ -n "${_pull_policy}" ]; then
        warn "  已尝试 patch ${_catalog} 的 values.image.pullPolicy=${_pull_policy}; 若该 chart 不使用该路径, 请用 CUBESTACK_COMPONENT_VALUES_FILE 指定正确 values"
    fi
fi

# ③ 滚动该组件的 Deployment(新 Pod 才会重新解析 tag; 第三方组件依赖上一步的 pullPolicy)
if [ "${CUBESTACK_COMPONENT_RESTART:-1}" != "0" ]; then
    # ★ 2026-10-19 实机: cubepilot-api 单 RWO PVC + 默认 RollingUpdate → 新 Pod 先起,
    #   在另一节点挂不上同一块 RBD 卷(Multi-Attach), 旧 Pod 又因 maxUnavailable 不退。
    #   滚动前先把它(以及任何引用 RWO PVC 的同组件 Deployment)纠正为 Recreate。
    if ! ensure_rwo_deployments_recreate "${NS}" "cubestack.io/component=${_catalog}" \
            "${CUBESTACK_COMPONENT_RWO_STRATEGY_WAIT_SECONDS:-15}"; then
        err "RWO 单卷 Deployment 的 Recreate 策略纠正失败 —— 中止滚动(否则可能 Multi-Attach)"
        err "  手工: kubectl -n ${NS} get deploy -l cubestack.io/component=${_catalog} -o yaml"
        exit 1
    fi
    # ⚠ 不要用远端 jsonpath(`{range ...}{"\n"}`): 本地单引号剥掉后, 远端 shell 会解析
    #   `{...}`/引号, 查询可能静默空结果 —— 2026-10-19 实测导致"找不到 Deployment"。
    #   用 --no-headers 取表格, 本地按列解析(NS NAME ...)。
    _deploys="$( (SSH "${K} get deploy -A -l cubestack.io/component=${_catalog} --no-headers 2>/dev/null") || true )"
    if [ -z "${_deploys}" ]; then
        warn "  未找到 label cubestack.io/component=${_catalog} 的 Deployment —— 跳过 restart(assets/CR-only 组件正常)"
    else
        while read -r _dns _dn _rest; do
            [ -n "${_dns}" ] || continue
            if SSH "${K} -n ${_dns} rollout restart deploy/${_dn}" </dev/null >/dev/null 2>&1; then
                ok "  已触发滚动: ${_dns}/deploy/${_dn}"
            else
                warn "  滚动失败: ${_dns}/deploy/${_dn}"
            fi
        done <<< "${_deploys}"
    fi
fi

# ③b envoy-gateway: 数据面 Service 类型对齐 SERVICE_EXPOSE_MODE
#   operator 的 CR serviceExposeMode 不作用于 Envoy Gateway 的默认 EnvoyProxy; 单独更新
#   envoy-gateway 后 Gateway/Service 可能被重建, 这里重新挂一次(幂等)。
if [ "${_cr}" = "envoyGateway" ]; then
    say "  对齐 Envoy Gateway 数据面 Service 类型(SERVICE_EXPOSE_MODE=${SERVICE_EXPOSE_MODE:-metallb})..."
    ensure_envoy_gateway_service_type "${SERVICE_EXPOSE_MODE:-metallb}" \
        || warn "  Envoy Gateway 数据面 Service 类型未确认"
fi

echo "---------------------------------------------"
say "组件 ${COMP}: 镜像新推 ${_n_push} / digest 跳过 ${_n_skip} / tar ${_n_tar}"
ok "单组件更新完成(未重跑 cubestack_operator)"
echo "  验证: kubectl -n ${NS} get csc ${CR_NAME} -o json | jq '.status.components'"
echo "        kubectl get deploy -A -l cubestack.io/component=${_catalog} -o wide"
