/**
 * LocationFusionService — 多源位置融合
 *
 * 融合 GPS、WiFi SSID、蓝牙设备三种信号，输出每个已知地点的置信度 0~1。
 * 当 GPS 漂移（室内/城市峡谷）时，WiFi/BT 信号可独立确认位置。
 *
 * 学习机制：GPS 高精度确认用户在某围栏内时，自动记录当前 WiFi SSID
 * 和附近 BT 设备。累积 3 次以上观测后，该信号可用于位置确认。
 */
import { wifiManager, connection } from '@kit.ConnectivityKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { LogService } from '../../common/LogService';
import { Geofence, LocationState } from './ContextModels';
import * as LocationFusionNative from './LocationFusionNative';
import * as GeoUtils from './GeoUtils';

const TAG = 'LocationFusion';

// ==================== 数据结构 ====================

/** 单个围栏的已学习信号 */
interface LearnedSignals {
  wifiSsids: Map<string, number>;    // ssid → 观测次数
  btDevices: Map<string, number>;    // deviceName → 观测次数
  totalObservations: number;         // 总观测次数
}

/** 序列化格式（preferences 存储用） */
interface LearnedSignalEntry {
  key: string;
  count: number;
}

interface LearnedSignalsJson {
  wifiSsids: LearnedSignalEntry[];
  btDevices: LearnedSignalEntry[];
  totalObservations: number;
}

/** 每个围栏的融合结果 */
export interface FusionResult {
  geofenceId: string;
  confidence: number;        // 0~1 融合置信度
  gpsConfidence: number;     // GPS 分项
  wifiConfidence: number;    // WiFi 分项
  btConfidence: number;      // BT 分项
  source: string;            // 主要来源: 'gps' | 'wifi' | 'bt'
}

/** 已学习信号的摘要（用于 UI 展示） */
export interface LearnedSignalsSummary {
  geofenceId: string;
  geofenceName: string;
  wifiSsids: string[];
  btDevices: string[];
  totalObservations: number;
}

// ==================== 常量 ====================

/** GPS 置信度衰减参数 */
const GPS_HIGH_CONFIDENCE_RADIUS = 50;     // 50m 内 → 1.0
const GPS_DECAY_SCALE = 200;               // 指数衰减尺度
const GPS_MIN_CONFIDENCE = 0.05;           // 最低 GPS 置信度

/** WiFi/BT 匹配置信度 */
const WIFI_MATCH_CONFIDENCE = 0.95;
const WIFI_NO_MATCH_CONFIDENCE = 0.1;
const BT_MATCH_CONFIDENCE = 0.8;

/** 学习参数 */
const LEARNING_GPS_ACCURACY_THRESHOLD = 30;  // GPS 精度 < 30m 时才学习
const LEARNING_MIN_OBSERVATIONS = 3;         // 至少 3 次观测后信号可用
const LEARNING_COOLDOWN_MS = 5 * 60 * 1000;  // 同一围栏学习间隔 5 分钟

/** GPS 质量阈值 */
const GPS_LOW_QUALITY_ACCURACY = 100;        // 精度 > 100m 视为低质量

export class LocationFusionService {
  private static instance: LocationFusionService;
  private log: LogService = LogService.getInstance();

  private initialized: boolean = false;
  private prefsStore: preferences.Preferences | null = null;

  // 每个围栏的已学习信号
  private learnedSignals: Map<string, LearnedSignals> = new Map();

  // 学习冷却：geofenceId → 上次学习时间戳
  private learningCooldown: Map<string, number> = new Map();

  private constructor() {}

  static getInstance(): LocationFusionService {
    if (!LocationFusionService.instance) {
      LocationFusionService.instance = new LocationFusionService();
    }
    return LocationFusionService.instance;
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.initialized) return;

    try {
      this.prefsStore = await preferences.getPreferences(context, 'location_fusion');
      await this.loadLearnedSignals();
      this.initialized = true;
      this.log.info(TAG, `Initialized, learned signals for ${this.learnedSignals.size} geofences`);
    } catch (err) {
      this.log.warn(TAG, `Init error: ${(err as Error).message}`);
    }
  }

  // ==================== 核心融合 ====================

  /**
   * 将 Map<string, number> 转为 Record<string, number>（C++ NAPI 需要）
   */
  private mapToRecord(map: Map<string, number>): Record<string, number> {
    let rec: Record<string, number> = {};
    map.forEach((v: number, k: string) => { rec[k] = v; });
    return rec;
  }

  /**
   * 将已学习信号转为 C++ NAPI 格式
   */
  private toNativeSignals(gfId: string): LocationFusionNative.LearnedSignals {
    let signals = this.learnedSignals.get(gfId);
    if (!signals) {
      return { wifiSsids: {}, btDevices: {}, totalObservations: 0 };
    }
    return {
      wifiSsids: this.mapToRecord(signals.wifiSsids),
      btDevices: this.mapToRecord(signals.btDevices),
      totalObservations: signals.totalObservations,
    };
  }

  /**
   * 获取每个已知围栏的位置置信度（使用 C++ 融合引擎）
   */
  async getLocationConfidence(
    geofences: Geofence[],
    location: LocationState | undefined
  ): Promise<Map<string, number>> {
    let result: Map<string, number> = new Map();

    let currentWifiSsid = await this.getCurrentWifiSsid();
    let currentBtDevices = this.getCurrentBtDevices();
    let gpsAccuracy = location?.accuracy ?? 9999;

    // 构建 C++ 批量计算参数
    let geofenceDistances: LocationFusionNative.GeofenceDistance[] = [];
    for (let i = 0; i < geofences.length; i++) {
      let gf = geofences[i];
      let dist = location
        ? this.haversineDistance(location.latitude, location.longitude, gf.latitude, gf.longitude)
        : 99999;
      let gfd: LocationFusionNative.GeofenceDistance = { id: gf.id, distance: dist };
      geofenceDistances.push(gfd);
    }

    // 构建 allSignals
    let allSignals: Record<string, LocationFusionNative.LearnedSignals> = {};
    for (let i = 0; i < geofences.length; i++) {
      allSignals[geofences[i].id] = this.toNativeSignals(geofences[i].id);
    }

    // 调用 C++ 批量融合
    let allParams: LocationFusionNative.AllConfidencesParams = {
      geofenceDistances: geofenceDistances,
      gpsAccuracy: gpsAccuracy,
      currentWifiSsid: currentWifiSsid,
      currentBtDevices: currentBtDevices,
      allSignals: allSignals,
    };
    let fusionResults = LocationFusionNative.calculateAllConfidences(allParams);

    for (let i = 0; i < fusionResults.length; i++) {
      result.set(fusionResults[i].geofenceId, fusionResults[i].confidence);
    }

    return result;
  }

  /**
   * 获取最佳匹配的围栏（融合后置信度最高且 > 0.5）
   */
  async getBestMatch(
    geofences: Geofence[],
    location: LocationState | undefined
  ): Promise<FusionResult | null> {
    let currentWifiSsid = await this.getCurrentWifiSsid();
    let currentBtDevices = this.getCurrentBtDevices();

    let best: FusionResult | null = null;
    let bestConf = 0;

    for (let i = 0; i < geofences.length; i++) {
      let gf = geofences[i];
      let dist = location
        ? this.haversineDistance(location.latitude, location.longitude, gf.latitude, gf.longitude)
        : 99999;

      // 调用 C++ 单个融合计算
      let params: LocationFusionNative.ConfidenceParams = {
        geofenceId: gf.id,
        distance: dist,
        gpsAccuracy: location?.accuracy ?? 9999,
        currentWifiSsid: currentWifiSsid,
        currentBtDevices: currentBtDevices,
        signals: this.toNativeSignals(gf.id),
      };
      let fr = LocationFusionNative.calculateConfidence(params);

      if (fr.confidence > bestConf) {
        bestConf = fr.confidence;
        best = {
          geofenceId: fr.geofenceId,
          confidence: fr.confidence,
          gpsConfidence: fr.gpsConfidence,
          wifiConfidence: fr.wifiConfidence,
          btConfidence: fr.btConfidence,
          source: fr.source,
        };
      }
    }

    if (best && best.confidence > 0.5) {
      return best;
    }
    return Promise.resolve(null);
  }

  // ==================== 信号置信度计算（已迁移到 C++ location_fusion） ====================
  // calcGpsConfidence, calcWifiConfidence, calcBtConfidence 已由 C++ 实现

  // ==================== 信号获取 ====================

  private async getCurrentWifiSsid(): Promise<string> {
    try {
      if (!wifiManager.isWifiActive()) return '';
      let info = await wifiManager.getLinkedInfo();
      let ssid: string = info.ssid || '';
      // 去掉可能的引号包裹
      if (ssid.startsWith('"') && ssid.endsWith('"')) {
        ssid = ssid.substring(1, ssid.length - 1);
      }
      return ssid;
    } catch {
      return '';
    }
  }

  private getCurrentBtDevices(): string[] {
    // 使用已配对设备列表获取蓝牙设备名称
    try {
      let pairedDevices = connection.getPairedDevices();
      let names: string[] = [];
      for (let i = 0; i < pairedDevices.length; i++) {
        try {
          let deviceName = connection.getRemoteDeviceName(pairedDevices[i]);
          if (deviceName && deviceName.length > 0) {
            names.push(deviceName);
          }
        } catch {
          // Device info unavailable, skip
        }
      }
      return names;
    } catch {
      return [];
    }
  }

  // ==================== 自动学习 ====================

  /**
   * 当 GPS 高精度确认用户在某围栏内时，学习当前 WiFi/BT 信号
   *
   * 调用时机：GeofenceManager 确认进入围栏，且 GPS 精度 < 30m
   */
  async learnSignals(geofenceId: string, location: LocationState): Promise<void> {
    // 精度检查
    if (location.accuracy > LEARNING_GPS_ACCURACY_THRESHOLD) return;

    // 冷却检查
    let lastLearn = this.learningCooldown.get(geofenceId);
    if (lastLearn !== undefined && Date.now() - lastLearn < LEARNING_COOLDOWN_MS) return;

    let currentSsid = await this.getCurrentWifiSsid();
    let currentBt = this.getCurrentBtDevices();

    // 没有可学习的信号
    if (currentSsid.length === 0 && currentBt.length === 0) return;

    let signals = this.learnedSignals.get(geofenceId);
    if (!signals) {
      signals = {
        wifiSsids: new Map(),
        btDevices: new Map(),
        totalObservations: 0,
      };
      this.learnedSignals.set(geofenceId, signals);
    }

    // 记录 WiFi SSID
    if (currentSsid.length > 0) {
      let prev = signals.wifiSsids.get(currentSsid) ?? 0;
      signals.wifiSsids.set(currentSsid, prev + 1);
    }

    // 记录 BT 设备
    for (let i = 0; i < currentBt.length; i++) {
      let name = currentBt[i];
      if (name.length > 0) {
        let prev = signals.btDevices.get(name) ?? 0;
        signals.btDevices.set(name, prev + 1);
      }
    }

    signals.totalObservations += 1;
    this.learningCooldown.set(geofenceId, Date.now());

    this.log.info(TAG,
      `Learned @${geofenceId}: wifi="${currentSsid}" bt=${currentBt.length} obs=${signals.totalObservations}`);

    // 异步持久化
    this.saveLearnedSignals().catch(() => {});
  }

  // ==================== 已学习信号管理 ====================

  /**
   * 获取所有围栏的已学习信号摘要（用于 UI）
   */
  /** 获取单个围栏的已学习信号摘要 */
  getLearnedSignalsSummary(gf: Geofence): LearnedSignalsSummary | null {
    let signals = this.learnedSignals.get(gf.id);
    if (!signals || signals.totalObservations === 0) return null;

    let wifiList: string[] = [];
    signals.wifiSsids.forEach((count: number, ssid: string) => {
      if (count >= LEARNING_MIN_OBSERVATIONS) {
        wifiList.push(ssid);
      }
    });

    let btList: string[] = [];
    signals.btDevices.forEach((count: number, name: string) => {
      if (count >= LEARNING_MIN_OBSERVATIONS) {
        btList.push(name);
      }
    });

    return {
      geofenceId: gf.id,
      geofenceName: gf.name,
      wifiSsids: wifiList,
      btDevices: btList,
      totalObservations: signals.totalObservations,
    };
  }

  getLearnedSignalsSummaries(geofences: Geofence[]): LearnedSignalsSummary[] {
    let summaries: LearnedSignalsSummary[] = [];

    for (let i = 0; i < geofences.length; i++) {
      let gf = geofences[i];
      let signals = this.learnedSignals.get(gf.id);

      // 从 LocationFusion 观测系统获取（需要3+次观测）
      let wifiList: string[] = [];
      let btList: string[] = [];
      let totalObs = 0;
      if (signals && signals.totalObservations > 0) {
        totalObs = signals.totalObservations;
        signals.wifiSsids.forEach((count: number, ssid: string) => {
          if (count >= LEARNING_MIN_OBSERVATIONS) {
            wifiList.push(ssid);
          }
        });
        signals.btDevices.forEach((count: number, name: string) => {
          if (count >= LEARNING_MIN_OBSERVATIONS) {
            btList.push(name);
          }
        });
      }

      // 合并 Geofence.learnedSignals 中即时学习的 WiFi（首次进入就记录）
      if (gf.learnedSignals && gf.learnedSignals.wifiSSIDs) {
        for (let j = 0; j < gf.learnedSignals.wifiSSIDs.length; j++) {
          let ssid = gf.learnedSignals.wifiSSIDs[j];
          if (!wifiList.includes(ssid)) {
            wifiList.push(ssid);
          }
        }
      }

      if (wifiList.length > 0 || btList.length > 0 || totalObs > 0) {
        summaries.push({
          geofenceId: gf.id,
          geofenceName: gf.name,
          wifiSsids: wifiList,
          btDevices: btList,
          totalObservations: totalObs > 0 ? totalObs : (gf.learnedSignals?.visitCount ?? 0),
        });
      }
    }

    return summaries;
  }

  /**
   * 清除某个围栏的已学习信号
   */
  async clearLearnedSignals(geofenceId: string): Promise<void> {
    this.learnedSignals.delete(geofenceId);
    this.learningCooldown.delete(geofenceId);
    await this.saveLearnedSignals();
    this.log.info(TAG, `Cleared learned signals for ${geofenceId}`);
  }

  /**
   * 清除所有已学习信号
   */
  async clearAllLearnedSignals(): Promise<void> {
    this.learnedSignals.clear();
    this.learningCooldown.clear();
    await this.saveLearnedSignals();
    this.log.info(TAG, 'Cleared all learned signals');
  }

  // ==================== 持久化 ====================

  private async saveLearnedSignals(): Promise<void> {
    if (!this.prefsStore) return;

    try {
      let data: Record<string, string> = {};
      this.learnedSignals.forEach((signals: LearnedSignals, gfId: string) => {
        let wifiArr: LearnedSignalEntry[] = [];
        signals.wifiSsids.forEach((count: number, ssid: string) => {
          wifiArr.push({ key: ssid, count });
        });

        let btArr: LearnedSignalEntry[] = [];
        signals.btDevices.forEach((count: number, name: string) => {
          btArr.push({ key: name, count });
        });

        let json: LearnedSignalsJson = {
          wifiSsids: wifiArr,
          btDevices: btArr,
          totalObservations: signals.totalObservations,
        };
        data[gfId] = JSON.stringify(json);
      });

      await this.prefsStore.put('learned_signals', JSON.stringify(data));
      await this.prefsStore.flush();
    } catch (err) {
      this.log.warn(TAG, `Save error: ${(err as Error).message}`);
    }
  }

  private async loadLearnedSignals(): Promise<void> {
    if (!this.prefsStore) return;

    try {
      let raw = String(await this.prefsStore.get('learned_signals', '{}'));
      let data: Record<string, string> = JSON.parse(raw) as Record<string, string>;

      let keys = Object.keys(data);
      for (let i = 0; i < keys.length; i++) {
        let gfId = keys[i];
        let json: LearnedSignalsJson = JSON.parse(data[gfId]) as LearnedSignalsJson;

        let wifiMap: Map<string, number> = new Map();
        for (let j = 0; j < json.wifiSsids.length; j++) {
          wifiMap.set(json.wifiSsids[j].key, json.wifiSsids[j].count);
        }

        let btMap: Map<string, number> = new Map();
        for (let j = 0; j < json.btDevices.length; j++) {
          btMap.set(json.btDevices[j].key, json.btDevices[j].count);
        }

        let signals: LearnedSignals = {
          wifiSsids: wifiMap,
          btDevices: btMap,
          totalObservations: json.totalObservations,
        };
        this.learnedSignals.set(gfId, signals);
      }

      this.log.info(TAG, `Loaded learned signals for ${this.learnedSignals.size} geofences`);
    } catch (err) {
      this.log.warn(TAG, `Load error: ${(err as Error).message}`);
    }
  }

  // ==================== 工具方法 ====================

  /** Haversine 距离（米）— 委托 C++ geo_utils */
  private haversineDistance(lat1: number, lon1: number, lat2: number, lon2: number): number {
    return GeoUtils.haversineDistance(lat1, lon1, lat2, lon2);
  }
}
