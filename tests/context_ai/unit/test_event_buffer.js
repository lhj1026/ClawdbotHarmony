'use strict';
/**
 * 事件缓冲区测试
 * 对应设计文档: §6.5 时序规则, §7.2 C++ 模块设计 - EventRingBuffer
 * 覆盖: 环形缓冲/窗口计数/序列匹配/容量溢出
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertGreaterThan
} = require('../../lib/assert');

// ── JS 镜像：事件环形缓冲区（C++ event_buffer.h） ──

class EventRingBuffer {
  constructor(capacity = 10000) {
    this.capacity = capacity;
    this.buffer = [];
    this.head = 0;
  }

  push(event, timestamp) {
    const entry = { event, timestamp: timestamp || Date.now() };
    if (this.buffer.length < this.capacity) {
      this.buffer.push(entry);
    } else {
      this.buffer[this.head] = entry;
    }
    this.head = (this.head + 1) % this.capacity;
  }

  /** 窗口内事件计数 */
  countInWindow(event, windowMs, now) {
    now = now || Date.now();
    const cutoff = now - windowMs;
    let count = 0;
    for (const e of this.buffer) {
      if (e.event === event && e.timestamp >= cutoff) count++;
    }
    return count;
  }

  /** 序列匹配：在窗口内按顺序找到指定事件序列 */
  matchSequence(sequence, windowMs, now) {
    now = now || Date.now();
    const cutoff = now - windowMs;
    // 按时间排序的窗口内事件
    const windowed = this.buffer
      .filter(e => e.timestamp >= cutoff)
      .sort((a, b) => a.timestamp - b.timestamp);

    let seqIdx = 0;
    for (const e of windowed) {
      if (e.event === sequence[seqIdx]) {
        seqIdx++;
        if (seqIdx === sequence.length) return true;
      }
    }
    return false;
  }

  /** 获取最近N个事件 */
  recent(n) {
    const sorted = [...this.buffer].sort((a, b) => b.timestamp - a.timestamp);
    return sorted.slice(0, n);
  }

  get size() {
    return this.buffer.length;
  }
}

// ── 测试 ──

const NOW = 1000000;

describe('EventBuffer - 基本操作', function () {
  it('push 后 size 增加', function () {
    const buf = new EventRingBuffer(100);
    buf.push('test', NOW);
    assertEqual(buf.size, 1);
  });

  it('多次 push', function () {
    const buf = new EventRingBuffer(100);
    for (let i = 0; i < 10; i++) buf.push('evt', NOW + i);
    assertEqual(buf.size, 10);
  });
});

describe('EventBuffer - 环形缓冲', function () {
  it('超出容量后不增长', function () {
    const buf = new EventRingBuffer(5);
    for (let i = 0; i < 10; i++) buf.push('evt', NOW + i);
    assertEqual(buf.size, 5);
  });

  it('超出容量后覆盖旧数据', function () {
    const buf = new EventRingBuffer(3);
    buf.push('a', 1);
    buf.push('b', 2);
    buf.push('c', 3);
    buf.push('d', 4); // 覆盖 'a'
    assertEqual(buf.countInWindow('a', 100000, 10), 0);
    assertEqual(buf.countInWindow('d', 100000, 10), 1);
  });

  it('大容量(10000)', function () {
    const buf = new EventRingBuffer(10000);
    for (let i = 0; i < 10000; i++) buf.push('x', i);
    assertEqual(buf.size, 10000);
  });
});

describe('EventBuffer - 窗口计数', function () {
  it('窗口内全部匹配', function () {
    const buf = new EventRingBuffer(100);
    buf.push('notification', NOW);
    buf.push('notification', NOW + 100);
    buf.push('notification', NOW + 200);
    assertEqual(buf.countInWindow('notification', 1000, NOW + 300), 3);
  });

  it('窗口外不计', function () {
    const buf = new EventRingBuffer(100);
    buf.push('old', NOW - 10000);
    buf.push('new', NOW);
    assertEqual(buf.countInWindow('old', 1000, NOW), 0);
    assertEqual(buf.countInWindow('new', 1000, NOW), 1);
  });

  it('不同事件类型独立计数', function () {
    const buf = new EventRingBuffer(100);
    buf.push('a', NOW);
    buf.push('b', NOW);
    buf.push('a', NOW);
    assertEqual(buf.countInWindow('a', 1000, NOW), 2);
    assertEqual(buf.countInWindow('b', 1000, NOW), 1);
  });

  it('空缓冲区 → 0', function () {
    const buf = new EventRingBuffer(100);
    assertEqual(buf.countInWindow('x', 1000, NOW), 0);
  });
});

describe('EventBuffer - 序列匹配', function () {
  it('正确顺序 → 匹配', function () {
    const buf = new EventRingBuffer(100);
    buf.push('leave_office', NOW);
    buf.push('start_driving', NOW + 1000);
    buf.push('enter_highway', NOW + 2000);
    assertTrue(buf.matchSequence(
      ['leave_office', 'start_driving', 'enter_highway'],
      10000, NOW + 3000
    ));
  });

  it('逆序 → 不匹配', function () {
    const buf = new EventRingBuffer(100);
    buf.push('enter_highway', NOW);
    buf.push('start_driving', NOW + 1000);
    buf.push('leave_office', NOW + 2000);
    assertEqual(buf.matchSequence(
      ['leave_office', 'start_driving', 'enter_highway'],
      10000, NOW + 3000
    ), false);
  });

  it('部分序列 → 不匹配', function () {
    const buf = new EventRingBuffer(100);
    buf.push('leave_office', NOW);
    buf.push('start_driving', NOW + 1000);
    assertEqual(buf.matchSequence(
      ['leave_office', 'start_driving', 'enter_highway'],
      10000, NOW + 2000
    ), false);
  });

  it('窗口外的事件不参与', function () {
    const buf = new EventRingBuffer(100);
    buf.push('leave_office', NOW - 20000); // 窗口外
    buf.push('start_driving', NOW);
    assertEqual(buf.matchSequence(
      ['leave_office', 'start_driving'],
      10000, NOW + 1000
    ), false);
  });

  it('中间有其他事件 → 仍匹配', function () {
    const buf = new EventRingBuffer(100);
    buf.push('a', NOW);
    buf.push('noise', NOW + 100);
    buf.push('b', NOW + 200);
    assertTrue(buf.matchSequence(['a', 'b'], 10000, NOW + 300));
  });
});

describe('EventBuffer - recent', function () {
  it('返回最近N个', function () {
    const buf = new EventRingBuffer(100);
    buf.push('a', 1);
    buf.push('b', 2);
    buf.push('c', 3);
    const r = buf.recent(2);
    assertEqual(r.length, 2);
    assertEqual(r[0].event, 'c');
    assertEqual(r[1].event, 'b');
  });
});
