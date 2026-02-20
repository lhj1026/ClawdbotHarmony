'use strict';
/**
 * 冷启动测试
 * 对应设计文档: §5.4 学习域架构 - 冷启动, §6.7 冷启动策略
 * 覆盖: 4阶段渐变（纯规则→混合→RL主导→稳定）
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertGreaterThan, assertLessThan
} = require('../../lib/assert');

// ── JS 镜像：冷启动策略 ──

/**
 * 根据使用天数返回规则/RL权重
 * 前2周: 100%规则, 0%RL
 * 第2周: 70%规则, 30%RL
 * 第4周+: 30%规则, 70%RL
 * 稳定后: 10%规则(兜底), 90%RL
 */
function getColdStartWeights(daysSinceInstall, rlConfidence) {
  let ruleWeight, rlWeight;

  if (daysSinceInstall < 14) {
    // 阶段1：纯规则
    ruleWeight = 1.0;
    rlWeight = 0.0;
  } else if (daysSinceInstall < 21) {
    // 阶段2：开始混入RL
    const progress = (daysSinceInstall - 14) / 7; // 0~1
    ruleWeight = 1.0 - 0.3 * progress;
    rlWeight = 0.3 * progress;
  } else if (daysSinceInstall < 28) {
    // 阶段3：RL逐步主导
    const progress = (daysSinceInstall - 21) / 7;
    ruleWeight = 0.7 - 0.4 * progress;
    rlWeight = 0.3 + 0.4 * progress;
  } else {
    // 阶段4：稳定
    ruleWeight = 0.1;
    rlWeight = 0.9;
  }

  // RL 不确定时回退规则
  if (rlConfidence < 0.3 && rlWeight > 0) {
    const fallback = rlWeight * 0.5;
    ruleWeight += fallback;
    rlWeight -= fallback;
  }

  return {
    ruleWeight: parseFloat(ruleWeight.toFixed(4)),
    rlWeight: parseFloat(rlWeight.toFixed(4)),
  };
}

/** 混合决策：根据权重组合规则和RL的结果 */
function blendDecision(ruleDecision, rlDecision, weights) {
  if (weights.rlWeight === 0) return ruleDecision;
  if (weights.ruleWeight === 0) return rlDecision;

  // 选择得分更高的
  const ruleScore = (ruleDecision.confidence || 0) * weights.ruleWeight;
  const rlScore = (rlDecision.confidence || 0) * weights.rlWeight;
  return ruleScore >= rlScore ? ruleDecision : rlDecision;
}

// ── 测试 ──

describe('ColdStart - 阶段1：纯规则（前2周）', function () {
  it('第0天 → 100%规则', function () {
    const w = getColdStartWeights(0, 0);
    assertEqual(w.ruleWeight, 1.0);
    assertEqual(w.rlWeight, 0.0);
  });

  it('第7天 → 100%规则', function () {
    const w = getColdStartWeights(7, 0.5);
    assertEqual(w.ruleWeight, 1.0);
    assertEqual(w.rlWeight, 0.0);
  });

  it('第13天 → 仍100%规则', function () {
    const w = getColdStartWeights(13, 0.8);
    assertEqual(w.ruleWeight, 1.0);
    assertEqual(w.rlWeight, 0.0);
  });
});

describe('ColdStart - 阶段2：开始混入RL（第2-3周）', function () {
  it('第14天 → RL开始参与', function () {
    const w = getColdStartWeights(14, 0.5);
    assertEqual(w.ruleWeight, 1.0); // progress=0
    assertEqual(w.rlWeight, 0.0);
  });

  it('第17天（中间） → ~85%规则, ~15%RL', function () {
    const w = getColdStartWeights(17, 0.5);
    assertGreaterThan(w.ruleWeight, 0.8);
    assertGreaterThan(w.rlWeight, 0.1);
  });

  it('第20天 → ~72%规则, ~28%RL', function () {
    const w = getColdStartWeights(20, 0.5);
    assertLessThan(w.ruleWeight, 0.8);
    assertGreaterThan(w.rlWeight, 0.2);
  });
});

describe('ColdStart - 阶段3：RL主导（第3-4周）', function () {
  it('第25天 → RL>50%', function () {
    const w = getColdStartWeights(25, 0.8);
    assertGreaterThan(w.rlWeight, 0.5);
  });
});

describe('ColdStart - 阶段4：稳定（4周后）', function () {
  it('第30天 → 10%规则, 90%RL', function () {
    const w = getColdStartWeights(30, 0.8);
    assertEqual(w.ruleWeight, 0.1);
    assertEqual(w.rlWeight, 0.9);
  });

  it('第100天 → 同样稳定', function () {
    const w = getColdStartWeights(100, 0.9);
    assertEqual(w.ruleWeight, 0.1);
    assertEqual(w.rlWeight, 0.9);
  });
});

describe('ColdStart - RL不确定时回退', function () {
  it('阶段4 + RL低置信度 → 回退到更多规则', function () {
    const w = getColdStartWeights(30, 0.2); // rlConfidence < 0.3
    assertGreaterThan(w.ruleWeight, 0.1);
    assertLessThan(w.rlWeight, 0.9);
  });

  it('阶段1 + RL低置信度 → 无影响（RL权重本来是0）', function () {
    const w = getColdStartWeights(5, 0.1);
    assertEqual(w.ruleWeight, 1.0);
    assertEqual(w.rlWeight, 0.0);
  });
});

describe('ColdStart - 混合决策', function () {
  it('纯规则阶段 → 选规则结果', function () {
    const r = blendDecision(
      { intent: 'rule_result', confidence: 0.8 },
      { intent: 'rl_result', confidence: 0.9 },
      { ruleWeight: 1.0, rlWeight: 0.0 }
    );
    assertEqual(r.intent, 'rule_result');
  });

  it('稳定阶段 + RL高置信 → 选RL结果', function () {
    const r = blendDecision(
      { intent: 'rule_result', confidence: 0.5 },
      { intent: 'rl_result', confidence: 0.9 },
      { ruleWeight: 0.1, rlWeight: 0.9 }
    );
    assertEqual(r.intent, 'rl_result');
  });
});
