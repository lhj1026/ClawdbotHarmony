'use strict';
/**
 * 📧 消息堆积合并场景测试
 * 对应设计文档: §2.3 - 消息堆积, §6.6 Cooldown + 合并推送
 * 触发: 10min内3+条未读 → 合并提醒
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertFalse, assertGreaterThan, assertLessThan
} = require('../../lib/assert');

// ── JS 镜像：消息堆积检测 + 合并推送逻辑 ──

const MERGE_WINDOW_MS = 600000; // 10分钟
const MERGE_THRESHOLD = 3;      // 3条以上触发合并
const PUSH_MERGE_WINDOW_MS = 300000; // 5分钟内低优先级合并

class MessagePileDetector {
  constructor() {
    this.messages = []; // { source, text, time, priority }
  }

  push(msg) {
    this.messages.push({ ...msg, time: msg.time || Date.now() });
  }

  /** 检测窗口内未读消息堆积 */
  detect(now) {
    now = now || Date.now();
    const cutoff = now - MERGE_WINDOW_MS;
    const recent = this.messages.filter(m => m.time >= cutoff);
    if (recent.length >= MERGE_THRESHOLD) {
      return {
        triggered: true,
        count: recent.length,
        sources: [...new Set(recent.map(m => m.source))],
        summary: this._generateSummary(recent),
        priority: '🟡',
      };
    }
    return { triggered: false, count: recent.length };
  }

  _generateSummary(messages) {
    const bySource = {};
    for (const m of messages) {
      if (!bySource[m.source]) bySource[m.source] = [];
      bySource[m.source].push(m.text);
    }
    const parts = [];
    for (const [source, texts] of Object.entries(bySource)) {
      parts.push(`${source}: ${texts.length}条`);
    }
    return parts.join(', ');
  }

  clear() {
    this.messages = [];
  }
}

/** 合并推送: 5分钟内多条 🟢/⚪ 合并为一条 */
function mergePushes(pushQueue, now) {
  now = now || Date.now();
  const cutoff = now - PUSH_MERGE_WINDOW_MS;
  const mergeable = pushQueue.filter(p =>
    p.time >= cutoff && (p.priority === '🟢' || p.priority === '⚪')
  );
  const keep = pushQueue.filter(p =>
    p.time < cutoff || (p.priority !== '🟢' && p.priority !== '⚪')
  );

  if (mergeable.length >= 2) {
    const merged = {
      type: 'merged_summary',
      count: mergeable.length,
      items: mergeable.map(p => ({ intent: p.intent, text: p.text })),
      priority: '🟢',
      time: now,
    };
    return { merged: true, result: [...keep, merged], mergedCount: mergeable.length };
  }
  return { merged: false, result: pushQueue, mergedCount: 0 };
}

// ── 测试 ──

const NOW = 1000000;

describe('Scenario: 消息堆积 - 触发合并', function () {
  it('10min内3条 → 触发', function () {
    const det = new MessagePileDetector();
    det.push({ source: 'WeChat', text: 'msg1', time: NOW - 300000 });
    det.push({ source: 'WeChat', text: 'msg2', time: NOW - 200000 });
    det.push({ source: 'QQ', text: 'msg3', time: NOW - 100000 });
    const r = det.detect(NOW);
    assertTrue(r.triggered);
    assertEqual(r.count, 3);
  });

  it('10min内5条 → 触发，count=5', function () {
    const det = new MessagePileDetector();
    for (let i = 0; i < 5; i++) {
      det.push({ source: 'WeChat', text: `msg${i}`, time: NOW - (5 - i) * 60000 });
    }
    const r = det.detect(NOW);
    assertTrue(r.triggered);
    assertEqual(r.count, 5);
  });

  it('合并摘要包含来源和数量', function () {
    const det = new MessagePileDetector();
    det.push({ source: 'WeChat', text: 'a', time: NOW - 100000 });
    det.push({ source: 'WeChat', text: 'b', time: NOW - 50000 });
    det.push({ source: 'QQ', text: 'c', time: NOW - 30000 });
    const r = det.detect(NOW);
    assertTrue(r.summary.includes('WeChat'));
    assertTrue(r.summary.includes('QQ'));
    assertTrue(r.summary.includes('2条'));
  });

  it('优先级为 🟡', function () {
    const det = new MessagePileDetector();
    for (let i = 0; i < 3; i++) {
      det.push({ source: 'X', text: `m${i}`, time: NOW - i * 1000 });
    }
    assertEqual(det.detect(NOW).priority, '🟡');
  });
});

describe('Scenario: 消息堆积 - 不触发', function () {
  it('2条 → 未达阈值', function () {
    const det = new MessagePileDetector();
    det.push({ source: 'WeChat', text: 'a', time: NOW - 60000 });
    det.push({ source: 'WeChat', text: 'b', time: NOW - 30000 });
    assertFalse(det.detect(NOW).triggered);
    assertEqual(det.detect(NOW).count, 2);
  });

  it('3条但跨30min → 部分超窗口', function () {
    const det = new MessagePileDetector();
    det.push({ source: 'WeChat', text: 'a', time: NOW - 900000 }); // 15min前，超10min窗口
    det.push({ source: 'WeChat', text: 'b', time: NOW - 300000 });
    det.push({ source: 'WeChat', text: 'c', time: NOW - 100000 });
    const r = det.detect(NOW);
    assertEqual(r.count, 2); // 只有2条在窗口内
    assertFalse(r.triggered);
  });

  it('0条消息 → 不触发', function () {
    const det = new MessagePileDetector();
    assertFalse(det.detect(NOW).triggered);
    assertEqual(det.detect(NOW).count, 0);
  });
});

describe('Scenario: 消息堆积 - 边界', function () {
  it('恰好3条 → 触发', function () {
    const det = new MessagePileDetector();
    for (let i = 0; i < 3; i++) {
      det.push({ source: 'A', text: `m${i}`, time: NOW - i * 1000 });
    }
    assertTrue(det.detect(NOW).triggered);
  });

  it('恰好在窗口边界 → 计入', function () {
    const det = new MessagePileDetector();
    det.push({ source: 'A', text: 'a', time: NOW - MERGE_WINDOW_MS + 1 }); // 刚好在窗口内
    det.push({ source: 'A', text: 'b', time: NOW - 100000 });
    det.push({ source: 'A', text: 'c', time: NOW - 50000 });
    assertTrue(det.detect(NOW).triggered);
  });

  it('恰好在窗口外 → 不计入', function () {
    const det = new MessagePileDetector();
    det.push({ source: 'A', text: 'a', time: NOW - MERGE_WINDOW_MS - 1 }); // 窗口外
    det.push({ source: 'A', text: 'b', time: NOW - 100000 });
    det.push({ source: 'A', text: 'c', time: NOW - 50000 });
    assertFalse(det.detect(NOW).triggered);
  });

  it('sources 去重', function () {
    const det = new MessagePileDetector();
    det.push({ source: 'WeChat', text: 'a', time: NOW });
    det.push({ source: 'WeChat', text: 'b', time: NOW });
    det.push({ source: 'WeChat', text: 'c', time: NOW });
    const r = det.detect(NOW);
    assertEqual(r.sources.length, 1);
    assertEqual(r.sources[0], 'WeChat');
  });

  it('clear 后重新检测', function () {
    const det = new MessagePileDetector();
    for (let i = 0; i < 5; i++) det.push({ source: 'A', text: `m${i}`, time: NOW });
    assertTrue(det.detect(NOW).triggered);
    det.clear();
    assertFalse(det.detect(NOW).triggered);
  });
});

describe('Scenario: 合并推送', function () {
  it('2条🟢 → 合并为1条摘要', function () {
    const pushes = [
      { intent: 'weather', text: '明天多云', priority: '🟢', time: NOW - 60000 },
      { intent: 'news', text: '新闻摘要', priority: '🟢', time: NOW - 30000 },
    ];
    const r = mergePushes(pushes, NOW);
    assertTrue(r.merged);
    assertEqual(r.mergedCount, 2);
  });

  it('🔴不参与合并', function () {
    const pushes = [
      { intent: 'urgent', text: '紧急', priority: '🔴', time: NOW - 60000 },
      { intent: 'weather', text: '天气', priority: '🟢', time: NOW - 30000 },
    ];
    const r = mergePushes(pushes, NOW);
    assertFalse(r.merged); // 只有1条🟢，不够合并
  });

  it('⚪也参与合并', function () {
    const pushes = [
      { intent: 'bg1', text: 'a', priority: '⚪', time: NOW - 60000 },
      { intent: 'bg2', text: 'b', priority: '⚪', time: NOW - 30000 },
    ];
    assertTrue(mergePushes(pushes, NOW).merged);
  });

  it('超窗口不合并', function () {
    const pushes = [
      { intent: 'a', text: 'a', priority: '🟢', time: NOW - 400000 },
      { intent: 'b', text: 'b', priority: '🟢', time: NOW - 350000 },
    ];
    assertFalse(mergePushes(pushes, NOW).merged);
  });

  it('合并结果包含原始items', function () {
    const pushes = [
      { intent: 'weather', text: '天气', priority: '🟢', time: NOW - 60000 },
      { intent: 'news', text: '新闻', priority: '🟢', time: NOW - 30000 },
    ];
    const r = mergePushes(pushes, NOW);
    const mergedItem = r.result.find(p => p.type === 'merged_summary');
    assertEqual(mergedItem.items.length, 2);
    assertEqual(mergedItem.items[0].intent, 'weather');
  });
});
