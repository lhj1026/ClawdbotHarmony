/**
 * RecommenderBridge.ets — MLP + LinUCB 推荐器 ArkTS 桥接层
 *
 * 职责：
 *   1. 封装 C++ NAPI recommender 函数
 *   2. 管理 UCB 参数持久化（debounced save）
 *   3. 提供 reward() 接口供 UI 反馈调用
 *   4. 记录每次推荐的"展示快照"，用于超时负反馈
 *
 * 使用方：
 *   - NodeRuntime：生成 alternatives 时调用 predict()，合并 MLP 建议
 *   - handleA2UIAction：accept/reject 时调用 reward()
 *   - App lifecycle：退后台时调用 flush()
 */
import contextEngine from 'libcontext_engine.so';
import { LogService } from '../../common/LogService';
import { fileIo } from '@kit.CoreFileKit';

const TAG = 'RecommenderBridge';

/** 单次推荐结果 */
export interface RecommendItem {
  code: string;       // "B7"
  name: string;       // "检查行程/车票"
  score: number;      // 0-1 综合分数
  mlpProb: number;    // MLP 先验概率
}

/** 展示快照（用于超时负反馈） */
interface ShownSnapshot {
  stateCode: string;
  items: RecommendItem[];
  shownAt: number;     // Date.now()
}

/** 反馈类型 */
export const enum FeedbackType {
  ACCEPT  = 1.0,  // 用户主动点击执行
  NEUTRAL = 0.5,  // 点击但结果一般（执行失败等）
  TIMEOUT = 0.15, // 展示超时无操作（隐式负反馈）
  DISMISS = 0.0,  // 用户主动关闭卡片
  NEVER   = 0.0,  // "不再推荐"（强负向）
}

export class RecommenderBridge {
  private static _instance: RecommenderBridge | null = null;
  private log = LogService.getInstance();
  private savePath = '';
  private inited = false;
  private saveTimer: number = -1;
  private _lastSnapshot: ShownSnapshot | null = null;
  /** 超时时间：展示超过此时间无操作 → TIMEOUT 反馈 */
  private readonly TIMEOUT_MS = 30_000;

  private constructor() {}

  static getInstance(): RecommenderBridge {
    if (!RecommenderBridge._instance) {
      RecommenderBridge._instance = new RecommenderBridge();
    }
    return RecommenderBridge._instance;
  }

  /** App 启动时调用，传入沙箱存储路径 */
  init(filesDir: string): void {
    if (this.inited) return;
    this.savePath = filesDir + '/recommender_ucb.bin';
    try {
      contextEngine.recommenderInit(this.savePath);
      this.inited = true;
      this.log.info(TAG, `初始化完成，UCB路径: ${this.savePath}`);
    } catch (e) {
      this.log.warn(TAG, `初始化失败: ${(e as Error).message}`);
    }
  }

  /**
   * MLP 预测 top-K 推荐
   * @param stateCode 7位状态码，如 "4711001"
   * @param topK 返回条数（默认3）
   */
  predict(stateCode: string, topK: number = 3): RecommendItem[] {
    if (!this.inited || stateCode.length < 7) return [];
    try {
      const json = contextEngine.recommenderPredict(stateCode, topK) as string;
      return JSON.parse(json) as RecommendItem[];
    } catch (e) {
      this.log.warn(TAG, `predict失败: ${(e as Error).message}`);
      return [];
    }
  }

  /**
   * 记录本次展示（供超时负反馈使用）
   * 应在 A2UI 卡片推送之后立即调用
   */
  recordShown(stateCode: string, items: RecommendItem[]): void {
    // 检查上次是否超时未响应
    this.checkPreviousTimeout();
    this._lastSnapshot = { stateCode, items, shownAt: Date.now() };
  }

  /**
   * 用户反馈
   * @param stateCode  触发时的状态码
   * @param actionCode 被反馈的动作代号，如 "B7"
   * @param r          reward 值（使用 FeedbackType 枚举）
   */
  reward(stateCode: string, actionCode: string, r: number): void {
    if (!this.inited || stateCode.length < 7 || actionCode.length < 2) return;
    try {
      contextEngine.recommenderReward(stateCode, actionCode, r);
      this.log.info(TAG, `reward: state=${stateCode} action=${actionCode} r=${r.toFixed(2)}`);
      this.scheduleAutoSave();
      // 清除快照（已处理）
      if (this._lastSnapshot?.stateCode === stateCode) {
        this._lastSnapshot = null;
      }
    } catch (e) {
      this.log.warn(TAG, `reward失败: ${(e as Error).message}`);
    }
  }

  /**
   * 卡片关闭（用户主动 × 或场景切换）
   * 对所有已展示动作发送 DISMISS 反馈
   */
  onCardDismissed(stateCode: string, shownCodes: string[]): void {
    for (const code of shownCodes) {
      this.reward(stateCode, code, FeedbackType.DISMISS);
    }
    this._lastSnapshot = null;
  }

  /**
   * 用户执行动作后报告结果
   * success=true → ACCEPT，success=false → NEUTRAL
   */
  onActionExecuted(stateCode: string, actionCode: string, success: boolean): void {
    this.reward(stateCode, actionCode, success ? FeedbackType.ACCEPT : FeedbackType.NEUTRAL);
  }

  /** 立即持久化 UCB 参数（App 退后台时调用）*/
  flush(): void {
    if (!this.inited) return;
    try {
      contextEngine.recommenderSave(this.savePath);
      this.log.info(TAG, 'UCB 参数已保存');
    } catch (e) {
      this.log.warn(TAG, `save失败: ${(e as Error).message}`);
    }
  }

  /** LinUCB 学习统计 */
  getStats(): string {
    if (!this.inited) return '[]';
    try { return contextEngine.recommenderStats() as string; }
    catch (e) { return '[]'; }
  }

  // ── 内部辅助 ────────────────────────────────────────────────────
  private scheduleAutoSave(): void {
    if (this.saveTimer >= 0) return;
    this.saveTimer = setTimeout(() => {
      this.flush();
      this.saveTimer = -1;
    }, 3000) as unknown as number;  // 3秒后 debounced 保存
  }

  private checkPreviousTimeout(): void {
    if (!this._lastSnapshot) return;
    const elapsed = Date.now() - this._lastSnapshot.shownAt;
    if (elapsed > this.TIMEOUT_MS) {
      // 超时未操作 → 弱负反馈
      this.log.info(TAG, `超时负反馈: state=${this._lastSnapshot.stateCode} elapsed=${elapsed}ms`);
      for (const item of this._lastSnapshot.items) {
        this.reward(this._lastSnapshot.stateCode, item.code, FeedbackType.TIMEOUT);
      }
      this._lastSnapshot = null;
    }
  }
}
