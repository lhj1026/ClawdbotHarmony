# Z轴振幅频率特征 - 走路vs驾车区分

## 概述
通过分析Z轴（竖直方向）的加速度振幅和频率特征，区分走路和驾车状态，特别是在GPS信号弱或不可用时。

## 核心原理

### 特征定义

| 特征 | 走路 | 驾车 | 静止 |
|------|------|------|------|
| **Z轴振幅** | 0.35~0.8g | 0.15~0.35g | <0.2g |
| **Z轴频率** | 1.5~2.5 Hz | <0.8 Hz | N/A |
| **规律性** | 高（强周期） | 低（随机） | N/A |

### 判断规则

```
if zAxisAmplitude < 0.2
  → 静止 (stationary)

if 1.2Hz ≤ zAxisFrequency ≤ 2.5Hz AND zAxisAmplitude ≥ 0.35g
  → 走路 (walking)

if (zAxisFrequency < 0.8Hz OR zAxisFrequency == 0) AND 0.15g ≤ zAxisAmplitude < 0.35g
  → 驾车 (driving)

if zAxisAmplitude ≥ 0.4g AND zAxisFrequency < 1.0Hz
  → 驾车 (driving) - 颠簸情况
```

## 实现细节

### 1. Z轴数据收集 (`recordAccelSample`)
- 维护 Z轴历史缓冲：最多1000个样本（5秒@200Hz）
- 每10个样本（~2秒）更新一次特征计算

### 2. 振幅计算 (`updateZAxisFeatures`)
```
amplitude = (max(Z) - min(Z)) / 9.8  // 转换为 g 单位
```
- 取最近2.5秒的数据
- 计算峰值-谷值差

### 3. 频率估计 (`estimateFrequencyByAutocorr`)
- 使用**自相关**算法检测周期
- 寻找第一个明显的负峰（对应一个完整周期）
- lag → 频率转换：`f = (1000/dt) / lag`
  - 走路：lag ~80-130 → 1.5-2.5 Hz
  - 驾车：lag >400 或 lag=0 → <0.8 Hz 或无规律

### 4. 方差计算
```
variance = Σ(z[i] - mean)² / N
```
- 走路时方差较大（高频震荡）
- 驾车时方差中等或随机

### 5. 集成到运动状态判断 (`updateMotionState`)

**场景A：GPS速度 1.5~5 m/s**
- 原来：只用 magnitude（加速度大小）判走路/跑步
- 现在：先用 Z轴特征判，无结果再用 magnitude

**场景B：GPS速度 < 1.5 m/s**
- 原来：直接用多数投票（classifyWithSmoothing）
- 现在：**优先用 Z轴特征**，无结果再用多数投票

## 数据记录到 DataTray

三个新的 key 供上层 UI/规则引擎读取：
```typescript
zAxisAmplitude: number  // 振幅 (g)
zAxisFrequency: number  // 频率 (Hz)
zAxisVariance: number   // 方差
```

用于调试、规则引擎决策树扩展、UI展示等。

## 测试建议

### 1. 实地测试（完整周期）

#### A. 走路场景
- 室内走路（10步左右）
- 室外走路（有GPS）
- 楼梯上下
- 快走/慢走
- 直线走和转弯走

**预期结果：**
- 频率 1.8±0.3 Hz
- 振幅 0.45±0.15 g
- 误判为驾车？减小频率上限或提高幅度阈值

#### B. 驾车场景
- 正常行驶（时速 30-50 km/h）
- 红灯停车（0 m/s but motion='driving'）
- 高速行驶（>80 km/h）
- 颠簸不平路面
- 地下停车场（GPS无信号）

**预期结果：**
- 频率 0.2~0.5 Hz（或0表示无规律）
- 振幅 0.2~0.4 g
- 误判为走路？提高频率下限

#### C. 静止场景
- 桌子前坐着（不动）
- 躺在床上（不动）
- 站着静止

**预期结果：**
- 振幅 <0.15 g
- 无周期性（frequency=0）

### 2. 自动化测试

创建 `SensorPlayer.ets` 回放模式的测试用例：
```typescript
// 加载真实的走路数据，验证特征
let walkingData = loadSensorRecording('walking_indoor.json');
playback(walkingData);
// 断言: zAxisFrequency in [1.5, 2.5]
// 断言: zAxisAmplitude > 0.35
```

### 3. 参数调优流程

1. **收集基线数据** (10次走路, 10次驾车, 10次静止)
   ```bash
   # 记录原始加速度 + 计算的特征
   sensor_log = [timestamp, x, y, z, freq, amp, state]
   ```

2. **绘制分布图**
   ```
   scatter(zAxisFrequency, zAxisAmplitude, color=state)
   ```

3. **微调阈值**
   - 如果有交叉，根据错误率调整边界
   - 优先保护驾车识别（避免驾车被误判为走路导致GPS频繁刷新）

4. **迭代验证** (新数据集)

## 日志关键字

调试时在 logcat 中搜索：
```
// 特征更新
"zAxisAmplitude=" "zAxisFrequency=" "zAxisVariance="

// 运动状态变化
"Motion state:"
"Z轴特征判断" (如果添加了调试日志)

// 规则引擎匹配
"evaluation"
```

## 未来优化方向

1. **迁到 C++ NAPI** - 减少 ArkTS 计算负担，提高精度
2. **FFT 替代自相关** - 更准确的频率估计
3. **机器学习** - 用真实数据训练 SVM/NN，取代阈值判断
4. **多维融合** - 结合步长、GPS速度变化率、GPS精度等
5. **围栏辅助** - 在已知室内围栏内优先信任走路，驾车场景优先信任GPS

## 代码位置

- **ArkTS 实现**：`entry/src/main/ets/service/context/ContextAwarenessService.ets`
  - 行 ~200: 字段定义 (zAxisHistory, zAxisAmplitude, etc.)
  - 行 ~880: recordAccelSample() 中的收集逻辑
  - 行 ~1020: updateZAxisFeatures() 特征计算
  - 行 ~1056: estimateFrequencyByAutocorr() 频率估计
  - 行 ~1098: classifyByZAxisFeatures() 分类逻辑
  - 行 ~1180, 1200: updateMotionState() 中的集成

## 已知限制

1. **自相关算法可能不稳定** 在低SNR（如地下停车场回声）时
   - 解决：改用更稳健的频率估计（如Welch方法）或迁到C++

2. **频率阈值固定** 不同步态（缓走/快走）差异可能大
   - 解决：动态调整阈值或用ML模型

3. **Z轴方向依赖** 手机倾斜时特征变化
   - 解决：归一化加速度向量或用更多维度（XY轴）

## 参考

- 走路频率标准文献：1.5-2.5 Hz @成年人正常步速
- 自相关原理：https://en.wikipedia.org/wiki/Autocorrelation
