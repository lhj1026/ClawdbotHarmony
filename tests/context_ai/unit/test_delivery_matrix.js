'use strict';
/**
 * 推送形式矩阵测试
 * 对应设计文档: §5.3 执行域架构 - 推送形式矩阵
 * 覆盖: 紧急度×用户状态→推送形式 / 低置信度降级 / 合并推送
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertDefined, assertNotEqual
} = require('../../lib/assert');

// ── JS 镜像：推送形式矩阵（ArkTS DeliveryManager） ──

/**
 * 推送形式矩阵
 * 行: 紧急度 🔴🟡🟢⚪
 * 列: 用户状态 idle/busy/meeting/sleeping/driving
 */
const DELIVERY_MATRIX = {
  '🔴': { idle: 'fullscreen+sound', busy: 'banner+vibrate', meeting: 'banner+vibrate', sleeping: 'fullscreen+sound', driving: 'voice' },
  '🟡': { idle: 'banner',           busy: 'badge',          meeting: 'silent',         sleeping: 'silent',           driving: 'voice' },
  '🟢': { idle: 'badge',            busy: 'silent',         meeting: 'silent',         sleeping: 'silent',           driving: 'silent' },
  '⚪': { idle: 'silent',           busy: 'silent',         meeting: 'silent',         sleeping: 'silent',           driving: 'silent' },
};

/** 降级映射: 低置信度时自动降一级 */
const DOWNGRADE_MAP = {
  'fullscreen+sound': 'banner+vibrate',
  'banner+vibrate':   'banner',
  'banner':           'badge',
  'badge':            'silent',
  'voice':            'silent',
  'silent':           'silent',
};

/**
 * 获取推送形式
 * @param {string} priority - 紧急度 (🔴🟡🟢⚪)
 * @param {string} userState - 用户状态
 * @param {number} confidence - 置信度 0~1
 * @returns {{ form: string, downgraded: boolean }}
 */
function getDeliveryForm(priority, userState, confidence) {
  confidence = confidence ?? 1.0;
  const row = DELIVERY_MATRIX[priority];
  if (!row) return { form: 'silent', downgraded: false };

  let form = row[userState];
  if (!form) form = 'silent'; // 未知状态默认静默

  let downgraded = false;
  if (confidence < 0.6) {
    const lower = DOWNGRADE_MAP[form];
    if (lower && lower !== form) {
      form = lower;
      downgraded = true;
    }
  }

  return { form, downgraded };
}

/**
 * 合并推送: 5分钟内多条 🟢/⚪ 合并为一条摘要
 */
function shouldMerge(pushes, windowMs) {
  windowMs = windowMs || 300000; // 5min
  const now = Date.now();
  const recent = pushes.filter(p =>
    (now - p.time) < windowMs && (p.priority === '🟢' || p.priority === '⚪')
  );
  return { merge: recent.length >= 2, count: recent.length, items: recent };
}

// ── 测试 ──

describe('DeliveryMatrix - 🔴 紧急', function () {
  it('空闲 → 全屏+声音', function () {
    assertEqual(getDeliveryForm('🔴', 'idle').form, 'fullscreen+sound');
  });

  it('忙碌 → 横幅+震动', function () {
    assertEqual(getDeliveryForm('🔴', 'busy').form, 'banner+vibrate');
  });

  it('开会 → 横幅+震动', function () {
    assertEqual(getDeliveryForm('🔴', 'meeting').form, 'banner+vibrate');
  });

  it('睡觉 → 全屏+声音（紧急唤醒）', function () {
    assertEqual(getDeliveryForm('🔴', 'sleeping').form, 'fullscreen+sound');
  });

  it('开车 → 语音播报', function () {
    assertEqual(getDeliveryForm('🔴', 'driving').form, 'voice');
  });
});

describe('DeliveryMatrix - 🟡 尽快', function () {
  it('空闲 → 横幅', function () {
    assertEqual(getDeliveryForm('🟡', 'idle').form, 'banner');
  });

  it('忙碌 → 小红点', function () {
    assertEqual(getDeliveryForm('🟡', 'busy').form, 'badge');
  });

  it('开会 → 静默', function () {
    assertEqual(getDeliveryForm('🟡', 'meeting').form, 'silent');
  });

  it('睡觉 → 静默', function () {
    assertEqual(getDeliveryForm('🟡', 'sleeping').form, 'silent');
  });

  it('开车 → 语音', function () {
    assertEqual(getDeliveryForm('🟡', 'driving').form, 'voice');
  });
});

describe('DeliveryMatrix - 🟢 稍后', function () {
  it('空闲 → 小红点', function () {
    assertEqual(getDeliveryForm('🟢', 'idle').form, 'badge');
  });

  it('忙碌 → 静默', function () {
    assertEqual(getDeliveryForm('🟢', 'busy').form, 'silent');
  });

  it('全部非空闲 → 静默', function () {
    for (const state of ['busy', 'meeting', 'sleeping', 'driving']) {
      assertEqual(getDeliveryForm('🟢', state).form, 'silent', `🟢+${state}`);
    }
  });
});

describe('DeliveryMatrix - ⚪ 背景', function () {
  it('任何状态 → 静默', function () {
    for (const state of ['idle', 'busy', 'meeting', 'sleeping', 'driving']) {
      assertEqual(getDeliveryForm('⚪', state).form, 'silent', `⚪+${state}`);
    }
  });
});

describe('DeliveryMatrix - 低置信度降级', function () {
  it('confidence<0.6 → 降一级', function () {
    const r = getDeliveryForm('🔴', 'idle', 0.5);
    assertEqual(r.form, 'banner+vibrate'); // fullscreen→banner+vibrate
    assertTrue(r.downgraded);
  });

  it('banner → badge', function () {
    const r = getDeliveryForm('🟡', 'idle', 0.4);
    assertEqual(r.form, 'badge');
    assertTrue(r.downgraded);
  });

  it('badge → silent', function () {
    const r = getDeliveryForm('🟢', 'idle', 0.3);
    assertEqual(r.form, 'silent');
    assertTrue(r.downgraded);
  });

  it('已是silent → 不再降级', function () {
    const r = getDeliveryForm('⚪', 'idle', 0.1);
    assertEqual(r.form, 'silent');
    assertEqual(r.downgraded, false); // silent→silent 无变化
  });

  it('confidence≥0.6 → 不降级', function () {
    const r = getDeliveryForm('🔴', 'idle', 0.6);
    assertEqual(r.form, 'fullscreen+sound');
    assertEqual(r.downgraded, false);
  });

  it('confidence=1.0 → 不降级', function () {
    const r = getDeliveryForm('🔴', 'idle', 1.0);
    assertEqual(r.form, 'fullscreen+sound');
  });
});

describe('DeliveryMatrix - 异常输入', function () {
  it('未知紧急度 → 静默', function () {
    assertEqual(getDeliveryForm('unknown', 'idle').form, 'silent');
  });

  it('未知用户状态 → 静默', function () {
    assertEqual(getDeliveryForm('🔴', 'unknown_state').form, 'silent');
  });

  it('confidence=null → 默认1.0', function () {
    const r = getDeliveryForm('🔴', 'idle', null);
    assertEqual(r.form, 'fullscreen+sound');
  });
});

describe('DeliveryMatrix - 合并推送', function () {
  it('2条低优先级 → 合并', function () {
    const now = Date.now();
    const pushes = [
      { priority: '🟢', time: now - 60000 },
      { priority: '🟢', time: now - 30000 },
    ];
    const r = shouldMerge(pushes);
    assertTrue(r.merge);
    assertEqual(r.count, 2);
  });

  it('1条 → 不合并', function () {
    const now = Date.now();
    const pushes = [{ priority: '🟢', time: now - 60000 }];
    assertEqual(shouldMerge(pushes).merge, false);
  });

  it('🔴不参与合并', function () {
    const now = Date.now();
    const pushes = [
      { priority: '🔴', time: now - 60000 },
      { priority: '🔴', time: now - 30000 },
    ];
    assertEqual(shouldMerge(pushes).merge, false);
  });

  it('超出窗口 → 不合并', function () {
    const now = Date.now();
    const pushes = [
      { priority: '🟢', time: now - 400000 }, // 超5min
      { priority: '🟢', time: now - 350000 },
    ];
    assertEqual(shouldMerge(pushes).merge, false);
  });
});
