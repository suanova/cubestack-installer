import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { clusterApi, hostApi, taskApi, vmApi } from '../api/client'
import { useToast } from '../components/Toast'
import { useAuth } from '../context/AuthContext'
import { useI18n } from '../i18n'

function formatDate(iso) {
  if (!iso) return '-'
  return new Date(iso).toLocaleString('zh-CN', { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' })
}

const TASK_STATUS = {
  pending: { key: 'status.waiting', cls: 'badge-muted' },
  running: { key: 'status.running', cls: 'badge-info' },
  success: { key: 'status.success', cls: 'badge-success' },
  failed: { key: 'status.failed', cls: 'badge-failed' },
}

export default function DashboardPage() {
  const { user, token } = useAuth()
  const { t } = useI18n()
  const toast = useToast()
  const [stats, setStats] = useState({ hosts: 0, hostsOnline: 0, vms: 0, vmsRunning: 0, clusters: 0, clustersReady: 0, tasksRunning: 0 })
  const [tasks, setTasks] = useState([])

  useEffect(() => {
    Promise.allSettled([hostApi.list(token), vmApi.list(token), clusterApi.list(token), taskApi.list(token)])
      .then(([h, v, c, tsk]) => {
        const hosts = h.status === 'fulfilled' ? h.value : []
        const vms = v.status === 'fulfilled' ? v.value : []
        const clusters = c.status === 'fulfilled' ? c.value : []
        const tasksList = tsk.status === 'fulfilled' ? tsk.value : []
        setTasks(tasksList.slice(0, 5))
        setStats({
          hosts: hosts.length,
          hostsOnline: hosts.filter((x) => x.status === 'online').length,
          vms: vms.length,
          vmsRunning: vms.filter((x) => x.status === 'running').length,
          clusters: clusters.length,
          clustersReady: clusters.filter((x) => x.status === 'ready').length,
          tasksRunning: tasksList.filter((x) => x.status === 'running' || x.status === 'pending').length,
        })
      })
      .catch((err) => toast(err.message, 'error'))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [token])

  const items = [
    { label: t('dash.statHosts'), value: stats.hosts, sub: t('dash.hostsOnline', { n: stats.hostsOnline }), icon: '▦', cls: 'stat-icon-violet' },
    { label: t('dash.statVms'), value: stats.vms, sub: t('dash.vmsRunning', { n: stats.vmsRunning }), icon: '▣', cls: 'stat-icon-green' },
    { label: t('dash.statClusters'), value: stats.clusters, sub: t('dash.clustersReady', { n: stats.clustersReady }), icon: '☸', cls: 'stat-icon-cyan' },
    { label: t('dash.statTasks'), value: stats.tasksRunning, sub: t('dash.tasksRunning'), icon: '▶', cls: 'stat-icon-pink' },
  ]

  const flows = [
    { n: '1', title: t('dash.flow1t'), desc: t('dash.flow1d') },
    { n: '2', title: t('dash.flow2t'), desc: t('dash.flow2d') },
    { n: '3', title: t('dash.flow3t'), desc: t('dash.flow3d') },
    { n: '4', title: t('dash.flow4t'), desc: t('dash.flow4d') },
  ]

  return (
    <div>
      <section className="hero">
        <div className="hero-content">
          <span className="hero-badge">{t('dash.badge')}</span>
          <h1 className="hero-title">{t('dash.welcome', { name: user?.full_name || user?.username })}</h1>
          <p className="hero-sub">{t('dash.heroDesc')}</p>
          <div className="hero-actions">
            <Link to="/vms" className="btn btn-light">{t('dash.createVm')}</Link>
            <Link to="/clusters" className="btn btn-light-ghost">{t('dash.createCluster')}</Link>
          </div>
        </div>
        <div className="hero-avatar">☸</div>
      </section>

      <section className="stats-grid">
        {items.map((it) => (
          <div className="stat-card" key={it.label}>
            <span className={'stat-icon ' + it.cls}>{it.icon}</span>
            <div>
              <div className="stat-label">{it.label}</div>
              <div className="stat-value">{it.value}</div>
              <div className="stat-sub">{it.sub}</div>
            </div>
          </div>
        ))}
      </section>

      <div className="dash-columns">
        <section className="card">
          <div className="card-head">
            <h2 className="card-title">{t('dash.recentTasks')}</h2>
            <Link to="/tasks" className="link-more">{t('dash.allTasks')}</Link>
          </div>
          {tasks.length === 0 ? (
            <p className="card-empty">{t('dash.noTasks')}</p>
          ) : (
            <ul className="task-mini-list">
              {tasks.map((tk) => {
                const st = TASK_STATUS[tk.status] || { key: tk.status, cls: 'badge-muted' }
                return (
                  <li key={tk.id}>
                    <span className="td-mono">#{tk.id}</span>
                    <span className="cell-name">{tk.target_name}</span>
                    <span className="td-muted">{formatDate(tk.created_at)}</span>
                    <span className={'badge ' + st.cls}>{t(st.key)}</span>
                    <span className="progress-mini">
                      <span className={'progress-bar progress-' + tk.status} style={{ width: tk.progress + '%' }} />
                    </span>
                  </li>
                )
              })}
            </ul>
          )}
        </section>

        <section className="card">
          <div className="card-head">
            <h2 className="card-title">{t('dash.flowTitle')}</h2>
          </div>
          <ol className="flow-list">
            {flows.map((f) => (
              <li key={f.n}>
                <span className="flow-num">{f.n}</span>
                <div><strong>{f.title}</strong><p>{f.desc}</p></div>
              </li>
            ))}
          </ol>
        </section>
      </div>
    </div>
  )
}
