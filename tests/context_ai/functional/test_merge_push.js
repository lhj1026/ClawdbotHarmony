'use strict';
/**
 * 合并推送测试
 * 对应设计文档: §5.3 执行域架构 - 合并推送, §6.6 Cooldown + 合并推送
 * 覆盖: 5分钟窗口/合并逻辑/优先级提升/窗口边界
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertFalse, assertGreaterThan
} = require('../../lib/assert');

// ── JS 镜像：合并推送 ──

const MERGE_WINDOW_MS = 5 * 60 * 1000; // 5分钟
const MERGEABLE_PRIORITIES = ['🟢', '⚪'];

class MergePushManager {
  constructor() {
    this.pending = []; // { decision, timestamp }
  }

  /** 尝试添加推送，返回是否应立即发送 */
  add(decision, now) {
    // 高优先级立即发送
    if (!MERGEABLE_PRIORITIES.includes(decision.priority)) {
      return { immediate: true, merged: null };
    }

    // 清理过期
    this.pending = this.pending.filter(p => (now - p.timestamp) < MERGE_WINDOW_MS);

    this.pending.push({ decision, timestamp: now });

    // 达到3条以上时合并发送
    if (this.pending.length >= 3) {
      return this._flush(now);
    }

    return { immediate: false, merged: null };
  }

  /** 窗口到期时调用 */
  flush(now) {
    this.pending = this.pending.filter(p => (now - p.timestamp) < MERGE_WINDOW_MS);
    if (this.pending.length === 0) return null;
    return this._flush(now);
  }

  _flush(now) {
    const items = [...this.pending];
    this.pending = [];
    // 合并为摘要
    const summary = {
      type: 'merged_summary',
      count: items.length,
      items: items.map(i => ({
        intent: i.decision.intent,
        text: i.decision.text,
      })),
      // 合并后优先级取最高
      priority: this._highestPriority(items.map(i => i.decision.priority)),
    };
    return { immediate: true, merged: summary };
  }

  _highestPriority(priorities) {
    const order = ['🔴', '🟡', '🟢', '⚪'];
    for (const p of order) {
      if (priorities.includes(p)) return p;
    }
    return '⚪';
  }

  get pendingCount() { return this.pending.length; }
}

// ── 测试 ──

const NOW = 1000000;

describe('MergePush - 即时推送', function () {
  it('🔴 优先级 → 立即发送', function () {
    const mgr = new MergePushManager();
    const r = mgr.add({ priority: '🔴', intent: 'urgent' }, NOW);
    assertTrue(r.immediate);
  });

  it('🟡 优先级 → 立即发送', function () {
    const mgr = new MergePushManager();
    const r = mgr.add({ priority: '🟡', intent: 'medium' }, NOW);
    assertTrue(r.immediate);
  });
});

describe('MergePush - 合并逻辑', function () {
  it('🟢 第1条 → 不立即发送', function () {
    const mgr = new MergePushManager();
    const r = mgr.add({ priority: '🟢', intent: 'a' }, NOW);
    assertFalse(r.immediate);
    assertEqual(mgr.pendingCount, 1);
  });

  it('🟢 累积3条 → 合并发送', function () {
    const mgr = new MergePushManager();
    mgr.add({ priority: '🟢', intent: 'a' }, NOW);
    mgr.add({ priority: '🟢', intent: 'b' }, NOW + 1000);
    const r = mgr.add({ priority: '🟢', intent: 'c' }, NOW + 2000);
    assertTrue(r.immediate);
    assertEqual(r.merged.count, 3);
    assertEqual(r.merged.type, 'merged_summary');
  });

  it('⚪ 也可合并', function () {
    const mgr = new MergePushManager();
    mgr.add({ priority: '⚪', intent: 'a' }, NOW);
    mgr.add({ priority: '⚪', intent: 'b' }, NOW + 1000);
    const r = mgr.add({ priority: '⚪', intent: 'c' }, NOW + 2000);
    assertTrue(r.immediate);
    assertEqual(r.merged.count, 3);
  });

  it('合并后清空pending', function () {
    const mgr = new MergePushManager();
    mgr.add({ priority: '🟢', intent: 'a' }, NOW);
    mgr.add({ priority: '🟢', intent: 'b' }, NOW + 1000);
    mgr.add({ priority: '🟢', intent: 'c' }, NOW + 2000);
    assertEqual(mgr.pendingCount, 0);
  });
});

describe('MergePush - 5分钟窗口', function () {
  it('窗口内事件保留', function () {
    const mgr = new MergePushManager();
    mgr.add({ priority: '🟢', intent: 'a' }, NOW);
    mgr.add({ priority: '🟢', intent: 'b' }, NOW + 4 * 60 * 1000); // 4分钟后
    assertEqual(mgr.pendingCount, 2);
  });

  it('窗口外事件过期', function () {
    const mgr = new MergePushManager();
    mgr.add({ priority: '🟢', intent: 'old' }, NOW);
    // 6分钟后添加新的，旧的应被清理
    mgr.add({ priority: '🟢', intent: 'new' }, NOW + 6 * 60 * 1000);
    assertEqual(mgr.pendingCount, 1);
  });

  it('flush 窗口到期', function () {
    const mgr = new MergePushManager();
    mgr.add({ priority: '🟢', intent: 'a' }, NOW);
    mgr.add({ priority: '🟢', intent: 'b' }, NOW + 1000);
    const r = mgr.flush(NOW + 4 * 60 * 1000); // 在窗口内
    assertEqual(r.merged.count, 2);
  });

  it('flush 空队列 → null', function () {
    const mgr = new MergePushManager();
    assertEqual(mgr.flush(NOW), null);
  });
});

describe('MergePush - 优先级提升', function () {
  it('混合🟢和⚪ → 合并后取🟢', function () {
    const mgr = new MergePushManager();
    mgr.add({ priority: '⚪', intent: 'a' }, NOW);
    mgr.add({ priority: '🟢', intent: 'b' }, NOW + 1000);
    const r = mgr.add({ priority: '⚪', intent: 'c' }, NOW + 2000);
    assertEqual(r.merged.priority, '🟢');
  });
});
