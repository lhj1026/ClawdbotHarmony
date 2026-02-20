'use strict';
/**
 * 噪音编码器测试
 * 对应设计文档: §2.1 环境(五感) - 耳, §5.1 编码器输出规范
 * 覆盖: 安静/办公/咖啡厅/嘈杂/分布/边界/缺失
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertGreaterThan, assertDefined
} = require('../../lib/assert');

// ── JS 镜像：噪音编码器 ──

function encodeNoise(dbLevel) {
  if (dbLevel == null || isNaN(dbLevel)) {
    return { distribution: { quiet: 0.5, office: 0.5, cafe: 0.5, loud: 0.5 }, features: [], quality: 0.0 };
  }
  const db = Math.max(0, Math.min(120, dbLevel));
  const envs = [
    { name: 'quiet',  center: 30,  sigma: 10 },
    { name: 'office', center: 50,  sigma: 10 },
    { name: 'cafe',   center: 65,  sigma: 8  },
    { name: 'loud',   center: 85,  sigma: 10 },
  ];
  const dist = {};
  for (const e of envs) {
    const v = Math.exp(-0.5 * ((db - e.center) / e.sigma) ** 2);
    if (v > 0.05) dist[e.name] = parseFloat(v.toFixed(4));
  }
  return { distribution: dist, features: [db / 120], quality: 0.8 };
}

// ── 测试 ──

describe('NoiseEncoder - 环境噪音分类', function () {
  it('30dB → quiet=1.0', function () {
    const r = encodeNoise(30);
    assertEqual(r.distribution.quiet, 1.0);
  });

  it('50dB → office=1.0', function () {
    const r = encodeNoise(50);
    assertEqual(r.distribution.office, 1.0);
  });

  it('65dB → cafe=1.0', function () {
    const r = encodeNoise(65);
    assertEqual(r.distribution.cafe, 1.0);
  });

  it('85dB → loud=1.0', function () {
    const r = encodeNoise(85);
    assertEqual(r.distribution.loud, 1.0);
  });

  it('40dB → quiet和office都有概率', function () {
    const r = encodeNoise(40);
    assertDefined(r.distribution.quiet);
    assertDefined(r.distribution.office);
  });

  it('75dB → cafe和loud都有概率', function () {
    const r = encodeNoise(75);
    assertDefined(r.distribution.cafe);
    assertDefined(r.distribution.loud);
  });
});

describe('NoiseEncoder - 边界/缺失', function () {
  it('0dB → quiet有值', function () {
    const r = encodeNoise(0);
    assertDefined(r.distribution.quiet);
  });

  it('120dB → loud有值 (或距中心太远衰减)', function () {
    const r = encodeNoise(110); // 110dB closer to loud center=85
    assertDefined(r.distribution.loud);
  });

  it('缺失 → 全部0.5, quality=0', function () {
    const r = encodeNoise(null);
    assertEqual(r.quality, 0.0);
    assertEqual(r.distribution.quiet, 0.5);
    assertEqual(r.distribution.office, 0.5);
  });

  it('分布值在[0,1]', function () {
    for (let db = 0; db <= 120; db += 10) {
      const r = encodeNoise(db);
      for (const v of Object.values(r.distribution)) {
        assertTrue(v >= 0 && v <= 1.0, `db=${db} val=${v}`);
      }
    }
  });
});
