import { API_BASE, MOCK } from '../config';
import type { ApiErrorBody } from './types';

const TOKEN_KEY = 'loopland_admin_token';

export class ApiError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export function getToken(): string | null {
  try {
    return localStorage.getItem(TOKEN_KEY);
  } catch {
    return null;
  }
}

export function setToken(token: string | null): void {
  try {
    if (token) localStorage.setItem(TOKEN_KEY, token);
    else localStorage.removeItem(TOKEN_KEY);
  } catch {
    // storage unavailable: token lives only for this page load
  }
}

let unauthorizedHandler: (() => void) | null = null;

/** Called on any 401 so the app can drop the session and go back to the login page. */
export function onUnauthorized(handler: (() => void) | null): void {
  unauthorizedHandler = handler;
}

export type Query = Record<string, string | number | boolean | null | undefined>;

function buildPath(path: string, query?: Query): string {
  if (!query) return path;
  const params = new URLSearchParams();
  for (const [k, v] of Object.entries(query)) {
    if (v === undefined || v === null || v === '') continue;
    params.set(k, String(v));
  }
  const qs = params.toString();
  return qs ? `${path}?${qs}` : path;
}

function isErrorBody(x: unknown): x is ApiErrorBody {
  return (
    typeof x === 'object' &&
    x !== null &&
    'error' in x &&
    typeof (x as ApiErrorBody).error === 'object' &&
    typeof (x as ApiErrorBody).error.message === 'string'
  );
}

export async function request<T>(method: string, path: string, opts: { query?: Query; body?: unknown } = {}): Promise<T> {
  const url = buildPath(path, opts.query);
  const token = getToken();

  try {
    if (MOCK) {
      const { mockFetch } = await import('../mocks');
      return (await mockFetch(method, url, opts.body, token)) as T;
    }

    let res: Response;
    try {
      res = await fetch(API_BASE + url, {
        method,
        headers: {
          Accept: 'application/json',
          ...(opts.body !== undefined ? { 'Content-Type': 'application/json' } : {}),
          ...(token ? { Authorization: `Bearer ${token}` } : {}),
        },
        body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
      });
    } catch {
      throw new ApiError(0, 'network', '无法连接服务器，请检查网络或后端是否已启动');
    }

    const text = await res.text();
    let data: unknown = null;
    if (text) {
      try {
        data = JSON.parse(text);
      } catch {
        data = null;
      }
    }
    if (!res.ok) {
      if (isErrorBody(data)) throw new ApiError(res.status, data.error.code, data.error.message);
      throw new ApiError(res.status, res.status === 401 ? 'unauthorized' : 'http_error', `请求失败（HTTP ${res.status}）`);
    }
    return data as T;
  } catch (err) {
    if (err instanceof ApiError && err.status === 401 && !path.endsWith('/login')) {
      setToken(null);
      unauthorizedHandler?.();
    }
    throw err;
  }
}

/** Status + body text → data, or an ApiError (shared by upload()). */
function parseResponse(status: number, text: string): unknown {
  let data: unknown = null;
  if (text) {
    try {
      data = JSON.parse(text);
    } catch {
      data = null;
    }
  }
  if (status < 200 || status >= 300) {
    if (isErrorBody(data)) throw new ApiError(status, data.error.code, data.error.message);
    if (status === 413) throw new ApiError(status, 'file_too_large', '文件太大');
    throw new ApiError(status, status === 401 ? 'unauthorized' : 'http_error', `请求失败（HTTP ${status}）`);
  }
  return data;
}

/**
 * multipart/form-data POST (image upload). Same auth, mock routing and 401 handling as request(); the
 * browser sets the multipart boundary itself, so no Content-Type header here. Uses XHR for upload progress.
 */
export async function upload<T>(path: string, form: FormData, opts: { onProgress?: (percent: number) => void; signal?: AbortSignal } = {}): Promise<T> {
  const token = getToken();
  try {
    if (MOCK) {
      const { mockFetch } = await import('../mocks');
      opts.onProgress?.(40);
      const r = (await mockFetch('POST', path, form, token)) as T;
      opts.onProgress?.(100);
      return r;
    }
    return await new Promise<T>((resolve, reject) => {
      const xhr = new XMLHttpRequest();
      xhr.open('POST', API_BASE + path);
      xhr.setRequestHeader('Accept', 'application/json');
      if (token) xhr.setRequestHeader('Authorization', `Bearer ${token}`);
      xhr.upload.onprogress = (e) => {
        if (e.lengthComputable) opts.onProgress?.(Math.round((e.loaded / e.total) * 100));
      };
      xhr.onload = () => {
        try {
          resolve(parseResponse(xhr.status, xhr.responseText) as T);
        } catch (err) {
          reject(err);
        }
      };
      xhr.onerror = () => reject(new ApiError(0, 'network', '无法连接服务器，请检查网络或后端是否已启动'));
      xhr.onabort = () => reject(new ApiError(0, 'aborted', '已取消上传'));
      opts.signal?.addEventListener('abort', () => xhr.abort());
      xhr.send(form);
    });
  } catch (err) {
    if (err instanceof ApiError && err.status === 401) {
      setToken(null);
      unauthorizedHandler?.();
    }
    throw err;
  }
}

export const http = {
  get: <T>(path: string, query?: Query) => request<T>('GET', path, { query }),
  post: <T>(path: string, body?: unknown) => request<T>('POST', path, { body: body ?? {} }),
  put: <T>(path: string, body: unknown) => request<T>('PUT', path, { body }),
  patch: <T>(path: string, body: unknown) => request<T>('PATCH', path, { body }),
  del: <T>(path: string, body?: unknown) => request<T>('DELETE', path, body === undefined ? {} : { body }),
};
