import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

const backend = process.env.LOOPLAND_API ?? 'http://localhost:8080';

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      '/admin/v1': { target: backend, changeOrigin: true },
      '/v1': { target: backend, changeOrigin: true },
    },
  },
  build: {
    chunkSizeWarningLimit: 2000,
    rollupOptions: {
      output: {
        manualChunks: {
          react: ['react', 'react-dom', 'react-router-dom'],
          antd: ['antd', '@ant-design/icons'],
          echarts: ['echarts', 'echarts-for-react'],
        },
      },
    },
  },
});
