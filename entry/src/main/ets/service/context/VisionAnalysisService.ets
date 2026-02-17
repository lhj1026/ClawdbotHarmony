/**
 * Vision Analysis Service
 * 
 * 视觉分析服务：定时拍照，AI 分析用户行为
 * 用于检测不健康的行为并给予提醒
 * 
 * ⚠️ 隐私注意：此功能需要用户明确授权
 */
import { camera, cameraPicker } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { LogService } from '../../common/LogService';
import { 
  VisionAnalysisConfig, 
  VisionAnalysisResult, 
  HealthRule,
} from './ContextModels';

const TAG = 'VisionAnalysis';
const PREFS_NAME = 'clawdbot_vision';
const KEY_CONFIG = 'vision_config';
const KEY_RULES = 'health_rules';
const KEY_HISTORY = 'analysis_history';

type VisionAlertListener = (result: VisionAnalysisResult, rule: HealthRule) => void;

export class VisionAnalysisService {
  private static instance: VisionAnalysisService;
  private log: LogService = LogService.getInstance();
  
  private config: VisionAnalysisConfig;
  private rules: Map<string, HealthRule> = new Map();
  private history: VisionAnalysisResult[] = [];
  private captureTimer: number = -1;
  private isRunning: boolean = false;
  private initialized: boolean = false;
  private context: common.UIAbilityContext | undefined;
  
  private alertListeners: VisionAlertListener[] = [];
  
  // AI 分析回调（由外部注入，调用云端 API）
  private analyzeImageCallback: ((imagePath: string) => Promise<VisionAnalysisResult>) | undefined;
  
  private constructor() {
    // 默认配置
    this.config = {
      enabled: false,  // 默认关闭，需要用户明确开启
      captureIntervalMinutes: 30,
      activeHours: {
        start: '07:00',
        end: '22:00',
      },
      onlyWhenScreenOn: true,
      deleteAfterAnalysis: true,
      localOnly: false,
    };
  }
  
  static getInstance(): VisionAnalysisService {
    if (!VisionAnalysisService.instance) {
      VisionAnalysisService.instance = new VisionAnalysisService();
    }
    return VisionAnalysisService.instance;
  }
  
  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.initialized) return;
    this.context = context;
    
    await this.loadConfig(context);
    await this.loadRules(context);
    await this.loadHistory(context);
    
    // 添加默认健康规则
    if (this.rules.size === 0) {
      this.addDefaultRules();
    }
    
    this.initialized = true;
    this.log.info(TAG, `Initialized: ${this.rules.size} rules, history: ${this.history.length}`);
  }
  
  private addDefaultRules(): void {
    const defaultRules: HealthRule[] = [
      {
        id: 'unhealthy_snacks',
        name: '避免高热量零食',
        triggerKeywords: ['薯片', 'chips', '可乐', 'cola', 'soda', '糖果', 'candy', '巧克力', 'chocolate', '饼干', 'cookies', '冰淇淋', 'ice cream'],
        exceptKeywords: ['坚果', 'nuts', '水果', 'fruit', '蔬菜', 'vegetable'],
        warningMessage: '🍟 检测到高热量零食，建议换成健康食品',
        suggestionMessage: '试试坚果、水果或酸奶',
        severity: 'warning',
        enabled: true,
      },
      {
        id: 'sedentary',
        name: '避免久坐',
        triggerKeywords: ['沙发', 'couch', 'sofa', '躺着', 'lying', '看电视', 'watching TV', '玩手机', 'phone'],
        activeTimeRanges: [
          { start: '09:00', end: '12:00' },
          { start: '14:00', end: '17:00' },
        ],
        warningMessage: '🧘 已经坐了一段时间，起来活动一下？',
        suggestionMessage: '站起来走动5分钟，做做伸展',
        severity: 'info',
        enabled: true,
      },
      {
        id: 'late_night_eating',
        name: '避免深夜进食',
        triggerKeywords: ['吃', 'eating', '食物', 'food', '零食', 'snack'],
        activeTimeRanges: [
          { start: '22:00', end: '23:59' },
          { start: '00:00', end: '06:00' },
        ],
        warningMessage: '🌙 深夜进食不利于消化和睡眠',
        suggestionMessage: '如果饿了，喝点水或吃点水果',
        severity: 'warning',
        enabled: true,
      },
      {
        id: 'poor_posture',
        name: '姿势提醒',
        triggerKeywords: ['低头', 'head down', '驼背', 'hunched', '趴着', 'lying face down'],
        warningMessage: '📱 注意姿势！抬起头来',
        suggestionMessage: '保持屏幕与眼睛平齐，背部挺直',
        severity: 'info',
        enabled: true,
      },
    ];
    
    for (const rule of defaultRules) {
      this.rules.set(rule.id, rule);
    }
  }
  
  // ==================== 配置管理 ====================
  
  getConfig(): VisionAnalysisConfig {
    return { ...this.config };
  }
  
  async updateConfig(newConfig: Partial<VisionAnalysisConfig>): Promise<void> {
    this.config = { ...this.config, ...newConfig };
    await this.saveConfig();
    
    // 重启服务以应用新配置
    if (this.isRunning) {
      this.stop();
      if (this.config.enabled) {
        this.start();
      }
    }
  }
  
  // ==================== 规则管理 ====================
  
  addRule(rule: HealthRule): void {
    this.rules.set(rule.id, rule);
    this.saveRulesAsync();
  }
  
  removeRule(id: string): boolean {
    const removed = this.rules.delete(id);
    if (removed) this.saveRulesAsync();
    return removed;
  }
  
  getRule(id: string): HealthRule | undefined {
    return this.rules.get(id);
  }
  
  getAllRules(): HealthRule[] {
    return Array.from(this.rules.values());
  }
  
  enableRule(id: string, enabled: boolean): void {
    const rule = this.rules.get(id);
    if (rule) {
      rule.enabled = enabled;
      this.saveRulesAsync();
    }
  }
  
  // ==================== 服务控制 ====================
  
  /**
   * 设置 AI 图像分析回调
   * 外部实现调用云端 API（如 GPT-4 Vision）
   */
  setAnalyzeCallback(callback: (imagePath: string) => Promise<VisionAnalysisResult>): void {
    this.analyzeImageCallback = callback;
  }
  
  start(): boolean {
    if (this.isRunning) return true;
    if (!this.config.enabled) {
      this.log.warn(TAG, 'Vision analysis is disabled');
      return false;
    }
    if (!this.analyzeImageCallback) {
      this.log.warn(TAG, 'No analyze callback set');
      return false;
    }
    
    const intervalMs = this.config.captureIntervalMinutes * 60 * 1000;
    
    this.captureTimer = setInterval(() => {
      this.captureAndAnalyze();
    }, intervalMs);
    
    this.isRunning = true;
    this.log.info(TAG, `Started: interval=${this.config.captureIntervalMinutes}min`);
    return true;
  }
  
  stop(): void {
    if (!this.isRunning) return;
    
    if (this.captureTimer >= 0) {
      clearInterval(this.captureTimer);
      this.captureTimer = -1;
    }
    
    this.isRunning = false;
    this.log.info(TAG, 'Stopped');
  }
  
  // ==================== 拍照分析 ====================
  
  /**
   * 手动触发一次分析
   */
  async triggerAnalysis(): Promise<VisionAnalysisResult | undefined> {
    return this.captureAndAnalyze();
  }
  
  private async captureAndAnalyze(): Promise<VisionAnalysisResult | undefined> {
    // 检查活跃时间
    if (!this.isWithinActiveHours()) {
      this.log.debug(TAG, 'Outside active hours, skipping');
      return undefined;
    }
    
    // TODO: 检查屏幕状态
    // if (this.config.onlyWhenScreenOn && !isScreenOn()) return;
    
    try {
      // 拍照
      const imagePath = await this.capturePhoto();
      if (!imagePath) {
        this.log.warn(TAG, 'Failed to capture photo');
        return undefined;
      }
      
      // 分析
      if (!this.analyzeImageCallback) {
        this.log.warn(TAG, 'No analyze callback');
        return undefined;
      }
      
      const result = await this.analyzeImageCallback(imagePath);
      result.imagePath = imagePath;
      
      this.log.info(TAG, `Analysis: ${result.description}`);
      
      // 检查健康规则
      await this.checkHealthRules(result);
      
      // 保存历史
      this.history.push(result);
      if (this.history.length > 100) {
        this.history = this.history.slice(-100);
      }
      this.saveHistoryAsync();
      
      // 删除照片（如果配置）
      if (this.config.deleteAfterAnalysis) {
        try {
          await fileIo.unlink(imagePath);
        } catch {
          // ignore
        }
      }
      
      return result;
    } catch (err) {
      this.log.error(TAG, `Analysis failed: ${(err as Error).message}`);
      return undefined;
    }
  }
  
  private async capturePhoto(): Promise<string | undefined> {
    // 使用前置摄像头拍照
    // 注意：实际实现需要更完整的相机控制
    try {
      // 简化实现：生成临时文件路径
      const timestamp = Date.now();
      const path = `${this.context?.filesDir}/vision_${timestamp}.jpg`;
      
      // TODO: 实际的相机拍照逻辑
      // 这里需要使用 CameraCapability 的功能
      this.log.debug(TAG, `Would capture photo to: ${path}`);
      
      // 暂时返回 undefined，等实际相机实现
      return undefined;
    } catch (err) {
      this.log.error(TAG, `Capture failed: ${(err as Error).message}`);
      return undefined;
    }
  }
  
  private isWithinActiveHours(): boolean {
    const now = new Date();
    const currentTime = `${now.getHours().toString().padStart(2, '0')}:${now.getMinutes().toString().padStart(2, '0')}`;
    
    const { start, end } = this.config.activeHours;
    return currentTime >= start && currentTime <= end;
  }
  
  // ==================== 健康规则检查 ====================
  
  private async checkHealthRules(result: VisionAnalysisResult): Promise<void> {
    const now = new Date();
    const currentTime = `${now.getHours().toString().padStart(2, '0')}:${now.getMinutes().toString().padStart(2, '0')}`;
    
    const allText = [
      result.description,
      ...result.detectedActivities,
      ...result.detectedObjects,
    ].join(' ').toLowerCase();
    
    for (const rule of this.rules.values()) {
      if (!rule.enabled) continue;
      
      // 检查时间范围
      if (rule.activeTimeRanges && rule.activeTimeRanges.length > 0) {
        const inRange = rule.activeTimeRanges.some(range => 
          currentTime >= range.start && currentTime <= range.end
        );
        if (!inRange) continue;
      }
      
      // 检查触发关键词
      const triggered = rule.triggerKeywords.some(kw => 
        allText.includes(kw.toLowerCase())
      );
      if (!triggered) continue;
      
      // 检查排除关键词
      if (rule.exceptKeywords && rule.exceptKeywords.length > 0) {
        const excepted = rule.exceptKeywords.some(kw => 
          allText.includes(kw.toLowerCase())
        );
        if (excepted) continue;
      }
      
      // 触发警告
      this.log.info(TAG, `Rule triggered: ${rule.name}`);
      
      // 更新结果
      result.concerns = result.concerns || [];
      result.concerns.push(rule.warningMessage);
      
      if (rule.suggestionMessage) {
        result.suggestions = result.suggestions || [];
        result.suggestions.push(rule.suggestionMessage);
      }
      
      // 发送通知
      await this.sendAlert(rule);
      
      // 通知监听器
      this.notifyAlertListeners(result, rule);
    }
  }
  
  private async sendAlert(rule: HealthRule): Promise<void> {
    try {
      const request: notificationManager.NotificationRequest = {
        id: Date.now() % 100000,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: rule.name,
            text: rule.warningMessage + (rule.suggestionMessage ? `\n${rule.suggestionMessage}` : ''),
          },
        },
      };
      
      await notificationManager.publish(request);
    } catch (err) {
      this.log.warn(TAG, `Alert failed: ${(err as Error).message}`);
    }
  }
  
  // ==================== 监听器 ====================
  
  addAlertListener(listener: VisionAlertListener): void {
    this.alertListeners.push(listener);
  }
  
  removeAlertListener(listener: VisionAlertListener): void {
    const idx = this.alertListeners.indexOf(listener);
    if (idx >= 0) this.alertListeners.splice(idx, 1);
  }
  
  private notifyAlertListeners(result: VisionAnalysisResult, rule: HealthRule): void {
    for (const listener of this.alertListeners) {
      try {
        listener(result, rule);
      } catch {
        // ignore
      }
    }
  }
  
  // ==================== 历史查询 ====================
  
  getHistory(limit: number = 50): VisionAnalysisResult[] {
    return this.history.slice(-limit);
  }
  
  getTodayStats(): {
    captures: number;
    healthyCount: number;
    concernCount: number;
  } {
    const today = new Date().toISOString().split('T')[0];
    const todayResults = this.history.filter(r => 
      new Date(r.timestamp).toISOString().split('T')[0] === today
    );
    
    let concernCount = 0;
    for (const r of todayResults) {
      if (r.concerns && r.concerns.length > 0) {
        concernCount++;
      }
    }
    
    return {
      captures: todayResults.length,
      healthyCount: todayResults.length - concernCount,
      concernCount,
    };
  }
  
  // ==================== 持久化 ====================
  
  private async saveConfig(): Promise<void> {
    if (!this.context) return;
    try {
      const store = await preferences.getPreferences(this.context, PREFS_NAME);
      await store.put(KEY_CONFIG, JSON.stringify(this.config));
      await store.flush();
    } catch (err) {
      this.log.warn(TAG, `Failed to save config: ${(err as Error).message}`);
    }
  }
  
  private async loadConfig(context: common.UIAbilityContext): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, PREFS_NAME);
      const data = await store.get(KEY_CONFIG, '') as string;
      if (data) {
        this.config = { ...this.config, ...JSON.parse(data) };
      }
    } catch {
      // use defaults
    }
  }
  
  private async saveRulesAsync(): Promise<void> {
    if (!this.context) return;
    try {
      const store = await preferences.getPreferences(this.context, PREFS_NAME);
      await store.put(KEY_RULES, JSON.stringify(Array.from(this.rules.entries())));
      await store.flush();
    } catch (err) {
      this.log.warn(TAG, `Failed to save rules: ${(err as Error).message}`);
    }
  }
  
  private async loadRules(context: common.UIAbilityContext): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, PREFS_NAME);
      const data = await store.get(KEY_RULES, '[]') as string;
      const entries = JSON.parse(data) as [string, HealthRule][];
      this.rules = new Map(entries);
    } catch {
      // use defaults
    }
  }
  
  private async saveHistoryAsync(): Promise<void> {
    if (!this.context) return;
    try {
      const store = await preferences.getPreferences(this.context, PREFS_NAME);
      await store.put(KEY_HISTORY, JSON.stringify(this.history));
      await store.flush();
    } catch {
      // ignore
    }
  }
  
  private async loadHistory(context: common.UIAbilityContext): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, PREFS_NAME);
      const data = await store.get(KEY_HISTORY, '[]') as string;
      this.history = JSON.parse(data);
    } catch {
      // empty history
    }
  }
  
  // ==================== 状态 ====================
  
  isActive(): boolean {
    return this.isRunning;
  }
  
  getStatus(): string {
    const stats = this.getTodayStats();
    return `Running: ${this.isRunning}, Today: ${stats.captures} captures, ${stats.concernCount} concerns`;
  }
}
