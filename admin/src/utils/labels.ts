import type { AdminRole, OrderStatus, RiskAction, RiskType, UserStatus } from '../api/types';

export const ROLE_LABEL: Record<AdminRole, string> = {
  admin: '管理员',
  ops: '运营',
  reviewer: '审核员',
  merchant: '商户对接',
};

export const USER_STATUS: Record<UserStatus, { text: string; color: string }> = {
  active: { text: '正常', color: 'success' },
  muted: { text: '禁言中', color: 'warning' },
  banned: { text: '已封禁', color: 'error' },
  deleting: { text: '注销冷静期', color: 'default' },
};

export const SOURCE_LABEL: Record<string, string> = {
  sms: '短信验证码',
  oneclick: '本机号一键登录',
  wechat: '微信',
  apple: 'Apple',
};

export const ORDER_STATUS: Record<OrderStatus, { text: string; color: string }> = {
  created: { text: '待支付', color: 'default' },
  paid: { text: '已支付', color: 'success' },
  refund_requested: { text: '退款申请', color: 'warning' },
  refunded: { text: '已退款', color: 'default' },
  closed: { text: '已关闭', color: 'default' },
  renew_failed: { text: '续费失败', color: 'error' },
};

export const CHANNEL_LABEL: Record<string, string> = {
  wechat_app: '微信支付',
  alipay_app: '支付宝',
  apple_iap: 'Apple 内购',
  mock: '模拟支付',
};

export const ORDER_KIND: Record<string, string> = { purchase: '新购', renewal: '续费', gift: '赠送' };

export const PERIOD_LABEL: Record<string, string> = { month: '1 个月', quarter: '3 个月', year: '12 个月' };

export const RISK_TYPE: Record<RiskType, string> = {
  speed: '速度异常',
  mock_location: '模拟定位',
  teleport: '轨迹瞬移',
  missing_device_data: '设备数据缺失',
  multi_account: '多账号同设备',
  device_tamper: '设备篡改',
};

export const RISK_ACTION: Record<RiskAction, { text: string; confirm: string; danger?: boolean }> = {
  void: { text: '作废记录并回滚领地', confirm: '作废这条运动记录，回滚它圈下和抢下的领地并扣回能量？', danger: true },
  warn: { text: '警告', confirm: '向该用户发送警告？' },
  ban_30d: { text: '封禁 30 天', confirm: '封禁该用户 30 天？封禁期间名下领地冻结。', danger: true },
  false_positive: { text: '误报，放行', confirm: '判定为误报并放行？系统会补做结算（圈地、发能量）。' },
};

export const SPORT_LABEL: Record<string, string> = {
  run: '跑步',
  ride: '骑行',
  hike: '徒步',
  walk: '健走',
  swim: '游泳',
  venue: '场馆签到',
  strength: '力量',
  yoga: '瑜伽',
  rope: '跳绳',
  hiit: 'HIIT',
  rally: '集结跑',
};

export const UNIT_LABEL: Record<string, string> = { km: 'km', m: '米', min: '分钟', count: '次', checkin: '次签到' };

export const DROP_KIND: Record<string, string> = { role: '角色', blueprint: '图纸', egg: '伙伴蛋', energy: '能量' };

export const TERRITORY_EVENT: Record<string, string> = {
  claim: '圈地',
  capture: '易手',
  attack: '被削弱',
  build: '建造',
  capture_whole: '整块易手',
  cut: '被切割',
  weaken: '被削弱',
  guard: '调整守卫值',
  admin_guard: '调整守卫值',
  owner_deleted: '原主注销',
  void: '运动作废',
  freeze: '冻结',
  unfreeze: '解冻',
  reset: '重置为无主',
  rollback: '风控回滚',
};

export const AUDIT_ACTION: Record<string, string> = {
  'admin.login': '登录',
  'user.reveal_phone': '查看完整手机号',
  'user.gift_member_7d': '赠送 7 天会员',
  'user.notify': '发站内通知',
  'user.mute_7d': '禁言 7 天',
  'user.unmute': '解除禁言',
  'user.ban': '封禁',
  'user.unban': '解封',
  'plan.update': '修改套餐',
  'plan.entitlements': '修改套餐权益',
  'order.refund': '退款',
  'order.remind': '续费失败提醒',
  'territory.guard': '调整守卫值',
  'territory.freeze': '冻结 / 解冻领地',
  'territory.reset': '重置领地',
  'risk.resolve': '处理风控告警',
  'risk.void': '风控：作废并回滚',
  'risk.warn': '风控：警告',
  'risk.ban_30d': '风控：封禁 30 天',
  'risk.false_positive': '风控：误报放行',
  'risk.rules': '修改风控规则',
  'gameplay.publish': '发布玩法配置',
  'gameplay.rollout': '玩法配置全量',
  'gameplay.rollback': '玩法配置回滚',
  'admin.create': '新建后台账号',
  'admin.update': '修改后台账号',
};

export const TODO_TYPE: Record<string, string> = { risk: '风控', refund: '会员退款', renew_failed: '续费失败' };
