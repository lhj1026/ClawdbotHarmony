/**
 * FederatedSync — 联邦学习同步服务
 *
 * 薄 ArkTS 层，核心逻辑委托给 C++ native (libfederated_sync.so)
 *
 * 职责:
 * 1. 调用 C++ 构建匿名化模型更新
 * 2. HTTP 上传到服务器 (POST /training/federated/upload)
 * 3. HTTP 下载聚合模型 (GET /training/federated/model)
 * 4. 调用 C++ 解析服务器模型，合并社区规则
 * 5. 管理联邦同步开关和周期
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { LogService } from '../../common/LogService';
import { ContextEngineService, ContextRule, ContextCondition, ContextAction } from './ContextEngine';
import { GeofenceManager } from './GeofenceManager';
import { BehaviorLogger } from './BehaviorLogger';
import federatedNative from 'libfederated_sync.so';

const TAG = 'FederatedSync';

// Typed NAPI wrappers
interface NativeInitConfig {
  deviceId: string;
}
interface ParsedModel {
  communityRulesJson: string;
  linucbState: string;
  modelVersion: number;
  participantCount: number;
  communityRuleCount: number;
}

function nativeInit(config: NativeInitConfig): void {
  federatedNative.init(config);
}
function nativeSetGeofenceCategories(json: string): void {
  federatedNative.setGeofenceCategories(json);
}
function nativeBuildModelUpdate(
  rulesJson: string, statsJson: string, linucbJson: string,
  patternsJson: string, dataPoints: number
): string {
  return federatedNative.buildModelUpdate(rulesJson, statsJson, linucbJson, patternsJson, dataPoints) as string;
}
function nativeParseFederatedModel(modelJson: string): ParsedModel {
  return federatedNative.parseFederatedModel(modelJson) as ParsedModel;
}
function nativeGetDeviceFingerprint(): string {
  return federatedNative.getDeviceFingerprint() as string;
}

/** 围栏类别条目 */
interface GeofenceCategoryEntry {
  geofenceId: string;
  category: string;
}

/** 行为模式记录（传给 C++ 聚合） */
interface BehaviorPatternRecord {
  placeCategory: string;
  timeOfDay: string;
  isWeekend: boolean;
  motionState: string;
  actionType: string;
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

/** HTTP GET 请求选项 */
interface HttpGetOptions {
  method: http.RequestMethod;
  header: HttpHeader;
  connectTimeout: number;
  readTimeout: number;
}

/** 联邦同步统计 */
export interface FederatedSyncStats {
  enabled: boolean;
  lastSyncTime: number;
  modelVersion: number;
  deviceFingerprint: string;
  lastUploadRuleCount: number;
  lastDownloadRuleCount: number;
}

export class FederatedSync {
  private static instance: FederatedSync;
  private log: LogService = LogService.getInstance();

  private context: common.UIAbilityContext | undefined;
  private syncEndpoint: string = '';
  private prefs: preferences.Preferences | undefined;

  private enabled: boolean = false;
  private lastSyncTime: number = 0;
  private modelVersion: number = 0;
  private lastUploadRuleCount: number = 0;
  private lastDownloadRuleCount: number = 0;

  // 联邦同步间隔: 6 小时
  static readonly FEDERATED_SYNC_INTERVAL: number = 6 * 60 * 60 * 1000;

  private constructor() {}

  static getInstance(): FederatedSync {
    if (!FederatedSync.instance) {
      FederatedSync.instance = new FederatedSync();
    }
    return FederatedSync.instance;
  }

  async init(context: common.UIAbilityContext, endpoint: string): Promise<void> {
    this.context = context;
    this.syncEndpoint = endpoint;

    try {
      let deviceId = context.applicationInfo?.name || 'clawdbot_device';
      nativeInit({ deviceId: deviceId });

      this.prefs = await preferences.getPreferences(context, 'federated_sync');
      this.enabled = await this.prefs.get('federated_sync_enabled', false) as boolean;
      this.lastSyncTime = await this.prefs.get('federated_last_sync', 0) as number;
      this.modelVersion = await this.prefs.get('federated_model_version', 0) as number;

      // 同步围栏类别到 C++
      this.syncGeofenceCategories();

      this.log.info(TAG, `Init: endpoint=${endpoint}, enabled=${this.enabled}, modelVersion=${this.modelVersion}`);
    } catch (err) {
      this.log.error(TAG, `Init failed: ${(err as Error).message}`);
    }
  }

  /** 设置联邦同步开关 */
  setEnabled(enabled: boolean): void {
    this.enabled = enabled;
    if (this.prefs) {
      this.prefs.put('federated_sync_enabled', enabled);
      this.prefs.flush();
    }
    this.log.info(TAG, `Federated sync ${enabled ? 'enabled' : 'disabled'}`);
  }

  isEnabled(): boolean {
    return this.enabled;
  }

  /** 检查是否到了同步时间 */
  shouldSync(): boolean {
    if (!this.enabled || !this.syncEndpoint) return false;
    let elapsed = Date.now() - this.lastSyncTime;
    return elapsed >= FederatedSync.FEDERATED_SYNC_INTERVAL;
  }

  /** 同步围栏类别映射到 C++ */
  private syncGeofenceCategories(): void {
    try {
      let geofences = GeofenceManager.getInstance().getAllGeofences();
      let categories: GeofenceCategoryEntry[] = [];
      for (let gf of geofences) {
        let entry: GeofenceCategoryEntry = { geofenceId: gf.id, category: gf.category };
        categories.push(entry);
      }
      nativeSetGeofenceCategories(JSON.stringify(categories));
    } catch (err) {
      this.log.warn(TAG, `syncGeofenceCategories: ${(err as Error).message}`);
    }
  }

  /**
   * 上传匿名化模型更新到服务器
   */
  async uploadModelUpdate(): Promise<boolean> {
    if (!this.enabled || !this.syncEndpoint) {
      this.log.debug(TAG, 'Upload skipped: disabled or no endpoint');
      return false;
    }

    try {
      // 同步最新围栏类别
      this.syncGeofenceCategories();

      let engine = ContextEngineService.getInstance();
      let rulesJson = engine.exportRules();
      let statsJson = engine.getStats();

      // LinUCB state (exported from C++ context_engine)
      let linucbJson = '';
      try {
        // exportLinUCB is exposed via the native module
        linucbJson = (engine as Object as Record<string, Function>)['exportLinUCB']
          ? '' : ''; // LinUCB 在 ContextEngine NAPI 层导出
      } catch (e) {
        // LinUCB export not critical
      }

      // 导出行为模式
      let patterns = this.exportBehaviorPatterns();
      let patternsJson = JSON.stringify(patterns);

      // 获取本地数据点数
      let dataPoints = 0;
      try {
        let statsObj: Object = JSON.parse(statsJson);
        let statsMap = statsObj as Record<string, Record<string, number>>;
        for (let key of Object.keys(statsMap)) {
          let arm = statsMap[key];
          if (arm && arm['pulls']) {
            dataPoints += arm['pulls'];
          }
        }
      } catch (e) { /* stats parse fail is ok */ }

      // C++ 构建匿名化模型更新
      let updateJson = nativeBuildModelUpdate(
        rulesJson, statsJson, linucbJson, patternsJson, dataPoints);

      // HTTP POST
      let request: http.HttpRequest = http.createHttp();
      let header: HttpHeader = { 'Content-Type': 'application/json' };
      let options: HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: header,
        extraData: updateJson,
        connectTimeout: 30000,
        readTimeout: 30000
      };

      let url = this.syncEndpoint + '/training/federated/upload';
      let response = await request.request(url, options);

      if (response.responseCode === 200 || response.responseCode === 201) {
        // 解析上传结果中的规则数
        try {
          let parsed: Object = JSON.parse(updateJson);
          let rules = (parsed as Record<string, object[]>)['rules'];
          this.lastUploadRuleCount = rules ? rules.length : 0;
        } catch (e) {
          this.lastUploadRuleCount = 0;
        }
        this.log.info(TAG, `Upload successful: ${this.lastUploadRuleCount} anonymized rules`);
        return true;
      } else {
        this.log.error(TAG, `Upload failed: HTTP ${response.responseCode}`);
        return false;
      }
    } catch (err) {
      let msg = (err instanceof Error) ? err.message : String(err);
      this.log.error(TAG, `Upload error: ${msg}`);
      return false;
    }
  }

  /**
   * 从服务器下载聚合模型并合并
   */
  async downloadAggregatedModel(): Promise<boolean> {
    if (!this.enabled || !this.syncEndpoint) {
      this.log.debug(TAG, 'Download skipped: disabled or no endpoint');
      return false;
    }

    try {
      let request: http.HttpRequest = http.createHttp();
      let header: HttpHeader = { 'Content-Type': 'application/json' };
      let options: HttpGetOptions = {
        method: http.RequestMethod.GET,
        header: header,
        connectTimeout: 30000,
        readTimeout: 30000
      };

      let url = this.syncEndpoint + '/training/federated/model?since=' + this.modelVersion;
      let response = await request.request(url, options);

      if (response.responseCode === 200) {
        let modelJson = response.result as string;
        if (!modelJson || modelJson.length === 0) {
          this.log.info(TAG, 'No new model available');
          return true;
        }

        // C++ 解析并转换社区规则
        let parsed: ParsedModel = nativeParseFederatedModel(modelJson);

        // 合并社区规则到引擎（作为 pending rules）
        this.mergeCommunityRules(parsed.communityRulesJson);

        // 更新模型版本
        this.modelVersion = parsed.modelVersion;
        this.lastDownloadRuleCount = parsed.communityRuleCount;

        this.log.info(TAG,
          `Download successful: ${parsed.communityRuleCount} community rules, ` +
          `${parsed.participantCount} participants, version=${parsed.modelVersion}`);
        return true;
      } else if (response.responseCode === 304) {
        this.log.info(TAG, 'Model not modified since last sync');
        return true;
      } else {
        this.log.error(TAG, `Download failed: HTTP ${response.responseCode}`);
        return false;
      }
    } catch (err) {
      let msg = (err instanceof Error) ? err.message : String(err);
      this.log.error(TAG, `Download error: ${msg}`);
      return false;
    }
  }

  /**
   * 执行完整同步：上传 + 下载
   */
  async sync(): Promise<boolean> {
    if (!this.shouldSync()) {
      this.log.debug(TAG, 'Federated sync skipped: not yet time');
      return false;
    }

    this.log.info(TAG, 'Starting federated sync...');

    let uploadOk = await this.uploadModelUpdate();
    let downloadOk = await this.downloadAggregatedModel();

    // 记录同步时间
    this.lastSyncTime = Date.now();
    if (this.prefs) {
      this.prefs.put('federated_last_sync', this.lastSyncTime);
      this.prefs.put('federated_model_version', this.modelVersion);
      this.prefs.flush();
    }

    this.log.info(TAG,
      `Federated sync complete: upload=${uploadOk}, download=${downloadOk}`);

    return uploadOk || downloadOk;
  }

  /** 合并社区规则到引擎 (作为 pending rules) */
  private mergeCommunityRules(engineRulesJson: string): void {
    try {
      let rules: ContextRule[] = JSON.parse(engineRulesJson) as ContextRule[];
      let engine = ContextEngineService.getInstance();

      for (let rule of rules) {
        // 确保 id 以 community_ 开头
        if (!rule.id.startsWith('community_')) {
          rule.id = 'community_' + rule.id;
        }
        // 用 addPendingRule — 用户正面反馈后才正式激活
        engine.addPendingRule(rule);
      }

      this.log.info(TAG, `Merged ${rules.length} community rules as pending`);
    } catch (err) {
      this.log.error(TAG, `mergeCommunityRules error: ${(err as Error).message}`);
    }
  }

  /** 导出行为模式记录 */
  private exportBehaviorPatterns(): BehaviorPatternRecord[] {
    let patterns: BehaviorPatternRecord[] = [];

    try {
      let behaviorLog = BehaviorLogger.getInstance();
      let allRules = behaviorLog.getAllRules();

      for (let rule of allRules) {
        if (!rule.enabled || rule.triggerCount < 2) continue;

        // 从触发条件中提取模式
        let placeCategory = 'unknown';
        let timeOfDay = 'unknown';
        let motionState = 'unknown';
        let isWeekend = false;

        if (rule.trigger.geofenceIds && rule.trigger.geofenceIds.length > 0) {
          let gf = GeofenceManager.getInstance().getGeofence(rule.trigger.geofenceIds[0]);
          if (gf) placeCategory = gf.category;
        }

        if (rule.trigger.timeOfDay && rule.trigger.timeOfDay.length > 0) {
          timeOfDay = rule.trigger.timeOfDay[0] as string;
        }

        if (rule.trigger.motionStates && rule.trigger.motionStates.length > 0) {
          motionState = rule.trigger.motionStates[0] as string;
        }

        if (rule.trigger.daysOfWeek) {
          let days = rule.trigger.daysOfWeek;
          isWeekend = days.includes(0) || days.includes(6);
        }

        patterns.push({
          placeCategory: placeCategory,
          timeOfDay: timeOfDay,
          isWeekend: isWeekend,
          motionState: motionState,
          actionType: rule.action.type
        });
      }
    } catch (err) {
      this.log.warn(TAG, `exportBehaviorPatterns: ${(err as Error).message}`);
    }

    return patterns;
  }

  /** 获取同步统计 */
  getStats(): FederatedSyncStats {
    return {
      enabled: this.enabled,
      lastSyncTime: this.lastSyncTime,
      modelVersion: this.modelVersion,
      deviceFingerprint: nativeGetDeviceFingerprint(),
      lastUploadRuleCount: this.lastUploadRuleCount,
      lastDownloadRuleCount: this.lastDownloadRuleCount
    };
  }

  /** 手动触发同步（忽略间隔检查） */
  async forceSync(): Promise<boolean> {
    if (!this.enabled) {
      this.log.warn(TAG, 'Force sync skipped: federated sync disabled');
      return false;
    }
    this.lastSyncTime = 0;  // 重置以绕过间隔检查
    return await this.sync();
  }
}
