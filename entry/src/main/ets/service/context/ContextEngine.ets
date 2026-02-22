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
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
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
  excludeConditions?: ContextCondition[][];  // Array of condition groups; if ANY group fully matches, rule is excluded
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
  wifiSsid?: string;       // current WiFi SSID
  cellId?: string;         // current CellID (mcc_mnc_lac_cellid)
  wifiLostWork?: string;   // "true" if recently lost work WiFi (backward compat)
  wifiGeofence?: string;   // WiFi signal matched geofence category (home/work/gym/etc)
  wifiLost?: string;       // "true" if recently lost a known WiFi
  wifiLostCategory?: string; // category of the lost WiFi geofence (home/work/gym/etc)
  latitude?: string;
  longitude?: string;
  stepCount?: string;
  speed?: string;           // estimated speed in km/h
  transportMode?: string;   // walking/running/cycling/driving/transit/stationary
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
  private appContext: common.UIAbilityContext | null = null;

  static getInstance(): ContextEngineService {
    if (!ContextEngineService.instance) {
      ContextEngineService.instance = new ContextEngineService();
    }
    return ContextEngineService.instance;
  }

  /**
   * Initialize engine: load rules from unified storage and MAB stats.
   *
   * Rule loading strategy:
   * 1. Try loading from preferences ('all_rules') — this is the single source of truth
   * 2. If empty (first run), load from rawfile default_rules.json template
   * 3. All rules (default + user-added + LLM-learned) are stored together in 'all_rules'
   */
  async init(context: Context): Promise<void> {
    if (this.initialized) return;

    try {
      this.appContext = context as common.UIAbilityContext;
      this.prefsStore = await preferences.getPreferences(context, 'context_engine');

      // Load all rules from unified storage
      let allRulesJson: string = String(await this.prefsStore.get('all_rules', ''));

      if (allRulesJson.length === 0 || allRulesJson === '[]') {
        // First run or migration: load from default_rules.json rawfile
        log.info(TAG, 'No persisted rules found, loading from default_rules.json');
        allRulesJson = await this.loadDefaultRulesFromFile();

        // Also migrate any legacy user rules
        let legacyUserJson: string = String(await this.prefsStore.get('user_rules', '[]'));
        try {
          let legacyUsers: ContextRule[] = JSON.parse(legacyUserJson) as ContextRule[];
          if (legacyUsers.length > 0) {
            let allRules: ContextRule[] = JSON.parse(allRulesJson) as ContextRule[];
            for (let i = 0; i < legacyUsers.length; i++) {
              allRules.push(legacyUsers[i]);
            }
            allRulesJson = JSON.stringify(allRules);
            log.info(TAG, `Migrated ${legacyUsers.length} legacy user rules`);
          }
        } catch (e) {
          log.warn(TAG, `Legacy user_rules migration failed: ${(e as Error).message}`);
        }

        // Persist the initial ruleset
        await this.prefsStore.put('all_rules', allRulesJson);
        await this.prefsStore.flush();
      }

      let ok = nativeLoadRules(allRulesJson);
      log.info(TAG, `Engine init: loaded ${nativeGetRuleCount()} rules from unified storage, success=${ok}`);

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

  /** Load default rules from rawfile config/default_rules.json */
  private async loadDefaultRulesFromFile(): Promise<string> {
    try {
      if (!this.appContext) return '[]';
      let resourceMgr = this.appContext.resourceManager;
      let rawData = await resourceMgr.getRawFileContent('config/default_rules.json');
      let decoder = new util.TextDecoder('utf-8');
      let json = decoder.decodeToString(rawData);
      log.info(TAG, `Loaded default rules from rawfile, length=${json.length}`);
      return json;
    } catch (err) {
      log.error(TAG, `Failed to load default_rules.json: ${(err as Error).message}`);
      return '[]';
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

  /** Add or update a single rule. Persisted to unified storage. */
  async addRule(rule: ContextRule): Promise<boolean> {
    let json = JSON.stringify(rule);
    let ok = nativeAddRule(json);
    if (ok) {
      await this.persistRules();
    }
    return ok;
  }

  /** Remove a rule by id. Any rule can be removed (will be re-added on next loadDefaultRules if it's a template rule). */
  async removeRule(ruleId: string): Promise<boolean> {
    let ok = nativeRemoveRule(ruleId);
    if (ok) {
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
  private _cachedRules: ContextRule[] | null = null;

  evaluate(snapshot: ContextSnapshot, maxResults: number = 5): MatchResult[] {
    this._cachedRules = null; // Clear cache for fresh data
    let contextJson = JSON.stringify(snapshot);
    // Request extra results so we still have enough after exclude filtering
    let resultJson = nativeEvaluate(contextJson, maxResults + 5);

    try {
      let parsed: Object = JSON.parse(resultJson);
      let results: MatchResult[] = parsed as MatchResult[];

      // Post-filter: remove results whose excludeConditions match
      // ArkTS 不支持 index signature，手动构建 Record
      let snapshotRecord: Record<string, string | undefined> = {
        'timeOfDay': snapshot.timeOfDay,
        'hour': snapshot.hour,
        'dayOfWeek': snapshot.dayOfWeek,
        'isWeekend': snapshot.isWeekend,
        'motionState': snapshot.motionState,
        'batteryLevel': snapshot.batteryLevel,
        'isCharging': snapshot.isCharging,
        'networkType': snapshot.networkType
      };
      if (snapshot.geofence !== undefined) snapshotRecord['geofence'] = snapshot.geofence;
      if (snapshot.wifiSsid !== undefined) snapshotRecord['wifiSsid'] = snapshot.wifiSsid;
      if (snapshot.wifiLostWork !== undefined) snapshotRecord['wifiLostWork'] = snapshot.wifiLostWork;
      if (snapshot.wifiGeofence !== undefined) snapshotRecord['wifiGeofence'] = snapshot.wifiGeofence;
      if (snapshot.wifiLost !== undefined) snapshotRecord['wifiLost'] = snapshot.wifiLost;
      if (snapshot.wifiLostCategory !== undefined) snapshotRecord['wifiLostCategory'] = snapshot.wifiLostCategory;
      if (snapshot.latitude !== undefined) snapshotRecord['latitude'] = snapshot.latitude;
      if (snapshot.longitude !== undefined) snapshotRecord['longitude'] = snapshot.longitude;
      if (snapshot.stepCount !== undefined) snapshotRecord['stepCount'] = snapshot.stepCount;
      if (snapshot.speed !== undefined) snapshotRecord['speed'] = snapshot.speed;
      if (snapshot.transportMode !== undefined) snapshotRecord['transportMode'] = snapshot.transportMode;
      let filtered: MatchResult[] = [];
      for (let i = 0; i < results.length; i++) {
        let result = results[i];
        if (!this.isExcluded(result.ruleId, snapshotRecord)) {
          filtered.push(result);
          if (filtered.length >= maxResults) break;
        } else {
          log.debug(TAG, `Rule ${result.ruleId} excluded by excludeConditions`);
        }
      }
      return filtered;
    } catch (err) {
      log.debug(TAG, `evaluate parse error: ${resultJson}`);
      return [];
    }
  }

  /**
   * Check if a rule should be excluded based on its excludeConditions.
   * Each element in excludeConditions is a group of conditions (AND);
   * if ANY group fully matches, the rule is excluded (OR between groups).
   */
  private isExcluded(ruleId: string, snapshot: Record<string, string | undefined>): boolean {
    // Cache rules for the duration of one evaluate call
    if (!this._cachedRules) {
      let rulesJson = nativeExportRules();
      this._cachedRules = JSON.parse(rulesJson) as ContextRule[];
    }
    let rule: ContextRule | undefined;
    for (let i = 0; i < this._cachedRules.length; i++) {
      if (this._cachedRules[i].id === ruleId) {
        rule = this._cachedRules[i];
        break;
      }
    }
    if (!rule || !rule.excludeConditions || rule.excludeConditions.length === 0) {
      return false;
    }

    // Check each exclusion group (OR logic between groups)
    for (let g = 0; g < rule.excludeConditions.length; g++) {
      let group = rule.excludeConditions[g];
      let groupMatch = true;
      // All conditions in a group must match (AND logic)
      for (let c = 0; c < group.length; c++) {
        if (!this.matchCondition(group[c], snapshot)) {
          groupMatch = false;
          break;
        }
      }
      if (groupMatch) return true;
    }
    return false;
  }

  /** Match a single condition against snapshot */
  private matchCondition(cond: ContextCondition, snapshot: Record<string, string | undefined>): boolean {
    let actual = snapshot[cond.key] ?? '';
    let expected = cond.value;
    switch (cond.op) {
      case 'eq': return actual === expected;
      case 'neq': return actual !== expected;
      case 'gt': return parseFloat(actual) > parseFloat(expected);
      case 'lt': return parseFloat(actual) < parseFloat(expected);
      case 'gte': return parseFloat(actual) >= parseFloat(expected);
      case 'lte': return parseFloat(actual) <= parseFloat(expected);
      case 'in': return expected.split(',').indexOf(actual) >= 0;
      case 'contains': return actual.indexOf(expected) >= 0;
      default: return actual === expected;
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
  /** Reload all rules from persisted storage (or default file if empty) */
  async loadDefaultRules(): Promise<void> {
    // Save user-added rules (id starts with 'user_')
    let savedUserRules = this.getUserRules();

    // Load template rules from rawfile
    let templateJson = await this.loadDefaultRulesFromFile();
    let templateRules: ContextRule[] = JSON.parse(templateJson) as ContextRule[];
    await this.loadRules(templateRules);

    // Re-add user rules
    for (let i = 0; i < savedUserRules.length; i++) {
      nativeAddRule(JSON.stringify(savedUserRules[i]));
    }
    await this.persistRules();
    log.info(TAG, `Reloaded ${templateRules.length} template rules + ${savedUserRules.length} user rules`);
  }

  /** 当用户添加/删除围栏后调用，重新绑定规则中的占位符（保留用户规则） */
  async rebindGeofences(geofences: GeofenceBinding[]): Promise<void> {
    // Save user rules before reloading templates
    let savedUserRules = this.getUserRules();
    let templateJson = await this.loadDefaultRulesFromFile();
    let rules: ContextRule[] = JSON.parse(templateJson) as ContextRule[];

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

  /** Persist all rules to unified storage */
  private async persistRules(): Promise<void> {
    if (!this.prefsStore) return;
    let json = nativeExportRules();
    await this.prefsStore.put('all_rules', json);
    await this.prefsStore.flush();
  }

  /** @deprecated — kept for backward compatibility, now just calls persistRules */
  private async persistUserRules(): Promise<void> {
    await this.persistRules();
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
