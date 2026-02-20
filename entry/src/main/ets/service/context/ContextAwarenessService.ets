/**
 * Context Awareness Service
 * 
 * 核心服务：整合传感器、地理围栏、行为记录和推荐
 */
import { sensor } from '@kit.SensorServiceKit';
import { batteryInfo } from '@kit.BasicServicesKit';
import { wifiManager } from '@kit.ConnectivityKit';
import { common } from '@kit.AbilityKit';
import { LogService } from '../../common/LogService';
import { GeofenceManager, GeofenceEvent } from './GeofenceManager';
import { BehaviorLogger } from './BehaviorLogger';
import { ContextEngineService, ContextSnapshot, MatchResult, GeofenceBinding } from './ContextEngine';
import { LocationDiscoveryService, GeofenceSuggestion, DiscoveryStatsInfo } from './LocationDiscoveryService';
import { FeedbackService } from './FeedbackService';
import { DigitalWorldService } from './DigitalWorldService';
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
} from './ContextModels';

const TAG = 'ContextService';

export interface ContextRecommendation {
  rule: ContextRule;
  action: UserAction;
  reason: string;
}

type RecommendationListener = (rec: ContextRecommendation) => void;

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
  
  // 推荐监听器
  private recommendationListeners: RecommendationListener[] = [];
  
  // C++ 规则引擎
  private engine: ContextEngineService = ContextEngineService.getInstance();
  private evaluationTimer: number = -1;
  private static readonly EVALUATION_INTERVAL_MS = 5 * 60 * 1000;  // 5分钟评估一次
  
  // 防抖：避免重复推荐
  private lastRecommendations: Map<string, number> = new Map();
  private static readonly RECOMMENDATION_COOLDOWN_MS = 5 * 60 * 1000;  // 5分钟冷却
  
  // 位置自动发现
  private locationDiscovery: LocationDiscoveryService = LocationDiscoveryService.getInstance();
  private discoveryTimer: number = -1;
  private static readonly DISCOVERY_INTERVAL_MS = 60 * 60 * 1000;  // 1小时发现一次

  // 数字世界感知
  private digitalWorld: DigitalWorldService = DigitalWorldService.getInstance();

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
    
    // 初始化位置发现服务
    await this.locationDiscovery.init(context);
    await this.feedbackSvc.init(context);

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
      
      // 启动传感器
      this.startMotionSensors();
      
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
    this.stopPeriodicEvaluation();
    this.stopLocationDiscovery();
    this.digitalWorld.stop();

    this.isRunning = false;
    this.log.info(TAG, 'Context Awareness Service stopped');
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
    let ctx = await this.getCurrentContext();
    let snapshot = this.buildSnapshot(ctx);
    this.evaluateAndDeliver(snapshot);
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
    let suggestions = await this.locationDiscovery.runDiscovery();
    if (suggestions.length > 0) {
      this.log.info(TAG, `Location discovery found ${suggestions.length} suggestions`);
      // TODO: 可以通过通知或聊天消息告知用户
    }
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
   * 获取当前完整的环境上下文
   */
  async getCurrentContext(): Promise<EnvironmentContext> {
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
        networkType = 'cellular';  // 简化处理
      }
    } catch {
      // ignore
    }
    
    // 当前围栏
    let currentGeofence: Geofence | undefined;
    if (this.lastLocation) {
      let geofences = this.geofenceMgr.getGeofencesAtLocation(
        this.lastLocation.latitude,
        this.lastLocation.longitude
      );
      currentGeofence = geofences[0];  // 取第一个
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
      screenOn: true,  // 简化处理
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
   * 评估并推送推荐
   */
  private evaluateAndDeliver(snapshot: ContextSnapshot): void {
    let results = this.engine.evaluate(snapshot, 3);
    if (results.length === 0) return;

    let top = results[0];
    if (this.isOnCooldown(top.ruleId)) return;

    // 转换为推荐格式
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
  }

  
  private async onGeofenceEvent(event: GeofenceEvent): Promise<void> {
    this.log.info(TAG, `Geofence ${event.type}: ${event.geofence.name}`);
    
    // 更新位置
    this.lastLocation = event.location;
    
    // Push event to engine buffer for temporal/sequence rules
    let eventType = event.type === 'enter' ? 'geofence_enter' : 'geofence_exit';
    this.engine.pushEvent(eventType);
    
    // 只处理进入事件
    if (event.type !== 'enter') return;
    
    // 获取当前上下文并通过 C++ 规则引擎评估
    let ctx = await this.getCurrentContext();
    let snapshot = this.buildSnapshot(ctx);
    this.log.info(TAG, `Geofence trigger evaluate: geofence=${snapshot.geofence ?? 'none'}`);
    this.evaluateAndDeliver(snapshot);
    
    // 同时尝试旧的 BehaviorLogger 匹配（兼容过渡）
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
  
  
  getStatus(): string {
    let stats = this.behaviorLog.getStats();
    return `Running: ${this.isRunning}, ` +
           `Geofences: ${this.geofenceMgr.getAllGeofences().length}, ` +
           `Records: ${stats.totalRecords}, ` +
           `Rules: ${stats.enabledRules}/${stats.totalRules}, ` +
           `AvgConf: ${(stats.avgConfidence * 100).toFixed(0)}%`;
  }
  
  isActive(): boolean {
    return this.isRunning;
  }

  /** Access digital world service for plugin status/control */
  getDigitalWorldService(): DigitalWorldService {
    return this.digitalWorld;
  }
}
