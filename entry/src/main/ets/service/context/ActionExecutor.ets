/**
 * ActionExecutor.ets — 推荐动作执行路由器
 *
 * 根据推荐动作的 type 分发到对应的系统能力执行，返回结果文本。
 * 当前支持: show_info (日历)，其余类型返回通用确认。
 */
import { CalendarPlugin, EventInfo, EventConflict } from './plugins/CalendarPlugin';
import { UserAction } from './ContextModels';
import { LogService } from '../../common/LogService';

const TAG = 'ActionExecutor';

export interface ActionResult {
  success: boolean;
  message: string;
  actionType: string;
}

export class ActionExecutor {
  private calendarPlugin: CalendarPlugin;
  private log: LogService = LogService.getInstance();

  constructor(calendarPlugin: CalendarPlugin) {
    this.calendarPlugin = calendarPlugin;
  }

  async execute(action: UserAction): Promise<ActionResult> {
    this.log.info(TAG, `Execute action: type=${action.type}, target=${action.target ?? ''}`);
    try {
      switch (action.type) {
        case 'show_info':
          return await this.executeShowInfo(action);
        case 'open_app':
          return { success: true, message: `🚀 正在打开 ${action.target ?? '应用'}...`, actionType: 'open_app' };
        case 'set_mode':
          return { success: true, message: `⚙️ 已切换到 ${action.target ?? '模式'}`, actionType: 'set_mode' };
        case 'show_notification':
          return { success: true, message: `🔔 ${action.params?.['info'] ?? '通知已发送'}`, actionType: 'show_notification' };
        default:
          return { success: true, message: `✅ 动作 "${action.type}" 已记录`, actionType: action.type };
      }
    } catch (err) {
      this.log.warn(TAG, `Execute failed: ${(err as Error).message}`);
      return { success: false, message: `执行失败: ${(err as Error).message}`, actionType: action.type };
    }
  }

  private async executeShowInfo(action: UserAction): Promise<ActionResult> {
    let target = action.target ?? '';
    if (target.indexOf('calendar') >= 0 || action.params?.['category'] === 'calendar') {
      return await this.executeCalendarInfo();
    }
    let info = action.params?.['info'] ?? '信息已显示';
    return { success: true, message: `ℹ️ ${info}`, actionType: 'show_info' };
  }

  private async executeCalendarInfo(): Promise<ActionResult> {
    let events: EventInfo[] = await this.calendarPlugin.getUpcomingEvents(8);
    let conflicts: EventConflict[] = this.calendarPlugin.findConflicts(events);
    let markdown = this.calendarPlugin.formatEventsMarkdown(events, conflicts);
    return { success: true, message: markdown, actionType: 'calendar_info' };
  }
}
