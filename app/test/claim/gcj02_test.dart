import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/claim/gcj02.dart';
import 'package:loopland/claim/geo.dart';

void main() {
  test('WGS-84 → GCJ-02 shifts a few hundred metres inside China', () {
    const wgs = LatLng(31.2304, 121.4737);
    final gcj = wgs84ToGcj02(wgs.lat, wgs.lng);
    final d = haversine(wgs, gcj);
    expect(d, inInclusiveRange(100, 800));
    // GCJ-02 in Shanghai is north-east of WGS-84 by roughly (-0.002 lat, +0.0045 lng).
    expect(gcj.lng, greaterThan(wgs.lng));
  });

  test('known reference point (天安门)', () {
    // Widely published pair: WGS-84 (39.908722, 116.397499) ≈ GCJ-02 (39.910126, 116.403741).
    final g = wgs84ToGcj02(39.908722, 116.397499);
    expect(haversine(g, const LatLng(39.910126, 116.403741)), lessThan(5));
  });

  test('outside China is unchanged', () {
    final g = wgs84ToGcj02(48.8584, 2.2945);
    expect(g, const LatLng(48.8584, 2.2945));
  });
}
