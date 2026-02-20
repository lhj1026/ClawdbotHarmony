'use strict';
/**
 * 🚗 回家路况场景测试
 * 对应设计文档: §2.3 - 回家路况
 * 触发: 离开公司 + 上车(driving)
 */
const { describe, it } = require('../../lib/test-runner');
const { assertEqual } = require('../../lib/assert');
const { evaluate } = require('./_helpers');

const RULES = [{
  id: 'rule_go_home', intent: 'go_home_traffic', priority: '🟡',
  conditions: {
    timeOfDay: { op: 'eq', value: 'evening' },
    motionState: { op: 'in', value: ['driving', 'transit'] },
    isWeekend: { op: 'eq', value: false },
  },
}];

describe('Scenario: 回家路况 - 匹配', function () {
  it('傍晚开车工作日 → 触发', function () {
    const r = evaluate({ timeOfDay: 'evening', motionState: 'driving', isWeekend: false }, RULES);
    assertEqual(r[0].intent, 'go_home_traffic');
  });
  it('傍晚公交 → 触发', function () {
    assertEqual(evaluate({ timeOfDay: 'evening', motionState: 'transit', isWeekend: false }, RULES).length, 1);
  });
});

describe('Scenario: 回家路况 - 不匹配', function () {
  it('周末 → 不触发', function () {
    assertEqual(evaluate({ timeOfDay: 'evening', motionState: 'driving', isWeekend: true }, RULES).length, 0);
  });
  it('早上 → 不触发', function () {
    assertEqual(evaluate({ timeOfDay: 'morning', motionState: 'driving', isWeekend: false }, RULES).length, 0);
  });
  it('步行 → 不触发', function () {
    assertEqual(evaluate({ timeOfDay: 'evening', motionState: 'walking', isWeekend: false }, RULES).length, 0);
  });
});
