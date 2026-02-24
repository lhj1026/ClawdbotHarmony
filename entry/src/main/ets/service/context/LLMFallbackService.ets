/**
 * LLM Fallback Service
 *
 * 当 C++ 决策树无匹配结果时，调用 LLM 分析当前情景并生成推荐。
 * - 单例模式
 * - 限流：每小时最多 3 次 LLM 调用
 * - 缓存：相同情景 10 分钟内复用结果
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { LogService } from '../../common/LogService';
import { Constants } from '../../common/Constants';
import { AIService } from '../AIService';
import { SettingsData } from '../../model/Models';
import { ContextSnapshot } from './ContextEngine';
import { LLMRecommendation } from './ContextModels';

const TAG = 'LLMFallback';

/** Cache entry for recent LLM results */
interface CacheEntry {
  key: string;
  result: LLMRecommendation | null;
  timestamp: number;
}

/** Parsed LLM JSON response */
interface LLMResponsePayload {
  action: string;
  title: string;
  content: string;
  priority: string;
}

const DAY_NAMES: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

export class LLMFallbackService {
  private static instance: LLMFallbackService | null = null;
  private log: LogService = LogService.getInstance();

  // Rate limiting: max 6 calls per hour
  private static readonly MAX_CALLS_PER_HOUR: number = 6;
  private callTimestamps: number[] = [];

  // Cache: reuse results for same context within 5 min
  private static readonly CACHE_TTL_MS: number = 5 * 60 * 1000;
  private cache: CacheEntry[] = [];
  private static readonly MAX_CACHE_SIZE: number = 10;

  private context: common.UIAbilityContext | null = null;

  // 调用方在 analyzeContext 前设置，用于 prompt
  btDeviceNames: string = '';

  private constructor() {}

  static getInstance(): LLMFallbackService {
    if (!LLMFallbackService.instance) {
      LLMFallbackService.instance = new LLMFallbackService();
    }
    return LLMFallbackService.instance;
  }

  init(context: common.UIAbilityContext): void {
    this.context = context;
  }

  /**
   * Analyze current context via LLM when C++ engine returns no matches.
   * Returns a structured recommendation, or null if LLM says NO_ACTION
   * or if rate-limited / error.
   */
  async analyzeContext(snapshot: ContextSnapshot): Promise<LLMRecommendation | null> {
    this.log.info(TAG, `[Explore-DBG] analyzeContext called, tod=${snapshot.timeOfDay}, motion=${snapshot.motionState}, geofence=${snapshot.geofence ?? 'none'}`);

    // Check cache first
    let cacheKey = this.buildCacheKey(snapshot);
    let cached = this.getCached(cacheKey);
    if (cached !== undefined) {
      this.log.info(TAG, `[Explore-DBG] Cache hit for key=${cacheKey}, result=${cached ? cached.title : 'null'}`);
      return cached;
    }

    // Check rate limit
    if (!this.canMakeCall()) {
      this.log.warn(TAG, `[Explore-DBG] Rate limited (${this.callTimestamps.length}/${LLMFallbackService.MAX_CALLS_PER_HOUR} calls in last hour)`);
      return null;
    }

    // Load settings
    let settings = await this.loadSettings();
    if (!settings) {
      this.log.warn(TAG, '[Explore-DBG] No API settings — provider has no key configured');
      return null;
    }
    this.log.info(TAG, `[Explore-DBG] LLM settings loaded: provider=${settings.provider}, model=${settings.model}`);

    // Build prompt
    let systemPrompt = this.buildSystemPrompt();
    let userMessage = this.buildUserMessage(snapshot);

    // Call LLM
    let result: LLMRecommendation | null = null;
    try {
      this.recordCall();
      let ai = AIService.getInstance();
      let response = await ai.simpleChat(systemPrompt, userMessage, settings);
      result = this.parseResponse(response);
      this.log.info(TAG, `LLM analysis complete: ${result ? result.title : 'NO_ACTION'}`);
    } catch (err) {
      this.log.error(TAG, `LLM call failed: ${(err as Error).message}`);
    }

    // Cache result (including null for NO_ACTION)
    this.setCache(cacheKey, result);
    return result;
  }

  // ==================== Prompt building ====================

  private buildSystemPrompt(): string {
    return '你是一个情景智能助手。根据用户当前的环境数据，判断是否需要提供帮助。\n\n' +
      '请分析:\n' +
      '1. 用户可能在做什么？\n' +
      '2. 是否需要提醒或建议？\n' +
      '3. 如果需要，给出一条简短建议。\n\n' +
      '如果不需要任何提醒，回复 "NO_ACTION"。\n' +
      '否则返回 JSON: {"action": "suggestion", "title": "标题", "content": "内容", "priority": "low|medium|high"}';
  }

  private buildUserMessage(snapshot: ContextSnapshot): string {
    let hour = snapshot.hour;
    let dayOfWeek = parseInt(snapshot.dayOfWeek);
    let dayName = (dayOfWeek >= 0 && dayOfWeek < DAY_NAMES.length)
      ? DAY_NAMES[dayOfWeek] : '未知';

    let geofenceStr = snapshot.geofence ? snapshot.geofence : '未知';
    let chargingStr = snapshot.isCharging === 'true' ? '充电中' : '未充电';
    let wifiStr = snapshot.wifiSsid ? snapshot.wifiSsid : '未连接';
    let btStr = this.btDeviceNames.length > 0 ? this.btDeviceNames : '无';

    return '当前状态:\n' +
      `- 时间: ${snapshot.timeOfDay} (${hour}:00), ${dayName}\n` +
      `- 位置: ${geofenceStr}\n` +
      `- 运动: ${snapshot.motionState}\n` +
      `- 电量: ${snapshot.batteryLevel}%, ${chargingStr}\n` +
      `- 网络: ${snapshot.networkType}\n` +
      `- WiFi: ${wifiStr}\n` +
      `- 蓝牙设备: ${btStr}`;
  }

  // ==================== Response parsing ====================

  private parseResponse(response: string): LLMRecommendation | null {
    let trimmed = response.trim();

    // Check for NO_ACTION
    if (trimmed.indexOf('NO_ACTION') >= 0) {
      return null;
    }

    // Try to extract JSON from the response
    let jsonStr = this.extractJson(trimmed);
    if (jsonStr.length === 0) {
      this.log.warn(TAG, 'Could not extract JSON from LLM response');
      return null;
    }

    try {
      let parsed: LLMResponsePayload = JSON.parse(jsonStr) as LLMResponsePayload;

      // Validate required fields
      if (!parsed.title || !parsed.content) {
        this.log.warn(TAG, 'LLM response missing title or content');
        return null;
      }

      let priority = parsed.priority || 'low';
      // Normalize priority
      if (priority !== 'low' && priority !== 'medium' && priority !== 'high') {
        priority = 'low';
      }

      let rec: LLMRecommendation = {
        action: parsed.action || 'suggestion',
        title: parsed.title,
        content: parsed.content,
        priority: priority,
        source: 'llm'
      };
      return rec;
    } catch (err) {
      this.log.warn(TAG, `Failed to parse LLM JSON: ${(err as Error).message}`);
      return null;
    }
  }

  /** Extract the first JSON object from a string that may contain surrounding text */
  private extractJson(text: string): string {
    let start = text.indexOf('{');
    if (start < 0) return '';

    let depth = 0;
    for (let i = start; i < text.length; i++) {
      let ch = text.charAt(i);
      if (ch === '{') {
        depth++;
      } else if (ch === '}') {
        depth--;
        if (depth === 0) {
          return text.substring(start, i + 1);
        }
      }
    }
    return '';
  }

  // ==================== Rate limiting ====================

  private canMakeCall(): boolean {
    let now = Date.now();
    let oneHourAgo = now - 60 * 60 * 1000;

    // Prune old timestamps
    let recent: number[] = [];
    for (let i = 0; i < this.callTimestamps.length; i++) {
      if (this.callTimestamps[i] > oneHourAgo) {
        recent.push(this.callTimestamps[i]);
      }
    }
    this.callTimestamps = recent;

    return this.callTimestamps.length < LLMFallbackService.MAX_CALLS_PER_HOUR;
  }

  private recordCall(): void {
    this.callTimestamps.push(Date.now());
  }

  // ==================== Caching ====================

  private buildCacheKey(snapshot: ContextSnapshot): string {
    // Key on the fields that meaningfully affect the recommendation (including WiFi/BT)
    return `${snapshot.timeOfDay}_${snapshot.hour}_${snapshot.dayOfWeek}_` +
      `${snapshot.motionState}_${snapshot.geofence || 'none'}_` +
      `${snapshot.networkType}_${snapshot.isCharging}_` +
      `${snapshot.wifiSsid || 'none'}_${this.btDeviceNames || 'none'}`;
  }

  /**
   * Returns cached result if found and not expired.
   * Returns undefined if no cache hit (to distinguish from cached null).
   */
  private getCached(key: string): LLMRecommendation | null | undefined {
    let now = Date.now();
    for (let i = 0; i < this.cache.length; i++) {
      let entry = this.cache[i];
      if (entry.key === key) {
        if (now - entry.timestamp < LLMFallbackService.CACHE_TTL_MS) {
          return entry.result;
        }
        // Expired — remove
        this.cache.splice(i, 1);
        return undefined;
      }
    }
    return undefined;
  }

  private setCache(key: string, result: LLMRecommendation | null): void {
    // Remove existing entry for this key
    for (let i = 0; i < this.cache.length; i++) {
      if (this.cache[i].key === key) {
        this.cache.splice(i, 1);
        break;
      }
    }

    // Evict oldest if at capacity
    if (this.cache.length >= LLMFallbackService.MAX_CACHE_SIZE) {
      this.cache.splice(0, 1);
    }

    let entry: CacheEntry = { key: key, result: result, timestamp: Date.now() };
    this.cache.push(entry);
  }

  // ==================== Settings ====================

  private async loadSettings(): Promise<SettingsData | null> {
    if (!this.context) return null;
    try {
      let store = await preferences.getPreferences(this.context, Constants.PREFS_SETTINGS);
      let provider = (await store.get('provider', 'openrouter')) as string;
      let keyPref = 'key_' + provider;
      let urlPref = 'url_' + provider;
      let modelPref = 'model_' + provider;
      let apiKey = (await store.get(keyPref, '')) as string;
      let baseUrl = (await store.get(urlPref, '')) as string;

      let defaultModel = provider === 'openrouter' ? Constants.DEFAULT_MODEL_OPENROUTER
        : provider === 'anthropic' ? Constants.DEFAULT_MODEL_ANTHROPIC
          : provider === 'openai' ? Constants.DEFAULT_MODEL_OPENAI
            : provider === 'siliconflow' ? Constants.DEFAULT_MODEL_SILICONFLOW
              : provider === 'custom' ? '' : 'llama3';
      let model = (await store.get(modelPref, defaultModel)) as string;
      // 如果存储的 model 为空字符串，回退到默认模型
      if (model.length === 0 && defaultModel.length > 0) {
        model = defaultModel;
      }

      // Use built-in keys as fallback
      if (apiKey.length === 0 && provider === 'openrouter' && Constants.OPENROUTER_DEFAULT_KEY.length > 0) {
        apiKey = Constants.OPENROUTER_DEFAULT_KEY;
      }
      if (apiKey.length === 0 && (provider === 'openai' || provider === 'siliconflow') && Constants.SILICONFLOW_DEFAULT_KEY.length > 0) {
        apiKey = Constants.SILICONFLOW_DEFAULT_KEY;
      }

      if (apiKey.length === 0 && provider !== 'local') {
        return null;
      }

      let settings: SettingsData = {
        provider: provider,
        apiKey: apiKey,
        model: model,
        baseUrl: baseUrl,
        temperature: 0.3,  // Lower temperature for more predictable analysis
      };
      return settings;
    } catch (err) {
      this.log.error(TAG, `loadSettings failed: ${(err as Error).message}`);
      return null;
    }
  }
}
