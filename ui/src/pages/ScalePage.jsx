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
    if (!wk.vmIds.length && !wk.hostIds.length) {
      toast(t('scale.needNode'), 'error')
      return
    }
    setBusy(true)
    clusterApi
      .scale(
        Number(clusterId),
        {
          control_plane_vm_ids: [],
          control_plane_host_ids: [],
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
    <div className="scale-page">
      <div className="page-head">
        <div>
          <h1 className="page-title">{t('scale.title')}</h1>
          <p className="page-desc">{t('scale.desc')}</p>
        </div>
      </div>

      <div className="card">
        <form onSubmit={submit}>
          <div className="node-group">
            <div className="group-label">{t('scale.cluster')}</div>
            <select className="input" value={clusterId} onChange={(e) => setClusterId(e.target.value)}>
              {readyClusters.map((c) => (
                <option key={c.id} value={c.id}>{c.name} · {c.api_server || c.k8s_version}</option>
              ))}
            </select>
            {readyClusters.length === 0 && <span className="td-hint">{t('scale.noReadyCluster')}</span>}
          </div>

          <div className="field">
            <span className="field-label">{t('scale.workerNodes')}</span>
            <span className="td-hint">{t('scale.workerOnlyHint')}</span>
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
