'use strict';
/**
 * StateTransitionTracker 单元测试
 * 对应: state_transition.h / state_transition.cpp
 * 覆盖: 状态变化检测、特征注入、routine检测、direction分类、持久化
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertGreaterThan, assertDefined
} = require('../../lib/assert');

// ============================================================
// JS 镜像：StateTransitionTracker
// ============================================================

class StateSnapshot {
  constructor() {
    this.geofence = '';
    this.geofenceLabel = '';
    this.geofenceIcon = '';
    this.motionState = 'stationary';
    this.timestamp = 0;
  }
}

function geoCategory(geo) {
  if (!geo) return '';
  if (geo.includes('home') || geo.includes('cafe') || geo.includes('gym') || geo.includes('park') || geo.includes('mall')) return 'rest';
  if (geo.includes('office') || geo.includes('work') || geo.includes('school') || geo.includes('hospital')) return 'work';
  return '';
}

function geofenceIcon(geo) {
  if (!geo) return '';
  if (geo.includes('home')) return '🏠';
  if (geo.includes('office') || geo.includes('work')) return '🏢';
  if (geo.includes('gym')) return '💪';
  if (geo.includes('cafe')) return '☕';
  if (geo.includes('mall')) return '🛍️';
  if (geo.includes('hospital')) return '🏥';
  if (geo.includes('airport')) return '✈️';
  if (geo.includes('school')) return '🏫';
  if (geo.includes('park')) return '🌳';
  if (geo.includes('transit') || geo.includes('station')) return '🚌';
  return '📍';
}

function geofenceLabel(geo) {
  if (!geo) return '';
  if (geo.includes('home')) return '家';
  if (geo.includes('office') || geo.includes('work')) return '办公室';
  if (geo.includes('gym')) return '健身房';
  if (geo.includes('cafe')) return '咖啡厅';
  if (geo.includes('mall')) return '商场';
  if (geo.includes('hospital')) return '医院';
  if (geo.includes('airport')) return '机场';
  if (geo.includes('school')) return '学校';
  if (geo.includes('park')) return '公园';
  return geo;
}

function classifyDirection(fromGeo, toGeo) {
  const fromCat = geoCategory(fromGeo);
  const toCat = geoCategory(toGeo);
  if (!fromCat || !toCat) return 0;
  if (fromCat === toCat) return 0;
  if (fromCat === 'rest' && toCat === 'work') return 1;
  if (fromCat === 'work' && toCat === 'rest') return -1;
  return 0;
}

const ROUTINE_THRESHOLD = 3;

class StateTransitionTracker {
  constructor() {
    this.current_ = new StateSnapshot();
    this.previous_ = new StateSnapshot();
    this.transitionTimestamps_ = [];
    this.hasTransition_ = false;
    this.routeCounts_ = {};
  }

  update(ctx, nowOverride) {
    const newGeo = ctx.geofence || '';
    const newMotion = ctx.motionState || 'stationary';
    const now = nowOverride || Date.now();

    // First time
    if (this.current_.timestamp === 0) {
      this.current_.geofence = newGeo;
      this.current_.geofenceLabel = geofenceLabel(newGeo);
      this.current_.geofenceIcon = geofenceIcon(newGeo);
      this.current_.motionState = newMotion;
      this.current_.timestamp = now;
      return true;
    }

    // Check change
    if (newGeo === this.current_.geofence && newMotion === this.current_.motionState) {
      return false;
    }

    // State changed
    this.previous_ = { ...this.current_ };

    this.current_.geofence = newGeo;
    this.current_.geofenceLabel = geofenceLabel(newGeo);
    this.current_.geofenceIcon = geofenceIcon(newGeo);
    this.current_.motionState = newMotion;
    this.current_.timestamp = now;

    this.transitionTimestamps_.push(now);

    // Prune old (> 1 hour)
    const cutoff = now - 3600000;
    while (this.transitionTimestamps_.length > 0 && this.transitionTimestamps_[0] < cutoff) {
      this.transitionTimestamps_.shift();
    }

    // Routine detection
    if (this.previous_.geofence && this.current_.geofence) {
      const hour = new Date(now).getHours();
      const hourBucket = Math.floor(hour / 4);
      const routeKey = `${this.previous_.geofence}|${this.current_.geofence}|${hourBucket}`;
      this.routeCounts_[routeKey] = (this.routeCounts_[routeKey] || 0) + 1;
    }

    this.hasTransition_ = true;
    return true;
  }

  injectFeatures(ctx) {
    if (!this.hasTransition_) return;

    ctx.prev_geofence = this.previous_.geofence ? '1' : '0';
    ctx.geofence_changed = (this.previous_.geofence !== this.current_.geofence) ? '1' : '0';

    const wasStationary = this.previous_.motionState === 'stationary';
    const wasMoving = ['walking', 'running', 'driving', 'transit'].includes(this.previous_.motionState);
    ctx.prev_motionState_stationary = wasStationary ? '1' : '0';
    ctx.prev_motionState_moving = wasMoving ? '1' : '0';

    let durationMin = 0;
    if (this.previous_.timestamp > 0 && this.current_.timestamp > this.previous_.timestamp) {
      durationMin = (this.current_.timestamp - this.previous_.timestamp) / 60000;
    }
    ctx.transition_duration_min = String(Math.min(durationMin / 120, 1.0));

    const now = Date.now();
    let timeInCurrent = this.current_.timestamp > 0 ? (now - this.current_.timestamp) / 60000 : 0;
    ctx.time_in_current_state_min = String(Math.min(timeInCurrent / 240, 1.0));

    ctx.transitions_last_hour = String(Math.min(this.transitionTimestamps_.length / 10, 1.0));

    // Routine check
    let isRoutine = false;
    if (this.previous_.geofence && this.current_.geofence) {
      for (let hb = 0; hb < 6; hb++) {
        const key = `${this.previous_.geofence}|${this.current_.geofence}|${hb}`;
        if ((this.routeCounts_[key] || 0) >= ROUTINE_THRESHOLD) {
          isRoutine = true;
          break;
        }
      }
    }
    ctx.is_routine_transition = isRoutine ? '1' : '0';

    const dir = classifyDirection(this.previous_.geofence, this.current_.geofence);
    ctx.transition_direction = String((dir + 1) / 2);
  }

  getTransitionJson() {
    if (!this.hasTransition_ || this.previous_.timestamp === 0) return '{}';

    const durationMin = this.previous_.timestamp > 0 && this.current_.timestamp > this.previous_.timestamp
      ? (this.current_.timestamp - this.previous_.timestamp) / 60000 : 0;

    let isRoutine = false;
    if (this.previous_.geofence && this.current_.geofence) {
      for (let hb = 0; hb < 6; hb++) {
        const key = `${this.previous_.geofence}|${this.current_.geofence}|${hb}`;
        if ((this.routeCounts_[key] || 0) >= ROUTINE_THRESHOLD) {
          isRoutine = true;
          break;
        }
      }
    }

    const dir = classifyDirection(this.previous_.geofence, this.current_.geofence);

    const result = {
      from: {
        icon: this.previous_.geofenceIcon,
        label: this.previous_.geofenceLabel,
        geofence: this.previous_.geofence,
        motionState: this.previous_.motionState
      },
      to: {
        icon: this.current_.geofenceIcon,
        label: this.current_.geofenceLabel,
        geofence: this.current_.geofence,
        motionState: this.current_.motionState
      },
      durationMin,
      isRoutine,
      direction: dir
    };

    if (isRoutine) {
      result.patternLabel = '常规通勤';
    }

    return JSON.stringify(result);
  }

  exportJson() {
    return JSON.stringify({
      hasTransition: this.hasTransition_,
      current: this.current_,
      previous: this.previous_,
      routeCounts: this.routeCounts_
    });
  }

  importJson(json) {
    const data = JSON.parse(json);
    this.hasTransition_ = data.hasTransition || false;
    if (data.current) Object.assign(this.current_, data.current);
    if (data.previous) Object.assign(this.previous_, data.previous);
    this.routeCounts_ = data.routeCounts || {};
  }
}

// ============================================================
// 测试
// ============================================================

describe('StateTransitionTracker - 状态变化检测', function () {
  it('首次 update → 返回 true（初始化）', function () {
    const tracker = new StateTransitionTracker();
    const changed = tracker.update({ geofence: 'home_001', motionState: 'stationary' }, 1000);
    assertTrue(changed, 'first update should return true');
  });

  it('相同状态 → 返回 false', function () {
    const tracker = new StateTransitionTracker();
    tracker.update({ geofence: 'home_001', motionState: 'stationary' }, 1000);
    const changed = tracker.update({ geofence: 'home_001', motionState: 'stationary' }, 2000);
    assertTrue(!changed, 'same state should return false');
  });

  it('geofence 变化 → 返回 true', function () {
    const tracker = new StateTransitionTracker();
    tracker.update({ geofence: 'home_001', motionState: 'stationary' }, 1000);
    const changed = tracker.update({ geofence: 'office_001', motionState: 'stationary' }, 2000);
    assertTrue(changed, 'geofence change should return true');
  });

  it('motionState 变化 → 返回 true', function () {
    const tracker = new StateTransitionTracker();
    tracker.update({ geofence: 'home_001', motionState: 'stationary' }, 1000);
    const changed = tracker.update({ geofence: 'home_001', motionState: 'walking' }, 2000);
    assertTrue(changed, 'motion change should return true');
  });

  it('geofence + motionState 同时变化 → 返回 true', function () {
    const tracker = new StateTransitionTracker();
    tracker.update({ geofence: 'home_001', motionState: 'stationary' }, 1000);
    const changed = tracker.update({ geofence: 'office_001', motionState: 'walking' }, 2000);
    assertTrue(changed, 'both changing should return true');
  });
});

describe('StateTransitionTracker - 特征注入', function () {
  it('无转移时不注入特征', function () {
    const tracker = new StateTransitionTracker();
    tracker.update({ geofence: 'home_001', motionState: 'stationary' }, 1000);
    const ctx = {};
    tracker.injectFeatures(ctx);
    // hasTransition_ is false after first update (no previous state)
    assertEqual(ctx.prev_geofence, undefined, 'should not inject without transition');
  });

  it('geofence 转移 → 注入正确特征', function () {
    const tracker = new StateTransitionTracker();
    tracker.update({ geofence: 'home_001', motionState: 'stationary' }, 1000);
    tracker.update({ geofence: 'office_001', motionState: 'walking' }, 1000 + 45 * 60000);

    const ctx = {};
    tracker.injectFeatures(ctx);

    assertEqual(ctx.prev_geofence, '1', 'had previous geofence');
    assertEqual(ctx.geofence_changed, '1', 'geofence changed');
    assertEqual(ctx.prev_motionState_stationary, '1', 'was stationary');
    assertEqual(ctx.prev_motionState_moving, '0', 'was not moving');
    // Duration: 45min / 120 = 0.375
    assertTrue(Math.abs(parseFloat(ctx.transition_duration_min) - 0.375) < 0.01, 'duration');
    assertEqual(ctx.transitions_last_hour, '0.1', 'one transition / 10');
  });

  it('无 geofence 转移 → prev_geofence=0', function () {
    const tracker = new StateTransitionTracker();
    tracker.update({ motionState: 'stationary' }, 1000);
    tracker.update({ motionState: 'walking' }, 2000);

    const ctx = {};
    tracker.injectFeatures(ctx);

    assertEqual(ctx.prev_geofence, '0', 'no previous geofence');
    assertEqual(ctx.geofence_changed, '0', 'no geofence change (both empty)');
  });
});

describe('StateTransitionTracker - Routine 检测', function () {
  it('3次同路线 → isRoutine=true', function () {
    const tracker = new StateTransitionTracker();
    const baseTime = new Date(2026, 2, 2, 8, 0, 0).getTime(); // Monday 8am

    // 3 identical transitions: home → office at ~8am
    for (let i = 0; i < 3; i++) {
      tracker.update({ geofence: 'home_001', motionState: 'stationary' }, baseTime + i * 86400000);
      tracker.update({ geofence: 'office_001', motionState: 'walking' }, baseTime + i * 86400000 + 45 * 60000);
    }

    const ctx = {};
    tracker.injectFeatures(ctx);
    assertEqual(ctx.is_routine_transition, '1', 'should be routine after 3 times');
  });

  it('2次同路线 → isRoutine=false', function () {
    const tracker = new StateTransitionTracker();
    const baseTime = new Date(2026, 2, 2, 8, 0, 0).getTime();

    for (let i = 0; i < 2; i++) {
      tracker.update({ geofence: 'home_001', motionState: 'stationary' }, baseTime + i * 86400000);
      tracker.update({ geofence: 'office_001', motionState: 'walking' }, baseTime + i * 86400000 + 45 * 60000);
    }

    const ctx = {};
    tracker.injectFeatures(ctx);
    assertEqual(ctx.is_routine_transition, '0', 'should not be routine after only 2 times');
  });

  it('不同路线不互相计数', function () {
    const tracker = new StateTransitionTracker();
    const baseTime = new Date(2026, 2, 2, 8, 0, 0).getTime();

    // home→office, home→gym, home→cafe (all different destinations)
    tracker.update({ geofence: 'home_001', motionState: 'stationary' }, baseTime);
    tracker.update({ geofence: 'office_001', motionState: 'walking' }, baseTime + 45 * 60000);

    tracker.update({ geofence: 'home_001', motionState: 'stationary' }, baseTime + 86400000);
    tracker.update({ geofence: 'gym_001', motionState: 'walking' }, baseTime + 86400000 + 30 * 60000);

    tracker.update({ geofence: 'home_001', motionState: 'stationary' }, baseTime + 2 * 86400000);
    tracker.update({ geofence: 'cafe_001', motionState: 'walking' }, baseTime + 2 * 86400000 + 15 * 60000);

    const ctx = {};
    tracker.injectFeatures(ctx);
    assertEqual(ctx.is_routine_transition, '0', 'different routes should not accumulate');
  });
});

describe('StateTransitionTracker - Direction 分类', function () {
  it('home→office → direction=+1 (rest→work)', function () {
    assertEqual(classifyDirection('home_001', 'office_001'), 1, 'home→office = +1');
  });

  it('office→home → direction=-1 (work→rest)', function () {
    assertEqual(classifyDirection('office_001', 'home_001'), -1, 'office→home = -1');
  });

  it('home→gym → direction=0 (same category)', function () {
    assertEqual(classifyDirection('home_001', 'gym_001'), 0, 'home→gym = 0 (both rest)');
  });

  it('office→school → direction=0 (same category)', function () {
    assertEqual(classifyDirection('office_001', 'school_001'), 0, 'office→school = 0 (both work)');
  });

  it('unknown → direction=0', function () {
    assertEqual(classifyDirection('home_001', 'unknown_place'), 0, 'unknown destination = 0');
    assertEqual(classifyDirection('', 'office_001'), 0, 'empty origin = 0');
  });

  it('normalized direction 映射', function () {
    // direction=-1 → (−1+1)/2 = 0.0
    // direction=0  → (0+1)/2  = 0.5
    // direction=+1 → (1+1)/2  = 1.0
    const tracker = new StateTransitionTracker();
    tracker.update({ geofence: 'home_001', motionState: 'stationary' }, 1000);
    tracker.update({ geofence: 'office_001', motionState: 'walking' }, 2000);
    const ctx = {};
    tracker.injectFeatures(ctx);
    assertEqual(parseFloat(ctx.transition_direction), 1.0, 'rest→work normalized = 1.0');
  });
});

describe('StateTransitionTracker - getTransitionJson', function () {
  it('无转移 → 空 JSON', function () {
    const tracker = new StateTransitionTracker();
    tracker.update({ geofence: 'home_001', motionState: 'stationary' }, 1000);
    const json = tracker.getTransitionJson();
    assertEqual(json, '{}', 'no transition should return {}');
  });

  it('有转移 → 正确 JSON 结构', function () {
    const tracker = new StateTransitionTracker();
    tracker.update({ geofence: 'home_001', motionState: 'stationary' }, 1000);
    tracker.update({ geofence: 'office_001', motionState: 'walking' }, 1000 + 45 * 60000);

    const json = tracker.getTransitionJson();
    const parsed = JSON.parse(json);

    assertDefined(parsed.from, 'should have from');
    assertDefined(parsed.to, 'should have to');
    assertEqual(parsed.from.label, '家', 'from label');
    assertEqual(parsed.to.label, '办公室', 'to label');
    assertTrue(Math.abs(parsed.durationMin - 45) < 0.1, 'duration ~45min');
    assertEqual(parsed.direction, 1, 'rest→work');
  });

  it('routine 标签', function () {
    const tracker = new StateTransitionTracker();
    const baseTime = new Date(2026, 2, 2, 8, 0, 0).getTime();

    for (let i = 0; i < 3; i++) {
      tracker.update({ geofence: 'home_001', motionState: 'stationary' }, baseTime + i * 86400000);
      tracker.update({ geofence: 'office_001', motionState: 'walking' }, baseTime + i * 86400000 + 45 * 60000);
    }

    const parsed = JSON.parse(tracker.getTransitionJson());
    assertTrue(parsed.isRoutine, 'should be routine');
    assertEqual(parsed.patternLabel, '常规通勤', 'pattern label');
  });
});

describe('StateTransitionTracker - 持久化', function () {
  it('export → import → 状态恢复', function () {
    const tracker = new StateTransitionTracker();
    tracker.update({ geofence: 'home_001', motionState: 'stationary' }, 1000);
    tracker.update({ geofence: 'office_001', motionState: 'walking' }, 2000);

    const exported = tracker.exportJson();
    const parsed = JSON.parse(exported);

    // Verify export structure
    assertDefined(parsed.current, 'should have current');
    assertDefined(parsed.previous, 'should have previous');
    assertDefined(parsed.routeCounts, 'should have routeCounts');
    assertTrue(parsed.hasTransition, 'should have transition');

    // Import into new tracker
    const tracker2 = new StateTransitionTracker();
    tracker2.importJson(exported);

    // Verify state restored
    const ctx = {};
    tracker2.injectFeatures(ctx);
    assertEqual(ctx.prev_geofence, '1', 'restored prev_geofence');
    assertEqual(ctx.geofence_changed, '1', 'restored geofence_changed');
  });

  it('routine counts 持久化', function () {
    const tracker = new StateTransitionTracker();
    const baseTime = new Date(2026, 2, 2, 8, 0, 0).getTime();

    for (let i = 0; i < 3; i++) {
      tracker.update({ geofence: 'home_001', motionState: 'stationary' }, baseTime + i * 86400000);
      tracker.update({ geofence: 'office_001', motionState: 'walking' }, baseTime + i * 86400000 + 45 * 60000);
    }

    const exported = tracker.exportJson();
    const tracker2 = new StateTransitionTracker();
    tracker2.importJson(exported);

    // Verify routine counts survive
    const ctx = {};
    tracker2.injectFeatures(ctx);
    assertEqual(ctx.is_routine_transition, '1', 'routine should survive persistence');
  });

  it('空 JSON → 不崩溃', function () {
    const tracker = new StateTransitionTracker();
    tracker.importJson('{}');
    // Should not throw
    const json = tracker.getTransitionJson();
    assertEqual(json, '{}', 'should handle empty import');
  });
});

describe('StateTransitionTracker - Geofence 图标和标签', function () {
  it('home → 🏠 家', function () {
    assertEqual(geofenceIcon('home_001'), '🏠');
    assertEqual(geofenceLabel('home_001'), '家');
  });

  it('office → 🏢 办公室', function () {
    assertEqual(geofenceIcon('office_001'), '🏢');
    assertEqual(geofenceLabel('office_001'), '办公室');
  });

  it('gym → 💪 健身房', function () {
    assertEqual(geofenceIcon('gym_001'), '💪');
    assertEqual(geofenceLabel('gym_001'), '健身房');
  });

  it('hospital → 🏥 医院', function () {
    assertEqual(geofenceIcon('hospital_001'), '🏥');
    assertEqual(geofenceLabel('hospital_001'), '医院');
  });

  it('unknown → 📍', function () {
    assertEqual(geofenceIcon('random_place'), '📍');
    assertEqual(geofenceLabel('random_place'), 'random_place');
  });
});

describe('StateTransitionTracker - transitions_last_hour', function () {
  it('多次转移 → 正确计数', function () {
    const tracker = new StateTransitionTracker();
    const now = Date.now();

    // 5 transitions within 1 hour
    const states = ['home_001', 'office_001', 'cafe_001', 'office_001', 'home_001', 'gym_001'];
    for (let i = 0; i < states.length; i++) {
      tracker.update({ geofence: states[i], motionState: 'walking' }, now + i * 10 * 60000);
    }

    const ctx = {};
    tracker.injectFeatures(ctx);

    // 5 transitions (the first update is init, not counted as transition)
    const transCount = parseFloat(ctx.transitions_last_hour);
    assertTrue(transCount > 0, 'should have transitions');
    assertTrue(transCount <= 1.0, 'should be capped at 1.0');
  });
});
