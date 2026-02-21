/**
 * Context Awareness Service
 * 
 * 核心服务：整合传感器、地理围栏、行为记录和推荐
 */
import { sensor } from '@kit.SensorServiceKit';
import { batteryInfo } from '@kit.BasicServicesKit';
import { wifiManager } from '@kit.ConnectivityKit';
import { common, abilityAccessCtrl } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { LogService } from '../../common/LogService';
import { Constants } from '../../common/Constants';
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
      // 启动位置监控
      await this.geofenceMgr.startMonitoring();
      
      // 请求运动传感器权限并启动
      await this.requestMotionPermission();
      this.startMotionSensors();
      
      // 启动 WiFi 状态监听
      this.startWifiMonitoring();
      
      // 启动定时规则评估
      this.startPeriodicEvaluation();

      // 启动位置自动发现（定时聚类）
      this.startLocationDiscovery();

      // 启动数字世界感知
      this.digitalWorld.start();

      this.isRunning = true;
      this.log.info(TAG, 'Context Awareness Service started');
      return true;
    } catch (err) {
      this.log.error(TAG, `Failed to start: ${(err as Error).message}`);
      return false;
    }
  }
  
  stop(): void {
    if (!this.isRunning) return;
    
    this.geofenceMgr.stopMonitoring();
    this.stopMotionSensors();
    this.stopWifiMonitoring();
    this.stopPeriodicEvaluation();
    this.stopLocationDiscovery();
    this.digitalWorld.stop();

    this.isRunning = false;
    this.log.info(TAG, 'Context Awareness Service stopped');
  }
  
  
  // ==================== WiFi 状态监听 ====================
  
  private wifiConnectionCallback: ((state: number) => void) | undefined;
  
  private startWifiMonitoring(): void {
    try {
      this.wifiConnectionCallback = (state: number) => {
        // state: 0=disconnected, 1=connected
        if (state === 0) {
          this.onWifiDisconnected();
        } else if (state === 1) {
          this.onWifiConnected();
        }
      };
      wifiManager.on('wifiConnectionChange', this.wifiConnectionCallback);
      this.log.info(TAG, 'WiFi monitoring started');
    } catch (err) {
      this.log.warn(TAG, `WiFi monitoring failed: ${(err as Error).message}`);
    }
  }
  
  private stopWifiMonitoring(): void {
    try {
      if (this.wifiConnectionCallback) {
        wifiManager.off('wifiConnectionChange', this.wifiConnectionCallback);
        this.wifiConnectionCallback = undefined;
      }
    } catch { /* ignore */ }
  }
  
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
        ['ohos.permission.ACTIVITY_MOTION']);
      let granted = result.authResults[0] === 0;
      this.log.info(TAG, `ACTIVITY_MOTION permission: ${granted ? 'granted' : 'denied'}`);
      return granted;
    } catch (err) {
      this.log.warn(TAG, `Motion permission request failed: ${(err as Error).message}`);
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
   * 基于加速度计数据判断运动状态
   * 简化版本：使用加速度幅度
   */
  private updateMotionState(): void {
    let x = this.accelerometerData.x;
    let y = this.accelerometerData.y;
    let z = this.accelerometerData.z;
    let magnitude = Math.sqrt(x * x + y * y + z * z);
    
    // 简单阈值判断（实际应用需要更复杂的算法）
    let newState: MotionState;
    
    if (magnitude < 10.5) {
      newState = 'stationary';
    } else if (magnitude < 12) {
      newState = 'walking';
    } else if (magnitude < 15) {
      newState = 'running';
    } else {
      // 高加速度可能是车辆
      newState = this.lastLocation?.speed && this.lastLocation.speed > 5 ? 'driving' : 'walking';
    }
    
    // Always update tray with latest motion data
    this.tray.put('motionState', newState, 0.9, 'accelerometer');

    if (newState !== this.lastMotionState) {
      this.log.debug(TAG, `Motion state: ${this.lastMotionState} -> ${newState}`);
      this.engine.pushEvent('motion_' + newState);
      this.lastMotionState = newState;
    }
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
      this.locationDiscovery.recordLocation(location);
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

    // TODO [Digital World Integration]: Merge digital world data into snapshot.
    // When ContextSnapshot interface is extended with an index signature or
    // digital-specific fields, uncomment the following to enrich the snapshot:
    //
    // let digitalData = this.digitalWorld.getDigitalData();
    // let digitalKeys = Object.keys(digitalData);
    // for (let i = 0; i < digitalKeys.length; i++) {
    //   (snapshot as Record<string, string | undefined>)[digitalKeys[i]] = digitalData[digitalKeys[i]];
    // }

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


  private haversineDistance(lat1: number, lng1: number, lat2: number, lng2: number): number {
    let R = 6371000;
    let dLat = (lat2 - lat1) * Math.PI / 180;
    let dLng = (lng2 - lng1) * Math.PI / 180;
    let a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
            Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
            Math.sin(dLng / 2) * Math.sin(dLng / 2);
    let c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
    return R * c;
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
}
