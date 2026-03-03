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

---

## 动作推荐系统（ActionRecommender）/ Action Recommendation System

### 架构概览

```
PhysicalState (当前)  ──┐
PhysicalState (上一个) ──┤ ActFeature::fromPair()
time_in_state (归一化) ──┘
        │
        ▼
  特征向量 185维
  [curr_state 92] | [prev_state 92] | [time_norm 1]
        │
        ├──▶ ActionMLP (185→128→64)  ──▶ prior概率 (权重 0.6)
        │
        └──▶ LinUCB (40臂, 185维)   ──▶ UCB分数  (权重 0.4)
                    │
                    ▼
           combined = 0.6×mlp + 0.4×tanh(ucb)
                    │
                    ▼
              Top-3 推荐动作
                    │
              用户接受/拒绝
                    │
                    ▼
        reward(state, actionCode, r)
         → UCBArm.update(feat, r)
         → debounced save to ucb_state.bin
```

### 状态对编码（State Pair Feature）

状态链中"从哪来"是最强的推荐信号：
- 刚从公司→家：推"导航回家"优先于"休息提醒"
- 早高峰从家→地铁：推"查看到站时间"优先于"查看日程"
- 机场候机且刚从通勤来：推"检查行程/车票"概率更高

**单状态编码（92维）：**

| 维度     | 偏移 | 总槽数 | 已用 | 预留 |
|----------|------|--------|------|------|
| time     | 0    | 12     | 9    | 3    |
| location | 12   | 36     | 15   | 21   |
| motion   | 48   | 8      | 4    | 4    |
| phone    | 56   | 12     | 8    | 4    |
| light    | 68   | 8      | 5    | 3    |
| sound    | 76   | 8      | 5    | 3    |
| dayType  | 84   | 8      | 4    | 4    |
| **合计** |      | **92** | 50   | 42   |

**状态对特征（185维）：**
```
x[0..91]   = 当前状态编码（92维 one-hot）
x[92..183] = 上一状态编码（92维 one-hot）
x[184]     = time_norm
             0.0 = 刚到(<5min)
             0.33 = 稳定(5-30min)
             0.67 = 久留(30-120min)
             1.0  = 超长(>2h)
```

**StateHistory 环形缓冲区（C++）：**
```cpp
// ActionRecommender 内维护 StateHistory history_
// recommend(s) 时自动调用 history_.push(s)
// 取 history_.prev() 构建状态对特征
// history_.timeNorm() 计算时长分段
```

### 训练数据生成（离线）

**数据来源：** 推荐矩阵 218行 × 合成过渡 = ~1800个状态对样本

**过渡合成规则（TRANSITION_PROBS）：**
```
home        ← commute(50%) / outdoor(20%) / restaurant(15%) / work(15%)
work        ← commute(60%) / home(20%) / restaurant(10%) / outdoor(10%)
commute     ← home(55%) / work(45%)
restaurant  ← work(40%) / outdoor(25%) / home(20%) / shopping(15%)
airport     ← commute(50%) / home(30%) / work(20%)
subway      ← home(50%) / work(50%)
cafe        ← work(50%) / outdoor(30%) / home(20%)
...
```

**训练流水线：**
```bash
node scripts/generate_training_data.js   # → training_data.json (1806 samples)
python3 scripts/train_action_mlp.py      # → action_weights.h  (185→128→64)
node tests/.../test_action_recommender.js  # 7/7 pass
```

### 动作目录（ActionCatalog）

40个标准动作，64槽（24预留），格式 `[Cat][N]`：

| 分类 | 范围 | 说明 |
|------|------|------|
| A - 亮码 | A1-A4 | 地铁码/公交码/支付码/门票 |
| B - 日程 | B1-B9 | 今日/明日日程、闹钟、提醒 |
| C - 天气 | C1    | 天气查询 |
| D - 媒体 | D1-D4 | 音乐/白噪音/播客/新闻 |
| E - 导航 | E1-E8 | 回家/公司/餐厅/枢纽/停车 |
| F - 交通 | F1-F4 | 到站时间/防过站/船班/场次 |
| G - 健康 | G1-G5 | 久坐/补水/拉伸/步数/休息 |
| H - 餐饮 | H1    | 点餐建议 |
| I - 社交 | I1    | 联系人提醒 |
| J - 系统 | J1-J3 | 关闭通知/静音/注意财物 |
| K-Z      | 预留  | 未来扩展 |

**扩展规则（无破坏性）：**
- 加新动作：填 `ACTIONS` 数组 + 矩阵加行 → 重训（30秒）
- 加新位置（G-Z）：直接用 location 预留槽，零改动
- 加新 motion/phone 类型：用对应维度 reserved 槽，零改动

### UI 反馈链路

```
A2UI 卡片展示
  → recordShown(stateCode, [A1,B7,E1])   ← 记录快照，开始超时计时

用户点击动作按钮
  → context_feedback(accept, actionCode=B7)
  → handleA2UIAction → reward(state, B7, 1.0)

用户关闭卡片（× 按钮）
  → context_feedback(reject)
  → reward(state, A1, 0.0) + reward(state, B7, 0.0) + reward(state, E1, 0.0)

卡片展示 30s 无操作后自动消失
  → checkPreviousTimeout() → reward(state, *, 0.15)  ← 弱负反馈

App 退后台
  → RecommenderBridge.flush() → save ucb_state.bin
```

### 相关文件

| 文件 | 说明 |
|------|------|
| `entry/src/main/cpp/context_engine/action_recommender.h` | C++ MLP+LinUCB+StateHistory |
| `entry/src/main/cpp/context_engine/action_weights.h` | 预训练权重（自动生成） |
| `entry/src/main/ets/service/context/RecommenderBridge.ets` | ArkTS 桥接层 |
| `scripts/generate_training_data.js` | 状态对训练数据生成 |
| `scripts/train_action_mlp.py` | MLP 训练脚本 |
| `scripts/training_data.json` | 训练数据（~1800 样本） |
| `docs/ps-recommendation-matrix.md` | 推荐矩阵（218行，StateCode主键） |
| `docs/action-catalog.json` | 标准动作目录 |
| `tests/context_ai/unit/test_action_recommender.js` | 7场景推理测试 |
