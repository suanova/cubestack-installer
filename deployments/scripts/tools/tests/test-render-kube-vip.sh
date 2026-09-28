#!/bin/bash
# 离线断言: 渲染器能吃下 v2.32 的 kube-vip 模板, 并对 1.0.3 发 vip_subnet
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "${SELF_DIR}/../../../.." && pwd)"
R="${ROOT}/deployments/scripts/tools/k8s/render-kube-vip-manifest.py"
T="${ROOT}/deployments/kubespray/kubespray/roles/kubernetes/node/templates/manifests/kube-vip.manifest.j2"
out="$(python3 "$R" --nodename n1 --vip 10.0.0.9 --template "$T" --image-tag v1.0.3 2>&1)"; rc=$?
[ "$rc" = 0 ] || { echo "  FAIL 渲染失败: $out"; exit 1; }
grep -q 'name: vip_subnet' <<<"$out" && echo "  ok  env = vip_subnet" || { echo "  FAIL 没有 vip_subnet"; exit 1; }
! grep -qE 'name: vip_cidr$' <<<"$out" && echo "  ok  不再发 vip_cidr" || { echo "  FAIL 仍在发 vip_cidr"; exit 1; }
grep -q 'nodename' <<<"$out" && echo "  ok  vip_nodename 在位" || { echo "  FAIL 缺 vip_nodename"; exit 1; }
out2="$(python3 "$R" --nodename n2 --vip 10.0.0.9 --template "$T" --image-tag v1.0.3 2>&1)"
# ⚠ 模板发的是**不带引号**的 `value: {{ inventory_hostname }}`(v2.28 与 v2.32 皆然, 与 address
#   的 `| to_json` 不同), 故只能按不带引号形态断言 —— 09_kube_vip.sh 的渲染后断言同样按 $2 取值。
#   若改成渲染器内嵌引号, 那个 awk 断言会读到 `"n1"` ≠ `n1` 而判定"会脑裂"硬失败, 所以不能那样做。
#   断言取"各渲染出自己的名字, 且**不含**对方的名字"(互不串台 = 防脑裂)。
[ "$(grep -cE '^      value: n1$' <<<"$out")" = 1 ] && ! grep -q 'n2' <<<"$out" \
  && [ "$(grep -cE '^      value: n2$' <<<"$out2")" = 1 ] && ! grep -q 'n1' <<<"$out2" \
  && echo "  ok  逐节点渲染不同(防脑裂)" || { echo "  FAIL 逐节点渲染异常"; exit 1; }

# ---- 反向断言(M3): 旧版 tag 必须走 vip_cidr 分支 ----
# 只断言"新版 → vip_subnet"是**单向**的: 若渲染器把 env 名硬编码成 vip_subnet(不看模板的
# version() 分支), 上面的断言照样全绿 —— 而旧版 kube-vip(<0.9.0)只认 vip_cidr, 收到
# vip_subnet 会**静默忽略**(VIP 起不来), 属只在实机暴露的缺陷。故两个 tag 都要各验一侧。
out3="$(python3 "$R" --nodename n3 --vip 10.0.0.9 --template "$T" --image-tag v0.8.9 2>&1)"; rc=$?
[ "$rc" = 0 ] || { echo "  FAIL 旧 tag 渲染失败: $out3"; exit 1; }
grep -q 'name: vip_cidr' <<<"$out3" && echo "  ok  v0.8.9 → env = vip_cidr(旧版分支)" \
  || { echo "  FAIL v0.8.9 没有 vip_cidr(旧版 kube-vip 会忽略 vip_subnet, VIP 起不来)"; exit 1; }
! grep -q 'vip_subnet' <<<"$out3" && echo "  ok  v0.8.9 不再发 vip_subnet" \
  || { echo "  FAIL v0.8.9 仍在发 vip_subnet"; exit 1; }
echo "✅ 渲染断言全过"
