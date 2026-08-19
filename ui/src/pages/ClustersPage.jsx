import { useCallback, useEffect, useRef, useState } from 'react'
import { CONSTANTS, clusterApi, downloadTaskLog, hostApi, taskApi, vmApi } from '../api/client'
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
  name: '', network_plugin: 'calico', run_node_host_id: '',
  cp_ids: [], worker_ids: [], ssh_key: '',
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
  const [hosts, setHosts] = useState([])
  const [busy, setBusy] = useState(false)
  const [detail, setDetail] = useState(null)
  const [deleting, setDeleting] = useState(null)
  const [deployingId, setDeployingId] = useState(null)
  const [wizard, setWizard] = useState(null)
  const [wizStep, setWizStep] = useState(0)
  const [stepState, setStepState] = useState({ 1: 'idle', 2: 'idle', 3: 'idle' })
  const [stepLogs, setStepLogs] = useState({ 1: '', 2: '', 3: '' })
  const [stepTaskIds, setStepTaskIds] = useState({ 1: null, 2: null, 3: null })
  const logRefs = { 1: useRef(null), 2: useRef(null), 3: useRef(null) }

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

  useEffect(() => {
    ;[1, 2, 3].forEach((n) => {
      if (logRefs[n].current) logRefs[n].current.scrollTop = logRefs[n].current.scrollHeight
    })
  }, [stepLogs])

  function openCreate() {
    setForm(emptyForm)
    setShowCreate(true)
    vmApi
      .list(token)
      .then(setVms)
      .catch(() => {})
    hostApi
      .list(token)
      .then((hs) => {
        setHosts(hs)
        setForm((f) => (f.run_node_host_id === '' && hs.length ? { ...f, run_node_host_id: String(hs[0].id) } : f))
      })
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
          network_plugin: form.network_plugin,
          run_node_host_id: form.run_node_host_id ? Number(form.run_node_host_id) : null,
          control_plane_vm_ids: form.cp_ids,
          worker_vm_ids: form.worker_ids,
          ssh_key: form.ssh_key.trim() || null,
        },
        token,
      )
      .then((c) => {
        setClusters((list) => [...list, c])
        setShowCreate(false)
        setWizard(c)
        setWizStep(0)
        setStepState({ 1: 'idle', 2: 'idle', 3: 'idle' })
        setStepLogs({ 1: '', 2: '', 3: '' })
        setStepTaskIds({ 1: null, 2: null, 3: null })
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

  function runWizardStep(n) {
    if (!wizard) return
    const apiCall = n === 1 ? clusterApi.prepare : n === 2 ? clusterApi.sshkey : clusterApi.deploy
    setStepState((s) => ({ ...s, [n]: 'running' }))
    setStepLogs((l) => ({ ...l, [n]: '' }))
    apiCall(wizard.id, token)
      .then((res) => {
        setStepTaskIds((s) => ({ ...s, [n]: res.task_id }))
        pollStep(n, res.task_id)
      })
      .catch((err) => {
        setStepState((s) => ({ ...s, [n]: 'failed' }))
        setStepLogs((l) => ({ ...l, [n]: '请求失败: ' + err.message }))
      })
  }

  function pollStep(n, taskId) {
    let iv
    const tick = () => {
      taskApi
        .get(taskId, token)
        .then((tk) => {
          setStepLogs((l) => ({ ...l, [n]: (tk.log_text || '').split('\n').slice(-80).join('\n') }))
          if (tk.status === 'success' || tk.status === 'failed') {
            clearInterval(iv)
            setStepState((s) => ({ ...s, [n]: tk.status === 'success' ? 'success' : 'failed' }))
            if (tk.status === 'success') {
              toast(t('clusters.stepOk', { n }))
              load()
            } else {
              toast(t('clusters.stepFail', { n }), 'error')
            }
          }
        })
        .catch(() => {
          clearInterval(iv)
          setStepState((s) => ({ ...s, [n]: 'failed' }))
        })
    }
    tick()
    iv = setInterval(tick, 2000)
  }

  function closeWizard() {
    setWizard(null)
    setStepTaskIds({ 1: null, 2: null, 3: null })
    load()
  }

  const WIZARD_STEPS = [
    { title: t('clusters.step1Title'), desc: t('clusters.step1Desc') },
    { title: t('clusters.step2Title'), desc: t('clusters.step2Desc') },
    { title: t('clusters.step3Title'), desc: t('clusters.step3Desc') },
  ]

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
                <th>{t('clusters.runNode')}</th>
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
                    <td className="td-mono td-muted">{c.run_node_name || t('clusters.runNodeAuto')}</td>
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
              <Select label={t('clusters.plugin')} value={form.network_plugin}
                onChange={(e) => setForm({ ...form, network_plugin: e.target.value })}>
                {CONSTANTS.networkPlugins.map((p) => <option key={p} value={p}>{p}</option>)}
              </Select>
            </div>
            <div className="field">
              <span className="field-label">{t('clusters.runNode')}</span>
              <select className="input" value={form.run_node_host_id}
                onChange={(e) => setForm({ ...form, run_node_host_id: e.target.value })}>
                <option value="">{t('clusters.runNodeAuto')}</option>
                {hosts.map((h) => (
                  <option key={h.id} value={h.id}>{h.name} ({h.ip})</option>
                ))}
              </select>
              {hosts.length === 0 && <span className="td-hint">{t('clusters.noHost')}</span>}
              <span className="td-hint">{t('clusters.runNodeHint')}</span>
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
            <div><span>{t('clusters.runNode')}</span><strong>{detail.cluster.run_node_name || t('clusters.runNodeAuto')}</strong></div>
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
            {detail.last_task && (
              <button className="btn btn-ghost"
                onClick={() => downloadTaskLog({ id: detail.last_task.id }, token).catch(() => {})}>
                {t('tasks.downloadLog')}
              </button>
            )}
            <button className="btn btn-ghost" onClick={() => setDetail(null)}>{t('common.close')}</button>
          </div>
        </Modal>
      )}

      {wizard && (
        <Modal title={t('clusters.wizardTitle', { name: wizard.name })} onClose={closeWizard} width="780px">
          <p className="cmd-note cmd-note-top">{t('clusters.wizardSub', { node: wizard.run_node_name || t('clusters.runNodeAuto') })}</p>

          {/* 步骤指示器(与添加宿主机向导一致) */}
          <div className="wizard-steps">
            {WIZARD_STEPS.map((s, i) => {
              const done = stepState[i + 1] === 'success'
              return (
                <div key={i} className={'wizard-step' + (i === wizStep ? ' active' : done ? ' done' : '')}>
                  <span className="wizard-step-dot">{done ? '✓' : String(i + 1)}</span>
                  <span className="wizard-step-label">{s.title}</span>
                </div>
              )
            })}
          </div>

          <div className="wizard-body">
            {[1, 2, 3].map((n) => {
              const st = stepState[n]
              const badge =
                st === 'success' ? 'badge-success' : st === 'failed' ? 'badge-failed' : st === 'running' ? 'badge-info' : 'badge-muted'
              const label =
                st === 'success' ? t('status.success') : st === 'failed' ? t('status.failed') : st === 'running' ? t('clusters.stepRunning') : t('clusters.stepReady')
              return (
                wizStep === n - 1 && (
                  <div key={n}>
                    <div className="wizard-step-run">
                      <span className="wizard-desc">{WIZARD_STEPS[n - 1].desc}</span>
                      <button className="btn btn-primary" disabled={st === 'running'} onClick={() => runWizardStep(n)}>
                        {st === 'running' ? t('common.loading') : st === 'success' ? t('clusters.stepRerun') : t('clusters.stepRun')}
                      </button>
                      <span className={'badge ' + badge}>{label}</span>
                      {stepTaskIds[n] && (
                        <button className="btn btn-ghost btn-sm" title={t('tasks.downloadLog')}
                          onClick={() => downloadTaskLog({ id: stepTaskIds[n] }, token).catch(() => {})}>
                          {t('common.download')}
                        </button>
                      )}
                    </div>
                    {stepLogs[n] && (
                      <pre ref={logRefs[n]} className="log-viewer wizard-step-log">
                        {stepLogs[n]}
                      </pre>
                    )}
                  </div>
                )
              )
            })}
          </div>

          {/* 底部导航(与添加宿主机向导一致) */}
          <div className="wizard-foot">
            <span className="wizard-foot-left" />
            <div className="wizard-foot-actions">
              {wizStep > 0 && (
                <button className="btn btn-ghost" onClick={() => setWizStep(wizStep - 1)}>{t('clusters.wizardPrev')}</button>
              )}
              {wizStep < 2 ? (
                <button className="btn btn-primary" disabled={stepState[wizStep + 1] !== 'success'} onClick={() => setWizStep(wizStep + 1)}>
                  {t('clusters.wizardNext')} →
                </button>
              ) : (
                <button className="btn btn-primary" onClick={closeWizard}>{t('common.close')}</button>
              )}
            </div>
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
