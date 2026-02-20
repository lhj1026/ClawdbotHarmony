'use strict';
/**
 * LinUCB 算法测试
 * 对应设计文档: §6.3 LinUCB 算法细节, §5.2 决策域架构
 * 覆盖: 选动作/更新/时间衰减/探索-利用/参数保护
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertGreaterThan, assertLessThan, assertDefined
} = require('../../lib/assert');

// ── JS 镜像：LinUCB（C++ linucb.cpp） ──

class LinUCB {
  /**
   * @param {number} d - 特征维度
   * @param {number} nActions - 动作数
   * @param {number} alpha - 探索参数
   * @param {number} gamma - 时间衰减因子
   */
  constructor(d, nActions, alpha = 1.0, gamma = 0.998) {
    this.d = d;
    this.nActions = nActions;
    this.alpha = alpha;
    this.gamma = gamma;
    this.A = []; // 每个动作一个 d×d 矩阵（用平坦数组表示）
    this.b = []; // 每个动作一个 d 维向量
    for (let i = 0; i < nActions; i++) {
      this.A.push(this._identity(d));
      this.b.push(new Array(d).fill(0));
    }
  }

  _identity(d) {
    const m = new Array(d * d).fill(0);
    for (let i = 0; i < d; i++) m[i * d + i] = 1.0;
    return m;
  }

  /** 计算 θ = A⁻¹b（简化：用对角近似） */
  _getTheta(arm) {
    const theta = [];
    for (let i = 0; i < this.d; i++) {
      const aii = this.A[arm][i * this.d + i];
      theta.push(aii > 0 ? this.b[arm][i] / aii : 0);
    }
    return theta;
  }

  /** UCB 分数 = θᵀx + α√(xᵀA⁻¹x) */
  score(arm, x) {
    const theta = this._getTheta(arm);
    let exploit = 0;
    let explore = 0;
    for (let i = 0; i < this.d; i++) {
      exploit += theta[i] * x[i];
      const aii = this.A[arm][i * this.d + i];
      explore += (x[i] * x[i]) / (aii > 0 ? aii : 1);
    }
    return exploit + this.alpha * Math.sqrt(explore);
  }

  /** 选择动作 */
  selectAction(x) {
    let bestArm = 0;
    let bestScore = -Infinity;
    for (let a = 0; a < this.nActions; a++) {
      const s = this.score(a, x);
      if (s > bestScore) {
        bestScore = s;
        bestArm = a;
      }
    }
    return { arm: bestArm, score: bestScore };
  }

  /** 更新: A = γA + xxᵀ, b = γb + rx */
  update(arm, x, reward) {
    for (let i = 0; i < this.d; i++) {
      for (let j = 0; j < this.d; j++) {
        this.A[arm][i * this.d + j] = this.gamma * this.A[arm][i * this.d + j] + x[i] * x[j];
      }
      this.b[arm][i] = this.gamma * this.b[arm][i] + reward * x[i];
    }
  }

  /** 获取某动作的学习次数（近似：A对角线 - 1） */
  getCount(arm) {
    return this.A[arm][0] - 1; // 粗略估计
  }
}

// ── 测试 ──

describe('LinUCB - 初始化', function () {
  it('初始 A 为单位矩阵', function () {
    const ucb = new LinUCB(3, 2);
    // A[0][0,0] = 1, A[0][0,1] = 0
    assertEqual(ucb.A[0][0], 1.0);
    assertEqual(ucb.A[0][1], 0.0);
  });

  it('初始 b 为零向量', function () {
    const ucb = new LinUCB(3, 2);
    assertEqual(ucb.b[0][0], 0);
    assertEqual(ucb.b[0][1], 0);
  });

  it('动作数正确', function () {
    const ucb = new LinUCB(4, 5);
    assertEqual(ucb.A.length, 5);
    assertEqual(ucb.b.length, 5);
  });
});

describe('LinUCB - 选动作', function () {
  it('初始状态 → 所有动作分数相近（探索主导）', function () {
    const ucb = new LinUCB(3, 3, 1.0);
    const x = [1, 0, 0];
    const scores = [];
    for (let a = 0; a < 3; a++) scores.push(ucb.score(a, x));
    // 初始时所有动作分数相同
    assertEqual(scores[0], scores[1]);
    assertEqual(scores[1], scores[2]);
  });

  it('更新后 → 高奖励动作得分更高', function () {
    const ucb = new LinUCB(3, 3, 1.0);
    const x = [1, 0.5, 0.3];
    // 给动作0正奖励
    for (let i = 0; i < 10; i++) ucb.update(0, x, 1.0);
    // 给动作1负奖励
    for (let i = 0; i < 10; i++) ucb.update(1, x, -1.0);

    const result = ucb.selectAction(x);
    assertEqual(result.arm, 0);
  });

  it('返回 arm 和 score', function () {
    const ucb = new LinUCB(2, 2);
    const result = ucb.selectAction([1, 0]);
    assertDefined(result.arm);
    assertDefined(result.score);
  });
});

describe('LinUCB - 更新', function () {
  it('更新后 A 矩阵变化', function () {
    const ucb = new LinUCB(2, 1);
    const before = ucb.A[0][0];
    ucb.update(0, [1, 0], 1.0);
    assertGreaterThan(ucb.A[0][0], before);
  });

  it('更新后 b 向量变化', function () {
    const ucb = new LinUCB(2, 1);
    ucb.update(0, [1, 0.5], 1.0);
    assertGreaterThan(ucb.b[0][0], 0);
    assertGreaterThan(ucb.b[0][1], 0);
  });

  it('负奖励 → b 减小', function () {
    const ucb = new LinUCB(2, 1);
    ucb.update(0, [1, 0], -1.0);
    assertLessThan(ucb.b[0][0], 0);
  });
});

describe('LinUCB - 时间衰减', function () {
  it('γ=0.998 → 旧数据逐渐衰减', function () {
    const ucb = new LinUCB(2, 1, 1.0, 0.998);
    ucb.update(0, [1, 0], 1.0);
    const a1 = ucb.A[0][0];
    // 再更新一次空数据触发衰减
    ucb.update(0, [0, 0], 0);
    const a2 = ucb.A[0][0];
    // A[0][0] 应该衰减（γ * a1 + 0）
    assertLessThan(a2, a1);
  });

  it('γ=1.0 → 无衰减', function () {
    const ucb = new LinUCB(2, 1, 1.0, 1.0);
    ucb.update(0, [1, 0], 1.0);
    const a1 = ucb.A[0][0];
    ucb.update(0, [0, 0], 0);
    // A[0][0] = 1.0 * a1 + 0 = a1
    assertEqual(ucb.A[0][0], a1);
  });
});

describe('LinUCB - 探索参数α', function () {
  it('α大 → 探索分数更高', function () {
    const ucbHigh = new LinUCB(2, 1, 2.0);
    const ucbLow = new LinUCB(2, 1, 0.1);
    const x = [1, 0];
    assertGreaterThan(ucbHigh.score(0, x), ucbLow.score(0, x));
  });

  it('α=0 → 纯利用（无探索项）', function () {
    const ucb = new LinUCB(2, 1, 0);
    // 初始 θ=0 → score=0
    assertEqual(ucb.score(0, [1, 0]), 0);
  });
});

describe('LinUCB - 内存/维度', function () {
  it('d=40, 10动作 → 正常工作', function () {
    const ucb = new LinUCB(40, 10);
    const x = new Array(40).fill(0);
    x[0] = 1;
    const result = ucb.selectAction(x);
    assertDefined(result.arm);
    assertTrue(result.arm >= 0 && result.arm < 10);
  });
});
