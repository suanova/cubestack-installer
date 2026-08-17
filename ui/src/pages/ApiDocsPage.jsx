import { useI18n } from '../i18n'

const DOCS = [
  {
    section: ['认证', 'Auth'],
    items: [
      { m: 'POST', p: '/api/auth/register', d: ['用户注册', 'User registration'], input: '{"username":"alice","email":"alice@example.com","password":"secret123","full_name":"Alice"}', output: '201 {"id":2,"username":"alice","role":"user",...}' },
      { m: 'POST', p: '/api/auth/login', d: ['登录,返回 JWT 与用户信息', 'Login, returns JWT and user'], input: '{"account":"alice","password":"secret123"}', output: '200 {"access_token":"eyJ...","token_type":"bearer","user":{...}}' },
      { m: 'GET', p: '/api/auth/me', d: ['当前登录用户', 'Current authenticated user'], input: '-', output: '200 {"id":2,"username":"alice","role":"user",...}' },
    ],
  },
  {
    section: ['宿主机', 'Hosts'],
    items: [
      { m: 'GET', p: '/api/hosts', d: ['宿主机列表', 'List hosts'], input: '-', output: '200 [{"id":1,"name":"node1","ip":"192.168.10.11","status":"online",...}]' },
      { m: 'POST', p: '/api/hosts', d: ['添加宿主机(管理员)', 'Add host (admin)'], input: '{"name":"node3","ip":"192.168.10.13","ssh_user":"root","ssh_port":22,"cpu_cores":8,"memory_gb":32,"disk_gb":500}', output: '201 {"id":3,"name":"node3","status":"unknown",...}' },
      { m: 'POST', p: '/api/hosts/precheck', d: ['宿主机向导预检:免密连通 + Ubuntu/libvirt 环境检测(不落库)', 'Host wizard precheck: SSH + Ubuntu/libvirt env check'], input: '{"name":"node3","ip":"192.168.10.13","ssh_user":"ubuntu","ssh_port":22,"cpu_cores":8,"memory_gb":32,"disk_gb":500}', output: '200 {"id":0,"name":"node3","status":"online","libvirt_ready":true,"check_report":"{\"packages\":{...}}"}' },
      { m: 'POST', p: '/api/hosts/{id}/check', d: ['SSH 连通性检测', 'SSH connectivity check'], input: '-', output: '200 {"id":3,"status":"online",...}' },
      { m: 'DELETE', p: '/api/hosts/{id}', d: ['删除宿主机(管理员)', 'Delete host (admin)'], input: '-', output: '200 {"message":"ok"}' },
    ],
  },
  {
    section: ['虚拟机', 'Virtual Machines'],
    items: [
      { m: 'GET', p: '/api/vms/providers', d: ['虚拟化后端状态(libvirt / kubevirt)', 'Virtualization backend status'], input: '-', output: '200 [{"key":"libvirt","name":"Libvirt","available":true,"mode":"real","detail":"..."}]' },
      { m: 'GET', p: '/api/vms/images?host_id=', d: ['MinIO 模板镜像列表(cubestack/installer/vm),host_id 可选', 'List MinIO template images (optional host_id)'], input: 'query: host_id', output: '200 [{"name":"ubuntu-template-v2.qcow2","size":6109069312,"last_modified":"..."}]' },
      { m: 'POST', p: '/api/vms/batch', d: ['从一个宿主机批量创建多台 VM,默认 2vCPU/16GB(管理员)', 'Batch create VMs from one host (admin)'], input: '{"names":["master1","master2","master3"],"host_id":3,"cpu":2,"memory_gb":16,"disk_gb":40,"image":"ubuntu-template-v2.qcow2"}', output: '202 {"task_ids":[6,7,8],"vms":[{"id":4,"name":"master1","status":"pending",...}]}' },
      { m: 'GET', p: '/api/vms', d: ['虚拟机列表(含宿主机信息)', 'List VMs with host info'], input: '-', output: '200 [{"id":1,"name":"k8s-master-1","host_name":"node1","ip":"192.168.10.101","status":"running",...}]' },
      { m: 'POST', p: '/api/vms', d: ['创建虚拟机,返回并启动部署任务(管理员)', 'Create VM, returns task (admin)'], input: '{"name":"k8s-node-4","host_id":2,"cpu":2,"memory_gb":16,"disk_gb":80,"image":"ubuntu-22.04-cloud.qcow2"}', output: '202 {"task_id":7,"vm":{"id":5,"name":"k8s-node-4","status":"pending",...}}' },
      { m: 'POST', p: '/api/vms/{id}/action', d: ['电源操作 start|stop|reboot(管理员)', 'Power actions (admin)'], input: '{"action":"start"}', output: '200 {"id":5,"status":"running",...}' },
      { m: 'DELETE', p: '/api/vms/{id}', d: ['删除虚拟机(管理员)', 'Delete VM (admin)'], input: '-', output: '200 {"message":"ok"}' },
    ],
  },
  {
    section: ['K8s 集群', 'K8s Clusters'],
    items: [
      { m: 'GET', p: '/api/clusters', d: ['集群列表(含节点统计)', 'List clusters with node counts'], input: '-', output: '200 [{"id":1,"name":"prod-cluster","k8s_version":"v1.29.8","status":"ready","control_plane_count":1,"worker_count":2}]' },
      { m: 'POST', p: '/api/clusters', d: ['创建集群,快照节点(管理员)', 'Create cluster (admin)'], input: '{"name":"prod-cluster","k8s_version":"v1.29.8","network_plugin":"calico","kubespray_version":"v2.25.0","control_plane_vm_ids":[1],"worker_vm_ids":[2,3],"ssh_key":null}', output: '201 {"id":1,"name":"prod-cluster","status":"pending",...}' },
      { m: 'GET', p: '/api/clusters/{id}', d: ['集群详情(节点与最近任务)', 'Cluster detail with nodes'], input: '-', output: '200 {"cluster":{...},"nodes":[{...}],"last_task":{...}}' },
      { m: 'POST', p: '/api/clusters/{id}/deploy', d: ['启动 Kubespray 安装(管理员)', 'Start Kubespray install (admin)'], input: '-', output: '202 {"task_id":8}' },
      { m: 'DELETE', p: '/api/clusters/{id}', d: ['删除集群(管理员)', 'Delete cluster (admin)'], input: '-', output: '200 {"message":"ok"}' },
    ],
  },
  {
    section: ['部署任务', 'Deploy Tasks'],
    items: [
      { m: 'GET', p: '/api/tasks', d: ['任务列表(含进度与日志摘要)', 'List tasks with progress'], input: '-', output: '200 [{"id":8,"type":"cluster_install","target_name":"prod-cluster","status":"success","progress":100,"log_excerpt":"..."}]' },
      { m: 'GET', p: '/api/tasks/{id}', d: ['任务详情(完整日志流)', 'Task detail with full log'], input: '-', output: '200 {"id":8,"type":"cluster_install","status":"running","progress":55,"log_text":"[1/8] ..."}' },
    ],
  },
  {
    section: ['用户管理', 'User Management'],
    items: [
      { m: 'GET', p: '/api/users', d: ['用户列表(需登录)', 'List users (auth required)'], input: '-', output: '200 [{"id":1,"username":"admin","role":"admin",...}]' },
      { m: 'PATCH', p: '/api/users/{id}', d: ['修改角色/状态/姓名(管理员)', 'Update role/status (admin)'], input: '{"role":"admin","is_active":true}', output: '200 {"id":2,"username":"alice","role":"admin",...}' },
      { m: 'DELETE', p: '/api/users/{id}', d: ['删除用户(管理员)', 'Delete user (admin)'], input: '-', output: '200 {"message":"ok"}' },
    ],
  },
]

const METHOD_CLS = { GET: 'method-get', POST: 'method-post', PATCH: 'method-patch', DELETE: 'method-delete' }

export default function ApiDocsPage() {
  const { t, isZh } = useI18n()
  return (
    <div>
      <div className="page-head">
        <div>
          <h1 className="page-title">{t('apidocs.title')}</h1>
          <p className="page-desc">
            {t('apidocs.desc')}{' '}
            <a href="http://127.0.0.1:8000/docs" target="_blank" rel="noreferrer">Swagger UI →</a>
            {t('apidocs.selfWrite')}
          </p>
        </div>
      </div>

      {DOCS.map((sec) => (
        <section className="card api-section" key={sec.section[0]}>
          <div className="card-head">
            <h2 className="card-title">{isZh ? sec.section[0] : sec.section[1]}</h2>
          </div>
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>{t('apidocs.method')}</th>
                  <th>{t('apidocs.path')}</th>
                  <th>{t('apidocs.descCol')}</th>
                  <th>{t('apidocs.input')}</th>
                  <th>{t('apidocs.output')}</th>
                </tr>
              </thead>
              <tbody>
                {sec.items.map((it, i) => (
                  <tr key={i}>
                    <td><span className={'method-chip ' + (METHOD_CLS[it.m] || 'method-get')}>{it.m}</span></td>
                    <td className="td-mono">{it.p}</td>
                    <td className="api-desc">{isZh ? it.d[0] : it.d[1]}</td>
                    <td><code className="api-code">{it.input}</code></td>
                    <td><code className="api-code">{it.output}</code></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      ))}
    </div>
  )
}