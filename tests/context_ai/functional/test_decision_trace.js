'use strict';
/**
 * 决策追溯测试
 * 对应设计文档: §7.2 C++ 模块设计 - DecisionTracer
 * 覆盖: 记录/查询/容量限制/JSON序列化
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertGreaterThan, assertDefined
} = require('../../lib/assert');

// ── JS 镜像：决策追溯 ──

class DecisionTracer {
  constructor(maxEntries = 1000) {
    this.entries = [];
    this.maxEntries = maxEntries;
  }

  record(decision, matchResults, context) {
    const entry = {
      timestamp: Date.now(),
      decision: {
        intent: decision.intent,
        confidence: decision.confidence,
        action: decision.action,
        priority: decision.priority,
      },
      matchResults: matchResults.map(m => ({
        ruleId: m.rule.id,
        confidence: m.confidence,
        path: m.path,
      })),
      context: { ...context },
    };
    this.entries.push(entry);
    if (this.entries.length > this.maxEntries) {
      this.entries.shift();
    }
    return entry;
  }

  getHistory(limit = 10) {
    return this.entries.slice(-limit).reverse();
  }

  getByIntent(intent) {
    return this.entries.filter(e => e.decision.intent === intent);
  }

  toJSON() {
    return JSON.stringify(this.entries);
  }

  clear() {
    this.entries = [];
  }

  get size() { return this.entries.length; }
}

// ── 测试 ──

describe('DecisionTrace - 记录', function () {
  it('记录决策', function () {
    const tracer = new DecisionTracer();
    tracer.record(
      { intent: 'commute', confidence: 0.9, action: 'notify', priority: '🟡' },
      [{ rule: { id: 'r1' }, confidence: 0.9, path: [] }],
      { hour: 8, location: 'home' }
    );
    assertEqual(tracer.size, 1);
  });

  it('记录包含完整信息', function () {
    const tracer = new DecisionTracer();
    const entry = tracer.record(
      { intent: 'test', confidence: 0.8, action: 'push', priority: '🟢' },
      [{ rule: { id: 'r1' }, confidence: 0.8, path: [{ key: 'hour', actual: 8 }] }],
      { hour: 8 }
    );
    assertEqual(entry.decision.intent, 'test');
    assertEqual(entry.matchResults[0].ruleId, 'r1');
    assertDefined(entry.timestamp);
    assertDefined(entry.context.hour);
  });
});

describe('DecisionTrace - 查询', function () {
  it('getHistory 返回最近N条（倒序）', function () {
    const tracer = new DecisionTracer();
    for (let i = 0; i < 5; i++) {
      tracer.record(
        { intent: `intent_${i}`, confidence: 0.5, action: 'x', priority: '🟢' },
        [], {}
      );
    }
    const h = tracer.getHistory(3);
    assertEqual(h.length, 3);
    assertEqual(h[0].decision.intent, 'intent_4');
  });

  it('getByIntent 按意图过滤', function () {
    const tracer = new DecisionTracer();
    tracer.record({ intent: 'a', confidence: 0.5, action: 'x', priority: '🟢' }, [], {});
    tracer.record({ intent: 'b', confidence: 0.5, action: 'x', priority: '🟢' }, [], {});
    tracer.record({ intent: 'a', confidence: 0.7, action: 'x', priority: '🟢' }, [], {});
    assertEqual(tracer.getByIntent('a').length, 2);
    assertEqual(tracer.getByIntent('b').length, 1);
    assertEqual(tracer.getByIntent('c').length, 0);
  });
});

describe('DecisionTrace - 容量限制', function () {
  it('超过maxEntries后自动清理', function () {
    const tracer = new DecisionTracer(5);
    for (let i = 0; i < 10; i++) {
      tracer.record({ intent: `i${i}`, confidence: 0.5, action: 'x', priority: '🟢' }, [], {});
    }
    assertEqual(tracer.size, 5);
    // 最早的应该是 i5（i0-i4被清理）
    assertEqual(tracer.entries[0].decision.intent, 'i5');
  });
});

describe('DecisionTrace - 序列化', function () {
  it('toJSON 输出有效JSON', function () {
    const tracer = new DecisionTracer();
    tracer.record({ intent: 'test', confidence: 0.5, action: 'x', priority: '🟢' }, [], {});
    const json = tracer.toJSON();
    const parsed = JSON.parse(json);
    assertEqual(parsed.length, 1);
  });
});

describe('DecisionTrace - 清空', function () {
  it('clear 清空所有记录', function () {
    const tracer = new DecisionTracer();
    tracer.record({ intent: 'x', confidence: 0.5, action: 'x', priority: '🟢' }, [], {});
    tracer.clear();
    assertEqual(tracer.size, 0);
  });
});
