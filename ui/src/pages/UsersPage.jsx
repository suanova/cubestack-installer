import { useCallback, useEffect, useState } from 'react'
import { userApi } from '../api/client'
import Field, { Select } from '../components/Field'
import Modal from '../components/Modal'
import { useToast } from '../components/Toast'
import { useAuth } from '../context/AuthContext'
import { useI18n } from '../i18n'

function formatDate(iso) {
  if (!iso) return '-'
  return new Date(iso).toLocaleString('zh-CN', {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  })
}

export default function UsersPage() {
  const { user: me, token } = useAuth()
  const { t } = useI18n()
  const toast = useToast()

  const [users, setUsers] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [busyId, setBusyId] = useState(null)
  const [deleting, setDeleting] = useState(null)
  const [showAdd, setShowAdd] = useState(false)
  const [addBusy, setAddBusy] = useState(false)
  const [addForm, setAddForm] = useState({ username: '', email: '', password: '', full_name: '', role: 'user' })

  const load = useCallback(() => {
    setLoading(true)
    setError('')
    userApi
      .list(token)
      .then(setUsers)
      .catch((err) => setError(err.message))
      .finally(() => setLoading(false))
  }, [token])

  useEffect(() => {
    load()
  }, [load])

  function patchUser(id, payload) {
    setBusyId(id)
    return userApi
      .update(id, payload, token)
      .then((updated) => {
        setUsers((list) => list.map((u) => (u.id === updated.id ? updated : u)))
        toast(t('users.updated'))
      })
      .catch((err) => toast(err.message, 'error'))
      .finally(() => setBusyId(null))
  }

  function submitAdd(e) {
    e.preventDefault()
    setAddBusy(true)
    userApi
      .create(
        {
          username: addForm.username.trim(),
          email: addForm.email.trim(),
          password: addForm.password,
          full_name: addForm.full_name.trim() || null,
          role: addForm.role,
        },
        token
      )
      .then((created) => {
        toast(t('users.added', { username: created.username }))
        setShowAdd(false)
        setAddForm({ username: '', email: '', password: '', full_name: '', role: 'user' })
        load()
      })
      .catch((err) => toast(err.message, 'error'))
      .finally(() => setAddBusy(false))
  }

  function confirmDelete() {
    if (!deleting) return
    userApi
      .remove(deleting.id, token)
      .then(() => {
        setUsers((list) => list.filter((u) => u.id !== deleting.id))
        toast(t('users.deleted', { username: deleting.username }))
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
          <h1 className="page-title">{t('users.title')}</h1>
          <p className="page-desc">{t('users.desc')}</p>
        </div>
        <div className="page-actions">
          <button className="btn btn-primary" onClick={() => setShowAdd(true)}>{t('users.add')}</button>
          <span className="count-chip">{t('users.count', { n: users.length })}</span>
        </div>
      </div>

      {error && <div className="alert">{error}</div>}

      <div className="card">
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>{t('common.id')}</th>
                <th>{t('common.user')}</th>
                <th>{t('auth.email')}</th>
                <th>{t('common.role')}</th>
                <th>{t('common.status')}</th>
                <th>{t('users.regTime')}</th>
                <th className="th-actions">{t('common.actions')}</th>
              </tr>
            </thead>
            <tbody>
              {users.map((u) => {
                const isSelf = u.id === me.id
                const busy = busyId === u.id
                return (
                  <tr key={u.id}>
                    <td className="td-mono">#{u.id}</td>
                    <td>
                      <div className="user-cell">
                        <span className="avatar avatar-sm">{u.username.slice(0, 1).toUpperCase()}</span>
                        <div>
                          <div className="cell-name">
                            {u.full_name || u.username}
                            {isSelf && <span className="tag-self">{t('users.me')}</span>}
                          </div>
                          <div className="cell-sub">@{u.username}</div>
                        </div>
                      </div>
                    </td>
                    <td className="td-mono">{u.email}</td>
                    <td>
                      {isSelf ? (
                        <span className={'badge ' + (u.role === 'admin' ? 'badge-admin' : 'badge-user')}>
                          {u.role === 'admin' ? t('common.roleAdmin') : t('common.roleUser')}
                        </span>
                      ) : (
                        <select
                          className="select-sm"
                          value={u.role}
                          disabled={busy}
                          onChange={(e) => patchUser(u.id, { role: e.target.value })}
                        >
                          <option value="user">{t('common.roleUser')}</option>
                          <option value="admin">{t('common.roleAdmin')}</option>
                        </select>
                      )}
                    </td>
                    <td>
                      {isSelf ? (
                        <span className={'pill ' + (u.status === 'active' ? 'pill-active' : 'pill-disabled')}>
                          {u.status === 'pending' ? t('users.statusPending') : u.status === 'active' ? t('common.enabled') : t('common.disabled')}
                        </span>
                      ) : u.status === 'pending' ? (
                        <button className="pill-btn pill-btn-active" disabled={busy}
                          onClick={() => patchUser(u.id, { status: 'active' })}>
                          {t('users.approve')}
                        </button>
                      ) : (
                        <button
                          className={'pill-btn ' + (u.status === 'active' ? 'pill-btn-active' : 'pill-btn-disabled')}
                          disabled={busy}
                          onClick={() => patchUser(u.id, { status: u.status === 'active' ? 'disabled' : 'active' })}
                        >
                          {u.status === 'active' ? t('common.enabled') : t('common.disabled')}
                        </button>
                      )}
                    </td>
                    <td className="td-mono td-muted">{formatDate(u.created_at)}</td>
                    <td>
                      <div className="td-actions">
                        {isSelf ? (
                          <span className="td-hint">{t('users.current')}</span>
                        ) : (
                          <button className="btn btn-danger btn-sm" onClick={() => setDeleting(u)}>
                            {t('common.delete')}
                          </button>
                        )}
                      </div>
                    </td>
                  </tr>
                )
              })}
              {users.length === 0 && (
                <tr>
                  <td colSpan="7" className="td-empty">-</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>

      {deleting && (
        <Modal title={t('users.deleteTitle')} onClose={() => setDeleting(null)}>
          <p className="modal-text">
            {t('users.deleteMsg', { name: deleting.full_name || deleting.username, username: deleting.username })}
          </p>
          <div className="modal-actions">
            <button className="btn btn-ghost" onClick={() => setDeleting(null)}>{t('common.cancel')}</button>
            <button className="btn btn-danger" onClick={confirmDelete}>{t('common.confirm')}</button>
          </div>
        </Modal>
      )}

      {showAdd && (
        <Modal title={t('users.addTitle')} onClose={() => setShowAdd(false)} width="460px">
          <form onSubmit={submitAdd}>
            <Field label={t('auth.username')} type="text" required value={addForm.username}
              onChange={(e) => setAddForm({ ...addForm, username: e.target.value })} />
            <Field label={t('auth.email')} type="email" required value={addForm.email}
              onChange={(e) => setAddForm({ ...addForm, email: e.target.value })} />
            <Field label={t('auth.fullName')} type="text" value={addForm.full_name}
              onChange={(e) => setAddForm({ ...addForm, full_name: e.target.value })} />
            <Field label={t('auth.password')} type="password" required value={addForm.password}
              onChange={(e) => setAddForm({ ...addForm, password: e.target.value })} />
            <Select label={t('common.role')} value={addForm.role}
              onChange={(e) => setAddForm({ ...addForm, role: e.target.value })}>
              <option value="user">{t('common.roleUser')}</option>
              <option value="admin">{t('common.roleAdmin')}</option>
            </Select>
            <div className="modal-actions">
              <button type="button" className="btn btn-ghost" onClick={() => setShowAdd(false)}>{t('common.cancel')}</button>
              <button className="btn btn-primary" type="submit" disabled={addBusy}>
                {addBusy ? t('common.loading') : t('users.add')}
              </button>
            </div>
          </form>
        </Modal>
      )}
    </div>
  )
}
