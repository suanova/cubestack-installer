# ============================================================
# CubeStack RDMA 诊断镜像(netshoot + rdma-core + perftest)
# ------------------------------------------------------------
# 用途: 离线集群里的网络/RDMA 诊断 pod 用镜像(模块 35_netshoot.sh)。
#   在 netshoot(Alpine, 自带 tcpdump/ethtool/ip/ss/mtr/ping/nslookup)基础上加:
#     · rdma-core  → ibv_devices / ibv_devinfo(verbs 层: 这块卡能不能被 verbs 看到)
#     · perftest   → ib_write_bw / ib_read_bw / ib_write_lat ...(带宽/时延实测)
#   ⚠ Alpine **没有 perftest 包**(社区源里查不到), 只能源码编译 → 两阶段构建, 构建期不留编译工具。
#
# 谁构建: 联网机 tools/images/netshoot-rdma-build.sh(本文件不由部署机执行, 不在模块里 build)
# 数据源: 无(cluster.conf 只在 build 脚本里用于 tag/输出目录)
# ============================================================
ARG BASE_IMAGE=nicolaka/netshoot:latest
# apk 源: 留空 = 保持镜像自带的上游 dl-cdn.alpinelinux.org(默认, 不改变外部环境行为)。
# ⚠ 实测上游 CDN 在部分网络下只有 ~70 KB/s, 装 build-base 要几十分钟(像卡死) —— 慢网络请传
#   国内镜像加速, 例如: --build-arg APK_MIRROR=https://mirrors.aliyun.com/alpine(实测 ~3 MB/s)。
ARG APK_MIRROR=""

# ---------- stage 1: 编译 perftest(产物装进 /out, 再整棵拷进 runtime 阶段) ----------
FROM ${BASE_IMAGE} AS builder
ARG PERFTEST_VERSION
ARG APK_MIRROR
# 换源(仅当显式给了 APK_MIRROR): 主/社区两个仓库都指向该镜像的 v3.24 分支
RUN if [ -n "${APK_MIRROR}" ]; then \
        _v="$(cut -d. -f1,2 /etc/alpine-release)"; \
        printf '%s/v%s/main\n%s/v%s/community\n' "${APK_MIRROR}" "${_v}" "${APK_MIRROR}" "${_v}" > /etc/apk/repositories; \
        echo "apk 源已切换 → ${APK_MIRROR}/v${_v}"; cat /etc/apk/repositories; \
    fi
# 构建依赖: autogen/configure 三件套 + rdma-core 头文件(libibverbs/librdmacm)
# ⚠ perftest 源码由**构建脚本在宿主机下载**后放进构建上下文(固定名 perftest-src.tar.gz)——
#   实测容器内常访问不到 github.com("Resource temporarily unavailable")而宿主机正常, 故不在
#   镜像构建里 wget; 也便于离线构建机预先放好源码包(脚本环境变量 PERFTEST_TARBALL)。
COPY perftest-src.tar.gz /tmp/perftest.tar.gz
# ⚠ musl 兼容补丁(必加): perftest 源码用了 glibc 扩展常量 _SC_LEVEL1_DCACHE_LINESIZE, musl 里
#   **没有这个常量** → 编译直接报 undeclared。这里替换成常量 64(x86_64/arm64 的典型 cache line
#   大小)。该值只用于缓冲区对齐, 不影响带宽/时延测量结果。
RUN apk add --no-cache build-base autoconf automake libtool pkgconf linux-headers rdma-core-dev pciutils-dev \
 && mkdir -p /tmp/perftest \
 && tar -xzf /tmp/perftest.tar.gz -C /tmp/perftest --strip-components=1 \
 && cd /tmp/perftest \
 && sed -i 's/sysconf(_SC_LEVEL1_DCACHE_LINESIZE)/64/' src/perftest_parameters.c \
 && ./autogen.sh \
 && ./configure --prefix=/usr --libdir=/usr/lib \
 && make -j"$(nproc)" \
 && make install DESTDIR=/out \
 && rm -rf /tmp/perftest /tmp/perftest.tar.gz

# ---------- stage 2: 运行时 = netshoot 原样 + rdma-core + perftest 二进制 ----------
FROM ${BASE_IMAGE}
ARG PERFTEST_VERSION
LABEL org.opencontainers.image.title="netshoot-rdma" \
      org.opencontainers.image.description="CubeStack RDMA diagnostics: netshoot + rdma-core(ibv_*) + perftest(ib_write_bw/ib_read_bw...)" \
      org.opencontainers.image.version="${PERFTEST_VERSION}" \
      org.opencontainers.image.source="https://github.com/nicolaka/netshoot"
# perftest 运行期依赖 pciutils-libs(configure 要求 pciutils 头; 二进制动态链 libpci)
RUN apk add --no-cache rdma-core pciutils-libs
COPY --from=builder /out/ /
