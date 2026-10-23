#!/bin/bash
# ============================================================
# check-secrets.sh — 凭据/公网地址卫生门禁(硬性规则; 2026-10-16 明文入库事故后落地)
# ------------------------------------------------------------
# 规则(命中即失败, exit 1):
#   ① 路径硬规则: 凭据类文件一律不得被 git 跟踪 ——
#      cluster.conf / minio.conf / *.bak* / external-ceph* / *.env(白名单 *.env.example、
#      deployments/releases/*/release.env —— 发布版本元数据, 按设计入库; 内容规则仍扫描它)
#   ② 内容硬规则(逐行, 行尾附 "# secret-scan: allow" 可豁免单行):
#      · 密码类赋值: password/passwd/secret/token/api_key/access_key = <非占位值>;
#        占位白名单: ${VAR}、<...>、CHANGE_ME、占位、示例占位词、空值、布尔;
#      · PEM 私钥块(BEGIN ... PRIVATE KEY);
#      · 公网 IPv4(白名单: 常见公共 DNS 223.5.5.5 / 114.114.114.114 / 8.8.8.8 / 1.1.1.1 等;
#        内网/回环/链路本地不报)。
#   ③ 本地禁词表(可选, **gitignored**, 不进仓库): deployments/config/secret-blocklist.txt
#      每行一条真实密文/敏感地址 → 逐字匹配; 事故密文只存这里, 绝不写进本脚本源码。
# 用法: check-secrets.sh [--staged | --all | --history]
#   (默认)  扫 git 跟踪文件——CI 与提交后自查用
#   --staged 只扫暂存内容(pre-commit 钩子调用)
#   --all    额外扫未跟踪(未忽略)文件
#   --history 历史全量巡检(仅按本地禁词表 pickaxe; 无禁词表则跳过)
# 退出码: 0=净; 1=有命中(逐条打印 文件:行)
# ============================================================
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "不在 git 仓库内"; exit 2; }
cd "${ROOT}"
BLOCKLIST="${ROOT}/deployments/config/secret-blocklist.txt"
MODE="tracked"
case "${1:-}" in
    --staged)  MODE="staged" ;;
    --all)     MODE="all" ;;
    --history) MODE="history" ;;
    "")        : ;;
    *) echo "未知参数: $1"; exit 2 ;;
esac

HITS=0
report() { HITS=$((HITS+1)); printf '  ✗ %s:%s: %s\n' "$1" "$2" "$3"; }

# ---------- ① 路径硬规则 ----------
if [ "${MODE}" = "tracked" ] || [ "${MODE}" = "all" ]; then
    while IFS= read -r f; do
        case "${f}" in
            *.env.example) continue ;;
            # 发布树清单是**版本元数据**(RELEASE_VERSION/KUBESPRAY_VERSION/镜像 tag), 不是凭据;
            # 它按设计入库供 load_config / release-publish / 测试读取。内容规则(②)仍会扫描,
            # 真把密码/私钥写进去照样会被命中(2026-10-23 CI 误报)。
            deployments/releases/*/release.env) continue ;;
        esac
        case "${f}" in
            */cluster.conf|*/minio.conf|*/secret-blocklist.txt|*.env|*.bak|*.bak.*|*external-ceph*) \
                report "${f}" "-" "凭据类文件被 git 跟踪(② 路径硬规则)" ;;
        esac
    done < <(git ls-files)
fi

# ---------- 扫描文件清单 ----------
list_files() {
    case "${MODE}" in
        staged)  git diff --cached --name-only --diff-filter=ACM ;;
        all)     { git ls-files; git ls-files --others --exclude-standard; } ;;
        *)       git ls-files ;;
    esac | sort -u
}
# 形状启发式(password/IP)的作用域: 排除 vendored 上游树/第三方 chart/前端/旧应用 ——
# 这些来源充满 schema 属性名/示例凭据/版本号(x.y.z 形似 IPv4), 实测 908 误报;
# 禁词表(③)对**全部路径**生效, 不受此排除影响。
_heuristic_scope() {  # <file> → 0=做启发式
    case "$1" in
        deployments/kubespray/*|deployments/cubestack-addon/*|ui/*|installer/*) return 1 ;;
        *) return 0 ;;
    esac
}
content_of() {  # <file> → stdout
    if [ "${MODE}" = "staged" ]; then git show ":$1" 2>/dev/null; else cat "$1" 2>/dev/null; fi
}

# ---------- ② 内容硬规则(二进制自动跳过: grep -I 语义由文件类型判断近似)----------
_IP_ALLOW='^(223\.5\.5\.5|114\.114\.114\.114|8\.8\.8\.8|1\.1\.1\.1|0\.0\.0\.0|255\.255\.255\.255|1\.2\.3\.4)$'   # 1.2.3.4=文档/测试经典示例地址
while IFS= read -r f; do
    [ -n "${f}" ] || continue
    content_of "${f}" > /tmp/.check-secrets.$$ 2>/dev/null || continue
    command grep -qI . /tmp/.check-secrets.$$ 2>/dev/null || { rm -f /tmp/.check-secrets.$$; continue; }
    if ! _heuristic_scope "${f}"; then rm -f /tmp/.check-secrets.$$; continue; fi
    # 密码类赋值(排除占位)
    while IFS=: read -r ln _rest; do
        line="$(sed -n "${ln}p" /tmp/.check-secrets.$$)"
        case "${line}" in *"secret-scan: allow"*) continue ;; esac
        val="$(printf '%s' "${line}" | sed -E 's/.*(password|passwd|secret[_-]?key|secret|token|api[_-]?key|access[_-]?key)[[:space:]]*[:=][[:space:]]*["'"'"']?([^"'"'"'[:space:]]+).*/\2/I')"
        # sed 未匹配时按语义回退为整行(${val} 与 ${line} 相等)—— 未匹配 = 关键词后无有效取值 → 跳过
        [ "${val}" = "${line}" ] && continue
        # 过短(占位 p/u/xxx)与过长截断形态, 不构成泄露面
        [ "${#val}" -lt 6 ] && continue
        # 中文说明性取值(bash case 的多字节区间不可靠, 用 grep -P)
        printf '%s' "${val}" | command grep -qP '[\x{4e00}-\x{9fa5}]' && continue
        case "${val}" in
            *'${'*|'<'*|'...'|CHANGE_ME|changeme|CHANGE-ME|*change*|*CHANGE*|*Change*|xxxx*|Xxxx*|placeholder|PLACEHOLDER|占位|example|EXAMPLE|your_*|YOUR_*|none|NULL|null|true|false|True|False|'*') continue ;;
            # 代码字面量(含调用/索引/比较/拼接符)与模板残片({}/)一律跳过
            *'('*|*')'*|*'['*|*']'*|*','*|*';'*|*'&&'*|*'||'*|*'=>'*|*'{'*|*'}'*) continue ;;
        esac
        report "${f}" "${ln}" "疑似明文密码赋值(值已隐去; 请改占位符/环境变量)"
    done < <(command grep -nEi '(password|passwd|secret[_-]?key|secret|token|api[_-]?key|access[_-]?key)[[:space:]]*[:=]' /tmp/.check-secrets.$$ 2>/dev/null)
    # PEM 私钥
    while IFS=: read -r ln _rest; do
        report "${f}" "${ln}" "PEM 私钥块(禁止入库)"
    done < <(command grep -nE 'BEGIN (RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY' /tmp/.check-secrets.$$ 2>/dev/null)
    # 公网 IPv4(白名单外)
    while IFS=: read -r ln _rest; do
        line="$(sed -n "${ln}p" /tmp/.check-secrets.$$)"
        case "${line}" in *"secret-scan: allow"*) continue ;; esac
        for ip in $(printf '%s' "${line}" | command grep -oE '(^|[^0-9A-Za-z._-])(([0-9]{1,3}\.){3}[0-9]{1,3})([^0-9A-Za-z._-]|$)' | command grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}'); do
            printf '%s' "${ip}" | command grep -qE "${_IP_ALLOW}" && continue
            python3 -c "
import ipaddress,sys
try: a=ipaddress.ip_address(sys.argv[1])
except ValueError: sys.exit(0)   # 无效八位组(如 495.x) = 非 IP, 跳过
sys.exit(0 if (a.is_private or a.is_loopback or a.is_link_local or a.is_multicast or a.is_reserved) else 1)" "${ip}" \
                || report "${f}" "${ln}" "公网 IPv4 出现: ${ip}(② 内容硬规则; 误报可加 secret-scan: allow)"
        done
    done < <(command grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}' /tmp/.check-secrets.$$ 2>/dev/null)
    rm -f /tmp/.check-secrets.$$
done < <(list_files)

# ---------- ③ 本地禁词表(逐字) ----------
if [ -f "${BLOCKLIST}" ]; then
    while IFS= read -r pat; do
        case "${pat}" in ''|\#*) continue ;; esac
        if [ "${MODE}" = "history" ]; then
            n="$(git log --all --oneline -S "${pat}" 2>/dev/null | wc -l)"
            [ "${n}" -gt 0 ] && report "(history)" "-" "禁词命中 ${n} 个提交(密文已隐去)"
        else
            while IFS= read -r f; do
                [ -n "${f}" ] || continue
                if content_of "${f}" 2>/dev/null | command grep -qF -- "${pat}"; then
                    report "${f}" "-" "本地禁词表命中(密文已隐去)"
                fi
            done < <(list_files)
        fi
    done < "${BLOCKLIST}"
elif [ "${MODE}" = "history" ]; then
    echo "  (无本地禁词表 ${BLOCKLIST}, --history 跳过)"
fi

echo "──────────────────────────────"
if [ "${HITS}" = "0" ]; then
    echo "✅ 凭据/公网地址卫生检查通过(${MODE})"
    exit 0
else
    echo "❌ 命中 ${HITS} 处; 规则与豁免: 见本脚本头部(行尾 'secret-scan: allow')"
    exit 1
fi
