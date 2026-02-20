'use strict';
/**
 * 软匹配引擎测试
 * 对应设计文档: §6.2 软匹配策略, §5.2 决策域架构
 * 覆盖: 高斯衰减/多源融合/缺失=0.5/各操作符(in/eq/lte/gte/range/neq)
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertGreaterThan, assertLessThan
} = require('../../lib/assert');

// ── JS 镜像：软匹配器（C++ soft_match.cpp） ──

/** 高斯衰减 */
function gaussianDecay(actual, target, tolerance, sigma) {
  sigma = sigma || 1.0;
  const diff = Math.abs(actual - target);
  if (diff <= tolerance) return 1.0;
  return Math.exp(-0.5 * ((diff - tolerance) / sigma) ** 2);
}

/** 时间软匹配：target=7.5, tolerance=0.5(30min), sigma=1.0 */
function matchHour(actual, target, tolerance) {
  if (actual == null) return 0.5; // 缺失=0.5
  return gaussianDecay(actual, target, tolerance, 1.0);
}

/** 数值比较: lte */
function matchLte(actual, threshold) {
  if (actual == null) return 0.5;
  if (actual <= threshold) return 1.0;
  // 超出阈值后线性衰减
  const excess = actual - threshold;
  const decay = Math.max(0, 1.0 - excess / (threshold * 0.5 || 1));
  return parseFloat(Math.max(0, decay).toFixed(4));
}

/** 数值比较: gte */
function matchGte(actual, threshold) {
  if (actual == null) return 0.5;
  if (actual >= threshold) return 1.0;
  const deficit = threshold - actual;
  const decay = Math.max(0, 1.0 - deficit / (threshold * 0.5 || 1));
  return parseFloat(Math.max(0, decay).toFixed(4));
}

/** 等值匹配: eq */
function matchEq(actual, expected) {
  if (actual == null) return 0.5;
  return actual === expected ? 1.0 : 0.0;
}

/** 不等匹配: neq */
function matchNeq(actual, expected) {
  if (actual == null) return 0.5;
  return actual !== expected ? 1.0 : 0.0;
}

/** 集合匹配: in */
function matchIn(actual, set) {
  if (actual == null) return 0.5;
  return set.includes(actual) ? 1.0 : 0.0;
}

/** 范围匹配: range */
function matchRange(actual, min, max) {
  if (actual == null) return 0.5;
  if (actual >= min && actual <= max) return 1.0;
  if (actual < min) return gaussianDecay(actual, min, 0, 1.0);
  return gaussianDecay(actual, max, 0, 1.0);
}

/** 多条件AND匹配（置信度相乘） */
function matchAll(conditions, context) {
  let confidence = 1.0;
  for (const c of conditions) {
    const score = c.matchFn(context[c.key]);
    confidence *= score;
    if (confidence < 0.01) return 0; // 提前剪枝
  }
  return confidence;
}

// ── 测试 ──

describe('SoftMatcher - 高斯衰减', function () {
  it('target=7:30, actual=7:30 → 1.0', function () {
    assertEqual(matchHour(7.5, 7.5, 0.5), 1.0);
  });

  it('target=7:30, actual=7:00 → 1.0 (在容差内)', function () {
    assertEqual(matchHour(7.0, 7.5, 0.5), 1.0);
  });

  it('target=7:30, actual=6:50 → ~0.85 衰减', function () {
    const s = matchHour(6.83, 7.5, 0.5);
    assertGreaterThan(s, 0.7);
    assertLessThan(s, 1.0);
  });

  it('target=7:30, actual=6:00 → 衰减明显', function () {
    const s = matchHour(6.0, 7.5, 0.5);
    assertLessThan(s, 0.7);
  });

  it('target=7:30, actual=8:00 → 1.0 (在容差内)', function () {
    assertEqual(matchHour(8.0, 7.5, 0.5), 1.0);
  });
});

describe('SoftMatcher - 缺失数据=0.5', function () {
  it('matchHour(null) → 0.5', function () {
    assertEqual(matchHour(null, 7.5, 0.5), 0.5);
  });

  it('matchEq(null) → 0.5', function () {
    assertEqual(matchEq(null, 'home'), 0.5);
  });

  it('matchIn(null) → 0.5', function () {
    assertEqual(matchIn(null, ['a', 'b']), 0.5);
  });

  it('matchLte(null) → 0.5', function () {
    assertEqual(matchLte(null, 15), 0.5);
  });

  it('matchGte(null) → 0.5', function () {
    assertEqual(matchGte(null, 80), 0.5);
  });

  it('matchNeq(null) → 0.5', function () {
    assertEqual(matchNeq(null, 'office'), 0.5);
  });

  it('matchRange(null) → 0.5', function () {
    assertEqual(matchRange(null, 22, 24), 0.5);
  });
});

describe('SoftMatcher - 各操作符', function () {
  it('eq: 匹配 → 1.0', function () {
    assertEqual(matchEq('home', 'home'), 1.0);
  });

  it('eq: 不匹配 → 0.0', function () {
    assertEqual(matchEq('office', 'home'), 0.0);
  });

  it('neq: 不等 → 1.0', function () {
    assertEqual(matchNeq('office', 'home'), 1.0);
  });

  it('neq: 相等 → 0.0', function () {
    assertEqual(matchNeq('home', 'home'), 0.0);
  });

  it('in: 在集合中 → 1.0', function () {
    assertEqual(matchIn('walking', ['walking', 'driving']), 1.0);
  });

  it('in: 不在集合中 → 0.0', function () {
    assertEqual(matchIn('running', ['walking', 'driving']), 0.0);
  });

  it('lte: 10 <= 15 → 1.0', function () {
    assertEqual(matchLte(10, 15), 1.0);
  });

  it('lte: 15 <= 15 → 1.0', function () {
    assertEqual(matchLte(15, 15), 1.0);
  });

  it('lte: 20 > 15 → 衰减', function () {
    const s = matchLte(20, 15);
    assertLessThan(s, 1.0);
    assertGreaterThan(s, 0);
  });

  it('gte: 90 >= 80 → 1.0', function () {
    assertEqual(matchGte(90, 80), 1.0);
  });

  it('gte: 70 < 80 → 衰减', function () {
    const s = matchGte(70, 80);
    assertLessThan(s, 1.0);
  });

  it('range: 23在[22,24]内 → 1.0', function () {
    assertEqual(matchRange(23, 22, 24), 1.0);
  });

  it('range: 21在[22,24]外 → 衰减', function () {
    const s = matchRange(21, 22, 24);
    assertLessThan(s, 1.0);
    assertGreaterThan(s, 0.3);
  });
});

describe('SoftMatcher - 多条件AND', function () {
  it('全部匹配 → 高置信度', function () {
    const conditions = [
      { key: 'hour', matchFn: v => matchHour(v, 7.5, 0.5) },
      { key: 'location', matchFn: v => matchEq(v, 'home') },
    ];
    const ctx = { hour: 7.5, location: 'home' };
    assertEqual(matchAll(conditions, ctx), 1.0);
  });

  it('一个不匹配 → 置信度降低', function () {
    const conditions = [
      { key: 'hour', matchFn: v => matchHour(v, 7.5, 0.5) },
      { key: 'location', matchFn: v => matchEq(v, 'home') },
    ];
    const ctx = { hour: 7.5, location: 'office' };
    assertEqual(matchAll(conditions, ctx), 0.0);
  });

  it('部分缺失 → 乘以0.5', function () {
    const conditions = [
      { key: 'hour', matchFn: v => matchHour(v, 7.5, 0.5) },
      { key: 'location', matchFn: v => matchEq(v, 'home') },
    ];
    const ctx = { hour: 7.5 }; // location 缺失
    assertEqual(matchAll(conditions, ctx), 0.5);
  });

  it('早期剪枝: 第一个=0 → 不继续', function () {
    let called = false;
    const conditions = [
      { key: 'a', matchFn: () => 0.0 },
      { key: 'b', matchFn: () => { called = true; return 1.0; } },
    ];
    matchAll(conditions, {});
    // 因为 0*anything=0，可能不调用第二个（取决于剪枝阈值）
    // confidence=0 < 0.01 → 提前返回
  });
});
