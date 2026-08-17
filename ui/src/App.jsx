import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import Layout from './components/Layout'
import ProtectedRoute from './components/ProtectedRoute'
import { ToastProvider } from './components/Toast'
import { AuthProvider } from './context/AuthContext'
import { I18nProvider } from './i18n'
import ApiDocsPage from './pages/ApiDocsPage'
import ClustersPage from './pages/ClustersPage'
import DashboardPage from './pages/DashboardPage'
import HostsPage from './pages/HostsPage'
import LoginPage from './pages/LoginPage'
import RegisterPage from './pages/RegisterPage'
import TasksPage from './pages/TasksPage'
import UsersPage from './pages/UsersPage'
import VmsPage from './pages/VmsPage'
import { ThemeProvider } from './theme'

export default function App() {
  return (
    <ThemeProvider>
      <I18nProvider>
        <BrowserRouter>
          <AuthProvider>
            <ToastProvider>
              <Routes>
                <Route path="/login" element={<LoginPage />} />
                <Route path="/register" element={<RegisterPage />} />
                <Route
                  element={
                    <ProtectedRoute>
                      <Layout />
                    </ProtectedRoute>
                  }
                >
                  <Route path="/" element={<DashboardPage />} />
                  <Route path="/hosts" element={<HostsPage />} />
                  <Route path="/vms" element={<VmsPage />} />
                  <Route path="/clusters" element={<ClustersPage />} />
                  <Route path="/tasks" element={<TasksPage typeFilter="cluster_install" titleKey="tasks.title" descKey="tasks.desc" />} />
                  <Route path="/vm-tasks" element={<TasksPage typeFilter="vm_create" titleKey="vmtasks.title" descKey="vmtasks.desc" />} />
                  <Route
                    path="/users"
                    element={
                      <ProtectedRoute admin>
                        <UsersPage />
                      </ProtectedRoute>
                    }
                  />
                  <Route path="/apidocs" element={<ApiDocsPage />} />
                </Route>
                <Route path="*" element={<Navigate to="/" replace />} />
              </Routes>
            </ToastProvider>
          </AuthProvider>
        </BrowserRouter>
      </I18nProvider>
    </ThemeProvider>
  )
}