/**
 * ScenarioMatcher.ets — 确定性场景链匹配器
 *
 * 将当前 PhysicalState 7-tuple 与场景定义匹配:
 *   1. 检查场景步骤条件是否匹配当前物理状态
 *   2. 跟踪活跃场景链的进展
 *   3. 返回所有匹配的场景及其推荐动作
 *
 * 这不是 RL 问题 — 场景匹配是确定性模式匹配。
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import {
  PhysicalState,
  Scenario,
  ScenarioStep,
  ScenarioStepCondition,
  ScenarioState,
  ScenarioMatchResult,
  ScenarioAction,
  ScenarioCategory,
} from './ContextModels';
import DataTray, { DataTray as SensorDataTray } from './DataTray';
import { LogService } from '../../common/LogService';

const TAG = 'ScenarioMatcher';
const log = LogService.getInstance();

/** 默认链超时: 2 小时 */
const DEFAULT_TIMEOUT_MS = 2 * 60 * 60 * 1000;

export class ScenarioMatcher {
  private static instance: ScenarioMatcher | null = null;
  private scenarios: Scenario[] = [];
  private activeStates: Map<string, ScenarioState> = new Map(); // scenarioId → state
  private tray: SensorDataTray = DataTray;
  private initialized: boolean = false;

  static getInstance(): ScenarioMatcher {
    if (!ScenarioMatcher.instance) {
      ScenarioMatcher.instance = new ScenarioMatcher();
    }
    return ScenarioMatcher.instance;
  }

  /**
   * 初始化: 从 rawfile 加载场景定义
   */
  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.initialized) return;
    try {
      let resourceMgr = context.resourceManager;
      let rawData = await resourceMgr.getRawFileContent('config/scenarios.json');
      let decoder = new util.TextDecoder('utf-8');
      let json = decoder.decodeToString(rawData);
      this.scenarios = JSON.parse(json) as Scenario[];
      log.info(TAG, `Loaded ${this.scenarios.length} scenario definitions`);
      this.initialized = true;
    } catch (err) {
      log.error(TAG, `Failed to load scenarios: ${(err as Error).message}`);
      this.scenarios = [];
    }
  }

  /**
   * 核心匹配方法: 给定当前 PhysicalState，返回所有匹配的场景
   */
  match(ps: PhysicalState): ScenarioMatchResult[] {
    let now = Date.now();
    let results: ScenarioMatchResult[] = [];

    // 1. 推进已有活跃场景链
    try {
      this.advanceActiveChains(ps, now, results);
    } catch (e) {
      log.warn(TAG, `advanceActiveChains error: ${(e as Error).message}`);
    }

    // 2. 检测新场景 (从 Step 0 开始匹配)
    try {
      this.detectNewScenarios(ps, now, results);
    } catch (e) {
      log.warn(TAG, `detectNewScenarios error: ${(e as Error).message}`);
    }

    // 3. 清理超时的活跃场景
    try {
      this.cleanupTimeouts(now);
    } catch (e) {
      log.warn(TAG, `cleanupTimeouts error: ${(e as Error).message}`);
    }

    return results;
  }

  /**
   * 推进活跃场景链
   */
  private advanceActiveChains(ps: PhysicalState, now: number, results: ScenarioMatchResult[]): void {
    let toRemove: string[] = [];

    this.activeStates.forEach((state: ScenarioState, scenarioId: string) => {
      let scenario = state.scenario;
      let nextStep = state.currentStep + 1;

      // 链已完成（在上一轮完成了最后一步）
      if (nextStep >= scenario.steps.length) {
        toRemove.push(scenarioId);
        return;
      }

      // 检查下一步是否匹配
      let step = scenario.steps[nextStep];
      let stepMatch = this.matchStep(step, ps);

      if (stepMatch > 0) {
        // 检查数字条件
        if (!this.checkDigitalConditions(step)) {
          return; // 物理状态匹配但数字条件不满足，保持当前状态等待
        }
        // 推进到下一步
        state.currentStep = nextStep;
        state.stepEntryTime = now;
        state.confidence = Math.min(state.confidence, stepMatch);

        // 收集该步骤的动作
        let actions = step.actions ?? [];
        results.push({
          scenarioId: scenario.id,
          scenarioName: scenario.name,
          category: scenario.category,
          currentStep: nextStep,
          totalSteps: scenario.steps.length,
          confidence: state.confidence,
          actions: actions,
        });

        log.info(TAG, `Chain advanced: ${scenario.id} step ${nextStep}/${scenario.steps.length} conf=${stepMatch.toFixed(2)}`);
      }
      // 如果不匹配，保持当前步骤等待（不立即移除）
    });

    // 移除已完成的链
    for (let ri = 0; ri < toRemove.length; ri++) {
      this.activeStates.delete(toRemove[ri]);
    }
  }

  /**
   * 检测新场景 (从 Step 0 开始)
   */
  private detectNewScenarios(ps: PhysicalState, now: number, results: ScenarioMatchResult[]): void {
    for (let si = 0; si < this.scenarios.length; si++) {
      let scenario = this.scenarios[si];
      if (!scenario.enabled) continue;
      if (this.activeStates.has(scenario.id)) continue; // 已在跟踪

      if (scenario.steps.length === 0) continue;

      let step0 = scenario.steps[0];
      let stepMatch = this.matchStep(step0, ps);

      if (stepMatch > 0) {
        // 检查数字条件
        if (!this.checkDigitalConditions(step0)) continue;

        // 开始新的场景链
        let state: ScenarioState = {
          scenario: scenario,
          currentStep: 0,
          startTime: now,
          stepEntryTime: now,
          confidence: stepMatch,
        };
        this.activeStates.set(scenario.id, state);

        // 收集 Step 0 的动作
        let actions = step0.actions ?? [];
        results.push({
          scenarioId: scenario.id,
          scenarioName: scenario.name,
          category: scenario.category,
          currentStep: 0,
          totalSteps: scenario.steps.length,
          confidence: stepMatch,
          actions: actions,
        });

        log.info(TAG, `New scenario detected: ${scenario.id} "${scenario.name}" conf=${stepMatch.toFixed(2)}`);
      }
    }
  }

  /**
   * 清理超时的活跃场景
   */
  private cleanupTimeouts(now: number): void {
    let toRemove: string[] = [];
    this.activeStates.forEach((state: ScenarioState, scenarioId: string) => {
      let timeout = state.scenario.timeoutMs > 0 ? state.scenario.timeoutMs : DEFAULT_TIMEOUT_MS;
      if (now - state.startTime > timeout) {
        log.info(TAG, `Scenario timeout: ${scenarioId} (${((now - state.startTime) / 60000).toFixed(0)}min)`);
        toRemove.push(scenarioId);
      }
    });
    for (let ri = 0; ri < toRemove.length; ri++) {
      this.activeStates.delete(toRemove[ri]);
    }
  }

  /**
   * 匹配一个步骤条件与当前物理状态
   * 返回匹配置信度 0-1 (0=不匹配, 1=完全匹配)
   */
  private matchStep(step: ScenarioStep, ps: PhysicalState): number {
    let cond = step.condition;
    let confidence = 1.0;

    // 逐维匹配，所有维度必须满足
    if (!this.matchDim(cond.time, ps.time)) return 0;
    if (!this.matchDim(cond.location, ps.location)) return 0;
    if (!this.matchDim(cond.motion, ps.motion)) return 0;
    if (!this.matchDim(cond.phone, ps.phone)) return 0;
    if (!this.matchDim(cond.light, ps.light)) return 0;
    if (!this.matchDim(cond.sound, ps.sound)) return 0;
    if (!this.matchDim(cond.dayType, ps.dayType)) return 0;

    // 具体维度越多，置信度越高
    let specifiedDims = 0;
    if (cond.time !== undefined && cond.time !== '*') specifiedDims++;
    if (cond.location !== undefined && cond.location !== '*') specifiedDims++;
    if (cond.motion !== undefined && cond.motion !== '*') specifiedDims++;
    if (cond.phone !== undefined && cond.phone !== '*') specifiedDims++;
    if (cond.light !== undefined && cond.light !== '*') specifiedDims++;
    if (cond.sound !== undefined && cond.sound !== '*') specifiedDims++;
    if (cond.dayType !== undefined && cond.dayType !== '*') specifiedDims++;

    // 置信度 = 指定维度数 / 7
    confidence = specifiedDims / 7.0;
    // 最低 0.3 (即使只有 2 个维度匹配也算)
    if (confidence < 0.3) confidence = 0.3;

    return confidence;
  }

  /**
   * 匹配单个维度:
   *   - undefined 或 '*' → 匹配任何值
   *   - 'A|B' → 匹配 A 或 B
   *   - 'exact' → 精确匹配
   */
  private matchDim(pattern: string | undefined, actual: string): boolean {
    if (pattern === undefined || pattern === '*') return true;

    // A|B 多值匹配
    if (pattern.indexOf('|') >= 0) {
      let values = pattern.split('|');
      for (let vi = 0; vi < values.length; vi++) {
        if (values[vi] === actual) return true;
      }
      return false;
    }

    return pattern === actual;
  }

  /**
   * 检查步骤的数字条件 (从 DataTray 读取)
   */
  private checkDigitalConditions(step: ScenarioStep): boolean {
    if (!step.digitalConditions) return true;

    let keys = Object.keys(step.digitalConditions);
    for (let ki = 0; ki < keys.length; ki++) {
      let key = keys[ki];
      let condStr = step.digitalConditions[key];
      let parts = condStr.split(' ');
      if (parts.length < 2) continue;

      let op = parts[0];
      let expected = parts[1];

      // 从 DataTray 读取实际值
      let result = this.tray.get(key);
      let actual = result?.value ?? '';
      if (actual.length === 0) return false; // 无数据则条件不满足

      if (!this.evalDigitalCondition(actual, op, expected)) {
        return false;
      }
    }
    return true;
  }

  /**
   * 评估数字条件: actual op expected
   */
  private evalDigitalCondition(actual: string, op: string, expected: string): boolean {
    switch (op) {
      case 'eq': return actual === expected;
      case 'neq': return actual !== expected;
      case 'gt': return parseFloat(actual) > parseFloat(expected);
      case 'lt': return parseFloat(actual) < parseFloat(expected);
      case 'gte': return parseFloat(actual) >= parseFloat(expected);
      case 'lte': return parseFloat(actual) <= parseFloat(expected);
      default: return actual === expected;
    }
  }

  // ==================== 状态查询 ====================

  /** 获取当前活跃场景数 */
  getActiveCount(): number {
    return this.activeStates.size;
  }

  /** 获取所有活跃场景状态 (用于 UI 显示) */
  getActiveStates(): ScenarioState[] {
    let states: ScenarioState[] = [];
    this.activeStates.forEach((state: ScenarioState) => {
      states.push(state);
    });
    return states;
  }

  /** 获取指定场景的活跃状态 */
  getScenarioState(scenarioId: string): ScenarioState | undefined {
    return this.activeStates.get(scenarioId);
  }

  /** 重置所有活跃场景 */
  resetAll(): void {
    this.activeStates.clear();
    log.info(TAG, 'All active scenarios reset');
  }

  /** 获取加载的场景总数 */
  getScenarioCount(): number {
    return this.scenarios.length;
  }

  /** 获取各类别场景统计 */
  getCategoryStats(): Record<string, number> {
    let stats: Record<string, number> = {};
    for (let si = 0; si < this.scenarios.length; si++) {
      let s = this.scenarios[si];
      let count = stats[s.category] ?? 0;
      stats[s.category] = count + 1;
    }
    return stats;
  }
}
