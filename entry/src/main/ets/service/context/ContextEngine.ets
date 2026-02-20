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
  return contextEngine.loadRules(json) as boolean;
}
function nativeAddRule(json: string): boolean {
  return contextEngine.addRule(json) as boolean;
}
function nativeRemoveRule(id: string): boolean {
  return contextEngine.removeRule(id) as boolean;
}
function nativeEvaluate(json: string, max: number): string {
  return contextEngine.evaluate(json, max) as string;
}
function nativeUpdateReward(id: string, reward: number): void {
  contextEngine.updateReward(id, reward);
}
function nativeSelectAction(json: string): number {
  return contextEngine.selectAction(json) as number;
}
function nativeGetStats(): string {
  return contextEngine.getStats() as string;
}
function nativeLoadStats(json: string): void {
  contextEngine.loadStats(json);
}
function nativeGetRuleCount(): number {
  return contextEngine.getRuleCount() as number;
}
function nativeExportRules(): string {
  return contextEngine.exportRules() as string;
}
function nativeExportLinUCB(): string {
  return contextEngine.exportLinUCB() as string;
}
function nativeImportLinUCB(json: string): void {
  contextEngine.importLinUCB(json);
}
function nativePushEvent(json: string): void {
  contextEngine.pushEvent(json);
}
function nativeSetLimits(json: string): void {
  contextEngine.setLimits(json);
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

/** Minimal geofence info for rule binding (avoids circular import) */
export interface GeofenceBinding {
  id: string;
  category: string;
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

  /** Initialize engine: load persisted rules (builtin + user) and MAB stats */
  async init(context: Context): Promise<void> {
    if (this.initialized) return;

    try {
      this.prefsStore = await preferences.getPreferences(context, 'context_engine');

      // Load persisted rules (builtin from native 'rules' key)
      let rulesJson: string = String(await this.prefsStore.get('rules', '[]'));
      let ok = nativeLoadRules(rulesJson);
      log.info(TAG, `Engine init: loaded ${nativeGetRuleCount()} builtin rules, success=${ok}`);

      // Load user custom rules and add them to the engine
      let userRulesJson: string = String(await this.prefsStore.get('user_rules', '[]'));
      try {
        let userRules: ContextRule[] = JSON.parse(userRulesJson) as ContextRule[];
        for (let i = 0; i < userRules.length; i++) {
          nativeAddRule(JSON.stringify(userRules[i]));
        }
        if (userRules.length > 0) {
          log.info(TAG, `Loaded ${userRules.length} user rules`);
        }
      } catch (e) {
        log.warn(TAG, `Failed to parse user_rules: ${(e as Error).message}`);
      }

      // Load MAB stats
      let statsJson: string = String(await this.prefsStore.get('mab_stats', '{}'));
      nativeLoadStats(statsJson);

      // Load LinUCB state
      let linucbJson: string = String(await this.prefsStore.get('linucb_state', ''));
      if (linucbJson.length > 0) {
        nativeImportLinUCB(linucbJson);
        log.info(TAG, 'LinUCB state restored');
      }

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

  /** Add or update a single rule. User rules (id starts with 'user_') are persisted separately. */
  async addRule(rule: ContextRule): Promise<boolean> {
    let json = JSON.stringify(rule);
    let ok = nativeAddRule(json);
    if (ok) {
      if (this.isUserRule(rule.id)) {
        await this.persistUserRules();
      }
      await this.persistRules();
    }
    return ok;
  }

  /** Remove a rule by id. Only user rules (id starts with 'user_') can be removed. */
  async removeRule(ruleId: string): Promise<boolean> {
    if (!this.isUserRule(ruleId)) {
      log.warn(TAG, `Cannot remove builtin rule: ${ruleId}`);
      return false;
    }
    let ok = nativeRemoveRule(ruleId);
    if (ok) {
      await this.persistUserRules();
      await this.persistRules();
    }
    return ok;
  }

  /** Check if a rule is user-created (id starts with 'user_') */
  isUserRule(ruleId: string): boolean {
    return ruleId.startsWith('user_');
  }

  /** Toggle a rule's enabled state */
  async toggleRule(ruleId: string, enabled: boolean): Promise<boolean> {
    // Export all rules, find the target, update enabled, re-add
    try {
      let allRulesJson = nativeExportRules();
      let allRules: ContextRule[] = JSON.parse(allRulesJson) as ContextRule[];
      let found = false;
      for (let i = 0; i < allRules.length; i++) {
        if (allRules[i].id === ruleId) {
          allRules[i].enabled = enabled;
          let ok = nativeAddRule(JSON.stringify(allRules[i]));
          if (ok) {
            found = true;
          }
          break;
        }
      }
      if (found) {
        await this.persistRules();
        if (this.isUserRule(ruleId)) {
          await this.persistUserRules();
        }
      }
      return found;
    } catch (e) {
      log.error(TAG, `toggleRule error: ${(e as Error).message}`);
      return false;
    }
  }

  /** Get user-created rules only */
  getUserRules(): ContextRule[] {
    try {
      let allRulesJson = nativeExportRules();
      let allRules: ContextRule[] = JSON.parse(allRulesJson) as ContextRule[];
      let userRules: ContextRule[] = [];
      for (let i = 0; i < allRules.length; i++) {
        if (this.isUserRule(allRules[i].id)) {
          userRules.push(allRules[i]);
        }
      }
      return userRules;
    } catch (e) {
      log.error(TAG, `getUserRules error: ${(e as Error).message}`);
      return [];
    }
  }

  /** Get all rules for display (builtin + user) */
  getAllRulesForDisplay(): ContextRule[] {
    try {
      let allRulesJson = nativeExportRules();
      let allRules: ContextRule[] = JSON.parse(allRulesJson) as ContextRule[];
      return allRules;
    } catch (e) {
      log.error(TAG, `getAllRulesForDisplay error: ${(e as Error).message}`);
      return [];
    }
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

  /** Record user feedback for MAB + LinUCB learning */
  async feedback(actionId: string, reward: number, snapshot?: ContextSnapshot): Promise<void> {
    if (snapshot) {
      contextEngine.updateReward(actionId, reward, JSON.stringify(snapshot));
    } else {
      nativeUpdateReward(actionId, reward);
    }
    await this.persistStats();
    await this.persistLinUCB();
  }

  /** Action selection from candidates. Uses LinUCB if context provided, MAB fallback otherwise. */
  selectAction(actionIds: string[], snapshot?: ContextSnapshot): number {
    let json = JSON.stringify(actionIds);
    if (snapshot) {
      return contextEngine.selectAction(json, JSON.stringify(snapshot)) as number;
    }
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

  /**
   * Push a context event into the event buffer (for recent/sequence conditions).
   * Call this when notable events happen: geofence enter/exit, motion change, etc.
   */
  pushEvent(eventType: string, context?: ContextSnapshot): void {
    let eventObj: Record<string, Object> = { 'eventType': eventType as Object };
    if (context) {
      eventObj['context'] = context as Object;
    }
    try {
      nativePushEvent(JSON.stringify(eventObj));
    } catch (e) {
      log.error(TAG, `pushEvent failed: ${JSON.stringify(e)}`);
    }
  }

  /**
   * Configure rate limits (category cooldown, global rate limit).
   */
  setLimits(categoryCooldownCount: number, categoryCooldownWindowMs: number, globalMaxPerHour: number): void {
    let limits: Record<string, number> = {
      'categoryCooldownCount': categoryCooldownCount,
      'categoryCooldownWindowMs': categoryCooldownWindowMs,
      'globalMaxPerHour': globalMaxPerHour
    };
    try {
      nativeSetLimits(JSON.stringify(limits));
      log.info(TAG, `Rate limits set: cat=${categoryCooldownCount}/${categoryCooldownWindowMs}ms, global=${globalMaxPerHour}/h`);
    } catch (e) {
      log.error(TAG, `setLimits failed: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 内置规则模板 — 结构固定，geofence 类的 value 通过用户围栏自动绑定
   *
   * 占位符约定:
   *   {{home}}    → 用户标记为 home 类别的第一个围栏 ID
   *   {{work}}    → 用户标记为 work 类别的第一个围栏 ID
   *   {{gym}}     → 用户标记为 gym 类别的第一个围栏 ID
   *
   * 含占位符的规则：如果用户没有对应围栏，该规则自动 disabled
   */
  async loadDefaultRules(): Promise<void> {
    // Save user rules before reloading
    let savedUserRules = this.getUserRules();
    let rules = this.getBuiltinRuleTemplates();
    await this.loadRules(rules);
    // Re-add user rules
    for (let i = 0; i < savedUserRules.length; i++) {
      nativeAddRule(JSON.stringify(savedUserRules[i]));
    }
    if (savedUserRules.length > 0) {
      await this.persistRules();
    }
    log.info(TAG, `Loaded ${rules.length} built-in rules + ${savedUserRules.length} user rules`);
  }

  /** 当用户添加/删除围栏后调用，重新绑定规则中的占位符（保留用户规则） */
  async rebindGeofences(geofences: GeofenceBinding[]): Promise<void> {
    // Save user rules before reloading builtin templates
    let savedUserRules = this.getUserRules();
    let rules = this.getBuiltinRuleTemplates();

    // 按类别找到第一个围栏 ID
    let homeId = '';
    let workId = '';
    let gymId = '';
    for (let gf of geofences) {
      if (gf.category === 'home' && homeId.length === 0) homeId = gf.id;
      if (gf.category === 'work' && workId.length === 0) workId = gf.id;
      if (gf.category === 'gym' && gymId.length === 0) gymId = gf.id;
    }

    log.info(TAG, `rebindGeofences: home=${homeId} work=${workId} gym=${gymId}`);

    // 绑定占位符并设置 enabled
    for (let rule of rules) {
      let needsBinding = false;
      for (let cond of rule.conditions) {
        if (cond.value === '{{home}}') {
          cond.value = homeId;
          if (homeId.length === 0) needsBinding = true;
        } else if (cond.value === '{{work}}') {
          cond.value = workId;
          if (workId.length === 0) needsBinding = true;
        } else if (cond.value === '{{gym}}') {
          cond.value = gymId;
          if (gymId.length === 0) needsBinding = true;
        }
      }
      // 缺少围栏绑定的规则自动禁用
      if (needsBinding) {
        rule.enabled = false;
      }
    }

    await this.loadRules(rules);

    // Re-add user rules
    for (let i = 0; i < savedUserRules.length; i++) {
      nativeAddRule(JSON.stringify(savedUserRules[i]));
    }
    if (savedUserRules.length > 0) {
      await this.persistRules();
    }

    log.info(TAG, `Rules rebound: ${rules.filter(r => r.enabled).length} builtin enabled, ${savedUserRules.length} user rules preserved`);
  }

  private getBuiltinRuleTemplates(): ContextRule[] {
    return [
      // ===== 不依赖围栏的通用规则（开箱即用）=====
      {
        id: 'rule_morning_workday',
        name: '工作日早出门',
        conditions: [
          { key: 'timeOfDay', op: 'eq', value: 'morning' },
          { key: 'isWeekend', op: 'eq', value: 'false' },
          { key: 'motionState', op: 'in', value: 'walking,driving' }
        ],
        action: { id: 'suggest_morning_commute', type: 'suggestion', payload: '早上好！查看通勤路线和天气？' },
        priority: 2.0, cooldownMs: 14400000, enabled: true
      },
      {
        id: 'rule_low_battery',
        name: '低电量提醒',
        conditions: [
          { key: 'batteryLevel', op: 'lte', value: '15' },
          { key: 'isCharging', op: 'eq', value: 'false' }
        ],
        action: { id: 'warn_low_battery', type: 'notification', payload: '电量不足 15%，建议省电模式或充电' },
        priority: 3.0, cooldownMs: 1800000, enabled: true
      },
      {
        id: 'rule_weekend_morning',
        name: '周末早上',
        conditions: [
          { key: 'timeOfDay', op: 'eq', value: 'morning' },
          { key: 'isWeekend', op: 'eq', value: 'true' }
        ],
        action: { id: 'suggest_weekend', type: 'suggestion', payload: '周末愉快！看看今天有什么好玩的？' },
        priority: 1.0, cooldownMs: 28800000, enabled: true
      },
      {
        id: 'rule_long_stationary',
        name: '久坐提醒',
        conditions: [
          { key: 'motionState', op: 'eq', value: 'stationary' },
          { key: 'timeOfDay', op: 'in', value: 'morning,afternoon' }
        ],
        action: { id: 'suggest_move', type: 'suggestion', payload: '坐了很久了，起来活动一下吧 🏃' },
        priority: 1.0, cooldownMs: 5400000, enabled: true
      },
      {
        id: 'rule_commuting',
        name: '通勤路上',
        conditions: [
          { key: 'motionState', op: 'in', value: 'driving,transit' },
          { key: 'isWeekend', op: 'eq', value: 'false' },
          { key: 'timeOfDay', op: 'in', value: 'morning,evening' }
        ],
        action: { id: 'suggest_commute_info', type: 'suggestion', payload: '通勤中，要听播客或看新闻摘要吗？' },
        priority: 1.5, cooldownMs: 14400000, enabled: true
      },
      {
        id: 'rule_bedtime',
        name: '睡前提醒',
        conditions: [
          { key: 'hour', op: 'gte', value: '22' },
          { key: 'motionState', op: 'eq', value: 'stationary' }
        ],
        action: { id: 'suggest_bedtime', type: 'suggestion', payload: '夜深了，明天的日程已准备好，早点休息 🌙' },
        priority: 1.0, cooldownMs: 28800000, enabled: true
      },

      // ===== 依赖围栏的规则（自动绑定，缺围栏则禁用）=====
      {
        id: 'rule_evening_home',
        name: '到家放松',
        conditions: [
          { key: 'timeOfDay', op: 'eq', value: 'evening' },
          { key: 'geofence', op: 'eq', value: '{{home}}' },
          { key: 'motionState', op: 'eq', value: 'stationary' }
        ],
        action: { id: 'suggest_evening_relax', type: 'suggestion', payload: '到家了！听音乐或看新闻摘要？' },
        priority: 1.5, cooldownMs: 14400000, enabled: true
      },
      {
        id: 'rule_leave_home_morning',
        name: '早上离家',
        conditions: [
          { key: 'timeOfDay', op: 'eq', value: 'morning' },
          { key: 'geofence', op: 'neq', value: '{{home}}' },
          { key: 'motionState', op: 'in', value: 'walking,driving' }
        ],
        action: { id: 'suggest_morning_brief', type: 'suggestion', payload: '出门了！今日天气和日程概览？' },
        priority: 2.0, cooldownMs: 14400000, enabled: true
      },
      {
        id: 'rule_arrive_work',
        name: '到达公司',
        conditions: [
          { key: 'geofence', op: 'eq', value: '{{work}}' },
          { key: 'isWeekend', op: 'eq', value: 'false' },
          { key: 'motionState', op: 'eq', value: 'stationary' }
        ],
        action: { id: 'suggest_work_mode', type: 'suggestion', payload: '到公司了，开启工作模式？查看今日待办' },
        priority: 2.0, cooldownMs: 28800000, enabled: true
      },
      {
        id: 'rule_leave_work',
        name: '下班离开公司',
        conditions: [
          { key: 'geofence', op: 'neq', value: '{{work}}' },
          { key: 'timeOfDay', op: 'in', value: 'evening,night' },
          { key: 'isWeekend', op: 'eq', value: 'false' }
        ],
        action: { id: 'suggest_leave_work', type: 'suggestion', payload: '下班了！查看回家路线？' },
        priority: 1.5, cooldownMs: 28800000, enabled: true
      },
      {
        id: 'rule_leave_work_music',
        name: '离开公司步行听音乐',
        conditions: [
          { key: 'geofence', op: 'neq', value: '{{work}}' },
          { key: 'motionState', op: 'eq', value: 'walking' },
          { key: 'isWeekend', op: 'eq', value: 'false' }
        ],
        action: { id: 'suggest_music', type: 'suggestion', payload: '走路中 🎵 打开音乐放松一下？' },
        priority: 2.0, cooldownMs: 28800000, enabled: true
      },
      {
        id: 'rule_arrive_gym',
        name: '到达健身房',
        conditions: [
          { key: 'geofence', op: 'eq', value: '{{gym}}' }
        ],
        action: { id: 'suggest_workout', type: 'suggestion', payload: '到健身房了💪 开始今天的训练计划？' },
        priority: 1.5, cooldownMs: 14400000, enabled: true
      }
    ];
  }

  private async persistRules(): Promise<void> {
    if (!this.prefsStore) return;
    let json = nativeExportRules();
    await this.prefsStore.put('rules', json);
    await this.prefsStore.flush();
  }

  /** Persist only user rules to a separate preferences key */
  private async persistUserRules(): Promise<void> {
    if (!this.prefsStore) return;
    let userRules = this.getUserRules();
    await this.prefsStore.put('user_rules', JSON.stringify(userRules));
    await this.prefsStore.flush();
    log.info(TAG, `Persisted ${userRules.length} user rules`);
  }

  private async persistStats(): Promise<void> {
    if (!this.prefsStore) return;
    let json = nativeGetStats();
    await this.prefsStore.put('mab_stats', json);
    await this.prefsStore.flush();
  }

  private async persistLinUCB(): Promise<void> {
    if (!this.prefsStore) return;
    let json = nativeExportLinUCB();
    await this.prefsStore.put('linucb_state', json);
    await this.prefsStore.flush();
  }
}
