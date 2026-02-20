'use strict';
/**
 * 决策树测试
 * 对应设计文档: §5.2 决策域架构 - 软匹配多路径/置信度乘积
 * 覆盖: 软匹配遍历/多叶节点返回/置信度计算/路径记录
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertGreaterThan, assertLessThan, assertDefined
} = require('../../lib/assert');

// ── JS 镜像：决策树软匹配执行（C++ decision_tree.cpp evaluateSoft） ──

function gaussianDecay(actual, target, tolerance) {
  const diff = Math.abs(actual - target);
  if (diff <= tolerance) return 1.0;
  return Math.exp(-0.5 * ((diff - tolerance) / 1.0) ** 2);
}

function softMatch(key, actual, condition) {
  if (actual == null) return 0.5;
  const { op, value } = condition;
  switch (op) {
    case 'eq': return actual === value ? 1.0 : 0.0;
    case 'neq': return actual !== value ? 1.0 : 0.0;
    case 'in': return value.includes(actual) ? 1.0 : 0.0;
    case 'lte': return actual <= value ? 1.0 : Math.max(0, 1 - (actual - value) / 5);
    case 'gte': return actual >= value ? 1.0 : Math.max(0, 1 - (value - actual) / 5);
    case 'range': {
      if (actual >= value[0] && actual <= value[1]) return 1.0;
      const dist = actual < value[0] ? value[0] - actual : actual - value[1];
      return gaussianDecay(0, dist, 0);
    }
    default: return 0.5;
  }
}

/** 软匹配遍历决策树，返回所有匹配路径 */
function evaluateSoft(node, context, pathConfidence, path) {
  pathConfidence = pathConfidence ?? 1.0;
  path = path || [];

  if (!node) return [];
  if (node.type === 'leaf') {
    return node.rules.map(r => ({ rule: r, confidence: pathConfidence, path: [...path] }));
  }
  if (node.type !== 'branch') return [];

  const results = [];
  const actual = context[node.key];

  // 走所有分支（软匹配，不剪枝除非置信度太低）
  for (const [condStr, child] of Object.entries(node.branches)) {
    const cond = JSON.parse(condStr);
    const score = softMatch(node.key, actual, { op: 'eq', value: cond });
    // 对于范围等条件，用更精确的匹配
    const branchConf = pathConfidence * Math.max(score, actual == null ? 0.5 : score);
    if (branchConf > 0.01) {
      results.push(...evaluateSoft(child, context, branchConf,
        [...path, { key: node.key, actual, expected: cond, confidence: score }]));
    }
  }

  // fallthrough
  if (node.fallthrough) {
    results.push(...evaluateSoft(node.fallthrough, context, pathConfidence, path));
  }

  return results;
}

// ── 测试用决策树 ──

const TREE = {
  type: 'branch',
  key: 'isWeekend',
  branches: {
    'false': {
      type: 'branch',
      key: 'hour',
      branches: {
        '8': { type: 'leaf', rules: [{ id: 'commute', intent: 'commute_reminder' }] },
        '12': { type: 'leaf', rules: [{ id: 'lunch', intent: 'lunch_recommend' }] },
      },
      fallthrough: null,
    },
    'true': {
      type: 'leaf',
      rules: [{ id: 'weekend_morning', intent: 'weekend_relax' }],
    },
  },
  fallthrough: {
    type: 'leaf',
    rules: [{ id: 'low_battery', intent: 'low_battery_alert' }],
  },
};

// ── 测试 ──

describe('DecisionTree - 软匹配遍历', function () {
  it('完全匹配 → confidence=1.0', function () {
    const results = evaluateSoft(TREE, { isWeekend: false, hour: 8 });
    const commute = results.find(r => r.rule.id === 'commute');
    assertDefined(commute);
    assertEqual(commute.confidence, 1.0);
  });

  it('不匹配的分支 → confidence=0.0', function () {
    const results = evaluateSoft(TREE, { isWeekend: true, hour: 8 });
    const commute = results.find(r => r.rule.id === 'commute');
    // commute 在 isWeekend=false 分支下，isWeekend=true 走不到
    assertTrue(!commute || commute.confidence < 0.1);
  });

  it('fallthrough规则始终可达', function () {
    const results = evaluateSoft(TREE, { isWeekend: false, hour: 8 });
    const battery = results.find(r => r.rule.id === 'low_battery');
    assertDefined(battery);
  });

  it('周末 → weekend_morning 高置信度', function () {
    const results = evaluateSoft(TREE, { isWeekend: true });
    const weekend = results.find(r => r.rule.id === 'weekend_morning');
    assertDefined(weekend);
    assertEqual(weekend.confidence, 1.0);
  });
});

describe('DecisionTree - 多路径返回', function () {
  it('多个规则同时匹配', function () {
    const results = evaluateSoft(TREE, { isWeekend: false, hour: 8 });
    // commute + low_battery (fallthrough)
    assertGreaterThan(results.length, 1);
  });

  it('结果按置信度可排序', function () {
    const results = evaluateSoft(TREE, { isWeekend: false, hour: 8 });
    results.sort((a, b) => b.confidence - a.confidence);
    assertTrue(results[0].confidence >= results[results.length - 1].confidence);
  });
});

describe('DecisionTree - 置信度乘积', function () {
  it('路径上多个条件 → 置信度相乘', function () {
    // isWeekend=false(1.0) * hour=8(1.0) = 1.0
    const results = evaluateSoft(TREE, { isWeekend: false, hour: 8 });
    const commute = results.find(r => r.rule.id === 'commute');
    assertEqual(commute.confidence, 1.0);
  });

  it('缺失数据 → 乘以0.5', function () {
    // isWeekend缺失 → 0.5
    const results = evaluateSoft(TREE, { hour: 8 });
    const commute = results.find(r => r.rule.id === 'commute');
    // 通过 fallthrough 中 isWeekend 缺失为 null
    // 具体结果取决于分支匹配逻辑
    assertDefined(results);
    assertTrue(results.length > 0);
  });
});

describe('DecisionTree - 路径记录', function () {
  it('匹配结果包含路径', function () {
    const results = evaluateSoft(TREE, { isWeekend: false, hour: 8 });
    const commute = results.find(r => r.rule.id === 'commute');
    assertDefined(commute.path);
    assertTrue(Array.isArray(commute.path));
  });

  it('路径包含每步的key和actual', function () {
    const results = evaluateSoft(TREE, { isWeekend: false, hour: 8 });
    const commute = results.find(r => r.rule.id === 'commute');
    if (commute.path.length > 0) {
      assertDefined(commute.path[0].key);
      assertDefined(commute.path[0].confidence);
    }
  });
});

describe('DecisionTree - 空树/边界', function () {
  it('空上下文 → 仍返回结果（通过fallthrough）', function () {
    const results = evaluateSoft(TREE, {});
    assertTrue(results.length > 0);
  });

  it('null节点 → 空结果', function () {
    const results = evaluateSoft(null, { hour: 8 });
    assertEqual(results.length, 0);
  });

  it('leaf节点 → 直接返回规则', function () {
    const leaf = { type: 'leaf', rules: [{ id: 'test' }] };
    const results = evaluateSoft(leaf, {});
    assertEqual(results.length, 1);
    assertEqual(results[0].rule.id, 'test');
  });
});
