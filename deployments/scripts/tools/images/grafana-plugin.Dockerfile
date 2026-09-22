# ============================================================
# grafana-plugin.Dockerfile — Grafana 派生镜像: 预装数据源插件(prometheus)
#
# ── 为什么必须自建 ──
# Grafana 13.2 起把 Prometheus(以及 Loki/Elasticsearch/InfluxDB/MySQL/PostgreSQL/MSSQL/
# Jaeger/Zipkin/OpenTSDB/Stackdriver/Pyroscope)从**内置**改为**独立插件**, 启动时去
# grafana.com 下载安装。离线环境拉不到 → 数据源对象存在但报 "Plugin not registered",
# **所有看板无数据**(2026-09-22 实机定位: 日志里 "Plugins installed plugins=[]")。
#
# ── 插件目录为什么放在 /var/lib/grafana 之外 ──
# kube-prometheus-stack 会把 /var/lib/grafana 挂成 emptyDir(volume "storage") ——
# 烤在那里的插件会被挂载点**整个遮住**(实机核对过 mounts)。故这里装到 /opt/grafana-plugins,
# 由模块 08 用 grafana.ini.paths.plugins 把 GF_PATHS_PLUGINS 指过来。
# ⚠ 两处路径必须一致: 本文件 AND modules/03_addon/08_prometheus.sh 的 PROM_PLUGIN_DIR。
#
# ── 构建上下文 ──
# 必须含解包好的插件目录(构建脚本负责准备与校验):
#   <context>/prometheus/{plugin.json,MANIFEST.txt,...}
#
# ── 用法 ──
# 不要直接 docker build —— 走 tools/images/grafana-plugin-build.sh
# (它负责: 取基础镜像 → 下载并校验官方签名插件 → 构建 → 自检 → docker save 离线 tar)
# ============================================================
ARG BASE_IMAGE=grafana/grafana:13.2.1-distroless
FROM ${BASE_IMAGE}

# 权限: Grafana 以 uid 472 运行。插件目录指向这里后 Grafana 不再有写需求(已关自动更新),
# 但仍给 472 写权限 —— 免得将来开启插件更新时踩 permission denied(grafana#127760 同款问题)。
COPY --chown=472:472 prometheus /opt/grafana-plugins/prometheus
