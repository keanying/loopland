import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/product_api.dart';
import '../../api/product_models.dart';

final productProvider = FutureProvider.autoDispose.family<Product, int>((ref, id) => ref.watch(productApiProvider).product(id));

/// My product orders by status ('' = all).
final myProductOrdersProvider = FutureProvider.autoDispose
    .family<List<ProductOrder>, String>((ref, status) => ref.watch(productApiProvider).myOrders(status: status));

final productOrderProvider =
    FutureProvider.autoDispose.family<ProductOrder, int>((ref, id) => ref.watch(productApiProvider).order(id));

/// Running and upcoming official promotions (本地生活 banner, 官方活动 list).
final promotionsProvider = FutureProvider.autoDispose<List<Promotion>>((ref) => ref.watch(productApiProvider).promotions());

final promotionProvider =
    FutureProvider.autoDispose.family<Promotion, int>((ref, id) => ref.watch(productApiProvider).promotion(id));
