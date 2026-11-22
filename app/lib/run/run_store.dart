import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../api/models.dart';

/// A run that has not finished yet (app killed, phone rebooted …).
class RunSnapshot {
  const RunSnapshot({
    required this.clientId,
    required this.sport,
    required this.goal,
    required this.startedAt,
    required this.points,
    required this.activeMs,
    required this.savedAt,
  });
  final String clientId;
  final String sport;
  final Goal goal;
  final DateTime startedAt;
  final List<TrackPoint> points;

  /// Active (non-paused) time up to [savedAt].
  final int activeMs;
  final DateTime savedAt;

  Json toJson() => {
        'client_id': clientId,
        'sport': sport,
        'goal': goal.toJson(),
        'started_at': startedAt.toIso8601String(),
        'points': [for (final p in points) p.toJson()],
        'active_ms': activeMs,
        'saved_at': savedAt.toIso8601String(),
      };

  factory RunSnapshot.fromJson(Json j) => RunSnapshot(
        clientId: j['client_id'] as String,
        sport: j['sport'] as String,
        goal: Goal.fromJson((j['goal'] as Map).cast<String, dynamic>()),
        startedAt: DateTime.parse(j['started_at'] as String),
        points: [
          for (final p in (j['points'] as List? ?? const []))
            TrackPoint.fromJson((p as Map).cast<String, dynamic>())
        ],
        activeMs: (j['active_ms'] as num).toInt(),
        savedAt: DateTime.parse(j['saved_at'] as String),
      );
}

/// An upload that has not been acknowledged by the server yet. It is retried
/// with the same `client_id`, so the server's idempotency returns the same
/// result if a previous attempt actually got through.
class PendingUpload {
  const PendingUpload({required this.upload, this.attempts = 0, this.lastError});
  final ActivityUpload upload;
  final int attempts;
  final String? lastError;

  Json toJson() => {'upload': upload.toJson(), 'attempts': attempts, 'last_error': lastError};
  factory PendingUpload.fromJson(Json j) => PendingUpload(
        upload: ActivityUpload.fromJson((j['upload'] as Map).cast<String, dynamic>()),
        attempts: (j['attempts'] as num?)?.toInt() ?? 0,
        lastError: j['last_error'] as String?,
      );
}

/// Local JSON-file persistence for runs (offline safety).
class RunStore {
  RunStore({Future<Directory> Function()? directory}) : _dirFn = directory ?? _defaultDir;

  final Future<Directory> Function() _dirFn;
  Directory? _dir;

  static Future<Directory> _defaultDir() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/runs');

  Future<Directory> _root() async {
    final d = _dir ??= await _dirFn();
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<Directory> _pendingDir() async {
    final d = Directory('${(await _root()).path}/pending');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// Write-then-rename so a crash never leaves a half-written file.
  static Future<void> _atomicWrite(File f, String content) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(f.path);
  }

  Future<File> get _inProgressFile async => File('${(await _root()).path}/in_progress.json');

  Future<void> saveInProgress(RunSnapshot s) async =>
      _atomicWrite(await _inProgressFile, jsonEncode(s.toJson()));

  Future<RunSnapshot?> loadInProgress() async {
    final f = await _inProgressFile;
    if (!await f.exists()) return null;
    try {
      return RunSnapshot.fromJson((jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  Future<void> clearInProgress() async {
    final f = await _inProgressFile;
    if (await f.exists()) await f.delete();
  }

  Future<void> savePending(PendingUpload p) async {
    final f = File('${(await _pendingDir()).path}/${p.upload.clientId}.json');
    await _atomicWrite(f, jsonEncode(p.toJson()));
  }

  Future<List<PendingUpload>> pending() async {
    final d = await _pendingDir();
    final out = <PendingUpload>[];
    await for (final e in d.list()) {
      if (e is File && e.path.endsWith('.json')) {
        try {
          out.add(PendingUpload.fromJson((jsonDecode(await e.readAsString()) as Map).cast<String, dynamic>()));
        } catch (_) {
          // corrupt file: leave it for inspection, skip
        }
      }
    }
    out.sort((a, b) => a.upload.startedAt.compareTo(b.upload.startedAt));
    return out;
  }

  Future<void> removePending(String clientId) async {
    final f = File('${(await _pendingDir()).path}/$clientId.json');
    if (await f.exists()) await f.delete();
  }
}

/// Browser (Flutter web) version: there is no app file system on the web, so
/// runs are kept in memory for this tab only (no crash recovery after a
/// reload). Phones use [RunStore].
class MemoryRunStore extends RunStore {
  MemoryRunStore() : super(directory: () async => throw UnsupportedError('no file system on the web'));

  RunSnapshot? _inProgress;
  final Map<String, PendingUpload> _pending = {};

  @override
  Future<void> saveInProgress(RunSnapshot s) async => _inProgress = s;

  @override
  Future<RunSnapshot?> loadInProgress() async => _inProgress;

  @override
  Future<void> clearInProgress() async => _inProgress = null;

  @override
  Future<void> savePending(PendingUpload p) async => _pending[p.upload.clientId] = p;

  @override
  Future<List<PendingUpload>> pending() async =>
      _pending.values.toList()..sort((a, b) => a.upload.startedAt.compareTo(b.upload.startedAt));

  @override
  Future<void> removePending(String clientId) async => _pending.remove(clientId);
}
