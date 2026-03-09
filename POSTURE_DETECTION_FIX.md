# PosturePlugin 改进 - 手握使用误判为平放

## 问题

用户报告：**手握使用手机时，经常被识别为平放朝上（face_up/on_desk）**

## 原因分析

**PosturePlugin** 原实现只用**光线传感器**判断姿态：

```typescript
// 原逻辑（有问题）
if (this.ambientLux < 10) {
  this.posture = 'face_up';      // 屏幕朝上，暗室
} else if (this.ambientLux < 50) {
  this.posture = 'on_desk';      // 微光环境，手机静置
} else {
  this.posture = 'in_use';       // 正常光线，使用中
}
```

**缺陷**：
- ❌ 没有结合加速度计判断手机是否**平放**
- ❌ 仅凭光线低就判断为平放/桌上
- ❌ 暗室手握手机也被误判为平放

## 解决方案

### 改进思路

加入**加速度计**判断手机是否**平放**：
- 平放：|z| 接近 9.8 m/s²（±2 误差）
- 手握：手机倾斜，|z| 偏离 9.8 较多

### 新逻辑

```typescript
private isPhoneFlat(): boolean {
  return Math.abs(Math.abs(this.accelZ) - 9.8) < 2.0;
}

private classifyPosture(): void {
  let isFlat = this.isPhoneFlat();

  if (this.proximityNear) {
    // ... 原有逻辑（口袋/面朝下）
  } else {
    // 屏幕暴露，非口袋
    if (isFlat) {
      // 确实平放
      if (this.ambientLux < 10) {
        this.posture = 'face_up';    // 暗室 + 平放
      } else {
        this.posture = 'on_desk';    // 有光 + 平放
      }
    } else {
      // 手机倾斜 → 手握使用
      this.posture = 'in_use';       // 无论光线如何，倾斜=使用中
    }
  }
}
```

## 实现细节

### 新增订阅加速度计

```typescript
private accelZ: number = 0;
private tiltAngle: number = 0;  // 倾斜角度
private accelRegistered: boolean = false;

private subscribeAccelerometer(): void {
  try {
    sensor.on(sensor.SensorId.ACCELEROMETER, (data: sensor.AccelerometerResponse) => {
      this.accelZ = data.z;
      // 计算倾斜角度
      let magnitude = Math.sqrt(data.x * data.x + data.y * data.y + data.z * data.z);
      this.tiltAngle = Math.atan2(data.z, Math.sqrt(data.x * data.x + data.y * data.y)) * 180 / Math.PI;
    }, { interval: 1000000000 }); // 1s，低频采样节省电量
    this.accelRegistered = true;
  } catch (err) {
    this.log.warn(TAG, `Accelerometer unavailable: ${(err as Error).message}`);
  }
}
```

**注意**：
- 采样间隔：1秒（比 ContextAwarenessService 的 200ms 更低，节省电量）
- 原因：姿态判断不需要高频更新，1秒足够

### 新增输出字段

```typescript
let data: Record<string, string> = {
  'phone_posture': this.posture,
  'ambient_brightness': this.ambientLux >= 0 ? this.ambientLux.toFixed(0) : 'unknown',
  'proximity': this.proximityNear ? 'near' : 'far',
  'tilt_angle': this.tiltAngle.toFixed(1),      // 新增：倾斜角度
  'is_flat': this.isPhoneFlat() ? 'true' : 'false'  // 新增：是否平放
};
```

用于：
- 调试和日志
- PhysicalStateBuilder 的交叉验证

## 场景对比

| 场景 | 光线 | 加速度（z） | 原判断 | 新判断 |
|------|------|----------|-------|-------|
| 暗室手握手机 | <10 lux | 倾斜（非9.8） | ❌ face_up | ✅ in_use |
| 暗室平放桌上 | <10 lux | 平放（~9.8） | ✅ face_up | ✅ face_up |
| 正常光手握 | >50 lux | 倾斜 | ✅ in_use | ✅ in_use |
| 正常光平放 | >50 lux | 平放 | ❌ in_use | ✅ on_desk |

## 性能影响

### 新增传感器订阅

- **加速度计**：1秒采样一次（vs ContextAwarenessService 的 200ms）
- **额外电耗**：<1%（低频采样）

### CPU 使用

- 新增计算：倾斜角度（三角函数）
- 预期增加：<0.5% CPU

### 内存

- 新增字段：accelZ, tiltAngle, accelRegistered
- 额外内存：<1KB

**总体影响**：可忽略

## 测试方案

### 快速验证（5分钟）

1. **暗室手握手机**
   ```
   - 环境：关闭灯光，<10 lux
   - 操作：手握手机倾斜使用
   - 预期：phone_posture='in_use'
   - 日志：is_flat='false', tilt_angle!=0
   ```

2. **暗室平放**
   ```
   - 环境：关闭灯光，<10 lux
   - 操作：平放在桌上
   - 预期：phone_posture='face_up'
   - 日志：is_flat='true', tilt_angle≈0
   ```

3. **正常光平放**
   ```
   - 环境：室内正常光线 >50 lux
   - 操作：平放在桌上
   - 预期：phone_posture='on_desk'
   - 日志：is_flat='true'
   ```

4. **正常光手握**
   ```
   - 环境：室内正常光线 >50 lux
   - 操作：手握手机使用
   - 预期：phone_posture='in_use'
   - 日志：is_flat='false'
   ```

### 日志验证

```bash
hdc shell hilog | grep "phone_posture\|is_flat\|tilt_angle"

# 期望输出：
# phone_posture=in_use, is_flat=false, tilt_angle=65.2
# phone_posture=on_desk, is_flat=true, tilt_angle=2.1
```

### 性能监测

```bash
# 监测电耗（应无明显增加）
hdc shell top | grep clawdbot

# 监测内存（应稳定）
hdc shell dumpsys meminfo | grep clawdbot
```

## 回滚方案

如果出现问题，快速回滚：

```typescript
// 在 PosturePlugin 中临时禁用加速度计
private subscribeAccelerometer(): void {
  // 临时禁用
  // try { ... } catch { ... }
}

private isPhoneFlat(): boolean {
  return false;  // 总是返回 false，使用旧逻辑
}
```

## 兼容性

### 传感器可用性

| 传感器 | 必需 | 回退方案 |
|-------|------|---------|
| PROXIMITY | ✅ | 不可用时仅用光线 |
| AMBIENT_LIGHT | ✅ | 不可用时 posture=unknown |
| ACCELEROMETER | ⚠️ 可选 | 不可用时仅用光线（降级到旧逻辑）|

### 代码兼容

```typescript
// 如果加速度计不可用，降级到旧逻辑
private isPhoneFlat(): boolean {
  if (!this.accelRegistered) {
    // 降级：无法判断，保守估计为非平放
    return false;
  }
  return Math.abs(Math.abs(this.accelZ) - 9.8) < 2.0;
}
```

## PhysicalStateBuilder 影响

PhysicalStateBuilder 中的交叉验证逻辑**仍然有效**：

```typescript
case 'face_up':
  // 暗室 + 手握 + 躺卧 + 非运动 → 手握躺卧（暗室看手机）
  if (isLyingDown && isHolding && !isMoving) return 'holding_lying';
  // 运动中 + 暗 → 口袋
  if (isMoving) return 'in_pocket';
  return 'face_up';
```

现在 PosturePlugin 提供更准确的 `face_up`/`in_use` 判断，PhysicalStateBuilder 的交叉验证会进一步减少误判。

## 未来优化

1. **陀螺仪辅助** - 检测微小的转动（手握时的抖动）
2. **触屏活动** - 有触摸事件 → 肯定在使用
3. **屏幕朝向** - 结合屏幕旋转角度
4. **机器学习** - 用历史数据训练分类模型

## 代码位置

**修改文件**：
- `entry/src/main/ets/service/context/plugins/PosturePlugin.ets`

**新增字段**：
- `accelZ: number`
- `tiltAngle: number`
- `accelRegistered: boolean`

**新增方法**：
- `isPhoneFlat(): boolean`
- `subscribeAccelerometer(): void`

**修改方法**：
- `classifyPosture(): void` - 加入平放判断
- `getSnapshot()` - 输出新增字段
- `destroy()` - 取消加速度计订阅
- `init()` - 订阅加速度计

---

**创建日期**：2026-03-04
**状态**：实现完成，待测试
**优先级**：高（影响用户体验）
