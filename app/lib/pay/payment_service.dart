import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:tobias/tobias.dart';

import '../api/errors.dart';
import '../api/loopland_api.dart';
import '../api/models.dart';
import '../auth/social_login.dart';
import '../core/env.dart';
import '../core/providers.dart';

final paymentServiceProvider = Provider<PaymentService>((ref) {
  final s = PaymentService(ref.watch(apiProvider));
  ref.onDispose(s.dispose);
  return s;
});

const channelNames = {
  'wechat_app': '微信支付',
  'alipay_app': '支付宝',
  'apple_iap': 'Apple 内购',
  'mock': '模拟支付（开发）',
};

/// Creates an order, hands it to the channel SDK and polls the order until
/// the server has seen the payment callback (the server is the source of
/// truth — a "success" from the SDK alone does not grant membership).
class PaymentService {
  PaymentService(this.api, {this.pollInterval = const Duration(seconds: 2), this.pollTimeout = const Duration(seconds: 90)});

  final LooplandApi api;
  final Duration pollInterval;
  final Duration pollTimeout;
  StreamSubscription<List<PurchaseDetails>>? _iapSub;
  Completer<void>? _applePending;
  String? _applePendingProduct;

  /// iOS may only use Apple IAP (`X-Platform: ios` → other channels 400).
  List<String> channels() => [
        if (Env.isIOS) 'apple_iap' else ...['wechat_app', 'alipay_app'],
        if (Env.isDev) 'mock',
      ];

  /// Starts listening to StoreKit so renewals / interrupted purchases are
  /// verified with the server even when no purchase screen is open.
  void startAppleListener() {
    if (!Env.isIOS || _iapSub != null) return;
    _iapSub = InAppPurchase.instance.purchaseStream.listen(_onPurchases, onError: (_) {});
  }

  Future<void> _onPurchases(List<PurchaseDetails> list) async {
    for (final p in list) {
      final mine = _applePending != null && p.productID == _applePendingProduct;
      switch (p.status) {
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          try {
            await api.verifyApple(p.verificationData.serverVerificationData);
            if (p.pendingCompletePurchase) await InAppPurchase.instance.completePurchase(p);
            if (mine && !_applePending!.isCompleted) _applePending!.complete();
          } catch (e) {
            if (mine && !_applePending!.isCompleted) _applePending!.completeError(e);
          }
        case PurchaseStatus.error:
          if (p.pendingCompletePurchase) await InAppPurchase.instance.completePurchase(p);
          if (mine && !_applePending!.isCompleted) {
            _applePending!.completeError(ApiException(status: 0, code: 'provider_error', message: p.error?.message ?? 'Apple 支付失败'));
          }
        case PurchaseStatus.canceled:
          if (p.pendingCompletePurchase) await InAppPurchase.instance.completePurchase(p);
          if (mine && !_applePending!.isCompleted) _applePending!.completeError(ApiException(status: 0, code: 'cancelled'));
        case PurchaseStatus.pending:
          break;
      }
    }
  }

  Future<Order> purchase(Plan plan, String channel) async {
    final r = await api.createOrder(plan.code, channel);
    final no = r.order.orderNo;
    final p = r.payParams;
    switch (channel) {
      case 'mock':
        await api.devPay(no);
      case 'wechat_app':
        final ok = await WeChat.pay(p);
        if (!ok) throw ApiException(status: 0, code: 'cancelled', message: '支付未完成');
      case 'alipay_app':
        final res = await Tobias().pay('${p['order_string']}');
        final status = '${res['resultStatus']}';
        if (status == '6001') throw ApiException(status: 0, code: 'cancelled', message: '支付已取消');
        if (status != '9000' && status != '8000' && status != '6004') {
          throw ApiException(status: 0, code: 'provider_error', message: '${res['memo'] ?? '支付宝支付失败'}');
        }
      case 'apple_iap':
        await _apple('${p['product_id'] ?? plan.appleProductId}', '${p['app_account_token']}');
      default:
        throw ApiException(status: 0, code: 'channel_not_allowed');
    }
    return pollOrder(no);
  }

  Future<void> _apple(String productId, String appAccountToken) async {
    final iap = InAppPurchase.instance;
    if (!await iap.isAvailable()) {
      throw ApiException(status: 0, code: 'provider_error', message: 'App Store 暂不可用');
    }
    final resp = await iap.queryProductDetails({productId});
    if (resp.productDetails.isEmpty) {
      throw ApiException(status: 0, code: 'plan_off_sale', message: '未找到商品 $productId');
    }
    startAppleListener();
    _applePending = Completer<void>();
    _applePendingProduct = productId;
    try {
      // applicationUserName → StoreKit appAccountToken, which the server uses
      // to match the transaction to this order.
      await iap.buyNonConsumable(
          purchaseParam: PurchaseParam(productDetails: resp.productDetails.first, applicationUserName: appAccountToken));
      await _applePending!.future.timeout(const Duration(minutes: 10));
    } finally {
      _applePending = null;
      _applePendingProduct = null;
    }
  }

  /// Polls `GET /v1/orders/{no}` until it leaves `created`.
  Future<Order> pollOrder(String orderNo) async {
    final deadline = DateTime.now().add(pollTimeout);
    while (true) {
      final o = await api.order(orderNo);
      if (o.isFinal) return o;
      if (DateTime.now().isAfter(deadline)) return o;
      await Future<void>.delayed(pollInterval);
    }
  }

  void dispose() => _iapSub?.cancel();
}
