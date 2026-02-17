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
import {
  EnvironmentContext,
  MotionState,
  TimeOfDay,
  NetworkType,
  UserAction,
  ActionOutcome,
  ContextRule,
  Geofence,
  LocationState,
} from './ContextModels';

const TAG = 'ContextService';

export interface ContextRecommendation {
  rule: ContextRule;
  action: UserAction;
  reason: string;
}

type RecommendationListener = (rec: ContextRecommendation) => void;

export class ContextAwarenessService {
  private static instance: ContextAwarenessService;
  private log: LogService = LogService.getInstance();
  
  private geofenceMgr: GeofenceManager;
  private behaviorLog: BehaviorLogger;
  
  private initialized: boolean = false;
  private isRunning: boolean = false;
  private context: common.UIAbilityContext | undefined;
  
  // 当前状态
  private currentContext: EnvironmentContext | undefined;
  private lastLocation: LocationState | undefined;
  private lastMotionState: MotionState = 'unknown';
  
  // 传感器数据
  private accelerometerData: { x: number, y: number, z: number } = { x: 0, y: 0, z: 0 };
  private stepCount: number = 0;
  
  // 推荐监听器
  private recommendationListeners: RecommendationListener[] = [];
  
  // 防抖：避免重复推荐
  private lastRecommendations: Map<string, number> = new Map();
  private static readonly RECOMMENDATION_COOLDOWN_MS = 5 * 60 * 1000;  // 5分钟冷却
  
  private constructor() {
    this.geofenceMgr = GeofenceManager.getInstance();
    this.behaviorLog = BehaviorLogger.getInstance();
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
    
    // 监听地理围栏事件
    this.geofenceMgr.addListener((event) => this.onGeofenceEvent(event));
    
    this.initialized = true;
    this.log.info(TAG, 'Context Awareness Service initialized');
  }
  
  // ==================== 服务控制 ====================
  
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
    
    this.isRunning = false;
    this.log.info(TAG, 'Context Awareness Service stopped');
  }
  
  // ==================== 传感器 ====================
  
  private startMotionSensors(): void {
    try {
      // 加速度计 - 用于运动状态检测
      sensor.on(sensor.SensorId.ACCELEROMETER, (data: sensor.AccelerometerResponse) => {
        this.accelerometerData = { x: data.x, y: data.y, z: data.z };
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
    const { x, y, z } = this.accelerometerData;
    const magnitude = Math.sqrt(x * x + y * y + z * z);
    
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
      this.lastMotionState = newState;
    }
  }
  
  // ==================== 上下文构建 ====================
  
  /**
   * 获取当前完整的环境上下文
   */
  async getCurrentContext(): Promise<EnvironmentContext> {
    const now = new Date();
    const hour = now.getHours();
    
    let timeOfDay: TimeOfDay;
    if (hour >= 5 && hour < 12) timeOfDay = 'morning';
    else if (hour >= 12 && hour < 17) timeOfDay = 'afternoon';
    else if (hour >= 17 && hour < 21) timeOfDay = 'evening';
    else timeOfDay = 'night';
    
    const dayOfWeek = now.getDay();
    const isWeekend = dayOfWeek === 0 || dayOfWeek === 6;
    
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
      const geofences = this.geofenceMgr.getGeofencesAtLocation(
        this.lastLocation.latitude,
        this.lastLocation.longitude
      );
      currentGeofence = geofences[0];  // 取第一个
    }
    
    const ctx: EnvironmentContext = {
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
  
  // ==================== 地理围栏事件 ====================
  
  private async onGeofenceEvent(event: GeofenceEvent): Promise<void> {
    this.log.info(TAG, `Geofence ${event.type}: ${event.geofence.name}`);
    
    // 更新位置
    this.lastLocation = event.location;
    
    // 只处理进入事件
    if (event.type !== 'enter') return;
    
    // 获取当前上下文
    const ctx = await this.getCurrentContext();
    
    // 查找匹配的规则
    const rules = this.behaviorLog.getMatchingRules(ctx);
    
    if (rules.length > 0) {
      const topRule = rules[0];
      
      // 检查冷却时间
      if (this.isOnCooldown(topRule.id)) {
        this.log.debug(TAG, `Rule ${topRule.id} on cooldown, skipping`);
        return;
      }
      
      // 生成推荐
      const rec: ContextRecommendation = {
        rule: topRule,
        action: topRule.action,
        reason: this.buildRecommendationReason(topRule, event.geofence),
      };
      
      this.notifyRecommendation(rec);
      this.setOnCooldown(topRule.id);
    } else {
      // 没有学习到的规则，检查是否应该主动推荐
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
        const store = geofence.metadata?.['store'] ?? 'store';
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
      const rec: ContextRecommendation = {
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
    const conf = Math.round(rule.confidence * 100);
    
    if (rule.action.type === 'show_qrcode') {
      return `到达 ${geofence.name}，显示乘车码？(${conf}% 匹配)`;
    } else if (rule.action.type === 'show_info') {
      return `到达 ${geofence.name}，为你准备了相关信息 (${conf}% 匹配)`;
    } else {
      return `基于你的习惯，推荐此操作 (${conf}% 匹配)`;
    }
  }
  
  // ==================== 推荐冷却 ====================
  
  private isOnCooldown(ruleId: string): boolean {
    const lastTime = this.lastRecommendations.get(ruleId);
    if (!lastTime) return false;
    return Date.now() - lastTime < ContextAwarenessService.RECOMMENDATION_COOLDOWN_MS;
  }
  
  private setOnCooldown(ruleId: string): void {
    this.lastRecommendations.set(ruleId, Date.now());
  }
  
  // ==================== 推荐反馈 ====================
  
  /**
   * 用户对推荐的反馈
   */
  async onRecommendationFeedback(
    rec: ContextRecommendation,
    accepted: boolean
  ): Promise<void> {
    const ctx = this.currentContext ?? await this.getCurrentContext();
    
    const outcome: ActionOutcome = {
      accepted,
      feedback: accepted ? 1 : -1,
    };
    
    // 记录行为
    await this.behaviorLog.logBehavior(ctx, rec.action, outcome);
    
    this.log.info(TAG, `Recommendation feedback: ${rec.rule.id} accepted=${accepted}`);
  }
  
  // ==================== 监听器 ====================
  
  addRecommendationListener(listener: RecommendationListener): void {
    this.recommendationListeners.push(listener);
  }
  
  removeRecommendationListener(listener: RecommendationListener): void {
    const idx = this.recommendationListeners.indexOf(listener);
    if (idx >= 0) this.recommendationListeners.splice(idx, 1);
  }
  
  private notifyRecommendation(rec: ContextRecommendation): void {
    this.log.info(TAG, `Recommendation: ${rec.reason}`);
    for (const listener of this.recommendationListeners) {
      try {
        listener(rec);
      } catch (err) {
        this.log.warn(TAG, `Listener error: ${(err as Error).message}`);
      }
    }
  }
  
  // ==================== 手动记录 ====================
  
  /**
   * 手动记录用户行为（用于学习用户习惯）
   */
  async recordUserAction(action: UserAction, accepted: boolean = true): Promise<void> {
    const ctx = await this.getCurrentContext();
    const outcome: ActionOutcome = { accepted, feedback: accepted ? 1 : 0 };
    await this.behaviorLog.logBehavior(ctx, action, outcome);
  }
  
  // ==================== 地理围栏管理 ====================
  
  addGeofence(geofence: Geofence): void {
    this.geofenceMgr.addGeofence(geofence);
    if (this.context) {
      this.geofenceMgr.saveGeofences(this.context);
    }
  }
  
  removeGeofence(id: string): boolean {
    const result = this.geofenceMgr.removeGeofence(id);
    if (result && this.context) {
      this.geofenceMgr.saveGeofences(this.context);
    }
    return result;
  }
  
  getAllGeofences(): Geofence[] {
    return this.geofenceMgr.getAllGeofences();
  }
  
  // ==================== 状态查询 ====================
  
  getStatus(): string {
    const stats = this.behaviorLog.getStats();
    return `Running: ${this.isRunning}, ` +
           `Geofences: ${this.geofenceMgr.getAllGeofences().length}, ` +
           `Records: ${stats.totalRecords}, ` +
           `Rules: ${stats.enabledRules}/${stats.totalRules}, ` +
           `AvgConf: ${(stats.avgConfidence * 100).toFixed(0)}%`;
  }
  
  isActive(): boolean {
    return this.isRunning;
  }
}
