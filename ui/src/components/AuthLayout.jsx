import { useI18n } from '../i18n'

export default function AuthLayout({ title, subtitle, children }) {
  const { t } = useI18n()
  return (
    <div className="auth-wrap">
      <div className="auth-blob blob-1" />
      <div className="auth-blob blob-2" />
      <div className="auth-blob blob-3" />
      <div className="auth-card">
        <div className="auth-brand">
          <span className="brand-mark brand-mark-lg">CSI</span>
          <span className="brand-name brand-name-lg">CubeStackInstaller</span>
        </div>
        <h1 className="auth-title">{title}</h1>
        <p className="auth-subtitle">{subtitle}</p>
        {children}
      </div>
      <p className="auth-foot">CubeStackInstaller · FastAPI + React</p>
    </div>
  )
}
