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

export class DailyTimelineService {
  private static instance: DailyTimelineService | null = null;
  private log: LogService = LogService.getInstance();
  private prefs: preferences.Preferences | undefined;
  private entries: TimelineEntry[] = [];
  private currentDate: string = '';
  private initialized: boolean = false;

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
      await this.loadEntries();
      this.initialized = true;
      this.log.info(TAG, `Init: ${this.entries.length} entries for ${this.currentDate}`);
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
                  latitude: number, longitude: number): void {
    let now = Date.now();

    // 检查日期变化 (午夜翻转)
    let today = this.getTodayStr();
    if (today !== this.currentDate) {
      this.log.info(TAG, `Date changed: ${this.currentDate} → ${today}`);
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
    if (raw.length === 0) return [];

    let merged: TimelineEntry[] = [];
    let current = raw[0];

    for (let i = 1; i < raw.length; i++) {
      let next = raw[i];
      // 同一地点 (非空) 且运动状态都是 stationary → 合并
      if (next.geofenceId.length > 0 &&
          next.geofenceId === current.geofenceId &&
          next.motionState === 'stationary' &&
          current.motionState === 'stationary') {
        // 延续当前 entry
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
    if (!this.prefs) return;
    try {
      let json = JSON.stringify(this.entries);
      this.prefs.putSync('date', this.currentDate);
      this.prefs.putSync('entries', json);
      await this.prefs.flush();
    } catch (err) {
      this.log.warn(TAG, `Save failed: ${(err as Error).message}`);
    }
  }

  private async loadEntries(): Promise<void> {
    if (!this.prefs) return;
    try {
      let savedDate = await this.prefs.get('date', '') as string;
      if (savedDate === this.currentDate) {
        let json = await this.prefs.get('entries', '[]') as string;
        let parsed: Object[] = JSON.parse(json) as Object[];
        this.entries = [];
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
          };
          this.entries.push(entry);
        }
        // 恢复去重状态
        if (this.entries.length > 0) {
          let last = this.entries[this.entries.length - 1];
          this.lastGeofenceId = last.geofenceId;
          this.lastMotionState = last.motionState;
        }
        this.log.info(TAG, `Loaded ${this.entries.length} entries for ${savedDate}`);
      } else {
        this.log.info(TAG, `New day or no saved data (saved=${savedDate}, today=${this.currentDate})`);
        this.entries = [];
      }
    } catch (err) {
      this.log.warn(TAG, `Load failed: ${(err as Error).message}`);
      this.entries = [];
    }
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
