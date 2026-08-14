import { useCallback, useEffect, useRef, useState } from 'react'
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

const emptyForm = {
  name: '', host_id: '', cpu: '4', memory_gb: '8', disk_gb: '40',
  image: CONSTANTS.images[0], provider: 'libvirt', namespace: '',
  auto_ip: true, ip: '',
}

export default function VmsPage() {
  const { token } = useAuth()
  const { t } = useI18n()
  const toast = useToast()

  const [vms, setVms] = useState([])
  const [hosts, setHosts] = useState([])
  const [providers, setProviders] = useState([])
  const [loading, setLoading] = useState(true)
  const [showCreate, setShowCreate] = useState(false)
  const [form, setForm] = useState(emptyForm)
  const [busy, setBusy] = useState(false)
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

  function openCreate() {
    setForm(emptyForm)
    setShowCreate(true)
    fetch('/api/hosts', { headers: { Authorization: 'Bearer ' + token } })
      .then((r) => r.json())
      .then(setHosts)
      .catch(() => {})
  }

  function submitCreate(e) {
    e.preventDefault()
    if (!form.host_id) {
      toast(t('vms.selectHost'), 'error')
      return
    }
    setBusy(true)
    vmApi
      .create(
        {
          name: form.name.trim(),
          host_id: parseInt(form.host_id, 10),
          cpu: parseInt(form.cpu, 10),
          memory_gb: parseInt(form.memory_gb, 10),
          disk_gb: parseInt(form.disk_gb, 10),
          image: form.image,
          provider: form.provider,
          namespace: form.provider === 'kubevirt' ? form.namespace.trim() || null : null,
          auto_ip: form.auto_ip,
          ip: form.auto_ip ? null : form.ip.trim() || null,
        },
        token,
      )
      .then((res) => {
        setShowCreate(false)
        toast(t('vms.created', { name: res.vm.name }))
        setTimeout(load, 800)
      })
      .catch((err) => toast(err.message, 'error'))
      .finally(() => setBusy(false))
  }

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

      {showCreate && (
        <Modal title={t('vms.createTitle')} onClose={() => setShowCreate(false)} width="560px">
          <form onSubmit={submitCreate}>
            <Field label={t('common.name')} placeholder="k8s-node-4" value={form.name} required
              onChange={(e) => setForm({ ...form, name: e.target.value })} />
            <Select label={t('vms.provider')} value={form.provider}
              onChange={(e) => setForm({ ...form, provider: e.target.value })}>
              {CONSTANTS.vmProviders.map((p) => (
                <option key={p.key} value={p.key}>{t(p.labelKey)}</option>
              ))}
            </Select>
            {form.provider === 'kubevirt' && (
              <Field label={t('vms.namespace')} placeholder={t('vms.namespaceHint')} value={form.namespace}
                onChange={(e) => setForm({ ...form, namespace: e.target.value })} />
            )}
            <Select label={t('vms.host')} value={form.host_id} required
              onChange={(e) => setForm({ ...form, host_id: e.target.value })}>
              <option value="">{t('vms.selectHost')}</option>
              {hosts.map((h) => (
                <option key={h.id} value={h.id}>{h.name} ({h.ip})</option>
              ))}
            </Select>
            <div className="grid-3">
              <Select label={t('vms.vcpu')} value={form.cpu} onChange={(e) => setForm({ ...form, cpu: e.target.value })}>
                {CONSTANTS.cpus.map((c) => <option key={c} value={c}>{c}</option>)}
              </Select>
              <Select label={t('vms.mem')} value={form.memory_gb} onChange={(e) => setForm({ ...form, memory_gb: e.target.value })}>
                {CONSTANTS.memories.map((m) => <option key={m} value={m}>{m} GB</option>)}
              </Select>
              <Select label={t('vms.disk')} value={form.disk_gb} onChange={(e) => setForm({ ...form, disk_gb: e.target.value })}>
                {CONSTANTS.disks.map((d) => <option key={d} value={d}>{d} GB</option>)}
              </Select>
            </div>
            <Select label={t('vms.image')} value={form.image} onChange={(e) => setForm({ ...form, image: e.target.value })}>
              {CONSTANTS.images.map((img) => <option key={img} value={img}>{img}</option>)}
            </Select>
            <label className="switch-row">
              <input type="checkbox" checked={form.auto_ip}
                onChange={(e) => setForm({ ...form, auto_ip: e.target.checked })} />
              <span>{t('vms.autoIp')}</span>
            </label>
            {!form.auto_ip && (
              <Field label={t('vms.customIp')} placeholder="192.168.10.x" value={form.ip}
                onChange={(e) => setForm({ ...form, ip: e.target.value })} />
            )}
            <div className="modal-actions">
              <button type="button" className="btn btn-ghost" onClick={() => setShowCreate(false)}>{t('common.cancel')}</button>
              <button type="submit" className="btn btn-primary" disabled={busy}>{busy ? t('common.loading') : t('vms.create')}</button>
            </div>
          </form>
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
