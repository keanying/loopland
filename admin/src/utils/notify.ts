import type { App } from 'antd';
import { ApiError } from '../api/client';

type AppApi = ReturnType<typeof App.useApp>;

let app: AppApi | null = null;

/** Set once from inside <App> so code outside React (react-query callbacks) can toast. */
export function setNotifier(a: AppApi) {
  app = a;
}

export function errorMessage(err: unknown): string {
  if (err instanceof ApiError) return err.message;
  if (err instanceof Error) return err.message;
  return '操作失败';
}

export function toastError(err: unknown) {
  if (err instanceof ApiError && err.status === 401) return; // handled by the redirect to /login
  app?.message.error(errorMessage(err));
}

export function toastOk(text: string) {
  app?.message.success(text);
}
