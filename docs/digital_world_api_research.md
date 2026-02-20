# Digital World Perception — HarmonyOS API Research

> **Project**: ClawdBot Context Intelligence Engine
> **Target SDK**: HarmonyOS 6.0.2 (API 22)
> **Date**: 2026-02-19
> **Author**: Claude (automated research)

## Overview

The context intelligence engine currently perceives the **physical world** (GPS, motion, battery, WiFi).
This document researches HarmonyOS APIs for a **digital world** perception layer that reads:
notifications, calendar events, app usage patterns, media state, screen state, and more.

### Feasibility Summary

| Capability | Feasibility | API Module | Permission Level |
|---|---|---|---|
| Notification Listening | ❌ Not available | `notificationSubscribe` | system_core |
| Calendar Reading | ✅ Available | `@kit.CalendarKit` | user_grant |
| App Usage Stats | ❌ Not available | `usageStatistics` | system_basic |
| Call Log / SMS | ❌ Not available | Contact DataAbility | system_basic |
| Media Playback | ⚠️ Limited | `@kit.AVSessionKit` | system_basic (controller) |
| Clipboard | ✅ Available | `@kit.BasicServicesKit` pasteboard | none (read own) |
| Screen State | ⚠️ Limited | `@kit.BasicServicesKit` screenLock | none (query) / system (events) |
| App Foreground | ❌ Not available | `appManager` | system_basic |

---

## a) Notification Listening

**Goal**: Read notifications from other apps (WeChat, SMS, phone calls).

### API Research

- **Module**: `@kit.NotificationKit` — `notificationSubscribe`
- **Key API**: `notificationSubscribe.subscribe(subscriber, callback)`
- **Permission**: `ohos.permission.NOTIFICATION_CONTROLLER`
- **Permission Level**: **system_core** — only pre-installed system apps
- **API Level**: API 7+

### Assessment: ❌ Not Available

HarmonyOS's `notificationSubscribe` API requires `ohos.permission.NOTIFICATION_CONTROLLER` which is
a **system_core** permission. This means:

- Only system apps (pre-installed by OEM) can use this API
- Third-party apps from AppGallery **cannot** request this permission
- There is no equivalent to Android's `NotificationListenerService` for third-party apps

This is a deliberate HarmonyOS security design — user notifications are considered highly sensitive.

### Code Snippet (for reference — won't work for third-party apps)

```typescript
// ⚠️ SYSTEM APP ONLY — requires ohos.permission.NOTIFICATION_CONTROLLER
import { notificationSubscribe } from '@kit.NotificationKit';

let subscriber: notificationSubscribe.NotificationSubscriber = {
  onConsume: (data: notificationSubscribe.SubscribeCallbackData) => {
    let request = data.request;
    let title = request.content?.normal?.title ?? '';
    let text = request.content?.normal?.text ?? '';
    let bundle = data.request.creatorBundleName ?? '';
    console.info(`Notification from ${bundle}: ${title} - ${text}`);
  },
  onCancel: (data: notificationSubscribe.SubscribeCallbackData) => {
    console.info(`Notification cancelled: ${data.request.id}`);
  }
};

// This call will fail with permission denied for third-party apps
notificationSubscribe.subscribe(subscriber);
```

### Alternatives

1. **Accessibility Service**: HarmonyOS has `@ohos.accessibility` but it also requires system-level
   configuration and user explicitly enabling it in Settings. Feasible but requires user action.
2. **Self-notifications only**: We can track notifications that OUR app sends via `notificationManager`,
   but not other apps' notifications.
3. **Intent-based**: Some apps support sharing via `Want`/deeplinks, but this is app-specific.

### Privacy Considerations

- Notification content can contain sensitive information (messages, OTPs, financial data)
- HarmonyOS's restriction is a reasonable privacy measure
- If we had access, we would need explicit user opt-in and content filtering

---

## b) Calendar Reading

**Goal**: Read upcoming calendar events to understand user schedule.

### API Research

- **Module**: `@kit.CalendarKit` — `calendarManager`
- **Key APIs**:
  - `calendarManager.getCalendarManager(context)` — get manager instance
  - `mgr.getAllCalendars()` — list all calendar accounts
  - `calendar.getEvents(filter)` — query events with filter
  - `calendarManager.EventFilter.filterByTime(start, end)` — time range filter
- **Permissions**: `ohos.permission.READ_CALENDAR` (user_grant)
- **Permission Level**: **user_grant** — user must approve at runtime
- **API Level**: API 10+

### Assessment: ✅ Available

This API is **already proven working** in the project. `AIService.ets` uses it for the `list_events`
tool capability. The permissions (`READ_CALENDAR`, `WRITE_CALENDAR`) are already declared in
`module.json5`.

### Code Snippet

```typescript
import { calendarManager } from '@kit.CalendarKit';
import { abilityAccessCtrl } from '@kit.AbilityKit';

// Request permission
let atManager = abilityAccessCtrl.createAtManager();
await atManager.requestPermissionsFromUser(context,
  ['ohos.permission.READ_CALENDAR']);

// Get calendar manager
let calMgr = calendarManager.getCalendarManager(context);

// Query events in next 2 hours
let now = Date.now();
let twoHoursLater = now + 2 * 60 * 60 * 1000;
let filter = calendarManager.EventFilter.filterByTime(now, twoHoursLater);

// Query all calendars
let allCals: calendarManager.Calendar[] = await calMgr.getAllCalendars();
for (let cal of allCals) {
  let events: calendarManager.Event[] = await cal.getEvents(filter);
  for (let ev of events) {
    let title = ev.title ?? '';
    let start = new Date(ev.startTime).toISOString();
    let end = new Date(ev.endTime).toISOString();
    let location = ev.location?.location ?? '';
    let description = ev.description ?? '';
  }
}
```

### Available Event Fields

- `title: string` — event title
- `startTime: number` — start timestamp (ms)
- `endTime: number` — end timestamp (ms)
- `location?: { location: string }` — location info
- `description?: string` — event description
- `type: calendarManager.EventType` — NORMAL, etc.
- `attendees?: Attendee[]` — participants (if available)

### Privacy Considerations

- Calendar data is personal — user must grant permission at runtime
- We only read, never modify (READ_CALENDAR only)
- Should only query near-future events (next 2 hours) to minimize data exposure
- Event details should not be logged in full

---

## c) App Usage Statistics

**Goal**: Get recently used apps, screen time, app launch frequency.

### API Research

- **Module**: `@ohos.resourceschedule.usageStatistics` (or `@kit.BackgroundTasksKit`)
- **Key APIs**:
  - `usageStatistics.queryBundleActiveStates(begin, end)` — app activity in time range
  - `usageStatistics.queryCurrentBundleActiveState()` — current app info
  - `usageStatistics.queryBundleStateInfoByInterval(...)` — aggregate stats
- **Permission**: `ohos.permission.BUNDLE_ACTIVE_INFO`
- **Permission Level**: **system_basic** — not available to third-party apps
- **API Level**: API 9+

### Assessment: ❌ Not Available

The `BUNDLE_ACTIVE_INFO` permission is `system_basic` level, meaning only pre-installed system apps
or apps signed with the system certificate can access usage statistics. Third-party apps cannot:
- Query which apps the user has opened
- Get screen time data
- See app launch frequency

### Code Snippet (for reference — system apps only)

```typescript
// ⚠️ SYSTEM APP ONLY — requires ohos.permission.BUNDLE_ACTIVE_INFO
import { usageStatistics } from '@kit.BackgroundTasksKit';

let begin = Date.now() - 24 * 60 * 60 * 1000; // 24 hours ago
let end = Date.now();

let states = await usageStatistics.queryBundleActiveStates(begin, end);
for (let state of states) {
  console.info(`App: ${state.bundleName}, Event: ${state.appUsagePriorityGroup}`);
}
```

### Alternatives

1. **Self-tracking**: Track when OUR app goes foreground/background using `UIAbility` lifecycle
   callbacks (`onForeground`, `onBackground`).
2. **User-reported**: Ask the user to manually report their habits or integrate with
   HarmonyOS's Digital Wellbeing settings (no API for this).

### Privacy Considerations

- App usage data reveals behavior patterns, routines, and interests
- HarmonyOS correctly restricts this to system-level access
- If available, should be aggregated (not raw event streams)

---

## d) Call Log / SMS

**Goal**: Read recent calls (missed call count) and unread messages.

### API Research

- **Call Log**:
  - **Module**: `@ohos.telephony.call` (limited) / Contact DataAbility
  - **Permission**: `ohos.permission.READ_CALL_LOG`
  - **Permission Level**: **system_basic** — not available to third-party apps

- **SMS**:
  - **Module**: `@ohos.telephony.sms`
  - **Permission**: `ohos.permission.RECEIVE_SMS` / `ohos.permission.READ_MESSAGES`
  - **Permission Level**: **system_basic** — not available to third-party apps

### Assessment: ❌ Not Available

Both call log reading and SMS reading require system-level permissions in HarmonyOS:

- `ohos.permission.READ_CALL_LOG` — system_basic
- `ohos.permission.READ_MESSAGES` — system_basic
- `ohos.permission.RECEIVE_SMS` — system_basic

Third-party apps cannot access call history or SMS content. This is consistent with HarmonyOS's
strong privacy model.

### Alternatives

1. **Telephony state only**: `@ohos.telephony.observer` can observe call state changes
   (ringing, off-hook, idle) without reading call log — but this requires
   `ohos.permission.READ_CALL_LOG` too, so still system-only.
2. **User opt-in reporting**: User manually reports missed calls or integrates with notification
   (but we can't read notifications either).

### Privacy Considerations

- Call logs and SMS are among the most sensitive personal data
- HarmonyOS's restriction aligns with privacy best practices
- Even if available, should default to DISABLED with explicit opt-in

---

## e) Media Playback State

**Goal**: Detect if music/video is playing, get current track info.

### API Research

- **Module**: `@kit.AVSessionKit` — `avSession`
- **Key APIs**:
  - `avSession.getAllSessionDescriptors()` — list active media sessions
  - `avSession.createController(sessionId)` — create controller for a session
  - `controller.getAVMetadata()` — get track info (title, artist, album)
  - `controller.getAVPlaybackState()` — get playback state (playing/paused)
- **Permission for controller**: `ohos.permission.MANAGE_MEDIA_RESOURCES`
- **Permission Level**: **system_basic** — controller creation requires system permission
- **API Level**: API 10+

### Assessment: ⚠️ Limited

The AVSession API has a split permission model:
- **Creating a session** (as a media app): Available to all apps — no special permission
- **Controlling/reading other apps' sessions**: Requires `ohos.permission.MANAGE_MEDIA_RESOURCES`
  (system_basic) — not available to third-party apps

However, there is a partial workaround:
- We can check if OUR app has an active audio session
- We can detect audio focus changes via `@kit.AudioKit` — `audio.AudioManager`
- `audioManager.getAudioScene()` returns the current audio scene (e.g., `AUDIO_SCENE_VOICE_CHAT`)

### Code Snippet (partial — audio scene detection)

```typescript
import { audio } from '@kit.AudioKit';

// Check current audio scene — works without special permissions
let audioManager = audio.getAudioManager();
let scene = await audioManager.getAudioScene();
// AUDIO_SCENE_DEFAULT, AUDIO_SCENE_RINGING, AUDIO_SCENE_PHONE_CALL, AUDIO_SCENE_VOICE_CHAT

// Audio routing info
let routingManager = audioManager.getRoutingManager();
let devices = routingManager.getDevicesSync(audio.DeviceFlag.OUTPUT_DEVICES_FLAG);
for (let i = 0; i < devices.length; i++) {
  let dev = devices[i];
  // dev.deviceType: SPEAKER, WIRED_HEADSET, BLUETOOTH_A2DP, etc.
}
```

### What we CAN detect

- Audio scene (default, ringing, phone call, voice chat) — useful for "don't disturb" detection
- Audio output device (speaker, headphones, Bluetooth) — useful context signal
- Audio renderer state change (if we create our own audio renderer)

### Privacy Considerations

- Media playback data is moderate sensitivity
- Track info from other apps not accessible (good for privacy)
- Audio scene is acceptable — tells us "a call is happening" without content

---

## f) Clipboard / Pasteboard

**Goal**: Read recently copied content.

### API Research

- **Module**: `@kit.BasicServicesKit` — `pasteboard`
- **Key APIs**:
  - `pasteboard.getSystemPasteboard()` — get system pasteboard
  - `systemPasteboard.getData()` — read current clipboard content
  - `systemPasteboard.on('update', callback)` — listen for clipboard changes
  - `pasteData.getPrimaryText()` — get text content
  - `pasteData.getPrimaryMimeType()` — get content type
- **Permission**: None required for reading your own app's clipboard data
- **API Level**: API 7+

### Assessment: ✅ Available (but privacy-sensitive — SKIP by default)

The pasteboard API is available to all apps without special permissions. However:

- Starting from API 12+, HarmonyOS may show a toast/popup when an app reads the clipboard
  in the background (similar to iOS clipboard transparency)
- Clipboard content is extremely sensitive (passwords, OTPs, personal messages)
- **Recommendation**: Do NOT implement this plugin. Document it as available but skip.

### Code Snippet

```typescript
import { pasteboard } from '@kit.BasicServicesKit';

let systemPasteboard = pasteboard.getSystemPasteboard();

// Read current clipboard
let hasData = await systemPasteboard.hasData();
if (hasData) {
  let pasteData = await systemPasteboard.getData();
  let mimeType = pasteData.getPrimaryMimeType();
  if (mimeType === 'text/plain') {
    let text = pasteData.getPrimaryText();
    // text contains clipboard content
  }
}

// Listen for clipboard changes
systemPasteboard.on('update', () => {
  // Clipboard was updated
});
```

### Privacy Considerations

- **Privacy Level: 🔴 CRITICAL** — clipboard may contain passwords, auth tokens, financial data
- HarmonyOS shows transparency notification when apps access clipboard
- **Decision: SKIP** — too privacy-invasive for a context engine
- If ever implemented, must be explicitly opt-in with clear disclosure

---

## g) Screen State

**Goal**: Detect if screen is on/off, locked/unlocked.

### API Research

- **Module**: `@kit.BasicServicesKit` — `screenLock` + `@kit.ArkUI` — `display`
- **Key APIs**:
  - `screenLock.isLocked()` — check if screen is locked (sync, no permission)
  - `display.getDefaultDisplaySync().state` — screen on/off via DisplayState enum (no permission)
  - `screenLock.onSystemEvent(callback)` — listen for lock/unlock events (system_core only)
  - `commonEventManager` — subscribe to `COMMON_EVENT_SCREEN_ON/OFF/LOCKED/UNLOCKED` (no permission!)
- **Permission for queries**: None required
- **Permission for `onSystemEvent()`**: `ohos.permission.ACCESS_SCREEN_LOCK_INNER` — system_core
- **Permission for `commonEventManager` screen events**: None required ✅
- **API Level**: API 9+ (query), API 10+ (display.state)

### Assessment: ✅ Available (polling + event-based)

- **Querying state**: `screenLock.isLocked()` + `display.getDefaultDisplaySync()` works without permissions ✅
- **Event-based**: `commonEventManager.subscribe()` for screen events works without system permission ✅
- **`onSystemEvent()`**: requires system_core permission ❌ (but `commonEventManager` is a valid alternative)

### Code Snippet (polling — implemented in ScreenStatePlugin)

```typescript
import { screenLock } from '@kit.BasicServicesKit';
import { display } from '@kit.ArkUI';

// Check lock state — no permission needed
let locked = screenLock.isLocked();

// Check screen on/off via display API — no permission needed
let defaultDisplay = display.getDefaultDisplaySync();
let screenOn = defaultDisplay.state === display.DisplayState.STATE_ON;
// DisplayState: STATE_ON, STATE_OFF, STATE_ON_SUSPEND, STATE_UNKNOWN
```

### Code Snippet (event-based — available for future use)

```typescript
import { commonEventManager } from '@kit.BasicServicesKit';

// Subscribe to screen events — available to third-party apps!
let subscriber = await commonEventManager.createSubscriber({
  events: [
    commonEventManager.Support.COMMON_EVENT_SCREEN_ON,
    commonEventManager.Support.COMMON_EVENT_SCREEN_OFF,
    commonEventManager.Support.COMMON_EVENT_SCREEN_LOCKED,
    commonEventManager.Support.COMMON_EVENT_SCREEN_UNLOCKED,
  ]
});

commonEventManager.subscribe(subscriber, (err, data) => {
  if (err) return;
  // data.event contains the event type
  // Can push to context engine: engine.pushEvent('screen_on') etc.
});
```

### Privacy Considerations

- Screen state is low sensitivity
- Useful for determining "is user actively using the device?"
- Polling-based approach is acceptable (every 30 seconds)
- Event-based approach via `commonEventManager` enables real-time context triggers

### Additional: Call State Detection (bonus)

HarmonyOS also provides call state detection without special permissions:

```typescript
import { call } from '@kit.TelephonyKit';

// Get current call state — no permission needed
let state = call.getCallStateSync();
// CALL_STATE_IDLE = 0, CALL_STATE_RINGING = 1, CALL_STATE_OFFHOOK = 2
// Note: phone number is NOT available without READ_CALL_LOG (system_basic)
```

This is leveraged by the `MediaStatePlugin` via `audio.getAudioScene()` which detects
`AUDIO_SCENE_PHONE_CALL` and `AUDIO_SCENE_RINGING` states.

---

## h) App Foreground Detection

**Goal**: Know which app is currently in the foreground.

### API Research

- **Module**: `@ohos.app.ability.appManager`
- **Key API**: `appManager.getForegroundApplications()`
- **Permission**: `ohos.permission.GET_RUNNING_INFO`
- **Permission Level**: **system_basic** — not available to third-party apps
- **API Level**: API 9+

### Assessment: ❌ Not Available

The `GET_RUNNING_INFO` permission is system_basic. Third-party apps cannot query which app
is in the foreground.

### Alternatives

1. **Self-awareness only**: Use `UIAbility.onForeground()` / `onBackground()` to track when
   OUR app is in the foreground.
2. **Window focus**: We can detect when our app's window gains/loses focus, but cannot see
   what app took focus.

### Code Snippet (self-awareness only)

```typescript
// In UIAbility lifecycle — detect OUR app going foreground/background
import { UIAbility } from '@kit.AbilityKit';

export default class EntryAbility extends UIAbility {
  onForeground() {
    // Our app is now in foreground
    // Push event: 'app_foreground'
  }

  onBackground() {
    // Our app went to background
    // Push event: 'app_background'
  }
}
```

### Privacy Considerations

- Foreground app data reveals real-time user activity
- HarmonyOS correctly restricts this to system apps

---

## Implementation Plan

Based on the research above, here are the plugins we CAN implement:

### Implementable Plugins

| Plugin | API | Usefulness | Default State |
|---|---|---|---|
| `CalendarPlugin` | `@kit.CalendarKit` | High — upcoming meetings/events | Enabled |
| `ScreenStatePlugin` | `screenLock.isLocked()` | Medium — user activity detection | Enabled |
| `MediaStatePlugin` | `audio.getAudioScene()` | Medium — don't-disturb detection | Enabled |

### Skipped (privacy or system-only)

| Capability | Reason |
|---|---|
| Notification Listening | system_core permission required |
| App Usage Stats | system_basic permission required |
| Call Log / SMS | system_basic permission required |
| Clipboard | Available but too privacy-invasive |
| App Foreground | system_basic permission required |

### Key Insight

HarmonyOS has a much stricter permission model than Android. Most "digital world" APIs that are
available on Android (NotificationListener, UsageStatsManager, CallLog) are restricted to system
apps on HarmonyOS. The three feasible plugins (Calendar, Screen State, Media State) provide
meaningful context signals while respecting privacy boundaries.
