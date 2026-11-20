import 'dart:async';

import 'package:dio/dio.dart';

import '../auth/token_store.dart';
import '../core/env.dart';
import 'errors.dart';

/// App-level signals raised by API responses.
enum ApiEvent { sessionExpired, phoneRequired, consentRequired, banned }

/// Thin wrapper over dio: bearer auth, `X-Platform`, error mapping, and
/// single-flight refresh-token rotation (the old refresh token is invalid as
/// soon as the server rotates it, so concurrent 401s must share one refresh).
class ApiClient {
  ApiClient({
    required this.tokens,
    String? baseUrl,
    HttpClientAdapter? adapter,
    String? platform,
  }) : platform = platform ?? Env.platform {
    BaseOptions opts() => BaseOptions(
          baseUrl: baseUrl ?? Env.apiBase,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(seconds: 60),
          contentType: 'application/json',
          responseType: ResponseType.json,
        );
    dio = Dio(opts());
    _bare = Dio(opts());
    if (adapter != null) {
      dio.httpClientAdapter = adapter;
      _bare.httpClientAdapter = adapter;
    }
    dio.interceptors.add(InterceptorsWrapper(onRequest: _onRequest, onError: _onError));
    _bare.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
      o.headers['X-Platform'] = this.platform;
      h.next(o);
    }));
  }

  final TokenStore tokens;
  final String platform;
  late final Dio dio;
  late final Dio _bare;
  final _events = StreamController<ApiEvent>.broadcast();
  Future<bool>? _refreshing;

  Stream<ApiEvent> get events => _events.stream;

  static bool _isAuthPath(String p) => p.contains('/v1/auth/');

  Future<void> _onRequest(RequestOptions o, RequestInterceptorHandler h) async {
    o.headers['X-Platform'] = platform;
    if (!_isAuthPath(o.path) || o.path.endsWith('/logout')) {
      final t = await tokens.accessToken;
      if (t != null && t.isNotEmpty) o.headers['Authorization'] = 'Bearer $t';
    }
    h.next(o);
  }

  Future<void> _onError(DioException e, ErrorInterceptorHandler h) async {
    final res = e.response;
    final status = res?.statusCode ?? 0;
    final o = e.requestOptions;
    if (status == 401 && !_isAuthPath(o.path) && o.extra['retried'] != true) {
      final ok = await refresh();
      if (ok) {
        try {
          o.extra['retried'] = true;
          final t = await tokens.accessToken;
          o.headers['Authorization'] = 'Bearer $t';
          return h.resolve(await dio.fetch(o));
        } on DioException catch (e2) {
          return h.next(e2);
        }
      }
      _events.add(ApiEvent.sessionExpired);
    }
    if (res != null) {
      final ex = ApiException.fromResponse(status, res.data);
      if (ex.code == 'phone_required') _events.add(ApiEvent.phoneRequired);
      if (ex.code == 'consent_required') _events.add(ApiEvent.consentRequired);
      if (ex.code == 'account_banned' && !_isAuthPath(o.path)) _events.add(ApiEvent.banned);
      return h.next(e.copyWith(error: ex));
    }
    h.next(e);
  }

  /// Rotates the refresh token. Concurrent callers share one request.
  Future<bool> refresh() {
    return _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);
  }

  Future<bool> _doRefresh() async {
    final rt = await tokens.refreshToken;
    if (rt == null || rt.isEmpty) return false;
    try {
      final r = await _bare.post<dynamic>('/v1/auth/refresh', data: {'refresh_token': rt});
      final m = r.data as Map;
      final access = m['access_token'] as String?;
      final next = m['refresh_token'] as String?;
      if (access == null || next == null) return false;
      await tokens.save(access, next);
      return true;
    } on DioException catch (e) {
      // Only drop the session when the server rejected the token; a network
      // failure should not log the user out.
      final s = e.response?.statusCode ?? 0;
      if (s == 401 || s == 403 || s == 400) await tokens.clear();
      return false;
    }
  }

  Future<dynamic> request(
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? query,
    ResponseType? responseType,
  }) async {
    try {
      final r = await dio.request<dynamic>(
        path,
        data: data,
        queryParameters: query,
        options: Options(method: method, responseType: responseType),
      );
      return r.data;
    } catch (e) {
      throw ApiException.from(e);
    }
  }

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) =>
      request('GET', path, query: query);
  Future<dynamic> post(String path, [Object? data]) => request('POST', path, data: data ?? const {});
  Future<dynamic> patch(String path, Object? data) => request('PATCH', path, data: data);
  Future<dynamic> delete(String path) => request('DELETE', path);

  void dispose() => _events.close();
}
