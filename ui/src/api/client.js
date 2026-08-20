// 统一 API 封装:自动携带 JWT、统一错误处理
const BASE = '/api'

async function request(path, { method = 'GET', body, token } = {}) {
  const headers = { 'Content-Type': 'application/json' }
  if (token) headers.Authorization = 'Bearer ' + token

  let res
  try {
    res = await fetch(BASE + path, {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
    })
  } catch {
    throw new Error('无法连接服务器,请确认后端已启动')
  }

  const data = await res.json().catch(() => ({}))
  if (!res.ok) {
    const err = new Error(data.detail || '请求失败 (' + res.status + ')')
    err.status = res.status
    throw err
  }
  return data
}

// 认证与用户
export const authApi = {
  register: (payload) => request('/auth/register', { method: 'POST', body: payload }),
  login: (payload) => request('/auth/login', { method: 'POST', body: payload }),
  me: (token) => request('/auth/me', { token }),
}

export const userApi = {
  list: (token) => request('/users', { token }),
  create: (payload, token) => request('/users', { method: 'POST', body: payload, token }),
  update: (id, payload, token) => request('/users/' + id, { method: 'PATCH', body: payload, token }),
  remove: (id, token) => request('/users/' + id, { method: 'DELETE', token }),
}

// 宿主机
export const hostApi = {
  list: (token) => request('/hosts', { token }),
  create: (payload, token) => request('/hosts', { method: 'POST', body: payload, token }),
  check: (id, token) => request('/hosts/' + id + '/check', { method: 'POST', token }),
  precheck: (payload, token) => request('/hosts/precheck', { method: 'POST', body: payload, token }),
  remove: (id, token) => request('/hosts/' + id, { method: 'DELETE', token }),
}

// 虚拟机
export const vmApi = {
  list: (token) => request('/vms', { token }),
  providers: (token) => request('/vms/providers', { token }),
  create: (payload, token) => request('/vms', { method: 'POST', body: payload, token }),
  createBatch: (payload, token) => request('/vms/batch', { method: 'POST', body: payload, token }),
  images: (token, hostId) => request('/vms/images' + (hostId ? '?host_id=' + hostId : ''), { token }),
  action: (id, action, token) =>
    request('/vms/' + id + '/action', { method: 'POST', body: { action }, token }),
  remove: (id, token) => request('/vms/' + id, { method: 'DELETE', token }),
}

// K8s 集群
export const clusterApi = {
  list: (token) => request('/clusters', { token }),
  create: (payload, token) => request('/clusters', { method: 'POST', body: payload, token }),
  detail: (id, token) => request('/clusters/' + id, { token }),
  deploy: (id, token) => request('/clusters/' + id + '/deploy', { method: 'POST', token }),
  scale: (id, payload, token) => request('/clusters/' + id + '/scale', { method: 'POST', body: payload, token }),
  prepare: (id, token) => request('/clusters/' + id + '/prepare', { method: 'POST', token }),
  sshkey: (id, token) => request('/clusters/' + id + '/sshkey', { method: 'POST', token }),
  remove: (id, token) => request('/clusters/' + id, { method: 'DELETE', token }),
}

// 部署任务
export const taskApi = {
  list: (token) => request('/tasks', { token }),
  get: (id, token) => request('/tasks/' + id, { token }),
  clearLog: (id, token) => request('/tasks/' + id + '/log', { method: 'DELETE', token }),
}

// 浏览器端把文本保存为本地文件
export function downloadText(filename, text) {
  const blob = new Blob([text], { type: 'text/plain;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}

// 下载部署任务完整日志(自动带鉴权头,获取完整 log_text 后保存为 .log 文件)
export function downloadTaskLog(task, token) {
  const id = typeof task === 'object' ? task.id : task
  return request('/tasks/' + id, { token }).then((tk) => {
    const safeName = (tk.target_name || 'task').replace(/[^\w.-]/g, '_')
    const type =
      tk.type === 'vm_create' ? 'vm-create' : tk.type === 'cluster_install' ? 'cluster-install' : tk.type || 'task'
    downloadText('task-' + tk.id + '-' + type + '-' + safeName + '.log', tk.log_text || '(暂无日志)')
  })
}

// 下载集群 kubeconfig(后端以文本返回, 需带鉴权头原始 fetch)
export function downloadClusterKubeconfig(cluster, token) {
  const id = typeof cluster === 'object' ? cluster.id : cluster
  const name = (typeof cluster === 'object' && cluster.name) || 'cluster-' + id
  const headers = {}
  if (token) headers.Authorization = 'Bearer ' + token
  return fetch('/api/clusters/' + id + '/kubeconfig', { headers })
    .then((res) => {
      if (!res.ok) {
        return res.json().catch(() => ({}))
          .then((err) => { throw new Error((err && err.detail) || ('HTTP ' + res.status)) })
      }
      return res.text()
    })
    .then((text) => downloadText('kubeconfig-' + name + '.conf', text))
}

export const CONSTANTS = {
  images: ['ubuntu-22.04-cloud.qcow2', 'ubuntu-24.04-cloud.qcow2', 'rocky-9.4-cloud.qcow2', 'debian-12-cloud.qcow2', 'centos-stream-9.qcow2'],
  k8sVersions: ['v1.27.16', 'v1.28.13', 'v1.29.8', 'v1.30.4', 'v1.31.1'],
  networkPlugins: ['calico', 'flannel', 'cilium', 'weave'],
  kubesprayVersions: ['v2.24.1', 'v2.25.0', 'v2.26.0'],
  cpus: [2, 4, 8, 16, 32],
  vmProviders: [
    { key: 'libvirt', labelKey: 'vms.providerLibvirt' },
    { key: 'kubevirt', labelKey: 'vms.providerKubevirt' },
  ],
  memories: [4, 8, 16, 32, 64],
  disks: [20, 40, 80, 160, 320],
}