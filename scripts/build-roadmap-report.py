#!/usr/bin/env python3
"""生成 ROADMAP.md / ROADMAP.html 可视化报表, 数据来自 GitHub 里程碑。"""
import datetime, html, json, subprocess, sys

REPO = "suanova/cubestack-installer"
MS = "CubeStack Installer 开发 Roadmap"


def gh_api(path):
    out = subprocess.check_output(["gh", "api", path], text=True)
    return json.loads(out)


def main():
    issues = [i for i in gh_api(f"repos/{REPO}/issues?state=all&per_page=100")
              if not i.get("pull_request")]
    ms = [m for m in gh_api(f"repos/{REPO}/milestones?state=all") if m["title"] == MS]
    m = ms[0] if ms else {"title": MS}
    total = len(issues)
    done = sum(1 for i in issues if i["state"] == "closed")
    open_ = total - done
    pct = round(done * 100 / total) if total else 0
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")

    done_items = sorted([i for i in issues if i["state"] == "closed"], key=lambda x: x["number"])
    open_items = sorted([i for i in issues if i["state"] == "open"], key=lambda x: x["number"])

    # ---------- Markdown ----------
    lines = []
    lines.append(f"# CubeStack Installer — Roadmap\n")
    lines.append(f"> 由 [github-planning skill](.claude/skills/github-planning/SKILL.md) 生成 · {now}\n")
    lines.append(f"> 数据源: GitHub `{REPO}` · 里程碑「{m['title']}」\n")
    lines.append("## 总览\n")
    lines.append("| 里程碑 | 总 issue | 已完成 | 剩余 | 进度 |")
    lines.append("|---|---|---|---|---|")
    lines.append(f"| {m['title']} | {total} | {done} | {open_} | **{pct}%** |")
    lines.append("\n完成度 **{}%**\n".format(pct))
    lines.append("## ✅ 已完成 (closed)\n")
    for i in done_items:
        lines.append(f"- [x] #{i['number']} {html.escape(i['title'])}")
    lines.append("\n## 📋 未完成 (open)\n")
    for i in open_items:
        lines.append(f"- [ ] #{i['number']} {html.escape(i['title'])}")
    lines.append("\n---\n")
    lines.append("_由 github-planning skill 生成, 手工改动可能会被后续 `gp update-milestone` 覆盖。_\n")
    open("ROADMAP.md", "w").write("\n".join(lines))

    # ---------- HTML (可视化列表) ----------
    # 进度条字符
    bar_len = 30
    filled = round(done / total * bar_len) if total else 0
    bar = "█" * filled + "░" * (bar_len - filled)

    rows_done = "\n".join(html.escape(f"#{i['number']} {i['title']}") for i in done_items)
    rows_open = "\n".join(html.escape(f"#{i['number']} {i['title']}") for i in open_items)

    doc = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(REPO)} · Roadmap</title>
<style>
  body{{font-family:-apple-system,'Segoe UI',Roboto,'Microsoft YaHei',sans-serif;margin:2rem auto;max-width:960px;padding:0 1rem;color:#24292f;background:#fff}}
  h1{{font-size:1.5rem;border-bottom:2px solid #0969da;padding-bottom:.3rem}}
  .meta{{color:#57606a;font-size:.85rem;margin-bottom:1.2rem}}
  .card{{background:#f6f8fa;border:1px solid #d0d7de;border-radius:8px;padding:1rem 1.5rem;margin:1rem 0}}
  .stat{{display:flex;gap:2rem;flex-wrap:wrap}}
  .stat b{{font-size:1.8rem;display:block;color:#0969da}}
  .bar{{height:16px;background:#e6edf3;border-radius:8px;overflow:hidden;margin:.6rem 0}}
  .bar>span{{display:block;height:100%;background:linear-gradient(90deg,#2da44e,#1a7f37);width:{pct}%}}
  h2{{font-size:1.1rem;margin-top:1.4rem}}
  ul{{padding-left:1.3rem;line-height:1.7}}
  ul.done li{{color:#2da44e}}
  ul.done li::marker{{content:"✅ "}}
  ul.open li::marker{{content:"📋 "}}
  footer{{margin-top:2rem;color:#57606a;font-size:.8rem;border-top:1px solid #d0d7de;padding-top:.8rem}}
  code{{background:#f0f3f6;padding:.1rem .3rem;border-radius:4px}}
</style>
</head>
<body>
<h1>📊 CubeStack Installer — Roadmap</h1>
<div class="meta">由 github-planning skill 生成 · {now}<br>数据源: <code>{REPO}</code> · 里程碑「{html.escape(m['title'])}」</div>

<div class="card">
  <div class="stat">
    <div style="text-align:center"><b>{total}</b>总 issue</div>
    <div style="text-align:center"><b>{done}</b>已完成</div>
    <div style="text-align:center"><b>{open_}</b>待办</div>
    <div style="text-align:center"><b>{pct}%</b>完成度</div>
  </div>
  <div class="bar"><span></span></div>
  <div style="font-family:monospace">{bar} {pct}%</div>
</div>

<h2>✅ 已完成 (closed)</h2>
<ul class="done">
{''.join(f'<li>#{i["number"]} {html.escape(i["title"])}</li>' for i in done_items)}
</ul>

<h2>📋 未完成 (open)</h2>
<ul class="open">
{''.join(f'<li>#{i["number"]} {html.escape(i["title"])}</li>' for i in open_items)}
</ul>

<footer>打开 <a href="{REPO}/milestones" style="color:#0969da">GitHub Milestones → /milestones</a> 查看原生看板</footer>
</body>
</html>"""
    open("ROADMAP.html", "w").write(doc)

    print(f"OK: ROADMAP.md + ROADMAP.html 已生成 ({total} issues, 完成 {pct}%)")
    return 0


if __name__ == "__main__":
    sys.exit(main())