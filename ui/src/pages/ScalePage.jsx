import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { clusterApi, hostApi, vmApi } from '../api/client'
import { CheckboxCard } from '../components/Field'
import { useToast } from '../components/Toast'
import { useAuth } from '../context/AuthContext'
import { useI18n } from '../i18n'

export default function ScalePage() {
  const { token } = useAuth()
  const { t } = useI18n()
  const toast = useToast()

  const [clusters, setClusters] = useState([])
  const [vms, setVms] = useState([])
  const [hosts, setHosts] = useState([])
  const [clusterId, setClusterId] = useState('')
  const [cp, setCp] = useState({ vmIds: [], hostIds: [] })
  const [wk, setWk] = useState({ vmIds: [], hostIds: [] })
  const [busy, setBusy] = useState(false)
  const [lastTask, setLastTask] = useState(null)

  useEffect(() => {
    Promise.all([clusterApi.list(token), vmApi.list(token), hostApi.list(token)])
      .then(([cs, vs, hs]) => {
        setClusters(cs)
        setVms(vs)
        setHosts(hs)
        const ready = cs.filter((c) => c.status === 'ready')
        if (ready.length) setClusterId(String(ready[0].id))
      })
      .catch((err) => toast(err.message, 'error'))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [token])

  const freeVms = vms.filter((v) => !v.in_cluster)
  const freeHosts = hosts.filter((h) => !h.in_cluster)
  const readyClusters = clusters.filter((c) => c.status === 'ready')

  // 互斥: 控制平面与工作节点不能选同一节点
  function toggleCpVm(id) {
    const adding = !cp.vmIds.includes(id)
    setCp({ ...cp, vmIds: adding ? [...cp.vmIds, id] : cp.vmIds.filter((x) => x !== id) })
    if (adding) setWk({ ...wk, vmIds: wk.vmIds.filter((x) => x !== id) })
  }
  function toggleCpHost(id) {
    const adding = !cp.hostIds.includes(id)
    setCp({ ...cp, hostIds: adding ? [...cp.hostIds, id] : cp.hostIds.filter((x) => x !== id) })
    if (adding) setWk({ ...wk, hostIds: wk.hostIds.filter((x) => x !== id) })
  }
  function toggleWorkerVm(id) {
    const adding = !wk.vmIds.includes(id)
    setWk({ ...wk, vmIds: adding ? [...wk.vmIds, id] : wk.vmIds.filter((x) => x !== id) })
    if (adding) setCp({ ...cp, vmIds: cp.vmIds.filter((x) => x !== id) })
  }
  function toggleWorkerHost(id) {
    const adding = !wk.hostIds.includes(id)
    setWk({ ...wk, hostIds: adding ? [...wk.hostIds, id] : wk.hostIds.filter((x) => x !== id) })
    if (adding) setCp({ ...cp, hostIds: cp.hostIds.filter((x) => x !== id) })
  }

  function submit(e) {
    e.preventDefault()
    if (!clusterId) {
      toast(t('scale.needCluster'), 'error')
      return
    }
    if (!cp.vmIds.length && !cp.hostIds.length && !wk.vmIds.length && !wk.hostIds.length) {
      toast(t('scale.needNode'), 'error')
      return
    }
    setBusy(true)
    clusterApi
      .scale(
        Number(clusterId),
        {
          control_plane_vm_ids: cp.vmIds,
          control_plane_host_ids: cp.hostIds,
          worker_vm_ids: wk.vmIds,
          worker_host_ids: wk.hostIds,
        },
        token
      )
      .then((res) => {
        setLastTask(res.task_id)
        toast(t('scale.started', { id: res.task_id }))
      })
      .catch((err) => toast(err.message, 'error'))
      .finally(() => setBusy(false))
  }

  return (
    <div>
      <div className="page-head">
        <div>
          <h1 className="page-title">{t('scale.title')}</h1>
          <p className="page-desc">{t('scale.desc')}</p>
        </div>
      </div>

      <div className="card">
        <form onSubmit={submit}>
          <div className="field">
            <span className="field-label">{t('scale.cluster')}</span>
            <select className="input" value={clusterId} onChange={(e) => setClusterId(e.target.value)}>
              {readyClusters.map((c) => (
                <option key={c.id} value={c.id}>{c.name} · {c.api_server || c.k8s_version}</option>
              ))}
            </select>
            {readyClusters.length === 0 && <span className="td-hint">{t('scale.noReadyCluster')}</span>}
          </div>

          <div className="field">
            <span className="field-label">{t('scale.cpNodes')}</span>
            <span className="td-hint">{t('scale.mutexHint')}</span>
            <div className="node-group">
              <div className="group-label">{t('clusters.groupHosts')}</div>
              <div className="checkbox-grid">
                {freeHosts.map((h) => (
                  <CheckboxCard
                    key={'scph-' + h.id}
                    label={h.name}
                    sub={h.ip + ' · 🖥 宿主机'}
                    checked={cp.hostIds.includes(h.id)}
                    onChange={() => toggleCpHost(h.id)}
                  />
                ))}
                {freeHosts.length === 0 && <span className="td-hint">{t('clusters.noHost')}</span>}
              </div>
            </div>
            <div className="node-group">
              <div className="group-label">{t('clusters.groupVms')}</div>
              <div className="checkbox-grid">
                {freeVms.map((v) => (
                  <CheckboxCard
                    key={'scpv-' + v.id}
                    label={v.name}
                    sub={v.ip + ' · ☁ ' + v.cpu + 'c/' + v.memory_gb + 'G'}
                    checked={cp.vmIds.includes(v.id)}
                    onChange={() => toggleCpVm(v.id)}
                  />
                ))}
                {freeVms.length === 0 && <span className="td-hint">{t('clusters.noVm')}</span>}
              </div>
            </div>
          </div>

          <div className="field">
            <span className="field-label">{t('scale.workerNodes')}</span>
            <div className="node-group">
              <div className="group-label">{t('clusters.groupHosts')}</div>
              <div className="checkbox-grid">
                {freeHosts.map((h) => (
                  <CheckboxCard
                    key={'scwh-' + h.id}
                    label={h.name}
                    sub={h.ip + ' · 🖥 宿主机'}
                    checked={wk.hostIds.includes(h.id)}
                    onChange={() => toggleWorkerHost(h.id)}
                  />
                ))}
                {freeHosts.length === 0 && <span className="td-hint">{t('clusters.noHost')}</span>}
              </div>
            </div>
            <div className="node-group">
              <div className="group-label">{t('clusters.groupVms')}</div>
              <div className="checkbox-grid">
                {freeVms.map((v) => (
                  <CheckboxCard
                    key={'scwv-' + v.id}
                    label={v.name}
                    sub={v.ip + ' · ☁ ' + v.cpu + 'c/' + v.memory_gb + 'G'}
                    checked={wk.vmIds.includes(v.id)}
                    onChange={() => toggleWorkerVm(v.id)}
                  />
                ))}
                {freeVms.length === 0 && <span className="td-hint">{t('clusters.noVm')}</span>}
              </div>
            </div>
          </div>

          <div className="modal-actions" style={{ paddingTop: 8 }}>
            <button type="submit" className="btn btn-primary" disabled={busy}>
              {busy ? t('common.loading') : t('scale.button')}
            </button>
            {lastTask && (
              <Link to="/tasks" className="btn btn-ghost">{t('scale.viewTasks')} (#{lastTask})</Link>
            )}
          </div>
        </form>
      </div>
    </div>
  )
}
