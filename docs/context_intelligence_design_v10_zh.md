# 情境智能框架设计文档 — 7-Tuple 物理状态与场景智能

> 版本: 10.0
> 日期: 2026-03-02
> 作者: 刘洪杰 (Hongjie Liu)
> 备注: 本文档为 `context_intelligence_design_v7_en.md` Section 25 的中文版。完整英文版请参阅该文件。

---

## 目录

- [1. 架构概述](#1-架构概述)
- [2. 7-Tuple 物理状态模型](#2-7-tuple-物理状态模型)
- [3. PhysicalStateBuilder 状态构建器](#3-physicalstatebuilder-状态构建器)
- [4. 场景链匹配](#4-场景链匹配)
- [5. 72 个场景定义](#5-72-个场景定义)
- [6. RL 特征扩展](#6-rl-特征扩展)
- [7. 双管线集成](#7-双管线集成)
- [8. UI 显示](#8-ui-显示)
- [9. 文件清单](#9-文件清单)

---

## 1. 架构概述

本节描述基于 7-tuple 物理状态的场景智能系统。该系统建立在状态转换特征（见英文版 Section 24）之上，实现了具体的**物理状态分类层**和**确定性场景链匹配器**，形成与现有规则引擎并行的推荐管线。

**核心架构流程**: 物理世界传感器 → 状态 (7-tuple) → 状态链 → 场景 → 场景 + 数字世界数据 → 推荐 → 动作执行

系统引入两个新组件：

1. **PhysicalStateBuilder** (ArkTS): 从 DataTray 读取原始传感器数据，分类为离散的 7-tuple `PhysicalState`
2. **ScenarioMatcher** (ArkTS): 将当前 `PhysicalState` 与 72 个预定义场景链进行确定性模式匹配，识别用户当前的生活情境

这些组件与现有 C++ 规则引擎并行运行：

```
┌─────────────────────────────────────────────────────────┐
│                  periodicEvaluate()                      │
│                                                          │
│  DataTray (原始传感器数据)                                │
│       │                                                  │
│       ├──▶ PhysicalStateBuilder.build()                  │
│       │         │                                        │
│       │         ▼                                        │
│       │    PhysicalState (7-tuple)                       │
│       │         │                                        │
│       │         ├──▶ ScenarioMatcher.match()             │
│       │         │         │                              │
│       │         │         ▼                              │
│       │         │    ScenarioMatchResult[]               │
│       │         │                                        │
│       │         └──▶ 注入 ps_* 到 DataTray               │
│       │                     │                            │
│       └──▶ tray.getSnapshot() ──▶ C++ evaluate()        │
│                                       │                  │
│                                       ▼                  │
│                              MatchResult[] (规则)        │
│                                       │                  │
│                              合并结果 → 推送              │
└─────────────────────────────────────────────────────────┘
```

## 2. 7-Tuple 物理状态模型

每个用户情境由 7 个正交的物理维度描述：

| # | 维度 | 类型 | 值 | 数量 |
|---|------|------|------|------|
| 1 | **时间** | `TimeSlot` | sleeping(深夜睡眠), dawn(清晨), morning(早晨), forenoon(上午), lunch(午间), afternoon(下午), evening(傍晚), night(夜晚), late_night(深夜) | 9 |
| 2 | **位置** | `LocationCategory` | home(家), work(公司), commute(通勤中), restaurant(餐厅), gym(健身房), transit_hub(交通枢纽), shopping(商场), outdoor(户外), cafe(咖啡馆), unknown(未知) | 10 |
| 3 | **运动** | `MotionCategory` | stationary(静止), walking(步行), running(跑步), cycling(骑行), driving(驾车), transit(公共交通), unknown(未知) | 7 |
| 4 | **手机** | `PhoneCategory` | in_use(使用中), on_desk(放桌上), in_pocket(在口袋), face_down(面朝下), charging(充电中), unknown(未知) | 6 |
| 5 | **光线** | `LightCategory` | dark(暗), dim(昏暗), normal(正常), bright(明亮) | 4 |
| 6 | **声音** | `SoundCategory` | silent(安静), quiet(较静), normal(一般), noisy(嘈杂), unknown(未知) | 5 |
| 7 | **日期类型** | `DayType` | workday(工作日), weekend(周末), holiday(假日) | 3 |

**状态空间**: 9 × 10 × 7 × 6 × 4 × 5 × 3 = **226,800** 种理论组合。由于物理上不可能的组合（如 gym + driving, bright + sleeping），有效组合约 **300–600** 种。

## 3. PhysicalStateBuilder 状态构建器

**文件**: `entry/src/main/ets/service/context/PhysicalStateBuilder.ets`

从 DataTray 读取传感器数据，对每个维度进行分类：

| 维度 | DataTray 键 | 分类逻辑 |
|------|------------|---------|
| 时间 | `hour` (系统) | 0:00–5:00→sleeping, 5:00–7:00→dawn, 7:00–9:00→morning, 9:00–11:30→forenoon, 11:30–13:30→lunch, 13:30–17:00→afternoon, 17:00–19:30→evening, 19:30–22:00→night, 22:00–24:00→late_night |
| 位置 | `wifiGeofence`, `motionState`, `gpsSpeed` | WiFi 围栏映射 (home/work/gym 等) → 对应位置；无围栏 + 运动=driving/transit → commute；无 WiFi + 有 GPS → outdoor；否则 → unknown |
| 运动 | `motionState`, `transportMode` | 直接映射；`transportMode=transit` → transit；`transportMode=cycling` → cycling |
| 手机 | `isCharging`, `ambient_brightness`, `proximity`, `screen_on`, `phone_posture` | 优先级：charging > pocket(暗+近距) > face_down > in_use(亮屏) > on_desk(平放) > unknown |
| 光线 | `ambient_brightness` (勒克斯) | <5→dark, 5–50→dim, 50–500→normal, >500→bright |
| 声音 | `noise_level` (分贝) | <25→silent, 25–40→quiet, 40–55→normal, >55→noisy |
| 日期类型 | `dayOfWeek`, 日历假日事件 | 假日日历事件 → holiday；周六/日 → weekend；否则 → workday |

**静态工具方法**:
- `fingerprint(ps)` → `"time|location|motion|phone|light|sound|dayType"` (用于去重)
- `equals(a, b)` → 比较所有 7 个维度是否相等

## 4. 场景链匹配

**文件**: `entry/src/main/ets/service/context/ScenarioMatcher.ets`

场景是一个多步骤的**状态链** — 描述生活情境变化过程的一系列预期 PhysicalState 模式。ScenarioMatcher 执行确定性模式匹配（非 RL）来识别当前活跃的场景。

**场景定义示例** (JSON):
```json
{
  "id": "S07",
  "name": "早晨驾车通勤",
  "nameEn": "Morning Driving Commute",
  "category": "commute",
  "steps": [
    {
      "time": "morning",
      "location": "home",
      "motion": "walking",
      "phone": "in_pocket",
      "light": "normal",
      "sound": "quiet",
      "dayType": "*",
      "actions": [{ "id": "check_traffic", "type": "suggestion", "payload": "..." }]
    },
    {
      "time": "morning",
      "location": "commute",
      "motion": "driving",
      "phone": "*",
      "light": "normal",
      "sound": "*",
      "dayType": "*",
      "actions": [{ "id": "nav_to_work", "type": "suggestion", "payload": "..." }]
    }
  ],
  "timeoutMs": 7200000,
  "priority": 5,
  "enabled": true
}
```

**匹配算法**:
1. **`advanceActiveChains()`**: 对每个活跃链，检查下一步是否匹配当前 PhysicalState。匹配则推进链位置。
2. **`detectNewScenarios()`**: 对所有未激活的启用场景，检查 Step 0 是否匹配。匹配则启动新链。
3. **`cleanupTimeouts()`**: 移除超过 `timeoutMs`（默认 2 小时）未进展的链。
4. **步骤匹配**: AND 匹配所有 7 个维度。`*` = 通配符（总是匹配）。`A|B` = OR（匹配任一值）。置信度 = 指定维度数（非通配符）/ 7。
5. **数字条件**: 每个步骤可选 `digitalConditions`（如 `{"batteryLevel": "lte 30"}`），从 DataTray 检查。

## 5. 72 个场景定义

**文件**: `entry/src/main/resources/rawfile/config/scenarios.json`

72 个场景，覆盖 12 个生活类别：

| 类别 | 场景数 | ID | 关键示例 |
|------|--------|------|---------|
| 早晨起床 | 6 | S01–S06 | 工作日早起、周末赖床、早起晨跑 |
| 通勤 | 6 | S07–S12 | 驾车/公交/骑车通勤、加班晚归 |
| 工作 | 8 | S13–S20 | 专注工作、开会、午餐、加班 |
| 在家生活 | 12 | S21–S32 | 做饭、看电视、阅读、做家务、周末休息 |
| 睡眠 | 5 | S33–S37 | 入睡、午睡、失眠、夜间起夜 |
| 运动健身 | 6 | S38–S43 | 健身房、户外跑步、散步、骑车 |
| 用餐 | 5 | S44–S48 | 午/晚餐、咖啡店、叫外卖 |
| 购物 | 3 | S49–S51 | 超市、商场、便利店 |
| 出行旅行 | 8 | S52–S59 | 机场、登机、飞行、高铁、打车 |
| 社交 | 3 | S60–S62 | 来客、外出社交、参加活动 |
| 健康提醒 | 5 | S63–S67 | 久坐、喝水、护眼、早睡提醒 |
| 设备告警 | 5 | S68–S72 | 低电量、充电完成、蓝牙车载、会议开始 |

**覆盖分析**: 55/72 (76%) 仅靠 7-tuple 完全覆盖；12/72 (17%) 需要数字条件辅助；5/72 (7%) 是纯数字触发器。

## 6. RL 特征扩展

7-tuple 状态和场景上下文编码为 RL 模型特征：

**Stream MLP** (25 → 34 维):

| 索引 | 特征 | 编码方式 |
|------|------|---------|
| 0–1 | 小时 sin/cos | sin/cos(2π·h/24) |
| 2–3 | 日期类型 one-hot | weekend, holiday (workday = 均为 0) |
| 4–12 | 位置 9 维 one-hot | home, work, commute, restaurant, gym, transit_hub, shopping, outdoor, cafe |
| 13–18 | 运动 6 维 one-hot | stationary, walking, running, cycling, driving, transit |
| 19–23 | 手机 5 维 one-hot | in_use, on_desk, in_pocket, charging, unknown |
| 24–25 | 光线 | 序数 (0/0.33/0.67/1) + 暗标记 |
| 26–27 | 声音 | 序数 (0/0.25/0.5/1) + 有人声 |
| 28 | 有活跃场景 | 二值 |
| 29 | 链位置 | step/total (0–1) |
| 30 | 场景类别哈希 | 类别 → 序数 (0.05–0.95) |
| 31 | 是否常规 | 来自 StateTransitionTracker |
| 32 | 状态持续时间（归一化） | min(minutes/120, 1) |
| 33 | 电量（归一化） | batteryLevel/100 |

**网络架构**: 34 → 128 → 64 → 1 (每臂 11,649 参数)

**LinUCB** (8 → 14 维):

| 索引 | 特征 |
|------|------|
| 0–1 | 小时 sin/cos |
| 2 | 电量/100 |
| 3 | 是否充电 |
| 4–5 | 日期类型 one-hot (weekend, holiday) |
| 6–10 | 运动 5 维 one-hot (stationary, walking, running, cycling, vehicle) |
| 11 | 光线序数 |
| 12 | 声音序数 |
| 13 | 有场景 |

**向后兼容**: 两个 `buildFeatures()` 函数包含回退路径（如 `ps_motion` 回退到 `motionState`）。`StreamMLP::importJson()` 检查 `featDim`，维度不匹配时跳过导入，优雅地重新初始化。

## 7. 双管线集成

`ContextAwarenessService.periodicEvaluate()` 中的评估管线现在运行两个并行管线：

```
管线 1 (规则):   tray → snapshot → C++ evaluate() → MatchResult[]
管线 2 (场景):   tray → PhysicalStateBuilder → ScenarioMatcher → ScenarioMatchResult[]
```

**注入 DataTray 的 PhysicalState 字段**（两个管线均可使用）:
- `ps_time`, `ps_location`, `ps_motion`, `ps_phone`, `ps_light`, `ps_sound`, `ps_dayType`
- `ps_scenario` (最高场景名称), `ps_scenarioCategory`, `ps_chainPosition`, `ps_scenarioConfidence`

这些 `ps_*` 键对 C++ 规则引擎的 `buildFeatures()` 可用，使 Stream MLP 和 LinUCB 能够从 7-tuple 状态学习，无需修改 C++ 评估逻辑。

## 8. UI 显示

**文件**: `entry/src/main/ets/pages/ContextSettingsPage.ets`

在状态概览下方新增一张卡片，显示：
- 7 个维度标签及当前值（2 列网格布局）
- 活跃场景名称、步骤进度（如 "2/3"）及数量

**文件**: `entry/src/main/ets/common/I18n.ets`

添加了所有维度值的中英文 I18n 标签：
- `ps.title` → "物理状态" / "Physical State"
- `ps.time.sleeping` → "深夜睡眠" / "Sleeping"
- `ps.location.home` → "家" / "Home"
- 等等（所有 7 个维度 × 所有值）

## 9. 文件清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `ContextModels.ets` | 编辑 | 新增 `TimeSlot`, `LocationCategory`, `MotionCategory`, `PhoneCategory`, `LightCategory`, `SoundCategory`, `DayType`, `PhysicalState`, `Scenario`, `ScenarioStep`, `ScenarioAction`, `ScenarioState`, `ScenarioMatchResult`, `ScenarioCategory` |
| `PhysicalStateBuilder.ets` | 新建 | 传感器 → 7-tuple 分类（7 个分类方法 + fingerprint/equals） |
| `ScenarioMatcher.ets` | 新建 | 确定性场景链匹配器（72 个场景，init/match/advance/cleanup） |
| `scenarios.json` | 新建 | 72 个场景定义 JSON（rawfile/config/） |
| `ContextAwarenessService.ets` | 编辑 | 管线集成：构建 PhysicalState，运行 ScenarioMatcher，注入 ps_* 字段 |
| `ContextEngine.ets` | 编辑 | ContextSnapshot 接口增加 ps_* 字段 |
| `stream_mlp.h` | 编辑 | `STREAM_FEAT_DIM` 25→34，更新特征布局注释 |
| `stream_mlp.cpp` | 编辑 | `buildFeatures()` 重写为 34 维（7-tuple + 场景上下文） |
| `context_engine.h` | 编辑 | `LINUCB_DIM` 8→14 |
| `linucb.cpp` | 编辑 | `buildFeatureVec()` 重写为 14 维 |
| `ContextSettingsPage.ets` | 编辑 | 7-tuple PhysicalState 显示卡片 |
| `I18n.ets` | 编辑 | 所有维度值的中英文标签 |

---

*文档结束*
