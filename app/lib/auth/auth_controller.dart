import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/errors.dart';
import '../api/models.dart';
import '../core/env.dart';
import '../core/providers.dart';

enum AuthStatus { unknown, loggedOut, loggedIn }

class AuthState {
  const AuthState({this.status = AuthStatus.unknown, this.user, this.needBindPhone = false, this.needConsent = false});

  final AuthStatus status;
  final User? user;

  /// 微信 / Apple 首次登录，或接口返回 403 phone_required。
  final bool needBindPhone;

  /// 接口返回 consent_required，或还没有同意隐私政策。
  final bool needConsent;

  bool get loggedIn => status == AuthStatus.loggedIn;

  AuthState copyWith({AuthStatus? status, User? user, bool? needBindPhone, bool? needConsent}) => AuthState(
        status: status ?? this.status,
        user: user ?? this.user,
        needBindPhone: needBindPhone ?? this.needBindPhone,
        needConsent: needConsent ?? this.needConsent,
      );
}

final authProvider = NotifierProvider<AuthController, AuthState>(AuthController.new);

/// The signed-in user (null while logged out).
final userProvider = Provider<User?>((ref) => ref.watch(authProvider).user);

class AuthController extends Notifier<AuthState> {
  StreamSubscription<ApiEvent>? _sub;

  @override
  AuthState build() {
    final client = ref.watch(apiClientProvider);
    _sub?.cancel();
    _sub = client.events.listen(_onEvent);
    ref.onDispose(() => _sub?.cancel());
    return const AuthState();
  }

  void _onEvent(ApiEvent e) {
    switch (e) {
      case ApiEvent.sessionExpired:
        _clearLocal();
        state = const AuthState(status: AuthStatus.loggedOut);
      case ApiEvent.phoneRequired:
        if (state.loggedIn) state = state.copyWith(needBindPhone: true);
      case ApiEvent.consentRequired:
        if (state.loggedIn) state = state.copyWith(needConsent: true);
      case ApiEvent.banned:
        // 403 account_banned on any authed endpoint: drop the session; the
        // login screen shows the ban message on the next attempt.
        forceLoggedOut();
    }
  }

  Future<void> _clearLocal() async {
    await ref.read(kvCacheProvider).remove('last_user');
  }

  Future<void> _cacheUser(User u, Map<String, dynamic>? raw) async {
    if (raw != null) await ref.read(kvCacheProvider).write('last_user', jsonEncode(raw));
  }

  /// Called once at startup.
  Future<void> bootstrap() async {
    final tokens = ref.read(tokenStoreProvider);
    final t = await tokens.accessToken;
    if (t == null || t.isEmpty) {
      state = const AuthState(status: AuthStatus.loggedOut);
      return;
    }
    try {
      final raw = await ref.read(apiClientProvider).get('/v1/me');
      final m = (raw as Map).cast<String, dynamic>();
      final u = User.fromJson(m);
      await _cacheUser(u, m);
      _setUser(u);
    } on ApiException catch (e) {
      if (e.code == 'phone_required') {
        state = AuthState(status: AuthStatus.loggedIn, user: await _cachedUser(), needBindPhone: true);
        return;
      }
      if (e.isNetwork || e.status >= 500) {
        // Offline start: keep the session with the cached profile so a run
        // can still be recorded and uploaded later.
        final cached = await _cachedUser();
        if (cached != null) {
          _setUser(cached);
          return;
        }
      }
      await tokens.clear();
      state = const AuthState(status: AuthStatus.loggedOut);
    }
  }

  Future<User?> _cachedUser() async {
    final c = await ref.read(kvCacheProvider).read('last_user');
    if (c == null) return null;
    return User.fromJson((jsonDecode(c) as Map).cast<String, dynamic>());
  }

  void _setUser(User u, {bool? needBindPhone}) {
    state = AuthState(
      status: AuthStatus.loggedIn,
      user: u,
      needBindPhone: needBindPhone ?? false,
      needConsent: !u.consents.privacyAccepted,
    );
  }

  /// Applies a fresh [User] returned by any endpoint.
  void setUser(User u) => _setUser(u, needBindPhone: state.needBindPhone && (u.phoneMasked ?? '').isEmpty);

  Future<AuthResult> login(String provider, Map<String, dynamic> credential) async {
    final r = await ref.read(apiProvider).login(provider, credential);
    await _cacheUser(r.user, null);
    _setUser(r.user, needBindPhone: r.needBindPhone);
    return r;
  }

  Future<void> refreshUser() async {
    final raw = await ref.read(apiClientProvider).get('/v1/me');
    final m = (raw as Map).cast<String, dynamic>();
    final u = User.fromJson(m);
    await _cacheUser(u, m);
    setUser(u);
  }

  Future<void> bindPhone({String? phone, String? code, String? oneclickToken}) async {
    final u = await ref.read(apiProvider).bindPhone(phone: phone, code: code, oneclickToken: oneclickToken);
    _setUser(u, needBindPhone: false);
  }

  Future<void> saveConsents({required bool location, required bool health}) async {
    final u = await ref
        .read(apiProvider)
        .setConsents(privacyVersion: Env.privacyVersion, location: location, health: health);
    _setUser(u, needBindPhone: false);
  }

  Future<void> logout() async {
    try {
      await ref.read(apiProvider).logout();
    } catch (_) {
      await ref.read(tokenStoreProvider).clear();
    }
    await _clearLocal();
    state = const AuthState(status: AuthStatus.loggedOut);
  }

  /// Used after account deletion takes effect locally.
  Future<void> forceLoggedOut() async {
    await ref.read(tokenStoreProvider).clear();
    await _clearLocal();
    state = const AuthState(status: AuthStatus.loggedOut);
  }
}
