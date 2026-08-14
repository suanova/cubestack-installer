import { NavLink, useNavigate } from 'react-router-dom'
import { useState } from 'react'
import { useAuth } from '../context/AuthContext'
import { useI18n } from '../i18n'

export default function Sidebar({ open, onClose }) {
  const { user, logout } = useAuth()
  const { t } = useI18n()
  const navigate = useNavigate()
  const [openVm, setOpenVm] = useState(true)
  const [openK8s, setOpenK8s] = useState(true)

  function handleLogout() {
    logout()
    navigate('/login')
  }

  return (
    <>
      {open && <div className="sidebar-mask" onClick={onClose} />}
      <aside className={'sidebar' + (open ? ' open' : '')}>
        <div className="sidebar-brand">
          <span className="brand-mark brand-mark-lg">CSI</span>
          <div>
            <div className="brand-name">CubeStackInstaller</div>
            <div className="brand-sub">{t('nav.subBrand')}</div>
          </div>
        </div>

        <nav className="sidebar-nav">
          <div className="tree">
            <button
              className={'tree-root' + (openVm ? ' expanded' : '')}
              onClick={() => setOpenVm(!openVm)}
            >
              <span className="tree-icon tree-icon-cyan">▦</span>
              <span className="tree-root-label">{t('nav.vmTree')}</span>
              <span className="tree-chevron">▾</span>
            </button>
            {openVm && (
              <div className="tree-children">
                <NavLink to="/hosts" className={({ isActive }) => 'tree-link' + (isActive ? ' active' : '')} onClick={onClose}>
                  {t('nav.hosts')}
                </NavLink>
                <NavLink to="/vms" className={({ isActive }) => 'tree-link' + (isActive ? ' active' : '')} onClick={onClose}>
                  {t('nav.vms')}
                </NavLink>
              </div>
            )}
          </div>

          <div className="tree">
            <button
              className={'tree-root' + (openK8s ? ' expanded' : '')}
              onClick={() => setOpenK8s(!openK8s)}
            >
              <span className="tree-icon tree-icon-violet">☸</span>
              <span className="tree-root-label">{t('nav.k8sTree')}</span>
              <span className="tree-chevron">▾</span>
            </button>
            {openK8s && (
              <div className="tree-children">
                <NavLink to="/clusters" className={({ isActive }) => 'tree-link' + (isActive ? ' active' : '')} onClick={onClose}>
                  {t('nav.clusters')}
                </NavLink>
                <NavLink to="/tasks" className={({ isActive }) => 'tree-link' + (isActive ? ' active' : '')} onClick={onClose}>
                  {t('nav.tasks')}
                </NavLink>
              </div>
            )}
          </div>

          <div className="tree tree-tools">
            <NavLink to="/apidocs" className={({ isActive }) => 'tree-link tree-tool' + (isActive ? ' active' : '')} onClick={onClose}>
              <span className="tree-icon tree-icon-slate">⌘</span> {t('nav.apiDocs')}
            </NavLink>
            {user?.role === 'admin' && (
              <NavLink to="/users" className={({ isActive }) => 'tree-link tree-tool' + (isActive ? ' active' : '')} onClick={onClose}>
                <span className="tree-icon tree-icon-slate">⚙</span> {t('nav.users')}
              </NavLink>
            )}
          </div>
        </nav>

        <div className="sidebar-user">
          <span className="avatar">{user?.username?.slice(0, 1).toUpperCase()}</span>
          <div className="user-meta">
            <span className="user-name">{user?.full_name || user?.username}</span>
            <span className={'role-chip role-' + (user?.role === 'admin' ? 'admin' : 'user')}>
              {user?.role === 'admin' ? t('common.roleAdmin') : t('common.roleUser')}
            </span>
          </div>
          <button className="btn btn-ghost btn-sm" onClick={handleLogout}>
            {t('nav.logout')}
          </button>
        </div>
      </aside>
    </>
  )
}
