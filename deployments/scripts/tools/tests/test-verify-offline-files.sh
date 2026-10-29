#!/bin/bash
# ============================================================
# test-verify-offline-files.sh — verify-offline-files.sh 离线回归
# 覆盖: 布局识别/清单覆盖/结构/哈希/校验戳/seal/JSON/退出码
# 用法: bash deployments/scripts/tools/tests/test-verify-offline-files.sh
# ============================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TOOL="${REPO_ROOT}/deployments/scripts/tools/offline/verify-offline-files.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: 期望[$2] 实际[$3]"; fail=1; fi; }
chk_contains() { if [[ "$3" == *"$2"* ]]; then echo "  ok  $1"; else echo "  FAIL $1: 未包含 [$2]"; fail=1; fi; }
chk_not_contains() { if [[ "$3" != *"$2"* ]]; then echo "  ok  $1"; else echo "  FAIL $1: 不应包含 [$2]"; fail=1; fi; }
run() { "$@" >"${TMP}/out" 2>"${TMP}/err"; echo $?; }
run_deep() { CUBESTACK_VERIFY_GZ_MAX_MIB=1 "$@" >"${TMP}/out" 2>"${TMP}/err"; echo $?; }

# 生成 SHA256SUMS + SIZES(排除元数据)
mk_manifests() {   # <dir>
    (
        cd "$1" || exit 1
        find . -type f ! -name SHA256SUMS ! -name SIZES ! -name _SUCCESS \
             ! -name '.cubestack-*' -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
        find . -type f ! -name SHA256SUMS ! -name SIZES ! -name _SUCCESS \
             ! -name '.cubestack-*' -printf '%s  %p\n' | sort -k2 > SIZES
    )
}

mk_success() {   # <offline-files-dir> <release>
    (
        cd "$1" || exit 1
        printf 'release=%s\nsha256sums=%s\n' "$2" "$(sha256sum SHA256SUMS | awk '{print $1}')" > _SUCCESS
    )
}

mk_release_tree() {   # <root> <ver>
    local root="$1" ver="$2"
    mkdir -p "${root}/${ver}/offline-files"
    printf 'RELEASE_VERSION=%s\nKUBESPRAY_VERSION=v9.9.9\nCUBESTACK_OPERATOR_CHART_VERSION=9.9.9\n' "${ver}" \
        > "${root}/${ver}/offline-files/release.env"
    printf 'x' > "${root}/${ver}/offline-files/a.txt"
    mk_manifests "${root}/${ver}/offline-files"
    mk_success "${root}/${ver}/offline-files" "${ver}"
    printf 'cli' > "${root}/${ver}/cubestack-installer-cli-v${ver}.tar"
    printf '{"release":"%s","cli_tar_sha256":"%s","cli_tar_size":3}\n' \
        "${ver}" "$(sha256sum "${root}/${ver}/cubestack-installer-cli-v${ver}.tar" | awk '{print $1}')" \
        > "${root}/${ver}/offline-files/release.json"
    mk_manifests "${root}/${ver}/offline-files"
    mk_success "${root}/${ver}/offline-files" "${ver}"
}

echo "== ⓪ --version =="
chk "退出码" "0" "$(run "${TOOL}" --version)"
chk_contains "版本号" "1.0.0" "$(cat "${TMP}/out")"

echo "== ① 布局识别: release =="
mk_release_tree "${TMP}/bucket" "2.0.0"
chk "release metadata 通过" "0" \
    "$(run "${TOOL}" --root "${TMP}/bucket/2.0.0/offline-files" --release 2.0.0 --layout release --level metadata --json)"
chk_contains "layout=release" '"layout": "release"' "$(cat "${TMP}/out")"

echo "== ② 布局识别: flat =="
mkdir -p "${TMP}/flat"
printf 'RELEASE_VERSION=2.0.0\n' > "${TMP}/flat/release.env"
printf 'x' > "${TMP}/flat/a.txt"
mk_manifests "${TMP}/flat"
chk "flat 自动识别" "0" "$(run "${TOOL}" --root "${TMP}/flat" --level metadata --json)"
chk_contains "layout=flat" '"layout": "flat"' "$(cat "${TMP}/out")"

echo "== ③ 布局识别: sealed-dev / unsealed-dev =="
mkdir -p "${TMP}/dev"
printf 'hello\n' > "${TMP}/dev/a.txt"
chk "unsealed 无 --allow-unsealed 失败" "1" "$(run "${TOOL}" --root "${TMP}/dev" --level metadata)"
chk "unsealed + --allow-unsealed 通过" "0" \
    "$(run "${TOOL}" --root "${TMP}/dev" --level metadata --allow-unsealed --json)"
chk_contains "layout=unsealed-dev" '"layout": "unsealed-dev"' "$(cat "${TMP}/out")"
mk_manifests "${TMP}/dev"
chk "sealed 通过" "0" "$(run "${TOOL}" --root "${TMP}/dev" --level metadata --json)"
chk_contains "layout=sealed-dev" '"layout": "sealed-dev"' "$(cat "${TMP}/out")"

echo "== ④ 清单覆盖性 =="
mkdir -p "${TMP}/cov"
printf 'x' > "${TMP}/cov/a.txt"
printf 'y' > "${TMP}/cov/b.txt"
printf '%s  ./a.txt\n' "$(sha256sum "${TMP}/cov/a.txt" | awk '{print $1}')" > "${TMP}/cov/SHA256SUMS"
chk "缺 b.txt 失败" "1" "$(run "${TOOL}" --root "${TMP}/cov" --level metadata)"
chk_contains "点名 b.txt" "b.txt" "$(cat "${TMP}/out")"
printf '%s  ./a.txt\n%s  ./b.txt\n%s  ./gone.txt\n' \
    "$(sha256sum "${TMP}/cov/a.txt" | awk '{print $1}')" \
    "$(sha256sum "${TMP}/cov/b.txt" | awk '{print $1}')" \
    "0000000000000000000000000000000000000000000000000000000000000000" > "${TMP}/cov/SHA256SUMS"
chk "清单多出 gone.txt 失败(严格)" "1" "$(run "${TOOL}" --root "${TMP}/cov" --level metadata --fail-missing)"
chk_contains "点名 gone.txt" "gone.txt" "$(cat "${TMP}/out")"

echo "== ⑤ 清单截断/路径安全/临时文件 =="
mk_manifests "${TMP}/cov"
printf 'x' > "${TMP}/cov/left.part"
chk "临时文件失败" "1" "$(run "${TOOL}" --root "${TMP}/cov" --level metadata)"
chk_contains "点名 .part" "left.part" "$(cat "${TMP}/out")"
rm -f "${TMP}/cov/left.part"
printf '%s  ../escape\n' "$(sha256sum "${TMP}/cov/a.txt" | awk '{print $1}')" > "${TMP}/cov/SHA256SUMS"
chk "路径穿越失败" "1" "$(run "${TOOL}" --root "${TMP}/cov" --level metadata)"
chk_contains "点名路径非法" "路径" "$(cat "${TMP}/out")"

echo "== ⑥ _SUCCESS 绑定 =="
mk_release_tree "${TMP}/rel2" "2.0.0"
chk "绑定正确通过" "0" \
    "$(run "${TOOL}" --root "${TMP}/rel2/2.0.0/offline-files" --release 2.0.0 --layout release --level metadata --json)"
printf 'release=2.0.0\nsha256sums=%064d\n' 0 > "${TMP}/rel2/2.0.0/offline-files/_SUCCESS"
chk "绑定错误失败" "1" \
    "$(run "${TOOL}" --root "${TMP}/rel2/2.0.0/offline-files" --release 2.0.0 --layout release --level metadata)"
chk_contains "点名绑定" "sha256sums" "$(cat "${TMP}/out")"

echo "== ⑦ 结构: 截断 tar / 空壳 docker-archive =="
mkdir -p "${TMP}/st" "${TMP}/st_src" "${TMP}/st_shellsrc"
printf 'layerdata' > "${TMP}/st_src/layer.tar"
printf '{}' > "${TMP}/st_src/config.json"
printf '[{"Config":"config.json","Layers":["layer.tar"],"RepoTags":["x:1"]}]' > "${TMP}/st_src/manifest.json"
tar -C "${TMP}/st_src" -cf "${TMP}/st/good.tar" .
# 空壳: manifest 指向不存在的 layer
printf '{}' > "${TMP}/st_shellsrc/config.json"
printf '[{"Config":"config.json","Layers":["missing.tar"],"RepoTags":["x:1"]}]' > "${TMP}/st_shellsrc/manifest.json"
tar -C "${TMP}/st_shellsrc" -cf "${TMP}/st/shell.tar" .
cp -f "${TMP}/st/good.tar" "${TMP}/st/trunc.tar"
mk_manifests "${TMP}/st"
# 截断发生在清单生成之后(真实场景: 发布时清单正确, 传输/存储被截断)
head -c $(( $(stat -c %s "${TMP}/st/good.tar") * 6 / 10 )) "${TMP}/st/good.tar" > "${TMP}/st/trunc.tmp"
mv -f "${TMP}/st/trunc.tmp" "${TMP}/st/trunc.tar"
chk "截断 tar 失败" "1" "$(run "${TOOL}" --root "${TMP}/st" --level quick)"
chk_contains "点名 trunc.tar" "trunc.tar" "$(cat "${TMP}/out")"
chk "空壳 tar 失败" "1" "$(run "${TOOL}" --root "${TMP}/st" --level quick)"
chk_contains "点名 shell.tar" "shell.tar" "$(cat "${TMP}/out")"
rm -f "${TMP}/st/trunc.tar" "${TMP}/st/shell.tar"
mk_manifests "${TMP}/st"
chk "合法 docker-archive 通过" "0" "$(run "${TOOL}" --root "${TMP}/st" --level quick)"

echo "== ⑧ 结构: 二进制/SIZES/树边车 =="
mkdir -p "${TMP}/bin"
printf '\177ELF\002\001\001\000' > "${TMP}/bin/run"
chmod +x "${TMP}/bin/run"
mk_manifests "${TMP}/bin"
chk "合法 ELF 通过" "0" "$(run "${TOOL}" --root "${TMP}/bin" --level quick)"
printf 'notelf' > "${TMP}/bin/run"
mk_manifests "${TMP}/bin"
chk "坏 ELF 失败" "1" "$(run "${TOOL}" --root "${TMP}/bin" --level quick)"
# 截断二进制: 保留 ELF 魔数, 大小与 SIZES 不符
printf '\177ELF\002\001\001\000' > "${TMP}/bin/run"
mk_manifests "${TMP}/bin"
printf '\177ELF' > "${TMP}/bin/run"
chk "SIZES 截断失败" "1" "$(run "${TOOL}" --root "${TMP}/bin" --level quick)"
chk_contains "点名 run" "run" "$(cat "${TMP}/out")"

mkdir -p "${TMP}/tree/kubespray/v9.9.9" "${TMP}/treesrc/kubespray"
printf 'tree' > "${TMP}/treesrc/kubespray/f"
tar -C "${TMP}/treesrc" -czf "${TMP}/tree/kubespray/v9.9.9/tree.tar.gz" kubespray
printf '%s\n' "$(sha256sum "${TMP}/tree/kubespray/v9.9.9/tree.tar.gz" | awk '{print $1}')" \
    > "${TMP}/tree/kubespray/v9.9.9/tree.tar.gz.sha256"
mk_manifests "${TMP}/tree"
chk "tree 边车一致通过" "0" "$(run "${TOOL}" --root "${TMP}/tree" --level quick)"
printf 'deadbeef\n' > "${TMP}/tree/kubespray/v9.9.9/tree.tar.gz.sha256"
mk_manifests "${TMP}/tree"
chk "tree 边车不符失败" "1" "$(run "${TOOL}" --root "${TMP}/tree" --level quick)"

echo "== ⑨ full: 内容损坏 / CLI tar =="
mkdir -p "${TMP}/full"
printf 'aaaa' > "${TMP}/full/a.bin"
mk_manifests "${TMP}/full"
chk "full 通过" "0" "$(run "${TOOL}" --root "${TMP}/full" --level full)"
printf 'bbbb' > "${TMP}/full/a.bin"
chk "full 坏字节失败" "1" "$(run "${TOOL}" --root "${TMP}/full" --level full)"
chk_contains "点名 a.bin" "a.bin" "$(cat "${TMP}/out")"

mk_release_tree "${TMP}/rel3" "3.0.0"
chk "CLI tar 正确通过" "0" \
    "$(run "${TOOL}" --root "${TMP}/rel3/3.0.0/offline-files" --release 3.0.0 --layout release --level full)"
printf 'bad' > "${TMP}/rel3/3.0.0/cubestack-installer-cli-v3.0.0.tar"
chk "CLI tar 损坏失败" "1" \
    "$(run "${TOOL}" --root "${TMP}/rel3/3.0.0/offline-files" --release 3.0.0 --layout release --level full)"

echo "== ⑩ 校验戳 =="
printf 'aaaa' > "${TMP}/full/a.bin"
mk_manifests "${TMP}/full"
chk "full+写戳" "0" "$(run "${TOOL}" --root "${TMP}/full" --level full)"
[ -f "${TMP}/full/.cubestack-verified.json" ] && echo "  ok  戳已写" || { echo "  FAIL 戳未写"; fail=1; }
chk "auto 走戳通过" "0" "$(run "${TOOL}" --root "${TMP}/full" --level auto --json)"
chk_contains "stamp.valid=true" '"valid": true' "$(cat "${TMP}/out")"
touch "${TMP}/full/a.bin"
chk "touch 后 auto 重算 full 通过" "0" "$(run "${TOOL}" --root "${TMP}/full" --level auto --json)"
printf 'cccc' > "${TMP}/full/a.bin"
chk "篡改后 auto 失败" "1" "$(run "${TOOL}" --root "${TMP}/full" --level auto)"

echo "== ⑪ seal =="
mkdir -p "${TMP}/seal"
printf 'x' > "${TMP}/seal/a.txt"
chk "seal 通过" "0" "$(run "${TOOL}" --root "${TMP}/seal" --seal)"
chk "生成 SHA256SUMS" "1" "$([ -f "${TMP}/seal/SHA256SUMS" ] && echo 1 || echo 0)"
chk "生成 SIZES" "1" "$([ -f "${TMP}/seal/SIZES" ] && echo 1 || echo 0)"
chk "seal 后 metadata 通过" "0" "$(run "${TOOL}" --root "${TMP}/seal" --level metadata)"
chk "seal 幂等" "0" "$(run "${TOOL}" --root "${TMP}/seal" --seal)"
chk "备份存在" "1" \
    "$(find "${TMP}/seal/.cubestack-manifest-backup" -name SHA256SUMS 2>/dev/null | head -1 | grep -q . && echo 1 || echo 0)"
printf 'x' > "${TMP}/seal/left.part"
chk "临时文件拒绝" "2" "$(run "${TOOL}" --root "${TMP}/seal" --seal)"
rm -f "${TMP}/seal/left.part"
printf 'RELEASE_VERSION=9.9.9\n' > "${TMP}/seal/release.env"
chk "正式树拒绝(无 --force)" "2" "$(run "${TOOL}" --root "${TMP}/seal" --seal)"
chk "--force 允许" "0" "$(run "${TOOL}" --root "${TMP}/seal" --seal --force)"
printf 'release=9.9.9\nsha256sums=%064d\n' 0 > "${TMP}/seal/_SUCCESS"
chk "seal 不更新 _SUCCESS -> 绑定失败" "1" "$(run "${TOOL}" --root "${TMP}/seal" --level metadata)"
chk "seal --update-success" "0" "$(run "${TOOL}" --root "${TMP}/seal" --seal --force --update-success)"
chk "update-success 后 metadata 通过" "0" "$(run "${TOOL}" --root "${TMP}/seal" --level metadata)"

echo "== ⑫ JSON schema =="
chk "JSON 通过" "0" "$(run "${TOOL}" --root "${TMP}/seal" --level metadata --json)"
python3 - "${TMP}/out" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for k in ("schema", "tool_version", "layout", "root", "ok", "summary", "checks", "failures", "warnings", "stamp"):
    assert k in d, k
assert d["ok"] is True
PY
chk "JSON 键完整" "0" "$?"


echo "== ⑬ chart 校验 =="
mkdir -p "${TMP}/chart/cubestack-operator/charts" "${TMP}/chartsrc"
printf 'apiVersion: v2\nname: test\nversion: 9.9.9\n' > "${TMP}/chartsrc/Chart.yaml"
tar -C "${TMP}/chartsrc" -czf "${TMP}/chart/cubestack-operator/charts/cubestack-operator-chart-9.9.9.tgz" .
printf 'RELEASE_VERSION=9.9.9\nCUBESTACK_OPERATOR_CHART_VERSION=9.9.9\n' > "${TMP}/chart/release.env"
mk_manifests "${TMP}/chart"
chk "chart 版本一致通过" "0" "$(run "${TOOL}" --root "${TMP}/chart" --level quick)"
# 陈旧 chart(非 release.env 指定版本)只警告, 不失败
printf 'apiVersion: v2\nname: test\nversion: 8.8.8\n' > "${TMP}/chartsrc/Chart.yaml"
tar -C "${TMP}/chartsrc" -czf "${TMP}/chart/cubestack-operator/charts/cubestack-operator-chart-8.8.8.tgz" .
mk_manifests "${TMP}/chart"
chk "陈旧 chart 仅警告" "0" "$(run "${TOOL}" --root "${TMP}/chart" --level quick)"
rm -f "${TMP}/chart/cubestack-operator/charts/cubestack-operator-chart-8.8.8.tgz"
printf 'apiVersion: v2\nname: test\nversion: 1.0.0\n' > "${TMP}/chartsrc/Chart.yaml"
tar -C "${TMP}/chartsrc" -czf "${TMP}/chart/cubestack-operator/charts/cubestack-operator-chart-9.9.9.tgz" .
mk_manifests "${TMP}/chart"
chk "chart 版本不符失败" "1" "$(run "${TOOL}" --root "${TMP}/chart" --level quick)"
rm -f "${TMP}/chart/cubestack-operator/charts/cubestack-operator-chart-9.9.9.tgz"
mk_manifests "${TMP}/chart"
chk "指定 chart 缺失失败" "1" "$(run "${TOOL}" --root "${TMP}/chart" --level quick)"
chk_contains "点名缺失 chart(stdout)" "缺少该 chart" "$(cat "${TMP}/out")"

echo "== ⑭ SIZES 缺失提示只在 quick 出现 =="
mkdir -p "${TMP}/nosizes"
printf 'x' > "${TMP}/nosizes/a.txt"
( cd "${TMP}/nosizes" && sha256sum ./a.txt > SHA256SUMS )
run "${TOOL}" --root "${TMP}/nosizes" --level full >/dev/null
chk "full 不提示 SIZES" "0" "$(grep -c 'SIZES 缺失' "${TMP}/out" 2>/dev/null || true)"
run "${TOOL}" --root "${TMP}/nosizes" --level quick >/dev/null
chk "quick 提示 SIZES" "1" "$(grep -c 'SIZES 缺失' "${TMP}/out" 2>/dev/null || true)"

echo "== ⑮ 默认 quick + --deep =="
chk "无 --level 默认 quick 通过" "0" "$(run "${TOOL}" --root "${TMP}/full")"
chk_contains "human 提示默认 quick" "默认：仅结构检查" "$(cat "${TMP}/out")"
chk_contains "stderr 提示默认 quick" "默认执行 quick" "$(cat "${TMP}/err")"
chk "metadata + --deep 拒绝" "2" "$(run "${TOOL}" --root "${TMP}/full" --level metadata --deep)"

mkdir -p "${TMP}/deep"
head -c 2000000 /dev/urandom | gzip -1 > "${TMP}/deep/big.tgz"
mk_manifests "${TMP}/deep"
chk "大 gz 非 tar: quick 不 deep 通过" "0" "$(run_deep "${TOOL}" --root "${TMP}/deep" --level quick)"
chk_contains "quick 提示 --deep" "--deep" "$(cat "${TMP}/out")"
chk "大 gz 非 tar: full 失败(deep 默认)" "1" "$(run_deep "${TOOL}" --root "${TMP}/deep" --level full)"
chk "大 gz 非 tar: quick --deep 失败" "1" "$(run_deep "${TOOL}" --root "${TMP}/deep" --level quick --deep)"
chk "大 gz 非 tar: full --deep 失败" "1" "$(run_deep "${TOOL}" --root "${TMP}/deep" --level full --deep)"

# 合法树: full --deep 写 deep 戳; auto --deep 可直接命中
mkdir -p "${TMP}/deepok"
printf 'ok\n' > "${TMP}/deepok/a.txt"
mk_manifests "${TMP}/deepok"
chk "full --deep 合法树通过" "0" "$(run "${TOOL}" --root "${TMP}/deepok" --level full --deep)"
chk_contains "戳记录 deep=true" '"deep": true' "$(cat "${TMP}/deepok/.cubestack-verified.json")"
chk_contains "auto --deep 命中戳" '"valid": true' "$(run "${TOOL}" --root "${TMP}/deepok" --level auto --deep --json; cat "${TMP}/out")"

echo "== ⑯ 普通 .gz CRC =="
mkdir -p "${TMP}/gz"
printf 'hello gzip\n' | gzip -c > "${TMP}/gz/valid.gz"
mk_manifests "${TMP}/gz"
chk "普通 gz 有效通过" "0" "$(run "${TOOL}" --root "${TMP}/gz" --level quick)"
python3 -c 'import sys; p=sys.argv[1]; d=bytearray(open(p,"rb").read()); d[-8:]=b"\0"*8; open(p,"wb").write(d)' "${TMP}/gz/valid.gz"
mk_manifests "${TMP}/gz"
chk "普通 gz CRC 损坏失败" "1" "$(run "${TOOL}" --root "${TMP}/gz" --level quick)"
chk_contains "点名 gz" "valid.gz" "$(cat "${TMP}/out")"

mkdir -p "${TMP}/gzbig"
head -c 2000000 /dev/urandom | gzip -1 > "${TMP}/gzbig/big.gz"
mk_manifests "${TMP}/gzbig"
chk "大 gz quick 跳过 CRC" "0" "$(run_deep "${TOOL}" --root "${TMP}/gzbig" --level quick)"
chk_contains "大 gz 提示 --deep" "--deep" "$(cat "${TMP}/out")"
python3 -c 'import sys; p=sys.argv[1]; d=bytearray(open(p,"rb").read()); d[-8:]=b"\0"*8; open(p,"wb").write(d)' "${TMP}/gzbig/big.gz"
mk_manifests "${TMP}/gzbig"
chk "大 gz full 检出 CRC(deep 默认)" "1" "$(run_deep "${TOOL}" --root "${TMP}/gzbig" --level full)"
chk "大 gz quick --deep 检出 CRC" "1" "$(run_deep "${TOOL}" --root "${TMP}/gzbig" --level quick --deep)"
chk "大 gz full --deep 检出 CRC" "1" "$(run_deep "${TOOL}" --root "${TMP}/gzbig" --level full --deep)"

echo "== ⑰ 清单文件被删除: 干净失败(无 traceback) =="
mkdir -p "${TMP}/missing"
printf 'x' > "${TMP}/missing/a.txt"
mk_manifests "${TMP}/missing"
rm -f "${TMP}/missing/a.txt"
chk "missing 默认跳过通过" "0" "$(run "${TOOL}" --root "${TMP}/missing" --level full)"
chk_contains "点名缺失文件" "a.txt" "$(cat "${TMP}/out")"
chk_contains "提示文件不存在/已删除" "文件不存在或已被删除" "$(cat "${TMP}/out")"
chk_not_contains "无 traceback" "Traceback" "$(cat "${TMP}/err")"
chk "missing 默认不写戳" "0" "$([ -f "${TMP}/missing/.cubestack-verified.json" ] && echo 1 || echo 0)"
chk "missing --fail-missing 失败" "1" "$(run "${TOOL}" --root "${TMP}/missing" --level full --fail-missing)"
chk_contains "fail-missing 点名" "a.txt" "$(cat "${TMP}/out")"
rm -f "${TMP}/missing/.cubestack-verified.json"
chk "missing full --skip-missing 通过" "0" "$(run "${TOOL}" --root "${TMP}/missing" --level full --skip-missing)"
chk_contains "skip-missing 提示已跳过" "已跳过" "$(cat "${TMP}/out")"
chk "skip-missing 不写戳" "0" "$([ -f "${TMP}/missing/.cubestack-verified.json" ] && echo 1 || echo 0)"

echo "== ⑱ 缺文件 + _SUCCESS 计数: 默认跳过不误报 =="
mkdir -p "${TMP}/missing2"
printf 'x' > "${TMP}/missing2/a.txt"
mk_manifests "${TMP}/missing2"
chk "seal 写 _SUCCESS" "0" "$(run "${TOOL}" --root "${TMP}/missing2" --seal --force --update-success --release 9.9.9)"
rm -f "${TMP}/missing2/a.txt"
chk "缺文件 + 计数默认通过" "0" "$(run "${TOOL}" --root "${TMP}/missing2" --level full)"
chk_contains "提示缺失" "文件不存在或已被删除" "$(cat "${TMP}/out")"

echo "== ⑲ 镜像 layer digest(deep/full 默认) =="
mkdir -p "${TMP}/imgsrc/layersrc" "${TMP}/imgsrc/build" "${TMP}/img"
printf 'layerdata' > "${TMP}/imgsrc/layersrc/f"
tar -C "${TMP}/imgsrc/layersrc" -cf "${TMP}/imgsrc/build/layer.tar" .
did="$(sha256sum "${TMP}/imgsrc/build/layer.tar" | awk '{print $1}')"
printf '{"rootfs":{"diff_ids":["sha256:%s"]}}\n' "${did}" > "${TMP}/imgsrc/build/config.json"
printf '[{"Config":"config.json","Layers":["layer.tar"],"RepoTags":["app:1"]}]\n' > "${TMP}/imgsrc/build/manifest.json"
tar -C "${TMP}/imgsrc/build" -cf "${TMP}/img/app.tar" .
mk_manifests "${TMP}/img"
chk "镜像 layer digest 通过" "0" "$(run "${TOOL}" --root "${TMP}/img" --level full --deep-log "${TMP}/img-deep.log")"
chk_contains "deep 日志记录 layer" "layer 1/1" "$(cat "${TMP}/img-deep.log")"
chk_contains "deep 日志记录 OK" "OK" "$(cat "${TMP}/img-deep.log")"
printf 'corrupt' >> "${TMP}/imgsrc/build/layer.tar"
tar -C "${TMP}/imgsrc/build" -cf "${TMP}/img/app.tar" .
mk_manifests "${TMP}/img"
chk "镜像 layer digest 损坏" "1" "$(run "${TOOL}" --root "${TMP}/img" --level full --deep-log "${TMP}/img-deep-bad.log")"
chk_contains "deep 日志记录 FAIL" "FAIL" "$(cat "${TMP}/img-deep-bad.log")"
chk_contains "点名 layer digest" "layer" "$(cat "${TMP}/out")"

echo "---------------------------------------------"
if [ "${fail}" = "0" ]; then
    echo "✅ verify-offline-files 回归通过"
    exit 0
else
    echo "❌ 回归失败"
    exit 1
fi
