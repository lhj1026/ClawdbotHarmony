'use strict';
/**
 * 电量编码器测试
 * 对应设计文档: §2.1 物理世界数据源 - 手机电源, §5.1 编码器输出规范
 * 覆盖: 电量级别/充电状态/分布格式/边界/缺失
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertGreaterThan, assertDefined
} = require('../../lib/assert');

// ── JS 镜像：电量编码器 ──

function encodeBattery(level, isCharging) {
  if (level == null || isNaN(level)) {
    return { distribution: {}, features: [], quality: 0.0 };
  }
  level = Math.max(0, Math.min(100, level));

  const dist = {};
  // 电量级别（带重叠的高斯）
  const levels = [
    { name: 'critical', center: 5,  sigma: 5  },
    { name: 'low',      center: 15, sigma: 8  },
    { name: 'medium',   center: 50, sigma: 20 },
    { name: 'high',     center: 85, sigma: 10 },
    { name: 'full',     center: 98, sigma: 3  },
  ];
  for (const l of levels) {
    const v = Math.exp(-0.5 * ((level - l.center) / l.sigma) ** 2);
    if (v > 0.05) dist[l.name] = parseFloat(v.toFixed(4));
  }

  // 充电状态
  dist.charging = isCharging ? 1.0 : 0.0;
  dist.discharging = isCharging ? 0.0 : 1.0;

  const features = [level / 100, isCharging ? 1 : 0];
  return { distribution: dist, features, quality: 1.0 };
}

// ── 测试 ──

describe('BatteryEncoder - 电量级别', function () {
  it('5% → critical高', function () {
    const r = encodeBattery(5, false);
    assertEqual(r.distribution.critical, 1.0);
  });

  it('15% → low高', function () {
    const r = encodeBattery(15, false);
    assertDefined(r.distribution.low);
    assertGreaterThan(r.distribution.low, 0.9);
  });

  it('50% → medium高', function () {
    const r = encodeBattery(50, false);
    assertEqual(r.distribution.medium, 1.0);
  });

  it('85% → high高', function () {
    const r = encodeBattery(85, false);
    assertDefined(r.distribution.high);
    assertGreaterThan(r.distribution.high, 0.9);
  });

  it('100% → full高', function () {
    const r = encodeBattery(100, false);
    assertDefined(r.distribution.full);
    assertGreaterThan(r.distribution.full, 0.5);
  });

  it('10% → low和critical都有值', function () {
    const r = encodeBattery(10, false);
    assertDefined(r.distribution.low);
    assertDefined(r.distribution.critical);
  });
});

describe('BatteryEncoder - 充电状态', function () {
  it('充电中 → charging=1', function () {
    const r = encodeBattery(50, true);
    assertEqual(r.distribution.charging, 1.0);
    assertEqual(r.distribution.discharging, 0.0);
  });

  it('未充电 → discharging=1', function () {
    const r = encodeBattery(50, false);
    assertEqual(r.distribution.charging, 0.0);
    assertEqual(r.distribution.discharging, 1.0);
  });
});

describe('BatteryEncoder - 边界/缺失', function () {
  it('level=0 → critical', function () {
    const r = encodeBattery(0, false);
    assertDefined(r.distribution.critical);
  });

  it('level<0 裁剪到0', function () {
    const r = encodeBattery(-10, false);
    assertEqual(r.features[0], 0);
  });

  it('level>100 裁剪到100', function () {
    const r = encodeBattery(150, false);
    assertEqual(r.features[0], 1.0);
  });

  it('缺失 → quality=0', function () {
    const r = encodeBattery(null, false);
    assertEqual(r.quality, 0.0);
  });

  it('NaN → quality=0', function () {
    const r = encodeBattery(NaN, false);
    assertEqual(r.quality, 0.0);
  });

  it('特征向量格式', function () {
    const r = encodeBattery(50, true);
    assertEqual(r.features.length, 2);
    assertEqual(r.features[0], 0.5);
    assertEqual(r.features[1], 1);
  });
});
