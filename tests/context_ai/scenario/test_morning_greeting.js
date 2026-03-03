'use strict';
/**
 * Morning Greeting scenario tests
 * Covers:
 *   t0_weekend_morning       — timeOfDay=morning + isWeekend=true
 *   t0_workday_morning       — timeOfDay=morning + isWeekend=false + isCharging=false
 *   t2_early_morning_lying   — isLyingDown=true + hour in [6,9) + activityDuration>=1800
 */

const { describe, it } = require('../../lib/test-runner');
const { assertEqual, assertGreaterThan, assertLessThan } = require('../../lib/assert');
const { evaluate } = require('./_helpers');

// ── Rules ──

const RULES = [
  {
    id: 't0_weekend_morning',
    intent: 'weekend_morning_greeting',
    priority: 't0',
    conditions: {
      timeOfDay:  { op: 'eq', value: 'morning' },
      isWeekend:  { op: 'eq', value: true },
    },
  },
  {
    id: 't0_workday_morning',
    intent: 'workday_morning_greeting',
    priority: 't0',
    conditions: {
      timeOfDay:  { op: 'eq', value: 'morning' },
      isWeekend:  { op: 'eq', value: false },
      isCharging: { op: 'eq', value: false },
    },
  },
  {
    id: 't2_early_morning_lying_reminder',
    intent: 'lying_too_long_reminder',
    priority: 't2',
    conditions: {
      isLyingDown:      { op: 'eq', value: true },
      hour:             { op: 'range', value: [6, 9] },
      activityDuration: { op: 'gte', value: 1800 },
    },
  },
];

// ── t0_weekend_morning ──

describe('t0_weekend_morning - positive', function () {
  it('Saturday morning -> weekend greeting fires', function () {
    const r = evaluate({ timeOfDay: 'morning', isWeekend: true }, RULES);
    const hit = r.find(x => x.ruleId === 't0_weekend_morning');
    assertEqual(hit != null, true);
    assertEqual(hit.intent, 'weekend_morning_greeting');
    assertEqual(hit.confidence, 1.0);
  });
});

describe('t0_weekend_morning - negative', function () {
  it('Weekday morning -> weekend greeting does NOT fire', function () {
    const r = evaluate({ timeOfDay: 'morning', isWeekend: false }, RULES);
    const hit = r.find(x => x.ruleId === 't0_weekend_morning');
    assertEqual(hit, undefined);
  });
});

// ── t0_workday_morning ──

describe('t0_workday_morning - positive', function () {
  it('Weekday morning, not charging -> workday greeting fires', function () {
    const r = evaluate({ timeOfDay: 'morning', isWeekend: false, isCharging: false }, RULES);
    const hit = r.find(x => x.ruleId === 't0_workday_morning');
    assertEqual(hit != null, true);
    assertEqual(hit.intent, 'workday_morning_greeting');
    assertEqual(hit.confidence, 1.0);
  });
});

describe('t0_workday_morning - negative', function () {
  it('Weekday morning, charging -> workday greeting does NOT fire', function () {
    const r = evaluate({ timeOfDay: 'morning', isWeekend: false, isCharging: true }, RULES);
    const hit = r.find(x => x.ruleId === 't0_workday_morning');
    assertEqual(hit, undefined);
  });
});

// ── t2_early_morning_lying_reminder ──

describe('t2_early_morning_lying_reminder - positive', function () {
  it('Lying down at 7:30, duration 2400s -> reminder fires', function () {
    const r = evaluate({ isLyingDown: true, hour: 7.5, activityDuration: 2400 }, RULES);
    const hit = r.find(x => x.ruleId === 't2_early_morning_lying_reminder');
    assertEqual(hit != null, true);
    assertEqual(hit.intent, 'lying_too_long_reminder');
    assertEqual(hit.confidence, 1.0);
  });
});

describe('t2_early_morning_lying_reminder - negative', function () {
  it('NOT lying down at 7:30 -> reminder does NOT fire', function () {
    const r = evaluate({ isLyingDown: false, hour: 7.5, activityDuration: 2400 }, RULES);
    const hit = r.find(x => x.ruleId === 't2_early_morning_lying_reminder');
    assertEqual(hit, undefined);
  });
});
