// Shape of admin/config.yaml (validated in ../loadConfig.ts). Types only: no runtime code here,
// so both the Vite config (Node) and the browser bundle can import it.

export interface LooplandConfig {
  /** `npm run dev` (Vite dev server). */
  dev_server: { host: string; port: number; strict_port: boolean; open: boolean };
  /** `npm run preview` (serves dist/). */
  preview: { host: string; port: number };
  /** Where the dev / preview proxy forwards API and WebSocket requests. */
  backend: { url: string };
  api: {
    /** Prefix the browser puts before every request; "" = same origin (dev proxy / nginx). */
    base_path: string;
    admin_prefix: string;
    app_prefix: string;
    ws_path: string;
  };
  amap: { key: string; security_code: string; service_host: string; version: string; map_style: string };
  app: { title: string; mock: boolean };
}

/** The part of the config that is compiled into the browser bundle (never dev-server / backend details). */
export type BrowserConfig = Pick<LooplandConfig, 'api' | 'amap' | 'app'>;
