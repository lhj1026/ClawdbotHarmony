/**
 * SmartActionPlugin — 智能功能执行插件
 *
 * 处理带 function 标签的动作，通过 OpenClaw Agent 执行真实功能：
 * - morning_briefing: 晨间播报（日程+天气）
 * - calendar_summary: 今日日程摘要
 * - calendar_tomorrow: 明日日程预览
 * - open_app:<target>: 打开指定应用
 */
import { UserAction, ActionType } from '../ContextModels';
import { ActionPlugin, ActionResult, ActionDisplayInfo } from './ActionPlugin';
import { LogService } from '../../../common/LogService';

const TAG = 'SmartActionPlugin';

/** Function → Agent prompt 映射 */
interface FunctionPrompt {
  prompt: string;
  emoji: string;
  title: string;
}

export class SmartActionPlugin implements ActionPlugin {
  readonly name = 'SmartActionPlugin';
  readonly supportedTypes: ActionType[] = ['show_notification', 'show_info', 'quick_action'];

  private sendToAgent: ((text: string) => Promise<void>) | undefined;

  /** 设置 agent 通信回调 */
  setSendToAgent(fn: (text: string) => Promise<void>): void {
    this.sendToAgent = fn;
  }

  private static FUNCTION_PROMPTS: Record<string, FunctionPrompt> = {
    'morning_briefing': {
      prompt: '请给我做一个简短的晨间播报：1) 今天的日程安排 2) 今天的天气。简洁明了，用中文回答。',
      emoji: '🌅',
      title: '晨间播报'
    },
    'calendar_summary': {
      prompt: '请查看我今天的日程安排，简要总结一下有哪些会议和待办。用中文回答。',
      emoji: '📅',
      title: '今日日程'
    },
    'calendar_tomorrow': {
      prompt: '请查看我明天的日程安排，简要总结一下。用中文回答。',
      emoji: '📅',
      title: '明日日程'
    },
  };

  canHandle(action: UserAction): boolean {
    let func = action.params?.['function'] ?? '';
    return func.length > 0;
  }

  async execute(action: UserAction): Promise<ActionResult> {
    let log = LogService.getInstance();
    let func = action.params?.['function'] ?? '';

    if (func.length === 0) {
      return { success: false, message: '⚠️ 未指定功能', actionType: action.type };
    }

    // open_app:<target> 特殊处理
    if (func.startsWith('open_app:')) {
      let appTarget = func.substring(9);
      log.info(TAG, `open_app function: ${appTarget}`);
      return {
        success: true,
        message: `🚀 正在打开 ${appTarget}...`,
        actionType: 'open_app'
      };
    }

    // 查找预定义的 function prompt
    let funcDef = SmartActionPlugin.FUNCTION_PROMPTS[func];
    if (!funcDef) {
      log.warn(TAG, `Unknown function: ${func}`);
      // fallback: 显示原始 payload 文本
      let message = action.target ?? '通知已发送';
      return { success: true, message: message, actionType: action.type };
    }

    // 发送到 Agent 执行
    if (this.sendToAgent) {
      log.info(TAG, `Sending to agent: ${func} → "${funcDef.prompt.substring(0, 50)}..."`);
      try {
        await this.sendToAgent(funcDef.prompt);
        return {
          success: true,
          message: `${funcDef.emoji} ${funcDef.title}正在准备中...`,
          actionType: action.type
        };
      } catch (err) {
        log.warn(TAG, `Agent request failed: ${(err as Error).message}`);
        return {
          success: false,
          message: `⚠️ ${funcDef.title}获取失败: ${(err as Error).message}`,
          actionType: action.type
        };
      }
    } else {
      log.warn(TAG, 'sendToAgent not configured');
      // fallback: 显示原始文本
      let message = action.target ?? funcDef.title;
      return { success: true, message: message, actionType: action.type };
    }
  }

  getDisplayInfo(action: UserAction): ActionDisplayInfo {
    let func = action.params?.['function'] ?? '';
    let funcDef = SmartActionPlugin.FUNCTION_PROMPTS[func];
    if (funcDef) {
      return { title: funcDef.title, emoji: funcDef.emoji };
    }
    return { title: action.target ?? '执行', emoji: '⚡' };
  }
}
