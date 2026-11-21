// Example payloads from docs/api/v2-1-玩法.md. "..." timestamps and `{..}`
// placeholders are filled in with concrete values.

const gameplayV2Json = r'''
{
  "version": "v4",
  "boss": {
    "strike_cost": 100, "strike_damage": 40, "strike_cooldown_s": 30,
    "combo_window_s": 300, "combo_pct": 10, "combo_max_pct": 50,
    "damage": [
      { "sport": "run", "per": 1, "unit": "km", "damage": 100 },
      { "sport": "ride", "per": 1, "unit": "km", "damage": 100 },
      { "sport": "hike", "per": 1, "unit": "km", "damage": 100 },
      { "sport": "walk", "per": 1, "unit": "km", "damage": 100 },
      { "sport": "rope", "per": 100, "unit": "count", "damage": 30 },
      { "sport": "strength", "per": 10, "unit": "min", "damage": 30 },
      { "sport": "yoga", "per": 10, "unit": "min", "damage": 30 },
      { "sport": "hiit", "per": 10, "unit": "min", "damage": 30 }
    ],
    "default_hp": 10000, "radius_m": 1000, "duration_h": 48, "auto_spawn_max": 3,
    "engage_h": 6, "expire_refund_pct": 20, "top_extra_rolls": 3, "drop_energy": 200,
    "yield_penalty_pct": 50
  },
  "chest": { "energy_min": 20, "energy_max": 60, "radius_m": 50, "daily_spawn": 20, "duration_h": 24 },
  "defense": { "window_h": 24, "max_guard": 2000 },
  "season": {
    "tiers": [
      { "name": "青铜", "min_km2": 0 }, { "name": "白银", "min_km2": 0.5 }, { "name": "黄金", "min_km2": 3.6 },
      { "name": "铂金", "min_km2": 8 }, { "name": "钻石", "min_km2": 15 }
    ]
  },
  "season_tasks": [
    { "key": "weekly_runs", "name": "本周运动 3 次", "type": "weekly_count", "target": 3, "reward_energy": 60 },
    { "key": "weekly_area", "name": "本周圈地 2 万 m²", "type": "weekly_area_m2", "target": 20000, "reward_energy": 80 },
    { "key": "weekly_distance", "name": "本周跑够 15 km", "type": "weekly_distance_km", "target": 15, "reward_energy": 80 },
    { "key": "new_sport", "name": "尝试一项本赛季没做过的运动", "type": "new_sport", "target": 1, "reward_energy": 50 }
  ],
  "medals": [
    { "key": "distance_100", "name": "百公里", "type": "distance_km", "target": 100, "distance_km": 100 },
    { "key": "guardian", "name": "守护者", "type": "defends", "target": 5 },
    { "key": "ten_loops", "name": "一夜十圈", "type": "loops_single", "target": 10 },
    { "key": "monster_hunter", "name": "怪兽猎人", "type": "boss_defeats", "target": 5 },
    { "key": "treasure", "name": "寻宝人", "type": "chests", "target": 20 },
    { "key": "orienteer", "name": "城市定向家", "type": "routes", "target": 3 }
  ],
  "companion": { "feed_cost": 50, "feed_exp": 10, "exp_per_100m": 1, "exp_per_level": 100 },
  "relay": { "default_legs": 6, "leg_km": 3, "duration_h": 168, "reward_energy": 100 },
  "buildings": [ { "key": "tower", "name": "箭塔", "cost": 320, "guard": 300, "daily_energy": 10, "unlock_level": 5, "blueprint_bypass_level": true } ]
}
''';

const settlementV2Json = r'''
{
  "status": "settled", "energy_raw": 53, "energy_granted": 53, "energy_capped": false,
  "claims": [], "attacks": [], "recruits": [], "eggs": [], "medals": [], "level_up": null, "flags": [],
  "boss_damage": [ { "boss_id": 3, "name": "沙发怪", "damage": 530, "defeated": false } ],
  "chests": [ { "chest_id": 9, "energy": 40 } ],
  "defended": [ { "territory_id": 12, "guard_before": 20, "guard_after": 73 } ],
  "routes": [ { "route_id": 2, "name": "城南线", "reached": ["拱桥", "老街口"], "completed": false } ],
  "campaigns": [ { "campaign_id": 5, "title": "夜跑专场", "reward_energy": 100 } ],
  "tasks": [ { "key": "weekly_runs", "name": "本周运动 3 次", "progress": 3, "target": 3, "completed": true, "reward_energy": 60 } ],
  "companion": { "key": "gecko", "exp": 34, "level": 2, "level_up": false },
  "relay": { "relay_id": 4, "leg": 3, "legs": 6, "completed": false }
}
''';

const mapObjectsJson = r'''
{
  "bosses": [ { "id": 3, "kind": "sofa", "name": "沙发怪", "level": 12, "center": {"lat": 31.2313, "lng": 121.4758}, "radius_m": 1000,
                "hp": 3800, "hp_max": 10000, "expires_at": "2026-11-22T20:00:00+08:00", "location_name": "滨江公园一带" } ],
  "chests": [ { "id": 9, "center": {"lat": 31.2290, "lng": 121.4720}, "radius_m": 50, "expires_at": "2026-11-22T06:00:00+08:00" } ],
  "checkpoints": [ { "route_id": 2, "index": 2, "name": "滨江码头", "center": {"lat": 31.2330, "lng": 121.4700}, "radius_m": 60, "state": "next" } ]
}
''';

const bossJson = r'''
{
  "id": 3, "kind": "sofa", "name": "沙发怪", "level": 12, "description": "它代表「懒得动」。周末出没在滨江公园一带，让附近领地的能量产出减半。",
  "location_name": "滨江公园一带", "center": {"lat": 31.2313, "lng": 121.4758}, "radius_m": 1000,
  "hp": 3800, "hp_max": 10000, "status": "active",
  "spawned_at": "2026-11-20T20:00:00+08:00", "expires_at": "2026-11-22T20:00:00+08:00", "defeated_at": null,
  "occupied_territories": 3, "effect_text": "范围内领地每日能量产出减半",
  "damage_rules": [ { "sport": "run", "label": "跑步", "per": 1, "unit": "km", "damage": 100 },
                    { "sport": "ride", "label": "骑行", "per": 1, "unit": "km", "damage": 100 },
                    { "sport": "rope", "label": "跳绳", "per": 100, "unit": "count", "damage": 30 },
                    { "sport": "yoga", "label": "瑜伽", "per": 10, "unit": "min", "damage": 30 } ],
  "strike": { "cost": 100, "damage": 40, "cooldown_s": 30, "available_in_s": 0 },
  "participants": 23,
  "rank": [ { "rank": 1, "user": { "id": 7, "nickname": "小鹿", "avatar_url": null }, "damage": 1200 },
            { "rank": 2, "user": { "id": 1, "nickname": "跑者1024", "avatar_url": null }, "damage": 530 } ],
  "me": { "damage": 530, "rank": 2, "engaged_until": null },
  "drops": [ { "item": "banner", "kind": "role", "name": "旗手卡", "percent": 35 },
             { "item": "tent", "kind": "blueprint", "name": "营帐图纸", "percent": 10 },
             { "item": "firetail", "kind": "egg", "name": "火尾蜥蛋", "percent": 5 },
             { "item": "energy", "kind": "energy", "name": "200 能量", "percent": 50 } ],
  "my_rewards": []
}
''';

const strikeJson = r'''{"damage":44,"combo_pct":10,"energy":1180,"boss":{"id":3,"hp":3756,"status":"active"}}''';

const seasonJson = r'''
{
  "season": { "id": 3, "name": "S3 冬季赛", "starts_at": "2026-11-01T00:00:00+08:00", "ends_at": "2026-12-31T23:59:59+08:00", "days_left": 42 },
  "me": { "area_m2": 2360000, "tier": { "name": "白银", "level": "II" }, "next": { "name": "黄金", "level": "I", "need_m2": 1240000 }, "rank": 128 },
  "crew": { "id": 3, "name": "城西跑团", "area_m2": 12000000, "rank": 4 },
  "tiers": [ { "name": "青铜", "min_m2": 0 }, { "name": "白银", "min_m2": 500000 }, { "name": "黄金", "min_m2": 3600000 },
             { "name": "铂金", "min_m2": 8000000 }, { "name": "钻石", "min_m2": 15000000 } ],
  "top": [ { "rank": 1, "user": { "id": 7, "nickname": "小鹿" }, "area_m2": 9000000 } ],
  "crew_top": [ { "rank": 1, "crew": { "id": 1, "name": "滨江夜跑团" }, "area_m2": 50000000 } ],
  "tasks": [ { "key": "weekly_runs", "name": "本周运动 3 次", "type": "weekly_count", "progress": 2, "target": 3, "reward_energy": 60, "completed": false },
             { "key": "weekly_area", "name": "本周圈地 2 万 m²", "type": "weekly_area_m2", "progress": 20000, "target": 20000, "reward_energy": 80, "completed": true } ],
  "medals": [ { "key": "guardian", "name": "守护者", "type": "defends", "progress": 3, "target": 5, "obtained": false, "obtained_at": null },
              { "key": "ten_loops", "name": "一夜十圈", "type": "loops_single", "progress": 10, "target": 10, "obtained": true, "obtained_at": "2026-11-08T22:00:00+08:00" } ]
}
''';

const leagueJson = r'''
{ "week_start": "2026-11-16", "district": "徐汇区",
  "standings": [ { "rank": 1, "crew": { "id": 3, "name": "城西跑团" }, "score_m2": 820000, "active_members": 9 },
                 { "rank": 2, "crew": { "id": 5, "name": "城南晨跑" }, "score_m2": 410000, "active_members": 6 } ],
  "my_crew": { "rank": 1, "score_m2": 820000 },
  "last_week": [ { "rank": 1, "crew": { "id": 5, "name": "城南晨跑" }, "score_m2": 900000 } ] }
''';

const campaignJson = r'''
{ "id": 5, "title": "夜跑专场", "type": "night_run", "description": "晚上出来跑一圈。",
  "rules": { "min_distance_km": 5, "max_pace_s_per_km": 360, "start_hour_from": 19, "start_hour_to": 23 },
  "starts_at": "2026-11-01T00:00:00+08:00", "ends_at": "2099-11-30T00:00:00+08:00", "reward_energy": 100, "reward_medal": { "key": "night_owl", "name": "夜行者" },
  "completed": false, "participants": 120 }
''';

const routeJson = r'''
{ "id": 2, "name": "城南线", "description": "沿着老城南走一圈。", "reward_energy": 150, "starts_at": "2026-11-01T00:00:00+08:00", "ends_at": "2026-12-31T00:00:00+08:00",
  "checkpoints": [ { "index": 1, "name": "老街口", "center": {"lat": 31.2320, "lng": 121.4710}, "radius_m": 60, "state": "done" },
                   { "index": 0, "name": "拱桥", "center": {"lat": 31.2300, "lng": 121.4700}, "radius_m": 60, "state": "done" },
                   { "index": 2, "name": "滨江码头", "center": {"lat": 31.2330, "lng": 121.4740}, "radius_m": 60, "state": "next" },
                   { "index": 3, "name": "城南体育场", "center": {"lat": 31.2290, "lng": 121.4770}, "radius_m": 60, "state": "todo" } ],
  "completed": false, "completed_at": null }
''';

const codexV2Json = r'''
{
  "progress": { "roles": "0/1", "buildings": "0/1", "companions": "1/1", "medals": "0/0", "monsters": "2/4" },
  "roles": [], "medals": [],
  "buildings": [ { "key": "tower", "name": "箭塔", "unlock_level": 5, "unlocked": false, "cost": 320, "guard": 300, "daily_energy": 10, "blueprint": true } ],
  "companions": [ { "key": "gecko", "name": "闪电壁虎", "state": "hatched", "progress_km": 10, "hatch_km": 10, "escort": true,
                    "level": 4, "exp": 362, "exp_to_next": 38, "meters": 1326 } ],
  "monsters": [ { "key": "sofa", "name": "沙发怪", "strikes": 12, "defeats": 2, "best_rank": 3, "seen": true },
                { "key": "bat", "name": "熬夜蝠", "strikes": 1, "defeats": 0, "best_rank": null, "seen": true },
                { "key": "smog", "name": "雾霾怪", "strikes": 0, "defeats": 0, "best_rank": null, "seen": false },
                { "key": "sugar", "name": "糖分怪", "strikes": 0, "defeats": 0, "best_rank": null, "seen": false } ]
}
''';

const relayJson = r'''
{ "id": 4, "legs": 6, "leg_km": 3, "status": "running", "started_at": "2026-11-20T08:00:00+08:00", "expires_at": "2099-11-27T08:00:00+08:00",
  "runs": [ { "leg": 1, "user": { "id": 7, "nickname": "小鹿" }, "activity_id": 88, "distance_m": 3200, "at": "2026-11-20T19:00:00+08:00" },
            { "leg": 2, "user": { "id": 1, "nickname": "跑者1024" }, "activity_id": 90, "distance_m": 4100, "at": "2026-11-21T07:00:00+08:00" } ] }
''';

const territoryDefenseJson = r'''{"deadline":"2099-11-21T20:00:00+08:00","attacked_by":{"id":7,"nickname":"小鹿"}}''';
