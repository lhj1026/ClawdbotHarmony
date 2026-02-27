/**
 * PlaceCategoryService - 地点分类配置管理
 *
 * 功能：
 * 1. 从配置文件加载分类定义
 * 2. 支持运行时添加/修改分类
 * 3. 提供分类标签的多语言支持
 */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { LogService } from '../../common/LogService';
import { I18n } from '../../common/I18n';

const TAG = 'PlaceCategoryService';

/** 地点分类定义 */
export interface PlaceCategoryDef {
  id: string;
  icon: string;
  color: string;
  timePatterns: TimePatterns;
  defaultRadius: number;
}

/** 时间模式（用于推断分类） */
export interface TimePatterns {
  nightRatio?: number;
  workdayRatio?: number;
  weekendRatioMax?: number;
  weekendRatio?: number;
  lunchHours?: number[];
  dinnerHours?: number[];
  activeHours?: number[];
}

/** 停留检测配置 */
export interface StayDetectionConfig {
  minStayMinutes: number;
  minGpsAccuracy: number;
  gpsDriftThreshold: number;
  autoConfirmAfterVisits: number;
  notificationEnabled: boolean;
}

/** 附近建议配置 */
export interface NearbySuggestionConfig {
  radiusMeters: number;
  maxResults: number;
  cooldownMinutes: number;
}

/** 完整配置 */
export interface PlaceCategoriesConfig {
  version: number;
  categories: PlaceCategoryDef[];
  stayDetection: StayDetectionConfig;
  nearbySuggestion: NearbySuggestionConfig;
}

const CONFIG_FILE = 'place_categories.json';
const DEFAULT_CONFIG_FILE = 'config/place_categories.json';

export class PlaceCategoryService {
  private static instance: PlaceCategoryService;
  private log: LogService = LogService.getInstance();

  private config: PlaceCategoriesConfig | null = null;
  private context: common.UIAbilityContext | null = null;
  private prefs: preferences.Preferences | null = null;

  private customCategories: Map<string, PlaceCategoryDef> = new Map();

  private constructor() {}

  static getInstance(): PlaceCategoryService {
    if (!PlaceCategoryService.instance) {
      PlaceCategoryService.instance = new PlaceCategoryService();
    }
    return PlaceCategoryService.instance;
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    this.prefs = await preferences.getPreferences(context, 'place_categories');

    await this.loadConfig();
    await this.loadCustomCategories();

    this.log.info(TAG, `Initialized with ${this.getAllCategories().length} categories`);
  }

  // ==================== 分类获取 ====================

  /**
   * 获取所有分类（内置 + 自定义）
   */
  getAllCategories(): PlaceCategoryDef[] {
    let result: PlaceCategoryDef[] = [];

    if (this.config && this.config.categories) {
      for (let cat of this.config.categories) {
        let custom = this.customCategories.get(cat.id);
        result.push(custom || cat);
      }
    }

    this.customCategories.forEach((cat: PlaceCategoryDef, id: string) => {
      let exists = result.some(c => c.id === id);
      if (!exists) {
        result.push(cat);
      }
    });

    return result;
  }

  /**
   * 获取单个分类
   */
  getCategory(id: string): PlaceCategoryDef | undefined {
    let custom = this.customCategories.get(id);
    if (custom) return custom;

    if (this.config && this.config.categories) {
      for (let cat of this.config.categories) {
        if (cat.id === id) return cat;
      }
    }
    return undefined;
  }

  /**
   * 获取分类的显示标签（多语言）
   */
  getCategoryLabel(id: string): string {
    let key = `place.category.${id}`;
    let translated = I18n.t(key);
    if (translated !== key) {
      return translated;
    }

    let cat = this.getCategory(id);
    if (cat) {
      return `${cat.icon} ${id}`;
    }
    return id;
  }

  /**
   * 获取分类图标
   */
  getCategoryIcon(id: string): string {
    let cat = this.getCategory(id);
    return cat ? cat.icon : '📍';
  }

  /**
   * 获取分类颜色
   */
  getCategoryColor(id: string): string {
    let cat = this.getCategory(id);
    return cat ? cat.color : '#9E9E9E';
  }

  /**
   * 获取默认半径
   */
  getDefaultRadius(id: string): number {
    let cat = this.getCategory(id);
    return cat ? cat.defaultRadius : 80;
  }

  // ==================== 分类管理 ====================

  /**
   * 添加或更新自定义分类
   */
  async setCustomCategory(category: PlaceCategoryDef): Promise<void> {
    this.customCategories.set(category.id, category);
    await this.saveCustomCategories();
    this.log.info(TAG, `Saved custom category: ${category.id}`);
  }

  /**
   * 删除自定义分类
   */
  async deleteCustomCategory(id: string): Promise<boolean> {
    if (!this.customCategories.has(id)) return false;

    this.customCategories.delete(id);
    await this.saveCustomCategories();
    this.log.info(TAG, `Deleted custom category: ${id}`);
    return true;
  }

  // ==================== 配置获取 ====================

  /**
   * 获取停留检测配置
   */
  getStayDetectionConfig(): StayDetectionConfig {
    if (this.config && this.config.stayDetection) {
      return this.config.stayDetection;
    }
    return {
      minStayMinutes: 5,
      minGpsAccuracy: 100,
      gpsDriftThreshold: 50,
      autoConfirmAfterVisits: 3,
      notificationEnabled: true,
    };
  }

  /**
   * 获取附近建议配置
   */
  getNearbySuggestionConfig(): NearbySuggestionConfig {
    if (this.config && this.config.nearbySuggestion) {
      return this.config.nearbySuggestion;
    }
    return {
      radiusMeters: 500,
      maxResults: 3,
      cooldownMinutes: 30,
    };
  }

  // ==================== 时间模式推断 ====================

  /**
   * 根据时间模式推断地点分类
   */
  inferCategory(
    nightRatio: number,
    workdayRatio: number,
    weekendRatio: number,
    weekdayHours: number[]
  ): string {
    let categories = this.getAllCategories();

    for (let cat of categories) {
      let patterns = cat.timePatterns;

      if (patterns.nightRatio && nightRatio > patterns.nightRatio) {
        return cat.id;
      }

      if (patterns.workdayRatio && patterns.weekendRatioMax) {
        if (workdayRatio > patterns.workdayRatio && weekendRatio < patterns.weekendRatioMax) {
          return cat.id;
        }
      }

      if (patterns.weekendRatio && weekendRatio > patterns.weekendRatio) {
        return cat.id;
      }

      if (patterns.lunchHours && weekdayHours.some(h => patterns.lunchHours!.includes(h))) {
        return cat.id;
      }
    }

    return 'custom';
  }

  // ==================== 时间格式化 ====================

  /**
   * 格式化时间差（多语言）
   */
  formatTimeAgo(timestamp: number): string {
    if (timestamp === 0) return '';

    let diffMs = Date.now() - timestamp;
    let diffMins = Math.round(diffMs / 60000);
    let diffHours = Math.round(diffMs / 3600000);
    let diffDays = Math.round(diffMs / 86400000);

    if (diffMins < 1) {
      return I18n.t('time.justNow');
    } else if (diffMins < 60) {
      return I18n.t('time.minutesAgo').replace('{0}', String(diffMins));
    } else if (diffHours < 24) {
      return I18n.t('time.hoursAgo').replace('{0}', String(diffHours));
    } else if (diffDays < 7) {
      return I18n.t('time.daysAgo').replace('{0}', String(diffDays));
    } else {
      let date = new Date(timestamp);
      return `${date.getMonth() + 1}/${date.getDate()}`;
    }
  }

  /**
   * 格式化停留时长（多语言）
   */
  formatStayDuration(ms: number): string {
    let mins = Math.round(ms / 60000);
    if (mins < 60) {
      return `${mins} ${I18n.t('place.minutes')}`;
    }
    let hours = Math.round(ms / 3600000);
    return `${hours} ${I18n.t('time.hoursAgo').replace(' ago', '').replace('{0}', '')}`;
  }

  // ==================== 持久化 ====================

  private async loadConfig(): Promise<void> {
    try {
      let filePath = `${this.context!.filesDir}/${CONFIG_FILE}`;
      let stat = fileIo.statSync(filePath);
      if (stat) {
        let file = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
        let buf = new ArrayBuffer(stat.size);
        fileIo.readSync(file.fd, buf);
        fileIo.closeSync(file.fd);

        let decoder = util.TextDecoder.create('utf-8');
        let json = decoder.decodeToString(new Uint8Array(buf));
        this.config = JSON.parse(json) as PlaceCategoriesConfig;
        this.log.info(TAG, 'Loaded config from file');
        return;
      }
    } catch (err) {
      this.log.debug(TAG, `No user config: ${(err as Error).message}`);
    }

    await this.loadDefaultConfig();
  }

  private async loadDefaultConfig(): Promise<void> {
    try {
      let resourceMgr = this.context!.resourceManager;
      let rawData = await resourceMgr.getRawFileContent(DEFAULT_CONFIG_FILE);
      let decoder = util.TextDecoder.create('utf-8');
      let json = decoder.decodeToString(new Uint8Array(rawData.buffer));
      this.config = JSON.parse(json) as PlaceCategoriesConfig;
      this.log.info(TAG, 'Loaded default config');
    } catch (err) {
      this.log.warn(TAG, `Failed to load default config: ${(err as Error).message}`);
      this.config = this.createFallbackConfig();
    }
  }

  private async loadCustomCategories(): Promise<void> {
    if (!this.prefs) return;

    try {
      let json = String(await this.prefs.get('custom_categories', '{}'));
      let data = JSON.parse(json) as Record<string, PlaceCategoryDef>;

      this.customCategories.clear();
      let keys = Object.keys(data);
      for (let key of keys) {
        this.customCategories.set(key, data[key]);
      }

      this.log.info(TAG, `Loaded ${this.customCategories.size} custom categories`);
    } catch (err) {
      this.log.warn(TAG, `Failed to load custom categories: ${(err as Error).message}`);
    }
  }

  private async saveCustomCategories(): Promise<void> {
    if (!this.prefs) return;

    try {
      let data: Record<string, PlaceCategoryDef> = {};
      this.customCategories.forEach((cat: PlaceCategoryDef, id: string) => {
        data[id] = cat;
      });

      await this.prefs.put('custom_categories', JSON.stringify(data));
      await this.prefs.flush();
    } catch (err) {
      this.log.error(TAG, `Failed to save custom categories: ${(err as Error).message}`);
    }
  }

  private createFallbackConfig(): PlaceCategoriesConfig {
    return {
      version: 1,
      categories: [
        { id: 'home', icon: '🏠', color: '#4CAF50', timePatterns: { nightRatio: 0.4 }, defaultRadius: 80 },
        { id: 'work', icon: '🏢', color: '#2196F3', timePatterns: { workdayRatio: 0.5, weekendRatioMax: 0.2 }, defaultRadius: 150 },
        { id: 'restaurant', icon: '🍽️', color: '#FF9800', timePatterns: { lunchHours: [11, 12, 13, 14] }, defaultRadius: 80 },
        { id: 'shopping', icon: '🛒', color: '#9C27B0', timePatterns: {}, defaultRadius: 120 },
        { id: 'transit', icon: '🚇', color: '#607D8B', timePatterns: {}, defaultRadius: 100 },
        { id: 'gym', icon: '💪', color: '#E91E63', timePatterns: { weekendRatio: 0.4 }, defaultRadius: 80 },
        { id: 'custom', icon: '📍', color: '#9E9E9E', timePatterns: {}, defaultRadius: 80 },
      ],
      stayDetection: {
        minStayMinutes: 5,
        minGpsAccuracy: 100,
        gpsDriftThreshold: 50,
        autoConfirmAfterVisits: 3,
        notificationEnabled: true,
      },
      nearbySuggestion: {
        radiusMeters: 500,
        maxResults: 3,
        cooldownMinutes: 30,
      },
    };
  }
}
