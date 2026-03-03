'use strict';
/**
 * 🏠 在家日常场景测试
 * 对应 default_rules.json 中的四条 home 规则:
 *   t1_home_lunch, t1_home_dinner,
 *   t1_home_evening_relax, t1_home_night_charging
 */
const { describe, it } = require('../../lib/test-runner');
const { assertEqual, assertGreaterThan, assertLessThan } = require('../../lib/assert');
const { evaluate } = require('./_helpers');

const RULES = [
  {
    id: 't1_home_lunch', intent: 'suggest_lunch', priority: 1.5,
    conditions: {
      wifiGeofence: { op: 'eq', value: 'home' },
      hour:         { op: 'gte', value: 11 },
      hour_upper:   { op: 'lte', value: 13 },
    },
  },
  {
    id: 't1_home_dinner', intent: 'suggest_dinner', priority: 1.5,
    conditions: {
      wifiGeofence: { op: 'eq', value: 'home' },
      hour:         { op: 'gte', value: 17 },
      hour_upper:   { op: 'lte', value: 19 },
    },
  },
  {
    id: 't1_home_evening_relax', intent: 'suggest_relax', priority: 1.0,
    conditions: {
      wifiGeofence: { op: 'eq', value: 'home' },
      hour:         { op: 'gte', value: 20 },
      hour_upper:   { op: 'lte', value: 22 },
      motionState:  { op: 'eq', value: 'still' },
    },
  },
  {
    id: 't1_home_night_charging', intent: 'set_sleep_mode', priority: 2.0,
    conditions: {
      wifiGeofence: { op: 'eq', value: 'home' },
      hour:         { op: 'gte', value: 23 },
      isCharging:   { op: 'eq', value: true },
    },
  },
];

// ---------------------------------------------------------------------------
// t1_home_lunch: wifiGeofence=home + hour>=11 + hour<=13
// ---------------------------------------------------------------------------

describe('Scenario: 在家午餐 - 正向匹配', function () {
  it('12:00 在家 → 触发 suggest_lunch', function () {
    const r = evaluate({ wifiGeofence: 'home', hour: 12, hour_upper: 12 }, RULES);
    const hit = r.find(m => m.ruleId === 't1_home_lunch');
    assertEqual(hit.intent, 'suggest_lunch');
    assertEqual(hit.confidence, 1.0);
  });
});

describe('Scenario: 在家午餐 - 负向不匹配', function () {
  it('12:00 在公司 → 不触发', function () {
    const r = evaluate({ wifiGeofence: 'office', hour: 12, hour_upper: 12 }, RULES);
    const hit = r.find(m => m.ruleId === 't1_home_lunch');
    assertEqual(hit, undefined);
  });
});

describe('Scenario: 在家午餐 - 边界', function () {
  it('hour=11（gte 边界） → 置信度 1.0', function () {
    const r = evaluate({ wifiGeofence: 'home', hour: 11, hour_upper: 11 }, RULES);
    const hit = r.find(m => m.ruleId === 't1_home_lunch');
    assertEqual(hit.confidence, 1.0);
  });
  it('hour=14（超出 lte 13） → 衰减', function () {
    const r = evaluate({ wifiGeofence: 'home', hour: 14, hour_upper: 14 }, RULES);
    const hit = r.find(m => m.ruleId === 't1_home_lunch');
    if (hit) assertLessThan(hit.confidence, 1.0);
  });
});

// ---------------------------------------------------------------------------
// t1_home_dinner: wifiGeofence=home + hour>=17 + hour<=19
// ---------------------------------------------------------------------------

describe('Scenario: 在家晚餐 - 正向匹配', function () {
  it('18:00 在家 → 触发 suggest_dinner', function () {
    const r = evaluate({ wifiGeofence: 'home', hour: 18, hour_upper: 18 }, RULES);
    const hit = r.find(m => m.ruleId === 't1_home_dinner');
    assertEqual(hit.intent, 'suggest_dinner');
    assertEqual(hit.confidence, 1.0);
  });
});

describe('Scenario: 在家晚餐 - 负向不匹配', function () {
  it('12:00 在家 → 不触发晚餐（时间不对）', function () {
    const r = evaluate({ wifiGeofence: 'home', hour: 12, hour_upper: 12 }, RULES);
    const hit = r.find(m => m.ruleId === 't1_home_dinner');
    assertEqual(hit, undefined);
  });
});

describe('Scenario: 在家晚餐 - 边界', function () {
  it('hour=17（gte 边界） → 置信度 1.0', function () {
    const r = evaluate({ wifiGeofence: 'home', hour: 17, hour_upper: 17 }, RULES);
    const hit = r.find(m => m.ruleId === 't1_home_dinner');
    assertEqual(hit.confidence, 1.0);
  });
  it('hour=20（超出 lte 19） → 衰减', function () {
    const r = evaluate({ wifiGeofence: 'home', hour: 20, hour_upper: 20 }, RULES);
    const hit = r.find(m => m.ruleId === 't1_home_dinner');
    if (hit) assertLessThan(hit.confidence, 1.0);
  });
});

// ---------------------------------------------------------------------------
// t1_home_evening_relax: wifiGeofence=home + hour>=20 + hour<=22 + motionState=still
// ---------------------------------------------------------------------------

describe('Scenario: 在家晚间放松 - 正向匹配', function () {
  it('21:00 在家静止 → 触发 suggest_relax', function () {
    const r = evaluate({ wifiGeofence: 'home', hour: 21, hour_upper: 21, motionState: 'still' }, RULES);
    const hit = r.find(m => m.ruleId === 't1_home_evening_relax');
    assertEqual(hit.intent, 'suggest_relax');
    assertEqual(hit.confidence, 1.0);
  });
});

describe('Scenario: 在家晚间放松 - 负向不匹配', function () {
  it('21:00 在家走动 → 不触发（motionState 不匹配）', function () {
    const r = evaluate({ wifiGeofence: 'home', hour: 21, hour_upper: 21, motionState: 'walking' }, RULES);
    const hit = r.find(m => m.ruleId === 't1_home_evening_relax');
    assertEqual(hit, undefined);
  });
});

describe('Scenario: 在家晚间放松 - 边界', function () {
  it('hour=20（gte 边界） → 置信度 1.0', function () {
    const r = evaluate({ wifiGeofence: 'home', hour: 20, hour_upper: 20, motionState: 'still' }, RULES);
    const hit = r.find(m => m.ruleId === 't1_home_evening_relax');
    assertEqual(hit.confidence, 1.0);
  });
  it('hour=23（超出 lte 22） → 衰减', function () {
    const r = evaluate({ wifiGeofence: 'home', hour: 23, hour_upper: 23, motionState: 'still' }, RULES);
    const hit = r.find(m => m.ruleId === 't1_home_evening_relax');
    if (hit) assertLessThan(hit.confidence, 1.0);
  });
});

// ---------------------------------------------------------------------------
// t1_home_night_charging: wifiGeofence=home + hour>=23 + isCharging=true
// ---------------------------------------------------------------------------

describe('Scenario: 在家夜间充电 - 正向匹配', function () {
  it('23:30 在家充电 → 触发 set_sleep_mode', function () {
    const r = evaluate({ wifiGeofence: 'home', hour: 23, isCharging: true }, RULES);
    const hit = r.find(m => m.ruleId === 't1_home_night_charging');
    assertEqual(hit.intent, 'set_sleep_mode');
    assertEqual(hit.confidence, 1.0);
  });
});

describe('Scenario: 在家夜间充电 - 负向不匹配', function () {
  it('23:00 在家未充电 → 不触发', function () {
    const r = evaluate({ wifiGeofence: 'home', hour: 23, isCharging: false }, RULES);
    const hit = r.find(m => m.ruleId === 't1_home_night_charging');
    assertEqual(hit, undefined);
  });
});

describe('Scenario: 在家夜间充电 - 边界', function () {
  it('hour=22 充电在家 → 衰减（未达 gte 23）', function () {
    const r = evaluate({ wifiGeofence: 'home', hour: 22, isCharging: true }, RULES);
    const hit = r.find(m => m.ruleId === 't1_home_night_charging');
    assertGreaterThan(hit.confidence, 0);
    assertLessThan(hit.confidence, 1.0);
  });
});
