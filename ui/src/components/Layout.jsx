import { Outlet } from 'react-router-dom'
import { useState } from 'react'
import { useI18n } from '../i18n'
import Sidebar from './Sidebar'
import { useTheme } from '../theme'

export default function Layout() {
  const [sidebarOpen, setSidebarOpen] = useState(false)
  const { theme, toggle } = useTheme()
  const { t, lang, setLang } = useI18n()

  return (
    <div className="app-shell">
      <Sidebar open={sidebarOpen} onClose={() => setSidebarOpen(false)} />
      <div className="app-main">
        <header className="topbar">
          <button className="hamburger" onClick={() => setSidebarOpen(true)} aria-label="menu">
            ☰
          </button>
          <span className="topbar-tagline">{t('nav.tagline')}</span>
          <div className="topbar-tools">
            <button className="icon-btn" onClick={() => setLang(lang === 'zh' ? 'en' : 'zh')} title="切换语言 / Language">
              {lang === 'zh' ? 'EN' : '中'}
            </button>
            <button className="icon-btn" onClick={toggle} title="切换主题 / Theme">
              {theme === 'dark' ? '☀' : '☾'}
            </button>
          </div>
        </header>
        <main className="page">
          <Outlet />
        </main>
        <footer className="footer">CubeStackInstaller © 2026 iSuanova</footer>
      </div>
    </div>
  )
}
