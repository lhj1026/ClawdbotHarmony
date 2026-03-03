'use strict';
/**
 * Vehicle & Motion scenario tests
 * Covers:
 *   t2_driving_bt            — bt_in_vehicle=true
 *   t2_commute_bt_morning    — bt_in_vehicle=true + timeOfDay=morning + isWeekend=false
 *   t2_walking_no_wifi       — step_count_today>=100 + wifiSsid="" + isCharging=false
 *   t0_critical_battery      — batteryLevel<=5 + isCharging=false
 *   t2_sedentary_reminder    — activityDuration>=2400 + step_count_today=0 + timeOfDay in [morning,afternoon]
 */

const { describe, it } = require('../../lib/test-runner');
const { assertEqual, assertGreaterThan, assertLessThan } = require('../../lib/assert');
const { evaluate } = require('./_helpers');

// ── Rules ──

const RULES = [
  {
    id: 't2_driving_bt',
    intent: 'driving_bluetooth_mode',
    priority: 't2',
    conditions: {
      bt_in_vehicle: { op: 'eq', value: true },
    },
  },
  {
    id: 't2_commute_bt_morning',
    intent: 'morning_commute_bluetooth',
    priority: 't2',
    conditions: {
      bt_in_vehicle: { op: 'eq', value: true },
      timeOfDay:     { op: 'eq', value: 'morning' },
      isWeekend:     { op: 'eq', value: false },
    },
  },
  {
    id: 't2_walking_no_wifi',
    intent: 'walking_outdoors_hint',
    priority: 't2',
    conditions: {
      step_count_today: { op: 'gte', value: 100 },
      wifiSsid:         { op: 'eq', value: '' },
      isCharging:       { op: 'eq', value: false },
    },
  },
  {
    id: 't0_critical_battery',
    intent: 'critical_battery_warning',
    priority: 't0',
    conditions: {
      batteryLevel: { op: 'lte', value: 5 },
      isCharging:   { op: 'eq', value: false },
    },
  },
  {
    id: 't2_sedentary_reminder',
    intent: 'sedentary_break_reminder',
    priority: 't2',
    conditions: {
      activityDuration:  { op: 'gte', value: 2400 },
      step_count_today:  { op: 'eq', value: 0 },
      timeOfDay:         { op: 'in', value: ['morning', 'afternoon'] },
    },
  },
];

// ── t2_driving_bt ──

describe('t2_driving_bt - positive', function () {
  it('Vehicle BT connected -> driving mode fires', function () {
    const r = evaluate({ bt_in_vehicle: true }, RULES);
    const hit = r.find(x => x.ruleId === 't2_driving_bt');
    assertEqual(hit != null, true);
    assertEqual(hit.intent, 'driving_bluetooth_mode');
    assertEqual(hit.confidence, 1.0);
  });
});

describe('t2_driving_bt - negative', function () {
  it('Vehicle BT not connected -> driving mode does NOT fire', function () {
    const r = evaluate({ bt_in_vehicle: false }, RULES);
    const hit = r.find(x => x.ruleId === 't2_driving_bt');
    assertEqual(hit, undefined);
  });
});

// ── t2_commute_bt_morning ──

describe('t2_commute_bt_morning - positive', function () {
  it('Vehicle BT + weekday morning -> morning commute BT fires', function () {
    const r = evaluate({ bt_in_vehicle: true, timeOfDay: 'morning', isWeekend: false }, RULES);
    const hit = r.find(x => x.ruleId === 't2_commute_bt_morning');
    assertEqual(hit != null, true);
    assertEqual(hit.intent, 'morning_commute_bluetooth');
    assertEqual(hit.confidence, 1.0);
  });
});

describe('t2_commute_bt_morning - negative', function () {
  it('Vehicle BT + weekend morning -> morning commute BT does NOT fire', function () {
    const r = evaluate({ bt_in_vehicle: true, timeOfDay: 'morning', isWeekend: true }, RULES);
    const hit = r.find(x => x.ruleId === 't2_commute_bt_morning');
    assertEqual(hit, undefined);
  });
});

// ── t2_walking_no_wifi ──

describe('t2_walking_no_wifi - positive', function () {
  it('500 steps, no WiFi, not charging -> walking outdoors fires', function () {
    const r = evaluate({ step_count_today: 500, wifiSsid: '', isCharging: false }, RULES);
    const hit = r.find(x => x.ruleId === 't2_walking_no_wifi');
    assertEqual(hit != null, true);
    assertEqual(hit.intent, 'walking_outdoors_hint');
    assertEqual(hit.confidence, 1.0);
  });
});

describe('t2_walking_no_wifi - negative', function () {
  it('500 steps but connected to WiFi -> walking outdoors does NOT fire', function () {
    const r = evaluate({ step_count_today: 500, wifiSsid: 'HomeNet', isCharging: false }, RULES);
    const hit = r.find(x => x.ruleId === 't2_walking_no_wifi');
    assertEqual(hit, undefined);
  });
});

// ── t0_critical_battery ──

describe('t0_critical_battery - positive', function () {
  it('3% not charging -> critical battery fires', function () {
    const r = evaluate({ batteryLevel: 3, isCharging: false }, RULES);
    const hit = r.find(x => x.ruleId === 't0_critical_battery');
    assertEqual(hit != null, true);
    assertEqual(hit.intent, 'critical_battery_warning');
    assertEqual(hit.confidence, 1.0);
  });
});

describe('t0_critical_battery - negative', function () {
  it('3% but charging -> critical battery does NOT fire', function () {
    const r = evaluate({ batteryLevel: 3, isCharging: true }, RULES);
    const hit = r.find(x => x.ruleId === 't0_critical_battery');
    assertEqual(hit, undefined);
  });
});

// ── t2_sedentary_reminder ──

describe('t2_sedentary_reminder - positive', function () {
  it('2400s idle, 0 steps, afternoon -> sedentary reminder fires', function () {
    const r = evaluate({ activityDuration: 2400, step_count_today: 0, timeOfDay: 'afternoon' }, RULES);
    const hit = r.find(x => x.ruleId === 't2_sedentary_reminder');
    assertEqual(hit != null, true);
    assertEqual(hit.intent, 'sedentary_break_reminder');
    assertEqual(hit.confidence, 1.0);
  });
});

describe('t2_sedentary_reminder - negative', function () {
  it('2400s idle, 0 steps, evening -> sedentary reminder does NOT fire', function () {
    const r = evaluate({ activityDuration: 2400, step_count_today: 0, timeOfDay: 'evening' }, RULES);
    const hit = r.find(x => x.ruleId === 't2_sedentary_reminder');
    assertEqual(hit, undefined);
  });
});
