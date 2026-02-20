/**
 * LocationDiscoveryService - 位置自动发现
 *
 * 通过 GPS 历史聚类自动发现常去位置（家、公司、健身房等）
 *
 * 算法：
 * 1. 收集 GPS 历史点（每次位置变化时记录，带时间戳）
 * 2. DBSCAN 聚类发现密集区域
 * 3. 根据时间模式推断类别（家：夜间，公司：工作日白天）
 * 4. 生成围栏建议
 */
import { geoLocationManager } from '@kit.LocationKit';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { LogService } from '../../common/LogService';

const TAG = 'LocationDiscovery';
const MIN_SAMPLES = 10;           // 聚类最小点数
const EPSILON_METERS = 50;        // DBSCAN 半径（米）
const MIN_STAY_MINUTES = 30;      // 最小停留时间（分钟）
const MAX_HISTORY_DAYS = 14;      // 历史保留天数
const DISCOVERY_INTERVAL_MS = 3600000; // 发现间隔（1小时）

/** GPS 历史点 */
interface LocationPoint {
  latitude: number;
  longitude: number;
  timestamp: number;  // ms
  accuracy: number;   // meters
}

/** 聚类结果 */
interface LocationCluster {
  id: string;
  centerLat: number;
  centerLng: number;
  radiusMeters: number;
  pointCount: number;
  firstSeen: number;
  lastSeen: number;
  totalStayMs: number;
  timePattern: TimePattern;
  suggestedCategory: string;
  suggestedName: string;
}

/** 时间模式分析 */
interface TimePattern {
  weekdayHours: number[];    // 0-23, 工作日出现的小时
  weekendHours: number[];    // 0-23, 周末出现的小时
  nightCount: number;        // 22:00-06:00 出现次数
  workdayCount: number;      // 工作日 09:00-18:00 出现次数
  weekendCount: number;      // 周末出现次数
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

type DiscoveryListener = (suggestions: GeofenceSuggestion[]) => void;

export class LocationDiscoveryService {
  private static instance: LocationDiscoveryService;
  private log: LogService = LogService.getInstance();

  private context: common.UIAbilityContext | null = null;
  private history: LocationPoint[] = [];
  private clusters: LocationCluster[] = [];
  private listeners: DiscoveryListener[] = [];
  private isRunning: boolean = false;
  private lastDiscoveryTime: number = 0;

  private constructor() {}

  static getInstance(): LocationDiscoveryService {
    if (!LocationDiscoveryService.instance) {
      LocationDiscoveryService.instance = new LocationDiscoveryService();
    }
    return LocationDiscoveryService.instance;
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    await this.loadHistory();
    this.log.info(TAG, `Initialized with ${this.history.length} history points, ${this.clusters.length} clusters`);
  }

  /**
   * 记录位置点
   */
  recordLocation(location: geoLocationManager.Location): void {
    let point: LocationPoint = {
      latitude: location.latitude,
      longitude: location.longitude,
      timestamp: Date.now(),
      accuracy: location.accuracy || 10
    };

    // 过滤低精度点
    if (point.accuracy > 100) {
      this.log.debug(TAG, `Skipping low accuracy point: ${point.accuracy}m`);
      return;
    }

    this.history.push(point);
    this.pruneOldHistory();

    // 定期保存
    if (this.history.length % 50 === 0) {
      this.saveHistory();
    }
  }

  /**
   * 运行聚类发现
   */
  async runDiscovery(): Promise<GeofenceSuggestion[]> {
    if (this.history.length < MIN_SAMPLES) {
      this.log.info(TAG, `Not enough history points: ${this.history.length} < ${MIN_SAMPLES}`);
      return [];
    }

    this.log.info(TAG, `Running discovery on ${this.history.length} points`);
    this.lastDiscoveryTime = Date.now();

    // DBSCAN 聚类
    this.clusters = this.dbscanCluster();

    // 分析时间模式并生成建议
    let suggestions: GeofenceSuggestion[] = [];
    for (let ci = 0; ci < this.clusters.length; ci++) {
      let cluster = this.clusters[ci];
      cluster.timePattern = this.analyzeTimePattern(cluster);
      cluster.suggestedCategory = this.inferCategory(cluster);
      cluster.suggestedName = this.generateName(cluster);

      // 只建议停留时间足够长的位置
      if (cluster.totalStayMs >= MIN_STAY_MINUTES * 60000) {
        suggestions.push({
          id: cluster.id,
          name: cluster.suggestedName,
          latitude: cluster.centerLat,
          longitude: cluster.centerLng,
          radiusMeters: Math.round(cluster.radiusMeters),
          category: cluster.suggestedCategory,
          confidence: this.calculateConfidence(cluster),
          reason: this.generateReason(cluster)
        });
      }
    }

    // 按置信度排序
    suggestions.sort((a, b) => b.confidence - a.confidence);

    this.log.info(TAG, `Discovery found ${suggestions.length} suggestions`);
    await this.saveHistory();

    // 通知监听器
    for (let li = 0; li < this.listeners.length; li++) {
      this.listeners[li](suggestions);
    }

    return suggestions;
  }

  /**
   * DBSCAN 聚类算法
   */
  private dbscanCluster(): LocationCluster[] {
    let clusters: LocationCluster[] = [];
    let visited = new Set<number>();
    let clusterId = 0;

    for (let i = 0; i < this.history.length; i++) {
      if (visited.has(i)) continue;

      let neighbors = this.getNeighbors(i);
      if (neighbors.length < MIN_SAMPLES) {
        visited.add(i);
        continue;
      }

      // 创建新聚类
      let clusterPoints: number[] = [];
      this.expandCluster(i, neighbors, clusterPoints, visited);

      if (clusterPoints.length >= MIN_SAMPLES) {
        let cluster = this.createCluster(clusterId++, clusterPoints);
        clusters.push(cluster);
      }
    }

    return clusters;
  }

  /**
   * 获取邻居点（在 epsilon 距离内）
   */
  private getNeighbors(pointIndex: number): number[] {
    let neighbors: number[] = [];
    let p = this.history[pointIndex];

    for (let i = 0; i < this.history.length; i++) {
      if (i === pointIndex) continue;
      let q = this.history[i];
      let dist = this.haversineDistance(p.latitude, p.longitude, q.latitude, q.longitude);
      if (dist <= EPSILON_METERS) {
        neighbors.push(i);
      }
    }

    return neighbors;
  }

  /**
   * 扩展聚类
   */
  private expandCluster(pointIndex: number, neighbors: number[],
                         clusterPoints: number[], visited: Set<number>): void {
    clusterPoints.push(pointIndex);
    visited.add(pointIndex);

    let queue: number[] = [];
    for (let ni = 0; ni < neighbors.length; ni++) {
      queue.push(neighbors[ni]);
    }
    while (queue.length > 0) {
      let current = queue[0];
      queue.splice(0, 1);
      if (!visited.has(current)) {
        visited.add(current);
        let currentNeighbors = this.getNeighbors(current);
        if (currentNeighbors.length >= MIN_SAMPLES) {
          for (let ki = 0; ki < currentNeighbors.length; ki++) {
            queue.push(currentNeighbors[ki]);
          }
        }
      }
      if (!clusterPoints.includes(current)) {
        clusterPoints.push(current);
      }
    }
  }

  /**
   * 创建聚类对象
   */
  private createCluster(id: number, pointIndices: number[]): LocationCluster {
    let points = pointIndices.map(i => this.history[i]);

    // 计算中心点
    let sumLat = 0, sumLng = 0;
    for (let pi = 0; pi < points.length; pi++) {
      sumLat += points[pi].latitude;
      sumLng += points[pi].longitude;
    }
    let centerLat = sumLat / points.length;
    let centerLng = sumLng / points.length;

    // 计算半径（95% 点在内部）
    let distances = points.map(p =>
      this.haversineDistance(centerLat, centerLng, p.latitude, p.longitude)
    );
    distances.sort((a, b) => a - b);
    let radiusIndex = Math.floor(distances.length * 0.95);
    let radius = distances[Math.min(radiusIndex, distances.length - 1)];
    radius = Math.max(50, Math.min(500, radius)); // 50-500m

    // 计算停留时间
    let timestamps = points.map(p => p.timestamp).sort((a, b) => a - b);
    let totalStay = 0;
    for (let i = 1; i < timestamps.length; i++) {
      let gap = timestamps[i] - timestamps[i - 1];
      if (gap < 3600000) { // 1小时内视为连续停留
        totalStay += gap;
      }
    }

    return {
      id: `cluster_${id}`,
      centerLat,
      centerLng,
      radiusMeters: radius,
      pointCount: points.length,
      firstSeen: timestamps[0],
      lastSeen: timestamps[timestamps.length - 1],
      totalStayMs: totalStay,
      timePattern: {
        weekdayHours: [],
        weekendHours: [],
        nightCount: 0,
        workdayCount: 0,
        weekendCount: 0
      },
      suggestedCategory: 'unknown',
      suggestedName: ''
    };
  }

  /**
   * 分析时间模式
   */
  private analyzeTimePattern(cluster: LocationCluster): TimePattern {
    let pattern: TimePattern = {
      weekdayHours: [],
      weekendHours: [],
      nightCount: 0,
      workdayCount: 0,
      weekendCount: 0
    };

    // 找到聚类中的所有点
    for (let i = 0; i < this.history.length; i++) {
      let p = this.history[i];
      let dist = this.haversineDistance(cluster.centerLat, cluster.centerLng, p.latitude, p.longitude);
      if (dist <= cluster.radiusMeters) {
        let date = new Date(p.timestamp);
        let hour = date.getHours();
        let dayOfWeek = date.getDay();
        let isWeekend = dayOfWeek === 0 || dayOfWeek === 6;
        let isNight = hour >= 22 || hour < 6;
        let isWorkHour = hour >= 9 && hour < 18;

        if (isWeekend) {
          if (!pattern.weekendHours.includes(hour)) {
            pattern.weekendHours.push(hour);
          }
          pattern.weekendCount++;
        } else {
          if (!pattern.weekdayHours.includes(hour)) {
            pattern.weekdayHours.push(hour);
          }
          if (isWorkHour) {
            pattern.workdayCount++;
          }
        }

        if (isNight) {
          pattern.nightCount++;
        }
      }
    }

    return pattern;
  }

  /**
   * 推断类别
   */
  private inferCategory(cluster: LocationCluster): string {
    let pattern = cluster.timePattern;
    let total = cluster.pointCount;

    let nightRatio = pattern.nightCount / total;
    let workdayRatio = pattern.workdayCount / total;
    let weekendRatio = pattern.weekendCount / total;

    // 夜间出现多 → 家
    if (nightRatio > 0.4) {
      return 'home';
    }

    // 工作日白天多 → 公司
    if (workdayRatio > 0.5 && weekendRatio < 0.2) {
      return 'work';
    }

    // 周末多、运动时段 → 健身房
    if (weekendRatio > 0.4 && pattern.weekendHours.some(h => h >= 8 && h <= 20)) {
      return 'gym';
    }

    // 工作日中午 → 餐厅
    if (pattern.weekdayHours.some(h => h >= 11 && h <= 14)) {
      return 'restaurant';
    }

    return 'other';
  }

  /**
   * 生成名称
   */
  private generateName(cluster: LocationCluster): string {
    let categoryNames: Record<string, string> = {
      'home': '家',
      'work': '公司',
      'gym': '健身房',
      'restaurant': '常去餐厅',
      'other': '常去地点'
    };
    return categoryNames[cluster.suggestedCategory] || '常去地点';
  }

  /**
   * 计算置信度
   */
  private calculateConfidence(cluster: LocationCluster): number {
    let score = 0;

    // 点数越多越可信
    score += Math.min(cluster.pointCount / 100, 0.3);

    // 停留时间越长越可信
    score += Math.min(cluster.totalStayMs / (86400000 * 7), 0.3); // 7天

    // 时间模式越规律越可信
    let pattern = cluster.timePattern;
    let weekdayRegularity = pattern.weekdayHours.length > 0 ? 0.2 : 0;
    let weekendRegularity = pattern.weekendHours.length > 0 ? 0.2 : 0;
    score += weekdayRegularity + weekendRegularity;

    return Math.min(score, 1);
  }

  /**
   * 生成推荐理由
   */
  private generateReason(cluster: LocationCluster): string {
    let hours = Math.round(cluster.totalStayMs / 3600000);
    let visits = Math.round(cluster.pointCount / 10);

    let pattern = cluster.timePattern;
    let timeDesc = '';
    if (pattern.nightCount > cluster.pointCount * 0.3) {
      timeDesc = '夜间常驻';
    } else if (pattern.workdayCount > cluster.pointCount * 0.3) {
      timeDesc = '工作日常驻';
    } else if (pattern.weekendCount > cluster.pointCount * 0.3) {
      timeDesc = '周末常去';
    } else {
      timeDesc = '经常到访';
    }

    return `${timeDesc}，累计停留约${hours}小时，到访${visits}+次`;
  }

  /**
   * 计算两点间距离（Haversine 公式）
   */
  private haversineDistance(lat1: number, lng1: number, lat2: number, lng2: number): number {
    let R = 6371000; // 地球半径（米）
    let dLat = (lat2 - lat1) * Math.PI / 180;
    let dLng = (lng2 - lng1) * Math.PI / 180;
    let a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
            Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
            Math.sin(dLng / 2) * Math.sin(dLng / 2);
    let c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
    return R * c;
  }

  /**
   * 清理过期历史
   */
  private pruneOldHistory(): void {
    let cutoff = Date.now() - MAX_HISTORY_DAYS * 86400000;
    while (this.history.length > 0 && this.history[0].timestamp < cutoff) {
      this.history.shift();
    }
  }

  /**
   * 保存历史到文件
   */
  private async saveHistory(): Promise<void> {
    if (!this.context) return;
    try {
      let path = `${this.context.filesDir}/location_history.json`;
      let data = {
        version: 1,
        history: this.history,
        clusters: this.clusters,
        lastDiscovery: this.lastDiscoveryTime
      };
      let json = JSON.stringify(data);
      let file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
      fileIo.writeSync(file.fd, json);
      fileIo.closeSync(file);
      this.log.info(TAG, `Saved ${this.history.length} history points`);
    } catch (err) {
      this.log.error(TAG, `Failed to save history: ${err}`);
    }
  }

  /**
   * 加载历史文件
   */
  private async loadHistory(): Promise<void> {
    if (!this.context) return;
    try {
      let path = `${this.context.filesDir}/location_history.json`;
      let file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      let stat = fileIo.statSync(path);
      let buffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      fileIo.closeSync(file);

      let decoder = util.TextDecoder.create('utf-8');
      let json = decoder.decodeToString(new Uint8Array(buffer));
      let data = JSON.parse(json) as {
        version: number;
        history: LocationPoint[];
        clusters: LocationCluster[];
        lastDiscovery: number;
      };

      this.history = data.history || [];
      this.clusters = data.clusters || [];
      this.lastDiscoveryTime = data.lastDiscovery || 0;
    } catch (err) {
      this.log.info(TAG, 'No existing history file, starting fresh');
      this.history = [];
      this.clusters = [];
    }
  }

  /**
   * 添加建议监听器
   */
  addListener(listener: DiscoveryListener): void {
    this.listeners.push(listener);
  }

  /**
   * 获取当前建议
   */
  getSuggestions(): GeofenceSuggestion[] {
    return this.clusters
      .filter(c => c.totalStayMs >= MIN_STAY_MINUTES * 60000)
      .map(cluster => ({
        id: cluster.id,
        name: cluster.suggestedName,
        latitude: cluster.centerLat,
        longitude: cluster.centerLng,
        radiusMeters: Math.round(cluster.radiusMeters),
        category: cluster.suggestedCategory,
        confidence: this.calculateConfidence(cluster),
        reason: this.generateReason(cluster)
      }))
      .sort((a, b) => b.confidence - a.confidence);
  }

  /**
   * 获取统计信息
   */
  getStats(): { historyCount: number; clusterCount: number; lastDiscovery: string } {
    return {
      historyCount: this.history.length,
      clusterCount: this.clusters.length,
      lastDiscovery: this.lastDiscoveryTime > 0
        ? new Date(this.lastDiscoveryTime).toLocaleString()
        : '从未'
    };
  }

  /**
   * 清除所有历史（重置）
   */
  async clearHistory(): Promise<void> {
    this.history = [];
    this.clusters = [];
    this.lastDiscoveryTime = 0;
    await this.saveHistory();
    this.log.info(TAG, 'History cleared');
  }
}
