// Reads admin/config.yaml (+ overlays), checks every key and returns a typed config.
// Used only by vite.config.ts (Node, at dev / build time). Error messages are for people, in Chinese.
import fs from 'node:fs';
import path from 'node:path';
import { parseDocument } from 'yaml';
import type { BrowserConfig, LooplandConfig } from './src/config.types';

/** Env var naming an extra config file (e.g. production); when set, config.local.yaml is skipped. */
export const CONFIG_ENV = 'LOOPLAND_ADMIN_CONFIG';

type Kind = 'string' | 'text' | 'boolean' | 'port' | 'host' | 'http_url' | 'http_url_or_empty' | 'base_path' | 'prefix';
type Schema = { [key: string]: Kind | Schema };

const SCHEMA = {
  dev_server: { host: 'host', port: 'port', strict_port: 'boolean', open: 'boolean' },
  preview: { host: 'host', port: 'port' },
  backend: { url: 'http_url' },
  api: { base_path: 'base_path', admin_prefix: 'prefix', app_prefix: 'prefix', ws_path: 'prefix' },
  amap: { key: 'string', security_code: 'string', service_host: 'http_url_or_empty', version: 'text', map_style: 'string' },
  app: { title: 'text', mock: 'boolean' },
} satisfies Schema;

export class ConfigError extends Error {
  constructor(problems: string[]) {
    super(
      ['admin 配置有误：', ...problems.map((p) => `  · ${p}`), '', '每一项的含义见 admin/config.yaml 里的注释和 admin/README.md「配置」一节。'].join('\n'),
    );
    this.name = 'ConfigError';
    // Vite prints error.stack; Node frames would only hide the message.
    this.stack = this.message;
  }
}

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => typeof v === 'object' && v !== null && !Array.isArray(v);
const show = (v: unknown) => (v === null ? '空值' : JSON.stringify(v));

function distance(a: string, b: string): number {
  const d = Array.from({ length: a.length + 1 }, (_, i) => [i, ...Array<number>(b.length).fill(0)]);
  for (let j = 1; j <= b.length; j++) d[0][j] = j;
  for (let i = 1; i <= a.length; i++)
    for (let j = 1; j <= b.length; j++) d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
  return d[a.length][b.length];
}

function suggest(key: string, known: string[]): string {
  const best = known.map((k) => [k, distance(key.toLowerCase(), k)] as const).sort((x, y) => x[1] - y[1])[0];
  return best && best[1] <= 3 ? `，是不是想写 ${best[0]}？` : `，这一层可用的有：${known.join('、')}`;
}

function readYaml(file: string, label: string, problems: string[]): Obj {
  let text: string;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (e) {
    problems.push(`读不到 ${label}：${(e as Error).message}`);
    return {};
  }
  const doc = parseDocument(text, { prettyErrors: true, uniqueKeys: true });
  if (doc.errors.length) {
    for (const e of doc.errors) problems.push(`${label} 不是合法的 YAML：${e.message.replace(/\n+/g, '\n      ')}`);
    return {};
  }
  const v: unknown = doc.toJS();
  if (v === null || v === undefined) return {};
  if (!isObj(v)) {
    problems.push(`${label} 的顶层必须是「键: 值」形式（如 dev_server: …），现在是 ${show(v)}`);
    return {};
  }
  return v;
}

/** Deep-merges `src` over `dst`, rejecting keys the schema doesn't know (typos). */
function merge(dst: Obj, src: Obj, schema: Schema, label: string, prefix: string, sources: Map<string, string>, problems: string[]) {
  for (const [k, v] of Object.entries(src)) {
    const key = prefix ? `${prefix}.${k}` : k;
    const spec = schema[k];
    if (spec === undefined) {
      problems.push(`${label}：未知配置项 ${key}${suggest(k, Object.keys(schema))}`);
    } else if (typeof spec === 'object') {
      if (v === null || v === undefined) continue; // "section:" with nothing under it
      if (!isObj(v)) {
        problems.push(`${label}：${key} 下面应该是子项（如 ${key}.${Object.keys(spec)[0]}），现在是 ${show(v)}`);
        continue;
      }
      if (!isObj(dst[k])) dst[k] = {};
      merge(dst[k] as Obj, v, spec, label, key, sources, problems);
    } else {
      dst[k] = v;
      sources.set(key, label);
    }
  }
}

const isHttpUrl = (s: string) => {
  try {
    const u = new URL(s);
    return (u.protocol === 'http:' || u.protocol === 'https:') && !!u.hostname;
  } catch {
    return false;
  }
};

/** Returns [normalized value] or an error text (without the key name). */
function check(kind: Kind, v: unknown): [unknown] | string {
  const quoted = typeof v === 'number' ? '（YAML 会把不加引号的数字读成数值，请给值加上引号，如 "2.0"）' : '';
  const str = v === null ? '' : v; // "key:" with no value = empty string
  switch (kind) {
    case 'port':
      if (typeof v === 'number' && Number.isInteger(v) && v >= 1 && v <= 65535) return [v];
      return `必须是 1–65535 的整数${typeof v === 'string' && /^\d+$/.test(v.trim()) ? '（去掉引号）' : ''}`;
    case 'boolean':
      if (typeof v === 'boolean') return [v];
      return `必须是 true 或 false${typeof v === 'string' && /^(yes|no|on|off|y|n|1|0)$/i.test(v) ? '（yes / no / on / off 不算）' : ''}`;
    case 'host':
      if (typeof v !== 'string' || !v.trim()) return '必须是主机名或 IP，如 localhost、0.0.0.0';
      if (v.includes('/') || /^[^:]+:\d+$/.test(v)) return '只写主机名或 IP，不要带 http:// 或端口（端口写在 port）';
      return [v.trim()];
    case 'http_url':
      if (typeof v === 'string' && isHttpUrl(v.trim())) return [v.trim().replace(/\/+$/, '')];
      return '必须是 http:// 或 https:// 开头的完整地址，如 http://localhost:8080';
    case 'http_url_or_empty':
      if (str === '') return [''];
      if (typeof str === 'string' && isHttpUrl(str.trim())) return [str.trim().replace(/\/+$/, '')];
      return '必须留空，或是 http:// / https:// 开头的完整地址';
    case 'base_path':
      if (str === '') return [''];
      if (typeof str === 'string' && (isHttpUrl(str.trim()) || /^\/\S*$/.test(str.trim()))) return [str.trim().replace(/\/+$/, '')];
      return '必须是 ""（同源）、以 / 开头的路径（如 /loopland），或 http(s):// 开头的地址';
    case 'prefix':
      if (typeof v === 'string' && /^(\/[\w.~-]+)+$/.test(v.trim())) return [v.trim()];
      return '必须以 / 开头、不以 / 结尾、中间不含空格，如 /admin/v1';
    case 'string':
      if (typeof str === 'string') return [str.trim()];
      return `必须是字符串${quoted}`;
    case 'text':
      if (typeof v === 'string' && v.trim()) return [v.trim()];
      return `必须是非空字符串${quoted}`;
  }
}

function validate(merged: Obj, schema: Schema, prefix: string, sources: Map<string, string>, problems: string[]): Obj {
  const out: Obj = {};
  for (const [k, spec] of Object.entries(schema)) {
    const key = prefix ? `${prefix}.${k}` : k;
    const v = merged[k];
    if (typeof spec === 'object') {
      out[k] = validate(isObj(v) ? v : {}, spec, key, sources, problems);
    } else if (v === undefined) {
      problems.push(`缺少配置项 ${key}（config.yaml 里应有它的默认值）`);
    } else {
      const r = check(spec, v);
      if (typeof r === 'string') problems.push(`${key} ${r}，现在是 ${show(v)}（来自 ${sources.get(key)}）`);
      else out[k] = r[0];
    }
  }
  return out;
}

export interface LoadedConfig {
  config: LooplandConfig;
  /** Files that were merged, in order (relative to admin/ when inside it). */
  files: string[];
  /** Every file that would affect the result if created / changed (for the dev-server watcher). */
  watch: string[];
}

/**
 * Merge order (later wins):
 *   config.yaml → config.local.yaml → config.<mode>.yaml → $LOOPLAND_ADMIN_CONFIG
 * config.local.yaml is skipped when LOOPLAND_ADMIN_CONFIG is set, so a production build never picks up a developer's local file.
 */
export function loadConfig(root: string, mode: string): LoadedConfig {
  const label = (f: string) => {
    const r = path.relative(root, f);
    return r.startsWith('..') || path.isAbsolute(r) ? f : r.split(path.sep).join('/');
  };
  const explicitRaw = process.env[CONFIG_ENV]?.trim();
  const explicit = explicitRaw ? path.resolve(root, explicitRaw) : null;
  const local = path.join(root, 'config.local.yaml');
  const modeFile = /^[\w-]+$/.test(mode) && mode !== 'local' ? path.join(root, `config.${mode}.yaml`) : null;

  const problems: string[] = [];
  const layers = [path.join(root, 'config.yaml')];
  if (!explicit && fs.existsSync(local)) layers.push(local);
  if (modeFile && fs.existsSync(modeFile)) layers.push(modeFile);
  if (explicit) {
    if (fs.existsSync(explicit)) layers.push(explicit);
    else problems.push(`环境变量 ${CONFIG_ENV} 指向的文件不存在：${explicit}`);
  }

  const merged: Obj = {};
  const sources = new Map<string, string>();
  for (const f of layers) merge(merged, readYaml(f, label(f), problems), SCHEMA, label(f), '', sources, problems);
  const config = validate(merged, SCHEMA, '', sources, problems) as unknown as LooplandConfig;

  if (!problems.length) {
    const { admin_prefix, app_prefix, ws_path } = config.api;
    if (admin_prefix === app_prefix) problems.push(`api.admin_prefix 和 api.app_prefix 不能相同（都是 ${admin_prefix}）`);
    if (ws_path === admin_prefix) problems.push('api.ws_path 不能和 api.admin_prefix 相同');
  }
  if (problems.length) throw new ConfigError(problems);

  return {
    config,
    files: layers.map(label),
    watch: [...layers, local, ...(modeFile ? [modeFile] : []), ...(explicit ? [explicit] : [])],
  };
}

/** What goes into the browser bundle as __LOOPLAND_CONFIG__. */
export function browserConfig(c: LooplandConfig): BrowserConfig {
  return { api: c.api, amap: c.amap, app: c.app };
}
