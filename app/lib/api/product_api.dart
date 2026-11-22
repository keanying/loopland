// V2 batch 5「商户商品与开放平台」App endpoints (docs/api/v2-5-商户商品与开放平台.md):
// merchant products, product orders (pay / cancel / refund) and official
// promotions. Venue detail's `products` comes with `GET /v1/venues/{id}`
// (LocalApi).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import 'api_client.dart';
import 'community_common.dart';
import 'product_models.dart';

final productApiProvider = Provider<ProductApi>((ref) => ProductApi(ref.watch(apiClientProvider)));

/// The payment channel as product orders name it (`wechat | alipay | mock`);
/// the app's payment code uses `wechat_app` / `alipay_app`.
String productChannel(String channel) => switch (channel) {
      'wechat_app' => 'wechat',
      'alipay_app' => 'alipay',
      _ => channel,
    };

class ProductApi {
  ProductApi(this.c);
  final ApiClient c;

  /// `GET /v1/merchants/{id}/products` — the merchant page.
  Future<CursorPage<Product>> merchantProducts(int merchantId, {String? cursor}) =>
      getCursorPage(c, '/v1/merchants/$merchantId/products', Product.fromJson, cursor: cursor);

  /// With `my_bought_qty`. 404 `not_found` once off sale.
  Future<Product> product(int id) async => Product.fromJson(jm(await c.get('/v1/products/$id')));

  /// [channel] is the app's name (`wechat_app` …); sent as the contract's.
  /// Errors: 409 `sold_out` / `limit_reached` / `not_on_sale`, 400 `invalid_request`.
  Future<ProductOrderCreated> createOrder(int productId, {required int qty, required String channel}) async =>
      ProductOrderCreated.fromJson(jm(await c.post('/v1/products/$productId/orders', {
        'qty': qty,
        'channel': productChannel(channel),
      })));

  /// 「继续支付」: fresh payment parameters for a `pending` order.
  Future<ProductOrderCreated> repay(int orderId) async =>
      ProductOrderCreated.fromJson(jm(await c.post('/v1/product-orders/$orderId/pay')));

  /// Only unpaid orders.
  Future<ProductOrder> cancel(int orderId) async => ProductOrder.fromJson(jm(await c.post('/v1/product-orders/$orderId/cancel')));

  /// Refunds every unused coupon. 409 `not_refundable` / `nothing_to_refund`.
  Future<ProductOrder> refund(int orderId) async => ProductOrder.fromJson(jm(await c.post('/v1/product-orders/$orderId/refund')));

  Future<List<ProductOrder>> myOrders({String status = ''}) async => jl(
      jm(await c.get('/v1/me/product-orders', query: {if (status.isNotEmpty) 'status': status}))['items'], ProductOrder.fromJson);

  Future<ProductOrder> order(int id) async => ProductOrder.fromJson(jm(await c.get('/v1/product-orders/$id')));

  /// Running and upcoming promotions.
  Future<List<Promotion>> promotions() async => jl(jm(await c.get('/v1/promotions'))['items'], Promotion.fromJson);

  /// With `items` (the promotion's products at their promotion price).
  Future<Promotion> promotion(int id) async => Promotion.fromJson(jm(await c.get('/v1/promotions/$id')));
}
