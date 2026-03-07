# 驾驶 vs 乘车区分 - 地点推断实现

## 问题
坐公交车、地铁时，Z轴振幅和频率特征与驾车相似，容易被误识别为"驾驶"，但实际上应该是"乘车"（不是自己驾驶）。

## 解决方案

### 核心思路
```
如果运动状态判定为 "driving" 但：
  ① 前一个地点 = 公交站/地铁站/机场/火车站 AND
  ② 还在5分钟内离开围栏
  
  → 推断为 "transit"（乘车）而非 "driving"（驾驶）

否则 → 保持 "driving"
```

### 实现细节

#### 1. 交通枢纽识别 (`isTransitHub`)
```typescript
private isTransitHub(geofenceId: string): boolean {
  if (!geofenceId || geofenceId.length === 0) return false;
  
  let lower = geofenceId.toLowerCase();
  return lower.includes('transit') ||
         lower.includes('station') ||
         lower.includes('metro') ||
         lower.includes('subway') ||
         lower.includes('bus') ||
         lower.includes('airport') ||
         lower.includes('railway') ||
         lower.includes('train') ||
         lower.includes('ferry');
}
```

检查的关键词：
- `transit`, `station` - 通用枢纽
- `metro`, `subway` - 地铁
- `bus` - 公交车站
- `airport` - 机场
- `railway`, `train` - 火车站
- `ferry` - 渡轮码头

#### 2. 驾驶 vs 乘车推断 (`inferDrivingVsTransit`)
```typescript
if (前一个围栏是交通枢纽) {
  if (当前还在枢纽内 OR 刚离开5分钟内) {
    → return 'transit'  // 很可能是乘车
  }
}
return 'driving'  // 继续识别为驾驶
```

#### 3. 集成到运动状态更新
在 `updateMotionState()` 中：
```typescript
// 驾驶 vs 乘车推断（使用地理围栏辅助）
if (newState === 'driving') {
  newState = this.inferDrivingVsTransit(newState, currentGeofence, gpsSpeed);
}

// 更新前一个围栏（用于下次推断）
if (currentGeofence.length > 0 && currentGeofence !== this.lastGeofence) {
  this.lastGeofence = currentGeofence;
}
```

### 数据流

```
GPS → 围栏信息 ─────┐
                    ├─→ 地点类型判断 (isTransitHub)
前一个地点信息 ──────┤
                    └─→ 驾驶推断 (inferDrivingVsTransit)
                         ↓
运动状态判定 (Z轴特征) → driving/walking/...
                         ↓
推断处理 → driving → transit（如果前一个地点是枢纽）
         → walking/stationary → 保持不变
         ↓
最终运动状态 → motionState (driving/transit)
```

### 输出变更

#### 新增字段
- `lastGeofence: string` - 前一个围栏ID，用于推断

#### 使用现有字段
- `geofenceDepartureTime: number` - 离开围栏时间（已存在）
- `motionState: string` - 现在可能是 "transit" 而非 "driving"

### GPS间隔配置

Transit 状态使用与 Driving 相同的 GPS 采集间隔：
```typescript
case 'transit':
  newGpsInterval = ContextAwarenessService.GPS_DRIVING;
  newWifiInterval = ContextAwarenessService.WIFI_DRIVING;
  newAccelInterval = ContextAwarenessService.ACCEL_DRIVING;
  break;
```

理由：乘车时乘客仍在运动中，需要高频 GPS 跟踪位置变化。

### 活动状态映射

Transit 映射到与 Driving 相同的活动状态：
```typescript
case 'transit':
  newActivityState = 'driving';  // 乘客也在"驾驶"活动中
  break;
```

## 测试场景

### 场景A：坐地铁
```
1. 到达地铁站 → geofence='subway_station' → motionState='stationary'
2. 进入地铁车厢 → geofence=''（信号差）→ motionState=?
   ↓ 地点推断：
   前一个地点='subway_station'（交通枢纽）
   刚离开<5分钟
   Z轴特征→driving → 推断为 transit
   ✅ 结果: motionState='transit'

3. 下车出站 → geofence='downtown'
   前一个地点=''
   不是枢纽出发 → motionState='walking' (Z轴特征)
```

### 场景B：自己开车
```
1. 从停车场离开 → geofence='parking'（非枢纽）
2. GPS速度>5 → motionState='driving'
3. 推断：前一个地点='parking'（不是枢纽）→ 保持 'driving'
   ✅ 结果: motionState='driving'
```

### 场景C：坐出租车/网约车
```
1. 等待地点 → geofence='restaurant'（非枢纽）
2. 上车后驾驶 → GPS速度>5 → motionState='driving'
3. 推断：前一个地点='restaurant'（不是枢纽）→ 保持 'driving'
   ✅ 结果: motionState='driving'（自己在开车的话）
   
   注：此场景无法区分，但由于不是从枢纽出发，识别为 driving 也合理
```

### 场景D：坐公交车
```
1. 在公交站等车 → geofence='bus_stop'(枢纽) → motionState='stationary'
2. 上车行驶 → geofence=''（信号差）→ Z轴特征→'driving'
3. 推断：前一个地点='bus_stop'（枢纽）
         刚离开<5分钟
         → 推断为 'transit'
   ✅ 结果: motionState='transit'
```

## 参数可调项

### 1. 离开窗口期（当前：5分钟）
```typescript
if (currentIsTransitHub || (Date.now() - this.geofenceDepartureTime < 5 * 60 * 1000)) {
  //                                                                      ↑
  // 调整这个值：
  // - 减小 → 更严格，只有刚离开才推断为乘车
  // - 增大 → 更宽松，离开后更长时间内仍认为可能是乘车
}
```

**建议值**：
- 地铁/公交：3-5 分钟（快速移动）
- 机场/火车：5-10 分钟（可能需要行走到停车场）
- 通用：5 分钟（当前值）

### 2. 枢纽关键词
在 `isTransitHub()` 中添加/删除关键词。

### 3. GPS速度辅助判断
当前实现未使用，但可以加入：
```typescript
// 可选：如果 GPS 速度与公交路线已知速度吻合，增强 transit 推断
if (gpsSpeed > 0 && gpsSpeed < 5) {
  // 较低速度 → 城市公交/地铁
} else if (gpsSpeed > 60) {
  // 高速 → 高铁/飞机（需要特殊处理）
}
```

## 限制与注意

### 已知限制
1. **GPS信号差** - 地铁内无GPS，需依赖Z轴特征+前一个围栏
2. **转车不间断** - 如果快速转车（地铁换地铁），lastGeofence 可能未更新
3. **私家停车场** - 如果停车场名称包含"station"等关键词，可能被误判为枢纽
4. **出租车不可区分** - 从普通地点上车的出租车无法自动识别（需用GPS速度辅助）

### 改进方向
1. **增加速度判断** - GPS速度 <10 km/h 且在枢纽→更强的乘车推断
2. **使用路线匹配** - 如果轨迹与已知公交/地铁路线吻合，提高 transit 置信度
3. **用户反馈** - 允许用户纠正"驾驶"→"乘车"，机器学习优化阈值
4. **多源融合** - 结合WiFi指纹库识别特定公交车/地铁车型
5. **时间周期** - 早高峰时段从枢纽出发的"驾驶"更可能是乘车

## 代码位置

**文件**：`entry/src/main/ets/service/context/ContextAwarenessService.ets`

- **字段定义**（~行160）：`lastGeofence`
- **枢纽识别**（~行1100）：`isTransitHub()`
- **推断逻辑**（~行1120）：`inferDrivingVsTransit()`
- **集成点**（~行1325）：`updateMotionState()` 中的推断调用
- **活动状态**（~行1415）：`updateActivityState()` 中的 transit 处理
- **GPS间隔**（~行1710）：`adjustLocationInterval()` 中的 transit case

## 测试建议

1. **快速验证**（5分钟）
   ```
   - 坐公交车 30 秒 → logcat 检查 motionState
   - 预期：开始为 'stationary'(等车) → 'transit'(行驶)
   ```

2. **完整测试**
   - 从不同类型枢纽出发：地铁站、公交站、机场、火车站
   - 对每种情况测试 10 次，记录准确率
   - 对比推断前后的运动状态识别准确率

3. **参数调优**
   - 如果出现"乘车被识别为驾驶"：延长离开窗口期（5→8 min）
   - 如果出现"驾驶被识别为乘车"：缩短离开窗口期（5→2 min）或审视围栏数据质量

## 规则引擎集成

可在决策树中新增规则：
```
if motionState='transit' AND previousGeofence='subway_station'
  → recommendAction: 'show_transit_reminder'
  → confidence: 0.95

if motionState='transit' AND speed>20
  → motionState='driving'  // 纠正：过快的公交/地铁不合理
  → confidence: 0.8
```

## UI 显示建议

### 当确定为 Transit 时
```
图标: 🚌 / 🚇
标签: "乘车"
副标签: "公交 / 地铁 / 火车"（根据枢纽类型）
```

### 当不确定时
```
图标: 🚗/🚌
标签: "驾驶/乘车"
副标签: "需要确认"
[确认按钮: 驾驶 | 乘车]
```

---

**创建日期**：2026-03-04  
**状态**：实现完成，待实地测试
