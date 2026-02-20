'use strict';
/**
 * 📧 消息堆积场景测试
 * 对应设计文档: §2.3 - 消息堆积
 * 触发: 10min内3+条未读
 */
const { describe, it } = require('../../lib/test-runner');
const { assertEqual, assertGreaterThan } = require('../../lib/assert');
const { evaluate } = require('./_helpers');

const RULES = [{
  id: 'rule_message_pile', intent: 'message_pile', priority: '🟡',
  conditions: {
    unreadCount10min: { op: 'gte', value: 3 },
  },
}];

describe('Scenario: 消息堆积 - 匹配', function () {
  it('5条未读 → 触发', function () {
    const r = evaluate({ unreadCount10min: 5 }, RULES);
    assertEqual(r[0].intent, 'message_pile');
  });
  it('恰好3条 → 触发', function () {
    assertEqual(evaluate({ unreadCount10min: 3 }, RULES)[0].confidence, 1.0);
  });
});

describe('Scenario: 消息堆积 - 不匹配', function () {
  it('1条未读 → 不触发', function () {
    const r = evaluate({ unreadCount10min: 1 }, RULES);
    if (r.length > 0) {
      // gte soft match: 1 vs 3, deficit=2, decay = max(0, 1-2/1) = 0
      assertEqual(r[0].confidence < 0.5, true);
    }
  });
  it('0条 → 不触发', function () {
    const r = evaluate({ unreadCount10min: 0 }, RULES);
    if (r.length > 0) assertEqual(r[0].confidence < 0.1, true);
  });
});

describe('Scenario: 消息堆积 - 缺失', function () {
  it('计数缺失 → 置信度0.5', function () {
    const r = evaluate({}, RULES);
    assertGreaterThan(r.length, 0);
    assertEqual(r[0].confidence, 0.5);
  });
});
