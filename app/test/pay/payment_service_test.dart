import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:loopland/api/api_client.dart';
import 'package:loopland/api/errors.dart';
import 'package:loopland/api/loopland_api.dart';
import 'package:loopland/api/models.dart';
import 'package:loopland/auth/social_login.dart';
import 'package:loopland/auth/token_store.dart';
import 'package:loopland/pay/payment_service.dart';

import '../api/api_client_test.dart' show FakeAdapter;
import '../api/fixtures.dart';

const jws = 'eyJhbGciOiJFUzI1NiJ9.eyJ0cmFuc2FjdGlvbklkIjoiMSJ9.c2lnbmF0dXJl';

class FakeGateways implements PayGateways {
  FakeGateways({this.alipayResult = const {'resultStatus': '9000'}, this.wechatCode = 0, this.installed = true, this.throwOnPay});
  final Map<Object?, Object?> alipayResult;
  final int wechatCode;
  final bool installed;
  final Object? throwOnPay;
  final log = <String>[];
  Map<String, dynamic>? wechatParams;
  String? orderString;

  @override
  Future<void> ensureWechatReady() async {
    if (!installed) throw ApiException(status: 0, code: 'wechat_not_installed', message: WeChat.notInstalled);
  }

  @override
  Future<int> wechatPay(Map<String, dynamic> payParams) async {
    log.add('sdk');
    wechatParams = payParams;
    if (throwOnPay != null) throw throwOnPay!;
    return wechatCode;
  }

  @override
  Future<Map<Object?, Object?>> alipay(String orderString) async {
    log.add('sdk');
    this.orderString = orderString;
    if (throwOnPay != null) throw throwOnPay!;
    return alipayResult;
  }
}

class FakeIap implements IapGateway {
  FakeIap(this.log, {this.serverData = jws});
  final List<String> log;
  final String serverData;
  final ctrl = StreamController<List<PurchaseDetails>>.broadcast();
  String? appAccountToken;

  PurchaseDetails details(PurchaseStatus status, {String id = 'com.loopland.member.auto_month'}) => PurchaseDetails(
        purchaseID: '1001',
        productID: id,
        verificationData: PurchaseVerificationData(localVerificationData: '{}', serverVerificationData: serverData, source: 'app_store'),
        transactionDate: '0',
        status: status,
      )..pendingCompletePurchase = status == PurchaseStatus.purchased;

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => ctrl.stream;
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<ProductDetails?> product(String id) async =>
      ProductDetails(id: id, title: '连续包月', description: '', price: '¥15', rawPrice: 15, currencyCode: 'CNY');
  @override
  Future<void> buy(ProductDetails product, String appAccountToken) async {
    log.add('buy');
    this.appAccountToken = appAccountToken;
    scheduleMicrotask(() => ctrl.add([details(PurchaseStatus.purchased, id: product.id)]));
  }

  @override
  Future<void> finish(PurchaseDetails p) async => log.add('finish');
  @override
  Future<void> restore() async {
    log.add('restore');
    scheduleMicrotask(() => ctrl.add([details(PurchaseStatus.restored)]));
  }
}

/// Fake backend: orders + polling + Apple verification; records the calls in
/// [log] so the order of SDK / server / StoreKit steps can be asserted.
class Backend {
  Backend({required this.channel, List<String>? statuses, this.verifyStatus = 200, this.payParams = const {}})
      : statuses = statuses ?? ['created', 'paid'];
  final String channel;
  final List<String> statuses;
  final int verifyStatus;
  final Map<String, Object?> payParams;
  final log = <String>[];
  var polls = 0;
  late final adapter = FakeAdapter((o) {
    if (o.method == 'POST' && o.path == '/v1/orders') {
      log.add('create');
      return (200, {'order': _order('created'), 'pay_params': payParams});
    }
    if (o.method == 'GET' && o.path == '/v1/orders/LP1') {
      log.add('poll');
      final s = statuses[polls < statuses.length ? polls : statuses.length - 1];
      polls++;
      return (200, _order(s));
    }
    if (o.path == '/v1/iap/apple') {
      log.add('verify:${(o.data as Map)['signed_transaction']}');
      return verifyStatus == 200 ? (200, j(userJson)) : (verifyStatus, {'error': {'code': 'provider_error', 'message': 'bad jws'}});
    }
    return (404, {'error': {'code': 'not_found', 'message': ''}});
  });

  Map<String, Object?> _order(String status) =>
      {...j(orderJson), 'order_no': 'LP1', 'channel': channel, 'status': status};

  PaymentService service({PayGateways? gateways, IapGateway? iap}) => PaymentService(
        LooplandApi(ApiClient(tokens: MemoryTokenStore(access: 'A'), baseUrl: 'http://x', adapter: adapter)),
        gateways: gateways ?? FakeGateways(),
        iap: iap,
        pollInterval: const Duration(milliseconds: 1),
        pollTimeout: const Duration(milliseconds: 200),
        unpaidCheckTimeout: const Duration(milliseconds: 5),
      );
}

final plan = Plan.fromJson(j(planJson));

void main() {
  group('Alipay: always poll GET /v1/orders/{no} after the SDK returns', () {
    test('9000 → polls until the server marks it paid', () async {
      final b = Backend(channel: 'alipay_app', statuses: ['created', 'created', 'paid'], payParams: {'order_string': 'app_id=1&sign=x'});
      final g = FakeGateways();
      final o = await b.service(gateways: g).purchase(plan, 'alipay_app');
      expect(g.orderString, 'app_id=1&sign=x');
      expect(o.isPaid, isTrue);
      expect(b.log, ['create', 'poll', 'poll', 'poll']);
    });

    test('6001 cancelled → still asks the server, then reports cancelled', () async {
      final b = Backend(channel: 'alipay_app', statuses: ['created']);
      final s = b.service(gateways: FakeGateways(alipayResult: {'resultStatus': '6001'}));
      await expectLater(s.purchase(plan, 'alipay_app'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'cancelled')));
      expect(b.log.first, 'create');
      expect(b.log, contains('poll'));
    });

    test('SDK says failed but the callback arrived → paid (server wins)', () async {
      final b = Backend(channel: 'alipay_app', statuses: ['paid']);
      final o = await b.service(gateways: FakeGateways(alipayResult: {'resultStatus': '4000', 'memo': '失败'})).purchase(plan, 'alipay_app');
      expect(o.isPaid, isTrue);
    });

    test('SDK throws → polls anyway, then surfaces the error', () async {
      final b = Backend(channel: 'alipay_app', statuses: ['created']);
      final s = b.service(gateways: FakeGateways(throwOnPay: Exception('boom')));
      await expectLater(s.purchase(plan, 'alipay_app'), throwsA(isA<ApiException>()));
      expect(b.log, contains('poll'));
    });

    test('8000 / 6004 (result unknown) wait for the callback like success', () async {
      for (final code in ['8000', '6004']) {
        final b = Backend(channel: 'alipay_app', statuses: ['created', 'paid']);
        final o = await b.service(gateways: FakeGateways(alipayResult: {'resultStatus': code})).purchase(plan, 'alipay_app');
        expect(o.isPaid, isTrue, reason: code);
      }
    });
  });

  group('WeChat Pay', () {
    const params = {
      'appid': 'wx1',
      'partnerid': '1900000109',
      'prepayid': 'wx2017',
      'package': 'Sign=WXPay',
      'noncestr': 'n0nce',
      'timestamp': '1700000000',
      'sign': 'SIGN',
    };

    test('passes pay_params through unchanged and polls after the SDK', () async {
      final b = Backend(channel: 'wechat_app', payParams: params);
      final g = FakeGateways();
      final o = await b.service(gateways: g).purchase(plan, 'wechat_app');
      expect(g.wechatParams, params);
      expect(o.isPaid, isTrue);
      expect(b.log, ['create', 'poll', 'poll']);

      final p = wechatPayment(params);
      expect([p.appId, p.partnerId, p.prepayId, p.packageValue, p.nonceStr, p.timestamp, p.sign],
          ['wx1', '1900000109', 'wx2017', 'Sign=WXPay', 'n0nce', 1700000000, 'SIGN']);
      expect(() => wechatPayment({...params}..remove('sign')), throwsA(isA<ApiException>()));
    });

    test('cancel (-2) → server is asked, then cancelled', () async {
      final b = Backend(channel: 'wechat_app', statuses: ['created'], payParams: params);
      await expectLater(b.service(gateways: FakeGateways(wechatCode: -2)).purchase(plan, 'wechat_app'),
          throwsA(isA<ApiException>().having((e) => e.code, 'code', 'cancelled')));
      expect(b.log, contains('poll'));
    });

    test('WeChat not installed → friendly message and no order is created', () async {
      final b = Backend(channel: 'wechat_app');
      await expectLater(
          b.service(gateways: FakeGateways(installed: false)).purchase(plan, 'wechat_app'),
          throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('未安装微信'))));
      expect(b.log, isEmpty);
    });
  });

  group('Apple IAP: finish only after POST /v1/iap/apple returned 200', () {
    test('buy → verify JWS → finish → poll; appAccountToken from pay_params', () async {
      final b = Backend(
          channel: 'apple_iap',
          payParams: {'product_id': 'com.loopland.member.auto_month', 'app_account_token': '6f1c2a9e-0000-4000-8000-000000000001'});
      final iap = FakeIap(b.log);
      final s = b.service(iap: iap);
      final o = await s.purchase(plan, 'apple_iap');
      expect(o.isPaid, isTrue);
      expect(iap.appAccountToken, '6f1c2a9e-0000-4000-8000-000000000001');
      final i = b.log.indexOf('verify:$jws');
      expect(i, greaterThan(b.log.indexOf('buy')));
      expect(b.log.indexOf('finish'), greaterThan(i), reason: 'finishTransaction after the server said 200');
      expect(b.log.last, 'poll');
      s.dispose();
    });

    test('server rejects → transaction is NOT finished (StoreKit redelivers it)', () async {
      final b = Backend(channel: 'apple_iap', verifyStatus: 400, payParams: {'app_account_token': 'u'});
      final iap = FakeIap(b.log);
      final s = b.service(iap: iap);
      await expectLater(s.purchase(plan, 'apple_iap'), throwsA(isA<ApiException>()));
      expect(b.log, contains('verify:$jws'));
      expect(b.log, isNot(contains('finish')));
      s.dispose();
    });

    test('legacy receipt instead of a JWS → nothing sent, nothing finished', () async {
      final b = Backend(channel: 'apple_iap', payParams: {'app_account_token': 'u'});
      final iap = FakeIap(b.log, serverData: 'MIIT0gYJKoZIhvcNAQcCoIITwzCCE78CAQEx');
      final s = b.service(iap: iap);
      await expectLater(s.purchase(plan, 'apple_iap'), throwsA(isA<ApiException>()));
      expect(b.log.where((l) => l.startsWith('verify')), isEmpty);
      expect(b.log, isNot(contains('finish')));
      s.dispose();
    });

    test('renewal delivered while no purchase is running is verified then finished', () async {
      final b = Backend(channel: 'apple_iap');
      final iap = FakeIap(b.log);
      final s = b.service(iap: iap);
      await s.handlePurchases([iap.details(PurchaseStatus.purchased)]);
      expect(b.log, ['verify:$jws', 'finish']);
      s.dispose();
    });

    test('restore purchases verifies restored transactions', () async {
      final b = Backend(channel: 'apple_iap');
      final iap = FakeIap(b.log);
      final s = b.service(iap: iap);
      final n = await s.restoreApple(window: const Duration(milliseconds: 20));
      expect(n, 1);
      expect(b.log, ['restore', 'verify:$jws']);
      s.dispose();
    });
  });

  test('looksLikeJws', () {
    expect(looksLikeJws(jws), isTrue);
    expect(looksLikeJws('MIIT0gYJKoZIhvcNAQcC+/='), isFalse);
    expect(looksLikeJws(''), isFalse);
  });
}
