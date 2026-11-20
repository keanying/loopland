// WGS-84 → GCJ-02 ("火星坐标"). The system GPS (geolocator) reports WGS-84,
// while the API and AMap use GCJ-02, so every recorded point is converted.
// Outside mainland China the offset is not applied.
import 'dart:math' as math;

import 'geo.dart';

const _a = 6378245.0;
const _ee = 0.00669342162296594323;

bool outOfChina(double lat, double lng) =>
    lng < 72.004 || lng > 137.8347 || lat < 0.8293 || lat > 55.8271;

double _tLat(double x, double y) {
  var r = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * math.sqrt(x.abs());
  r += (20.0 * math.sin(6.0 * x * math.pi) + 20.0 * math.sin(2.0 * x * math.pi)) * 2.0 / 3.0;
  r += (20.0 * math.sin(y * math.pi) + 40.0 * math.sin(y / 3.0 * math.pi)) * 2.0 / 3.0;
  r += (160.0 * math.sin(y / 12.0 * math.pi) + 320 * math.sin(y * math.pi / 30.0)) * 2.0 / 3.0;
  return r;
}

double _tLng(double x, double y) {
  var r = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * math.sqrt(x.abs());
  r += (20.0 * math.sin(6.0 * x * math.pi) + 20.0 * math.sin(2.0 * x * math.pi)) * 2.0 / 3.0;
  r += (20.0 * math.sin(x * math.pi) + 40.0 * math.sin(x / 3.0 * math.pi)) * 2.0 / 3.0;
  r += (150.0 * math.sin(x / 12.0 * math.pi) + 300.0 * math.sin(x / 30.0 * math.pi)) * 2.0 / 3.0;
  return r;
}

LatLng wgs84ToGcj02(double lat, double lng) {
  if (outOfChina(lat, lng)) return LatLng(lat, lng);
  var dLat = _tLat(lng - 105.0, lat - 35.0);
  var dLng = _tLng(lng - 105.0, lat - 35.0);
  final radLat = lat / 180.0 * math.pi;
  var magic = math.sin(radLat);
  magic = 1 - _ee * magic * magic;
  final sqrtMagic = math.sqrt(magic);
  dLat = (dLat * 180.0) / ((_a * (1 - _ee)) / (magic * sqrtMagic) * math.pi);
  dLng = (dLng * 180.0) / (_a / sqrtMagic * math.cos(radLat) * math.pi);
  return LatLng(lat + dLat, lng + dLng);
}
