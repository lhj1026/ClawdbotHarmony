'use strict';
/**
 * 🏃 运动提醒场景测试
 * 对应设计文档: §2.3 - 运动提醒
 * 触发: 久坐>2小时(stationary_duration >= 120min)
 */
const { describe, it } = require('../../lib/test-runner');
const { assertEqual, assertGreaterThan, assertLessThan } = require('../../lib/assert');
const { evaluate } = require('./_helpers');

const RULES = [{
  id: 'rule_exercise', intent: 'exercise_reminder', priority: '🟢',
  conditions: {
    motionState: { op: 'eq', value: 'stationary' },
    stationaryMinutes: { op: 'gte', value: 120 },
  },
}];

describe('Scenario: 运动提醒 - 匹配', function () {
  it('静坐150分钟 → 触发', function () {
    const r = evaluate({ motionState: 'stationary', stationaryMinutes: 150 }, RULES);
    assertEqual(r[0].intent, 'exercise_reminder');
  });
  it('静坐恰好120分钟 → 触发', function () {
    assertEqual(evaluate({ motionState: 'stationary', stationaryMinutes: 120 }, RULES)[0].confidence, 1.0);
  });
});

describe('Scenario: 运动提醒 - 不匹配', function () {
  it('走路中 → 不触发', function () {
    assertEqual(evaluate({ motionState: 'walking', stationaryMinutes: 150 }, RULES).length, 0);
  });
  it('静坐30分钟 → 不触发或低置信度', function () {
    const r = evaluate({ motionState: 'stationary', stationaryMinutes: 30 }, RULES);
    if (r.length > 0) assertLessThan(r[0].confidence, 0.1);
  });
});

describe('Scenario: 运动提醒 - 边界', function () {
  it('118分钟 → 衰减', function () {
    const r = evaluate({ motionState: 'stationary', stationaryMinutes: 118 }, RULES);
    assertGreaterThan(r.length, 0);
    assertLessThan(r[0].confidence, 1.0);
    assertGreaterThan(r[0].confidence, 0.3);
  });
});
