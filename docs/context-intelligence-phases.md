# Context Intelligence — Phase Plan

## Overview
增强 ClawdBotHarmony 的场景感知能力，从传感器数据展示到多模态环境识别。

---

## Phase 1: 场景快照展示

**目标**: 改造现有纠正卡片，展示当前所有传感器数据的实时快照。

**现状**: 点击"不准确"只弹出位置+活动选择的纠正卡片，用户看不到系统实际采集到了什么。

**方案**:
- 在 A2UI 推荐卡片上增加"查看详情"按钮
- 点击后展开显示当前 ContextSnapshot 的所有信号：
  - 📍 位置: 公司/家/未知
  - 🚶 步数: 今日 3,200 步 | 状态: 静止
  - ❤️ 心率: 72 bpm | 状态: 休息
  - ⌚ 穿戴: 佩戴中
  - 📶 WiFi: HomeNetwork
  - 🔵 蓝牙: AirPods Pro 已连接
  - 📱 屏幕: 亮屏 | 使用中
  - 📅 日历: 下一事件 14:00 周会
  - ⏰ 时间: 工作日 10:30
- A2UI HTML 模板新增 `scene_snapshot` 类型卡片
- 数据来源: `DigitalWorldService.getLatestSnapshots()` + `ContextAwarenessService` 物理传感器

**涉及文件**:
- `resources/rawfile/a2ui/index.html` — 新增快照卡片渲染
- `NodeRuntime.ets` — `buildSceneSnapshotA2UI()` 新方法
- `DigitalWorldService.ets` — 暴露 `getFormattedSnapshot()` 方法

---

## Phase 2: 条件化否定规则

**目标**: 支持"在特定场景下不触发某规则"的否定条件。

**现状**: 规则只有正向触发条件（满足则触发），无法表达"在X场景下不要提醒我Y"。

**方案**:
- Rule 结构新增 `excludeConditions` 字段:
  ```
  {
    id: "rule_001",
    conditions: { location: "office", time: "morning" },
    excludeConditions: [
      { activity: "meeting" },       // 开会时不触发
      { bluetooth: "会议室音箱" }     // 连了会议室蓝牙不触发
    ],
    action: "remind_checkin"
  }
  ```
- ContextEngine 评估时: 先匹配 conditions，再检查 excludeConditions，任一排除条件满足则跳过
- NLP 创建支持: "到公司提醒我打卡，但开会的时候不要提醒"
- RuleManagementPage 增加排除条件编辑 UI
- C++ rule_engine.cpp 同步更新排除逻辑

**涉及文件**:
- `ContextEngine.ets` — 规则评估增加排除逻辑
- `cpp/context_engine/rule_engine.cpp` — C++ 引擎同步
- `IntentClassifier.ets` — NLP 解析排除条件
- `RuleManagementPage.ets` — UI 编辑排除条件
- `NodeRuntime.ets` — NLP 创建规则时提取排除条件

---

## Phase 3: 前置摄像头姿态识别

**目标**: 利用前置摄像头判断用户姿态（看手机/放桌上/口袋里）。

**现状**: 仅靠加速度计粗略判断，无法区分"放桌上"和"拿在手里但没看"。

**方案**:
- 使用 `@kit.CameraKit` 低分辨率前置摄像头预览
- 分析策略（本地，不上传）:
  - **亮度检测**: 极暗 = 口袋/包里
  - **人脸检测**: 有人脸 = 用户在看手机
  - **方向检测**: 结合加速度计判断手机朝向
- 输出信号: `phone_posture`: `in_use` | `on_desk` | `in_pocket` | `unknown`
- 隐私保护:
  - 不保存任何图像
  - 仅提取特征值（亮度/有无人脸/方向）
  - 用户可在设置中关闭
  - 采样频率低（每30秒一帧）

**涉及文件**:
- 新建 `plugins/PosturePlugin.ets`
- `DigitalWorldService.ets` — 注册插件
- `module.json5` — CAMERA 权限已有
- 可能需要 `@kit.VisionKit` 做轻量人脸检测

---

## Phase 4: 静默录音 + 语音场景识别

**目标**: 短时间环境音采样，识别场景（办公室/户外/交通/安静）。

**现状**: 无声音信号，错过大量场景信息。

**方案**:
- 使用 `@kit.AudioKit` 短时采样（3-5秒）
- 本地分析，**不上传原始音频**:
  - **音量级别**: 安静/正常/嘈杂
  - **环境分类**: 
    - 安静（<30dB）→ 卧室/图书馆
    - 办公（30-50dB，键盘声/低语）→ 办公室
    - 嘈杂（>60dB）→ 餐厅/街道
    - 交通（引擎声/地铁声）→ 通勤中
  - **语音检测**: 有人说话 vs 无人声（VAD）
  - **声纹识别**: 本地声纹模型，判断是否用户本人在说话
- 采样后立即丢弃原始音频，仅保留特征值
- 使用 Sherpa-ONNX 已有的 VAD 能力

**隐私（最高级别）**:
- `privacyLevel: 'critical'`
- `enabledByDefault: false` — 必须用户手动开启
- 运行时再次确认授权
- 设置页醒目提示
- 绝不保存/传输原始音频

**涉及文件**:
- 新建 `plugins/AmbientSoundPlugin.ets`
- `DigitalWorldService.ets` — 注册，critical 级别
- Sherpa-ONNX VAD 模块复用
- 可能新建 `service/audio/AudioAnalyzer.ets` 做特征提取

---

## Phase 5: App 使用识别

**目标**: 检测当前前台 App，推断用户意图。

**现状**: AppUsagePlugin 只统计本应用使用时长，不知道用户在用什么其他 App。

**方案**:
- 使用 `@kit.UsageStatisticsKit` 获取最近使用的 App 列表
- 信号:
  - `foreground_app`: 当前前台应用 bundleName
  - `app_category`: 社交/办公/娱乐/导航/购物/...
  - `app_usage_duration`: 当前 App 使用时长
- App 分类映射表（本地维护）:
  ```
  com.huawei.hmos.email → 办公
  com.tencent.mm → 社交
  com.ss.android.article.news → 资讯
  com.autonavi.minimap → 导航
  ```
- 结合其他信号的推断:
  - 导航 App + GPS移动 = 开车/通勤
  - 邮件 App + WiFi(办公网) = 工作中
  - 视频 App + 晚间 + 沙发 = 休闲

**权限**: `ohos.permission.BUNDLE_ACTIVE_INFO`（系统权限，可能受限）

**涉及文件**:
- 改造 `plugins/AppUsagePlugin.ets` 或新建 `plugins/ForegroundAppPlugin.ets`
- `DigitalWorldService.ets` — 注册
- 新建 `resources/rawfile/app_categories.json` — App 分类映射

---

## 实施顺序与依赖

```
Phase 1 (场景快照) ──── 无依赖，立即可做
Phase 2 (否定规则) ──── 无依赖，立即可做
Phase 3 (姿态识别) ──── 依赖 Camera 权限（已有）
Phase 4 (环境音)  ──── 依赖 Sherpa-ONNX VAD、Mic 权限（已有）
Phase 5 (App使用)  ──── 依赖 BUNDLE_ACTIVE_INFO 权限（可能受限）
```

Phase 1-2 可以并行开发，Phase 3-5 按顺序推进。

---

## ContextSnapshot 信号汇总（完成后）

| 来源 | 信号 | 类型 |
|------|------|------|
| GPS | location, place_type | 物理 |
| 加速度计 | motion_state, phone_posture | 物理 |
| 计步器 | step_count, is_active | 物理 |
| 心率 | heart_rate, heart_rate_status | 穿戴 |
| 佩戴检测 | wearing_state | 穿戴 |
| WiFi | ssid, connected | 数字 |
| 蓝牙 | devices, connected_names | 数字 |
| 屏幕 | screen_on, locked | 数字 |
| 日历 | next_event, in_meeting | 数字 |
| 前置摄像头 | phone_posture (refined) | 视觉 |
| 环境音 | noise_level, sound_scene, has_voice | 音频 |
| 前台App | foreground_app, app_category | 数字 |
| 时间 | hour, day_of_week, is_workday | 基础 |
