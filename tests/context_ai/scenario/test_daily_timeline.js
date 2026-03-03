'use strict';
/**
 * 每日行程时间线场景测试
 * 对应: DailyTimelineService — 事件推送 + 去重 + 合并 + 午夜翻转
 *
 * 场景覆盖:
 *   1. 空时间线
 *   2. 单次地点推送 → 产生一条 entry
 *   3. 同地点同状态短时间内不重复 (去重)
 *   4. 地点变化 → 新 entry，旧 entry 被关闭
 *   5. 运动状态变化 (同地点) → 新 entry
 *   6. pickup/putdown/unknown 被过滤
 *   7. 连续相同地点 stationary → 合并
 *   8. 途中 (无围栏) → 空 geofenceId
 *   9. 午夜翻转 → 清空
 *   10. MAX_ENTRIES 限制
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertFalse
} = require('../../lib/assert');

// ============================================================
// JS mirror: DailyTimelineService core logic
// ============================================================

const MAX_ENTRIES_PER_DAY = 200;
const DEDUP_INTERVAL_MS = 5000;

class TimelineService {
  constructor() {
    this.entries = [];
    this.currentDate = '';
    this.lastGeofenceId = '';
    this.lastMotionState = '';
    this.lastPushTime = 0;
  }

  pushStateChange(geofenceId, geofenceLabel, geofenceIcon, motionState, now, todayStr, lat = 0, lng = 0) {
    // Date change check
    if (todayStr !== this.currentDate) {
      this.entries = [];
      this.currentDate = todayStr;
      this.lastGeofenceId = '';
      this.lastMotionState = '';
    }

    // Dedup
    if (geofenceId === this.lastGeofenceId &&
        motionState === this.lastMotionState &&
        now - this.lastPushTime < DEDUP_INTERVAL_MS) {
      return;
    }

    // Filter non-main motion states
    let isMainMotion = motionState !== 'pickup' && motionState !== 'putdown' && motionState !== 'unknown';
    if (!isMainMotion) return;

    let geofenceChanged = geofenceId !== this.lastGeofenceId;
    let motionChanged = motionState !== this.lastMotionState;
    if (!geofenceChanged && !motionChanged) return;

    // Close previous entry
    if (this.entries.length > 0) {
      let last = this.entries[this.entries.length - 1];
      if (last.endTime === 0) {
        last.endTime = now;
      }
    }

    // Create new entry
    this.entries.push({
      id: now.toString(),
      startTime: now,
      endTime: 0,
      geofenceId,
      geofenceLabel,
      geofenceIcon,
      motionState,
      latitude: lat,
      longitude: lng,
      geocodeLabel: '',
    });

    if (this.entries.length > MAX_ENTRIES_PER_DAY) {
      this.entries = this.entries.slice(-MAX_ENTRIES_PER_DAY);
    }

    this.lastGeofenceId = geofenceId;
    this.lastMotionState = motionState;
    this.lastPushTime = now;
  }

  getDailyTimeline(now) {
    let result = [];
    for (let e of this.entries) {
      result.push({
        ...e,
        endTime: e.endTime === 0 ? now : e.endTime,
      });
    }
    return result;
  }

  getMergedTimeline(now) {
    let raw = this.getDailyTimeline(now);
    if (raw.length === 0) return [];

    let merged = [];
    let current = raw[0];

    for (let i = 1; i < raw.length; i++) {
      let next = raw[i];
      if (next.geofenceId.length > 0 &&
          next.geofenceId === current.geofenceId &&
          next.motionState === 'stationary' &&
          current.motionState === 'stationary') {
        current = { ...current, endTime: next.endTime };
      } else {
        merged.push(current);
        current = next;
      }
    }
    merged.push(current);
    return merged;
  }
}

// ============================================================
// Tests
// ============================================================

describe('场景: 时间线基本推送', function () {
  it('空时间线返回空数组', function () {
    let svc = new TimelineService();
    svc.currentDate = '2026-03-02';
    let timeline = svc.getDailyTimeline(Date.now());
    assertEqual(timeline.length, 0, 'empty timeline should have 0 entries');
  });

  it('单次推送产生一条 entry', function () {
    let svc = new TimelineService();
    let now = 1709380800000; // 2026-03-02 08:00
    svc.currentDate = '2026-03-02';
    svc.pushStateChange('home', '家', '🏠', 'stationary', now, '2026-03-02');
    assertEqual(svc.entries.length, 1, 'should have 1 entry');
    assertEqual(svc.entries[0].geofenceLabel, '家');
    assertEqual(svc.entries[0].motionState, 'stationary');
    assertEqual(svc.entries[0].endTime, 0, 'current entry endTime should be 0');
  });

  it('地点变化 → 旧 entry 关闭，新 entry 创建', function () {
    let svc = new TimelineService();
    svc.currentDate = '2026-03-02';
    let t1 = 1709380800000;
    let t2 = t1 + 3600000; // +1h

    svc.pushStateChange('home', '家', '🏠', 'stationary', t1, '2026-03-02');
    svc.pushStateChange('office', '公司', '🏢', 'stationary', t2, '2026-03-02');

    assertEqual(svc.entries.length, 2, 'should have 2 entries');
    assertEqual(svc.entries[0].endTime, t2, 'first entry should be closed');
    assertEqual(svc.entries[1].geofenceLabel, '公司');
    assertEqual(svc.entries[1].endTime, 0, 'second entry should be ongoing');
  });

  it('运动状态变化 (同地点) → 新 entry', function () {
    let svc = new TimelineService();
    svc.currentDate = '2026-03-02';
    let t1 = 1709380800000;
    let t2 = t1 + 600000; // +10min

    svc.pushStateChange('home', '家', '🏠', 'stationary', t1, '2026-03-02');
    svc.pushStateChange('home', '家', '🏠', 'walking', t2, '2026-03-02');

    assertEqual(svc.entries.length, 2);
    assertEqual(svc.entries[0].motionState, 'stationary');
    assertEqual(svc.entries[1].motionState, 'walking');
  });
});

describe('场景: 去重与过滤', function () {
  it('同地点+同状态 5秒内不重复', function () {
    let svc = new TimelineService();
    svc.currentDate = '2026-03-02';
    let t1 = 1709380800000;

    svc.pushStateChange('home', '家', '🏠', 'stationary', t1, '2026-03-02');
    svc.pushStateChange('home', '家', '🏠', 'stationary', t1 + 2000, '2026-03-02'); // +2s
    svc.pushStateChange('home', '家', '🏠', 'stationary', t1 + 4000, '2026-03-02'); // +4s

    assertEqual(svc.entries.length, 1, 'dedup should prevent extra entries within 5s');
  });

  it('同地点+同状态 5秒后允许 (但不创建新entry因为没变化)', function () {
    let svc = new TimelineService();
    svc.currentDate = '2026-03-02';
    let t1 = 1709380800000;

    svc.pushStateChange('home', '家', '🏠', 'stationary', t1, '2026-03-02');
    svc.pushStateChange('home', '家', '🏠', 'stationary', t1 + 6000, '2026-03-02'); // +6s

    // No new entry because geofence and motion haven't actually changed
    assertEqual(svc.entries.length, 1, 'same state after dedup window still no new entry');
  });

  it('pickup/putdown/unknown 被过滤', function () {
    let svc = new TimelineService();
    svc.currentDate = '2026-03-02';
    let t1 = 1709380800000;

    svc.pushStateChange('home', '家', '🏠', 'stationary', t1, '2026-03-02');
    svc.pushStateChange('home', '家', '🏠', 'pickup', t1 + 6000, '2026-03-02');
    svc.pushStateChange('home', '家', '🏠', 'putdown', t1 + 8000, '2026-03-02');
    svc.pushStateChange('home', '家', '🏠', 'unknown', t1 + 10000, '2026-03-02');

    assertEqual(svc.entries.length, 1, 'pickup/putdown/unknown should be filtered');
  });
});

describe('场景: 途中 (无围栏)', function () {
  it('离开围栏 → 途中 entry (geofenceId 为空)', function () {
    let svc = new TimelineService();
    svc.currentDate = '2026-03-02';
    let t1 = 1709380800000;
    let t2 = t1 + 3600000;

    svc.pushStateChange('home', '家', '🏠', 'stationary', t1, '2026-03-02');
    svc.pushStateChange('', '', '', 'driving', t2, '2026-03-02');

    assertEqual(svc.entries.length, 2);
    assertEqual(svc.entries[1].geofenceId, '', 'transit entry should have empty geofenceId');
    assertEqual(svc.entries[1].motionState, 'driving');
  });
});

describe('场景: 合并连续相同地点', function () {
  it('连续 stationary 同地点 → 合并为一条', function () {
    let svc = new TimelineService();
    svc.currentDate = '2026-03-02';
    let t1 = 1709380800000;
    let t2 = t1 + 600000;
    let t3 = t2 + 600000;
    let t4 = t3 + 600000;

    // home stationary → home walking → home stationary
    svc.pushStateChange('home', '家', '🏠', 'stationary', t1, '2026-03-02');
    svc.pushStateChange('home', '家', '🏠', 'walking', t2, '2026-03-02');
    svc.pushStateChange('home', '家', '🏠', 'stationary', t3, '2026-03-02');

    let raw = svc.getDailyTimeline(t4);
    assertEqual(raw.length, 3, 'raw should have 3 entries');

    let merged = svc.getMergedTimeline(t4);
    // entry[0] = home stationary, entry[1] = home walking, entry[2] = home stationary
    // [0] and [2] have same geofenceId but [1] is walking so they DON'T merge
    assertEqual(merged.length, 3, 'non-consecutive stationary should not merge');
  });

  it('连续 stationary 同地点无间断 → 合并', function () {
    let svc = new TimelineService();
    svc.currentDate = '2026-03-02';
    let t1 = 1709380800000;
    let t2 = t1 + 3600000;
    let t3 = t2 + 3600000;
    let t4 = t3 + 3600000;

    // home → office → office (different entries but same geofence + stationary)
    svc.pushStateChange('home', '家', '🏠', 'stationary', t1, '2026-03-02');
    svc.pushStateChange('office', '公司', '🏢', 'stationary', t2, '2026-03-02');
    // Simulate: office entry closed, new office entry created (e.g., motion changed briefly)
    svc.pushStateChange('office', '公司', '🏢', 'walking', t3, '2026-03-02');
    svc.pushStateChange('office', '公司', '🏢', 'stationary', t3 + 300000, '2026-03-02'); // back to stationary

    let merged = svc.getMergedTimeline(t4);
    // home(stationary), office(stationary), office(walking), office(stationary)
    // office(stationary) at idx 1, then walking at idx 2, then stationary at idx 3
    // idx 1 and idx 3 are NOT consecutive → no merge
    assertEqual(merged.length, 4, 'non-consecutive same place stationary should not merge');
  });

  it('直接相邻的同地点 stationary → 合并为一条', function () {
    let svc = new TimelineService();
    svc.currentDate = '2026-03-02';
    let t1 = 1709380800000;

    // Manually create entries that are consecutive same-place stationary
    svc.entries = [
      { id: '1', startTime: t1, endTime: t1 + 3600000, geofenceId: 'office', geofenceLabel: '公司', geofenceIcon: '🏢', motionState: 'stationary' },
      { id: '2', startTime: t1 + 3600000, endTime: 0, geofenceId: 'office', geofenceLabel: '公司', geofenceIcon: '🏢', motionState: 'stationary' },
    ];

    let merged = svc.getMergedTimeline(t1 + 7200000);
    assertEqual(merged.length, 1, 'consecutive same-place stationary should merge to 1');
    assertEqual(merged[0].startTime, t1, 'merged startTime should be first entry start');
    assertEqual(merged[0].endTime, t1 + 7200000, 'merged endTime should be last entry end');
  });
});

describe('场景: 午夜翻转', function () {
  it('日期变化 → 清空时间线', function () {
    let svc = new TimelineService();
    svc.currentDate = '2026-03-01';
    let t1 = 1709294400000; // 2026-03-01
    svc.pushStateChange('home', '家', '🏠', 'stationary', t1, '2026-03-01');
    assertEqual(svc.entries.length, 1);

    // Next day
    let t2 = t1 + 86400000; // 2026-03-02
    svc.pushStateChange('home', '家', '🏠', 'stationary', t2, '2026-03-02');
    // Old entries cleared, new entry created
    assertEqual(svc.entries.length, 1, 'should have 1 entry after date change');
    assertEqual(svc.currentDate, '2026-03-02');
  });
});

describe('场景: MAX_ENTRIES 限制', function () {
  it('超过 200 条 → 保留最新 200 条', function () {
    let svc = new TimelineService();
    svc.currentDate = '2026-03-02';
    let t = 1709380800000;

    // Push 210 entries (alternating geofence to avoid dedup)
    for (let i = 0; i < 210; i++) {
      let geoId = i % 2 === 0 ? 'a' : 'b';
      svc.pushStateChange(geoId, geoId, '📍', 'stationary', t + i * 10000, '2026-03-02');
    }

    assertTrue(svc.entries.length <= MAX_ENTRIES_PER_DAY,
      `entries should be <= ${MAX_ENTRIES_PER_DAY}, got ${svc.entries.length}`);
  });
});

describe('场景: getDailyTimeline 实时 endTime', function () {
  it('最后一条的 endTime = 当前时间', function () {
    let svc = new TimelineService();
    svc.currentDate = '2026-03-02';
    let t1 = 1709380800000;
    svc.pushStateChange('home', '家', '🏠', 'stationary', t1, '2026-03-02');

    let now = t1 + 7200000; // +2h
    let timeline = svc.getDailyTimeline(now);
    assertEqual(timeline.length, 1);
    assertEqual(timeline[0].endTime, now, 'ongoing entry endTime should be current time');
  });

  it('已关闭的 entry 保留原 endTime', function () {
    let svc = new TimelineService();
    svc.currentDate = '2026-03-02';
    let t1 = 1709380800000;
    let t2 = t1 + 3600000;

    svc.pushStateChange('home', '家', '🏠', 'stationary', t1, '2026-03-02');
    svc.pushStateChange('office', '公司', '🏢', 'stationary', t2, '2026-03-02');

    let now = t2 + 3600000;
    let timeline = svc.getDailyTimeline(now);
    assertEqual(timeline[0].endTime, t2, 'closed entry should keep its endTime');
    assertEqual(timeline[1].endTime, now, 'last entry endTime should be now');
  });
});

describe('场景: 完整一日行程', function () {
  it('家 → 驾车 → 公司 → 步行 → 午餐 → 公司 → 驾车 → 家', function () {
    let svc = new TimelineService();
    svc.currentDate = '2026-03-02';
    let base = 1709380800000; // 08:00

    // 08:00 家 静止
    svc.pushStateChange('home', '家', '🏠', 'stationary', base, '2026-03-02');
    // 09:00 离家 驾车
    svc.pushStateChange('', '', '', 'driving', base + 3600000, '2026-03-02');
    // 09:30 到公司 静止
    svc.pushStateChange('office', '公司', '🏢', 'stationary', base + 5400000, '2026-03-02');
    // 12:00 出去走
    svc.pushStateChange('office', '公司', '🏢', 'walking', base + 14400000, '2026-03-02');
    // 12:10 到餐厅
    svc.pushStateChange('restaurant', '午餐', '🍜', 'stationary', base + 15000000, '2026-03-02');
    // 13:00 走回公司
    svc.pushStateChange('', '', '', 'walking', base + 18000000, '2026-03-02');
    // 13:10 到公司
    svc.pushStateChange('office', '公司', '🏢', 'stationary', base + 18600000, '2026-03-02');
    // 18:00 下班驾车
    svc.pushStateChange('', '', '', 'driving', base + 36000000, '2026-03-02');
    // 18:30 到家
    svc.pushStateChange('home', '家', '🏠', 'stationary', base + 37800000, '2026-03-02');

    assertEqual(svc.entries.length, 9, 'full day should have 9 entries');

    // Check merged
    let now = base + 43200000; // 20:00
    let merged = svc.getMergedTimeline(now);
    // No consecutive same-place stationary → same as raw
    assertEqual(merged.length, 9, 'no merge needed for diverse sequence');

    // Verify first and last
    assertEqual(merged[0].geofenceLabel, '家');
    assertEqual(merged[0].motionState, 'stationary');
    assertEqual(merged[merged.length - 1].geofenceLabel, '家');
    assertEqual(merged[merged.length - 1].motionState, 'stationary');
  });
});
