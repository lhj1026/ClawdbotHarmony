'use strict';
/**
 * 📅 会议准备场景测试
 * 对应设计文档: §2.3 - 会议准备
 * 触发: 日历事件前15min
 */
const { describe, it } = require('../../lib/test-runner');
const { assertEqual, assertGreaterThan, assertLessThan } = require('../../lib/assert');
const { evaluate } = require('./_helpers');

const RULES = [{
  id: 'rule_meeting', intent: 'meeting_prep', priority: '🟡',
  conditions: {
    calendarEventMinutes: { op: 'lte', value: 15 },
    hasUpcomingMeeting: { op: 'eq', value: true },
  },
}];

describe('Scenario: 会议准备 - 匹配', function () {
  it('会议10分钟后 → 触发', function () {
    const r = evaluate({ calendarEventMinutes: 10, hasUpcomingMeeting: true }, RULES);
    assertEqual(r[0].intent, 'meeting_prep');
  });
  it('会议1分钟后 → 触发', function () {
    assertEqual(evaluate({ calendarEventMinutes: 1, hasUpcomingMeeting: true }, RULES)[0].confidence, 1.0);
  });
});

describe('Scenario: 会议准备 - 不匹配', function () {
  it('无会议 → 不触发', function () {
    assertEqual(evaluate({ calendarEventMinutes: 10, hasUpcomingMeeting: false }, RULES).length, 0);
  });
  it('会议60分钟后 → 不触发或低置信度', function () {
    const r = evaluate({ calendarEventMinutes: 60, hasUpcomingMeeting: true }, RULES);
    if (r.length > 0) assertLessThan(r[0].confidence, 0.1);
  });
});

describe('Scenario: 会议准备 - 边界', function () {
  it('恰好15分钟 → confidence=1.0', function () {
    assertEqual(evaluate({ calendarEventMinutes: 15, hasUpcomingMeeting: true }, RULES)[0].confidence, 1.0);
  });
  it('16分钟 → 衰减', function () {
    const r = evaluate({ calendarEventMinutes: 16, hasUpcomingMeeting: true }, RULES);
    assertGreaterThan(r.length, 0);
    assertLessThan(r[0].confidence, 1.0);
  });
});
