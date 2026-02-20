'use strict';
/**
 * 共享场景测试辅助函数
 */

function gaussianDecay(diff, tolerance) {
  if (diff <= tolerance) return 1.0;
  return Math.exp(-0.5 * ((diff - tolerance) / 1.0) ** 2);
}

function evaluate(snapshot, rules) {
  const results = [];
  for (const rule of rules) {
    let confidence = 1.0;
    for (const [key, cond] of Object.entries(rule.conditions)) {
      const actual = snapshot[key];
      if (actual == null) { confidence *= 0.5; continue; }
      switch (cond.op) {
        case 'eq': confidence *= (actual === cond.value) ? 1.0 : 0.0; break;
        case 'neq': confidence *= (actual !== cond.value) ? 1.0 : 0.0; break;
        case 'in': confidence *= cond.value.includes(actual) ? 1.0 : 0.0; break;
        case 'range': {
          const mid = (cond.value[0] + cond.value[1]) / 2;
          const half = (cond.value[1] - cond.value[0]) / 2;
          confidence *= gaussianDecay(Math.abs(actual - mid), half);
          break;
        }
        case 'lte': confidence *= actual <= cond.value ? 1.0 : Math.max(0, 1 - (actual - cond.value) / 3); break;
        case 'gte': confidence *= actual >= cond.value ? 1.0 : Math.max(0, 1 - (cond.value - actual) / 3); break;
      }
      if (confidence < 0.01) break;
    }
    if (confidence > 0.01) results.push({ ruleId: rule.id, confidence, intent: rule.intent, priority: rule.priority });
  }
  return results.sort((a, b) => b.confidence - a.confidence);
}

module.exports = { evaluate, gaussianDecay };
