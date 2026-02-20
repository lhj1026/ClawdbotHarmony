'use strict';
/**
 * 冷启动渐进场景测试
 * 对应设计文档: §5.4 学习域架构 - 冷启动, §6.7 冷启动策略
 * 覆盖: 4阶段渐进(100%规则→混合→RL主导→稳定) / 不确定时回退
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertGreaterThan, assertLessThan
} = require('../../lib/assert');

// ── JS 镜像：冷启动策略 ──

/**
 * 冷启动阶段
 * | 阶段     | 规则 | RL  | 说明           |
 * | 前2周    | 100% | 0%  | 只收集数据     |
 * | 第2-4周  | 70%  | 30% | 开始参与       |
 * | 第4周+   | 30%  | 70% | 逐步放权       |
 * | 稳定后   | 兜底 | 主导 | RL不确定时用规则 |
 */

const PHASES = [
  { name: 'bootstrap',  maxDays: 14,  ruleWeight: 1.0,  rlWeight: 0.0  },
  { name: 'rampup',     maxDays: 28,  ruleWeight: 0.7,  rlWeight: 0.3  },
  { name: 'transition', maxDays: 56,  ruleWeight: 0.3,  rlWeight: 0.7  },
  { name: 'stable',     maxDays: Infinity, ruleWeight: 0.1, rlWeight: 0.9 },
];

/** 获取当前阶段 */
function getPhase(daysSinceInstall) {
  for (const phase of PHASES) {
    if (daysSinceInstall < phase.maxDays) return phase;
  }
  return PHASES[PHASES.length - 1];
}

/** 混合决策: 根据阶段混合规则结果和RL结果 */
function blendDecision(ruleDecision, rlDecision, phase, rlConfidence) {
  // RL 不确定时回退到规则
  if (rlConfidence < 0.3) {
    return {
      source: 'rule_fallback',
      decision: ruleDecision,
      confidence: ruleDecision.confidence,
      reason: 'rl_uncertain',
    };
  }

  const ruleScore = ruleDecision.confidence * phase.ruleWeight;
  const rlScore = rlDecision.confidence * phase.rlWeight;

  if (ruleScore >= rlScore) {
    return {
      source: 'rule',
      decision: ruleDecision,
      confidence: ruleScore,
      blend: { ruleScore, rlScore },
    };
  }
  return {
    source: 'rl',
    decision: rlDecision,
    confidence: rlScore,
    blend: { ruleScore, rlScore },
  };
}

/** 数据收集器: 前2周只收集不决策 */
class DataCollector {
  constructor() {
    this.events = [];
    this.feedbacks = [];
  }

  recordEvent(event) { this.events.push(event); }
  recordFeedback(fb) { this.feedbacks.push(fb); }

  get eventCount() { return this.events.length; }
  get feedbackCount() { return this.feedbacks.length; }

  /** 是否有足够数据启动RL */
  hasEnoughData(minEvents, minFeedbacks) {
    return this.events.length >= minEvents && this.feedbacks.length >= minFeedbacks;
  }
}

/** 冷启动管理器 */
class ColdStartManager {
  constructor(installDate) {
    this.installDate = installDate;
    this.collector = new DataCollector();
  }

  getDaysSinceInstall(now) {
    return (now - this.installDate) / (24 * 60 * 60 * 1000);
  }

  getCurrentPhase(now) {
    return getPhase(this.getDaysSinceInstall(now));
  }

  /** 决定是否使用RL */
  shouldUseRL(now) {
    const phase = this.getCurrentPhase(now);
    return phase.rlWeight > 0 && this.collector.hasEnoughData(50, 10);
  }
}

// ── 测试 ──

const DAY_MS = 24 * 60 * 60 * 1000;
const INSTALL = 0;

describe('ColdStart - 阶段识别', function () {
  it('第0天 → bootstrap', function () {
    const phase = getPhase(0);
    assertEqual(phase.name, 'bootstrap');
    assertEqual(phase.ruleWeight, 1.0);
    assertEqual(phase.rlWeight, 0.0);
  });

  it('第7天 → bootstrap (前2周)', function () {
    assertEqual(getPhase(7).name, 'bootstrap');
  });

  it('第13天 → 仍是bootstrap', function () {
    assertEqual(getPhase(13).name, 'bootstrap');
  });

  it('第14天 → rampup (第2-4周)', function () {
    const phase = getPhase(14);
    assertEqual(phase.name, 'rampup');
    assertEqual(phase.ruleWeight, 0.7);
    assertEqual(phase.rlWeight, 0.3);
  });

  it('第21天 → rampup', function () {
    assertEqual(getPhase(21).name, 'rampup');
  });

  it('第28天 → transition (第4-8周)', function () {
    const phase = getPhase(28);
    assertEqual(phase.name, 'transition');
    assertEqual(phase.ruleWeight, 0.3);
    assertEqual(phase.rlWeight, 0.7);
  });

  it('第56天 → stable', function () {
    const phase = getPhase(56);
    assertEqual(phase.name, 'stable');
    assertEqual(phase.rlWeight, 0.9);
  });

  it('第100天 → stable', function () {
    assertEqual(getPhase(100).name, 'stable');
  });
});

describe('ColdStart - bootstrap阶段 (100%规则)', function () {
  it('规则权重=1.0, RL权重=0.0', function () {
    const phase = getPhase(0);
    assertEqual(phase.ruleWeight, 1.0);
    assertEqual(phase.rlWeight, 0.0);
  });

  it('混合决策 → 永远选规则', function () {
    const phase = getPhase(0);
    const ruleDec = { intent: 'commute', confidence: 0.8 };
    const rlDec = { intent: 'lunch', confidence: 0.9 };
    const r = blendDecision(ruleDec, rlDec, phase, 0.9);
    // ruleScore = 0.8*1.0 = 0.8, rlScore = 0.9*0.0 = 0.0
    assertEqual(r.source, 'rule');
    assertEqual(r.decision.intent, 'commute');
  });

  it('不使用RL', function () {
    const mgr = new ColdStartManager(INSTALL);
    assertEqual(mgr.shouldUseRL(DAY_MS), false);
  });
});

describe('ColdStart - rampup阶段 (70%规则 30%RL)', function () {
  it('规则置信度高 → 选规则', function () {
    const phase = getPhase(20);
    const ruleDec = { intent: 'commute', confidence: 0.9 };
    const rlDec = { intent: 'lunch', confidence: 0.6 };
    const r = blendDecision(ruleDec, rlDec, phase, 0.8);
    // ruleScore = 0.9*0.7 = 0.63, rlScore = 0.6*0.3 = 0.18
    assertEqual(r.source, 'rule');
  });

  it('RL置信度极高 → 仍可能选规则（RL权重低）', function () {
    const phase = getPhase(20);
    const ruleDec = { intent: 'commute', confidence: 0.8 };
    const rlDec = { intent: 'lunch', confidence: 1.0 };
    const r = blendDecision(ruleDec, rlDec, phase, 0.8);
    // ruleScore = 0.8*0.7 = 0.56, rlScore = 1.0*0.3 = 0.30
    assertEqual(r.source, 'rule');
  });
});

describe('ColdStart - transition阶段 (30%规则 70%RL)', function () {
  it('RL置信度高 → 选RL', function () {
    const phase = getPhase(35);
    const ruleDec = { intent: 'commute', confidence: 0.8 };
    const rlDec = { intent: 'lunch', confidence: 0.9 };
    const r = blendDecision(ruleDec, rlDec, phase, 0.9);
    // ruleScore = 0.8*0.3 = 0.24, rlScore = 0.9*0.7 = 0.63
    assertEqual(r.source, 'rl');
    assertEqual(r.decision.intent, 'lunch');
  });

  it('规则仍有影响力（置信度极高时）', function () {
    const phase = getPhase(35);
    const ruleDec = { intent: 'commute', confidence: 1.0 };
    const rlDec = { intent: 'lunch', confidence: 0.4 };
    const r = blendDecision(ruleDec, rlDec, phase, 0.5);
    // ruleScore = 1.0*0.3 = 0.30, rlScore = 0.4*0.7 = 0.28
    assertEqual(r.source, 'rule');
  });
});

describe('ColdStart - stable阶段 (RL主导)', function () {
  it('RL主导决策', function () {
    const phase = getPhase(100);
    const ruleDec = { intent: 'commute', confidence: 0.8 };
    const rlDec = { intent: 'optimal', confidence: 0.7 };
    const r = blendDecision(ruleDec, rlDec, phase, 0.7);
    // ruleScore = 0.8*0.1 = 0.08, rlScore = 0.7*0.9 = 0.63
    assertEqual(r.source, 'rl');
  });
});

describe('ColdStart - RL不确定时回退规则', function () {
  it('RL confidence<0.3 → 回退到规则', function () {
    const phase = getPhase(100); // stable阶段
    const ruleDec = { intent: 'commute', confidence: 0.8 };
    const rlDec = { intent: 'risky', confidence: 0.9 };
    const r = blendDecision(ruleDec, rlDec, phase, 0.2); // RL不确定
    assertEqual(r.source, 'rule_fallback');
    assertEqual(r.decision.intent, 'commute');
    assertEqual(r.reason, 'rl_uncertain');
  });

  it('RL confidence=0 → 完全依赖规则', function () {
    const phase = getPhase(50);
    const ruleDec = { intent: 'safe', confidence: 0.6 };
    const rlDec = { intent: 'unknown', confidence: 0.1 };
    const r = blendDecision(ruleDec, rlDec, phase, 0.0);
    assertEqual(r.source, 'rule_fallback');
  });

  it('RL confidence=0.3 → 正常混合（不回退）', function () {
    const phase = getPhase(50);
    const ruleDec = { intent: 'a', confidence: 0.5 };
    const rlDec = { intent: 'b', confidence: 0.8 };
    const r = blendDecision(ruleDec, rlDec, phase, 0.3);
    assertTrue(r.source === 'rule' || r.source === 'rl');
  });
});

describe('ColdStart - 数据收集', function () {
  it('记录事件计数', function () {
    const collector = new DataCollector();
    collector.recordEvent({ type: 'location' });
    collector.recordEvent({ type: 'motion' });
    assertEqual(collector.eventCount, 2);
  });

  it('记录反馈计数', function () {
    const collector = new DataCollector();
    collector.recordFeedback({ ruleId: 'r1', reward: 1.0 });
    assertEqual(collector.feedbackCount, 1);
  });

  it('数据不足 → 不启动RL', function () {
    const collector = new DataCollector();
    for (let i = 0; i < 10; i++) collector.recordEvent({ type: 'x' });
    assertEqual(collector.hasEnoughData(50, 10), false);
  });

  it('数据充足 → 可启动RL', function () {
    const collector = new DataCollector();
    for (let i = 0; i < 50; i++) collector.recordEvent({ type: 'x' });
    for (let i = 0; i < 10; i++) collector.recordFeedback({ reward: 1.0 });
    assertTrue(collector.hasEnoughData(50, 10));
  });
});

describe('ColdStart - ColdStartManager', function () {
  it('安装后第1天 → bootstrap', function () {
    const mgr = new ColdStartManager(INSTALL);
    assertEqual(mgr.getCurrentPhase(DAY_MS).name, 'bootstrap');
  });

  it('安装后第20天 → rampup', function () {
    const mgr = new ColdStartManager(INSTALL);
    assertEqual(mgr.getCurrentPhase(20 * DAY_MS).name, 'rampup');
  });

  it('bootstrap阶段 → shouldUseRL=false', function () {
    const mgr = new ColdStartManager(INSTALL);
    assertEqual(mgr.shouldUseRL(DAY_MS), false);
  });

  it('rampup阶段+数据充足 → shouldUseRL=true', function () {
    const mgr = new ColdStartManager(INSTALL);
    for (let i = 0; i < 50; i++) mgr.collector.recordEvent({ type: 'x' });
    for (let i = 0; i < 10; i++) mgr.collector.recordFeedback({ reward: 1 });
    assertTrue(mgr.shouldUseRL(20 * DAY_MS));
  });

  it('rampup阶段+数据不足 → shouldUseRL=false', function () {
    const mgr = new ColdStartManager(INSTALL);
    assertEqual(mgr.shouldUseRL(20 * DAY_MS), false);
  });
});
