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
      if (actual == null) {
        // Critical fields: missing → 0.0 (no match), mirrors soft_match.cpp
        const criticalKeys = new Set([
          'motionState', 'isCharging', 'isWeekend', 'isSleeping',
          'timeOfDay', 'geofence', 'batteryLevel'
        ]);
        confidence *= criticalKeys.has(key) ? 0.0 : 0.5;
        continue;
      }
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

/**
 * Load an NDJSON recording file and parse into structured data.
 * @param {string} filePath - Path to the .ndjson recording file
 * @returns {{ header: object|null, events: object[], snapshots: object[], footer: object|null }}
 */
function loadRecording(filePath) {
  const fs = require('fs');
  const content = fs.readFileSync(filePath, 'utf-8');
  const lines = content.split('\n').filter(l => l.trim().length > 0);

  let header = null;
  let footer = null;
  const events = [];
  const snapshots = [];

  for (const line of lines) {
    try {
      const obj = JSON.parse(line);
      switch (obj.type) {
        case 'header': header = obj; break;
        case 'footer': footer = obj; break;
        case 'event': events.push(obj); break;
        case 'snap': snapshots.push(obj); break;
      }
    } catch (_e) { /* skip malformed lines */ }
  }

  return { header, events, snapshots, footer };
}

/**
 * Build a context snapshot at a given timestamp by replaying events.
 * Uses the nearest snapshot keyframe before `time` as a starting point,
 * then applies events up to `time`.
 *
 * @param {object[]} events - Array of recording event objects (sorted by t)
 * @param {number} time - Target timestamp
 * @param {object[]} [snapshots] - Optional array of snapshot keyframes
 * @returns {object} Context snapshot at the given time
 */
function buildSnapshotAtTime(events, time, snapshots) {
  let snapshot = {};

  // Find nearest snapshot before target time
  if (snapshots && snapshots.length > 0) {
    for (const snap of snapshots) {
      if (snap.t <= time) {
        snapshot = Object.assign({}, snap.d);
      } else {
        break;
      }
    }
  }

  // Apply events up to the target time
  for (const ev of events) {
    if (ev.t > time) break;
    snapshot[ev.k] = ev.v;
  }

  return snapshot;
}

module.exports = { evaluate, gaussianDecay, loadRecording, buildSnapshotAtTime };
