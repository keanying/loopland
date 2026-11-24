import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:tobias/tobias.dart';

import '../api/errors.dart';
import '../api/loopland_api.dart';
import '../api/models.dart';
import '../auth/social_login.dart';
import '../core/features.dart';
import '../core/providers.dart';
import '../core/sdk_config.dart';
import '../audio/audio.dart';

final paymentServiceProvider = Provider<PaymentService>((ref) {
  final s = PaymentService(ref.watch(apiProvider), onPaid: () {
    ref.read(audioProvider)
      ..play(Sounds.payOk)
      ..haptic(HapticKind.medium);
  });
  ref.onDispose(s.dispose);
  return s;
});

const channelNames = {
  'wechat_app': '微信支付',
  'alipay_app': '支付宝',
  'apple_iap': 'Apple 内购',
  'mock': '模拟支付（开发）',
};

/// WeChat Pay / Alipay SDK calls (seam for tests).
abstract class PayGateways {
  /// Throws a friendly [ApiException] when WeChat is missing / not configured.
  Future<void> ensureWechatReady();

  /// WeChat Pay errCode: 0 success, -2 cancelled, else failed.
  Future<int> wechatPay(Map<String, dynamic> payParams);

  /// Alipay result map (`resultStatus`, `memo`, `result`).
  Future<Map<Object?, Object?>> alipay(String orderString);
}

class SdkPayGateways implements PayGateways {
  @override
  Future<void> ensureWechatReady() => WeChat.ensureReady();
  @override
  Future<int> wechatPay(Map<String, dynamic> payParams) => WeChat.pay(payParams);
  @override
  Future<Map<Object?, Object?>> alipay(String orderString) async {
    final c = SdkConfig.current;
    return Tobias().pay(orderString,
        universalLink: c.isIOS && c.alipayUniversalLink.isNotEmpty ? c.alipayUniversalLink : null);
  }
}

/// StoreKit (seam for tests). With in_app_purchase_storekit ≥ 0.4 StoreKit 2
/// is the default, and `verificationData.serverVerificationData` is the
/// transaction's `jwsRepresentation`.
abstract class IapGateway {
  Stream<List<PurchaseDetails>> get purchaseStream;
  Future<bool> isAvailable();
  Future<ProductDetails?> product(String id);

  /// `appAccountToken` → StoreKit 2 `Product.PurchaseOption.appAccountToken`.
  Future<void> buy(ProductDetails product, String appAccountToken);

  /// `Transaction.finish()`.
  Future<void> finish(PurchaseDetails p);
  Future<void> restore();
}

class StoreKitIapGateway implements IapGateway {
  InAppPurchase get _iap => InAppPurchase.instance;
  @override
  Stream<List<PurchaseDetails>> get purchaseStream => _iap.purchaseStream;
  @override
  Future<bool> isAvailable() => _iap.isAvailable();
  @override
  Future<ProductDetails?> product(String id) async {
    final r = await _iap.queryProductDetails({id});
    return r.productDetails.isEmpty ? null : r.productDetails.first;
  }

  @override
  Future<void> buy(ProductDetails product, String appAccountToken) =>
      _iap.buyNonConsumable(purchaseParam: PurchaseParam(productDetails: product, applicationUserName: appAccountToken));
  @override
  Future<void> finish(PurchaseDetails p) => _iap.completePurchase(p);
  @override
  Future<void> restore() => _iap.restorePurchases();
}

/// A StoreKit 2 JWS has three base64url segments; the legacy receipt has none.
bool looksLikeJws(String s) => RegExp(r'^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$').hasMatch(s);

/// Creates an order, hands it to the channel SDK and then always polls
/// `GET /v1/orders/{no}` — the server's payment callback is the source of
/// truth; the SDK's own result only decides how long to wait.
class PaymentService {
  PaymentService(
    this.api, {
    PayGateways? gateways,
    IapGateway? iap,
    this.pollInterval = const Duration(seconds: 2),
    this.pollTimeout = const Duration(seconds: 90),
    this.unpaidCheckTimeout = const Duration(seconds: 6),
    this.onPaid,
  })  : gateways = gateways ?? SdkPayGateways(),
        iap = iap ?? StoreKitIapGateway();

  final LooplandApi api;
  final PayGateways gateways;
  final IapGateway iap;
  final Duration pollInterval;
  final Duration pollTimeout;

  /// How long to keep checking when the SDK reported cancel/failure (the
  /// callback may still arrive, e.g. the user paid and then backed out).
  final Duration unpaidCheckTimeout;

  /// An order of [payOrder] came back paid (支付成功的「叮」).
  final void Function()? onPaid;

  StreamSubscription<List<PurchaseDetails>>? _iapSub;
  Completer<void>? _applePending;
  String? _applePendingProduct;

  /// Restore window: counts transactions verified while restoring.
  int? _restored;

  /// Channels to offer: local checks ∩ `/v1/config/features`.
  List<String> channels([ServerFeatures? features]) => payChannels(features, SdkConfig.current);

  /// Starts listening to StoreKit so renewals / interrupted purchases are
  /// verified with the server even when no purchase screen is open.
  void startAppleListener() {
    if (_iapSub != null) return;
    _iapSub = iap.purchaseStream.listen((l) => handlePurchases(l), onError: (_) {});
  }

  /// Verifies each transaction with the server and finishes it only after
  /// `POST /v1/iap/apple` returned 200. A failed verification leaves the
  /// transaction unfinished so StoreKit delivers it again on next launch.
  Future<void> handlePurchases(List<PurchaseDetails> list) async {
    for (final p in list) {
      final mine = _applePending != null && p.productID == _applePendingProduct;
      void ok() {
        if (mine && !_applePending!.isCompleted) _applePending!.complete();
      }

      void err(Object e) {
        if (mine && !_applePending!.isCompleted) _applePending!.completeError(e);
      }

      switch (p.status) {
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          final jws = p.verificationData.serverVerificationData;
          if (!looksLikeJws(jws)) {
            developer.log('StoreKit returned no JWS (legacy receipt?) for ${p.productID}', name: 'loopland.iap');
            err(ApiException(status: 0, code: 'provider_error', message: '无法获取 App Store 交易凭证，请升级到 iOS 15 或以上'));
            continue;
          }
          try {
            await api.verifyApple(jws);
          } catch (e) {
            err(e); // not finished → redelivered later
            continue;
          }
          if (p.pendingCompletePurchase) {
            try {
              await iap.finish(p);
            } catch (_) {}
          }
          if (_restored != null) _restored = _restored! + 1;
          ok();
        case PurchaseStatus.error:
          if (p.pendingCompletePurchase) await iap.finish(p);
          err(ApiException(status: 0, code: 'provider_error', message: p.error?.message ?? 'Apple 支付失败'));
        case PurchaseStatus.canceled:
          if (p.pendingCompletePurchase) await iap.finish(p);
          err(ApiException(status: 0, code: 'cancelled'));
        case PurchaseStatus.pending:
          break; // Ask to Buy etc.; the listener verifies it when it completes.
      }
    }
  }

  /// Channels for physical services (订场 / 赛事报名费): WeChat Pay and Alipay
  /// on both platforms (no IAP for offline services), plus `mock` in dev.
  List<String> serviceChannels([ServerFeatures? features]) => servicePayChannels(features, SdkConfig.current);

  Future<Order> purchase(Plan plan, String channel) async {
    // Check before creating an order the user cannot pay.
    if (channel == 'wechat_app') await gateways.ensureWechatReady();
    final r = await api.createOrder(plan.code, channel);
    if (channel == 'apple_iap') {
      final p = r.payParams;
      await _apple('${p['product_id'] ?? plan.appleProductId}', '${p['app_account_token']}');
      return pollOrder(r.order.orderNo);
    }
    return payOrder(r.order.orderNo, channel, r.payParams);
  }

  /// Pays an order another endpoint created (`POST /v1/bookings`, paid race
  /// signup): hands [payParams] to the channel SDK, then polls the order.
  /// Call [ensureChannelReady] before creating the order. Throws `cancelled`
  /// when the user backed out and the server also says unpaid.
  Future<Order> payOrder(String orderNo, String channel, Map<String, dynamic> payParams) async {
    final o = await _payOrder(orderNo, channel, payParams);
    if (o.isPaid) onPaid?.call();
    return o;
  }

  Future<Order> _payOrder(String orderNo, String channel, Map<String, dynamic> payParams) async {
    final no = orderNo;
    final p = payParams;
    switch (channel) {
      case 'mock':
        await api.devPay(no);
        return pollOrder(no);
      case 'wechat_app':
        int code;
        try {
          code = await gateways.wechatPay(p);
        } catch (e) {
          return _afterSdk(no, paidPerSdk: false, error: ApiException.from(e));
        }
        return _afterSdk(no,
            paidPerSdk: code == 0,
            error: code == -2
                ? ApiException(status: 0, code: 'cancelled', message: '支付已取消')
                : ApiException(status: 0, code: 'provider_error', message: '微信支付未完成（$code）'));
      case 'alipay_app':
        Map<Object?, Object?> res;
        try {
          res = await gateways.alipay('${p['order_string'] ?? ''}');
        } catch (e) {
          return _afterSdk(no, paidPerSdk: false, error: ApiException.from(e));
        }
        final status = '${res['resultStatus']}';
        // 9000 成功 · 8000 处理中 · 6004 结果未知 → wait for the callback.
        final maybePaid = status == '9000' || status == '8000' || status == '6004';
        return _afterSdk(no,
            paidPerSdk: maybePaid,
            error: status == '6001'
                ? ApiException(status: 0, code: 'cancelled', message: '支付已取消')
                : ApiException(status: 0, code: 'provider_error', message: '${res['memo'] ?? '支付宝支付失败'}'));
      default:
        throw ApiException(status: 0, code: 'channel_not_allowed');
    }
  }

  /// Hands [payParams] to the channel SDK without polling an order (for a
  /// response that carries no order number; the caller polls its own
  /// resource). Returns whether the SDK reported success or "processing";
  /// throws `cancelled` when the user backed out.
  Future<bool> sdkPay(String channel, Map<String, dynamic> payParams) async {
    switch (channel) {
      case 'wechat_app':
        final code = await gateways.wechatPay(payParams);
        if (code == -2) throw ApiException(status: 0, code: 'cancelled', message: '支付已取消');
        return code == 0;
      case 'alipay_app':
        final res = await gateways.alipay('${payParams['order_string'] ?? ''}');
        final status = '${res['resultStatus']}';
        if (status == '6001') throw ApiException(status: 0, code: 'cancelled', message: '支付已取消');
        return status == '9000' || status == '8000' || status == '6004';
      default:
        throw ApiException(status: 0, code: 'channel_not_allowed', message: '缺少订单号，无法使用${channelNames[channel] ?? channel}');
    }
  }

  /// Checks the channel can be used before an order is created (WeChat
  /// installed / configured).
  Future<void> ensureChannelReady(String channel) async {
    if (channel == 'wechat_app') await gateways.ensureWechatReady();
  }

  /// After the SDK returned: poll the order. If the SDK said "not paid" the
  /// server still gets the last word; only if it also says unpaid is
  /// [error] thrown.
  Future<Order> _afterSdk(String no, {required bool paidPerSdk, required ApiException error}) async {
    if (paidPerSdk) return pollOrder(no);
    final o = await pollOrder(no, timeout: unpaidCheckTimeout);
    if (o.isPaid) return o;
    throw error;
  }

  Future<void> _apple(String productId, String appAccountToken) async {
    if (!await iap.isAvailable()) {
      throw ApiException(status: 0, code: 'provider_error', message: 'App Store 暂不可用');
    }
    final product = await iap.product(productId);
    if (product == null) throw ApiException(status: 0, code: 'plan_off_sale', message: '未找到商品 $productId');
    startAppleListener();
    _applePending = Completer<void>();
    _applePendingProduct = productId;
    try {
      // applicationUserName → StoreKit appAccountToken, which the server uses
      // to match the transaction to this order.
      await iap.buy(product, appAccountToken);
      await _applePending!.future.timeout(const Duration(minutes: 10));
    } finally {
      _applePending = null;
      _applePendingProduct = null;
    }
  }

  /// 恢复购买: StoreKit re-delivers the user's transactions as `restored`;
  /// each one is verified with the server. Returns how many were verified
  /// within [window].
  Future<int> restoreApple({Duration window = const Duration(seconds: 6)}) async {
    if (!await iap.isAvailable()) {
      throw ApiException(status: 0, code: 'provider_error', message: 'App Store 暂不可用');
    }
    startAppleListener();
    _restored = 0;
    try {
      await iap.restore();
      await Future<void>.delayed(window);
      return _restored ?? 0;
    } finally {
      _restored = null;
    }
  }

  /// Polls `GET /v1/orders/{no}` until it leaves `created` or [timeout].
  Future<Order> pollOrder(String orderNo, {Duration? timeout}) async {
    final deadline = DateTime.now().add(timeout ?? pollTimeout);
    while (true) {
      final o = await api.order(orderNo);
      if (o.isFinal) return o;
      if (DateTime.now().isAfter(deadline)) return o;
      await Future<void>.delayed(pollInterval);
    }
  }

  void dispose() => _iapSub?.cancel();
}
