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
