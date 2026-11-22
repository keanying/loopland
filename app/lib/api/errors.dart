import 'package:dio/dio.dart';

/// Chinese messages for every `error.code` in docs/api/v1.md. The server's
/// `message` is preferred when present (it is meant for display and often
/// carries numbers, e.g. "需要 120，当前 80"); these are the fallbacks.
const errorMessages = <String, String>{
  // 通用
  'invalid_body': '请求参数有误，请检查后重试',
  'unauthorized': '登录已过期，请重新登录',
  'forbidden': '没有权限进行此操作',
  'not_found': '内容不存在或已被删除',
  'conflict': '操作冲突，请刷新后重试',
  'rate_limited': '操作太频繁，请稍后再试',
  'internal': '服务器开小差了，请稍后再试',
  // 账号
  'invalid_code': '验证码不正确',
  'captcha_failed': '人机验证未通过，请重新验证',
  'captcha_unavailable': '人机验证暂不可用，请稍后再试',
  'wechat_not_installed': '未安装微信，请安装微信后再试，或选择其他方式',
  'code_expired': '验证码已过期，请重新获取',
  'provider_error': '第三方登录失败，请稍后再试或换一种方式登录',
  'account_banned': '账号已被封禁，如有疑问请联系客服',
  'sport_not_supported': '暂不支持上传这种运动',
  'invalid_phone': '手机号格式不正确',
  'phone_required': '请先绑定手机号',
  'phone_taken': '该手机号已被其他账号使用',
  'consent_required': '请先同意隐私政策和位置授权',
  'realname_failed': '实名认证未通过，请核对姓名和身份证号',
  'realname_required': '开通会员前需要先完成实名认证',
  // 领地与建城
  'not_owner': '这不是你的领地',
  'frozen': '领地已被冻结，暂时无法操作',
  'slot_taken': '这个建造位已经有建筑了',
  'invalid_slot': '建造位不存在',
  'level_too_low': '等级不够，还不能建造这个建筑',
  'not_enough_energy': '能量不足，去运动攒点能量吧',
  'unknown_building': '未知的建筑类型',
  'role_not_owned': '还没有招募到这个角色',
  'no_station_slot': '驻扎位已满，先撤下一个角色或建造营帐、民居',
  // 跑团
  'already_in_crew': '你已经在一个跑团里了，先退出再加入新的',
  'invite_only': '该跑团仅限邀请加入',
  'leader_must_transfer': '团长需要先转让团长身份才能退出',
  // 会员与支付
  'channel_not_allowed': '当前设备不支持该支付方式',
  'minor_blocked': '未成年账号暂不支持购买会员',
  'plan_off_sale': '该套餐已下架，请选择其他套餐',
  'manage_in_app_store': 'Apple 订阅请在系统设置 › Apple ID › 订阅 中管理自动续费',
  // V2 玩法
  'out_of_range': '离得太远了，走近一点再试',
  'cooldown': '合击冷却中，稍等一下',
  'boss_not_active': '这只怪兽已经被击退或离开了',
  'already_opened': '这个宝箱你已经开过了',
  'chest_expired': '宝箱已经消失了，明天再来看看',
  'companion_not_hatched': '伙伴还没孵化，先跑够里程孵化它',
  'relay_running': '已经有一场接力在进行中',
  'not_leader': '只有团长可以发起接力',
  'not_in_crew': '先加入一个跑团',
  // V2 社区 · 动态 / 评论 / 主页
  'content_blocked': '内容包含不允许发布的信息，请修改后再试',
  'muted': '你已被禁言，暂时不能发布内容',
  'invalid_media': '图片无效或不是你上传的，请重新选择',
  'invalid_target': '不能对自己进行这个操作',
  'blocked': '你们之间存在拉黑关系，无法操作',
  // V2 社区 · 私信 / 组局 / 集结跑 / 赛事 / 跑团邀请
  'stranger_limit': '对方还没有回复或关注你，最多先发 3 条消息',
  'checkin_not_allowed': '现在还不能签到：需要在开始前 30 分钟到开始后 60 分钟内、离集合点 300 米以内',
  'meetup_full': '这个局已经满员了',
  'meetup_started': '这个局已经开始了，不能再报名',
  'signup_closed': '报名已截止',
  'race_full': '赛事名额已满',
  'race_started': '赛事已经开始，不能取消报名',
  'invalid_invite': '邀请码无效或已过期',
  // V2 AI
  'ai_unavailable': 'AI 助手暂时不可用，请稍后再试',
  'ai_quota_exceeded': '本周免费次数已用完，开通会员不限次数',
  'ai_image_unsupported': '当前 AI 模型还不支持识别图片',
  'regenerate_limit': '这次运动的战报已经换过 2 次了',
  'stream_interrupted': '回答中断了，请重试',
  'invalid_content': '问题不能为空，最多 500 字',
  'invalid_activity': '这次运动还没结算完成，稍后再生成战报',
  'invalid_ai_report': '这次运动还没有 AI 战报，先生成一篇吧',
  // V2 本地生活 · 场馆签到 / 订场 / 报名费
  'already_checked_in': '今天已经在这个场馆签到过了，明天再来',
  'minor_not_allowed': '未成年账号暂不支持订场和付费报名',
  'slot_unavailable': '这个时段刚被订走了，换一个时段吧',
  'cancel_too_late': '开始前 2 小时内不能自助取消，如需退款请联系客服',
  // V2 本地生活 · 补给站 / 卡券 / 能量商城
  'too_far': '不在补给站范围内，走近一点再领取',
  'already_claimed': '今天已经领过这个补给站的券了，明天再来',
  'sold_out': '今天的券已经发完了，明天再来',
  'already_owned': '你已经拥有这件装扮了',
  // V2 本地生活 · 商户商品 / 商品订单
  'limit_reached': '已达到这个商品的限购数量',
  'not_on_sale': '这个商品已下架，看看其他的吧',
  'not_refundable': '这个商品购买后不可退款',
  'nothing_to_refund': '没有可以退款的券了（已使用或已退款）',
  'invalid_status': '订单状态已变化，请刷新后再试',
  // 客户端
  'network': '网络连接失败，请检查网络后重试',
  'timeout': '网络超时，请稍后再试',
  'cancelled': '已取消',
  'unknown': '出了点问题，请稍后再试',
};

class ApiException implements Exception {
  ApiException({required this.status, required this.code, String? message, this.data = const {}})
      : serverMessage = message ?? '';

  final int status;
  final String code;
  final String serverMessage;

  /// The whole `error` object (and top-level extras such as `delete_after`).
  final Map<String, dynamic> data;

  String get message =>
      serverMessage.isNotEmpty ? serverMessage : (errorMessages[code] ?? errorMessages['unknown']!);

  bool get isNetwork => code == 'network' || code == 'timeout';

  /// `cooldown` carries `retry_after_s`.
  int? get retryAfterS {
    final v = data['retry_after_s'];
    return v is num ? v.toInt() : null;
  }

  /// `account_banned` may carry `banned_until`.
  DateTime? get bannedUntil {
    final v = data['banned_until'];
    return v is String ? DateTime.tryParse(v) : null;
  }

  /// Message with the ban end date appended when the server sent one.
  String get displayMessage {
    final until = bannedUntil;
    if (code == 'account_banned' && until != null) {
      final l = until.toLocal();
      return '$message（解封时间 ${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}）';
    }
    return message;
  }

  static ApiException from(Object e) {
    if (e is ApiException) return e;
    if (e is DioException) {
      if (e.error is ApiException) return e.error as ApiException;
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return ApiException(status: 0, code: 'timeout');
        case DioExceptionType.connectionError:
          return ApiException(status: 0, code: 'network');
        case DioExceptionType.cancel:
          return ApiException(status: 0, code: 'cancelled');
        default:
      }
      final res = e.response;
      if (res != null) return fromResponse(res.statusCode ?? 0, res.data);
      return ApiException(status: 0, code: 'network');
    }
    return ApiException(status: 0, code: 'unknown', message: e.toString());
  }

  static ApiException fromResponse(int status, Object? body) {
    if (body is Map && body['error'] is Map) {
      final err = (body['error'] as Map).cast<String, dynamic>();
      final extra = <String, dynamic>{
        for (final e in body.entries)
          if (e.key != 'error') e.key.toString(): e.value,
        ...err,
      };
      return ApiException(
        status: status,
        code: (err['code'] as String?) ?? _codeForStatus(status),
        message: err['message'] as String?,
        data: extra,
      );
    }
    return ApiException(status: status, code: _codeForStatus(status));
  }

  static String _codeForStatus(int s) => switch (s) {
        400 => 'invalid_body',
        401 => 'unauthorized',
        403 => 'forbidden',
        404 => 'not_found',
        409 => 'conflict',
        429 => 'rate_limited',
        _ => 'internal',
      };

  @override
  String toString() => 'ApiException($status $code: $message)';
}

/// Human message for any error thrown by the API layer.
String errorText(Object e) => ApiException.from(e).displayMessage;
