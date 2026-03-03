'use strict';
/**
 * Airport / Flight scenario tests
 * Covers 6 rules from default_rules.json:
 *   airport_arrive, airport_boarding_soon, airport_boarding_now,
 *   airport_takeoff, airport_landing, airport_exit
 */

const { describe, it } = require('../../lib/test-runner');
const { assertEqual, assertGreaterThan, assertLessThan } = require('../../lib/assert');
const { evaluate } = require('./_helpers');

// ── Rules (mirror of default_rules.json, test-local format) ──

const RULES = [
  {
    id: 'airport_arrive',
    intent: 'airport_arrive',
    priority: '🟡',
    conditions: {
      wifiGeofence:      { op: 'eq', value: 'transit' },
      hasUpcomingFlight:  { op: 'eq', value: true },
    },
  },
  {
    id: 'airport_boarding_soon',
    intent: 'airport_boarding_soon',
    priority: '🔴',
    conditions: {
      wifiGeofence:       { op: 'eq',  value: 'transit' },
      flightCountdownMin: { op: 'range', value: [11, 45] },
    },
  },
  {
    id: 'airport_boarding_now',
    intent: 'airport_boarding_now',
    priority: '🔴',
    conditions: {
      wifiGeofence:       { op: 'eq',  value: 'transit' },
      flightCountdownMin: { op: 'lte', value: 10 },
    },
  },
  {
    id: 'airport_takeoff',
    intent: 'airport_takeoff',
    priority: '🔴',
    conditions: {
      wifiGeofence:       { op: 'eq',  value: 'transit' },
      flightCountdownMin: { op: 'range', value: [-30, 0] },
    },
  },
  {
    id: 'airport_landing',
    intent: 'airport_landing',
    priority: '🔴',
    conditions: {
      flightArrivalMin: { op: 'range', value: [-30, 10] },
    },
  },
  {
    id: 'airport_exit',
    intent: 'airport_exit',
    priority: '🟡',
    conditions: {
      wifiLost:         { op: 'eq', value: true },
      wifiLostCategory: { op: 'eq', value: 'transit' },
    },
  },
];

// ── airport_arrive ──

describe('airport_arrive - positive', function () {
  it('at transit geofence with upcoming flight -> triggers airport_arrive', function () {
    const r = evaluate({ wifiGeofence: 'transit', hasUpcomingFlight: true }, RULES);
    const hit = r.find(x => x.ruleId === 'airport_arrive');
    assertEqual(hit != null, true);
    assertEqual(hit.confidence, 1.0);
  });
});

describe('airport_arrive - negative', function () {
  it('at transit geofence but no upcoming flight -> does not trigger airport_arrive', function () {
    const r = evaluate({ wifiGeofence: 'transit', hasUpcomingFlight: false }, RULES);
    const hit = r.find(x => x.ruleId === 'airport_arrive');
    assertEqual(hit, undefined);
  });
});

// ── airport_boarding_soon ──

describe('airport_boarding_soon - positive', function () {
  it('at transit with flightCountdownMin=30 -> triggers boarding_soon', function () {
    const r = evaluate({ wifiGeofence: 'transit', flightCountdownMin: 30 }, RULES);
    const hit = r.find(x => x.ruleId === 'airport_boarding_soon');
    assertEqual(hit != null, true);
    assertGreaterThan(hit.confidence, 0.5);
  });
});

describe('airport_boarding_soon - negative', function () {
  it('at transit with flightCountdownMin=60 -> does not trigger boarding_soon (too far)', function () {
    const r = evaluate({ wifiGeofence: 'transit', flightCountdownMin: 60 }, RULES);
    const hit = r.find(x => x.ruleId === 'airport_boarding_soon');
    assertEqual(hit, undefined);
  });
});

// ── airport_boarding_now ──

describe('airport_boarding_now - positive', function () {
  it('at transit with flightCountdownMin=5 -> triggers boarding_now', function () {
    const r = evaluate({ wifiGeofence: 'transit', flightCountdownMin: 5 }, RULES);
    const hit = r.find(x => x.ruleId === 'airport_boarding_now');
    assertEqual(hit != null, true);
    assertEqual(hit.confidence, 1.0);
  });
});

describe('airport_boarding_now - negative', function () {
  it('at transit with flightCountdownMin=20 -> does not trigger boarding_now', function () {
    const r = evaluate({ wifiGeofence: 'transit', flightCountdownMin: 20 }, RULES);
    const hit = r.find(x => x.ruleId === 'airport_boarding_now');
    assertEqual(hit, undefined);
  });
});

// ── airport_takeoff ──

describe('airport_takeoff - positive', function () {
  it('at transit with flightCountdownMin=-10 -> triggers takeoff', function () {
    const r = evaluate({ wifiGeofence: 'transit', flightCountdownMin: -10 }, RULES);
    const hit = r.find(x => x.ruleId === 'airport_takeoff');
    assertEqual(hit != null, true);
    assertGreaterThan(hit.confidence, 0.5);
  });
});

describe('airport_takeoff - negative', function () {
  it('at transit with flightCountdownMin=-60 -> does not trigger takeoff (too long ago)', function () {
    const r = evaluate({ wifiGeofence: 'transit', flightCountdownMin: -60 }, RULES);
    const hit = r.find(x => x.ruleId === 'airport_takeoff');
    assertEqual(hit, undefined);
  });
});

// ── airport_landing ──

describe('airport_landing - positive', function () {
  it('flightArrivalMin=5 -> triggers landing', function () {
    const r = evaluate({ flightArrivalMin: 5 }, RULES);
    const hit = r.find(x => x.ruleId === 'airport_landing');
    assertEqual(hit != null, true);
    assertGreaterThan(hit.confidence, 0.5);
  });
});

describe('airport_landing - negative', function () {
  it('flightArrivalMin=60 -> does not trigger landing (too far away)', function () {
    const r = evaluate({ flightArrivalMin: 60 }, RULES);
    const hit = r.find(x => x.ruleId === 'airport_landing');
    assertEqual(hit, undefined);
  });
});

// ── airport_exit ──

describe('airport_exit - positive', function () {
  it('wifiLost from transit -> triggers airport_exit', function () {
    const r = evaluate({ wifiLost: true, wifiLostCategory: 'transit' }, RULES);
    const hit = r.find(x => x.ruleId === 'airport_exit');
    assertEqual(hit != null, true);
    assertEqual(hit.confidence, 1.0);
  });
});

describe('airport_exit - negative', function () {
  it('wifiLost from home -> does not trigger airport_exit', function () {
    const r = evaluate({ wifiLost: true, wifiLostCategory: 'home' }, RULES);
    const hit = r.find(x => x.ruleId === 'airport_exit');
    assertEqual(hit, undefined);
  });
});

// ── Boundary: flight countdown transitions ──

describe('Boundary: boarding_soon -> boarding_now transition at 10 min', function () {
  it('flightCountdownMin=10 triggers boarding_now with full confidence; boarding_soon decays', function () {
    const r = evaluate({ wifiGeofence: 'transit', flightCountdownMin: 10 }, RULES);
    const now  = r.find(x => x.ruleId === 'airport_boarding_now');
    const soon = r.find(x => x.ruleId === 'airport_boarding_soon');
    assertEqual(now != null, true);
    assertEqual(now.confidence, 1.0);
    // 10 is just outside range [11,45] -- gaussian decay means partial confidence
    if (soon) assertLessThan(soon.confidence, now.confidence);
  });
});

describe('Boundary: takeoff -> boarding_now transition at 0 min', function () {
  it('flightCountdownMin=0 triggers takeoff; boarding_now also fires (lte 10)', function () {
    const r = evaluate({ wifiGeofence: 'transit', flightCountdownMin: 0 }, RULES);
    const takeoff = r.find(x => x.ruleId === 'airport_takeoff');
    const now     = r.find(x => x.ruleId === 'airport_boarding_now');
    assertEqual(takeoff != null, true);
    assertGreaterThan(takeoff.confidence, 0.5);
    assertEqual(now != null, true);
    assertEqual(now.confidence, 1.0);
  });
});
