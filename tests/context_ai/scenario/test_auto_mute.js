'use strict';
/**
 * 🔇 自动静音场景测试
 * 对应设计文档: §2.3 - 自动静音
 * 触发: 进入会议室/电影院
 */
const { describe, it } = require('../../lib/test-runner');
const { assertEqual, assertGreaterThan } = require('../../lib/assert');
const { evaluate } = require('./_helpers');

const RULES = [{
  id: 'rule_auto_mute', intent: 'auto_mute', priority: '⚪',
  conditions: {
    geofence: { op: 'in', value: ['meeting_room', 'cinema', 'library', 'hospital'] },
  },
}];

describe('Scenario: 自动静音 - 匹配', function () {
  it('进入会议室 → 触发', function () {
    assertEqual(evaluate({ geofence: 'meeting_room' }, RULES)[0].intent, 'auto_mute');
  });
  it('进入电影院 → 触发', function () {
    assertEqual(evaluate({ geofence: 'cinema' }, RULES)[0].confidence, 1.0);
  });
  it('进入图书馆 → 触发', function () {
    assertEqual(evaluate({ geofence: 'library' }, RULES).length, 1);
  });
  it('进入医院 → 触发', function () {
    assertEqual(evaluate({ geofence: 'hospital' }, RULES).length, 1);
  });
});

describe('Scenario: 自动静音 - 不匹配', function () {
  it('在家 → 不触发', function () {
    assertEqual(evaluate({ geofence: 'home' }, RULES).length, 0);
  });
  it('在公司(非会议室) → 不触发', function () {
    assertEqual(evaluate({ geofence: 'office' }, RULES).length, 0);
  });
});

describe('Scenario: 自动静音 - 优先级', function () {
  it('优先级为⚪(背景)', function () {
    assertEqual(evaluate({ geofence: 'meeting_room' }, RULES)[0].priority, '⚪');
  });
});

describe('Scenario: 自动静音 - 缺失', function () {
  it('位置未知 → 置信度0.5', function () {
    const r = evaluate({}, RULES);
    assertGreaterThan(r.length, 0);
    assertEqual(r[0].confidence, 0.5);
  });
});
