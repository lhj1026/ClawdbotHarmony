'use strict';
/**
 * 🔋 低电量场景测试
 * 对应设计文档: §2.3 - 低电量
 * 触发: 电量<20% + 未充电
 */
const { describe, it } = require('../../lib/test-runner');
const { assertEqual, assertGreaterThan, assertLessThan } = require('../../lib/assert');
const { evaluate } = require('./_helpers');

const RULES = [{
  id: 'rule_low_battery', intent: 'low_battery_alert', priority: '🟡',
  conditions: {
    batteryLevel: { op: 'lte', value: 20 },
    isCharging: { op: 'eq', value: false },
  },
}];

describe('Scenario: 低电量 - 匹配', function () {
  it('10% 未充电 → 触发', function () {
    const r = evaluate({ batteryLevel: 10, isCharging: false }, RULES);
    assertEqual(r[0].intent, 'low_battery_alert');
    assertEqual(r[0].confidence, 1.0);
  });
  it('20% 未充电 → 触发', function () {
    assertEqual(evaluate({ batteryLevel: 20, isCharging: false }, RULES)[0].confidence, 1.0);
  });
  it('5% 未充电 → 触发', function () {
    assertEqual(evaluate({ batteryLevel: 5, isCharging: false }, RULES)[0].confidence, 1.0);
  });
});

describe('Scenario: 低电量 - 不匹配', function () {
  it('充电中 → 不触发', function () {
    assertEqual(evaluate({ batteryLevel: 10, isCharging: true }, RULES).length, 0);
  });
  it('60% 未充电 → 不触发或极低置信度', function () {
    const r = evaluate({ batteryLevel: 60, isCharging: false }, RULES);
    if (r.length > 0) assertLessThan(r[0].confidence, 0.1);
  });
});

describe('Scenario: 低电量 - 边界', function () {
  it('21% → 衰减（soft match）', function () {
    const r = evaluate({ batteryLevel: 21, isCharging: false }, RULES);
    assertGreaterThan(r.length, 0);
    assertLessThan(r[0].confidence, 1.0);
    assertGreaterThan(r[0].confidence, 0.5);
  });
  it('15% 恰好边界 → confidence=1.0', function () {
    assertEqual(evaluate({ batteryLevel: 15, isCharging: false }, RULES)[0].confidence, 1.0);
  });
});
