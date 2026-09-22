#!/usr/bin/env python3
"""
normalize-dashboard-datasource.py — 把 Grafana dashboard JSON 里的数据源引用统一绑到目标数据源

为什么需要(2026-09-22):
  看板多来自 grafana.com / 上游仓库, 里面写死的是**别人环境的数据源 uid**(如 rYdddlPWk、
  eefhg6y1xs8owa、tbO9LAiZK)或用**小写名字**(`"datasource": "prometheus"`)。导入到本集群后:
    · 写死 uid 的面板 → Grafana 解析不到该 uid → 面板报 "Datasource not found" / 一直 No data;
    · 模板变量形式的(${DS_XXX}) → 变量没有 current 值 → 同样不出数。
  本工具在**导入前**把这些引用统一改成集群里那份 Prometheus 数据源(uid/type 由调用方给),
  于是"自定义 dashboard 放进来就能直接用", 不需要人去 Grafana 里逐个面板手选数据源。

改哪些(最小必要, 不碰无关字段):
  1) "datasource" 是字符串: 保留内置数据源(-- Grafana -- / grafana / -- Mixed --), 其余改成目标数据源;
  2) "datasource" 是对象: 没有 type 或 type 是 prometheus 系 → 只改 uid(保留其它字段);
     是别的前端数据源(如 loki/elasticsearch) → **不动**, 只计数提示(它需要各自的数据源);
  3) templating 列表里 type=datasource 的变量: 把 query/current/options 指向目标数据源,
     让面板里的 $DS_XXX 能解析。

用法: normalize-dashboard-datasource.py <in.json> <out.json> <uid> <name> [--quiet]
退出码: 0=成功(含"无需改动"); 非 0=输入不是合法 JSON(python 异常)
输出: 到 stderr 一行摘要(除非 --quiet)
"""
import json
import sys

BUILTIN = ("-- Grafana --", "-- Mixed --", "grafana")
PROM_TYPE = ("prometheus", "", "Prometheus")


def _target(uid, name):
    return {"type": "prometheus", "uid": uid, "name": name}


def normalize(obj, uid, name, stats, in_templating=False):
    """递归改写 dashboard 结构里的 datasource 引用。

    ⚠ 两个易误伤的坑(实测):
      · 顶层 `"uid"` 是**看板自身的身份**, 不是数据源引用 —— 只在 "datasource" 键下才改;
      · annotation 里有 `"datasource": {"type": "datasource", "uid": "grafana"}` —— 那是指向
        内置 Grafana 数据源的注解源, 必须原样保留(改了就丢注解数据)。
      · templating.list 里的 `{"type": "datasource"}` 是**变量定义**, 不是数据源引用 →
        通用遍历跳过整个 templating, 交给 normalize_templating 专门处理。
    """
    if isinstance(obj, dict):
        for k, v in list(obj.items()):
            if k == "templating":
                continue
            if k == "datasource":
                if isinstance(v, str):
                    if v in BUILTIN:
                        continue
                    obj[k] = _target(uid, name)
                    stats["rewritten"] += 1
                elif isinstance(v, dict):
                    t, u = v.get("type", ""), v.get("uid", "")
                    if u in BUILTIN or t == "datasource":
                        continue          # 内置(grafana)/注解源 → 原样保留
                    if t in PROM_TYPE:
                        if u != uid or t != "prometheus":
                            v["uid"] = uid
                            v["type"] = "prometheus"
                            stats["rewritten"] += 1
                    else:
                        stats["other_types"].add(t or "?")
                elif v is None:
                    obj[k] = _target(uid, name)   # 显式 null = 跟随默认数据源, 也钉死
                    stats["rewritten"] += 1
            else:
                normalize(v, uid, name, stats)
    elif isinstance(obj, list):
        for it in obj:
            normalize(it, uid, name, stats)


def normalize_templating(obj, uid, name, stats):
    """templating.list 里 type=datasource 的变量: 指向目标数据源。"""
    tpl = obj.get("templating")
    if not isinstance(tpl, dict):
        return
    for var in tpl.get("list", []) or []:
        if not isinstance(var, dict) or var.get("type") != "datasource":
            continue
        var["query"] = "prometheus"
        var["current"] = {"selected": False, "text": name, "value": uid}
        var["options"] = [{"selected": True, "text": name, "value": uid}]
        stats["vars"] += 1


def main():
    if len(sys.argv) < 5:
        sys.exit(__doc__)
    src, dst, uid, name = sys.argv[1:5]
    quiet = "--quiet" in sys.argv[5:]

    data = json.load(open(src, encoding="utf-8"))
    # 兼容两种形态: 纯 dashboard 对象 / 带 dashboard 外层的导出格式
    root = data["dashboard"] if isinstance(data, dict) and "dashboard" in data else data

    stats = {"rewritten": 0, "vars": 0, "other_types": set()}
    normalize(root, uid, name, stats)
    normalize_templating(root, uid, name, stats)

    json.dump(data, open(dst, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    if not quiet:
        msg = f"数据源引用改写 {stats['rewritten']} 处, 模板变量 {stats['vars']} 个 → {name}({uid})"
        if stats["other_types"]:
            msg += f"; ⚠ 另有其它类型数据源未改: {', '.join(sorted(stats['other_types']))}(需各自数据源)"
        print(msg, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
