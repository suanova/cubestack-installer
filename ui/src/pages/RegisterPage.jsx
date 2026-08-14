import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import AuthLayout from '../components/AuthLayout'
import Field from '../components/Field'
import { useToast } from '../components/Toast'
import { useAuth } from '../context/AuthContext'
import { useI18n } from '../i18n'

export default function RegisterPage() {
  const { login } = useAuth()
  const toast = useToast()
  const { t } = useI18n()
  const navigate = useNavigate()

  const [form, setForm] = useState({
    username: '',
    email: '',
    full_name: '',
    password: '',
    confirm: '',
  })
  const [errors, setErrors] = useState({})
  const [serverError, setServerError] = useState('')
  const [busy, setBusy] = useState(false)

  function validate() {
    const e = {}
    if (form.username.trim().length < 3) e.username = t('auth.errUsername')
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(form.email)) e.email = t('auth.errEmail')
    if (form.password.length < 6) e.password = t('auth.errPwd')
    if (form.confirm !== form.password) e.confirm = t('auth.errConfirm')
    setErrors(e)
    return Object.keys(e).length === 0
  }

  function submit(e) {
    e.preventDefault()
    setServerError('')
    if (!validate()) return
    setBusy(true)

    const payload = {
      username: form.username.trim(),
      email: form.email.trim(),
      password: form.password,
      full_name: form.full_name.trim() || null,
    }

    fetch('/api/auth/register', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    })
      .then(async (res) => {
        const data = await res.json().catch(() => ({}))
        if (!res.ok) throw new Error(data.detail || 'Register failed')
        return login({ account: form.username, password: form.password })
      })
      .then(() => {
        toast(t('auth.registerOk'))
        navigate('/', { replace: true })
      })
      .catch((err) => setServerError(err.message))
      .finally(() => setBusy(false))
  }

  return (
    <AuthLayout title={t('auth.registerTitle')} subtitle={t('auth.registerSubtitle')}>
      <form onSubmit={submit} noValidate>
        {serverError && <div className="alert">{serverError}</div>}
        <Field
          label={t('auth.username')}
          type="text"
          placeholder={t('auth.usernameHint')}
          value={form.username}
          error={errors.username}
          onChange={(e) => setForm({ ...form, username: e.target.value })}
          autoComplete="username"
        />
        <Field
          label={t('auth.email')}
          type="email"
          placeholder="you@example.com"
          value={form.email}
          error={errors.email}
          onChange={(e) => setForm({ ...form, email: e.target.value })}
          autoComplete="email"
        />
        <Field
          label={t('auth.fullName')}
          type="text"
          value={form.full_name}
          onChange={(e) => setForm({ ...form, full_name: e.target.value })}
        />
        <Field
          label={t('auth.password')}
          type="password"
          placeholder={t('auth.pwdHint')}
          value={form.password}
          error={errors.password}
          onChange={(e) => setForm({ ...form, password: e.target.value })}
          autoComplete="new-password"
        />
        <Field
          label={t('auth.confirmPassword')}
          type="password"
          value={form.confirm}
          error={errors.confirm}
          onChange={(e) => setForm({ ...form, confirm: e.target.value })}
          autoComplete="new-password"
        />
        <button className="btn btn-primary btn-block" type="submit" disabled={busy}>
          {busy ? t('auth.registering') : t('auth.register')}
        </button>
      </form>

      <p className="auth-switch">
        {t('auth.haveAccount')}<Link to="/login">{t('auth.loginDirect')}</Link>
      </p>
    </AuthLayout>
  )
}
