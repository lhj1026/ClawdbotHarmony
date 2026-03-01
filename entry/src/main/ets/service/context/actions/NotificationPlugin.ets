/**
 * NotificationPlugin — 通知/提醒/建议类动作
 *
 * 处理: suggestion, notification, alert
 * 这些动作本质是向用户展示文字信息。
 */
import { UserAction, ActionType } from '../ContextModels';
import { ActionPlugin, ActionResult, ActionDisplayInfo } from './ActionPlugin';

export class NotificationPlugin implements ActionPlugin {
  readonly name = 'NotificationPlugin';
  readonly supportedTypes: ActionType[] = ['show_notification', 'show_info', 'quick_action'];

  canHandle(action: UserAction): boolean {
    return action.type === 'show_notification' || action.type === 'show_info' || action.type === 'quick_action';
  }

  async execute(action: UserAction): Promise<ActionResult> {
    let message = action.params?.['info'] ?? action.target ?? '通知已发送';
    let emoji = action.type === 'show_notification' ? '🔔' : action.type === 'show_info' ? 'ℹ️' : '⚡';
    return {
      success: true,
      message: `${emoji} ${message}`,
      actionType: action.type
    };
  }

  getDisplayInfo(action: UserAction): ActionDisplayInfo {
    return {
      title: action.params?.['info'] ?? action.target ?? '查看通知',
      emoji: '🔔'
    };
  }
}
