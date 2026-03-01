# Context Intelligence Architecture / 情景智能架构设计

## Overview / 概述

Context Intelligence is an on-device proactive assistant system that detects user's current situation through multi-sensor fusion and provides contextual recommendations via A2UI cards.

情景智能是一个运行在设备端的主动式助手系统，通过多传感器融合检测用户当前情境，并通过 A2UI 卡片提供上下文相关的推荐。

## System Architecture / 系统架构

```
┌─────────────────────────────────────────────────────────┐
│                    A2UI Rendering Layer                  │
│              (index.html / renderAllSurfaces)            │
├─────────────────────────────────────────────────────────┤
│                    NodeRuntime (Gateway Bridge)          │
│   ┌──────────┐  ┌───────────┐  ┌─────────────────────┐ │
│   │ A2UI     │  │ Feedback  │  │ Action Execution    │ │
│   │ Builder  │  │ Handler   │  │ (ActionRouter)      │ │
│   └──────────┘  └───────────┘  └─────────────────────┘ │
├─────────────────────────────────────────────────────────┤
│              ContextAwarenessService (CAS)               │
│   ┌──────────┐  ┌───────────┐  ┌─────────────────────┐ │
│   │ DataTray │  │ Rule      │  │ Location            │ │
│   │ (C++ ←→  │  │ Engine    │  │ Fusion              │ │
│   │  ArkTS)  │  │ (C++ NAPI)│  │ Service             │ │
│   └──────────┘  └───────────┘  └─────────────────────┘ │
├─────────────────────────────────────────────────────────┤
│                    Sensor Plugins                        │
│   ┌────────┐ ┌──────┐ ┌────┐ ┌──────┐ ┌─────────────┐ │
│   │ WiFi   │ │Motion│ │ BT │ │Battery│ │ Calendar    │ │
│   │ Scanner│ │Sensor│ │    │ │      │ │ Plugin      │ │
│   └────────┘ └──────┘ └────┘ └──────┘ └─────────────┘ │
├─────────────────────────────────────────────────────────┤
│                  Action Plugin System                    │
│   ┌─────────────────────────────────────────────────┐   │
│   │              ActionRouter                        │   │
│   │  ┌──────────┐ ┌──────────┐ ┌──────────────────┐ │   │
│   │  │Notify    │ │ModeChange│ │TravelInfo        │ │   │
│   │  │Plugin    │ │Plugin    │ │Plugin            │ │   │
│   │  └──────────┘ └──────────┘ └──────────────────┘ │   │
│   │  ┌──────────┐ ┌──────────┐ ┌──────────────────┐ │   │
│   │  │AppLaunch │ │QRCode   │ │CalendarInfo      │ │   │
│   │  │Plugin    │ │Plugin    │ │Plugin            │ │   │
│   │  └──────────┘ └──────────┘ └──────────────────┘ │   │
│   └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

## Core Components / 核心组件

### 1. DataTray (数据托盘)

**C++ native module** (`libcontext_engine.so`) that stores all sensor data with TTL-based expiration.

C++ 原生模块，存储所有传感器数据，带 TTL 过期机制。

```
DataTray (C++)
├── put(key, value)        → Store sensor reading / 存储传感器读数
├── get(key) → SlotData    → Read with freshness check / 带新鲜度检查读取
├── getSnapshot()          → All current data as ContextSnapshot / 所有数据快照
└── TTL expiration          → Auto-expire stale data / 自动过期旧数据

ArkTS augmentSnapshot()    → Supplements C++ snapshot with ArkTS-only fields
                             补充 C++ 快照中缺失的 ArkTS 端字段
                             (wifiGeofence, geofence fallback, wifiSsid)
```

**Key data slots / 关键数据槽:**
| Key | Source | TTL | Description |
|-----|--------|-----|-------------|
| batteryLevel | System | 5min | 电量百分比 |
| isCharging | System | 5min | 是否充电 |
| motionState | Motion sensor | 2min | 运动状态 |
| wifiSsid | WiFi scanner | 5min | 当前 WiFi SSID |
| wifiGeofence | LocationFusion | 5min | WiFi 匹配的围栏类别 |
| geofence | GPS/WiFi | 5min | 当前围栏 ID |
| bt_device_names | BT scanner | 3min | 蓝牙设备名 |
| networkType | System | 5min | 网络类型 |

### 2. Rule Engine (规则引擎)

**C++ NAPI module** that evaluates rules against current context snapshot.

C++ NAPI 模块，基于当前上下文快照评估规则。

```
RuleEngine (C++)
├── loadRules(json)                      → Load rules from JSON / 加载规则
├── evaluate(snapshot, maxResults=3)      → Match rules, return top N / 匹配规则返回 Top N
├── exportRules()                         → Export current rules / 导出规则
└── adjustPriority(ruleId, delta)         → Adjust rule weight / 调整规则权重

Rule Structure:
{
  id: string,
  name: string,
  tier: 0|1|2,              // T0=零配置, T1=WiFi, T2=BT+步数
  category: string,          // person|phone|environment|digital
  conditions: Condition[],   // key-op-value triplets
  action: ContextAction,     // {id, type, payload}
  priority: number,          // base weight
  cooldownMs: number,        // minimum interval between triggers
  enabled: boolean
}
```

**Tier system / 层级系统:**
- **T0** (Zero-config): time + battery + charging — 无需配置
- **T1** (WiFi): WiFi SSID geofence matching — WiFi 围栏匹配
- **T2** (BT+sensors): Bluetooth + step count + screen — 蓝牙+步数+屏幕

### 3. ContextAwarenessService (CAS - 情景感知服务)

**Central orchestrator** that coordinates sensors, evaluates rules, and dispatches recommendations.

中央协调器，协调传感器、评估规则、分发推荐。

```
CAS
├── Sensor polling (30s interval)        → Collect sensor data / 采集传感器数据
├── augmentSnapshot()                    → Enrich C++ snapshot / 丰富快照数据
├── evaluateAndDeliver(snapshot)          → Run engine → top 3 matches / 引擎评估 → Top 3
├── notifyRecommendation(rec)            → Push to listeners / 推送给监听器
├── contextActionToUserAction()          → ContextAction → UserAction mapping
├── Geofence management                  → CRUD geofences / 围栏增删改查
├── LocationFusion integration           → WiFi SSID → geofence matching
├── Explore mode                         → Fingerprint-based novelty detection / 指纹新鲜度检测
└── Cooldown management                  → Prevent re-triggering / 防止重复触发
```

### 4. NodeRuntime (Gateway Bridge - 网关桥接)

**Bridge between CAS and A2UI rendering**, handles user feedback and action execution.

CAS 和 A2UI 渲染之间的桥梁，处理用户反馈和动作执行。

```
NodeRuntime
├── Recommendation listener              → CAS → A2UI card / CAS推荐 → A2UI卡片
├── buildCombinedStateRecA2UI()          → State + recommendations in one card
│                                          状态+推荐合并为一张卡片
├── Feedback handling                    → rec_select / dismiss / view_snapshot
├── Action execution                     → ActionRouter.execute(action)
├── Dedup logic                          → _pendingStateRec null check
├── Geofence name resolution             → ID/WiFi SSID → name + category emoji
└── dispatchA2UI(push/reset)             → Send card to rendering layer
```

### 5. Action Plugin System (动作插件系统)

**Extensible plugin architecture** for executing recommended actions.

可扩展的插件架构，用于执行推荐动作。

```
ActionPlugin (Interface / 接口)
├── name: string                          → Plugin identifier / 插件标识
├── supportedTypes: ActionType[]          → Handled action types / 处理的动作类型
├── canHandle(action): boolean            → Can this plugin handle it? / 能否处理？
├── execute(action): ActionResult         → Execute and return result / 执行并返回结果
└── getDisplayInfo(action): DisplayInfo   → Button text for A2UI / A2UI 按钮文本

ActionRouter
├── register(plugin)                      → Add plugin / 注册插件
├── findPlugin(action)                    → Find matching plugin / 查找匹配插件
└── execute(action)                       → Route to plugin / 路由到插件

Plugins:
├── NotificationPlugin    → show_notification, show_info, quick_action
├── ModeChangePlugin      → set_mode (sleep/driving/silent/dnd)
├── CalendarInfoPlugin    → show_info + target=calendar
├── TravelInfoPlugin      → show_info + target=travel/flight/train
├── AppLaunchPlugin       → open_app (Want-based app launch)
└── QRCodePlugin          → show_qrcode (transit/payment)
```

**Adding a new plugin / 添加新插件:**
1. Create `NewPlugin.ets` implementing `ActionPlugin`
2. Register in `ActionExecutor` constructor: `this.router.register(new NewPlugin())`
3. Done — zero changes to other code / 零改动其他代码

### 6. A2UI Rendering (A2UI 渲染层)

**Web-based card rendering** in `index.html`, supporting multiple simultaneous cards.

基于 Web 的卡片渲染，支持多卡片同时显示。

```
A2UI Pipeline:
1. NodeRuntime → dispatchA2UI('push', jsonl)
2. convertSimplified(jsonl)              → Convert form JSON to A2UI messages
3. renderAllSurfaces()                    → Render all active surfaces
4. User clicks button                    → Event callback to NodeRuntime
5. NodeRuntime handles feedback           → dispatchA2UI('reset') to close

Dedup:
- Source-level: _pendingStateRec null check (only one card at a time)
- Content-level: extractTexts() comparison (different JSON, same visual = skip)
```

## Data Flow / 数据流

```
Sensors → DataTray → C++ Snapshot → augmentSnapshot() → evaluateAndDeliver()
                                                              │
                                          ┌───────────────────┤
                                          ▼                   ▼
                                    No matches:          Top 1-3 matches:
                                    (skip)               contextActionToUserAction()
                                                              │
                                                              ▼
                                                    NodeRuntime listener
                                                              │
                                                              ▼
                                                buildCombinedStateRecA2UI()
                                                  (state + recommendations)
                                                              │
                                                              ▼
                                                    A2UI Card Display
                                                              │
                                              ┌───────────────┼───────────────┐
                                              ▼               ▼               ▼
                                        rec_select        dismiss        view_snapshot
                                              │               │               │
                                              ▼               ▼               ▼
                                     ActionRouter →      Close card     Show DataTray
                                     Plugin.execute()
```

## Geofence System / 围栏系统

```
WiFi Connected
     │
     ▼
LocationFusionService.getLearnedSignalsSummary(gf)
     │ Match WiFi SSID against all geofences' learned signals
     ▼
Found match → tray.put('wifiGeofence', category)
            → tray.put('geofence', gf.id)
     │
     ▼
Rule engine evaluates: wifiGeofence == 'home' / 'work' / 'transit' / etc.
     │
     ▼
State card: geofence ID → name resolution
  Priority: 1) geofence ID lookup
            2) WiFi SSID → locationFusion match
            3) wifiGeofence category label
```

## Key Design Decisions / 关键设计决策

| Decision | Rationale |
|----------|-----------|
| C++ rule engine | Performance: evaluate 22 rules in <1ms / 性能：22条规则 <1ms |
| WiFi-first positioning | More reliable indoors than GPS / 室内比 GPS 更可靠 |
| No GPS geofence | Power consumption; WiFi SSID sufficient / 功耗考虑 |
| Combined A2UI card | One-tap UX: state + recommendations together / 一键完成 |
| No LLM fallback | Deterministic: only show when rules match / 确定性：仅规则匹配时推荐 |
| Action plugins | Extensible: add new actions without touching core / 可扩展 |
| Source-level dedup | One card at a time via _pendingStateRec / 一次只显示一张卡片 |
| ContextAction → UserAction | C++ engine returns {type, payload}; ArkTS needs {type, target} |
| Two data sources for signals | C++ DataTray (fast) + ArkTS augment (completeness) |

## File Map / 文件结构

```
entry/src/main/ets/service/context/
├── ContextAwarenessService.ets    (~3900 lines) — Central orchestrator / 中央协调器
├── ContextEngine.ets              — C++ NAPI wrapper / C++ 接口封装
├── ContextModels.ets              — Type definitions / 类型定义
├── DataTray.ets                   — C++ DataTray wrapper / 数据托盘封装
├── ActionExecutor.ets             — ActionRouter wrapper (backward compat)
├── LocationFusionService.ets      — WiFi/BT signal learning / 信号学习
├── TravelInfoService.ets          — Flight/train from calendar / 日历解析航班车次
├── actions/                       — Action plugin system / 动作插件系统
│   ├── ActionPlugin.ets           — Interface / 接口定义
│   ├── ActionRouter.ets           — Plugin router / 插件路由器
│   ├── NotificationPlugin.ets     — Notifications / 通知
│   ├── ModeChangePlugin.ets       — Mode switching / 模式切换
│   ├── CalendarInfoPlugin.ets     — Calendar info / 日历信息
│   ├── TravelInfoPlugin.ets       — Travel info / 出行信息
│   ├── AppLaunchPlugin.ets        — App launch / 应用启动
│   └── QRCodePlugin.ets           — QR codes / 二维码
├── plugins/
│   └── CalendarPlugin.ets         — Calendar data access / 日历数据
└── GeofenceManager.ets            — Geofence CRUD / 围栏管理

entry/src/main/ets/service/gateway/
└── NodeRuntime.ets                (~4800 lines) — Gateway bridge / 网关桥接

entry/src/main/resources/rawfile/
├── config/default_rules.json      — 22 default rules / 默认规则
└── a2ui/index.html                — A2UI rendering / A2UI 渲染

entry/src/main/cpp/
├── context_engine/rule_engine.cpp — C++ rule engine / 规则引擎
└── data_tray/data_tray.h          — C++ data tray / 数据托盘
```

## Version History / 版本历史

- **v2.58.17**: Multi-card A2UI, combined state+rec card, action plugin system, source dedup
- **RULES_VERSION 4**: 22 rules, low battery 30%, tiered T0/T1/T2
