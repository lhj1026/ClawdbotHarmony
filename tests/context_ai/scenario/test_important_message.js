'use strict';
/**
 * 📱 重要消息场景测试
 * 对应设计文档: §2.3 - 重要消息
 * 触发: 老婆/老板发消息 → 紧急通知
 */
const { describe, it } = require('../../lib/test-runner');
const { assertEqual, assertGreaterThan } = require('../../lib/assert');
const { evaluate } = require('./_helpers');

const RULES = [{
  id: 'rule_important_msg', intent: 'important_message', priority: '🔴',
  conditions: {
    sender: { op: 'in', value: ['老婆', '老板', 'boss', 'wife'] },
  },
}];

describe('Scenario: 重要消息 - 匹配', function () {
  it('老婆发消息 → 紧急触发', function () {
    const r = evaluate({ sender: '老婆' }, RULES);
    assertEqual(r[0].intent, 'important_message');
    assertEqual(r[0].priority, '🔴');
  });
  it('老板发消息 → 触发', function () {
    assertEqual(evaluate({ sender: '老板' }, RULES)[0].confidence, 1.0);
  });
  it('boss → 触发', function () {
    assertEqual(evaluate({ sender: 'boss' }, RULES).length, 1);
  });
});

describe('Scenario: 重要消息 - 不匹配', function () {
  it('同事 → 不触发', function () {
    assertEqual(evaluate({ sender: '同事A' }, RULES).length, 0);
  });
  it('未知发送者 → 不触发', function () {
    assertEqual(evaluate({ sender: 'random' }, RULES).length, 0);
  });
});

describe('Scenario: 重要消息 - 优先级', function () {
  it('与低优先级规则同时匹配时排在前面', function () {
    const rules = [
      ...RULES,
      { id: 'rule_generic', intent: 'generic', priority: '🟢', conditions: {} },
    ];
    const r = evaluate({ sender: '老婆' }, rules);
    assertEqual(r[0].intent, 'important_message');
  });
});
