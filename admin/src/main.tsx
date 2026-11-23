import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import { App as AntApp, ConfigProvider } from 'antd';
import zhCN from 'antd/locale/zh_CN';
import { MutationCache, QueryCache, QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { ApiError } from './api/client';
import { AuthProvider } from './auth/AuthContext';
import { theme } from './theme';
import { ANTD_ICON_CONFIG, installAntdIconSkin } from './components/antdIcons';
import { toastError } from './utils/notify';
import App from './App';
import './utils/format';
import './styles.css';

const queryClient = new QueryClient({
  // meta.silent: background polls (the 站内信 bell) fail quietly and retry on the next tick.
  queryCache: new QueryCache({ onError: (err, query) => !query.meta?.silent && toastError(err) }),
  // meta.inlineError: the page shows the message itself (e.g. 系统配置 drawer), so no toast.
  mutationCache: new MutationCache({ onError: (err, _vars, _ctx, mutation) => !mutation.meta?.inlineError && toastError(err) }),
  defaultOptions: {
    queries: {
      staleTime: 15_000,
      refetchOnWindowFocus: false,
      retry: (count, err) => !(err instanceof ApiError && err.status >= 400 && err.status < 500) && count < 1,
    },
  },
});

installAntdIconSkin();

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <ConfigProvider locale={zhCN} theme={theme} button={{ autoInsertSpace: false }} {...ANTD_ICON_CONFIG}>
      <AntApp>
        <QueryClientProvider client={queryClient}>
          <BrowserRouter future={{ v7_startTransition: true, v7_relativeSplatPath: true }}>
            <AuthProvider>
              <App />
            </AuthProvider>
          </BrowserRouter>
        </QueryClientProvider>
      </AntApp>
    </ConfigProvider>
  </StrictMode>,
);
