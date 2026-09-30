#!/bin/bash
# ============================================================
# lib-kubespray-tables.sh — 读 **kubespray 树内版本表**的共享解析器
#
# 为什么要有这个库: "树内表值"有两处消费者, 且**必须口径一致**:
#   ① check-modules.sh ⑯(k8s 基座钉子 ↔ 仓库树表值; 每次 PR 跑)
#   ② cubestack-version-dir.sh new 的档案骨架推导(从**任意树** — 如 tag 检出 — 机械取值)
# 两处各写一套 = 必然漂移(⑯-C 的教训就是"镜像的表要一起改")。故下沉到这里, 双方共享。
#
# 约定: 本库**不 source lib-common.sh**、不依赖任何全局变量 —— 每个函数显式接收文件路径,
#   (CI / 任意树 / fixture 都能用)。
# 用法: source lib-kubespray-tables.sh
#   树内文件(相对树根 roles/kubespray_defaults/):
#     defaults/main/download.yml      ← 标量与内联查表(nginx_image_tag / coredns_supported_versions…)
#     vars/main/checksums.yml         ← 各 *_checksums 表(calicoctl / kubelet / etcd 二进制校验和)
#     vars/main/main.yml              ← etcd_supported_versions(带版本区间)
# ⚠ 语义与上游 Jinja 表达式逐条对应(在 check-modules.sh ⑯ 的注释里有出处), 改这里等于改判据。
# ============================================================
set -uo pipefail

# checksums.yml: 某小节下 <arch> 的**首个**版本键(上游 (…|dict2items)[0].key 的语义)
kb_tables_first_key() {   # <checksums.yml> <section> <arch>
    awk -v want="$2" -v arch="$3" '
        /^[a-zA-Z_]+_checksums:/ { sec=$1; sub(/:$/,"",sec); a=0 }
        sec==want && /^  [a-z0-9_]+:$/ { a=($1 == arch ":"); next }
        a && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+:$/ { v=$1; sub(/:$/,"",v); print v; exit }
    ' "$1"
}

# checksums.yml: etcd_binary_checksums 里文件顺序首个 < <bound> 的键(bound 从 vars/main/main.yml 现读)
kb_tables_etcd() {   # <checksums.yml> <vars/main/main.yml> <major>
    local bound
    bound="$(sed -n "/^etcd_supported_versions:/,/^[^[:space:]]/p" "$2" \
             | grep -F "'$3':" \
             | sed -n "s/.*select('version', '\([^']*\)',.*/\1/p" | head -1)"
    [ -n "${bound}" ] || return 0
    awk -v b="${bound}" '
        function vlt(x, y,   n, m, i, xa, ya) {
            n=split(x, X, "."); m=split(y, Y, ".")
            for (i=1; i<=(n>m?n:m); i++) {
                xa=(i<=n)?X[i]+0:0; ya=(i<=m)?Y[i]+0:0
                if (xa<ya) return 1; if (xa>ya) return 0
            }
            return 0
        }
        /^[a-zA-Z_]+_checksums:/ { sec=$1; sub(/:$/,"",sec); a=0 }
        sec=="etcd_binary_checksums" && /^  [a-z0-9_]+:$/ { a=($1=="amd64:"); next }
        a && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+:$/ { v=$1; sub(/:$/,"",v); if (vlt(v,b)) { print v; exit } }
    ' "$1"
}

# yml 里的内联查表(coredns_supported_versions / pod_infra_supported_versions)取 <major> 行
kb_tables_inline() {   # <yml 文件> <表名> <major>
    sed -n "/^$2:/,/^[^[:space:]]/p" "$1" | grep -F "'$3':" | head -1 \
        | sed -E "s/^[^:]+:[[:space:]]*//; s/[[:space:]]*#.*//" | tr -d "\"'"
}

# yml 里的标量版本变量(如 nodelocaldns_version: "1.25.0")
kb_tables_scalar() {   # <yml 文件> <变量名>
    grep -m1 -E "^$2:" "$1" | sed -E "s/^[^:]+:[[:space:]]*//; s/[[:space:]]*#.*//" | tr -d "\"'"
}

# kubelet_checksums 成员判定(<ver> → 输出 1/0) —— 判"该版本在表内"(可安装版本全集)
kb_tables_kubelet_has() {   # <checksums.yml> <ver>
    awk -v want="$2" '
        /^kubelet_checksums:/ { s=1; next }
        /^[a-zA-Z_]+_checksums:/ { s=0 }
        s && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+:$/ { v=$1; sub(/:$/,"",v); if (v==want) { print "1"; exit } }
    ' "$1"
}

# kubelet_checksums 表内全部版本(升序文件顺序; 供"必须显式选一个在表内的版本"时给候选)
kb_tables_kubelet_list() {   # <checksums.yml>
    awk '
        /^kubelet_checksums:/ { s=1; next }
        /^[a-zA-Z_]+_checksums:/ { s=0 }
        s && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+:$/ { v=$1; sub(/:$/,"",v); print v }
    ' "$1"
}

# ============================================================
# 跨版本布局容忍层(2026-09-30)
#
# 实测 kubespray 的"k8s 线 → 组件版本"支持矩阵在版本间漂移, 共三种形态:
#   ① 表所在**文件**不同: v2.28 的 pod_infra/etcd 在 defaults/main/download.yml, v2.32 在 vars/main/main.yml
#   ② 同一个键的**值形态**不同: v2.28 `'1.32': 3.5.16`(字面量) / v2.32 `'1.35': "{{ (etcd_binary_checksums…select('version','3.7','<'))[0] }}"`
#   ③ 有的版本**没有表**: v2.28 的 coredns 是单行条件表达式
#      `coredns_version: "{{ '1.11.3' if (kube_version is version('1.30.5', '>=')) else '1.11.1' }}"`
#
# 本层把这三种都求值成**一个版本字符串**; 形态不认识时**输出空**, 由调用方报错并把原文打给人工
#   —— 绝不猜(猜错 = 订到错误的镜像 tag, 部署期才炸)。
# ============================================================

# 版本比较: <a> <op> <b>(op ∈ >= > <= < ==) → 0/1
kb_tables_vercmp() {   # <a> <op> <b>
    awk -v a="$1" -v op="$2" -v b="$3" '
        function cmp(x, y,   n, m, i, xa, ya) {
            n=split(x, X, "."); m=split(y, Y, ".")
            for (i=1; i<=(n>m?n:m); i++) {
                xa=(i<=n)?X[i]+0:0; ya=(i<=m)?Y[i]+0:0
                if (xa<ya) return -1; if (xa>ya) return 1
            }
            return 0
        }
        BEGIN { c=cmp(a,b)
            r = (op==">=" ? c>=0 : op==">" ? c>0 : op=="<=" ? c<=0 : op=="<" ? c<0 : op=="==" ? c==0 : 0)
            print (r ? "1" : "0") }'
}

# 取 <表> 在 <major> 键的**原样**取值文本(跨两个候选文件找; 找不到输出空)
kb_tables_raw() {   # <树根> <表名> <major>
    local t="$1" tbl="$2" major="$3" f line
    for f in "${t}/roles/kubespray_defaults/vars/main/main.yml" \
             "${t}/roles/kubespray_defaults/defaults/main/download.yml"; do
        [ -f "${f}" ] || continue
        line="$(sed -n "/^${tbl}:/,/^[^[:space:]]/p" "${f}" | grep -F "'${major}':" | head -1)"
        [ -n "${line}" ] || continue
        line="${line#*:}"
        line="$(printf '%s' "${line}" | sed -E 's/[[:space:]]*#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
        printf '%s' "${line}"; return 0
    done
    return 0
}

# 求值: 支持矩阵里 <表>['<major>'] → 版本字符串(跨版本三种形态 + 标量回退; 认不出输出空)
# 解析链: ① 表键(两个文件里找) → 求值 ② 表缺 → 标量 <表基名>_version(v2.28 的 coredns 即此形) → 求值
#         ③ 都认不出 → 空(由调用方报原文, 人工补规则)
kb_tables_version_for() {   # <树根> <表名> <major>
    local t="$1" tbl="$2" major="$3" raw=""
    raw="$(kb_tables_raw "${t}" "${tbl}" "${major}")"
    if [ -z "${raw}" ]; then
        # ② 标量回退: <表基名>_version(coredns_supported_versions → coredns_version)
        local sname="${tbl%_supported_versions}_version" f line
        for f in "${t}/roles/kubespray_defaults/vars/main/main.yml" \
                 "${t}/roles/kubespray_defaults/defaults/main/download.yml"; do
            [ -f "${f}" ] || continue
            line="$(grep -m1 -E "^${sname}:" "${f}" || true)"
            [ -n "${line}" ] || continue
            raw="$(printf '%s' "${line#*:}" | sed -E 's/[[:space:]]*#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
            break
        done
        [ -n "${raw}" ] || return 0
    fi
    _kb_tables_eval_expr "${t}" "${tbl}" "${major}" "${raw}"
}

# 求值一个"值文本"(字面量 / Jinja select / 条件表达式)
_kb_tables_eval_expr() {   # <树根> <表名(取 checksums 段用)> <major> <raw>
    local t="$1" tbl="$2" major="$3" raw="$4" ck
    ck="${t}/roles/kubespray_defaults/vars/main/checksums.yml"
    # ⚠ 先判表达式, 再判字面量 —— 反了会把 Jinja 表达式"去掉引号当值"返回(实测踩过)
    case "${raw}" in
        *'{{'*)
            # 形态 B: select('version', '<bound>', '<op>') 等值取 <table>_checksums 里首个满足的键
            if printf '%s' "${raw}" | grep -q "select('version'"; then
                local sec bound op
                sec="${tbl%_supported_versions}"
                [ "${tbl}" = "etcd_supported_versions" ] && sec="etcd_binary"
                bound="$(printf '%s' "${raw}" | sed -nE "s/.*select\('version', *'([^']*)'.*/\1/p" | head -1)"
                op="$(printf '%s' "${raw}" | sed -nE "s/.*select\('version', *'[^']*', *'([^']*)'.*/\1/p" | head -1)"
                [ -n "${bound}" ] || return 0
                awk -v want="${sec}_checksums" -v b="${bound}" -v op="${op}" '
                    function cmp(x, y,   n, m, i, xa, ya) {
                        n=split(x, X, "."); m=split(y, Y, ".")
                        for (i=1; i<=(n>m?n:m); i++) {
                            xa=(i<=n)?X[i]+0:0; ya=(i<=m)?Y[i]+0:0
                            if (xa<ya) return -1; if (xa>ya) return 1
                        }
                        return 0
                    }
                    /^[a-zA-Z_]+_checksums:/ { sec=$1; sub(/:$/,"",sec); a=0 }
                    sec==want && /^  [a-z0-9_]+:$/ { a=($1=="amd64:"); next }
                    a && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+:$/ {
                        v=$1; sub(/:$/,"",v); c=cmp(v,b)
                        ok = (op=="<" ? c<0 : op=="<=" ? c<=0 : op==">" ? c>0 : op==">=" ? c>=0 : 0)
                        if (ok) { print v; exit }
                    }
                ' "${ck}"
                return 0
            fi
            # 形态 C: 'X' if (kube_version is version('B', '>=')) else 'Y'
            if printf '%s' "${raw}" | grep -qE "if .*kube_version is version\("; then
                local x y bound2 op2
                x="$(printf '%s' "${raw}" | sed -nE "s/.*'([^']*)' *if.*/\1/p" | head -1)"
                y="$(printf '%s' "${raw}" | sed -nE "s/.*else *'([^']*)'.*/\1/p" | head -1)"
                bound2="$(printf '%s' "${raw}" | sed -nE "s/.*kube_version is version\('([^']*)'.*/\1/p" | head -1)"
                op2="$(printf '%s' "${raw}" | sed -nE "s/.*kube_version is version\('[^']*', *'([^']*)'.*/\1/p" | head -1)"
                [ -n "${x}" ] && [ -n "${y}" ] && [ -n "${bound2}" ] || return 0
                [ -n "${op2}" ] || op2=">="
                if [ "$(kb_tables_vercmp "${major}.0" "${op2}" "${bound2}")" = "1" ]; then
                    printf '%s' "${x}"
                else
                    printf '%s' "${y}"
                fi
                return 0
            fi
            return 0 ;;   # 认不出的表达式形态 → 空(不猜)
        *)
            # 形态 A: 字面量('3.10' / 3.5.16 / "3.10.2")
            printf '%s' "${raw//[\"\']/}"
            return 0 ;;
    esac
}

