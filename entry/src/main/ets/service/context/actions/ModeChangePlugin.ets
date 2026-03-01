/**
 * ModeChangePlugin — 模式切换动作
 *
 * 处理: set_mode
 * 目标模式: sleep（睡眠/勿扰）, driving（驾驶）, silent（静音）, normal（正常）
 */
import { UserAction, ActionType } from '../ContextModels';
import { ActionPlugin, ActionResult, ActionDisplayInfo } from './ActionPlugin';
import { LogService } from '../../../common/LogService';

const TAG = 'ModeChangePlugin';

export class ModeChangePlugin implements ActionPlugin {
  readonly name = 'ModeChangePlugin';
  readonly supportedTypes: ActionType[] = ['set_mode'];

  canHandle(action: UserAction): boolean {
    return action.type === 'set_mode';
  }

  async execute(action: UserAction): Promise<ActionResult> {
    let mode = action.target ?? 'normal';
    let log = LogService.getInstance();
    log.info(TAG, `切换模式: ${mode}`);

    let modeLabels: Record<string, string> = {
      'sleep': '🌙 睡眠模式',
      'driving': '🚗 驾驶模式',
      'silent': '🔇 静音模式',
      'dnd': '🔕 勿扰模式',
      'normal': '📱 正常模式',
      'flight': '✈️ 飞行模式'
    };

    let label = modeLabels[mode] ?? `⚙️ ${mode}模式`;

    // TODO: 实际调用系统 API 切换模式
    // import audio from '@ohos.multimedia.audio' → 静音
    // import notification from '@ohos.notification' → 勿扰

    return {
      success: true,
      message: `已切换到${label}`,
      actionType: 'set_mode'
    };
  }

  getDisplayInfo(action: UserAction): ActionDisplayInfo {
    let mode = action.target ?? 'normal';
    let emojiMap: Record<string, string> = {
      'sleep': '🌙', 'driving': '🚗', 'silent': '🔇', 'dnd': '🔕', 'normal': '📱', 'flight': '✈️'
    };
    let nameMap: Record<string, string> = {
      'sleep': '睡眠模式', 'driving': '驾驶模式', 'silent': '静音', 'dnd': '勿扰', 'normal': '正常模式', 'flight': '飞行模式'
    };
    return {
      title: nameMap[mode] ?? `${mode}模式`,
      emoji: emojiMap[mode] ?? '⚙️'
    };
  }
}
