/**
 * Geofence Manager
 * 
 * 管理地理围栏，检测用户进入/离开特定区域
 */
import { geoLocationManager } from '@kit.LocationKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { LogService } from '../../common/LogService';
import { Geofence, GeofenceCategory, LocationState } from './ContextModels';

const TAG = 'GeofenceManager';
const PREFS_NAME = 'clawdbot_geofences';
const KEY_GEOFENCES = 'geofence_list';

export type GeofenceEventType = 'enter' | 'exit' | 'dwell';

export interface GeofenceEvent {
  type: GeofenceEventType;
  geofence: Geofence;
  timestamp: number;
  location: LocationState;
}

type GeofenceListener = (event: GeofenceEvent) => void;

export class GeofenceManager {
  private static instance: GeofenceManager;
  private log: LogService = LogService.getInstance();
  
  private geofences: Map<string, Geofence> = new Map();
  private currentlyInside: Set<string> = new Set();
  private listeners: GeofenceListener[] = [];
  private initialized: boolean = false;
  
  // 位置监听
  private locationCallback: ((location: geoLocationManager.Location) => void) | undefined;
  private isMonitoring: boolean = false;
  
  private constructor() {}
  
  static getInstance(): GeofenceManager {
    if (!GeofenceManager.instance) {
      GeofenceManager.instance = new GeofenceManager();
    }
    return GeofenceManager.instance;
  }
  
  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.initialized) return;
    
    // 加载保存的围栏
    await this.loadGeofences(context);
    
    // 添加一些默认的常用地点（用户可以自定义）
    if (this.geofences.size === 0) {
      this.addDefaultGeofences();
    }
    
    this.initialized = true;
    this.log.info(TAG, `Initialized with ${this.geofences.size} geofences`);
  }
  
  private addDefaultGeofences(): void {
    // 大温地区常见地点示例
    const defaults: Geofence[] = [
      // 地铁站示例
      {
        id: 'skytrain_metrotown',
        name: 'Metrotown Station',
        latitude: 49.2258,
        longitude: -123.0036,
        radiusMeters: 100,
        category: 'transit',
      },
      {
        id: 'skytrain_patterson',
        name: 'Patterson Station',
        latitude: 49.2298,
        longitude: -123.0126,
        radiusMeters: 100,
        category: 'transit',
      },
      // 购物中心
      {
        id: 'costco_burnaby',
        name: 'Costco Burnaby',
        latitude: 49.2590,
        longitude: -123.0065,
        radiusMeters: 150,
        category: 'shopping',
        metadata: { store: 'costco' },
      },
      {
        id: 'superstore_metrotown',
        name: 'Superstore Metrotown',
        latitude: 49.2279,
        longitude: -122.9998,
        radiusMeters: 100,
        category: 'shopping',
        metadata: { store: 'superstore' },
      },
    ];
    
    for (const gf of defaults) {
      this.geofences.set(gf.id, gf);
    }
  }
  
  // ==================== 围栏管理 ====================
  
  addGeofence(geofence: Geofence): void {
    this.geofences.set(geofence.id, geofence);
    this.log.info(TAG, `Added geofence: ${geofence.name} (${geofence.id})`);
  }
  
  removeGeofence(id: string): boolean {
    const removed = this.geofences.delete(id);
    this.currentlyInside.delete(id);
    if (removed) {
      this.log.info(TAG, `Removed geofence: ${id}`);
    }
    return removed;
  }
  
  getGeofence(id: string): Geofence | undefined {
    return this.geofences.get(id);
  }
  
  getAllGeofences(): Geofence[] {
    return Array.from(this.geofences.values());
  }
  
  getGeofencesByCategory(category: GeofenceCategory): Geofence[] {
    return this.getAllGeofences().filter(gf => gf.category === category);
  }
  
  // ==================== 位置检测 ====================
  
  /**
   * 检查位置是否在指定围栏内
   */
  isInsideGeofence(lat: number, lon: number, geofence: Geofence): boolean {
    const distance = this.calculateDistance(lat, lon, geofence.latitude, geofence.longitude);
    return distance <= geofence.radiusMeters;
  }
  
  /**
   * 获取位置所在的所有围栏
   */
  getGeofencesAtLocation(lat: number, lon: number): Geofence[] {
    const result: Geofence[] = [];
    for (const gf of this.geofences.values()) {
      if (this.isInsideGeofence(lat, lon, gf)) {
        result.push(gf);
      }
    }
    return result;
  }
  
  /**
   * 更新位置并触发进入/离开事件
   */
  updateLocation(location: LocationState): GeofenceEvent[] {
    const events: GeofenceEvent[] = [];
    const nowInside = new Set<string>();
    
    // 检查当前在哪些围栏内
    for (const gf of this.geofences.values()) {
      if (this.isInsideGeofence(location.latitude, location.longitude, gf)) {
        nowInside.add(gf.id);
        
        // 新进入的围栏
        if (!this.currentlyInside.has(gf.id)) {
          const event: GeofenceEvent = {
            type: 'enter',
            geofence: gf,
            timestamp: Date.now(),
            location,
          };
          events.push(event);
          this.notifyListeners(event);
          this.log.info(TAG, `ENTER: ${gf.name}`);
        }
      }
    }
    
    // 检查离开的围栏
    for (const id of this.currentlyInside) {
      if (!nowInside.has(id)) {
        const gf = this.geofences.get(id);
        if (gf) {
          const event: GeofenceEvent = {
            type: 'exit',
            geofence: gf,
            timestamp: Date.now(),
            location,
          };
          events.push(event);
          this.notifyListeners(event);
          this.log.info(TAG, `EXIT: ${gf.name}`);
        }
      }
    }
    
    this.currentlyInside = nowInside;
    return events;
  }
  
  // ==================== 持续监控 ====================
  
  async startMonitoring(): Promise<boolean> {
    if (this.isMonitoring) return true;
    
    try {
      this.locationCallback = (location: geoLocationManager.Location) => {
        const state: LocationState = {
          latitude: location.latitude,
          longitude: location.longitude,
          accuracy: location.accuracy,
          speed: location.speed || 0,
          timestamp: location.timeStamp,
          insideGeofences: [],
        };
        
        // 更新并获取当前围栏
        this.updateLocation(state);
        state.insideGeofences = Array.from(this.currentlyInside);
      };
      
      const request: geoLocationManager.ContinuousLocationRequest = {
        interval: 10,  // 10秒更新一次
        locationScenario: geoLocationManager.UserActivityScenario.NAVIGATION,
      };
      
      geoLocationManager.on('continuousLocationChange', request, this.locationCallback);
      this.isMonitoring = true;
      this.log.info(TAG, 'Started location monitoring');
      return true;
    } catch (err) {
      this.log.error(TAG, `Failed to start monitoring: ${(err as Error).message}`);
      return false;
    }
  }
  
  stopMonitoring(): void {
    if (!this.isMonitoring || !this.locationCallback) return;
    
    try {
      geoLocationManager.off('continuousLocationChange', this.locationCallback);
      this.isMonitoring = false;
      this.locationCallback = undefined;
      this.log.info(TAG, 'Stopped location monitoring');
    } catch (err) {
      this.log.warn(TAG, `Error stopping monitoring: ${(err as Error).message}`);
    }
  }
  
  // ==================== 事件监听 ====================
  
  addListener(listener: GeofenceListener): void {
    this.listeners.push(listener);
  }
  
  removeListener(listener: GeofenceListener): void {
    const idx = this.listeners.indexOf(listener);
    if (idx >= 0) this.listeners.splice(idx, 1);
  }
  
  private notifyListeners(event: GeofenceEvent): void {
    for (const listener of this.listeners) {
      try {
        listener(event);
      } catch (err) {
        this.log.warn(TAG, `Listener error: ${(err as Error).message}`);
      }
    }
  }
  
  // ==================== 持久化 ====================
  
  async saveGeofences(context: common.UIAbilityContext): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, PREFS_NAME);
      const data = JSON.stringify(this.getAllGeofences());
      await store.put(KEY_GEOFENCES, data);
      await store.flush();
      this.log.info(TAG, `Saved ${this.geofences.size} geofences`);
    } catch (err) {
      this.log.error(TAG, `Failed to save: ${(err as Error).message}`);
    }
  }
  
  private async loadGeofences(context: common.UIAbilityContext): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, PREFS_NAME);
      const data = await store.get(KEY_GEOFENCES, '[]') as string;
      const list = JSON.parse(data) as Geofence[];
      for (const gf of list) {
        this.geofences.set(gf.id, gf);
      }
      this.log.info(TAG, `Loaded ${list.length} geofences`);
    } catch (err) {
      this.log.warn(TAG, `Failed to load: ${(err as Error).message}`);
    }
  }
  
  // ==================== 工具方法 ====================
  
  /**
   * 计算两点间距离（米）- Haversine公式
   */
  private calculateDistance(lat1: number, lon1: number, lat2: number, lon2: number): number {
    const R = 6371000; // 地球半径（米）
    const dLat = this.toRad(lat2 - lat1);
    const dLon = this.toRad(lon2 - lon1);
    const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
              Math.cos(this.toRad(lat1)) * Math.cos(this.toRad(lat2)) *
              Math.sin(dLon / 2) * Math.sin(dLon / 2);
    const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
    return R * c;
  }
  
  private toRad(deg: number): number {
    return deg * Math.PI / 180;
  }
  
  /**
   * 获取当前状态摘要
   */
  getStatus(): string {
    return `Geofences: ${this.geofences.size}, Inside: [${Array.from(this.currentlyInside).join(', ')}], Monitoring: ${this.isMonitoring}`;
  }
}
