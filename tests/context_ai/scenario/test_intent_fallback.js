'use strict';
/**
 * IntentFallbackPlugin 关键词匹配与路由 场景测试
 * 对应: IntentFallbackPlugin — 无 function tag 时的关键词意图识别
 *
 * 场景覆盖:
 *   1. "寻找附近餐厅" (无 function) → maps
 *   2. "查看天气预报" (无 function) → weather
 *   3. "播放音乐" (无 function) → music
 *   4. "设置闹钟" (无 function) → clock
 *   5. "查看运动步数" (无 function) → health
 *   6. 有 function tag → canHandle 返回 false
 *   7. 无匹配关键词 → canHandle 返回 false
 *   8. "导航回家" (无 function) → maps
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertFalse
} = require('../../lib/assert');

// ============================================================
// JS mirror: IntentFallbackPlugin
// ============================================================

/**
 * Keyword → app intent mapping.
 * Each entry: { keywords: string[], app: string }
 */
const INTENT_KEYWORD_MAP = [
  { keywords: ['餐厅', '美食', '附近'], app: 'maps' },
  { keywords: ['天气', '温度'],          app: 'weather' },
  { keywords: ['音乐', '歌'],            app: 'music' },
  { keywords: ['日历', '日程'],          app: 'calendar' },
  { keywords: ['闹钟', '提醒'],          app: 'clock' },
  { keywords: ['运动', '步数'],          app: 'health' },
  { keywords: ['路线', '导航'],          app: 'maps' },
];

/**
 * Check if text contains any keyword from a keyword list.
 */
function matchKeywords(text, keywords) {
  for (const kw of keywords) {
    if (text.includes(kw)) return true;
  }
  return false;
}

/**
 * Find the matching app intent for a given text.
 * Returns the app name if a keyword matches, or null if none match.
 */
function findIntent(text) {
  for (const entry of INTENT_KEYWORD_MAP) {
    if (matchKeywords(text, entry.keywords)) {
      return entry.app;
    }
  }
  return null;
}

/**
 * canHandle() — returns true only when:
 *   1. NO function tag is present (functionTag is falsy/empty)
 *   2. Target text contains at least one known intent keyword
 *
 * If a function tag exists, SmartActionPlugin handles it instead → returns false.
 *
 * @param {string} text        - the user's target text
 * @param {string} functionTag - function tag from LLM, if any
 * @returns {boolean}
 */
function canHandle(text, functionTag) {
  // If function tag exists → SmartActionPlugin handles it
  if (functionTag && functionTag.length > 0) {
    return false;
  }

  // Check for keyword match
  return findIntent(text) !== null;
}

/**
 * route() — returns the target app for the given text.
 * Should only be called after canHandle() returns true.
 *
 * @param {string} text - the user's target text
 * @returns {string|null} - the app to route to
 */
function route(text) {
  return findIntent(text);
}

// ============================================================
// Tests
// ============================================================

describe('场景: 关键词匹配路由 (无 function tag)', function () {
  it('"寻找附近餐厅" → maps', function () {
    const text = '寻找附近餐厅';
    assertTrue(canHandle(text, ''),
      'should handle: contains 附近 and 餐厅');
    assertEqual(route(text), 'maps',
      'should route to maps for restaurant/nearby keywords');
  });

  it('"查看天气预报" → weather', function () {
    const text = '查看天气预报';
    assertTrue(canHandle(text, ''),
      'should handle: contains 天气');
    assertEqual(route(text), 'weather',
      'should route to weather app');
  });

  it('"播放音乐" → music', function () {
    const text = '播放音乐';
    assertTrue(canHandle(text, ''),
      'should handle: contains 音乐');
    assertEqual(route(text), 'music',
      'should route to music app');
  });

  it('"设置闹钟" → clock', function () {
    const text = '设置闹钟';
    assertTrue(canHandle(text, ''),
      'should handle: contains 闹钟');
    assertEqual(route(text), 'clock',
      'should route to clock app');
  });

  it('"查看运动步数" → health', function () {
    const text = '查看运动步数';
    assertTrue(canHandle(text, ''),
      'should handle: contains 运动 and 步数');
    assertEqual(route(text), 'health',
      'should route to health app');
  });

  it('"导航回家" → maps', function () {
    const text = '导航回家';
    assertTrue(canHandle(text, ''),
      'should handle: contains 导航');
    assertEqual(route(text), 'maps',
      'should route to maps for navigation keyword');
  });
});

describe('场景: function tag 存在 → canHandle 返回 false', function () {
  it('有 function tag "morning_briefing" → false', function () {
    assertFalse(canHandle('寻找附近餐厅', 'morning_briefing'),
      'should NOT handle when function tag exists (SmartActionPlugin handles it)');
  });

  it('有 function tag "play_music" → false (即使文本匹配)', function () {
    assertFalse(canHandle('播放音乐', 'play_music'),
      'should NOT handle even when text matches, if function tag is present');
  });

  it('有 function tag 任意字符串 → false', function () {
    assertFalse(canHandle('设置闹钟', 'some_function'),
      'any non-empty function tag should cause canHandle to return false');
  });
});

describe('场景: 无匹配关键词 → canHandle 返回 false', function () {
  it('"你好世界" → false (无匹配关键词)', function () {
    assertFalse(canHandle('你好世界', ''),
      'no keyword match should return false');
    assertEqual(route('你好世界'), null,
      'no keyword match should route to null');
  });

  it('"今天心情不错" → false', function () {
    assertFalse(canHandle('今天心情不错', ''),
      'casual text without intent keywords should return false');
  });

  it('空字符串 → false', function () {
    assertFalse(canHandle('', ''),
      'empty text should return false');
  });
});

describe('场景: 边界与多关键词情况', function () {
  it('"美食推荐" → maps (美食关键词)', function () {
    assertTrue(canHandle('美食推荐', ''),
      'should handle: contains 美食');
    assertEqual(route('美食推荐'), 'maps',
      'should route to maps for food keyword');
  });

  it('"查看日程安排" → calendar', function () {
    assertTrue(canHandle('查看日程安排', ''),
      'should handle: contains 日程');
    assertEqual(route('查看日程安排'), 'calendar',
      'should route to calendar app');
  });

  it('"今天温度多少" → weather (温度关键词)', function () {
    assertTrue(canHandle('今天温度多少', ''),
      'should handle: contains 温度');
    assertEqual(route('今天温度多少'), 'weather',
      'should route to weather for temperature keyword');
  });

  it('"听一首歌" → music (歌关键词)', function () {
    assertTrue(canHandle('听一首歌', ''),
      'should handle: contains 歌');
    assertEqual(route('听一首歌'), 'music',
      'should route to music for song keyword');
  });

  it('"设置提醒事项" → clock (提醒关键词)', function () {
    assertTrue(canHandle('设置提醒事项', ''),
      'should handle: contains 提醒');
    assertEqual(route('设置提醒事项'), 'clock',
      'should route to clock for reminder keyword');
  });

  it('文本含多个意图关键词 → 匹配第一个', function () {
    // "附近有好听的音乐餐厅" contains 附近 (maps) and 音乐 (music)
    // First match wins: 附近 → maps
    const text = '附近有好听的音乐餐厅';
    assertTrue(canHandle(text, ''));
    assertEqual(route(text), 'maps',
      'should match first keyword group in priority order (maps before music)');
  });

  it('function tag 为 null/undefined → 视为无 function tag', function () {
    assertTrue(canHandle('播放音乐', null),
      'null function tag should be treated as absent');
    assertTrue(canHandle('播放音乐', undefined),
      'undefined function tag should be treated as absent');
  });

  it('"查看路线" → maps (路线关键词)', function () {
    assertTrue(canHandle('查看路线', ''),
      'should handle: contains 路线');
    assertEqual(route('查看路线'), 'maps',
      'should route to maps for route keyword');
  });
});
