'use strict';
/**
 * 😴 睡眠建议场景测试
 * 对应设计文档: §2.3 - 睡眠建议
 * 触发: 连续3天23点后还在用手机（时序规则）
 */
const { describe, it } = require('../../lib/test-runner');
const { assertEqual, assertTrue, assertFalse } = require('../../lib/assert');

// 时序规则需要事件缓冲区
class SimpleEventBuffer {
  constructor() { this.events = []; }
  push(event, ts) { this.events.push({ event, ts }); }
  countInWindow(event, windowMs, now) {
    return this.events.filter(e => e.event === event && (now - e.ts) < windowMs).length;
  }
}

function checkSleepSuggestion(buffer, now) {
  const DAY_MS = 24 * 60 * 60 * 1000;
  // 检查最近3天是否都有 late_night_usage 事件
  const count = buffer.countInWindow('late_night_usage', 3 * DAY_MS, now);
  return count >= 3;
}

const NOW = Date.now();
const DAY = 24 * 60 * 60 * 1000;

describe('Scenario: 睡眠建议 - 匹配', function () {
  it('连续3天晚睡 → 触发', function () {
    const buf = new SimpleEventBuffer();
    buf.push('late_night_usage', NOW - 2 * DAY);
    buf.push('late_night_usage', NOW - 1 * DAY);
    buf.push('late_night_usage', NOW);
    assertTrue(checkSleepSuggestion(buf, NOW + 1000));
  });
});

describe('Scenario: 睡眠建议 - 不匹配', function () {
  it('只有2天晚睡 → 不触发', function () {
    const buf = new SimpleEventBuffer();
    buf.push('late_night_usage', NOW - 1 * DAY);
    buf.push('late_night_usage', NOW);
    assertFalse(checkSleepSuggestion(buf, NOW + 1000));
  });
  it('3天前的记录过期 → 不触发', function () {
    const buf = new SimpleEventBuffer();
    buf.push('late_night_usage', NOW - 4 * DAY);
    buf.push('late_night_usage', NOW - 1 * DAY);
    buf.push('late_night_usage', NOW);
    // 4天前的在3天窗口外
    assertFalse(checkSleepSuggestion(buf, NOW + 1000));
  });
});

describe('Scenario: 睡眠建议 - 边界', function () {
  it('恰好3天窗口边界', function () {
    const buf = new SimpleEventBuffer();
    buf.push('late_night_usage', NOW - 3 * DAY + 2000); // 刚好在窗口内
    buf.push('late_night_usage', NOW - 1 * DAY);
    buf.push('late_night_usage', NOW);
    assertTrue(checkSleepSuggestion(buf, NOW + 1000));
  });
});
