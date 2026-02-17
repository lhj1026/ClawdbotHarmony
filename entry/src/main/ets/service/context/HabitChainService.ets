/**
 * Habit Chain Service
 * 
 * 管理习惯链：按顺序执行的习惯序列
 * 例：早起习惯 = [喝水 → 吃蔬菜 → 吃坚果]
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { LogService } from '../../common/LogService';
import { 
  HabitChain, 
  HabitStep, 
  TimeTrigger,
} from './ContextModels';

const TAG = 'HabitChain';
const PREFS_NAME = 'clawdbot_habits';
const KEY_CHAINS = 'habit_chains';

type HabitEventListener = (chain: HabitChain, step: HabitStep, event: 'remind' | 'complete' | 'skip') => void;

export class HabitChainService {
  private static instance: HabitChainService;
  private log: LogService = LogService.getInstance();
  
  private chains: Map<string, HabitChain> = new Map();
  private timers: Map<string, number> = new Map();  // chainId -> timerId
  private listeners: HabitEventListener[] = [];
  private initialized: boolean = false;
  private context: common.UIAbilityContext | undefined;
  
  private constructor() {}
  
  static getInstance(): HabitChainService {
    if (!HabitChainService.instance) {
      HabitChainService.instance = new HabitChainService();
    }
    return HabitChainService.instance;
  }
  
  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.initialized) return;
    this.context = context;
    
    await this.loadChains(context);
    
    // 添加示例习惯链
    if (this.chains.size === 0) {
      this.addDefaultChains();
    }
    
    // 检查并重置今日状态
    this.resetDailyStatus();
    
    // 启动所有启用的习惯链
    this.startAllChains();
    
    this.initialized = true;
    this.log.info(TAG, `Initialized with ${this.chains.size} habit chains`);
  }
  
  private addDefaultChains(): void {
    // 示例：早起健康习惯
    const morningChain: HabitChain = {
      id: 'morning_health',
      name: '早起健康习惯',
      description: '健康的早晨从这里开始',
      triggerType: 'time',
      timeTrigger: {
        type: 'daily',
        time: '07:00',
        daysOfWeek: [1, 2, 3, 4, 5, 6, 0],  // 每天
      },
      steps: [
        {
          id: 'drink_water',
          name: '喝水',
          description: '起床后喝一杯温水',
          completionType: 'manual',
          reminder: {
            message: '☀️ 早上好！该喝一杯温水了',
            type: 'notification',
            repeatIntervalMinutes: 10,
            maxRepeats: 3,
          },
          completedToday: false,
        },
        {
          id: 'eat_vegetables',
          name: '吃蔬菜',
          description: '吃一些蔬菜或沙拉',
          completionType: 'manual',
          reminder: {
            message: '🥗 喝完水了？来点蔬菜补充纤维',
            type: 'notification',
            repeatIntervalMinutes: 15,
            maxRepeats: 2,
          },
          completedToday: false,
        },
        {
          id: 'eat_nuts',
          name: '吃坚果',
          description: '现在可以吃点坚果了',
          completionType: 'manual',
          reminder: {
            message: '🥜 蔬菜吃完了？现在可以吃点坚果',
            type: 'notification',
            repeatIntervalMinutes: 20,
            maxRepeats: 2,
          },
          completedToday: false,
        },
      ],
      enabled: true,
      currentStepIndex: 0,
      lastResetDate: '',
      completionCount: 0,
      partialCount: 0,
      streakDays: 0,
    };
    
    this.chains.set(morningChain.id, morningChain);
    
    // 示例：睡前习惯
    const nightChain: HabitChain = {
      id: 'night_routine',
      name: '睡前放松',
      description: '准备一个好睡眠',
      triggerType: 'time',
      timeTrigger: {
        type: 'daily',
        time: '22:00',
        daysOfWeek: [1, 2, 3, 4, 5, 6, 0],
      },
      steps: [
        {
          id: 'stop_screens',
          name: '放下手机',
          description: '减少蓝光刺激',
          completionType: 'manual',
          reminder: {
            message: '🌙 是时候放下手机了，准备休息',
            type: 'notification',
          },
          completedToday: false,
        },
        {
          id: 'drink_water_night',
          name: '喝水',
          description: '睡前喝一小杯水',
          completionType: 'manual',
          reminder: {
            message: '💧 睡前喝点水',
            type: 'notification',
          },
          completedToday: false,
        },
      ],
      enabled: true,
      currentStepIndex: 0,
      lastResetDate: '',
      completionCount: 0,
      partialCount: 0,
      streakDays: 0,
    };
    
    this.chains.set(nightChain.id, nightChain);
  }
  
  // ==================== 习惯链管理 ====================
  
  addChain(chain: HabitChain): void {
    this.chains.set(chain.id, chain);
    if (chain.enabled) {
      this.startChain(chain.id);
    }
    this.saveAsync();
    this.log.info(TAG, `Added chain: ${chain.name}`);
  }
  
  removeChain(id: string): boolean {
    this.stopChain(id);
    const removed = this.chains.delete(id);
    if (removed) {
      this.saveAsync();
    }
    return removed;
  }
  
  getChain(id: string): HabitChain | undefined {
    return this.chains.get(id);
  }
  
  getAllChains(): HabitChain[] {
    return Array.from(this.chains.values());
  }
  
  enableChain(id: string, enabled: boolean): void {
    const chain = this.chains.get(id);
    if (!chain) return;
    
    chain.enabled = enabled;
    if (enabled) {
      this.startChain(id);
    } else {
      this.stopChain(id);
    }
    this.saveAsync();
  }
  
  // ==================== 步骤完成 ====================
  
  /**
   * 标记当前步骤完成，进入下一步
   */
  completeCurrentStep(chainId: string): HabitStep | undefined {
    const chain = this.chains.get(chainId);
    if (!chain) return undefined;
    
    const currentStep = chain.steps[chain.currentStepIndex];
    if (!currentStep) return undefined;
    
    // 标记完成
    currentStep.completedToday = true;
    currentStep.completedAt = Date.now();
    
    this.log.info(TAG, `Step completed: ${chain.name} / ${currentStep.name}`);
    this.notifyListeners(chain, currentStep, 'complete');
    
    // 进入下一步
    chain.currentStepIndex++;
    
    // 检查是否全部完成
    if (chain.currentStepIndex >= chain.steps.length) {
      this.onChainCompleted(chain);
    } else {
      // 提醒下一步
      const nextStep = chain.steps[chain.currentStepIndex];
      this.remindStep(chain, nextStep);
    }
    
    this.saveAsync();
    return currentStep;
  }
  
  /**
   * 跳过当前步骤
   */
  skipCurrentStep(chainId: string): HabitStep | undefined {
    const chain = this.chains.get(chainId);
    if (!chain) return undefined;
    
    const currentStep = chain.steps[chain.currentStepIndex];
    if (!currentStep) return undefined;
    
    this.log.info(TAG, `Step skipped: ${chain.name} / ${currentStep.name}`);
    this.notifyListeners(chain, currentStep, 'skip');
    
    // 进入下一步（不标记完成）
    chain.currentStepIndex++;
    
    if (chain.currentStepIndex >= chain.steps.length) {
      // 部分完成
      chain.partialCount++;
    } else {
      const nextStep = chain.steps[chain.currentStepIndex];
      this.remindStep(chain, nextStep);
    }
    
    this.saveAsync();
    return currentStep;
  }
  
  /**
   * 获取当前需要完成的步骤
   */
  getCurrentStep(chainId: string): HabitStep | undefined {
    const chain = this.chains.get(chainId);
    if (!chain || chain.currentStepIndex >= chain.steps.length) {
      return undefined;
    }
    return chain.steps[chain.currentStepIndex];
  }
  
  private onChainCompleted(chain: HabitChain): void {
    const allCompleted = chain.steps.every(s => s.completedToday);
    
    if (allCompleted) {
      chain.completionCount++;
      chain.streakDays++;
      this.log.info(TAG, `Chain fully completed: ${chain.name} (streak: ${chain.streakDays})`);
      
      // 发送完成通知
      this.sendNotification(
        `🎉 ${chain.name} 完成！`,
        `太棒了！连续 ${chain.streakDays} 天完成`
      );
    } else {
      chain.partialCount++;
      chain.streakDays = 0;  // 中断连续
      this.log.info(TAG, `Chain partially completed: ${chain.name}`);
    }
  }
  
  // ==================== 定时触发 ====================
  
  private startAllChains(): void {
    for (const chain of this.chains.values()) {
      if (chain.enabled) {
        this.startChain(chain.id);
      }
    }
  }
  
  private startChain(chainId: string): void {
    const chain = this.chains.get(chainId);
    if (!chain || !chain.timeTrigger) return;
    
    // 清除旧的定时器
    this.stopChain(chainId);
    
    const trigger = chain.timeTrigger;
    
    if (trigger.type === 'daily' && trigger.time) {
      // 计算下次触发时间
      const nextTrigger = this.getNextDailyTrigger(trigger.time, trigger.daysOfWeek);
      const delay = nextTrigger - Date.now();
      
      if (delay > 0) {
        const timerId = setTimeout(() => {
          this.onChainTriggered(chainId);
        }, delay);
        
        this.timers.set(chainId, timerId);
        this.log.info(TAG, `Chain ${chain.name} scheduled for ${new Date(nextTrigger).toLocaleTimeString()}`);
      }
    }
  }
  
  private stopChain(chainId: string): void {
    const timerId = this.timers.get(chainId);
    if (timerId !== undefined) {
      clearTimeout(timerId);
      this.timers.delete(chainId);
    }
  }
  
  private getNextDailyTrigger(time: string, daysOfWeek?: number[]): number {
    const [hours, minutes] = time.split(':').map(Number);
    const now = new Date();
    const target = new Date();
    
    target.setHours(hours, minutes, 0, 0);
    
    // 如果今天的时间已过，设置为明天
    if (target.getTime() <= now.getTime()) {
      target.setDate(target.getDate() + 1);
    }
    
    // 检查星期
    if (daysOfWeek && daysOfWeek.length > 0) {
      while (!daysOfWeek.includes(target.getDay())) {
        target.setDate(target.getDate() + 1);
      }
    }
    
    return target.getTime();
  }
  
  private onChainTriggered(chainId: string): void {
    const chain = this.chains.get(chainId);
    if (!chain || !chain.enabled) return;
    
    this.log.info(TAG, `Chain triggered: ${chain.name}`);
    
    // 重置今日状态
    this.resetChainDaily(chain);
    
    // 提醒第一步
    if (chain.steps.length > 0) {
      this.remindStep(chain, chain.steps[0]);
    }
    
    // 重新调度明天
    this.startChain(chainId);
  }
  
  // ==================== 提醒 ====================
  
  private remindStep(chain: HabitChain, step: HabitStep): void {
    this.log.info(TAG, `Reminding: ${chain.name} / ${step.name}`);
    
    this.sendNotification(
      `${chain.name}`,
      step.reminder.message
    );
    
    this.notifyListeners(chain, step, 'remind');
  }
  
  private async sendNotification(title: string, content: string): Promise<void> {
    try {
      const request: notificationManager.NotificationRequest = {
        id: Date.now() % 100000,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title,
            text: content,
          },
        },
      };
      
      await notificationManager.publish(request);
    } catch (err) {
      this.log.warn(TAG, `Notification failed: ${(err as Error).message}`);
    }
  }
  
  // ==================== 每日重置 ====================
  
  private resetDailyStatus(): void {
    const today = new Date().toISOString().split('T')[0];
    
    for (const chain of this.chains.values()) {
      if (chain.lastResetDate !== today) {
        this.resetChainDaily(chain);
      }
    }
  }
  
  private resetChainDaily(chain: HabitChain): void {
    const today = new Date().toISOString().split('T')[0];
    
    // 检查昨天是否完成（用于连续天数）
    if (chain.lastResetDate && chain.lastResetDate !== today) {
      const allCompleted = chain.steps.every(s => s.completedToday);
      if (!allCompleted) {
        chain.streakDays = 0;
      }
    }
    
    // 重置步骤状态
    chain.currentStepIndex = 0;
    for (const step of chain.steps) {
      step.completedToday = false;
      step.completedAt = undefined;
    }
    chain.lastResetDate = today;
    
    this.log.info(TAG, `Reset daily status: ${chain.name}`);
  }
  
  // ==================== 监听器 ====================
  
  addListener(listener: HabitEventListener): void {
    this.listeners.push(listener);
  }
  
  removeListener(listener: HabitEventListener): void {
    const idx = this.listeners.indexOf(listener);
    if (idx >= 0) this.listeners.splice(idx, 1);
  }
  
  private notifyListeners(chain: HabitChain, step: HabitStep, event: 'remind' | 'complete' | 'skip'): void {
    for (const listener of this.listeners) {
      try {
        listener(chain, step, event);
      } catch {
        // ignore
      }
    }
  }
  
  // ==================== 统计 ====================
  
  getStats(): {
    totalChains: number;
    enabledChains: number;
    todayCompleted: number;
    todayTotal: number;
    longestStreak: number;
  } {
    let todayCompleted = 0;
    let todayTotal = 0;
    let longestStreak = 0;
    let enabledCount = 0;
    
    for (const chain of this.chains.values()) {
      if (!chain.enabled) continue;
      enabledCount++;
      
      for (const step of chain.steps) {
        todayTotal++;
        if (step.completedToday) todayCompleted++;
      }
      
      if (chain.streakDays > longestStreak) {
        longestStreak = chain.streakDays;
      }
    }
    
    return {
      totalChains: this.chains.size,
      enabledChains: enabledCount,
      todayCompleted,
      todayTotal,
      longestStreak,
    };
  }
  
  // ==================== 持久化 ====================
  
  private async saveAsync(): Promise<void> {
    if (!this.context) return;
    try {
      const store = await preferences.getPreferences(this.context, PREFS_NAME);
      const data = JSON.stringify(Array.from(this.chains.entries()));
      await store.put(KEY_CHAINS, data);
      await store.flush();
    } catch (err) {
      this.log.warn(TAG, `Failed to save: ${(err as Error).message}`);
    }
  }
  
  private async loadChains(context: common.UIAbilityContext): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, PREFS_NAME);
      const data = await store.get(KEY_CHAINS, '[]') as string;
      const entries = JSON.parse(data) as [string, HabitChain][];
      this.chains = new Map(entries);
    } catch (err) {
      this.log.warn(TAG, `Failed to load: ${(err as Error).message}`);
    }
  }
}
