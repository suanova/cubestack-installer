import { Navigate } from 'react-router-dom'
import { useAuth } from '../context/AuthContext'

// 路由守卫:未登录跳转登录页;admin=true 时校验管理员角色
export default function ProtectedRoute({ children, admin = false }) {
  const { user, loading } = useAuth()

  if (loading) {
    return (
      <div className="page-loader">
        <div className="spinner" />
      </div>
    )
  }
  if (!user) return <Navigate to="/login" replace />
  if (admin && user.role !== 'admin') return <Navigate to="/" replace />
  return children
}
