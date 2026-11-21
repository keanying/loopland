// tool/gen_config.dart: merge, ws derivation, validation, rendered files.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/core/config_keys.dart';
import 'package:loopland/core/sdk_config.dart';

import '../../tool/src/app_config.dart';

Map<String, Object?> _y(String s) => parseYaml(s);

/// A minimal valid app.yaml (dev + prod, prod keys empty).
Map<String, Object?> _app() => _y('''
shared:
  api: { base_url: http://localhost:8080 }
  links:
    user_agreement: https://loop.test/legal/terms
    privacy_policy: https://loop.test/legal/privacy
    universal_link_domain: loop.test
  alipay: { url_scheme: loopland-alipay }
  amap: { navigation_url: https://uri.amap.com/navigation }
  aliyun:
    captcha_js_url: https://o.alicdn.com/captcha-frontend/aliyunCaptcha/AliyunCaptcha.js
    captcha_page_url: https://captcha.loopland.local/
profiles:
  dev:
    env: dev
  prod:
    env: prod
    api: { base_url: https://api.loop.test }
''');

/// Every prod SDK key filled with a dummy value.
Map<String, Object?> _prodKeys() => _y('''
profiles:
  prod:
    wechat: { app_id: wx0123456789abcdef, universal_link: https://loop.test/wechat/ }
    amap: { android_key: a-key, ios_key: i-key }
    aliyun: { auth_secret_android: sa, auth_secret_ios: si, captcha_prefix: pre, captcha_scene_id: scene }
''');

GenerateResult _gen(
  String profile, {
  Map<String, Object?>? app,
  Map<String, Object?>? local,
  String? apiBase,
  Map<String, String> sets = const {},
  bool allowEmptyKeys = false,
}) => generate(
  app: app ?? _app(),
  local: local,
  profile: profile,
  apiBase: apiBase,
  sets: sets,
  allowEmptyKeys: allowEmptyKeys,
);

List<String> _errors(String profile, {Map<String, Object?>? local, Map<String, String> sets = const {}}) =>
    _gen(profile, local: local, sets: sets).validation.errors;

Map<String, Object?> _json(GenerateResult r) =>
    (jsonDecode(r.files.firstWhere((f) => f.path.endsWith('.json')).content) as Map).cast<String, Object?>();

String _file(GenerateResult r, String path) => r.files.firstWhere((f) => f.path == path).content;

void main() {
  group('merge', () {
    test('deepMerge merges maps recursively, replaces scalars and lists, does not mutate', () {
      final base = {
        'a': {'x': 1, 'y': 2},
        'l': [1, 2],
        's': 'base',
      };
      final out = deepMerge(base, {
        'a': {'y': 3, 'z': 4},
        'l': [9],
        'n': 'new',
      });
      expect(out, {
        'a': {'x': 1, 'y': 3, 'z': 4},
        'l': [9],
        's': 'base',
        'n': 'new',
      });
      expect(base['a'], {'x': 1, 'y': 2});
    });

    test('precedence: shared < profile < local shared < local profile < --set < --api-base', () {
      final app = deepMerge(
        _app(),
        _y('shared: { amap: { ios_key: shared } }\nprofiles: { dev: { amap: { ios_key: prof, android_key: prof } } }'),
      );
      expect(mergeProfile(app, null, 'dev')['amap'], containsPair('ios_key', 'prof'));
      final local = _y(
        'shared: { amap: { ios_key: lshared, style_data: assets/map/s.data } }\n'
        'profiles: { dev: { amap: { android_key: lprof } } }',
      );
      final m = mergeProfile(app, local, 'dev');
      expect((m['amap'] as Map)['ios_key'], 'lshared');
      expect((m['amap'] as Map)['android_key'], 'lprof');
      expect((m['amap'] as Map)['navigation_url'], 'https://uri.amap.com/navigation', reason: 'untouched keys survive');

      final r = _gen(
        'dev',
        app: app,
        local: local,
        sets: {'amap.ios_key': 'cli', 'api.base_url': 'http://set:1'},
        apiBase: 'http://10.0.2.2:8080',
      );
      expect(r.validation.errors, isEmpty);
      expect(r.config!['amap.ios_key'], 'cli');
      expect(r.config!['api.base_url'], 'http://10.0.2.2:8080', reason: '--api-base beats --set');
    });

    test('local file may override a single value of a profile (LAN IP)', () {
      final r = _gen('dev', local: _y('profiles:\n  dev:\n    api:\n      base_url: http://192.168.1.10:8080\n'));
      expect(_json(r)['API_BASE'], 'http://192.168.1.10:8080');
      expect(_json(r)['LOOPLAND_ENV'], 'dev');
    });

    test('unknown profile and unknown top-level keys are reported', () {
      expect(_errors('staging').single, allOf(contains('staging'), contains('dev / prod')));
      expect(_gen('dev', local: _y('dev: { env: dev }')).validation.errors.single, contains('顶层只允许'));
    });

    test('YAML errors name the file; BOM and CRLF are accepted', () {
      expect(() => parseYaml('a: [1, 2', source: 'x.yaml'), throwsA(isA<ConfigException>()));
      expect(parseYaml('\uFEFFshared:\r\n  api:\r\n    base_url: http://a:1\r\n'), {
        'shared': {
          'api': {'base_url': 'http://a:1'},
        },
      });
      expect(parseYaml(''), isEmpty);
    });
  });

  group('ws url', () {
    test('derived from base_url: http→ws, https→wss, keeps host / port / path', () {
      expect(deriveWsUrl('http://10.0.2.2:8080'), 'ws://10.0.2.2:8080/v1/ws');
      expect(deriveWsUrl('https://api.loop.test'), 'wss://api.loop.test/v1/ws');
      expect(deriveWsUrl('https://api.loop.test:8443/base/'), 'wss://api.loop.test:8443/base/v1/ws');
    });

    test('derived ws url is not frozen into the JSON; an explicit api.ws_url is', () {
      final r = _gen('dev', apiBase: 'http://192.168.1.10:8080');
      expect(r.config!.wsUrl, 'ws://192.168.1.10:8080/v1/ws');
      expect(r.config!.wsUrlExplicit, isFalse);
      expect(_json(r)['WS_URL'], '', reason: 'app derives it from API_BASE at runtime');

      final e = _gen('dev', sets: {'api.ws_url': 'ws://rt.loop.test:9000/v1/ws'});
      expect(e.config!.wsUrl, 'ws://rt.loop.test:9000/v1/ws');
      expect(_json(e)['WS_URL'], 'ws://rt.loop.test:9000/v1/ws');
    });
  });

  group('validation', () {
    test('the minimal dev profile is valid', () {
      final r = _gen('dev');
      expect(r.validation.errors, isEmpty);
      expect(r.files.map((f) => f.path), [
        'config/dev.json',
        'android/loopland.properties',
        'ios/Flutter/Loopland.xcconfig',
      ]);
    });

    test('required keys', () {
      final app = _app();
      ((app['shared'] as Map)['links'] as Map).remove('privacy_policy');
      final errs = _gen('dev', app: app).validation.errors;
      expect(errs.single, allOf(contains('links.privacy_policy'), contains('必填')));
      expect(_errors('dev', sets: {'env': ''}).single, contains('env'));
      expect(_errors('dev', sets: {'env': 'staging'}).single, contains('只能是 dev 或 prod'));
    });

    test('URLs must be well-formed', () {
      expect(_errors('dev', sets: {'api.base_url': 'localhost:8080'}).single, contains('api.base_url'));
      expect(_errors('dev', sets: {'api.base_url': 'ftp://x.test'}).single, contains('http / https'));
      expect(_errors('dev', sets: {'api.base_url': 'http://x.test/?a=1'}).single, contains('不能带'));
      expect(_errors('dev', sets: {'api.ws_url': 'http://x.test/v1/ws'}).single, contains('api.ws_url'));
      expect(_errors('dev', sets: {'aliyun.captcha_js_url': 'http://cdn.test/a.js'}).single, contains('https'));
      expect(_errors('dev', sets: {'links.universal_link_domain': 'https://loop.test/'}).single, contains('只写域名'));
    });

    test('prod: https / wss only, no local hosts, no empty SDK keys', () {
      final ok = _gen('prod', local: _prodKeys());
      expect(ok.validation.errors, isEmpty);

      final empty = _errors('prod');
      expect(empty, hasLength(sdkKeyPaths.length), reason: 'every SDK key');
      expect(empty.first, contains('prod 必须填写'));

      final local = _prodKeys();
      expect(
        _errors('prod', local: local, sets: {'api.base_url': 'http://api.loop.test'}).single,
        contains('prod 必须使用 https'),
      );
      expect(
        _errors('prod', local: local, sets: {'api.base_url': 'https://10.0.2.2:8080'}).single,
        contains('本机 / 局域网'),
      );
      expect(_errors('prod', local: local, sets: {'api.base_url': 'https://192.168.1.10'}).single, contains('局域网'));
      expect(_errors('prod', local: local, sets: {'api.ws_url': 'ws://api.loop.test/v1/ws'}).single, contains('wss'));
      expect(
        _errors('prod', local: local, sets: {'links.privacy_policy': 'http://loop.test/p'}).single,
        contains('https'),
      );
      // dev may use http / LAN addresses.
      expect(_errors('dev', sets: {'api.base_url': 'http://192.168.1.10:8080'}), isEmpty);
    });

    test('prod: empty keys can be allowed explicitly', () {
      expect(_gen('prod', allowEmptyKeys: true).validation.errors, isEmpty);
      final local = deepMerge(
        _prodKeys(),
        _y(
          'profiles: { prod: { aliyun: { captcha_prefix: "", captcha_scene_id: "" }, '
          'allow_empty: [aliyun.captcha_prefix, aliyun.captcha_scene_id] } }',
        ),
      );
      expect(_gen('prod', local: local).validation.errors, isEmpty);
      expect(
        _gen('prod', local: _y('profiles: { prod: { allow_empty: [api.base_url] } }')).validation.errors,
        contains(contains('不是 SDK Key')),
      );
    });

    test('unknown keys (typos) are errors', () {
      final errs = _errors('dev', sets: {'amap.andriod_key': 'x'});
      expect(errs.single, allOf(contains('amap.andriod_key'), contains('amap.android_key')));
      expect(_gen('dev', local: _y('shared: { mapbox: { key: x } }')).validation.errors.single, contains('mapbox'));
      expect(
        _gen('dev', local: _y('shared: { api: http://x }')).validation.errors,
        contains(allOf(contains('应该是映射'), contains('api.base_url'))),
      );
    });

    test('universal links: https, trailing slash, on links.universal_link_domain', () {
      expect(_errors('dev', sets: {'wechat.universal_link': 'https://loop.test/wechat'}).single, contains('/ 结尾'));
      expect(
        _errors('dev', sets: {'alipay.universal_link': 'https://other.test/alipay/'}).single,
        contains('universal_link_domain'),
      );
    });

    test('native-only values are checked for the xcconfig / manifest', () {
      expect(_errors('dev', sets: {'alipay.url_scheme': 'loopland_alipay'}).single, contains('下划线'));
      expect(_errors('dev', sets: {'wechat.app_id': '12345'}).single, contains('wx'));
      expect(_errors('dev', sets: {'ios.development_team': 'abc'}).single, contains('Team ID'));
      expect(_errors('dev', sets: {'amap.style_data': r'assets\map\style.data'}).single, contains('/ 分隔'));
    });

    test('<...> placeholders count as missing (with a warning)', () {
      final r = _gen('dev', sets: {'amap.ios_key': '<高德 iOS Key>'});
      expect(r.validation.errors, isEmpty);
      expect(r.config!['amap.ios_key'], '');
      expect(r.validation.warnings.single, contains('占位符'));
      expect(
        _errors('prod', local: _prodKeys(), sets: {'amap.ios_key': '<高德 iOS Key>'}).single,
        contains('amap.ios_key'),
      );
    });

    test('numbers are stringified, values trimmed, newlines rejected', () {
      final r = _gen('dev', local: _y('shared: { alipay: { app_id: 2021000123 }, amap: { ios_key: "  k  " } }'));
      expect(r.config!['alipay.app_id'], '2021000123');
      expect(r.config!['amap.ios_key'], 'k');
      expect(_errors('dev', sets: {'amap.ios_key': 'a\nb'}).single, contains('换行'));
    });
  });

  group('output', () {
    final r = _gen(
      'prod',
      local: deepMerge(_prodKeys(), _y('profiles: { prod: { ios: { development_team: ABCDE12345 } } }')),
    );

    test('every file starts with the generated-file header and uses \\n only', () {
      for (final f in r.files) {
        expect(f.content.split('\n').take(2).join('\n'), contains(generatedHeader), reason: f.path);
        expect(f.content, isNot(contains('\r')), reason: f.path);
        expect(f.content, endsWith('\n'), reason: f.path);
      }
    });

    test('config/<profile>.json carries every dart-define and SdkConfig reads it', () {
      final j = _json(r);
      expect(r.files.first.path, 'config/prod.json');
      expect(j.keys.first, '_generated');
      expect(j.keys.skip(1).toList(), dartDefineKeys);
      expect(j['LOOPLAND_ENV'], 'prod');
      expect(j['LOOPLAND_CONFIG_PROFILE'], 'prod');
      expect(j['API_BASE'], 'https://api.loop.test');
      expect(j['WECHAT_UNIVERSAL_LINK'], 'https://loop.test/wechat/');
      final c = SdkConfig.fromMap(j, platform: 'ios', release: true);
      expect(c.oneClickConfigured && c.wechatConfigured && c.amapConfigured && c.captchaConfigured, isTrue);
      expect(c.logMissing(log: (_) {}), isEmpty);
    });

    test('android/loopland.properties', () {
      final props = _file(r, 'android/loopland.properties');
      expect(props, contains('\nAMAP_ANDROID_KEY=a-key\n'));
      expect(props, contains('\nLOOPLAND_PROFILE=prod\n'));
      expect(props, contains('\nKEY_PROPERTIES=key.properties\n'));
      expect(props, contains('\nLOOPLAND_LINK_DOMAIN=loop.test\n'));
      final win = _gen('dev', sets: {'android.key_properties': r'C:\ci\key.properties'});
      expect(_file(win, 'android/loopland.properties'), contains(r'KEY_PROPERTIES=C\:\\ci\\key.properties'));
      expect(propertiesEscape('a=b:c#d é'), r'a\=b\:c\#d \u00e9');
      expect(propertiesEscape(' x'), r'\ x');
    });

    test('ios/Flutter/Loopland.xcconfig has only domains / schemes / IDs', () {
      final xc = _file(r, 'ios/Flutter/Loopland.xcconfig');
      expect(xc, contains('\nWECHAT_APP_ID = wx0123456789abcdef\n'));
      expect(xc, contains('\nALIPAY_URL_SCHEME = loopland-alipay\n'));
      expect(xc, contains('\nLOOPLAND_ASSOCIATED_DOMAIN = loop.test\n'));
      expect(xc, contains('\nDEVELOPMENT_TEAM = ABCDE12345\n'));
      for (final line in xc.split('\n').where((l) => l.isNotEmpty && !l.startsWith('//'))) {
        expect(line, isNot(contains('//')), reason: '// starts a comment in xcconfig: $line');
      }
      final dev = _file(_gen('dev'), 'ios/Flutter/Loopland.xcconfig');
      expect(dev, contains('\nWECHAT_APP_ID =\n'));
      expect(dev, contains('// DEVELOPMENT_TEAM 未设置'));
    });

    test('writeOutputs writes under out-dir with \\n and skips unchanged files', () {
      final dir = Directory.systemTemp.createTempSync('loopland_gen_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final first = writeOutputs(dir.path, r.files);
      expect(first.values, everyElement(isTrue));
      final json = File('${dir.path}/config/prod.json');
      expect(json.readAsBytesSync(), isNot(contains(13)), reason: 'no CR');
      expect(json.readAsBytesSync().take(3), isNot([0xEF, 0xBB, 0xBF]), reason: 'no BOM');
      expect(File('${dir.path}/ios/Flutter/Loopland.xcconfig').existsSync(), isTrue);
      expect(writeOutputs(dir.path, r.files).values, everyElement(isFalse));
    });

    test('invalid config renders nothing', () {
      expect(_gen('prod').files, isEmpty);
    });
  });

  group('committed config/app.yaml', () {
    final app = parseYaml(File('config/app.yaml').readAsStringSync());

    test('has dev and prod; dev is valid as committed', () {
      expect(profileNames(app), containsAll(['dev', 'prod']));
      final r = generate(app: app, profile: 'dev');
      expect(r.validation.errors, isEmpty);
      expect(r.config!.env, 'dev');
    });

    test('prod is rejected until real keys are supplied, then accepted', () {
      expect(generate(app: app, profile: 'prod').validation.errors, isNotEmpty);
      final local = _y('''
profiles:
  prod:
    api: { base_url: https://api.dummy.test }
    links: { user_agreement: https://dummy.test/t, privacy_policy: https://dummy.test/p, universal_link_domain: dummy.test }
    wechat: { app_id: wx0000000000000001, universal_link: https://dummy.test/wechat/ }
    alipay: { universal_link: https://dummy.test/alipay/ }
    amap: { android_key: dummy, ios_key: dummy }
    aliyun: { auth_secret_android: dummy, auth_secret_ios: dummy, captcha_prefix: dummy, captcha_scene_id: dummy }
''');
      final r = generate(app: app, local: local, profile: 'prod');
      expect(r.validation.errors, isEmpty);
      expect(r.validation.warnings, isEmpty);
    });

    test('contains no secrets', () {
      for (final p in profileNames(app)) {
        final r = generate(app: app, profile: p, allowEmptyKeys: true);
        for (final k in sdkKeyPaths.where((k) => !k.endsWith('universal_link'))) {
          expect(r.config![k], '', reason: '$p $k');
        }
      }
    });
  });
}
