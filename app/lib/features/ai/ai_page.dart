import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/ai_api.dart';
import '../../api/ai_models.dart';
import '../../api/community_api.dart';
import '../../api/community_common.dart';
import '../../api/errors.dart';
import '../../auth/auth_controller.dart';
import '../../claim/geo.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../run/run_controller.dart';
import '../../widgets/common.dart';
import '../chat/pick_image.dart';
import '../social/social_widgets.dart';
import 'ai_providers.dart';
import 'ai_widgets.dart';

const _defaultSuggestions = ['规划圈地路线', '今晚去哪抢地', '生成今日战报', '帮我排一周计划'];

/// A photo attached to the next question (`POST /v1/media` purpose=chat).
class _Attachment {
  _Attachment(this.picked);
  final PickedImage picked;
  int? mediaId;
  bool uploading = true;
  Object? error;
}

/// A failed answer: what to show and how to ask again.
class _Failure {
  const _Failure(this.message, this.retry);
  final String message;
  final VoidCallback retry;
}

/// E-08 AI 助手「圈圈」: greeting + suggestions, history (paged upward),
/// streamed answers with route / territory / boss cards, photos (vision
/// models only), weekly quota and model disclosure. A-04「问 AI」 opens it
/// with an [AIContext].
class AIAssistantPage extends ConsumerStatefulWidget {
  const AIAssistantPage({super.key, this.initialContext});
  final AIContext? initialContext;

  @override
  ConsumerState<AIAssistantPage> createState() => _AIAssistantPageState();
}

class _AIAssistantPageState extends ConsumerState<AIAssistantPage> {
  late final AiApi _api = ref.read(aiApiProvider);
  late final CursorPager<AIMessage> _pager = CursorPager((c) => _api.messages(before: c));
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();

  AIGreeting? _greeting;
  LatLng? _me;
  AIContext? _ctx;
  _Attachment? _attachment;

  /// Newer than the info's quota (from the last answer).
  AIQuota? _quota;
  bool _visionOff = false;

  bool _sending = false;
  int? _streamingId;
  CancelToken? _cancel;
  int _seq = 0;

  /// Photos of my not-yet-confirmed messages (temp id → bytes).
  final _localImages = <int, Uint8List>{};
  final _failures = <int, _Failure>{};

  @override
  void initState() {
    super.initState();
    _ctx = widget.initialContext;
    if (_ctx != null) {
      _text.text = switch (_ctx!.type) {
        'boss' => '这只怪兽怎么打最划算？',
        _ => '这块地怎么抢下来？',
      };
    }
    _pager.addListener(_changed);
    _pager.refresh();
    _scroll.addListener(_onScroll);
    _loadGreeting();
  }

  @override
  void dispose() {
    _cancel?.cancel();
    _pager.removeListener(_changed);
    _pager.dispose();
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _onScroll() {
    // Reversed list: older pages are towards the max extent.
    if (_scroll.position.extentAfter < 400) _pager.loadMore();
  }

  Future<void> _loadGreeting() async {
    final u = ref.read(userProvider);
    if (u?.consents.location == true) {
      try {
        final f = await ref.read(locationSourceProvider).current().timeout(const Duration(seconds: 4));
        if (f != null) _me = LatLng(f.lat, f.lng);
      } catch (_) {}
    }
    try {
      final g = await _api.greeting(lat: _me?.lat, lng: _me?.lng);
      if (mounted) setState(() => _greeting = g);
    } catch (_) {
      if (mounted) setState(() => _greeting = AIGreeting(text: '嗨${u == null ? '' : '，${u.nickname}'}！我是圈圈，问我去哪抢地、怪兽怎么打、今天跑多少合适。'));
    }
  }

  AIQuota? _quotaOf(AIInfo? info) => _quota ?? info?.quota;

  // ── sending ──

  Future<void> _send([String? preset]) async {
    if (_sending) return;
    final att = _attachment;
    if (att != null && att.mediaId == null) {
      toast(context, att.uploading ? '图片还在上传，稍等一下' : '图片上传失败，请删除后重新选择');
      return;
    }
    final typed = (preset ?? _text.text).trim();
    final content = typed.isEmpty && att != null ? '帮我看看这张图' : typed;
    if (content.isEmpty) return;
    if (content.runes.length > 500) {
      toast(context, '一次最多问 500 字');
      return;
    }
    final info = ref.read(aiInfoProvider).value;
    if (_quotaOf(info)?.exhausted ?? false) {
      await _upsell(null);
      return;
    }
    final ctx = _ctx;
    final draft = _text.text;
    setState(() {
      if (preset == null) _text.clear();
      _attachment = null;
      _ctx = null;
    });
    await _ask(
      content,
      imageId: att?.mediaId,
      imageBytes: att?.picked.bytes,
      ctx: ctx,
      restore: () {
        if (!mounted) return;
        setState(() {
          if (preset == null) _text.text = draft;
          _attachment ??= att;
          _ctx ??= ctx;
        });
      },
    );
  }

  Future<void> _ask(String content, {int? imageId, Uint8List? imageBytes, AIContext? ctx, required VoidCallback restore}) async {
    final userId = -(++_seq), botId = -(++_seq);
    if (imageBytes != null) _localImages[userId] = imageBytes;
    _pager.insertFirst(AIMessage(id: userId, role: 'user', content: content, createdAt: DateTime.now()));
    _pager.insertFirst(AIMessage(id: botId, role: 'assistant', aiGenerated: true, createdAt: DateTime.now()));
    _cancel = CancelToken();
    setState(() {
      _sending = true;
      _streamingId = botId;
    });
    _jumpToLatest();

    var events = 0;
    AIChatResult? done;
    ApiException? failure;
    try {
      await for (final ev in _api.chatStream(content, imageId: imageId, context: ctx, lat: _me?.lat, lng: _me?.lng, cancel: _cancel)) {
        events++;
        switch (ev) {
          case AIDelta(:final text):
            _pager.replaceWhere((m) => m.id == botId, (m) => m.copyWith(content: m.content + text));
          case AICardEvent(:final card):
            _pager.replaceWhere((m) => m.id == botId, (m) => m.copyWith(cards: [...m.cards, card]));
          case AIDone(:final result):
            done = result;
          case AIError(:final code, :final message):
            failure = ApiException(status: 0, code: code, message: message);
        }
      }
    } catch (e) {
      final ex = ApiException.from(e);
      // Streaming not possible (proxy, old server, network hiccup before the
      // first byte): ask again without streaming. Server-coded errors
      // (quota, blocked, …) are final.
      if (events == 0 && ex.status == 0 && ex.code != 'cancelled') {
        try {
          done = await _api.chat(content, imageId: imageId, context: ctx, lat: _me?.lat, lng: _me?.lng);
        } catch (e2) {
          failure = ApiException.from(e2);
        }
      } else {
        failure = ex;
      }
    }
    if (!mounted) return;
    final result = done;
    if (result != null) {
      final user = result.userMessage;
      if (user != null) {
        final bytes = _localImages.remove(userId);
        if (bytes != null && user.imageUrl == null) _localImages[user.id] = bytes;
        _pager.replaceWhere((m) => m.id == userId, (_) => user);
      }
      // done.message is authoritative: output moderation may replace the
      // streamed text (「这个问题圈圈暂时回答不了」) and drop the cards.
      final streamed = _pager.items.where((m) => m.id == botId).firstOrNull;
      final msg = result.message;
      final malformed = msg.id == 0 && msg.content.isEmpty;
      _pager.replaceWhere((m) => m.id == botId, (_) => malformed ? (streamed ?? msg) : msg);
      if (result.quota != null) _quota = result.quota;
    } else {
      _fail(failure ?? ApiException(status: 0, code: 'stream_interrupted'), userId, botId, () {
        _pager.removeWhere((m) => m.id == userId || m.id == botId);
        _failures.remove(botId);
        _ask(content, imageId: imageId, imageBytes: imageBytes, ctx: ctx, restore: restore);
      }, restore);
    }
    setState(() {
      _sending = false;
      _streamingId = null;
    });
  }

  void _fail(ApiException e, int userId, int botId, VoidCallback retry, VoidCallback restore) {
    void drop() {
      _pager.removeWhere((m) => m.id == userId || m.id == botId);
      _localImages.remove(userId);
      restore();
    }

    switch (e.code) {
      case 'cancelled':
        drop();
      case 'ai_quota_exceeded':
        drop();
        final q = _quotaOf(ref.read(aiInfoProvider).value);
        _quota = AIQuota(weeklyFree: q?.weeklyFree ?? 3, used: q?.weeklyFree ?? 3, remaining: 0, resetsAt: q?.resetsAt);
        _upsell(e);
      case 'content_blocked':
        drop();
        _alert('内容未通过检查', e.message);
      case 'ai_image_unsupported':
        drop();
        setState(() {
          _visionOff = true;
          _attachment = null;
        });
        _alert('暂不支持图片', e.message);
      case 'rate_limited' || 'invalid_content':
        drop();
        toast(context, e.message);
      default:
        // ai_unavailable, network, interrupted stream: keep the question,
        // show the error in the answer bubble with a retry.
        setState(() => _failures[botId] = _Failure(e.message, retry));
    }
  }

  void _jumpToLatest() {
    if (_scroll.hasClients && _scroll.offset > 0) {
      _scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    }
  }

  Future<void> _upsell(ApiException? e) async {
    final q = _quotaOf(ref.read(aiInfoProvider).value);
    final go = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('本周免费次数已用完'),
        content: Text(
          [
            e?.message.isNotEmpty == true ? e!.message : '免费用户每周可以问圈圈 ${q?.weeklyFree ?? 3} 次，开通会员不限次数。',
            if (q?.resetsAt != null) '免费次数将于 ${Fmt.dateTime(q!.resetsAt)} 重置。',
          ].join('\n'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('知道了')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('开通会员')),
        ],
      ),
    );
    if (go == true && mounted) context.push('/membership');
  }

  Future<void> _alert(String title, String body) => showDialog<void>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [FilledButton(onPressed: () => Navigator.pop(d), child: const Text('知道了'))],
    ),
  );

  // ── photo ──

  Future<void> _pickPhoto() async {
    final source = await showModalBottomSheet<String>(
      context: context,
      builder: (s) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(leading: const Icon(Icons.photo_camera_outlined), title: const Text('拍照'), onTap: () => Navigator.pop(s, 'camera')),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(s, 'gallery'),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    final PickedImage? picked;
    try {
      picked = await ref.read(singleImagePickerProvider)(camera: source == 'camera');
    } catch (_) {
      if (mounted) toast(context, source == 'camera' ? '无法打开相机，请在系统设置里允许圈圈使用相机' : '无法打开相册，请在系统设置里允许圈圈访问照片');
      return;
    }
    if (picked == null || !mounted) return;
    final att = _Attachment(picked);
    setState(() => _attachment = att);
    try {
      final up = await ref.read(communityApiProvider).uploadMedia(picked.bytes, filename: picked.name, purpose: 'chat');
      att.mediaId = up.id;
    } catch (e) {
      att.error = e;
      if (mounted) showError(context, e);
    } finally {
      att.uploading = false;
      if (mounted) setState(() {});
    }
  }

  // ── menu ──

  Future<void> _about(AIInfo info) => showModalBottomSheet<void>(
    context: context,
    builder: (s) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                AIBadge(size: 40),
                SizedBox(width: 12),
                Text('关于 AI 助手', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
              ],
            ),
            const SizedBox(height: 16),
            _kv('模型名称', info.modelName.isEmpty ? '-' : info.modelName),
            _kv('备案编号', info.registrationNo.isEmpty ? '-' : info.registrationNo),
            _kv('图片识别', info.vision && !_visionOff ? '支持' : '不支持'),
            _kv('本周次数', _quotaText(_quotaOf(info), long: true)),
            const SizedBox(height: 10),
            Text(info.disclaimer, style: const TextStyle(color: LL.text2, height: 1.5)),
            const SizedBox(height: 6),
            const Text(
              '圈圈会结合你的领地、运动记录和附近的玩法给建议，训练建议仅供参考，不构成医疗意见，身体不适请及时就医。'
              '对话内容保存 180 天用于投诉核查，你可以随时清空。',
              style: TextStyle(color: LL.text3, fontSize: 12, height: 1.5),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 76,
          child: Text(k, style: const TextStyle(color: LL.text2)),
        ),
        Expanded(
          child: Text(v, style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
      ],
    ),
  );

  String _quotaText(AIQuota? q, {bool long = false}) {
    if (q == null) return '-';
    if (q.unlimited) return long ? '会员不限次数' : '不限次数';
    final left = q.remaining ?? (q.weeklyFree - q.used).clamp(0, q.weeklyFree);
    return long ? '剩 $left / ${q.weeklyFree} 次（每周一重置）' : '本周剩 $left 次';
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('清空对话？'),
        content: const Text('清空后你将看不到之前的对话记录。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('清空')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final done = await runGuarded(context, () async {
      await _api.clearMessages();
      return true;
    });
    if (done == true && mounted) {
      _failures.clear();
      _localImages.clear();
      await _pager.refresh();
      if (mounted) toast(context, '对话已清空');
    }
  }

  // ── build ──

  @override
  Widget build(BuildContext context) {
    final infoAsync = ref.watch(aiInfoProvider);
    final info = infoAsync.value;
    final unavailable =
        (infoAsync.hasError && ApiException.from(infoAsync.error!).code == 'ai_unavailable') || (info != null && !info.enabled);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _header(info),
            if (unavailable)
              const Expanded(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text('AI 助手暂时不可用，请稍后再试', style: TextStyle(color: LL.text2)),
                  ),
                ),
              )
            else ...[
              Expanded(
                child: GestureDetector(onTap: () => _focus.unfocus(), child: _list()),
              ),
              _chips(),
              if (_ctx != null) _contextChip(_ctx!),
              if (_attachment != null) _attachmentPreview(_attachment!),
              _composer(info),
            ],
          ],
        ),
      ),
    );
  }

  Widget _header(AIInfo? info) {
    final q = _quotaOf(info);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              RoundIconButton(icon: Icons.arrow_back_ios_new_rounded, tooltip: '返回', onTap: () => Navigator.of(context).maybePop()),
              const SizedBox(width: 12),
              const AIBadge(),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('圈圈 · AI 助手', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                    Text(
                      '懂你的领地、配速和附近的搭子',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: LL.text2, fontSize: 12),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '更多',
                icon: const Icon(Icons.more_vert_rounded, color: LL.text2),
                color: LL.card2,
                onSelected: (v) {
                  if (v == 'about' && info != null) _about(info);
                  if (v == 'clear') _clear();
                },
                itemBuilder: (_) => [
                  if (info != null) const PopupMenuItem(value: 'about', child: Text('关于 AI 助手')),
                  const PopupMenuItem(value: 'clear', child: Text('清空对话')),
                ],
              ),
            ],
          ),
          // Model disclosure (生成式人工智能服务管理暂行办法) + weekly quota.
          if (info != null)
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 4, right: 8),
              child: Row(
                children: [
                  Expanded(child: _disclosure(info)),
                  if (q != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: q.exhausted ? const Color(0xFF3A1D22) : LL.card2,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        _quotaText(q),
                        style: TextStyle(
                          color: q.exhausted ? LL.red : (q.unlimited ? LL.lime : LL.text2),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _disclosure(AIInfo info) => Align(
    alignment: Alignment.centerLeft,
    child: InkWell(
      key: const Key('ai-disclosure'),
      onTap: () => _about(info),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.info_outline_rounded, size: 13, color: LL.text3),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                [
                  if (info.modelName.isNotEmpty) '模型：${info.modelName}',
                  if (info.registrationNo.isNotEmpty) '备案号：${info.registrationNo}',
                  '内容由 AI 生成',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: LL.text3, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _list() {
    final items = _pager.items;
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      itemCount: items.length + 1,
      itemBuilder: (context, i) {
        if (i == items.length) return _top();
        final m = items[i];
        return Padding(padding: const EdgeInsets.only(top: 12), child: m.isUser ? _userBubble(m) : _botBubble(m));
      },
    );
  }

  /// Oldest end of the list: next page spinner / error, else the greeting.
  Widget _top() {
    final p = _pager;
    if (p.error != null && p.items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: TextButton(onPressed: p.refresh, child: Text('历史对话加载失败：${errorText(p.error!)}，点此重试')),
        ),
      );
    }
    if (p.initialLoading || (p.hasMore && p.loading)) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (p.hasMore) {
      return Center(
        child: TextButton(onPressed: p.loadMore, child: const Text('查看更早的对话')),
      );
    }
    final g = _greeting;
    if (g == null) return const SizedBox(height: 8);
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.82),
        child: Container(
          key: const Key('ai-greeting'),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: LL.card,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: LL.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(g.text, style: const TextStyle(fontSize: 15, height: 1.6)),
              if (g.aiGenerated) const Padding(padding: EdgeInsets.only(top: 6), child: AILabel()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _userBubble(AIMessage m) {
    final local = _localImages[m.id];
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (local != null || m.imageUrl != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: SizedBox(
                    width: 160,
                    height: 160,
                    child: local != null
                        ? Image.memory(
                            local,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const ColoredBox(color: LL.card2),
                          )
                        : NetImage(url: m.imageUrl!),
                  ),
                ),
              ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: const BoxDecoration(
                color: LL.lime,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                  bottomLeft: Radius.circular(20),
                  bottomRight: Radius.circular(6),
                ),
              ),
              child: Text(m.content, style: const TextStyle(color: LL.ink, fontSize: 15, height: 1.5)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _botBubble(AIMessage m) {
    final streaming = m.id == _streamingId;
    final failure = _failures[m.id];
    final waiting = streaming && m.content.isEmpty && m.cards.isEmpty;
    final cards = [
      for (final c in m.cards)
        if (c.known) c,
    ];
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.86),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (waiting)
              const _TypingDots()
            else if (m.content.isNotEmpty || failure == null)
              Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                decoration: const BoxDecoration(
                  color: LL.card,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(20),
                    topRight: Radius.circular(20),
                    bottomRight: Radius.circular(20),
                    bottomLeft: Radius.circular(6),
                  ),
                  border: Border.fromBorderSide(BorderSide(color: LL.border)),
                ),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: m.content),
                      if (streaming)
                        const TextSpan(
                          text: ' ▍',
                          style: TextStyle(color: LL.lavender),
                        ),
                    ],
                  ),
                  style: const TextStyle(fontSize: 15, height: 1.6),
                ),
              ),
            for (final c in cards) Padding(padding: const EdgeInsets.only(top: 8), child: _card(c)),
            if (failure != null)
              Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                decoration: BoxDecoration(color: const Color(0xFF3A1D22), borderRadius: BorderRadius.circular(18)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline_rounded, color: LL.red, size: 18),
                    const SizedBox(width: 8),
                    Flexible(child: Text(failure.message, style: const TextStyle(fontSize: 13))),
                    TextButton(onPressed: _sending ? null : failure.retry, child: const Text('重试')),
                  ],
                ),
              ),
            if (!waiting) const Padding(padding: EdgeInsets.only(top: 6, left: 4), child: AILabel()),
          ],
        ),
      ),
    );
  }

  Widget _card(AICard c) => switch (c.type) {
    'route' => AIRouteCard(route: c.route!, onStart: () => openAICard(context, ref, c)),
    'territory' => AITerritoryCard(territory: c.territory!, onTap: () => openAICard(context, ref, c)),
    'boss' => AIBossCard(boss: c.boss!, onTap: () => openAICard(context, ref, c)),
    _ => const SizedBox.shrink(),
  };

  Widget _chips() {
    final list = _greeting?.suggestions.isNotEmpty == true ? _greeting!.suggestions : _defaultSuggestions;
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
        itemCount: list.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) => ActionChip(
          label: Text(list[i]),
          onPressed: _sending ? null : () => _send(list[i]),
          backgroundColor: LL.card,
          side: const BorderSide(color: Color(0xFF3A3A42)),
          shape: const StadiumBorder(),
          labelStyle: const TextStyle(color: LL.text, fontSize: 13),
        ),
      ),
    );
  }

  Widget _contextChip(AIContext c) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
    child: Align(
      alignment: Alignment.centerLeft,
      child: InputChip(
        avatar: Icon(c.type == 'boss' ? Icons.whatshot_rounded : Icons.flag_outlined, size: 16, color: LL.lavender),
        label: Text('关于${c.type == 'boss' ? '怪兽' : '领地'}「${c.name.isEmpty ? '#${c.id}' : c.name}」'),
        onDeleted: () => setState(() => _ctx = null),
        backgroundColor: const Color(0xFF26223A),
        side: BorderSide.none,
        labelStyle: const TextStyle(color: LL.lavender, fontSize: 12, fontWeight: FontWeight.w700),
      ),
    ),
  );

  Widget _attachmentPreview(_Attachment a) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
    child: Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: 64,
        height: 64,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                a.picked.bytes,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const ColoredBox(color: LL.card2),
              ),
            ),
            if (a.uploading || a.error != null)
              Container(
                decoration: BoxDecoration(color: const Color(0x990E0E10), borderRadius: BorderRadius.circular(12)),
                alignment: Alignment.center,
                child: a.uploading
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.error_outline_rounded, color: LL.red),
              ),
            Positioned(
              top: 2,
              right: 2,
              child: GestureDetector(
                onTap: () => setState(() => _attachment = null),
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: const BoxDecoration(color: Color(0xCC0E0E10), shape: BoxShape.circle),
                  child: const Icon(Icons.close_rounded, size: 14, color: LL.text, semanticLabel: '移除图片'),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _composer(AIInfo? info) {
    final vision = (info?.vision ?? false) && !_visionOff;
    final exhausted = _quotaOf(info)?.exhausted ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        children: [
          if (vision) ...[
            RoundIconButton(icon: Icons.photo_camera_outlined, size: 48, tooltip: '发图片', onTap: _sending ? null : _pickPhoto),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: TextField(
              key: const Key('ai-input'),
              controller: _text,
              focusNode: _focus,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: exhausted ? '本周免费次数已用完，开通会员不限次数' : '问问圈圈，比如：今晚去哪抢地？',
                contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: const BorderSide(color: LL.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: const BorderSide(color: LL.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: const BorderSide(color: LL.lavender),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          RoundIconButton(
            icon: _sending ? Icons.more_horiz_rounded : Icons.arrow_forward_rounded,
            size: 48,
            color: LL.lime,
            fg: LL.ink,
            tooltip: '发送',
            onTap: _sending ? null : () => _send(),
          ),
        ],
      ),
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'AI 正在输入',
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: LL.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: LL.border),
      ),
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++)
              Container(
                width: 8,
                height: 8,
                margin: EdgeInsets.only(right: i < 2 ? 6 : 0),
                decoration: BoxDecoration(
                  color: LL.lavender.withValues(alpha: 0.25 + 0.75 * (((_c.value * 3 - i) % 3) < 1 ? 1 : 0)),
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
