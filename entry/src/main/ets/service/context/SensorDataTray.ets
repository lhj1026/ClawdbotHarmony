/**
 * SensorDataTray — 传感器数据托盘
 *
 * 感知层和决策层之间的缓存中间层。
 * 传感器异步写入 (put)，引擎同步读取 (get/getSnapshot)。
 * 每个槽位携带 TTL，过期数据 quality 线性衰减。
 */
import { ContextSnapshot } from './ContextEngine';

/** 托盘槽位 */
export interface TraySlot {
  key: string;
  value: string;
  updatedAt: number;    // Date.now() ms
  ttlMs: number;
  quality: number;      // 0~1
  source: string;
}

/** 读取结果（含 TTL 衰减后的有效 quality） */
export interface TrayReadResult {
  value: string | null;
  quality: number;      // effective quality after TTL decay
  fresh: boolean;       // age < ttl
  ageMs: number;        // how old the data is
}

/** 调试用状态信息 */
export interface TrayStatus {
  key: string;
  value: string;
  ageMs: number;
  ttlMs: number;
  fresh: boolean;
  effectiveQuality: number;
  source: string;
}

/** 默认 TTL 配置（毫秒） */
const DEFAULT_TTL: Record<string, number> = {
  // 时间类 — 实时计算，永远新鲜
  'hour': 0x7FFFFFFF,
  'timeOfDay': 0x7FFFFFFF,
  'dayOfWeek': 0x7FFFFFFF,
  'isWeekend': 0x7FFFFFFF,

  // 设备状态
  'batteryLevel': 5 * 60 * 1000,    // 5 min
  'isCharging': 5 * 60 * 1000,      // 5 min

  // 网络
  'networkType': 2 * 60 * 1000,     // 2 min

  // 运动
  'motionState': 30 * 1000,         // 30 sec
  'stepCount': 30 * 1000,           // 30 sec
  'step_count_today': 2 * 60 * 1000, // 2 min (from StepCounterPlugin)

  // 位置
  'latitude': 2 * 60 * 1000,        // 2 min
  'longitude': 2 * 60 * 1000,       // 2 min
  'geofence': 5 * 60 * 1000,        // 5 min

  // WiFi 围栏
  'wifiSsid': 2 * 60 * 1000,       // 2 min
  'wifiGeofence': 5 * 60 * 1000,    // 5 min
  'wifiLost': 10 * 60 * 1000,       // 10 min
  'wifiLostWork': 10 * 60 * 1000,   // 10 min
  'wifiLostCategory': 10 * 60 * 1000, // 10 min

  // 交通模式
  'transportMode': 30 * 1000,       // 30 sec
  'speed': 2 * 60 * 1000,           // 2 min

  // 环境
  'heartRate': 60 * 1000,           // 1 min
  'ambientLight': 30 * 1000,        // 30 sec
  'noiseLevel': 30 * 1000,          // 30 sec
};

/** 未配置 key 的回退 TTL */
const FALLBACK_TTL_MS = 2 * 60 * 1000; // 2 min

export class SensorDataTray {
  private static instance: SensorDataTray | null = null;
  private slots: Map<string, TraySlot> = new Map();
  private ttlOverrides: Map<string, number> = new Map();

  static getInstance(): SensorDataTray {
    if (!SensorDataTray.instance) {
      SensorDataTray.instance = new SensorDataTray();
    }
    return SensorDataTray.instance;
  }

  /**
   * 传感器写入数据
   * @param key      传感器标识
   * @param value    最新值（字符串）
   * @param quality  数据质量 0~1，默认 1.0
   * @param source   来源标识，默认与 key 相同
   */
  put(key: string, value: string, quality: number = 1.0, source: string = ''): void {
    let ttl = this.getTTL(key);
    let slot: TraySlot = {
      key: key,
      value: value,
      updatedAt: Date.now(),
      ttlMs: ttl,
      quality: quality,
      source: source.length > 0 ? source : key,
    };
    this.slots.set(key, slot);
  }

  /**
   * 引擎读取数据（含 TTL 衰减）
   */
  get(key: string): TrayReadResult {
    let slot = this.slots.get(key);
    if (!slot) {
      return { value: null, quality: 0.5, fresh: false, ageMs: 0 };
    }

    let now = Date.now();
    let age = now - slot.updatedAt;
    let ttl = slot.ttlMs;

    // 新鲜
    if (age < ttl) {
      return { value: slot.value, quality: slot.quality, fresh: true, ageMs: age };
    }

    // 过期但未超过 2x TTL — quality 线性衰减
    let decay = 1.0 - (age - ttl) / ttl;
    if (decay < 0) decay = 0;
    let effectiveQuality = slot.quality * decay;

    return { value: slot.value, quality: effectiveQuality, fresh: false, ageMs: age };
  }

  /**
   * 从所有槽位构建 ContextSnapshot（替代 getCurrentContext + buildSnapshot）
   */
  getSnapshot(): ContextSnapshot {
    let snap: ContextSnapshot = {
      timeOfDay: this.getValueOrDefault('timeOfDay', 'unknown'),
      hour: this.getValueOrDefault('hour', '0'),
      dayOfWeek: this.getValueOrDefault('dayOfWeek', '0'),
      isWeekend: this.getValueOrDefault('isWeekend', 'false'),
      motionState: this.getValueOrDefault('motionState', 'unknown'),
      batteryLevel: this.getValueOrDefault('batteryLevel', '100'),
      isCharging: this.getValueOrDefault('isCharging', 'false'),
      networkType: this.getValueOrDefault('networkType', 'none'),
    };

    // Optional fields
    let geofence = this.get('geofence');
    if (geofence.value !== null) {
      snap.geofence = geofence.value;
    }
    let lat = this.get('latitude');
    if (lat.value !== null) {
      snap.latitude = lat.value;
    }
    let lon = this.get('longitude');
    if (lon.value !== null) {
      snap.longitude = lon.value;
    }
    let steps = this.get('stepCount');
    if (steps.value !== null) {
      snap.stepCount = steps.value;
    }
    let wifiSsid = this.get('wifiSsid');
    if (wifiSsid.value !== null) {
      snap.wifiSsid = wifiSsid.value;
    }
    let wifiGeofence = this.get('wifiGeofence');
    if (wifiGeofence.value !== null) {
      snap.wifiGeofence = wifiGeofence.value;
    }
    let wifiLost = this.get('wifiLost');
    if (wifiLost.value !== null) {
      snap.wifiLost = wifiLost.value;
    }
    let wifiLostWork = this.get('wifiLostWork');
    if (wifiLostWork.value !== null) {
      snap.wifiLostWork = wifiLostWork.value;
    }
    let wifiLostCategory = this.get('wifiLostCategory');
    if (wifiLostCategory.value !== null) {
      snap.wifiLostCategory = wifiLostCategory.value;
    }
    let speed = this.get('speed');
    if (speed.value !== null) {
      snap.speed = speed.value;
    }
    let transportMode = this.get('transportMode');
    if (transportMode.value !== null) {
      snap.transportMode = transportMode.value;
    }

    return snap;
  }

  /**
   * 配置单个 key 的 TTL
   */
  setTTL(key: string, ttlMs: number): void {
    this.ttlOverrides.set(key, ttlMs);
    // 更新已有槽位
    let slot = this.slots.get(key);
    if (slot) {
      slot.ttlMs = ttlMs;
    }
  }

  /**
   * 获取所有槽位的调试状态
   */
  getStatus(): TrayStatus[] {
    let now = Date.now();
    let result: TrayStatus[] = [];
    let keys = Array.from(this.slots.keys());
    for (let i = 0; i < keys.length; i++) {
      let key = keys[i];
      let slot = this.slots.get(key);
      if (!slot) continue;
      let age = now - slot.updatedAt;
      let fresh = age < slot.ttlMs;
      let decay = fresh ? 1.0 : Math.max(0, 1.0 - (age - slot.ttlMs) / slot.ttlMs);
      let eq = slot.quality * decay;
      result.push({
        key: key,
        value: slot.value,
        ageMs: age,
        ttlMs: slot.ttlMs,
        fresh: fresh,
        effectiveQuality: eq,
        source: slot.source,
      });
    }
    return result;
  }

  /**
   * 清除所有数据（测试用）
   */
  clear(): void {
    this.slots.clear();
  }

  // ────── private ──────

  private getValueOrDefault(key: string, defaultValue: string): string {
    let r = this.get(key);
    return r.value !== null ? r.value : defaultValue;
  }

  private getTTL(key: string): number {
    // 优先用用户覆盖
    let override = this.ttlOverrides.get(key);
    if (override !== undefined) {
      return override;
    }
    // 然后用默认表
    let def = DEFAULT_TTL[key];
    if (def !== undefined) {
      return def;
    }
    return FALLBACK_TTL_MS;
  }
}
