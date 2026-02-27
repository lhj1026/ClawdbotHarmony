/**
 * FeedbackService.ets — 推荐反馈管理服务
 *
 * 职责：
 *   - 收集显式反馈（👍/👎）和隐式反馈（执行动作/忽略/超时）
 *   - 调用 ContextEngine.feedback() 传递 MAB reward
 *   - 记录反馈到 BehaviorLogger
 *   - 管理卡片的超时定时器（dismiss 5min / ignore 10min）
 *   - 提供反馈统计数据供 ContextSettingsPage 使用
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { LogService } from '../../common/LogService';
import { ContextEngineService } from './ContextEngine';
import { BehaviorLogger } from './BehaviorLogger';
import {
  FeedbackRecord,
  FeedbackStats,
  FeedbackRuleStat,
  FeedbackType,
  EnvironmentContext,
  ActionOutcome,
  UserAction,
} from './ContextModels';
import { ContextRecommendation } from './ContextAwarenessService';

interface RuleAggData {
  total: number;
  count: number;
}

const TAG = 'FeedbackService';
const PREFS_NAME = 'clawdbot_feedback';
const KEY_RECORDS = 'feedback_records';
const MAX_RECORDS = 500;

// 奖励值常量
const REWARD_THUMBS_UP = 1.0;
const REWARD_THUMBS_DOWN = -0.5;
const REWARD_ACTION_TAKEN = 0.8;
const REWARD_DISMISSED = -0.1;
const REWARD_IGNORED = -0.2;

// 超时常量
const DISMISS_TIMEOUT_MS = 5 * 60 * 1000;   // 5 分钟
const IGNORE_TIMEOUT_MS = 10 * 60 * 1000;   // 10 分钟

/** 活跃卡片的追踪信息 */
interface ActiveCard {
  rec: ContextRecommendation;
  shownAt: number;
  dismissTimerId: number;
  ignoreTimerId: number;
  resolved: boolean;
}

export class FeedbackService {
  private static instance: FeedbackService | null = null;
  private log: LogService = LogService.getInstance();
  private engine: ContextEngineService = ContextEngineService.getInstance();
  private behaviorLog: BehaviorLogger = BehaviorLogger.getInstance();

  private records: FeedbackRecord[] = [];
  private initialized: boolean = false;
  private context: common.UIAbilityContext | undefined;

  // 活跃卡片追踪：ruleId -> ActiveCard
  private activeCards: Map<string, ActiveCard> = new Map();

  // 规则名称缓存（用于统计显示）
  private ruleNames: Map<string, string> = new Map();

  /** Register a rule name for display in stats */
  setRuleName(ruleId: string, name: string): void {
    if (ruleId.length > 0 && name.length > 0) {
      this.ruleNames.set(ruleId, name);
    }
  }

  private constructor() {}

  static getInstance(): FeedbackService {
    if (!FeedbackService.instance) {
      FeedbackService.instance = new FeedbackService();
    }
    return FeedbackService.instance;
  }

  async init(appContext: common.UIAbilityContext): Promise<void> {
    if (this.initialized) return;
    this.context = appContext;
    await this.loadRecords();
    this.initialized = true;
    this.log.info(TAG, 'Initialized with ' + this.records.length.toString() + ' feedback records');
  }

  // ==================== 卡片生命周期 ====================

  /**
   * 当推荐卡片展示时调用，启动超时定时器
   */
  onCardShown(rec: ContextRecommendation): void {
    let ruleId = rec.rule.id;

    // 清理已有的同 ruleId 定时器
    this.clearCardTimers(ruleId);

    // 缓存规则名称
    let ruleName = rec.rule.trigger.geofenceIds
      ? 'rule_' + ruleId
      : ruleId;
    // 尝试使用 action target 作为更可读的名字
    if (rec.action.target) {
      ruleName = rec.action.target;
    }
    this.ruleNames.set(ruleId, ruleName);

    let card: ActiveCard = {
      rec: rec,
      shownAt: Date.now(),
      dismissTimerId: -1,
      ignoreTimerId: -1,
      resolved: false,
    };

    // 10 分钟无交互 → 自动记录 ignored, remove pending LLM rule
    card.ignoreTimerId = setTimeout(() => {
      if (!card.resolved) {
        this.recordFeedback(ruleId, 'ignored', REWARD_IGNORED);
        card.resolved = true;
        this.activeCards.delete(ruleId);
        // Don't promote ignored LLM rules
        if (ruleId.startsWith('user_llm_')) {
          this.engine.removePendingRule(ruleId);
        }
      }
    }, IGNORE_TIMEOUT_MS) as number;

    this.activeCards.set(ruleId, card);
    this.log.info(TAG, 'Card shown: ' + ruleId);
  }

  /**
   * 用户滑走/关闭卡片 → 5 分钟后记录 dismiss 惩罚
   */
  onCardDismissed(ruleId: string): void {
    let card = this.activeCards.get(ruleId);
    if (!card || card.resolved) return;

    // 清除 ignore 定时器
    if (card.ignoreTimerId >= 0) {
      clearTimeout(card.ignoreTimerId);
    }

    // 5 分钟后给 dismiss 惩罚, remove pending LLM rule
    let dismissCard = card;
    card.dismissTimerId = setTimeout(() => {
      if (!dismissCard.resolved) {
        this.recordFeedback(ruleId, 'dismissed', REWARD_DISMISSED);
        dismissCard.resolved = true;
        this.activeCards.delete(ruleId);
        // Don't promote dismissed LLM rules
        if (ruleId.startsWith('user_llm_')) {
          this.engine.removePendingRule(ruleId);
        }
      }
    }, DISMISS_TIMEOUT_MS) as number;

    this.log.info(TAG, 'Card dismissed: ' + ruleId + ' (reward in 5min)');
  }

  // ==================== 显式反馈 ====================

  /**
   * 用户点击 👍 — positive feedback promotes LLM rules to engine
   */
  async onThumbsUp(ruleId: string, envContext?: EnvironmentContext): Promise<void> {
    this.resolveCard(ruleId);
    await this.recordFeedback(ruleId, 'thumbs_up', REWARD_THUMBS_UP);
    await this.logToBehavior(ruleId, true, envContext);
    await this.handleLlmRuleFeedback(ruleId, true);
  }

  /**
   * 用户点击 👎 — negative feedback removes pending LLM rules
   */
  async onThumbsDown(ruleId: string, envContext?: EnvironmentContext): Promise<void> {
    this.resolveCard(ruleId);
    await this.recordFeedback(ruleId, 'thumbs_down', REWARD_THUMBS_DOWN);
    await this.logToBehavior(ruleId, false, envContext);
    await this.handleLlmRuleFeedback(ruleId, false);
  }

  /**
   * 用户执行了推荐的动作（如点击卡片打开导航）— promotes LLM rules
   */
  async onActionTaken(ruleId: string, envContext?: EnvironmentContext): Promise<void> {
    this.resolveCard(ruleId);
    await this.recordFeedback(ruleId, 'action_taken', REWARD_ACTION_TAKEN);
    await this.logToBehavior(ruleId, true, envContext);
    await this.handleLlmRuleFeedback(ruleId, true);
  }

  /**
   * Handle LLM rule promotion/removal based on user feedback.
   * Positive: promote pending rule to engine (becomes permanent).
   * Negative: remove pending rule (won't be used again).
   */
  private async handleLlmRuleFeedback(ruleId: string, positive: boolean): Promise<void> {
    if (!ruleId.startsWith('user_llm_')) return;

    // Notify ContextAwarenessService that feedback was received (via callback)
    if (this.llmFeedbackCallback) {
      this.llmFeedbackCallback(ruleId);
    }

    if (positive) {
      let ok = await this.engine.promotePendingRule(ruleId);
      this.log.info(TAG, `LLM rule promoted on positive feedback: ${ruleId} ok=${ok}`);
    } else {
      this.engine.removePendingRule(ruleId);
      this.log.info(TAG, `LLM rule removed on negative feedback: ${ruleId}`);
    }
  }

  // Callback to notify ContextAwarenessService without circular import
  private llmFeedbackCallback: ((ruleId: string) => void) | null = null;

  /** Set callback for LLM feedback notification (called by ContextAwarenessService) */
  setLlmFeedbackCallback(cb: (ruleId: string) => void): void {
    this.llmFeedbackCallback = cb;
  }

  // ==================== 统计 ====================

  getStats(): FeedbackStats {
    let positiveCount = 0;
    let negativeCount = 0;
    let dismissCount = 0;
    let ignoreCount = 0;

    // 按 ruleId 聚合
    let ruleAgg: Map<string, RuleAggData> = new Map();

    for (let i = 0; i < this.records.length; i++) {
      let r = this.records[i];
      if (r.feedbackType === 'thumbs_up' || r.feedbackType === 'action_taken') {
        positiveCount++;
      } else if (r.feedbackType === 'thumbs_down') {
        negativeCount++;
      } else if (r.feedbackType === 'dismissed') {
        dismissCount++;
      } else if (r.feedbackType === 'ignored') {
        ignoreCount++;
      }

      let agg = ruleAgg.get(r.ruleId);
      if (agg) {
        agg.total += r.reward;
        agg.count++;
      } else {
        let newAgg: RuleAggData = { total: r.reward, count: 1 };
        ruleAgg.set(r.ruleId, newAgg);
      }
    }

    // Try to populate missing rule names from ContextEngine
    try {
      let engineRulesJson = this.engine.exportRules();
      if (engineRulesJson.length > 2) {
        let engineRules: Array<Record<string, Object>> = JSON.parse(engineRulesJson) as Array<Record<string, Object>>;
        for (let i = 0; i < engineRules.length; i++) {
          let r = engineRules[i];
          let id = r['id'] as string;
          let name = r['name'] as string;
          if (id && name && !this.ruleNames.has(id)) {
            this.ruleNames.set(id, name);
          }
        }
      }
    } catch { /* ignore */ }

    // 排序 top rules by avg reward
    let ruleEntries: FeedbackRuleStat[] = [];
    ruleAgg.forEach((val: RuleAggData, key: string) => {
      ruleEntries.push({
        ruleId: key,
        ruleName: this.ruleNames.get(key) ?? key,
        totalReward: val.total,
        feedbackCount: val.count,
        avgReward: val.count > 0 ? val.total / val.count : 0,
      });
    });
    ruleEntries.sort((a: FeedbackRuleStat, b: FeedbackRuleStat) => b.avgReward - a.avgReward);

    let topRules = ruleEntries.slice(0, 3);

    let explicitTotal = positiveCount + negativeCount;
    let positiveRatio = explicitTotal > 0 ? positiveCount / explicitTotal : 0;

    return {
      totalCount: this.records.length,
      positiveCount: positiveCount,
      negativeCount: negativeCount,
      dismissCount: dismissCount,
      ignoreCount: ignoreCount,
      positiveRatio: positiveRatio,
      topRules: topRules,
    };
  }

  // ==================== 内部方法 ====================

  private resolveCard(ruleId: string): void {
    let card = this.activeCards.get(ruleId);
    if (card) {
      card.resolved = true;
      this.clearCardTimers(ruleId);
      this.activeCards.delete(ruleId);
    }
  }

  private clearCardTimers(ruleId: string): void {
    let card = this.activeCards.get(ruleId);
    if (!card) return;
    if (card.dismissTimerId >= 0) {
      clearTimeout(card.dismissTimerId);
    }
    if (card.ignoreTimerId >= 0) {
      clearTimeout(card.ignoreTimerId);
    }
  }

  private async recordFeedback(ruleId: string, feedbackType: FeedbackType, reward: number): Promise<void> {
    // 发送到 C++ 引擎（含 Stream RL 训练）
    try {
      let card = this.activeCards.get(ruleId);
      let snapshot = card?.rec?.snapshot;
      await this.engine.feedback(ruleId, reward, snapshot);
    } catch (err) {
      this.log.warn(TAG, 'Engine feedback failed: ' + (err as Error).message);
    }

    // 存本地记录
    let record: FeedbackRecord = {
      id: 'fb_' + Date.now().toString() + '_' + Math.floor(Math.random() * 10000).toString(),
      ruleId: ruleId,
      timestamp: Date.now(),
      feedbackType: feedbackType,
      reward: reward,
    };
    this.records.push(record);

    if (this.records.length > MAX_RECORDS) {
      this.records = this.records.slice(this.records.length - MAX_RECORDS);
    }

    this.log.info(TAG, 'Feedback: ' + ruleId + ' type=' + feedbackType + ' reward=' + reward.toString());
    this.saveRecordsAsync();
  }

  private async logToBehavior(
    ruleId: string,
    accepted: boolean,
    envContext?: EnvironmentContext
  ): Promise<void> {
    if (!envContext) return;
    let card = this.activeCards.get(ruleId);
    let action = card ? card.rec.action : { type: 'dismiss', target: '' } as UserAction;
    let outcome: ActionOutcome = {
      accepted: accepted,
      feedback: accepted ? 1 : -1,
    };
    try {
      await this.behaviorLog.logBehavior(envContext, action, outcome);
    } catch (err) {
      this.log.warn(TAG, 'BehaviorLog failed: ' + (err as Error).message);
    }
  }

  // ==================== 持久化 ====================

  private async loadRecords(): Promise<void> {
    if (!this.context) return;
    try {
      let store = await preferences.getPreferences(this.context, PREFS_NAME);
      let data = String(await store.get(KEY_RECORDS, '[]'));
      this.records = JSON.parse(data) as FeedbackRecord[];
    } catch (err) {
      this.log.warn(TAG, 'Load failed: ' + (err as Error).message);
    }
  }

  private async saveRecordsAsync(): Promise<void> {
    if (!this.context) return;
    try {
      let store = await preferences.getPreferences(this.context, PREFS_NAME);
      await store.put(KEY_RECORDS, JSON.stringify(this.records));
      await store.flush();
    } catch (err) {
      this.log.warn(TAG, 'Save failed: ' + (err as Error).message);
    }
  }
}
