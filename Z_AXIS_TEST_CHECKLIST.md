# Z轴特征实现 - 测试验收清单

## ✅ 编译与部署

- [ ] 无编译错误
- [ ] 无 TypeScript 类型错误
- [ ] HAP 构建成功
- [ ] 安装到手机成功
- [ ] 应用启动无崩溃

## 📊 功能验证

### 1. 特征计算验证

在 logcat 中观察以下输出（使用 `hdc shell hilog | grep -i "zaxis\|zAxisAmplitude\|zAxisFrequency"`）：

#### A. 走路场景（10次，每次5步）

**操作**
```
1. 打开应用 → 观察 motion=unknown
2. 开始走路（保持手机自然握持）
3. 走5步停下
4. 观察 logcat
```

**期望日志**
```
zAxisAmplitude=0.45...  // 0.35-0.65g
zAxisFrequency=1.80...  // 1.5-2.3 Hz
zAxisVariance=2.50...
Motion state: unknown -> walking
```

**验证项**
- [ ] 频率在 1.5-2.5 Hz 范围内
- [ ] 振幅 ≥ 0.35g
- [ ] 识别为 walking
- [ ] 重复10次，记录最小/最大/平均值

| 次数 | 频率(Hz) | 振幅(g) | 识别结果 | 备注 |
|------|---------|---------|---------|------|
| 1 | | | | |
| 2 | | | | |
| ... | | | | |

#### B. 驾车场景（3个小场景）

**B1: 正常驾车（30-50 km/h）**
```
1. 启动引擎（静止）
2. 开始驾驶，保持匀速
3. 持续15秒
4. 观察特征稳定性
```

**期望**
```
zAxisAmplitude=0.25...  // 0.15-0.35g
zAxisFrequency=0.50...  // 0.2-0.8 Hz
Motion state: ... -> driving
```

**验证项**
- [ ] 频率 < 0.8 Hz
- [ ] 振幅 0.15-0.35g
- [ ] 识别为 driving
- [ ] GPS速度 >5 m/s 时应该已经是 driving

**B2: 红灯停车（v=0但保持驾车状态）**
```
1. 从 driving 状态
2. 减速停车（红灯）
3. 持续10秒静止
4. 观察是否维持 driving（惯性保护）
```

**期望**
```
Motion state: driving -> driving (惯性)
zAxisAmplitude < 0.2  // 停车时振幅降低
// 但由于 DRIVING_INERTIA_MS=90秒，应维持 driving
```

**验证项**
- [ ] 停车后仍是 driving（不立即变为 stationary）
- [ ] 超过90秒后逐渐转为 walking/stationary
- [ ] 步数 <20 时不转状态

**B3: 颠簸路面（地下停车场或山路）**
```
1. 驾驶在颠簸路面
2. 持续10秒
3. 观察特征
```

**期望**
```
zAxisAmplitude=0.40...  // 可能偏高（颠簸）
zAxisFrequency=很低或=0  // 无规律，自相关无周期
Motion state: driving
```

**验证项**
- [ ] 仍识别为 driving（不误判为走路）
- [ ] 频率接近0或很低

#### C. 静止场景（3个状态）

**C1: 坐着不动（办公桌）**
```
1. 手机放在桌上（平放）
2. 30秒不动
3. 观察特征
```

**期望**
```
zAxisAmplitude < 0.15
zAxisFrequency = 0  // 完全无周期
Motion state: stationary
```

**验证项**
- [ ] 振幅 < 0.2g
- [ ] 识别为 stationary

**C2: 躺着不动（床上）**
```
1. 躺在床上，手机放在胸口
2. 30秒完全不动
3. 观察特征
```

**期望**
```
zAxisAmplitude < 0.15
isLyingDown = true
Motion state: stationary or pickup (如果检测到拿起)
```

**验证项**
- [ ] 正确识别为躺卧 (isLyingDown=true)
- [ ] 不误判为走路

**C3: 站着静止**
```
1. 站着不动，手机握在手
2. 30秒
3. 观察特征
```

**期望**
```
zAxisAmplitude < 0.2
isHolding = true
Motion state: stationary
```

**验证项**
- [ ] 虽然握着但无运动
- [ ] 识别为 stationary

### 2. 数据完整性检查

检查 DataTray 中新字段是否正确写入：

```bash
# 查看 TrayStatus
hdc shell hilog | grep "TrayStatus\|zAxisAmplitude\|zAxisFrequency"
```

**验证项**
- [ ] zAxisAmplitude 在 [0, 2] 范围内
- [ ] zAxisFrequency 在 [0, 50] 范围内（合理Hz值）
- [ ] zAxisVariance > 0
- [ ] 数据不是 NaN 或 Infinity

### 3. 规则引擎集成（可选）

如果启用了探索模式或规则引擎：

```bash
hdc shell hilog | grep "evaluate\|rule"
```

**验证项**
- [ ] 特征被规则引擎读到（在条件判断中）
- [ ] 可以新增规则如：`zAxisFrequency in [1.5, 2.5] AND zAxisAmplitude > 0.35 → confidence+=0.5`

## 🔍 性能检查

### CPU/内存使用

```bash
# 监测应用进程
hdc shell top | grep clawdbot  # 查看 CPU% 和 内存

# 特别关注 Z轴计算的耗时
# 在 updateZAxisFeatures() 前后添加时间戳
```

**期望**
- [ ] 每次 updateZAxisFeatures() < 5ms（自相关 O(n²)）
- [ ] 内存增长 < 1MB（相对于基础）
- [ ] 电池消耗无明显增加（计算频率：每2秒一次）

## 📈 数据采集与调优

### 基线数据集合

在 3 个典型场景各收集 10 组数据：

```json
{
  "scenario": "walking|driving|stationary",
  "speed_gps": 0.5,
  "zAxisAmplitude": 0.45,
  "zAxisFrequency": 1.8,
  "zAxisVariance": 2.5,
  "motionState": "walking",
  "confidence": 0.9,
  "timestamp": 1234567890
}
```

**收集方法**
1. 在 logcat 导出 log
2. 用脚本解析关键字段
3. 生成 CSV 或 JSON
4. 绘制分布图确认无交叠

### 错误分析

如果出现误判：

**误判：走路被识别为驾车**
```
原因可能：
- 频率估计错误（自相关不稳定）
- 手握方式导致 Z 轴变化异常
- 楼梯/不规则步伐

调优方向：
- 提高频率下限：1.5 → 1.3 Hz
- 或降低幅度阈值：0.35 → 0.3g
- 检查自相关算法（可能需要低通滤波Z轴）
```

**误判：驾车被识别为走路**
```
原因可能：
- 道路平坦，Z轴振幅太小
- 颠簸过度被当成周期信号

调优方向：
- 降低频率上限：2.5 → 2.2 Hz
- 检查速度辅助信号是否生效
- 确保 GPS 速度 > 5 时直接判 driving
```

## 🎯 验收标准

### 最小可接受标准（MVP）
- [x] 无编译错误
- [x] 三个场景各正确识别一次
- [x] 特征数据正确记录到 DataTray

### 推荐标准
- [ ] 三个场景各 10 次测试，准确率 > 90%
- [ ] 性能满足（CPU < 10%, 内存 +0 MB）
- [ ] 数据分布无明显交叠

### 优化标准
- [ ] 准确率 > 95%
- [ ] 参数已根据基线数据调优
- [ ] 规则引擎新增相关规则

## 📋 问题记录

如遇见问题，记录：

| 问题 | 场景 | 重现步骤 | 预期vs实际 | 原因分析 | 解决方案 |
|------|------|---------|----------|---------|---------|
| | | | | | |

## 完成标志

当满足以下条件时，可认为实现完成：

```
□ 所有编译检查通过
□ 三个基本场景各成功演示一遍
□ logcat 日志显示特征正确计算
□ 性能无异常
□ 文档已更新
□ 代码提交到 git 并推送
```

## 下一步（如需要）

1. **收集更大数据集** - 20+ 个不同用户，各类环境
2. **迁移到 C++** - 如性能不满足或需要更高精度
3. **引入 ML** - 用真实数据训练，取代固定阈值
4. **UI 展示** - 在设置页或主页显示实时频率/幅度波形
5. **规则库扩展** - 为情景智能框架添加新规则利用这些特征
