import { createContext, useContext, useEffect, useMemo, useState } from 'react'
import { authApi } from '../api/client'

const AuthContext = createContext(null)

const TOKEN_KEY = 'userhub_token'
const USER_KEY = 'userhub_user'

export function AuthProvider({ children }) {
  const [token, setToken] = useState(() => localStorage.getItem(TOKEN_KEY))
  const [user, setUser] = useState(() => {
    try {
      return JSON.parse(localStorage.getItem(USER_KEY) || 'null')
    } catch {
      return null
    }
  })
  const [loading, setLoading] = useState(Boolean(token))

  // 页面刷新后校验令牌有效性
  useEffect(() => {
    if (!token) {
      setLoading(false)
      return
    }
    authApi
      .me(token)
      .then(setUser)
      .catch(() => logout())
      .finally(() => setLoading(false))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [token])

  function login(payload) {
    return authApi.login(payload).then((res) => {
      setToken(res.access_token)
      setUser(res.user)
      localStorage.setItem(TOKEN_KEY, res.access_token)
      localStorage.setItem(USER_KEY, JSON.stringify(res.user))
      return res.user
    })
  }

  function logout() {
    setToken(null)
    setUser(null)
    localStorage.removeItem(TOKEN_KEY)
    localStorage.removeItem(USER_KEY)
  }

  const value = useMemo(() => ({ user, token, loading, login, logout }), [user, token, loading])

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useAuth() {
  return useContext(AuthContext)
}
