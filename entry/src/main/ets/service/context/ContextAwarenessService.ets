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
} from './ContextModels';
import { LLMFallbackService } from './LLMFallbackService';

const TAG = 'ContextService';

export interface ContextRecommendation {
  rule: ContextRule;
  action: UserAction;
  reason: string;
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
}

export class ContextAwarenessService {
  private static instance: ContextAwarenessService;
  private log: LogService = LogService.getInstance();
  
  private geofenceMgr: GeofenceManager;
  private behaviorLog: BehaviorLogger;
  private feedbackSvc: FeedbackService;
  
  private initialized: boolean = false;
  private isRunning: boolean = false;
  private context: common.UIAbilityContext | undefined;
  
  // 当前状态
  private currentContext: EnvironmentContext | undefined;
  private lastLocation: LocationState | undefined;
  private lastMotionState: MotionState = 'unknown';
  
  // 传感器数据
  private accelerometerData: AccelerometerData = { x: 0, y: 0, z: 0 } as AccelerometerData;
  private stepCount: number = 0;
  
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
  private static readonly RECOMMENDATION_COOLDOWN_MS = 5 * 60 * 1000;  // 5分钟冷却
  
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
    await this.loadSuggestionState();

    // 初始化 LLM 兜底服务
    this.llmFallback.init(context);

    // 初始化数字世界感知服务
    // TODO [Digital World Integration]: DigitalWorldService provides digital context
    // (calendar events, screen state, audio scene, etc.) that enriches the ContextSnapshot.
    // Currently initialized and polled independently; data is merged in buildSnapshot().
    await this.digitalWorld.init(context);

    // 监听地理围栏事件
    this.geofenceMgr.addListener((event) => this.onGeofenceEvent(event));

    this.initialized = true;
    this.log.info(TAG, `Context Awareness Service initialized, rules: ${this.engine.getRuleCount()}`);
  }
  
  
  async start(): Promise<boolean> {
    if (this.isRunning) return true;
    if (!this.initialized) {
      this.log.error(TAG, 'Service not initialized');
      return false;
    }
    
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

      // 启动数字世界感知
      this.digitalWorld.start();

      this.isRunning = true;
      this.log.info(TAG, 'Context Awareness Service started (multi-tier sensing enabled)');
      return true;
    } catch (err) {
      this.log.error(TAG, `Failed to start: ${(err as Error).message}`);
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
        let allGeofences = this.geofenceMgr.getAllGeofences();
        for (let gf of allGeofences) {
          let summary = this.locationFusion.getLearnedSignalsSummary(gf);
          if (summary && summary.wifiSsids.includes(ssid)) {
            this.log.info(TAG, `WiFi connected: ${ssid} matches ${gf.category} geofence`);
            this.tray.put('wifiGeofence', gf.category, 0.9, 'wifi');
            this.engine.pushEvent('wifi_arrive_' + gf.category);

            // 立即触发评估
            this.refreshTray().then(() => {
              let snapshot = this.augmentSnapshot(this.tray.getSnapshot());
              this.evaluateAndDeliver(snapshot);
            });
            return;
          }
        }
      });
    } catch (err) {
      this.log.debug(TAG, `WiFi connected, get info failed: ${(err as Error).message}`);
    }
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
    return snapshot;
  }

  private async requestMotionPermission(): Promise<boolean> {
    try {
      let atManager = abilityAccessCtrl.createAtManager();
      let result = await atManager.requestPermissionsFromUser(this.context as common.UIAbilityContext,
        ['ohos.permission.ACTIVITY_MOTION', 'ohos.permission.READ_HEALTH_DATA']);
      let motionGranted = result.authResults[0] === 0;
      let healthGranted = result.authResults.length > 1 && result.authResults[1] === 0;
      this.log.info(TAG, `ACTIVITY_MOTION permission: ${motionGranted ? 'granted' : 'denied'}, READ_HEALTH_DATA: ${healthGranted ? 'granted' : 'denied'}`);
      let granted = motionGranted;
      return granted;
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
      // 加速度计 - 用于运动状态检测
      sensor.on(sensor.SensorId.ACCELEROMETER, (data: sensor.AccelerometerResponse) => {
        this.accelerometerData = { x: data.x, y: data.y, z: data.z } as AccelerometerData;
        this.updateMotionState();
      }, { interval: 1000000000 });  // 1秒采样
      
      // 计步器
      sensor.on(sensor.SensorId.PEDOMETER, (data: sensor.PedometerResponse) => {
        this.stepCount = data.steps;
        this.tray.put('stepCount', data.steps.toString(), 1.0, 'pedometer');
      }, { interval: 5000000000 });  // 5秒采样
      
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
  
  /**
   * 基于加速度计数据和GPS速度综合判断运动状态
   * 解决：开车/高铁匀速时加速度小但速度快的问题
   */
  private updateMotionState(): void {
    let x = this.accelerometerData.x;
    let y = this.accelerometerData.y;
    let z = this.accelerometerData.z;
    let magnitude = Math.sqrt(x * x + y * y + z * z);
    let gpsSpeed = this.lastLocation?.speed ?? 0;  // m/s
    
    let newState: MotionState;
    
    // 优先使用GPS速度判断（解决开车/高铁匀速问题）
    if (gpsSpeed > 20) {
      // > 72 km/h: 高铁/高速公路
      newState = 'driving';
    } else if (gpsSpeed > 5) {
      // > 18 km/h: 驾驶/骑行
      newState = 'driving';
    } else if (gpsSpeed > 1.5) {
      // > 5.4 km/h: 跑步/快走
      newState = magnitude > 12 ? 'running' : 'walking';
    } else {
      // GPS速度慢或无，用加速度判断
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
    
    // 更新数据托盘
    this.tray.put('motionState', newState, 0.9, 'accelerometer');
    this.tray.put('gpsSpeed', gpsSpeed.toFixed(2), 0.85, 'gps');

    // 运动状态变化时调整GPS采样频率
    if (newState !== this.lastMotionState) {
      this.log.info(TAG, `Motion state: ${this.lastMotionState} -> ${newState}, gpsSpeed=${gpsSpeed.toFixed(1)}m/s`);
      this.engine.pushEvent('motion_' + newState);
      this.lastMotionState = newState;
      this.adjustLocationInterval(newState);
    }
  }

  /**
   * 根据运动状态调整所有传感器采样间隔 (多级采集)
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
    
    // 调整GPS采集
    if (newGpsInterval !== this.locationIntervalMs) {
      this.locationIntervalMs = newGpsInterval;
      this.log.info(TAG, `GPS interval: ${newGpsInterval / 1000}s for ${state}`);
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
        this.tray.put('wifiSSID', ssid, 0.9, 'wifi');
        
        // 始终更新 lastWifiSsid
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
        this.accelerometerData = { x: data.x, y: data.y, z: data.z } as AccelerometerData;
        this.updateMotionState();
      }, { interval: this.accelIntervalNs });
    } catch (err) {
      this.log.warn(TAG, `Accelerometer restart failed: ${(err as Error).message}`);
    }
  }

  /**
   * 获取单次位置并处理
   */
  private fetchSingleLocation(): void {
    try {
      // 先获取WiFi信息
      this.refreshWifiSync();
      
      let request: geoLocationManager.CurrentLocationRequest = {
        priority: geoLocationManager.LocationRequestPriority.FIRST_FIX,
        scenario: geoLocationManager.LocationRequestScenario.UNSET,
        maxAccuracy: 100,
      };
      
      geoLocationManager.getCurrentLocation(request).then((location) => {
        if (location) {
          this.handleLocationUpdate(location);
        }
      }).catch((err: Error) => {
        this.log.warn(TAG, `Location fetch failed: ${err.message}`);
      });
    } catch (err) {
      this.log.warn(TAG, `Location request error: ${(err as Error).message}`);
    }
  }

  /**
   * 同步获取WiFi信息
   */
  private refreshWifiSync(): void {
    try {
      wifiManager.getLinkedInfo().then((info) => {
        let ssid = info.ssid ?? '';
        this.tray.put('wifiSSID', ssid, 0.9, 'wifi');
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
      this.tray.put('wifiSSID', ssid, 0.9, 'wifi');
      if (ssid !== this.lastWifiSsid) {
        this.log.info(TAG, `WiFi: ${this.lastWifiSsid} -> ${ssid}`);
        this.engine.pushEvent('wifi_change');
      }
      this.lastWifiSsid = ssid;
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
    let snapshot = this.tray.getSnapshot();
    await this.evaluateAndDeliver(snapshot);
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
      }
    }

    // 步数
    if (this.stepCount > 0) {
      this.tray.put('stepCount', this.stepCount.toString(), 1.0, 'pedometer');
    }

    // 运动状态（加速度计回调已写入，这里确保有值）
    if (this.lastMotionState !== 'unknown') {
      this.tray.put('motionState', this.lastMotionState, 0.9, 'accelerometer');
    }
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
      stepCount: ctx.stepCount?.toString()
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

    if (results.length > 0) {
      let top = results[0];
      if (this.isOnCooldown(top.ruleId)) return;

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
        reason: `基于当前情景推荐 (${Math.round(top.confidence * 100)}% 匹配)`
      };

      this.notifyRecommendation(rec);
      this.setOnCooldown(top.ruleId);
      return;
    }

    // C++ engine returned no matches — try LLM fallback
    this.log.info(TAG, 'No engine matches, trying LLM fallback');
    let llmResult = await this.llmFallback.analyzeContext(snapshot);
    if (!llmResult) return;

    let llmRuleId = `user_llm_${Date.now()}`;
    if (this.isOnCooldown('llm_fallback')) return;

    let rec: ContextRecommendation = {
      rule: {
        id: llmRuleId,
        trigger: {} as RuleTrigger,
        action: { type: 'show_info', target: 'llm_suggestion' } as UserAction,
        confidence: llmResult.priority === 'high' ? 0.9 : llmResult.priority === 'medium' ? 0.7 : 0.5,
        triggerCount: 0,
        acceptCount: 0,
        createdAt: Date.now(),
        updatedAt: Date.now(),
        enabled: true
      },
      action: { type: 'show_info', target: 'llm_suggestion' } as UserAction,
      reason: `${llmResult.title}: ${llmResult.content}`
    };

    this.notifyRecommendation(rec);
    this.setOnCooldown('llm_fallback');

    // === Persist LLM result as a C++ engine rule for future matching ===
    try {
      let conditions: EngineCondition[] = this.snapshotToConditions(snapshot);
      let actionPayload = `${llmResult.title}: ${llmResult.content}`;
      let cooldownMs = llmResult.priority === 'high' ? 3600000 : llmResult.priority === 'medium' ? 14400000 : 28800000;

      let newRule: EngineRule = {
        id: llmRuleId,
        name: llmResult.title,
        conditions: conditions,
        action: { id: `llm_action_${Date.now()}`, type: 'suggestion', payload: actionPayload } as EngineAction,
        priority: llmResult.priority === 'high' ? 2.0 : llmResult.priority === 'medium' ? 1.5 : 1.0,
        cooldownMs: cooldownMs,
        enabled: true,
      };

      let engine = ContextEngineService.getInstance();
      let ok = await engine.addRule(newRule);
      this.log.info(TAG, `LLM rule persisted: id=${llmRuleId}, name=${llmResult.title}, ok=${ok}, totalRules=${engine.getRuleCount()}`);
    } catch (err) {
      this.log.warn(TAG, `Failed to persist LLM rule: ${(err as Error).message}`);
    }

    // Log to BehaviorLogger with source='llm'
    let ctx = this.currentContext ?? await this.getCurrentContext();
    let llmAction: UserAction = { type: 'show_info', target: 'llm_suggestion', params: { 'source': 'llm', 'title': llmResult.title } };
    await this.behaviorLog.logBehavior(ctx, llmAction);
    this.log.info(TAG, `LLM fallback delivered and persisted: ${llmResult.title}`);
  }

  /**
   * 检测新地点：GPS + WiFi 稳定 5 分钟且不在任何已知围栏内
   */
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
      // 在已知围栏内，重置检测
      this.newPlaceDetectionStart = 0;
      return;
    }
    
    let now = Date.now();
    
    // 检查位置是否稳定（与上次记录的差异 < 100m）
    if (this.newPlaceDetectionStart > 0) {
      let drift = this.haversineDistance(lat, lng, this.newPlaceLastLat, this.newPlaceLastLng);
      if (drift > ContextAwarenessService.NEW_PLACE_MAX_DRIFT_M) {
        // 位置漂移太大，重置
        this.log.info(TAG, `New place reset: drifted ${Math.round(drift)}m`);
        this.newPlaceDetectionStart = 0;
        return;
      }
    }
    
    // 开始新检测或继续现有检测
    if (this.newPlaceDetectionStart === 0) {
      this.newPlaceDetectionStart = now;
      this.newPlaceLastLat = lat;
      this.newPlaceLastLng = lng;
      this.newPlaceWifiSsid = wifiSsid;
      this.log.info(TAG, `New place detection started at (${lat.toFixed(4)}, ${lng.toFixed(4)})`);
      return;
    }
    
    // 检查是否稳定足够时间
    let stableMs = now - this.newPlaceDetectionStart;
    if (stableMs < ContextAwarenessService.NEW_PLACE_STABLE_MS) {
      this.log.debug(TAG, `New place stable for ${Math.round(stableMs / 1000)}s, need ${ContextAwarenessService.NEW_PLACE_STABLE_MS / 1000}s`);
      return;
    }
    
    // 稳定 5 分钟，检测到新地点！
    this.log.info(TAG, `New place detected! (${lat.toFixed(4)}, ${lng.toFixed(4)}) WiFi=${wifiSsid}`);
    this.newPlaceDetectionStart = 0;  // 重置防止重复
    
    // 尝试逆地理编码获取地点名
    let placeName = await this.reverseGeocode(lat, lng);
    
    // 显示 A2UI 卡片让用户确认
    this.showNewPlaceCard(lat, lng, wifiSsid, placeName);
  }

  /**
   * 实时检测新地点（结合当前WiFi状态）
   * 停留5分钟+有WiFi连接 → 立即发现，不等聚类
   */
  private async checkForNewPlaceSmart(lat: number, lng: number): Promise<void> {
    // 同时学习当前围栏的特征（会先获取WiFi）
    await this.learnPlaceSignals(lat, lng);
    
    // 检测新地点
    await this.checkForNewPlace(lat, lng, this.lastWifiSsid);
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
          typicalTimes: [],
          lastSeen: 0,
          visitCount: 0
        };
        
        let updated = false;
        
        // 学习WiFi SSID
        if (this.lastWifiSsid && this.lastWifiSsid.length > 0) {
          if (!signals.wifiSSIDs!.includes(this.lastWifiSsid)) {
            signals.wifiSSIDs!.push(this.lastWifiSsid);
            this.log.info(TAG, `Learned WiFi for ${gf.name}: ${this.lastWifiSsid}`);
            this.notifyGeofenceFeatureLearned(gf.name, 'WiFi', this.lastWifiSsid);
            updated = true;
          }
        } else {
          this.log.debug(TAG, `No WiFi to learn for ${gf.name}`);
        }
        
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
    
    let titleText = I18n.t('context.newPlace.title');
    let wifiLabel = I18n.t('context.newPlace.wifi');
    let saveAsLabel = I18n.t('context.newPlace.saveAs');
    let renameLabel = I18n.t('context.newPlace.rename');
    let ignoreLabel = I18n.t('context.newPlace.ignore');
    
    let jsonl = '{"type":"form","id":"new_place_' + Date.now() + '","children":[' +
      '{"type":"text","text":"📍 ' + titleText + '","style":{"fontSize":18,"fontWeight":"bold"}},' +
      '{"type":"text","text":"' + escapedName + '"},' +
      '{"type":"text","text":"' + wifiLabel + ': ' + escapedWifi + '","style":{"fontSize":12,"color":"#666"}}},' +
      '{"type":"row","children":[' +
        '{"type":"button","label":"✅ ' + saveAsLabel + ' ' + category + '","action":{"event":{"name":"new_place_save","context":{"lat":' + lat + ',"lng":' + lng + ',"wifi":"' + escapedWifi + '","name":"' + escapedName + '","category":"' + category + '"}}},"style":"primary"},' +
        '{"type":"button","label":"✏️ ' + renameLabel + '","action":{"event":{"name":"new_place_rename","context":{"lat":' + lat + ',"lng":' + lng + '}}}},"style":"secondary"},' +
        '{"type":"button","label":"❌ ' + ignoreLabel + '","action":{"event":{"name":"new_place_ignore","context":{}}}},"style":"secondary"}' +
      ']}]}';
    
    this.dispatchA2UI('push', jsonl);
    this.log.info(TAG, `New place card shown: ${placeName}`);
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

  
  private async onGeofenceEvent(event: GeofenceEvent): Promise<void> {
    this.log.info(TAG, `Geofence ${event.type}: ${event.geofence.name}`);

    // 更新位置
    this.lastLocation = event.location;

    // 写入托盘
    this.tray.put('latitude', event.location.latitude.toString(), 1.0, 'gps');
    this.tray.put('longitude', event.location.longitude.toString(), 1.0, 'gps');
    if (event.type === 'enter') {
      this.tray.put('geofence', event.geofence.id, 1.0, 'geofence');
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
    
    this.evaluateAndDeliver(snapshot);

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
    this.log.info(TAG, 'Recommendation: ' + rec.reason);
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

  /** Get last collected digital plugin data (merged key-value pairs) */
  getLastDigitalData(): Record<string, string> {
    return this.lastDigitalData;
  }
}
