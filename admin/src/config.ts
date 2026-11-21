// Browser-side configuration. Values come from admin/config.yaml (+ overlays) and are injected
// by vite.config.ts at dev / build time as __LOOPLAND_CONFIG__ — never hard-code hosts, ports or keys elsewhere.
import type { BrowserConfig } from './config.types';

export const config: BrowserConfig = __LOOPLAND_CONFIG__;

/** Mock mode: every request is answered by src/mocks (app.mock in the config). */
export const MOCK = config.app.mock;
/** Prefix for fetch(): "" = same origin. */
export const API_BASE = config.api.base_path;
/** Admin API prefix, e.g. /admin/v1. */
export const ADMIN_PREFIX = config.api.admin_prefix;
