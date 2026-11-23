import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineConfig, type Plugin, type ProxyOptions } from 'vite';
import react from '@vitejs/plugin-react';
import { browserConfig, loadConfig, type LoadedConfig } from './loadConfig';

// Every host / port / API prefix / key comes from config.yaml (see the comments there and README「配置」).
const root = path.dirname(fileURLToPath(import.meta.url));

const escapeHtml = (s: string) => s.replace(/[&<>"]/g, (c) => `&#${c.charCodeAt(0)};`);

/** Sets <title>, logs which files were merged, and restarts the dev server when a config file changes. */
function looplandConfig({ config: c, files, watch }: LoadedConfig): Plugin {
  return {
    name: 'loopland-config',
    transformIndexHtml: (html) => html.replace(/<title>[\s\S]*?<\/title>/, `<title>${escapeHtml(c.app.title)}</title>`),
    configResolved(rc) {
      const api = c.app.mock ? '假数据（app.mock）' : `${c.api.base_path || '同源'} ${c.api.admin_prefix}`;
      rc.logger.info(`[loopland] 配置 ${files.join(' → ')} · API ${api} · 代理到 ${c.backend.url}`);
    },
    configureServer(server) {
      server.watcher.add(watch);
      const onChange = (file: string) => {
        if (!watch.includes(path.resolve(file))) return;
        server.config.logger.info(`[loopland] ${path.basename(file)} 有改动，重启开发服务器`, { timestamp: true });
        void server.restart();
      };
      server.watcher.on('change', onChange).on('add', onChange).on('unlink', onChange);
    },
  };
}

export default defineConfig(({ mode }) => {
  const loaded = loadConfig(root, mode);
  const { config: c } = loaded;
  const target = c.backend.url;
  // First match wins, so the WebSocket path goes before the /v1 prefix that contains it.
  const proxy: Record<string, ProxyOptions> = {
    [c.api.ws_path]: { target, changeOrigin: true, ws: true },
    [c.api.admin_prefix]: { target, changeOrigin: true },
    [c.api.app_prefix]: { target, changeOrigin: true },
  };

  return {
    plugins: [react(), looplandConfig(loaded)],
    define: {
      __LOOPLAND_CONFIG__: JSON.stringify(browserConfig(c)),
    },
    server: {
      host: c.dev_server.host,
      port: c.dev_server.port,
      strictPort: c.dev_server.strict_port,
      open: c.dev_server.open,
      proxy,
    },
    preview: {
      host: c.preview.host,
      port: c.preview.port,
      proxy,
    },
    build: {
      chunkSizeWarningLimit: 2000,
      rollupOptions: {
        output: {
          manualChunks: {
            react: ['react', 'react-dom', 'react-router-dom'],
            antd: ['antd'],
            echarts: ['echarts', 'echarts-for-react'],
          },
        },
      },
    },
  };
});
