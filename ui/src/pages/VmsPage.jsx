import { useCallback, useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { CONSTANTS, vmApi } from '../api/client'
import Field, { Select } from '../components/Field'
import Modal from '../components/Modal'
import { useToast } from '../components/Toast'
import { useAuth } from '../context/AuthContext'
import { useI18n } from '../i18n'

const STATUS_MAP = {
  pending: { key: 'status.pending', cls: 'badge-muted' },
  creating: { key: 'status.creating', cls: 'badge-info' },
  running: { key: 'status.running', cls: 'badge-success' },
  stopped: { key: 'status.stopped', cls: 'badge-warning' },
  error: { key: 'status.error', cls: 'badge-failed' },
}

const ACTION_DONE = { start: 'vms.doneStart', stop: 'vms.doneStop', reboot: 'vms.doneReboot' }
const PROVIDER_CLS = { libvirt: 'badge-cyan', kubevirt: 'badge-violet' }
const NAME_RE = /^[A-Za-z0-9_.-]{2,80}$/

const emptyBatch = {
  names: '', host_id: '', cpu: '2', memory_gb: '16', disk_gb: '40',
  image: '', manual: '', images: [], imagesLoading: false, imagesError: false,
}

export default function VmsPage() {
  const { token } = useAuth()
  const { t } = useI18n()
  const toast = useToast()
  const navigate = useNavigate()

  const [vms, setVms] = useState([])
  const [hosts, setHosts] = useState([])
  const [providers, setProviders] = useState([])
  const [loading, setLoading] = useState(true)
  const [showCreate, setShowCreate] = useState(false)
  const [batch, setBatch] = useState(emptyBatch)
  const [errors, setErrors] = useState({})
  const [busy, setBusy] = useState(false)
  const [result, setResult] = useState(null) // { names: [...] }
  const [deleting, setDeleting] = useState(null)
  const timer = useRef(null)

  const load = useCallback(() => {
    vmApi
      .list(token)
      .then(setVms)
      .catch(() => {})
  }, [token])

  const loadProviders = useCallback(() => {
    vmApi
      .providers(token)
      .then(setProviders)
      .catch(() => {})
  }, [token])

  useEffect(() => {
    load()
    loadProviders()
    timer.current = setInterval(() => {
      load()
      setVms((list) => {
        if (!list.some((v) => v.status === 'pending' || v.status === 'creating')) {
          clearInterval(timer.current)
        }
        return list
      })
    }, 2500)
    return () => clearInterval(timer.current)
  }, [load, loadProviders])

  useEffect(() => {
    setLoading(false)
  }, [vms])

  // ---------- 镜像列表 ----------
  function loadImages(hostId) {
    setBatch((b) => ({ ...b, imagesLoading: true, imagesError: false }))
    vmApi
      .images(token, hostId)
      .then((imgs) => {
        const list = imgs || []
        setBatch((b) => ({ ...b, images: list, imagesLoading: false, imagesError: list.length === 0 }))
      })
      .catch(() => setBatch((b) => ({ ...b, imagesLoading: false, imagesError: true })))
  }

  function openCreate() {
    setBatch({ ...emptyBatch })
    setErrors({})
    setShowCreate(true)
    fetch('/api/hosts', { headers: { Authorization: 'Bearer ' + token } })
      .then((r) => r.json())
      .then((list) => {
        setHosts(list)
        const real = list.find((h) => !h.is_demo)
        if (real) {
          setBatch((b) => ({ ...b, host_id: String(real.id) }))
          loadImages(real.id)
        } else {
          loadImages()
        }
      })
      .catch(() => {})
  }

  // ---------- 批量创建 ----------
  function parseNames() {
    const raw = batch.names
      .split(/[\n,]+/)
      .map((s) => s.trim())
      .filter(Boolean)
    const seen = new Set()
    const names = []
    for (const n of raw) {
      if (!seen.has(n)) {
        seen.add(n)
        names.push(n)
      }
    }
    return names
  }

  function submitBatch(e) {
    e.preventDefault()
    const errs = {}
    const names = parseNames()
    if (!batch.host_id) errs.host_id = t('vms.selectHost')
    if (names.length === 0) errs.names = t('vms.needNames')
    else if (names.some((n) => !NAME_RE.test(n))) errs.names = t('vms.badName')
    const image = (batch.image || '').trim() || (batch.manual || '').trim()
    if (!image) errs.image = t('vms.needImage')
    if (Object.keys(errs).length) {
      setErrors(errs)
      return
    }
    setErrors({})
    setBusy(true)
    vmApi
      .createBatch(
        {
          names,
          host_id: parseInt(batch.host_id, 10),
          cpu: parseInt(batch.cpu, 10),
          memory_gb: parseInt(batch.memory_gb, 10),
          disk_gb: parseInt(batch.disk_gb, 10),
          image,
          provider: 'libvirt',
        },
        token,
      )
      .then(() => {
        setShowCreate(false)
        setResult({ names })
        toast(t('vms.batchCreated', { n: names.length }))
        setTimeout(load, 800)
      })
      .catch((err) => toast(err.message, 'error'))
      .finally(() => setBusy(false))
  }

  // ---------- 电源操作 / 删除 ----------
  function doAction(id, action, name) {
    vmApi
      .action(id, action, token)
      .then((v) => {
        setVms((list) => list.map((x) => (x.id === v.id ? v : x)))
        toast(t('vms.actionDone', { name, action: t(ACTION_DONE[action]) }))
      })
      .catch((err) => toast(err.message, 'error'))
  }

  function confirmDelete() {
    if (!deleting) return
    vmApi
      .remove(deleting.id, token)
      .then(() => {
        setVms((list) => list.filter((v) => v.id !== deleting.id))
        toast(t('vms.deleted', { name: deleting.name }))
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

  const resultAllDone = result && result.names.every((name) => {
    const v = vms.find((x) => x.name === name)
    return v && (v.status === 'running' || v.status === 'error' || v.status === 'stopped')
  })

  return (
    <div>
      <div className="page-head">
        <div>
          <h1 className="page-title">{t('vms.title')}</h1>
          <p className="page-desc">{t('vms.desc')}</p>
        </div>
        <button className="btn btn-primary" onClick={openCreate}>＋ {t('vms.create')}</button>
      </div>

      {/* 虚拟化后端状态 */}
      {providers.length > 0 && (
        <div className="providers-bar">
          <span className="providers-label">{t('vms.providersTitle')}:</span>
          {providers.map((p) => (
            <span key={p.key} className={'provider-chip ' + (p.available ? 'provider-ok' : 'provider-off')}>
              <span className={'badge ' + (PROVIDER_CLS[p.key] || 'badge-muted')}>{p.name}</span>
              <span className={'badge ' + (p.available ? 'badge-success' : 'badge-warning')}>
                {p.available ? t('vms.connected') + ' · ' + t('vms.modeReal') : t('vms.notConnected') + ' · ' + t('vms.modeSim')}
              </span>
            </span>
          ))}
        </div>
      )}

      <div className="card">
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>{t('common.name')}</th>
                <th>{t('vms.providerCol')}</th>
                <th>{t('vms.host')}</th>
                <th>{t('hosts.spec')}</th>
                <th>{t('vms.image')}</th>
                <th>{t('hosts.ip')}</th>
                <th>{t('common.status')}</th>
                <th className="th-actions">{t('common.actions')}</th>
              </tr>
            </thead>
            <tbody>
              {vms.map((v) => {
                const st = STATUS_MAP[v.status] || { key: v.status, cls: 'badge-muted' }
                return (
                  <tr key={v.id}>
                    <td>
                      <div className="user-cell">
                        <span className="avatar avatar-sm">{v.name.slice(0, 1).toUpperCase()}</span>
                        <div>
                          <div className="cell-name">
                            {v.name}
                            {v.is_demo && <span className="tag-demo">{t('common.demo')}</span>}
                          </div>
                          <div className="cell-sub">{t('common.id')} #{v.id}</div>
                        </div>
                      </div>
                    </td>
                    <td>
                      <span className={'badge ' + (PROVIDER_CLS[v.provider] || 'badge-muted')}>
                        {v.provider === 'kubevirt' ? t('vms.providerKubevirt') : t('vms.providerLibvirt')}
                      </span>
                      {v.provider === 'kubevirt' && v.namespace && (
                        <div className="cell-sub">ns: {v.namespace}</div>
                      )}
                    </td>
                    <td>
                      <div className="cell-name">{v.host_name || '-'}</div>
                      <div className="cell-sub">{v.host_ip}</div>
                    </td>
                    <td>
                      <div className="spec">
                        <span>{v.cpu} vCPU</span>
                        <span>{v.memory_gb} GB</span>
                        <span>{v.disk_gb} GB</span>
                      </div>
                    </td>
                    <td className="td-mono td-muted">{v.image}</td>
                    <td className="td-mono">{v.ip || '-'}</td>
                    <td>
                      <span className={'badge ' + st.cls}>{t(st.key)}</span>
                    </td>
                    <td>
                      <div className="td-actions">
                        {v.status === 'stopped' && (
                          <button className="btn btn-ghost btn-sm" onClick={() => doAction(v.id, 'start', v.name)}>{t('vms.start')}</button>
                        )}
                        {v.status === 'running' && (
                          <>
                            <button className="btn btn-ghost btn-sm" onClick={() => doAction(v.id, 'stop', v.name)}>{t('vms.stop')}</button>
                            <button className="btn btn-ghost btn-sm" onClick={() => doAction(v.id, 'reboot', v.name)}>{t('vms.reboot')}</button>
                          </>
                        )}
                        {v.status === 'creating' && <span className="td-hint">{t('vms.creatingHint')}</span>}
                        <button className="btn btn-danger btn-sm" onClick={() => setDeleting(v)}>{t('common.delete')}</button>
                      </div>
                    </td>
                  </tr>
                )
              })}
              {vms.length === 0 && (
                <tr>
                  <td colSpan="8" className="td-empty">{t('vms.empty')}</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* 批量创建弹窗 */}
      {showCreate && (
        <Modal title={t('vms.batchTitle')} onClose={() => setShowCreate(false)} width="600px">
          <form onSubmit={submitBatch}>
            <Select label={t('vms.host')} value={batch.host_id} required error={errors.host_id}
              onChange={(e) => {
                const hid = e.target.value
                setBatch({ ...batch, host_id: hid, image: '', manual: '' })
                if (hid) loadImages(parseInt(hid, 10))
              }}>
              <option value="">{t('vms.selectHost')}</option>
              {hosts.map((h) => (
                <option key={h.id} value={h.id}>{h.name} ({h.ip})</option>
              ))}
            </Select>

            <label className="field">
              <span className="field-label">{t('vms.names')}</span>
              <textarea className={'input' + (errors.names ? ' input-error' : '')} rows="4"
                placeholder={t('vms.namesHint')} value={batch.names}
                onChange={(e) => setBatch({ ...batch, names: e.target.value })} />
              {errors.names && <span className="field-error">{errors.names}</span>}
            </label>

            <div className="grid-3">
              <Select label={t('vms.vcpu')} value={batch.cpu} onChange={(e) => setBatch({ ...batch, cpu: e.target.value })}>
                {CONSTANTS.cpus.map((c) => <option key={c} value={c}>{c}</option>)}
              </Select>
              <Select label={t('vms.mem')} value={batch.memory_gb} onChange={(e) => setBatch({ ...batch, memory_gb: e.target.value })}>
                {CONSTANTS.memories.map((m) => <option key={m} value={m}>{m} GB</option>)}
              </Select>
              <Select label={t('vms.disk')} value={batch.disk_gb} onChange={(e) => setBatch({ ...batch, disk_gb: e.target.value })}>
                {CONSTANTS.disks.map((d) => <option key={d} value={d}>{d} GB</option>)}
              </Select>
            </div>

            <label className="field">
              <span className="field-label">
                {t('vms.imagesFromMinio')}
                <button type="button" className="btn btn-ghost btn-sm" style={{ marginLeft: 8 }}
                  onClick={() => (batch.host_id ? loadImages(parseInt(batch.host_id, 10)) : loadImages())}>
                  {t('vms.refreshImages')}
                </button>
              </span>
              <select className={'input' + (errors.image ? ' input-error' : '')} value={batch.image}
                onChange={(e) => setBatch({ ...batch, image: e.target.value })} disabled={batch.imagesLoading}>
                <option value="">{batch.imagesLoading ? t('vms.imagesLoading') : t('vms.selectImage')}</option>
                {batch.images.map((img) => (
                  <option key={img.name} value={img.name}>
                    {img.name} ({(img.size / 1073741824).toFixed(1)} GB)
                  </option>
                ))}
              </select>
              {errors.image && <span className="field-error">{errors.image}</span>}
            </label>

            {(batch.imagesError || !batch.images.length) && (
              <Field label={t('vms.manualImage')} placeholder="ubuntu-22.04-cloud.qcow2" value={batch.manual}
                onChange={(e) => setBatch({ ...batch, manual: e.target.value })} />
            )}

            <div className="modal-note">{t('vms.defaultSpec')} · {t('vms.loginHint')}</div>

            <div className="modal-actions">
              <button type="button" className="btn btn-ghost" onClick={() => setShowCreate(false)}>{t('common.cancel')}</button>
              <button type="submit" className="btn btn-primary" disabled={busy}>{busy ? t('common.loading') : t('vms.create')}</button>
            </div>
          </form>
        </Modal>
      )}

      {/* 批量创建结果(含 IP) */}
      {result && (
        <Modal title={t('vms.batchResultTitle')} onClose={() => setResult(null)} width="540px">
          <div className="wizard-summary">
            {result.names.map((name) => {
              const v = vms.find((x) => x.name === name)
              const st = v ? STATUS_MAP[v.status] || { key: v.status, cls: 'badge-muted' } : { key: 'status.pending', cls: 'badge-muted' }
              return (
                <div key={name} className="wizard-summary-row">
                  <span className="wizard-summary-label">{name}</span>
                  <span className={'badge ' + st.cls}>{t(st.key)}</span>
                  <span className="td-mono">{v ? (v.ip || '-') : '-'}</span>
                </div>
              )
            })}
          </div>
          <p className="modal-text">{resultAllDone ? t('vms.batchDone') : t('vms.batchPolling')}</p>
          <div className="modal-actions">
            <button className="btn btn-ghost" onClick={() => setResult(null)}>{t('common.close')}</button>
            <button className="btn btn-primary" onClick={() => navigate('/vm-tasks')}>{t('vms.batchWatch')}</button>
          </div>
        </Modal>
      )}

      {deleting && (
        <Modal title={t('vms.deleteTitle')} onClose={() => setDeleting(null)}>
          <p className="modal-text">{t('vms.deleteMsg', { name: deleting.name })}</p>
          <div className="modal-actions">
            <button className="btn btn-ghost" onClick={() => setDeleting(null)}>{t('common.cancel')}</button>
            <button className="btn btn-danger" onClick={confirmDelete}>{t('common.confirm')}</button>
          </div>
        </Modal>
      )}
    </div>
  )
}