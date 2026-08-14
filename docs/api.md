# API 接口规范

## 一、通用说明

- 基础地址:`http://<host>:8000`
- 除登录与注册外,所有接口请求头须携带 `Authorization: Bearer <token>`
- 写操作(创建、删除、部署)须具备管理员权限
- 交互式调试可通过 Swagger UI 完成:http://127.0.0.1:8000/docs

## 二、认证接口

| 方法 | 路径 | 输入 | 输出 |
| --- | --- | --- | --- |
| POST | /api/auth/register | `{"username","email","password","full_name?"}` | 201 用户对象 |
| POST | /api/auth/login | `{"account","password"}`(用户名或邮箱) | 200 `{"access_token","token_type","user"}` |
| GET | /api/auth/me | - | 200 当前用户 |

## 三、宿主机接口

| 方法 | 路径 | 输入 | 输出 |
| --- | --- | --- | --- |
| GET | /api/hosts | - | 200 主机数组(含环境检测字段) |
| POST | /api/hosts | `{"name","ip","ssh_user?","ssh_port?","cpu_cores?","memory_gb?","disk_gb?"}` | 201 主机(自动执行环境检测) |
| POST | /api/hosts/{id}/check | - | 200 主机(环境检测报告) |
| DELETE | /api/hosts/{id} | - | 200 `{"message"}` |

环境检测报告字段:`os_name`、`os_ok`、`libvirt_ready`、`check_report`(JSON)、`last_checked_at`。

## 四、虚拟机接口

| 方法 | 路径 | 输入 | 输出 |
| --- | --- | --- | --- |
| GET | /api/vms | - | 200 虚拟机数组(含提供方信息) |
| GET | /api/vms/providers | - | 200 虚拟化后端状态(libvirt / kubevirt) |
| POST | /api/vms | `{"name","host_id","cpu","memory_gb","disk_gb","image","provider","namespace?","auto_ip","ip?"}` | 202 `{"task_id","vm"}` |
| POST | /api/vms/{id}/action | `{"action":"start|stop|reboot"}` | 200 虚拟机 |
| DELETE | /api/vms/{id} | - | 200 `{"message"}` |

说明:provider 字段可选 libvirt 或 kubevirt,默认 libvirt;namespace 仅适用于 kubevirt。

## 五、K8s 集群接口

| 方法 | 路径 | 输入 | 输出 |
| --- | --- | --- | --- |
| GET | /api/clusters | - | 200 集群数组(含节点统计) |
| POST | /api/clusters | `{"name","k8s_version","network_plugin","kubespray_version","control_plane_vm_ids","worker_vm_ids","ssh_key?"}` | 201 集群对象 |
| GET | /api/clusters/{id} | - | 200 `{"cluster","nodes","last_task"}` |
| POST | /api/clusters/{id}/deploy | - | 202 `{"task_id"}` |
| DELETE | /api/clusters/{id} | - | 200 `{"message"}` |

## 六、部署任务接口

| 方法 | 路径 | 输入 | 输出 |
| --- | --- | --- | --- |
| GET | /api/tasks | - | 200 任务数组(含进度与日志摘要) |
| GET | /api/tasks/{id} | - | 200 任务详情(完整日志流) |

## 七、用户管理接口

| 方法 | 路径 | 输入 | 输出 |
| --- | --- | --- | --- |
| GET | /api/users | - | 200 用户数组 |
| PATCH | /api/users/{id} | `{"role"?,"is_active"?,"full_name"?}` | 200 用户 |
| DELETE | /api/users/{id} | - | 200 `{"message"}` |

