import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

/// Where the access/refresh tokens and the device id live.
abstract class TokenStore {
  Future<String?> get accessToken;
  Future<String?> get refreshToken;
  Future<void> save(String access, String refresh);
  Future<void> clear();

  /// Stable per-install device id (sent as `device_id` / `device.id`).
  Future<String> deviceId();
}

class SecureTokenStore implements TokenStore {
  SecureTokenStore([FlutterSecureStorage? storage])
      : _s = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _s;
  String? _access, _refresh;
  bool _loaded = false;

  Future<void> _load() async {
    if (_loaded) return;
    _access = await _s.read(key: 'access_token');
    _refresh = await _s.read(key: 'refresh_token');
    _loaded = true;
  }

  @override
  Future<String?> get accessToken async {
    await _load();
    return _access;
  }

  @override
  Future<String?> get refreshToken async {
    await _load();
    return _refresh;
  }

  @override
  Future<void> save(String access, String refresh) async {
    _access = access;
    _refresh = refresh;
    _loaded = true;
    await _s.write(key: 'access_token', value: access);
    await _s.write(key: 'refresh_token', value: refresh);
  }

  @override
  Future<void> clear() async {
    _access = null;
    _refresh = null;
    _loaded = true;
    await _s.delete(key: 'access_token');
    await _s.delete(key: 'refresh_token');
  }

  @override
  Future<String> deviceId() async {
    var id = await _s.read(key: 'device_id');
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await _s.write(key: 'device_id', value: id);
    }
    return id;
  }
}

/// In-memory store for tests and previews.
class MemoryTokenStore implements TokenStore {
  MemoryTokenStore({String? access, String? refresh}) {
    _access = access;
    _refresh = refresh;
  }
  String? _access, _refresh;
  final String _device = const Uuid().v4();

  @override
  Future<String?> get accessToken async => _access;
  @override
  Future<String?> get refreshToken async => _refresh;
  @override
  Future<void> save(String access, String refresh) async {
    _access = access;
    _refresh = refresh;
  }

  @override
  Future<void> clear() async {
    _access = null;
    _refresh = null;
  }

  @override
  Future<String> deviceId() async => _device;
}
