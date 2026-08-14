import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// /api 请求代理到 FastAPI 后端,避免开发期跨域问题
export default defineConfig({
  plugins: [react()],
  server: {
    host: '0.0.0.0',
    port: 5173,
    proxy: {
      '/api': {
        target: 'http://127.0.0.1:8000',
        changeOrigin: true,
      },
    },
  },
})
