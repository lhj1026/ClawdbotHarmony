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
