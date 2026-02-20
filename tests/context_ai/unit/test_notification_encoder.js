'use strict';
/**
 * 通知编码器测试
 * 对应设计文档: §2.2 数字世界数据源, §5.1 感知域架构
 * 覆盖: 外卖/快递/IM/日历/银行/分类/隐私级别/缺失
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertDefined, assertGreaterThan
} = require('../../lib/assert');

// ── JS 镜像：通知编码器 ──

const NOTIFICATION_CATEGORIES = {
  'meituan':    { category: 'food_delivery', privacy: 'open',    urgency: 0.6 },
  'eleme':      { category: 'food_delivery', privacy: 'open',    urgency: 0.6 },
  'sf_express': { category: 'delivery',      privacy: 'open',    urgency: 0.5 },
  'jd_delivery':{ category: 'delivery',      privacy: 'open',    urgency: 0.5 },
  'wechat':     { category: 'im',            privacy: 'summary', urgency: 0.7 },
  'qq':         { category: 'im',            privacy: 'summary', urgency: 0.6 },
  'calendar':   { category: 'calendar',      privacy: 'open',    urgency: 0.8 },
  'icbc':       { category: 'bank',          privacy: 'blocked', urgency: 0.3 },
  'alipay':     { category: 'finance',       privacy: 'summary', urgency: 0.5 },
};

/** 关键词匹配提取意图 */
function classifyByKeyword(title, content) {
  const text = `${title || ''} ${content || ''}`.toLowerCase();
  const patterns = [
    { keywords: ['到达', '已送达', '取件', '快递柜'], intent: 'delivery_arrived' },
    { keywords: ['出发', '配送中', '骑手'],          intent: 'delivery_enroute' },
    { keywords: ['会议', '日程', '提醒'],             intent: 'calendar_event' },
    { keywords: ['转账', '收款', '付款'],             intent: 'transaction' },
    { keywords: ['消息', '回复', '@'],                intent: 'message' },
  ];
  for (const p of patterns) {
    if (p.keywords.some(k => text.includes(k))) return p.intent;
  }
  return 'generic';
}

function encodeNotification(appId, title, content, sender) {
  if (!appId) return { distribution: {}, features: [], quality: 0.0 };

  const config = NOTIFICATION_CATEGORIES[appId] || { category: 'unknown', privacy: 'blocked', urgency: 0.3 };
  const intent = classifyByKeyword(title, content);

  const dist = {};
  dist[config.category] = 1.0;
  dist[intent] = Math.max(dist[intent] || 0, 0.9);
  dist.urgency = config.urgency;

  // 重要联系人加权
  const importantSenders = ['老婆', '老板', 'boss', 'wife'];
  const isImportant = sender && importantSenders.some(s => sender.includes(s));
  if (isImportant) dist.urgency = Math.min(1.0, dist.urgency + 0.3);

  const features = [
    config.urgency,
    isImportant ? 1 : 0,
    config.privacy === 'open' ? 1 : config.privacy === 'summary' ? 0.5 : 0,
  ];

  return {
    distribution: dist,
    features,
    quality: 1.0,
    privacyLevel: config.privacy,
  };
}

// ── 测试 ──

describe('NotificationEncoder - App分类', function () {
  it('美团 → food_delivery', function () {
    const r = encodeNotification('meituan', '订单配送中', '', '');
    assertEqual(r.distribution.food_delivery, 1.0);
  });

  it('顺丰 → delivery', function () {
    const r = encodeNotification('sf_express', '快递已到达', '', '');
    assertEqual(r.distribution.delivery, 1.0);
  });

  it('微信 → im + summary隐私', function () {
    const r = encodeNotification('wechat', '新消息', '', '');
    assertEqual(r.distribution.im, 1.0);
    assertEqual(r.privacyLevel, 'summary');
  });

  it('日历 → calendar', function () {
    const r = encodeNotification('calendar', '会议提醒', '', '');
    assertEqual(r.distribution.calendar, 1.0);
  });

  it('工行 → bank + blocked隐私', function () {
    const r = encodeNotification('icbc', '转账通知', '', '');
    assertEqual(r.distribution.bank, 1.0);
    assertEqual(r.privacyLevel, 'blocked');
  });
});

describe('NotificationEncoder - 关键词意图', function () {
  it('到达 → delivery_arrived', function () {
    const r = encodeNotification('sf_express', '您的快递已到达菜鸟驿站', '', '');
    assertDefined(r.distribution.delivery_arrived);
    assertGreaterThan(r.distribution.delivery_arrived, 0.8);
  });

  it('会议 → calendar_event', function () {
    const r = encodeNotification('calendar', '10:00 项目会议', '', '');
    assertDefined(r.distribution.calendar_event);
  });

  it('无匹配 → generic', function () {
    const r = encodeNotification('meituan', '优惠活动', '', '');
    assertDefined(r.distribution.generic);
  });
});

describe('NotificationEncoder - 重要联系人', function () {
  it('老婆发消息 → urgency提高', function () {
    const r = encodeNotification('wechat', '消息', '', '老婆');
    assertEqual(r.distribution.urgency, 1.0);
  });

  it('老板发消息 → urgency提高', function () {
    const r = encodeNotification('wechat', '消息', '', '老板');
    assertEqual(r.distribution.urgency, 1.0);
  });

  it('普通联系人 → 默认urgency', function () {
    const r = encodeNotification('wechat', '消息', '', '同事A');
    assertEqual(r.distribution.urgency, 0.7);
  });
});

describe('NotificationEncoder - 边界/缺失', function () {
  it('无appId → quality=0', function () {
    const r = encodeNotification(null, '', '', '');
    assertEqual(r.quality, 0.0);
  });

  it('未知app → unknown + blocked', function () {
    const r = encodeNotification('random_app', '', '', '');
    assertDefined(r.distribution.unknown);
    assertEqual(r.privacyLevel, 'blocked');
  });

  it('空标题和内容 → generic意图', function () {
    const r = encodeNotification('wechat', '', '', '');
    assertDefined(r.distribution.generic);
  });
});
