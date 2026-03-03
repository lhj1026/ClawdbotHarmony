'use strict';
/**
 * 状态转换首次调用修复 + 路径栏渲染 场景测试
 * 对应: StateTransitionTracker — first-call 初始化, getTransitionJson, 路径栏标签
 *
 * 场景覆盖:
 *   1. 首次调用 → 无转换, current_ 已初始化
 *   2. 首次调用 → getTransitionJson 返回 "{}"
 *   3. 第二次调用不同地理围栏 → 正确 from/to 转换
 *   4. 两个标签都为空 → 返回 "{}"
 *   5. 两个标签都非空 → 有效路径栏 JSON
 *   6. 转换间持续时间计算正确
 *   7. 导入/导出保持首次调用初始化
 *   8. 路径栏标签验证: 空字符串 → 不渲染
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertFalse, assertDefined
} = require('../../lib/assert');

// ============================================================
// JS mirror: StateTransitionTracker
// ============================================================

class StateTransitionTracker {
  constructor() {
    this.current_ = null;    // { label, geofenceId, timestamp }
    this.previous_ = null;   // { label, geofenceId, timestamp }
    this.hasTransition_ = false;
    this.initialized_ = false;
  }

  /**
   * update() — called with each new state observation.
   * First call: initializes current_ but does NOT create a transition.
   * Subsequent calls: if state changed, shifts current_ → previous_, sets new current_, marks transition.
   *
   * @param {string} label      - human-readable label (e.g., "Home", "Office")
   * @param {string} geofenceId - geofence zone ID
   * @param {number} timestamp  - epoch ms
   */
  update(label, geofenceId, timestamp) {
    if (!this.initialized_) {
      // First call: just initialize, no transition
      this.current_ = { label, geofenceId, timestamp };
      this.initialized_ = true;
      this.hasTransition_ = false;
      return;
    }

    // Subsequent calls: check if geofence changed
    if (geofenceId !== this.current_.geofenceId) {
      this.previous_ = { ...this.current_ };
      this.current_ = { label, geofenceId, timestamp };
      this.hasTransition_ = true;
    } else {
      // Same geofence — update timestamp but no transition
      this.current_.timestamp = timestamp;
      this.hasTransition_ = false;
    }
  }

  /**
   * getTransitionJson() — returns JSON describing the last transition.
   * Returns "{}" if both from/to labels are empty or no transition occurred.
   */
  getTransitionJson() {
    if (!this.hasTransition_ || !this.previous_ || !this.current_) {
      return '{}';
    }

    const fromLabel = this.previous_.label || '';
    const toLabel = this.current_.label || '';

    // If both labels are empty → no meaningful transition to report
    if (fromLabel === '' && toLabel === '') {
      return '{}';
    }

    const duration = this.current_.timestamp - this.previous_.timestamp;

    return JSON.stringify({
      from: {
        label: fromLabel,
        geofenceId: this.previous_.geofenceId,
        timestamp: this.previous_.timestamp,
      },
      to: {
        label: toLabel,
        geofenceId: this.current_.geofenceId,
        timestamp: this.current_.timestamp,
      },
      durationMs: duration,
    });
  }

  /**
   * persistTransitionState() — serialize for periodic persistence during evaluate.
   */
  persistTransitionState() {
    return JSON.stringify({
      current: this.current_,
      previous: this.previous_,
      hasTransition: this.hasTransition_,
      initialized: this.initialized_,
    });
  }

  /**
   * restoreTransitionState() — restore from persisted data.
   */
  restoreTransitionState(json) {
    const data = JSON.parse(json);
    this.current_ = data.current;
    this.previous_ = data.previous;
    this.hasTransition_ = data.hasTransition;
    this.initialized_ = data.initialized;
  }
}

// ============================================================
// JS mirror: Path bar rendering validation
// ============================================================

/**
 * shouldRenderPathBar() — path bar requires label to be a non-empty string,
 * not just !== undefined.
 */
function shouldRenderPathBar(transitionJson) {
  if (transitionJson === '{}') return false;

  let data;
  try {
    data = JSON.parse(transitionJson);
  } catch (_e) {
    return false;
  }

  // Both from and to labels must be non-empty strings
  const fromLabel = (data.from && data.from.label) || '';
  const toLabel = (data.to && data.to.label) || '';

  return fromLabel.length > 0 && toLabel.length > 0;
}

// ============================================================
// Tests
// ============================================================

describe('场景: 首次调用初始化 (first-call fix)', function () {
  it('首次调用 → 无转换, current_ 已初始化', function () {
    const tracker = new StateTransitionTracker();

    tracker.update('Home', 'geo_001', 1000);

    // current_ should be initialized
    assertDefined(tracker.current_, 'current_ should be defined after first call');
    assertEqual(tracker.current_.label, 'Home');
    assertEqual(tracker.current_.geofenceId, 'geo_001');
    assertEqual(tracker.current_.timestamp, 1000);

    // No transition should exist
    assertFalse(tracker.hasTransition_,
      'first call should NOT create a transition');
    assertEqual(tracker.previous_, null,
      'previous_ should remain null after first call');
  });

  it('首次调用 → getTransitionJson 返回 "{}"', function () {
    const tracker = new StateTransitionTracker();

    tracker.update('Home', 'geo_001', 1000);

    const json = tracker.getTransitionJson();
    assertEqual(json, '{}',
      'first call should produce empty transition JSON');
  });
});

describe('场景: 状态变化创建转换', function () {
  it('第二次调用不同地理围栏 → 正确 from/to', function () {
    const tracker = new StateTransitionTracker();

    // First call: Home
    tracker.update('Home', 'geo_001', 1000);

    // Second call: Office (different geofence)
    tracker.update('Office', 'geo_002', 5000);

    assertTrue(tracker.hasTransition_,
      'different geofence should create a transition');
    assertDefined(tracker.previous_,
      'previous_ should be set after transition');

    const json = tracker.getTransitionJson();
    const data = JSON.parse(json);

    assertEqual(data.from.label, 'Home', 'from label should be Home');
    assertEqual(data.from.geofenceId, 'geo_001', 'from geofenceId should be geo_001');
    assertEqual(data.to.label, 'Office', 'to label should be Office');
    assertEqual(data.to.geofenceId, 'geo_002', 'to geofenceId should be geo_002');
  });

  it('两个标签都为空 → 返回 "{}"', function () {
    const tracker = new StateTransitionTracker();

    // First call with empty label
    tracker.update('', 'geo_001', 1000);

    // Second call with empty label and different geofence
    tracker.update('', 'geo_002', 5000);

    assertTrue(tracker.hasTransition_,
      'geofence change should set hasTransition_ even with empty labels');

    const json = tracker.getTransitionJson();
    assertEqual(json, '{}',
      'both labels empty should return "{}" even when transition exists');
  });

  it('两个标签都非空 → 有效路径栏 JSON', function () {
    const tracker = new StateTransitionTracker();

    tracker.update('Home', 'geo_001', 1000);
    tracker.update('Office', 'geo_002', 5000);

    const json = tracker.getTransitionJson();
    const data = JSON.parse(json);

    // Verify structure
    assertDefined(data.from, 'from should be defined');
    assertDefined(data.to, 'to should be defined');
    assertDefined(data.durationMs, 'durationMs should be defined');
    assertEqual(data.from.label, 'Home');
    assertEqual(data.to.label, 'Office');

    // Should render path bar
    assertTrue(shouldRenderPathBar(json),
      'valid labels should allow path bar rendering');
  });
});

describe('场景: 持续时间计算', function () {
  it('转换间持续时间计算正确', function () {
    const tracker = new StateTransitionTracker();

    const t1 = 1709400000000; // some epoch time
    const t2 = t1 + 1800000;  // 30 minutes later

    tracker.update('Home', 'geo_001', t1);
    tracker.update('Office', 'geo_002', t2);

    const json = tracker.getTransitionJson();
    const data = JSON.parse(json);

    assertEqual(data.durationMs, 1800000,
      'duration should be 1800000ms (30 minutes)');
    assertEqual(data.from.timestamp, t1, 'from timestamp should be t1');
    assertEqual(data.to.timestamp, t2, 'to timestamp should be t2');
  });
});

describe('场景: 持久化导入/导出', function () {
  it('导入/导出保持首次调用初始化', function () {
    const original = new StateTransitionTracker();

    // First call only — initialized but no transition
    original.update('Home', 'geo_001', 1000);

    // Persist
    const persisted = original.persistTransitionState();

    // Restore into new tracker
    const restored = new StateTransitionTracker();
    restored.restoreTransitionState(persisted);

    // Verify restored state matches
    assertTrue(restored.initialized_,
      'restored tracker should be initialized');
    assertFalse(restored.hasTransition_,
      'restored tracker should preserve no-transition from first call');
    assertEqual(restored.current_.label, 'Home',
      'restored current_ label should match');
    assertEqual(restored.current_.geofenceId, 'geo_001',
      'restored current_ geofenceId should match');
    assertEqual(restored.previous_, null,
      'restored previous_ should remain null');

    // Now subsequent update on restored tracker should work correctly
    restored.update('Office', 'geo_002', 5000);

    assertTrue(restored.hasTransition_,
      'update after restore should create proper transition');
    const data = JSON.parse(restored.getTransitionJson());
    assertEqual(data.from.label, 'Home');
    assertEqual(data.to.label, 'Office');
  });

  it('导入/导出保持有转换的状态', function () {
    const original = new StateTransitionTracker();
    original.update('Home', 'geo_001', 1000);
    original.update('Office', 'geo_002', 5000);

    const persisted = original.persistTransitionState();
    const restored = new StateTransitionTracker();
    restored.restoreTransitionState(persisted);

    assertTrue(restored.hasTransition_,
      'restored transition flag should be preserved');
    assertEqual(restored.previous_.label, 'Home');
    assertEqual(restored.current_.label, 'Office');

    const json = restored.getTransitionJson();
    const data = JSON.parse(json);
    assertEqual(data.durationMs, 4000,
      'restored duration should be 4000ms');
  });
});

describe('场景: 路径栏标签验证', function () {
  it('空字符串标签 → 不渲染路径栏', function () {
    // Empty transition JSON
    assertFalse(shouldRenderPathBar('{}'),
      'empty transition should not render path bar');

    // One label empty
    const oneEmpty = JSON.stringify({
      from: { label: 'Home', geofenceId: 'g1', timestamp: 1000 },
      to: { label: '', geofenceId: 'g2', timestamp: 2000 },
      durationMs: 1000,
    });
    assertFalse(shouldRenderPathBar(oneEmpty),
      'one empty label should not render path bar');

    // Both labels empty
    const bothEmpty = JSON.stringify({
      from: { label: '', geofenceId: 'g1', timestamp: 1000 },
      to: { label: '', geofenceId: 'g2', timestamp: 2000 },
      durationMs: 1000,
    });
    assertFalse(shouldRenderPathBar(bothEmpty),
      'both empty labels should not render path bar');
  });

  it('两个有效标签 → 渲染路径栏', function () {
    const valid = JSON.stringify({
      from: { label: 'Home', geofenceId: 'g1', timestamp: 1000 },
      to: { label: 'Office', geofenceId: 'g2', timestamp: 5000 },
      durationMs: 4000,
    });
    assertTrue(shouldRenderPathBar(valid),
      'both labels non-empty should render path bar');
  });

  it('undefined 标签字段 → 不渲染路径栏', function () {
    // Missing label fields entirely
    const noLabels = JSON.stringify({
      from: { geofenceId: 'g1', timestamp: 1000 },
      to: { geofenceId: 'g2', timestamp: 2000 },
      durationMs: 1000,
    });
    assertFalse(shouldRenderPathBar(noLabels),
      'missing label fields should not render path bar');
  });

  it('同一地理围栏重复更新 → 无转换', function () {
    const tracker = new StateTransitionTracker();
    tracker.update('Home', 'geo_001', 1000);
    tracker.update('Home', 'geo_001', 2000); // same geofence

    assertFalse(tracker.hasTransition_,
      'same geofence should not create transition');
    assertEqual(tracker.getTransitionJson(), '{}',
      'no transition should produce empty JSON');
    assertEqual(tracker.current_.timestamp, 2000,
      'timestamp should be updated even without transition');
  });
});
