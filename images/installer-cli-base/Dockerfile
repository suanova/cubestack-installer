# =====================================================================
# images/installer-cli-base/Dockerfile — CubeStack CLI 容器的**基础层**(系统 + 工具链, 极少变)
# ---------------------------------------------------------------------
# 设计(2026-09-30, 用户口径): **镜像分两层**
#   ① 本文件 = base 镜像: ubuntu:22.04 + apt 系统工具 + python3.11 + ansible(requirements.txt)
#      + kubectl/helm/skopeo/yq/mc(按 pinned version + sha256 从上游下载)。
#      **只在"新增 package / 工具 或 依赖版本变化"时重建**(需要联网 apt/pip)。
#   ② images/installer-cli/Dockerfile(代码层): `FROM <base>` + **只 copy deployments/skills 代码** —— 日常
#      "改了部署脚本要出新镜像"走这一层, 秒级~分钟级, 且**层数不累积**(每次都基于同一个 base,
#      而不是叠在上一版镜像上)。
#
# ★ 为什么必须分层: 旧的"增量构建 = FROM 上一版 latest"会让层数**单调累积**(实测 443 → 590 层),
#   而 containerd overlayfs 把全部祖先层拼进 lowerdir, 选项字符串超过内核 PAGE_SIZE(4096B)
#   ⇒ buildkit 在任意 RUN 步报 `mount source: "overlay" ... invalid argument`。
#   分层后: base 层数固定, 代码层每次只加 1~2 层 ⇒ 该问题从结构上消失。
#
# 构建/推送:
#   sudo ./deployments/scripts/tools/docker/build-cli-image.sh --base            # 构建 base
#   sudo ./deployments/scripts/tools/docker/build-cli-image.sh --base --push     # 并推送到 Harbor
# 依赖: 构建机联网(apt 清华源 + PyPI 清华源 + 上游工具下载); ubuntu:22.04 本地缺失时自动 pull。
# =====================================================================

# 基础镜像: ubuntu:22.04(build-cli-image.sh --base 本地缺失时自动 pull)
ARG BASE_IMAGE=ubuntu:22.04
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive \
    REPO_ROOT=/opt/cubestack-installer \
    PIP_NO_CACHE_DIR=1 \
    LANG=C.UTF-8 \
    TZ=Asia/Shanghai

# ---------- 默认时区: GMT+8(Asia/Shanghai) ----------
# ubuntu 基础镜像带 tzdata(/usr/share/zoneinfo), 设置容器内时区为东八区,
# 使日志时间戳/date 输出与国内一致(installer 部署/日志/脚本执行均按 GMT+8)。
RUN ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && echo "Asia/Shanghai" > /etc/timezone

# ---------- apt 源走清华镜像(国内加速) ----------
RUN sed -i 's@//archive.ubuntu.com@//mirrors.tuna.tsinghua.edu.cn@g; s@//security.ubuntu.com@//mirrors.tuna.tsinghua.edu.cn@g; s@//ports.ubuntu.com@//mirrors.tuna.tsinghua.edu.cn@g' /etc/apt/sources.list

# ---------- 系统工具链(apt 已走清华镜像) ----------
# 含 01_vm_network 依赖: iproute2(ip)/kmod(modprobe)/systemd(systemctl)/procps(sysctl)
# 及 NTP 权威源(chrony): 容器内充当权威时间源时使用
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget git unzip jq \
        openssh-client sshpass rsync iputils-ping iptables dnsutils \
        netcat-openbsd patch \
        python3 python3-pip python3-venv python3-yaml \
        libvirt-clients vim gnupg software-properties-common \
        iproute2 kmod systemd procps bridge-utils chrony \
        moreutils zstd \
    && rm -rf /var/lib/apt/lists/*

# 构建期门禁(2026-10-25): patch 是 kubespray 补丁层(cubestack-offline.sh)的必需工具。
# 缺失时补丁层会**静默跳过**, 导致 Calico RBAC / coredns / metallb 等补丁不生效。
RUN command -v patch >/dev/null && patch --version | head -1

# ---------- Python 3.11(deadsnakes)—— ansible 12.x 在**控制端**硬要求 Python ≥3.11 ----------
# 树内 requirements.txt 是 ansible==12.3.0(= ansible-core 2.19.x);ubuntu:22.04 自带 python3=3.10
# → pip 直接拒绝("Ignored the following versions that require a different python version: …
#   12.3.0 Requires-Python >=3.11" / "No matching distribution found for ansible==12.3.0")。
# 这里只装一个 python3.11 并让 **ansible 走它**(pip 的 console script 带 3.11 shebang, 落在 /usr/local/bin,
# 先于 /usr/bin 命中);系统 python3 保持 3.10 不动 ⇒ python3-libvirt 等按 3.10 编译的扩展不受影响。
# (jammy universe 里那个 python3.11 是 3.11.0~rc1 的 RC 版, 不适合跑生产 ansible, 故走 deadsnakes 的 3.11.16。)
RUN apt-get update && apt-get install -y --no-install-recommends software-properties-common \
    && add-apt-repository -y ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends python3.11 python3.11-venv python3.11-dev \
    && python3.11 -m ensurepip --upgrade \
    && rm -rf /var/lib/apt/lists/* \
    && python3.11 -V

# ---------- CLI 工具链(kubectl / helm / skopeo / yq / mc) ----------
# All tools are downloaded from their upstream release URLs with pinned versions
# and sha256 checksums. Nothing is read from the build host's PATH or offline
# directory, so a clean checkout is enough to rebuild this layer.
ARG TARGETARCH=amd64
ARG KUBECTL_VERSION=v1.35.8
ARG KUBECTL_SHA256=874d5e72dbb819f43cff16bcd1e4f8bac5b7f2361fe1e55049b0a6c676fb0cbf
ARG HELM_VERSION=3.22.0
ARG HELM_SHA256=1e4ab49e429626cf6c6958d914248b78c9730803c2751b87627e171dc800e7bb
ARG SKOPEO_VERSION=1.16.1
ARG SKOPEO_SHA256=8813fb7fcd7a723196ac287683dd929d280f6fe7f0782eace452fe1e3ff2b7eb
ARG YQ_VERSION=4.42.1
ARG YQ_SHA256=1a95960dddd426321354d58d2beac457717f7c49a9ec0806749a5a9e400eb45e
ARG MC_VERSION=RELEASE.2026-09-19T15-24-59Z
ARG MC_SHA256=83938eded435e7c28c397ece1dc590b2a79626dd9354aae2107060fec559ae2b

RUN set -eux; \
    [ "${TARGETARCH}" = "amd64" ] || { echo "only linux/amd64 is supported" >&2; exit 1; }; \
    curl -fsSL -o /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"; \
    echo "${KUBECTL_SHA256}  /tmp/kubectl" | sha256sum -c -; \
    install -m 0755 /tmp/kubectl /usr/local/bin/kubectl; \
    rm -f /tmp/kubectl; \
    kubectl version --client 2>/dev/null | head -1

RUN set -eux; \
    curl -fsSL -o /tmp/helm.tar.gz "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz"; \
    echo "${HELM_SHA256}  /tmp/helm.tar.gz" | sha256sum -c -; \
    tar xzf /tmp/helm.tar.gz -C /tmp; \
    install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm; \
    rm -rf /tmp/linux-amd64 /tmp/helm.tar.gz; \
    helm version --short

RUN set -eux; \
    curl -fsSL -o /tmp/skopeo "https://github.com/lework/skopeo-binary/releases/download/v${SKOPEO_VERSION}/skopeo-linux-amd64"; \
    echo "${SKOPEO_SHA256}  /tmp/skopeo" | sha256sum -c -; \
    install -m 0755 /tmp/skopeo /usr/local/bin/skopeo; \
    rm -f /tmp/skopeo; \
    skopeo --version

RUN set -eux; \
    curl -fsSL -o /tmp/yq "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64"; \
    echo "${YQ_SHA256}  /tmp/yq" | sha256sum -c -; \
    install -m 0755 /tmp/yq /usr/local/bin/yq; \
    rm -f /tmp/yq; \
    yq --version

# mc bootstraps MinIO downloads and cannot be supplied by a mount.
RUN set -eux; \
    curl -fsSL -o /tmp/mc "https://dl.min.io/aistor/mc/release/linux-amd64/archive/mc.${MC_VERSION}"; \
    echo "${MC_SHA256}  /tmp/mc" | sha256sum -c -; \
    install -m 0755 /tmp/mc /usr/local/bin/mc; \
    rm -f /tmp/mc; \
    mc --version

# ---------- kubespray Python 依赖(ansible 等; 构建时下载 wheel 缓存, 运行时离线安装) ----------
# ① 构建机联网时(清华源) pip download 拉 wheel 到 /tmp/pipcache;
# ② pip install --no-index 全程走本地缓存, 容器内零联网;
# ③ 复用安装(第二次 --no-index 空跑, 确保幂等/完整), 然后清缓存并校验 ansible。
# ⚠ 必须用 python3.11(见上一步): 系统 python3=3.10 装不了 ansible 12.3.0。
# ⚠ requirements.txt 来自构建上下文(deployments/kubespray/kubespray/requirements.txt); 代码层
#   构建时会按**最新**的 requirements.txt 再对齐一次(依赖变化时不用重建 base)。
COPY deployments/kubespray/kubespray/requirements.txt /tmp/kubespray-requirements.txt
RUN python3.11 -m pip install --upgrade pip -i https://pypi.tuna.tsinghua.edu.cn/simple \
    && python3.11 -m pip download -d /tmp/pipcache -r /tmp/kubespray-requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple \
    && python3.11 -m pip install --no-index --find-links=/tmp/pipcache -r /tmp/kubespray-requirements.txt \
    && python3.11 -m pip install --no-index --find-links=/tmp/pipcache -r /tmp/kubespray-requirements.txt \
    && rm -rf /tmp/pipcache /tmp/kubespray-requirements.txt \
    && ansible --version 2>/dev/null | head -1

WORKDIR ${REPO_ROOT}
CMD ["/bin/bash"]
