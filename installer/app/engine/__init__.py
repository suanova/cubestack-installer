"""部署引擎:虚拟机创建 / Kubespray 集群安装。

自动检测宿主机是否具备真实工具(virt-install / ansible-playbook / kubespray):
- 具备 -> 真实模式,调用系统命令执行
- 不具备 -> 仿真模式,完整模拟流程与日志,便于开发与演示
"""
