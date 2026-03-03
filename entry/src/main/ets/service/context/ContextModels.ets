/**
 * Context Awareness Data Models
 * 
 * 环境感知系统的核心数据结构
 */

// ==================== 基础接口 ====================

/** 时间范围接口 */
export interface TimeRange {
  start: string;
  end: string;
}

// ==================== 位置相关 ====================

/** 地理围栏定义 */
export interface Geofence {
  id: string;
  name: string;                    // "地铁站", "Costco", "公司"
  latitude: number;
  longitude: number;
  radiusMeters: number;            // 触发半径
  category: GeofenceCategory;
  metadata?: Record<string, string>; // 额外数据，如商店ID
  // 学习的特征信号
  learnedSignals?: LearnedPlaceSignals;
}

/** 学习的地点特征信号 */
export interface LearnedPlaceSignals {
  wifiSSIDs?: string[];            // 关联的WiFi SSID列表 (一对多)
  bluetoothDevices?: string[];     // 关联的蓝牙设备MAC/名称 (一对多)
  cellIds?: string[];              // 关联的CellID列表 (一对多)
  typicalTimes?: TimeRange[];      // 典型出现时间段
  lastSeen?: number;               // 最后一次学习时间戳
  visitCount?: number;             // 访问次数
  typicalActivities?: Record<string, number>;  // "hourBucket-activity" → count
}

export type GeofenceCategory = 
  | 'transit'      // 交通：地铁站、公交站
  | 'shopping'     // 购物：超市、商场
  | 'work'         // 工作：办公室
  | 'home'         // 家
  | 'restaurant'   // 餐饮
  | 'gym'          // 健身
  | 'custom';      // 用户自定义

/** 位置状态 */
export interface LocationState {
  latitude: number;
  longitude: number;
  accuracy: number;
  speed: number;           // m/s
  timestamp: number;
  insideGeofences: string[];  // 当前所在的围栏ID列表
}

// ==================== 运动状态 ====================

export type MotionState =
  | 'stationary'   // 静止
  | 'walking'      // 步行
  | 'running'      // 跑步
  | 'cycling'      // 骑车
  | 'driving'      // 开车
  | 'transit'      // 公共交通
  | 'pickup'       // 拿起手机（看一眼）
  | 'putdown'      // 放下手机
  | 'unknown';

// ==================== 环境特征 ====================

/** 完整的环境上下文 */
export interface EnvironmentContext {
  timestamp: number;
  
  // 位置
  location?: LocationState;
  currentGeofence?: Geofence;
  
  // 运动
  motionState: MotionState;
  stepCount?: number;
  
  // 时间
  timeOfDay: TimeOfDay;
  dayOfWeek: number;        // 0=Sunday, 6=Saturday
  isWeekend: boolean;
  
  // 设备状态
  batteryLevel: number;     // 0-100
  isCharging: boolean;
  networkType: NetworkType;
  screenOn: boolean;
  
  // 环境
  ambientLight?: number;    // lux
  noiseLevel?: number;      // dB
}

export type TimeOfDay = 'morning' | 'afternoon' | 'evening' | 'night';
export type NetworkType = 'wifi' | 'cellular' | 'none';

// ==================== 行为记录 ====================

/** 用户行为记录 */
export interface BehaviorRecord {
  id: string;
  timestamp: number;
  
  // 上下文快照
  context: EnvironmentContext;
  
  // 用户动作
  action: UserAction;
  
  // 结果（用于强化学习）
  outcome?: ActionOutcome;
}

/** 用户动作类型 */
export interface UserAction {
  type: ActionType;
  target?: string;           // 目标App、功能、URL等
  params?: Record<string, string>;
}

export type ActionType = 
  | 'open_app'              // 打开应用
  | 'show_qrcode'           // 显示二维码/乘车码
  | 'show_notification'     // 显示通知
  | 'show_info'             // 显示信息卡片
  | 'set_mode'              // 设置模式（静音、勿扰）
  | 'quick_action'          // 快捷操作
  | 'dismiss';              // 用户忽略

/** 动作结果（用于RL奖励计算） */
export interface ActionOutcome {
  accepted: boolean;        // 用户是否采纳
  interactionTime?: number; // 交互时长(ms)
  feedback?: number;        // 显式反馈 -1/0/+1
}

// ==================== 推荐规则 ====================

/** 学习到的规则 */
export interface ContextRule {
  id: string;
  
  // 触发条件
  trigger: RuleTrigger;
  
  // 推荐动作
  action: UserAction;
  
  // 学习参数
  confidence: number;       // 置信度 0-1
  triggerCount: number;     // 触发次数
  acceptCount: number;      // 采纳次数
  lastTriggered?: number;   // 上次触发时间
  
  // 元数据
  createdAt: number;
  updatedAt: number;
  enabled: boolean;
}

/** 规则触发条件 */
export interface RuleTrigger {
  // 位置条件（任一满足）
  geofenceIds?: string[];
  
  // 时间条件
  timeOfDay?: TimeOfDay[];
  daysOfWeek?: number[];
  
  // 运动条件
  motionStates?: MotionState[];
  
  // 设备条件
  networkTypes?: NetworkType[];
  minBattery?: number;
}

// ==================== 强化学习状态 ====================

/** RL状态向量 */
export interface RLState {
  // 位置特征 (one-hot per geofence category)
  locTransit: number;       // 0 or 1
  locShopping: number;
  locWork: number;
  locHome: number;
  locOther: number;
  
  // 时间特征
  timeMorning: number;
  timeAfternoon: number;
  timeEvening: number;
  timeNight: number;
  isWeekend: number;
  
  // 运动特征
  isStationary: number;
  isWalking: number;
  isInVehicle: number;
  
  // 设备特征
  batteryLow: number;       // < 20%
  onWifi: number;
  screenOn: number;
}

/** Q-table entry */
export interface QTableEntry {
  stateKey: string;         // RLState序列化的key
  actionId: string;         // 动作ID
  qValue: number;           // Q值
  visitCount: number;       // 访问次数
  lastUpdate: number;
}

// ==================== 触发器类型扩展 ====================

/** 触发器类型 */
export type TriggerType = 
  | 'geofence'     // 位置触发
  | 'time'         // 时间触发（定时/周期）
  | 'event'        // 事件触发（屏幕、电话等）
  | 'vision'       // 视觉触发（看到某场景）
  | 'sequence'     // 序列触发（前置条件完成后）
  | 'manual';      // 手动触发

/** 时间触发配置 */
export interface TimeTrigger {
  type: 'once' | 'daily' | 'weekly' | 'interval';
  time?: string;              // "07:30" 格式
  daysOfWeek?: number[];      // [1,2,3,4,5] = 周一到周五
  intervalMinutes?: number;   // 间隔分钟数
  startTime?: string;         // 开始时间
  endTime?: string;           // 结束时间
}

/** 事件触发类型 */
export type EventTriggerType = 
  | 'screen_on'       // 屏幕亮起
  | 'screen_unlock'   // 屏幕解锁
  | 'app_open'        // 打开某App
  | 'charging_start'  // 开始充电
  | 'charging_end'    // 停止充电
  | 'headphone_connect';  // 耳机连接

// ==================== 习惯链 ====================

/** 习惯链定义 */
export interface HabitChain {
  id: string;
  name: string;               // "早起健康习惯"
  description?: string;
  
  // 触发条件
  triggerType: TriggerType;
  timeTrigger?: TimeTrigger;
  
  // 习惯步骤（按顺序执行）
  steps: HabitStep[];
  
  // 状态
  enabled: boolean;
  currentStepIndex: number;   // 今天完成到哪一步
  lastResetDate: string;      // 上次重置日期 "YYYY-MM-DD"
  
  // 统计
  completionCount: number;    // 完全完成次数
  partialCount: number;       // 部分完成次数
  streakDays: number;         // 连续完成天数
}

/** 习惯步骤 */
export interface HabitStep {
  id: string;
  name: string;               // "喝水"
  description?: string;       // "喝一杯温水"
  
  // 完成条件
  completionType: 'manual' | 'auto' | 'vision';
  
  // 如果是 vision 类型
  visionKeywords?: string[];  // ["喝水", "杯子", "水杯"]
  
  // 如果是 auto 类型（如打开某App）
  autoTrigger?: EventTriggerType;
  
  // 时间限制
  timeoutMinutes?: number;    // 超时分钟数（可选）
  
  // 提醒配置
  reminder: StepReminder;
  
  // 状态
  completedToday: boolean;
  completedAt?: number;
}

/** 步骤提醒配置 */
export interface StepReminder {
  message: string;            // "该喝水了！"
  type: 'notification' | 'popup' | 'voice';
  repeatIntervalMinutes?: number;  // 未完成时重复提醒间隔
  maxRepeats?: number;        // 最多重复几次
}

// ==================== 视觉分析 ====================

/** 视觉分析配置 */
export interface VisionAnalysisConfig {
  enabled: boolean;
  
  // 拍照频率
  captureIntervalMinutes: number;  // 多少分钟拍一次
  
  // 拍照时间范围
  activeHours: TimeRange;
  
  // 隐私保护
  onlyWhenScreenOn: boolean;  // 只在屏幕亮着时拍
  deleteAfterAnalysis: boolean;  // 分析后删除照片
  localOnly: boolean;         // 只在本地分析（不上传）
}

/** 视觉分析结果 */
export interface VisionAnalysisResult {
  timestamp: number;
  imagePath?: string;
  
  // AI 分析结果
  description: string;        // "用户正在吃薯片"
  detectedActivities: string[];  // ["eating", "snacking"]
  detectedObjects: string[];     // ["chips", "couch", "TV"]
  
  // 健康评估
  healthScore?: number;       // 0-100
  concerns?: string[];        // ["高热量零食", "久坐"]
  suggestions?: string[];     // ["建议换成坚果", "起来活动一下"]
}

/** 健康规则 */
export interface HealthRule {
  id: string;
  name: string;               // "避免高热量零食"
  
  // 检测条件（视觉关键词）
  triggerKeywords: string[];  // ["薯片", "可乐", "糖果"]
  
  // 排除条件
  exceptKeywords?: string[];  // ["坚果", "水果"]
  
  // 时间限制
  activeTimeRanges?: TimeRange[];
  
  // 提醒
  warningMessage: string;     // "检测到你在吃零食，建议换成健康食品"
  suggestionMessage?: string; // "可以试试坚果或水果"
  
  // 严重程度
  severity: 'info' | 'warning' | 'alert';
  
  enabled: boolean;
}

// ==================== 反馈记录 ====================

/** 反馈类型 */
export type FeedbackType =
  | 'thumbs_up'         // 用户点赞
  | 'thumbs_down'       // 用户踩
  | 'action_taken'      // 用户执行了推荐动作
  | 'dismissed'          // 用户滑走/关闭
  | 'ignored';           // 超时无交互

/** 反馈记录 */
export interface FeedbackRecord {
  id: string;
  ruleId: string;
  timestamp: number;
  feedbackType: FeedbackType;
  reward: number;         // 实际发送给引擎的奖励值
}

/** 反馈统计 */
export interface FeedbackStats {
  totalCount: number;
  positiveCount: number;  // thumbs_up + action_taken
  negativeCount: number;  // thumbs_down
  dismissCount: number;
  ignoreCount: number;
  positiveRatio: number;  // positiveCount / (positiveCount + negativeCount), 0 if no explicit feedback
  topRules: FeedbackRuleStat[];
}

/** 单条规则的反馈统计 */
export interface FeedbackRuleStat {
  ruleId: string;
  ruleName: string;
  totalReward: number;
  feedbackCount: number;
  avgReward: number;
}

// ==================== LLM 兜底推荐 ====================

/** LLM fallback recommendation (when C++ engine returns no matches) */
export interface LLMRecommendation {
  action: string;
  title: string;
  content: string;
  priority: string;   // 'low' | 'medium' | 'high'
  source: string;     // 'llm'
}

// ==================== 地点自动发现 ====================

/** 地点访问记录 */
export interface PlaceVisit {
  id: string;
  geofenceId: string;         // 关联的围栏ID
  placeName: string;          // 地点名称
  latitude: number;
  longitude: number;
  enterTime: number;          // 进入时间戳
  exitTime?: number;          // 离开时间戳（undefined表示还在）
  stayDurationMs: number;     // 停留时长（毫秒）
  wifiSsid?: string;          // 当时的 WiFi SSID
  source: 'manual' | 'auto';  // 手动添加还是自动发现
  confirmed: boolean;         // 用户是否确认
}

/** 待确认的新地点 */
export interface PendingPlace {
  id: string;
  latitude: number;
  longitude: number;
  accuracy: number;
  firstSeenTime: number;      // 首次检测到的时间
  wifiSsid?: string;          // 检测到的 WiFi
  suggestedName?: string;     // API 反查的建议名称
  suggestedCategory?: string; // 建议类别
  address?: string;           // 反查的地址
  stayDurationMs: number;     // 已停留时长
  notified: boolean;          // 是否已发送通知
}

/** 自动发现的地点（用户已确认） */
export interface DiscoveredPlace extends Geofence {
  discoverySource: 'gps_wifi' | 'gps_only' | 'wifi_only';
  discoveredAt: number;       // 发现时间
  confirmAt: number;          // 确认时间
  visits: PlaceVisit[];       // 访问记录
  totalVisits: number;        // 总访问次数
  totalStayMs: number;        // 累计停留时间
}

/** 地点发现配置 */
export interface PlaceDiscoveryConfig {
  enabled: boolean;
  minStayMinutes: number;           // 最小停留时间（分钟）触发发现
  minGpsAccuracy: number;           // GPS 精度阈值（米）
  gpsDriftThreshold: number;        // GPS 漂移阈值（米），小于此值视为停留
  notificationEnabled: boolean;     // 是否发送通知
  autoConfirmAfterVisits: number;   // N次访问后自动确认
}

export const DEFAULT_DISCOVERY_CONFIG: PlaceDiscoveryConfig = {
  enabled: true,
  minStayMinutes: 5,
  minGpsAccuracy: 100,
  gpsDriftThreshold: 50,
  notificationEnabled: true,
  autoConfirmAfterVisits: 3,
};

// ==================== 每日摘要 ====================

/** 每日健康摘要 */
export interface DailySummary {
  date: string;               // "YYYY-MM-DD"
  
  // 习惯完成情况
  habitsCompleted: number;
  habitsTotal: number;
  
  // 健康评分
  overallScore: number;       // 0-100
  
  // 视觉分析统计
  visionCaptures: number;
  healthyBehaviors: number;
  unhealthyBehaviors: number;
  
  // 位置统计
  placesVisited: string[];
  stepsWalked?: number;
  
  // 亮点和问题
  highlights: string[];       // ["完成了所有早起习惯", "步行3000步"]
  concerns: string[];         // ["下午吃了3次零食"]
  
  // 建议
  suggestions: string[];
}

// ==================== 睡眠时间学习 ====================

/** 睡眠时间学习 */
export interface SleepPattern {
  typicalBedtime: number;         // 典型入睡时间 (小时, 0-23.99)
  typicalWakeTime: number;        // 典型起床时间 (小时, 0-23.99)
  sleepDurationHours: number;     // 平均睡眠时长
  weekdays: SleepDayPattern;      // 工作日
  weekends: SleepDayPattern;      // 周末
  lastUpdated: number;            // 最后更新时间
  confidence: number;             // 置信度 0-1
}

/** 单日睡眠模式 */
export interface SleepDayPattern {
  bedtime: number;                // 入睡时间
  wakeTime: number;               // 起床时间
  sampleCount: number;            // 样本数量
}

/** 单次睡眠记录 */
export interface SleepRecord {
  date: string;                   // "YYYY-MM-DD"
  bedtime?: number;               // 入睡时间戳
  wakeTime?: number;              // 起床时间戳
  durationMs?: number;            // 睡眠时长
  source: 'wearable' | 'inferred' | 'manual';  // 来源
}

// ==================== 分层传感器 & 设备分类 ====================

/** 传感器层级: T0常驻, T1低功耗, T2中功耗, T3高功耗 */
export type SensorTier = 0 | 1 | 2 | 3;

/** 蓝牙设备移动性分类 */
export type DeviceMobility = 'fixed' | 'portable' | 'vehicle' | 'unknown';

/** WiFi 移动性分类 */
export type WifiMobility = 'hotspot' | 'public' | 'fixed';

/** 蓝牙 Major/Minor Class 常量 (用于设备分类) */
export const BT_MINOR_CLASS: Record<string, number> = {
  'LOUDSPEAKER': 0x0414,
  'HIFI_AUDIO': 0x0428,
  'SET_TOP_BOX': 0x0424,
  'VIDEO_DISPLAY_LOUDSPEAKER': 0x043C,
  'WEARABLE_HEADSET': 0x0404,
  'HEADPHONES': 0x0418,
  'PORTABLE_AUDIO': 0x041C,
  'MAJOR_WEARABLE': 0x0700,
  'CAR_AUDIO': 0x0420,
  'HANDSFREE': 0x0408,
};

/** 设备连接时长记录 */
export interface DeviceConnectionRecord {
  deviceName: string;
  deviceType: 'wifi' | 'bluetooth';
  mobility: DeviceMobility;
  geofenceId: string;
  firstSeen: number;
  lastSeen: number;
  totalDurationMs: number;
  sessionCount: number;
  currentSessionStart: number;
}

// ==================== 每日行程时间线 ====================

/** 时间线条目 — 记录一段状态停留 */
export interface TimelineEntry {
  id: string;                    // 唯一ID (timestamp-based)
  startTime: number;             // 进入此状态的时间戳
  endTime: number;               // 离开此状态的时间戳 (0 = 当前/进行中)
  geofenceId: string;            // 围栏ID (空 = 未知位置/途中)
  geofenceLabel: string;         // 显示名称 (家、办公室、...)
  geofenceIcon: string;          // emoji 图标 (🏠、🏢、...)
  motionState: string;           // 运动状态 (stationary/walking/running/driving)
  latitude: number;              // GPS 纬度 (0 = 未知)
  longitude: number;             // GPS 经度 (0 = 未知)
  geocodeLabel: string;          // 逆地理编码地名 (道路名/区域名)
}

// ==================== 传感器录制/回放 ====================

/** 录制信息 */
export interface RecordingInfo {
  id: string;                    // "rec_{timestamp}"
  label: string;                 // 用户标签 (如 "早通勤")
  startTime: number;             // 录制开始时间戳
  endTime: number;               // 录制结束时间戳 (0 = 进行中)
  eventCount: number;            // 事件总数
  durationMs: number;            // 录制时长 (ms)
  filePath: string;              // NDJSON 文件路径
  fileSize: number;              // 文件大小 (bytes)
}

/** NDJSON header 行 */
export interface RecordingHeader {
  type: 'header';
  ver: number;                   // 格式版本
  id: string;                    // 录制 ID
  t0: number;                    // 起始时间戳
  label: string;                 // 用户标签
}

/** NDJSON event 行 — 单次 tray.put 的镜像 */
export interface RecordingEvent {
  type: 'event';
  t: number;                     // 时间戳
  k: string;                     // key
  v: string;                     // value
  q: number;                     // quality 0~1
  s: string;                     // source
}

/** NDJSON snap 行 — 完整 ContextSnapshot keyframe */
export interface RecordingSnap {
  type: 'snap';
  t: number;                     // 时间戳
  d: Record<string, string>;     // 完整快照数据
}

/** NDJSON footer 行 */
export interface RecordingFooter {
  type: 'footer';
  t1: number;                    // 结束时间戳
  n: number;                     // 总事件数
  dur: number;                   // 总时长 (ms)
}

/** 回放进度 */
export interface ReplayProgress {
  state: 'idle' | 'playing' | 'paused' | 'finished';
  progress: number;              // 0~1
  eventsPlayed: number;
  totalEvents: number;
  speed: number;                 // 1x, 2x, 5x, 10x
  currentTime: number;           // 当前回放时间戳
}

// ==================== 7-Tuple 物理状态模型 ====================

/** 时间段 (9 values) */
export type TimeSlot =
  | 'sleeping'    // 0:00-5:00 深夜
  | 'dawn'        // 5:00-7:00 清晨
  | 'morning'     // 7:00-9:00 早上（通勤高峰）
  | 'forenoon'    // 9:00-11:30 上午
  | 'lunch'       // 11:30-13:30 午餐
  | 'afternoon'   // 13:30-17:00 下午
  | 'evening'     // 17:00-19:30 傍晚
  | 'night'       // 19:30-22:00 夜晚
  | 'late_night'; // 22:00-0:00 深夜前

/** 位置类别 (10 values) */
export type LocationCategory =
  | 'home'        // WiFi geofence = home
  | 'work'        // WiFi geofence = work
  | 'commute'     // 无围栏 + 移动中 (driving/transit/walking)
  | 'restaurant'  // WiFi geofence = restaurant
  | 'gym'         // WiFi geofence = gym
  | 'transit_hub' // WiFi geofence = transit (机场/火车站)
  | 'shopping'    // WiFi geofence = shopping
  | 'outdoor'     // 无 WiFi + GPS 可用 + 非驾车
  | 'cafe'        // WiFi geofence = cafe
  | 'unknown';    // 无信号匹配

/** 运动类别 (7 values) */
export type MotionCategory =
  | 'stationary'  // 静止 (加速度 + GPS速度 < 0.5 m/s)
  | 'walking'     // 步行 (加速度 + 步数增加)
  | 'running'     // 跑步 (加速度幅值 > 12)
  | 'cycling'     // 骑车 (GPS 3-8 m/s + 低步频)
  | 'driving'     // 驾车 (GPS > 5 m/s 或驾车惯性)
  | 'transit'     // 公共交通 (BT/GPS模式)
  | 'unknown';    // 数据不足

/** 手机状态类别 (8 values) */
export type PhoneCategory =
  | 'in_use'           // 亮屏 + 手握 + 正常坐/站
  | 'holding_lying'    // 手握 + 躺卧（加速度计检测）
  | 'on_desk'          // 平放 + 屏幕朝上 + 有环境光
  | 'face_up'          // 屏幕朝上 + 暗室（放床头/桌上，非手握）
  | 'in_pocket'        // 距离=近 + 环境光 < 5 lux
  | 'face_down'        // 距离=近 + 环境光 > 5 lux
  | 'charging'         // 充电中 (覆盖其他姿态)
  | 'unknown';         // 无传感器数据

/** 光线类别 (4 values) */
export type LightCategory =
  | 'dark'        // < 5 lux (夜晚, 口袋, 密闭房间)
  | 'dim'         // 5-50 lux (卧室, 暗办公室)
  | 'normal'      // 50-500 lux (室内, 阴天室外)
  | 'bright';     // > 500 lux (晴天室外, 明亮办公室)

/** 声音类别 (5 values) */
export type SoundCategory =
  | 'silent'      // < 25 dB (空房间, 深夜)
  | 'quiet'       // 25-40 dB (家中, 图书馆)
  | 'normal'      // 40-55 dB (办公室, 咖啡馆)
  | 'noisy'       // > 55 dB (街道, 餐厅)
  | 'unknown';    // 麦克风禁用 (默认)

/** 日期类型 (3 values) */
export type DayType =
  | 'workday'     // 工作日 (周一-周五 且非法定假日)
  | 'weekend'     // 周末 (周六/周日)
  | 'holiday';    // 假日 (法定假日或用户标记)

/** 7-Tuple 物理状态 */
export interface PhysicalState {
  time: TimeSlot;
  location: LocationCategory;
  motion: MotionCategory;
  phone: PhoneCategory;
  light: LightCategory;
  sound: SoundCategory;
  dayType: DayType;
  timestamp: number;             // 构建时间戳
}

/** 场景步骤条件 — 用 * 表示任意值, A|B 表示多选 */
export interface ScenarioStepCondition {
  time?: string;        // TimeSlot 或 '*' 或 'A|B'
  location?: string;    // LocationCategory 或 '*' 或 'A|B'
  motion?: string;      // MotionCategory 或 '*' 或 'A|B'
  phone?: string;       // PhoneCategory 或 '*' 或 'A|B'
  light?: string;       // LightCategory 或 '*' 或 'A|B'
  sound?: string;       // SoundCategory 或 '*' 或 'A|B'
  dayType?: string;     // DayType 或 '*' 或 'A|B'
}

/** 场景推荐动作 */
export interface ScenarioAction {
  id: string;           // 动作 ID
  type: string;         // suggestion, automation, notification
  payload: string;      // 动作描述 JSON
}

/** 场景步骤 */
export interface ScenarioStep {
  condition: ScenarioStepCondition;
  digitalConditions?: Record<string, string>;  // 数字条件 (key op value)
  actions?: ScenarioAction[];                  // 该步骤推荐的动作
}

/** 场景定义 */
export interface Scenario {
  id: string;                    // "S01", "S02", ...
  name: string;                  // "工作日早起"
  nameEn: string;                // "Weekday morning wakeup"
  category: ScenarioCategory;    // 场景类别
  steps: ScenarioStep[];         // 状态链步骤
  timeoutMs: number;             // 链超时 (ms)，默认 2 小时
  priority: number;              // 优先级 1-10
  enabled: boolean;
}

/** 场景类别 (12 categories) */
export type ScenarioCategory =
  | 'morning'     // 早晨起床
  | 'commute'     // 通勤
  | 'work'        // 工作
  | 'home'        // 在家生活
  | 'sleep'       // 睡眠
  | 'exercise'    // 运动健身
  | 'dining'      // 用餐
  | 'shopping'    // 购物
  | 'travel'      // 出行旅行
  | 'social'      // 社交
  | 'health'      // 健康提醒
  | 'device';     // 设备/系统

/** 活跃场景状态 — 跟踪一个正在进行的场景链 */
export interface ScenarioState {
  scenario: Scenario;            // 场景定义
  currentStep: number;           // 当前步骤索引
  startTime: number;             // 链开始时间
  stepEntryTime: number;         // 进入当前步骤的时间
  confidence: number;            // 匹配置信度 0-1
}

/** 场景匹配结果 */
export interface ScenarioMatchResult {
  scenarioId: string;
  scenarioName: string;
  category: ScenarioCategory;
  currentStep: number;
  totalSteps: number;
  confidence: number;
  actions: ScenarioAction[];     // 当前步骤的推荐动作
}
