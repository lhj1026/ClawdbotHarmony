/**
 * LocationDiscoveryService — 已废弃 (v2.66.1)
 *
 * 位置自动发现功能已由 GeofenceManager + PlaceLearner 覆盖。
 * 此文件仅保留类型导出以保持 import 兼容。
 */

/** 统计信息 */
export interface DiscoveryStatsInfo {
  historyCount: number;
  clusterCount: number;
  lastDiscovery: string;
}

/** 围栏建议 */
export interface GeofenceSuggestion {
  id: string;
  name: string;
  latitude: number;
  longitude: number;
  radiusMeters: number;
  category: string;
  confidence: number;  // 0-1
  reason: string;      // 为什么建议这个位置
}

/** @deprecated — 保留空壳以兼容现有 import */
export class LocationDiscoveryService {
  private static instance: LocationDiscoveryService;

  private constructor() {}

  static getInstance(): LocationDiscoveryService {
    if (!LocationDiscoveryService.instance) {
      LocationDiscoveryService.instance = new LocationDiscoveryService();
    }
    return LocationDiscoveryService.instance;
  }

  getSuggestions(): GeofenceSuggestion[] { return []; }
  getStats(): DiscoveryStatsInfo { return { historyCount: 0, clusterCount: 0, lastDiscovery: '' }; }
  async runDiscovery(): Promise<GeofenceSuggestion[]> { return []; }
}
