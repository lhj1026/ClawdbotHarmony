'use strict';
/**
 * Stream Deep RL 集成场景测试
 * 对应: rule_engine.cpp evaluate() 混合评分, 冷启动策略, 反馈闭环
 *
 * 场景覆盖:
 *   1. 冷启动 → LinUCB/纯规则 → Stream RL 过渡
 *   2. 用户反馈学习：正/负反馈调整排序
 *   3. 多规则竞争：RL 重排序
 *   4. 上下文区分：早晚不同偏好
 *   5. 极端条件：大量规则/极端奖励
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertGreaterThan, assertLessThan, assertDefined
} = require('../../lib/assert');

// ============================================================
// Constants
// ============================================================

const STREAM_FEAT_DIM = 16;
const STREAM_H1 = 64;
const STREAM_H2 = 32;
const STREAM_LR = 0.01;
const STREAM_KAPPA = 2.0;
const STREAM_WEIGHT_DECAY = 1e-4;
const STREAM_LEAKY_ALPHA = 0.01;
const SPARSE_RATIO = 0.9;
const STREAM_MIN_SAMPLES = 5;
const STREAM_RAMP_SAMPLES = 20;

// ============================================================
// Minimal JS mirrors (shared with unit test)
// ============================================================

function mulberry32(seed) {
  let t = seed;
  return function () {
    t += 0x6D2B79F5;
    let a = t;
    a = Math.imul(a ^ (a >>> 15), a | 1);
    a ^= a + Math.imul(a ^ (a >>> 7), a | 61);
    return ((a ^ (a >>> 14)) >>> 0) / 4294967296;
  };
}

class RunningStats {
  constructor(dim) {
    this.dim = dim;
    this.mean = new Float64Array(dim);
    this.m2 = new Float64Array(dim);
    this.count = 0;
  }
  update(x) {
    this.count++;
    for (let i = 0; i < this.dim; i++) {
      const d = x[i] - this.mean[i];
      this.mean[i] += d / this.count;
      this.m2[i] += d * (x[i] - this.mean[i]);
    }
  }
  normalize(x) {
    const out = new Float64Array(this.dim);
    if (this.count < 2) { for (let i = 0; i < this.dim; i++) out[i] = x[i]; return out; }
    for (let i = 0; i < this.dim; i++) {
      out[i] = (x[i] - this.mean[i]) / Math.sqrt(this.m2[i] / this.count + 1e-8);
    }
    return out;
  }
}

function layerNorm(x, dim) {
  let m = 0; for (let i = 0; i < dim; i++) m += x[i]; m /= dim;
  let v = 0; for (let i = 0; i < dim; i++) { const d = x[i] - m; v += d * d; } v /= dim;
  const inv = 1.0 / Math.sqrt(v + 1e-5);
  for (let i = 0; i < dim; i++) x[i] = (x[i] - m) * inv;
}

function leakyRelu(x, dim) {
  for (let i = 0; i < dim; i++) if (x[i] < 0) x[i] *= STREAM_LEAKY_ALPHA;
}

class DenseLayer {
  constructor(inD, outD) { this.inD = inD; this.outD = outD; this.W = []; this.b = new Float64Array(outD); for (let o = 0; o < outD; o++) this.W.push(new Float64Array(inD)); }
  sparseInit(rng) {
    const lim = 1.0 / Math.sqrt(this.inD);
    for (let o = 0; o < this.outD; o++) {
      for (let i = 0; i < this.inD; i++) this.W[o][i] = (rng() < SPARSE_RATIO ? 0.0 : 1.0) * (rng() * 2 * lim - lim);
      this.b[o] = 0;
    }
  }
  forward(input) {
    const out = new Float64Array(this.outD);
    for (let o = 0; o < this.outD; o++) { let s = this.b[o]; for (let i = 0; i < this.inD; i++) s += this.W[o][i] * input[i]; out[o] = s; }
    return out;
  }
}

class StreamMLP {
  constructor(seed = 42) {
    const rng = mulberry32(seed);
    this.layer1 = new DenseLayer(STREAM_FEAT_DIM, STREAM_H1);
    this.layer2 = new DenseLayer(STREAM_H1, STREAM_H2);
    this.output = new DenseLayer(STREAM_H2, 1);
    this.layer1.sparseInit(rng); this.layer2.sparseInit(rng); this.output.sparseInit(rng);
    this.inputStats = new RunningStats(STREAM_FEAT_DIM);
    this.rewardMean = 0; this.rewardM2 = 0; this.rewardCount = 0; this.sampleCount = 0;
  }
  predict(features) {
    const normed = this.inputStats.normalize(features);
    let h1 = this.layer1.forward(normed); layerNorm(h1, STREAM_H1); leakyRelu(h1, STREAM_H1);
    let h2 = this.layer2.forward(h1); layerNorm(h2, STREAM_H2); leakyRelu(h2, STREAM_H2);
    return this.output.forward(h2)[0];
  }
  update(features, reward) {
    this.sampleCount++;
    this.inputStats.update(features);
    this.rewardCount++;
    const rD = reward - this.rewardMean; this.rewardMean += rD / this.rewardCount;
    this.rewardM2 += rD * (reward - this.rewardMean);
    let normR = reward;
    if (this.rewardCount >= 2) { normR = (reward - this.rewardMean) / Math.sqrt(this.rewardM2 / this.rewardCount + 1e-8); }

    const normed = this.inputStats.normalize(features);
    const z1 = this.layer1.forward(normed); const z1_ln = new Float64Array(z1); layerNorm(z1_ln, STREAM_H1);
    const h1 = new Float64Array(z1_ln); leakyRelu(h1, STREAM_H1);
    const z2 = this.layer2.forward(h1); const z2_ln = new Float64Array(z2); layerNorm(z2_ln, STREAM_H2);
    const h2 = new Float64Array(z2_ln); leakyRelu(h2, STREAM_H2);
    const pred = this.output.forward(h2);
    const delta = pred[0] - normR;

    let gL1 = 0;
    const dOH2 = new Float64Array(STREAM_H2);
    for (let j = 0; j < STREAM_H2; j++) { gL1 += Math.abs(delta * h2[j]); dOH2[j] = delta * this.output.W[0][j]; }
    gL1 += Math.abs(delta);

    const dH2 = new Float64Array(STREAM_H2);
    for (let j = 0; j < STREAM_H2; j++) dH2[j] = dOH2[j] * (z2_ln[j] >= 0 ? 1 : STREAM_LEAKY_ALPHA);
    const dL2H1 = new Float64Array(STREAM_H1);
    for (let o = 0; o < STREAM_H2; o++) { for (let i = 0; i < STREAM_H1; i++) { gL1 += Math.abs(dH2[o] * h1[i]); dL2H1[i] += dH2[o] * this.layer2.W[o][i]; } gL1 += Math.abs(dH2[o]); }

    const dH1 = new Float64Array(STREAM_H1);
    for (let j = 0; j < STREAM_H1; j++) dH1[j] = dL2H1[j] * (z1_ln[j] >= 0 ? 1 : STREAM_LEAKY_ALPHA);
    for (let o = 0; o < STREAM_H1; o++) { for (let i = 0; i < STREAM_FEAT_DIM; i++) gL1 += Math.abs(dH1[o] * normed[i]); gL1 += Math.abs(dH1[o]); }

    const prod = STREAM_KAPPA * Math.abs(delta) * gL1;
    const lr = prod > 1 ? STREAM_LR / prod : STREAM_LR;

    for (let j = 0; j < STREAM_H2; j++) this.output.W[0][j] -= lr * (delta * h2[j]) + STREAM_WEIGHT_DECAY * this.output.W[0][j];
    this.output.b[0] -= lr * delta;
    for (let o = 0; o < STREAM_H2; o++) { for (let i = 0; i < STREAM_H1; i++) this.layer2.W[o][i] -= lr * (dH2[o] * h1[i]) + STREAM_WEIGHT_DECAY * this.layer2.W[o][i]; this.layer2.b[o] -= lr * dH2[o]; }
    for (let o = 0; o < STREAM_H1; o++) { for (let i = 0; i < STREAM_FEAT_DIM; i++) this.layer1.W[o][i] -= lr * (dH1[o] * normed[i]) + STREAM_WEIGHT_DECAY * this.layer1.W[o][i]; this.layer1.b[o] -= lr * dH1[o]; }
  }
  samples() { return this.sampleCount; }
}

// ============================================================
// 特征构建 + 评估辅助
// ============================================================

function buildFeatures(ctx) {
  const out = new Float64Array(STREAM_FEAT_DIM);
  const hour = parseFloat(ctx.hour || '12');
  out[0] = Math.sin(2 * Math.PI * hour / 24);
  out[1] = Math.cos(2 * Math.PI * hour / 24);
  const dow = parseFloat(ctx.dayOfWeek || '0');
  out[2] = Math.sin(2 * Math.PI * dow / 7);
  out[3] = Math.cos(2 * Math.PI * dow / 7);
  out[4] = ctx.isWeekend === 'true' ? 1 : 0;
  const todMap = { dawn: 0.1, morning: 0.3, afternoon: 0.5, evening: 0.7, night: 0.9 };
  out[5] = todMap[ctx.timeOfDay] || 0.5;
  out[6] = ctx.batteryLevel ? parseFloat(ctx.batteryLevel) / 100 : 0.5;
  out[7] = ctx.isCharging === 'true' ? 1 : 0;
  const motion = ctx.motionState || 'stationary';
  out[8] = motion === 'stationary' ? 1 : 0;
  out[9] = motion === 'walking' ? 1 : 0;
  out[10] = motion === 'running' ? 1 : 0;
  out[11] = (motion === 'driving' || motion === 'transit') ? 1 : 0;
  out[12] = (ctx.geofence && ctx.geofence.length > 0) ? 1 : 0;
  out[13] = (ctx.wifiSsid && ctx.wifiSsid.length > 0) ? 1 : 0;
  out[14] = ctx.networkType === 'wifi' ? 1 : 0;
  out[15] = ctx.networkType === 'cellular' ? 1 : 0;
  return out;
}

function hybridScore(ruleScore, armSamples, mlpScore) {
  if (armSamples < STREAM_MIN_SAMPLES) return ruleScore;
  const nMlp = Math.tanh(mlpScore);
  let w = armSamples >= STREAM_RAMP_SAMPLES ? 0.3 : (armSamples - STREAM_MIN_SAMPLES) / (STREAM_RAMP_SAMPLES - STREAM_MIN_SAMPLES) * 0.3;
  return ruleScore * (1 + w * nMlp);
}

// Simple soft-match from _helpers.js
function softMatch(key, op, value, ctx) {
  const actual = ctx[key];
  if (actual == null) return 0.5;
  if (op === 'eq') return actual === value ? 1.0 : 0.0;
  if (op === 'in') return value.split(',').indexOf(actual) >= 0 ? 1.0 : 0.0;
  return actual === value ? 1.0 : 0.0;
}

// Evaluate a rule against context → confidence
function evalRule(rule, ctx) {
  let confidence = 1.0;
  for (const cond of rule.conditions) {
    confidence *= softMatch(cond.key, cond.op, cond.value, ctx);
    if (confidence < 0.01) break;
  }
  return confidence;
}

// ============================================================
// 场景测试
// ============================================================

describe('场景: 冷启动 → 过渡 → MLP 主导', function () {
  it('新用户第一天: 纯规则分（0 样本）', function () {
    const rules = [
      { id: 'morning_coffee', conditions: [{ key: 'timeOfDay', op: 'eq', value: 'morning' }], priority: 1.0, actionId: 'coffee' },
      { id: 'evening_music', conditions: [{ key: 'timeOfDay', op: 'eq', value: 'evening' }], priority: 1.0, actionId: 'music' }
    ];

    const ctx = { timeOfDay: 'morning', hour: '8' };
    const features = buildFeatures(ctx);

    // No training yet → cold start
    const mlp = new StreamMLP(42);
    const conf = evalRule(rules[0], ctx);
    const score = hybridScore(conf * rules[0].priority, mlp.samples(), mlp.predict(features));
    assertEqual(score, conf * rules[0].priority, 'cold start should use pure rule score');
  });

  it('5次反馈后: 过渡开始', function () {
    const mlp = new StreamMLP(42);
    const ctx = { timeOfDay: 'morning', hour: '8' };
    const features = buildFeatures(ctx);

    // Simulate 5 positive feedbacks
    for (let i = 0; i < 5; i++) {
      mlp.update(features, 1.0);
    }

    assertEqual(mlp.samples(), 5);

    // At exactly 5 samples, rlWeight = 0/15 * 0.3 = 0, so still pure rule score
    const ruleScore = 0.9;
    const score = hybridScore(ruleScore, mlp.samples(), mlp.predict(features));
    assertEqual(score, ruleScore, 'at 5 samples rlWeight=0, should equal rule score');
  });

  it('20次反馈后: MLP 全量影响', function () {
    const mlp = new StreamMLP(42);
    const ctx = { timeOfDay: 'morning', hour: '8', motionState: 'walking' };
    const features = buildFeatures(ctx);

    // Train 20 positive feedbacks
    for (let i = 0; i < 20; i++) {
      mlp.update(features, 1.0);
    }

    assertEqual(mlp.samples(), 20);
    const ruleScore = 0.8;
    const mlpPred = mlp.predict(features);
    const score = hybridScore(ruleScore, mlp.samples(), mlpPred);

    // rlWeight = 0.3, score should differ from pure rule score
    assertTrue(isFinite(score), 'hybrid score should be finite');
    assertTrue(score !== ruleScore || Math.abs(mlpPred) < 0.001,
      'at 20 samples, hybrid score should differ from rule score (unless MLP predicts ~0)');
  });
});

describe('场景: 用户反馈学习调整排序', function () {
  it('持续正反馈 → 规则排名上升', function () {
    // Two competing rules with same rule score
    const mlpA = new StreamMLP(42);
    const mlpB = new StreamMLP(43);

    const ctx = { timeOfDay: 'morning', hour: '8', motionState: 'walking' };
    const features = buildFeatures(ctx);
    const ruleScore = 0.8;

    // User always likes rule A, dislikes B
    for (let i = 0; i < 30; i++) {
      mlpA.update(features, 1.0);    // positive
      mlpB.update(features, -0.5);   // negative
    }

    const scoreA = hybridScore(ruleScore, mlpA.samples(), mlpA.predict(features));
    const scoreB = hybridScore(ruleScore, mlpB.samples(), mlpB.predict(features));

    assertGreaterThan(scoreA, scoreB, 'positively-trained rule should rank higher');
  });

  it('持续负反馈 → 规则排名下降', function () {
    const mlp = new StreamMLP(42);
    const ctx = { timeOfDay: 'evening', hour: '20' };
    const features = buildFeatures(ctx);

    // Train with consistent negative feedback
    for (let i = 0; i < 30; i++) {
      mlp.update(features, -1.0);
    }

    const ruleScore = 0.9;
    const score = hybridScore(ruleScore, mlp.samples(), mlp.predict(features));

    // Negative MLP prediction should reduce hybrid score
    assertLessThan(score, ruleScore, 'negative feedback should reduce hybrid score below rule score');
  });
});

describe('场景: 多规则竞争 RL 重排序', function () {
  it('3条规则竞争 → RL 调整相对分数', function () {
    // Rules with similar base scores so RL can meaningfully reorder
    const rules = [
      { id: 'rule_A', ruleScore: 0.9, priority: 1.0, actionId: 'actA' },
      { id: 'rule_B', ruleScore: 0.9, priority: 1.0, actionId: 'actB' },
      { id: 'rule_C', ruleScore: 0.9, priority: 1.0, actionId: 'actC' }
    ];

    const ctx = { timeOfDay: 'morning', hour: '8', motionState: 'walking' };
    const features = buildFeatures(ctx);

    // All have same base score = 0.9

    // Create per-arm MLPs
    const mlps = {};
    let seed = 100;
    for (const r of rules) {
      mlps[r.actionId] = new StreamMLP(seed++);
    }

    // User loves A, hates B, OK with C
    for (let i = 0; i < 40; i++) {
      mlps['actA'].update(features, 1.0);
      mlps['actB'].update(features, -1.0);
      mlps['actC'].update(features, 0.3);
    }

    // Compute hybrid scores
    const scores = rules.map(r => ({
      id: r.id,
      score: hybridScore(r.ruleScore * r.priority, mlps[r.actionId].samples(), mlps[r.actionId].predict(features))
    }));
    scores.sort((a, b) => b.score - a.score);

    // After RL learning with same base scores:
    // A (positive) should be #1, B (negative) should be last
    assertEqual(scores[0].id, 'rule_A', 'positively-trained rule A should be #1');
    assertEqual(scores[2].id, 'rule_B', 'negatively-trained rule B should be last');
  });
});

describe('场景: 上下文区分（早晚偏好）', function () {
  it('早晨正反馈 + 晚上负反馈 → 同一规则不同分', function () {
    const mlp = new StreamMLP(42);

    const morningCtx = { timeOfDay: 'morning', hour: '8', motionState: 'walking' };
    const eveningCtx = { timeOfDay: 'evening', hour: '20', motionState: 'stationary' };
    const morningFeats = buildFeatures(morningCtx);
    const eveningFeats = buildFeatures(eveningCtx);

    // Train: user likes this rule in morning, dislikes in evening
    for (let i = 0; i < 40; i++) {
      mlp.update(morningFeats, 1.0);
      mlp.update(eveningFeats, -1.0);
    }

    const morningPred = mlp.predict(morningFeats);
    const eveningPred = mlp.predict(eveningFeats);

    assertGreaterThan(morningPred, eveningPred,
      'MLP should predict higher for morning (positive-trained) than evening (negative-trained)');
  });

  it('工作日 vs 周末: 不同上下文不同预测', function () {
    const mlp = new StreamMLP(42);

    const weekdayCtx = { hour: '9', dayOfWeek: '2', isWeekend: 'false', timeOfDay: 'morning' };
    const weekendCtx = { hour: '9', dayOfWeek: '6', isWeekend: 'true', timeOfDay: 'morning' };
    const wdFeats = buildFeatures(weekdayCtx);
    const weFeats = buildFeatures(weekendCtx);

    // User likes commute reminder on weekdays, not weekends
    for (let i = 0; i < 40; i++) {
      mlp.update(wdFeats, 1.0);
      mlp.update(weFeats, -0.5);
    }

    const wdPred = mlp.predict(wdFeats);
    const wePred = mlp.predict(weFeats);

    assertGreaterThan(wdPred, wePred,
      'weekday prediction should be higher than weekend for commute rule');
  });
});

describe('场景: 极端条件稳定性', function () {
  it('大量连续训练（200次）→ 不发散', function () {
    const mlp = new StreamMLP(42);
    const features = buildFeatures({ hour: '12', timeOfDay: 'afternoon' });

    for (let i = 0; i < 200; i++) {
      mlp.update(features, Math.sin(i * 0.1));  // oscillating reward
    }

    const pred = mlp.predict(features);
    assertTrue(isFinite(pred), 'prediction should be finite after 200 updates');
    assertTrue(Math.abs(pred) < 1000, 'prediction should not diverge');
  });

  it('混合极端奖励 → 系统稳定', function () {
    const mlp = new StreamMLP(42);
    const features = buildFeatures({ hour: '8', timeOfDay: 'morning' });

    const extremeRewards = [100, -100, 0.001, -0.001, 50, -50, 0, 1, -1];
    for (const r of extremeRewards) {
      mlp.update(features, r);
    }

    const pred = mlp.predict(features);
    assertTrue(isFinite(pred), 'prediction stable with extreme rewards');
  });

  it('多 arm 并行训练不互相干扰', function () {
    const arms = {};
    const actionIds = ['act_a', 'act_b', 'act_c', 'act_d', 'act_e'];
    let seed = 10;
    for (const id of actionIds) {
      arms[id] = new StreamMLP(seed++);
    }

    const features = buildFeatures({ hour: '15', timeOfDay: 'afternoon' });

    // Train each arm with different reward
    const rewards = [1.0, -1.0, 0.5, -0.5, 0.0];
    for (let iter = 0; iter < 30; iter++) {
      for (let a = 0; a < actionIds.length; a++) {
        arms[actionIds[a]].update(features, rewards[a]);
      }
    }

    // All predictions should be finite
    for (const id of actionIds) {
      const pred = arms[id].predict(features);
      assertTrue(isFinite(pred), `${id} prediction should be finite`);
    }

    // Positive-trained arm should score higher than negative
    const predA = arms['act_a'].predict(features);
    const predB = arms['act_b'].predict(features);
    assertGreaterThan(predA, predB, 'positive-trained arm should predict higher');
  });
});

describe('场景: 完整反馈闭环模拟', function () {
  it('模拟一周使用：规则匹配→推荐→反馈→学习', function () {
    // 3 rules competing
    const rules = [
      {
        id: 'commute',
        conditions: [{ key: 'timeOfDay', op: 'eq', value: 'morning' }, { key: 'motionState', op: 'eq', value: 'walking' }],
        priority: 1.0,
        actionId: 'show_commute'
      },
      {
        id: 'weather',
        conditions: [{ key: 'timeOfDay', op: 'eq', value: 'morning' }],
        priority: 0.9,
        actionId: 'show_weather'
      },
      {
        id: 'news',
        conditions: [{ key: 'timeOfDay', op: 'eq', value: 'morning' }],
        priority: 0.8,
        actionId: 'show_news'
      }
    ];

    // Per-arm MLPs
    const arms = {};
    let seed = 200;
    for (const r of rules) {
      arms[r.actionId] = new StreamMLP(seed++);
    }

    // Simulate 7 days: morning context, user always likes commute, ignores weather, dislikes news
    const morningCtx = {
      timeOfDay: 'morning', hour: '8', dayOfWeek: '1',
      isWeekend: 'false', motionState: 'walking',
      geofence: 'home', batteryLevel: '85'
    };
    const features = buildFeatures(morningCtx);

    for (let day = 0; day < 7; day++) {
      // Evaluate all rules
      const candidates = rules.map(r => {
        const conf = evalRule(r, morningCtx);
        const mlpPred = arms[r.actionId].predict(features);
        return {
          ruleId: r.id,
          actionId: r.actionId,
          ruleScore: conf * r.priority,
          hybridScore: hybridScore(conf * r.priority, arms[r.actionId].samples(), mlpPred)
        };
      });
      candidates.sort((a, b) => b.hybridScore - a.hybridScore);

      // User feedback
      arms['show_commute'].update(features, 1.0);     // 👍
      arms['show_weather'].update(features, -0.2);     // ignored
      arms['show_news'].update(features, -0.5);        // 👎
    }

    // After a week, commute should score highest
    const finalScores = rules.map(r => {
      const conf = evalRule(r, morningCtx);
      const pred = arms[r.actionId].predict(features);
      return {
        id: r.id,
        score: hybridScore(conf * r.priority, arms[r.actionId].samples(), pred)
      };
    });
    finalScores.sort((a, b) => b.score - a.score);

    // Commute should be #1 after learning
    assertEqual(finalScores[0].id, 'commute',
      'after a week of positive feedback, commute should be top recommendation');

    // News should be last
    assertEqual(finalScores[2].id, 'news',
      'after a week of negative feedback, news should be last');
  });
});

describe('场景: 冷启动 fallback 正确性', function () {
  it('LinUCB fallback: 冷启动期间不使用 MLP', function () {
    const mlp = new StreamMLP(42);
    const features = buildFeatures({ hour: '8', timeOfDay: 'morning' });

    // Train only 3 times (below STREAM_MIN_SAMPLES=5)
    for (let i = 0; i < 3; i++) {
      mlp.update(features, 1.0);
    }

    const ruleScore = 0.85;
    const score = hybridScore(ruleScore, mlp.samples(), mlp.predict(features));
    assertEqual(score, ruleScore, 'below min samples should use pure rule score');
  });

  it('过渡期线性插值正确', function () {
    const ruleScore = 1.0;
    const mlpScore = 1.0;  // tanh(1.0) ≈ 0.762

    // Check linearity of rlWeight
    for (let s = STREAM_MIN_SAMPLES; s <= STREAM_RAMP_SAMPLES; s++) {
      const expected_w = (s - STREAM_MIN_SAMPLES) / (STREAM_RAMP_SAMPLES - STREAM_MIN_SAMPLES) * 0.3;
      const expectedScore = ruleScore * (1 + expected_w * Math.tanh(mlpScore));
      const actual = hybridScore(ruleScore, s, mlpScore);
      assertTrue(Math.abs(actual - expectedScore) < 1e-10,
        `at samples=${s}, hybridScore should match linear interpolation`);
    }
  });
});

// ============================================================
// v8.0: Stream RL UI Display — 学习标签
// ============================================================

describe('Stream RL UI 标签显示', function () {
  function getLabel(samples) {
    if (samples < 5) return '探索中';
    if (samples < 20) return `学习中 (${samples}次)`;
    return `已学习 (${samples}次)`;
  }

  it('冷启动阶段 (0-4) → 探索中', function () {
    assertEqual(getLabel(0), '探索中');
    assertEqual(getLabel(1), '探索中');
    assertEqual(getLabel(4), '探索中');
  });

  it('学习阶段 (5-19) → 学习中 (N次)', function () {
    assertEqual(getLabel(5), '学习中 (5次)');
    assertEqual(getLabel(10), '学习中 (10次)');
    assertEqual(getLabel(19), '学习中 (19次)');
  });

  it('收敛阶段 (20+) → 已学习 (N次)', function () {
    assertEqual(getLabel(20), '已学习 (20次)');
    assertEqual(getLabel(50), '已学习 (50次)');
    assertEqual(getLabel(100), '已学习 (100次)');
  });

  it('标签边界值精确', function () {
    // Boundary: 4 → 探索中, 5 → 学习中
    assertTrue(!getLabel(4).includes('学习中'));
    assertTrue(getLabel(5).includes('学习中'));
    // Boundary: 19 → 学习中, 20 → 已学习
    assertTrue(!getLabel(19).includes('已学习'));
    assertTrue(getLabel(20).includes('已学习'));
  });
});

// ============================================================
// v8.0: Explore State RL Phase
// ============================================================

describe('Explore 模式 RL 阶段标记', function () {
  function getRLPhase(totalSamples) {
    return totalSamples < 10 ? '冷启动' : totalSamples < 50 ? '学习中' : '已收敛';
  }

  it('0样本 → 冷启动', function () { assertEqual(getRLPhase(0), '冷启动'); });
  it('9样本 → 冷启动', function () { assertEqual(getRLPhase(9), '冷启动'); });
  it('10样本 → 学习中', function () { assertEqual(getRLPhase(10), '学习中'); });
  it('49样本 → 学习中', function () { assertEqual(getRLPhase(49), '学习中'); });
  it('50样本 → 已收敛', function () { assertEqual(getRLPhase(50), '已收敛'); });
  it('100样本 → 已收敛', function () { assertEqual(getRLPhase(100), '已收敛'); });
});
