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
import { LocationDiscoveryService, GeofenceSuggestion, DiscoveryStatsInfo } from './LocationDiscoveryService';
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
  
  // 状态历史 (用于规则判断)
  private prevMotionState: MotionState = 'unknown';
  private prevActivityState: string = 'unknown';  // 'sitting', 'sleeping', 'walking', 'active'
  private activityState: string = 'unknown';      // 当前活动状态
  private activityStateTimestamp: number = 0;     // 状态开始时间
  private activityStateDuration: number = 0;      // 持续时间(ms)
  
  // 传感器数据
  private accelerometerData: AccelerometerData = { x: 0, y: 0, z: 0, timestamp: 0 } as AccelerometerData;
  private stepCount: number = 0;
  private stepCountBaseline: number = -1;   // 今日步数基线（CAS自有计步备用）
  private stepCountBaselineDate: string = '';
  
  // 拿起手机检测
  private accelHistory: AccelSample[] = [];
  private static readonly ACCEL_HISTORY_SIZE = 30;
  private pickupStartTime: number = 0;
  private isPickupState: boolean = false;
  private lastStableGravityAngle: number = 90;  // 90° = held in hand; avoid false pickup at startup (0° = flat would trigger immediately)
  private pickupConfirmed: boolean = false;
  private stateBeforePickup: MotionState = 'stationary';
  private postPickupCooldownUntil: number = 0;
  private static readonly POST_PICKUP_COOLDOWN_MS = 8000;  // 拿起后8秒冷却，防止手持抖动误判walking
  private static readonly PICKUP_PULSE_THRESHOLD = 10.5;
  private static readonly PICKUP_ANGLE_CHANGE_THRESHOLD = 20;
  private static readonly PICKUP_MAX_DURATION_MS = 3000;
  private static readonly MOTION_MIN_DURATION_MS = 10000;
  private motionStartTime: number = 0;
  private motionStepCountStart: number = 0;
  
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
  
  // 位置自动发现
  private locationDiscovery: LocationDiscoveryService = LocationDiscoveryService.getInstance();
  private discoveryTimer: number = -1;
  private static readonly DISCOVERY_INTERVAL_MS = 60 * 60 * 1000;  // 1小时发现一次

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
  // 训练数据同步
  private trainingSync: TrainingDataSync = TrainingDataSync.getInstance();
  // 旅行信息服务 (航班/火车票)
  private travelInfoSvc: TravelInfoService = TravelInfoService.getInstance();

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

    // 初始化位置发现服务
    await this.locationDiscovery.init(context);
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

    // 监听地理围栏事件
    this.geofenceMgr.addListener((event) => this.onGeofenceEvent(event));

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
        this.startLocationDiscovery();
      } else {
        this.log.warn(TAG, 'Location permission denied, location features disabled');
      }

      // 核心功能已就绪，标记 isRunning 以启用定时评估
      this.isRunning = true;
      this.log.info(TAG, 'Context Awareness Service started (multi-tier sensing enabled)');

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
    this.stopLocationDiscovery();
    this.digitalWorld.stop();

    this.isRunning = false;
    this.log.info(TAG, 'Context Awareness Service stopped');
  }
  
  
  // ==================== WiFi 连接事件处理 ====================
  
  private onWifiDisconnected(): void {
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
      this.tray.put('wifiLost', 'true', 0.8, 'wifi');
      this.tray.put('wifiLostCategory', matchedCategory, 0.8, 'wifi');

      // 向后兼容：work 类别同时设置 wifiLostWork
      if (matchedCategory === 'work') {
        this.wifiLostWorkTimestamp = now;
        this.tray.put('wifiLostWork', 'true', 0.8, 'wifi');
      }

      this.engine.pushEvent('wifi_lost_' + matchedCategory);

      // 立即触发评估
      this.refreshTray().then(() => {
        let snapshot = this.augmentSnapshot(this.tray.getSnapshot());
        this.evaluateAndDeliver(snapshot);
      });
    }

    // 清除当前 WiFi 围栏匹配
    this.tray.put('wifiGeofence', '', 0, 'wifi');
    this.lastWifiSsid = '';
  }
  
  private onWifiConnected(): void {
    this.log.info(TAG, `onWifiConnected called, lastWifiSsid=${this.lastWifiSsid}`);
    // WiFi 重新连接，清除丢失标记
    this.wifiLostWorkTimestamp = 0;
    this.wifiLostTimestamps.clear();

    // 尝试获取当前 SSID 并匹配围栏
    try {
      wifiManager.getLinkedInfo().then((info) => {
        let ssid = info.ssid || '';
        if (ssid.startsWith('"') && ssid.endsWith('"')) {
          ssid = ssid.substring(1, ssid.length - 1);
        }
        if (ssid.length === 0) return;

        this.lastWifiSsid = ssid;
        this.tray.put('wifiSsid', ssid, 1.0, 'wifi');

        // 遍历所有围栏查找匹配
        let matched = false;
        let allGeofences = this.geofenceMgr.getAllGeofences();
        for (let gf of allGeofences) {
          let summary = this.locationFusion.getLearnedSignalsSummary(gf);
          if (summary && summary.wifiSsids.includes(ssid)) {
            this.log.info(TAG, `WiFi connected: ${ssid} matches ${gf.category} geofence`);
            this.tray.put('wifiGeofence', gf.category, 0.9, 'wifi');
            this.engine.pushEvent('wifi_arrive_' + gf.category);
            matched = true;

            // 交通场景: 检查旅行信息并显示登机牌/火车票
            if (gf.category === 'transit') {
              this.triggerTravelInfoCards(gf.name);
            }

            // 立即触发评估
            this.refreshTray().then(() => {
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
      }, { interval: 1000000000 });
      
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
    
    this.accelHistory.push({
      magnitude: magnitude,
      gravityAngle: gravityAngle,
      timestamp: this.accelerometerData.timestamp
    });
    
    if (this.accelHistory.length > ContextAwarenessService.ACCEL_HISTORY_SIZE) {
      this.accelHistory.shift();
    }
  }
  
  private detectPickup(): boolean {
    if (this.accelHistory.length < 3) return false;

    let now = Date.now();
    let recent = this.accelHistory.slice(-5);
    let current = recent[recent.length - 1];
    let prev = recent.length > 1 ? recent[recent.length - 2] : current;

    let hasPulse = current.magnitude > ContextAwarenessService.PICKUP_PULSE_THRESHOLD;
    let angleChange = Math.abs(current.gravityAngle - this.lastStableGravityAngle);
    let hasAngleChange = angleChange > ContextAwarenessService.PICKUP_ANGLE_CHANGE_THRESHOLD;

    // 只在手机之前是平放状态时才触发 pickup（区分拿起 vs 放下）
    // 平放: gravityAngle < 25°(正面朝上) 或 > 155°(正面朝下)
    let wasFlat = this.lastStableGravityAngle < 25 || this.lastStableGravityAngle > 155;

    if (hasPulse && hasAngleChange && wasFlat && !this.isPickupState) {
      this.pickupStartTime = now;
      this.isPickupState = true;
      this.pickupConfirmed = false;
      this.log.debug(TAG, `Pickup detected: mag=${current.magnitude.toFixed(1)}, angle=${angleChange.toFixed(1)}, stableAngle=${this.lastStableGravityAngle.toFixed(1)}`);
    }
    
    if (this.isPickupState) {
      let pickupDuration = now - this.pickupStartTime;
      
      let stillMoving = current.magnitude > 10.5;
      let stepsIncreased = this.stepCount > this.motionStepCountStart + 5;
      let gpsMoving = (this.lastLocation?.speed ?? 0) > 0.5;
      
      if (pickupDuration > ContextAwarenessService.MOTION_MIN_DURATION_MS && (stillMoving || stepsIncreased || gpsMoving)) {
        this.log.info(TAG, `Pickup -> Motion: duration=${pickupDuration}ms, steps=+${this.stepCount - this.motionStepCountStart}`);
        this.isPickupState = false;
        this.pickupConfirmed = false;
        return false;
      }
      
      if (pickupDuration < ContextAwarenessService.PICKUP_MAX_DURATION_MS) {
        return true;
      }
      
      if (!stillMoving && pickupDuration >= ContextAwarenessService.PICKUP_MAX_DURATION_MS) {
        this.log.info(TAG, `Pickup confirmed: brief glance, duration=${pickupDuration}ms`);
        this.pickupConfirmed = true;
        this.isPickupState = false;
        return true;
      }
      
      this.isPickupState = false;
      return false;
    }
    
    return false;
  }
  
  /**
   * 基于加速度计数据和GPS速度综合判断运动状态
   * 解决：开车/高铁匀速时加速度小但速度快的问题
   */
  private updateMotionState(): void {
    let x = this.accelerometerData.x;
    let y = this.accelerometerData.y;
    let z = this.accelerometerData.z;
    let magnitude = Math.sqrt(x * x + y * y + z * z);
    let gpsSpeed = this.lastLocation?.speed ?? 0;
    
    let isPickup = this.detectPickup();
    
    if (isPickup || this.pickupConfirmed) {
      this.tray.put('motionState', 'pickup', 0.85, 'accelerometer');

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
    
    if (gpsSpeed > 20) {
      newState = 'driving';
    } else if (gpsSpeed > 5) {
      newState = 'driving';
    } else if (gpsSpeed > 1.5) {
      newState = magnitude > 12 ? 'running' : 'walking';
    } else {
      if (magnitude < 10.5) {
        newState = 'stationary';
      } else if (magnitude < 12) {
        newState = 'walking';
      } else if (magnitude < 15) {
        newState = 'running';
      } else {
        newState = 'driving';
      }
    }
    
    // 车载蓝牙覆盖：连接车载BT时，stationary/walking → driving
    let btInVehicle = this.tray.get('bt_in_vehicle');
    if (btInVehicle && btInVehicle.value === 'true' && (newState === 'stationary' || newState === 'walking')) {
      newState = 'driving';
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

    this.tray.put('motionState', newState, 0.9, 'accelerometer');
    this.tray.put('gpsSpeed', gpsSpeed.toFixed(2), 0.85, 'gps');

    if (newState !== this.lastMotionState) {
      this.log.info(TAG, `Motion state: ${this.lastMotionState} -> ${newState}, gpsSpeed=${gpsSpeed.toFixed(1)}m/s`);

      // 放下手机：从 pickup 转为其他状态，恢复拿起前状态，启动冷却期
      if (this.lastMotionState === 'pickup') {
        this.engine.pushEvent('motion_putdown');
        // 恢复拿起前的GPS间隔，不要因为手持抖动误触walking GPS
        newState = this.stateBeforePickup;
        this.postPickupCooldownUntil = Date.now() + ContextAwarenessService.POST_PICKUP_COOLDOWN_MS;
        this.log.info(TAG, `Putdown: pickup -> restore ${newState} (cooldown ${ContextAwarenessService.POST_PICKUP_COOLDOWN_MS}ms)`);
        this.tray.put('motionState', newState, 0.9, 'accelerometer');
      }

      // 更新状态历史
      this.updateActivityState(newState);

      this.engine.pushEvent('motion_' + newState);
      this.prevMotionState = this.lastMotionState;
      this.lastMotionState = newState;
      this.adjustLocationInterval(newState);
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
        
      case 'pickup':
        // 拿起手机不改变活动状态
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
        this.tray.put('wifiSsid', ssid, 0.9, 'wifi');
        
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
   * 获取单次位置并处理 (环境信号优化：如果WiFi/BT没变且静止，跳过GPS)
   */
  private async fetchSingleLocation(): Promise<void> {
    try {
      // 先获取WiFi信息
      this.refreshWifiSync();

      // T1 + stationary + 已知围栏 → 跳过 GPS 请求
      if (this.currentTier <= 1 && this.lastMotionState === 'stationary') {
        let geofenceSlot = this.tray.get('geofence');
        if (geofenceSlot !== undefined && geofenceSlot !== null && geofenceSlot.value !== null && geofenceSlot.value.length > 0 && this.lastLocation) {
          this.log.debug(TAG, 'T1 skip GPS: stationary in known geofence');
          return;
        }
      }

      // 环境信号优化：如果静止且WiFi/BT没变，跳过GPS请求
      if (this.lastMotionState === 'stationary') {
        let envChanged = await this.checkEnvironmentChanged();
        if (!envChanged && this.lastLocation) {
          // 环境信号没变，用户可能还在同一位置，使用缓存位置
          this.log.debug(TAG, 'Environment unchanged (WiFi/BT stable), using cached location');
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
        this.tray.put('wifiSsid', ssid, 0.9, 'wifi');
        if (ssid !== this.lastWifiSsid) {
          this.log.info(TAG, `WiFi: ${this.lastWifiSsid} -> ${ssid}`);
          this.engine.pushEvent('wifi_change');
        }
        this.lastWifiSsid = ssid;
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
      this.tray.put('wifiSsid', ssid, 0.9, 'wifi');
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
    let lat = location.latitude;
    let lng = location.longitude;
    let speed = location.speed ?? 0;
    let accuracy = location.accuracy ?? 100;
    
    // 更新数据托盘
    this.tray.put('latitude', lat.toFixed(6), 1.0, 'gps');
    this.tray.put('longitude', lng.toFixed(6), 1.0, 'gps');
    this.tray.put('locationAccuracy', accuracy.toFixed(0), 0.8, 'gps');
    
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
    if (!this.isRunning) return;
    // Refresh tray with latest sensor data, then read snapshot from tray
    await this.refreshTray();

    // Evaluate sensor tier escalation/de-escalation
    this.evaluateTierEscalation();

    // Detect BT device changes and track connections
    this.detectBtChangesAndTrackConnections();

    let snapshot = this.tray.getSnapshot();
    await this.evaluateAndDeliver(snapshot);

    // Periodically save connection records (every evaluation cycle)
    this.saveConnectionRecords();
  }


  private startLocationDiscovery(): void {
    if (this.discoveryTimer !== -1) return;

    // 监听位置变化，记录到发现服务
    this.geofenceMgr.addLocationListener((location) => {
      this.log.info(TAG, `Location update: (${location.latitude.toFixed(4)}, ${location.longitude.toFixed(4)})`);
      this.locationDiscovery.recordLocation(location);
      // 检测新地点
      let ssid = this.lastWifiSsid ?? '';
      this.checkForNewPlace(location.latitude, location.longitude, ssid);
    });

    // 定时运行聚类发现
    this.discoveryTimer = setInterval(() => {
      this.runLocationDiscovery();
    }, ContextAwarenessService.DISCOVERY_INTERVAL_MS);

    this.log.info(TAG, 'Started location discovery');
  }

  private stopLocationDiscovery(): void {
    if (this.discoveryTimer !== -1) {
      clearInterval(this.discoveryTimer);
      this.discoveryTimer = -1;
      this.log.info(TAG, 'Stopped location discovery');
    }
  }

  private async runLocationDiscovery(): Promise<void> {
    if (!this.isRunning) return;
    let allSuggestions = await this.locationDiscovery.runDiscovery();
    if (allSuggestions.length === 0) return;

    let filtered = this.filterSuggestions(allSuggestions);
    if (filtered.length === 0) {
      this.log.info(TAG, `Discovery found ${allSuggestions.length} raw, all filtered out`);
      return;
    }

    // Mark as shown today
    let now = Date.now();
    for (let i = 0; i < filtered.length; i++) {
      this.suggestionState.lastShown[filtered[i].id] = now;
    }
    this.saveSuggestionState();

    this.log.info(TAG, `Emitting ${filtered.length} geofence suggestions`);
    this.notifySuggestionListeners(filtered);
  }

  /** 获取位置发现建议 */
  getLocationSuggestions(): GeofenceSuggestion[] {
    return this.locationDiscovery.getSuggestions();
  }

  /** 获取位置发现统计 */
  getLocationDiscoveryStats(): DiscoveryStatsInfo {
    return this.locationDiscovery.getStats();
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

    this.tray.put('hour', hour.toString(), 1.0, 'system');
    this.tray.put('timeOfDay', timeOfDay, 1.0, 'system');
    this.tray.put('dayOfWeek', dayOfWeek.toString(), 1.0, 'system');
    this.tray.put('isWeekend', isWeekend ? 'true' : 'false', 1.0, 'system');

    // 电池
    try {
      this.tray.put('batteryLevel', batteryInfo.batterySOC.toString(), 1.0, 'battery');
      let charging = batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.ENABLE;
      this.tray.put('isCharging', charging ? 'true' : 'false', 1.0, 'battery');
    } catch {
      // ignore
    }

    // 网络 + WiFi SSID
    try {
      if (wifiManager.isWifiActive()) {
        this.tray.put('networkType', 'wifi', 1.0, 'wifi');
        try {
          let info = await wifiManager.getLinkedInfo();
          let ssid = info.ssid || '';
          if (ssid.startsWith('"') && ssid.endsWith('"')) {
            ssid = ssid.substring(1, ssid.length - 1);
          }
          if (ssid.length > 0) {
            this.tray.put('wifiSsid', ssid, 1.0, 'wifi');
            this.lastWifiSsid = ssid;
          }
        } catch { /* ignore */ }
      } else {
        this.tray.put('networkType', 'cellular', 0.8, 'network');
      }
    } catch {
      // ignore
    }
    
    // WiFi丢失标记（遍历所有类别，有效期内）
    let nowMs = Date.now();
    this.wifiLostTimestamps.forEach((ts: number, category: string) => {
      if (nowMs - ts < ContextAwarenessService.WIFI_LOST_TTL_MS) {
        this.tray.put('wifiLost', 'true', 0.8, 'wifi');
        this.tray.put('wifiLostCategory', category, 0.8, 'wifi');
        // 向后兼容
        if (category === 'work') {
          this.tray.put('wifiLostWork', 'true', 0.8, 'wifi');
        }
      }
    });

    // 位置 / 围栏
    if (this.lastLocation) {
      this.tray.put('latitude', this.lastLocation.latitude.toString(), 1.0, 'gps');
      this.tray.put('longitude', this.lastLocation.longitude.toString(), 1.0, 'gps');

      let geofences = this.geofenceMgr.getGeofencesAtLocation(
        this.lastLocation.latitude,
        this.lastLocation.longitude
      );
      if (geofences.length > 0) {
        this.tray.put('geofence', geofences[0].id, 1.0, 'geofence');
      } else {
        // 不在任何围栏内，清除旧值（防止新地点检测被 T1 skip 阻断）
        this.tray.put('geofence', '', 0, 'geofence');
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
        this.tray.put('step_count_today', casDaily.toString(), 0.8, 'pedometer');
      }
    }

    // 运动状态（加速度计回调已写入，这里确保有值）
    if (this.lastMotionState !== 'unknown') {
      this.tray.put('motionState', this.lastMotionState, 0.9, 'accelerometer');
    }
    // 拿起手机状态（基于当前运动状态判断，不依赖瞬时检测器）
    this.tray.put('isPickup', this.lastMotionState === 'pickup' ? 'true' : 'false', 0.9, 'accelerometer');

    // Sensor tier
    this.tray.put('sensorTier', this.currentTier.toString(), 1.0, 'system');

    // BT 环境指纹 (替代不可用的 CellID)
    if (this.lastCellId.length > 0) {
      this.tray.put('btFingerprint', this.lastCellId, 0.8, 'bluetooth');
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
          this.tray.put(k, v, 0.8, source);
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
      let top = results[0];
      this.log.info(TAG, `[Explore-DBG] top match: ruleId=${top.ruleId}, confidence=${top.confidence.toFixed(2)}, cooldown=${this.isOnCooldown(top.ruleId)}, exploreTriggered=${exploreTriggered}`);
      if (!this.isOnCooldown(top.ruleId)) {
        let rec: ContextRecommendation = {
          rule: {
            id: top.ruleId,
            trigger: {} as RuleTrigger,
            action: top.action as UserAction,
            confidence: top.confidence,
            triggerCount: 0,
            acceptCount: 0,
            createdAt: Date.now(),
            updatedAt: Date.now(),
            enabled: true
          },
          action: top.action as UserAction,
          reason: `基于当前情景推荐 (${Math.round(top.confidence * 100)}% 匹配)`,
          snapshot: snapshot
        };

        this.notifyRecommendation(rec);
        this.setOnCooldown(top.ruleId);

        // 记录训练数据
        this.trainingSync.recordRuleMatch(snapshot, top.ruleId, top.action.type || 'suggestion', top.confidence);
      } else if (this.exploreMode) {
        // 探索模式：规则在 cooldown，跳过（不重复显示状态卡片）
        this.log.info(TAG, `[Explore] rule ${top.ruleId} on cooldown, skipping state display`);
      }

      // 非探索模式或已探索过的指纹：有引擎结果就够了
      if (!exploreTriggered) return;
    } else if (this.exploreMode && !exploreTriggered) {
      // 探索模式：无引擎匹配，跳过（不显示无匹配的状态卡片）
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

    let placeName = await this.reverseGeocode(lat, lng);
    this.showNewPlaceCard(lat, lng, wifiSsid, placeName);
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
  private showNewPlaceCard(lat: number, lng: number, wifiSsid: string, placeName: string): void {
    let escapedName = placeName.replace(/"/g, "'");
    let escapedWifi = wifiSsid.replace(/"/g, "'");
    
    // 推断类别
    let category = this.inferCategoryFromTime();
    
    // 自动保存地点（不需要用户确认）
    this.autoSaveNewPlace(lat, lng, wifiSsid, placeName, category);
    
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
  private autoSaveNewPlace(lat: number, lng: number, wifiSsid: string, placeName: string, category: string): void {
    try {
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
    } catch (err) {
      this.log.error(TAG, `Failed to auto-save place: ${(err as Error).message}`);
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
    this.tray.put('sensorTier', target.toString(), 1.0, 'system');
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
    this.tray.put('sensorTier', target.toString(), 1.0, 'system');
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
    this.log.info(TAG, `Geofence ${event.type}: ${event.geofence.name}`);

    // 更新位置
    this.lastLocation = event.location;

    // 写入托盘
    this.tray.put('latitude', event.location.latitude.toString(), 1.0, 'gps');
    this.tray.put('longitude', event.location.longitude.toString(), 1.0, 'gps');
    if (event.type === 'enter') {
      this.tray.put('geofence', event.geofence.id, 1.0, 'geofence');
    } else {
      // Exit: 清除围栏标记，让新地点检测和 GPS 定时器正常工作
      this.tray.put('geofence', '', 0, 'geofence');
      this.log.info(TAG, `Geofence exit: cleared tray, left ${event.geofence.name}`);
    }

    // Push event to engine buffer for temporal/sequence rules
    let eventType = event.type === 'enter' ? 'geofence_enter' : 'geofence_exit';
    this.engine.pushEvent(eventType);

    // GPS 高精度进入围栏时，学习 WiFi/BT 信号
    if (event.type === 'enter') {
      this.locationFusion.learnSignals(event.geofence.id, event.location);
    }

    // 只处理进入事件
    if (event.type !== 'enter') return;

    // 刷新托盘 + 通过 C++ 规则引擎评估
    await this.refreshTray();
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
    // 方法2: 通过 WiFi SSID 查找
    if (gfName.length === 0 && snapshot.wifiSsid && snapshot.wifiSsid.length > 0) {
      for (let i = 0; i < allGf.length; i++) {
        let signals = allGf[i].learnedSignals;
        if (signals && signals.wifiSSIDs) {
          for (let j = 0; j < signals.wifiSSIDs.length; j++) {
            if (signals.wifiSSIDs[j] === snapshot.wifiSsid) {
              gfName = allGf[i].name;
              gfCat = allGf[i].category ?? gfCat;
              break;
            }
          }
          if (gfName.length > 0) break;
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

    // Stream RL 学习阶段
    try {
      let engine = ContextEngineService.getInstance();
      let rlStatsJson = engine.getStreamRLStats();
      let rlStats: Record<string, Object> = JSON.parse(rlStatsJson) as Record<string, Object>;
      let totalSamples = (rlStats['totalSamples'] as number) ?? 0;
      let totalArms = (rlStats['totalArms'] as number) ?? 0;
      if (totalArms > 0) {
        let rlPhase = totalSamples < 10 ? '冷启动' : totalSamples < 50 ? '学习中' : '已收敛';
        lines.push(`🧠 RL: ${rlPhase} (${totalArms}模型, ${totalSamples}样本)`);
      }
    } catch { /* RL stats not available */ }

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
        let catOptions = JSON.stringify(['🏠 家', '🏢 公司', '💪 健身房', '🍜 餐饮', '🛒 购物', '🚇 交通', '🏨 酒店', '📍 其他']);
        let nameOptions = JSON.stringify([safeName, safeSsid, '自定义...']);
        let a2uiJsonl = '{"type":"form","id":"place_name_' + placeId + '","children":[' +
          '{"type":"text","text":"📍 发现新地点","style":{"fontSize":16,"fontWeight":"bold"}},' +
          '{"type":"text","text":"WiFi: ' + safeSsid + '","style":{"fontSize":12,"color":"#666"}},' +
          (gpsAccurate ? '{"type":"text","text":"📌 ' + lat.toFixed(4) + ', ' + lng.toFixed(4) + '","style":{"fontSize":11,"color":"#999"}},' : '') +
          '{"type":"text","text":"这是什么地方？","style":{"fontSize":14}},' +
          '{"type":"choice","id":"place_name","options":' + nameOptions + '},' +
          '{"type":"text","text":"分类","style":{"fontSize":14}},' +
          '{"type":"choice","id":"place_cat","options":' + catOptions + '},' +
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
    let raw = this.locationDiscovery.getSuggestions();
    return this.filterSuggestions(raw);
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
}
