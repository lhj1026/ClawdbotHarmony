'use strict';
/**
 * 运动状态平滑分类场景测试
 * 对应: MotionClassifier — 滑动窗口多数投票 + 驻留逻辑
 *
 * 场景覆盖:
 *   1. 全静止样本 → stationary
 *   2. 全步行样本 → walking
 *   3. 多数投票: 步行 > 静止 → walking
 *   4. running 需 5/7 才能从 walking 切换 (防手臂摆动误判)
 *   5. 5/7 running 阈值满足 → 切换 running
 *   6. 短暂静止不切换 (驻留阻挡)
 *   7. 静止持续 3000ms+ → 最终切换
 *   8. 活跃运动 800ms+ → 及时切换
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertFalse
} = require('../../lib/assert');

// ============================================================
// JS mirror: MotionClassifier (sliding window + dwell logic)
// ============================================================

/**
 * Classify a single accelerometer magnitude sample.
 *   <10.5     → stationary
 *   10.5-12   → walking
 *   12-15     → running
 *   >=15      → driving
 */
function classifySingleSample(magnitude) {
  if (magnitude < 10.5) return 'stationary';
  if (magnitude < 12.0) return 'walking';
  if (magnitude < 15.0) return 'running';
  return 'driving';
}

/**
 * Majority-vote classification over a sliding window of samples,
 * with variance-based walking detection for hand-held scenarios.
 *
 * Key insight: walking with phone in hand produces magnitude oscillations
 * around gravity (~9.8) with high variance (>0.3), while stationary has
 * variance < 0.15. Variance check catches walking even when mean < 10.5.
 *
 * @param {number[]} accelHistory - last 7 magnitude samples
 * @param {string}   currentState - the currently committed motion state
 * @returns {string} the voted motion state
 */
function classifyWithSmoothing(accelHistory, currentState) {
  if (accelHistory.length === 0) return currentState || 'stationary';

  // Compute mean and variance
  let sum = 0;
  for (const mag of accelHistory) sum += mag;
  const mean = sum / accelHistory.length;
  let varianceSum = 0;
  for (const mag of accelHistory) {
    const d = mag - mean;
    varianceSum += d * d;
  }
  const variance = varianceSum / accelHistory.length;

  // Variance compensation: hand-held walking has mean ~9.8 but variance > 0.3
  if (variance > 0.3 && mean < 10.5) {
    return 'walking';
  }

  // Classify each sample
  const votes = {};
  for (const mag of accelHistory) {
    const label = classifySingleSample(mag);
    votes[label] = (votes[label] || 0) + 1;
  }

  // Find majority
  let majority = currentState || 'stationary';
  let maxCount = 0;
  for (const [label, count] of Object.entries(votes)) {
    if (count > maxCount) {
      maxCount = count;
      majority = label;
    }
  }

  // Special rule: walking→running transition requires 5/7 threshold
  if (currentState === 'walking' && majority === 'running') {
    const runningVotes = votes['running'] || 0;
    if (runningVotes < 5) {
      return 'walking'; // not enough running votes, stay walking
    }
  }

  return majority;
}

/**
 * Dwell timer logic: prevents rapid state flicker.
 *
 * - Transition to stationary: candidate must hold for dwellToStationary ms
 * - Transition to active (walking/running/driving): candidate must hold for dwellToActive ms
 *
 * @param {string} currentState    - committed state
 * @param {string} candidateState  - new state from smoothing
 * @param {number} candidateHeldMs - how long candidate has been stable
 * @param {number} dwellToStationary - ms required to switch to stationary (default 3000)
 * @param {number} dwellToActive     - ms required to switch to active (default 800)
 * @returns {{ state: string, switched: boolean }}
 */
function applyDwell(currentState, candidateState, candidateHeldMs,
                    dwellToStationary = 3000, dwellToActive = 800) {
  if (candidateState === currentState) {
    return { state: currentState, switched: false };
  }

  const requiredMs = candidateState === 'stationary'
    ? dwellToStationary
    : dwellToActive;

  if (candidateHeldMs >= requiredMs) {
    return { state: candidateState, switched: true };
  }

  return { state: currentState, switched: false };
}

// ============================================================
// Full pipeline helper: classify + dwell in one call
// ============================================================

function classifyMotion(accelHistory, currentState, candidateState,
                        candidateHeldMs) {
  const smoothed = classifyWithSmoothing(accelHistory, currentState);
  return applyDwell(currentState, smoothed, candidateHeldMs);
}

// ============================================================
// Tests
// ============================================================

describe('单样本分类 (classifySingleSample)', function () {
  it('magnitude < 10.5 → stationary', function () {
    assertEqual(classifySingleSample(9.8), 'stationary');
    assertEqual(classifySingleSample(0), 'stationary');
    assertEqual(classifySingleSample(10.4), 'stationary');
  });

  it('magnitude 10.5-12 → walking', function () {
    assertEqual(classifySingleSample(10.5), 'walking');
    assertEqual(classifySingleSample(11.0), 'walking');
    assertEqual(classifySingleSample(11.99), 'walking');
  });

  it('magnitude 12-15 → running', function () {
    assertEqual(classifySingleSample(12.0), 'running');
    assertEqual(classifySingleSample(13.5), 'running');
    assertEqual(classifySingleSample(14.99), 'running');
  });

  it('magnitude >= 15 → driving', function () {
    assertEqual(classifySingleSample(15.0), 'driving');
    assertEqual(classifySingleSample(20.0), 'driving');
  });
});

describe('场景: 滑动窗口多数投票分类', function () {
  it('7 samples all ~9.8 → stationary', function () {
    const history = [9.8, 9.7, 9.81, 9.79, 9.82, 9.78, 9.80];
    const result = classifyWithSmoothing(history, 'stationary');
    assertEqual(result, 'stationary',
      'all samples below 10.5 should yield stationary');
  });

  it('7 samples all ~11.0 → walking', function () {
    const history = [11.0, 10.9, 11.1, 10.8, 11.2, 11.0, 10.95];
    const result = classifyWithSmoothing(history, 'stationary');
    assertEqual(result, 'walking',
      'all samples in walking range should yield walking');
  });

  it('4 walking + 3 stationary → walking (majority)', function () {
    // 4 walking (10.5-12) + 3 stationary (<10.5)
    const history = [11.0, 11.1, 10.8, 11.2, 9.8, 9.7, 9.9];
    const result = classifyWithSmoothing(history, 'stationary');
    assertEqual(result, 'walking',
      '4/7 walking vs 3/7 stationary → walking wins majority');
  });

  it('4 running + 3 walking, current=walking → stays walking (need 5/7 running)', function () {
    // 4 running (12-15) + 3 walking (10.5-12)
    const history = [13.0, 13.5, 14.0, 12.5, 11.0, 11.5, 10.8];
    const result = classifyWithSmoothing(history, 'walking');
    assertEqual(result, 'walking',
      'only 4/7 running votes when current=walking → stays walking (needs 5/7)');
  });

  it('5 running + 2 walking, current=walking → switches to running (5/7 threshold met)', function () {
    // 5 running + 2 walking
    const history = [13.0, 13.5, 14.0, 12.5, 12.8, 11.0, 11.5];
    const result = classifyWithSmoothing(history, 'walking');
    assertEqual(result, 'running',
      '5/7 running votes when current=walking → threshold met, switch to running');
  });
});

describe('场景: 方差检测 — 手持走路', function () {
  it('手持走路: 均值~9.8 但方差>0.3 → walking（不被误判为 stationary）', function () {
    // 模拟手持走路：magnitude 在 9.0~10.5 之间震荡, 均值 ~9.8, 方差 ~0.35
    const history = [9.0, 10.5, 9.2, 10.5, 9.0, 10.4, 9.3];
    const result = classifyWithSmoothing(history, 'stationary');
    assertEqual(result, 'walking',
      'high variance (>0.3) with mean < 10.5 should classify as walking');
  });

  it('真正静止: 均值~9.8 且方差<0.15 → stationary', function () {
    // 模拟平放桌面：magnitude 稳定在 9.8±0.1
    const history = [9.81, 9.79, 9.80, 9.82, 9.78, 9.80, 9.81];
    const result = classifyWithSmoothing(history, 'stationary');
    assertEqual(result, 'stationary',
      'low variance (<0.15) with mean ~9.8 should stay stationary');
  });

  it('手持走路较剧烈: 均值~10.0 方差~1.0 → walking', function () {
    // 模拟快走手持：magnitude 在 9.0~11.0 之间大幅震荡
    const history = [9.0, 11.0, 9.2, 10.8, 9.1, 10.9, 10.0];
    const result = classifyWithSmoothing(history, 'stationary');
    assertEqual(result, 'walking',
      'large variance with mean near 10 should detect walking');
  });

  it('方差检测仅在均值<10.5时生效: 高均值+高方差 → 用投票', function () {
    // 均值 ~13 (running range), 方差也大 — 应该用投票结果 running, 不受方差规则影响
    const history = [12.0, 14.0, 12.5, 13.5, 12.0, 14.0, 13.0];
    const result = classifyWithSmoothing(history, 'stationary');
    assertEqual(result, 'running',
      'high mean (>10.5) should use majority vote even with high variance');
  });
});

describe('场景: 驻留逻辑 (dwell timer)', function () {
  it('brief stationary during walking → does NOT switch (dwell blocks it)', function () {
    // Even though candidate is stationary, only 500ms held — well below 3000ms threshold
    const result = applyDwell('walking', 'stationary', 500);
    assertEqual(result.state, 'walking',
      'brief stationary (500ms < 3000ms) should not switch');
    assertFalse(result.switched,
      'switched flag should be false when dwell not satisfied');
  });

  it('stationary held for 3000ms+ → finally switches', function () {
    const result = applyDwell('walking', 'stationary', 3000);
    assertEqual(result.state, 'stationary',
      'stationary held for exactly 3000ms should trigger switch');
    assertTrue(result.switched,
      'switched flag should be true when dwell threshold met');

    // Also test with > 3000ms
    const result2 = applyDwell('walking', 'stationary', 4500);
    assertEqual(result2.state, 'stationary',
      'stationary held for 4500ms (> 3000ms) should switch');
    assertTrue(result2.switched);
  });

  it('active motion for 800ms+ → switches promptly', function () {
    // From stationary to walking, held 800ms
    const result = applyDwell('stationary', 'walking', 800);
    assertEqual(result.state, 'walking',
      'walking held for exactly 800ms should trigger switch from stationary');
    assertTrue(result.switched);

    // From stationary to running, held 900ms
    const result2 = applyDwell('stationary', 'running', 900);
    assertEqual(result2.state, 'running',
      'running held for 900ms (> 800ms) should trigger switch');
    assertTrue(result2.switched);
  });

  it('active motion for < 800ms → does NOT switch', function () {
    const result = applyDwell('stationary', 'walking', 500);
    assertEqual(result.state, 'stationary',
      'walking held for only 500ms (< 800ms) should not switch');
    assertFalse(result.switched);
  });
});

describe('场景: 完整管道 (smoothing + dwell)', function () {
  it('all walking samples + sufficient dwell → switches from stationary to walking', function () {
    const history = [11.0, 11.1, 10.8, 11.2, 11.0, 10.9, 11.05];
    const result = classifyMotion(history, 'stationary', 'walking', 1000);
    assertEqual(result.state, 'walking',
      'unanimous walking + 1000ms dwell should switch from stationary');
    assertTrue(result.switched);
  });

  it('candidate same as current → no switch needed', function () {
    const result = applyDwell('walking', 'walking', 0);
    assertEqual(result.state, 'walking');
    assertFalse(result.switched,
      'same state should not trigger a switch');
  });

  it('asymmetric dwell thresholds: quicker to go active, slower to go stationary', function () {
    // To active: 800ms
    const goActive = applyDwell('stationary', 'running', 800);
    assertTrue(goActive.switched, 'should switch to active at 800ms');

    // To stationary: 800ms is NOT enough — needs 3000ms
    const goStationary = applyDwell('running', 'stationary', 800);
    assertFalse(goStationary.switched,
      '800ms is not enough to switch to stationary (needs 3000ms)');

    // To stationary: 3000ms is enough
    const goStationary2 = applyDwell('running', 'stationary', 3000);
    assertTrue(goStationary2.switched,
      '3000ms should be enough to switch to stationary');
  });
});
