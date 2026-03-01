/**
 * HomeScene.ets — 家庭场景插件
 *
 * 检测: wifiGeofence=home
 * 子场景: 到家、早安、晚餐、睡前、充电
 */
import { ContextSnapshot } from '../ContextEngine';
import { ScenePlugin, SceneMatch, SceneAction, SceneActionResult } from './ScenePlugin';

type HomePhase = 'arrive' | 'morning' | 'lunch' | 'dinner' | 'evening' | 'bedtime';

export class HomeScene implements ScenePlugin {
  readonly id = 'home';
  readonly name = '在家';
  readonly emoji = '🏠';

  detectScene(snapshot: ContextSnapshot): SceneMatch | null {
    let wifiGf = snapshot.wifiGeofence ?? '';
    if (wifiGf !== 'home') return null;

    let tod = snapshot.timeOfDay ?? '';
    let hour = parseInt(snapshot.hour ?? '12');
    let isCharging = snapshot.isCharging === 'true';
    let battery = parseInt(snapshot.batteryLevel ?? '50');

    let phase: HomePhase;
    let priority = 2;
    let stateDesc = '';

    if (tod === 'night' && isCharging) {
      phase = 'bedtime';
      priority = 3;
      stateDesc = '🌙 夜深了，手机在充电';
    } else if (tod === 'morning' || (hour >= 6 && hour < 9)) {
      phase = 'morning';
      priority = 2;
      stateDesc = `☀️ 早上好！电量 ${battery}%`;
    } else if (hour >= 11 && hour < 13) {
      phase = 'lunch';
      priority = 2;
      stateDesc = '🍚 午饭时间';
    } else if (hour >= 17 && hour < 19) {
      phase = 'dinner';
      priority = 2;
      stateDesc = '🍽️ 晚餐时间';
    } else if (tod === 'evening') {
      phase = 'evening';
      priority = 2;
      stateDesc = '🏠 在家放松时间';
    } else {
      phase = 'arrive';
      priority = 1;
      stateDesc = '🏠 到家了';
    }

    return {
      sceneId: this.id,
      sceneName: this.name,
      priority,
      confidence: 0.8,
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

  async executeAction(actionId: string, _match: SceneMatch): Promise<SceneActionResult> {
    switch (actionId) {
      case 'calendar':
        return { success: true, message: '📅 查看今日日程（需要日历插件）' };
      case 'weather':
        return { success: true, message: '🌤️ 查看天气（功能开发中）' };
      case 'sleep_mode':
        return { success: true, message: '🌙 已开启睡眠模式' };
      case 'music':
        return { success: true, message: '🎵 正在打开音乐...' };
      default:
        return { success: true, message: `✅ ${actionId}` };
    }
  }
}
