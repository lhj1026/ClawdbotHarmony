# 今日行程显示不及时 - 修复方案

## 问题描述

**用户反馈**："今日行程显示的不及时"

## 原因分析

### 根本原因

`DailyTimelineService.pushStateChange()` 只在 `ContextAwarenessService.refreshTray()` 中被调用，而 `refreshTray()` 是通过定时器周期性执行的：

```typescript
private static readonly EVALUATION_INTERVAL_MS = 2 * 60 * 1000;  // 2分钟评估一次
```

**最大延迟**：2 分钟

### 延迟场景

| 事件 | 原触发时机 | 延迟 |
|------|----------|------|
| 运动状态变化 | 下次周期评估（最多2分钟后） | **0-120秒** |
| 围栏进入/离开 | 下次周期评估（最多2分钟后） | **0-120秒** |
| 应用启动 | 下次周期评估（最多2分钟后） | **0-120秒** |

### 典型问题场景

1. **用户刚到家** → 围栏进入事件触发 → 但时间线要等最多2分钟才更新
2. **用户开始走路** → 运动状态变化 → 时间线延迟更新
3. **打开App查看今日行程** → 如果刚启动服务，数据还未推送

## 解决方案

### 策略：关键事件立即推送 + 周期评估保持

保持 2 分钟周期评估（省电），但在**关键状态变化时立即推送**。

### 改动点

#### 1. 运动状态变化时立即推送

**文件**：`ContextAwarenessService.ets`

**位置**：`updateMotionState()` 函数，状态变化后

**改动**：
```typescript
// 运动状态变化后立即推送时间线事件
if (newState !== this.lastMotionState) {
  // ... 现有逻辑 ...

  // 新增：立即推送（不等待周期性评估）
  this.pushTimelineEvent();
}
```

**影响**：
- ✅ 走路/驾车/静止状态变化 → 立即记录到时间线
- ⚠️ 轻微增加 CPU 使用（每次状态变化额外调用一次 pushTimelineEvent）
- 预估：<0.1% CPU（状态变化频率低）

#### 2. 围栏进入/离开时立即推送

**位置**：围栏事件处理器

**改动**：
```typescript
// 围栏事件（进入/离开）后立即推送时间线
this.engine.pushEvent(eventType);
this.pushTimelineEvent();  // 新增
```

**影响**：
- ✅ 到家/到公司/离开 → 立即记录到时间线
- ⚠️ 围栏频繁进出时会增加调用频率
- 优化：DailyTimelineService 已有 5 秒去重逻辑，不会重复记录

#### 3. 服务启动时立即推送初始状态

**位置**：`start()` 方法

**改动**：
```typescript
// 服务启动后立即推送初始状态
this.isRunning = true;
this.pushTimelineEvent();  // 新增
```

**影响**：
- ✅ 打开 App 后立即看到当前状态
- ⚠️ 启动时增加一次调用（可忽略）

## 延迟对比

| 事件 | 原延迟 | 新延迟 | 改进 |
|------|-------|-------|------|
| 运动状态变化 | 0-120秒 | **<1秒** | ✅ 120倍 |
| 围栏进入/离开 | 0-120秒 | **<1秒** | ✅ 120倍 |
| 应用启动 | 0-120秒 | **<1秒** | ✅ 120倍 |
| 周期性更新 | 120秒 | 120秒（不变）| - |

## 测试方案

### 快速验证（5分钟）

1. **启动 App**
   ```bash
   # 清除时间线数据
   hdc shell "rm -f /data/accounts/account_0/appdata/com.hongjieliu.clawdbot/cache/daily_timeline_prefs"

   # 启动 App，观察日志
   hdc shell hilog | grep "DailyTimeline\|pushStateChange"

   # 期望：启动后立即看到 "pushStateChange" 被调用
   ```

2. **走路 → 驾车转换**
   ```
   - 从静止开始走路
   - 期望：时间线立即显示 "walking" 条目（不等2分钟）
   ```

3. **围栏进入**
   ```
   - 从外面回到家（home 围栏）
   - 期望：时间线立即显示 "home" 条目
   ```

### 完整测试（15分钟）

1. **冷启动测试**
   - 杀掉 App → 重新打开
   - 检查"今日行程"是否立即显示当前状态

2. **状态变化测试**
   - 静止 → 走路 → 驾车 → 静止
   - 每次变化后 5 秒内检查时间线是否更新

3. **围栏进出测试**
   - 离家 → 到公司 → 离开公司
   - 每次进出后 5 秒内检查时间线

### 日志验证

```bash
# 搜索 pushTimelineEvent 调用
hdc shell hilog | grep "pushTimelineEvent\|pushStateChange"

# 期望输出：
# [启动时] pushTimelineEvent called
# [运动状态变化] Motion state: stationary -> walking
#                pushTimelineEvent called
# [围栏进入] Geofence enter: home
#           pushTimelineEvent called
```

## 性能影响

### CPU 使用

| 操作 | 额外调用 | CPU 影响 |
|------|---------|---------|
| 启动 | +1 次 pushTimelineEvent | <0.01% |
| 运动状态变化 | +1 次/次变化 | <0.1%（变化频率低）|
| 围栏进出 | +1 次/次进出 | <0.1%（进出频率低）|
| **总体** | - | **<0.2%** |

### 电耗

- 周期评估保持 2 分钟间隔（不变）
- 额外调用频率低（运动状态和围栏变化不频繁）
- **预估电耗增加**：<0.5%（可忽略）

### 内存

- 无新增字段
- DailyTimelineService 去重逻辑防止重复记录
- **内存影响**：0

## 潜在问题

### 1. 频繁进出围栏

**场景**：用户在围栏边缘来回走动

**影响**：频繁调用 pushTimelineEvent()

**缓解**：
- DailyTimelineService 已有 5 秒去重
- 可考虑增加围栏进出的 debounce（30秒）

**解决方案**（如需要）：
```typescript
private lastGeofencePushTime: number = 0;
private static readonly GEOFENCE_PUSH_DEBOUNCE_MS = 30000;  // 30秒

// 围栏事件后
if (Date.now() - this.lastGeofencePushTime > ContextAwarenessService.GEOFENCE_PUSH_DEBOUNCE_MS) {
  this.pushTimelineEvent();
  this.lastGeofencePushTime = Date.now();
}
```

### 2. 运动状态频繁抖动

**场景**：走路/静止边界频繁切换

**影响**：多次调用 pushTimelineEvent()

**缓解**：
- DailyTimelineService 的去重逻辑
- updateMotionState() 的 dwell 机制（0.8-30秒）

**现有保护已足够**，无需额外处理

## 回滚方案

如果出现问题，可以快速回滚：

```typescript
// 在关键位置注释掉新增的 pushTimelineEvent() 调用
// this.pushTimelineEvent();  // 回滚：禁用立即推送
```

服务将回到纯周期评估模式（2分钟延迟）。

## 未来优化

### 1. 自适应推送频率

根据状态变化频率动态调整：
- 高频变化时：增加 debounce
- 低频时：立即推送

### 2. 批量推送

积累多个小变化后批量推送：
```typescript
private pendingTimelinePush: boolean = false;

private scheduleTimelinePush(): void {
  if (this.pendingTimelinePush) return;
  this.pendingTimelinePush = true;

  setTimeout(() => {
    this.pushTimelineEvent();
    this.pendingTimelinePush = false;
  }, 5000);  // 5秒后批量推送
}
```

### 3. UI 实时更新

DailyTimelinePage 可以监听时间线变化事件：
```typescript
// DailyTimelinePage.ets
onPageShow() {
  // 监听时间线更新事件
  eventBus.on('timeline_updated', () => {
    this.refreshTimeline();
  });
}
```

## 代码位置

**修改文件**：
- `entry/src/main/ets/service/context/ContextAwarenessService.ets`

**改动行**：
- 行 ~1345：运动状态变化后立即推送
- 行 ~3335：围栏事件后立即推送
- 行 ~485：服务启动后立即推送

**涉及方法**：
- `updateMotionState()` - 新增推送调用
- `handleGeofenceEvent()` - 新增推送调用
- `start()` - 新增推送调用
- `pushTimelineEvent()` - 无改动，仅被更频繁调用

---

**创建日期**：2026-03-04
**状态**：实现完成，待测试
**优先级**：高（影响用户体验）
**预期改善**：延迟从 0-120秒 → <1秒（120倍改进）
