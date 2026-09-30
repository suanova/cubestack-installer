# 版本套装档案: kubespray v2.32.0(k8s 1.35 线)
#
# 规则(见 docs/kubespray-versioning/design.md §3.2):
#   · 选定档案后, 本文件的版本面变量**接管** cluster.conf 的同名变量(档案 > cluster.conf)——
#     否则 --profile v2.28.0 会静默变成"v2.28 的资产 + v1.35.8 的钉子", 部署期才炸;
#   · 要手工钉某一项 → KUBESPRAY_PROFILE=none(全部按 cluster.conf, 等价历史行为);
#   · 字段真值由 check-modules.sh ⑯ 对照**该版本树表值**逐项断言(禁人手抄):
#     K8S_VERSION → kubelet_checksums 表成员判定; 其余 → 树内 download.yml 表值。
KUBESPRAY_VERSION=v2.32.0
K8S_VERSION=v1.35.8
PAUSE_VERSION=3.10.1
COREDNS_VERSION=v1.12.4
DNS_NODE_CACHE_VERSION=1.25.0
ETCD_VERSION=v3.6.14
CALICO_VERSION=v3.31.7
METRICS_SERVER_VERSION=v0.9.0
CPA_VERSION=v1.10.3
API_LB_NGINX_IMAGE_TAG=1.30.1-alpine
LOCAL_VOLUME_PROVISIONER_VERSION=2.5.0
NFD_VERSION=0.19.0
