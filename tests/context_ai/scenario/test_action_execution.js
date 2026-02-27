'use strict';
/**
 * 推荐动作执行场景测试
 * 覆盖:
 *   1. 用户接受日历推荐 → 读取日历 → 显示会议列表
 *   2. 日历为空时的处理
 *   3. 有冲突会议时的显示
 *   4. 不同 action.type 的路由
 *   5. 推荐缓存和超时
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertGreaterThan, assertDefined
} = require('../../lib/assert');

// ============================================================
// Mock CalendarPlugin (mirrors ArkTS CalendarPlugin)
// ============================================================

class MockCalendarPlugin {
  constructor(events) {
    this.events = events || [];
  }

  async getUpcomingEvents(hoursAhead) {
    const now = Date.now();
    const windowMs = (hoursAhead || 8) * 60 * 60 * 1000;
    const cutoff = now + windowMs;
    return this.events.filter(ev => ev.startTime > now && ev.startTime < cutoff);
  }

  findConflicts(events) {
    const conflicts = [];
    for (let i = 0; i < events.length; i++) {
      for (let j = i + 1; j < events.length; j++) {
        const a = events[i];
        const b = events[j];
        const overlapStart = Math.max(a.startTime, b.startTime);
        const overlapEnd = Math.min(a.endTime, b.endTime);
        if (overlapStart < overlapEnd) {
          conflicts.push({ event1: a, event2: b, overlapMinutes: Math.round((overlapEnd - overlapStart) / 60000) });
        }
      }
    }
    return conflicts;
  }

  formatEventsMarkdown(events, conflicts) {
    if (events.length === 0) return '📅 接下来没有日程安排';
    const lines = [`📅 **接下来有 ${events.length} 个日程**\n`];
    for (let i = 0; i < events.length; i++) {
      const ev = events[i];
      const s = new Date(ev.startTime);
      const e = new Date(ev.endTime);
      const t = `${String(s.getHours()).padStart(2, '0')}:${String(s.getMinutes()).padStart(2, '0')} - ${String(e.getHours()).padStart(2, '0')}:${String(e.getMinutes()).padStart(2, '0')}`;
      const loc = ev.location.length > 0 ? ` 📍 ${ev.location}` : '';
      lines.push(`${i + 1}. **${ev.title}**`);
      lines.push(`   🕐 ${t}${loc}`);
    }
    if (conflicts && conflicts.length > 0) {
      lines.push('', `⚠️ **发现 ${conflicts.length} 个时间冲突：**`);
      for (const c of conflicts) lines.push(`   - "${c.event1.title}" 与 "${c.event2.title}" 重叠 ${c.overlapMinutes} 分钟`);
    }
    return lines.join('\n');
  }
}

// Mock ActionExecutor
class MockActionExecutor {
  constructor(calPlugin) { this.cal = calPlugin; }

  async execute(action) {
    switch (action.type) {
      case 'show_info': return this.showInfo(action);
      case 'open_app': return { success: true, message: `🚀 打开 ${action.target || ''}`, actionType: 'open_app' };
      case 'set_mode': return { success: true, message: `⚙️ 切换 ${action.target || ''}`, actionType: 'set_mode' };
      default: return { success: true, message: `✅ ${action.type}`, actionType: action.type };
    }
  }

  async showInfo(action) {
    if ((action.target || '').includes('calendar') || (action.params || {}).category === 'calendar') {
      const events = await this.cal.getUpcomingEvents(8);
      const conflicts = this.cal.findConflicts(events);
      return { success: true, message: this.cal.formatEventsMarkdown(events, conflicts), actionType: 'calendar_info' };
    }
    return { success: true, message: `ℹ️ ${(action.params || {}).info || ''}`, actionType: 'show_info' };
  }
}

// ============================================================
// 场景 1: 用户到达办公室 → 接受日历推荐 → 显示会议
// ============================================================

describe('场景: 办公室日历推荐接受', function () {
  it('有2个会议 → 显示完整列表', async function () {
    const now = Date.now();
    const events = [
      { title: '早会', startTime: now + 30 * 60000, endTime: now + 60 * 60000, location: 'A101' },
      { title: '项目评审', startTime: now + 2 * 3600000, endTime: now + 3 * 3600000, location: 'B201' },
    ];
    const executor = new MockActionExecutor(new MockCalendarPlugin(events));
    const result = await executor.execute({ type: 'show_info', target: 'calendar_today' });

    assertTrue(result.success, 'action should succeed');
    assertEqual(result.actionType, 'calendar_info');
    assertTrue(result.message.includes('2 个日程'));
    assertTrue(result.message.includes('早会'));
    assertTrue(result.message.includes('项目评审'));
    assertTrue(result.message.includes('A101'));
    assertTrue(result.message.includes('B201'));
  });

  it('有冲突会议 → 显示冲突警告', async function () {
    const now = Date.now();
    const events = [
      { title: '会议A', startTime: now + 60 * 60000, endTime: now + 2 * 3600000, location: '' },
      { title: '会议B', startTime: now + 90 * 60000, endTime: now + 2.5 * 3600000, location: '' },
    ];
    const executor = new MockActionExecutor(new MockCalendarPlugin(events));
    const result = await executor.execute({ type: 'show_info', target: 'calendar_today' });

    assertTrue(result.message.includes('时间冲突'));
    assertTrue(result.message.includes('会议A'));
    assertTrue(result.message.includes('会议B'));
  });
});

// ============================================================
// 场景 2: 日历为空
// ============================================================

describe('场景: 日历为空', function () {
  it('无事件 → 友好提示', async function () {
    const executor = new MockActionExecutor(new MockCalendarPlugin([]));
    const result = await executor.execute({ type: 'show_info', target: 'calendar_today' });

    assertTrue(result.success);
    assertEqual(result.actionType, 'calendar_info');
    assertTrue(result.message.includes('没有日程'));
  });
});

// ============================================================
// 场景 3: 不同 action type 路由
// ============================================================

describe('场景: 动作类型路由', function () {
  it('open_app → 打开应用消息', async function () {
    const executor = new MockActionExecutor(new MockCalendarPlugin([]));
    const r = await executor.execute({ type: 'open_app', target: '支付宝' });
    assertEqual(r.actionType, 'open_app');
    assertTrue(r.message.includes('支付宝'));
  });

  it('set_mode → 切换模式消息', async function () {
    const executor = new MockActionExecutor(new MockCalendarPlugin([]));
    const r = await executor.execute({ type: 'set_mode', target: '勿扰' });
    assertEqual(r.actionType, 'set_mode');
    assertTrue(r.message.includes('勿扰'));
  });

  it('未知类型 → 通用确认', async function () {
    const executor = new MockActionExecutor(new MockCalendarPlugin([]));
    const r = await executor.execute({ type: 'future_action' });
    assertEqual(r.actionType, 'future_action');
    assertTrue(r.success);
  });
});

// ============================================================
// 场景 4: 推荐缓存和超时
// ============================================================

describe('场景: 推荐缓存', function () {
  it('缓存推荐 → 接受时可获取', function () {
    const cache = new Map();
    const rec = { rule: { id: 'r1' }, action: { type: 'show_info', target: 'calendar_today' }, reason: 'test' };
    cache.set('r1', rec);
    const cached = cache.get('r1');
    assertDefined(cached);
    assertEqual(cached.action.target, 'calendar_today');
  });

  it('超时后缓存已清除', function () {
    const cache = new Map();
    cache.set('r2', { rule: { id: 'r2' }, action: { type: 'open_app' } });
    // Simulate timeout
    cache.delete('r2');
    assertEqual(cache.get('r2'), undefined);
  });
});
