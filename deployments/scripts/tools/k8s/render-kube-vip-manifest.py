#!/usr/bin/env python3
# ============================================================
# render-kube-vip-manifest.py — 渲染 kubespray 原版 kube-vip 静态 Pod manifest
#
# 为什么用它而不是让 ansible 渲染:
#   · 不依赖 kubespray inventory / ansible-playbook(部署机上是临时容器, 越少依赖越好)
#   · 也不手抄 manifest —— 直接读 roles/.../kube-vip.manifest.j2, 上游改了自动跟随
#
# ⚠ 一个必须记住的坑: 模板里的 {{ inventory_hostname }} 是 **每台节点自己的名字**,
#   它同时是 kube-vip 的 vip_nodename —— 租约 election 用它区分各节点。
#   若所有节点渲染成同一个值(例如用 ansible localhost 渲染), 三台 kube-vip 会
#   互相抢同一个租约 → 都认为自己是 leader → **三台同时绑定 VIP(脑裂)**。
#   故本脚本**必须**按节点逐个调用, 且显式传入该节点的 hostname。
#
# 用法:
#   render-kube-vip-manifest.py --nodename <节点名> --vip <VIP> [--interface <网卡>] \
#       [--template <path>] [--image-repo <repo>] [--image-tag <tag>] [--port 6443]
# 输出: 渲染好的 YAML 到 stdout
# ============================================================
import argparse
import json
import sys

try:
    import jinja2
except ImportError:
    sys.stderr.write("【错误】缺少 jinja2 模块(pip3 install jinja2)\n")
    sys.exit(1)


def to_json(value):
    """复刻 ansible 的 to_json 过滤器(模板大量使用)。"""
    return json.dumps(value)


def render(template_path, variables):
    with open(template_path, encoding="utf-8") as fh:
        source = fh.read()
    env = jinja2.Environment(
        undefined=jinja2.StrictUndefined,   # 缺变量直接报错, 不静默渲染出坏 manifest
        trim_blocks=True,
        lstrip_blocks=True,
        keep_trailing_newline=True,
    )
    env.filters["to_json"] = to_json
    return env.from_string(source).render(**variables)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--nodename", required=True,
                    help="该节点的 hostname(= 模板里的 inventory_hostname, 也是 vip_nodename)")
    ap.add_argument("--vip", required=True, help="VIP 地址")
    ap.add_argument("--interface", default="", help="承载 VIP 的网卡(留空 = kube-vip 自动检测)")
    ap.add_argument("--template", required=True, help="kube-vip.manifest.j2 路径")
    ap.add_argument("--image-repo", default="ghcr.io/kube-vip/kube-vip")
    ap.add_argument("--image-tag", default="v0.8.9")
    ap.add_argument("--port", type=int, default=6443)
    ap.add_argument("--pull-policy", default="IfNotPresent")
    ap.add_argument("--cp-detect", default="true", choices=["true", "false"],
                    help="apiserver 进程级故障检测")
    args = ap.parse_args()

    variables = {
        "inventory_hostname": args.nodename,
        "kube_vip_address": args.vip,
        "kube_vip_interface": args.interface,
        "kube_apiserver_port": args.port,
        "kube_vip_image_repo": args.image_repo,
        "kube_vip_image_tag": args.image_tag,
        "k8s_image_pull_policy": args.pull_policy,
        "kube_vip_admin_conf": "admin.conf",
        # --- 固定策略(与 docs/kube-vip-api-ha.md 的决策 D1/D4 一致)---
        "kube_vip_arp_enabled": True,
        "kube_vip_controlplane_enabled": True,
        "kube_vip_cp_detect": args.cp_detect == "true",
        "kube_vip_services_enabled": False,       # D1: 服务 LB 归 MetalLB
        "kube_vip_lb_enable": False,              # D4: 不开控制面 LB(local 转发在内核里是 null_xmit, 见 docs/troubleshooting.md 三.11)
        "kube_vip_leader_election_enabled": True, # ARP 模式下由 kube_vip_arp_enabled 派生的默认
        "kube_vip_lb_fwdmethod": "local",         # 仅因不开 LB 才安全; 它不转发(见 troubleshooting 三.11), 开 LB 必须换 masquerade
        "kube_vip_cidr": 32,
        "kube_vip_dns_mode": "first",
        "kube_vip_ddns_enabled": False,
        "kube_vip_enable_node_labeling": False,
        "kube_vip_enableServicesElection": False,
        "kube_vip_leasename": "plndr-cp-lock",
        "kube_vip_svc_leasename": "plndr-svcs-lock",
        "kube_vip_leaseduration": 5,
        "kube_vip_renewdeadline": 3,
        "kube_vip_retryperiod": 1,
        "kube_vip_services_interface": "",
        # BGP 未实现(见文档 R6), 关闭以免模板引用未定义变量
        "kube_vip_bgp_enabled": False,
    }

    try:
        sys.stdout.write(render(args.template, variables))
    except jinja2.UndefinedError as exc:
        sys.stderr.write(f"【错误】模板变量缺失: {exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
