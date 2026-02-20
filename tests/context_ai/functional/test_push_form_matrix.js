'use strict';
/**
 * 推送形式矩阵测试
 * 对应设计文档: §5.3 执行域架构 - 推送形式矩阵
 * 覆盖: 5种用户状态 × 4种优先级 = 20种组合 + 低置信度降级
 */

const { describe, it } = require('../../lib/test-runner');
const { assertEqual, assertTrue } = require('../../lib/assert');

// ── JS 镜像：推送形式矩阵 ──

const PUSH_MATRIX = {
  //           idle          busy          meeting       sleeping      driving
  '🔴': { idle: 'fullscreen_sound', busy: 'banner_vibrate', meeting: 'banner_vibrate', sleeping: 'fullscreen_sound', driving: 'voice' },
  '🟡': { idle: 'banner',           busy: 'badge',          meeting: 'silent',          sleeping: 'silent',            driving: 'voice' },
  '🟢': { idle: 'badge',            busy: 'silent',         meeting: 'silent',          sleeping: 'silent',            driving: 'silent' },
  '⚪': { idle: 'silent',           busy: 'silent',         meeting: 'silent',          sleeping: 'silent',            driving: 'silent' },
};

const DOWNGRADE = {
  'fullscreen_sound': 'banner_vibrate',
  'banner_vibrate':   'banner',
  'banner':           'badge',
  'badge':            'silent',
  'voice':            'silent',
  'silent':           'silent',
};

function getPushForm(priority, userState, confidence) {
  const form = PUSH_MATRIX[priority]?.[userState] || 'silent';
  if (confidence < 0.6) return DOWNGRADE[form] || 'silent';
  return form;
}

// ── 测试：全矩阵覆盖 ──

const priorities = ['🔴', '🟡', '🟢', '⚪'];
const states = ['idle', 'busy', 'meeting', 'sleeping', 'driving'];

describe('PushFormMatrix - 20种组合（高置信度）', function () {
  for (const p of priorities) {
    for (const s of states) {
      it(`${p} × ${s} → ${PUSH_MATRIX[p][s]}`, function () {
        assertEqual(getPushForm(p, s, 0.9), PUSH_MATRIX[p][s]);
      });
    }
  }
});

describe('PushFormMatrix - 低置信度降级', function () {
  it('🔴 idle 低置信度: fullscreen→banner_vibrate', function () {
    assertEqual(getPushForm('🔴', 'idle', 0.5), 'banner_vibrate');
  });

  it('🟡 idle 低置信度: banner→badge', function () {
    assertEqual(getPushForm('🟡', 'idle', 0.5), 'badge');
  });

  it('🟢 idle 低置信度: badge→silent', function () {
    assertEqual(getPushForm('🟢', 'idle', 0.5), 'silent');
  });

  it('⚪ 任何状态 低置信度: silent→silent', function () {
    assertEqual(getPushForm('⚪', 'idle', 0.5), 'silent');
  });

  it('🔴 driving 低置信度: voice→silent', function () {
    assertEqual(getPushForm('🔴', 'driving', 0.5), 'silent');
  });

  it('置信度恰好0.6 → 不降级', function () {
    assertEqual(getPushForm('🔴', 'idle', 0.6), 'fullscreen_sound');
  });

  it('置信度0.59 → 降级', function () {
    assertEqual(getPushForm('🔴', 'idle', 0.59), 'banner_vibrate');
  });
});

describe('PushFormMatrix - 边界', function () {
  it('未知优先级 → silent', function () {
    assertEqual(getPushForm('unknown', 'idle', 0.9), 'silent');
  });

  it('未知用户状态 → silent', function () {
    assertEqual(getPushForm('🔴', 'unknown', 0.9), 'silent');
  });
});
