'use strict';
/**
 * Functional test: Recommendation delivery logic.
 *
 * Mirrors the recommendation listener in NodeRuntime.ets (lines 585-777)
 * and the dispatchChatEvent / notification logic.
 *
 * Validates:
 *   - ChatPage visible → NO chat event, NO notification (A2UI card handles display)
 *   - ChatPage not visible, foreground → chat event dispatched + notification sent
 *   - ChatPage not visible, background → chat event dispatched + notification sent
 *   - Chat events use correct GatewayChatEvent structure
 *   - Pending chat events buffer when no listeners (mirrors _pendingChatEvents)
 *   - Geofence suggestion notification expands to foreground-non-chat case
 */

const { describe, it, beforeEach } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertFalse, assertDefined, assertStartsWith,
  assertGreaterThan,
} = require('../../lib/assert');

// --- Mirror of recommendation delivery from NodeRuntime.ets ---

const MAX_PENDING_EVENTS = 50;

class RecommendationDeliverySimulator {
  constructor() {
    this._isInForeground = true;           // line 246
    this._isChatPageVisible = false;       // line 247
    this._chatListeners = [];              // line 196
    this._pendingChatEvents = [];          // line 260

    // Mock tracking
    this.dispatchedChatEvents = [];
    this.sentNotifications = [];
  }

  setChatPageVisible(visible) {
    this._isChatPageVisible = visible;
  }

  setForegroundState(inForeground) {
    this._isInForeground = inForeground;
  }

  addChatListener(listener) {
    this._chatListeners.push(listener);
    // Replay pending events (mirrors line 930-942)
    if (this._pendingChatEvents.length > 0) {
      const pending = this._pendingChatEvents.splice(0);
      for (const ev of pending) {
        try { listener(ev); } catch (_e) { /* ignore */ }
      }
    }
  }

  removeChatListener(listener) {
    const idx = this._chatListeners.indexOf(listener);
    if (idx >= 0) this._chatListeners.splice(idx, 1);
  }

  // Mirror of dispatchChatEvent (lines 1169-1185)
  dispatchChatEvent(event) {
    this.dispatchedChatEvents.push(event);
    if (this._chatListeners.length === 0) {
      this._pendingChatEvents.push(event);
      if (this._pendingChatEvents.length > MAX_PENDING_EVENTS) {
        this._pendingChatEvents.shift();
      }
    } else {
      for (const listener of this._chatListeners) {
        try { listener(event); } catch (_e) { /* ignore */ }
      }
    }
  }

  // Mirror of notification send
  sendNotification(title, text) {
    this.sentNotifications.push({ title, text });
  }

  // Mirror of recommendation listener logic (lines 761-777)
  onRecommendation(ruleName, reason) {
    if (!this._isChatPageVisible) {
      // ChatPage 不可见：投递为持久 chat message
      const text = `💡 **${ruleName}**\n${reason}`;
      const event = {
        runId: `ctx-rec-${Date.now()}`,
        sessionKey: '',
        seq: 0,
        state: 'final',
        message: {
          role: 'assistant',
          content: [{ type: 'text', text }],
        },
      };
      this.dispatchChatEvent(event);
      // 同时发送系统通知
      this.sendNotification('💡 context.notification.title', reason);
    }
    // ChatPage 可见时：A2UI 卡片由 stateChangeListener 处理（不在此处）
  }

  // Mirror of geofence suggestion notification (line 800-801)
  onGeofenceSuggestion(suggestions) {
    // dispatchChatEvent for each suggestion (always, like original code)
    for (let i = 0; i < suggestions.length; i++) {
      const s = suggestions[i];
      const text = `📍 discovered: ${s.name}\n${s.reason}`;
      const event = {
        runId: `suggest-${Date.now()}-${i}`,
        sessionKey: '',
        seq: 0,
        state: 'final',
        message: { role: 'assistant', content: [{ type: 'text', text }] },
      };
      this.dispatchChatEvent(event);
    }
    // Notification when ChatPage not visible (expanded condition)
    if ((!this._isInForeground || !this._isChatPageVisible) && suggestions.length > 0) {
      this.sendNotification('📍 discoveredPlace', `${suggestions[0].name} — ${suggestions[0].reason}`);
    }
  }
}

// --- Tests ---

describe('Recommendation delivery - ChatPage visible', function () {
  let sim;
  beforeEach(function () {
    sim = new RecommendationDeliverySimulator();
    sim.setForegroundState(true);
    sim.setChatPageVisible(true);
  });

  it('does NOT dispatch chat event when ChatPage visible', function () {
    sim.onRecommendation('久坐提醒', '您已静坐超过40分钟');
    assertEqual(sim.dispatchedChatEvents.length, 0, 'no chat event when ChatPage visible');
  });

  it('does NOT send notification when ChatPage visible', function () {
    sim.onRecommendation('久坐提醒', '您已静坐超过40分钟');
    assertEqual(sim.sentNotifications.length, 0, 'no notification when ChatPage visible');
  });
});

describe('Recommendation delivery - foreground, ChatPage NOT visible', function () {
  let sim;
  beforeEach(function () {
    sim = new RecommendationDeliverySimulator();
    sim.setForegroundState(true);
    sim.setChatPageVisible(false);
  });

  it('dispatches chat event as persistent message', function () {
    sim.onRecommendation('就寝提醒', '已经23:00了，建议准备休息');
    assertEqual(sim.dispatchedChatEvents.length, 1, 'should dispatch one chat event');
    const ev = sim.dispatchedChatEvents[0];
    assertEqual(ev.state, 'final');
    assertDefined(ev.message);
    assertEqual(ev.message.role, 'assistant');
    assertEqual(ev.message.content.length, 1);
    assertEqual(ev.message.content[0].type, 'text');
    assertTrue(ev.message.content[0].text.includes('就寝提醒'), 'should contain rule name');
    assertTrue(ev.message.content[0].text.includes('23:00'), 'should contain reason');
  });

  it('sends system notification', function () {
    sim.onRecommendation('就寝提醒', '已经23:00了');
    assertEqual(sim.sentNotifications.length, 1, 'should send one notification');
    assertEqual(sim.sentNotifications[0].text, '已经23:00了');
  });

  it('chat event runId starts with ctx-rec-', function () {
    sim.onRecommendation('test', 'reason');
    assertStartsWith(sim.dispatchedChatEvents[0].runId, 'ctx-rec-');
  });
});

describe('Recommendation delivery - background', function () {
  let sim;
  beforeEach(function () {
    sim = new RecommendationDeliverySimulator();
    sim.setForegroundState(false);
    sim.setChatPageVisible(false);
  });

  it('dispatches chat event in background', function () {
    sim.onRecommendation('低电量提醒', '电量低于20%');
    assertEqual(sim.dispatchedChatEvents.length, 1);
    assertTrue(sim.dispatchedChatEvents[0].message.content[0].text.includes('低电量提醒'));
  });

  it('sends notification in background', function () {
    sim.onRecommendation('低电量提醒', '电量低于20%');
    assertEqual(sim.sentNotifications.length, 1);
  });
});

describe('Recommendation delivery - pending event buffer', function () {
  let sim;
  beforeEach(function () {
    sim = new RecommendationDeliverySimulator();
    sim.setForegroundState(true);
    sim.setChatPageVisible(false);
    // No chat listener registered (ChatPage not mounted)
  });

  it('buffers chat event when no listeners', function () {
    sim.onRecommendation('久坐提醒', '该站起来走走了');
    assertEqual(sim._pendingChatEvents.length, 1, 'event should be buffered');
  });

  it('replays buffered events when listener registers', function () {
    sim.onRecommendation('久坐提醒', '该站起来走走了');
    sim.onRecommendation('喝水提醒', '记得补充水分');
    assertEqual(sim._pendingChatEvents.length, 2);

    // Simulate ChatPage appearing and registering listener
    const received = [];
    sim.addChatListener((ev) => { received.push(ev); });

    assertEqual(received.length, 2, 'both buffered events should be replayed');
    assertTrue(received[0].message.content[0].text.includes('久坐提醒'));
    assertTrue(received[1].message.content[0].text.includes('喝水提醒'));
    assertEqual(sim._pendingChatEvents.length, 0, 'buffer should be cleared after replay');
  });

  it('buffer respects MAX_PENDING_EVENTS limit', function () {
    for (let i = 0; i < 55; i++) {
      sim.onRecommendation(`rule-${i}`, `reason-${i}`);
    }
    assertEqual(sim._pendingChatEvents.length, MAX_PENDING_EVENTS,
      'buffer should not exceed MAX_PENDING_EVENTS');
  });
});

describe('Geofence suggestion notification - expanded condition', function () {
  let sim;
  beforeEach(function () {
    sim = new RecommendationDeliverySimulator();
  });

  it('no notification when foreground + ChatPage visible', function () {
    sim.setForegroundState(true);
    sim.setChatPageVisible(true);
    sim.onGeofenceSuggestion([{ name: '公司', reason: '您经常在此工作' }]);
    assertEqual(sim.sentNotifications.length, 0, 'no notification when ChatPage visible');
    // But chat event IS dispatched (geofence always dispatches chat event)
    assertEqual(sim.dispatchedChatEvents.length, 1);
  });

  it('sends notification when foreground but ChatPage NOT visible', function () {
    sim.setForegroundState(true);
    sim.setChatPageVisible(false);
    sim.onGeofenceSuggestion([{ name: '公司', reason: '您经常在此工作' }]);
    assertEqual(sim.sentNotifications.length, 1, 'should notify when ChatPage not visible');
    assertEqual(sim.dispatchedChatEvents.length, 1);
  });

  it('sends notification when background', function () {
    sim.setForegroundState(false);
    sim.setChatPageVisible(false);
    sim.onGeofenceSuggestion([{ name: '健身房', reason: '检测到您常来运动' }]);
    assertEqual(sim.sentNotifications.length, 1);
  });

  it('no notification for empty suggestions', function () {
    sim.setForegroundState(false);
    sim.setChatPageVisible(false);
    sim.onGeofenceSuggestion([]);
    assertEqual(sim.sentNotifications.length, 0);
  });
});
