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
    let motion = snapshot.motionState ?? '';
    let isStationary = (motion === 'stationary' || motion === '');
    let isMoving = (motion === 'walking' || motion === 'driving' || motion === 'cycling');

    // 围栏变化信号：刚从另一个已知地点（如 home）转移过来
    let recentGeofenceChange = (snapshot.wifiLost === 'true');
    let cameFromHome = recentGeofenceChange && (snapshot.wifiLostCategory === 'home');

    let phase: WorkPhase;
    let stateDesc: string;
    let confidence: number;

    if (hour >= 7 && hour < 10) {
      phase = 'arrive';
      stateDesc = '🏢 到公司了，开始新的一天';
      // 运动转移场景：有围栏变化事件才给高置信度
      // 从家过来 → 强通勤信号；无围栏变化 → 正常到达
      if (cameFromHome) {
        confidence = 0.92;
      } else if (recentGeofenceChange) {
        confidence = 0.85;
      } else {
        confidence = 0.80;
      }
    } else if (hour >= 11 && hour < 14) {
      phase = 'lunch_break';
      stateDesc = '🍱 午休时间';
      confidence = isStationary ? 0.82 : 0.75;
    } else if (hour >= 17) {
      // 离开场景：需要有运动信号（正在走动/驾车）才触发为下班场景
      // 纯静止 + 下班时间 → 降低置信度（可能还在加班）
      phase = 'leave';
      stateDesc = '🏢 下班时间到了';
      if (isMoving) {
        // 检测到移动 → 正在离开，强信号
        confidence = 0.88;
      } else if (isStationary) {
        // 静止但已到下班时间 → 置信度略低（可能还在工作）
        confidence = 0.72;
      } else {
        confidence = 0.78;
      }
    } else {
      phase = 'arrive';
      stateDesc = '🏢 在公司';
      confidence = 0.80;
    }

    return {
      sceneId: this.id, sceneName: this.name,
      priority: 2, confidence,
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
