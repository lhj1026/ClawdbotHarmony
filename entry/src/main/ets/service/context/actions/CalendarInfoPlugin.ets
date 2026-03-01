/**
 * CalendarInfoPlugin — 日历信息动作
 *
 * 处理: show_info (target=calendar)
 * 显示今日日程、会议提醒等。
 */
import { UserAction, ActionType } from '../ContextModels';
import { ActionPlugin, ActionResult, ActionDisplayInfo } from './ActionPlugin';
import { CalendarPlugin, EventInfo, EventConflict } from '../plugins/CalendarPlugin';

export class CalendarInfoPlugin implements ActionPlugin {
  readonly name = 'CalendarInfoPlugin';
  readonly supportedTypes: ActionType[] = ['show_info'];
  private calendarPlugin: CalendarPlugin;

  constructor(calendarPlugin: CalendarPlugin) {
    this.calendarPlugin = calendarPlugin;
  }

  canHandle(action: UserAction): boolean {
    if (action.type !== 'show_info') return false;
    let target = action.target ?? '';
    return target.indexOf('calendar') >= 0 || action.params?.['category'] === 'calendar';
  }

  async execute(action: UserAction): Promise<ActionResult> {
    let events: EventInfo[] = await this.calendarPlugin.getUpcomingEvents(8);
    let conflicts: EventConflict[] = this.calendarPlugin.findConflicts(events);
    let markdown = this.calendarPlugin.formatEventsMarkdown(events, conflicts);
    return {
      success: true,
      message: markdown,
      actionType: 'calendar_info'
    };
  }

  getDisplayInfo(_action: UserAction): ActionDisplayInfo {
    return {
      title: '查看今日日程',
      emoji: '📅'
    };
  }
}
