'use strict';
/**
 * 🚗 通勤提醒场景测试
 * 对应设计文档: §2.3 核心用例清单 - 通勤提醒
 * 触发条件: 工作日 + 7:00±30min + 在家
 */

const { describe, it } = require('../../lib/test-runner');
const { assertEqual, assertTrue, assertGreaterThan, assertLessThan } = require('../../lib/assert');

// ── 场景引擎（简化版，镜像 C++ evaluate 逻辑） ──

function gaussianDecay(diff, tolerance) {
  if (diff <= tolerance) return 1.0;
  return Math.exp(-0.5 * ((diff - tolerance) / 1.0) ** 2);
}

function evaluate(snapshot, rules) {
  const results = [];
  for (const rule of rules) {
    let confidence = 1.0;
    for (const [key, cond] of Object.entries(rule.conditions)) {
      const actual = snapshot[key];
      if (actual == null) { confidence *= 0.5; continue; }
      switch (cond.op) {
        case 'eq': confidence *= (actual === cond.value) ? 1.0 : 0.0; break;
        case 'neq': confidence *= (actual !== cond.value) ? 1.0 : 0.0; break;
        case 'in': confidence *= cond.value.includes(actual) ? 1.0 : 0.0; break;
        case 'range': {
          const mid = (cond.value[0] + cond.value[1]) / 2;
          const half = (cond.value[1] - cond.value[0]) / 2;
          confidence *= gaussianDecay(Math.abs(actual - mid), half);
          break;
        }
        case 'lte': confidence *= actual <= cond.value ? 1.0 : Math.max(0, 1 - (actual - cond.value) / 3); break;
      }
      if (confidence < 0.01) break;
    }
    if (confidence > 0.01) results.push({ ruleId: rule.id, confidence, intent: rule.intent });
  }
  return results.sort((a, b) => b.confidence - a.confidence);
}

const COMMUTE_RULE = {
  id: 'rule_morning_workday',
  intent: 'commute_reminder',
  conditions: {
    timeOfDay: { op: 'eq', value: 'morning' },
    isWeekend: { op: 'eq', value: false },
    motionState: { op: 'in', value: ['walking', 'driving', 'transit'] },
  },
};

const RULES = [COMMUTE_RULE];

// ── 测试 ──

describe('Scenario: 通勤提醒 - 匹配', function () {
  it('工作日早上走路出门 → 触发', function () {
    const r = evaluate({ timeOfDay: 'morning', isWeekend: false, motionState: 'walking' }, RULES);
    assertEqual(r.length, 1);
    assertEqual(r[0].intent, 'commute_reminder');
    assertEqual(r[0].confidence, 1.0);
  });

  it('工作日早上开车 → 触发', function () {
    const r = evaluate({ timeOfDay: 'morning', isWeekend: false, motionState: 'driving' }, RULES);
    assertEqual(r[0].intent, 'commute_reminder');
  });

  it('工作日早上坐公交 → 触发', function () {
    const r = evaluate({ timeOfDay: 'morning', isWeekend: false, motionState: 'transit' }, RULES);
    assertEqual(r[0].intent, 'commute_reminder');
  });
});

describe('Scenario: 通勤提醒 - 不匹配', function () {
  it('周末早上 → 不触发', function () {
    const r = evaluate({ timeOfDay: 'morning', isWeekend: true, motionState: 'walking' }, RULES);
    assertEqual(r.length, 0);
  });

  it('工作日下午 → 不触发', function () {
    const r = evaluate({ timeOfDay: 'afternoon', isWeekend: false, motionState: 'walking' }, RULES);
    assertEqual(r.length, 0);
  });

  it('工作日早上跑步 → 不触发（不是通勤）', function () {
    const r = evaluate({ timeOfDay: 'morning', isWeekend: false, motionState: 'running' }, RULES);
    assertEqual(r.length, 0);
  });

  it('工作日早上静止 → 不触发', function () {
    const r = evaluate({ timeOfDay: 'morning', isWeekend: false, motionState: 'stationary' }, RULES);
    assertEqual(r.length, 0);
  });
});

describe('Scenario: 通勤提醒 - 边界/缺失', function () {
  it('运动状态缺失 → 置信度×0.5', function () {
    const r = evaluate({ timeOfDay: 'morning', isWeekend: false }, RULES);
    assertGreaterThan(r.length, 0);
    assertEqual(r[0].confidence, 0.5);
  });

  it('全部缺失 → 低置信度', function () {
    const r = evaluate({}, RULES);
    if (r.length > 0) assertLessThan(r[0].confidence, 0.2);
  });
});
