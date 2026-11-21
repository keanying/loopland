// Dev-server URL and admin API prefix for the screenshot scripts, read from the same files as
// vite.config.ts (config.yaml → config.local.yaml, or $LOOPLAND_ADMIN_CONFIG). Vite does the
// real validation; this only needs dev_server.host / port and api.admin_prefix.
const fs = require('fs');
const path = require('path');
const YAML = require('yaml');

const root = path.join(__dirname, '..');
const read = (f) => (fs.existsSync(f) ? YAML.parse(fs.readFileSync(f, 'utf8')) || {} : {});
const explicit = process.env.LOOPLAND_ADMIN_CONFIG;
const layers = [path.join(root, 'config.yaml'), explicit ? path.resolve(root, explicit) : path.join(root, 'config.local.yaml')].map(read);
const pick = (section, key) => layers.reduce((v, l) => (l[section] && l[section][key] !== undefined ? l[section][key] : v), undefined);

const host = pick('dev_server', 'host');
const browserHost = !host || host === '0.0.0.0' || host === '::' ? 'localhost' : host;

module.exports = {
  /** Override with BASE_URL=… (e.g. when Vite picked another port). */
  baseUrl: process.env.BASE_URL || `http://${browserHost}:${pick('dev_server', 'port') || 5173}`,
  adminPrefix: pick('api', 'admin_prefix') || '/admin/v1',
};
