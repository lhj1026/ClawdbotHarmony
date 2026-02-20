'use strict';
/**
 * 🌙 睡前摘要场景测试
 * 对应设计文档: §2.3 - 睡前摘要
 * 触发: 22:00-24:00 + 在家
 */
const { describe, it } = require('../../lib/test-runner');
const { assertEqual, assertGreaterThan, assertLessThan } = require('../../lib/assert');
const { evaluate } = require('./_helpers');

const RULES = [{
  id: 'rule_bedtime', intent: 'bedtime_summary', priority: '🟢',
  conditions: {
    hour: { op: 'range', value: [22, 24] },
    geofence: { op: 'eq', value: 'home' },
    motionState: { op: 'eq', value: 'stationary' },
  },
}];

describe('Scenario: 睡前摘要 - 匹配', function () {
  it('23:00 在家静止 → 触发', function () {
    const r = evaluate({ hour: 23, geofence: 'home', motionState: 'stationary' }, RULES);
    assertEqual(r[0].intent, 'bedtime_summary');
    assertEqual(r[0].confidence, 1.0);
  });
  it('22:00 在家 → 触发', function () {
    assertEqual(evaluate({ hour: 22, geofence: 'home', motionState: 'stationary' }, RULES)[0].confidence, 1.0);
  });
});

describe('Scenario: 睡前摘要 - 不匹配', function () {
  it('在公司 → 不触发', function () {
    assertEqual(evaluate({ hour: 23, geofence: 'office', motionState: 'stationary' }, RULES).length, 0);
  });
  it('下午 → 不触发', function () {
    const r = evaluate({ hour: 15, geofence: 'home', motionState: 'stationary' }, RULES);
    if (r.length > 0) assertLessThan(r[0].confidence, 0.1);
  });
});

describe('Scenario: 睡前摘要 - 边界', function () {
  it('21:00 → 衰减（range边界外）', function () {
    const r = evaluate({ hour: 21, geofence: 'home', motionState: 'stationary' }, RULES);
    assertGreaterThan(r.length, 0);
    assertLessThan(r[0].confidence, 1.0);
    assertGreaterThan(r[0].confidence, 0.3);
  });
});
