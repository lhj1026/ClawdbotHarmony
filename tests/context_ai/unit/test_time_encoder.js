'use strict';
/**
 * 时间编码器测试
 * 对应设计文档: §5.1 感知域架构 - 编码器输出规范
 * 覆盖: 时刻编码/星期编码/节假日/时间段分类/分布格式/边界/缺失
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertGreaterThan, assertLessThan,
  assertDefined, assertDeepEqual
} = require('../../lib/assert');

// ── JS 镜像：时间编码器 ──

/** 时间段分类（non-exclusive, multi-label） */
function classifyTimePeriod(hour) {
  const dist = {};
  // 定义时间段及其中心和半宽
  const periods = [
    { name: 'dawn',      center: 5.5,  hw: 1.5 },
    { name: 'morning',   center: 8,    hw: 2   },
    { name: 'commute_am',center: 7.5,  hw: 1   },
    { name: 'noon',      center: 12,   hw: 1   },
    { name: 'afternoon', center: 15,   hw: 2   },
    { name: 'commute_pm',center: 17.5, hw: 1   },
    { name: 'evening',   center: 20,   hw: 2   },
    { name: 'night',     center: 23,   hw: 1.5 },
    { name: 'midnight',  center: 2,    hw: 2   },
  ];
  for (const p of periods) {
    let diff = Math.abs(hour - p.center);
    // 处理跨午夜
    if (diff > 12) diff = 24 - diff;
    if (diff <= p.hw) {
      dist[p.name] = 1.0;
    } else {
      const decay = Math.exp(-0.5 * ((diff - p.hw) / 1.0) ** 2);
      if (decay > 0.05) dist[p.name] = parseFloat(decay.toFixed(4));
    }
  }
  return dist;
}

/** 星期编码 */
function encodeWeekday(dayOfWeek) {
  // dayOfWeek: 0=Sun, 1=Mon, ..., 6=Sat
  const dist = {};
  if (dayOfWeek >= 1 && dayOfWeek <= 5) {
    dist.weekday = 1.0;
    dist.weekend = 0.0;
  } else {
    dist.weekday = 0.0;
    dist.weekend = 1.0;
  }
  // 周五下午也带点 weekend 味
  if (dayOfWeek === 5) dist.weekend = 0.3;
  return dist;
}

/** 节假日编码（简化：传入 isHoliday boolean） */
function encodeHoliday(isHoliday, isWorkdayOverride) {
  if (isWorkdayOverride === true) return { holiday: 0.0, workday: 1.0 };
  if (isHoliday) return { holiday: 1.0, workday: 0.0 };
  return { holiday: 0.0, workday: 1.0 };
}

/** 完整时间编码输出 */
function encodeTime(hour, dayOfWeek, isHoliday, isWorkdayOverride) {
  if (hour === null || hour === undefined || isNaN(hour)) {
    return { distribution: {}, features: [], quality: 0.0 };
  }
  const period = classifyTimePeriod(hour);
  const weekday = encodeWeekday(dayOfWeek ?? 1);
  const holiday = encodeHoliday(isHoliday ?? false, isWorkdayOverride);
  const distribution = { ...period, ...weekday, ...holiday };
  // 特征向量: [hour_sin, hour_cos, dow_sin, dow_cos, isHoliday]
  const hRad = (hour / 24) * 2 * Math.PI;
  const dRad = ((dayOfWeek ?? 1) / 7) * 2 * Math.PI;
  const features = [
    Math.sin(hRad), Math.cos(hRad),
    Math.sin(dRad), Math.cos(dRad),
    isHoliday ? 1.0 : 0.0,
  ];
  return { distribution, features, quality: 1.0 };
}

// ── 测试 ──

describe('TimeEncoder - 时间段分类', function () {
  it('8:00 → morning=1.0', function () {
    const d = classifyTimePeriod(8);
    assertEqual(d.morning, 1.0);
  });

  it('7:30 → commute_am=1.0, morning=1.0', function () {
    const d = classifyTimePeriod(7.5);
    assertEqual(d.commute_am, 1.0);
    assertEqual(d.morning, 1.0);
  });

  it('12:00 → noon=1.0', function () {
    const d = classifyTimePeriod(12);
    assertEqual(d.noon, 1.0);
  });

  it('23:00 → night=1.0', function () {
    const d = classifyTimePeriod(23);
    assertEqual(d.night, 1.0);
  });

  it('2:00 → midnight=1.0', function () {
    const d = classifyTimePeriod(2);
    assertEqual(d.midnight, 1.0);
  });

  it('边界: 0:00 跨午夜 → midnight 有值', function () {
    const d = classifyTimePeriod(0);
    assertDefined(d.midnight);
    assertGreaterThan(d.midnight, 0.5);
  });

  it('10:00 → morning衰减, 非noon', function () {
    const d = classifyTimePeriod(10);
    // morning center=8, hw=2, diff=2 → 1.0（边界）
    assertEqual(d.morning, 1.0);
  });

  it('11:00 → morning衰减 < 1.0, noon衰减', function () {
    const d = classifyTimePeriod(11);
    assertGreaterThan(d.noon || 0, 0.3);
    assertLessThan(d.morning || 0, 1.0);
  });

  it('所有分布值在 [0,1]', function () {
    for (let h = 0; h < 24; h++) {
      const d = classifyTimePeriod(h);
      for (const v of Object.values(d)) {
        assertTrue(v >= 0 && v <= 1.0, `hour=${h} val=${v}`);
      }
    }
  });
});

describe('TimeEncoder - 星期编码', function () {
  it('周一 → weekday=1.0', function () {
    assertEqual(encodeWeekday(1).weekday, 1.0);
  });

  it('周日 → weekend=1.0', function () {
    assertEqual(encodeWeekday(0).weekend, 1.0);
  });

  it('周六 → weekend=1.0', function () {
    assertEqual(encodeWeekday(6).weekend, 1.0);
  });

  it('周五 → weekday=1.0, weekend=0.3', function () {
    const d = encodeWeekday(5);
    assertEqual(d.weekday, 1.0);
    assertEqual(d.weekend, 0.3);
  });
});

describe('TimeEncoder - 节假日编码', function () {
  it('普通工作日', function () {
    assertDeepEqual(encodeHoliday(false), { holiday: 0.0, workday: 1.0 });
  });

  it('节假日', function () {
    assertDeepEqual(encodeHoliday(true), { holiday: 1.0, workday: 0.0 });
  });

  it('调休上班（节假日但工作日覆盖）', function () {
    assertDeepEqual(encodeHoliday(true, true), { holiday: 0.0, workday: 1.0 });
  });
});

describe('TimeEncoder - 完整编码输出', function () {
  it('正常输出包含 distribution/features/quality', function () {
    const r = encodeTime(8, 1, false);
    assertDefined(r.distribution);
    assertDefined(r.features);
    assertEqual(r.quality, 1.0);
    assertEqual(r.features.length, 5);
  });

  it('缺失 hour → quality=0', function () {
    const r = encodeTime(null, 1, false);
    assertEqual(r.quality, 0.0);
    assertDeepEqual(r.distribution, {});
  });

  it('NaN hour → quality=0', function () {
    const r = encodeTime(NaN, 1, false);
    assertEqual(r.quality, 0.0);
  });

  it('特征向量: sin/cos 周期性', function () {
    const r = encodeTime(0, 1, false);
    // hour=0 → sin(0)=0, cos(0)=1
    assertLessThan(Math.abs(r.features[0]), 0.01);
    assertGreaterThan(r.features[1], 0.99);
  });

  it('特征向量: 节假日标志', function () {
    const rh = encodeTime(8, 1, true);
    assertEqual(rh.features[4], 1.0);
    const rw = encodeTime(8, 1, false);
    assertEqual(rw.features[4], 0.0);
  });
});
