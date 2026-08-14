import { useCallback, useEffect, useState } from 'react'
import { CONSTANTS, clusterApi, vmApi } from '../api/client'
import Field, { CheckboxCard, Select } from '../components/Field'
import Modal from '../components/Modal'
import { useToast } from '../components/Toast'
import { useAuth } from '../context/AuthContext'
import { useI18n } from '../i18n'

const STATUS_MAP = {
  pending: { key: 'status.pending', cls: 'badge-muted' },
  installing: { key: 'status.installing', cls: 'badge-info' },
  ready: { key: 'status.ready', cls: 'badge-success' },
  failed: { key: 'status.failed', cls: 'badge-failed' },
}

const emptyForm = {
  name: '', k8s_version: CONSTANTS.k8sVersions[2], network_plugin: 'calico',
  kubespray_version: CONSTANTS.kubesprayVersions[1], cp_ids: [], worker_ids: [], ssh_key: '',
}

export default function ClustersPage() {
  const { token } = useAuth()
  const { t } = useI18n()
  const toast = useToast()

  const [clusters, setClusters] = useState([])
  const [loading, setLoading] = useState(true)
  const [showCreate, setShowCreate] = useState(false)
  const [form, setForm] = useState(emptyForm)
  const [vms, setVms] = useState([])
  const [busy, setBusy] = useState(false)
  const [detail, setDetail] = useState(null)
  const [deleting, setDeleting] = useState(null)
  const [deployingId, setDeployingId] = useState(null)

  const load = useCallback(() => {
    clusterApi
      .list(token)
      .then(setClusters)
      .catch(() => {})
      .finally(() => setLoading(false))
  }, [token])

  useEffect(() => {
    load()
    const iv = setInterval(load, 4000)
    return () => clearInterval(iv)
  }, [load])

  function openCreate() {
    setForm(emptyForm)
    setShowCreate(true)
    vmApi
      .list(token)
      .then(setVms)
      .catch(() => {})
  }

  function toggleCp(id) {
    setForm((f) => ({
      ...f,
      cp_ids: f.cp_ids.includes(id) ? f.cp_ids.filter((x) => x !== id) : [...f.cp_ids, id],
    }))
  }

  function toggleWorker(id) {
    setForm((f) => ({
      ...f,
      worker_ids: f.worker_ids.includes(id) ? f.worker_ids.filter((x) => x !== id) : [...f.worker_ids, id],
    }))
  }

  function submitCreate(e) {
    e.preventDefault()
    if (!form.cp_ids.length) {
      toast(t('clusters.needCp'), 'error')
      return
    }
    setBusy(true)
    clusterApi
      .create(
        {
          name: form.name.trim(),
          k8s_version: form.k8s_version,
          network_plugin: form.network_plugin,
          kubespray_version: form.kubespray_version,
          control_plane_vm_ids: form.cp_ids,
          worker_vm_ids: form.worker_ids,
          ssh_key: form.ssh_key.trim() || null,
        },
        token,
      )
      .then((c) => {
        setClusters((list) => [...list, c])
        setShowCreate(false)
        toast(t('clusters.created', { name: c.name }))
      })
      .catch((err) => toast(err.message, 'error'))
      .finally(() => setBusy(false))
  }

  function doDeploy(id) {
    setDeployingId(id)
    clusterApi
      .deploy(id, token)
      .then((res) => {
        toast(t('clusters.deployStarted', { id: res.task_id }))
        setTimeout(load, 1000)
      })
      .catch((err) => toast(err.message, 'error'))
      .finally(() => setDeployingId(null))
  }

  function openDetail(id) {
    clusterApi
      .detail(id, token)
      .then(setDetail)
      .catch((err) => toast(err.message, 'error'))
  }

  function confirmDelete() {
    if (!deleting) return
    clusterApi
      .remove(deleting.id, token)
      .then(() => {
        setClusters((list) => list.filter((c) => c.id !== deleting.id))
        toast(t('clusters.deleted', { name: deleting.name }))
        setDeleting(null)
      })
      .catch((err) => {
        toast(err.message, 'error')
        setDeleting(null)
      })
  }

  if (loading) {
    return (
      <div className="page-loader">
        <div className="spinner" />
      </div>
    )
  }

  return (
    <div>
      <div className="page-head">
        <div>
          <h1 className="page-title">{t('clusters.title')}</h1>
          <p className="page-desc">{t('clusters.desc')}</p>
        </div>
        <button className="btn btn-primary" onClick={openCreate}>＋ {t('clusters.create')}</button>
      </div>

      <div className="card">
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>{t('common.name')}</th>
                <th>{t('clusters.version')}</th>
                <th>{t('clusters.nodes')}</th>
                <th>Kubespray</th>
                <th>{t('common.status')}</th>
                <th className="th-actions">{t('common.actions')}</th>
              </tr>
            </thead>
            <tbody>
              {clusters.map((c) => {
                const st = STATUS_MAP[c.status] || { key: c.status, cls: 'badge-muted' }
                return (
                  <tr key={c.id}>
                    <td>
                      <div className="user-cell">
                        <span className="avatar avatar-sm avatar-k8s">☸</span>
                        <div>
                          <div className="cell-name">{c.name}</div>
                          <div className="cell-sub">{t('common.id')} #{c.id}</div>
                        </div>
                      </div>
                    </td>
                    <td>
                      <div className="cell-name">{c.k8s_version}</div>
                      <div className="cell-sub">{c.network_plugin}</div>
                    </td>
                    <td>
                      <div className="spec">
                        <span className="spec-cp">{t('clusters.cpCount', { n: c.control_plane_count })}</span>
                        <span>{t('clusters.workerCount', { n: c.worker_count })}</span>
                      </div>
                    </td>
                    <td className="td-mono td-muted">{c.kubespray_version}</td>
                    <td>
                      <span className={'badge ' + st.cls}>{t(st.key)}</span>
                    </td>
                    <td>
                      <div className="td-actions">
                        {(c.status === 'pending' || c.status === 'failed') && (
                          <button className="btn btn-primary btn-sm" disabled={deployingId === c.id} onClick={() => doDeploy(c.id)}>
                            {deployingId === c.id ? t('common.loading') : t('clusters.install')}
                          </button>
                        )}
                        {c.status === 'installing' && <span className="td-hint">{t('clusters.installingHint')}</span>}
                        <button className="btn btn-ghost btn-sm" onClick={() => openDetail(c.id)}>{t('clusters.detail')}</button>
                        <button className="btn btn-danger btn-sm" onClick={() => setDeleting(c)}>{t('common.delete')}</button>
                      </div>
                    </td>
                  </tr>
                )
              })}
              {clusters.length === 0 && (
                <tr>
                  <td colSpan="6" className="td-empty">{t('clusters.empty')}</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>

      {showCreate && (
        <Modal title={t('clusters.createTitle')} onClose={() => setShowCreate(false)} width="640px">
          <form onSubmit={submitCreate}>
            <div className="grid-2">
              <Field label={t('clusters.name')} placeholder="prod-cluster" value={form.name} required
                onChange={(e) => setForm({ ...form, name: e.target.value })} />
              <Select label={t('clusters.k8sVersion')} value={form.k8s_version}
                onChange={(e) => setForm({ ...form, k8s_version: e.target.value })}>
                {CONSTANTS.k8sVersions.map((v) => <option key={v} value={v}>{v}</option>)}
              </Select>
            </div>
            <div className="grid-2">
              <Select label={t('clusters.plugin')} value={form.network_plugin}
                onChange={(e) => setForm({ ...form, network_plugin: e.target.value })}>
                {CONSTANTS.networkPlugins.map((p) => <option key={p} value={p}>{p}</option>)}
              </Select>
              <Select label={t('clusters.kubespray')} value={form.kubespray_version}
                onChange={(e) => setForm({ ...form, kubespray_version: e.target.value })}>
                {CONSTANTS.kubesprayVersions.map((v) => <option key={v} value={v}>{v}</option>)}
              </Select>
            </div>

            <div className="field">
              <span className="field-label">{t('clusters.cpNodes')}</span>
              <div className="checkbox-grid">
                {vms.map((v) => (
                  <CheckboxCard
                    key={'cp-' + v.id}
                    label={v.name}
                    sub={v.ip + ' · ' + v.cpu + 'c/' + v.memory_gb + 'G'}
                    checked={form.cp_ids.includes(v.id)}
                    onChange={() => toggleCp(v.id)}
                  />
                ))}
                {vms.length === 0 && <span className="td-hint">{t('clusters.noVm')}</span>}
              </div>
            </div>

            <div className="field">
              <span className="field-label">{t('clusters.workerNodes')}</span>
              <div className="checkbox-grid">
                {vms.map((v) => (
                  <CheckboxCard
                    key={'wk-' + v.id}
                    label={v.name}
                    sub={v.ip + ' · ' + v.cpu + 'c/' + v.memory_gb + 'G'}
                    checked={form.worker_ids.includes(v.id)}
                    onChange={() => toggleWorker(v.id)}
                  />
                ))}
              </div>
            </div>

            <Field label={t('clusters.sshKey')} placeholder={t('clusters.sshKeyHint')} value={form.ssh_key}
              onChange={(e) => setForm({ ...form, ssh_key: e.target.value })} />

            <div className="modal-actions">
              <button type="button" className="btn btn-ghost" onClick={() => setShowCreate(false)}>{t('common.cancel')}</button>
              <button type="submit" className="btn btn-primary" disabled={busy}>{busy ? t('common.loading') : t('clusters.create')}</button>
            </div>
          </form>
        </Modal>
      )}

      {detail && (
        <Modal title={t('clusters.detailTitle', { name: detail.cluster.name })} onClose={() => setDetail(null)} width="600px">
          <div className="detail-kv">
            <div><span>{t('clusters.k8sVersion')}</span><strong>{detail.cluster.k8s_version}</strong></div>
            <div><span>{t('clusters.plugin')}</span><strong>{detail.cluster.network_plugin}</strong></div>
            <div><span>Kubespray</span><strong>{detail.cluster.kubespray_version}</strong></div>
            <div><span>{t('common.status')}</span>
              <strong>
                <span className={'badge ' + (STATUS_MAP[detail.cluster.status] || {}).cls}>
                  {t((STATUS_MAP[detail.cluster.status] || { key: detail.cluster.status }).key)}
                </span>
              </strong>
            </div>
          </div>
          <table className="mini-table">
            <thead>
              <tr><th>{t('clusters.node')}</th><th>{t('hosts.ip')}</th><th>{t('common.role')}</th></tr>
            </thead>
            <tbody>
              {detail.nodes.map((n) => (
                <tr key={n.id}>
                  <td className="cell-name">{n.name}</td>
                  <td className="td-mono">{n.ip || '-'}</td>
                  <td>
                    <span className={'badge ' + (n.role === 'control_plane' ? 'badge-admin' : 'badge-user')}>
                      {n.role === 'control_plane' ? t('clusters.roleCp') : t('clusters.roleWorker')}
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          {detail.last_task && (
            <p className="detail-task-hint">
              {t('clusters.lastTask')} #{detail.last_task.id}:
              <span className={'badge ' + (detail.last_task.status === 'success' ? 'badge-success' : detail.last_task.status === 'failed' ? 'badge-failed' : 'badge-info')}>
                {t('status.' + detail.last_task.status)}
              </span>
            </p>
          )}
          <div className="modal-actions">
            <button className="btn btn-ghost" onClick={() => setDetail(null)}>{t('common.close')}</button>
          </div>
        </Modal>
      )}

      {deleting && (
        <Modal title={t('clusters.deleteTitle')} onClose={() => setDeleting(null)}>
          <p className="modal-text">{t('clusters.deleteMsg', { name: deleting.name })}</p>
          <div className="modal-actions">
            <button className="btn btn-ghost" onClick={() => setDeleting(null)}>{t('common.cancel')}</button>
            <button className="btn btn-danger" onClick={confirmDelete}>{t('common.confirm')}</button>
          </div>
        </Modal>
      )}
    </div>
  )
}
