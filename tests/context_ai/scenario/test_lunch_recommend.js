'use strict';
/**
 * 🍜 午餐推荐场景测试
 * 对应设计文档: §2.3 - 午餐推荐
 * 触发: 工作日 + 12:00±1h + 在公司
 */
const { describe, it } = require('../../lib/test-runner');
const { assertEqual, assertGreaterThan } = require('../../lib/assert');
const { evaluate } = require('./_helpers');

const RULES = [{
  id: 'rule_lunch', intent: 'lunch_recommend', priority: '🟢',
  conditions: {
    timeOfDay: { op: 'eq', value: 'noon' },
    isWeekend: { op: 'eq', value: false },
    geofence: { op: 'eq', value: 'office' },
  },
}];

describe('Scenario: 午餐推荐 - 匹配', function () {
  it('工作日中午在公司 → 触发', function () {
    const r = evaluate({ timeOfDay: 'noon', isWeekend: false, geofence: 'office' }, RULES);
    assertEqual(r[0].intent, 'lunch_recommend');
    assertEqual(r[0].confidence, 1.0);
  });
});

describe('Scenario: 午餐推荐 - 不匹配', function () {
  it('周末 → 不触发', function () {
    assertEqual(evaluate({ timeOfDay: 'noon', isWeekend: true, geofence: 'office' }, RULES).length, 0);
  });
  it('在家 → 不触发', function () {
    assertEqual(evaluate({ timeOfDay: 'noon', isWeekend: false, geofence: 'home' }, RULES).length, 0);
  });
  it('早上 → 不触发', function () {
    assertEqual(evaluate({ timeOfDay: 'morning', isWeekend: false, geofence: 'office' }, RULES).length, 0);
  });
});

describe('Scenario: 午餐推荐 - 缺失', function () {
  it('位置缺失 → 置信度0.5', function () {
    const r = evaluate({ timeOfDay: 'noon', isWeekend: false }, RULES);
    assertGreaterThan(r.length, 0);
    assertEqual(r[0].confidence, 0.5);
  });
});
