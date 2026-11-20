// Example payloads copied from docs/api/v1.md (App sections). Placeholders
// such as `{ User }` are substituted with the corresponding example; "..."
// timestamps are kept as-is where the parser is expected to tolerate them.
import 'dart:convert';

Map<String, dynamic> j(String s) => (jsonDecode(s) as Map).cast<String, dynamic>();

const userJson = r'''
{
  "id": 1,
  "nickname": "跑者1024",
  "avatar_url": null,
  "level": 2,
  "energy": 135,
  "energy_today": 50,
  "daily_energy_cap": 600,
  "phone_masked": "138****8000",
  "realname_verified": false,
  "is_adult": null,
  "status": "active",
  "muted_until": null,
  "delete_after": null,
  "consents": { "privacy_version": "2026-11", "location": true, "health": false },
  "settings": { "track_visibility": "crew", "hide_endpoints": true, "show_avatar_on_map": true, "personalized": true },
  "crew": { "id": 3, "name": "城西跑团" },
  "membership": { "active": true, "plan_code": "auto_month", "plan_name": "连续包月", "expires_at": "2026-12-20T10:00:00+08:00", "auto_renew": true, "next_charge_at": "2026-12-15T10:00:00+08:00", "channel": "wechat_app" },
  "stats": { "total_distance_m": 12345, "activity_count": 4, "territory_count": 3, "territory_area_m2": 50210, "week": { "count": 2, "distance_m": 10000, "duration_s": 3600, "energy": 100 } },
  "created_at": "2026-11-01T08:00:00+08:00"
}
''';

String authResultJson = '''
{
  "access_token": "acc", "refresh_token": "ref", "expires_in": 7200,
  "is_new": true,
  "need_bind_phone": false,
  "user": $userJson
}
''';

const configJson = r'''
{
  "version": "v3.12",
  "slots_per_territory": 6,
  "base_station_slots": 1,
  "daily_energy_cap": 600,
  "min_claim_area_m2": 500,
  "level_thresholds": [0, 200, 600, 1200, 2000, 3200],
  "energy": [{ "sport": "run", "name": "跑步", "unit": "km", "per": 1, "energy": 10 }, { "sport": "strength", "name": "力量", "unit": "min", "per": 10, "energy": 5 }],
  "buildings": [{ "key": "campfire", "name": "营火", "note": "基础", "cost": 80, "guard": 50, "daily_energy": 10, "unlock_level": 1, "station_slots": 0 }],
  "roles": [{ "key": "archer", "name": "弓箭手", "sport": "run", "threshold": 30, "unit": "km", "buff": "guard_pct", "buff_value": 5, "buff_text": "领地守卫 +5%" }],
  "companions": [{ "key": "gecko", "name": "闪电壁虎", "hatch_km": 10 }],
  "medals": [{ "key": "distance_100", "name": "百公里", "distance_km": 100 }],
  "bosses": [ ]
}
''';

const activityJson = r'''
{
  "id": 1, "sport": "run", "status": "settled",
  "started_at": "2026-11-20T19:00:00+08:00", "ended_at": "2026-11-20T19:30:00+08:00",
  "distance_m": 5370, "duration_s": 1800, "avg_pace_s_per_km": 335,
  "amount": 5.37, "energy_granted": 53, "claimed_area_m2": 5230.5,
  "track": { "type": "LineString", "coordinates": [[121.47, 31.23], [121.48, 31.24]] },
  "claims": [ { "territory_id": 101, "kind": "claim", "area_m2": 5230.5 } ]
}
''';

String activityResultJson = '''
{
  "activity": $activityJson,
  "settlement": {
    "status": "settled",
    "energy_raw": 53,
    "energy_granted": 53,
    "energy_capped": false,
    "claims": [ { "territory_id": 101, "kind": "claim", "area_m2": 5230.5 } ],
    "attacks": [ { "territory_id": 88, "owner": { "id": 7, "nickname": "小鹿" }, "captured": false, "guard_before": 120, "guard_after": 67, "area_m2": 900 } ],
    "recruits": [ { "role": "archer", "name": "弓箭手", "progress": 12.4, "threshold": 30, "unit": "km", "recruited": false } ],
    "eggs": [ { "key": "gecko", "name": "闪电壁虎", "progress_km": 3.6, "hatch_km": 10, "hatched": false } ],
    "medals": [ { "key": "distance_100", "name": "百公里" } ],
    "level_up": null,
    "flags": [ { "rule": "speed", "detail": "平均速度 24.3 km/h 超过跑步上限 20" } ]
  }
}
''';

const previewJson = r'''
{"loops":[{"ring":[{"lat":31.23,"lng":121.47},{"lat":31.231,"lng":121.47},{"lat":31.231,"lng":121.471},{"lat":31.23,"lng":121.47}],"area_m2":5000,"perimeter_m":300,"closed_at":4}],"total_area_m2":5000,"discarded":0,"hint":{"distance_m":120,"target":{"lat":31.23,"lng":121.47}},"distance_km":1.2,"raw_energy":12}
''';

const territorySummaryJson = r'''
{
  "id": 101,
  "name": "领地 #101",
  "relation": "mine",
  "owner": { "id": 1, "nickname": "跑者1024", "avatar_url": null },
  "crew": { "id": 3, "name": "城西跑团" },
  "geometry": { "type": "MultiPolygon", "coordinates": [[[[121.47, 31.23], [121.48, 31.23], [121.48, 31.24], [121.47, 31.23]]]] },
  "center": { "lat": 31.23, "lng": 121.47 },
  "area_m2": 5230.5,
  "guard": 120,
  "frozen": false
}
''';

const territoryJson = r'''
{
  "id": 101,
  "name": "领地 #101",
  "relation": "mine",
  "owner": { "id": 1, "nickname": "跑者1024", "avatar_url": null },
  "crew": null,
  "geometry": { "type": "MultiPolygon", "coordinates": [[[[121.47, 31.23], [121.48, 31.23], [121.48, 31.24], [121.47, 31.23]]]] },
  "center": { "lat": 31.23, "lng": 121.47 },
  "area_m2": 5230.5,
  "guard": 120,
  "frozen": false,
  "daily_energy": 25,
  "slots": [ { "slot": 0, "building": "campfire", "name": "营火" }, { "slot": 1, "building": null, "name": null } ],
  "station_slots": 1,
  "stationed": [ { "role": "archer", "name": "弓箭手", "buff_text": "领地守卫 +5%" } ],
  "captured_at": "2026-11-20T19:30:00+08:00",
  "events": [ { "kind": "capture", "actor": { "id": 2, "nickname": "小鹿" }, "created_at": "2026-11-20T19:30:00+08:00" } ]
}
''';

const codexJson = r'''
{
  "progress": { "roles": "2/8", "buildings": "3/8", "companions": "1/6", "medals": "0/3" },
  "roles": [ { "key": "archer", "name": "弓箭手", "sport": "run", "threshold": 30, "unit": "km", "progress": 12.4, "obtained": false, "obtained_at": null, "buff_text": "领地守卫 +5%", "stationed_at": null },
             { "key": "knight", "name": "骑士", "sport": "ride", "threshold": 80, "unit": "km", "progress": 80, "obtained": true, "obtained_at": "2026-11-10T08:00:00+08:00", "buff_text": "攻占速度 +8%", "stationed_at": 101 } ],
  "buildings": [ { "key": "campfire", "name": "营火", "unlock_level": 1, "unlocked": true, "cost": 80, "guard": 50, "daily_energy": 10 },
                 { "key": "tower", "name": "箭塔", "unlock_level": 5, "unlocked": false, "cost": 320, "guard": 300, "daily_energy": 10 } ],
  "companions": [ { "key": "gecko", "name": "闪电壁虎", "state": "egg", "progress_km": 3.6, "hatch_km": 10, "escort": false },
                  { "key": "frog", "name": "泡泡蛙", "state": "hatched", "progress_km": 10, "hatch_km": 10, "escort": true } ],
  "medals": [ { "key": "distance_100", "name": "百公里", "obtained": false, "obtained_at": null } ]
}
''';

const crewJson = r'''
{
  "id": 3, "name": "城西跑团", "avatar_url": null, "district": "徐汇区", "join_mode": "open",
  "leader": { "id": 1, "nickname": "跑者1024" },
  "member_count": 12, "territory_count": 30, "territory_area_m2": 1203300,
  "my_role": "leader",
  "week_rank": [ { "user": { "id": 1, "nickname": "跑者1024" }, "distance_m": 20000, "area_m2": 50000 } ]
}
''';

const planJson = r'''
{
  "code": "auto_month", "name": "连续包月", "period": "month",
  "auto_renew": true, "price_fen": 1800, "first_price_fen": 1500, "renew_price_fen": 1800,
  "seats": 1, "recommended": true, "apple_product_id": "com.loopland.member.auto_month",
  "entitlements": ["map_styles", "advanced_stats", "ai_coach_unlimited", "exclusive_skins", "hd_replay_export", "crew_tools"]
}
''';

const orderJson = r'''
{ "order_no": "LP20261120xxxx", "plan_code": "auto_month", "plan_name": "连续包月", "amount_fen": 1500, "channel": "wechat_app", "kind": "purchase", "status": "created", "created_at": "2026-11-20T19:30:00+08:00", "paid_at": null }
''';

const inboxJson = r'''
{"items":[{"id":1,"category":"territory","title":"领地被抢","body":"西岸草坪被「城西跑团」夺走","data":{"territory_id":101},"read":false,"created_at":"2026-11-20T19:30:00+08:00"}],"total":1,"unread":3}
''';
