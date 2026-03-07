/**
 * HomeScene.ets — 家庭场景插件
 *
 * 检测: wifiGeofence=home
 * 子场景: 到家、早安、晚餐、睡前、充电
 * calendar/weather/calendar_tomorrow 委托给 SmartActionPlugin 执行
 */
import { ContextSnapshot } from '../ContextEngine';
import { ScenePlugin, SceneMatch, SceneAction, SceneActionResult } from './ScenePlugin';
import { SmartActionPlugin } from '../actions/SmartActionPlugin';
import { ContextAwarenessService } from '../ContextAwarenessService';
import { UserAction } from '../ContextModels';
import { LogService } from '../../../common/LogService';

type HomePhase = 'arrive' | 'morning' | 'lunch' | 'dinner' | 'evening' | 'bedtime';

export class HomeScene implements ScenePlugin {
  readonly id = 'home';
  readonly name = '在家';
  readonly emoji = '🏠';

  private smartPlugin: SmartActionPlugin | undefined;
  private calendarWired: boolean = false;

  detectScene(snapshot: ContextSnapshot): SceneMatch | null {
    let wifiGf = snapshot.wifiGeofence ?? '';
    if (wifiGf !== 'home') return null;

    let tod = snapshot.timeOfDay ?? '';
    let hour = parseInt(snapshot.hour ?? '12');
    let isCharging = snapshot.isCharging === 'true';
    let battery = parseInt(snapshot.batteryLevel ?? '50');
    let motion = snapshot.motionState ?? '';
    let isStationary = (motion === 'stationary' || motion === '');

    let phase: HomePhase;
    let priority = 2;
    let stateDesc = '';

    // ── 时间窗口：每个子场景限定明确时间区间 ─────────────────────
    // 睡前/充电：22:00+ 且正在充电（需 stationary）
    if (hour >= 22 && isCharging && isStationary) {
      phase = 'bedtime';
      priority = 3;
      stateDesc = '🌙 夜深了，手机在充电';
    // 早晨：6:00-9:00（需 stationary，避免出门途中误触）
    } else if (hour >= 6 && hour < 9 && isStationary) {
      phase = 'morning';
      priority = 2;
      stateDesc = `☀️ 早上好！电量 ${battery}%`;
    // 午餐：11:30-13:30（需 stationary）
    } else if (hour >= 11 && hour < 14 && isStationary) {
      phase = 'lunch';
      priority = 2;
      stateDesc = '🍚 午饭时间';
    // 晚餐：17:00-19:30（需 stationary）
    } else if (hour >= 17 && hour < 20 && isStationary) {
      phase = 'dinner';
      priority = 2;
      stateDesc = '🍽️ 晚餐时间';
    // 傍晚/居家：19:30-22:00
    } else if ((tod === 'evening' || tod === 'night') && hour < 22) {
      phase = 'evening';
      priority = 2;
      stateDesc = '🏠 在家放松时间';
    } else {
      // 默认：到家（不限 motionState，允许刚到家的短暂走动）
      phase = 'arrive';
      priority = 1;
      stateDesc = '🏠 到家了';
    }

    // ── 动态置信度（0-100 → 0-1） ─────────────────────────────────
    // 家+静止类场景：stationary 时置信度高（85/100）；
    // 运动状态与预期矛盾（如 driving）时降到 60 以下，低于阈值不触发。
    let confidence: number;
    if (phase === 'arrive') {
      // 到家场景：任何运动状态均合理
      confidence = 0.82;
    } else if (isStationary) {
      // 静止状态与家+静止场景完全匹配
      confidence = 0.85;
    } else if (motion === 'walking') {
      // 家中走动：轻微不匹配，仍可接受
      confidence = 0.75;
    } else if (motion === 'unknown') {
      // 传感器暂时不确定
      confidence = 0.72;
    } else {
      // 驾车/跑步等：与静止家庭场景严重矛盾，低于阈值
      confidence = 0.55;
    }

    return {
      sceneId: this.id,
      sceneName: this.name,
      priority,
      confidence,
      stateDescription: stateDesc,
      emoji: this.emoji,
      metadata: { 'phase': phase }
    };
  }

  getRecommendations(match: SceneMatch, _snapshot: ContextSnapshot): SceneAction[] {
    let phase = (match.metadata?.['phase'] ?? 'arrive') as HomePhase;

    switch (phase) {
      case 'morning':
        return [
          { id: 'calendar', label: '查看今日日程', emoji: '📅' },
          { id: 'weather', label: '今日天气', emoji: '🌤️' },
        ];
      case 'lunch':
        return [
          { id: 'food_suggest', label: '午餐推荐', emoji: '🍚' },
        ];
      case 'dinner':
        return [
          { id: 'food_suggest', label: '晚餐推荐', emoji: '🍽️' },
          { id: 'order_food', label: '叫外卖', emoji: '📱' },
        ];
      case 'evening':
        return [
          { id: 'music', label: '听音乐', emoji: '🎵' },
          { id: 'calendar_tomorrow', label: '明天的安排', emoji: '📋' },
        ];
      case 'bedtime':
        return [
          { id: 'sleep_mode', label: '开启睡眠模式', emoji: '🌙' },
        ];
      default:
        return [
          { id: 'relax', label: '到家了，放松一下', emoji: '🛋️' },
        ];
    }
  }

  /** 设置 SmartActionPlugin 引用（用于 calendar/weather 执行） */
  setSmartPlugin(plugin: SmartActionPlugin): void {
    this.smartPlugin = plugin;
  }

  async executeAction(actionId: string, _match: SceneMatch): Promise<SceneActionResult> {
    // calendar/weather/calendar_tomorrow 委托给 SmartActionPlugin
    let funcMap: Record<string, string> = {
      'calendar': 'calendar_summary',
      'weather': 'morning_briefing',  // morning_briefing 包含天气
      'calendar_tomorrow': 'calendar_tomorrow',
    };
    let func = funcMap[actionId];
    if (func && this.smartPlugin) {
      // 延迟绑定 CalendarPlugin（初始化时可能还没准备好）
      if (!this.calendarWired) {
        try {
          let cas = ContextAwarenessService.getInstance();
          let calPlugin = cas.getCalendarPlugin();
          this.smartPlugin.setCalendarPlugin(calPlugin);
          LogService.getInstance().info('HomeScene', `CalendarPlugin wired: ${calPlugin ? 'yes' : 'no'}`);
        } catch (_e) { /* ignore */ }
        this.calendarWired = true;
      }
      let action: UserAction = {
        type: 'show_info',
        params: { 'function': func }
      };
      let result = await this.smartPlugin.execute(action);
      return { success: result.success, message: result.message, a2uiCard: result.a2uiCard };
    }

    switch (actionId) {
      case 'calendar':
      case 'calendar_tomorrow':
        return { success: true, message: '📅 日历未授权，无法查看日程' };
      case 'weather':
        return { success: true, message: '🌤️ 天气功能加载中...' };
      case 'sleep_mode':
        return { success: true, message: '🌙 已开启睡眠模式' };
      case 'music':
        return { success: true, message: '🎵 正在打开音乐...' };
      default:
        return { success: true, message: `✅ ${actionId}` };
    }
  }
}
