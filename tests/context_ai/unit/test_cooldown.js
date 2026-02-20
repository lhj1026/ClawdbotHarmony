'use strict';
/**
 * Cooldown 管理器测试
 * 对应设计文档: §6.6 Cooldown + 合并推送
 * 覆盖: 冷却判断/合并事件/重置事件/scope区分/过期清理
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertFalse
} = require('../../lib/assert');

// ── JS 镜像：CooldownManager（C++ rule_engine.cpp） ──

class CooldownManager {
  constructor() {
    this.lastFired = new Map();   // ruleId → timestamp
    this.mergeQueues = new Map(); // ruleId → events[]
  }

  /** 加载规则时清空（修复：§8.4） */
  reset() {
    this.lastFired.clear();
    this.mergeQueues.clear();
  }

  /** 是否在冷却中 */
  isInCooldown(ruleId, config, now) {
    if (!config || !config.duration) return false;
    const last = this.lastFired.get(ruleId);
    if (last == null) return false;
    return (now - last) < config.duration;
  }

  /** 开始冷却 */
  startCooldown(ruleId, now) {
    this.lastFired.set(ruleId, now);
  }

  /** 重置冷却（某事件触发重置） */
  resetCooldown(ruleId) {
    this.lastFired.delete(ruleId);
    this.mergeQueues.delete(ruleId);
  }

  /** 合并事件（冷却期间累积） */
  mergeEvent(ruleId, event) {
    if (!this.mergeQueues.has(ruleId)) this.mergeQueues.set(ruleId, []);
    this.mergeQueues.get(ruleId).push(event);
  }

  /** 获取合并队列 */
  getMergedEvents(ruleId) {
    return this.mergeQueues.get(ruleId) || [];
  }

  /** 清空合并队列 */
  clearMerged(ruleId) {
    this.mergeQueues.delete(ruleId);
  }
}

// ── 测试 ──

describe('Cooldown - 冷却判断', function () {
  it('首次触发 → 不在冷却中', function () {
    const cm = new CooldownManager();
    assertFalse(cm.isInCooldown('rule1', { duration: 60000 }, 1000));
  });

  it('刚触发 → 在冷却中', function () {
    const cm = new CooldownManager();
    cm.startCooldown('rule1', 1000);
    assertTrue(cm.isInCooldown('rule1', { duration: 60000 }, 2000));
  });

  it('冷却过期 → 不在冷却中', function () {
    const cm = new CooldownManager();
    cm.startCooldown('rule1', 1000);
    assertFalse(cm.isInCooldown('rule1', { duration: 60000 }, 70000));
  });

  it('恰好过期边界', function () {
    const cm = new CooldownManager();
    cm.startCooldown('rule1', 0);
    assertTrue(cm.isInCooldown('rule1', { duration: 1000 }, 999));
    assertFalse(cm.isInCooldown('rule1', { duration: 1000 }, 1000));
  });

  it('无cooldown配置 → 不冷却', function () {
    const cm = new CooldownManager();
    cm.startCooldown('rule1', 0);
    assertFalse(cm.isInCooldown('rule1', null, 100));
    assertFalse(cm.isInCooldown('rule1', {}, 100));
  });
});

describe('Cooldown - 合并事件', function () {
  it('冷却中累积事件', function () {
    const cm = new CooldownManager();
    cm.mergeEvent('rule1', { type: 'notification', text: 'msg1' });
    cm.mergeEvent('rule1', { type: 'notification', text: 'msg2' });
    assertEqual(cm.getMergedEvents('rule1').length, 2);
  });

  it('不同规则独立队列', function () {
    const cm = new CooldownManager();
    cm.mergeEvent('rule1', { text: 'a' });
    cm.mergeEvent('rule2', { text: 'b' });
    assertEqual(cm.getMergedEvents('rule1').length, 1);
    assertEqual(cm.getMergedEvents('rule2').length, 1);
  });

  it('清空合并队列', function () {
    const cm = new CooldownManager();
    cm.mergeEvent('rule1', { text: 'a' });
    cm.clearMerged('rule1');
    assertEqual(cm.getMergedEvents('rule1').length, 0);
  });

  it('空队列 → 空数组', function () {
    const cm = new CooldownManager();
    assertEqual(cm.getMergedEvents('nonexistent').length, 0);
  });
});

describe('Cooldown - 重置', function () {
  it('resetCooldown 清除冷却', function () {
    const cm = new CooldownManager();
    cm.startCooldown('rule1', 1000);
    assertTrue(cm.isInCooldown('rule1', { duration: 60000 }, 2000));
    cm.resetCooldown('rule1');
    assertFalse(cm.isInCooldown('rule1', { duration: 60000 }, 2000));
  });

  it('reset() 清空所有', function () {
    const cm = new CooldownManager();
    cm.startCooldown('r1', 0);
    cm.startCooldown('r2', 0);
    cm.mergeEvent('r1', { text: 'x' });
    cm.reset();
    assertFalse(cm.isInCooldown('r1', { duration: 60000 }, 100));
    assertFalse(cm.isInCooldown('r2', { duration: 60000 }, 100));
    assertEqual(cm.getMergedEvents('r1').length, 0);
  });
});

describe('Cooldown - 多规则独立', function () {
  it('规则A冷却不影响规则B', function () {
    const cm = new CooldownManager();
    cm.startCooldown('ruleA', 1000);
    assertTrue(cm.isInCooldown('ruleA', { duration: 60000 }, 2000));
    assertFalse(cm.isInCooldown('ruleB', { duration: 60000 }, 2000));
  });
});
