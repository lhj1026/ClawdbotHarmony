# Z轴特征实现 - 改动总结

## 📝 改动概述

在 `ContextAwarenessService.ets` 中实现了基于 Z 轴加速度的走路 vs 驾车区分，特别优化了 GPS 信号弱或无信号的场景。

**文件**: `entry/src/main/ets/service/context/ContextAwarenessService.ets`

## 🔧 核心改动

### 1. 新增字段定义（~行 200）
```typescript
// Z轴振幅和频率特征（用于走路vs驾车区分）
private zAxisHistory: Array<{ value: number; timestamp: number }> = [];
private static readonly Z_AXIS_HISTORY_SIZE = 1000;  // 5秒@200Hz
private zAxisFrequency: number = 0;  // Hz
private zAxisAmplitude: number = 0;  // g
private zAxisVariance: number = 0;   // 规律性指标
```

### 2. Z轴样本收集（~行 880，在 `recordAccelSample()` 中）
```typescript
// 记录 Z 轴值用于频率分析
this.zAxisHistory.push({
  value: z,
  timestamp: this.accelerometerData.timestamp
});

if (this.zAxisHistory.length > ContextAwarenessService.Z_AXIS_HISTORY_SIZE) {
  this.zAxisHistory.shift();
}

// 更新 Z 轴特征（每10个样本计算一次，约2秒）
if (this.zAxisHistory.length % 10 === 0) {
  this.updateZAxisFeatures();
}
```

### 3. 特征计算（~行 1020-1048，新增函数 `updateZAxisFeatures`）
- 计算 Z 轴 **振幅** = (max - min) / 9.8
- 计算 Z 轴 **方差**（规律性指标）
- 计算 Z 轴 **频率**（通过自相关）

### 4. 频率估计算法（~行 1056-1095，新增函数 `estimateFrequencyByAutocorr`）
- 基于自相关检测周期
- 走路：~1.5-2.5 Hz
- 驾车：<0.8 Hz 或无规律（freq=0）
- 返回合理范围的 Hz 值

### 5. 分类逻辑（~行 1098-1130，新增函数 `classifyByZAxisFeatures`）
根据振幅+频率判定运动状态：
```
振幅 < 0.2g → stationary
1.2-2.5Hz + ≥0.35g → walking
低频 + 0.15-0.35g → driving
高幅+低频 → driving
其他 → unknown（让上层逻辑继续处理）
```

### 6. 集成到运动状态决策（~行 1180, 1200，修改 `updateMotionState`）

**场景A：GPS速度 1.5~5 m/s**
```typescript
// GPS速度不可靠时用 Z 轴特征辅助
let zAxisClassify = this.classifyByZAxisFeatures();
if (zAxisClassify !== 'unknown') {
  newState = zAxisClassify;  // 用 Z 轴判断
} else {
  newState = magnitude > 12 ? 'running' : 'walking';  // 降级到 magnitude
}
```

**场景B：GPS速度 < 1.5 m/s**
```typescript
// GPS 不可用时，用 Z 轴特征优先判断
let zAxisClassify = this.classifyByZAxisFeatures();
if (zAxisClassify !== 'unknown') {
  newState = zAxisClassify;  // 优先用 Z 轴
} else {
  newState = this.classifyWithSmoothing();  // 降级到多数投票
}
```

## 📊 输出数据

新增三个 DataTray key，供上层使用：

| Key | 范围 | 含义 |
|-----|------|------|
| `zAxisAmplitude` | 0~2 g | Z轴振幅 |
| `zAxisFrequency` | 0~50 Hz | Z轴主频率 |
| `zAxisVariance` | 0~100 | Z轴规律性 |

这些值实时更新到 DataTray，可用于：
- **UI展示** - 用户可以看到实时振动特征
- **规则引擎** - 可新增规则如 `zAxisFrequency in [1.5, 2.5]`
- **调试** - 验证特征计算正确性

## 🎯 解决的问题

### 原问题
在运动状态识别中，走路容易被误判为驾车，原因：
1. GPS 信号弱或无信号（地下停车场、隧道）时，speed=0 无法判断
2. 仅靠加速度 magnitude 无法区分（magnitude ~10-12 时两者都可能）
3. 频繁 GPS 刷新造成电耗

### 解决方案
引入 Z 轴频率特征，利用人体步态的周期性（1.5-2.5 Hz）与车辆运动的随机性显著不同这一特点。

### 预期改进
- ✅ GPS不可用时仍能准确识别走路 vs 驾车
- ✅ 减少误判率（特别是在弱GPS环境）
- ✅ 间接降低电耗（GPS 刷新频率可能降低）

## 🔍 验证方法

### 快速验证（5分钟）
```bash
# 1. 走路 5 步 → 观察 logcat
hdc shell hilog | grep "zAxisFrequency"
# 期望：频率 1.5-2.5 Hz

# 2. 开车 30 秒 → 观察 logcat  
hdc shell hilog | grep "zAxisFrequency"
# 期望：频率 <0.8 Hz 或 0

# 3. 站着不动 → 观察 logcat
hdc shell hilog | grep "zAxisAmplitude"
# 期望：振幅 <0.2 g
```

### 完整测试
见 `Z_AXIS_TEST_CHECKLIST.md`

## ⚙️ 参数调优

如果实地测试发现误判，可调整阈值：

```typescript
// 在 classifyByZAxisFeatures() 中
if (this.zAxisFrequency >= 1.2 && this.zAxisFrequency <= 2.5 && this.zAxisAmplitude >= 0.35) {
  //                     ↑ 下限   ↑ 上限                        ↑ 幅度阈值
  // 调整以减少误判
  return 'walking';
}
```

常见调优：
- **走路被识别为驾车** → 降低频率下限（1.2→1.0）或幅度下限（0.35→0.3）
- **驾车被识别为走路** → 提高频率上限（2.5→2.2）或检查 GPS 速度逻辑

## 📚 文档

- `Z_AXIS_MOTION_DETECTION.md` - 完整的设计和原理
- `Z_AXIS_TEST_CHECKLIST.md` - 测试验收清单
- `Z_AXIS_IMPLEMENTATION_SUMMARY.md` - 本文件，改动概览

## 🚀 下一步建议

1. **编译和部署** → `scripts/build_and_install.bat`
2. **实地测试** → 按 TEST_CHECKLIST 逐一验证
3. **数据采集** → 收集 10+ 个场景的基线数据
4. **参数调优** → 根据误判情况微调阈值
5. **规则扩展** → 在决策树中新增利用 zAxisFrequency 的规则
6. **C++ 迁移** （可选）→ 提高性能和稳定性

## 技术细节

### 自相关算法为什么适合
- 检测周期性很有效 → 走路是周期运动
- 对噪音容忍度高 → 加速度计噪音不影响
- 计算复杂度可接受 → O(n²) 但 n~200

### 为什么选择 Z 轴
- Z 轴（竖直方向）是步态振动最明显的轴
- X/Y 轴（水平）受转身、步态偏斜影响大
- Z 轴与重力同轴，特征稳定

### 频率范围选择
- 成年人正常步速：1.5-2.5 步/秒（文献标准）
- 提速跑步：2.5-3.0 Hz
- 开车：颠簸频率多为 0.5-1.0 Hz（悬挂系统特性）
- 高铁/飞机：频率更低 <0.2 Hz

## 潜在风险

1. **自相关算法不稳定** → 在极其嘈杂环境可能失效
   - 缓解：低通滤波 Z 轴信号，或改用 FFT
   
2. **参数不通用** → 不同人步幅/手握方式差异
   - 缓解：机器学习或自适应算法

3. **计算耗电** → 每 2 秒一次自相关 O(n²)
   - 缓解：迁到 C++ NAPI，或降低计算频率

## 测试环境
- **设备**：HarmonyOS 12+
- **SDK**：API 12~22
- **传感器**：ACCELEROMETER@200Hz
- **依赖**：无新增第三方库

---

**创建日期**：2026-03-04  
**状态**：实现完成，待测试和调优
