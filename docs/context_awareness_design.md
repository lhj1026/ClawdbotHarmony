# ClawdBot 情景智能设计文档

## 1. 多级采集策略 (功耗优化)

### 1.1 设计原则
- 根据运动状态动态调整传感器采集频率
- 静止时降低采集频率以节省功耗
- 运动时提高采集频率以保证精度
- **使用 CellID 代替 GPS 进行位置变化检测**

### 1.2 CellID 位置变化检测 (功耗优化)

**原理**：基站CellID变化说明用户可能移动了，CellID不变说明用户位置没变

**策略**：
```
1. 获取当前 CellID
2. 如果 CellID 与上次相同：
   - 不请求 GPS
   - 继续使用缓存的 GPS 位置
3. 如果 CellID 变化：
   - 可能移动了，请求一次 GPS
   - 更新缓存位置
```

**优势**：
- CellID 获取功耗极低（网络状态的一部分）
- 大幅减少 GPS 请求次数
- 在室内/静止场景下特别有效

**API**：`@ohos.telephony.radio` - `getSignalInformation()` 或监听网络状态变化

### 1.3 采集间隔配置

| 运动状态 | GPS间隔 | WiFi间隔 | 加速度计间隔 | 说明 |
|---------|---------|----------|-------------|------|
| stationary (静止) | 5分钟 | 5分钟 | 5秒 | 在家/办公室久坐 |
| walking (步行) | 30秒 | 2分钟 | 1秒 | 低速移动 |
| running (跑步) | 15秒 | 5分钟 | 500ms | 高频运动，不需要WiFi |
| driving (驾驶) | 5秒 | 关闭 | 2秒 | 高速移动，频繁更新GPS |
| unknown (未知) | 1分钟 | 2分钟 | 1秒 | 默认配置 |

### 1.3 运动状态检测
- **加速度传感器**：检测身体运动
- **GPS速度**：解决开车/高铁匀速问题
  - GPS速度 > 20m/s (72km/h) → 驾驶
  - GPS速度 > 5m/s (18km/h) → 驾驶/骑行
  - GPS速度 > 1.5m/s (5.4km/h) → 跑步/快走

### 1.4 拿起手机检测 (TODO)
**问题**：当前"拿起手机"会触发运动状态变化，导致不必要的GPS重采样

**解决方案**：
```
拿起手机特征：
- 加速度计：短暂脉冲 + 重力方向变化
- 陀螺仪：快速旋转
- 持续时间：< 3秒

运动特征：
- 加速度计：持续变化
- 步数增加
- GPS位移
- 持续时间：> 10秒
```

**实现要点**：
1. 区分"拿起看一眼" vs "开始移动"
2. 拿起手机不触发GPS频率调整
3. 只有真正运动才调整采集策略

---

## 2. 围栏特征学习

### 2.1 数据结构
```typescript
interface LearnedPlaceSignals {
  wifiSSIDs?: string[];            // 关联的WiFi SSID列表
  bluetoothDevices?: string[];     // 关联的蓝牙设备MAC/名称
  typicalTimes?: TimeRange[];      // 典型出现时间段
  lastSeen?: number;               // 最后一次学习时间戳
  visitCount?: number;             // 访问次数
}
```

### 2.2 学习触发
- 进入围栏时自动学习当前WiFi/蓝牙
- 首次学习到新特征时在聊天窗口提醒
- 数据持久化到 user_places.json

### 2.3 特征匹配
- WiFi连接时检查是否匹配已知围栏
- 即使GPS不精确，也能通过WiFi判断位置
- 支持多WiFi绑定同一围栏

---

## 3. App使用记录学习

### 3.1 权限
- `ohos.permission.LOOK_AT_SCREEN_DATA`

### 3.2 App分类
| 分类 | 示例App |
|------|---------|
| 社交 | 微信、QQ、WhatsApp、Telegram、Discord |
| 办公 | Email、WPS、Teams、Zoom、飞书、钉钉 |
| 娱乐 | 抖音、快手、B站、YouTube、Netflix |
| 导航 | 高德、百度地图、Google Maps |
| 购物 | 淘宝、京东、拼多多、Amazon |
| 资讯 | 今日头条、知乎、Twitter、Reddit |
| 健康 | 运动健康、Keep |
| 音乐 | 网易云、QQ音乐、Spotify |
| 阅读 | 微信读书、Kindle |
| 游戏 | 各种游戏 |

### 3.3 学习内容
- 当前前台App
- App使用时长
- 使用时段模式（用户习惯在什么时候用什么类型的App）
- 分类使用频率

### 3.4 推荐应用
- 根据用户习惯推荐相关App执行
- 例：用户习惯晚上刷抖音，推荐时可以提到

---

## 4. 静默模式增强

### 4.1 当前功能
- VAD语音检测
- 声纹识别说话人
- ASR转写
- AI摘要

### 4.2 待增强：关键信息提取
```typescript
interface ConversationKeyInfo {
  // 时间相关
  times: string[];           // "明天下午3点", "下周一"
  dates: string[];           // "3月15日", "这周末"
  
  // 地点相关
  locations: string[];       // "星巴克", "公司楼下"
  
  // 人物相关
  people: string[];          // "老王", "张总"
  
  // 事件相关
  events: string[];          // "开会", "吃饭", "看电影"
  
  // 计划相关
  plans: string[];           // "打算去买电脑", "准备出差"
  
  // 主题
  topics: string[];          // "讨论项目进度", "聊孩子教育"
}
```

### 4.3 待增强：情绪/心情检测
```typescript
interface EmotionAnalysis {
  mood: 'happy' | 'sad' | 'angry' | 'neutral' | 'excited' | 'tired';
  activity: 'talking' | 'singing' | 'arguing' | 'laughing' | 'whispering';
  energy: 'high' | 'medium' | 'low';
  stress: number;  // 0-100
}
```

**检测方法**：
- 语调分析（音高、语速、音量）
- 词汇情感分析
- 声音特征（笑声、叹气等）

### 4.4 唱歌检测
- 音高稳定性（唱歌 vs 说话）
- 节奏特征
- 旋律模式
- 背景音乐检测

---

## 5. 穿戴设备集成

### 5.1 问题
HarmonyOS `sensor.SensorId.HEART_RATE` 只能读取手机本身的传感器，**不能直接读取华为手表数据**。

### 5.2 解决方案
**方案A：使用健康数据API**
- 需要用户在华为健康App中开启数据共享
- 使用 `@ohos.healthDevice` 或 Health Kit

**方案B：华为健康数据同步**
- 华为健康App会将心率数据同步到系统
- 某些设备上 `sensor.SensorId.HEART_RATE` 可以获取同步后的数据
- 需要权限：`ohos.permission.READ_HEALTH_DATA`

### 5.3 待验证
- 检查 `sensor.on(SensorId.HEART_RATE)` 是否能获取手表同步数据
- 如果不能，需要研究 Health Kit API

---

## 6. 规则引擎与推荐

### 6.1 当前问题
- 规则定义了但匹配不到
- 可能是snapshot字段名与规则条件不匹配

### 6.2 规则条件字段
```json
{
  "timeOfDay": "morning|afternoon|evening|night",
  "isWeekend": "true|false",
  "motionState": "stationary|walking|running|driving",
  "geofence": "home|work|gym|...",
  "batteryLevel": "0-100",
  "isCharging": "true|false"
}
```

### 6.3 Snapshot生成
需要确保 `SensorDataTray.getSnapshot()` 返回的字段与规则条件匹配：
- `timeOfDay` - 需要根据当前时间计算
- `isWeekend` - 需要根据星期几计算
- `motionState` - 从数据托盘获取
- `geofence` - 从围栏管理器获取

---

## 7. 数据托盘规范

### 7.1 字段命名规范
- 统一使用小驼峰命名：`wifiSsid`, `gpsSpeed`, `heartRate`
- 避免重复字段
- TTL根据数据特性设置

### 7.2 当前字段
| Key | TTL | 来源 | 说明 |
|-----|-----|------|------|
| latitude | 2min | GPS | 纬度 |
| longitude | 2min | GPS | 经度 |
| wifiSsid | 2min | WiFi | 当前连接的WiFi |
| motionState | 30s | 加速度计 | 运动状态 |
| gpsSpeed | 2min | GPS | GPS速度 |
| heartRate | 30s | 穿戴设备 | 心率 |
| stepCount | 5min | 计步器 | 步数 |

---

## 8. 待办事项

### 高优先级
1. [ ] 修复规则匹配问题 - 检查snapshot字段与规则条件
2. [ ] 验证穿戴设备心率数据获取
3. [ ] 实现拿起手机检测（区分运动）
4. [ ] 静默模式关键信息提取

### 中优先级
5. [ ] App使用记录学习与推荐
6. [ ] 静默模式情绪/唱歌检测
7. [ ] 前置摄像头姿态检测优化

### 低优先级
8. [ ] 设计文档持续更新
9. [ ] 单元测试补充
