// 声音素材目录：每个声音的编号 → 素材文件（含 _1/_2/_3 变体）、所属通道、
// 语音的台词（缺素材时用系统语音合成读出）和单个文件的音量补偿。
// 素材与台词见 docs/音频素材清单.md；新增声音：放好文件，在这里加一项。

/// The three user-facing channels (设置 → 声音), each with its own switch and
/// volume.
enum SoundChannel {
  /// 语音播报（圈圈的声音 + 系统语音合成）.
  voice('语音播报'),

  /// 音效.
  sfx('音效'),

  /// 角色声音（怪兽、伙伴、角色卡的叫声）.
  character('角色声音');

  const SoundChannel(this.label);
  final String label;
}

/// One sound id of the catalogue.
class Sound {
  const Sound._(
    this.id,
    this.channel,
    this.dir, {
    this.variants = 1,
    this.numbered = false,
    this.text = '',
    this.texts = const [],
    this.gainsDb = const {},
  });

  /// Voice line in `voice/<dir>/`; [text] is read by TTS when the file is
  /// missing. Lines with variants give one text per variant in [texts].
  const Sound.voice(String id, String dir, String text, {int variants = 1, List<String>? texts})
    : this._(
        id,
        SoundChannel.voice,
        'voice/$dir',
        variants: variants,
        numbered: variants > 1,
        text: text,
        texts: texts ?? const [],
      );

  /// Sound effect in `sfx/`.
  const Sound.sfx(String id, {int variants = 1, Map<int, double> gainsDb = const {}})
    : this._(id, SoundChannel.sfx, 'sfx', variants: variants, numbered: variants > 1, gainsDb: gainsDb);

  /// Character sound in `char/`. Monster / companion sounds are always
  /// numbered (`_1`…), role cards never are.
  const Sound.char(String id, {int variants = 1, bool numbered = true, Map<int, double> gainsDb = const {}})
    : this._(id, SoundChannel.character, 'char', variants: variants, numbered: numbered, gainsDb: gainsDb);

  final String id;
  final SoundChannel channel;

  /// Folder under `assets/audio/`.
  final String dir;
  final int variants;

  /// Files are `<id>_1 … <id>_n` (else just `<id>`).
  final bool numbered;

  /// The line (voice only).
  final String text;

  /// Per-variant lines (voice with variants only).
  final List<String> texts;

  /// Per-variant gain in dB (1-based variant → dB) for files that were
  /// mastered a little quiet; see the table in docs/音频素材清单.md.
  final Map<int, double> gainsDb;

  /// Asset key of variant [v] (1-based), relative to `assets/` (the
  /// `audioplayers` AudioCache prefix).
  String asset(int v) => 'audio/$dir/${numbered ? '${id}_$v' : id}.m4a';

  List<String> get assets => [for (var v = 1; v <= variants; v++) asset(v)];

  double gainDb(int v) => gainsDb[v] ?? 0;

  /// The line of variant [v] (TTS fallback).
  String textOf(int v) => texts.isEmpty ? text : texts[(v - 1).clamp(0, texts.length - 1)];

  @override
  String toString() => 'Sound($id)';
}

/// Every sound of docs/音频素材清单.md.
abstract final class Sounds {
  // ── 4.1 跑步中 voice/run ──
  static const runCount3 = Sound.voice('run_count_3', 'run', '三');
  static const runCount2 = Sound.voice('run_count_2', 'run', '二');
  static const runCount1 = Sound.voice('run_count_1', 'run', '一');
  static const runGo = Sound.voice('run_go', 'run', '出发！今天去圈哪块地？');
  static const runPause = Sound.voice('run_pause', 'run', '先歇会儿，我等你。');
  static const runResume = Sound.voice('run_resume', 'run', '继续！');
  static const runFinish = Sound.voice('run_finish', 'run', '收工！我来算算你圈了多少地。');
  static const runHalf = Sound.voice('run_half', 'run', '已经过半了，保持这个节奏。');
  static const runGoal = Sound.voice('run_goal', 'run', '目标完成！还想多跑一会儿也可以。');
  static const runClose200 = Sound.voice('run_close_200', 'run', '再跑两百米，这块地就圈下来了。');
  static const runClose100 = Sound.voice('run_close_100', 'run', '还差一百米，冲！');
  static const runClose50 = Sound.voice('run_close_50', 'run', '马上闭合，最后几步！');
  static const runClaim = Sound.voice(
    'run_claim',
    'run',
    '圈下来了！这块地归你了。',
    variants: 3,
    texts: ['圈下来了！这块地归你了。', '漂亮！又多一块领地。', '这圈画得真圆！'],
  );
  static const runClaimCombo = Sound.voice('run_claim_combo', 'run', '连圈！今天状态在线！');
  static const runSteal = Sound.voice('run_steal', 'run', '抢过来了！记得常回来守着。');
  static const runBossNear = Sound.voice('run_boss_near', 'run', '前面有怪兽，从它身边跑过去就能打它！');
  static const runBossHit = Sound.voice('run_boss_hit', 'run', '打中了！它掉血了。');
  static const runBossDown = Sound.voice('run_boss_down', 'run', '搞定！怪兽被你赶跑了。');
  static const runChest = Sound.voice('run_chest', 'run', '叮！顺路捡了个宝箱。');
  static const runSupply = Sound.voice('run_supply', 'run', '补给站到账，券在卡券包里。');
  static const runEnergyFull = Sound.voice('run_energy_full', 'run', '今天的能量拿满了，剩下的路程就当享受。');
  static const runGpsWeak = Sound.voice('run_gps_weak', 'run', '定位信号有点弱，到开阔一点的地方试试。');
  static const runGpsBack = Sound.voice('run_gps_back', 'run', '信号回来了，继续记录。');
  static const runAutoPause = Sound.voice('run_auto_pause', 'run', '看你停下来了，先帮你暂停。');

  static Sound runCount(int n) => switch (n) {
    3 => runCount3,
    2 => runCount2,
    _ => runCount1,
  };

  // ── 4.2 AI 跟练 voice/coach ──
  static const coachReady = Sound.voice('coach_ready', 'coach', '准备好了吗？跟着我一起来。');
  static const coachNext = Sound.voice('coach_next', 'coach', '下一个动作：');
  static const coach3 = Sound.voice('coach_3', 'coach', '三');
  static const coach2 = Sound.voice('coach_2', 'coach', '二');
  static const coach1 = Sound.voice('coach_1', 'coach', '一');
  static const coachHalfway = Sound.voice('coach_halfway', 'coach', '过半了，坚持住！');
  static const coachLast10 = Sound.voice('coach_last10', 'coach', '最后十秒！');
  static const coachRest = Sound.voice('coach_rest', 'coach', '休息一下，调整呼吸。');
  static const coachGoodForm = Sound.voice('coach_good_form', 'coach', '动作很标准！');
  static const coachFixForm = Sound.voice('coach_fix_form', 'coach', '注意动作，慢一点没关系。');
  static const coachDone = Sound.voice('coach_done', 'coach', '练完了！今天的你比昨天更强。');

  static Sound coachCount(int n) => switch (n) {
    3 => coach3,
    2 => coach2,
    _ => coach1,
  };

  // ── 4.3 结算与成就 voice/result ──
  static const resultPb = Sound.voice('result_pb', 'result', '新纪录！比你上次快多了！');
  static const resultLevelUp = Sound.voice('result_levelup', 'result', '升级啦！');
  static const resultCodex = Sound.voice('result_codex', 'result', '新伙伴加入图鉴！');
  static const resultReview = Sound.voice('result_review', 'result', '这次的数据有点特别，我们核对一下，很快告诉你结果。');

  // ── 五、音效 sfx ──
  static const uiTap = Sound.sfx('ui_tap', variants: 3);
  static const uiTab = Sound.sfx('ui_tab', variants: 2);
  static const uiToggleOn = Sound.sfx('ui_toggle_on');
  static const uiToggleOff = Sound.sfx('ui_toggle_off');
  static const uiSheetOpen = Sound.sfx('ui_sheet_open');
  static const uiSuccess = Sound.sfx('ui_success');
  static const uiError = Sound.sfx('ui_error');
  static const uiRefresh = Sound.sfx('ui_refresh');
  static const startPress = Sound.sfx('start_press');
  static const runTick = Sound.sfx('run_tick');
  static const runGoSfx = Sound.sfx('run_go');

  /// Seamless 1.5 s loop while the finish button is held.
  static const runHold = Sound.sfx('run_hold');
  static const runHoldDone = Sound.sfx('run_hold_done');
  static const claim = Sound.sfx('claim', variants: 2);
  static const territoryLost = Sound.sfx('territory_lost');
  static const chestOpen = Sound.sfx('chest_open', variants: 2);
  static const energyGain = Sound.sfx('energy_gain');
  static const levelUp = Sound.sfx('level_up');
  static const codexUnlock = Sound.sfx('codex_unlock');
  static const buildingDone = Sound.sfx('building_done');
  static const like = Sound.sfx('like', variants: 2);
  static const message = Sound.sfx('message');
  static const scanOk = Sound.sfx('scan_ok');
  static const payOk = Sound.sfx('pay_ok');
  static const bossSpawn = Sound.sfx('boss_spawn');
  static const bossHit = Sound.sfx('boss_hit', variants: 3, gainsDb: {1: 3});
  static const bossDown = Sound.sfx('boss_down');

  // ── 六、角色声音 char ──
  static const monsterKinds = ['sofa', 'bat', 'smog', 'sugar'];
  static const companionKeys = ['gecko', 'axolotl', 'frog', 'spiky', 'firetail', 'nightnewt'];
  static const roleKeys = ['archer', 'knight', 'smith', 'monk', 'scout', 'banner', 'alchemist', 'farmer'];

  /// Files mastered 2–4 dB quiet (processing report), boosted on playback.
  static const charGainsDb = <String, Map<int, double>>{
    'boss_bat_tap': {2: 2},
    'boss_smog_hit': {2: 3},
    'boss_sofa_hit': {1: 3},
    'boss_sugar_hit': {2: 3},
    'role_knight': {1: 4},
  };

  static Sound _char(String id, int variants, {bool numbered = true}) =>
      Sound.char(id, variants: variants, numbered: numbered, gainsDb: charGainsDb[id] ?? const {});

  static String _monster(String kind) => monsterKinds.contains(kind) ? kind : 'sofa';

  /// 点怪兽 (`sofa | bat | smog | sugar`; unknown kinds use the sofa).
  static Sound bossTap(String kind) => _char('boss_${_monster(kind)}_tap', 3);

  /// 怪兽被打.
  static Sound bossHitChar(String kind) => _char('boss_${_monster(kind)}_hit', 2);

  /// 怪兽被击败.
  static Sound bossDownChar(String kind) => _char('boss_${_monster(kind)}_down', 1);

  /// 点伙伴 (null for keys without sounds).
  static Sound? petTap(String key) => companionKeys.contains(key) ? _char('pet_${key}_tap', 3) : null;

  /// 伙伴设为陪跑 / 解锁.
  static Sound? petHappy(String key) => companionKeys.contains(key) ? _char('pet_${key}_happy', 1) : null;

  /// 点角色卡.
  static Sound? role(String key) => roleKeys.contains(key) ? _char('role_$key', 1, numbered: false) : null;

  /// A sound by its id (`run_go`, `boss_bat_tap` …), or null.
  static Sound? byId(String id) => all.where((s) => s.id == id).firstOrNull;

  /// Everything, for preloading and the asset test.
  static List<Sound> get all => [
    runCount3, runCount2, runCount1, runGo, runPause, runResume, runFinish, runHalf, runGoal, //
    runClose200, runClose100, runClose50, runClaim, runClaimCombo, runSteal, runBossNear, runBossHit,
    runBossDown, runChest, runSupply, runEnergyFull, runGpsWeak, runGpsBack, runAutoPause,
    coachReady, coachNext, coach3, coach2, coach1, coachHalfway, coachLast10, coachRest, coachGoodForm,
    coachFixForm, coachDone,
    resultPb, resultLevelUp, resultCodex, resultReview,
    uiTap, uiTab, uiToggleOn, uiToggleOff, uiSheetOpen, uiSuccess, uiError, uiRefresh, startPress, runTick,
    runGoSfx, runHold, runHoldDone, claim, territoryLost, chestOpen, energyGain, levelUp, codexUnlock,
    buildingDone, like, message, scanOk, payOk, bossSpawn, bossHit, bossDown,
    for (final k in monsterKinds) ...[bossTap(k), bossHitChar(k), bossDownChar(k)],
    for (final k in companionKeys) ...[petTap(k)!, petHappy(k)!],
    for (final k in roleKeys) role(k)!,
  ];
}
