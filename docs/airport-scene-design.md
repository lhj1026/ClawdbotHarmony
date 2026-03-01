# Airport Scene Design / 机场场景设计

## Complete Timeline / 完整时间线

```
出发前 ──→ 到达机场 ──→ 安检后 ──→ 登机口 ──→ 登机 ──→ 起飞 ──→ 落地 ──→ 离开机场
 -24h        T=0       T+20min    T+40min   Board    Depart  Arrive    Exit
```

## Phase 1: Pre-Airport / 出发前 (-24h ~ 到达)

**Trigger / 触发条件:** Calendar event with flight number detected
**数据来源:** TravelInfoService 扫描日历事件

| Time | Action | A2UI Card |
|------|--------|-----------|
| -24h | Parse flight from calendar | (background, no card) |
| -3h | "✈️ 3小时后出发，注意出行准备" | Notification card |
| -2h | "🧳 出发准备提醒：护照/身份证、登机牌、充电宝" | Checklist card |

**Rule:**
```json
{
  "id": "airport_preflight_3h",
  "name": "出发前3小时提醒",
  "conditions": [
    {"key": "flightCountdownMin", "op": "lte", "value": "180"},
    {"key": "flightCountdownMin", "op": "gt", "value": "120"}
  ],
  "action": {"type": "show_info", "payload": "travel"}
}
```

## Phase 2: Arrive at Airport / 到达机场

**Trigger / 触发条件:** WiFi geofence = transit (airport WiFi detected)
**检测方式:** WiFi SSID 匹配机场围栏（如 `Airport_Free_WiFi`, `YVR-WiFi`）

### Card: 登机牌 (Boarding Pass)

```
┌─────────────────────────────────────┐
│ ✈️ 登机牌                           │
│                                     │
│ CA1234  🟢 准时                     │
│ 北京 PEK → 上海 SHA                 │
│                                     │
│ 🕐 14:30  ⏰ 2小时15分钟后出发       │
│ 航站楼 T3 | 登机口 B23 | 座位 12C   │
│                                     │
│ ── 💡 推荐操作 ──                    │
│ 🥇 查看登机牌详情 (90%)              │
│ 🥈 查看航站楼地图 (75%)              │
│ 🥉 开启飞行模式提醒 (60%)            │
│ 🙈 忽略                             │
└─────────────────────────────────────┘
```

**Key behaviors / 关键行为:**
- Auto-show boarding pass when entering airport geofence / 进入机场围栏自动显示登机牌
- Flight info parsed from calendar event / 航班信息从日历解析
- Real-time countdown / 实时倒计时
- Gate/terminal from calendar description or API / 登机口从日历描述解析

## Phase 3: Approaching Boarding / 临近登机

**Trigger:** At airport + countdown < 45 min
**触发:** 在机场 + 倒计时 < 45分钟

### Card: 登机提醒 (Boarding Reminder)

```
┌─────────────────────────────────────┐
│ ⚠️ 即将登机                         │
│                                     │
│ CA1234 北京→上海                     │
│ 🕐 14:30 ⏰ 还有 42 分钟！          │
│ 📍 登机口 B23                       │
│                                     │
│ 🥇 打开登机牌 (95%)                 │  ← Primary action
│ 🙈 忽略                             │
└─────────────────────────────────────┘
```

**Rule:**
```json
{
  "id": "airport_boarding_soon",
  "name": "即将登机提醒",
  "conditions": [
    {"key": "wifiGeofence", "op": "eq", "value": "transit"},
    {"key": "flightCountdownMin", "op": "lte", "value": "45"},
    {"key": "flightCountdownMin", "op": "gt", "value": "10"}
  ],
  "action": {"type": "show_info", "payload": "travel"},
  "priority": 5.0,
  "cooldownMs": 600000
}
```

## Phase 4: Boarding Now / 开始登机

**Trigger:** At airport + countdown < 10 min
**触发:** 在机场 + 倒计时 < 10分钟

### Card: 紧急登机 (Urgent Boarding)

```
┌─────────────────────────────────────┐
│ 🔴 立即登机！                        │
│                                     │
│ CA1234 → 登机口 B23                  │
│ ⏰ 还有 8 分钟！                     │
│                                     │
│ 🥇 打开登机牌 🔴 (99%)              │  ← Urgent primary
│ 🙈 忽略                             │
└─────────────────────────────────────┘
```

**Urgency escalation / 紧急度升级:**
- `> 45 min`: Normal notification (blue) / 普通通知
- `10-45 min`: Warning (yellow) / 警告
- `< 10 min`: Urgent (red) + vibration / 紧急 + 震动

## Phase 5: Takeoff / 起飞

**Trigger:** At airport + flight departure time reached + motion=stationary (seated)
**触发:** 在机场 + 航班起飞时间到达 + 静止状态

### Card: 飞行模式提醒

```
┌─────────────────────────────────────┐
│ 🛫 即将起飞                          │
│                                     │
│ CA1234 北京→上海 预计 2h10min        │
│                                     │
│ 🥇 开启飞行模式 ✈️ (95%)            │
│ 🙈 忽略                             │
└─────────────────────────────────────┘
```

**Action:** `ModeChangePlugin` → `set_mode: flight`

**Rule:**
```json
{
  "id": "airport_takeoff_flight_mode",
  "name": "起飞开启飞行模式",
  "conditions": [
    {"key": "wifiGeofence", "op": "eq", "value": "transit"},
    {"key": "flightCountdownMin", "op": "lte", "value": "0"},
    {"key": "flightCountdownMin", "op": "gte", "value": "-30"},
    {"key": "motionState", "op": "eq", "value": "stationary"}
  ],
  "action": {"type": "set_mode", "payload": "flight"},
  "priority": 6.0,
  "cooldownMs": 86400000
}
```

## Phase 6: Landing / 落地

**Trigger:** Flight mode active + arrival time reached (from calendar end time)
**触发:** 飞行模式中 + 到达时间到 (从日历结束时间推断)

### Card: 到达提醒

```
┌─────────────────────────────────────┐
│ 🛬 已到达上海                        │
│                                     │
│ CA1234 北京→上海                     │
│                                     │
│ 🥇 关闭飞行模式 📱 (95%)            │
│ 🥈 查看行李转盘 (70%)               │
│ 🙈 忽略                             │
└─────────────────────────────────────┘
```

**Rule:**
```json
{
  "id": "airport_landing",
  "name": "落地关闭飞行模式",
  "conditions": [
    {"key": "flightArrivalMin", "op": "lte", "value": "10"},
    {"key": "flightArrivalMin", "op": "gte", "value": "-30"}
  ],
  "action": {"type": "set_mode", "payload": "normal"},
  "priority": 6.0,
  "cooldownMs": 86400000
}
```

## Phase 7: Exit Airport / 离开机场

**Trigger:** Was at airport + WiFi disconnected + networkType changes
**触发:** 之前在机场 + WiFi 断开

### Card: 离开机场

```
┌─────────────────────────────────────┐
│ 🏁 已离开机场                        │
│                                     │
│ 🥇 叫车/查看交通 (85%)              │
│ 🥈 查看目的地天气 (70%)             │
│ 🙈 忽略                             │
└─────────────────────────────────────┘
```

## Implementation Plan / 实现计划

### Step 1: TravelInfoService Integration / 出行服务集成

TravelInfoService already exists. Need to:

1. **Initialize on CAS startup** — `TravelInfoService.init(context)` in CAS
2. **Periodic flight scan** — Every 30min, scan calendar for flights/trains
3. **Inject flight countdown into DataTray** — New tray keys:
   - `flightCountdownMin`: Minutes until next flight departure
   - `flightArrivalMin`: Minutes until arrival (from calendar end time)
   - `flightNumber`: Current flight number
   - `hasUpcomingFlight`: "true" / "false"

```typescript
// In CAS sensor polling loop:
async injectTravelData(): Promise<void> {
  let flights = await this.travelService.getTodayFlights();
  if (flights.length > 0) {
    let next = flights[0]; // Nearest flight
    let countdownMin = Math.floor((next.departureTime - Date.now()) / 60000);
    this.tray.put('flightCountdownMin', countdownMin.toString());
    this.tray.put('flightNumber', next.flightNumber);
    this.tray.put('hasUpcomingFlight', 'true');
    // Arrival = endTime from calendar
    if (next.calendarEndTime) {
      let arrivalMin = Math.floor((next.calendarEndTime - Date.now()) / 60000);
      this.tray.put('flightArrivalMin', arrivalMin.toString());
    }
  } else {
    this.tray.put('hasUpcomingFlight', 'false');
  }
}
```

### Step 2: New DataTray Keys in C++ / C++ 数据槽

Add to `data_tray.h`:
```cpp
{"flightCountdownMin", 2 * 60 * 1000},   // 2 min TTL (updated every 30s)
{"flightArrivalMin", 2 * 60 * 1000},
{"flightNumber", 30 * 60 * 1000},
{"hasUpcomingFlight", 30 * 60 * 1000},
```

Add to snapshot mapping:
```cpp
auto flightCountdown = getUnlocked("flightCountdownMin");
if (flightCountdown.value.has_value()) {
    snap.flightCountdownMin = flightCountdown.value;
}
```

### Step 3: New Rules / 新规则

Add 6 airport rules to `default_rules.json`:

1. `airport_arrive` — wifiGeofence=transit + hasUpcomingFlight=true → show boarding pass
2. `airport_boarding_soon` — transit + flightCountdownMin ≤ 45 → boarding reminder
3. `airport_boarding_now` — transit + flightCountdownMin ≤ 10 → urgent boarding
4. `airport_takeoff` — transit + flightCountdownMin ≤ 0 → flight mode
5. `airport_landing` — flightArrivalMin ≤ 10 → exit flight mode
6. `airport_exit` — wifiLost + wifiLostCategory=transit → transport suggestions

### Step 4: ModeChangePlugin Enhancement / 模式切换增强

Add `flight` mode to ModeChangePlugin:
```typescript
case 'flight':
  // Enable airplane mode via system API
  // @ohos.telephony.radio → setAirplaneMode(true)
  return { success: true, message: '✈️ 已开启飞行模式' };
```

### Step 5: TravelInfoPlugin A2UI Enhancement / 出行卡片增强

- Add countdown color coding (blue > 45min, yellow 10-45min, red < 10min)
- Add urgency vibration for < 10min
- Boarding pass shows gate/terminal if available

## Data Dependencies / 数据依赖

```
Calendar Event ("CA1234 北京→上海 14:30")
     │
     ▼ TravelInfoService.refresh()
     │
FlightInfo { flightNumber, departure, arrival, departureTime, gate, seat, terminal }
     │
     ▼ CAS.injectTravelData()
     │
DataTray: flightCountdownMin, flightNumber, hasUpcomingFlight, flightArrivalMin
     │
     ▼ C++ RuleEngine.evaluate()
     │
MatchResult: airport_boarding_soon (confidence=0.95)
     │
     ▼ NodeRuntime
     │
A2UI Combined Card: state info + boarding pass + action buttons
```

## Edge Cases / 边界情况

| Scenario | Handling |
|----------|----------|
| Flight delayed | TravelInfoService should check flight status API (future) |
| Gate changed | Re-parse calendar if updated; show "登机口变更" notification |
| Multiple flights same day | Show nearest departure; allow switching |
| No calendar event | No airport rules trigger (hasUpcomingFlight=false) |
| Airport WiFi not learned | First visit: auto-discover + create geofence with category=transit |
| Phone dead during flight | Landing rule uses calendar end time, triggers when phone turns on |
| Connection flight | Show next boarding pass after landing |

## Security & Privacy / 安全与隐私

- All data processed on-device / 所有数据本地处理
- Calendar read requires `ohos.permission.READ_CALENDAR` / 需要日历读取权限
- No flight data sent to server / 不上传航班数据
- User can disable travel rules individually / 用户可单独关闭出行规则
