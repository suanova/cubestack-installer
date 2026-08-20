import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import AuthLayout from '../components/AuthLayout'
import Field from '../components/Field'
import { useToast } from '../components/Toast'
import { useAuth } from '../context/AuthContext'
import { useI18n } from '../i18n'

export default function LoginPage() {
  const { login } = useAuth()
  const toast = useToast()
  const { t } = useI18n()
  const navigate = useNavigate()

  const [form, setForm] = useState({ account: '', password: '' })
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const [showPwd, setShowPwd] = useState(false)

  function submit(e) {
    e.preventDefault()
    setError('')
    setBusy(true)
    login(form)
      .then(() => {
        toast(t('auth.loginOk'))
        navigate('/', { replace: true })
      })
      .catch((err) => setError(err.message))
      .finally(() => setBusy(false))
  }

  return (
    <AuthLayout title={t('auth.loginTitle')} subtitle={t('auth.loginSubtitle')}>
      <form onSubmit={submit} noValidate>
        {error && <div className="alert">{error}</div>}
        <Field
          label={t('auth.account')}
          type="text"
          placeholder={t('auth.account')}
          value={form.account}
          onChange={(e) => setForm({ ...form, account: e.target.value })}
          autoComplete="username"
          required
        />
        <Field
          label={t('auth.password')}
          type={showPwd ? 'text' : 'password'}
          placeholder={t('auth.password')}
          value={form.password}
          onChange={(e) => setForm({ ...form, password: e.target.value })}
          autoComplete="current-password"
          required
          action={
            <button type="button" className="field-toggle"
              onClick={() => setShowPwd(!showPwd)}
              title={showPwd ? t('auth.hidePwd') : t('auth.showPwd')}
              aria-label={showPwd ? t('auth.hidePwd') : t('auth.showPwd')}>
              {showPwd ? (
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19m-6.72-1.07a3 3 0 1 1-4.24-4.24" />
                  <line x1="1" y1="1" x2="23" y2="23" />
                </svg>
              ) : (
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z" />
                  <circle cx="12" cy="12" r="3" />
                </svg>
              )}
            </button>
          }
        />
        <button className="btn btn-primary btn-block" type="submit" disabled={busy}>
          {busy ? t('auth.loggingIn') : t('auth.login')}
        </button>
      </form>

      <p className="auth-switch">
        {t('auth.noAccount')}<Link to="/register">{t('auth.registerNow')}</Link>
      </p>


    </AuthLayout>
  )
}
