// 生成各端配置文件：config/app.yaml（+ config/app.local.yaml）→
//   config/<profile>.json            flutter run/build --dart-define-from-file=…
//   android/loopland.properties      android/app/build.gradle.kts（manifestPlaceholders）
//   ios/Flutter/Loopland.xcconfig    Debug/Release.xcconfig include
//
//   dart run tool/gen_config.dart --profile dev [--api-base http://10.0.2.2:8080]
//
// 用法见 --help 和 app/README.md「配置」。Linux / macOS / Windows 行为一致。

import 'dart:io';

import 'package:path/path.dart' as p;

import 'src/app_config.dart';

const _usage = '''
用法：dart run tool/gen_config.dart [选项]

  --profile <名字>      要生成的 profile（config/app.yaml 的 profiles 下），默认 dev
  --api-base <URL>      覆盖 api.base_url（如 Android 模拟器 http://10.0.2.2:8080）
  --set <键>=<值>       覆盖任意配置项，可重复，如 --set wechat.app_id=wx123
  --config <文件>       主配置，默认 config/app.yaml
  --local <文件>        本机覆盖，默认 config/app.local.yaml（不存在则跳过）
  --no-local            不读本机覆盖文件
  --out-dir <目录>      输出根目录（其下写 config/、android/、ios/Flutter/），默认 app 目录
  --allow-empty-keys    prod 也允许 SDK Key 为空（仅用于冒烟构建）
  --check               只校验，不写文件
  -h, --help            显示本帮助

优先级（低 → 高）：app.yaml shared → app.yaml profiles.<p> → app.local.yaml shared
→ app.local.yaml profiles.<p> → --set → --api-base。生成的 JSON 再被 flutter 命令行上
单独写的 --dart-define 覆盖。''';

Never _usageError(String msg) {
  stderr.writeln('错误：$msg\n\n$_usage');
  exit(64);
}

/// The app directory: the parent of tool/ when run as a script, else the
/// working directory.
String _appRoot() {
  try {
    final script = File.fromUri(Platform.script);
    if (p.basename(script.parent.path) == 'tool') {
      final root = script.parent.parent.path;
      if (File(p.join(root, 'pubspec.yaml')).existsSync()) return p.normalize(root);
    }
  } catch (_) {}
  return Directory.current.path;
}

void main(List<String> args) {
  var profile = 'dev';
  String? apiBase, configPath, localPath, outDir;
  var noLocal = false, allowEmpty = false, checkOnly = false;
  final sets = <String, String>{};

  var i = 0;
  while (i < args.length) {
    var a = args[i++];
    String? inline;
    if (a.startsWith('--') && a.contains('=')) {
      inline = a.substring(a.indexOf('=') + 1);
      a = a.substring(0, a.indexOf('='));
    }
    String next() {
      if (inline != null) return inline;
      if (i >= args.length || args[i].startsWith('--')) _usageError('$a 需要一个值');
      return args[i++];
    }

    switch (a) {
      case '-h' || '--help':
        stdout.writeln(_usage);
        return;
      case '--profile':
        profile = next();
      case '--api-base':
        apiBase = next();
      case '--set':
        final kv = next();
        final eq = kv.indexOf('=');
        if (eq <= 0) _usageError('--set 的格式是 键=值，如 --set amap.ios_key=xxx');
        sets[kv.substring(0, eq).trim()] = kv.substring(eq + 1);
      case '--config':
        configPath = next();
      case '--local':
        localPath = next();
      case '--no-local':
        noLocal = true;
      case '--out-dir':
        outDir = next();
      case '--allow-empty-keys':
        allowEmpty = true;
      case '--check':
        checkOnly = true;
      default:
        _usageError('未知参数「$a」');
    }
  }

  final root = _appRoot();
  final appFile = File(configPath ?? p.join(root, 'config', 'app.yaml'));
  final localFile = File(localPath ?? p.join(root, 'config', 'app.local.yaml'));

  final Map<String, Object?> app;
  Map<String, Object?>? local;
  try {
    app = loadYamlFile(appFile)!;
    // An explicit --local must exist; the default one is optional.
    local = noLocal ? null : loadYamlFile(localFile, optional: localPath == null);
  } on ConfigException catch (e) {
    stderr.writeln('错误：$e');
    exit(1);
  }

  final r = generate(
    app: app,
    local: local,
    profile: profile,
    apiBase: apiBase,
    sets: sets,
    allowEmptyKeys: allowEmpty,
  );

  stdout.writeln(
    '圈圈配置：profile=$profile，来源 ${p.relative(appFile.path, from: root)}'
    '${local != null ? ' + ${p.relative(localFile.path, from: root)}' : ''}'
    '${sets.isNotEmpty ? ' + --set ${sets.keys.join(', ')}' : ''}'
    '${apiBase != null ? ' + --api-base' : ''}',
  );
  for (final w in r.validation.warnings) {
    stdout.writeln('  警告  $w');
  }
  if (!r.validation.ok) {
    stderr.writeln('配置有 ${r.validation.errors.length} 处错误（未写任何文件）：');
    for (final e in r.validation.errors) {
      stderr.writeln('  ✗ [$profile] $e');
    }
    exit(1);
  }

  final c = r.config!;
  stdout.writeln('  env         ${c.env}');
  stdout.writeln('  API         ${c['api.base_url']}');
  stdout.writeln('  WebSocket   ${c.wsUrl}${c.wsUrlExplicit ? '' : '（由 base_url 推导）'}');
  final empty = [
    for (final k in sdkKeyPaths)
      if (c[k].isEmpty) k,
  ];
  if (empty.isNotEmpty) stdout.writeln('  未配置      ${empty.join(', ')}');

  if (checkOnly) {
    stdout.writeln('校验通过（--check，未写文件）');
    return;
  }
  final out = outDir ?? root;
  final changed = writeOutputs(out, r.files);
  changed.forEach((path, ch) {
    stdout.writeln('  ${ch ? '已生成' : '未变化'}  ${p.joinAll([?outDir, ...path.split('/')])}');
  });
  stdout.writeln('运行：flutter run --dart-define-from-file=config/$profile.json');
}
