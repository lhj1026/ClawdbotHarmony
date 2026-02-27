'use strict';
/**
 * ActionExecutor 动作路由 + CalendarPlugin 扩展 单元测试
 * 覆盖: 动作路由、日历冲突检测、事件格式化、RL学习标签
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertGreaterThan, assertDefined
} = require('../../lib/assert');

// ============================================================
// Mock CalendarPlugin (mirrors ArkTS implementation)
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
          conflicts.push({
            event1: a, event2: b,
            overlapMinutes: Math.round((overlapEnd - overlapStart) / 60000)
          });
        }
      }
    }
    return conflicts;
  }

  formatEventsMarkdown(events, conflicts) {
    if (events.length === 0) {
      return '📅 接下来没有日程安排';
    }
    const lines = [];
    lines.push(`📅 **接下来有 ${events.length} 个日程**\n`);
    for (let i = 0; i < events.length; i++) {
      const ev = events[i];
      const start = new Date(ev.startTime);
      const end = new Date(ev.endTime);
      const timeStr = `${String(start.getHours()).padStart(2, '0')}:${String(start.getMinutes()).padStart(2, '0')}` +
        ` - ${String(end.getHours()).padStart(2, '0')}:${String(end.getMinutes()).padStart(2, '0')}`;
      const locStr = ev.location.length > 0 ? ` 📍 ${ev.location}` : '';
      lines.push(`${i + 1}. **${ev.title}**`);
      lines.push(`   🕐 ${timeStr}${locStr}`);
    }
    if (conflicts && conflicts.length > 0) {
      lines.push('');
      lines.push(`⚠️ **发现 ${conflicts.length} 个时间冲突：**`);
      for (const c of conflicts) {
        lines.push(`   - "${c.event1.title}" 与 "${c.event2.title}" 重叠 ${c.overlapMinutes} 分钟`);
      }
    }
    return lines.join('\n');
  }
}

// ============================================================
// Mock ActionExecutor (mirrors ArkTS implementation)
// ============================================================

class MockActionExecutor {
  constructor(calendarPlugin) {
    this.calendarPlugin = calendarPlugin;
  }

  async execute(action) {
    switch (action.type) {
      case 'show_info':
        return this.executeShowInfo(action);
      case 'open_app':
        return { success: true, message: `🚀 正在打开 ${action.target || '应用'}...`, actionType: 'open_app' };
      case 'set_mode':
        return { success: true, message: `⚙️ 已切换到 ${action.target || '模式'}`, actionType: 'set_mode' };
      case 'show_notification':
        return { success: true, message: `🔔 ${(action.params || {}).info || '通知已发送'}`, actionType: 'show_notification' };
      default:
        return { success: true, message: `✅ 动作 "${action.type}" 已记录`, actionType: action.type };
    }
  }

  async executeShowInfo(action) {
    const target = action.target || '';
    if (target.indexOf('calendar') >= 0 || (action.params || {}).category === 'calendar') {
      return this.executeCalendarInfo();
    }
    return { success: true, message: `ℹ️ ${(action.params || {}).info || '信息已显示'}`, actionType: 'show_info' };
  }

  async executeCalendarInfo() {
    const events = await this.calendarPlugin.getUpcomingEvents(8);
    const conflicts = this.calendarPlugin.findConflicts(events);
    const markdown = this.calendarPlugin.formatEventsMarkdown(events, conflicts);
    return { success: true, message: markdown, actionType: 'calendar_info' };
  }
}

// ============================================================
// ActionExecutor 路由测试
// ============================================================

describe('ActionExecutor 路由', function () {
  it('show_info + calendar target → calendar_info', async function () {
    const executor = new MockActionExecutor(new MockCalendarPlugin([]));
    const r = await executor.execute({ type: 'show_info', target: 'calendar_today' });
    assertEqual(r.actionType, 'calendar_info');
    assertTrue(r.success);
  });

  it('show_info + category=calendar → calendar_info', async function () {
    const executor = new MockActionExecutor(new MockCalendarPlugin([]));
    const r = await executor.execute({ type: 'show_info', target: 'something', params: { category: 'calendar' } });
    assertEqual(r.actionType, 'calendar_info');
  });

  it('show_info + non-calendar target → show_info', async function () {
    const executor = new MockActionExecutor(new MockCalendarPlugin([]));
    const r = await executor.execute({ type: 'show_info', target: 'deals_costco', params: { info: '今日优惠' } });
    assertEqual(r.actionType, 'show_info');
    assertTrue(r.message.includes('今日优惠'));
  });

  it('open_app 路由', async function () {
    const executor = new MockActionExecutor(new MockCalendarPlugin([]));
    const r = await executor.execute({ type: 'open_app', target: 'WeChat' });
    assertEqual(r.actionType, 'open_app');
    assertTrue(r.message.includes('WeChat'));
  });

  it('set_mode 路由', async function () {
    const executor = new MockActionExecutor(new MockCalendarPlugin([]));
    const r = await executor.execute({ type: 'set_mode', target: '静音' });
    assertEqual(r.actionType, 'set_mode');
  });

  it('show_notification 路由', async function () {
    const executor = new MockActionExecutor(new MockCalendarPlugin([]));
    const r = await executor.execute({ type: 'show_notification', params: { info: '会议提醒' } });
    assertEqual(r.actionType, 'show_notification');
  });

  it('未知类型 fallback', async function () {
    const executor = new MockActionExecutor(new MockCalendarPlugin([]));
    const r = await executor.execute({ type: 'some_future_type' });
    assertEqual(r.actionType, 'some_future_type');
    assertTrue(r.success);
  });
});

// ============================================================
// CalendarPlugin.findConflicts 测试
// ============================================================

describe('CalendarPlugin.findConflicts', function () {
  it('不重叠事件 → 无冲突', function () {
    const plugin = new MockCalendarPlugin();
    const events = [
      { title: 'A', startTime: 1000, endTime: 2000, location: '' },
      { title: 'B', startTime: 3000, endTime: 4000, location: '' },
    ];
    assertEqual(plugin.findConflicts(events).length, 0);
  });

  it('两事件重叠 → 1个冲突', function () {
    const plugin = new MockCalendarPlugin();
    const events = [
      { title: 'A', startTime: 1000, endTime: 3000, location: '' },
      { title: 'B', startTime: 2000, endTime: 4000, location: '' },
    ];
    const conflicts = plugin.findConflicts(events);
    assertEqual(conflicts.length, 1);
    assertEqual(conflicts[0].overlapMinutes, Math.round(1000 / 60000));
  });

  it('三事件互相重叠 → 3个冲突', function () {
    const plugin = new MockCalendarPlugin();
    const events = [
      { title: 'A', startTime: 0, endTime: 5000000, location: '' },
      { title: 'B', startTime: 1000000, endTime: 3000000, location: '' },
      { title: 'C', startTime: 2000000, endTime: 4000000, location: '' },
    ];
    assertEqual(plugin.findConflicts(events).length, 3);
  });

  it('空事件 → 无冲突', function () {
    const plugin = new MockCalendarPlugin();
    assertEqual(plugin.findConflicts([]).length, 0);
  });

  it('单事件 → 无冲突', function () {
    const plugin = new MockCalendarPlugin();
    assertEqual(plugin.findConflicts([{ title: 'A', startTime: 1000, endTime: 2000, location: '' }]).length, 0);
  });

  it('相邻事件 (endTime === startTime) → 无冲突', function () {
    const plugin = new MockCalendarPlugin();
    const events = [
      { title: 'A', startTime: 1000, endTime: 2000, location: '' },
      { title: 'B', startTime: 2000, endTime: 3000, location: '' },
    ];
    assertEqual(plugin.findConflicts(events).length, 0);
  });
});

// ============================================================
// CalendarPlugin.formatEventsMarkdown 测试
// ============================================================

describe('CalendarPlugin.formatEventsMarkdown', function () {
  it('空事件 → 无日程消息', function () {
    const plugin = new MockCalendarPlugin();
    const md = plugin.formatEventsMarkdown([]);
    assertTrue(md.includes('没有日程'));
  });

  it('单事件 — 标题+时间+地点', function () {
    const plugin = new MockCalendarPlugin();
    const now = new Date();
    now.setHours(14, 0, 0, 0);
    const ev = {
      title: '项目评审', startTime: now.getTime(),
      endTime: now.getTime() + 60 * 60 * 1000, location: '3号会议室'
    };
    const md = plugin.formatEventsMarkdown([ev]);
    assertTrue(md.includes('1 个日程'));
    assertTrue(md.includes('项目评审'));
    assertTrue(md.includes('3号会议室'));
    assertTrue(md.includes('14:00'));
  });

  it('含冲突信息', function () {
    const plugin = new MockCalendarPlugin();
    const ev1 = { title: 'A', startTime: 1000, endTime: 2000, location: '' };
    const ev2 = { title: 'B', startTime: 1500, endTime: 2500, location: '' };
    const conflicts = [{ event1: ev1, event2: ev2, overlapMinutes: 30 }];
    const md = plugin.formatEventsMarkdown([ev1, ev2], conflicts);
    assertTrue(md.includes('时间冲突'));
    assertTrue(md.includes('30 分钟'));
    assertTrue(md.includes('2 个日程'));
  });
});

// ============================================================
// RL 学习标签逻辑
// ============================================================

describe('RL 学习标签', function () {
  function getLabel(samples) {
    if (samples < 5) return '探索中';
    if (samples < 20) return `学习中 (${samples}次)`;
    return `已学习 (${samples}次)`;
  }

  it('0 样本 → 探索中', function () { assertEqual(getLabel(0), '探索中'); });
  it('4 样本 → 探索中', function () { assertEqual(getLabel(4), '探索中'); });
  it('5 样本 → 学习中', function () { assertEqual(getLabel(5), '学习中 (5次)'); });
  it('19 样本 → 学习中', function () { assertEqual(getLabel(19), '学习中 (19次)'); });
  it('20 样本 → 已学习', function () { assertEqual(getLabel(20), '已学习 (20次)'); });
  it('100 样本 → 已学习', function () { assertEqual(getLabel(100), '已学习 (100次)'); });
});
