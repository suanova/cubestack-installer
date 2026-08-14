# API 参考

Base URL: `http://<host>:8000`
所有接口除登录/注册外,请求头需携带 `Authorization: Bearer <token>`;写操作(创建/删除/部署)需**管理员**权限。
交互式调试: http://127.0.0.1:8000/docs (Swagger UI)

## 认证

| 方法 | 路径 | 输入 | 输出 |
| --- | --- | --- | --- |
| POST | /api/auth/register | `{"username","email","password","full_name?"}` | 201 用户对象 |
| POST | /api/auth/login | `{"account","password"}`(用户名或邮箱) | 200 `{"access_token","token_type","user"}` |
| GET | /api/auth/me | - | 200 当前用户 |

## 宿主机

| 方法 | 路径 | 输入 | 输出 |
| --- | --- | --- | --- |
| GET | /api/hosts | - | 200 主机数组(含环境检测字段) |
| POST | /api/hosts | `{"name","ip","ssh_user?","ssh_port?","cpu_cores?","memory_gb?","disk_gb?"}` | 201 主机(自动执行环境检测) |
| POST | /api/hosts/{id}/check | - | 200 主机(环境检测报告) |
| DELETE | /api/hosts/{id} | - | 200 `{"message"}` |

环境检测报告字段: `os_name / os_ok / libvirt_ready / check_report(JSON) / last_checked_at`

## 虚拟机

| 方法 | 路径 | 输入 | 输出 |
| --- | --- | --- | --- |
| GET | /api/vms | - | 200 虚拟机数组(含提供方) |
| GET | /api/vms/providers | - | 200 虚拟化后端状态(libvirt/kubevirt) |
| POST | /api/vms | `{"name","host_id","cpu","memory_gb","disk_gb","image","provider","namespace?","auto_ip","ip?"}` | 202 `{"task_id","vm"}` |
| POST | /api/vms/{id}/action | `{"action":"start|stop|reboot"}` | 200 虚拟机 |
| DELETE | /api/vms/{id} | - | 200 `{"message"}` |

## K8s 集群

| 方法 | 路径 | 输入 | 输出 |
| --- | --- | --- | --- |
| GET | /api/clusters | - | 200 集群数组(含节点统计) |
| POST | /api/clusters | `{"name","k8s_version","network_plugin","kubespray_version","control_plane_vm_ids","worker_vm_ids","ssh_key?"}` | 201 集群对象 |
| GET | /api/clusters/{id} | - | 200 `{"cluster","nodes","last_task"}` |
| POST | /api/clusters/{id}/deploy | - | 202 `{"task_id"}` |
| DELETE | /api/clusters/{id} | - | 200 `{"message"}` |

## 部署任务

| 方法 | 路径 | 输入 | 输出 |
| --- | --- | --- | --- |
| GET | /api/tasks | - | 200 任务数组(含进度与日志摘要) |
| GET | /api/tasks/{id} | - | 200 任务详情(完整日志流) |

## 用户管理

| 方法 | 路径 | 输入 | 输出 |
| --- | --- | --- | --- |
| GET | /api/users | - | 200 用户数组 |
| PATCH | /api/users/{id} | `{"role"?,"is_active"?,"full_name"?}` | 200 用户 |
| DELETE | /api/users/{id} | - | 200 `{"message"}` |

