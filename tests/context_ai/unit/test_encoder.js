'use strict';
/**
 * 编码器测试
 * 对应设计文档: §5.1 感知域架构 - 编码器输出规范
 * 覆盖: 概率分布输出/特征向量/数据质量评分/各类编码器
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertGreaterThan, assertLessThan, assertDefined
} = require('../../lib/assert');

// ── JS 镜像：编码器（ArkTS plugins → C++ encoder 接口） ──

/**
 * 编码器输出规范
 * @typedef {{ distribution: Object, features: number[], quality: number, summary?: string }} EncodedOutput
 */

/** 位置编码器: GPS精度差时多地点有概率 */
function encodeLocation(lat, lng, accuracy, knownPlaces) {
  if (lat == null || lng == null) {
    return { distribution: {}, features: [0, 0, 0], quality: 0, summary: '位置未知' };
  }

  const distribution = {};
  let maxScore = 0;
  for (const place of knownPlaces) {
    const dist = haversineApprox(lat, lng, place.lat, place.lng);
    // 距离越近概率越高，考虑GPS精度
    const score = Math.max(0, 1 - dist / (accuracy + place.radius));
    if (score > 0.01) distribution[place.name] = parseFloat(score.toFixed(3));
    if (score > maxScore) maxScore = score;
  }

  const quality = Math.min(1.0, 50 / (accuracy + 1)); // 精度越高quality越高
  const features = [lat / 90, lng / 180, quality]; // 归一化特征

  return { distribution, features, quality: parseFloat(quality.toFixed(3)), summary: `位置精度 ${accuracy}m` };
}

/** 近似 Haversine (km) */
function haversineApprox(lat1, lng1, lat2, lng2) {
  const R = 6371;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLng = (lng2 - lng1) * Math.PI / 180;
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) * Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

/** 运动状态编码器: 多状态概率 */
function encodeMotion(accelMag, stepFreq) {
  if (accelMag == null) {
    return { distribution: { unknown: 1.0 }, features: [0, 0], quality: 0 };
  }

  const distribution = {};
  // 静止: 加速度接近9.8, 无步频
  distribution.stationary = accelMag < 10.5 && stepFreq < 0.5 ? 0.9 : Math.max(0, 1 - accelMag / 20);
  // 走路: 中等加速度, 有步频
  distribution.walking = stepFreq >= 1.0 && stepFreq < 3.0 ? 0.8 : 0.1;
  // 跑步: 高步频
  distribution.running = stepFreq >= 3.0 ? 0.8 : 0.05;
  // 开车: 低步频但高加速变化
  distribution.driving = accelMag > 11 && stepFreq < 0.5 ? 0.7 : 0.05;

  // 过滤极低概率
  for (const k of Object.keys(distribution)) {
    distribution[k] = parseFloat(distribution[k].toFixed(3));
    if (distribution[k] < 0.01) delete distribution[k];
  }

  const quality = 0.9; // 加速度计一般很可靠
  return { distribution, features: [accelMag / 20, stepFreq / 5], quality };
}

/** 时间段编码器: 非互斥分类 */
function encodeTimePeriod(hour) {
  if (hour == null || hour < 0 || hour > 24) {
    return { distribution: {}, features: [0], quality: 0 };
  }

  const distribution = {};
  // 非互斥: morning 和 commute 可以同时为true
  if (hour >= 5 && hour < 12) distribution.morning = gaussianScore(hour, 8, 3);
  if (hour >= 12 && hour < 14) distribution.noon = gaussianScore(hour, 12.5, 1);
  if (hour >= 12 && hour < 18) distribution.afternoon = gaussianScore(hour, 15, 3);
  if (hour >= 17 && hour < 21) distribution.evening = gaussianScore(hour, 19, 2);
  if (hour >= 21 || hour < 5) distribution.night = hour >= 21 ? gaussianScore(hour, 23, 2) : 0.8;

  // 通勤时间带 (非互斥)
  if (hour >= 7 && hour < 9) distribution.commute_morning = gaussianScore(hour, 7.5, 0.5);
  if (hour >= 17 && hour < 19) distribution.commute_evening = gaussianScore(hour, 18, 0.5);

  // 清理
  for (const k of Object.keys(distribution)) {
    distribution[k] = parseFloat(distribution[k].toFixed(3));
    if (distribution[k] < 0.01) delete distribution[k];
  }

  return { distribution, features: [hour / 24], quality: 1.0 };
}

function gaussianScore(val, center, sigma) {
  return Math.exp(-0.5 * ((val - center) / sigma) ** 2);
}

/** 噪音编码器 */
function encodeNoise(dbLevel) {
  if (dbLevel == null) {
    return { distribution: {}, features: [0], quality: 0 };
  }

  const distribution = {};
  if (dbLevel < 40) distribution.quiet = Math.max(0, 1 - dbLevel / 40);
  if (dbLevel >= 30 && dbLevel < 60) distribution.office = gaussianScore(dbLevel, 45, 10);
  if (dbLevel >= 50 && dbLevel < 75) distribution.cafe = gaussianScore(dbLevel, 60, 10);
  if (dbLevel >= 70) distribution.noisy = Math.min(1, (dbLevel - 70) / 30);

  for (const k of Object.keys(distribution)) {
    distribution[k] = parseFloat(distribution[k].toFixed(3));
    if (distribution[k] < 0.01) delete distribution[k];
  }

  return { distribution, features: [dbLevel / 100], quality: 0.85 };
}

/** 通用质量评分 */
function qualityScore(age_ms, maxAge_ms, sensorReliability) {
  sensorReliability = sensorReliability ?? 1.0;
  const freshness = Math.max(0, 1 - age_ms / maxAge_ms);
  return parseFloat((freshness * sensorReliability).toFixed(3));
}

// ── 测试 ──

describe('Encoder - 概率分布输出', function () {
  it('位置分布: 不要求归一化', function () {
    const places = [
      { name: 'home', lat: 39.9, lng: 116.3, radius: 0.1 },
      { name: 'market', lat: 39.91, lng: 116.31, radius: 0.2 },
    ];
    const r = encodeLocation(39.9, 116.3, 10, places);
    assertDefined(r.distribution);
    // 多个地点可以同时有概率
    assertGreaterThan(Object.keys(r.distribution).length, 0);
    // 不要求归一化: 总和可以>1或<1
    const sum = Object.values(r.distribution).reduce((a, b) => a + b, 0);
    // 只验证值在合理范围
    for (const v of Object.values(r.distribution)) {
      assertGreaterThan(v, 0);
      assertLessThan(v, 1.01);
    }
  });

  it('运动分布: 多状态同时有概率', function () {
    const r = encodeMotion(9.8, 0.1); // 静止
    assertDefined(r.distribution.stationary);
    assertGreaterThan(r.distribution.stationary, 0.5);
  });

  it('时间段分布: morning+commute 非互斥', function () {
    const r = encodeTimePeriod(7.5);
    assertDefined(r.distribution.morning);
    assertDefined(r.distribution.commute_morning);
    // 两个同时存在
    assertGreaterThan(r.distribution.morning, 0);
    assertGreaterThan(r.distribution.commute_morning, 0);
  });
});

describe('Encoder - 特征向量', function () {
  it('位置特征: [lat_norm, lng_norm, quality]', function () {
    const r = encodeLocation(39.9, 116.3, 10, []);
    assertEqual(r.features.length, 3);
    assertTrue(r.features[0] > 0 && r.features[0] < 1); // lat/90
    assertTrue(r.features[1] > 0 && r.features[1] < 1); // lng/180
  });

  it('运动特征: [accel_norm, step_norm]', function () {
    const r = encodeMotion(10, 2);
    assertEqual(r.features.length, 2);
    assertTrue(r.features[0] >= 0 && r.features[0] <= 1);
  });

  it('时间特征: [hour_norm]', function () {
    const r = encodeTimePeriod(12);
    assertEqual(r.features.length, 1);
    assertEqual(r.features[0], 0.5); // 12/24
  });
});

describe('Encoder - 数据质量评分', function () {
  it('GPS精度10m → 高quality', function () {
    const r = encodeLocation(39.9, 116.3, 10, []);
    assertGreaterThan(r.quality, 0.8);
  });

  it('GPS精度500m → 低quality', function () {
    const r = encodeLocation(39.9, 116.3, 500, []);
    assertLessThan(r.quality, 0.2);
  });

  it('时间 → quality=1.0（时钟总是准确的）', function () {
    assertEqual(encodeTimePeriod(8).quality, 1.0);
  });

  it('加速度计 → quality=0.9', function () {
    assertEqual(encodeMotion(10, 1).quality, 0.9);
  });

  it('缺失数据 → quality=0', function () {
    assertEqual(encodeLocation(null, null, 0, []).quality, 0);
    assertEqual(encodeMotion(null, null).quality, 0);
    assertEqual(encodeTimePeriod(null).quality, 0);
  });
});

describe('Encoder - 位置编码', function () {
  it('在家附近 → home高概率', function () {
    const places = [{ name: 'home', lat: 39.9, lng: 116.3, radius: 0.5 }];
    const r = encodeLocation(39.9, 116.3, 10, places);
    assertGreaterThan(r.distribution.home, 0.5);
  });

  it('GPS不确定时多地点有概率', function () {
    const places = [
      { name: 'home', lat: 39.9, lng: 116.3, radius: 0.5 },
      { name: 'park', lat: 39.901, lng: 116.301, radius: 0.5 },
    ];
    const r = encodeLocation(39.9005, 116.3005, 200, places); // 精度差
    // 两个地点都可能有概率
    const keys = Object.keys(r.distribution);
    assertGreaterThan(keys.length, 0);
  });

  it('远离所有地点 → 空分布', function () {
    const places = [{ name: 'home', lat: 39.9, lng: 116.3, radius: 0.1 }];
    const r = encodeLocation(40.5, 117.0, 10, places);
    assertEqual(Object.keys(r.distribution).length, 0);
  });
});

describe('Encoder - 运动编码', function () {
  it('静止: accel≈9.8, step=0', function () {
    const r = encodeMotion(9.8, 0.1);
    assertGreaterThan(r.distribution.stationary, 0.5);
  });

  it('走路: step=2Hz', function () {
    const r = encodeMotion(12, 2.0);
    assertGreaterThan(r.distribution.walking, 0.5);
  });

  it('跑步: step=4Hz', function () {
    const r = encodeMotion(15, 4.0);
    assertGreaterThan(r.distribution.running, 0.5);
  });

  it('等红灯: 静止和开车都可能', function () {
    // 静止状态但加速度稍高（车辆震动）
    const r = encodeMotion(10.2, 0.2);
    assertDefined(r.distribution.stationary);
    assertGreaterThan(r.distribution.stationary, 0);
  });
});

describe('Encoder - 时间段编码', function () {
  it('8:00 → morning', function () {
    const r = encodeTimePeriod(8);
    assertDefined(r.distribution.morning);
    assertGreaterThan(r.distribution.morning, 0.9);
  });

  it('12:30 → noon + afternoon', function () {
    const r = encodeTimePeriod(12.5);
    assertDefined(r.distribution.noon);
    assertDefined(r.distribution.afternoon);
  });

  it('23:00 → night', function () {
    const r = encodeTimePeriod(23);
    assertDefined(r.distribution.night);
    assertGreaterThan(r.distribution.night, 0.5);
  });

  it('7:30 → morning + commute_morning', function () {
    const r = encodeTimePeriod(7.5);
    assertDefined(r.distribution.morning);
    assertDefined(r.distribution.commute_morning);
  });
});

describe('Encoder - 噪音编码', function () {
  it('30dB → quiet', function () {
    const r = encodeNoise(30);
    assertDefined(r.distribution.quiet);
    assertGreaterThan(r.distribution.quiet, 0);
  });

  it('45dB → office', function () {
    const r = encodeNoise(45);
    assertDefined(r.distribution.office);
    assertGreaterThan(r.distribution.office, 0.5);
  });

  it('缺失 → quality=0', function () {
    assertEqual(encodeNoise(null).quality, 0);
  });
});

describe('Encoder - 质量评分工具', function () {
  it('新鲜数据 → 高质量', function () {
    assertGreaterThan(qualityScore(0, 60000, 1.0), 0.9);
  });

  it('过期数据 → 低质量', function () {
    assertEqual(qualityScore(60000, 60000, 1.0), 0);
  });

  it('传感器可靠性影响', function () {
    assertGreaterThan(
      qualityScore(1000, 60000, 1.0),
      qualityScore(1000, 60000, 0.5)
    );
  });
});

describe('Encoder - 边界和异常', function () {
  it('hour=-1 → 空分布', function () {
    assertEqual(Object.keys(encodeTimePeriod(-1).distribution).length, 0);
  });

  it('hour=25 → 空分布', function () {
    assertEqual(Object.keys(encodeTimePeriod(25).distribution).length, 0);
  });

  it('GPS null → quality=0, 空分布', function () {
    const r = encodeLocation(null, null, 0, []);
    assertEqual(r.quality, 0);
    assertEqual(Object.keys(r.distribution).length, 0);
  });

  it('加速度 null → quality=0', function () {
    const r = encodeMotion(null, null);
    assertEqual(r.quality, 0);
  });
});
