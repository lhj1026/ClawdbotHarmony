'use strict';
/**
 * 运动状态编码器测试
 * 对应设计文档: §2.1 物理世界数据源 - 运动状态, §5.1 编码器输出规范
 * 覆盖: 静止/走路/跑步/骑车/坐车/分布格式/缺失/边界
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertGreaterThan, assertLessThan, assertDefined
} = require('../../lib/assert');

// ── JS 镜像：运动状态编码器 ──

const MOTION_STATES = ['stationary', 'walking', 'running', 'cycling', 'driving', 'transit'];

/**
 * 运动状态编码：输入加速度计数据，输出概率分布
 * 简化模型：给定主状态和置信度，生成 multi-label 分布
 */
function encodeMotion(primaryState, confidence) {
  if (!primaryState || confidence == null || isNaN(confidence)) {
    // 缺失数据 → 均匀分布
    const dist = {};
    for (const s of MOTION_STATES) dist[s] = 1.0 / MOTION_STATES.length;
    return { distribution: dist, features: [], quality: 0.0 };
  }

  const dist = {};
  const conf = Math.max(0, Math.min(1, confidence));
  const remaining = 1.0 - conf;

  // 混淆矩阵：容易混淆的状态对
  const confusion = {
    stationary: { walking: 0.4, driving: 0.3 },   // 等红灯时
    walking:    { stationary: 0.3, running: 0.3 },
    running:    { walking: 0.5, cycling: 0.2 },
    cycling:    { running: 0.3, driving: 0.3 },
    driving:    { stationary: 0.4, transit: 0.4 },  // 堵车时
    transit:    { driving: 0.5, stationary: 0.3 },
  };

  dist[primaryState] = conf;
  const confusionMap = confusion[primaryState] || {};
  const totalConfusion = Object.values(confusionMap).reduce((a, b) => a + b, 0);

  for (const [state, weight] of Object.entries(confusionMap)) {
    dist[state] = parseFloat((remaining * weight / totalConfusion).toFixed(4));
  }

  // 特征向量：one-hot + confidence
  const features = MOTION_STATES.map(s => s === primaryState ? conf : 0);
  features.push(conf);

  return {
    distribution: dist,
    features,
    quality: conf,
  };
}

// ── 测试 ──

describe('MotionEncoder - 基本状态编码', function () {
  it('stationary 高置信度 → stationary=0.9', function () {
    const r = encodeMotion('stationary', 0.9);
    assertEqual(r.distribution.stationary, 0.9);
    assertGreaterThan(r.quality, 0.8);
  });

  it('walking 高置信度 → walking为主', function () {
    const r = encodeMotion('walking', 0.8);
    assertEqual(r.distribution.walking, 0.8);
  });

  it('driving 低置信度 → 混淆状态也有概率', function () {
    const r = encodeMotion('driving', 0.5);
    assertEqual(r.distribution.driving, 0.5);
    assertDefined(r.distribution.stationary);
    assertDefined(r.distribution.transit);
  });

  for (const state of MOTION_STATES) {
    it(`${state} 编码输出非空`, function () {
      const r = encodeMotion(state, 0.7);
      assertGreaterThan(r.distribution[state], 0.5);
    });
  }
});

describe('MotionEncoder - 混淆矩阵', function () {
  it('等红灯: driving低置信度 → stationary也有概率', function () {
    const r = encodeMotion('driving', 0.5);
    assertGreaterThan(r.distribution.stationary, 0);
  });

  it('缓步: walking低置信度 → stationary和running都有', function () {
    const r = encodeMotion('walking', 0.6);
    assertGreaterThan(r.distribution.stationary || 0, 0);
    assertGreaterThan(r.distribution.running || 0, 0);
  });

  it('公交: transit → driving也有概率', function () {
    const r = encodeMotion('transit', 0.7);
    assertGreaterThan(r.distribution.driving || 0, 0);
  });
});

describe('MotionEncoder - 边界/缺失', function () {
  it('confidence=1.0 → 主状态=1.0, 无混淆', function () {
    const r = encodeMotion('running', 1.0);
    assertEqual(r.distribution.running, 1.0);
    // remaining=0 → 其他状态=0或不存在
  });

  it('confidence=0 → 全部分配给混淆', function () {
    const r = encodeMotion('walking', 0.0);
    assertEqual(r.distribution.walking, 0.0);
  });

  it('confidence超出范围被裁剪', function () {
    const r = encodeMotion('walking', 1.5);
    assertEqual(r.distribution.walking, 1.0);
  });

  it('缺失状态 → 均匀分布, quality=0', function () {
    const r = encodeMotion(null, null);
    assertEqual(r.quality, 0.0);
    const vals = Object.values(r.distribution);
    assertEqual(vals.length, MOTION_STATES.length);
    for (const v of vals) {
      assertLessThan(Math.abs(v - 1.0 / MOTION_STATES.length), 0.01);
    }
  });

  it('未知状态名 → 仅主状态有值', function () {
    const r = encodeMotion('flying', 0.8);
    assertEqual(r.distribution.flying, 0.8);
  });
});

describe('MotionEncoder - 特征向量', function () {
  it('特征长度 = 状态数+1', function () {
    const r = encodeMotion('walking', 0.7);
    assertEqual(r.features.length, MOTION_STATES.length + 1);
  });

  it('one-hot 位置正确', function () {
    const r = encodeMotion('running', 0.9);
    assertEqual(r.features[MOTION_STATES.indexOf('running')], 0.9);
    assertEqual(r.features[MOTION_STATES.indexOf('walking')], 0);
  });
});
