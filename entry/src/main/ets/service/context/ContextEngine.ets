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
function nativeTrainStreamRL(actionId: string, reward: number, contextJson: string): void {
  contextEngine.trainStreamRL(actionId, reward, contextJson);
}
function nativeExportStreamRL(): string {
  return contextEngine.exportStreamRL() as string;
}
function nativeImportStreamRL(json: string): void {
  contextEngine.importStreamRL(json);
}
function nativeGetStreamRLStats(): string {
  return contextEngine.getStreamRLStats() as string;
}
function nativeGetStreamRLArmSamples(actionId: string): number {
  return contextEngine.getStreamRLArmSamples(actionId) as number;
}
function nativeGetTransitionInfo(): string {
  return contextEngine.getTransitionInfo() as string;
}
function nativeExportTransitionState(): string {
  return contextEngine.exportTransitionState() as string;
}
function nativeImportTransitionState(json: string): void {
  contextEngine.importTransitionState(json);
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
  tier?: number;      // 0=zero-config, 1=WiFi-aware, 2=BT+step+screen
  category?: string;  // person, phone, environment
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
  isSleeping?: string;      // "true" if user is likely sleeping
  heartRate?: string;       // heart rate from wearable
  // 状态历史 (用于状态机判断)
  prevMotionState?: string;     // 上一个运动状态
  prevActivityState?: string;   // 上一个活动状态: 'sitting', 'sleeping', 'standing', 'active'
  activityDuration?: string;    // 当前活动持续时间(秒)
  activityState?: string;       // 当前活动状态
  // 设备分类 & 层级
  bt_in_vehicle?: string;       // 'true' if vehicle BT connected
  bt_fixed_devices?: string;    // comma-separated fixed device names
  bt_vehicle_devices?: string;  // comma-separated vehicle device names
  sensorTier?: string;          // current sensor tier '0'-'3'
  heart_rate_status?: string;   // 'resting', 'normal', 'exercise'
  wearing_state?: string;       // 'on_wrist', 'off_wrist'
  // 出行/航班
  flightCountdownMin?: string;  // 距离起飞的分钟数（可为负）
  flightArrivalMin?: string;    // 距离降落的分钟数（可为负）
  flightNumber?: string;        // 航班号 e.g. "CA1234"
  hasUpcomingFlight?: string;   // "true"/"false"
  // 7-Tuple 物理状态 (PhysicalState)
  ps_time?: string;             // TimeSlot: sleeping/dawn/morning/forenoon/lunch/afternoon/evening/night/late_night
  ps_location?: string;         // LocationCategory: home/work/commute/restaurant/gym/transit_hub/shopping/outdoor/cafe/unknown
  ps_motion?: string;           // MotionCategory: stationary/walking/running/cycling/driving/transit/unknown
  ps_phone?: string;            // PhoneCategory: in_use/holding_lying/on_desk/face_up/in_pocket/face_down/charging/unknown
  ps_light?: string;            // LightCategory: dark/dim/normal/bright
  ps_sound?: string;            // SoundCategory: silent/quiet/normal/noisy/unknown
  ps_dayType?: string;          // DayType: workday/weekend/holiday
  // 场景匹配信息
  ps_scenario?: string;         // 当前匹配的场景 ID (e.g. "S07")
  ps_scenarioCategory?: string; // 场景类别 (commute/work/home/...)
  ps_chainPosition?: string;    // 链位置 "step/total" (e.g. "1/3")
  ps_scenarioConfidence?: string; // 场景匹配置信度 "0.85"
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

  // Pending LLM rules: held until user gives positive feedback
  private pendingLlmRules: Map<string, ContextRule> = new Map();
  // ruleId → action function mapping (e.g. "morning_briefing", "calendar_summary")
  private ruleFunctionMap: Map<string, string> = new Map();

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

      // Rules version: bump this when default_rules.json changes significantly
      const RULES_VERSION = 6; // v6: action function tags (morning_briefing, calendar_summary etc.)
      let storedVersion: number = Number(await this.prefsStore.get('rules_version', 0));

      // Load all rules from unified storage
      let allRulesJson: string = String(await this.prefsStore.get('all_rules', ''));

      if (allRulesJson.length === 0 || allRulesJson === '[]' || storedVersion < RULES_VERSION) {
        if (storedVersion < RULES_VERSION && storedVersion > 0) {
          log.info(TAG, `Rules version upgrade: v${storedVersion} → v${RULES_VERSION}, reloading defaults`);
        } else {
          log.info(TAG, 'No persisted rules found, loading from default_rules.json');
        }
        allRulesJson = await this.loadDefaultRulesFromFile();

        // Persist the new ruleset and version
        await this.prefsStore.put('all_rules', allRulesJson);
        await this.prefsStore.put('rules_version', RULES_VERSION);
        await this.prefsStore.flush();
      }

      let ok = nativeLoadRules(allRulesJson);
      log.info(TAG, `Engine init: loaded ${nativeGetRuleCount()} rules from unified storage, success=${ok}`);

      // Parse function field from rules JSON for ArkTS-side routing
      this.parseRuleFunctions(allRulesJson);

      // Load MAB stats
      let statsJson: string = String(await this.prefsStore.get('mab_stats', '{}'));
      nativeLoadStats(statsJson);

      // Load LinUCB state
      let linucbJson: string = String(await this.prefsStore.get('linucb_state', ''));
      if (linucbJson.length > 0) {
        nativeImportLinUCB(linucbJson);
        log.info(TAG, 'LinUCB state restored');
      }

      // Load Stream RL state
      let streamRLJson: string = String(await this.prefsStore.get('stream_rl_state', ''));
      if (streamRLJson.length > 0) {
        nativeImportStreamRL(streamRLJson);
        log.info(TAG, 'Stream RL state restored');
      }

      // Load transition state
      let transitionJson: string = String(await this.prefsStore.get('transition_state', ''));
      if (transitionJson.length > 0) {
        nativeImportTransitionState(transitionJson);
        log.info(TAG, 'Transition state restored');
      }

      // Deduplicate existing rules (clean up duplicates from previous LLM auto-persist)
      let removed = await this.deduplicateRules();
      if (removed > 0) {
        log.info(TAG, `Init dedup: removed ${removed} duplicate rules`);
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

  /** Parse action.function from rules JSON and cache in ruleFunctionMap */
  private parseRuleFunctions(rulesJson: string): void {
    try {
      let rules = JSON.parse(rulesJson) as Record<string, Object>[];
      this.ruleFunctionMap.clear();
      for (let i = 0; i < rules.length; i++) {
        let rule = rules[i];
        let id = String(rule['id'] ?? '');
        let action = rule['action'] as Record<string, string> | undefined;
        if (action && action['function'] && action['function'].length > 0) {
          this.ruleFunctionMap.set(id, action['function']);
        }
      }
      if (this.ruleFunctionMap.size > 0) {
        log.info(TAG, `Parsed ${this.ruleFunctionMap.size} rule functions`);
      }
    } catch (err) {
      log.warn(TAG, `parseRuleFunctions error: ${(err as Error).message}`);
    }
  }

  /** Get action function for a rule (e.g. "morning_briefing", "calendar_summary") */
  getRuleFunction(ruleId: string): string | undefined {
    return this.ruleFunctionMap.get(ruleId);
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

  // ==================== Pending LLM rules ====================

  /** Store an LLM-generated rule as pending (not yet in engine). */
  addPendingRule(rule: ContextRule): void {
    this.pendingLlmRules.set(rule.id, rule);
    log.info(TAG, `Pending LLM rule stored: ${rule.id} "${rule.name}" (${this.pendingLlmRules.size} pending)`);
  }

  /** Promote a pending LLM rule to the engine (user gave positive feedback). Dedup before adding. */
  async promotePendingRule(ruleId: string): Promise<boolean> {
    let rule = this.pendingLlmRules.get(ruleId);
    if (!rule) {
      log.warn(TAG, `promotePendingRule: ${ruleId} not found in pending`);
      return false;
    }
    this.pendingLlmRules.delete(ruleId);

    // Dedup: check if a similar rule already exists
    if (this.isDuplicateRule(rule)) {
      log.info(TAG, `Skipping duplicate rule: ${ruleId} "${rule.name}"`);
      return false;
    }

    let ok = await this.addRule(rule);
    log.info(TAG, `LLM rule promoted: ${ruleId} "${rule.name}" ok=${ok}, totalRules=${this.getRuleCount()}`);
    return ok;
  }

  /** Remove a pending LLM rule (user gave negative feedback or dismissed). */
  removePendingRule(ruleId: string): void {
    if (this.pendingLlmRules.delete(ruleId)) {
      log.info(TAG, `Pending LLM rule removed: ${ruleId}`);
    }
  }

  /**
   * Check if a similar rule already exists in the engine.
   * Similarity: same action payload OR same set of key conditions.
   */
  private isDuplicateRule(newRule: ContextRule): boolean {
    try {
      let allRulesJson = nativeExportRules();
      let allRules: ContextRule[] = JSON.parse(allRulesJson) as ContextRule[];

      for (let existing of allRules) {
        // Same action payload → duplicate
        if (existing.action.payload === newRule.action.payload) {
          log.debug(TAG, `Duplicate by payload: "${existing.id}" vs "${newRule.id}"`);
          return true;
        }

        // Same core conditions (timeOfDay + motionState + geofence + isWeekend) → likely duplicate
        if (this.conditionsOverlap(existing.conditions, newRule.conditions)) {
          log.debug(TAG, `Duplicate by conditions: "${existing.id}" vs "${newRule.id}"`);
          return true;
        }
      }
    } catch (err) {
      log.warn(TAG, `isDuplicateRule error: ${(err as Error).message}`);
    }
    return false;
  }

  /** Check if two condition sets overlap on all core keys */
  private conditionsOverlap(a: ContextCondition[], b: ContextCondition[]): boolean {
    let coreKeys = ['timeOfDay', 'isWeekend', 'motionState', 'geofence'];
    let matchCount = 0;
    let totalKeys = 0;

    for (let key of coreKeys) {
      let aVal = '';
      let bVal = '';
      for (let c of a) {
        if (c.key === key) { aVal = c.value; break; }
      }
      for (let c of b) {
        if (c.key === key) { bVal = c.value; break; }
      }
      // Both have this key
      if (aVal.length > 0 && bVal.length > 0) {
        totalKeys++;
        if (aVal === bVal) matchCount++;
      }
    }

    // Consider duplicate if 3+ core keys match
    return totalKeys >= 3 && matchCount >= 3;
  }

  /** Deduplicate existing rules in the engine. Removes rules with identical action payloads. */
  async deduplicateRules(): Promise<number> {
    try {
      let allRulesJson = nativeExportRules();
      let allRules: ContextRule[] = JSON.parse(allRulesJson) as ContextRule[];
      let seen: Set<string> = new Set();
      let toRemove: string[] = [];

      for (let rule of allRules) {
        let fingerprint = rule.action.payload.trim();
        if (seen.has(fingerprint)) {
          toRemove.push(rule.id);
        } else {
          seen.add(fingerprint);
        }
      }

      for (let id of toRemove) {
        nativeRemoveRule(id);
        log.info(TAG, `Dedup removed: ${id}`);
      }

      if (toRemove.length > 0) {
        await this.persistRules();
      }
      log.info(TAG, `Deduplication: removed ${toRemove.length} duplicates, ${this.getRuleCount()} rules remain`);
      return toRemove.length;
    } catch (err) {
      log.error(TAG, `deduplicateRules error: ${(err as Error).message}`);
      return 0;
    }
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
      if (snapshot.bt_in_vehicle !== undefined) snapshotRecord['bt_in_vehicle'] = snapshot.bt_in_vehicle;
      if (snapshot.bt_fixed_devices !== undefined) snapshotRecord['bt_fixed_devices'] = snapshot.bt_fixed_devices;
      if (snapshot.bt_vehicle_devices !== undefined) snapshotRecord['bt_vehicle_devices'] = snapshot.bt_vehicle_devices;
      if (snapshot.sensorTier !== undefined) snapshotRecord['sensorTier'] = snapshot.sensorTier;
      // 7-Tuple PhysicalState fields
      if (snapshot.ps_time !== undefined) snapshotRecord['ps_time'] = snapshot.ps_time;
      if (snapshot.ps_location !== undefined) snapshotRecord['ps_location'] = snapshot.ps_location;
      if (snapshot.ps_motion !== undefined) snapshotRecord['ps_motion'] = snapshot.ps_motion;
      if (snapshot.ps_phone !== undefined) snapshotRecord['ps_phone'] = snapshot.ps_phone;
      if (snapshot.ps_light !== undefined) snapshotRecord['ps_light'] = snapshot.ps_light;
      if (snapshot.ps_sound !== undefined) snapshotRecord['ps_sound'] = snapshot.ps_sound;
      if (snapshot.ps_dayType !== undefined) snapshotRecord['ps_dayType'] = snapshot.ps_dayType;
      if (snapshot.ps_scenario !== undefined) snapshotRecord['ps_scenario'] = snapshot.ps_scenario;
      if (snapshot.ps_scenarioCategory !== undefined) snapshotRecord['ps_scenarioCategory'] = snapshot.ps_scenarioCategory;
      if (snapshot.heart_rate_status !== undefined) snapshotRecord['heart_rate_status'] = snapshot.heart_rate_status;
      if (snapshot.wearing_state !== undefined) snapshotRecord['wearing_state'] = snapshot.wearing_state;
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
      // 周期性持久化转移状态（fire-and-forget，不阻塞 evaluate）
      this.persistTransitionState();
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

  /** Record user feedback for MAB + LinUCB + Stream RL learning */
  async feedback(actionId: string, reward: number, snapshot?: ContextSnapshot): Promise<void> {
    if (snapshot) {
      let ctxJson = JSON.stringify(snapshot);
      contextEngine.updateReward(actionId, reward, ctxJson);
      // Train Stream RL with the same context
      nativeTrainStreamRL(actionId, reward, ctxJson);
    } else {
      nativeUpdateReward(actionId, reward);
    }
    await this.persistStats();
    await this.persistLinUCB();
    await this.persistStreamRL();
    await this.persistTransitionState();
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

  /** Get Stream RL summary stats as JSON */
  getStreamRLStats(): string {
    return nativeGetStreamRLStats();
  }

  /** Get Stream RL sample count for a specific arm */
  getStreamRLArmSamples(actionId: string): number {
    return nativeGetStreamRLArmSamples(actionId);
  }

  /** Get state transition info as JSON string (for UI path bar) */
  getTransitionInfo(): string {
    return nativeGetTransitionInfo();
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

  private async persistStreamRL(): Promise<void> {
    if (!this.prefsStore) return;
    let json = nativeExportStreamRL();
    await this.prefsStore.put('stream_rl_state', json);
    await this.prefsStore.flush();
  }

  private async persistTransitionState(): Promise<void> {
    if (!this.prefsStore) return;
    let json = nativeExportTransitionState();
    await this.prefsStore.put('transition_state', json);
    await this.prefsStore.flush();
  }
}
