// Logic of `tool/gen_config.dart`: load config/app.yaml (+ app.local.yaml),
// merge, validate, and render every derived file. Pure functions except
// [loadYamlFile] / [writeOutputs], so test/tool/ can exercise all of it.

import 'dart:convert';
import 'dart:io';

import 'package:loopland/core/config_keys.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// First line (comment) of every generated file.
const generatedHeader = '生成文件，勿手改，来源 config/app.yaml';

/// Thrown for unreadable / malformed input (not for validation errors).
class ConfigException implements Exception {
  ConfigException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum FieldKind {
  /// Free text (keys, IDs).
  text,

  /// `dev` | `prod`.
  env,

  /// http(s) URL with a host; prod requires https.
  url,

  /// Always https.
  https,

  /// ws(s) URL with a host; prod requires wss.
  wsUrl,

  /// https URL ending in `/` whose host is `links.universal_link_domain`.
  universalLink,

  /// Bare domain (goes into an xcconfig, where `//` starts a comment).
  domain,

  /// iOS URL scheme (no underscore).
  scheme,

  /// `wx…` WeChat AppID.
  wechatAppId,

  /// 10 character Apple team ID.
  teamId,

  /// Flutter asset key (`assets/…`, forward slashes).
  asset,

  /// File path (relative to android/ or absolute).
  path,
}

class Field {
  const Field(this.path, this.kind, {this.define, this.required = false, this.sdkKey = false, this.label = ''});

  /// Dotted path inside a profile, e.g. `api.base_url`.
  final String path;
  final FieldKind kind;

  /// The `--dart-define` name, if Dart reads it.
  final String? define;

  /// Must be non-empty in every profile.
  final bool required;

  /// An SDK key: must be non-empty when `env: prod` unless allowed (see
  /// `allow_empty` / `--allow-empty-keys`).
  final bool sdkKey;
  final String label;
}

/// Every key a profile may contain. Unknown keys are an error (typos).
const fields = <Field>[
  Field('env', FieldKind.env, define: 'LOOPLAND_ENV', required: true, label: '环境'),
  Field('api.base_url', FieldKind.url, define: 'API_BASE', required: true, label: '后端地址'),
  Field('api.ws_url', FieldKind.wsUrl, define: 'WS_URL', label: 'WebSocket 地址（留空由 base_url 推导）'),
  Field('links.user_agreement', FieldKind.url, define: 'USER_AGREEMENT_URL', label: '用户协议（留空跟随 api.base_url/legal/…）'),
  Field('links.privacy_policy', FieldKind.url, define: 'PRIVACY_POLICY_URL', label: '隐私政策（留空跟随 api.base_url/legal/…）'),
  Field('links.universal_link_domain', FieldKind.domain, required: true, label: 'Universal Link 域名'),
  Field('wechat.app_id', FieldKind.wechatAppId, define: 'WECHAT_APP_ID', sdkKey: true, label: '微信 AppID'),
  Field(
    'wechat.universal_link',
    FieldKind.universalLink,
    define: 'WECHAT_UNIVERSAL_LINK',
    sdkKey: true,
    label: '微信 Universal Link',
  ),
  Field('alipay.app_id', FieldKind.text, define: 'ALIPAY_APP_ID', label: '支付宝 APPID（可选）'),
  Field(
    'alipay.universal_link',
    FieldKind.universalLink,
    define: 'ALIPAY_UNIVERSAL_LINK',
    label: '支付宝 Universal Link（可选）',
  ),
  Field('alipay.url_scheme', FieldKind.scheme, required: true, label: '支付宝回调 URL Scheme'),
  Field('amap.android_key', FieldKind.text, define: 'AMAP_ANDROID_KEY', sdkKey: true, label: '高德 Android Key'),
  Field('amap.ios_key', FieldKind.text, define: 'AMAP_IOS_KEY', sdkKey: true, label: '高德 iOS Key'),
  Field('amap.style_data', FieldKind.asset, define: 'AMAP_STYLE_DATA', label: '高德自定义样式'),
  Field('amap.style_extra_data', FieldKind.asset, define: 'AMAP_STYLE_EXTRA_DATA', label: '高德自定义样式 extra'),
  Field('amap.navigation_url', FieldKind.https, define: 'AMAP_NAVIGATION_URL', required: true, label: '高德导航 URI'),
  Field(
    'aliyun.auth_secret_android',
    FieldKind.text,
    define: 'ALIYUN_AUTH_SECRET_ANDROID',
    sdkKey: true,
    label: '号码认证 Android 方案秘钥',
  ),
  Field(
    'aliyun.auth_secret_ios',
    FieldKind.text,
    define: 'ALIYUN_AUTH_SECRET_IOS',
    sdkKey: true,
    label: '号码认证 iOS 方案秘钥',
  ),
  Field('aliyun.captcha_prefix', FieldKind.text, define: 'ALIYUN_CAPTCHA_PREFIX', sdkKey: true, label: '验证码身份标'),
  Field('aliyun.captcha_scene_id', FieldKind.text, define: 'ALIYUN_CAPTCHA_SCENE_ID', sdkKey: true, label: '验证码场景 ID'),
  Field('aliyun.captcha_js_url', FieldKind.https, define: 'ALIYUN_CAPTCHA_JS_URL', required: true, label: '验证码 JS'),
  Field(
    'aliyun.captcha_page_url',
    FieldKind.https,
    define: 'ALIYUN_CAPTCHA_PAGE_URL',
    required: true,
    label: '验证码页面 origin',
  ),
  Field('ios.development_team', FieldKind.teamId, label: 'iOS 签名团队'),
  Field('android.key_properties', FieldKind.path, label: 'release 签名配置文件'),
];

final _byPath = {for (final f in fields) f.path: f};
const _allowEmptyKey = 'allow_empty';
final sdkKeyPaths = [
  for (final f in fields)
    if (f.sdkKey) f.path,
];

// ── Loading & merging ──────────────────────────────────────────────────────

/// Plain Dart maps / lists from a YAML document. A missing or empty
/// document is `{}`.
Map<String, Object?> parseYaml(String text, {String source = 'app.yaml'}) {
  // Windows editors may add a BOM; package:yaml handles CRLF itself.
  if (text.startsWith('﻿')) text = text.substring(1);
  Object? doc;
  try {
    doc = loadYaml(text, sourceUrl: Uri.file(source));
  } on YamlException catch (e) {
    throw ConfigException('$source 不是合法的 YAML：${e.message}（第 ${(e.span?.start.line ?? 0) + 1} 行）');
  }
  if (doc == null) return {};
  final plain = _plain(doc);
  if (plain is! Map<String, Object?>) throw ConfigException('$source 顶层必须是映射（shared: / profiles:）');
  return plain;
}

Object? _plain(Object? v) {
  if (v is YamlMap || v is Map) {
    return {for (final e in (v as Map).entries) '${e.key}': _plain(e.value)};
  }
  if (v is YamlList || v is List) return [for (final x in v as List) _plain(x)];
  return v;
}

/// Reads [file]; returns null when it does not exist and [optional].
Map<String, Object?>? loadYamlFile(File file, {bool optional = false}) {
  if (!file.existsSync()) {
    if (optional) return null;
    throw ConfigException('找不到配置文件 ${file.path}');
  }
  return parseYaml(file.readAsStringSync(), source: file.path);
}

/// Recursive merge: maps merge key by key, everything else (scalars, lists)
/// is replaced by [over].
Map<String, Object?> deepMerge(Map<String, Object?> base, Map<String, Object?> over) {
  final out = {...base};
  over.forEach((k, v) {
    final b = out[k];
    out[k] = b is Map<String, Object?> && v is Map<String, Object?> ? deepMerge(b, v) : v;
  });
  return out;
}

/// Sets `a.b.c` in [m] (creating maps on the way).
void setPath(Map<String, Object?> m, String dotted, Object? value) {
  final parts = dotted.split('.');
  var cur = m;
  for (final k in parts.take(parts.length - 1)) {
    final next = cur[k];
    if (next is Map<String, Object?>) {
      cur = next;
    } else {
      cur = cur[k] = <String, Object?>{};
    }
  }
  cur[parts.last] = value;
}

/// The profile names defined in either file.
List<String> profileNames(Map<String, Object?> app, [Map<String, Object?>? local]) => {
  for (final m in [app, ?local])
    if (m['profiles'] case final Map<String, Object?> ps) ...ps.keys,
}.toList();

/// Merges, lowest to highest precedence: `app.yaml shared` → `app.yaml
/// profiles.<p>` → `app.local.yaml shared` → `app.local.yaml profiles.<p>` →
/// [sets] (`--set a.b=v`, then `--api-base`). Returns the raw profile map.
Map<String, Object?> mergeProfile(
  Map<String, Object?> app,
  Map<String, Object?>? local,
  String profile, {
  Map<String, String> sets = const {},
}) {
  for (final (name, m) in [('config/app.yaml', app), ('config/app.local.yaml', local)]) {
    if (m == null) continue;
    for (final k in m.keys) {
      if (k != 'shared' && k != 'profiles') {
        throw ConfigException('$name 顶层只允许 shared: 和 profiles:，发现「$k」');
      }
    }
    for (final k in ['shared', 'profiles']) {
      if (m[k] != null && m[k] is! Map) throw ConfigException('$name 的 $k 必须是映射');
    }
  }
  final names = profileNames(app, local);
  if (!names.contains(profile)) {
    throw ConfigException('没有名为「$profile」的 profile，可选：${names.join(' / ')}');
  }
  Map<String, Object?> section(Map<String, Object?>? m, String? profileName) {
    if (m == null) return {};
    final profiles = m['profiles'] as Map<String, Object?>?;
    final v = profileName == null ? m['shared'] : profiles?[profileName];
    if (v == null) return {};
    if (v is! Map<String, Object?>) {
      throw ConfigException('${profileName == null ? 'shared' : 'profiles.$profileName'} 必须是映射');
    }
    return v;
  }

  var merged = <String, Object?>{};
  for (final layer in [section(app, null), section(app, profile), section(local, null), section(local, profile)]) {
    merged = deepMerge(merged, layer);
  }
  sets.forEach((k, v) => setPath(merged, k, v));
  return merged;
}

// ── Resolution & validation ────────────────────────────────────────────────

class ResolvedConfig {
  ResolvedConfig(this.profile, this.values, this.allowEmpty);

  final String profile;

  /// Every [fields] path → trimmed string ('' when unset or a `<…>` placeholder).
  final Map<String, String> values;

  /// SDK key paths that may stay empty in prod.
  final Set<String> allowEmpty;

  String operator [](String path) => values[path] ?? '';
  String get env => this['env'];
  bool get isProd => env == 'prod';

  /// `api.ws_url` if set, else derived from `api.base_url`.
  String get wsUrl => this['api.ws_url'].isNotEmpty ? this['api.ws_url'] : deriveWsUrl(this['api.base_url']);
  bool get wsUrlExplicit => this['api.ws_url'].isNotEmpty;

  /// Relative to android/ (gradle `rootProject.file`).
  String get keyProperties =>
      this['android.key_properties'].isEmpty ? 'key.properties' : this['android.key_properties'];
}

class Validation {
  final errors = <String>[];
  final warnings = <String>[];
  bool get ok => errors.isEmpty;
}

/// Flattens [raw] into a [ResolvedConfig], recording structural problems
/// (unknown keys, wrong types) in [v].
ResolvedConfig resolve(String profile, Map<String, Object?> raw, Validation v, {bool allowEmptyKeys = false}) {
  final values = {for (final f in fields) f.path: ''};
  final allowEmpty = <String>{if (allowEmptyKeys) ...sdkKeyPaths};

  void walk(Map<String, Object?> m, String prefix) {
    m.forEach((k, val) {
      final path = prefix.isEmpty ? k : '$prefix.$k';
      if (path == _allowEmptyKey) {
        if (val == null) return;
        if (val is! List) {
          v.errors.add('$_allowEmptyKey 必须是列表，例如 [amap.ios_key]');
          return;
        }
        for (final x in val) {
          final s = '$x'.trim();
          if (!sdkKeyPaths.contains(s)) {
            v.errors.add('$_allowEmptyKey 里的「$s」不是 SDK Key，可选：${sdkKeyPaths.join(', ')}');
          } else {
            allowEmpty.add(s);
          }
        }
        return;
      }
      if (val is Map<String, Object?>) {
        if (_byPath.containsKey(path)) {
          v.errors.add('$path 应该是一个值，不是映射');
        } else if (!fields.any((f) => f.path.startsWith('$path.'))) {
          v.errors.add('未知配置段「$path」（拼写错误？）');
        } else {
          walk(val, path);
        }
        return;
      }
      if (!_byPath.containsKey(path) && fields.any((f) => f.path.startsWith('$path.'))) {
        v.errors.add(
          '$path 应该是映射（其下的键：${[for (final f in fields)
            if (f.path.startsWith('$path.')) f.path].join(', ')}），不是单个值',
        );
        return;
      }
      if (!_byPath.containsKey(path)) {
        final group = path.contains('.') ? path.substring(0, path.lastIndexOf('.')) : '';
        final siblings = [
          for (final f in fields)
            if (f.path.startsWith('$group.') || group.isEmpty) f.path,
        ];
        v.errors.add('未知配置项「$path」（拼写错误？${group.isEmpty ? '' : '「$group」下可用：${siblings.join(', ')}'}）');
        return;
      }
      if (val is List) {
        v.errors.add('$path 应该是字符串，不是列表');
        return;
      }
      var s = val == null ? '' : '$val'.trim();
      if (s.contains('\n') || s.contains('\r')) {
        v.errors.add('$path 不能包含换行');
        s = s.replaceAll(RegExp(r'[\r\n]'), '');
      }
      if (s.startsWith('<') && s.endsWith('>')) {
        v.warnings.add('$path 仍是占位符 $s，按未配置处理');
        s = '';
      }
      values[path] = s;
    });
  }

  walk(raw, '');
  return ResolvedConfig(profile, values, allowEmpty);
}

final _domainRe = RegExp(r'^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$');
final _schemeRe = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*$');
final _teamRe = RegExp(r'^[A-Z0-9]{10}$');

/// Whether [host] is this machine / a LAN address (never valid for prod).
bool isLocalHost(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h.endsWith('.local') || h == '0.0.0.0' || h == '::1' || h == '[::1]') return true;
  final ip = RegExp(r'^(\d+)\.(\d+)\.(\d+)\.(\d+)$').firstMatch(h);
  if (ip == null) return false;
  final a = int.parse(ip[1]!), b = int.parse(ip[2]!);
  return a == 127 || a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) || (a == 169 && b == 254);
}

/// Validates [c]; appends to [v] and returns it.
Validation validate(ResolvedConfig c, [Validation? into]) {
  final v = into ?? Validation();
  final prod = c.isProd;
  final domain = c['links.universal_link_domain'];

  final placeholders = <String>[];
  void err(String path, String msg) => v.errors.add('$path：$msg');

  Uri? url(Field f, String s, Set<String> schemes) {
    final u = Uri.tryParse(s);
    if (u == null || !schemes.contains(u.scheme) || u.host.isEmpty) {
      err(f.path, '不是合法的 ${schemes.join(' / ')} 地址：「$s」');
      return null;
    }
    if (s.contains(' ')) err(f.path, '不能包含空格：「$s」');
    // The captcha page URL is only the WebView's origin, never requested.
    if (f.path != 'aliyun.captcha_page_url') {
      if (prod && isLocalHost(u.host)) err(f.path, 'prod 不能指向本机 / 局域网地址（${u.host}）');
      if (prod && (u.host == 'example.com' || u.host.endsWith('.example.com'))) placeholders.add(f.path);
    }
    return u;
  }

  for (final f in fields) {
    final s = c[f.path];
    if (s.isEmpty) {
      if (f.required) {
        err(f.path, '必填（${f.label}）');
      } else if (f.sdkKey && prod && !c.allowEmpty.contains(f.path)) {
        err(f.path, 'prod 必须填写${f.label}（确实不用时把它加进 allow_empty，或运行时加 --allow-empty-keys）');
      }
      continue;
    }
    switch (f.kind) {
      case FieldKind.env:
        if (s != 'dev' && s != 'prod') err(f.path, '只能是 dev 或 prod，当前「$s」');
      case FieldKind.url:
        final u = url(f, s, {'http', 'https'});
        if (u != null && prod && u.scheme != 'https') err(f.path, 'prod 必须使用 https（当前 $s）');
        if (u != null && f.path == 'api.base_url' && (u.hasQuery || u.hasFragment)) {
          err(f.path, '不能带 ? 或 #（当前 $s）');
        }
      case FieldKind.https:
        url(f, s, {'https'});
      case FieldKind.wsUrl:
        final u = url(f, s, {'ws', 'wss'});
        if (u != null && prod && u.scheme != 'wss') err(f.path, 'prod 必须使用 wss（当前 $s）');
      case FieldKind.universalLink:
        final u = url(f, s, {'https'});
        if (u == null) break;
        if (!s.endsWith('/')) err(f.path, 'Universal Link 必须以 / 结尾（当前 $s）');
        if (domain.isNotEmpty && u.host != domain) {
          err(f.path, '域名 ${u.host} 与 links.universal_link_domain（$domain）不一致，iOS Associated Domains 只有这一个');
        }
      case FieldKind.domain:
        if (!_domainRe.hasMatch(s)) err(f.path, '只写域名（如 loopland.example.com），不要写 https:// 或路径，当前「$s」');
      case FieldKind.scheme:
        if (!_schemeRe.hasMatch(s)) err(f.path, 'URL Scheme 只能含字母、数字、+ . -（不能有下划线），当前「$s」');
      case FieldKind.wechatAppId:
        if (!s.startsWith('wx')) err(f.path, '微信 AppID 以 wx 开头，当前「$s」');
      case FieldKind.teamId:
        if (!_teamRe.hasMatch(s)) err(f.path, 'Apple Team ID 是 10 位大写字母 / 数字，当前「$s」');
      case FieldKind.asset:
        if (s.contains(r'\')) {
          err(f.path, 'asset 路径用 / 分隔（Windows 上也是），当前「$s」');
        } else if (!s.startsWith('assets/')) {
          err(f.path, '应是 pubspec 里的 asset 路径（assets/…），当前「$s」');
        }
      case FieldKind.path:
      case FieldKind.text:
        break;
    }
  }
  if (placeholders.isNotEmpty) v.warnings.add('仍是 example.com 占位域名：${placeholders.join(', ')}');
  return v;
}

// ── Rendering ──────────────────────────────────────────────────────────────

/// The `--dart-define`s, in [dartDefineKeys] order. `WS_URL` stays empty
/// unless `api.ws_url` is set, so the app derives it from `API_BASE` at
/// runtime — a lone `--dart-define=API_BASE=…` then moves the WebSocket too.
Map<String, String> dartDefines(ResolvedConfig c) {
  final byDefine = {
    for (final f in fields)
      if (f.define != null) f.define!: c[f.path],
  };
  byDefine['LOOPLAND_CONFIG_PROFILE'] = c.profile;
  return {for (final k in dartDefineKeys) k: byDefine[k] ?? ''};
}

String renderDartDefineJson(ResolvedConfig c) {
  final m = <String, String>{
    // JSON has no comments; Flutter turns this into an unused dart-define.
    '_generated': '$generatedHeader（profile: ${c.profile}；dart run tool/gen_config.dart --profile ${c.profile}）',
    ...dartDefines(c),
  };
  return '${const JsonEncoder.withIndent('  ').convert(m)}\n';
}

/// Java `.properties` escaping (Properties.load reads ISO-8859-1).
String propertiesEscape(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    switch (ch) {
      case r'\':
        b.write(r'\\');
      case '=' || ':' || '#' || '!':
        b.write('\\$ch');
      default:
        if (r > 0x7e || r < 0x20) {
          for (final u in ch.codeUnits) {
            b.write('\\u${u.toRadixString(16).padLeft(4, '0')}');
          }
        } else {
          b.write(ch);
        }
    }
  }
  final out = b.toString();
  return out.startsWith(' ') ? '\\$out' : out;
}

String renderAndroidProperties(ResolvedConfig c) => [
  '# $generatedHeader',
  '# profile: ${c.profile}（重新生成：dart run tool/gen_config.dart --profile ${c.profile}）',
  '# android/app/build.gradle.kts 读取；同名 --dart-define 优先。',
  'LOOPLAND_PROFILE=${propertiesEscape(c.profile)}',
  '# 高德 Key → AndroidManifest <meta-data com.amap.api.v2.apikey>（manifestPlaceholders）',
  'AMAP_ANDROID_KEY=${propertiesEscape(c['amap.android_key'])}',
  '# 场馆二维码 App Link 域名（links.universal_link_domain）→ MainActivity https intent-filter',
  'LOOPLAND_LINK_DOMAIN=${propertiesEscape(c['links.universal_link_domain'])}',
  '# release 签名配置文件（相对 android/，密码只写在那个文件里）',
  'KEY_PROPERTIES=${propertiesEscape(c.keyProperties)}',
  '',
].join('\n');

String _xc(String k, String v) => v.isEmpty ? '$k =' : '$k = $v';

String renderIosXcconfig(ResolvedConfig c) {
  final team = c['ios.development_team'];
  return [
    '// $generatedHeader',
    '// profile: ${c.profile}（重新生成：dart run tool/gen_config.dart --profile ${c.profile}）',
    '// Debug.xcconfig / Release.xcconfig 在 LooplandDefaults.xcconfig 之后 include 本文件。',
    '// xcconfig 中 // 是注释，所以这里只有域名 / scheme / ID，没有 https:// 链接。',
    _xc('WECHAT_APP_ID', c['wechat.app_id']),
    _xc('ALIPAY_URL_SCHEME', c['alipay.url_scheme']),
    _xc('LOOPLAND_ASSOCIATED_DOMAIN', c['links.universal_link_domain']),
    if (team.isNotEmpty) _xc('DEVELOPMENT_TEAM', team) else '// DEVELOPMENT_TEAM 未设置（ios.development_team）',
    '',
  ].join('\n');
}

class GeneratedFile {
  const GeneratedFile(this.path, this.content);

  /// Relative to the output dir, always with `/`.
  final String path;
  final String content;
}

List<GeneratedFile> renderAll(ResolvedConfig c) => [
  GeneratedFile('config/${c.profile}.json', renderDartDefineJson(c)),
  GeneratedFile('android/loopland.properties', renderAndroidProperties(c)),
  GeneratedFile('ios/Flutter/Loopland.xcconfig', renderIosXcconfig(c)),
];

/// Writes [files] under [outDir] with `\n` line endings (no BOM). Returns,
/// per file, whether it changed (unchanged files are not touched, so Gradle
/// / Xcode do not rebuild).
Map<String, bool> writeOutputs(String outDir, List<GeneratedFile> files) {
  final changed = <String, bool>{};
  for (final f in files) {
    final file = File(p.joinAll([outDir, ...f.path.split('/')]));
    final content = f.content.replaceAll('\r\n', '\n');
    final same = file.existsSync() && file.readAsStringSync() == content;
    if (!same) {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(content, flush: true);
    }
    changed[f.path] = !same;
  }
  return changed;
}

// ── One call for the CLI and tests ─────────────────────────────────────────

class GenerateResult {
  GenerateResult(this.config, this.validation, this.files);
  final ResolvedConfig? config;
  final Validation validation;
  final List<GeneratedFile> files;
}

/// Merge → resolve → validate → render. Never writes; never throws for
/// validation problems (they are in `validation.errors`).
GenerateResult generate({
  required Map<String, Object?> app,
  Map<String, Object?>? local,
  required String profile,
  String? apiBase,
  Map<String, String> sets = const {},
  bool allowEmptyKeys = false,
}) {
  final v = Validation();
  final Map<String, Object?> raw;
  try {
    raw = mergeProfile(app, local, profile, sets: {...sets, 'api.base_url': ?apiBase});
  } on ConfigException catch (e) {
    v.errors.add(e.message);
    return GenerateResult(null, v, const []);
  }
  final c = resolve(profile, raw, v, allowEmptyKeys: allowEmptyKeys);
  validate(c, v);
  return GenerateResult(c, v, v.ok ? renderAll(c) : const []);
}
