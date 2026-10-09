# offline-files/os/

**OS / 引导层**离线资产:基础 OS 镜像、临时调试镜像,以及 **CLI 镜像构建期要用的引导工具**。

| 文件 | 用途 | 谁用 |
|---|---|---|
| `ubuntu-22.04.tar` | CLI 镜像全量构建的**基础镜像**(`docker load` 后 `docker build`) | `tools/docker/build-cli-context.sh --build` |
| `netshoot.tar` | 网络排障临时 Pod 的镜像(手动 `ctr` 导入节点) | 排查时人工使用 |
| `mc-<版本>-linux-amd64` | MinIO Client 静态二进制 —— **镜像里唯一必须内置的工具** | `build-cli-context.sh` 拷进构建上下文 `bin/mc` |
| `packages/` | **节点 OS 层 deb**(版本无关; 2026-10-08 起 kubespray/<版本>/packages 与 repair 全部并入)。**顶层=对账集**(全线节点逐个装), `chrony/` 子目录=专用安装集(仅 NTP 模块用, 不对账) | `reconcile-node-packages.sh` / `install-packages.yml` / `setup-ntp.sh` 等(详见 `packages/README.md`) |

## mc 为什么必须打进 CLI 镜像(例外说明)

CLI 镜像的总体契约是**只含 `deployments/` 代码**:`kubectl`/`helm`/`skopeo` 都由容器**运行期**从挂载的
版本目录挂到 PATH(见 `docs/kubespray-versioning/README.md` §8)。**`mc` 是唯一例外**,原因两条:

1. **引导工具,不能被挂载提供**:容器正是靠 `mc` 去 MinIO **拉**离线文件 —— 那份离线文件(含版本目录)
   还没下到本机之前,没有任何可挂载的东西能把 `mc` 供给容器(先有鸡还是先有蛋);
2. **上游下载 URL 已失效**:原 `https://dl.min.io/client/mc/release/linux-amd64/mc` 现返回 **HTTP 410 Gone**
   (2026-09-30 实测),官方 apt 仓库历史上也不稳定 ⇒ 任何"构建时联网装 mc"的写法都会挂。

故:`build-cli-context.sh` 从本目录的 `mc-*` 拷进构建上下文 `bin/mc`,`Dockerfile-cli` 用 `COPY bin/mc`
装进镜像。取值顺序 = **本目录离线件(首选) → 官方新地址联网下载(兜底, 会告警) → 宿主机 `command -v mc`
(再兜底, 会告警) → 全无则报错**。

## 升级 mc

```bash
# ① 联网机拉官方二进制(⚠ 路径带 /aistor/; 老路径 /client/ 已 410 Gone):
wget https://dl.min.io/aistor/mc/release/linux-amd64/mc -O /tmp/mc
chmod +x /tmp/mc && /tmp/mc --version | head -1        # 记下 RELEASE.<日期> 版本号
# ② 沉淀为离线件(只留一份, 免得构建挑错):
sudo install -m 0644 /tmp/mc deployments/offline-files/os/mc-RELEASE.<日期>-linux-amd64
rm -f deployments/offline-files/os/mc-RELEASE.<旧日期>-linux-amd64
# ③ 重建镜像(构建工具会优先用这个离线件):
sudo ./deployments/scripts/tools/docker/build-cli-context.sh --build
```

> 备选:任何已有 mc 的机器上 `sudo install -m 0644 /usr/bin/mc .../os/mc-RELEASE.<日期>-linux-amd64`。
> 构建工具的取值顺序 = **离线件 → 新地址联网下载(兜底, 会告警) → 宿主机 mc → 报错**。

> ⚠ 本目录的文件**不入库**(`.gitignore` 只放行各层 README.md);本 README 是唯一受版本控制的条目 ——
> 少了它,`os/` 组在 git 里就不存在(空目录存不下)。备料/同步见仓库根 `README.md` 与
> `tools/offline/fetch-offline-from-minio.sh`(远端结构与本地同构)。
