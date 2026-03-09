/**
 * DailyTimelineService — 每日行程时间线
 *
 * 记录一天中的位置变化和运动状态变化，按时间线展示。
 * 每次地理围栏或运动状态发生有意义的变化时，CAS 推送事件到此服务。
 *
 * 数据模型:
 *   TimelineEntry[] — 按 startTime 排序的状态段列表
 *   每个 entry 记录: 开始时间、结束时间、地点、运动状态
 *
 * 持久化: preferences (daily_timeline_YYYY-MM-DD)
 * 午夜自动清理前一天数据
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { LogService } from '../../common/LogService';
import { TimelineEntry } from './ContextModels';
import { GeoCodingService } from './GeoCodingService';

const TAG = 'DailyTimeline';
const PREFS_NAME = 'daily_timeline_prefs';
const MAX_ENTRIES_PER_DAY = 200;
const MAX_WAYPOINTS_PER_ENTRY = 500;
const WAYPOINT_MIN_DISTANCE_M = 30;
const MAX_HISTORY_DAYS = 90;
const DATE_LIST_KEY = 'saved_dates';

export class DailyTimelineService {
  private static instance: DailyTimelineService | null = null;
  private log: LogService = LogService.getInstance();
  private prefs: preferences.Preferences | undefined;
  private entries: TimelineEntry[] = [];
  private currentDate: string = '';
  private initialized: boolean = false;
  private savedDates: string[] = [];

  // 用于去重: 避免短时间内重复推送相同状态
  private lastGeofenceId: string = '';
  private lastMotionState: string = '';
  private lastPushTime: number = 0;
  private static readonly DEDUP_INTERVAL_MS = 5000; // 5秒内相同状态不重复记录

  static getInstance(): DailyTimelineService {
    if (!DailyTimelineService.instance) {
      DailyTimelineService.instance = new DailyTimelineService();
    }
    return DailyTimelineService.instance;
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.initialized) return;
    try {
      this.prefs = await preferences.getPreferences(context, PREFS_NAME);
      this.currentDate = this.getTodayStr();
      await this.loadDateList();
      await this.loadEntries();
      this.initialized = true;
      this.log.info(TAG, `Init: ${this.entries.length} entries for ${this.currentDate}, ${this.savedDates.length} history days`);
    } catch (err) {
      this.log.warn(TAG, `Init failed: ${(err as Error).message}`);
    }
  }

  /**
   * 推送状态变化事件
   * @param geofenceId  当前围栏ID (空字符串 = 途中/未知)
   * @param geofenceLabel 围栏显示名
   * @param geofenceIcon  围栏图标 emoji
   * @param motionState   运动状态
   * @param latitude      GPS 纬度 (0 = 未知)
   * @param longitude     GPS 经度 (0 = 未知)
   */
  pushStateChange(geofenceId: string, geofenceLabel: string,
                  geofenceIcon: string, motionState: string,
                  latitude: number, longitude: number,
                  scenarioTitle: string = ''): void {
    let now = Date.now();

    // 检查日期变化 (午夜翻转)
    let today = this.getTodayStr();
    if (today !== this.currentDate) {
      this.log.info(TAG, `Date changed: ${this.currentDate} → ${today}`);
      // 保存旧日期数据到历史
      this.saveEntriesForDate(this.currentDate);
      this.entries = [];
      this.currentDate = today;
      this.lastGeofenceId = '';
      this.lastMotionState = '';
    }

    // 去重: 同地点+同运动状态 且在 DEDUP_INTERVAL_MS 内 → 跳过
    if (geofenceId === this.lastGeofenceId &&
        motionState === this.lastMotionState &&
        now - this.lastPushTime < DailyTimelineService.DEDUP_INTERVAL_MS) {
      return;
    }

    // 仅当地点或运动状态有意义变化时才记录新 entry
    // 运动状态变化: 忽略 pickup/putdown/unknown, 只关注主要状态
    let isMainMotion = motionState !== 'pickup' && motionState !== 'putdown' && motionState !== 'unknown';
    if (!isMainMotion) return;

    let geofenceChanged = geofenceId !== this.lastGeofenceId;
    let motionChanged = motionState !== this.lastMotionState;

    if (!geofenceChanged && !motionChanged) return;

    // 关闭上一条 entry
    if (this.entries.length > 0) {
      let last = this.entries[this.entries.length - 1];
      if (last.endTime === 0) {
        last.endTime = now;
      }
    }

    // 显示标签: 围栏有名称用围栏名，否则异步 geocode
    let displayLabel = geofenceLabel;

    // 创建新 entry
    let entry: TimelineEntry = {
      id: now.toString(),
      startTime: now,
      endTime: 0,
      geofenceId: geofenceId,
      geofenceLabel: displayLabel,
      geofenceIcon: geofenceIcon,
      motionState: motionState,
      latitude: latitude,
      longitude: longitude,
      geocodeLabel: '',
      scenarioTitle: scenarioTitle,
    };

    this.entries.push(entry);

    // 防止过多 entry
    if (this.entries.length > MAX_ENTRIES_PER_DAY) {
      this.entries = this.entries.slice(-MAX_ENTRIES_PER_DAY);
    }

    this.lastGeofenceId = geofenceId;
    this.lastMotionState = motionState;
    this.lastPushTime = now;

    this.log.info(TAG, `Push: ${geofenceIcon} ${displayLabel || '途中'} [${motionState}] (${latitude.toFixed(4)},${longitude.toFixed(4)}) (total: ${this.entries.length})`);

    // 异步保存
    this.saveEntries();

    // 无围栏名但有坐标 → 异步 geocoding 填充地名
    if (displayLabel.length === 0 && latitude !== 0 && longitude !== 0) {
      this.asyncGeocodeEntry(entry);
    }
  }

  /**
   * 推送途中 GPS 轨迹点 (在移动状态下定期调用)
   */
  pushWaypoint(latitude: number, longitude: number): void {
    if (latitude === 0 && longitude === 0) return;
    if (this.entries.length === 0) return;

    let last = this.entries[this.entries.length - 1];
    // 只在进行中的非围栏 entry 上追加 waypoint
    if (last.endTime !== 0) return;
    if (last.geofenceId.length > 0 && last.motionState === 'stationary') return;

    if (!last.waypoints) {
      last.waypoints = [];
    }

    // 距离去重: 与上一个 waypoint 距离 < WAYPOINT_MIN_DISTANCE_M 则跳过
    if (last.waypoints.length > 0) {
      let prev = last.waypoints[last.waypoints.length - 1];
      let dist = this.haversineM(prev[0], prev[1], latitude, longitude);
      if (dist < WAYPOINT_MIN_DISTANCE_M) return;
    } else {
      // 也跟 entry 起点比较
      let dist = this.haversineM(last.latitude, last.longitude, latitude, longitude);
      if (dist < WAYPOINT_MIN_DISTANCE_M) return;
    }

    last.waypoints.push([latitude, longitude, Date.now()]);

    if (last.waypoints.length > MAX_WAYPOINTS_PER_ENTRY) {
      last.waypoints = last.waypoints.slice(-MAX_WAYPOINTS_PER_ENTRY);
    }

    // 日志: 每5个点记录一次
    if (last.waypoints.length % 5 === 0) {
      this.log.info(TAG, `Waypoint #${last.waypoints.length}: (${latitude.toFixed(4)},${longitude.toFixed(4)}) [${last.motionState}]`);
    }

    // 节流保存: 每 10 个 waypoint 保存一次
    if (last.waypoints.length % 10 === 0) {
      this.saveEntries();
    }
  }

  private haversineM(lat1: number, lng1: number, lat2: number, lng2: number): number {
    let R = 6371000;
    let dLat = (lat2 - lat1) * Math.PI / 180;
    let dLng = (lng2 - lng1) * Math.PI / 180;
    let a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
      Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
      Math.sin(dLng / 2) * Math.sin(dLng / 2);
    return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  }

  /**
   * 异步逆地理编码：为途中 entry 补充地名
   */
  private asyncGeocodeEntry(entry: TimelineEntry): void {
    GeoCodingService.getInstance().reverseGeocode(entry.latitude, entry.longitude).then((result) => {
      if (result.success && result.name && result.name.length > 0) {
        entry.geocodeLabel = result.name;
        // 如果 geofenceLabel 为空，用 geocode 结果作为显示名
        if (entry.geofenceLabel.length === 0) {
          entry.geofenceLabel = result.name;
          entry.geofenceIcon = '\u{1F4CD}';  // 📍
        }
        this.log.info(TAG, `Geocode: (${entry.latitude.toFixed(4)},${entry.longitude.toFixed(4)}) → ${result.name}`);
        this.saveEntries();
      } else if (result.success && result.address) {
        // 用道路名作为标签
        let road = result.address.road ?? '';
        let suburb = result.address.suburb ?? '';
        let label = road.length > 0 ? road : suburb;
        if (label.length > 0) {
          entry.geocodeLabel = label;
          if (entry.geofenceLabel.length === 0) {
            entry.geofenceLabel = label;
            entry.geofenceIcon = '\u{1F6E3}';  // 🛣️
          }
          this.log.info(TAG, `Geocode(addr): (${entry.latitude.toFixed(4)},${entry.longitude.toFixed(4)}) → ${label}`);
          this.saveEntries();
        }
      }
    }).catch(() => {
      // geocoding 失败不影响主流程
    });
  }

  /**
   * 获取今日时间线 (带实时 endTime 计算)
   */
  getDailyTimeline(): TimelineEntry[] {
    // 检查日期翻转
    let today = this.getTodayStr();
    if (today !== this.currentDate) {
      this.entries = [];
      this.currentDate = today;
    }

    // 更新最后一条的 endTime 为当前时间 (UI 显示用)
    let result: TimelineEntry[] = [];
    let now = Date.now();
    for (let i = 0; i < this.entries.length; i++) {
      let e = this.entries[i];
      let copy: TimelineEntry = {
        id: e.id,
        startTime: e.startTime,
        endTime: e.endTime === 0 ? now : e.endTime,
        geofenceId: e.geofenceId,
        geofenceLabel: e.geofenceLabel,
        geofenceIcon: e.geofenceIcon,
        motionState: e.motionState,
        latitude: e.latitude,
        longitude: e.longitude,
        geocodeLabel: e.geocodeLabel,
        scenarioTitle: e.scenarioTitle,
        waypoints: e.waypoints,
      };
      result.push(copy);
    }
    return result;
  }

  /**
   * 获取原始 entries (用于调试/持久化)
   */
  getRawEntries(): TimelineEntry[] {
    return this.entries;
  }

  /**
   * 合并短暂相同地点的 entries (用于 UI 简化显示)
   * 连续相同 geofenceId 的 entries 合并为一条，保留第一条的 startTime 和最后一条的 endTime
   */
  getMergedTimeline(): TimelineEntry[] {
    let raw = this.getDailyTimeline();
    return this.mergeRawEntries(raw);
  }

  private mergeRawEntries(raw: TimelineEntry[]): TimelineEntry[] {
    if (raw.length === 0) return [];

    let merged: TimelineEntry[] = [];
    let current = raw[0];

    for (let i = 1; i < raw.length; i++) {
      let next = raw[i];
      if (next.geofenceId.length > 0 &&
          next.geofenceId === current.geofenceId &&
          next.motionState === 'stationary' &&
          current.motionState === 'stationary') {
        current = {
          id: current.id,
          startTime: current.startTime,
          endTime: next.endTime,
          geofenceId: current.geofenceId,
          geofenceLabel: current.geofenceLabel,
          geofenceIcon: current.geofenceIcon,
          motionState: current.motionState,
          latitude: current.latitude,
          longitude: current.longitude,
          geocodeLabel: current.geocodeLabel,
          scenarioTitle: next.scenarioTitle.length > 0 ? next.scenarioTitle : current.scenarioTitle,
        };
      } else {
        merged.push(current);
        current = next;
      }
    }
    merged.push(current);
    return merged;
  }

  // ─── 持久化 ───

  private async saveEntries(): Promise<void> {
    this.saveEntriesForDate(this.currentDate);
  }

  private async saveEntriesForDate(dateStr: string): Promise<void> {
    if (!this.prefs) return;
    try {
      let entriesToSave = dateStr === this.currentDate ? this.entries : [];
      // 如果不是当天，从 prefs 中读取（已保存的）
      if (dateStr !== this.currentDate) return;

      let json = JSON.stringify(entriesToSave);
      let key = 'entries_' + dateStr;
      this.prefs.putSync(key, json);
      // 兼容旧格式
      this.prefs.putSync('date', dateStr);
      this.prefs.putSync('entries', json);

      // 更新日期列表
      if (entriesToSave.length > 0 && !this.savedDates.includes(dateStr)) {
        this.savedDates.push(dateStr);
        this.savedDates.sort();
        // 限制历史天数
        if (this.savedDates.length > MAX_HISTORY_DAYS) {
          let removed = this.savedDates.shift()!;
          this.prefs.deleteSync('entries_' + removed);
        }
        this.prefs.putSync(DATE_LIST_KEY, JSON.stringify(this.savedDates));
      }
      await this.prefs.flush();
    } catch (err) {
      this.log.warn(TAG, `Save failed: ${(err as Error).message}`);
    }
  }

  private async loadDateList(): Promise<void> {
    if (!this.prefs) return;
    try {
      let json = await this.prefs.get(DATE_LIST_KEY, '[]') as string;
      this.savedDates = JSON.parse(json) as string[];
      // 迁移: 如果旧格式有数据但 savedDates 没有今天，添加今天
      let oldDate = await this.prefs.get('date', '') as string;
      if (oldDate.length > 0 && !this.savedDates.includes(oldDate)) {
        // 把旧格式数据迁移到新 key
        let oldJson = await this.prefs.get('entries', '[]') as string;
        this.prefs.putSync('entries_' + oldDate, oldJson);
        this.savedDates.push(oldDate);
        this.savedDates.sort();
        this.prefs.putSync(DATE_LIST_KEY, JSON.stringify(this.savedDates));
        await this.prefs.flush();
        this.log.info(TAG, `Migrated old data for ${oldDate}`);
      }
    } catch (err) {
      this.savedDates = [];
    }
  }

  private parseEntriesJson(json: string): TimelineEntry[] {
    let parsed: Object[] = JSON.parse(json) as Object[];
    let result: TimelineEntry[] = [];
    for (let i = 0; i < parsed.length; i++) {
      let obj = parsed[i] as Record<string, Object>;
      let entry: TimelineEntry = {
        id: (obj['id'] as string) ?? '',
        startTime: (obj['startTime'] as number) ?? 0,
        endTime: (obj['endTime'] as number) ?? 0,
        geofenceId: (obj['geofenceId'] as string) ?? '',
        geofenceLabel: (obj['geofenceLabel'] as string) ?? '',
        geofenceIcon: (obj['geofenceIcon'] as string) ?? '',
        motionState: (obj['motionState'] as string) ?? '',
        latitude: (obj['latitude'] as number) ?? 0,
        longitude: (obj['longitude'] as number) ?? 0,
        geocodeLabel: (obj['geocodeLabel'] as string) ?? '',
        scenarioTitle: (obj['scenarioTitle'] as string) ?? '',
      };
      let wp = obj['waypoints'];
      if (wp) {
        entry.waypoints = wp as number[][];
      }
      result.push(entry);
    }
    return result;
  }

  private async loadEntries(): Promise<void> {
    if (!this.prefs) return;
    try {
      let key = 'entries_' + this.currentDate;
      let json = await this.prefs.get(key, '') as string;
      if (json.length === 0) {
        // 兼容旧格式
        let savedDate = await this.prefs.get('date', '') as string;
        if (savedDate === this.currentDate) {
          json = await this.prefs.get('entries', '[]') as string;
        }
      }
      if (json.length > 0) {
        this.entries = this.parseEntriesJson(json);
        // 恢复去重状态
        if (this.entries.length > 0) {
          let last = this.entries[this.entries.length - 1];
          this.lastGeofenceId = last.geofenceId;
          this.lastMotionState = last.motionState;
        }
        this.log.info(TAG, `Loaded ${this.entries.length} entries for ${this.currentDate}`);
      } else {
        this.log.info(TAG, `No data for ${this.currentDate}`);
        this.entries = [];
      }
    } catch (err) {
      this.log.warn(TAG, `Load failed: ${(err as Error).message}`);
      this.entries = [];
    }
  }

  /**
   * 获取历史某天的时间线
   */
  async getTimelineForDate(dateStr: string): Promise<TimelineEntry[]> {
    if (dateStr === this.currentDate || dateStr === this.getTodayStr()) {
      return this.getMergedTimeline();
    }
    if (!this.prefs) return [];
    try {
      let key = 'entries_' + dateStr;
      let json = await this.prefs.get(key, '[]') as string;
      let raw = this.parseEntriesJson(json);
      return this.mergeRawEntries(raw);
    } catch {
      return [];
    }
  }

  /**
   * 获取有数据的历史日期列表（含今天）
   */
  getAvailableDates(): string[] {
    let today = this.getTodayStr();
    let dates = this.savedDates.slice();
    if (!dates.includes(today) && this.entries.length > 0) {
      dates.push(today);
    }
    dates.sort();
    return dates;
  }

  // ─── 工具 ───

  private getTodayStr(): string {
    let d = new Date();
    let y = d.getFullYear().toString();
    let m = (d.getMonth() + 1).toString().padStart(2, '0');
    let day = d.getDate().toString().padStart(2, '0');
    return y + '-' + m + '-' + day;
  }
}
