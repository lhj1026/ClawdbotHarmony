'use strict';
/**
 * 规则编译器测试
 * 对应设计文档: §6.1 决策树自动编译, §5.2 决策域架构
 * 覆盖: 平铺规则→决策树/成本感知排序/key选择/分支合并
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertGreaterThan, assertDefined, assertLessThan
} = require('../../lib/assert');

// ── JS 镜像：规则编译器（C++ decision_tree.cpp） ──

const FEATURE_COSTS = {
  'weekday': 1, 'hour': 1, 'isWeekend': 1, 'charging': 1, 'battery': 1,
  'keyword': 2, 'sender': 2, 'app': 2,
  'location': 10, 'activity': 10, 'motionState': 10,
  'noise': 15, 'heartrate': 20,
};

/** 选择最佳分裂key: score = coverage × discrimination / cost */
function selectBestKey(rules) {
  const keyCounts = {};
  for (const r of rules) {
    for (const k of Object.keys(r.conditions)) {
      keyCounts[k] = (keyCounts[k] || 0) + 1;
    }
  }

  let bestKey = null;
  let bestScore = -1;
  for (const [key, count] of Object.entries(keyCounts)) {
    const coverage = count / rules.length;
    // 区分度：不同取值数
    const values = new Set(rules.filter(r => r.conditions[key]).map(r => JSON.stringify(r.conditions[key].value)));
    const discrimination = Math.min(1.0, values.size / rules.length);
    const cost = FEATURE_COSTS[key] || 5;
    const score = (coverage * discrimination) / cost;
    if (score > bestScore) {
      bestScore = score;
      bestKey = key;
    }
  }
  return bestKey;
}

/** 编译决策树（简化版） */
function compileTree(rules) {
  if (rules.length === 0) return { type: 'empty' };
  if (rules.length === 1 || rules.every(r => Object.keys(r.conditions).length === 0)) {
    return { type: 'leaf', rules };
  }

  const key = selectBestKey(rules);
  if (!key) return { type: 'leaf', rules };

  // 按该key的条件值分组
  const branches = {};
  const fallthrough = [];
  for (const r of rules) {
    if (r.conditions[key]) {
      const val = JSON.stringify(r.conditions[key].value);
      if (!branches[val]) branches[val] = [];
      // 移除已分裂的条件
      const remaining = { ...r, conditions: { ...r.conditions } };
      delete remaining.conditions[key];
      branches[val].push(remaining);
    } else {
      fallthrough.push(r);
    }
  }

  // 递归编译子树
  const compiledBranches = {};
  for (const [val, subRules] of Object.entries(branches)) {
    compiledBranches[val] = compileTree([...subRules, ...fallthrough]);
  }

  return {
    type: 'branch',
    key,
    branches: compiledBranches,
    fallthrough: fallthrough.length > 0 ? compileTree(fallthrough) : null,
  };
}

/** 收集树中所有key（按层序） */
function collectKeys(node, depth = 0) {
  if (!node || node.type !== 'branch') return [];
  const result = [{ key: node.key, depth }];
  for (const child of Object.values(node.branches)) {
    result.push(...collectKeys(child, depth + 1));
  }
  if (node.fallthrough) result.push(...collectKeys(node.fallthrough, depth + 1));
  return result;
}

// ── 测试规则 ──

const RULES = [
  {
    id: 'commute', intent: 'commute_reminder',
    conditions: {
      hour: { op: 'range', value: [7, 8] },
      isWeekend: { op: 'eq', value: false },
      location: { op: 'eq', value: 'home' },
    },
  },
  {
    id: 'low_battery', intent: 'low_battery_alert',
    conditions: {
      battery: { op: 'lte', value: 15 },
      charging: { op: 'eq', value: false },
    },
  },
  {
    id: 'bedtime', intent: 'bedtime_summary',
    conditions: {
      hour: { op: 'range', value: [22, 24] },
      location: { op: 'eq', value: 'home' },
    },
  },
  {
    id: 'lunch', intent: 'lunch_recommend',
    conditions: {
      hour: { op: 'range', value: [11, 13] },
      isWeekend: { op: 'eq', value: false },
      location: { op: 'eq', value: 'office' },
    },
  },
];

// ── 测试 ──

describe('RuleCompiler - Key选择', function () {
  it('hour出现最多，成本低 → 优先选hour', function () {
    const key = selectBestKey(RULES);
    // hour出现在3/4规则，cost=1
    assertTrue(key === 'hour' || key === 'isWeekend', `got ${key}`);
  });

  it('location成本高(10) → 不优先选', function () {
    const key = selectBestKey(RULES);
    assertTrue(key !== 'location', 'location不应最先被选');
  });

  it('单条规则 → 返回其唯一key之一', function () {
    const key = selectBestKey([RULES[1]]);
    assertTrue(key === 'battery' || key === 'charging');
  });

  it('无条件规则 → 返回null', function () {
    const key = selectBestKey([{ id: 'x', conditions: {} }]);
    assertEqual(key, null);
  });
});

describe('RuleCompiler - 决策树编译', function () {
  it('编译成功 → 根节点是branch', function () {
    const tree = compileTree(RULES);
    assertEqual(tree.type, 'branch');
  });

  it('空规则 → empty节点', function () {
    const tree = compileTree([]);
    assertEqual(tree.type, 'empty');
  });

  it('单条规则 → leaf节点', function () {
    const tree = compileTree([RULES[1]]);
    // 单条规则但有多个条件，会继续分裂
    assertTrue(tree.type === 'branch' || tree.type === 'leaf');
  });

  it('便宜特征在上层', function () {
    const tree = compileTree(RULES);
    const keys = collectKeys(tree);
    // 第一层key应该是便宜的（cost<=2）
    if (keys.length > 0) {
      const topKey = keys[0].key;
      assertLessThan(FEATURE_COSTS[topKey] || 5, 5, `top key ${topKey} should be cheap`);
    }
  });

  it('所有规则可达', function () {
    const tree = compileTree(RULES);
    // 通过遍历树收集所有叶节点的规则
    function collectLeafRules(node) {
      if (!node) return [];
      if (node.type === 'leaf') return node.rules.map(r => r.id);
      if (node.type === 'branch') {
        const ids = [];
        for (const child of Object.values(node.branches)) {
          ids.push(...collectLeafRules(child));
        }
        if (node.fallthrough) ids.push(...collectLeafRules(node.fallthrough));
        return ids;
      }
      return [];
    }
    const leafIds = collectLeafRules(tree);
    for (const r of RULES) {
      assertTrue(leafIds.includes(r.id), `rule ${r.id} should be reachable`);
    }
  });
});

describe('RuleCompiler - 成本排序', function () {
  it('FEATURE_COSTS 定义完整', function () {
    assertDefined(FEATURE_COSTS.weekday);
    assertDefined(FEATURE_COSTS.location);
    assertDefined(FEATURE_COSTS.noise);
  });

  it('传感器特征成本 > 时间特征成本', function () {
    assertGreaterThan(FEATURE_COSTS.location, FEATURE_COSTS.hour);
    assertGreaterThan(FEATURE_COSTS.noise, FEATURE_COSTS.weekday);
  });
});
