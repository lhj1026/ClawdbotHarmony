'use strict';
/**
 * 隐私过滤测试
 * 对应设计文档: §1.6 隐私边界, §5.3 执行域架构 - 隐私过滤
 * 覆盖: 4级隐私（开放/摘要/禁止/授权）
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertDefined, assertUndefined
} = require('../../lib/assert');

// ── JS 镜像：隐私过滤器 ──

const PRIVACY_LEVELS = {
  OPEN:       'open',       // 🟢 完整原文
  SUMMARY:    'summary',    // 🟡 摘要+元数据
  BLOCKED:    'blocked',    // 🔴 仅"有新消息"
  AUTHORIZED: 'authorized', // 🔵 临时授权
};

/**
 * 隐私过滤：根据数据隐私级别和用户设置决定可见内容
 */
function filterContent(content, privacyLevel, hasAuthorization) {
  switch (privacyLevel) {
    case PRIVACY_LEVELS.OPEN:
      return { passed: true, content, redacted: false };

    case PRIVACY_LEVELS.SUMMARY:
      return {
        passed: true,
        content: {
          summary: content.summary || `来自 ${content.source || '未知'} 的消息`,
          metadata: { source: content.source, time: content.time, count: content.count },
        },
        redacted: true,
      };

    case PRIVACY_LEVELS.BLOCKED:
      if (hasAuthorization) {
        return { passed: true, content, redacted: false, authorized: true };
      }
      return {
        passed: false,
        content: { text: '有新消息' },
        redacted: true,
        blocked: true,
      };

    case PRIVACY_LEVELS.AUTHORIZED:
      if (hasAuthorization) {
        return { passed: true, content, redacted: false, authorized: true };
      }
      return {
        passed: false,
        content: { text: '需要授权查看' },
        redacted: true,
        needsAuth: true,
      };

    default:
      return { passed: false, content: null, redacted: true };
  }
}

/** 批量过滤 */
function filterBatch(items) {
  return items.map(item => ({
    ...item,
    filtered: filterContent(item.content, item.privacyLevel, item.authorized),
  }));
}

// ── 测试 ──

describe('PrivacyFilter - 开放级别 🟢', function () {
  it('完整内容通过', function () {
    const r = filterContent({ text: '快递已到', source: 'SF' }, 'open', false);
    assertTrue(r.passed);
    assertEqual(r.content.text, '快递已到');
    assertEqual(r.redacted, false);
  });

  it('无需授权', function () {
    const r = filterContent({ text: 'test' }, 'open', false);
    assertTrue(r.passed);
  });
});

describe('PrivacyFilter - 摘要级别 🟡', function () {
  it('原文被替换为摘要', function () {
    const content = { text: '私密内容', summary: '1条新消息', source: 'WeChat', time: 123 };
    const r = filterContent(content, 'summary', false);
    assertTrue(r.passed);
    assertTrue(r.redacted);
    assertEqual(r.content.summary, '1条新消息');
    assertUndefined(r.content.text);
  });

  it('保留元数据', function () {
    const content = { text: 'xxx', source: 'WeChat', time: 123, count: 3 };
    const r = filterContent(content, 'summary', false);
    assertEqual(r.content.metadata.source, 'WeChat');
    assertEqual(r.content.metadata.count, 3);
  });

  it('无摘要时生成默认', function () {
    const content = { text: 'xxx', source: 'QQ' };
    const r = filterContent(content, 'summary', false);
    assertTrue(r.content.summary.includes('QQ'));
  });
});

describe('PrivacyFilter - 禁止级别 🔴', function () {
  it('无授权 → 阻断', function () {
    const r = filterContent({ text: '银行转账' }, 'blocked', false);
    assertEqual(r.passed, false);
    assertTrue(r.blocked);
    assertEqual(r.content.text, '有新消息');
  });

  it('有授权 → 通过', function () {
    const r = filterContent({ text: '银行转账' }, 'blocked', true);
    assertTrue(r.passed);
    assertTrue(r.authorized);
    assertEqual(r.content.text, '银行转账');
  });
});

describe('PrivacyFilter - 授权级别 🔵', function () {
  it('无授权 → 请求授权', function () {
    const r = filterContent({ text: '日记内容' }, 'authorized', false);
    assertEqual(r.passed, false);
    assertTrue(r.needsAuth);
  });

  it('有授权 → 完整通过', function () {
    const r = filterContent({ text: '日记内容' }, 'authorized', true);
    assertTrue(r.passed);
    assertEqual(r.content.text, '日记内容');
  });
});

describe('PrivacyFilter - 批量过滤', function () {
  it('混合级别正确处理', function () {
    const items = [
      { content: { text: 'a' }, privacyLevel: 'open', authorized: false },
      { content: { text: 'b', source: 'X' }, privacyLevel: 'summary', authorized: false },
      { content: { text: 'c' }, privacyLevel: 'blocked', authorized: false },
    ];
    const results = filterBatch(items);
    assertTrue(results[0].filtered.passed);
    assertTrue(results[1].filtered.passed);
    assertEqual(results[2].filtered.passed, false);
  });
});

describe('PrivacyFilter - 未知级别', function () {
  it('未知级别 → 阻断', function () {
    const r = filterContent({ text: 'x' }, 'invalid', false);
    assertEqual(r.passed, false);
  });
});
