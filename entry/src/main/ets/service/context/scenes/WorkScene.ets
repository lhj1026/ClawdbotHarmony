/**
 * WorkScene.ets — 办公场景插件
 *
 * 检测: wifiGeofence=work
 * 子场景: 到公司、会议前、午休、下班
 */
import { ContextSnapshot } from '../ContextEngine';
import { ScenePlugin, SceneMatch, SceneAction, SceneActionResult } from './ScenePlugin';

type WorkPhase = 'arrive' | 'meeting_soon' | 'lunch_break' | 'leave';

export class WorkScene implements ScenePlugin {
  readonly id = 'work';
  readonly name = '办公';
  readonly emoji = '🏢';

  detectScene(snapshot: ContextSnapshot): SceneMatch | null {
    let wifiGf = snapshot.wifiGeofence ?? '';
    if (wifiGf !== 'work') return null;

    let hour = parseInt(snapshot.hour ?? '12');

    let phase: WorkPhase;
    let stateDesc: string;

    if (hour >= 7 && hour < 10) {
      phase = 'arrive';
      stateDesc = '🏢 到公司了，开始新的一天';
    } else if (hour >= 11 && hour < 13) {
      phase = 'lunch_break';
      stateDesc = '🍱 午休时间';
    } else if (hour >= 17) {
      phase = 'leave';
      stateDesc = '🏢 下班时间到了';
    } else {
      phase = 'arrive';
      stateDesc = '🏢 在公司';
    }

    return {
      sceneId: this.id, sceneName: this.name,
      priority: 2, confidence: 0.8,
      stateDescription: stateDesc, emoji: this.emoji,
      metadata: { 'phase': phase }
    };
  }

  getRecommendations(match: SceneMatch, _snapshot: ContextSnapshot): SceneAction[] {
    let phase = (match.metadata?.['phase'] ?? 'arrive') as WorkPhase;
    switch (phase) {
      case 'arrive':
        return [
          { id: 'calendar', label: '今日会议和待办', emoji: '📋' },
          { id: 'silent_mode', label: '开启静音', emoji: '🔇' },
        ];
      case 'lunch_break':
        return [
          { id: 'food_nearby', label: '附近餐厅', emoji: '🍜' },
        ];
      case 'leave':
        return [
          { id: 'route_home', label: '查看回家路线', emoji: '🚗' },
          { id: 'normal_mode', label: '关闭静音', emoji: '📱' },
        ];
      default:
        return [];
    }
  }

  async executeAction(actionId: string, _match: SceneMatch): Promise<SceneActionResult> {
    switch (actionId) {
      case 'calendar':
        return { success: true, message: '📋 查看今日日程' };
      case 'silent_mode':
        return { success: true, message: '🔇 已开启静音' };
      case 'normal_mode':
        return { success: true, message: '📱 已关闭静音' };
      case 'route_home':
        return { success: true, message: '🚗 正在查看回家路线...' };
      default:
        return { success: true, message: `✅ ${actionId}` };
    }
  }
}
