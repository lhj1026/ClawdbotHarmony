/**
 * Context Awareness Data Models
 * 
 * 环境感知系统的核心数据结构
 */

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
  activeHours: {
    start: string;  // "07:00"
    end: string;    // "22:00"
  };
  
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
  activeTimeRanges?: {
    start: string;
    end: string;
  }[];
  
  // 提醒
  warningMessage: string;     // "检测到你在吃零食，建议换成健康食品"
  suggestionMessage?: string; // "可以试试坚果或水果"
  
  // 严重程度
  severity: 'info' | 'warning' | 'alert';
  
  enabled: boolean;
}

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
