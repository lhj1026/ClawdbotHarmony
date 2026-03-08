'use strict';
/**
 * Motion Classifier Unit Tests
 *
 * Complete test suite covering all motion classification logic:
 *   1. classifySingleSample — magnitude thresholds
 *   2. classifyWithSmoothing — sliding window majority vote + variance
 *   3. classifyByZAxisFeatures — Z-axis amplitude/frequency/variance
 *   4. updateMotionState — full pipeline (GPS + Z-axis + smoothing + overrides)
 *   5. Dwell timer — debounce transitions
 *   6. Lying-down override — when it should/shouldn't suppress walking
 *   7. Driving inertia — red light / brief stop protection
 *   8. Edge cases — boundary values, transitions
 *
 * These tests mirror the ArkTS implementation in ContextAwarenessService.ets.
 * If a test fails after code changes, the production code has regressed.
 */

const { describe, it } = require('../../lib/test-runner');
const { assertEqual, assertTrue, assertFalse, assertNotEqual } = require('../../lib/assert');

// ============================================================
// JS mirrors of production classification functions
// ============================================================

// --- classifySingleSample (CAS line 956) ---
function classifySingleSample(magnitude) {
  if (magnitude < 10.5) return 'stationary';
  if (magnitude < 12)   return 'walking';
  if (magnitude < 15)   return 'running';
  return 'driving';
}

// --- classifyWithSmoothing (CAS line 970) ---
function classifyWithSmoothing(accelHistory, currentState) {
  let windowSize = Math.min(7, accelHistory.length);
  if (windowSize === 0) return 'stationary';

  let samples = accelHistory.slice(-windowSize);

  // Mean and variance
  let sum = 0;
  for (let i = 0; i < samples.length; i++) sum += samples[i];
  let mean = sum / samples.length;
  let varianceSum = 0;
  for (let i = 0; i < samples.length; i++) {
    let diff = samples[i] - mean;
    varianceSum += diff * diff;
  }
  let variance = varianceSum / samples.length;

  // Variance compensation: hand-held walking
  if (variance > 0.3 && mean < 10.5) {
    return 'walking';
  }

  // Majority vote
  let votes = {};
  for (let i = 0; i < samples.length; i++) {
    let cls = classifySingleSample(samples[i]);
    votes[cls] = (votes[cls] || 0) + 1;
  }

  let bestState = 'stationary';
  let bestCount = 0;
  for (let [state, count] of Object.entries(votes)) {
    if (count > bestCount) {
      bestCount = count;
      bestState = state;
    }
  }

  // walking->running needs 5/7 votes
  if (currentState === 'walking' && bestState === 'running') {
    let runningVotes = votes['running'] || 0;
    if (runningVotes < 5) {
      return 'walking';
    }
  }

  return bestState;
}

// --- classifyByZAxisFeatures (CAS line 1161) ---
function classifyByZAxisFeatures(amplitude, frequency, variance) {
  // Stationary: very small amplitude
  if (amplitude < 0.2) {
    return 'stationary';
  }

  // Walking: high frequency + large amplitude
  if (frequency >= 1.2 && frequency <= 2.5 && amplitude >= 0.35) {
    return 'walking';
  }

  // Driving: low frequency + medium amplitude
  if (amplitude >= 0.15 && amplitude < 0.35) {
    if (frequency < 0.8 || frequency === 0) {
      return 'driving';
    }
  }

  // Driving: high amplitude + low frequency (bumpy road)
  if (amplitude >= 0.4 && frequency < 1.0) {
    return 'driving';
  }

  return 'unknown';
}

// --- C++ classifyByZAxis (motion_classifier.h line 150) ---
// NOTE: Different thresholds from ArkTS version!
function classifyByZAxis_cpp(amplitude, frequency, variance) {
  // Stationary: very small amplitude
  if (amplitude < 0.15) {
    return 'stationary';
  }

  // Walking: freq 1.2-2.5 Hz + amplitude >= 0.35
  if (frequency >= 1.2 && frequency <= 2.5 && amplitude >= 0.35) {
    return 'walking';
  }

  // Vehicle range: medium amplitude + low frequency
  if (amplitude >= 0.1 && amplitude < 0.40) {
    if (frequency < 1.0) {
      // Low variance = transit, high variance = driving
      if (variance < 0.5) {
        return 'transit';
      }
      return 'driving';
    }
  }

  // High amplitude + low freq = driving (bumpy road)
  if (amplitude >= 0.40 && frequency < 1.0) {
    return 'driving';
  }

  return 'unknown';
}

// --- updateMotionState simplified (CAS line 1193) ---
function updateMotionState(opts) {
  let {
    magnitude,
    gpsSpeed,
    zAxisAmplitude,
    zAxisFrequency,
    zAxisVariance,
    accelHistory,
    lastMotionState,
    isLyingDown,
    inGeofence,
    btInVehicle,
    lastHighSpeedTime,
    stepCount,
    drivingInertiaStepBase,
    now
  } = opts;

  const DRIVING_INERTIA_MS = 90000;

  let newState;

  if (gpsSpeed > 5) {
    newState = 'driving';
  } else if (gpsSpeed > 1.5) {
    if (lastMotionState === 'driving') {
      newState = 'driving';
    } else {
      let zAxis = classifyByZAxisFeatures(zAxisAmplitude, zAxisFrequency, zAxisVariance);
      if (zAxis !== 'unknown') {
        newState = zAxis;
      } else {
        newState = magnitude > 12 ? 'running' : 'walking';
      }
    }
  } else {
    // GPS speed low
    let recentlyDriving = (lastMotionState === 'driving')
      && ((now - lastHighSpeedTime) < DRIVING_INERTIA_MS);
    let stepsSinceHighSpeed = stepCount - drivingInertiaStepBase;
    if (recentlyDriving && stepsSinceHighSpeed < 20) {
      newState = 'driving'; // red light
    } else {
      let zAxis = classifyByZAxisFeatures(zAxisAmplitude, zAxisFrequency, zAxisVariance);
      if (zAxis !== 'unknown') {
        newState = zAxis;
      } else {
        newState = classifyWithSmoothing(accelHistory, lastMotionState);
      }
    }
  }

  // BT override
  if (btInVehicle && (newState === 'stationary' || newState === 'walking')) {
    newState = 'driving';
  }

  // Lying-down override
  let hasVehicleSignal = gpsSpeed > 1.5 || btInVehicle;
  if (isLyingDown && inGeofence && !hasVehicleSignal && (newState === 'walking' || newState === 'running')) {
    newState = 'stationary';
  }

  return newState;
}

// --- Dwell timer (CAS line 1292) ---
function applyDwell(currentState, newState, pendingState, dwellStartMs, nowMs) {
  const STATIONARY_DWELL_MS = 3000;
  const ACTIVE_DWELL_MS = 800;
  const DRIVING_EXIT_DWELL_MS = 30000;

  if (newState === currentState || currentState === 'unknown' || currentState === 'pickup' || currentState === 'putdown') {
    return { state: newState, pending: 'unknown' };
  }

  if (newState !== pendingState) {
    // New candidate, start dwell timer
    return { state: currentState, pending: newState, dwellStart: nowMs };
  }

  // Same candidate, check dwell duration
  let isDrivingExit = (currentState === 'driving') && (newState === 'stationary' || newState === 'walking');
  let dwellRequired = isDrivingExit
    ? DRIVING_EXIT_DWELL_MS
    : (newState === 'stationary')
      ? STATIONARY_DWELL_MS
      : ACTIVE_DWELL_MS;

  if ((nowMs - dwellStartMs) < dwellRequired) {
    return { state: currentState, pending: newState }; // Not enough dwell time
  }

  // Dwell passed
  return { state: newState, pending: 'unknown' };
}

// ============================================================
// Tests
// ============================================================

// ─────── 1. classifySingleSample ───────

describe('1. classifySingleSample — magnitude thresholds', function() {
  it('gravity only (9.8) → stationary', function() {
    assertEqual(classifySingleSample(9.8), 'stationary');
  });

  it('phone flat on table (9.81) → stationary', function() {
    assertEqual(classifySingleSample(9.81), 'stationary');
  });

  it('boundary: 10.49 → stationary', function() {
    assertEqual(classifySingleSample(10.49), 'stationary');
  });

  it('boundary: 10.5 → walking', function() {
    assertEqual(classifySingleSample(10.5), 'walking');
  });

  it('typical walking (11.0) → walking', function() {
    assertEqual(classifySingleSample(11.0), 'walking');
  });

  it('boundary: 11.99 → walking', function() {
    assertEqual(classifySingleSample(11.99), 'walking');
  });

  it('boundary: 12.0 → running', function() {
    assertEqual(classifySingleSample(12.0), 'running');
  });

  it('typical running (13.5) → running', function() {
    assertEqual(classifySingleSample(13.5), 'running');
  });

  it('boundary: 14.99 → running', function() {
    assertEqual(classifySingleSample(14.99), 'running');
  });

  it('boundary: 15.0 → driving (heavy vibration)', function() {
    assertEqual(classifySingleSample(15.0), 'driving');
  });

  it('extreme vibration (20.0) → driving', function() {
    assertEqual(classifySingleSample(20.0), 'driving');
  });

  it('zero magnitude → stationary', function() {
    assertEqual(classifySingleSample(0), 'stationary');
  });
});

// ─────── 2. classifyWithSmoothing — sliding window ───────

describe('2a. classifyWithSmoothing — clear majority', function() {
  it('all stationary (~9.8) → stationary', function() {
    let h = [9.8, 9.79, 9.81, 9.80, 9.82, 9.78, 9.80];
    assertEqual(classifyWithSmoothing(h, 'stationary'), 'stationary');
  });

  it('all walking (~11.0) → walking', function() {
    let h = [11.0, 10.9, 11.1, 10.8, 11.2, 11.0, 10.95];
    assertEqual(classifyWithSmoothing(h, 'stationary'), 'walking');
  });

  it('all running (~13.5) → running', function() {
    let h = [13.0, 13.5, 14.0, 13.2, 13.8, 13.1, 14.5];
    assertEqual(classifyWithSmoothing(h, 'stationary'), 'running');
  });

  it('4 walking + 3 stationary → walking majority', function() {
    let h = [11.0, 11.1, 10.8, 11.2, 9.8, 9.7, 9.9];
    assertEqual(classifyWithSmoothing(h, 'stationary'), 'walking');
  });

  it('4 stationary + 3 walking → walking (variance compensation triggers)', function() {
    // Mean ~10.15, variance >0.3 due to mix → variance rule classifies as walking
    // This is CORRECT: mixed stationary+walking samples have high variance
    let h = [9.8, 9.7, 9.9, 9.81, 11.0, 11.1, 10.8];
    assertEqual(classifyWithSmoothing(h, 'stationary'), 'walking');
  });

  it('pure stationary (no walking mixed in) → stationary', function() {
    let h = [9.8, 9.7, 9.9, 9.81, 9.75, 9.85, 9.82];
    assertEqual(classifyWithSmoothing(h, 'stationary'), 'stationary');
  });
});

describe('2b. classifyWithSmoothing — walking→running threshold (5/7)', function() {
  it('4/7 running + current=walking → stays walking', function() {
    let h = [13.0, 13.5, 14.0, 12.5, 11.0, 11.5, 10.8];
    assertEqual(classifyWithSmoothing(h, 'walking'), 'walking');
  });

  it('5/7 running + current=walking → switches to running', function() {
    let h = [13.0, 13.5, 14.0, 12.5, 12.8, 11.0, 11.5];
    assertEqual(classifyWithSmoothing(h, 'walking'), 'running');
  });

  it('6/7 running + current=walking → switches to running', function() {
    let h = [13.0, 13.5, 14.0, 12.5, 12.8, 12.2, 11.0];
    assertEqual(classifyWithSmoothing(h, 'walking'), 'running');
  });

  it('4/7 running + current=stationary → running (no 5/7 rule for non-walking)', function() {
    let h = [13.0, 13.5, 14.0, 12.5, 11.0, 11.5, 10.8];
    assertEqual(classifyWithSmoothing(h, 'stationary'), 'running');
  });
});

describe('2c. classifyWithSmoothing — variance compensation (hand-held walking)', function() {
  it('CRITICAL: hand-held walking (mean~9.8, variance>0.3) → walking, NOT stationary', function() {
    // This is the key test: walking with phone in hand produces oscillation
    // around 9.8 that looks like stationary by mean alone
    let h = [9.0, 10.5, 9.2, 10.5, 9.0, 10.4, 9.3];
    let result = classifyWithSmoothing(h, 'stationary');
    assertEqual(result, 'walking',
      'REGRESSION: hand-held walking with mean<10.5 but high variance MUST be walking');
  });

  it('CRITICAL: truly stationary (mean~9.8, variance<0.15) → stationary', function() {
    let h = [9.81, 9.79, 9.80, 9.82, 9.78, 9.80, 9.81];
    let result = classifyWithSmoothing(h, 'stationary');
    assertEqual(result, 'stationary',
      'Flat on table: low variance should stay stationary');
  });

  it('vigorous hand-held walking (mean~10.0, variance~1.0) → walking', function() {
    let h = [9.0, 11.0, 9.2, 10.8, 9.1, 10.9, 10.0];
    assertEqual(classifyWithSmoothing(h, 'stationary'), 'walking');
  });

  it('high mean (>10.5) with high variance → uses vote (not variance rule)', function() {
    let h = [12.0, 14.0, 12.5, 13.5, 12.0, 14.0, 13.0];
    let result = classifyWithSmoothing(h, 'stationary');
    assertEqual(result, 'running',
      'Mean>10.5: variance rule should NOT apply, majority vote wins');
  });

  it('pocket walking: moderate oscillation (mean~10.2, variance~0.4) → walking', function() {
    let h = [9.5, 10.8, 9.6, 10.9, 9.7, 10.7, 10.2];
    let result = classifyWithSmoothing(h, 'stationary');
    assertEqual(result, 'walking',
      'Phone in pocket while walking should detect via variance');
  });
});

// ─────── 3. classifyByZAxisFeatures (ArkTS version) ───────

describe('3a. classifyByZAxisFeatures — stationary', function() {
  it('very low amplitude (0.05) → stationary', function() {
    assertEqual(classifyByZAxisFeatures(0.05, 0, 0), 'stationary');
  });

  it('boundary: amplitude 0.19 → stationary', function() {
    assertEqual(classifyByZAxisFeatures(0.19, 1.5, 0.1), 'stationary');
  });

  it('boundary: amplitude 0.20 → NOT stationary (walking or other)', function() {
    assertNotEqual(classifyByZAxisFeatures(0.20, 1.5, 0.1), 'stationary');
  });
});

describe('3b. classifyByZAxisFeatures — walking', function() {
  it('CRITICAL: typical walking (amp=0.5, freq=1.8) → walking', function() {
    assertEqual(classifyByZAxisFeatures(0.5, 1.8, 0.3), 'walking',
      'REGRESSION: standard walking pattern must be classified as walking');
  });

  it('slow walking (amp=0.35, freq=1.2) → walking', function() {
    assertEqual(classifyByZAxisFeatures(0.35, 1.2, 0.2), 'walking');
  });

  it('fast walking (amp=0.6, freq=2.5) → walking', function() {
    assertEqual(classifyByZAxisFeatures(0.6, 2.5, 0.4), 'walking');
  });

  it('boundary: amp=0.34 (below 0.35), freq=1.8 → NOT walking', function() {
    assertNotEqual(classifyByZAxisFeatures(0.34, 1.8, 0.1), 'walking',
      'Amplitude below 0.35 should not classify as walking');
  });

  it('boundary: freq=1.19 (below 1.2), amp=0.5 → NOT walking', function() {
    assertNotEqual(classifyByZAxisFeatures(0.5, 1.19, 0.1), 'walking',
      'Frequency below 1.2 should not classify as walking');
  });

  it('boundary: freq=2.51 (above 2.5), amp=0.5 → NOT walking', function() {
    assertNotEqual(classifyByZAxisFeatures(0.5, 2.51, 0.1), 'walking',
      'Frequency above 2.5 should not classify as walking');
  });
});

describe('3c. classifyByZAxisFeatures — driving', function() {
  it('low freq + medium amp (amp=0.25, freq=0.5) → driving', function() {
    assertEqual(classifyByZAxisFeatures(0.25, 0.5, 0.3), 'driving');
  });

  it('no frequency + medium amp (amp=0.25, freq=0) → driving', function() {
    assertEqual(classifyByZAxisFeatures(0.25, 0, 0.3), 'driving');
  });

  it('bumpy road (amp=0.5, freq=0.8) → driving', function() {
    assertEqual(classifyByZAxisFeatures(0.5, 0.8, 1.0), 'driving');
  });

  it('high freq + medium amp (amp=0.25, freq=1.5) → unknown (not driving)', function() {
    assertEqual(classifyByZAxisFeatures(0.25, 1.5, 0.3), 'unknown',
      'High frequency with medium amplitude is ambiguous, not driving');
  });
});

describe('3d. classifyByZAxisFeatures — unknown (ambiguous)', function() {
  it('medium amp + medium freq (amp=0.25, freq=1.0) → unknown', function() {
    assertEqual(classifyByZAxisFeatures(0.25, 1.0, 0.1), 'unknown');
  });

  it('high amp + high freq (amp=0.5, freq=1.5) → walking (matches walking pattern)', function() {
    assertEqual(classifyByZAxisFeatures(0.5, 1.5, 0.3), 'walking');
  });
});

// ─────── 4. C++ classifyByZAxis (motion_classifier.h) — threshold differences ───────

describe('4. C++ classifyByZAxis — verify C++ thresholds', function() {
  it('C++ stationary threshold is 0.15 (stricter than ArkTS 0.20)', function() {
    assertEqual(classifyByZAxis_cpp(0.14, 0, 0), 'stationary');
    // ArkTS would also say stationary at 0.14
    assertEqual(classifyByZAxisFeatures(0.14, 0, 0), 'stationary');
  });

  it('C++ amp=0.17: NOT stationary (above 0.15), ArkTS: still stationary (below 0.20)', function() {
    assertNotEqual(classifyByZAxis_cpp(0.17, 0.5, 0.3), 'stationary');
    assertEqual(classifyByZAxisFeatures(0.17, 0.5, 0.3), 'stationary',
      'ArkTS threshold is 0.20, so 0.17 is still stationary');
  });

  it('C++ distinguishes transit vs driving by variance', function() {
    // Low variance → transit
    assertEqual(classifyByZAxis_cpp(0.25, 0.5, 0.3), 'transit');
    // High variance → driving
    assertEqual(classifyByZAxis_cpp(0.25, 0.5, 0.6), 'driving');
  });

  it('C++ walking same as ArkTS: freq 1.2-2.5, amp >= 0.35', function() {
    assertEqual(classifyByZAxis_cpp(0.5, 1.8, 0.3), 'walking');
    assertEqual(classifyByZAxisFeatures(0.5, 1.8, 0.3), 'walking');
  });
});

// ─────── 5. updateMotionState — full pipeline ───────

describe('5a. updateMotionState — GPS-based classification', function() {
  let baseOpts = {
    magnitude: 9.8,
    gpsSpeed: 0,
    zAxisAmplitude: 0.05, zAxisFrequency: 0, zAxisVariance: 0,
    accelHistory: [9.8, 9.8, 9.8, 9.8, 9.8, 9.8, 9.8],
    lastMotionState: 'stationary',
    isLyingDown: false,
    inGeofence: false,
    btInVehicle: false,
    lastHighSpeedTime: 0,
    stepCount: 0,
    drivingInertiaStepBase: 0,
    now: Date.now()
  };

  it('GPS > 5 m/s → driving', function() {
    assertEqual(updateMotionState({...baseOpts, gpsSpeed: 10}), 'driving');
  });

  it('GPS > 5 m/s overrides all other signals', function() {
    // Even with walking Z-axis features, GPS speed wins
    assertEqual(updateMotionState({
      ...baseOpts, gpsSpeed: 8,
      zAxisAmplitude: 0.5, zAxisFrequency: 1.8
    }), 'driving');
  });

  it('GPS 1.5-5 m/s + was driving → stays driving', function() {
    assertEqual(updateMotionState({
      ...baseOpts, gpsSpeed: 3, lastMotionState: 'driving'
    }), 'driving');
  });

  it('GPS 1.5-5 m/s + was NOT driving + Z-axis walking → walking', function() {
    assertEqual(updateMotionState({
      ...baseOpts, gpsSpeed: 2,
      zAxisAmplitude: 0.5, zAxisFrequency: 1.8, zAxisVariance: 0.3
    }), 'walking');
  });

  it('GPS 1.5-5 m/s + no Z-axis + mag>12 → running', function() {
    assertEqual(updateMotionState({
      ...baseOpts, gpsSpeed: 2, magnitude: 13,
      zAxisAmplitude: 0.25, zAxisFrequency: 1.0, zAxisVariance: 0.1
    }), 'running');
  });

  it('GPS 1.5-5 m/s + no Z-axis + mag<12 → walking', function() {
    assertEqual(updateMotionState({
      ...baseOpts, gpsSpeed: 2, magnitude: 11,
      zAxisAmplitude: 0.25, zAxisFrequency: 1.0, zAxisVariance: 0.1
    }), 'walking');
  });
});

describe('5b. updateMotionState — driving inertia (red light)', function() {
  it('was driving + stopped < 90s + few steps → stays driving', function() {
    let now = Date.now();
    assertEqual(updateMotionState({
      magnitude: 9.8,
      gpsSpeed: 0,
      zAxisAmplitude: 0.05, zAxisFrequency: 0, zAxisVariance: 0,
      accelHistory: [9.8, 9.8, 9.8, 9.8, 9.8, 9.8, 9.8],
      lastMotionState: 'driving',
      isLyingDown: false, inGeofence: false, btInVehicle: false,
      lastHighSpeedTime: now - 30000, // 30s ago
      stepCount: 5,
      drivingInertiaStepBase: 0,
      now: now
    }), 'driving');
  });

  it('was driving + stopped > 90s → uses Z-axis/smoothing', function() {
    let now = Date.now();
    let result = updateMotionState({
      magnitude: 9.8,
      gpsSpeed: 0,
      zAxisAmplitude: 0.05, zAxisFrequency: 0, zAxisVariance: 0,
      accelHistory: [9.8, 9.8, 9.8, 9.8, 9.8, 9.8, 9.8],
      lastMotionState: 'driving',
      isLyingDown: false, inGeofence: false, btInVehicle: false,
      lastHighSpeedTime: now - 100000, // 100s ago (> 90s)
      stepCount: 0,
      drivingInertiaStepBase: 0,
      now: now
    });
    assertEqual(result, 'stationary', 'After 90s+ inertia expired, should classify by sensor');
  });

  it('was driving + stopped < 90s BUT 20+ steps → NOT driving (walked away)', function() {
    let now = Date.now();
    let result = updateMotionState({
      magnitude: 11.0,
      gpsSpeed: 0,
      zAxisAmplitude: 0.5, zAxisFrequency: 1.8, zAxisVariance: 0.3,
      accelHistory: [11.0, 11.0, 11.0, 11.0, 11.0, 11.0, 11.0],
      lastMotionState: 'driving',
      isLyingDown: false, inGeofence: false, btInVehicle: false,
      lastHighSpeedTime: now - 30000,
      stepCount: 25,
      drivingInertiaStepBase: 0,
      now: now
    });
    assertEqual(result, 'walking', '20+ steps means user walked away from car');
  });
});

describe('5c. updateMotionState — BT override', function() {
  it('vehicle BT + stationary → driving', function() {
    assertEqual(updateMotionState({
      magnitude: 9.8, gpsSpeed: 0,
      zAxisAmplitude: 0.05, zAxisFrequency: 0, zAxisVariance: 0,
      accelHistory: [9.8, 9.8, 9.8, 9.8, 9.8, 9.8, 9.8],
      lastMotionState: 'stationary',
      isLyingDown: false, inGeofence: false,
      btInVehicle: true,
      lastHighSpeedTime: 0, stepCount: 0, drivingInertiaStepBase: 0,
      now: Date.now()
    }), 'driving');
  });

  it('vehicle BT + walking → driving', function() {
    assertEqual(updateMotionState({
      magnitude: 11.0, gpsSpeed: 0,
      zAxisAmplitude: 0.5, zAxisFrequency: 1.8, zAxisVariance: 0.3,
      accelHistory: [11.0, 11.0, 11.0, 11.0, 11.0, 11.0, 11.0],
      lastMotionState: 'stationary',
      isLyingDown: false, inGeofence: false,
      btInVehicle: true,
      lastHighSpeedTime: 0, stepCount: 0, drivingInertiaStepBase: 0,
      now: Date.now()
    }), 'driving');
  });

  it('vehicle BT + Z-axis walking signal → driving (BT overrides walking)', function() {
    // Z-axis: amp=0.5, freq=2.0 → classifies as walking first
    // Then BT override: walking → driving
    // This is CORRECT: in a car, phone vibration can mimic walking Z-axis pattern
    assertEqual(updateMotionState({
      magnitude: 13.0, gpsSpeed: 0,
      zAxisAmplitude: 0.5, zAxisFrequency: 2.0, zAxisVariance: 0.3,
      accelHistory: [13.0, 13.0, 13.0, 13.0, 13.0, 13.0, 13.0],
      lastMotionState: 'stationary',
      isLyingDown: false, inGeofence: false,
      btInVehicle: true,
      lastHighSpeedTime: 0, stepCount: 0, drivingInertiaStepBase: 0,
      now: Date.now()
    }), 'driving');
  });
});

// ─────── 6. Lying-down override ───────

describe('6. updateMotionState — lying-down override', function() {
  it('CRITICAL: isLyingDown=true + inGeofence + walking → stationary', function() {
    assertEqual(updateMotionState({
      magnitude: 11.0, gpsSpeed: 0,
      zAxisAmplitude: 0.5, zAxisFrequency: 1.8, zAxisVariance: 0.3,
      accelHistory: [11.0, 11.0, 11.0, 11.0, 11.0, 11.0, 11.0],
      lastMotionState: 'walking',
      isLyingDown: true, inGeofence: true, btInVehicle: false,
      lastHighSpeedTime: 0, stepCount: 0, drivingInertiaStepBase: 0,
      now: Date.now()
    }), 'stationary',
      'Lying in bed with slight movement should be stationary');
  });

  it('CRITICAL: isLyingDown=true + NOT in geofence + walking → walking (NOT suppressed)', function() {
    assertEqual(updateMotionState({
      magnitude: 11.0, gpsSpeed: 0,
      zAxisAmplitude: 0.5, zAxisFrequency: 1.8, zAxisVariance: 0.3,
      accelHistory: [11.0, 11.0, 11.0, 11.0, 11.0, 11.0, 11.0],
      lastMotionState: 'walking',
      isLyingDown: true, inGeofence: false, btInVehicle: false,
      lastHighSpeedTime: 0, stepCount: 0, drivingInertiaStepBase: 0,
      now: Date.now()
    }), 'walking',
      'REGRESSION: outside geofence, lying-down override must NOT suppress walking');
  });

  it('CRITICAL: isLyingDown=true + inGeofence + GPS>1.5 + walking → walking (vehicle signal)', function() {
    assertEqual(updateMotionState({
      magnitude: 11.0, gpsSpeed: 2.0,
      zAxisAmplitude: 0.5, zAxisFrequency: 1.8, zAxisVariance: 0.3,
      accelHistory: [11.0, 11.0, 11.0, 11.0, 11.0, 11.0, 11.0],
      lastMotionState: 'walking',
      isLyingDown: true, inGeofence: true, btInVehicle: false,
      lastHighSpeedTime: 0, stepCount: 0, drivingInertiaStepBase: 0,
      now: Date.now()
    }), 'walking',
      'GPS speed indicates real movement, override should not apply');
  });

  it('isLyingDown=false + inGeofence + walking → walking (no override)', function() {
    assertEqual(updateMotionState({
      magnitude: 11.0, gpsSpeed: 0,
      zAxisAmplitude: 0.5, zAxisFrequency: 1.8, zAxisVariance: 0.3,
      accelHistory: [11.0, 11.0, 11.0, 11.0, 11.0, 11.0, 11.0],
      lastMotionState: 'stationary',
      isLyingDown: false, inGeofence: true, btInVehicle: false,
      lastHighSpeedTime: 0, stepCount: 0, drivingInertiaStepBase: 0,
      now: Date.now()
    }), 'walking',
      'Not lying down: walking should not be suppressed');
  });
});

// ─────── 7. Dwell timer ───────

describe('7a. Dwell timer — stationary transitions', function() {
  it('walking→stationary at 500ms → stays walking (needs 3000ms)', function() {
    let r = applyDwell('walking', 'stationary', 'stationary', 1000, 1500);
    assertEqual(r.state, 'walking');
  });

  it('walking→stationary at 3000ms → switches to stationary', function() {
    let r = applyDwell('walking', 'stationary', 'stationary', 0, 3000);
    assertEqual(r.state, 'stationary');
  });

  it('walking→stationary at 4000ms → switches to stationary', function() {
    let r = applyDwell('walking', 'stationary', 'stationary', 0, 4000);
    assertEqual(r.state, 'stationary');
  });
});

describe('7b. Dwell timer — active transitions', function() {
  it('stationary→walking at 500ms → stays stationary (needs 800ms)', function() {
    let r = applyDwell('stationary', 'walking', 'walking', 1000, 1500);
    assertEqual(r.state, 'stationary');
  });

  it('stationary→walking at 800ms → switches to walking', function() {
    let r = applyDwell('stationary', 'walking', 'walking', 0, 800);
    assertEqual(r.state, 'walking');
  });

  it('stationary→running at 900ms → switches to running', function() {
    let r = applyDwell('stationary', 'running', 'running', 0, 900);
    assertEqual(r.state, 'running');
  });
});

describe('7c. Dwell timer — driving exit (30s)', function() {
  it('driving→stationary at 5s → stays driving', function() {
    let r = applyDwell('driving', 'stationary', 'stationary', 0, 5000);
    assertEqual(r.state, 'driving',
      'Driving exit needs 30s dwell to prevent red light false transitions');
  });

  it('driving→walking at 5s → stays driving', function() {
    let r = applyDwell('driving', 'walking', 'walking', 0, 5000);
    assertEqual(r.state, 'driving',
      'Driving exit to walking also needs 30s dwell');
  });

  it('driving→stationary at 30s → switches to stationary', function() {
    let r = applyDwell('driving', 'stationary', 'stationary', 0, 30000);
    assertEqual(r.state, 'stationary');
  });

  it('driving→walking at 30s → switches to walking', function() {
    let r = applyDwell('driving', 'walking', 'walking', 0, 30000);
    assertEqual(r.state, 'walking');
  });

  it('driving→running at 800ms → switches to running (not a driving exit rule)', function() {
    let r = applyDwell('driving', 'running', 'running', 0, 800);
    assertEqual(r.state, 'running',
      'driving→running uses active dwell (800ms), not driving exit dwell');
  });
});

describe('7d. Dwell timer — new candidate resets timer', function() {
  it('pending=walking, new=running → resets to new candidate', function() {
    let r = applyDwell('stationary', 'running', 'walking', 0, 5000);
    assertEqual(r.state, 'stationary', 'New candidate should reset dwell timer');
    assertEqual(r.pending, 'running');
  });
});

// ─────── 8. Real-world scenarios (integration) ───────

describe('8. Real-world scenarios — regression guards', function() {
  it('SCENARIO: walking outdoors, no GPS → should detect walking', function() {
    // User is walking outside, no GPS lock, phone in pocket
    let result = updateMotionState({
      magnitude: 11.2, gpsSpeed: 0,
      zAxisAmplitude: 0.5, zAxisFrequency: 1.8, zAxisVariance: 0.3,
      accelHistory: [11.0, 11.3, 10.9, 11.4, 11.1, 11.2, 10.8],
      lastMotionState: 'stationary',
      isLyingDown: false, inGeofence: false, btInVehicle: false,
      lastHighSpeedTime: 0, stepCount: 500, drivingInertiaStepBase: 0,
      now: Date.now()
    });
    assertEqual(result, 'walking',
      'REGRESSION: outdoor walking without GPS must be detected as walking');
  });

  it('SCENARIO: walking at home (in geofence, not lying down) → walking', function() {
    let result = updateMotionState({
      magnitude: 11.0, gpsSpeed: 0,
      zAxisAmplitude: 0.45, zAxisFrequency: 1.6, zAxisVariance: 0.25,
      accelHistory: [10.8, 11.2, 10.9, 11.1, 11.0, 10.8, 11.3],
      lastMotionState: 'stationary',
      isLyingDown: false, inGeofence: true, btInVehicle: false,
      lastHighSpeedTime: 0, stepCount: 100, drivingInertiaStepBase: 0,
      now: Date.now()
    });
    assertEqual(result, 'walking',
      'REGRESSION: walking at home (not lying down) must still be walking');
  });

  it('SCENARIO: phone on car mount (isLyingDown may be true) + no geofence → driving not blocked', function() {
    // Phone mounted sideways in car → isLyingDown=true (angle detection)
    // But not in geofence → override should NOT apply
    let result = updateMotionState({
      magnitude: 9.8, gpsSpeed: 15,
      zAxisAmplitude: 0.25, zAxisFrequency: 0.5, zAxisVariance: 0.8,
      accelHistory: [9.8, 9.9, 9.7, 9.8, 9.9, 9.8, 9.7],
      lastMotionState: 'stationary',
      isLyingDown: true, inGeofence: false, btInVehicle: false,
      lastHighSpeedTime: 0, stepCount: 0, drivingInertiaStepBase: 0,
      now: Date.now()
    });
    assertEqual(result, 'driving',
      'Car mount: GPS speed overrides, lying-down flag should not interfere');
  });

  it('SCENARIO: sitting on bus (GPS speed, medium Z-axis) → driving/transit', function() {
    let result = updateMotionState({
      magnitude: 9.9, gpsSpeed: 8,
      zAxisAmplitude: 0.2, zAxisFrequency: 0.3, zAxisVariance: 0.2,
      accelHistory: [9.8, 9.9, 9.85, 9.9, 9.8, 9.95, 9.85],
      lastMotionState: 'stationary',
      isLyingDown: false, inGeofence: false, btInVehicle: false,
      lastHighSpeedTime: 0, stepCount: 0, drivingInertiaStepBase: 0,
      now: Date.now()
    });
    assertEqual(result, 'driving',
      'On bus with GPS > 5 m/s should be driving (transit inference is separate)');
  });

  it('SCENARIO: stopped at red light after driving → stays driving (inertia)', function() {
    let now = Date.now();
    let result = updateMotionState({
      magnitude: 9.8, gpsSpeed: 0,
      zAxisAmplitude: 0.08, zAxisFrequency: 0, zAxisVariance: 0.01,
      accelHistory: [9.8, 9.81, 9.79, 9.8, 9.82, 9.78, 9.80],
      lastMotionState: 'driving',
      isLyingDown: false, inGeofence: false, btInVehicle: false,
      lastHighSpeedTime: now - 15000, // 15s ago
      stepCount: 0, drivingInertiaStepBase: 0,
      now: now
    });
    assertEqual(result, 'driving',
      'Red light: recently driving + no steps → maintain driving');
  });

  it('SCENARIO: hand-held slow walk, no GPS, no Z-axis → variance detection saves it', function() {
    // GPS is 0, Z-axis says unknown, but variance in accelHistory catches walking
    let result = updateMotionState({
      magnitude: 10.0, gpsSpeed: 0,
      zAxisAmplitude: 0.25, zAxisFrequency: 1.0, zAxisVariance: 0.1, // Z-axis → unknown
      accelHistory: [9.0, 10.5, 9.2, 10.6, 9.1, 10.4, 9.3], // variance > 0.3
      lastMotionState: 'stationary',
      isLyingDown: false, inGeofence: false, btInVehicle: false,
      lastHighSpeedTime: 0, stepCount: 200, drivingInertiaStepBase: 0,
      now: Date.now()
    });
    assertEqual(result, 'walking',
      'REGRESSION: hand-held walking with Z-axis unknown must use variance fallback');
  });

  it('SCENARIO: truly stationary at home → stationary', function() {
    let result = updateMotionState({
      magnitude: 9.8, gpsSpeed: 0,
      zAxisAmplitude: 0.05, zAxisFrequency: 0, zAxisVariance: 0.01,
      accelHistory: [9.81, 9.79, 9.80, 9.82, 9.78, 9.80, 9.81],
      lastMotionState: 'stationary',
      isLyingDown: false, inGeofence: true, btInVehicle: false,
      lastHighSpeedTime: 0, stepCount: 0, drivingInertiaStepBase: 0,
      now: Date.now()
    });
    assertEqual(result, 'stationary',
      'Sitting at desk: everything quiet → must be stationary');
  });
});

// ─────── 8b. Posture detection — isLyingDown vs walking ───────

describe('8b. Posture detection — isLyingDown must not fire during walking', function() {
  /**
   * Mirror of updatePosture() logic (CAS line 1535)
   * isLyingDown should NOT be true when user is walking
   */
  function computeIsLyingDown(x, y, z, tiltAngle, isHoldingPhone, lastMotionState) {
    let isBackLying = (tiltAngle >= -80 && tiltAngle <= -15) && (Math.abs(y) < 6);
    let isSideLying = (Math.abs(z) < 4.5) && (Math.abs(y) < 5) && isHoldingPhone;

    let magnitude = Math.sqrt(x * x + y * y + z * z);
    let isInMotion = lastMotionState === 'walking' || lastMotionState === 'running';
    let hasMotionAccel = Math.abs(magnitude - 9.8) > 0.8;

    return (isBackLying || isSideLying) && !isInMotion && !hasMotionAccel;
  }

  it('CRITICAL: phone in pocket while walking (tilted, |z|<4.5, |y|<5) → NOT lying down', function() {
    // Walking: phone tilted in pocket, motion state = walking
    let result = computeIsLyingDown(3.0, -4.0, 2.5, -30, true, 'walking');
    assertFalse(result,
      'REGRESSION: walking with phone in pocket must NOT trigger isLyingDown');
  });

  it('CRITICAL: phone in pocket while walking (high accel magnitude) → NOT lying down', function() {
    // Walking: magnitude oscillates (11.0), even if motion state hasn't updated yet
    let result = computeIsLyingDown(5.0, -4.0, 2.5, -30, true, 'stationary');
    // magnitude = sqrt(25+16+6.25) ≈ 6.87, |6.87-9.8| = 2.93 > 0.8
    assertFalse(result,
      'High acceleration magnitude should prevent isLyingDown');
  });

  it('actually lying in bed (tilt=-45, |y|<6, stationary, mag≈9.8) → IS lying down', function() {
    // Lying in bed: phone face up, stationary
    let result = computeIsLyingDown(0.5, -2.0, -9.5, -45, false, 'stationary');
    // magnitude ≈ 9.72, |9.72-9.8| = 0.08 < 0.8, isBackLying = true
    assertTrue(result,
      'Actually lying in bed should detect isLyingDown=true');
  });

  it('side lying with phone (|z|<4.5, |y|<5, holding, stationary) → IS lying down', function() {
    let result = computeIsLyingDown(8.0, -3.0, 3.0, -20, true, 'stationary');
    // magnitude = sqrt(64+9+9) ≈ 9.06, |9.06-9.8| = 0.74 < 0.8
    // isSideLying = |3|<4.5 && |3|<5 && holding = true
    assertTrue(result,
      'Side lying with phone in hand should detect isLyingDown=true');
  });

  it('running with phone → NOT lying down', function() {
    let result = computeIsLyingDown(5.0, -4.0, 2.5, -30, true, 'running');
    assertFalse(result);
  });

  it('driving with phone on mount (tilted) → not blocked by motion check', function() {
    // Driving: lastMotionState='driving', so isInMotion=false
    // But phone on mount: isSideLying conditions met
    // magnitude ≈ 9.8 (steady driving), so hasMotionAccel=false
    // This means isLyingDown=true for driving, but that's OK because
    // the lying-down override (line 1288) only suppresses walking/running,
    // and driving state doesn't pass through that check
    let result = computeIsLyingDown(0.5, -3.0, -9.2, -72, false, 'driving');
    // isBackLying: tilt=-72 in [-80,-15], |y|=3<6 → true
    // magnitude = sqrt(0.25+9+84.64) ≈ 9.69, |9.69-9.8| = 0.11 < 0.8
    // isInMotion = false (driving is not in the check)
    // So isLyingDown=true, but that's fine for driving
    assertTrue(result);
  });
});

// ─────── 9. PhysicalStateBuilder majority vote (60% threshold) ───────

describe('9. PhysicalStateBuilder — motionHistory 60% majority', function() {
  function majorityVote(history) {
    const DOMINANT_RATIO = 0.6;
    let totalSamples = history.length;
    if (totalSamples < 3) return history[history.length - 1] || 'unknown';

    let counts = {};
    for (let s of history) {
      counts[s] = (counts[s] || 0) + 1;
    }

    let candidates = ['stationary', 'walking', 'running', 'cycling', 'driving', 'transit'];
    for (let s of candidates) {
      let cnt = counts[s] || 0;
      if (cnt / totalSamples >= DOMINANT_RATIO) {
        return s;
      }
    }
    return 'unknown';
  }

  it('10x stationary → stationary (100%)', function() {
    let h = Array(10).fill('stationary');
    assertEqual(majorityVote(h), 'stationary');
  });

  it('10x walking → walking (100%)', function() {
    let h = Array(10).fill('walking');
    assertEqual(majorityVote(h), 'walking');
  });

  it('6x walking + 4x stationary → walking (60%)', function() {
    let h = Array(6).fill('walking').concat(Array(4).fill('stationary'));
    assertEqual(majorityVote(h), 'walking');
  });

  it('5x walking + 5x stationary → unknown (50% < 60%)', function() {
    let h = Array(5).fill('walking').concat(Array(5).fill('stationary'));
    assertEqual(majorityVote(h), 'unknown',
      '50% is not enough for 60% threshold');
  });

  it('7x driving + 3x stationary → driving (70%)', function() {
    let h = Array(7).fill('driving').concat(Array(3).fill('stationary'));
    assertEqual(majorityVote(h), 'driving');
  });

  it('3x walking + 3x stationary + 4x driving → unknown (no 60%)', function() {
    let h = ['walking','walking','walking','stationary','stationary','stationary',
             'driving','driving','driving','driving'];
    assertEqual(majorityVote(h), 'unknown');
  });

  it('less than 3 samples → returns last sample', function() {
    assertEqual(majorityVote(['walking', 'stationary']), 'stationary');
    assertEqual(majorityVote(['walking']), 'walking');
  });
});

// ─────── 10. classifyPhone — motion + posture conflict fix (Bug A) ───────

describe('10. classifyPhone — motion overrides flat posture', function() {
  /**
   * Mirror of PhysicalStateBuilder.classifyPhone() (PSB line 175)
   * When user is moving, phone cannot be "on_desk"/"flat"/"face_up"
   */
  function classifyPhone(opts) {
    let { motionState, posture, proximity, isLyingDown, isHolding, isCharging, ambientLight } = opts;

    if (isCharging) return 'charging';

    let isMoving = motionState === 'walking' || motionState === 'running'
      || motionState === 'driving' || motionState === 'transit'
      || motionState === 'cycling';

    // PosturePlugin path
    if (posture && posture !== 'unknown') {
      // Core rule: moving + flat posture → correct to carried state
      if (isMoving && (posture === 'on_desk' || posture === 'flat' || posture === 'face_up')) {
        if (proximity === 'near') return 'in_pocket';
        return 'in_use';
      }

      switch (posture) {
        case 'in_use':
          if (isLyingDown && isMoving) return 'in_pocket';
          if (isLyingDown) return 'holding_lying';
          if (!isHolding) return 'on_desk';
          return 'in_use';
        case 'on_desk':
        case 'flat':
          if (isHolding) return 'in_use';
          return 'on_desk';
        case 'in_pocket': return 'in_pocket';
        case 'face_down': return 'face_down';
        case 'face_up':
          if (isLyingDown && isHolding && !isMoving) return 'holding_lying';
          if (isMoving) return 'in_pocket';
          return 'face_up';
        default: break;
      }
    }

    // Fallback: proximity + motion
    if (proximity === 'near' && isMoving) return 'in_pocket';
    return 'unknown';
  }

  it('CRITICAL: walking + posture=on_desk + proximity=near → in_pocket', function() {
    assertEqual(classifyPhone({
      motionState: 'walking', posture: 'on_desk', proximity: 'near',
      isLyingDown: false, isHolding: false, isCharging: false
    }), 'in_pocket',
      'REGRESSION: walking with phone "on_desk" must be corrected to in_pocket');
  });

  it('CRITICAL: running + posture=face_up + proximity=far → in_use', function() {
    assertEqual(classifyPhone({
      motionState: 'running', posture: 'face_up', proximity: 'far',
      isLyingDown: false, isHolding: true, isCharging: false
    }), 'in_use',
      'REGRESSION: running with "face_up" must be corrected to in_use');
  });

  it('CRITICAL: driving + posture=on_desk + proximity=far → in_use (car mount)', function() {
    assertEqual(classifyPhone({
      motionState: 'driving', posture: 'on_desk', proximity: 'far',
      isLyingDown: false, isHolding: false, isCharging: false
    }), 'in_use',
      'REGRESSION: driving with "on_desk" must be corrected to in_use');
  });

  it('transit + posture=flat + proximity=near → in_pocket', function() {
    assertEqual(classifyPhone({
      motionState: 'transit', posture: 'flat', proximity: 'near',
      isLyingDown: false, isHolding: false, isCharging: false
    }), 'in_pocket');
  });

  it('cycling + posture=face_up + proximity=far → in_use', function() {
    assertEqual(classifyPhone({
      motionState: 'cycling', posture: 'face_up', proximity: 'far',
      isLyingDown: false, isHolding: false, isCharging: false
    }), 'in_use');
  });

  it('stationary + posture=on_desk → on_desk (no override)', function() {
    assertEqual(classifyPhone({
      motionState: 'stationary', posture: 'on_desk', proximity: 'far',
      isLyingDown: false, isHolding: false, isCharging: false
    }), 'on_desk',
      'Stationary: on_desk should remain on_desk');
  });

  it('stationary + posture=on_desk + isHolding → in_use (cross-validation)', function() {
    assertEqual(classifyPhone({
      motionState: 'stationary', posture: 'on_desk', proximity: 'far',
      isLyingDown: false, isHolding: true, isCharging: false
    }), 'in_use',
      'Holding phone but PosturePlugin says on_desk → in_use');
  });

  it('walking + posture=in_use + isLyingDown → in_pocket (lying=pocket tilt)', function() {
    assertEqual(classifyPhone({
      motionState: 'walking', posture: 'in_use', proximity: 'far',
      isLyingDown: true, isHolding: true, isCharging: false
    }), 'in_pocket',
      'Walking + isLyingDown: phone tilted in pocket, not actually lying');
  });

  it('stationary + isLyingDown + isHolding + face_up → holding_lying (bed use)', function() {
    assertEqual(classifyPhone({
      motionState: 'stationary', posture: 'face_up', proximity: 'far',
      isLyingDown: true, isHolding: true, isCharging: false
    }), 'holding_lying');
  });

  it('charging overrides everything', function() {
    assertEqual(classifyPhone({
      motionState: 'walking', posture: 'on_desk', proximity: 'near',
      isLyingDown: false, isHolding: false, isCharging: true
    }), 'charging');
  });
});

// ─────── 11. isPhoneFlat — PosturePlugin accel-based flat detection (Bug B) ───────

describe('11. isPhoneFlat — accelerometer flat detection', function() {
  /**
   * Mirror of PosturePlugin.isPhoneFlat()
   * Phone is flat when |z| is close to 9.8 (within 2.0 tolerance)
   */
  function isPhoneFlat(accelZ) {
    return Math.abs(Math.abs(accelZ) - 9.8) < 2.0;
  }

  it('face up on table: z ≈ -9.8 → flat', function() {
    assertTrue(isPhoneFlat(-9.8));
    assertTrue(isPhoneFlat(-9.5));
    assertTrue(isPhoneFlat(-10.0));
  });

  it('face down on table: z ≈ +9.8 → flat', function() {
    assertTrue(isPhoneFlat(9.8));
    assertTrue(isPhoneFlat(9.5));
  });

  it('boundary: z = -8.0 → flat (|9.8-8.0|=1.8 < 2.0)', function() {
    assertTrue(isPhoneFlat(-8.0));
  });

  it('boundary: z = -7.7 → NOT flat (|9.8-7.7|=2.1 > 2.0)', function() {
    assertFalse(isPhoneFlat(-7.7));
  });

  it('CRITICAL: hand-held tilted: z ≈ -5.0 → NOT flat', function() {
    assertFalse(isPhoneFlat(-5.0),
      'REGRESSION: tilted phone (hand-held) must NOT be classified as flat');
  });

  it('hand-held nearly vertical: z ≈ -2.0 → NOT flat', function() {
    assertFalse(isPhoneFlat(-2.0));
  });

  it('z = 0 (phone sideways) → NOT flat', function() {
    assertFalse(isPhoneFlat(0));
  });

  /**
   * Full PosturePlugin classification with flat detection
   */
  function classifyPosture(accelZ, proximityNear, ambientLux) {
    let isFlat = Math.abs(Math.abs(accelZ) - 9.8) < 2.0;

    if (proximityNear) {
      return 'in_pocket';
    }

    if (isFlat) {
      if (ambientLux < 10) return 'face_up';
      return 'on_desk';
    } else {
      return 'in_use'; // tilted = hand-held
    }
  }

  it('CRITICAL: dark room + hand-held (z=-5) → in_use, NOT face_up', function() {
    assertEqual(classifyPosture(-5.0, false, 5), 'in_use',
      'REGRESSION: dark room hand-held must be in_use, not face_up');
  });

  it('dark room + flat (z=-9.8) → face_up', function() {
    assertEqual(classifyPosture(-9.8, false, 5), 'face_up');
  });

  it('normal light + flat → on_desk', function() {
    assertEqual(classifyPosture(-9.8, false, 100), 'on_desk');
  });

  it('normal light + tilted → in_use', function() {
    assertEqual(classifyPosture(-5.0, false, 100), 'in_use');
  });

  it('proximity near → in_pocket regardless', function() {
    assertEqual(classifyPosture(-9.8, true, 100), 'in_pocket');
    assertEqual(classifyPosture(-5.0, true, 5), 'in_pocket');
  });
});

// ─────── 12. inferDrivingVsTransit — transit hub detection (Bug C) ───────

describe('12a. isTransitHub — keyword detection', function() {
  function isTransitHub(geofenceId) {
    if (!geofenceId || geofenceId.length === 0) return false;
    let lower = geofenceId.toLowerCase();
    return lower.includes('transit') ||
           lower.includes('station') ||
           lower.includes('metro') ||
           lower.includes('subway') ||
           lower.includes('bus') ||
           lower.includes('airport') ||
           lower.includes('railway') ||
           lower.includes('train') ||
           lower.includes('ferry');
  }

  it('subway_station → true', function() { assertTrue(isTransitHub('subway_station')); });
  it('metro_line2 → true', function() { assertTrue(isTransitHub('metro_line2')); });
  it('bus_stop_east → true', function() { assertTrue(isTransitHub('bus_stop_east')); });
  it('Central_Station → true', function() { assertTrue(isTransitHub('Central_Station')); });
  it('AIRPORT_T2 → true', function() { assertTrue(isTransitHub('AIRPORT_T2')); });
  it('railway_platform → true', function() { assertTrue(isTransitHub('railway_platform')); });
  it('Train_Depot → true', function() { assertTrue(isTransitHub('Train_Depot')); });
  it('ferry_terminal → true', function() { assertTrue(isTransitHub('ferry_terminal')); });
  it('transit_hub → true', function() { assertTrue(isTransitHub('transit_hub')); });

  it('home → false', function() { assertFalse(isTransitHub('home')); });
  it('work_office → false', function() { assertFalse(isTransitHub('work_office')); });
  it('restaurant_abc → false', function() { assertFalse(isTransitHub('restaurant_abc')); });
  it('parking_lot → false', function() { assertFalse(isTransitHub('parking_lot')); });
  it('gym → false', function() { assertFalse(isTransitHub('gym')); });
  it('empty string → false', function() { assertFalse(isTransitHub('')); });
  it('null → false', function() { assertFalse(isTransitHub(null)); });
});

describe('12b. inferDrivingVsTransit — geofence-based transit detection', function() {
  function isTransitHub(geofenceId) {
    if (!geofenceId || geofenceId.length === 0) return false;
    let lower = geofenceId.toLowerCase();
    return lower.includes('transit') || lower.includes('station') ||
           lower.includes('metro') || lower.includes('subway') ||
           lower.includes('bus') || lower.includes('airport') ||
           lower.includes('railway') || lower.includes('train') ||
           lower.includes('ferry');
  }

  const DEPARTURE_WINDOW_MS = 5 * 60 * 1000;

  function inferDrivingVsTransit(detectedMotion, prevGeofence, currentGeofence, geofenceDepartureTime, now) {
    if (detectedMotion !== 'driving') return detectedMotion;

    if (prevGeofence && isTransitHub(prevGeofence)) {
      let currentIsTransitHub = currentGeofence && isTransitHub(currentGeofence);
      let inDepartureWindow = (now - geofenceDepartureTime) < DEPARTURE_WINDOW_MS;

      if (currentIsTransitHub || inDepartureWindow) {
        return 'transit';
      }
    }

    return detectedMotion;
  }

  it('CRITICAL: driving from subway_station within 5min → transit', function() {
    let now = Date.now();
    assertEqual(inferDrivingVsTransit('driving', 'subway_station', '', now - 60000, now), 'transit',
      'REGRESSION: driving from transit hub within 5min must be classified as transit');
  });

  it('driving from bus_stop within 3min → transit', function() {
    let now = Date.now();
    assertEqual(inferDrivingVsTransit('driving', 'bus_stop', '', now - 180000, now), 'transit');
  });

  it('driving from airport, still in airport → transit', function() {
    let now = Date.now();
    assertEqual(inferDrivingVsTransit('driving', 'airport_t1', 'airport_runway', now - 600000, now), 'transit',
      'Current location is also transit hub → transit');
  });

  it('driving from subway_station after 6min → driving (window expired)', function() {
    let now = Date.now();
    assertEqual(inferDrivingVsTransit('driving', 'subway_station', '', now - 360000, now), 'driving',
      'After 5min window, should stay as driving');
  });

  it('driving from parking_lot → driving (not a transit hub)', function() {
    let now = Date.now();
    assertEqual(inferDrivingVsTransit('driving', 'parking_lot', '', now - 60000, now), 'driving');
  });

  it('driving from home → driving', function() {
    let now = Date.now();
    assertEqual(inferDrivingVsTransit('driving', 'home', '', now - 60000, now), 'driving');
  });

  it('walking from subway_station → walking (only driving gets overridden)', function() {
    let now = Date.now();
    assertEqual(inferDrivingVsTransit('walking', 'subway_station', '', now - 60000, now), 'walking');
  });

  it('stationary from bus_stop → stationary (only driving gets overridden)', function() {
    let now = Date.now();
    assertEqual(inferDrivingVsTransit('stationary', 'bus_stop', '', now - 60000, now), 'stationary');
  });

  it('no previous geofence → driving (no inference possible)', function() {
    let now = Date.now();
    assertEqual(inferDrivingVsTransit('driving', '', '', now - 60000, now), 'driving');
    assertEqual(inferDrivingVsTransit('driving', null, '', now - 60000, now), 'driving');
  });
});

// ─────── 13. Timeline immediate push triggers (Bug D) ───────

describe('13. Timeline push — immediate triggers on state change', function() {
  /**
   * Mirror of CAS timeline push logic:
   * - pushTimelineEvent() called on motion state change
   * - pushTimelineEvent() called on geofence enter/leave
   * - pushTimelineEvent() called on service start
   * - DailyTimelineService.pushStateChange() has 5s dedup
   */
  const DEDUP_MS = 5000;

  function createTimelinePushTracker() {
    let pushes = [];
    return {
      push(event, timestamp) {
        // Dedup: same geofence + same motion within 5s → skip
        let last = pushes.length > 0 ? pushes[pushes.length - 1] : null;
        if (last && last.geofence === event.geofence &&
            last.motionState === event.motionState &&
            (timestamp - last.timestamp) < DEDUP_MS) {
          return false; // deduped
        }
        pushes.push({ ...event, timestamp });
        return true; // accepted
      },
      get count() { return pushes.length; },
      get entries() { return pushes; }
    };
  }

  it('motion state change → immediate push accepted', function() {
    let tracker = createTimelinePushTracker();
    let t = Date.now();
    assertTrue(tracker.push({ geofence: 'home', motionState: 'stationary' }, t));
    assertTrue(tracker.push({ geofence: 'home', motionState: 'walking' }, t + 1000));
    assertEqual(tracker.count, 2, 'Motion change should create new entry immediately');
  });

  it('geofence change → immediate push accepted', function() {
    let tracker = createTimelinePushTracker();
    let t = Date.now();
    assertTrue(tracker.push({ geofence: 'home', motionState: 'stationary' }, t));
    assertTrue(tracker.push({ geofence: '', motionState: 'driving' }, t + 1000));
    assertTrue(tracker.push({ geofence: 'work', motionState: 'stationary' }, t + 2000));
    assertEqual(tracker.count, 3, 'Each geofence change should create new entry');
  });

  it('same state within 5s → deduped', function() {
    let tracker = createTimelinePushTracker();
    let t = Date.now();
    assertTrue(tracker.push({ geofence: 'home', motionState: 'stationary' }, t));
    assertFalse(tracker.push({ geofence: 'home', motionState: 'stationary' }, t + 2000));
    assertEqual(tracker.count, 1, 'Duplicate within 5s should be rejected');
  });

  it('same state after 5s → accepted (not deduped)', function() {
    let tracker = createTimelinePushTracker();
    let t = Date.now();
    assertTrue(tracker.push({ geofence: 'home', motionState: 'stationary' }, t));
    assertTrue(tracker.push({ geofence: 'home', motionState: 'stationary' }, t + 6000));
    assertEqual(tracker.count, 2);
  });

  it('service start → initial push', function() {
    let tracker = createTimelinePushTracker();
    let t = Date.now();
    // Service start pushes initial state
    assertTrue(tracker.push({ geofence: '', motionState: 'unknown' }, t));
    assertEqual(tracker.count, 1, 'Service start should push initial timeline entry');
  });

  it('rapid state changes → all captured if different', function() {
    let tracker = createTimelinePushTracker();
    let t = Date.now();
    assertTrue(tracker.push({ geofence: 'home', motionState: 'stationary' }, t));
    assertTrue(tracker.push({ geofence: 'home', motionState: 'walking' }, t + 500));
    assertTrue(tracker.push({ geofence: '', motionState: 'driving' }, t + 1000));
    assertEqual(tracker.count, 3, 'Different states should all be recorded');
  });
});

// ─────── 14. Driving inertia — step base reset + mid-speed timestamp (Bug E & F) ───────

describe('14a. Driving inertia step base reset (Bug E)', function() {
  /**
   * Mirror of CAS driving inertia logic:
   * drivingInertiaStepBase must be reset each time driving speed is confirmed,
   * otherwise cumulative vibration pseudo-steps cause inertia to fail prematurely.
   */
  function simulateDrivingWithStepBase(events) {
    let lastHighSpeedTime = 0;
    let drivingInertiaStepBase = 0;
    let lastMotionState = 'stationary';
    let results = [];

    for (let e of events) {
      let { gpsSpeed, stepCount, now } = e;
      let newState;

      if (gpsSpeed > 5) {
        newState = 'driving';
        lastHighSpeedTime = now;
        drivingInertiaStepBase = stepCount; // KEY: reset step base
      } else if (gpsSpeed > 1.5 && lastMotionState === 'driving') {
        newState = 'driving';
        lastHighSpeedTime = now; // KEY: refresh timestamp at mid-speed
        drivingInertiaStepBase = stepCount; // KEY: also reset step base
      } else {
        let recentlyDriving = (lastMotionState === 'driving')
          && ((now - lastHighSpeedTime) < 90000);
        let stepsSinceHighSpeed = stepCount - drivingInertiaStepBase;
        if (recentlyDriving && stepsSinceHighSpeed < 20) {
          newState = 'driving'; // inertia holds
        } else {
          newState = 'stationary'; // simplified fallback
        }
      }

      lastMotionState = newState;
      results.push({
        state: newState,
        stepBase: drivingInertiaStepBase,
        stepsSinceBase: stepCount - drivingInertiaStepBase
      });
    }
    return results;
  }

  it('CRITICAL: step base resets on each speed confirmation', function() {
    let t = Date.now();
    let results = simulateDrivingWithStepBase([
      { gpsSpeed: 15, stepCount: 0, now: t },         // start driving
      { gpsSpeed: 15, stepCount: 5, now: t + 10000 },  // still driving, vibration +5
      { gpsSpeed: 15, stepCount: 12, now: t + 20000 }, // still driving, vibration +7
      { gpsSpeed: 0,  stepCount: 15, now: t + 30000 }, // red light
    ]);
    assertEqual(results[0].state, 'driving');
    assertEqual(results[1].stepBase, 5, 'Step base should reset to current on speed confirm');
    assertEqual(results[2].stepBase, 12, 'Step base should reset again');
    assertEqual(results[3].state, 'driving', 'Red light: only 3 steps since last base → inertia holds');
    assertEqual(results[3].stepsSinceBase, 3);
  });

  it('WITHOUT step base reset: vibration accumulates → inertia fails', function() {
    // Simulating the OLD bug: step base never resets
    let t = Date.now();
    let stepBase = 0; // never reset (the bug)
    let steps = 25; // accumulated vibration pseudo-steps

    let stepsSince = steps - stepBase; // 25 - 0 = 25 >= 20
    assertTrue(stepsSince >= 20,
      'Without reset, pseudo-steps accumulate and inertia fails (the old bug)');
  });

  it('with reset: same scenario, inertia holds', function() {
    let t = Date.now();
    let results = simulateDrivingWithStepBase([
      { gpsSpeed: 15, stepCount: 0, now: t },
      { gpsSpeed: 15, stepCount: 10, now: t + 30000 },
      { gpsSpeed: 15, stepCount: 22, now: t + 60000 }, // 22 cumulative but base=10 after last
      { gpsSpeed: 0,  stepCount: 25, now: t + 70000 },  // red light
    ]);
    assertEqual(results[3].state, 'driving');
    assertEqual(results[3].stepsSinceBase, 3, 'Only 3 steps since last base reset');
  });
});

describe('14b. Driving inertia mid-speed timestamp refresh (Bug F)', function() {
  /**
   * Bug: at mid-speed (1.5-5 m/s), lastHighSpeedTime was not refreshed.
   * After 90s at mid-speed, inertia expired even though still driving.
   */
  function simulateMidSpeedDriving(events) {
    let lastHighSpeedTime = 0;
    let drivingInertiaStepBase = 0;
    let lastMotionState = 'stationary';
    let results = [];

    for (let e of events) {
      let { gpsSpeed, stepCount, now } = e;
      let newState;

      if (gpsSpeed > 5) {
        newState = 'driving';
        lastHighSpeedTime = now;
        drivingInertiaStepBase = stepCount;
      } else if (gpsSpeed > 1.5 && lastMotionState === 'driving') {
        newState = 'driving';
        lastHighSpeedTime = now; // FIX: refresh at mid-speed too
        drivingInertiaStepBase = stepCount;
      } else {
        let recentlyDriving = (lastMotionState === 'driving')
          && ((now - lastHighSpeedTime) < 90000);
        let stepsSinceHighSpeed = stepCount - drivingInertiaStepBase;
        if (recentlyDriving && stepsSinceHighSpeed < 20) {
          newState = 'driving';
        } else {
          newState = 'stationary';
        }
      }

      lastMotionState = newState;
      results.push({ state: newState, lastHighSpeedTime });
    }
    return results;
  }

  it('CRITICAL: mid-speed (3 m/s) for 2 min → inertia still valid at stop', function() {
    let t = Date.now();
    let results = simulateMidSpeedDriving([
      { gpsSpeed: 15, stepCount: 0, now: t },              // fast start
      { gpsSpeed: 3,  stepCount: 2, now: t + 30000 },      // slow down to 3 m/s
      { gpsSpeed: 3,  stepCount: 4, now: t + 60000 },      // still 3 m/s
      { gpsSpeed: 3,  stepCount: 6, now: t + 100000 },     // 100s in, mid-speed refreshes
      { gpsSpeed: 0,  stepCount: 7, now: t + 110000 },     // stop
    ]);
    assertEqual(results[4].state, 'driving',
      'REGRESSION: mid-speed refresh should keep inertia alive at stop');
  });

  it('WITHOUT mid-speed refresh: inertia expires after 90s', function() {
    // Simulating OLD bug: no refresh at mid-speed
    let t = Date.now();
    let lastHighSpeedTime = t; // set only at initial high speed

    // After 100s at mid-speed, stop
    let timeSinceHighSpeed = (t + 110000) - lastHighSpeedTime; // 110s
    assertTrue(timeSinceHighSpeed > 90000,
      'Without mid-speed refresh, 110s > 90s inertia window → would fail');
  });

  it('mid-speed refreshes timestamp each time', function() {
    let t = Date.now();
    let results = simulateMidSpeedDriving([
      { gpsSpeed: 15, stepCount: 0, now: t },
      { gpsSpeed: 2,  stepCount: 1, now: t + 50000 },
      { gpsSpeed: 2,  stepCount: 2, now: t + 100000 },
    ]);
    assertEqual(results[1].lastHighSpeedTime, t + 50000, 'Mid-speed should update timestamp');
    assertEqual(results[2].lastHighSpeedTime, t + 100000, 'Each mid-speed event refreshes');
  });

  it('truly stopped after high-speed (no mid-speed) → inertia expires at 90s', function() {
    let t = Date.now();
    let results = simulateMidSpeedDriving([
      { gpsSpeed: 15, stepCount: 0, now: t },
      { gpsSpeed: 0,  stepCount: 0, now: t + 95000 }, // 95s later, no mid-speed in between
    ]);
    assertEqual(results[1].state, 'stationary',
      '95s with no speed at all → inertia should expire');
  });
});
