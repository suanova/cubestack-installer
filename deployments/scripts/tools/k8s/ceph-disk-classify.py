#!/usr/bin/env python3
# ============================================================
# TOOL: ceph-disk-classify
# DESC: 单节点块设备分类器 —— 判定每块顶层磁盘是 "ceph 占用 / 空闲 / 在用 / 混合"
# 被谁调用: tools/k8s/ceph-detect-disks.sh --classify(经 SSH 取 lsblk 后喂给本程序)
# 输出(stdout, 每行一块盘, TAB 分隔): <设备>\t<分类>\t<证据>
#   分类: ceph  = 被 Ceph 占用(OSD 数据盘等), 覆盖安装可清空复用
#         free  = 未使用裸盘, 可直接作新 OSD
#         inuse = 被别的方式占用(挂载/非 ceph 文件系统/非 ceph LVM/系统盘), 绝不可碰
#         mixed = 同一块盘上 ceph 物证与非 ceph 数据并存 → 调用方必须跳过, 人工判断
# ============================================================
# 判定原则: **只认强证据**(可复核的物证), 不做启发式猜测。
#   早期版本直接把"有分区 + 未挂载"当典型 OSD 盘 —— 这类猜测会误伤"刚分区还没
#   格式化的业务数据盘", 与本工具"绝不覆盖其他使用方式的磁盘"的目标冲突, 已弃用。
#   Ceph 占用判定只取下列物证(任一命中即算, 证据串会打印出来供人工复核):
#     ① FSTYPE ∈ Ceph 文件系统类型(ceph_bluestore / ceph / ceph_journal / ceph_luks)
#        —— 整盘 raw 模式 OSD 与 LVM 模式 OSD 的 LV 都会命中(lsblk 探测 dm 设备)
#     ② GPT 分区类型 GUID 是 Ceph 专用类型(见 CEPH_PARTTYPE)
#     ③ 分区名(PARTLABEL)以 "ceph " 开头: ceph data / block / block.db / block.wal / journal
#     ④ LVM: VG 名以 ceph- 开头, 或 VG/LV 带 ceph.* 标签, 或 LV/dm 名形如
#        ceph--<uuid>-osd--block--<uuid>(ceph-volume 的命名)
#     ⑤ BlueStore label **副本**残留(固定偏移 10/100/1000GiB 命中 "ceph osd volume" magic)——
#        lsblk/blkid 看不见这个(它们只看 offset 0), 由 ceph-detect-disks.sh 的 LABEL_PROBE_CMD
#        探针提供(第 4 个位置参数)。★ 2026-09-24 事故: 头被擦过、副本还在的盘被判 free →
#        进 CR → Rook 判 "already prepared" → 认领失败 → **新集群 0 OSD**。有这条证据才能
#        在确认屏上把它显示成"上次 Ceph 占用", 并让清盘把它擦掉。
#   "在用"判定(命中即不可碰): 有任何挂载点、非 ceph 文件系统、非 ceph 的 VG/LV、
#   非 ceph 的分区名、RAID 成员、以及"有分区但没有任何 Ceph 物证"(宁可不动)。
#   注意 ②③④ 三条互相独立: ceph-volume 建盘时三条一般同时存在, 但只命中一条也足以判定;
#   三条全不命中时按"在用"处理(宁可不擦, 也不猜)。
# ============================================================
# 输入(stdin): lsblk -J -o NAME,TYPE,FSTYPE,MOUNTPOINT,PARTTYPE,PARTLABEL 的原样 JSON;
#   也接受完整对象 {"lsblk": <上述>, "lvm": {"pvs": "...", "lvs": "..."}}(便于离线单测)。
# 命令行: [exclude 正则] [pvs 文本] [lvs 文本] [label 副本探针输出]
#   pvs/lvs/探针 走位置参数而非塞进 JSON —— 这几段是带换行/方括号的自由文本, 让 shell 去转义
#   字符串字面量极易出错; 位置参数对换行透明。三者可选, 缺失时只少对应的一条佐证,
#   lsblk 侧的物证(文件系统类型/分区 GUID/分区名)仍足以判定。
# 退出码: 0 正常; 1 exclude 正则非法; 2 输入不是合法 JSON(调用方据此提示 lsblk 取数失败)
# ============================================================
import json
import re
import sys

# Ceph 在 lsblk/blkid 里的文件系统类型名(bluestore OSD / cephfs 数据 / journal / 加密 OSD)
CEPH_FSTYPES = {"ceph_bluestore", "ceph", "ceph_journal", "ceph_luks"}

# Ceph 专用 GPT 分区类型 GUID(小写比较)。来源: Ceph 官方分区类型定义 +
# ceph-volume 建 LVM PV 分区时用的 "Ceph OSD" 类型。全是 Ceph 专属值 ——
# 命中它就可以确定这块分区是 Ceph 建的, 不会是别人的数据。
CEPH_PARTTYPE = {
    "4fbd7e29-9d25-41b8-afd0-062c0ceff05d": "Ceph OSD data",
    "45b0969e-9b03-4f30-b4c6-b4b80ceff106": "Ceph OSD journal",
    "30cd0809-c2b2-499c-8879-2d6b78529876": "Ceph OSD block",
    "5ce17fce-4087-4169-b7ff-056cc58473f9": "Ceph OSD block.db",
    "fb3aabf9-d25f-47cc-bf5e-721d1816496b": "Ceph OSD block.wal",
    "4fbd7e29-8ae0-4982-bf9d-5a8d867af560": "Ceph dm-crypt OSD",
    "7cc45c84-d2ea-4b34-ae3d-ebdeed10527a": "Ceph dm-crypt journal",
    "89c57f98-2fe5-4dc0-89c1-f3ad0ceff2be": "Ceph OSD (ceph-volume)",
}

# 分区名以 "ceph " 开头 —— ceph-volume 写的是 ceph data / ceph block / ceph block.db /
# ceph block.wal / ceph journal / ceph osd(全部**空格**分隔)。
# ★ 必须要求那个空格: 曾写成 `^ceph[ _]?\b`, 而 `-` 是非单词字符, `^ceph[ _]?\b` 对
#   "ceph-backup"/"ceph-archive" 也成立 → 人工起的这类分区名会被判成 Ceph 盘**直接擦掉**(无 --force)。
#   收紧到空格后, 这类名字落回"非 ceph 分区名"→ inuse, 与本文件"只认强证据"的原则一致。
CEPH_PARTLABEL_RE = re.compile(r"^ceph ", re.IGNORECASE)

# ceph-volume 的 LVM 命名: VG=ceph-<fsid>, LV=osd-block-<uuid>。
# lsblk/dm 名把 '-' 转义成 '--', 故 dm 名形如 "ceph--<fsid>-osd--block--<uuid>"。
# ★ 只认 **ceph-- 前缀**(= VG 名以 ceph- 开头)。曾用过更松的 osd--block--/osd-block- 单独匹配,
#   结果用户自己起名叫 osd-block-xxx 的 LV 也会被判成 Ceph → 被清盘, 属不可接受的误伤;
#   非 ceph VG 里的卷名再像也不算物证(宁可漏判成"在用", 也不猜)。
CEPH_DM_NAME_RE = re.compile(r"^ceph--")

# 伪设备/非物理盘: 永不作为 OSD 盘, 也不参与分类(静默跳过, 与既有 detect 行为一致)
PSEUDO_PREFIX = ("loop", "ram", "zram", "sr", "rbd", "dm-", "md")

# ★ nbd 不能静默跳过: 它是**网络块设备**, 很可能是 ceph rbd-nbd 的映射(用户现场实测
#   一台机器上就是 nbd0..nbd15)。旧版只把 loop/ram/zram/sr/rbd 排除, nbd 会落进"空闲盘"
#   → 被写进 CR 当 OSD, 被 --all 当 Ceph 盘擦 —— dd 直接写穿到背后的 RBD 卷, 销毁真实数据。
#   CEPH_DETECT_EXCLUDE 默认值(`^(sda|sr0|vda)$`)并不含 nbd, 所以不能靠配置兜底。
NBD_PREFIX = "nbd"

# 空分区(无 fs / 无名 / 无挂载): 既不算 Ceph 也不算"别的数据", 记为中性
LINUX_FS_GUID = "0fc63daf-8483-4772-8e79-3d69d8477de4"


def _norm(v):
    """lsblk 的 null → 空串"""
    return "" if v is None else str(v).strip()


def _walk(node, top, ancestors=()):
    """深度优先展开: yield (节点, 所属顶层磁盘名, 祖先名元组)。

    ancestors 必须是**按分支**累积的 —— 曾把祖先收集写成跨兄弟节点累加的列表,
    会导致同一块盘上后面的分区误匹配到前面兄弟分区的 PV, 证据串张冠李戴。
    这里随递归传递, 天然按分支隔离。
    """
    yield node, top, ancestors
    for child in node.get("children") or []:
        yield from _walk(child, top, ancestors + (_norm(node.get("name")),))


def _parse_pvs(text):
    """pvs --noheadings -o pv_name,vg_name,vg_tags → {pv_basename: (vg_name, vg_tags)}"""
    out = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        pv, vg = parts[0], parts[1]
        tags = " ".join(parts[2:])
        out[pv.rsplit("/", 1)[-1]] = (vg, tags)
    return out


def _parse_lvs(text):
    """lvs --noheadings -o lv_name,vg_name,lv_tags → {(vg_name, lv_name): lv_tags}"""
    out = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        lv, vg = parts[0], parts[1]
        out[(vg, lv)] = " ".join(parts[2:])
    return out


def _tag_is_ceph(tagstr):
    """LVM 标签里是否有 ceph.* 前缀的(ceph-volume 会打 ceph.osd_id / ceph.cluster_fsid 等)。"""
    return any(t.startswith("ceph.") for t in tagstr.replace("[", " ").replace("]", " ").split())


def _pv_evidence(dev, pvs):
    """该设备**本身**是 LVM PV 时的物证。

    ★ 关键: 只看 `pvs` 输出, **不依赖 dm 子设备**。VG 未激活时(新装机器还没装 lvm2、
    磁盘从别处挪来的 foreign VG、`vgchange -an` 过)lsblk 里看不到任何 lvm 子设备,
    但 `pvs` 照样报得出 PV 与 VG 名 —— 这是"整盘 PV 被误判为空闲盘"的唯一防线。
    返回 (ceph 证据, 非 ceph 证据)。
    """
    ceph, other = [], []
    if dev not in pvs:
        return ceph, other
    vg, tags = pvs[dev]
    if vg.startswith("ceph-"):
        ceph.append("LVM PV %s → VG %s" % (dev, vg))
    elif vg:
        other.append("LVM PV %s → 非 ceph VG %s" % (dev, vg))
    if _tag_is_ceph(tags):
        ceph.append("VG %s 带 ceph 标签" % vg)
    return ceph, other


def _lvm_evidence(name, ancestors, pvs, lvs):
    """对树中的一个 lvm(dm) 设备找 LVM 侧的 Ceph 物证(名字正则 + lvs 表)。

    PV→VG 的判定不在这里做 —— 由 `_pv_evidence` 在每个 disk/part 节点上做(见上),
    避免同一份证据被重复计入。
    """
    ceph, other = [], []

    # 名字正则是独立物证: ceph-volume 的 dm 名形如 ceph--<uuid>-osd--block--<uuid>
    if CEPH_DM_NAME_RE.search(name):
        vg_hit = next((vg for dev, (vg, _t) in pvs.items() if dev in (name,) + tuple(ancestors)), "")
        ceph.append("LVM 卷名 %s%s" % (name, "（VG %s）" % vg_hit if vg_hit else ""))

    # lvs 侧: LV 名/VG 名/标签(主要覆盖 non-bluestore 的 ceph LV, 如 osd-data/journal)
    for (vg, lv), tags in lvs.items():
        name_hit = name == lv or name.endswith("-" + lv) or (vg and vg in name and lv in name)
        if not name_hit:
            continue
        if vg.startswith("ceph-"):
            ceph.append("LVM LV %s/%s" % (vg, lv))
        if _tag_is_ceph(tags):
            ceph.append("LV %s/%s 带 ceph 标签" % (vg, lv))
    return ceph, other


def classify(doc, exclude=None):
    """返回 [(设备, 分类, 证据), ...]（按设备名排序）"""
    try:
        lsblk = doc["lsblk"]
    except (TypeError, KeyError):
        return []
    if isinstance(lsblk, str):
        lsblk = json.loads(lsblk)
    lvm = doc.get("lvm") or {}
    pvs = _parse_pvs(lvm.get("pvs", ""))
    lvs = _parse_lvs(lvm.get("lvs", ""))
    # label 副本探针命中的盘(裸名字, 如 nvme1n1); 缺省为空 = 没有这条证据
    label_hits = {ln.strip() for ln in (doc.get("label_probe") or "").split() if ln.strip()}

    results = []
    for disk in lsblk.get("blockdevices") or []:
        name = _norm(disk.get("name"))
        if not name or disk.get("type") != "disk":
            continue
        if name.startswith(PSEUDO_PREFIX):
            continue
        if exclude and exclude.search(name):
            continue

        # nbd: 判定为"在用"(不是跳过 —— 要让人看见), 理由写清楚, 绝不参与清理/CR
        if name.startswith(NBD_PREFIX):
            results.append(("/dev/%s" % name, "inuse",
                            "网络块设备(nbd), 很可能是 ceph rbd-nbd 映射; 用 rbd unmap 或重启节点解除; 绝不作 OSD/不清理"))
            continue

        ceph_ev, other_ev, neutral_ev = [], [], []
        # ⑤ label 副本探针命中(顶层盘; 见文件头说明)——这条只有探针给得出, lsblk 侧看不见
        if name in label_hits:
            ceph_ev.append("%s: BlueStore label 副本(10/100/1000GiB 处仍有 'ceph osd volume' magic; "
                           "lsblk/blkid 不看这些偏移) —— 直接作 OSD 会被 Rook 判 already prepared; "
                           "需 zap-device 清副本" % name)
        # 本盘上出现过 LVM 签名(分区类型 LVM2_member, 或该设备/其祖先在 pvs 里)。
        # 用途见下方兜底: 有 LVM 签名却认不出归属时判 inuse, 绝不判 free。
        lvm_sig = False

        for node, _top, ancestors in _walk(disk, name):
            nname = _norm(node.get("name"))
            fstype = _norm(node.get("fstype"))
            mount = _norm(node.get("mountpoint"))
            ptype = _norm(node.get("parttype")).lower()
            plabel = _norm(node.get("partlabel"))
            ntype = _norm(node.get("type"))

            # ① 文件系统类型
            if fstype in CEPH_FSTYPES:
                ceph_ev.append("%s: 文件系统 %s" % (nname, fstype))
            elif mount:
                # 挂载中的盘一律算"在用"(无论挂在 / 还是 /data) —— 可能含数据, 绝不作为 OSD
                other_ev.append("%s: 已挂载 %s%s" % (nname, mount, "（%s）" % fstype if fstype else ""))
            elif fstype == "LVM2_member":
                # LVM2_member 本身不是"别的文件系统", 但也**绝不能说它是空闲** ——
                # 它表示"这个设备是 LVM PV, 上面有 VG/LV, 可能装着任何数据"。
                lvm_sig = True
            elif fstype == "swap":
                other_ev.append("%s: swap" % nname)
            elif fstype:
                other_ev.append("%s: 文件系统 %s" % (nname, fstype))

            # ② GPT 分区类型 GUID
            if ptype in CEPH_PARTTYPE:
                ceph_ev.append("%s: 分区类型 %s（GUID %s）" % (nname, CEPH_PARTTYPE[ptype], ptype))
            # ③ 分区名
            if plabel:
                if CEPH_PARTLABEL_RE.match(plabel):
                    ceph_ev.append('%s: 分区名 "%s"' % (nname, plabel))
                else:
                    other_ev.append('%s: 非 ceph 分区名 "%s"' % (nname, plabel))

            # ④ LVM —— 两条独立的路:
            #   (a) 该设备**本身**是 PV(disk 或 part 节点都查): VG 未激活时也认得出,
            #       这是"整盘 PV"那族的唯一防线(见 _pv_evidence 注释);
            #   (b) lvm(dm) 设备: 名字正则 + lvs 表。
            _c, _o = _pv_evidence(nname, pvs)
            if _c or _o:
                lvm_sig = True
                ceph_ev.extend(_c)
                other_ev.extend(_o)
            if ntype == "lvm":
                _c, _o = _lvm_evidence(nname, ancestors, pvs, lvs)
                ceph_ev.extend(_c)
                other_ev.extend(_o)
                if not _c and not _o:
                    other_ev.append("%s: LVM 逻辑卷(无 ceph 物证)" % nname)
            elif ntype.startswith("raid"):
                other_ev.append("%s: RAID 成员" % nname)

            # 中性: 有分区但既无 fs、无名、未挂载, 且不是 LVM PV —— 像是擦过/从未用过
            if (ntype == "part" and not fstype and not plabel and not mount
                    and ptype in ("", LINUX_FS_GUID) and nname not in pvs):
                neutral_ev.append("%s: 空分区" % nname)

        if ceph_ev and other_ev:
            cls, ev = "mixed", ceph_ev + other_ev
        elif ceph_ev:
            cls, ev = "ceph", ceph_ev
        elif other_ev:
            cls, ev = "inuse", other_ev
        elif lvm_sig:
            # ★ 有 LVM 签名却一条物证都没认出来(VG 未激活 + pvs 取不到, 或 VG 无名字)。
            #   这正是"整盘 PV 的业务数据盘"的样子 —— **宁可判 inuse 漏清, 也绝不判 free 误擦**。
            #   (旧版把 LVM2_member 整盘 PV 直接排除在候选外, 语义等价于 inuse。)
            cls, ev = "inuse", ["有 LVM 签名但认不出归属(VG 未激活/pvs 不可得) → 宁可不擦; 人工核对后可 --force"]
        elif disk.get("children"):
            # 有子设备但认不出是什么 → 宁可不碰
            cls, ev = "inuse", (neutral_ev or ["有分区但无 Ceph 物证"])
        elif _norm(disk.get("mountpoint")):
            cls, ev = "inuse", ["顶层盘直接挂载 %s" % _norm(disk.get("mountpoint"))]
        else:
            cls, ev = "free", ["整盘无分区/无文件系统/无挂载"]
        results.append(("/dev/%s" % name, cls, "; ".join(ev)))

    return sorted(results)


def main():
    exclude = None
    if len(sys.argv) > 1 and sys.argv[1]:
        try:
            exclude = re.compile(sys.argv[1])
        except re.error as exc:                      # 配置写错时明确报错, 不静默失效
            sys.stderr.write("ceph-disk-classify: CEPH_DETECT_EXCLUDE 正则非法: %s\n" % exc)
            return 1
    raw = sys.stdin.read()
    if not raw.strip():
        sys.stderr.write("ceph-disk-classify: 标准输入为空(未收到 lsblk JSON)\n")
        return 2
    try:
        doc = json.loads(raw)
    except ValueError as exc:
        sys.stderr.write("ceph-disk-classify: 输入不是合法 JSON: %s\n" % exc)
        return 2

    # 允许 stdin 直接是 lsblk -J 的输出(裸 JSON), 由壳层用位置参数补 LVM 文本
    if not isinstance(doc, dict) or "lsblk" not in doc:
        doc = {"lsblk": doc}
    if len(sys.argv) > 2 or len(sys.argv) > 3:
        lvm = doc.setdefault("lvm", {})
        if len(sys.argv) > 2 and sys.argv[2].strip():
            lvm.setdefault("pvs", sys.argv[2])
        if len(sys.argv) > 3 and sys.argv[3].strip():
            lvm.setdefault("lvs", sys.argv[3])
    # label 副本探针输出(每行一个被命中盘的裸名); 缺省 = 没有这条证据
    if len(sys.argv) > 4 and sys.argv[4].strip():
        doc.setdefault("label_probe", sys.argv[4])

    for dev, cls, ev in classify(doc, exclude):
        sys.stdout.write("%s\t%s\t%s\n" % (dev, cls, ev))
    return 0


if __name__ == "__main__":
    sys.exit(main())
