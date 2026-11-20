import 'package:intl/intl.dart';

/// Display helpers. Units follow the API: metres, m², seconds, 分.
class Fmt {
  Fmt._();

  static String km(num metres, {int digits = 2}) =>
      (metres / 1000).toStringAsFixed(digits);

  static String distance(num metres) =>
      metres < 1000 ? '${metres.round()} m' : '${km(metres)} km';

  /// Area: m² below 0.01 km², otherwise km².
  static String area(num m2) {
    if (m2 < 10000) return '${m2.round()} m²';
    return '${(m2 / 1e6).toStringAsFixed(2)} km²';
  }

  /// 5'35" style pace from seconds per km.
  static String pace(num? secPerKm) {
    if (secPerKm == null || secPerKm <= 0 || secPerKm.isInfinite || secPerKm.isNaN) {
      return '--\'--"';
    }
    final s = secPerKm.round();
    if (s >= 60 * 60) return '--\'--"';
    return "${s ~/ 60}'${(s % 60).toString().padLeft(2, '0')}\"";
  }

  static String duration(num seconds) {
    final s = seconds.round();
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
  }

  static String minutes(num seconds) => '${(seconds / 60).round()} 分钟';

  /// ¥15 / ¥15.90 from 分.
  static String yuan(int fen) {
    if (fen % 100 == 0) return '¥${fen ~/ 100}';
    return '¥${(fen / 100).toStringAsFixed(2)}';
  }

  static String date(DateTime? t) =>
      t == null ? '-' : DateFormat('yyyy-MM-dd').format(t.toLocal());

  static String dateTime(DateTime? t) =>
      t == null ? '-' : DateFormat('MM-dd HH:mm').format(t.toLocal());

  static String relative(DateTime? t, {DateTime? now}) {
    if (t == null) return '';
    final d = (now ?? DateTime.now()).difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    if (d.inDays < 7) return '${d.inDays} 天前';
    return date(t);
  }

  static String thousands(num v) => NumberFormat.decimalPattern('en').format(v);

  static String unit(String unit) => switch (unit) {
        'km' => 'km',
        'm' => 'm',
        'min' => '分钟',
        'count' => '次',
        'checkin' => '次签到',
        _ => unit,
      };

  /// Progress value for a unit; keeps decimals for km.
  static String amount(num v, String unit) =>
      unit == 'km' ? v.toStringAsFixed(1) : v.round().toString();
}

/// Chinese sport names (API `sport` values).
const sportNames = {
  'run': '跑步',
  'ride': '骑行',
  'hike': '徒步',
  'walk': '健走',
  'strength': '力量',
  'yoga': '瑜伽',
  'rope': '跳绳',
  'hiit': 'HIIT',
  'rally': '集结跑',
  'swim': '游泳',
  'venue': '场馆签到',
};

const gpsSports = ['run', 'ride', 'hike', 'walk'];
const homeSports = ['strength', 'yoga', 'rope', 'hiit'];

String sportName(String s) => sportNames[s] ?? s;
