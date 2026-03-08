# 手机姿态与运动状态冲突修复

## 问题描述

**用户反馈**："如果是步行，不可能是平放桌上"

## 逻辑冲突

**运动状态**（motionState）和**手机姿态**（phone_posture）是独立判断的：
- **运动状态**：由 ContextAwarenessService 判断（walking/running/driving/...）
- **手机姿态**：由 PosturePlugin 判断（on_desk/face_up/in_use/...）

**冲突**：PosturePlugin 只用**光线传感器**和**加速度计倾斜**判断，不知道用户是否在运动：

```typescript
// PosturePlugin 原逻辑（有问题）
if (isFlat && ambientLux >= 10) {
  posture = 'on_desk';  // ❌ 用户可能在走路，手机在口袋/手中！
}
```

**结果**：用户走路时，手机可能被误判为 `on_desk`

## 错误场景

| 真实场景 | PosturePlugin 判断 | 错误 |
|---------|-------------------|------|
| 步行（手机在口袋） | `on_desk`（暗光+平放误判） | ❌ |
| 跑步（手机在手） | `face_up`（暗光+平放误判） | ❌ |
| 驾车（手机在支架） | `on_desk`（平放误判） | ❌ |

## 修复方案

### 核心规则

```
if (isMoving) {
  // 运动中(步行/跑步/驾车/乘车/骑车)时：
  // 手机不可能平放在桌上 → 纠正姿态判断

  if (posture === 'on_desk' || posture === 'flat' || posture === 'face_up') {
    if (proximity === 'near') {
      posture = 'in_pocket';  // 口袋中
    } else {
      posture = 'in_use';     // 手中握持
    }
  }
}
```

### 实现位置

**文件**：`PhysicalStateBuilder.ets`

**方法**：`classifyPhone()`

**改动**：在 PosturePlugin 判断后、switch 之前加入运动状态检查：

```typescript
// 关键规则：运动中时，手机不可能平放在桌上
if (isMoving && (posture === 'on_desk' || posture === 'flat' || posture === 'face_up')) {
  if (proximity === 'near') return 'in_pocket';
  return 'in_use';
}

// 然后才进入原有的 switch 判断
switch (posture) { ... }
```

## 修复后的判断逻辑

### 场景1：步行（手机在口袋）

**输入**：
- `motionState` = 'walking'
- `posture` = 'on_desk'（PosturePlugin 误判）
- `proximity` = 'near'

**修复流程**：
```
isMoving=true → 检查 posture
posture='on_desk' + proximity='near' → 纠正为 'in_pocket' ✅
```

### 场景2：跑步（手机在手）

**输入**：
- `motionState` = 'running'
- `posture` = 'face_up'（PosturePlugin 误判）
- `proximity` = 'far'

**修复流程**：
```
isMoving=true → 检查 posture
posture='face_up' + proximity='far' → 纠正为 'in_use' ✅
```

### 场景3：驾车（手机在支架）

**输入**：
- `motionState` = 'driving'
- `posture` = 'on_desk'（PosturePlugin 误判）
- `proximity` = 'far'

**修复流程**：
```
isMoving=true → 检查 posture
posture='on_desk' + proximity='far' → 纠正为 'in_use' ✅
（在车载支架上 = 被使用）
```

## 对比表

| 真实场景 | PosturePlugin | 原判断 | 新判断 | 改进 |
|---------|--------------|-------|-------|------|
| 步行（口袋） | `on_desk` | ❌ on_desk | ✅ **in_pocket** | ✅ |
| 跑步（手中） | `face_up` | ❌ face_up | ✅ **in_use** | ✅ |
| 驾车（支架） | `on_desk` | ❌ on_desk | ✅ **in_use** | ✅ |
| 静止（桌上） | `on_desk` | ✅ on_desk | ✅ on_desk | 保持 |

## 性能影响

- **计算复杂度**：O(1)（只是额外的 if 判断）
- **CPU**：<0.01% 增加（可忽略）
- **内存**：0 增加
- **电耗**：0 增加

## 测试方案

### 快速验证（5分钟）

```bash
# 1. 开始走路（5步以上）
# 观察 phonePosture 的变化

hdc shell hilog | grep "phonePosture\|classifyPhone"

# 期望：
# motionState=walking, posture=on_desk
# → classifyPhone -> in_pocket ✅
```

### 完整测试（10分钟）

1. **步行场景**
   ```
   - 开始走路
   - 检查 phonePosture
   - 期望：in_pocket 或 in_use（不是 on_desk）
   ```

2. **跑步场景**
   ```
   - 开始跑步
   - 检查 phonePosture
   - 期望：in_use（不是 face_up）
   ```

3. **驾车场景**
   ```
   - 开始驾车
   - 检查 phonePosture
   - 期望：in_use（不是 on_desk）
   ```

4. **静止场景**（对照）
   ```
   - 平放在桌上
   - 检查 phonePosture
   - 期望：on_desk（保持正确）
   ```

## 边界情况

### 1. 刚停止运动

**场景**：从 walking → stationary，但 PosturePlugin 还没更新

**处理**：
- `isMoving` 由 motionState 决定
- motionState 变为 stationary 时，`isMoving=false`
- 此时允许 `on_desk` 判断

**正确**：是

### 2. 公交/地铁颠簸

**场景**：坐公交时，手机在包里颠簸

**输入**：
- `motionState` = 'transit'
- `posture` = 'face_up'（颠簸导致误判）
- `proximity` = 'far'

**处理**：
```
isMoving=true（transit 算运动）
posture='face_up' + proximity='far' → in_use
```

**可能不完全准确**（在包里不是"使用"），但比 `face_up` 好

**改进方向**：可增加 `in_bag` 状态（需要陀螺仪辅助）

### 3. 骑自行车

**场景**：骑自行车，手机在支架上

**输入**：
- `motionState` = 'cycling'
- `posture` = 'on_desk'（支架平放误判）
- `proximity` = 'far'

**处理**：
```
isMoving=true（cycling 算运动）
posture='on_desk' + proximity='far' → in_use ✅
```

**正确**：是（在支架上 = 使用导航）

## 回滚方案

如果出现问题，快速回滚：

```typescript
// 注释掉新增的运动检查
/*
if (isMoving && (posture === 'on_desk' || posture === 'flat' || posture === 'face_up')) {
  if (proximity === 'near') return 'in_pocket';
  return 'in_use';
}
*/
```

将回到原有的 PosturePlugin 判断逻辑。

## 未来优化

### 1. 引入陀螺仪

检测手机的微小运动（口袋里的晃动 vs 桌上的静止）：
```typescript
if (gyroscopeVariance > threshold) {
  // 有晃动 → 口袋/手中
} else {
  // 完全静止 → 桌上
}
```

### 2. 机器学习模型

训练分类器：
- 输入：加速度计(x,y,z) + 陀螺仪 + 光线 + proximity + motionState
- 输出：phone_posture（更准确）

### 3. 场景融合

将 motionState 和 phonePosture 在更高层融合：
```typescript
interface FusedContext {
  motion: MotionState;
  posture: PhonePosture;
  confidence: number;
}

function fuseMotionAndPosture(motion, posture): FusedContext {
  if (motion === 'walking' && posture === 'on_desk') {
    return { motion: 'walking', posture: 'in_pocket', confidence: 0.95 };
  }
  // ... 其他融合规则
}
```

## 代码位置

**修改文件**：
- `entry/src/main/ets/service/context/PhysicalStateBuilder.ets`

**修改方法**：
- `classifyPhone()` - 新增运动状态检查

**改动行数**：
- +7 行（if 判断 + 逻辑）

---

**创建日期**：2026-03-04
**状态**：实现完成，待测试
**优先级**：高（逻辑冲突修复）
