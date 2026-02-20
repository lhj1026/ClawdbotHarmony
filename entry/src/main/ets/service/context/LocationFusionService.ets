/**
 * LocationFusionService — 多源位置融合
 *
 * 融合 GPS、WiFi SSID、蓝牙设备三种信号，输出每个已知地点的置信度 0~1。
 * 当 GPS 漂移（室内/城市峡谷）时，WiFi/BT 信号可独立确认位置。
 *
 * 学习机制：GPS 高精度确认用户在某围栏内时，自动记录当前 WiFi SSID
 * 和附近 BT 设备。累积 3 次以上观测后，该信号可用于位置确认。
 */
import { wifiManager } from '@kit.ConnectivityKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { LogService } from '../../common/LogService';
import { Geofence, LocationState } from './ContextModels';

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
   * 获取每个已知围栏的位置置信度
   *
   * @param geofences 所有已知围栏
   * @param location 当前 GPS 位置（可能不精确）
   * @returns placeId → 置信度 (0~1) 映射
   */
  getLocationConfidence(
    geofences: Geofence[],
    location: LocationState | undefined
  ): Map<string, number> {
    let result: Map<string, number> = new Map();

    // 获取当前 WiFi 和 BT 信号
    let currentWifiSsid = this.getCurrentWifiSsid();
    let currentBtDevices = this.getCurrentBtDevices();

    let gpsAccuracy = location?.accuracy ?? 9999;
    let gpsLowQuality = gpsAccuracy > GPS_LOW_QUALITY_ACCURACY;

    for (let i = 0; i < geofences.length; i++) {
      let gf = geofences[i];

      // GPS 置信度
      let gpsConf = this.calcGpsConfidence(gf, location);

      // WiFi 置信度
      let wifiConf = this.calcWifiConfidence(gf.id, currentWifiSsid);

      // BT 置信度
      let btConf = this.calcBtConfidence(gf.id, currentBtDevices);

      // 融合：max(gps, wifi, bt)
      // GPS 低质量时，WiFi/BT 已经通过 max 自然获得更高权重
      let confidence = Math.max(gpsConf, wifiConf, btConf);

      // GPS 低质量且 WiFi/BT 有信号时，略微提升非 GPS 信号
      if (gpsLowQuality && (wifiConf > 0.5 || btConf > 0.5)) {
        let nonGpsMax = Math.max(wifiConf, btConf);
        confidence = Math.max(confidence, Math.min(nonGpsMax + 0.05, 1.0));
      }

      result.set(gf.id, confidence);
    }

    return result;
  }

  /**
   * 获取最佳匹配的围栏（融合后置信度最高且 > 0.5）
   */
  getBestMatch(
    geofences: Geofence[],
    location: LocationState | undefined
  ): FusionResult | null {
    let currentWifiSsid = this.getCurrentWifiSsid();
    let currentBtDevices = this.getCurrentBtDevices();

    let best: FusionResult | null = null;
    let bestConf = 0;

    for (let i = 0; i < geofences.length; i++) {
      let gf = geofences[i];
      let gpsConf = this.calcGpsConfidence(gf, location);
      let wifiConf = this.calcWifiConfidence(gf.id, currentWifiSsid);
      let btConf = this.calcBtConfidence(gf.id, currentBtDevices);

      let confidence = Math.max(gpsConf, wifiConf, btConf);

      // 确定主要来源
      let source = 'gps';
      if (wifiConf >= gpsConf && wifiConf >= btConf) source = 'wifi';
      else if (btConf >= gpsConf && btConf >= wifiConf) source = 'bt';

      if (confidence > bestConf) {
        bestConf = confidence;
        best = {
          geofenceId: gf.id,
          confidence,
          gpsConfidence: gpsConf,
          wifiConfidence: wifiConf,
          btConfidence: btConf,
          source,
        };
      }
    }

    // 只返回置信度 > 0.5 的结果
    if (best && best.confidence > 0.5) {
      return best;
    }
    return null;
  }

  // ==================== 信号置信度计算 ====================

  private calcGpsConfidence(gf: Geofence, location: LocationState | undefined): number {
    if (!location) return GPS_MIN_CONFIDENCE;

    let dist = this.haversineDistance(
      location.latitude, location.longitude,
      gf.latitude, gf.longitude
    );

    if (dist < GPS_HIGH_CONFIDENCE_RADIUS) {
      return 1.0;
    }
    if (dist < GPS_DECAY_SCALE * 3) {
      // 指数衰减: exp(-dist/scale)
      return Math.max(Math.exp(-dist / GPS_DECAY_SCALE), GPS_MIN_CONFIDENCE);
    }
    return GPS_MIN_CONFIDENCE;
  }

  private calcWifiConfidence(geofenceId: string, currentSsid: string): number {
    if (currentSsid.length === 0) return 0;

    let signals = this.learnedSignals.get(geofenceId);
    if (!signals || signals.totalObservations < LEARNING_MIN_OBSERVATIONS) {
      return 0;  // 观测不足，WiFi 信号尚不可用
    }

    let ssidCount = signals.wifiSsids.get(currentSsid);
    if (ssidCount !== undefined && ssidCount >= LEARNING_MIN_OBSERVATIONS) {
      return WIFI_MATCH_CONFIDENCE;
    }

    // 有已学习的 WiFi 但当前不匹配
    if (signals.wifiSsids.size > 0) {
      return WIFI_NO_MATCH_CONFIDENCE;
    }

    return 0;
  }

  private calcBtConfidence(geofenceId: string, currentDevices: string[]): number {
    if (currentDevices.length === 0) return 0;

    let signals = this.learnedSignals.get(geofenceId);
    if (!signals || signals.totalObservations < LEARNING_MIN_OBSERVATIONS) {
      return 0;
    }

    // 任一已学习的 BT 设备匹配即可
    for (let i = 0; i < currentDevices.length; i++) {
      let deviceCount = signals.btDevices.get(currentDevices[i]);
      if (deviceCount !== undefined && deviceCount >= LEARNING_MIN_OBSERVATIONS) {
        return BT_MATCH_CONFIDENCE;
      }
    }

    return 0;
  }

  // ==================== 信号获取 ====================

  private getCurrentWifiSsid(): string {
    try {
      if (!wifiManager.isWifiActive()) return '';
      let info = wifiManager.getLinkedInfo();
      let ssid = info.ssid || '';
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
    // BLE 扫描需要持续监听，这里使用已配对设备列表作为替代
    // HarmonyOS @kit.ConnectivityKit 的 ble/access 模块
    try {
      // 注意：HarmonyOS ble.getConnectedBLEDevices() 可能不可用或需要权限
      // 降级策略：返回空数组，不影响 GPS-only 场景
      return [];
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
  learnSignals(geofenceId: string, location: LocationState): void {
    // 精度检查
    if (location.accuracy > LEARNING_GPS_ACCURACY_THRESHOLD) return;

    // 冷却检查
    let lastLearn = this.learningCooldown.get(geofenceId);
    if (lastLearn !== undefined && Date.now() - lastLearn < LEARNING_COOLDOWN_MS) return;

    let currentSsid = this.getCurrentWifiSsid();
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
  getLearnedSignalsSummaries(geofences: Geofence[]): LearnedSignalsSummary[] {
    let summaries: LearnedSignalsSummary[] = [];

    for (let i = 0; i < geofences.length; i++) {
      let gf = geofences[i];
      let signals = this.learnedSignals.get(gf.id);
      if (!signals || signals.totalObservations === 0) continue;

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

      if (wifiList.length > 0 || btList.length > 0 || signals.totalObservations > 0) {
        summaries.push({
          geofenceId: gf.id,
          geofenceName: gf.name,
          wifiSsids: wifiList,
          btDevices: btList,
          totalObservations: signals.totalObservations,
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

  /** Haversine 距离（米） */
  private haversineDistance(lat1: number, lon1: number, lat2: number, lon2: number): number {
    let R = 6371000;
    let dLat = (lat2 - lat1) * Math.PI / 180;
    let dLon = (lon2 - lon1) * Math.PI / 180;
    let a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
            Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
            Math.sin(dLon / 2) * Math.sin(dLon / 2);
    let c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
    return R * c;
  }
}
