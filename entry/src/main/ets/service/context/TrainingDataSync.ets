/**
 * TrainingDataSync — 训练数据同步服务
 * 
 * 封装 C++ training_sync 模块
 * 负责网络上传（HarmonyOS HTTP API）
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { LogService } from '../../common/LogService';
import { ContextSnapshot } from './ContextEngine';
import { FederatedSync } from './FederatedSync';
import trainingSyncNative from 'libtraining_sync.so';

const TAG = 'TrainingDataSync';

// Typed wrappers for native NAPI calls (ArkTS strict mode disallows implicit any)
interface NativeInitConfig {
  deviceId: string;
}
function nativeInit(config: NativeInitConfig): void {
  trainingSyncNative.init(config);
}
function nativeDeserialize(data: string): void {
  trainingSyncNative.deserialize(data);
}
function nativeRecordRuleMatch(record: RuleMatchRecord): void {
  trainingSyncNative.recordRuleMatch(record);
}
function nativeRecordFeedback(record: UserFeedbackRecord): void {
  trainingSyncNative.recordFeedback(record);
}
function nativeRecordStateTransition(record: StateTransitionRecord): void {
  trainingSyncNative.recordStateTransition(record);
}
function nativeRecordGeofenceFeature(record: GeofenceFeatureRecord): void {
  trainingSyncNative.recordGeofenceFeature(record);
}
function nativeGetStats(): SyncStatsInfo {
  return trainingSyncNative.getStats() as SyncStatsInfo;
}
function nativeExportPending(): string {
  return trainingSyncNative.exportPending() as string;
}
function nativeMarkSynced(ids: string[]): void {
  trainingSyncNative.markSynced(ids);
}
function nativeCleanupSynced(): void {
  trainingSyncNative.cleanupSynced();
}
function nativeSerialize(): string {
  return trainingSyncNative.serialize() as string;
}
function nativeClear(): void {
  trainingSyncNative.clear();
}
function nativeSetMaxRecords(max: number): void {
  trainingSyncNative.setMaxRecords(max);
}

/** 同步统计 */
export interface SyncStatsInfo {
  pending: number;
  synced: number;
  lastSync: number;
  totalRecords: number;
}

/** 规则匹配数据 */
export interface RuleMatchRecord {
  ruleId: string;
  action: string;
  confidence: number;
  timeOfDay: string;
  hour: number;
  motionState: string;
  prevMotionState: string;
  prevActivityState: string;
  activityDuration: number;
  geofence: string;
  wifiSsid: string;
  batteryLevel: number;
  isCharging: boolean;
}

/** 用户反馈数据 */
export interface UserFeedbackRecord {
  ruleId: string;
  feedbackType: string;
  originalValue: string;
  adjustedValue: string;
  timeOfDay: string;
  hour: number;
  motionState: string;
  prevActivityState: string;
  activityDuration: number;
  geofence: string;
}

/** 状态转换数据 */
export interface StateTransitionRecord {
  prevState: string;
  newState: string;
  duration: number;
  timeOfDay: string;
  hour: number;
  geofence: string;
  wifiSsid: string;
}

/** 围栏特征数据 */
export interface GeofenceFeatureRecord {
  geofenceId: string;
  geofenceName: string;
  wifiSsid: string;
  timeOfDay: string;
  hour: number;
  duration: number;
}

/** 用户反馈记录 (兼容旧接口) */
export interface FeedbackData {
  ruleId: string;
  feedbackType: 'accept' | 'reject' | 'adjust' | 'dismiss';
  originalValue?: string;
  adjustedValue?: string;
  context: ContextSnapshot;
  timestamp: number;
}

/** 状态转换记录 (兼容旧接口) */
export interface StateTransitionData {
  prevState: string;
  newState: string;
  duration: number;
  context: ContextSnapshot;
  timestamp: number;
}

/** 同步数据记录 (JSON解析用) */
interface SyncRecord {
  id: string;
  type: string;
  timestamp: number;
  data: Record<string, string | number | boolean>;
}

/** 同步数据响应 (JSON解析用) */
interface SyncDataResponse {
  deviceId: string;
  timestamp: number;
  records: SyncRecord[];
}

/** HTTP 请求头 */
interface HttpHeader {
  'Content-Type': string;
}

/** HTTP 请求选项 */
interface HttpRequestOptions {
  method: http.RequestMethod;
  header: HttpHeader;
  extraData: string;
  connectTimeout: number;
  readTimeout: number;
}

/** 统计返回类型 */
interface StatsResult {
  pending: number;
  synced: number;
  lastSync: number;
}

export class TrainingDataSync {
  private static instance: TrainingDataSync;
  private log: LogService = LogService.getInstance();
  
  private context: common.UIAbilityContext | undefined;
  private syncEndpoint: string = '';
  private syncEnabled: boolean = false;
  private prefs: preferences.Preferences | undefined;
  
  private static readonly SYNC_INTERVAL = 60 * 60 * 1000;
  private syncTimer: number = -1;
  
  private constructor() {}
  
  static getInstance(): TrainingDataSync {
    if (!TrainingDataSync.instance) {
      TrainingDataSync.instance = new TrainingDataSync();
    }
    return TrainingDataSync.instance;
  }
  
  async init(context: common.UIAbilityContext, endpoint: string): Promise<void> {
    this.context = context;
    this.syncEndpoint = endpoint;
    
    try {
      let deviceId = context.applicationInfo?.name || 'clawdbot_device';
      nativeInit({ deviceId: deviceId });
      
      this.prefs = await preferences.getPreferences(context, 'training_data_sync');
      this.syncEnabled = await this.prefs.get('sync_enabled', false) as boolean;
      
      let savedData = await this.prefs.get('data', '') as string;
      if (savedData.length > 0) {
        try {
          nativeDeserialize(savedData);
        } catch (deserializeErr) {
          this.log.error(TAG, `Deserialize failed, clearing corrupted data: ${(deserializeErr as Error).message}`);
          await this.prefs.delete('data');
          await this.prefs.flush();
        }
      }
      
      this.log.info(TAG, `Init: endpoint=${endpoint}, native=loaded, enabled=${this.syncEnabled}`);
    } catch (err) {
      this.log.error(TAG, `Init failed: ${(err as Error).message}`);
    }
  }
  
  setSyncEnabled(enabled: boolean): void {
    this.syncEnabled = enabled;
    
    if (this.prefs) {
      this.prefs.put('sync_enabled', enabled);
      this.prefs.flush();
    }
    
    if (enabled) {
      this.startSyncTimer();
    } else {
      this.stopSyncTimer();
    }
    
    this.log.info(TAG, `Sync ${enabled ? 'enabled' : 'disabled'}`);
  }
  
  private startSyncTimer(): void {
    if (this.syncTimer !== -1) return;
    
    this.syncTimer = setInterval(() => {
      this.sync();
    }, TrainingDataSync.SYNC_INTERVAL) as number;
  }
  
  private stopSyncTimer(): void {
    if (this.syncTimer !== -1) {
      clearInterval(this.syncTimer);
      this.syncTimer = -1;
    }
  }
  
  recordRuleMatch(snapshot: ContextSnapshot, ruleId: string, action: string, confidence: number): void {
    let record: RuleMatchRecord = {
      ruleId: ruleId,
      action: action,
      confidence: confidence,
      timeOfDay: snapshot.timeOfDay,
      hour: parseInt(snapshot.hour || '0') || 0,
      motionState: snapshot.motionState,
      prevMotionState: snapshot.prevMotionState || '',
      prevActivityState: snapshot.prevActivityState || '',
      activityDuration: parseInt(snapshot.activityDuration || '0') || 0,
      geofence: snapshot.geofence || '',
      wifiSsid: snapshot.wifiSsid || '',
      batteryLevel: parseInt(snapshot.batteryLevel || '0') || 0,
      isCharging: snapshot.isCharging === 'true'
    };
    
    nativeRecordRuleMatch(record);
    this.persist();
  }
  
  recordFeedback(data: FeedbackData): void {
    
    
    let record: UserFeedbackRecord = {
      ruleId: data.ruleId,
      feedbackType: data.feedbackType,
      originalValue: data.originalValue || '',
      adjustedValue: data.adjustedValue || '',
      timeOfDay: data.context.timeOfDay,
      hour: parseInt(data.context.hour || '0') || 0,
      motionState: data.context.motionState,
      prevActivityState: data.context.prevActivityState || '',
      activityDuration: parseInt(data.context.activityDuration || '0') || 0,
      geofence: data.context.geofence || ''
    };
    
    nativeRecordFeedback(record);
    this.persist();
  }
  
  recordStateTransition(data: StateTransitionData): void {
    
    
    let record: StateTransitionRecord = {
      prevState: data.prevState,
      newState: data.newState,
      duration: data.duration,
      timeOfDay: data.context.timeOfDay,
      hour: parseInt(data.context.hour || '0') || 0,
      geofence: data.context.geofence || '',
      wifiSsid: data.context.wifiSsid || ''
    };
    
    nativeRecordStateTransition(record);
    this.persist();
  }
  
  recordGeofenceFeature(
    geofenceId: string,
    geofenceName: string,
    wifiSsid: string,
    timeOfDay: string,
    hour: number,
    duration: number
  ): void {
    
    
    let record: GeofenceFeatureRecord = {
      geofenceId: geofenceId,
      geofenceName: geofenceName,
      wifiSsid: wifiSsid,
      timeOfDay: timeOfDay,
      hour: hour,
      duration: duration
    };
    
    nativeRecordGeofenceFeature(record);
    this.persist();
  }
  
  async sync(): Promise<boolean> {
    if (!this.syncEnabled || !this.syncEndpoint) {
      this.log.debug(TAG, 'Sync skipped: disabled or no endpoint');
      return false;
    }
    
    let stats:SyncStatsInfo = nativeGetStats();
    if (stats.pending === 0) {
      this.log.debug(TAG, 'No records to sync');
      return true;
    }
    
    let pendingJson:string = nativeExportPending();
    this.log.info(TAG, `Syncing ${stats.pending} records to ${this.syncEndpoint}`);
    
    try {
      let request: http.HttpRequest = http.createHttp();
      let header: HttpHeader = { 'Content-Type': 'application/json' };
      let options: HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: header,
        extraData: pendingJson,
        connectTimeout: 30000,
        readTimeout: 30000
      };
      let response = await request.request(this.syncEndpoint + '/training/upload', options);
      
      if (response.responseCode === 200 || response.responseCode === 201) {
        nativeMarkSynced([]);
        nativeCleanupSynced();
        this.persist();
        
        this.log.info(TAG, `Sync successful: ${stats.pending} records`);

        // 触发联邦同步（如果已启用且到达间隔）
        this.triggerFederatedSync();

        return true;
      } else {
        this.log.error(TAG, `Sync failed: HTTP ${response.responseCode}`);
        return false;
      }
    } catch (err) {
      let errorMsg = (err instanceof Error) ? err.message : String(err);
      this.log.error(TAG, `Sync error: ${errorMsg}`);
      return false;
    }
  }

  /** 在训练数据同步成功后触发联邦同步 */
  private triggerFederatedSync(): void {
    try {
      let fedSync = FederatedSync.getInstance();
      if (fedSync.shouldSync()) {
        fedSync.sync().then((ok: boolean) => {
          this.log.info(TAG, `Federated sync triggered: ${ok}`);
        }).catch((err: Error) => {
          this.log.warn(TAG, `Federated sync error: ${err.message}`);
        });
      }
    } catch (err) {
      this.log.debug(TAG, `Federated sync not available: ${(err as Error).message}`);
    }
  }
  
  getStats(): StatsResult {
    let stats: SyncStatsInfo = nativeGetStats();
    let result: StatsResult = {
      pending: stats.pending,
      synced: stats.synced,
      lastSync: stats.lastSync
    };
    return result;
  }
  
  exportData(): string {
    return nativeSerialize();
  }
  
  clear(): void {
    nativeClear();
    this.persist();
  }
  
  setMaxRecords(max: number): void {
    nativeSetMaxRecords(max);
  }
  
  private persist(): void {
    if (this.prefs) {
      let data: string = nativeSerialize();
      this.prefs.put('data', data);
      this.prefs.flush();
    }
  }
}
