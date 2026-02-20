'use strict';
/**
 * 奖励计算测试
 * 对应设计文档: §5.4 学习域架构 - 奖励计算
 * 覆盖: 基础奖励/打扰惩罚/正确性奖励/时段加权
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertGreaterThan, assertLessThan, assertTrue
} = require('../../lib/assert');

// ── JS 镜像：奖励计算 ──

/** 基础反馈奖励 */
function baseReward(feedback) {
  const map = {
    'click':    1.0,   // 点击通知
    'thanks':   1.5,   // 说谢谢
    'dismiss':  -0.5,  // 划走
    'ignore':   -0.3,  // 忽略
    'annoyed':  -2.0,  // "别烦我"
  };
  return map[feedback] ?? 0;
}

/** 打扰惩罚: -0.1 × (最近推送次数^1.5) */
function disturbancePenalty(recentPushCount) {
  return -0.1 * Math.pow(recentPushCount, 1.5);
}

/** 正确性奖励 */
function accuracyBonus(pushed, shouldHavePushed) {
  if (pushed && shouldHavePushed) return 0.5;    // 推对了
  if (!pushed && !shouldHavePushed) return 0.2;   // 没推也对了
  if (!pushed && shouldHavePushed) return -1.0;   // 该推没推
  return -0.3;                                     // 不该推但推了
}

/** 时段加权 */
function periodWeight(period) {
  const weights = {
    'sleeping': 3.0,
    'driving':  2.5,
    'meeting':  2.0,
    'idle':     1.0,
    'busy':     1.5,
  };
  return weights[period] ?? 1.0;
}

/** 完整奖励计算 */
function computeReward(feedback, recentPushCount, pushed, shouldHavePushed, period) {
  const base = baseReward(feedback);
  const penalty = disturbancePenalty(recentPushCount);
  const accuracy = accuracyBonus(pushed, shouldHavePushed);
  const weight = periodWeight(period);
  return (base + penalty + accuracy) * weight;
}

// ── 测试 ──

describe('Reward - 基础反馈', function () {
  it('click → +1.0', function () {
    assertEqual(baseReward('click'), 1.0);
  });

  it('thanks → +1.5', function () {
    assertEqual(baseReward('thanks'), 1.5);
  });

  it('dismiss → -0.5', function () {
    assertEqual(baseReward('dismiss'), -0.5);
  });

  it('ignore → -0.3', function () {
    assertEqual(baseReward('ignore'), -0.3);
  });

  it('annoyed → -2.0', function () {
    assertEqual(baseReward('annoyed'), -2.0);
  });

  it('未知反馈 → 0', function () {
    assertEqual(baseReward('unknown'), 0);
  });
});

describe('Reward - 打扰惩罚', function () {
  it('0次推送 → 无惩罚', function () {
    assertEqual(disturbancePenalty(0), 0);
  });

  it('1次推送 → -0.1', function () {
    assertEqual(disturbancePenalty(1), -0.1);
  });

  it('5次推送 → 较大惩罚', function () {
    const p = disturbancePenalty(5);
    assertLessThan(p, -1.0);
  });

  it('推送越多惩罚越大（非线性）', function () {
    const p3 = disturbancePenalty(3);
    const p5 = disturbancePenalty(5);
    assertLessThan(p5, p3);
  });
});

describe('Reward - 正确性奖励', function () {
  it('推对了 → +0.5', function () {
    assertEqual(accuracyBonus(true, true), 0.5);
  });

  it('没推也对了 → +0.2', function () {
    assertEqual(accuracyBonus(false, false), 0.2);
  });

  it('该推没推 → -1.0', function () {
    assertEqual(accuracyBonus(false, true), -1.0);
  });

  it('不该推但推了 → -0.3', function () {
    assertEqual(accuracyBonus(true, false), -0.3);
  });
});

describe('Reward - 时段加权', function () {
  it('sleeping → ×3.0', function () {
    assertEqual(periodWeight('sleeping'), 3.0);
  });

  it('driving → ×2.5', function () {
    assertEqual(periodWeight('driving'), 2.5);
  });

  it('meeting → ×2.0', function () {
    assertEqual(periodWeight('meeting'), 2.0);
  });

  it('idle → ×1.0', function () {
    assertEqual(periodWeight('idle'), 1.0);
  });

  it('未知时段 → ×1.0', function () {
    assertEqual(periodWeight('unknown'), 1.0);
  });
});

describe('Reward - 完整计算', function () {
  it('空闲时点击正确推送 → 正奖励', function () {
    const r = computeReward('click', 0, true, true, 'idle');
    // (1.0 + 0 + 0.5) * 1.0 = 1.5
    assertEqual(r, 1.5);
  });

  it('睡觉时误推并被骂 → 很大负奖励', function () {
    const r = computeReward('annoyed', 3, true, false, 'sleeping');
    // (-2.0 + (-0.1*3^1.5) + (-0.3)) * 3.0
    assertLessThan(r, -5);
  });

  it('开会时忽略 → 中等负面', function () {
    const r = computeReward('ignore', 1, true, true, 'meeting');
    // (-0.3 + -0.1 + 0.5) * 2.0 = 0.2
    assertGreaterThan(r, -1);
  });

  it('频繁推送加重惩罚', function () {
    const r1 = computeReward('click', 1, true, true, 'idle');
    const r5 = computeReward('click', 5, true, true, 'idle');
    assertGreaterThan(r1, r5);
  });
});
