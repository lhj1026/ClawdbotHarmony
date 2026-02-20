/**
 * ContextEngine.ets — ArkTS wrapper for native context_engine C++ NAPI module
 *
 * 情景智能规则引擎的 ArkTS 层:
 *   - 管理规则的加载/持久化
 *   - 从 ContextAwarenessService 获取传感器数据，转为 ContextMap
 *   - 调用 C++ evaluate，返回推荐结果
 *   - 处理用户反馈 (MAB reward)
 */
import contextEngine from 'libcontext_engine.so';
import { preferences } from '@kit.ArkData';
import { LogService } from '../../common/LogService';

const TAG = 'ContextEngine';
const log = LogService.getInstance();

// Typed wrappers for native NAPI calls (ArkTS strict mode disallows implicit any)
function nativeLoadRules(json: string): boolean {
  return nativeLoadRules(json) as boolean;
}
function nativeAddRule(json: string): boolean {
  return nativeAddRule(json) as boolean;
}
function nativeRemoveRule(id: string): boolean {
  return nativeRemoveRule(id) as boolean;
}
function nativeEvaluate(json: string, max: number): string {
  return nativeEvaluate(json, max) as string;
}
function nativeUpdateReward(id: string, reward: number): void {
  nativeUpdateReward(id, reward);
}
function nativeSelectAction(json: string): number {
  return nativeSelectAction(json) as number;
}
function nativeGetStats(): string {
  return nativeGetStats() as string;
}
function nativeLoadStats(json: string): void {
  nativeLoadStats(json);
}
function nativeGetRuleCount(): number {
  return nativeGetRuleCount() as number;
}
function nativeExportRules(): string {
  return nativeExportRules() as string;
}

/** Rule definition for ArkTS side */
export interface ContextRule {
  id: string;
  name: string;
  conditions: ContextCondition[];
  action: ContextAction;
  priority: number;
  cooldownMs: number;
  enabled: boolean;
}

export interface ContextCondition {
  key: string;
  op: string;   // eq, neq, gt, lt, gte, lte, in, range
  value: string;
}

export interface ContextAction {
  id: string;
  type: string;   // suggestion, automation, notification
  payload: string;
}

/** Evaluation result from C++ engine */
export interface MatchResult {
  ruleId: string;
  confidence: number;
  action: ContextAction;
}

/** Context snapshot to pass to engine */
export interface ContextSnapshot {
  timeOfDay: string;       // dawn, morning, afternoon, evening, night
  hour: string;            // "0"-"23"
  dayOfWeek: string;       // "0"-"6" (0=Sunday)
  isWeekend: string;       // "true"/"false"
  motionState: string;     // stationary, walking, running, driving, transit
  batteryLevel: string;    // "0"-"100"
  isCharging: string;      // "true"/"false"
  networkType: string;     // wifi, cellular, none
  geofence?: string;       // current geofence id, if any
  latitude?: string;
  longitude?: string;
  stepCount?: string;
}

export class ContextEngineService {
  private static instance: ContextEngineService | null = null;
  private initialized: boolean = false;
  private prefsStore: preferences.Preferences | null = null;

  static getInstance(): ContextEngineService {
    if (!ContextEngineService.instance) {
      ContextEngineService.instance = new ContextEngineService();
    }
    return ContextEngineService.instance;
  }

  /** Initialize engine: load persisted rules and MAB stats */
  async init(context: Context): Promise<void> {
    if (this.initialized) return;

    try {
      this.prefsStore = await preferences.getPreferences(context, 'context_engine');

      // Load persisted rules
      let rulesJson: string = String(await this.prefsStore.get('rules', '[]'));
      let ok = nativeLoadRules(rulesJson);
      log.info(TAG, `Engine init: loaded ${nativeGetRuleCount()} rules, success=${ok}`);

      // Load MAB stats
      let statsJson: string = String(await this.prefsStore.get('mab_stats', '{}'));
      nativeLoadStats(statsJson);

      this.initialized = true;
    } catch (err) {
      let error = err as Error;
      log.system(TAG, `Init failed: ${error.message}`);
    }
  }

  /** Load rules (replaces all). Persists to preferences. */
  async loadRules(rules: ContextRule[]): Promise<boolean> {
    let json = JSON.stringify(rules);
    let ok = nativeLoadRules(json);
    if (ok && this.prefsStore) {
      await this.prefsStore.put('rules', json);
      await this.prefsStore.flush();
    }
    log.info(TAG, `loadRules: ${rules.length} rules, success=${ok}`);
    return ok;
  }

  /** Add or update a single rule */
  async addRule(rule: ContextRule): Promise<boolean> {
    let json = JSON.stringify(rule);
    let ok = nativeAddRule(json);
    if (ok) {
      await this.persistRules();
    }
    return ok;
  }

  /** Remove a rule by id */
  async removeRule(ruleId: string): Promise<boolean> {
    let ok = nativeRemoveRule(ruleId);
    if (ok) {
      await this.persistRules();
    }
    return ok;
  }

  /** Evaluate current context and return ranked matches */
  evaluate(snapshot: ContextSnapshot, maxResults: number = 5): MatchResult[] {
    let contextJson = JSON.stringify(snapshot);
    let resultJson = nativeEvaluate(contextJson, maxResults);

    try {
      let parsed: Object = JSON.parse(resultJson);
      let results: MatchResult[] = parsed as MatchResult[];
      return results;
    } catch (err) {
      log.debug(TAG, `evaluate parse error: ${resultJson}`);
      return [];
    }
  }

  /** Record user feedback for MAB learning */
  async feedback(actionId: string, reward: number): Promise<void> {
    nativeUpdateReward(actionId, reward);
    await this.persistStats();
  }

  /** MAB action selection from candidates */
  selectAction(actionIds: string[]): number {
    let json = JSON.stringify(actionIds);
    return nativeSelectAction(json);
  }

  /** Get rule count */
  getRuleCount(): number {
    return nativeGetRuleCount();
  }

  /** Get MAB stats */
  getStats(): string {
    return nativeGetStats();
  }

  /** Export rules as JSON */
  exportRules(): string {
    return nativeExportRules();
  }

  /** Load default MVP rules (示例规则) */
  async loadDefaultRules(): Promise<void> {
    let defaultRules: ContextRule[] = [
      {
        id: 'rule_morning_workday',
        name: '工作日早出门提醒',
        conditions: [
          { key: 'timeOfDay', op: 'eq', value: 'morning' },
          { key: 'isWeekend', op: 'eq', value: 'false' },
          { key: 'motionState', op: 'in', value: 'walking,driving' }
        ],
        action: {
          id: 'suggest_morning_commute',
          type: 'suggestion',
          payload: '早上好！今天的通勤路线和天气如何？'
        },
        priority: 2.0,
        cooldownMs: 14400000,  // 4 hours
        enabled: true
      },
      {
        id: 'rule_evening_home',
        name: '晚上到家放松',
        conditions: [
          { key: 'timeOfDay', op: 'eq', value: 'evening' },
          { key: 'geofence', op: 'eq', value: 'home' },
          { key: 'motionState', op: 'eq', value: 'stationary' }
        ],
        action: {
          id: 'suggest_evening_relax',
          type: 'suggestion',
          payload: '到家了！要不要听听音乐或看看今天的新闻摘要？'
        },
        priority: 1.5,
        cooldownMs: 14400000,
        enabled: true
      },
      {
        id: 'rule_low_battery',
        name: '低电量提醒',
        conditions: [
          { key: 'batteryLevel', op: 'lte', value: '15' },
          { key: 'isCharging', op: 'eq', value: 'false' }
        ],
        action: {
          id: 'warn_low_battery',
          type: 'notification',
          payload: '电量不足 15%，建议开启省电模式或找地方充电'
        },
        priority: 3.0,
        cooldownMs: 1800000,  // 30 min
        enabled: true
      },
      {
        id: 'rule_weekend_morning',
        name: '周末早上',
        conditions: [
          { key: 'timeOfDay', op: 'eq', value: 'morning' },
          { key: 'isWeekend', op: 'eq', value: 'true' }
        ],
        action: {
          id: 'suggest_weekend',
          type: 'suggestion',
          payload: '周末愉快！看看今天有什么好玩的活动？'
        },
        priority: 1.0,
        cooldownMs: 28800000,  // 8 hours
        enabled: true
      },
      {
        id: 'rule_long_stationary',
        name: '久坐提醒',
        conditions: [
          { key: 'motionState', op: 'eq', value: 'stationary' },
          { key: 'timeOfDay', op: 'in', value: 'morning,afternoon' }
        ],
        action: {
          id: 'suggest_move',
          type: 'suggestion',
          payload: '已经坐了很久了，起来活动一下吧 🏃'
        },
        priority: 1.0,
        cooldownMs: 5400000,  // 90 min
        enabled: true
      }
    ];

    await this.loadRules(defaultRules);
    log.info(TAG, `Loaded ${defaultRules.length} default MVP rules`);
  }

  private async persistRules(): Promise<void> {
    if (!this.prefsStore) return;
    let json = nativeExportRules();
    await this.prefsStore.put('rules', json);
    await this.prefsStore.flush();
  }

  private async persistStats(): Promise<void> {
    if (!this.prefsStore) return;
    let json = nativeGetStats();
    await this.prefsStore.put('mab_stats', json);
    await this.prefsStore.flush();
  }
}
