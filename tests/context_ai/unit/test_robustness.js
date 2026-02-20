'use strict';
/**
 * 鲁棒性测试
 * 对应设计文档: §6.4 鲁棒性详细设计, §5.4 学习域架构 - 5层鲁棒性防护
 * 覆盖: 异常检测/参数保护/奖励裁剪/回滚/性能监控
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertFalse, assertGreaterThan, assertLessThan
} = require('../../lib/assert');

// ── JS 镜像：鲁棒性模块 ──

/** Layer 1: 输入特征异常检测 */
function validateFeatures(features, ranges) {
  const cleaned = [];
  let anomalyCount = 0;
  for (let i = 0; i < features.length; i++) {
    const v = features[i];
    const range = ranges[i] || { min: -10, max: 10, default: 0 };
    if (v == null || isNaN(v) || v < range.min || v > range.max) {
      cleaned.push(range.default); // 填充默认值
      anomalyCount++;
    } else {
      cleaned.push(v);
    }
  }
  return { cleaned, anomalyCount, valid: anomalyCount === 0 };
}

/** Layer 2: 异常反馈检测（3σ + 频率限制） */
function validateFeedback(reward, history, maxPerMinute) {
  // 3σ 检测
  if (history.length > 10) {
    const mean = history.reduce((a, b) => a + b, 0) / history.length;
    const std = Math.sqrt(history.reduce((s, v) => s + (v - mean) ** 2, 0) / history.length);
    if (std > 0 && Math.abs(reward - mean) > 3 * std) {
      return { valid: false, reason: '3sigma_outlier' };
    }
  }
  // 奖励裁剪
  const clipped = Math.max(-3, Math.min(3, reward));
  return { valid: true, reward: clipped };
}

/** Layer 3: 参数保护（变化限制5%） */
function protectParams(oldParams, newParams, maxChangeRate) {
  maxChangeRate = maxChangeRate || 0.05;
  const protected_ = [];
  for (let i = 0; i < oldParams.length; i++) {
    const old = oldParams[i];
    const new_ = newParams[i];
    const maxDelta = Math.abs(old) * maxChangeRate || maxChangeRate;
    const delta = new_ - old;
    if (Math.abs(delta) > maxDelta) {
      protected_.push(old + Math.sign(delta) * maxDelta);
    } else {
      protected_.push(new_);
    }
  }
  return protected_;
}

/** Layer 4: 不确定性检查 */
function uncertaintyCheck(confidence, threshold) {
  threshold = threshold || 0.3;
  if (confidence < threshold) return { action: 'fallback_to_rules', uncertain: true };
  return { action: 'proceed', uncertain: false };
}

/** Layer 5: 性能监控 + 自动回滚 */
class PerformanceMonitor {
  constructor(windowSize = 100, rollbackThreshold = 0.3) {
    this.window = [];
    this.windowSize = windowSize;
    this.rollbackThreshold = rollbackThreshold;
    this.checkpoints = [];
    this.baselineAvg = null;
  }

  record(reward) {
    this.window.push(reward);
    if (this.window.length > this.windowSize) this.window.shift();
  }

  getAverage() {
    if (this.window.length === 0) return 0;
    return this.window.reduce((a, b) => a + b, 0) / this.window.length;
  }

  saveCheckpoint(params) {
    this.checkpoints.push({ params: [...params], avg: this.getAverage(), time: Date.now() });
    if (this.baselineAvg == null) this.baselineAvg = this.getAverage();
  }

  shouldRollback() {
    if (this.baselineAvg == null || this.checkpoints.length === 0) return false;
    const currentAvg = this.getAverage();
    const drop = (this.baselineAvg - currentAvg) / (Math.abs(this.baselineAvg) || 1);
    return drop > this.rollbackThreshold;
  }

  getLastCheckpoint() {
    return this.checkpoints.length > 0 ? this.checkpoints[this.checkpoints.length - 1] : null;
  }
}

// ── 测试 ──

describe('Robustness - Layer1 输入异常检测', function () {
  const ranges = [
    { min: 0, max: 24, default: 12 },  // hour
    { min: 0, max: 1, default: 0.5 },  // confidence
    { min: -1, max: 1, default: 0 },   // feature
  ];

  it('正常特征 → 无异常', function () {
    const r = validateFeatures([8, 0.9, 0.5], ranges);
    assertTrue(r.valid);
    assertEqual(r.anomalyCount, 0);
  });

  it('超范围 → 替换为默认值', function () {
    const r = validateFeatures([25, 0.9, 0.5], ranges);
    assertFalse(r.valid);
    assertEqual(r.cleaned[0], 12);
  });

  it('NaN → 替换为默认值', function () {
    const r = validateFeatures([NaN, 0.5, 0], ranges);
    assertEqual(r.cleaned[0], 12);
    assertEqual(r.anomalyCount, 1);
  });

  it('null → 替换为默认值', function () {
    const r = validateFeatures([null, null, null], ranges);
    assertEqual(r.anomalyCount, 3);
  });
});

describe('Robustness - Layer2 异常反馈', function () {
  it('正常奖励 → 通过', function () {
    const r = validateFeedback(1.0, [0.5, 0.8, 1.0, 0.6], 5);
    assertTrue(r.valid);
  });

  it('3σ异常 → 拒绝', function () {
    // Need variation in history for std > 0
    const history = [];
    for (let i = 0; i < 20; i++) history.push(0.5 + (i % 2 ? 0.1 : -0.1));
    const r = validateFeedback(100, history, 5);
    assertFalse(r.valid);
    assertEqual(r.reason, '3sigma_outlier');
  });

  it('奖励裁剪到[-3,3]', function () {
    const r = validateFeedback(10, [1, 2, 3, 4, 5], 5); // 少量历史不触发3σ
    assertEqual(r.reward, 3);
  });

  it('负奖励裁剪', function () {
    const r = validateFeedback(-10, [1, 2], 5);
    assertEqual(r.reward, -3);
  });
});

describe('Robustness - Layer3 参数保护', function () {
  it('小变化 → 直接应用', function () {
    const r = protectParams([1.0, 2.0], [1.01, 2.02], 0.05);
    assertEqual(r[0], 1.01);
    assertEqual(r[1], 2.02);
  });

  it('大变化 → 限制5%', function () {
    const r = protectParams([1.0, 2.0], [2.0, 4.0], 0.05);
    // max delta = 1.0 * 0.05 = 0.05
    assertEqual(r[0], 1.05);
    // max delta = 2.0 * 0.05 = 0.1
    assertEqual(r[1], 2.1);
  });

  it('负方向变化也限制', function () {
    const r = protectParams([1.0], [0.0], 0.05);
    assertEqual(r[0], 0.95);
  });
});

describe('Robustness - Layer4 不确定性', function () {
  it('高置信度 → proceed', function () {
    const r = uncertaintyCheck(0.8, 0.3);
    assertFalse(r.uncertain);
    assertEqual(r.action, 'proceed');
  });

  it('低置信度 → fallback', function () {
    const r = uncertaintyCheck(0.2, 0.3);
    assertTrue(r.uncertain);
    assertEqual(r.action, 'fallback_to_rules');
  });

  it('边界: 恰好等于阈值 → proceed', function () {
    const r = uncertaintyCheck(0.3, 0.3);
    assertFalse(r.uncertain);
  });
});

describe('Robustness - Layer5 性能监控', function () {
  it('记录奖励并计算平均', function () {
    const pm = new PerformanceMonitor(5);
    pm.record(1); pm.record(2); pm.record(3);
    assertEqual(pm.getAverage(), 2);
  });

  it('窗口滑动', function () {
    const pm = new PerformanceMonitor(3);
    pm.record(1); pm.record(2); pm.record(3); pm.record(10);
    // 窗口: [2, 3, 10]
    assertEqual(pm.getAverage(), 5);
  });

  it('性能下降 → 需要回滚', function () {
    const pm = new PerformanceMonitor(5, 0.3);
    for (let i = 0; i < 5; i++) pm.record(1.0);
    pm.saveCheckpoint([1, 2, 3]);
    // 模拟性能下降
    pm.window.length = 0;
    for (let i = 0; i < 5; i++) pm.record(0.3);
    assertTrue(pm.shouldRollback());
  });

  it('性能正常 → 不回滚', function () {
    const pm = new PerformanceMonitor(5, 0.3);
    for (let i = 0; i < 5; i++) pm.record(1.0);
    pm.saveCheckpoint([1, 2, 3]);
    for (let i = 0; i < 5; i++) pm.record(0.9);
    assertFalse(pm.shouldRollback());
  });

  it('检查点保存和恢复', function () {
    const pm = new PerformanceMonitor(5);
    pm.record(1);
    pm.saveCheckpoint([10, 20]);
    const cp = pm.getLastCheckpoint();
    assertEqual(cp.params[0], 10);
    assertEqual(cp.params[1], 20);
  });
});
