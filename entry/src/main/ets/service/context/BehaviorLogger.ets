/**
 * Behavior Logger
 * 
 * 记录用户行为，用于强化学习训练
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { LogService } from '../../common/LogService';
import { 
  BehaviorRecord, 
  EnvironmentContext, 
  UserAction, 
  ActionOutcome,
  ContextRule,
  RuleTrigger,
} from './ContextModels';

const TAG = 'BehaviorLogger';
const PREFS_NAME = 'clawdbot_behavior';
const KEY_RECORDS = 'behavior_records';
const KEY_RULES = 'learned_rules';
const MAX_RECORDS = 1000;  // 最多保存1000条记录

export class BehaviorLogger {
  private static instance: BehaviorLogger;
  private log: LogService = LogService.getInstance();
  
  private records: BehaviorRecord[] = [];
  private rules: Map<string, ContextRule> = new Map();
  private initialized: boolean = false;
  private context: common.UIAbilityContext | undefined;
  
  private constructor() {}
  
  static getInstance(): BehaviorLogger {
    if (!BehaviorLogger.instance) {
      BehaviorLogger.instance = new BehaviorLogger();
    }
    return BehaviorLogger.instance;
  }
  
  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.initialized) return;
    this.context = context;
    
    await this.loadRecords(context);
    await this.loadRules(context);
    
    this.initialized = true;
    this.log.info(TAG, `Initialized: ${this.records.length} records, ${this.rules.size} rules`);
  }
  
  // ==================== 行为记录 ====================
  
  /**
   * 记录一次用户行为
   */
  async logBehavior(
    context: EnvironmentContext,
    action: UserAction,
    outcome?: ActionOutcome
  ): Promise<BehaviorRecord> {
    const record: BehaviorRecord = {
      id: `bh_${Date.now()}_${Math.floor(Math.random() * 10000)}`,
      timestamp: Date.now(),
      context,
      action,
      outcome,
    };
    
    this.records.push(record);
    
    // 限制记录数量
    if (this.records.length > MAX_RECORDS) {
      this.records = this.records.slice(-MAX_RECORDS);
    }
    
    this.log.info(TAG, `Logged: ${action.type} at ${context.currentGeofence?.name ?? 'unknown'}`);
    
    // 异步保存
    this.saveRecordsAsync();
    
    return record;
  }
  
  /**
   * 更新行为记录的结果
   */
  async updateOutcome(recordId: string, outcome: ActionOutcome): Promise<boolean> {
    const record = this.records.find(r => r.id === recordId);
    if (!record) return false;
    
    record.outcome = outcome;
    this.log.info(TAG, `Updated outcome: ${recordId} accepted=${outcome.accepted}`);
    
    // 用于规则学习
    this.updateRuleFromOutcome(record);
    
    this.saveRecordsAsync();
    return true;
  }
  
  // ==================== 规则学习 ====================
  
  /**
   * 基于行为结果更新或创建规则
   */
  private updateRuleFromOutcome(record: BehaviorRecord): void {
    const ctx = record.context;
    const action = record.action;
    const outcome = record.outcome;
    
    if (!outcome) return;
    
    // 生成规则key：基于位置+动作
    const geofenceId = ctx.currentGeofence?.id ?? 'anywhere';
    const ruleKey = `${geofenceId}:${action.type}:${action.target ?? ''}`;
    
    let rule = this.rules.get(ruleKey);
    
    if (!rule) {
      // 创建新规则
      rule = {
        id: ruleKey,
        trigger: this.buildTriggerFromContext(ctx),
        action: action,
        confidence: 0.5,
        triggerCount: 0,
        acceptCount: 0,
        createdAt: Date.now(),
        updatedAt: Date.now(),
        enabled: true,
      };
      this.rules.set(ruleKey, rule);
    }
    
    // 更新统计
    rule.triggerCount++;
    if (outcome.accepted) {
      rule.acceptCount++;
    }
    rule.lastTriggered = Date.now();
    rule.updatedAt = Date.now();
    
    // 计算置信度（简单的频率估计）
    rule.confidence = rule.acceptCount / rule.triggerCount;
    
    // 如果置信度太低，禁用规则
    if (rule.triggerCount >= 5 && rule.confidence < 0.2) {
      rule.enabled = false;
      this.log.info(TAG, `Disabled low-confidence rule: ${ruleKey} (${(rule.confidence * 100).toFixed(0)}%)`);
    }
    
    this.saveRulesAsync();
    this.log.info(TAG, `Rule updated: ${ruleKey} conf=${(rule.confidence * 100).toFixed(0)}% (${rule.acceptCount}/${rule.triggerCount})`);
  }
  
  private buildTriggerFromContext(ctx: EnvironmentContext): RuleTrigger {
    const trigger: RuleTrigger = {};
    
    if (ctx.currentGeofence) {
      trigger.geofenceIds = [ctx.currentGeofence.id];
    }
    
    trigger.timeOfDay = [ctx.timeOfDay];
    
    if (ctx.motionState !== 'unknown') {
      trigger.motionStates = [ctx.motionState];
    }
    
    return trigger;
  }
  
  // ==================== 规则查询 ====================
  
  /**
   * 获取匹配当前上下文的规则
   */
  getMatchingRules(ctx: EnvironmentContext): ContextRule[] {
    const matching: ContextRule[] = [];
    
    for (const rule of this.rules.values()) {
      if (!rule.enabled) continue;
      if (this.ruleMatchesContext(rule, ctx)) {
        matching.push(rule);
      }
    }
    
    // 按置信度排序
    matching.sort((a, b) => b.confidence - a.confidence);
    
    return matching;
  }
  
  private ruleMatchesContext(rule: ContextRule, ctx: EnvironmentContext): boolean {
    const t = rule.trigger;
    
    // 检查位置
    if (t.geofenceIds && t.geofenceIds.length > 0) {
      if (!ctx.currentGeofence) return false;
      if (!t.geofenceIds.includes(ctx.currentGeofence.id)) return false;
    }
    
    // 检查时间
    if (t.timeOfDay && t.timeOfDay.length > 0) {
      if (!t.timeOfDay.includes(ctx.timeOfDay)) return false;
    }
    
    // 检查星期
    if (t.daysOfWeek && t.daysOfWeek.length > 0) {
      if (!t.daysOfWeek.includes(ctx.dayOfWeek)) return false;
    }
    
    // 检查运动状态
    if (t.motionStates && t.motionStates.length > 0) {
      if (!t.motionStates.includes(ctx.motionState)) return false;
    }
    
    // 检查网络
    if (t.networkTypes && t.networkTypes.length > 0) {
      if (!t.networkTypes.includes(ctx.networkType)) return false;
    }
    
    // 检查电量
    if (t.minBattery !== undefined) {
      if (ctx.batteryLevel < t.minBattery) return false;
    }
    
    return true;
  }
  
  /**
   * 获取所有规则
   */
  getAllRules(): ContextRule[] {
    return Array.from(this.rules.values());
  }
  
  /**
   * 获取高置信度规则
   */
  getHighConfidenceRules(minConfidence: number = 0.6): ContextRule[] {
    return this.getAllRules().filter(r => r.enabled && r.confidence >= minConfidence);
  }
  
  // ==================== 统计分析 ====================
  
  /**
   * 获取某个地点的常见行为
   */
  getCommonActionsAtGeofence(geofenceId: string, limit: number = 5): { action: UserAction, count: number }[] {
    const actionCounts = new Map<string, { action: UserAction, count: number }>();
    
    for (const record of this.records) {
      if (record.context.currentGeofence?.id !== geofenceId) continue;
      if (!record.outcome?.accepted) continue;
      
      const key = `${record.action.type}:${record.action.target ?? ''}`;
      const existing = actionCounts.get(key);
      if (existing) {
        existing.count++;
      } else {
        actionCounts.set(key, { action: record.action, count: 1 });
      }
    }
    
    const sorted = Array.from(actionCounts.values())
      .sort((a, b) => b.count - a.count)
      .slice(0, limit);
    
    return sorted;
  }
  
  /**
   * 获取统计摘要
   */
  getStats(): {
    totalRecords: number;
    totalRules: number;
    enabledRules: number;
    avgConfidence: number;
  } {
    const enabledRules = this.getAllRules().filter(r => r.enabled);
    const avgConf = enabledRules.length > 0
      ? enabledRules.reduce((sum, r) => sum + r.confidence, 0) / enabledRules.length
      : 0;
    
    return {
      totalRecords: this.records.length,
      totalRules: this.rules.size,
      enabledRules: enabledRules.length,
      avgConfidence: avgConf,
    };
  }
  
  // ==================== 持久化 ====================
  
  private async saveRecordsAsync(): Promise<void> {
    if (!this.context) return;
    try {
      const store = await preferences.getPreferences(this.context, PREFS_NAME);
      await store.put(KEY_RECORDS, JSON.stringify(this.records));
      await store.flush();
    } catch (err) {
      this.log.warn(TAG, `Failed to save records: ${(err as Error).message}`);
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
  
  private async loadRecords(context: common.UIAbilityContext): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, PREFS_NAME);
      const data = await store.get(KEY_RECORDS, '[]') as string;
      this.records = JSON.parse(data) as BehaviorRecord[];
    } catch (err) {
      this.log.warn(TAG, `Failed to load records: ${(err as Error).message}`);
    }
  }
  
  private async loadRules(context: common.UIAbilityContext): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, PREFS_NAME);
      const data = await store.get(KEY_RULES, '[]') as string;
      const entries = JSON.parse(data) as [string, ContextRule][];
      this.rules = new Map(entries);
    } catch (err) {
      this.log.warn(TAG, `Failed to load rules: ${(err as Error).message}`);
    }
  }
  
  /**
   * 清除所有数据（用于测试）
   */
  async clearAll(context: common.UIAbilityContext): Promise<void> {
    this.records = [];
    this.rules.clear();
    const store = await preferences.getPreferences(context, PREFS_NAME);
    await store.clear();
    await store.flush();
    this.log.info(TAG, 'Cleared all behavior data');
  }
}
