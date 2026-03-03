'use strict';
/**
 * Arrival / Departure scenario tests
 * Covers tier-1 geofence rules from default_rules.json:
 *   t1_arrive_home, t1_arrive_work, t1_leave_home_morning,
 *   t1_arrive_transit, t1_arrive_restaurant, t1_arrive_gym
 */

const { describe, it } = require('../../lib/test-runner');
const { assertEqual, assertGreaterThan } = require('../../lib/assert');
const { evaluate } = require('./_helpers');

// ── Rules (mirroring default_rules.json conditions) ──

const RULES = [
  {
    id: 't1_arrive_home',
    intent: 'greet_home',
    priority: '1.5',
    conditions: {
      wifiGeofence: { op: 'eq', value: 'home' },
      timeOfDay:    { op: 'in', value: ['afternoon', 'evening', 'night'] },
    },
  },
  {
    id: 't1_arrive_work',
    intent: 'greet_work',
    priority: '1.8',
    conditions: {
      wifiGeofence: { op: 'eq', value: 'work' },
      isWeekend:    { op: 'eq', value: false },
    },
  },
  {
    id: 't1_leave_home_morning',
    intent: 'brief_leave_home',
    priority: '2.0',
    conditions: {
      wifiLostCategory: { op: 'eq', value: 'home' },
      timeOfDay:        { op: 'in', value: ['dawn', 'morning'] },
    },
  },
  {
    id: 't1_arrive_transit',
    intent: 'travel_info',
    priority: '2.5',
    conditions: {
      wifiGeofence: { op: 'eq', value: 'transit' },
    },
  },
  {
    id: 't1_arrive_restaurant',
    intent: 'restaurant_info',
    priority: '1.5',
    conditions: {
      wifiGeofence: { op: 'eq', value: 'restaurant' },
    },
  },
  {
    id: 't1_arrive_gym',
    intent: 'gym_start',
    priority: '1.5',
    conditions: {
      wifiGeofence: { op: 'eq', value: 'gym' },
    },
  },
];

// ── t1_arrive_home ──

describe('Scenario: t1_arrive_home - 匹配', function () {
  it('下午到家 wifiGeofence=home + timeOfDay=afternoon', function () {
    const r = evaluate({ wifiGeofence: 'home', timeOfDay: 'afternoon' }, RULES);
    assertGreaterThan(r.length, 0);
    assertEqual(r[0].ruleId, 't1_arrive_home');
    assertEqual(r[0].confidence, 1.0);
  });
});

describe('Scenario: t1_arrive_home - 不匹配', function () {
  it('早上到家 timeOfDay=morning 不在 afternoon/evening/night', function () {
    const r = evaluate({ wifiGeofence: 'home', timeOfDay: 'morning' }, RULES);
    const match = r.find(function (x) { return x.ruleId === 't1_arrive_home'; });
    assertEqual(match, undefined);
  });
});

// ── t1_arrive_work ──

describe('Scenario: t1_arrive_work - 匹配', function () {
  it('工作日到公司 wifiGeofence=work + isWeekend=false', function () {
    const r = evaluate({ wifiGeofence: 'work', isWeekend: false }, RULES);
    assertGreaterThan(r.length, 0);
    assertEqual(r[0].ruleId, 't1_arrive_work');
    assertEqual(r[0].confidence, 1.0);
  });
});

describe('Scenario: t1_arrive_work - 不匹配', function () {
  it('周末到公司 isWeekend=true 不触发', function () {
    const r = evaluate({ wifiGeofence: 'work', isWeekend: true }, RULES);
    const match = r.find(function (x) { return x.ruleId === 't1_arrive_work'; });
    assertEqual(match, undefined);
  });
});

// ── t1_leave_home_morning ──

describe('Scenario: t1_leave_home_morning - 匹配', function () {
  it('清晨离家 wifiLostCategory=home + timeOfDay=dawn', function () {
    const r = evaluate({ wifiLostCategory: 'home', timeOfDay: 'dawn' }, RULES);
    assertGreaterThan(r.length, 0);
    assertEqual(r[0].ruleId, 't1_leave_home_morning');
    assertEqual(r[0].confidence, 1.0);
  });
});

describe('Scenario: t1_leave_home_morning - 不匹配', function () {
  it('下午离家 timeOfDay=afternoon 不在 dawn/morning', function () {
    const r = evaluate({ wifiLostCategory: 'home', timeOfDay: 'afternoon' }, RULES);
    const match = r.find(function (x) { return x.ruleId === 't1_leave_home_morning'; });
    assertEqual(match, undefined);
  });
});

// ── t1_arrive_transit ──

describe('Scenario: t1_arrive_transit - 匹配', function () {
  it('到达交通枢纽 wifiGeofence=transit', function () {
    const r = evaluate({ wifiGeofence: 'transit' }, RULES);
    assertGreaterThan(r.length, 0);
    assertEqual(r[0].ruleId, 't1_arrive_transit');
    assertEqual(r[0].confidence, 1.0);
  });
});

describe('Scenario: t1_arrive_transit - 不匹配', function () {
  it('wifiGeofence=home 不触发 transit 规则', function () {
    const r = evaluate({ wifiGeofence: 'home', timeOfDay: 'morning' }, RULES);
    const match = r.find(function (x) { return x.ruleId === 't1_arrive_transit'; });
    assertEqual(match, undefined);
  });
});

// ── t1_arrive_restaurant ──

describe('Scenario: t1_arrive_restaurant - 匹配', function () {
  it('到达餐厅 wifiGeofence=restaurant', function () {
    const r = evaluate({ wifiGeofence: 'restaurant' }, RULES);
    assertGreaterThan(r.length, 0);
    assertEqual(r[0].ruleId, 't1_arrive_restaurant');
    assertEqual(r[0].confidence, 1.0);
  });
});

describe('Scenario: t1_arrive_restaurant - 不匹配', function () {
  it('wifiGeofence=work 不触发 restaurant 规则', function () {
    const r = evaluate({ wifiGeofence: 'work', isWeekend: false }, RULES);
    const match = r.find(function (x) { return x.ruleId === 't1_arrive_restaurant'; });
    assertEqual(match, undefined);
  });
});

// ── t1_arrive_gym ──

describe('Scenario: t1_arrive_gym - 匹配', function () {
  it('到达健身房 wifiGeofence=gym', function () {
    const r = evaluate({ wifiGeofence: 'gym' }, RULES);
    assertGreaterThan(r.length, 0);
    assertEqual(r[0].ruleId, 't1_arrive_gym');
    assertEqual(r[0].confidence, 1.0);
  });
});

describe('Scenario: t1_arrive_gym - 不匹配', function () {
  it('wifiGeofence=restaurant 不触发 gym 规则', function () {
    const r = evaluate({ wifiGeofence: 'restaurant' }, RULES);
    const match = r.find(function (x) { return x.ruleId === 't1_arrive_gym'; });
    assertEqual(match, undefined);
  });
});
