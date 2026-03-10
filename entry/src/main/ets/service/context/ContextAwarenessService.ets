/**
 * Context Awareness Service
 * 
 * 核心服务：整合传感器、地理围栏、行为记录和推荐
 */
import { sensor } from '@kit.SensorServiceKit';
import { batteryInfo } from '@kit.BasicServicesKit';
import { wifiManager } from '@kit.ConnectivityKit';
import { geoLocationManager } from '@kit.LocationKit';
import { common, abilityAccessCtrl } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { LogService } from '../../common/LogService';
import { Constants } from '../../common/Constants';
import { I18n } from '../../common/I18n';
import { GeofenceManager, GeofenceEvent } from './GeofenceManager';
import { BehaviorLogger } from './BehaviorLogger';
import { ContextEngineService, ContextSnapshot, ContextRule as EngineRule, ContextCondition as EngineCondition, ContextAction as EngineAction, MatchResult, GeofenceBinding } from './ContextEngine';
import { GeofenceSuggestion, DiscoveryStatsInfo } from './LocationDiscoveryService';
import { FeedbackService } from './FeedbackService';
import { LocationFusionService, LearnedSignalsSummary } from './LocationFusionService';
import { DigitalWorldService } from './DigitalWorldService';
import { CalendarPlugin } from './plugins/CalendarPlugin';
import DataTray, { DataTray as SensorDataTray, TrayStatus } from './DataTray';
import {
  EnvironmentContext,
  MotionState,
  TimeOfDay,
  NetworkType,
  ActionType,
  UserAction,
  ActionOutcome,
  ContextRule,
  RuleTrigger,
  Geofence,
  LocationState,
  FeedbackStats,
  LLMRecommendation,
  GeofenceCategory,
  SensorTier,
  WifiMobility,
  DeviceMobility,
  DeviceConnectionRecord,
  DiscoveredPlace,
} from './ContextModels';
import { LLMFallbackService } from './LLMFallbackService';
import { TrainingDataSync } from './TrainingDataSync';
import { FederatedSync } from './FederatedSync';
import { GeoCodingService } from './GeoCodingService';
import { TravelInfoService } from './TravelInfoService';
import { DailyTimelineService } from './DailyTimelineService';
import { SensorRecorder } from './SensorRecorder';
import { SensorPlayer, ReplayState } from './SensorPlayer';
import { RecordingInfo, ReplayProgress, PhysicalState, ScenarioMatchResult } from './ContextModels';
import { PhysicalStateBuilder } from './PhysicalStateBuilder';
import { ScenarioMatcher } from './ScenarioMatcher';

const TAG = 'ContextService';

/** 位置候选 */
export interface LocationCandidate {
  name: string;         // "首都机场 T3" or "家"
  category: string;     // "transit" | "home" | "work" | ...
  confidence: number;   // 0~1
  source: string;       // "geofence" | "geocode" | "wifi"
  emoji: string;        // "✈️" | "🏠"
}

/** 活动候选 */
export interface ActivityCandidate {
  name: string;         // "赶飞机"
  emoji: string;        // "✈️"
  confidence: number;
}

/** NodeRuntime 接口（用于类型安全访问 globalThis） */
interface NodeRuntimeInterface {
  dispatchA2UI?: (action: string, jsonl: string) => void;
}

interface GlobalWithRuntime {
  nodeRuntime?: NodeRuntimeInterface;
}

/** Z轴采样点 */
interface ZAxisSamplePoint {
  value: number;
  timestamp: number;
}

/** 围栏置信度排序辅助 */
interface GeofenceConfEntry {
  gf: Geofence;
  conf: number;
}

export interface ContextRecommendation {
  rule: ContextRule;
  action: UserAction;
  reason: string;
  exploreStateInfo?: string;  // 探索模式：当前检测到的状态摘要
  snapshot?: ContextSnapshot;  // 推荐时的上下文快照，用于 Stream RL 训练
  alternatives?: MatchResult[];  // Top N 匹配结果（含主推荐），用于多选卡片
}

type RecommendationListener = (rec: ContextRecommendation) => void;
type SuggestionListener = (suggestions: GeofenceSuggestion[]) => void;

/** Persisted state for geofence suggestion filtering */
interface GeofenceSuggestionState {
  /** Cluster IDs the user permanently ignored */
  blacklist: string[];
  /** Cluster ID → timestamp when deferred ("以后再说"), resurface after 7 days */
  deferred: Record<string, number>;
  /** Cluster ID → timestamp of last suggestion shown, max once per day */
  lastShown: Record<string, number>;
}

const SUGGEST_PREFS_KEY = 'geofence_suggestion_state';
const DEFER_DURATION_MS = 7 * 24 * 3600 * 1000;     // 7 days
const DAILY_COOLDOWN_MS = 24 * 3600 * 1000;          // 24 hours

/** 加速度传感器数据接口 */
interface AccelerometerData {
  x: number;
  y: number;
  z: number;
  timestamp: number;
}

/** 加速度历史采样点 */
interface AccelSample {
  magnitude: number;
  gravityAngle: number;  // 重力方向与Z轴夹角
  timestamp: number;
}

/** 指纹持久化条目 */
interface FingerprintEntry {
  fp: string;
  ts: number;
}

export class ContextAwarenessService {
  private static instance: ContextAwarenessService;
  private log: LogService = LogService.getInstance();
  
  private geofenceMgr: GeofenceManager;
  private behaviorLog: BehaviorLogger;
  private feedbackSvc: FeedbackService;
  
  private initialized: boolean = false;
  private initializing: boolean = false;
  private initPromise: Promise<void> | undefined;
  private isRunning: boolean = false;
  private starting: boolean = false;
  private context: common.UIAbilityContext | undefined;
  
  // 当前状态
  private currentContext: EnvironmentContext | undefined;
  private lastLocation: LocationState | undefined;
  private lastMotionState: MotionState = 'unknown';
  private lastGeofence: string = '';  // 前一个围栏（用于驾驶vs乘车推断）
  
  // 状态历史 (用于规则判断)
  private prevMotionState: MotionState = 'unknown';
  private prevActivityState: string = 'unknown';  // 'sitting', 'sleeping', 'walking', 'active'
  private activityState: string = 'unknown';      // 当前活动状态
  private activityStateTimestamp: number = 0;     // 状态开始时间
  private activityStateDuration: number = 0;      // 持续时间(ms)

  // 用户姿势检测 (基于手机倾斜角)
  private isLyingDown: boolean = false;           // 用户是否躺着
  private lastTiltAngle: number = 0;              // 最近的手机倾斜角度
  
  // 传感器数据
  private accelerometerData: AccelerometerData = { x: 0, y: 0, z: 0, timestamp: 0 } as AccelerometerData;
  private stepCount: number = 0;
  private stepCountBaseline: number = -1;   // 今日步数基线（CAS自有计步备用）
  private stepCountBaselineDate: string = '';
  
  // 拿起手机检测
  private accelHistory: AccelSample[] = [];
  private static readonly ACCEL_HISTORY_SIZE = 30;
  private isHoldingPhone: boolean = false;  // 手握手机状态
  private pickupStartTime: number = 0;
  private isPickupState: boolean = false;
  private lastStableGravityAngle: number = 90;  // 90° = held in hand; avoid false pickup at startup (0° = flat would trigger immediately)
  private pickupConfirmed: boolean = false;
  private stateBeforePickup: MotionState = 'stationary';
  private postPickupCooldownUntil: number = 0;
  private static readonly POST_PICKUP_COOLDOWN_MS = 8000;  // 拿起后8秒冷却，防止手持抖动误判walking
  private static readonly MOTION_MIN_DURATION_MS = 10000;
  private motionStartTime: number = 0;
  private motionStepCountStart: number = 0;

  // 运动状态平滑（滑动窗口多数投票 + dwell）
  private pendingMotionState: MotionState = 'unknown';
  private motionDwellStart: number = 0;
  private static readonly STATIONARY_DWELL_MS = 3000;   // 转静止需3秒
  private static readonly ACTIVE_DWELL_MS = 800;         // 转运动需0.8秒
  private static readonly DRIVING_EXIT_DWELL_MS = 30 * 1000;  // driving退出需30秒dwell
  private static readonly DRIVING_INERTIA_MS = 90 * 1000;     // 驾车惯性90秒
  private static readonly GEOFENCE_DEPARTURE_COOLDOWN_MS = 3 * 60 * 1000;  // 围栏离开冷却3分钟

  // Z轴振幅和频率特征（用于走路vs驾车区分）
  private zAxisHistory: Array<ZAxisSamplePoint> = [];
  private static readonly Z_AXIS_HISTORY_SIZE = 1000;  // 5秒@200Hz
  private zAxisFrequency: number = 0;  // Hz
  private zAxisAmplitude: number = 0;  // g
  private zAxisVariance: number = 0;   // 规律性指标

  // 驾车惯性
  private lastHighSpeedTime: number = 0;
  private drivingInertiaStepBase: number = 0;  // 高速行驶时的步数基线，用于惯性期步数比对
  // 围栏离开冷却
  private geofenceDepartureTime: number = 0;
  
  // WiFi 状态跟踪
  private lastWifiSsid: string = '';
  private wifiLostWorkTimestamp: number = 0;  // backward compat
  private wifiLostTimestamps: Map<string, number> = new Map();  // category → timestamp
  private static readonly WIFI_LOST_TTL_MS = 10 * 60 * 1000;  // WiFi丢失标记保持10分钟
  
  // 推荐监听器
  private recommendationListeners: RecommendationListener[] = [];
  
  // C++ 规则引擎
  private engine: ContextEngineService = ContextEngineService.getInstance();
  private evaluationTimer: number = -1;
  private static readonly EVALUATION_INTERVAL_MS = 2 * 60 * 1000;  // 2分钟评估一次
  
  // 防抖：避免重复推荐
  private lastRecommendations: Map<string, number> = new Map();
  private lastDigitalData: Record<string, string> = {};

  // LLM fallback dedup: don't repeat same recommendation without feedback
  private lastLlmPayload: string = '';
  private lastLlmRuleId: string = '';
  private lastLlmFeedbackReceived: boolean = false;
  private static readonly RECOMMENDATION_COOLDOWN_MS = 5 * 60 * 1000;  // 5分钟冷却

  // 积极探索模式：每个新状态指纹都触发 LLM 建议
  private exploreMode: boolean = false;
  private exploredFingerprints: Map<string, number> = new Map(); // fp → timestamp
  private static readonly FINGERPRINT_EXPIRY_MS = 24 * 60 * 60 * 1000; // 24小时后过期，允许重新探索
  private lastExploreBtDevices: string = ''; // 上次探索时的 BT 设备
  private static readonly EXPLORE_STATE_DISPLAY_COOLDOWN_MS = 5 * 60 * 1000; // 探索模式状态显示冷却 5分钟
  private lastExploreStateDisplayTime: number = 0;
  private lastExploreWifiSsid: string = '';  // 上次探索时的 WiFi
  
  // 位置自动发现 (已迁移到 GeofenceManager)
  private discoveryTimer: number = -1;

  // LLM 兜底服务
  private llmFallback: LLMFallbackService = LLMFallbackService.getInstance();
  // 多源位置融合
  private locationFusion: LocationFusionService = LocationFusionService.getInstance();
  // 围栏建议管理
  private suggestionListeners: SuggestionListener[] = [];
  private suggestionState: GeofenceSuggestionState = { blacklist: [], deferred: {}, lastShown: {} };
  private suggestionStateLoaded: boolean = false;
  // A2UI 监听器 (本地UI分发)
  private a2uiListeners: ((type: string, content: string) => void)[] = [];
  // 状态变化监听器 (每次 PhysicalState 变化时触发)
  private stateChangeListeners: ((ps: PhysicalState, prevPS: PhysicalState | undefined) => void)[] = [];
  private lastPhysicalFingerprint: string = '';
  // 新地点自动发现
  private newPlaceDetectionStart: number = 0;
  private newPlaceLastLat: number = 0;
  private newPlaceLastLng: number = 0;
  private newPlaceWifiSsid: string = '';
  private static readonly NEW_PLACE_STABLE_MS = 5 * 60 * 1000;
  private static readonly NEW_PLACE_MAX_DRIFT_M = 100;
  // CellID 跟踪 (用于低功耗位置变化检测)
  private lastCellId: string = '';
  private lastCellIdTime: number = 0;
  // WiFi SSID stationarity tracking (用于检测WiFi切换 → 触发GPS)
  private lastStationaryWifiSsid: string = '';
  
  // ==================== 多级采集策略 (功耗优化) ====================
  // GPS间隔
  private locationTimer: number = -1;
  private locationIntervalMs: number = 60 * 1000;
  private static readonly GPS_STATIONARY = 5 * 60 * 1000;      // 静止: 5分钟
  private static readonly GPS_WALKING = 30 * 1000;             // 步行: 30秒
  private static readonly GPS_RUNNING = 15 * 1000;             // 跑步: 15秒
  private static readonly GPS_DRIVING = 5 * 1000;              // 驾驶: 5秒
  private static readonly GPS_UNKNOWN = 60 * 1000;             // 未知: 1分钟
  
  // WiFi扫描间隔
  private wifiTimer: number = -1;
  private wifiIntervalMs: number = 2 * 60 * 1000;
  private static readonly WIFI_STATIONARY = 5 * 60 * 1000;     // 静止: 5分钟
  private static readonly WIFI_WALKING = 2 * 60 * 1000;        // 步行: 2分钟
  private static readonly WIFI_RUNNING = 5 * 60 * 1000;        // 跑步: 5分钟 (不太可能连WiFi)
  private static readonly WIFI_DRIVING = 0;                     // 驾驶: 关闭
  private static readonly WIFI_UNKNOWN = 2 * 60 * 1000;
  
  // 加速度计间隔 (纳秒)
  private accelIntervalNs: number = 1000000000;  // 1秒
  private static readonly ACCEL_STATIONARY = 5000000000;       // 静止: 5秒
  private static readonly ACCEL_WALKING = 1000000000;          // 步行: 1秒
  private static readonly ACCEL_RUNNING = 500000000;           // 跑步: 500ms
  private static readonly ACCEL_DRIVING = 2000000000;          // 驾驶: 2秒
  private static readonly ACCEL_UNKNOWN = 1000000000;
  
  // 数字世界感知
  private digitalWorld: DigitalWorldService = DigitalWorldService.getInstance();
  // 传感器数据托盘
  private tray: SensorDataTray = DataTray;
  // 传感器录制/回放
  private recorder: SensorRecorder = SensorRecorder.getInstance();
  private player: SensorPlayer = SensorPlayer.getInstance();
  private isReplaying: boolean = false;
  private preReplayMotionState: MotionState = 'unknown';
  private preReplayLocation: LocationState | undefined;
  private preReplayTraySnapshot: Map<string, string> = new Map();
  // 训练数据同步
  private trainingSync: TrainingDataSync = TrainingDataSync.getInstance();
  // 旅行信息服务 (航班/火车票)
  private travelInfoSvc: TravelInfoService = TravelInfoService.getInstance();

  // ==================== 7-Tuple 物理状态 & 场景匹配 ====================
  private psBuilder: PhysicalStateBuilder = PhysicalStateBuilder.getInstance();
  private scenarioMatcher: ScenarioMatcher = ScenarioMatcher.getInstance();
  private prevPhysicalState: PhysicalState | undefined;
  private lastPhysicalState: PhysicalState | undefined;
  private prevScenarioResults: ScenarioMatchResult[] = [];
  private lastScenarioResults: ScenarioMatchResult[] = [];

  // ==================== 分层传感器 (Sensor Tier System) ====================
  private currentTier: SensorTier = 1;
  private tierEscalationTime: number = 0;
  private tierDeEscalationTimer: number = -1;
  private stationarySinceMs: number = 0;
  private unknownLocationSinceMs: number = 0;

  // ==================== 设备分类 & 连接时长 ====================
  private connectionRecords: Map<string, DeviceConnectionRecord> = new Map();
  private lastKnownBtFixed: string = '';
  private lastKnownBtVehicle: string = '';

  // WiFi hotspot/public SSID patterns
  private static readonly WIFI_HOTSPOT_PATTERNS: string[] = [
    'iPhone', 'Android', 'Pixel', 'Galaxy', '的iPhone', 'HUAWEI-', '手机',
    'Hotspot', '热点', 'DIRECT-'
  ];
  private static readonly WIFI_PUBLIC_PREFIXES: string[] = [
    'CMCC', 'ChinaNet', 'ChinaUnicom', 'eduroam'
  ];

  private constructor() {
    this.geofenceMgr = GeofenceManager.getInstance();
    this.behaviorLog = BehaviorLogger.getInstance();
    this.feedbackSvc = FeedbackService.getInstance();
  }
  
  static getInstance(): ContextAwarenessService {
    if (!ContextAwarenessService.instance) {
      ContextAwarenessService.instance = new ContextAwarenessService();
    }
    return ContextAwarenessService.instance;
  }
  
  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.initialized) return;
    if (this.initializing && this.initPromise) {
      // Another caller is initializing — wait for it to complete
      await this.initPromise;
      return;
    }
    this.initializing = true;
    this.initPromise = this.doInit(context);
    await this.initPromise;
  }

  private async doInit(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    
    await this.geofenceMgr.init(context);
    await this.behaviorLog.init(context);
    
    // 初始化 C++ 规则引擎
    await this.engine.init(context);
    if (this.engine.getRuleCount() === 0) {
      await this.engine.loadDefaultRules();
      this.log.info(TAG, `Loaded default rules: ${this.engine.getRuleCount()}`);
    }
    
    // 初始化多源位置融合
    await this.locationFusion.init(context);

    await this.feedbackSvc.init(context);
    // Register callback so FeedbackService can notify us of LLM feedback (avoids circular import)
    this.feedbackSvc.setLlmFeedbackCallback((ruleId: string) => {
      this.markLlmFeedbackReceived(ruleId);
    });
    await this.loadSuggestionState();

    // 初始化 LLM 兜底服务
    this.llmFallback.init(context);

    // 数字世界感知服务：延迟到 start() 里权限请求之后再 init
    // 这样 WearablePlugin 请求 READ_HEALTH_DATA 时 UI 已就绪，弹窗能正常显示

    // 加载积极探索模式状态
    await this.loadExploreMode();

    // 加载设备连接记录
    await this.loadConnectionRecords();

    // 初始化训练数据同步 (服务端与 Gateway 同机，端口 18790)
    await this.trainingSync.init(context, 'http://192.168.1.76:18790');

    // 初始化联邦学习同步 (与训练同步共用端点)
    await FederatedSync.getInstance().init(context, 'http://192.168.1.76:18790');

    // 初始化旅行信息服务 (航班/火车票日历解析)
    this.travelInfoSvc.init(context).catch((err: Error) => {
      this.log.warn(TAG, `TravelInfoService init failed: ${err.message}`);
    });

    // 初始化场景匹配器 (加载 scenarios.json)
    await this.scenarioMatcher.init(context);
    this.log.info(TAG, `ScenarioMatcher initialized: ${this.scenarioMatcher.getScenarioCount()} scenarios`);

    // 初始化每日行程时间线
    await DailyTimelineService.getInstance().init(context);

    // 初始化传感器录制服务
    this.recorder.init(context.filesDir);

    // 监听地理围栏事件
    this.geofenceMgr.addListener((event) => this.onGeofenceEvent(event));

    // 注册系统 WiFi 连接状态变化监听（实时检测 WiFi 断开/连接）
    try {
      wifiManager.on('wifiConnectionChange', (state: number) => {
        if (state === 1) {
          // WiFi 已连接
          this.log.info(TAG, 'WiFi connection event: connected');
          this.refreshWifiAsync();
        } else {
          // WiFi 已断开
          this.log.info(TAG, 'WiFi connection event: disconnected');
          if (this.lastWifiSsid.length > 0) {
            this.onWifiDisconnected();
          }
        }
      });
      this.log.info(TAG, 'WiFi connection change listener registered');
    } catch (err) {
      this.log.warn(TAG, `WiFi listener registration failed: ${(err as Error).message}`);
    }

    this.initialized = true;
    this.log.info(TAG, `Context Awareness Service initialized, rules: ${this.engine.getRuleCount()}`);
  }
  
  
  async start(): Promise<boolean> {
    if (this.isRunning) return true;
    if (!this.initialized) {
      this.log.warn(TAG, 'Service not initialized yet, skipping start');
      return false;
    }
    if (this.starting) return true;
    this.starting = true;
    
    try {
      // 请求位置权限
      let locationGranted = await this.requestLocationPermission();
      
      // 请求运动传感器权限并启动
      await this.requestMotionPermission();
      this.startMotionSensors();
      
      // 启动WiFi定时扫描 (多级采集)
      this.startWifiTimer();
      
      // 启动定时规则评估
      this.startPeriodicEvaluation();

      // 启动智能位置获取（多级采集）
      if (locationGranted) {
        this.startSmartLocationTimer();
      } else {
        this.log.warn(TAG, 'Location permission denied, location features disabled');
      }

      // 核心功能已就绪，标记 isRunning 以启用定时评估
      this.isRunning = true;
      this.log.info(TAG, 'Context Awareness Service started (multi-tier sensing enabled)');

      // 立即推送初始状态到时间线（解决"今日行程显示不及时"问题）
      this.pushTimelineEvent();

      // 初始化 + 启动数字世界感知（非关键路径，失败不影响规则评估）
      try {
        await this.digitalWorld.init(this.context as common.UIAbilityContext);
        this.digitalWorld.start();
      } catch (dwErr) {
        this.log.warn(TAG, `DigitalWorld init/start failed (non-fatal): ${(dwErr as Error).message}`);
      }

      return true;
    } catch (err) {
      this.log.error(TAG, `Failed to start: ${(err as Error).message}`);
      this.starting = false;  // 允许重试
      return false;
    }
  }
  
  stop(): void {
    if (!this.isRunning) return;

    this.stopSmartLocationTimer();
    this.stopWifiTimer();
    this.stopMotionSensors();
    this.stopPeriodicEvaluation();
    this.digitalWorld.stop();

    this.isRunning = false;
    this.log.info(TAG, 'Context Awareness Service stopped');
  }

  /**
   * 更新用户姿势状态（来自NodeRuntime的传感器检测）
   * 注意: tiltAngle由本类的加速度计独家负责，NodeRuntime只更新isLyingDown
   */
  updatePostureState(isLyingDown: boolean): void {
    let wasLyingDown = this.isLyingDown;
    this.isLyingDown = isLyingDown;

    // 只更新躺卧状态，不更新tiltAngle (避免与本类加速度计冲突)
    this.recordedPut('isLyingDown', this.isLyingDown ? 'true' : 'false', 0.9, 'accelerometer');

    // 仅在姿势变化时记录日志
    if (wasLyingDown !== isLyingDown) {
      this.log.info(TAG, `姿势状态更新: ${isLyingDown ? '躺下' : '坐/站'}`);
    }
  }
  
  
  // ==================== WiFi 断开连接事件处理 ====================
  
  private onWifiDisconnected(): void {
    if (this.isReplaying) return;  // 回放中不处理WiFi事件
    let lostSsid = this.lastWifiSsid;
    this.log.info(TAG, `WiFi disconnected, last SSID: ${lostSsid}`);

    if (lostSsid.length === 0) return;

    // 遍历所有围栏，检查丢失的 WiFi 是否匹配任何围栏的学习信号
    let allGeofences = this.geofenceMgr.getAllGeofences();
    let matchedCategory = '';

    for (let gf of allGeofences) {
      let summary = this.locationFusion.getLearnedSignalsSummary(gf);
      if (summary && summary.wifiSsids.includes(lostSsid)) {
        matchedCategory = gf.category;
        break;
      }
    }

    if (matchedCategory.length > 0) {
      let now = Date.now();
      this.log.info(TAG, `WiFi lost: ${lostSsid} — leaving ${matchedCategory} geofence`);
      this.wifiLostTimestamps.set(matchedCategory, now);

      // 设置通用丢失标记
      this.recordedPut('wifiLost', 'true', 0.8, 'wifi');
      this.recordedPut('wifiLostCategory', matchedCategory, 0.8, 'wifi');

      // 向后兼容：work 类别同时设置 wifiLostWork
      if (matchedCategory === 'work') {
        this.wifiLostWorkTimestamp = now;
        this.recordedPut('wifiLostWork', 'true', 0.8, 'wifi');
      }

      this.engine.pushEvent('wifi_lost_' + matchedCategory);

      // 围栏 WiFi 断开 → 用户正在离开该围栏
      // 立即强制 GPS 刷新，并按当前运动状态切换到室外 GPS 频率
      this.log.info(TAG, `Geofence WiFi lost: force GPS fetch, entering outdoor mode (motion=${this.lastMotionState})`);
      this.recordedPut('geofence', '', 0, 'geofence');  // 先清除旧围栏，防止 T1 skip
      this.geofenceDepartureTime = Date.now();  // 启动围栏离开冷却
      this.adjustLocationInterval(this.lastMotionState);  // 按运动状态设置GPS频率
      this.fetchSingleLocation();  // 立即获取一次 GPS 定位

      // 立即触发评估
      this.refreshTray().then(() => {
        this.buildPhysicalStateAndDetectChange();
        let snapshot = this.augmentSnapshot(this.tray.getSnapshot());
        this.evaluateAndDeliver(snapshot);
      });
    }

    // 清除当前 WiFi 围栏匹配
    this.recordedPut('wifiGeofence', '', 0, 'wifi');
    this.recordedPut('geofenceCategory', '', 0, 'wifi');  // 同步清除 GPS 围栏类别
    this.recordedPut('wifiSsid', '', 0, 'wifi');  // 清除 WiFi SSID
    this.lastWifiSsid = '';
  }
  
  private onWifiConnected(): void {
    if (this.isReplaying) return;  // 回放中不处理WiFi事件
    this.log.info(TAG, `onWifiConnected called, lastWifiSsid=${this.lastWifiSsid}`);
    // WiFi 重新连接，清除丢失标记
    this.wifiLostWorkTimestamp = 0;
    this.wifiLostTimestamps.clear();
    this.geofenceDepartureTime = 0;  // WiFi重连，取消围栏离开冷却

    // 尝试获取当前 SSID 并匹配围栏
    try {
      wifiManager.getLinkedInfo().then((info) => {
        let ssid = info.ssid || '';
        if (ssid.startsWith('"') && ssid.endsWith('"')) {
          ssid = ssid.substring(1, ssid.length - 1);
        }
        if (ssid.length === 0) return;

        this.lastWifiSsid = ssid;
        this.recordedPut('wifiSsid', ssid, 1.0, 'wifi');

        // 遍历所有围栏查找匹配
        let matched = false;
        let allGeofences = this.geofenceMgr.getAllGeofences();
        for (let gf of allGeofences) {
          let summary = this.locationFusion.getLearnedSignalsSummary(gf);
          if (summary && summary.wifiSsids.includes(ssid)) {
            this.log.info(TAG, `WiFi connected: ${ssid} matches ${gf.category} geofence (${gf.id})`);
            this.recordedPut('wifiGeofence', gf.category, 0.9, 'wifi');
            this.recordedPut('geofence', gf.id, 1.0, 'wifi');  // WiFi 直接确认围栏
            this.engine.pushEvent('wifi_arrive_' + gf.category);
            matched = true;

            // 到达新围栏 → WiFi 已确认位置，无需额外 GPS
            this.adjustLocationInterval(this.lastMotionState);

            // 交通场景: 检查旅行信息并显示登机牌/火车票
            if (gf.category === 'transit') {
              this.triggerTravelInfoCards(gf.name);
            }

            // 立即触发评估
            this.refreshTray().then(() => {
              this.buildPhysicalStateAndDetectChange();
              let snapshot = this.augmentSnapshot(this.tray.getSnapshot());
              this.evaluateAndDeliver(snapshot);
            });
            return;
          }
        }

        // 自动地点发现：未匹配围栏的 WiFi，记录 GPS+SSID
        if (!matched) {
          this.recordDiscoveredWifiPlace(ssid);
        }

        // 探索模式：WiFi 变化但未匹配围栏也触发评估（让 LLM 分析新环境）
        if (!matched && this.exploreMode) {
          this.log.info(TAG, `[Explore-DBG] WiFi connected to unmatched "${ssid}", triggering explore evaluation`);
          this.refreshTray().then(() => {
            this.buildPhysicalStateAndDetectChange();
            let snapshot = this.augmentSnapshot(this.tray.getSnapshot());
            this.evaluateAndDeliver(snapshot);
          });
        }
      });
    } catch (err) {
      this.log.debug(TAG, `WiFi connected, get info failed: ${(err as Error).message}`);
    }
  }
  
  /**
   * 触发交通场景旅行信息卡片: 检查今天的航班/火车，显示状态确认卡片
   */
  private triggerTravelInfoCards(placeName: string): void {
    this.travelInfoSvc.getTodayFlights().then((flights) => {
      this.travelInfoSvc.getTodayTrains().then((trains) => {
        let hasFlights = flights.length > 0;
        let hasTrains = trains.length > 0;

        if (!hasFlights && !hasTrains) {
          this.log.info(TAG, `Transit geofence "${placeName}": no travel info found in next 24h`);
          return;
        }

        this.log.info(TAG, `Transit geofence "${placeName}": ${flights.length} flights, ${trains.length} trains`);
        let ts = Date.now().toString();

        // Show flight state card
        if (hasFlights) {
          let f = flights[0];
          let dTime = new Date(f.departureTime);
          let hh = dTime.getHours().toString().padStart(2, '0');
          let mm = dTime.getMinutes().toString().padStart(2, '0');
          let safeFlight = f.flightNumber.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
          let safeDep = f.departure.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
          let safeArr = f.arrival.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
          let safePlace = placeName.replace(/\\/g, '\\\\').replace(/"/g, '\\"');

          let summary = safeFlight;
          if (safeDep.length > 0 && safeArr.length > 0) {
            summary = `${safeFlight} ${safeDep}→${safeArr}`;
          }

          let card = `{"type":"form","id":"transit_flight_state_${ts}","children":[` +
            `{"type":"text","text":"✈️ 检测到你在 ${safePlace}","style":{"fontSize":18,"fontWeight":"bold"}},` +
            `{"type":"text","text":"发现今日航班: ${summary} ${hh}:${mm} 出发","style":{"fontSize":15}},` +
            `{"type":"button","text":"📋 查看登机牌","variant":"primary","action":{"event":{"name":"travel_confirm","context":{"type":"flight"}}}},` +
            `{"type":"button","text":"🙈 不用了","variant":"borderless","action":{"event":{"name":"travel_dismiss","context":{"type":"flight","id":"${safeFlight}"}}}}` +
            `]}`;
          this.dispatchA2UI('push', card);
        }

        // Show train state card (delayed 1.5s to avoid simultaneous cards)
        if (hasTrains) {
          let tr = trains[0];
          let dTime = new Date(tr.departureTime);
          let hh = dTime.getHours().toString().padStart(2, '0');
          let mm = dTime.getMinutes().toString().padStart(2, '0');
          let safeTrain = tr.trainNumber.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
          let safeDep = tr.departure.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
          let safeArr = tr.arrival.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
          let safePlace = placeName.replace(/\\/g, '\\\\').replace(/"/g, '\\"');

          let summary = safeTrain;
          if (safeDep.length > 0 && safeArr.length > 0) {
            summary = `${safeTrain} ${safeDep}→${safeArr}`;
          }

          let tsDelay = (Date.now() + 1500).toString();
          let card = `{"type":"form","id":"transit_train_state_${tsDelay}","children":[` +
            `{"type":"text","text":"🚄 检测到你在 ${safePlace}","style":{"fontSize":18,"fontWeight":"bold"}},` +
            `{"type":"text","text":"发现今日车次: ${summary} ${hh}:${mm} 出发","style":{"fontSize":15}},` +
            `{"type":"button","text":"🎫 查看车票","variant":"primary","action":{"event":{"name":"travel_confirm","context":{"type":"train"}}}},` +
            `{"type":"button","text":"🙈 不用了","variant":"borderless","action":{"event":{"name":"travel_dismiss","context":{"type":"train","id":"${safeTrain}"}}}}` +
            `]}`;
          setTimeout(() => {
            this.dispatchA2UI('push', card);
          }, 1500);
        }
      }).catch((err: Error) => {
        this.log.warn(TAG, `triggerTravelInfoCards trains error: ${err.message}`);
      });
    }).catch((err: Error) => {
      this.log.warn(TAG, `triggerTravelInfoCards flights error: ${err.message}`);
    });
  }

  /**
   * 增强 snapshot：补充 WiFi 围栏丢失标记（基于 wifiLostTimestamps 的 TTL）
   */
  private augmentSnapshot(snapshot: ContextSnapshot): ContextSnapshot {
    let now = Date.now();
    // 检查所有 WiFi 丢失时间戳，找最近的未过期记录
    let latestCategory = '';
    let latestTime = 0;
    this.wifiLostTimestamps.forEach((ts: number, category: string) => {
      if (now - ts < ContextAwarenessService.WIFI_LOST_TTL_MS && ts > latestTime) {
        latestCategory = category;
        latestTime = ts;
      }
    });
    if (latestCategory.length > 0) {
      snapshot.wifiLost = 'true';
      snapshot.wifiLostCategory = latestCategory;
      if (latestCategory === 'work') {
        snapshot.wifiLostWork = 'true';
      }
    }

    // 补充 C++ snapshot 缺失的 tray 字段
    let wifiGfSlot = this.tray.get('wifiGeofence');
    if (wifiGfSlot && wifiGfSlot.value && wifiGfSlot.value.length > 0) {
      snapshot.wifiGeofence = wifiGfSlot.value;
    } else {
      // WiFi 未匹配围栏时，回退到 GPS/围栏事件确认的类别
      let gfCatSlot = this.tray.get('geofenceCategory');
      if (gfCatSlot && gfCatSlot.value && gfCatSlot.value.length > 0) {
        snapshot.wifiGeofence = gfCatSlot.value;
      }
    }
    // 补充 geofence（C++ 可能因过期没返回）
    if (!snapshot.geofence || snapshot.geofence.length === 0) {
      let gfSlot = this.tray.get('geofence');
      if (gfSlot && gfSlot.value && gfSlot.value.length > 0) {
        snapshot.geofence = gfSlot.value;
      }
    }
    // 补充 wifiSsid
    if (!snapshot.wifiSsid || snapshot.wifiSsid.length === 0) {
      if (this.lastWifiSsid && this.lastWifiSsid.length > 0) {
        snapshot.wifiSsid = this.lastWifiSsid;
      }
    }

    return snapshot;
  }

  private async requestMotionPermission(): Promise<boolean> {
    try {
      let atManager = abilityAccessCtrl.createAtManager();
      // READ_HEALTH_DATA 由 WearablePlugin.init() 单独请求，避免重复弹窗
      let result = await atManager.requestPermissionsFromUser(this.context as common.UIAbilityContext,
        ['ohos.permission.ACTIVITY_MOTION']);
      let motionGranted = result.authResults[0] === 0;
      this.log.info(TAG, `ACTIVITY_MOTION permission: ${motionGranted ? 'granted' : 'denied'}`);
      return motionGranted;
    } catch (err) {
      this.log.warn(TAG, `Motion permission request failed: ${(err as Error).message}`);
      return false;
    }
  }

  private async requestLocationPermission(): Promise<boolean> {
    try {
      let atManager = abilityAccessCtrl.createAtManager();
      let result = await atManager.requestPermissionsFromUser(this.context as common.UIAbilityContext,
        ['ohos.permission.APPROXIMATELY_LOCATION', 'ohos.permission.LOCATION']);
      let approxGranted = result.authResults[0] === 0;
      let preciseGranted = result.authResults.length > 1 && result.authResults[1] === 0;
      this.log.info(TAG, `Location permission: approx=${approxGranted ? 'granted' : 'denied'}, precise=${preciseGranted ? 'granted' : 'denied'}`);
      return approxGranted || preciseGranted;
    } catch (err) {
      this.log.warn(TAG, `Location permission request failed: ${(err as Error).message}`);
      return false;
    }
  }

  private startMotionSensors(): void {
    try {
      sensor.on(sensor.SensorId.ACCELEROMETER, (data: sensor.AccelerometerResponse) => {
        this.accelerometerData = { x: data.x, y: data.y, z: data.z, timestamp: Date.now() };
        this.recordAccelSample();
        this.updateMotionState();
      }, { interval: 200000000 }); // 200ms 采样间隔，提高姿势检测灵敏度
      
      sensor.on(sensor.SensorId.PEDOMETER, (data: sensor.PedometerResponse) => {
        this.stepCount = data.steps;
        // 维护CAS自有的今日步数基线（作为StepCounterPlugin的备用）
        let today = new Date();
        let todayStr = today.getFullYear() + '-' + (today.getMonth() + 1).toString().padStart(2, '0') + '-' + today.getDate().toString().padStart(2, '0');
        if (this.stepCountBaselineDate !== todayStr) {
          this.stepCountBaseline = data.steps;
          this.stepCountBaselineDate = todayStr;
        } else if (this.stepCountBaseline < 0) {
          this.stepCountBaseline = data.steps;
        }
      }, { interval: 5000000000 });
      
      this.log.info(TAG, 'Motion sensors started');
    } catch (err) {
      this.log.warn(TAG, `Sensor error: ${(err as Error).message}`);
    }
  }
  
  private stopMotionSensors(): void {
    try {
      sensor.off(sensor.SensorId.ACCELEROMETER);
      sensor.off(sensor.SensorId.PEDOMETER);
    } catch {
      // ignore
    }
}
  
  private recordAccelSample(): void {
    let x = this.accelerometerData.x;
    let y = this.accelerometerData.y;
    let z = this.accelerometerData.z;
    let magnitude = Math.sqrt(x * x + y * y + z * z);
    let gravityAngle = Math.acos(z / magnitude) * 180 / Math.PI;

    // 计算手机倾斜角 (用于姿势检测)
    this.lastTiltAngle = Math.atan2(z, Math.sqrt(x * x + y * y)) * 180 / Math.PI;
    this.updatePosture();
    this.updateHoldingState();  // 更新手握状态

    let accelSample: AccelSample = {
      magnitude: magnitude,
      gravityAngle: gravityAngle,
      timestamp: this.accelerometerData.timestamp
    };
    this.accelHistory.push(accelSample);

    if (this.accelHistory.length > ContextAwarenessService.ACCEL_HISTORY_SIZE) {
      this.accelHistory.shift();
    }

    // 记录 Z 轴值用于频率分析
    let zSample: ZAxisSamplePoint = {
      value: z,
      timestamp: this.accelerometerData.timestamp
    };
    this.zAxisHistory.push(zSample);

    if (this.zAxisHistory.length > ContextAwarenessService.Z_AXIS_HISTORY_SIZE) {
      this.zAxisHistory.shift();
    }

    // 更新 Z 轴特征（每10个样本计算一次，约2秒）
    if (this.zAxisHistory.length % 10 === 0) {
      this.updateZAxisFeatures();
    }
  }

  /**
   * 检测用户是否正在手握手机
   * 简化判断: 手机非平放 = 手握
   */
  private updateHoldingState(): void {
    let x = this.accelerometerData.x;
    let y = this.accelerometerData.y;
    let z = this.accelerometerData.z;

    // 判断手机是否平放在桌面
    // 平放: |z| 接近 9.8 m/s² (重力加速度)，允许 ±2 误差
    // 手握/倾斜: |z| 偏离 9.8 较多
    let isFlat = Math.abs(Math.abs(z) - 9.8) < 2.0;

    let wasHolding = this.isHoldingPhone;

    // 手握判断: 只要不是平放就算手握
    this.isHoldingPhone = !isFlat;

    // 更新数据托盘
    this.recordedPut('isHolding', this.isHoldingPhone ? 'true' : 'false', 0.9, 'accelerometer');

    // 始终记录日志用于调试
    this.log.info(TAG, `Holding: ${this.isHoldingPhone ? 'YES' : 'NO'} (z=${z.toFixed(2)}, |z|=${Math.abs(z).toFixed(2)}, flat=${isFlat})`);
  }

  /**
   * 检测加速度计的微小波动 (手持抖动)
   */
  private detectMicroMovements(): boolean {
    if (this.accelHistory.length < 5) return false;

    let recent = this.accelHistory.slice(-5);
    let magnitudes = recent.map(s => s.magnitude);

    // 计算方差
    let avg = magnitudes.reduce((a, b) => a + b) / magnitudes.length;
    let variance = magnitudes.reduce((sum, m) => sum + Math.pow(m - avg, 2), 0) / magnitudes.length;

    // 小方差表示微小抖动 (不是完全静止，也不是大幅运动)
    return variance > 0.05 && variance < 3.0;
  }
  
  /**
   * 旧的拿起检测方法 - 已禁用，改用 isHolding (手握状态) 替代
   * 保留此方法以避免破坏 updateMotionState 的调用
   */
  private detectPickup(): boolean {
    // 禁用拿起检测，改用 isHolding
    return false;
  }
  
  /**
   * 单样本加速度分类（用于滑动窗口投票）
   */
  private classifySingleSample(magnitude: number): MotionState {
    if (magnitude < 10.5) return 'stationary';
    if (magnitude < 12) return 'walking';
    if (magnitude < 15) return 'running';
    return 'driving';
  }

  /**
   * 滑动窗口多数投票分类 + 方差检测
   * 取 accelHistory 最后 7 个样本(~1.4秒@200ms)，每个样本分别分类再投票。
   * 方差补偿：走路时 magnitude 在 9.5~12 之间震荡，均值可能接近 9.8（静止），
   * 但方差远高于真正静止(>0.3)，此时强制判定为 walking。
   * walking→running 需要 5/7 票（防止走路摆臂误判为跑步）。
   */
  private classifyWithSmoothing(): MotionState {
    let windowSize = Math.min(7, this.accelHistory.length);
    if (windowSize === 0) return 'stationary';

    let samples = this.accelHistory.slice(-windowSize);

    // 计算 magnitude 均值和方差
    let sum = 0;
    for (let i = 0; i < samples.length; i++) {
      sum += samples[i].magnitude;
    }
    let mean = sum / samples.length;
    let varianceSum = 0;
    for (let i = 0; i < samples.length; i++) {
      let diff = samples[i].magnitude - mean;
      varianceSum += diff * diff;
    }
    let variance = varianceSum / samples.length;

    // 方差补偿：手持走路时 magnitude 均值接近 9.8 但震荡明显(方差>0.08)
    // 真正静止时方差极低(<0.02)。阈值 0.08 覆盖慢走场景（方差约 0.08-0.20），
    // 原阈值 0.15 会漏判缓慢步行（慢走方差在 0.08-0.14 之间）。
    if (variance > 0.08 && mean < 10.5) {
      return 'walking';
    }

    // 多数投票
    let votes: Map<string, number> = new Map();
    for (let i = 0; i < samples.length; i++) {
      let cls = this.classifySingleSample(samples[i].magnitude) as string;
      votes.set(cls, (votes.get(cls) ?? 0) + 1);
    }

    // 找出票数最多的状态
    let bestStateStr: string = 'stationary';
    let bestCount = 0;
    votes.forEach((count: number, state: string) => {
      if (count > bestCount) {
        bestCount = count;
        bestStateStr = state;
      }
    });

    // walking→running 防误判：需要 5/7 票才允许升级到 running
    let currentMotionSlot = this.tray.get('motionState');
    let curState = currentMotionSlot ? currentMotionSlot.value : 'unknown';
    if (curState === 'walking' && bestStateStr === 'running') {
      let runningVotes = votes.get('running') ?? 0;
      if (runningVotes < 5) {
        return 'walking'; // 不够票，维持 walking
      }
    }

    return bestStateStr as MotionState;
  }

  /**
   * 更新 Z 轴振幅、频率和方差特征
   * 用于区分走路 vs 驾车
   *   - 走路: 高频(1.5-2.5Hz) + 大幅度(>0.4g)
   *   - 驾车: 低频(<0.8Hz) 或无规律
   *   - 静止: 极小幅度(<0.2g)
   */
  private updateZAxisFeatures(): void {
    if (this.zAxisHistory.length < 50) return;  // 需要至少 250ms 数据@200Hz

    // 取最近 2-3 秒的数据
    let recentMs = Date.now() - 2500;
    let recent = this.zAxisHistory.filter(s => s.timestamp >= recentMs);

    if (recent.length < 10) return;

    let values = recent.map(s => s.value);

    // 1. 计算振幅（峰值-谷值）/ 9.8 转换为 g
    let max = Math.max(...values);
    let min = Math.min(...values);
    this.zAxisAmplitude = (max - min) / 9.8;

    // 2. 计算方差（规律性指标）
    let mean = values.reduce((a, b) => a + b, 0) / values.length;
    let varianceSum = values.reduce((sum, v) => sum + (v - mean) ** 2, 0);
    this.zAxisVariance = varianceSum / values.length;

    // 3. 频率估计（自相关，找第一个负峰）
    this.zAxisFrequency = this.estimateFrequencyByAutocorr(recent);

    // 记录到 DataTray 用于调试
    this.recordedPut('zAxisAmplitude', this.zAxisAmplitude.toFixed(3), 0.8, 'accelerometer');
    this.recordedPut('zAxisFrequency', this.zAxisFrequency.toFixed(2), 0.8, 'accelerometer');
    this.recordedPut('zAxisVariance', this.zAxisVariance.toFixed(3), 0.8, 'accelerometer');
  }

  /**
   * 通过自相关估计 Z 轴主频率
   * 原理：找到第一个负峰对应的 lag，转换为 Hz
   * 走路频率: ~1.5-2.5 Hz (200Hz采样 → lag 80-130)
   * 驾车频率: ~0.2-0.5 Hz (200Hz采样 → lag 400+) 或无规律
   */
  private estimateFrequencyByAutocorr(samples: Array<ZAxisSamplePoint>): number {
    if (samples.length < 50) return 0;

    let values = samples.map(s => s.value);
    let mean = values.reduce((a, b) => a + b, 0) / values.length;
    let centered = values.map(v => v - mean);

    // 采样间隔（假设200Hz，即5ms）
    let dt = samples.length > 1
      ? (samples[samples.length - 1].timestamp - samples[0].timestamp) / (samples.length - 1)
      : 5;

    // 自相关：寻找第一个负峰（一个完整周期）
    let bestLag = 0;
    let bestCorr = 0;

    // 只搜索 10 ~ 200 lag（对应 0.5Hz ~ 20Hz）
    for (let lag = 10; lag < Math.min(200, values.length / 2); lag++) {
      let corr = 0;
      for (let i = 0; i < values.length - lag; i++) {
        corr += centered[i] * centered[i + lag];
      }
      // 第一个明显的负值 = 半个周期
      if (corr < -0.1 * centered.length && bestLag === 0) {
        bestLag = lag * 2;  // 乘以2得到完整周期
        bestCorr = corr;
        break;
      }
    }

    if (bestLag === 0) return 0;  // 无规律

    // lag → 频率 (Hz)
    let frequency = (1000 / dt) / bestLag;
    return Math.max(0, Math.min(frequency, 50));  // 限制在合理范围
  }

  /**
   * 判断一个地点是否是交通枢纽（公交站、地铁站、机场等）
   * 如果是，则从该地点出发检测到的"驾驶"更可能是"乘车"
   */
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

  /**
   * 推断驾驶 vs 乘车
   * 如果前一个地点是交通枢纽，当前检测到"驾驶"运动，很可能是乘车而非自己驾驶
   * 返回 'driving' / 'transit' / 'unknown'
   */
  private inferDrivingVsTransit(detectedMotion: MotionState, currentGeofence: string, gpsSpeed: number): MotionState {
    if (detectedMotion !== 'driving') {
      return detectedMotion;  // 非驾驶状态，直接返回
    }

    // 检查前一个围栏是否是交通枢纽
    if (this.lastGeofence && this.isTransitHub(this.lastGeofence)) {
      // 从交通枢纽出发，检测到驾驶 → 更可能是乘车
      // 但需要排除：实际上自己开车离开停车场的情况
      
      // 启发式判断：
      // 1. 如果还没离开很远（GPS精度可能有偏），推断为乘车
      // 2. 如果是机场/火车站且GPS速度稳定，很可能是公交/地铁
      
      let currentIsTransitHub = currentGeofence && this.isTransitHub(currentGeofence);
      
      // 如果前后都是交通枢纽或从枢纽刚出来 → 乘车可能性大
      if (currentIsTransitHub || (Date.now() - this.geofenceDepartureTime < 5 * 60 * 1000)) {
        return 'transit';  // 推断为乘车
      }
      
      // 其他情况无法确定 → 返回 'driving' 让规则引擎处理
    }

    return detectedMotion;
  }

  /**
   * 使用 Z 轴特征辅助判断运动状态
   * 特别是在 GPS 速度不可靠时
   * 返回基于 Z 轴的建议状态，或 'unknown' 表示无法判断
   */
  private classifyByZAxisFeatures(): MotionState {
    // 幅度极小时无法区分静止与手机朝向导致的低Z分量（如口袋竖放走路），
    // 交由方差分类器 classifyWithSmoothing() 判断，避免误判走路为静止。
    if (this.zAxisAmplitude < 0.2) {
      return 'unknown';
    }

    // 走路特征：高频 + 大幅度
    if (this.zAxisFrequency >= 1.2 && this.zAxisFrequency <= 2.5 && this.zAxisAmplitude >= 0.35) {
      return 'walking';
    }

    // 驾车特征：低频 + 中等幅度 或 无规律
    if (this.zAxisAmplitude >= 0.15 && this.zAxisAmplitude < 0.35) {
      // 低频或无规律 → 驾车或颠簸
      if (this.zAxisFrequency < 0.8 || this.zAxisFrequency === 0) {
        return 'driving';
      }
    }

    // 高幅度低频 → 驾车（颠簸）
    if (this.zAxisAmplitude >= 0.4 && this.zAxisFrequency < 1.0) {
      return 'driving';
    }

    // 无法判定
    return 'unknown';
  }

  /**
   * 基于加速度计数据和GPS速度综合判断运动状态
   * 解决：开车/高铁匀速时加速度小但速度快的问题
   */
  private updateMotionState(): void {
    if (this.isReplaying) return;  // 回放中不更新真实运动状态
    let x = this.accelerometerData.x;
    let y = this.accelerometerData.y;
    let z = this.accelerometerData.z;
    let magnitude = Math.sqrt(x * x + y * y + z * z);
    let gpsSpeed = this.lastLocation?.speed ?? 0;
    
    let isPickup = this.detectPickup();
    
    if (isPickup || this.pickupConfirmed) {
      this.recordedPut('motionState', 'pickup', 0.85, 'accelerometer');

      if (this.lastMotionState !== 'pickup') {
        this.stateBeforePickup = this.lastMotionState;
        this.log.info(TAG, `Motion state: ${this.lastMotionState} -> pickup (brief glance)`);
        this.engine.pushEvent('motion_pickup');
        this.lastMotionState = 'pickup';
      }
      this.pickupConfirmed = false;
      // 拿起手机不触发GPS — 只是瞬间查看，不需要位置更新
      return;
    }

    // 拿起后冷却期：恢复拿起前的状态，防止手持抖动误判为walking触发GPS
    let now_ms = Date.now();
    if (now_ms < this.postPickupCooldownUntil) {
      return;
    }

    if (this.accelHistory.length >= 3) {
      let recent = this.accelHistory.slice(-3);
      let avgMag = recent.reduce((sum, s) => sum + s.magnitude, 0) / recent.length;
      if (avgMag < 10.3) {
        this.lastStableGravityAngle = recent[recent.length - 1].gravityAngle;
      }
    }
    
    let newState: MotionState;

    if (gpsSpeed > 5) {
      newState = 'driving';
      // 高速行驶：刷新惯性时间戳 + 步数基线
      this.lastHighSpeedTime = Date.now();
      this.drivingInertiaStepBase = this.stepCount;
    } else if (gpsSpeed > 1.5) {
      // 中速：已在驾车就继续驾车，否则判走路/跑步
      if (this.lastMotionState === 'driving') {
        newState = 'driving';
        this.lastHighSpeedTime = Date.now();
        this.drivingInertiaStepBase = this.stepCount;
      } else {
        // GPS速度不可靠时用 Z 轴特征辅助
        let zAxisClassify = this.classifyByZAxisFeatures();
        if (zAxisClassify !== 'unknown') {
          newState = zAxisClassify;
        } else {
          newState = magnitude > 12 ? 'running' : 'walking';
        }
      }
    } else {
      // GPS速度极低：驾车惯性保护（红灯/短暂停车）
      let recentlyDriving = (this.lastMotionState === 'driving')
        && (Date.now() - this.lastHighSpeedTime < ContextAwarenessService.DRIVING_INERTIA_MS);
      // 步数比对：只统计从最后一次确认驾车速度以来的新增步数
      let stepsSinceHighSpeed = this.stepCount - this.drivingInertiaStepBase;
      if (recentlyDriving && stepsSinceHighSpeed < 20) {
        newState = 'driving';  // 红灯/短暂停车，维持驾车
      } else {
        // GPS 不可用时，用 Z 轴特征优先判断
        let zAxisClassify = this.classifyByZAxisFeatures();
        if (zAxisClassify !== 'unknown') {
          newState = zAxisClassify;
        } else {
          // 否则使用滑动窗口多数投票
          newState = this.classifyWithSmoothing();
        }
      }
    }
    
    // 车载蓝牙覆盖：连接车载BT时，stationary/walking → driving
    let btInVehicle = this.tray.get('bt_in_vehicle');
    if (btInVehicle && btInVehicle.value === 'true' && (newState === 'stationary' || newState === 'walking')) {
      newState = 'driving';
    }

    // 躺卧覆盖：躺着时翻身等动作不能被误判成步行
    // 仅在已知围栏内(home/work等室内)才应用 — 排除驾车场景：
    //   手机在车载支架上（横屏/倾斜）满足 isSideLying 条件导致 isLyingDown 误判，
    //   如果无条件覆盖 walking→stationary，会阻止 GPS 更新速度，永远检测不到 driving。
    //   离开围栏后 WiFi 断连清除了 geofence，此时不应用覆盖，让 walking 状态
    //   触发高频 GPS → 检测到速度 → 识别为 driving。
    let geofenceSlot = this.tray.get('geofence');
    let inGeofence = geofenceSlot && geofenceSlot.value !== null && geofenceSlot.value.length > 0;
    let hasVehicleSignal = gpsSpeed > 1.5 || (btInVehicle && btInVehicle.value === 'true');
    if (this.isLyingDown && inGeofence && !hasVehicleSignal && (newState === 'walking' || newState === 'running')) {
      newState = 'stationary';
    }

    // Dwell 逻辑：新候选状态须持续一段时间才生效，防止短暂波动
    let currentMotion = this.tray.get('motionState');
    let currentState: MotionState = (currentMotion ? currentMotion.value : 'unknown') as MotionState;
    if (newState !== currentState && currentState !== 'unknown' && currentState !== 'pickup' && currentState !== 'putdown') {
      let now_dwell = Date.now();
      if (newState !== this.pendingMotionState) {
        // 新候选状态，开始 dwell 计时
        this.pendingMotionState = newState;
        this.motionDwellStart = now_dwell;
        return; // 不更新，等待 dwell 确认
      }
      // 同一候选状态，检查 dwell 时间是否满足
      // driving退出到stationary/walking需要更长dwell，防止停车后加速度计波动
      let isDrivingExit = (currentState === 'driving') && (newState === 'stationary' || newState === 'walking');
      let dwellRequired = isDrivingExit
        ? ContextAwarenessService.DRIVING_EXIT_DWELL_MS
        : (newState === 'stationary')
          ? ContextAwarenessService.STATIONARY_DWELL_MS
          : ContextAwarenessService.ACTIVE_DWELL_MS;
      if (now_dwell - this.motionDwellStart < dwellRequired) {
        return; // dwell 时间不够，继续等待
      }
      // dwell 通过，清除 pending 状态，继续执行更新
      this.pendingMotionState = 'unknown';
    } else {
      // 状态未变或特殊状态，清除 pending
      this.pendingMotionState = 'unknown';
    }

    if (newState !== 'stationary') {
      if (this.motionStartTime === 0) {
        this.motionStartTime = Date.now();
        this.motionStepCountStart = this.stepCount;
      }
    } else {
      this.motionStartTime = 0;
      this.motionStepCountStart = 0;
    }

    // 驾驶 vs 乘车推断（使用地理围栏辅助）
    let currentGeofence = this.tray.get('geofence')?.value ?? '';
    if (newState === 'driving') {
      newState = this.inferDrivingVsTransit(newState, currentGeofence, gpsSpeed) as MotionState;
    }

    // 更新前一个围栏（用于下次推断）
    if (currentGeofence.length > 0 && currentGeofence !== this.lastGeofence) {
      this.lastGeofence = currentGeofence;
    }

    this.recordedPut('motionState', newState, 0.9, 'accelerometer');
    this.recordedPut('gpsSpeed', gpsSpeed.toFixed(2), 0.85, 'gps');

    if (newState !== this.lastMotionState) {
      this.log.info(TAG, `Motion state: ${this.lastMotionState} -> ${newState}, gpsSpeed=${gpsSpeed.toFixed(1)}m/s`);

      // driving → 非driving：立即刷新GPS获取最新速度，避免旧速度残留
      if (this.lastMotionState === 'driving' && newState !== 'driving') {
        this.log.info(TAG, `Driving exit: force GPS refresh for accurate speed`);
        this.fetchSingleLocation();
      }

      // 放下手机：从 pickup 转为其他状态，恢复拿起前状态，启动冷却期
      if (this.lastMotionState === 'pickup') {
        this.engine.pushEvent('motion_putdown');
        // 恢复拿起前的GPS间隔，不要因为手持抖动误触walking GPS
        newState = this.stateBeforePickup;
        this.postPickupCooldownUntil = Date.now() + ContextAwarenessService.POST_PICKUP_COOLDOWN_MS;
        this.log.info(TAG, `Putdown: pickup -> restore ${newState} (cooldown ${ContextAwarenessService.POST_PICKUP_COOLDOWN_MS}ms)`);
        this.recordedPut('motionState', newState, 0.9, 'accelerometer');
      }

      // 更新状态历史
      this.updateActivityState(newState);

      this.engine.pushEvent('motion_' + newState);
      this.prevMotionState = this.lastMotionState;
      this.lastMotionState = newState;
      this.adjustLocationInterval(newState);

      // 立即推送时间线事件，不等待周期性评估（解决"今日行程显示不及时"问题）
      this.pushTimelineEvent();
    }
  }
  
  /**
   * 更新活动状态 (状态机)
   * 
   * 活动状态: 'sleeping', 'sitting', 'standing', 'walking', 'active', 'driving'
   */
  private updateActivityState(motionState: MotionState): void {
    let newActivityState = this.activityState;
    let now = Date.now();
    
    // 根据运动状态推断活动状态
    switch (motionState) {
      case 'stationary':
        // 静止状态需要根据上下文判断是睡觉还是坐着
        let hour = new Date().getHours();
        let geofence = this.tray.get('geofence')?.value;
        
        // 夜间在家 → 睡觉
        if ((hour >= 22 || hour < 6) && geofence === 'home') {
          newActivityState = 'sleeping';
        } 
        // 之前在睡觉 → 继续睡觉
        else if (this.activityState === 'sleeping') {
          // 检查心率判断是否醒来
          let heartRate = this.getHeartRateFromWearable();
          if (heartRate > 0 && heartRate < 60) {
            newActivityState = 'sleeping';
          } else if (heartRate >= 60) {
            newActivityState = 'sitting';  // 醒来但还躺着/坐着
          } else {
            // 没有心率数据，保持之前状态
            newActivityState = this.activityState;
          }
        }
        // 其他情况 → 坐着
        else {
          newActivityState = 'sitting';
        }
        break;
        
      case 'walking':
        newActivityState = 'walking';
        break;
        
      case 'running':
        newActivityState = 'active';
        break;
        
      case 'driving':
        newActivityState = 'driving';
        break;
        
      case 'transit':
        // 乘车时的活动状态同驾车
        newActivityState = 'driving';
        break;
        
      case 'cycling':
        // 骑车时的活动状态
        newActivityState = 'active';
        break;
        
      case 'pickup':
        // 拿起手机不改变活动状态
        return;
        
      case 'putdown':
        // 放下手机不改变活动状态
        return;
        
      default:
        newActivityState = 'unknown';
    }
    
    // 状态变化时记录
    if (newActivityState !== this.activityState) {
      this.log.info(TAG, `Activity: ${this.activityState} -> ${newActivityState}`);
      
      // 计算上一个状态的持续时间
      let duration = this.activityStateTimestamp > 0 ? now - this.activityStateTimestamp : 0;
      
      // 记录状态转换到训练数据
      let snapshot = this.augmentSnapshot(this.tray.getSnapshot());
      this.trainingSync.recordStateTransition({
        prevState: this.activityState,
        newState: newActivityState,
        duration: duration,
        context: snapshot,
        timestamp: now
      });
      
      this.prevActivityState = this.activityState;
      this.activityState = newActivityState;
      this.activityStateTimestamp = now;
    }

    // 检查久坐提醒 (无论是否状态变化都要检查)
    this.checkSedentaryReminder();
  }

  /**
   * 推送当前状态到每日行程时间线
   * 由 enrichTray() 在每次数据汇总后调用
   */
  private pushTimelineEvent(): void {
    let geofenceSlot = this.tray.get('geofence');
    let geofenceId: string = (geofenceSlot && geofenceSlot.value) ? geofenceSlot.value : '';
    let geofenceLabel: string = '';
    let geofenceIcon: string = '';

    if (geofenceId.length > 0) {
      try {
        let gf = this.geofenceMgr.getGeofence(geofenceId);
        if (gf) {
          geofenceLabel = gf.name;
          geofenceIcon = this.getGeofenceCategoryIcon(gf.category);
        }
      } catch {
        // ignore
      }
    }

    let motionState: string = this.lastMotionState;
    let lat: number = this.lastLocation ? this.lastLocation.latitude : 0;
    let lng: number = this.lastLocation ? this.lastLocation.longitude : 0;

    // 获取当前最佳活跃场景标题
    let scenarioTitle = '';
    let activeScenarios = this.scenarioMatcher.getActiveStates();
    if (activeScenarios.length > 0) {
      // 取最高置信度的场景
      let best = activeScenarios[0];
      for (let i = 1; i < activeScenarios.length; i++) {
        if (activeScenarios[i].confidence > best.confidence) {
          best = activeScenarios[i];
        }
      }
      scenarioTitle = `${best.scenario.id} ${best.scenario.name}`;
    }

    DailyTimelineService.getInstance().pushStateChange(
      geofenceId, geofenceLabel, geofenceIcon, motionState, lat, lng, scenarioTitle
    );
  }

  private getGeofenceCategoryIcon(cat: string): string {
    if (cat === 'home') return '\u{1F3E0}';        // 🏠
    if (cat === 'work') return '\u{1F3E2}';         // 🏢
    if (cat === 'transit') return '\u{1F687}';       // 🚇
    if (cat === 'gym') return '\u{1F4AA}';           // 💪
    if (cat === 'restaurant') return '\u{1F35C}';    // 🍜
    if (cat === 'shopping') return '\u{1F6D2}';      // 🛒
    if (cat === 'custom') return '\u{1F4CD}';        // 📍
    return '\u{1F4CD}';
  }

  /**
   * 更新用户姿势 (基于手机方向和倾斜角检测用户是否躺着)
   */
  private updatePosture(): void {
    let wasLyingDown = this.isLyingDown;

    let x = this.accelerometerData.x;
    let y = this.accelerometerData.y;
    let z = this.accelerometerData.z;
    let tilt = this.lastTiltAngle;

    // 躺卧判断：必须 tiltAngle 为负值（屏幕朝上/朝脸）
    //
    // tiltAngle = atan2(z, sqrt(x²+y²))
    //   躺着看手机：z<0 → tilt 为负（-15°~-80°）
    //   坐立手握：  z<0 但 y 有明显负分量（重力沿手机长轴）→ tilt 可能微负但 |y|>5
    //   关键区分：坐立时 |y| 大（手机竖着），躺着时 |y| 小（手机横着/斜着）
    //
    // 1. 仰卧（屏幕斜朝向脸部）：tiltAngle ∈ [-80°, -15°] 且 |y| < 6
    //    |y|<6 排除坐立手握（坐立时 y ≈ -7~-9.8）
    let isBackLying = (tilt >= -80 && tilt <= -15) && (Math.abs(y) < 6);

    // 2. 侧卧（手机接近水平 + 手握）：
    //    侧卧时 z 分量小且 y 分量也小（手机近乎水平）
    //    坐立竖握时 |y| > 5，排除坐立场景
    let isSideLying = (Math.abs(z) < 4.5) && (Math.abs(y) < 5) && this.isHoldingPhone;

    if (isBackLying || isSideLying) {
      this.isLyingDown = true;
    } else {
      this.isLyingDown = false;
    }

    // 始终更新数据托盘（确保及时反映当前状态）
    this.recordedPut('isLyingDown', this.isLyingDown ? 'true' : 'false', 0.8, 'accelerometer');
    this.recordedPut('tiltAngle', this.lastTiltAngle.toFixed(1), 0.8, 'accelerometer');

    // 仅在姿势变化时记录日志和触发提醒
    if (wasLyingDown !== this.isLyingDown) {
      this.log.info(TAG, `Posture: ${wasLyingDown ? 'lying' : 'upright'} -> ${this.isLyingDown ? 'lying' : 'upright'} (tilt: ${this.lastTiltAngle.toFixed(1)}°)`);

      // 如果从躺着变为坐立，可能需要检查是否触发早醒提示
      if (wasLyingDown && !this.isLyingDown) {
        this.checkEarlyWakeupReminder();
      }
    }
  }

  /**
   * 从穿戴设备获取心率
   */
  private getHeartRateFromWearable(): number {
    let digitalData = this.digitalWorld.getDigitalData();
    if (digitalData['heart_rate']) {
      return parseInt(digitalData['heart_rate']) || 0;
    }
    return 0;
  }

  /**
   * 检测是否在睡觉
   */
  private detectSleepingState(ctx: EnvironmentContext, hour: number): string {
    // 夜间时段 (22:00 - 06:00)
    if (hour >= 22 || hour < 6) {
      // 在家 + 静止 = 睡觉
      if (ctx.currentGeofence?.id === 'home' && ctx.motionState === 'stationary') {
        return 'true';
      }
    }
    // 检查活动状态
    if (this.activityState === 'sleeping') {
      return 'true';
    }
    return 'false';
  }

  /**
   * 检查是否需要显示早醒提示卡片
   */
  private checkEarlyWakeupReminder(): void {
    let now = new Date();
    let hour = now.getHours();
    let geofence = this.tray.get('geofence')?.value;

    // 早醒时段：6-9点，在家，且从躺着状态变为坐立
    if (hour >= 6 && hour <= 9 && geofence === 'home') {
      this.log.info(TAG, `Early wakeup detected at ${hour}:${now.getMinutes().toString().padStart(2, '0')}`);
      this.showEarlyWakeupCard();
    }
  }

  /**
   * 显示早醒提示卡片
   */
  private showEarlyWakeupCard(): void {
    let now = new Date();
    let timeStr = `${now.getHours()}:${now.getMinutes().toString().padStart(2, '0')}`;

    let a2uiJsonl = '{"type":"card","id":"early_wakeup_' + Date.now() + '","children":[' +
      '{"type":"text","text":"😴 早起了？","style":{"fontSize":18,"fontWeight":"bold"}},' +
      '{"type":"text","text":"现在是 ' + timeStr + '，还可以再睡一会儿","style":{"fontSize":14,"color":"#888"}},' +
      '{"type":"button","text":"好的","variant":"borderless","action":{"event":{"name":"early_wakeup_dismiss"}}}' +
      ']}';

    // 使用 NodeRuntime 发送 A2UI 卡片
    let global = globalThis as GlobalWithRuntime;
    if (global.nodeRuntime?.dispatchA2UI) {
      global.nodeRuntime.dispatchA2UI('push', a2uiJsonl);
      this.log.info(TAG, 'Early wakeup card sent');
    } else {
      this.log.warn(TAG, 'NodeRuntime not available for early wakeup card');
    }
  }

  /**
   * 检查久坐提醒逻辑 (集成姿势检测)
   */
  private checkSedentaryReminder(): void {
    // 只在坐着状态时检查久坐提醒
    if (this.activityState !== 'sitting') {
      return;
    }

    let now = Date.now();
    let activityDuration = this.activityStateTimestamp > 0 ? now - this.activityStateTimestamp : 0;
    let durationMinutes = Math.floor(activityDuration / (1000 * 60));

    // 30分钟久坐提醒阈值
    if (durationMinutes < 30) {
      return;
    }

    let hour = new Date().getHours();

    // 如果用户躺着，根据时间决定处理方式
    if (this.isLyingDown) {
      if (hour >= 6 && hour <= 9) {
        // 早上躺着 → 已经在 checkEarlyWakeupReminder 处理
        return;
      } else {
        // 白天躺着 → 视为午休或休息，不触发久坐提醒
        this.log.info(TAG, `User lying down at ${hour}:xx, treating as nap/rest - skip sedentary reminder`);
        return;
      }
    }

    // 用户坐着/站着，触发久坐提醒
    this.log.info(TAG, `Sedentary reminder triggered: sitting for ${durationMinutes} minutes`);
    this.showSedentaryReminderCard(durationMinutes);
  }

  /**
   * 显示久坐提醒卡片
   */
  private showSedentaryReminderCard(durationMinutes: number): void {
    let a2uiJsonl = '{"type":"card","id":"sedentary_reminder_' + Date.now() + '","children":[' +
      '{"type":"text","text":"🧘 起来活动一下","style":{"fontSize":18,"fontWeight":"bold"}},' +
      '{"type":"text","text":"已经坐了 ' + durationMinutes + ' 分钟","style":{"fontSize":14,"color":"#888"}},' +
      '{"type":"text","text":"站起来走动5分钟，做做伸展","style":{"fontSize":13,"color":"#666"}},' +
      '{"type":"button","text":"好的","variant":"primary","action":{"event":{"name":"sedentary_reminder_ok"}}},' +
      '{"type":"button","text":"稍后提醒","variant":"borderless","action":{"event":{"name":"sedentary_reminder_snooze"}}}' +
      ']}';

    // 使用 NodeRuntime 发送 A2UI 卡片
    let global = globalThis as GlobalWithRuntime;
    if (global.nodeRuntime?.dispatchA2UI) {
      global.nodeRuntime.dispatchA2UI('push', a2uiJsonl);
      this.log.info(TAG, `Sedentary reminder card sent (${durationMinutes} min)`);
    } else {
      this.log.warn(TAG, 'NodeRuntime not available for sedentary reminder card');
    }
  }

  /**
   * 根据运动状态调整所有传感器采样间隔 (多级采集)
   * pickup 状态将 GPS 降到静止频率以节省功耗
   */
  private adjustLocationInterval(state: MotionState): void {
    let newGpsInterval: number;
    let newWifiInterval: number;
    let newAccelInterval: number;

    switch (state) {
      case 'stationary':
        newGpsInterval = ContextAwarenessService.GPS_STATIONARY;
        newWifiInterval = ContextAwarenessService.WIFI_STATIONARY;
        newAccelInterval = ContextAwarenessService.ACCEL_STATIONARY;
        break;
      case 'walking':
        newGpsInterval = ContextAwarenessService.GPS_WALKING;
        newWifiInterval = ContextAwarenessService.WIFI_WALKING;
        newAccelInterval = ContextAwarenessService.ACCEL_WALKING;
        break;
      case 'running':
        newGpsInterval = ContextAwarenessService.GPS_RUNNING;
        newWifiInterval = ContextAwarenessService.WIFI_RUNNING;
        newAccelInterval = ContextAwarenessService.ACCEL_RUNNING;
        break;
      case 'driving':
        newGpsInterval = ContextAwarenessService.GPS_DRIVING;
        newWifiInterval = ContextAwarenessService.WIFI_DRIVING;
        newAccelInterval = ContextAwarenessService.ACCEL_DRIVING;
        break;
      case 'transit':
        // 乘车的GPS频率应该和驾车类似（乘客也在运动中）
        newGpsInterval = ContextAwarenessService.GPS_DRIVING;
        newWifiInterval = ContextAwarenessService.WIFI_DRIVING;
        newAccelInterval = ContextAwarenessService.ACCEL_DRIVING;
        break;
      default:
        newGpsInterval = ContextAwarenessService.GPS_UNKNOWN;
        newWifiInterval = ContextAwarenessService.WIFI_UNKNOWN;
        newAccelInterval = ContextAwarenessService.ACCEL_UNKNOWN;
    }
    
    // T2+ 模式下保持高频 GPS（不降低到静止频率），确保新地点检测不被阻断
    if (this.currentTier >= 2 && newGpsInterval > ContextAwarenessService.GPS_WALKING) {
      newGpsInterval = ContextAwarenessService.GPS_WALKING;
    }

    // 调整GPS采集
    if (newGpsInterval !== this.locationIntervalMs) {
      this.locationIntervalMs = newGpsInterval;
      this.log.info(TAG, `GPS interval: ${newGpsInterval / 1000}s for ${state} (tier=T${this.currentTier})`);
      this.restartLocationTimer();
    }
    
    // 调整WiFi扫描
    if (newWifiInterval !== this.wifiIntervalMs) {
      this.wifiIntervalMs = newWifiInterval;
      this.log.info(TAG, `WiFi interval: ${newWifiInterval / 1000}s for ${state}`);
      this.restartWifiTimer();
    }
    
    // 调整加速度计
    if (newAccelInterval !== this.accelIntervalNs) {
      this.accelIntervalNs = newAccelInterval;
      this.log.info(TAG, `Accel interval: ${newAccelInterval / 1000000}ms for ${state}`);
      this.restartAccelerometer();
    }
  }

  /**
   * 启动智能位置获取定时器
   */
  private startSmartLocationTimer(): void {
    if (this.locationTimer !== -1) return;
    
    this.locationTimer = setInterval(() => {
      this.fetchSingleLocation();
    }, this.locationIntervalMs);
    
    this.log.info(TAG, `GPS timer started: ${this.locationIntervalMs / 1000}s`);
    this.fetchSingleLocation();
  }

  private stopSmartLocationTimer(): void {
    if (this.locationTimer !== -1) {
      clearInterval(this.locationTimer);
      this.locationTimer = -1;
    }
  }

  private restartLocationTimer(): void {
    this.stopSmartLocationTimer();
    if (this.locationIntervalMs > 0) {
      this.startSmartLocationTimer();
    }
  }

  /**
   * WiFi扫描定时器 (多级采集)
   */
  private startWifiTimer(): void {
    if (this.wifiTimer !== -1 || this.wifiIntervalMs === 0) return;
    
    this.wifiTimer = setInterval(() => {
      this.scanWifi();
    }, this.wifiIntervalMs);
    
    this.log.info(TAG, `WiFi timer started: ${this.wifiIntervalMs / 1000}s`);
    this.scanWifi();
  }

  private stopWifiTimer(): void {
    if (this.wifiTimer !== -1) {
      clearInterval(this.wifiTimer);
      this.wifiTimer = -1;
    }
  }

  private restartWifiTimer(): void {
    this.stopWifiTimer();
    if (this.wifiIntervalMs > 0) {
      this.startWifiTimer();
    }
  }

  private scanWifi(): void {
    try {
      wifiManager.getLinkedInfo().then((info) => {
        let ssid = info.ssid ?? '';
        // 去引号（部分系统返回 "SSID" 带引号）
        if (ssid.startsWith('"') && ssid.endsWith('"')) {
          ssid = ssid.substring(1, ssid.length - 1);
        }
        this.recordedPut('wifiSsid', ssid, 0.9, 'wifi');
        
        if (ssid !== this.lastWifiSsid) {
          let oldSsid = this.lastWifiSsid;
          this.log.info(TAG, `WiFi change detected: "${oldSsid}" -> "${ssid}"`);
          this.lastWifiSsid = ssid;
          this.engine.pushEvent('wifi_change');


          // 触发连接/断开回调
          if (ssid.length > 0 && oldSsid !== ssid) {
            this.onWifiConnected();
          } else if (ssid.length === 0 && oldSsid.length > 0) {
            this.onWifiDisconnected();
          }
        } else {
          this.lastWifiSsid = ssid;
        }
      }).catch(() => {});
    } catch {
      // ignore
    }
  }

  /**
   * 重启加速度计 (多级采集)
   */
  private restartAccelerometer(): void {
    try {
      sensor.off(sensor.SensorId.ACCELEROMETER);
    } catch {
      // ignore
    }
    try {
      sensor.on(sensor.SensorId.ACCELEROMETER, (data: sensor.AccelerometerResponse) => {
        this.accelerometerData = { x: data.x, y: data.y, z: data.z, timestamp: Date.now() };
        this.recordAccelSample();
        this.updateMotionState();
      }, { interval: this.accelIntervalNs });
    } catch (err) {
      this.log.warn(TAG, `Accelerometer restart failed: ${(err as Error).message}`);
    }
  }

  /**
   * 获取单次位置并处理
   * GPS 跳过策略：
   *   1. 静止 + 已知围栏 → 跳过（室内不需要 GPS）
   *   2. 运动中但围栏 WiFi 仍连接 → 跳过（还在围栏范围内）
   *   3. WiFi 断开后 → 正常按间隔获取 GPS（室外模式）
   */
  private async fetchSingleLocation(): Promise<void> {
    try {
      // 先获取WiFi信息
      this.refreshWifiSync();

      // 检查是否仍在已知围栏内（WiFi 连接 = 仍在围栏覆盖范围）
      let geofenceSlot = this.tray.get('geofence');
      let inKnownGeofence = geofenceSlot !== undefined && geofenceSlot !== null
        && geofenceSlot.value !== null && geofenceSlot.value.length > 0;
      let wifiGeofenceSlot = this.tray.get('wifiGeofence');
      let wifiMatchesGeofence = wifiGeofenceSlot !== undefined && wifiGeofenceSlot !== null
        && wifiGeofenceSlot.value !== null && wifiGeofenceSlot.value.length > 0;

      // 围栏 WiFi 仍连接 → 用户还在围栏内，跳过 GPS（无论是静止还是走路）
      if (inKnownGeofence && wifiMatchesGeofence && this.lastLocation) {
        this.log.debug(TAG, 'Skip GPS: geofence WiFi still connected');
        // 清除过期速度，防止驾车状态因旧速度残留而"卡住"
        this.lastLocation.speed = 0;
        return;
      }

      // 静止 + 已知围栏（无 WiFi 但 GPS 已确认在围栏内）→ 跳过
      if (this.lastMotionState === 'stationary' && inKnownGeofence && this.lastLocation) {
        this.log.debug(TAG, 'Skip GPS: stationary in known geofence');
        this.lastLocation.speed = 0;
        return;
      }

      // 静止 + 环境信号未变 → 跳过
      if (this.lastMotionState === 'stationary') {
        let envChanged = await this.checkEnvironmentChanged();
        if (!envChanged && this.lastLocation) {
          this.log.debug(TAG, 'Skip GPS: stationary, environment unchanged');
          this.lastLocation.speed = 0;
          this.checkForNewPlaceSmart(this.lastLocation.latitude, this.lastLocation.longitude);
          return;
        }
      }

      // 环境变化或不在静止状态，请求GPS
      let request: geoLocationManager.CurrentLocationRequest = {
        priority: geoLocationManager.LocationRequestPriority.FIRST_FIX,
        scenario: geoLocationManager.LocationRequestScenario.UNSET,
        maxAccuracy: 100,
      };
      
      let location = await geoLocationManager.getCurrentLocation(request);
      if (location) {
        this.handleLocationUpdate(location);
      }
    } catch (err) {
      this.log.warn(TAG, `Location fetch failed: ${(err as Error).message}`);
    }
  }

  /**
   * 同步获取WiFi信息
   */
  private refreshWifiSync(): void {
    try {
      wifiManager.getLinkedInfo().then((info) => {
        let ssid = info.ssid ?? '';
        if (ssid.startsWith('"') && ssid.endsWith('"')) {
          ssid = ssid.substring(1, ssid.length - 1);
        }
        this.recordedPut('wifiSsid', ssid, 0.9, 'wifi');
        if (ssid !== this.lastWifiSsid) {
          let oldSsid = this.lastWifiSsid;
          this.log.info(TAG, `WiFi(sync): ${oldSsid} -> ${ssid}`);
          this.lastWifiSsid = ssid;
          this.engine.pushEvent('wifi_change');
          if (ssid.length > 0 && oldSsid !== ssid) {
            this.onWifiConnected();
          } else if (ssid.length === 0 && oldSsid.length > 0) {
            this.onWifiDisconnected();
          }
        }
      }).catch(() => {});
    } catch {
      // ignore
    }
  }

  /**
   * 异步获取WiFi信息
   */
  private async refreshWifiAsync(): Promise<void> {
    try {
      let info = await wifiManager.getLinkedInfo();
      let ssid = info.ssid ?? '';
      if (ssid.startsWith('"') && ssid.endsWith('"')) {
        ssid = ssid.substring(1, ssid.length - 1);
      }
      this.recordedPut('wifiSsid', ssid, 0.9, 'wifi');
      if (ssid !== this.lastWifiSsid) {
        let oldSsid = this.lastWifiSsid;
        this.log.info(TAG, `WiFi(async): ${oldSsid} -> ${ssid}`);
        this.lastWifiSsid = ssid;
        this.engine.pushEvent('wifi_change');
        if (ssid.length > 0 && oldSsid !== ssid) {
          this.onWifiConnected();
        } else if (ssid.length === 0 && oldSsid.length > 0) {
          this.onWifiDisconnected();
        }
      }
    } catch {
      // ignore
    }
  }

  /**
   * 处理位置更新
   */
  private handleLocationUpdate(location: geoLocationManager.Location): void {
    if (this.isReplaying) return;  // 回放中不更新真实位置
    let lat = location.latitude;
    let lng = location.longitude;
    let speed = location.speed ?? 0;
    let accuracy = location.accuracy ?? 100;
    
    // 更新数据托盘
    this.recordedPut('latitude', lat.toFixed(6), 1.0, 'gps');
    this.recordedPut('longitude', lng.toFixed(6), 1.0, 'gps');
    this.recordedPut('locationAccuracy', accuracy.toFixed(0), 0.8, 'gps');
    
    // 检查围栏
    let locState: LocationState = {
      latitude: lat,
      longitude: lng,
      speed: speed,
      accuracy: accuracy,
      timestamp: Date.now(),
      insideGeofences: []
    };
    this.geofenceMgr.updateLocation(locState);
    this.lastLocation = locState;
    
    this.log.debug(TAG, `Location update: (${lat.toFixed(4)}, ${lng.toFixed(4)}) speed=${speed.toFixed(1)}m/s wifi=${this.lastWifiSsid}`);
    
    // 检查新地点（停留5分钟+WiFi）- 异步执行
    this.checkForNewPlaceSmart(lat, lng);
  }

  /**
   * 检查环境信号是否有变化 (用于决定是否需要请求GPS)
   *
   * CellID 不可用 (GET_TELEPHONY_STATE 是 system_basic 权限)。
   * 替代策略：WiFi SSID 变化 + BT 设备变化 + WiFi 断连 作为位置变化信号。
   *
   * @return true=环境变化需要GPS, false=环境不变可跳过GPS
   */
  private async checkEnvironmentChanged(): Promise<boolean> {
    // --- WiFi SSID 变化检测 ---
    if (this.lastWifiSsid.length > 0 && this.lastLocation) {
      if (this.lastStationaryWifiSsid.length > 0 && this.lastWifiSsid !== this.lastStationaryWifiSsid) {
        this.log.info(TAG, `WiFi SSID changed: ${this.lastStationaryWifiSsid} -> ${this.lastWifiSsid}, requesting GPS`);
        this.lastStationaryWifiSsid = this.lastWifiSsid;
        return true;
      }
      this.lastStationaryWifiSsid = this.lastWifiSsid;
    } else if (this.lastStationaryWifiSsid.length > 0 && this.lastWifiSsid.length === 0) {
      // WiFi disconnected → likely moving
      this.log.info(TAG, 'WiFi disconnected, likely moving → request GPS');
      this.lastStationaryWifiSsid = '';
      return true;
    }

    // --- BT 设备变化检测 ---
    try {
      let btSlot = this.tray.get('bt_fixed_devices');
      let currentBt = btSlot?.value ?? '';
      if (this.lastCellId.length > 0 && currentBt !== this.lastCellId) {
        // Reuse lastCellId field to track BT fingerprint (CellID never used)
        this.log.info(TAG, `BT devices changed: "${this.lastCellId}" -> "${currentBt}", requesting GPS`);
        this.lastCellId = currentBt;
        this.lastCellIdTime = Date.now();
        return true;
      }
      if (this.lastCellId.length === 0 && currentBt.length > 0) {
        this.lastCellId = currentBt;  // First observation
      }
    } catch { /* ignore */ }

    // WiFi available and stable → no GPS needed
    if (this.lastWifiSsid.length > 0) {
      return false;
    }

    // No WiFi at all → conservative, request GPS
    return true;
  }
  private startPeriodicEvaluation(): void {
    if (this.evaluationTimer !== -1) return;
    this.evaluationTimer = setInterval(() => {
      this.periodicEvaluate();
    }, ContextAwarenessService.EVALUATION_INTERVAL_MS);
    this.log.info(TAG, 'Started periodic evaluation');
  }

  private stopPeriodicEvaluation(): void {
    if (this.evaluationTimer !== -1) {
      clearInterval(this.evaluationTimer);
      this.evaluationTimer = -1;
      this.log.info(TAG, 'Stopped periodic evaluation');
    }
  }

  private async periodicEvaluate(): Promise<void> {
    if (!this.isRunning || this.isReplaying) return;  // 回放中暂停周期评估
    // Refresh tray with latest sensor data, then read snapshot from tray
    await this.refreshTray();

    // Inject travel data (flight countdown, arrival, etc.)
    await this.injectTravelData();

    // Evaluate sensor tier escalation/de-escalation
    this.evaluateTierEscalation();

    // Detect BT device changes and track connections
    this.detectBtChangesAndTrackConnections();

    // ==================== 7-Tuple 物理状态 & 场景匹配 ====================
    this.buildPhysicalStateAndDetectChange();

    let snapshot = this.augmentSnapshot(this.tray.getSnapshot());
    await this.evaluateAndDeliver(snapshot);

    // Periodically save connection records (every evaluation cycle)
    this.saveConnectionRecords();
  }

  /** 注入航班数据到 DataTray */
  private async injectTravelData(): Promise<void> {
    try {
      let flights = await this.travelInfoSvc.getTodayFlights();
      let trains = await this.travelInfoSvc.getTodayTrains();
      this.log.info(TAG, `[Travel] flights=${flights.length}, trains=${trains.length}`);
      if (flights.length > 0) {
        let next = flights[0];
        let countdownMin = Math.floor((next.departureTime - Date.now()) / 60000);
        this.log.info(TAG, `[Travel] next flight: ${next.flightNumber} ${next.departure}→${next.arrival} countdown=${countdownMin}min`);
        this.recordedPut('flightCountdownMin', countdownMin.toString(), 1.0, 'travel');
        this.recordedPut('flightNumber', next.flightNumber, 1.0, 'travel');
        this.recordedPut('hasUpcomingFlight', 'true', 1.0, 'travel');
        if (next.calendarEndTime !== undefined) {
          let arrivalMin = Math.floor((next.calendarEndTime - Date.now()) / 60000);
          this.recordedPut('flightArrivalMin', arrivalMin.toString(), 1.0, 'travel');
        }
      } else if (trains.length > 0) {
        let next = trains[0];
        let countdownMin = Math.floor((next.departureTime - Date.now()) / 60000);
        this.log.info(TAG, `[Travel] next train: ${next.trainNumber} ${next.departure}→${next.arrival} countdown=${countdownMin}min`);
        this.recordedPut('flightCountdownMin', countdownMin.toString(), 1.0, 'travel');
        this.recordedPut('flightNumber', next.trainNumber, 1.0, 'travel');
        this.recordedPut('hasUpcomingFlight', 'true', 1.0, 'travel');
        if (next.calendarEndTime !== undefined) {
          let arrivalMin = Math.floor((next.calendarEndTime - Date.now()) / 60000);
          this.recordedPut('flightArrivalMin', arrivalMin.toString(), 1.0, 'travel');
        }
      } else {
        this.recordedPut('hasUpcomingFlight', 'false', 1.0, 'travel');
        // 设置大值使航班相关规则不匹配（无 remove 方法，用 99999 表示"无航班"）
        this.recordedPut('flightCountdownMin', '99999', 0.0, 'travel');
        this.recordedPut('flightArrivalMin', '99999', 0.0, 'travel');
      }
    } catch (err) {
      this.log.warn(TAG, `injectTravelData failed: ${(err as Error).message}`);
    }
  }


  /** 获取位置发现建议 (stub — LocationDiscovery removed) */
  getLocationSuggestions(): GeofenceSuggestion[] {
    return [];
  }

  /** 获取位置发现统计 (stub — LocationDiscovery removed) */
  getLocationDiscoveryStats(): DiscoveryStatsInfo {
    return { historyCount: 0, clusterCount: 0, lastDiscovery: '' };
  }

  
  /**
   * 刷新托盘：将所有可轮询的传感器数据写入托盘
   * 事件驱动的数据（加速度计、围栏）由回调直接写入。
   */
  private async refreshTray(): Promise<void> {
    let now = new Date();
    let hour = now.getHours();

    // 时间（实时计算，TTL=∞）
    let timeOfDay: TimeOfDay;
    if (hour >= 5 && hour < 12) timeOfDay = 'morning';
    else if (hour >= 12 && hour < 17) timeOfDay = 'afternoon';
    else if (hour >= 17 && hour < 21) timeOfDay = 'evening';
    else timeOfDay = 'night';

    let dayOfWeek = now.getDay();
    let isWeekend = dayOfWeek === 0 || dayOfWeek === 6;

    this.recordedPut('hour', hour.toString(), 1.0, 'system');
    this.recordedPut('timeOfDay', timeOfDay, 1.0, 'system');
    this.recordedPut('dayOfWeek', dayOfWeek.toString(), 1.0, 'system');
    this.recordedPut('isWeekend', isWeekend ? 'true' : 'false', 1.0, 'system');

    // 电池
    try {
      this.recordedPut('batteryLevel', batteryInfo.batterySOC.toString(), 1.0, 'battery');
      let charging = batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.ENABLE;
      this.recordedPut('isCharging', charging ? 'true' : 'false', 1.0, 'battery');
    } catch {
      // ignore
    }

    // 网络 + WiFi SSID
    try {
      if (wifiManager.isWifiActive()) {
        this.recordedPut('networkType', 'wifi', 1.0, 'wifi');
        try {
          let info = await wifiManager.getLinkedInfo();
          let ssid = info.ssid || '';
          if (ssid.startsWith('"') && ssid.endsWith('"')) {
            ssid = ssid.substring(1, ssid.length - 1);
          }
          if (ssid.length > 0) {
            this.recordedPut('wifiSsid', ssid, 1.0, 'wifi');
            this.lastWifiSsid = ssid;
          }
        } catch { /* ignore */ }
      } else {
        this.recordedPut('networkType', 'cellular', 0.8, 'network');
      }
    } catch {
      // ignore
    }
    
    // WiFi丢失标记（遍历所有类别，有效期内）
    let nowMs = Date.now();
    this.wifiLostTimestamps.forEach((ts: number, category: string) => {
      if (nowMs - ts < ContextAwarenessService.WIFI_LOST_TTL_MS) {
        this.recordedPut('wifiLost', 'true', 0.8, 'wifi');
        this.recordedPut('wifiLostCategory', category, 0.8, 'wifi');
        // 向后兼容
        if (category === 'work') {
          this.recordedPut('wifiLostWork', 'true', 0.8, 'wifi');
        }
      }
    });

    // 位置 / 围栏
    if (this.lastLocation) {
      this.recordedPut('latitude', this.lastLocation.latitude.toString(), 1.0, 'gps');
      this.recordedPut('longitude', this.lastLocation.longitude.toString(), 1.0, 'gps');

      // 围栏离开冷却期内：跳过GPS围栏重匹配，防止旧坐标重新匹配到刚离开的围栏
      let inDepartureCooldown = this.geofenceDepartureTime > 0
        && (Date.now() - this.geofenceDepartureTime < ContextAwarenessService.GEOFENCE_DEPARTURE_COOLDOWN_MS);

      if (!inDepartureCooldown) {
        let geofences = this.geofenceMgr.getGeofencesAtLocation(
          this.lastLocation.latitude,
          this.lastLocation.longitude
        );
        if (geofences.length > 0) {
          this.recordedPut('geofence', geofences[0].id, 1.0, 'geofence');
          // GPS 确认围栏：写入独立字段供 PhysicalStateBuilder 使用（不写 wifiGeofence，避免污染 WiFi guard）
          this.recordedPut('geofenceCategory', geofences[0].category, 0.8, 'geofence');
        } else {
          // 不在任何围栏内，清除旧值（防止新地点检测被 T1 skip 阻断）
          this.recordedPut('geofence', '', 0, 'geofence');
          this.recordedPut('geofenceCategory', '', 0, 'geofence');
        }
      }
    }

    // 步数：由 StepCounterPlugin 通过插件路径写入（step_count_today）
    // 备用：如果插件步数为0但CAS计步器有数据，使用CAS数据
    if (this.stepCountBaseline >= 0 && this.stepCount > 0) {
      let casDaily = this.stepCount - this.stepCountBaseline;
      if (casDaily < 0) {
        this.stepCountBaseline = this.stepCount;
        casDaily = 0;
      }
      let traySteps = this.tray.get('step_count_today');
      if (!traySteps || traySteps.value === '0' || traySteps.value === '') {
        this.recordedPut('step_count_today', casDaily.toString(), 0.8, 'pedometer');
      }
    }

    // 运动状态（加速度计回调已写入，这里确保有值）
    if (this.lastMotionState !== 'unknown') {
      this.recordedPut('motionState', this.lastMotionState, 0.9, 'accelerometer');
    }
    // 手握状态由 updateHoldingState() 更新，不在此处重复写入

    // 每日行程时间线：推送当前地点+运动状态
    this.pushTimelineEvent();

    // Sensor tier
    this.recordedPut('sensorTier', this.currentTier.toString(), 1.0, 'system');

    // BT 环境指纹 (替代不可用的 CellID)
    if (this.lastCellId.length > 0) {
      this.recordedPut('btFingerprint', this.lastCellId, 0.8, 'bluetooth');
    }

    // 插件数据 → 托盘（按物理/数字世界分类）
    // 物理世界插件：传感器类（bluetooth, wearable, audio, media, posture, screen, stepCounter）
    // 数字世界插件：应用/信息类（calendar, appUsage, foregroundApp, notification）
    let pluginSkip: string[] = [
      'wifi_ssid', 'wifi_connected', 'wifi_rssi', 'wifi_frequency',  // 已有 wifiSsid / networkType
      'step_count', 'is_active',                                      // 已有 stepCount / motionState
      'screen_on', 'screen_locked', 'user_active',                   // 内部状态
      'init_error', 'data_source', 'device_name', 'device_connected' // 元数据噪声
    ];
    // 💻 数字世界: 软件层/应用数据
    let digitalPluginNames: string[] = ['calendar', 'appUsage', 'foregroundApp', 'notification', 'media'];
    // 🧑 人: wearable, stepCounter → person
    // 📱 手机: screen, posture → phone
    // 🌍 环境: bluetooth, wifi, ambientSound → environment
    let physicalSourceMap: Record<string, string> = {
      'bluetooth': 'bluetooth', 'wearable': 'wearable', 'ambientSound': 'audio',
      'posture': 'phone', 'screen': 'phone', 'stepCounter': 'pedometer',
      'wifi': 'wifi'
    };
    let pluginStatuses = this.digitalWorld.getPluginStatus();
    for (let i = 0; i < pluginStatuses.length; i++) {
      let ps = pluginStatuses[i];
      if (!ps.enabled || !ps.hasData) continue;
      let snapshot = this.digitalWorld.getPluginSnapshot(ps.name);
      if (!snapshot) continue;
      let isDigital = digitalPluginNames.includes(ps.name);
      let source = isDigital ? 'digital' : (physicalSourceMap[ps.name] ?? ps.name);
      let keys = Object.keys(snapshot.data);
      for (let j = 0; j < keys.length; j++) {
        let k = keys[j];
        let v = snapshot.data[k];
        if (v.length > 0 && !pluginSkip.includes(k)) {
          this.recordedPut(k, v, 0.8, source);
        }
      }
    }
    // 保留 lastDigitalData 供兼容
    this.lastDigitalData = this.digitalWorld.getDigitalData();
  }

  /**
   * 获取当前完整的环境上下文
   * 保留供反馈路径和兼容旧 API 使用。内部同时刷新托盘。
   */
  async getCurrentContext(): Promise<EnvironmentContext> {
    // 刷新托盘（所有传感器数据写入）
    await this.refreshTray();

    let now = new Date();
    let hour = now.getHours();

    let timeOfDay: TimeOfDay;
    if (hour >= 5 && hour < 12) timeOfDay = 'morning';
    else if (hour >= 12 && hour < 17) timeOfDay = 'afternoon';
    else if (hour >= 17 && hour < 21) timeOfDay = 'evening';
    else timeOfDay = 'night';

    let dayOfWeek = now.getDay();
    let isWeekend = dayOfWeek === 0 || dayOfWeek === 6;

    // 设备状态
    let batteryLevel = 100;
    let isCharging = false;
    try {
      batteryLevel = batteryInfo.batterySOC;
      isCharging = batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.ENABLE;
    } catch {
      // ignore
    }

    // 网络状态
    let networkType: NetworkType = 'none';
    try {
      if (wifiManager.isWifiActive()) {
        networkType = 'wifi';
      } else {
        networkType = 'cellular';
      }
    } catch {
      // ignore
    }
    
    // 当前围栏（多源融合）

    // 当前围栏
    let currentGeofence: Geofence | undefined;
    let allGeofences = this.geofenceMgr.getAllGeofences();
    let fusionResult = await this.locationFusion.getBestMatch(allGeofences, this.lastLocation);
    if (fusionResult) {
      currentGeofence = this.geofenceMgr.getGeofence(fusionResult.geofenceId);
      this.log.debug(TAG,
        `Fused location: ${fusionResult.geofenceId} conf=${fusionResult.confidence.toFixed(2)} src=${fusionResult.source}`);
    } else if (this.lastLocation) {
      // 降级：融合无结果时用原始 GPS
      let gpsGeofences = this.geofenceMgr.getGeofencesAtLocation(
        this.lastLocation.latitude,
        this.lastLocation.longitude
      );
      currentGeofence = gpsGeofences[0];
    }

    let ctx: EnvironmentContext = {
      timestamp: Date.now(),
      location: this.lastLocation,
      currentGeofence,
      motionState: this.lastMotionState,
      stepCount: this.stepCount,
      timeOfDay,
      dayOfWeek,
      isWeekend,
      batteryLevel,
      isCharging,
      networkType,
      screenOn: true,
    };

    this.currentContext = ctx;
    return ctx;
  }

  /**
   * 构建 C++ 规则引擎需要的快照格式
   *
   * TODO [Digital World Integration Point]:
   * Digital world data from DigitalWorldService is merged into the snapshot here.
   * The C++ engine's ContextSnapshot currently uses a fixed set of keys (timeOfDay,
   * hour, motionState, etc.), but the evaluate() method passes JSON so additional
   * digital-world keys (cal_hasUpcoming, audio_inCall, screen_locked, etc.) can be
   * matched by rules that reference these keys. New rules can use conditions like:
   *   { key: 'cal_inMeeting', op: 'eq', value: 'true' }
   *   { key: 'audio_inCall', op: 'eq', value: 'true' }
   *   { key: 'screen_locked', op: 'eq', value: 'true' }
   *
   * To fully wire this up:
   * 1. Extend ContextSnapshot interface in ContextEngine.ets with optional digital fields
   * 2. Add built-in rules that reference digital-world keys
   * 3. Connect DigitalWorldService lifecycle to this service (done — see init/start/stop)
   */
  private buildSnapshot(ctx: EnvironmentContext): ContextSnapshot {
    let now = new Date();
    let hour = now.getHours();
    let dayOfWeek = now.getDay();

    // 计算活动持续时间
    let activityDuration = 0;
    if (this.activityStateTimestamp > 0) {
      activityDuration = Math.floor((Date.now() - this.activityStateTimestamp) / 1000);
    }

    let snapshot: ContextSnapshot = {
      timeOfDay: ctx.timeOfDay,
      hour: hour.toString(),
      dayOfWeek: dayOfWeek.toString(),
      isWeekend: ctx.isWeekend ? 'true' : 'false',
      motionState: ctx.motionState || 'unknown',
      batteryLevel: ctx.batteryLevel.toString(),
      isCharging: ctx.isCharging ? 'true' : 'false',
      networkType: ctx.networkType || 'none',
      geofence: ctx.currentGeofence?.id,
      latitude: ctx.location?.latitude?.toString(),
      longitude: ctx.location?.longitude?.toString(),
      stepCount: ctx.stepCount?.toString(),
      isSleeping: this.detectSleepingState(ctx, hour),
      // 状态历史
      prevMotionState: this.prevMotionState,
      prevActivityState: this.prevActivityState,
      activityDuration: activityDuration.toString(),
      activityState: this.activityState
    };

    // Merge digital world plugin data into snapshot for rule evaluation
    // Digital data is merged via JSON since ContextSnapshot has fixed keys
    let digitalData = this.digitalWorld.getDigitalData();
    this.lastDigitalData = digitalData;

    return snapshot;
  }

  /**
   * 评估并推送推荐，无匹配时调用 LLM 兜底
   * 评估并推送推荐
   */
  private async evaluateAndDeliver(snapshot: ContextSnapshot): Promise<void> {
    let results = this.engine.evaluate(snapshot, 3);
    this.log.info(TAG, `[Explore-DBG] evaluateAndDeliver called: exploreMode=${this.exploreMode}, engineMatches=${results.length}, tod=${snapshot.timeOfDay}, motion=${snapshot.motionState}, geofence=${snapshot.geofence ?? 'none'}, wifi=${snapshot.wifiSsid ?? ''}`);

    // 积极探索模式：新/过期指纹 或 WiFi/BT 变化 → 强制触发 LLM
    let exploreTriggered = false;
    if (this.exploreMode) {
      let fp = this.computeFingerprint(snapshot);
      let now = Date.now();

      // 清理过期指纹
      let expiredCount = 0;
      let keysToRemove: string[] = [];
      this.exploredFingerprints.forEach((ts: number, key: string) => {
        if (now - ts > ContextAwarenessService.FINGERPRINT_EXPIRY_MS) {
          keysToRemove.push(key);
        }
      });
      for (let k of keysToRemove) {
        this.exploredFingerprints.delete(k);
        expiredCount++;
      }
      if (expiredCount > 0) {
        this.log.info(TAG, `[Explore-DBG] expired ${expiredCount} fingerprints`);
      }

      let lastTs = this.exploredFingerprints.get(fp);
      let isNew = lastTs === undefined;
      let isExpired = !isNew && (now - (lastTs as number) > ContextAwarenessService.FINGERPRINT_EXPIRY_MS);

      // 检测 WiFi/BT 变化
      let currentWifi = snapshot.wifiSsid || '';
      let btSlot = this.tray.get('bt_device_names');
      let currentBt = (btSlot && btSlot.value) ? btSlot.value : '';
      let wifiChanged = currentWifi.length > 0 && currentWifi !== this.lastExploreWifiSsid;
      let btChanged = currentBt.length > 0 && currentBt !== this.lastExploreBtDevices;

      this.log.info(TAG, `[Explore-DBG] fp="${fp}", isNew=${isNew}, isExpired=${isExpired}, wifiChanged=${wifiChanged}, btChanged=${btChanged}, total=${this.exploredFingerprints.size}`);

      if (isNew || isExpired || wifiChanged || btChanged) {
        this.exploredFingerprints.set(fp, now);
        this.saveExploredFingerprints();
        this.lastExploreWifiSsid = currentWifi;
        this.lastExploreBtDevices = currentBt;
        exploreTriggered = true;
        let reason = isNew ? 'new fingerprint' : isExpired ? 'expired fingerprint' : wifiChanged ? 'WiFi changed' : 'BT changed';
        this.log.info(TAG, `Explore mode: ${reason} "${fp}", will trigger LLM`);
      }
    }

    if (results.length > 0) {
      // 过滤掉 cooldown 中的规则，取 top 3
      let available: MatchResult[] = [];
      for (let i = 0; i < results.length; i++) {
        if (!this.isOnCooldown(results[i].ruleId)) {
          available.push(results[i]);
          if (available.length >= 3) break;
        }
      }

      this.log.info(TAG, `[Evaluate] ${results.length} matches, ${available.length} available (not on cooldown)`);

      if (available.length > 0) {
        // 构建包含所有可用匹配的推荐（top 1 为主推荐，其余作为备选）
        let top = available[0];
        let topUserAction = this.contextActionToUserAction(top.action, top.ruleId);
        let rec: ContextRecommendation = {
          rule: {
            id: top.ruleId,
            trigger: {} as RuleTrigger,
            action: topUserAction,
            confidence: top.confidence,
            triggerCount: 0,
            acceptCount: 0,
            createdAt: Date.now(),
            updatedAt: Date.now(),
            enabled: true
          },
          action: topUserAction,
          reason: `基于当前情景推荐 (${Math.round(top.confidence * 100)}% 匹配)`,
          snapshot: snapshot,
          alternatives: available  // 传递所有可用匹配
        };

        this.notifyRecommendation(rec);
        // 只对展示的规则设置 cooldown
        for (let i = 0; i < available.length; i++) {
          this.setOnCooldown(available[i].ruleId);
        }

        // 记录训练数据
        this.trainingSync.recordRuleMatch(snapshot, top.ruleId, top.action.type || 'suggestion', top.confidence);
      } else if (this.exploreMode) {
        this.log.info(TAG, `[Explore] all rules on cooldown, skipping`);
      }

      if (!exploreTriggered) return;
    } else if (this.exploreMode && !exploreTriggered) {
      this.log.info(TAG, `[Explore] no engine matches, skipping state display`);
      return;
    }

    // C++ engine returned no matches — LLM fallback disabled
    this.log.info(TAG, `No engine matches, LLM fallback disabled. exploreTriggered=${exploreTriggered}`);
  }

  private async checkForNewPlace(lat: number, lng: number, wifiSsid: string): Promise<void> {
    // 检查是否在任何已知围栏内
    let allGeofences = this.geofenceMgr.getAllGeofences();
    let inKnownGeofence = false;
    for (let i = 0; i < allGeofences.length; i++) {
      let gf = allGeofences[i];
      let dist = this.haversineDistance(lat, lng, gf.latitude, gf.longitude);
      if (dist < gf.radiusMeters) {
        inKnownGeofence = true;
        break;
      }
    }

    if (inKnownGeofence) {
      this.newPlaceDetectionStart = 0;
      return;
    }

    let now = Date.now();

    // 检查位置是否稳定
    if (this.newPlaceDetectionStart > 0) {
      let drift = this.haversineDistance(lat, lng, this.newPlaceLastLat, this.newPlaceLastLng);
      let sameWifi = wifiSsid.length > 0 && wifiSsid === this.newPlaceWifiSsid;
      let maxDrift = sameWifi ? 300 : ContextAwarenessService.NEW_PLACE_MAX_DRIFT_M;
      if (drift > maxDrift) {
        this.log.info(TAG, `New place reset: drifted ${Math.round(drift)}m > ${maxDrift}m (sameWifi=${sameWifi})`);
        this.newPlaceDetectionStart = 0;
      }
    }

    if (this.newPlaceDetectionStart === 0) {
      this.newPlaceDetectionStart = now;
      this.newPlaceLastLat = lat;
      this.newPlaceLastLng = lng;
      this.newPlaceWifiSsid = wifiSsid;
      this.log.info(TAG, `New place detection started at (${lat.toFixed(4)}, ${lng.toFixed(4)}) wifi=${wifiSsid}`);
      return;
    }

    let stableMs = now - this.newPlaceDetectionStart;
    if (stableMs < ContextAwarenessService.NEW_PLACE_STABLE_MS) {
      this.log.info(TAG, `New place stable for ${Math.round(stableMs / 1000)}s/${ContextAwarenessService.NEW_PLACE_STABLE_MS / 1000}s wifi=${wifiSsid} tier=T${this.currentTier}`);
      return;
    }

    this.log.info(TAG, `New place detected! (${lat.toFixed(4)}, ${lng.toFixed(4)}) WiFi=${wifiSsid}`);
    this.newPlaceDetectionStart = 0;

    // 优先用 OSM Nominatim 获取 POI 名称和类别
    let geoResult = await GeoCodingService.getInstance().reverseGeocode(lat, lng);
    let placeName = '';
    let geoCategory = '';
    if (geoResult.success && geoResult.name && geoResult.name.length > 0) {
      placeName = geoResult.name;
      geoCategory = geoResult.category ?? '';
    } else {
      placeName = await this.reverseGeocode(lat, lng);
    }
    this.showNewPlaceCard(lat, lng, wifiSsid, placeName, geoCategory);
  }

  /**
   * 实时检测新地点（结合当前WiFi状态）
   * 停留5分钟+有WiFi连接 → 立即发现，不等聚类
   */
  private async checkForNewPlaceSmart(lat: number, lng: number): Promise<void> {
    try {
      // 同时学习当前围栏的特征（会先获取WiFi）
      await this.learnPlaceSignals(lat, lng);
    } catch (err) {
      this.log.warn(TAG, `learnPlaceSignals error: ${(err as Error).message}`);
    }

    try {
      // 检测新地点
      await this.checkForNewPlace(lat, lng, this.lastWifiSsid);
    } catch (err) {
      this.log.warn(TAG, `checkForNewPlace error: ${(err as Error).message}`);
    }
  }

  /**
   * 学习围栏特征信号：在围栏内时，记录WiFi/蓝牙等特征
   */
  private async learnPlaceSignals(lat: number, lng: number): Promise<void> {
    let allGeofences = this.geofenceMgr.getAllGeofences();
    
    // 如果WiFi信息为空，尝试同步获取
    if (!this.lastWifiSsid || this.lastWifiSsid.length === 0) {
      await this.refreshWifiAsync();
    }
    
    this.log.debug(TAG, `learnPlaceSignals: checking ${allGeofences.length} geofences, wifi=${this.lastWifiSsid}`);
    
    for (let i = 0; i < allGeofences.length; i++) {
      let gf = allGeofences[i];
      let dist = this.haversineDistance(lat, lng, gf.latitude, gf.longitude);
      
      if (dist < gf.radiusMeters) {
        this.log.info(TAG, `Inside geofence: ${gf.name}, dist=${Math.round(dist)}m, wifi=${this.lastWifiSsid}`);
        
        // 在此围栏内，学习信号
        let signals = gf.learnedSignals ?? {
          wifiSSIDs: [],
          bluetoothDevices: [],
          cellIds: [],
          typicalTimes: [],
          lastSeen: 0,
          visitCount: 0
        };
        
        let updated = false;
        
        // 学习WiFi SSID (只学习 fixed WiFi, 跳过 hotspot/public)
        if (this.lastWifiSsid && this.lastWifiSsid.length > 0) {
          let wifiMobility = this.classifyWifi(this.lastWifiSsid);
          if (wifiMobility === 'fixed') {
            if (!signals.wifiSSIDs!.includes(this.lastWifiSsid)) {
              signals.wifiSSIDs!.push(this.lastWifiSsid);
              this.log.info(TAG, `Learned WiFi for ${gf.name}: ${this.lastWifiSsid}`);
              this.notifyGeofenceFeatureLearned(gf.name, 'WiFi', this.lastWifiSsid);
              updated = true;
            }
          } else {
            this.log.debug(TAG, `${I18n.t(wifiMobility === 'hotspot' ? 'context.wifi.hotspot' : 'context.wifi.public')}: ${this.lastWifiSsid}`);
          }
        }

        // 学习蓝牙设备 (只学习 fixed 设备, 跳过 portable/vehicle)
        let btFixedSlot = this.tray.get('bt_fixed_devices');
        if (btFixedSlot && btFixedSlot.value && btFixedSlot.value.length > 0) {
          let btNames = btFixedSlot.value.split(', ');
          for (let b = 0; b < btNames.length; b++) {
            let btName = btNames[b].trim();
            if (btName.length > 0 && !signals.bluetoothDevices!.includes(btName)) {
              signals.bluetoothDevices!.push(btName);
              this.log.info(TAG, `Learned BT fixed for ${gf.name}: ${btName}`);
              this.notifyGeofenceFeatureLearned(gf.name, 'Bluetooth', btName);
              updated = true;
            }
          }
        }
        // Log vehicle/portable BT (not learned to geofence)
        let btVehicleSlot = this.tray.get('bt_vehicle_devices');
        if (btVehicleSlot && btVehicleSlot.value && btVehicleSlot.value.length > 0) {
          this.log.debug(TAG, `BT vehicle (skip geofence): ${btVehicleSlot.value}`);
        }
        let btPortableSlot = this.tray.get('bt_portable_devices');
        if (btPortableSlot && btPortableSlot.value && btPortableSlot.value.length > 0) {
          this.log.debug(TAG, `BT portable (skip): ${btPortableSlot.value}`);
        }

        // CellID 不可用，跳过（使用 WiFi/BT 替代）
        
        // 更新访问统计
        signals.visitCount = (signals.visitCount ?? 0) + 1;
        signals.lastSeen = Date.now();
        
        // 学习典型时间
        let hour = new Date().getHours();
        let timeRange = `${hour}:00-${hour + 1}:00`;
        if (!signals.typicalTimes!.some(t => t.start === timeRange)) {
          signals.typicalTimes!.push({ start: timeRange, end: `${hour + 1}:00` });
          if (signals.typicalTimes!.length > 5) {
            signals.typicalTimes!.shift();
          }
          updated = true;
        }
        
        // 保存更新
        if (updated || signals.visitCount === 1) {
          gf.learnedSignals = signals;
          this.geofenceMgr.saveToFile();
        }
        
        // 只处理第一个匹配的围栏
        break;
      }
    }
  }

  /**
   * 通知围栏学习到新特征
   */
  private notifyGeofenceFeatureLearned(geofenceName: string, featureType: string, featureValue: string): void {
    let titleText = I18n.t('context.geofence.learned');
    let wifiLabelText = I18n.t('context.geofence.newWifi');
    
    let jsonl = '{"type":"form","id":"gf_learn_' + Date.now() + '","children":[' +
      '{"type":"text","text":"🔗 ' + titleText + '","style":{"fontSize":16,"fontWeight":"bold"}},' +
      '{"type":"text","text":"' + geofenceName + '"},' +
      '{"type":"text","text":"' + wifiLabelText + ': ' + featureValue + '","style":{"fontSize":12,"color":"#666"}}' +
      ']}';
    
    this.dispatchA2UI('push', jsonl);
  }

  /**
   * 逆地理编码：坐标 → 地点名
   */
  private async reverseGeocode(lat: number, lng: number): Promise<string> {
    try {
      // 使用 HarmonyOS 逆地理编码 API
      let request: geoLocationManager.ReverseGeoCodeRequest = {
        latitude: lat,
        longitude: lng,
        maxItems: 1,
        locale: 'zh'
      };
      let results = await geoLocationManager.getAddressesFromLocation(request);
      if (results && results.length > 0) {
        let addr = results[0];
        // 优先使用地标名，其次街道地址
        let name = addr.placeName ?? addr.roadName ?? '';
        if (name.length === 0 && addr.locality) {
          name = addr.locality;
        }
        if (name.length > 0) {
          this.log.info(TAG, `Reverse geocode: ${name}`);
          return name;
        }
      }
    } catch (err) {
      this.log.warn(TAG, `Reverse geocode failed: ${(err as Error).message}`);
    }
    // 失败时用坐标生成名称
    return `新地点 (${lat.toFixed(3)}, ${lng.toFixed(3)})`;
  }

  /**
   * 显示新地点确认卡片
   */
  private showNewPlaceCard(lat: number, lng: number, wifiSsid: string, placeName: string, geoCategory: string = ''): void {
    let escapedName = placeName.replace(/"/g, "'");
    let escapedWifi = wifiSsid.replace(/"/g, "'");
    
    // 优先用 OSM 类别，fallback 到时间推断
    let category = geoCategory.length > 0 ? geoCategory : this.inferCategoryFromTime();
    
    // 自动保存地点（不需要用户确认），重复则跳过
    let saved = this.autoSaveNewPlace(lat, lng, wifiSsid, placeName, category);
    if (!saved) return;
    
    // 获取类别的中文显示名
    let categoryLabels: Record<string, string> = {
      'home': '🏠 家', 'work': '🏢 公司', 'restaurant': '🍽️ 餐饮',
      'shopping': '🛒 购物', 'gym': '💪 健身', 'transit': '🚉 交通',
      'hotel': '🏨 酒店', 'other': '📍 其他'
    };
    let categoryLabel = categoryLabels[category] ?? ('📍 ' + category);
    
    // 显示轻量通知卡片（点击可修改名称和类别）
    let jsonl = '{"type":"form","id":"new_place_' + Date.now() + '","children":[' +
      '{"type":"text","text":"📍 已记录新地点","style":{"fontSize":16,"fontWeight":"bold"}},' +
      '{"type":"text","text":"' + escapedName + ' (' + categoryLabel + ')","style":{"fontSize":14}},' +
      '{"type":"text","text":"WiFi: ' + escapedWifi + '","style":{"fontSize":12,"color":"#666"}},' +
      '{"type":"button","text":"✏️ 修改名称/类别","variant":"borderless","action":{"event":{"name":"new_place_edit","context":{"lat":' + lat + ',"lng":' + lng + ',"wifi":"' + escapedWifi + '","name":"' + escapedName + '","category":"' + category + '"}}}}' +
      ']}';
    
    this.dispatchA2UI('push', jsonl);
    this.log.info(TAG, `New place auto-saved: ${placeName} (${category}), card shown for editing`);
  }

  /**
   * 自动保存新发现的地点为围栏
   */
  private autoSaveNewPlace(lat: number, lng: number, wifiSsid: string, placeName: string, category: string): boolean {
    try {
      // 去重：检查是否已有距离 <200m 或同 WiFi 的围栏
      let existing = this.geofenceMgr.getAllGeofences();
      for (let i = 0; i < existing.length; i++) {
        let gf = existing[i];
        let dist = this.haversineDistance(lat, lng, gf.latitude, gf.longitude);
        if (dist < 200) {
          this.log.info(TAG, `Skip auto-save: existing geofence "${gf.name}" within ${Math.round(dist)}m`);
          return false;
        }
        if (wifiSsid.length > 0 && gf.learnedSignals?.wifiSSIDs && gf.learnedSignals.wifiSSIDs.indexOf(wifiSsid) >= 0) {
          this.log.info(TAG, `Skip auto-save: existing geofence "${gf.name}" has same WiFi "${wifiSsid}"`);
          return false;
        }
      }
      let geofence: Geofence = {
        id: `auto_${Date.now()}`,
        name: placeName.length > 0 ? placeName : wifiSsid,
        latitude: lat,
        longitude: lng,
        radiusMeters: 200,
        category: category as GeofenceCategory,
        learnedSignals: {
          wifiSSIDs: wifiSsid.length > 0 ? [wifiSsid] : [],
          bluetoothDevices: [],
          cellIds: [],
          typicalTimes: [],
          lastSeen: Date.now(),
          visitCount: 1
        }
      };
      this.geofenceMgr.addGeofence(geofence);
      this.log.info(TAG, `Auto-saved geofence: ${geofence.name} (${category}) at (${lat.toFixed(4)}, ${lng.toFixed(4)})`);
      return true;
    } catch (err) {
      this.log.error(TAG, `Failed to auto-save place: ${(err as Error).message}`);
      return false;
    }
  }

  /**
   * 根据当前时间推断地点类别
   */
  private inferCategoryFromTime(): string {
    let hour = new Date().getHours();
    let dayOfWeek = new Date().getDay();
    let isWeekend = dayOfWeek === 0 || dayOfWeek === 6;
    
    if (!isWeekend && hour >= 9 && hour < 18) {
      return 'work';
    }
    if (hour >= 22 || hour < 6) {
      return 'home';
    }
    if (hour >= 11 && hour < 14) {
      return 'restaurant';
    }
    if (isWeekend && hour >= 8 && hour < 20) {
      return 'gym';
    }
    return 'other';
  }

  /**
   * 计算两点距离（米）
   */
  private haversineDistance(lat1: number, lng1: number, lat2: number, lng2: number): number {
    let R = 6371000; // 地球半径（米）
    let dLat = (lat2 - lat1) * Math.PI / 180;
    let dLng = (lng2 - lng1) * Math.PI / 180;
    let a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
            Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
            Math.sin(dLng / 2) * Math.sin(dLng / 2);
    let c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
    return R * c;
  }

  // ==================== WiFi 分类 ====================

  /**
   * 分类 WiFi SSID: hotspot (移动热点), public (公共), fixed (固定/家用/企业)
   */
  private classifyWifi(ssid: string): WifiMobility {
    if (ssid.length === 0) return 'fixed';

    // Check hotspot patterns (contains match)
    for (let i = 0; i < ContextAwarenessService.WIFI_HOTSPOT_PATTERNS.length; i++) {
      if (ssid.indexOf(ContextAwarenessService.WIFI_HOTSPOT_PATTERNS[i]) >= 0) {
        return 'hotspot';
      }
    }

    // Check public WiFi prefixes
    for (let i = 0; i < ContextAwarenessService.WIFI_PUBLIC_PREFIXES.length; i++) {
      if (ssid.startsWith(ContextAwarenessService.WIFI_PUBLIC_PREFIXES[i])) {
        return 'public';
      }
    }

    return 'fixed';
  }

  // ==================== 分层传感器管理 (Sensor Tier) ====================

  /**
   * 评估是否需要升级或降级传感器层级
   * 在 periodicEvaluate() 开头调用
   */
  private evaluateTierEscalation(): void {
    let now = Date.now();
    let motionState = this.lastMotionState;
    let geofenceSlot = this.tray.get('geofence');
    let inKnownGeofence = geofenceSlot !== undefined && geofenceSlot !== null && geofenceSlot.value !== null && geofenceSlot.value.length > 0;

    // 穿戴设备联动
    let heartRateStatus = this.tray.get('heart_rate_status');
    let wearingState = this.tray.get('wearing_state');

    // Track stationary duration
    if (motionState === 'stationary') {
      if (this.stationarySinceMs === 0) this.stationarySinceMs = now;
    } else {
      this.stationarySinceMs = 0;
    }

    // Track unknown location duration
    if (!inKnownGeofence) {
      if (this.unknownLocationSinceMs === 0) this.unknownLocationSinceMs = now;
    } else {
      this.unknownLocationSinceMs = 0;
    }

    let stationaryDuration = this.stationarySinceMs > 0 ? now - this.stationarySinceMs : 0;
    let unknownLocationDuration = this.unknownLocationSinceMs > 0 ? now - this.unknownLocationSinceMs : 0;

    // === 降级检查 ===

    // T3→T2: 2 分钟超时自动降级
    if (this.currentTier === 3) {
      let t3Duration = now - this.tierEscalationTime;
      if (t3Duration > 2 * 60 * 1000) {
        this.deEscalateTier(2, 'T3 timeout (2min)');
        return;
      }
    }

    // T2→T1: 已知围栏 + 静止 10 分钟
    if (this.currentTier === 2) {
      if (inKnownGeofence && stationaryDuration > 10 * 60 * 1000) {
        this.deEscalateTier(1, 'known geofence + stationary 10min');
        return;
      }
      // 穿戴 off_wrist → 降级
      if (wearingState && wearingState.value === 'off_wrist') {
        this.deEscalateTier(1, 'off_wrist');
        return;
      }
    }

    // === 升级检查 ===

    // T1→T2 triggers
    if (this.currentTier === 1) {
      // 运动状态变化 (非静止)
      if (motionState !== 'stationary' && motionState !== 'unknown' && motionState !== 'pickup') {
        this.escalateTier(2, 'motion: ' + motionState);
        return;
      }
      // 未知位置
      if (!inKnownGeofence && unknownLocationDuration > 60 * 1000) {
        this.escalateTier(2, 'unknown location');
        return;
      }
      // 心率 exercise
      if (heartRateStatus && heartRateStatus.value === 'exercise') {
        this.escalateTier(2, 'exercise heart rate');
        this.log.info(TAG, I18n.t('context.exercise.detected'));
        return;
      }
    }

    // T2→T3: 未知位置 + 静止 5 分钟 (arrived at new place)
    if (this.currentTier === 2) {
      if (!inKnownGeofence && stationaryDuration > 5 * 60 * 1000) {
        this.escalateTier(3, 'unknown location + stationary 5min');
        return;
      }
    }
  }

  /**
   * 升级传感器层级
   */
  private escalateTier(target: SensorTier, reason: string): void {
    if (target <= this.currentTier) return;
    let prev = this.currentTier;
    this.currentTier = target;
    this.tierEscalationTime = Date.now();
    this.recordedPut('sensorTier', target.toString(), 1.0, 'system');
    this.log.info(TAG, `Tier T${prev}->T${target}: ${reason}`);

    if (target >= 2) this.onTier2Activated();
    if (target >= 3) this.onTier3Activated();
  }

  /**
   * 降级传感器层级
   */
  private deEscalateTier(target: SensorTier, reason: string): void {
    if (target >= this.currentTier) return;
    let prev = this.currentTier;

    // Deactivate higher tiers
    if (prev >= 3 && target < 3) this.onTier3Deactivated();
    if (prev >= 2 && target < 2) this.onTier2Deactivated();

    this.currentTier = target;
    this.recordedPut('sensorTier', target.toString(), 1.0, 'system');
    this.log.info(TAG, `Tier T${prev}->T${target}: ${reason}`);
  }

  /**
   * T2 激活: 确保 GPS 运行, AmbientSound 可启用
   */
  private onTier2Activated(): void {
    // Ensure GPS is on at walking interval
    if (this.locationIntervalMs > ContextAwarenessService.GPS_WALKING) {
      this.locationIntervalMs = ContextAwarenessService.GPS_WALKING;
      this.restartLocationTimer();
    }
    this.log.info(TAG, 'Tier T2 activated: GPS ensured, ambient sound eligible');
  }

  /**
   * T2 停用: 降低 GPS 频率
   */
  private onTier2Deactivated(): void {
    // Revert GPS to stationary interval
    this.locationIntervalMs = ContextAwarenessService.GPS_STATIONARY;
    this.restartLocationTimer();
    this.log.info(TAG, 'Tier T2 deactivated: GPS reduced');
  }

  /**
   * T3 激活: 高功耗传感器 (VisionAnalysis stub)
   */
  private onTier3Activated(): void {
    this.log.info(TAG, 'Tier T3 activated: high-power sensors eligible');
    // VisionAnalysis is disabled by default; T3 makes it eligible if user enables it
  }

  /**
   * T3 停用
   */
  private onTier3Deactivated(): void {
    this.log.info(TAG, 'Tier T3 deactivated');
  }

  // ==================== 设备围栏关联 & 自动创建 ====================

  /**
   * 为固定设备自动创建围栏 (GPS 精度 < 50m, 200m 内无已有围栏)
   */
  private autoCreateGeofenceForFixedDevice(lat: number, lng: number, accuracy: number, deviceName: string): void {
    if (accuracy > 50) {
      this.log.debug(TAG, `Skip auto-create geofence: GPS accuracy ${accuracy}m > 50m`);
      return;
    }

    // Check if a geofence already exists within 200m
    let allGeofences = this.geofenceMgr.getAllGeofences();
    for (let i = 0; i < allGeofences.length; i++) {
      let gf = allGeofences[i];
      let dist = this.haversineDistance(lat, lng, gf.latitude, gf.longitude);
      if (dist < 200) {
        this.log.info(TAG, `Auto-create skipped: ${deviceName} within ${Math.round(dist)}m of ${gf.name}`);
        // Associate device with existing geofence instead
        this.learnDeviceToGeofence(gf, deviceName, 'bluetooth');
        return;
      }
    }

    // Create new geofence
    let category = this.inferCategoryFromTime();
    let gfId = 'auto_' + Date.now().toString();
    let gf: Geofence = {
      id: gfId,
      name: deviceName,
      latitude: lat,
      longitude: lng,
      radiusMeters: 100,
      category: category as GeofenceCategory,
      learnedSignals: {
        wifiSSIDs: [],
        bluetoothDevices: [deviceName],
        cellIds: [],
        typicalTimes: [],
        lastSeen: Date.now(),
        visitCount: 1,
      }
    };

    this.addGeofence(gf);
    this.log.info(TAG, `${I18n.t('context.geofence.autoCreated')}: ${deviceName} → ${gfId} (${category})`);
  }

  /**
   * 将设备学习到围栏的 learnedSignals 中
   */
  private learnDeviceToGeofence(gf: Geofence, deviceName: string, deviceType: 'wifi' | 'bluetooth'): void {
    let signals = gf.learnedSignals ?? {
      wifiSSIDs: [], bluetoothDevices: [], cellIds: [], typicalTimes: [], lastSeen: 0, visitCount: 0
    };

    if (deviceType === 'bluetooth') {
      if (!signals.bluetoothDevices!.includes(deviceName)) {
        signals.bluetoothDevices!.push(deviceName);
        this.log.info(TAG, `BT fixed: ${deviceName} -> learned for ${gf.name}`);
        this.notifyGeofenceFeatureLearned(gf.name, 'Bluetooth', deviceName);
      }
    } else {
      if (!signals.wifiSSIDs!.includes(deviceName)) {
        signals.wifiSSIDs!.push(deviceName);
        this.log.info(TAG, `WiFi fixed: ${deviceName} -> learned for ${gf.name}`);
        this.notifyGeofenceFeatureLearned(gf.name, 'WiFi', deviceName);
      }
    }

    signals.lastSeen = Date.now();
    gf.learnedSignals = signals;
    this.geofenceMgr.saveToFile();
  }

  // ==================== BT 变化检测 & 连接时长追踪 ====================

  /**
   * 检测 BT 固定设备变化, 关联围栏, 追踪连接时长
   * 在 periodicEvaluate() 中调用
   */
  private detectBtChangesAndTrackConnections(): void {
    let now = Date.now();

    // Read current BT devices from tray
    let btFixedSlot = this.tray.get('bt_fixed_devices');
    let currentBtFixed = (btFixedSlot && btFixedSlot.value) ? btFixedSlot.value : '';
    let btVehicleSlot = this.tray.get('bt_vehicle_devices');
    let currentBtVehicle = (btVehicleSlot && btVehicleSlot.value) ? btVehicleSlot.value : '';

    // Parse device names
    let currentFixedSet: Set<string> = new Set();
    if (currentBtFixed.length > 0) {
      let parts = currentBtFixed.split(', ');
      for (let p of parts) {
        let trimmed = p.trim();
        if (trimmed.length > 0) currentFixedSet.add(trimmed);
      }
    }

    let previousFixedSet: Set<string> = new Set();
    if (this.lastKnownBtFixed.length > 0) {
      let parts = this.lastKnownBtFixed.split(', ');
      for (let p of parts) {
        let trimmed = p.trim();
        if (trimmed.length > 0) previousFixedSet.add(trimmed);
      }
    }

    // New fixed devices → associate with geofence or auto-create
    currentFixedSet.forEach((name: string) => {
      if (!previousFixedSet.has(name)) {
        this.log.info(TAG, `BT fixed device appeared: ${name}`);
        // Start connection session
        this.startConnectionSession(name, 'bluetooth', 'fixed');
        // Associate with geofence
        if (this.lastLocation && this.lastLocation.accuracy < 50) {
          this.autoCreateGeofenceForFixedDevice(
            this.lastLocation.latitude, this.lastLocation.longitude,
            this.lastLocation.accuracy, name
          );
        }
      }
    });

    // Disappeared fixed devices → end session
    previousFixedSet.forEach((name: string) => {
      if (!currentFixedSet.has(name)) {
        this.log.info(TAG, `BT fixed device disappeared: ${name}`);
        this.endConnectionSession(name);
      }
    });

    // Vehicle BT change detection
    if (currentBtVehicle !== this.lastKnownBtVehicle) {
      if (currentBtVehicle.length > 0 && this.lastKnownBtVehicle.length === 0) {
        this.log.info(TAG, `${I18n.t('context.device.inVehicle')}: ${currentBtVehicle}`);
      }
    }

    this.lastKnownBtFixed = currentBtFixed;
    this.lastKnownBtVehicle = currentBtVehicle;
  }

  /**
   * 开始设备连接会话
   */
  private startConnectionSession(deviceName: string, deviceType: 'wifi' | 'bluetooth', mobility: string): void {
    let now = Date.now();
    let existing = this.connectionRecords.get(deviceName);
    if (existing) {
      existing.sessionCount++;
      existing.currentSessionStart = now;
      existing.lastSeen = now;
    } else {
      let record: DeviceConnectionRecord = {
        deviceName: deviceName,
        deviceType: deviceType,
        mobility: mobility as DeviceMobility,
        geofenceId: '',
        firstSeen: now,
        lastSeen: now,
        totalDurationMs: 0,
        sessionCount: 1,
        currentSessionStart: now,
      };
      this.connectionRecords.set(deviceName, record);
    }
  }

  /**
   * 结束设备连接会话
   */
  private endConnectionSession(deviceName: string): void {
    let record = this.connectionRecords.get(deviceName);
    if (record && record.currentSessionStart > 0) {
      let sessionDuration = Date.now() - record.currentSessionStart;
      record.totalDurationMs += sessionDuration;
      record.currentSessionStart = 0;
      record.lastSeen = Date.now();
      this.log.info(TAG, `Connection ended: ${deviceName}, session=${Math.round(sessionDuration / 1000)}s, total=${Math.round(record.totalDurationMs / 1000)}s`);
    }
  }

  /**
   * 持久化连接记录
   */
  private async saveConnectionRecords(): Promise<void> {
    if (!this.context) return;
    try {
      let prefs = await preferences.getPreferences(this.context, 'context_awareness');
      let arr: Object[] = [];
      this.connectionRecords.forEach((record: DeviceConnectionRecord) => {
        arr.push(record as Object);
      });
      await prefs.put('device_connection_records', JSON.stringify(arr));
      await prefs.flush();
    } catch (err) {
      this.log.warn(TAG, `Failed to save connection records: ${(err as Error).message}`);
    }
  }

  /**
   * 加载连接记录
   */
  private async loadConnectionRecords(): Promise<void> {
    if (!this.context) return;
    try {
      let prefs = await preferences.getPreferences(this.context, 'context_awareness');
      let json = await prefs.get('device_connection_records', '[]') as string;
      let arr = JSON.parse(json) as DeviceConnectionRecord[];
      let now = Date.now();
      for (let i = 0; i < arr.length; i++) {
        let record = arr[i];
        // Cap orphan sessions at 30 minutes
        if (record.currentSessionStart > 0) {
          let orphanDuration = now - record.currentSessionStart;
          if (orphanDuration > 30 * 60 * 1000) {
            record.totalDurationMs += 30 * 60 * 1000;
          } else {
            record.totalDurationMs += orphanDuration;
          }
          record.currentSessionStart = 0;
        }
        this.connectionRecords.set(record.deviceName, record);
      }
      this.log.info(TAG, `Loaded ${this.connectionRecords.size} connection records`);
    } catch (err) {
      this.log.warn(TAG, `Failed to load connection records: ${(err as Error).message}`);
    }
  }

  private async onGeofenceEvent(event: GeofenceEvent): Promise<void> {
    if (this.isReplaying) return;  // 回放中不处理围栏事件
    this.log.info(TAG, `Geofence ${event.type}: ${event.geofence.name}`);

    // 更新位置
    this.lastLocation = event.location;

    // 写入托盘
    this.recordedPut('latitude', event.location.latitude.toString(), 1.0, 'gps');
    this.recordedPut('longitude', event.location.longitude.toString(), 1.0, 'gps');
    if (event.type === 'enter') {
      this.recordedPut('geofence', event.geofence.id, 1.0, 'geofence');
      this.recordedPut('geofenceCategory', event.geofence.category, 0.8, 'geofence');
    } else {
      // Exit: 清除围栏标记，让新地点检测和 GPS 定时器正常工作
      this.recordedPut('geofence', '', 0, 'geofence');
      this.recordedPut('geofenceCategory', '', 0, 'geofence');
      this.log.info(TAG, `Geofence exit: cleared tray, left ${event.geofence.name}`);
    }

    // Push event to engine buffer for temporal/sequence rules
    let eventType = event.type === 'enter' ? 'geofence_enter' : 'geofence_exit';
    this.engine.pushEvent(eventType);

    // 立即推送时间线事件（解决"今日行程显示不及时"问题）
    this.pushTimelineEvent();

    // GPS 高精度进入围栏时，学习 WiFi/BT 信号
    if (event.type === 'enter') {
      this.locationFusion.learnSignals(event.geofence.id, event.location);
    }

    // 只处理进入事件
    if (event.type !== 'enter') return;

    // 刷新托盘 + 通过 C++ 规则引擎评估
    await this.refreshTray();
    this.buildPhysicalStateAndDetectChange();
    let snapshot = this.tray.getSnapshot();
    this.log.info(TAG, `Geofence trigger evaluate: geofence=${snapshot.geofence ?? 'none'}`);
    await this.evaluateAndDeliver(snapshot);

    // 同时尝试旧的 BehaviorLogger 匹配（兼容过渡）
    let ctx = await this.getCurrentContext();
    let rules = this.behaviorLog.getMatchingRules(ctx);
    if (rules.length > 0) {
      let topRule = rules[0];
      if (!this.isOnCooldown(topRule.id)) {
        let rec: ContextRecommendation = {
          rule: topRule,
          action: topRule.action,
          reason: this.buildRecommendationReason(topRule, event.geofence),
        };
        this.notifyRecommendation(rec);
        this.setOnCooldown(topRule.id);
      }
    } else {
      this.handleNewLocationWithoutRules(event.geofence, ctx);
    }
  }
  
  /**
   * 处理没有规则的新位置 - 基于位置类型的默认推荐
   */
  private handleNewLocationWithoutRules(geofence: Geofence, ctx: EnvironmentContext): void {
    let defaultAction: UserAction | undefined;
    let reason: string = '';
    
    switch (geofence.category) {
      case 'transit':
        defaultAction = { type: 'show_qrcode', target: 'transit_code' };
        reason = `到达 ${geofence.name}，需要乘车码吗？`;
        break;
        
      case 'shopping':
        let store = (geofence.metadata && geofence.metadata['store']) ? geofence.metadata['store'] as string : 'store';
        defaultAction = { type: 'show_info', target: `deals_${store}` };
        reason = `到达 ${geofence.name}，查看今日优惠？`;
        break;
        
      case 'work':
        defaultAction = { type: 'show_info', target: 'calendar_today' };
        reason = `到达办公室，查看今日日程？`;
        break;
        
      default:
        return;  // 不推荐
    }
    
    if (defaultAction && !this.isOnCooldown(`default_${geofence.id}`)) {
      let rec: ContextRecommendation = {
        rule: {
          id: `default_${geofence.id}`,
          trigger: { geofenceIds: [geofence.id] },
          action: defaultAction,
          confidence: 0.5,  // 默认推荐的初始置信度
          triggerCount: 0,
          acceptCount: 0,
          createdAt: Date.now(),
          updatedAt: Date.now(),
          enabled: true,
        },
        action: defaultAction,
        reason,
      };
      
      this.notifyRecommendation(rec);
      this.setOnCooldown(`default_${geofence.id}`);
    }
  }
  
  private buildRecommendationReason(rule: ContextRule, geofence: Geofence): string {
    let conf = Math.round(rule.confidence * 100);
    
    if (rule.action.type === 'show_qrcode') {
      return `到达 ${geofence.name}，显示乘车码？(${conf}% 匹配)`;
    } else if (rule.action.type === 'show_info') {
      return `到达 ${geofence.name}，为你准备了相关信息 (${conf}% 匹配)`;
    } else {
      return `基于你的习惯，推荐此操作 (${conf}% 匹配)`;
    }
  }
  
  
  /**
   * Convert a ContextSnapshot into ContextCondition[] for rule persistence.
   * Extracts the key fields that defined this context moment.
   */
  private snapshotToConditions(snapshot: ContextSnapshot): EngineCondition[] {
    let conditions: EngineCondition[] = [];

    // Time of day
    conditions.push({ key: 'timeOfDay', op: 'eq', value: snapshot.timeOfDay });

    // Hour range: ±1 hour for flexibility
    let hour = parseInt(snapshot.hour);
    if (!isNaN(hour)) {
      let low = Math.max(0, hour - 1);
      let high = Math.min(23, hour + 1);
      conditions.push({ key: 'hour', op: 'range', value: `${low},${high}` });
    }

    // Weekend
    conditions.push({ key: 'isWeekend', op: 'eq', value: snapshot.isWeekend });

    // Motion state
    if (snapshot.motionState && snapshot.motionState !== 'unknown') {
      conditions.push({ key: 'motionState', op: 'eq', value: snapshot.motionState });
    }

    // Battery (only if notably low)
    let battery = parseInt(snapshot.batteryLevel);
    if (!isNaN(battery) && battery <= 20) {
      conditions.push({ key: 'batteryLevel', op: 'lte', value: '20' });
    }

    // Charging
    if (snapshot.isCharging === 'true') {
      conditions.push({ key: 'isCharging', op: 'eq', value: 'true' });
    }

    // Network
    if (snapshot.networkType && snapshot.networkType !== 'unknown') {
      conditions.push({ key: 'networkType', op: 'eq', value: snapshot.networkType });
    }

    // Geofence
    if (snapshot.geofence && snapshot.geofence.length > 0) {
      conditions.push({ key: 'geofence', op: 'eq', value: snapshot.geofence });
    }

    return conditions;
  }

  private isOnCooldown(ruleId: string): boolean {
    let lastTime = this.lastRecommendations.get(ruleId);
    if (!lastTime) return false;
    return Date.now() - lastTime < ContextAwarenessService.RECOMMENDATION_COOLDOWN_MS;
  }
  
  private setOnCooldown(ruleId: string): void {
    this.lastRecommendations.set(ruleId, Date.now());
  }
  

  /**
   * Mark that the user gave feedback on an LLM recommendation.
   * Called by FeedbackService so we know whether to repeat the recommendation.
   */
  markLlmFeedbackReceived(ruleId: string): void {
    if (ruleId === this.lastLlmRuleId || ruleId.startsWith('user_llm_')) {
      this.lastLlmFeedbackReceived = true;
    }
  }

  // ==================== 积极探索模式 ====================

  /** 获取积极探索模式状态 */
  isExploreMode(): boolean {
    return this.exploreMode;
  }

  /** 设置积极探索模式 */
  async setExploreMode(enabled: boolean): Promise<void> {
    this.exploreMode = enabled;
    if (this.context) {
      try {
        let prefs = await preferences.getPreferences(this.context, 'context_awareness');
        await prefs.put('explore_mode', enabled);
        await prefs.flush();
      } catch (err) {
        this.log.warn(TAG, `Failed to persist explore mode: ${(err as Error).message}`);
      }
    }
    this.log.info(TAG, `Explore mode ${enabled ? 'enabled' : 'disabled'}, explored ${this.exploredFingerprints.size} fingerprints`);

    // 开启时立即触发一次评估，让用户能即时看到效果
    if (enabled && this.isRunning) {
      this.periodicEvaluate();
    }
  }

  /** 加载积极探索模式持久化状态 */
  private async loadExploreMode(): Promise<void> {
    if (!this.context) return;
    try {
      let prefs = await preferences.getPreferences(this.context, 'context_awareness');
      this.exploreMode = await prefs.get('explore_mode', false) as boolean;
      let fpJson = await prefs.get('explored_fingerprints', '[]') as string;
      let parsed: Object[] = JSON.parse(fpJson) as Object[];
      // 兼容旧格式 (string[]) 和新格式 ({fp: string, ts: number}[])
      for (let i = 0; i < parsed.length; i++) {
        let item: Object = parsed[i];
        if (typeof item === 'string') {
          // 旧格式：没有时间戳，视为已过期（会被重新探索）
          this.exploredFingerprints.set(item as string, 0);
        } else {
          let entry = item as Record<string, string | number>;
          if (entry['fp'] !== undefined && entry['ts'] !== undefined) {
            this.exploredFingerprints.set(entry['fp'] as string, entry['ts'] as number);
          }
        }
      }
      this.log.info(TAG, `Explore mode loaded: enabled=${this.exploreMode}, fingerprints=${this.exploredFingerprints.size}`);
    } catch (err) {
      this.log.warn(TAG, `Failed to load explore mode: ${(err as Error).message}`);
    }
  }

  /** 持久化已探索指纹 (带时间戳) */
  private async saveExploredFingerprints(): Promise<void> {
    if (!this.context) return;
    try {
      let prefs = await preferences.getPreferences(this.context, 'context_awareness');
      let arr: FingerprintEntry[] = [];
      this.exploredFingerprints.forEach((ts: number, fp: string) => {
        let entry: FingerprintEntry = { fp: fp, ts: ts };
        arr.push(entry);
      });
      await prefs.put('explored_fingerprints', JSON.stringify(arr));
      await prefs.flush();
    } catch (err) {
      this.log.warn(TAG, `Failed to save fingerprints: ${(err as Error).message}`);
    }
  }

  /** 计算状态指纹：核心维度 + WiFi/BT 设备 + 小时段 */
  /** 将 C++ ContextAction 转换为 UserAction */
  private contextActionToUserAction(action: EngineAction, ruleId?: string): UserAction {
    // C++ engine types → ArkTS ActionType 映射
    let typeMap: Record<string, string> = {
      'suggestion': 'show_notification',
      'notification': 'show_notification',
      'alert': 'show_notification',
      'show_info': 'show_info',
      'show_notification': 'show_notification',
      'open_app': 'open_app',
      'show_qrcode': 'show_qrcode',
      'set_mode': 'set_mode',
      'mode_change': 'set_mode',
      'quick_action': 'quick_action',
      'dismiss': 'dismiss',
    };
    let rawType = action.type ?? 'suggestion';
    let mappedType = (typeMap[rawType] ?? 'show_notification') as ActionType;

    // 查找规则的 function 字段（用 ruleId，不是 action.id）
    let lookupId = ruleId ?? action.id;
    let ruleFunction = this.engine.getRuleFunction(lookupId);
    let params: Record<string, string> | undefined = undefined;
    if (ruleFunction && ruleFunction.length > 0) {
      params = { 'function': ruleFunction };
      this.log.info(TAG, `[ActionMap] rule=${lookupId} → function=${ruleFunction}`);
    }

    return {
      type: mappedType,
      target: action.payload ?? '',
      params: params,
    };
  }

  private computeFingerprint(snapshot: ContextSnapshot): string {
    // 小时段：将24小时分为 3 小时一组 (0-2, 3-5, 6-8, ...) → 更细粒度
    let hourNum = parseInt(snapshot.hour || '0');
    let hourBucket = Math.floor(hourNum / 3).toString();
    let wifi = snapshot.wifiSsid || 'none';
    // BT: 取已连接的设备名
    let btSlot = this.tray.get('bt_device_names');
    let bt = (btSlot && btSlot.value && btSlot.value.length > 0) ? btSlot.value : 'none';
    return `${snapshot.timeOfDay || 'unknown'}|${snapshot.isWeekend || 'false'}|${snapshot.motionState || 'unknown'}|${snapshot.geofence || 'none'}|h${hourBucket}|w:${wifi}|bt:${bt}`;
  }

  /** 构建探索模式状态摘要：人类可读的当前检测状态 */
  private buildExploreStateInfo(snapshot: ContextSnapshot): string {
    let lines: string[] = [];

    // 时段
    let todMap: Record<string, string> = {
      'dawn': '黎明', 'morning': '上午', 'afternoon': '下午',
      'evening': '傍晚', 'night': '深夜'
    };
    let todLabel = todMap[snapshot.timeOfDay] ?? snapshot.timeOfDay;
    let h = snapshot.hour ?? '';
    let dayNames: string[] = ['日', '一', '二', '三', '四', '五', '六'];
    let dayIdx = parseInt(snapshot.dayOfWeek || '0');
    let dayLabel = dayIdx >= 0 && dayIdx < 7 ? `周${dayNames[dayIdx]}` : '';
    let weekendTag = snapshot.isWeekend === 'true' ? '（周末）' : '';
    lines.push(`⏰ ${todLabel} ${h}:00 ${dayLabel}${weekendTag}`);

    // 运动状态
    let motionMap: Record<string, string> = {
      'stationary': '静止', 'walking': '步行', 'running': '跑步',
      'driving': '驾车', 'transit': '乘车', 'cycling': '骑行',
      'unknown': '未知'
    };
    let motionLabel = motionMap[snapshot.motionState] ?? snapshot.motionState;
    if (motionLabel.length > 0 && motionLabel !== '未知' && motionLabel !== 'unknown') {
      let durationSec = parseInt(snapshot.activityDuration || '0');
      let durationStr = durationSec > 0
        ? ` (${durationSec >= 3600 ? Math.floor(durationSec / 3600) + '小时' : Math.floor(durationSec / 60) + '分钟'})`
        : '';
      lines.push(`🏃 ${motionLabel}${durationStr}`);
    }

    // 位置：综合 geofence ID、wifiGeofence category、WiFi SSID 查找围栏名称
    let catLabels: Record<string, string> = {
      'home': '🏠 家', 'work': '🏢 公司', 'restaurant': '🍽️ 餐饮',
      'shopping': '🛒 购物', 'gym': '💪 健身', 'transit': '🚉 交通', 'hotel': '🏨 酒店'
    };
    let gfName = '';
    let gfCat = snapshot.wifiGeofence ?? '';
    let allGf = this.geofenceMgr.getAllGeofences();
    // 方法1: 通过 geofence ID 查找
    if (snapshot.geofence && snapshot.geofence.length > 0) {
      for (let i = 0; i < allGf.length; i++) {
        if (allGf[i].id === snapshot.geofence) {
          gfName = allGf[i].name;
          gfCat = allGf[i].category ?? gfCat;
          break;
        }
      }
    }
    // 方法2: 通过 WiFi SSID 查找 (使用 locationFusion 的学习数据)
    if (gfName.length === 0 && snapshot.wifiSsid && snapshot.wifiSsid.length > 0) {
      for (let i = 0; i < allGf.length; i++) {
        let summary = this.locationFusion.getLearnedSignalsSummary(allGf[i]);
        if (summary && summary.wifiSsids.includes(snapshot.wifiSsid)) {
          gfName = allGf[i].name;
          gfCat = allGf[i].category ?? gfCat;
          break;
        }
      }
    }
    // 显示
    if (gfName.length > 0) {
      let catLabel = catLabels[gfCat] ?? gfCat;
      lines.push(`📍 ${gfName} (${catLabel})`);
    } else if (gfCat.length > 0) {
      let catLabel = catLabels[gfCat] ?? gfCat;
      lines.push(`📍 ${catLabel}`);
    }
    if (snapshot.wifiSsid && snapshot.wifiSsid.length > 0) {
      lines.push(`📶 WiFi: ${snapshot.wifiSsid}`);
    }

    // 蓝牙设备
    let btSlot = this.tray.get('bt_device_names');
    let btNames = (btSlot && btSlot.value && btSlot.value.length > 0) ? btSlot.value : '';
    if (btNames.length > 0) {
      lines.push(`🔵 蓝牙: ${btNames}`);
    }
    if (snapshot.bt_in_vehicle === 'true') {
      lines.push(`🚗 车载蓝牙已连接`);
    }

    // 心率 & 穿戴
    if (snapshot.heartRate && snapshot.heartRate.length > 0 && snapshot.heartRate !== '0') {
      let hrStatusMap: Record<string, string> = {
        'resting': '休息', 'active': '活跃', 'exercise': '运动',
        'low': '偏低', 'unknown': '未知'
      };
      let hrLabel = hrStatusMap[snapshot.heart_rate_status ?? ''] ?? '';
      lines.push(`❤️ 心率: ${snapshot.heartRate} bpm${hrLabel.length > 0 ? ' (' + hrLabel + ')' : ''}`);
    }
    if (snapshot.wearing_state && snapshot.wearing_state.length > 0) {
      lines.push(`⌚ ${snapshot.wearing_state === 'on_wrist' ? '佩戴中' : '未佩戴'}`);
    }

    // 步数
    if (snapshot.stepCount && snapshot.stepCount.length > 0 && snapshot.stepCount !== '0') {
      lines.push(`🚶 今日 ${snapshot.stepCount} 步`);
    }

    // 电量
    if (snapshot.batteryLevel && snapshot.batteryLevel.length > 0) {
      let chargingTag = snapshot.isCharging === 'true' ? ' 充电中' : '';
      lines.push(`🔋 ${snapshot.batteryLevel}%${chargingTag}`);
    }

    // 传感器层级
    if (snapshot.sensorTier && snapshot.sensorTier.length > 0) {
      lines.push(`📊 传感器层级: T${snapshot.sensorTier}`);
    }

    return lines.join('\n');
  }

  /**
   * 探索模式：定期发送当前状态 + 匹配的建议到聊天窗口
   * 有自己的 cooldown（5分钟），不依赖规则 cooldown
   */
  private sendExploreStateDisplay(snapshot: ContextSnapshot, topMatch: MatchResult | null): void {
    let now = Date.now();
    if (now - this.lastExploreStateDisplayTime < ContextAwarenessService.EXPLORE_STATE_DISPLAY_COOLDOWN_MS) {
      return; // 状态显示在 cooldown 内
    }
    this.lastExploreStateDisplayTime = now;

    let stateInfo = this.buildExploreStateInfo(snapshot);

    // 构建建议文本：从匹配的规则中获取 payload
    let suggestion = '';
    if (topMatch !== null) {
      let payload = topMatch.action.payload ?? '';
      if (payload.length > 0) {
        suggestion = payload;
      } else {
        suggestion = `规则 ${topMatch.ruleId} 匹配 (${Math.round(topMatch.confidence * 100)}%)`;
      }
    } else {
      suggestion = '当前无匹配规则';
    }

    // 查找规则名称
    let ruleName = topMatch !== null ? topMatch.ruleId : 'explore_state';
    let ruleId = topMatch !== null ? topMatch.ruleId : 'explore_state';
    if (topMatch !== null) {
      try {
        let allRulesJson = this.engine.exportRules();
        let allRules: EngineRule[] = JSON.parse(allRulesJson) as EngineRule[];
        for (let i = 0; i < allRules.length; i++) {
          if (allRules[i].id === topMatch.ruleId) {
            ruleName = allRules[i].name;
            break;
          }
        }
      } catch { /* ignore */ }
    }

    let rec: ContextRecommendation = {
      rule: {
        id: `explore_display_${ruleId}`,
        trigger: {} as RuleTrigger,
        action: { type: 'show_info', target: 'explore_state' } as UserAction,
        confidence: topMatch !== null ? topMatch.confidence : 0,
        triggerCount: 0,
        acceptCount: 0,
        createdAt: now,
        updatedAt: now,
        enabled: true
      },
      action: { type: 'show_info', target: 'explore_state' } as UserAction,
      reason: suggestion,
      exploreStateInfo: stateInfo
    };

    this.log.info(TAG, `[Explore] sending state display: stateLen=${stateInfo.length}, suggestion="${suggestion.substring(0, 50)}"`);
    this.notifyRecommendation(rec);
  }

  /**
   * 用户对推荐的反馈（保留旧 API 兼容性）
   */
  async onRecommendationFeedback(
    rec: ContextRecommendation,
    accepted: boolean
  ): Promise<void> {
    let ctx = this.currentContext ?? await this.getCurrentContext();

    let outcome: ActionOutcome = {
      accepted,
      feedback: accepted ? 1 : -1,
    };

    // 记录行为
    await this.behaviorLog.logBehavior(ctx, rec.action, outcome);

    this.log.info(TAG, 'Recommendation feedback: ' + rec.rule.id + ' accepted=' + accepted.toString());
  }

  /**
   * 卡片展示时通知 FeedbackService（启动超时定时器）
   */
  onCardShown(rec: ContextRecommendation): void {
    this.feedbackSvc.onCardShown(rec);
  }

  /**
   * 👍 反馈 → reward +1.0
   */
  async onThumbsUp(ruleId: string): Promise<void> {
    let ctx = this.currentContext ?? await this.getCurrentContext();
    await this.feedbackSvc.onThumbsUp(ruleId, ctx);
  }

  /**
   * 👎 反馈 → reward -0.5
   */
  async onThumbsDown(ruleId: string): Promise<void> {
    let ctx = this.currentContext ?? await this.getCurrentContext();
    await this.feedbackSvc.onThumbsDown(ruleId, ctx);
  }

  /**
   * 用户执行推荐动作 → reward +0.8
   */
  async onActionTaken(ruleId: string): Promise<void> {
    let ctx = this.currentContext ?? await this.getCurrentContext();
    await this.feedbackSvc.onActionTaken(ruleId, ctx);
  }

  /**
   * 用户滑走卡片 → 5min 后 reward -0.1
   */
  onCardDismissed(ruleId: string): void {
    this.feedbackSvc.onCardDismissed(ruleId);
  }

  /**
   * 获取反馈统计
   */
  getFeedbackStats(): FeedbackStats {
    return this.feedbackSvc.getStats();
  }
  
  
  addRecommendationListener(listener: RecommendationListener): void {
    this.recommendationListeners.push(listener);
  }
  
  removeRecommendationListener(listener: RecommendationListener): void {
    let idx = this.recommendationListeners.indexOf(listener);
    if (idx >= 0) this.recommendationListeners.splice(idx, 1);
  }
  
  private notifyRecommendation(rec: ContextRecommendation): void {
    // 探索模式：确保每条推荐都带当前状态摘要
    if (this.exploreMode && (!rec.exploreStateInfo || rec.exploreStateInfo.length === 0)) {
      let snapshot = this.augmentSnapshot(this.tray.getSnapshot());
      rec.exploreStateInfo = this.buildExploreStateInfo(snapshot);
      this.log.info(TAG, `[Explore] attached stateInfo (${rec.exploreStateInfo.length} chars) to rec: ${rec.rule.id}`);
    }
    this.log.info(TAG, `Recommendation: ${rec.reason} (hasStateInfo=${rec.exploreStateInfo ? rec.exploreStateInfo.length > 0 : false})`);
    // 注册卡片到 FeedbackService（启动超时定时器）
    this.feedbackSvc.onCardShown(rec);
    for (let i = 0; i < this.recommendationListeners.length; i++) {
      try {
        this.recommendationListeners[i](rec);
      } catch (err) {
        this.log.warn(TAG, 'Listener error: ' + (err as Error).message);
      }
    }
  }
  
  // ==================== 物理状态构建 & 状态变化检测 ====================

  /**
   * 构建 7-tuple 物理状态 → 场景匹配 → 检测状态变化 → 触发监听器
   * 从 periodicEvaluate 和事件驱动路径统一调用
   */
  buildPhysicalStateAndDetectChange(): void {
    if (!this.isRunning) return;
    try {
      // 传感器 → 7-tuple 状态
      this.log.debug(TAG, '[PS-DBG] step1: build');
      let ps = this.psBuilder.build();
      this.log.debug(TAG, `[PS-DBG] step2: built ${PhysicalStateBuilder.fingerprint(ps)}`);
      // 保存前一轮状态（用于状态转移显示）
      this.prevPhysicalState = this.lastPhysicalState;
      this.prevScenarioResults = this.lastScenarioResults;
      this.lastPhysicalState = ps;

      // 状态链 → 场景匹配
      this.log.debug(TAG, `[PS-DBG] step3: match (matcherType=${typeof this.scenarioMatcher}, matchFn=${typeof this.scenarioMatcher?.match}, initialized=${this.scenarioMatcher?.getScenarioCount()})`);
      let scenarioResults = this.scenarioMatcher.match(ps);
      this.log.debug(TAG, `[PS-DBG] step4: matched ${scenarioResults.length}`);
      this.lastScenarioResults = scenarioResults;

      // 注入 ps_* 字段到 DataTray (供规则引擎读取)
      this.recordedPut('ps_time', ps.time, 1.0, 'physical_state');
      this.recordedPut('ps_location', ps.location, 1.0, 'physical_state');
      this.recordedPut('ps_motion', ps.motion, 1.0, 'physical_state');
      this.recordedPut('ps_phone', ps.phone, 1.0, 'physical_state');
      this.recordedPut('ps_light', ps.light, 1.0, 'physical_state');
      this.recordedPut('ps_sound', ps.sound, 1.0, 'physical_state');
      this.recordedPut('ps_dayType', ps.dayType, 1.0, 'physical_state');

      // 注入最佳场景匹配信息
      if (scenarioResults.length > 0) {
        let best = scenarioResults[0];
        this.recordedPut('ps_scenario', best.scenarioId, 1.0, 'scenario');
        this.recordedPut('ps_scenarioCategory', best.category, 1.0, 'scenario');
        this.recordedPut('ps_chainPosition', `${best.currentStep}/${best.totalSteps}`, 1.0, 'scenario');
        this.recordedPut('ps_scenarioConfidence', best.confidence.toFixed(2), 1.0, 'scenario');
      }

      this.log.info(TAG, `[PS] ${PhysicalStateBuilder.fingerprint(ps)} | scenarios=${scenarioResults.length} active=${this.scenarioMatcher.getActiveCount()}`);

      // 检测状态变化 → 通知状态变化监听器
      this.log.debug(TAG, '[PS-DBG] step5: getActiveStates');
      let activeStates = this.scenarioMatcher.getActiveStates();
      this.log.debug(TAG, `[PS-DBG] step6: activeStates=${activeStates.length}`);
      let fpParts: string[] = [];
      for (let i = 0; i < activeStates.length; i++) {
        let st = activeStates[i];
        fpParts.push(st.scenario.id + ':' + st.confidence.toFixed(1));
      }
      let scenarioFp = fpParts.length > 0 ? fpParts.join(',') : '(none)';
      let currentFingerprint = PhysicalStateBuilder.fingerprint(ps) + '|' + scenarioFp;
      this.log.debug(TAG, `[PS-DBG] step7: fp=${currentFingerprint}`);
      if (currentFingerprint !== this.lastPhysicalFingerprint) {
        this.log.info(TAG, `[PS] State changed: ${this.lastPhysicalFingerprint} → ${currentFingerprint}`);
        this.lastPhysicalFingerprint = currentFingerprint;
        for (let j = 0; j < this.stateChangeListeners.length; j++) {
          try {
            this.stateChangeListeners[j](ps, this.prevPhysicalState);
          } catch (e) {
            this.log.warn(TAG, `stateChangeListener error: ${(e as Error).message}`);
          }
        }
      }
    } catch (err) {
      this.log.warn(TAG, `buildPhysicalStateAndDetectChange error: ${(err as Error).message}`);
    }
  }

  // ==================== 状态变化监听 ====================

  addStateChangeListener(listener: (ps: PhysicalState, prevPS: PhysicalState | undefined) => void): void {
    this.stateChangeListeners.push(listener);
  }

  // ==================== A2UI 本地分发 ====================

  addA2UIListener(listener: (type: string, content: string) => void): void {
    this.a2uiListeners.push(listener);
  }
  
  removeA2UIListener(listener: (type: string, content: string) => void): void {
    let idx = this.a2uiListeners.indexOf(listener);
    if (idx >= 0) this.a2uiListeners.splice(idx, 1);
  }
  
  dispatchA2UI(type: string, content: string): void {
    this.log.info(TAG, `dispatchA2UI: type=${type} contentLen=${content.length} listeners=${this.a2uiListeners.length}`);
    for (let i = 0; i < this.a2uiListeners.length; i++) {
      try {
        this.a2uiListeners[i](type, content);
      } catch (err) {
        this.log.warn(TAG, 'A2UI listener error: ' + (err as Error).message);
      }
    }
  }
  
  
  /**
   * 手动记录用户行为（用于学习用户习惯）
   */
  async recordUserAction(action: UserAction, accepted: boolean = true): Promise<void> {
    let ctx = await this.getCurrentContext();
    let outcome: ActionOutcome = { accepted, feedback: accepted ? 1 : 0 };
    await this.behaviorLog.logBehavior(ctx, action, outcome);
  }
  
  
  /**
   * 将用户反馈的活动记录到当前围栏的 typicalActivities 中
   */
  learnActivityForCurrentGeofence(activity: string): void {
    let geofenceSlot = this.tray.get('geofence');
    let geofenceId = geofenceSlot?.value ?? '';
    if (geofenceId.length === 0) return;

    let gf = this.geofenceMgr.getGeofence(geofenceId);
    if (!gf) return;
    if (!gf.learnedSignals) {
      gf.learnedSignals = {};
    }
    if (!gf.learnedSignals.typicalActivities) {
      gf.learnedSignals.typicalActivities = {};
    }
    let hourBucket = Math.floor(new Date().getHours() / 3) * 3; // 3h bucket
    let key = `${hourBucket}-${activity}`;
    let count = gf.learnedSignals.typicalActivities[key] ?? 0;
    gf.learnedSignals.typicalActivities[key] = count + 1;
    this.geofenceMgr.saveToFile();
    this.log.info(TAG, `Learned activity: geofence=${geofenceId} key=${key} count=${count + 1}`);
  }

  addGeofence(geofence: Geofence): void {
    this.geofenceMgr.addGeofence(geofence);
    this.geofenceMgr.saveToFile();
    this.rebindAfterGeofenceChange();
  }
  
  updateGeofence(id: string, name: string, category: GeofenceCategory): boolean {
    let result = this.geofenceMgr.updateGeofence(id, name, category);
    if (result) {
      this.rebindAfterGeofenceChange();
    }
    return result;
  }

  removeGeofence(id: string): boolean {
    let result = this.geofenceMgr.removeGeofence(id);
    if (result) {
      this.geofenceMgr.saveToFile();
      this.rebindAfterGeofenceChange();
    }
    return result;
  }

  private rebindAfterGeofenceChange(): void {
    try {
      let geofences = this.geofenceMgr.getAllGeofences();
      let bindings: GeofenceBinding[] = [];
      for (let i = 0; i < geofences.length; i++) {
        bindings.push({ id: geofences[i].id, category: geofences[i].category });
      }
      this.engine.rebindGeofences(bindings);
      this.log.info(TAG, `围栏变更后重新绑定规则，围栏数: ${geofences.length}`);
    } catch (err) {
      this.log.warn(TAG, `rebind failed: ${(err as Error).message}`);
    }
  }
  
  getAllGeofences(): Geofence[] {
    return this.geofenceMgr.getAllGeofences();
  }
  
  

  /** 获取所有围栏的已学习信号摘要（用于设置页展示） */
  getLearnedSignalsSummaries(): LearnedSignalsSummary[] {
    return this.locationFusion.getLearnedSignalsSummaries(this.geofenceMgr.getAllGeofences());
  }

  /** 清除某个围栏的已学习信号 */
  async clearLearnedSignals(geofenceId: string): Promise<void> {
    await this.locationFusion.clearLearnedSignals(geofenceId);
  }

  /** 清除所有已学习信号 */
  async clearAllLearnedSignals(): Promise<void> {
    await this.locationFusion.clearAllLearnedSignals();
  }

  // ==================== 自动地点发现 ====================

  /** WiFi 连接时记录位置：SSID + GPS 坐标 → discovered_places */
  private async recordDiscoveredWifiPlace(ssid: string): Promise<void> {
    if (!ssid || ssid.length === 0) return;

    // WiFi 分类检查：跳过热点和公共 WiFi
    let wifiType = this.classifyWifi(ssid);
    if (wifiType !== 'fixed') {
      this.log.debug(TAG, `Skip non-fixed WiFi for place discovery: ${ssid} (${wifiType})`);
      return;
    }

    let now = Date.now();
    let hasGps = this.lastLocation && this.lastLocation.latitude !== 0;
    let gpsAccurate = hasGps && this.lastLocation!.accuracy <= 200;  // 放宽到200m（室内场景）
    let lat = hasGps ? this.lastLocation!.latitude : 0;
    let lng = hasGps ? this.lastLocation!.longitude : 0;
    let discoverySource: 'gps_wifi' | 'wifi_only' = gpsAccurate ? 'gps_wifi' : 'wifi_only';

    let diagMsg = `WiFi地点发现: ssid=${ssid}, hasGps=${hasGps}, accuracy=${hasGps ? this.lastLocation!.accuracy.toFixed(0) : 'N/A'}, source=${discoverySource}`;
    this.log.info(TAG, diagMsg);


    try {
      let places = await this.getDiscoveredPlaces();

      // 查找是否已有相同 SSID 或附近的地点 (200m内)
      let existing: DiscoveredPlace | null = null;
      for (let i = 0; i < places.length; i++) {
        let p = places[i];
        // 同一 SSID
        if (p.learnedSignals?.wifiSSIDs?.includes(ssid)) {
          existing = p;
          break;
        }
        // 附近 200m（需要双方都有GPS）
        if (gpsAccurate && p.latitude !== 0) {
          let dist = this.haversineDistance(lat, lng, p.latitude, p.longitude);
          if (dist < 200 && (!p.learnedSignals?.wifiSSIDs || p.learnedSignals.wifiSSIDs.length === 0)) {
            existing = p;
            break;
          }
        }
      }

      if (existing) {
        // 更新已有地点：增加访问次数，更新时间，添加 WiFi
        existing.totalVisits++;
        existing.learnedSignals = existing.learnedSignals ?? { wifiSSIDs: [], bluetoothDevices: [], cellIds: [], typicalTimes: [], lastSeen: 0, visitCount: 0 };
        existing.learnedSignals.lastSeen = now;
        existing.learnedSignals.visitCount = (existing.learnedSignals.visitCount ?? 0) + 1;
        if (!existing.learnedSignals.wifiSSIDs!.includes(ssid)) {
          existing.learnedSignals.wifiSSIDs!.push(ssid);
        }
        // 更新 GPS（只在有精确GPS时）
        if (gpsAccurate && lat !== 0) {
          if (existing.latitude === 0) {
            existing.latitude = lat;
            existing.longitude = lng;
            existing.discoverySource = 'gps_wifi';
          } else {
            existing.latitude = (existing.latitude * (existing.totalVisits - 1) + lat) / existing.totalVisits;
            existing.longitude = (existing.longitude * (existing.totalVisits - 1) + lng) / existing.totalVisits;
          }
        }
        this.log.info(TAG, `Updated discovered place: ${existing.name}, visits=${existing.totalVisits}, wifi=${ssid}`);
      } else {
        // 新地点：用 geocoding + WiFi SSID 联合推断名称和分类
        let placeName = ssid;
        let placeCategory: GeofenceCategory = 'custom';
        // 只在有GPS时尝试geocoding
        if (gpsAccurate && lat !== 0) try {
          let geo = await GeoCodingService.getInstance().reverseGeocode(lat, lng);
          if (geo.success) {
            // 优先用 POI 名称（如"星巴克"、"YVR Airport"），否则用路名+区域
            if (geo.name && geo.name.length > 0) {
              placeName = geo.name;
            } else if (geo.address) {
              let parts: string[] = [];
              if (geo.address.road) parts.push(geo.address.road);
              if (geo.address.suburb) parts.push(geo.address.suburb);
              placeName = parts.length > 0 ? parts.join(', ') : ssid;
            }
            // 用 OSM type 推断分类
            if (geo.type && geo.type.length > 0) {
              let mappedCat = this.mapOsmTypeToCategory(geo.type);
              if (mappedCat.length > 0) {
                placeCategory = mappedCat as GeofenceCategory;
              }
            }
            this.log.info(TAG, `Geocoded: "${placeName}" (${geo.type ?? 'unknown'}) → ${placeCategory}`);
          }
        } catch (geoErr) {
          this.log.debug(TAG, `Geocoding failed, using WiFi name: ${(geoErr as Error).message}`);
        }

        let newPlace: DiscoveredPlace = {
          id: 'dp_' + now.toString(),
          name: placeName,
          latitude: lat,
          longitude: lng,
          radiusMeters: 150,
          category: placeCategory,
          metadata: ssid !== placeName ? { 'wifiSsid': ssid } : undefined,
          learnedSignals: {
            wifiSSIDs: [ssid],
            bluetoothDevices: [],
            cellIds: [],
            typicalTimes: [],
            lastSeen: now,
            visitCount: 1
          },
          discoverySource: discoverySource,
          discoveredAt: now,
          confirmAt: 0,
          visits: [],
          totalVisits: 1,
          totalStayMs: 0
        };
        places.push(newPlace);
        this.log.info(TAG, `Discovered new place: "${placeName}" (wifi=${ssid}) at ${lat.toFixed(4)},${lng.toFixed(4)}, category=${placeCategory}`);

        // A2UI: 让用户确认/命名新发现的地点
        let safeName = placeName.replace(/"/g, "'");
        let safeSsid = ssid.replace(/"/g, "'");
        let placeId = newPlace.id;
        let catOptions = JSON.stringify(['🏠 家', '🏢 公司', '💪 健身房', '🍜 餐饮', '🛒 购物', '🚇 交通', '🏨 酒店', '📍 其他', '✏️ 自定义...']);
        let nameOptions = JSON.stringify([safeName, safeSsid, '自定义...']);
        let a2uiJsonl = '{"type":"form","id":"place_name_' + placeId + '","children":[' +
          '{"type":"text","text":"📍 发现新地点","style":{"fontSize":16,"fontWeight":"bold"}},' +
          '{"type":"text","text":"WiFi: ' + safeSsid + '","style":{"fontSize":12,"color":"#666"}},' +
          (gpsAccurate ? '{"type":"text","text":"📌 ' + lat.toFixed(4) + ', ' + lng.toFixed(4) + '","style":{"fontSize":11,"color":"#999"}},' : '') +
          '{"type":"text","text":"这是什么地方？","style":{"fontSize":14}},' +
          '{"type":"choice","id":"place_name","options":' + nameOptions + '},' +
          '{"type":"input","id":"place_name_custom","placeholder":"自定义名称（选择自定义时填写）","style":{"fontSize":13},"conditional":{"field":"place_name","value":"自定义..."}},' +
          '{"type":"text","text":"分类","style":{"fontSize":14}},' +
          '{"type":"choice","id":"place_cat","options":' + catOptions + '},' +
          '{"type":"input","id":"place_cat_custom","placeholder":"自定义分类（选择自定义时填写）","style":{"fontSize":13},"conditional":{"field":"place_cat","value":"✏️ 自定义..."}},' +
          '{"type":"button","text":"✅ 确认","variant":"primary","action":{"event":{"name":"place_confirm","context":{"placeId":"' + placeId + '"}}}},' +
          '{"type":"button","text":"跳过","variant":"borderless","action":{"event":{"name":"place_confirm","context":{"placeId":"skip"}}}}' +
          ']}'
        this.dispatchA2UI('push', a2uiJsonl);
      }

      await this.saveDiscoveredPlaces(places);
    } catch (err) {
      this.log.warn(TAG, `recordDiscoveredWifiPlace error: ${(err as Error).message}`);
    }
  }

  /** OSM type → GeofenceCategory */
  private mapOsmTypeToCategory(osmType: string): string {
    let map: Record<string, string> = {
      'cafe': 'restaurant', 'restaurant': 'restaurant', 'fast_food': 'restaurant',
      'pub': 'restaurant', 'bar': 'restaurant', 'food_court': 'restaurant',
      'supermarket': 'shopping', 'convenience': 'shopping', 'mall': 'shopping',
      'department_store': 'shopping', 'clothes': 'shopping',
      'fuel': 'transit', 'parking': 'transit', 'bus_station': 'transit',
      'train_station': 'transit', 'subway_station': 'transit', 'airport': 'transit',
      'aerodrome': 'transit', 'station': 'transit', 'halt': 'transit',
      'office': 'work', 'bank': 'work', 'company': 'work',
      'gym': 'gym', 'fitness_centre': 'gym', 'sports_centre': 'gym',
      'residential': 'home', 'apartments': 'home', 'house': 'home',
      'hospital': 'custom', 'school': 'custom', 'university': 'custom',
      'library': 'custom', 'park': 'custom', 'cinema': 'custom',
    };
    return map[osmType] ?? '';
  }

  /** 获取所有已发现的地点 */
  async getDiscoveredPlaces(): Promise<DiscoveredPlace[]> {
    try {
      if (!this.context) return [];
      let prefs = await preferences.getPreferences(this.context, 'context_awareness');
      let json = await prefs.get('discovered_places', '[]') as string;
      return JSON.parse(json) as DiscoveredPlace[];
    } catch (err) {
      this.log.warn(TAG, `getDiscoveredPlaces parse error: ${(err as Error).message}`);
      return [];
    }
  }

  /** 保存已发现的地点 */
  private async saveDiscoveredPlaces(places: DiscoveredPlace[]): Promise<void> {
    if (!this.context) return;
    let prefs = await preferences.getPreferences(this.context, 'context_awareness');
    await prefs.put('discovered_places', JSON.stringify(places));
    await prefs.flush();
  }

  /** 将已发现的地点提升为正式 geofence */
  async promoteDiscoveredPlace(placeId: string, name: string, category: GeofenceCategory): Promise<boolean> {
    let places = await this.getDiscoveredPlaces();
    let place: DiscoveredPlace | null = null;
    let idx = -1;
    for (let i = 0; i < places.length; i++) {
      if (places[i].id === placeId) {
        place = places[i];
        idx = i;
        break;
      }
    }
    if (!place) return false;

    // 创建正式 geofence
    let gf: Geofence = {
      id: 'gf_' + Date.now().toString(),
      name: name,
      latitude: place.latitude,
      longitude: place.longitude,
      radiusMeters: place.radiusMeters,
      category: category,
      learnedSignals: place.learnedSignals
    };
    this.addGeofence(gf);

    // 标记为已确认
    place.confirmAt = Date.now();
    await this.saveDiscoveredPlaces(places);

    this.log.info(TAG, `Promoted discovered place "${name}" (${category}) as geofence ${gf.id}`);
    return true;
  }

  /** 删除已发现的地点 */
  async removeDiscoveredPlace(placeId: string): Promise<void> {
    let places = await this.getDiscoveredPlaces();
    let filtered: DiscoveredPlace[] = [];
    for (let i = 0; i < places.length; i++) {
      if (places[i].id !== placeId) filtered.push(places[i]);
    }
    await this.saveDiscoveredPlaces(filtered);
  }

  // ==================== 智能场景推断 ====================

  /** emoji 映射 by category */
  private categoryEmoji(category: string, name: string): string {
    // Name-based overrides for transit sub-types
    if (name.includes('机场') || name.toLowerCase().includes('airport')) return '✈️';
    if (name.includes('火车站') || name.includes('高铁站') || name.toLowerCase().includes('train')) return '🚄';

    let emojiMap: Record<string, string> = {
      'home': '🏠', 'work': '🏢', 'transit': '🚇', 'restaurant': '🍜',
      'shopping': '🛒', 'gym': '💪', 'custom': '📍',
    };
    return emojiMap[category] ?? '📍';
  }

  /**
   * 获取位置候选列表 — 融合围栏、逆地理编码、WiFi SSID
   */
  async getLocationCandidates(): Promise<LocationCandidate[]> {
    let candidates: LocationCandidate[] = [];
    let addedNames: string[] = [];  // 去重用

    let allGeofences = this.geofenceMgr.getAllGeofences();
    let location = this.lastLocation;

    // Helper: 添加候选并去重
    let addCand = (name: string, category: string, confidence: number, source: string): void => {
      if (addedNames.includes(name)) return;
      addedNames.push(name);
      let c: LocationCandidate = {
        name: name,
        category: category,
        confidence: confidence,
        source: source,
        emoji: this.categoryEmoji(category, name),
      };
      candidates.push(c);
    };

    // --- 0. 当前 DataTray 围栏（最可靠：系统已确认用户在此围栏内）---
    try {
      let geofenceSlot = this.tray.get('geofence');
      let currentGfId = geofenceSlot?.value ?? '';
      if (currentGfId.length > 0) {
        let gf = this.geofenceMgr.getGeofence(currentGfId);
        if (gf) {
          addCand(gf.name, gf.category, 0.95, 'geofence');
          this.log.info(TAG, `LocationCandidate[0]: DataTray geofence="${gf.name}" cat=${gf.category}`);
        }
      }
    } catch (err) {
      this.log.warn(TAG, `getLocationCandidates tray error: ${(err as Error).message}`);
    }

    // --- A. 已知围栏融合匹配（补充其他可能围栏）---
    try {
      let confidenceMap = await this.locationFusion.getLocationConfidence(allGeofences, location);
      let entries: GeofenceConfEntry[] = [];
      for (let i = 0; i < allGeofences.length; i++) {
        let gf = allGeofences[i];
        let conf = confidenceMap.get(gf.id) ?? 0;
        if (conf > 0.15) {  // 低阈值：让更多候选进入列表
          let entry: GeofenceConfEntry = { gf: gf, conf: conf };
          entries.push(entry);
        }
      }
      entries.sort((a, b) => b.conf - a.conf);
      for (let i = 0; i < entries.length && i < 3; i++) {
        let gf = entries[i].gf;
        addCand(gf.name, gf.category, entries[i].conf, 'geofence');
      }
    } catch (err) {
      this.log.warn(TAG, `getLocationCandidates fusion error: ${(err as Error).message}`);
    }

    // --- B. GPS 逆地理编码（始终尝试，获取实际地名）---
    if (location && location.latitude !== 0) {
      try {
        let geo = GeoCodingService.getInstance();
        let result = await geo.reverseGeocode(location.latitude, location.longitude);
        if (result.success && result.name) {
          let cat = result.category ?? 'custom';
          let conf = candidates.length > 0 ? 0.4 : 0.6;
          addCand(result.name, cat, conf, 'geocode');
          this.log.info(TAG, `LocationCandidate[geocode]: name="${result.name}" cat=${cat}`);
        }
      } catch (err) {
        this.log.warn(TAG, `getLocationCandidates geocode error: ${(err as Error).message}`);
      }
    }

    // --- C. WiFi SSID 直接匹配 ---
    try {
      let currentSsid = this.lastWifiSsid;
      if (currentSsid.length > 0) {
        for (let i = 0; i < allGeofences.length; i++) {
          let gf = allGeofences[i];
          let wifiList = gf.learnedSignals?.wifiSSIDs ?? [];
          for (let j = 0; j < wifiList.length; j++) {
            if (wifiList[j] === currentSsid) {
              addCand(gf.name, gf.category, 0.4, 'wifi');
              break;
            }
          }
        }
      }
    } catch (err) {
      this.log.warn(TAG, `getLocationCandidates wifi error: ${(err as Error).message}`);
    }

    // --- D. 兜底：如果没有任何推断结果，用时间+运动状态生成默认候选 ---
    if (candidates.length === 0) {
      this.log.info(TAG, `LocationCandidate: no inference results, using defaults`);
      let hour = new Date().getHours();
      let motion = this.lastMotionState;
      // 根据运动状态
      if (motion === 'driving') {
        addCand(I18n.t('ctx.status.driving'), 'transit', 0.3, 'infer');
      }
      if (motion === 'walking') {
        addCand('在路上', 'transit', 0.3, 'infer');
      }
      // 根据时间推测：晚上大概率在家
      if (hour >= 21 || hour <= 7) {
        addCand('家', 'home', 0.3, 'infer');
      } else if (hour >= 9 && hour <= 18) {
        addCand('公司', 'work', 0.25, 'infer');
      }
      // 添加通用选项
      addCand('家', 'home', 0.2, 'infer');
      addCand('公司', 'work', 0.2, 'infer');
      addCand('餐厅', 'restaurant', 0.15, 'infer');
      addCand('在路上', 'transit', 0.15, 'infer');
    }

    // Sort by confidence descending, limit to 4 + "其他"
    candidates.sort((a, b) => b.confidence - a.confidence);
    if (candidates.length > 4) {
      candidates = candidates.slice(0, 4);
    }
    // Append "Other"
    let other: LocationCandidate = {
      name: I18n.t('ctx.correction.otherPlace'),
      category: 'custom',
      confidence: 0,
      source: 'manual',
      emoji: '📍',
    };
    candidates.push(other);

    let locLog: string[] = [];
    for (let i = 0; i < candidates.length; i++) {
      locLog.push(candidates[i].emoji + candidates[i].name + '(' + candidates[i].confidence.toFixed(2) + ')');
    }
    this.log.info(TAG, 'LocationCandidates: ' + locLog.join(', '));
    return candidates;
  }

  /**
   * 推断活动候选列表
   */
  inferActivityCandidates(locations: LocationCandidate[]): ActivityCandidate[] {
    let candidates: ActivityCandidate[] = [];
    let addedNames: string[] = [];  // 去重用

    let now = new Date();
    let hour = now.getHours();
    let dayOfWeek = now.getDay(); // 0=Sun
    let isWeekday = dayOfWeek >= 1 && dayOfWeek <= 5;
    let motion = this.lastMotionState;

    // Top location category & name (skip "Other" at end)
    let topCategory = '';
    let topName = '';
    for (let i = 0; i < locations.length; i++) {
      if (locations[i].source !== 'manual') {
        topCategory = locations[i].category;
        topName = locations[i].name;
        break;
      }
    }

    // Helper to add candidate (explicit properties for ArkTS)
    let addAct = (actName: string, actEmoji: string, conf: number): void => {
      if (addedNames.includes(actName)) return;
      addedNames.push(actName);
      let c: ActivityCandidate = { name: actName, emoji: actEmoji, confidence: conf };
      candidates.push(c);
    };

    // --- Historical typicalActivities from current geofence ---
    let geofenceSlot = this.tray.get('geofence');
    let currentGfId = geofenceSlot?.value ?? '';
    if (currentGfId.length > 0) {
      let gf = this.geofenceMgr.getGeofence(currentGfId);
      if (gf && gf.learnedSignals?.typicalActivities) {
        let hourBucket = Math.floor(hour / 3) * 3;
        let activities = gf.learnedSignals.typicalActivities;
        let keys = Object.keys(activities);
        let bestKey = '';
        let bestCount = 0;
        for (let i = 0; i < keys.length; i++) {
          if (keys[i].startsWith(`${hourBucket}-`) && activities[keys[i]] > bestCount) {
            bestCount = activities[keys[i]];
            bestKey = keys[i];
          }
        }
        if (bestKey.length > 0 && bestCount >= 2) {
          let actName = bestKey.substring(bestKey.indexOf('-') + 1);
          addAct(actName, '⭐', 0.9);
        }
      }
    }

    // --- Rule-based inference from location + time + motion ---
    // Airport
    if (topCategory === 'transit' && (topName.includes('机场') || topName.toLowerCase().includes('airport'))) {
      addAct(I18n.t('ctx.activity.catchFlight'), '✈️', 0.85);
    }
    // Train station
    if (topCategory === 'transit' && (topName.includes('火车') || topName.includes('高铁') || topName.toLowerCase().includes('train'))) {
      addAct(I18n.t('ctx.activity.takeTrain'), '🚄', 0.85);
    }
    // Restaurant during meal times
    if (topCategory === 'restaurant' && ((hour >= 11 && hour <= 14) || (hour >= 17 && hour <= 21))) {
      addAct(I18n.t('ctx.activity.eating'), '🍽️', 0.8);
    }
    // Work during weekday hours
    if (topCategory === 'work' && isWeekday && hour >= 9 && hour <= 18) {
      addAct(I18n.t('ctx.activity.working'), '💻', 0.8);
    }
    // Home late night
    if (topCategory === 'home' && (hour >= 22 || hour <= 6)) {
      addAct(I18n.t('ctx.activity.sleeping'), '😴', 0.8);
    }
    // Home evening
    if (topCategory === 'home' && hour >= 18 && hour < 22) {
      addAct(I18n.t('ctx.activity.resting'), '🛋️', 0.7);
    }
    // Home daytime weekday (WFH)
    if (topCategory === 'home' && isWeekday && hour >= 9 && hour <= 18) {
      addAct(I18n.t('ctx.activity.working'), '💻', 0.6);
    }
    // Home daytime weekend
    if (topCategory === 'home' && !isWeekday && hour >= 8 && hour < 18) {
      addAct(I18n.t('ctx.activity.resting'), '🛋️', 0.6);
    }
    // Gym
    if (topCategory === 'gym') {
      addAct(I18n.t('ctx.activity.exercising'), '🏃', 0.8);
    }
    // Shopping + walking
    if (topCategory === 'shopping') {
      addAct(I18n.t('ctx.activity.shopping'), '🛒', 0.75);
    }
    // Driving/vehicle
    if (motion === 'driving') {
      addAct(I18n.t('ctx.activity.driving'), '🚗', 0.8);
    }
    // Commuting hours + walking/transit
    if ((hour >= 7 && hour <= 9) || (hour >= 17 && hour <= 19)) {
      if (motion === 'walking' || topCategory === 'transit') {
        addAct(I18n.t('ctx.activity.commuting'), '🚶', 0.6);
      }
    }
    // Meal times (regardless of location)
    if ((hour >= 11 && hour <= 13) || (hour >= 17 && hour <= 19)) {
      addAct(I18n.t('ctx.activity.eating'), '🍽️', 0.5);
    }

    // Always fill with context-aware defaults if too few
    if (candidates.length < 3) {
      // Time-based defaults
      if (hour >= 22 || hour <= 6) {
        addAct(I18n.t('ctx.activity.sleeping'), '😴', 0.3);
        addAct(I18n.t('ctx.activity.resting'), '🛋️', 0.25);
      } else if (isWeekday && hour >= 9 && hour <= 18) {
        addAct(I18n.t('ctx.activity.working'), '💻', 0.3);
      } else {
        addAct(I18n.t('ctx.activity.resting'), '🛋️', 0.3);
      }
      addAct(I18n.t('ctx.activity.eating'), '🍽️', 0.2);
      addAct(I18n.t('ctx.activity.commuting'), '🚶', 0.15);
      addAct(I18n.t('ctx.activity.exercising'), '🏃', 0.1);
    }

    // Sort and limit to 4 + "Other"
    candidates.sort((a, b) => b.confidence - a.confidence);
    if (candidates.length > 4) {
      candidates = candidates.slice(0, 4);
    }
    let other: ActivityCandidate = { name: I18n.t('ctx.correction.otherAct'), emoji: '📝', confidence: 0 };
    candidates.push(other);

    let actLog: string[] = [];
    for (let i = 0; i < candidates.length; i++) {
      actLog.push(candidates[i].emoji + candidates[i].name + '(' + candidates[i].confidence.toFixed(2) + ')');
    }
    this.log.info(TAG, 'ActivityCandidates: ' + actLog.join(', '));
    return candidates;
  }


  addSuggestionListener(listener: SuggestionListener): void {
    this.suggestionListeners.push(listener);
  }

  removeSuggestionListener(listener: SuggestionListener): void {
    let idx = this.suggestionListeners.indexOf(listener);
    if (idx >= 0) this.suggestionListeners.splice(idx, 1);
  }

  private notifySuggestionListeners(suggestions: GeofenceSuggestion[]): void {
    for (let i = 0; i < this.suggestionListeners.length; i++) {
      try {
        this.suggestionListeners[i](suggestions);
      } catch (err) {
        this.log.warn(TAG, 'Suggestion listener error: ' + (err as Error).message);
      }
    }
  }

  /**
   * Filter raw suggestions: remove blacklisted, deferred (< 7 days), daily-cooled,
   * and clusters that already have a matching geofence.
   */
  private filterSuggestions(raw: GeofenceSuggestion[]): GeofenceSuggestion[] {
    let now = Date.now();
    let existingGeofences = this.geofenceMgr.getAllGeofences();
    let result: GeofenceSuggestion[] = [];

    for (let i = 0; i < raw.length; i++) {
      let s = raw[i];

      // Skip blacklisted
      if (this.suggestionState.blacklist.indexOf(s.id) >= 0) continue;

      // Skip deferred (within 7 days)
      let deferredAt = this.suggestionState.deferred[s.id];
      if (deferredAt !== undefined && (now - deferredAt) < DEFER_DURATION_MS) continue;

      // Skip daily cooldown (already shown today)
      let lastShown = this.suggestionState.lastShown[s.id];
      if (lastShown !== undefined && (now - lastShown) < DAILY_COOLDOWN_MS) continue;

      // Skip if a geofence already covers this cluster (within 200m)
      let alreadyCovered = false;
      for (let gi = 0; gi < existingGeofences.length; gi++) {
        let gf = existingGeofences[gi];
        let dist = this.haversineDistance(s.latitude, s.longitude, gf.latitude, gf.longitude);
        if (dist < 200) {
          alreadyCovered = true;
          break;
        }
      }
      if (alreadyCovered) continue;

      result.push(s);
    }

    return result;
  }

  /**
   * Accept a suggestion: create geofence with the user's chosen name/category.
   */
  acceptSuggestion(suggestion: GeofenceSuggestion, name: string, category: string): void {
    let gf: Geofence = {
      id: 'auto_' + Date.now().toString(),
      name: name,
      latitude: suggestion.latitude,
      longitude: suggestion.longitude,
      radiusMeters: suggestion.radiusMeters,
      category: category as GeofenceCategory,
    };
    this.addGeofence(gf);
    this.log.info(TAG, `Accepted suggestion "${name}" as geofence ${gf.id}`);
  }

  /**
   * Ignore a suggestion permanently (blacklist).
   */
  ignoreSuggestion(clusterId: string): void {
    if (this.suggestionState.blacklist.indexOf(clusterId) < 0) {
      this.suggestionState.blacklist.push(clusterId);
    }
    // Clean up deferred/lastShown entries
    this.suggestionState.deferred[clusterId] = 0;
    this.suggestionState.lastShown[clusterId] = 0;
    this.saveSuggestionState();
    this.log.info(TAG, `Blacklisted suggestion: ${clusterId}`);
  }

  /**
   * Defer a suggestion ("以后再说") — may resurface after 7 days.
   */
  deferSuggestion(clusterId: string): void {
    this.suggestionState.deferred[clusterId] = Date.now();
    this.saveSuggestionState();
    this.log.info(TAG, `Deferred suggestion: ${clusterId}`);
  }

  /**
   * Get currently actionable suggestions (filtered).
   */
  getFilteredSuggestions(): GeofenceSuggestion[] {
    return [];
  }


  private async loadSuggestionState(): Promise<void> {
    if (!this.context) return;
    try {
      let store = await preferences.getPreferences(this.context, Constants.PREFS_GEOFENCE_SUGGEST);
      let json = (await store.get(SUGGEST_PREFS_KEY, '')) as string;
      if (json.length > 0) {
        let parsed = JSON.parse(json) as GeofenceSuggestionState;
        this.suggestionState = {
          blacklist: parsed.blacklist || [],
          deferred: parsed.deferred || {},
          lastShown: parsed.lastShown || {},
        };
      }
      this.suggestionStateLoaded = true;
      this.log.info(TAG, `Loaded suggestion state: ${this.suggestionState.blacklist.length} blacklisted`);
    } catch (err) {
      this.log.warn(TAG, `Failed to load suggestion state: ${(err as Error).message}`);
      this.suggestionStateLoaded = true;
    }
  }

  private saveSuggestionState(): void {
    if (!this.context) return;
    let json = JSON.stringify(this.suggestionState);
    preferences.getPreferences(this.context, Constants.PREFS_GEOFENCE_SUGGEST).then((store) => {
      return store.put(SUGGEST_PREFS_KEY, json).then(() => store.flush());
    }).catch((err: Error) => {
      this.log.warn(TAG, `Failed to save suggestion state: ${err.message}`);
    });
  }


  /**
   * 模拟情景智能完整 UI 提醒流程（含 cooldown 检查、notifyRecommendation、系统通知）
   * 用于调试：与 evaluateAndDeliver 走相同路径，但返回匹配结果供调用方检查。
   */
  async simulateContext(snapshot: ContextSnapshot): Promise<MatchResult[]> {
    await this.evaluateAndDeliver(snapshot);
    // 返回引擎匹配结果（evaluateAndDeliver 内部已处理推送）
    return this.engine.evaluate(snapshot, 3);
  }

  /**
   * 暴露内部状态给测试运行器 (ContextTestRunner)
   */
  getTestableState(): Record<string, string> {
    let result: Record<string, string> = {
      'currentTier': this.currentTier.toString(),
      'motionState': this.lastMotionState,
      'exploreMode': this.exploreMode.toString(),
      'isRunning': this.isRunning.toString(),
    };
    let geofenceSlot = this.tray.get('geofence');
    result['geofence'] = geofenceSlot?.value ?? '';
    let wifiSlot = this.tray.get('wifiSsid');
    result['wifiSsid'] = wifiSlot?.value ?? '';
    // WiFi mobility classification
    if (this.lastWifiSsid.length > 0) {
      result['wifiMobility'] = this.classifyWifi(this.lastWifiSsid);
    }
    return result;
  }

  getStatus(): string {
    let stats = this.behaviorLog.getStats();
    return `Running: ${this.isRunning}, ` +
           `Geofences: ${this.geofenceMgr.getAllGeofences().length}, ` +
           `Records: ${stats.totalRecords}, ` +
           `Rules: ${stats.enabledRules}/${stats.totalRules}, ` +
           `AvgConf: ${(stats.avgConfidence * 100).toFixed(0)}%`;
  }

  /** 获取数据托盘状态（调试用） */
  getTrayStatus(): TrayStatus[] {
    return this.tray.getStatus();
  }
  
  isActive(): boolean {
    return this.isRunning;
  }

  /** Access digital world service for plugin status/control */
  getDigitalWorldService(): DigitalWorldService {
    return this.digitalWorld;
  }

  getDataTray(): SensorDataTray {
    return this.tray;
  }

  /** Get last collected digital plugin data (merged key-value pairs) */
  getLastDigitalData(): Record<string, string> {
    return this.lastDigitalData;
  }

  /** Get CalendarPlugin instance for action execution */
  getCalendarPlugin(): CalendarPlugin | undefined {
    return this.digitalWorld.getCalendarPlugin();
  }

  // ==================== 传感器录制/回放 ====================

  /**
   * Wrapper for tray.put that also records events when recording is active.
   */
  private recordedPut(key: string, value: string, quality: number, source: string): void {
    this.tray.put(key, value, quality, source);
    if (this.recorder.isRecording()) {
      this.recorder.recordEvent(key, value, quality, source);
    }
  }

  /** Start sensor recording */
  startRecording(label: string): RecordingInfo | null {
    return this.recorder.startRecording(label);
  }

  /** Stop sensor recording */
  stopRecording(): RecordingInfo | null {
    return this.recorder.stopRecording();
  }

  /** Check if currently recording */
  isSensorRecording(): boolean {
    return this.recorder.isRecording();
  }

  /** Get current recording duration */
  getRecordingDuration(): number {
    return this.recorder.getRecordingDuration();
  }

  /** Get current recording event count */
  getRecordingEventCount(): number {
    return this.recorder.getEventCount();
  }

  /** List all saved recordings */
  listRecordings(): RecordingInfo[] {
    return this.recorder.listRecordings();
  }

  /** Delete a recording */
  deleteRecording(id: string): boolean {
    return this.recorder.deleteRecording(id);
  }

  /** Load a recording for replay */
  loadReplay(sessionId: string): boolean {
    return this.player.loadRecording(sessionId);
  }

  /** Start replay at given speed (1/2/5/10/0=instant) */
  startReplay(speed: number = 1): void {
    if (!this.isReplaying) {
      // 首次开始回放：保存当前真实状态
      this.isReplaying = true;
      this.preReplayMotionState = this.lastMotionState;
      this.preReplayLocation = this.lastLocation;
      this.preReplayTraySnapshot.clear();
      let keys: string[] = ['motionState', 'gpsSpeed', 'geofence', 'latitude', 'longitude',
        'locationAccuracy', 'wifiSsid', 'networkType', 'btFingerprint'];
      for (let k of keys) {
        let entry = this.tray.get(k);
        if (entry && entry.value !== null) {
          this.preReplayTraySnapshot.set(k, entry.value);
        }
      }
      this.log.info(TAG, `Replay: saved pre-replay state (motion=${this.preReplayMotionState})`);
    }
    this.player.play(speed);
  }

  /** Pause replay */
  pauseReplay(): void {
    this.player.pause();
  }

  /** Resume replay */
  resumeReplay(): void {
    this.player.resume();
  }

  /** Stop replay and restore pre-replay state */
  stopReplay(): void {
    this.player.stop();
    if (this.isReplaying) {
      this.isReplaying = false;
      // 恢复回放前的真实状态
      this.lastMotionState = this.preReplayMotionState;
      this.lastLocation = this.preReplayLocation;
      // 恢复 tray 中的关键值
      this.preReplayTraySnapshot.forEach((v: string, k: string) => {
        this.recordedPut(k, v, 0.9, 'restore');
      });
      this.preReplayTraySnapshot.clear();
      this.log.info(TAG, `Replay: restored pre-replay state (motion=${this.lastMotionState})`);
    }
  }

  /** Seek replay to timestamp */
  seekReplay(timestamp: number): void {
    this.player.seekTo(timestamp);
  }

  /** Get replay progress */
  getReplayProgress(): ReplayProgress {
    return this.player.getProgress();
  }

  /** Get replay state */
  getReplayState(): ReplayState {
    return this.player.getState();
  }

  /** Get recording time range [t0, tEnd] */
  getReplayTimeRange(): [number, number] {
    return this.player.getRecordingTimeRange();
  }

  /** Set replay progress listener */
  setReplayProgressListener(listener: ((progress: ReplayProgress) => void) | null): void {
    this.player.setProgressListener(listener);
  }

  // ==================== 7-Tuple 物理状态 API ====================

  /** 获取最新 PhysicalState 7-tuple */
  getLastPhysicalState(): PhysicalState | undefined {
    return this.lastPhysicalState;
  }

  /** 获取前一轮 PhysicalState 7-tuple */
  getPrevPhysicalState(): PhysicalState | undefined {
    return this.prevPhysicalState;
  }

  /** 获取最新场景匹配结果 */
  getLastScenarioResults(): ScenarioMatchResult[] {
    return this.lastScenarioResults;
  }

  /** 获取前一轮场景匹配结果 */
  getPrevScenarioResults(): ScenarioMatchResult[] {
    return this.prevScenarioResults;
  }

  /** 获取 ScenarioMatcher 活跃场景数 */
  getActiveScenarioCount(): number {
    return this.scenarioMatcher.getActiveCount();
  }

  /** 获取 ScenarioMatcher 实例 (用于 UI 显示) */
  getScenarioMatcher(): ScenarioMatcher {
    return this.scenarioMatcher;
  }
}
