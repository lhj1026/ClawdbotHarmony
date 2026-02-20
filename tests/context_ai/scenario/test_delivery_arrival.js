'use strict';
/**
 * 📦 快递到达场景测试
 * 对应设计文档: §2.3 - 快递到达
 * 触发: 快递通知(到达关键词) + 在家
 */
const { describe, it } = require('../../lib/test-runner');
const { assertEqual, assertGreaterThan } = require('../../lib/assert');
const { evaluate } = require('./_helpers');

const RULES = [{
  id: 'rule_delivery', intent: 'delivery_arrival', priority: '🟢',
  conditions: {
    notificationType: { op: 'eq', value: 'delivery_arrived' },
    geofence: { op: 'eq', value: 'home' },
  },
}];

describe('Scenario: 快递到达 - 匹配', function () {
  it('在家收到快递到达通知 → 触发', function () {
    const r = evaluate({ notificationType: 'delivery_arrived', geofence: 'home' }, RULES);
    assertEqual(r[0].intent, 'delivery_arrival');
  });
});

describe('Scenario: 快递到达 - 不匹配', function () {
  it('在公司 → 不触发', function () {
    assertEqual(evaluate({ notificationType: 'delivery_arrived', geofence: 'office' }, RULES).length, 0);
  });
  it('快递在途 → 不触发', function () {
    assertEqual(evaluate({ notificationType: 'delivery_enroute', geofence: 'home' }, RULES).length, 0);
  });
});

describe('Scenario: 快递到达 - 缺失', function () {
  it('位置未知 → 置信度0.5', function () {
    const r = evaluate({ notificationType: 'delivery_arrived' }, RULES);
    assertGreaterThan(r.length, 0);
    assertEqual(r[0].confidence, 0.5);
  });
});
