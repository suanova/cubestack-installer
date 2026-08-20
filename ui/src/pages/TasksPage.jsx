import { useCallback, useEffect, useRef, useState } from 'react'
import { downloadTaskLog, taskApi } from '../api/client'
import { useToast } from '../components/Toast'
import { useAuth } from '../context/AuthContext'
import { useI18n } from '../i18n'

const TYPE_MAP = {
  vm_create: { key: 'tasks.typeVm', cls: 'badge-cyan' },
  cluster_install: { key: 'tasks.typeCluster', cls: 'badge-violet' },
  cluster_scale: { key: 'tasks.typeScale', cls: 'badge-warning' },
}

const STATUS_MAP = {
  pending: { key: 'status.waiting', cls: 'badge-muted' },
  running: { key: 'status.running', cls: 'badge-info' },
  success: { key: 'status.success', cls: 'badge-success' },
  failed: { key: 'status.failed', cls: 'badge-failed' },
}

function formatDate(iso) {
  if (!iso) return '-'
  return new Date(iso).toLocaleString('zh-CN', { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' })
}

export default function TasksPage({ typeFilter, titleKey, descKey }) {
  const toast = useToast()
  const { token } = useAuth()
  const { t } = useI18n()
  const [tasks, setTasks] = useState([])
  const [loading, setLoading] = useState(true)
  const [selected, setSelected] = useState(null)
  const [logText, setLogText] = useState('')
  const logRef = useRef(null)

  const load = useCallback(() => {
    taskApi
      .list(token)
      .then((list) => {
        setTasks(list)
        setLoading(false)
        if (selected) {
          taskApi.get(selected.id, token).then((tk) => {
            setSelected(tk)
            setLogText(tk.log_text || '')
          }).catch(() => {})
        }
      })
      .catch(() => {})
  }, [token, selected])

  useEffect(() => {
    load()
    const iv = setInterval(load, 2000)
    return () => clearInterval(iv)
  }, [load])

  useEffect(() => {
    if (logRef.current) logRef.current.scrollTop = logRef.current.scrollHeight
  }, [logText])

  function openLog(task) {
    taskApi
      .get(task.id, token)
      .then((tk) => {
        setSelected(tk)
        setLogText(tk.log_text || t('tasks.noLog'))
      })
      .catch(() => {})
  }

  function deleteLog(tk) {
    if (!window.confirm(t('tasks.deleteLogConfirm', { id: tk.id }))) return
    taskApi
      .clearLog(tk.id, token)
      .then(() => {
        toast(t('tasks.logDeleted'))
        if (selected?.id === tk.id) {
          setSelected((s) => (s ? { ...s, log_text: '' } : s))
          setLogText(t('tasks.noLog'))
        }
        load()
      })
      .catch((err) => toast(err.message, 'error'))
  }

  const visibleTasks = typeFilter
    ? tasks.filter((tk) => (Array.isArray(typeFilter) ? typeFilter.includes(tk.type) : tk.type === typeFilter))
    : tasks
  const hasRunning = visibleTasks.some((tk) => tk.status === 'running' || tk.status === 'pending')

  return (
    <div>
      <div className="page-head">
        <div>
          <h1 className="page-title">{t(titleKey || 'tasks.title')}</h1>
          <p className="page-desc">
            {t(descKey || 'tasks.desc')}
            {hasRunning && ' · ' + t('tasks.autoRefresh')}
          </p>
        </div>
        <span className={'count-chip' + (hasRunning ? ' pulse' : '')}>
          {hasRunning ? t('tasks.running') : t('tasks.history', { n: visibleTasks.length })}
        </span>
      </div>

      {loading ? (
        <div className="page-loader"><div className="spinner" /></div>
      ) : (
        <div className="card">
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>#</th>
                  <th>{t('tasks.type')}</th>
                  <th>{t('tasks.target')}</th>
                  <th>{t('common.status')}</th>
                  <th>{t('tasks.progress')}</th>
                  <th>{t('tasks.createdAt')}</th>
                  <th className="th-actions">{t('tasks.log') || t('common.log')}</th>
                </tr>
              </thead>
              <tbody>
                {visibleTasks.map((tk) => {
                  const ty = TYPE_MAP[tk.type] || { key: tk.type, cls: 'badge-muted' }
                  const st = STATUS_MAP[tk.status] || { key: tk.status, cls: 'badge-muted' }
                  return (
                    <tr key={tk.id} className={selected?.id === tk.id ? 'row-selected' : ''}>
                      <td className="td-mono">#{tk.id}</td>
                      <td><span className={'badge ' + ty.cls}>{t(ty.key)}</span></td>
                      <td className="cell-name">{tk.target_name}</td>
                      <td><span className={'badge ' + st.cls}>{t(st.key)}</span></td>
                      <td>
                        <div className="progress">
                          <div className={'progress-bar progress-' + tk.status} style={{ width: tk.progress + '%' }} />
                        </div>
                        <span className="progress-num">{tk.progress}%</span>
                      </td>
                      <td className="td-mono td-muted">
                        {formatDate(tk.created_at)}
                        <div>{formatDate(tk.finished_at)}</div>
                      </td>
                      <td>
                        <div className="td-actions">
                          <button className="btn btn-ghost btn-sm" onClick={() => openLog(tk)}>
                            {selected?.id === tk.id ? t('tasks.viewing') : t('tasks.viewLog')}
                          </button>
                          <button className="btn btn-ghost btn-sm" title={t('tasks.downloadLog')}
                            onClick={() => downloadTaskLog(tk, token).catch(() => {})}>
                            {t('common.download')}
                          </button>
                          <button className="btn btn-danger btn-sm" title={t('tasks.deleteLog')}
                            onClick={() => deleteLog(tk)}>
                            {t('tasks.deleteLog')}
                          </button>
                        </div>
                      </td>
                    </tr>
                  )
                })}
                {visibleTasks.length === 0 && (
                  <tr><td colSpan="7" className="td-empty">{t('tasks.empty')}</td></tr>
                )}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {selected && (
        <div className="card log-card">
          <div className="log-head">
            <span>
              {t('tasks.taskLabel', { id: selected.id, name: selected.target_name })}{' '}
              <span className={'badge ' + (STATUS_MAP[selected.status] || {}).cls}>
                {t((STATUS_MAP[selected.status] || { key: selected.status }).key)}
              </span>
            </span>
            <div className="td-actions">
              <button className="btn btn-ghost btn-sm" onClick={() => downloadTaskLog(selected, token).catch(() => {})}>
                {t('tasks.downloadLog')}
              </button>
              <button className="btn btn-ghost btn-sm" onClick={() => setSelected(null)}>{t('tasks.collapse')}</button>
            </div>
          </div>
          <pre className="log-viewer" ref={logRef}>{logText}</pre>
        </div>
      )}
    </div>
  )
}