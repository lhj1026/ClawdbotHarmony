/**
 * QRCodePlugin — 二维码/乘车码动作
 *
 * 处理: show_qrcode
 * 在交通场景下快速显示乘车码、付款码等。
 */
import { UserAction, ActionType } from '../ContextModels';
import { ActionPlugin, ActionResult, ActionDisplayInfo } from './ActionPlugin';
import { LogService } from '../../../common/LogService';

const TAG = 'QRCodePlugin';

export class QRCodePlugin implements ActionPlugin {
  readonly name = 'QRCodePlugin';
  readonly supportedTypes: ActionType[] = ['show_qrcode'];

  canHandle(action: UserAction): boolean {
    return action.type === 'show_qrcode';
  }

  async execute(action: UserAction): Promise<ActionResult> {
    let target = action.target ?? 'transit';
    let log = LogService.getInstance();
    log.info(TAG, `显示二维码: ${target}`);

    // TODO: 实际调用系统卡包 / 支付宝 / 微信乘车码
    // HarmonyOS: 可以通过 Want 跳转到对应 App 的乘车码页面

    let typeMap: Record<string, string> = {
      'transit': '🚇 乘车码',
      'payment': '💳 付款码',
      'health': '🏥 健康码',
    };
    let label = typeMap[target] ?? `📱 ${target}`;

    return {
      success: true,
      message: `${label} 已准备好`,
      actionType: 'show_qrcode'
    };
  }

  getDisplayInfo(action: UserAction): ActionDisplayInfo {
    let target = action.target ?? 'transit';
    let nameMap: Record<string, string> = {
      'transit': '乘车码', 'payment': '付款码', 'health': '健康码'
    };
    return {
      title: nameMap[target] ?? '二维码',
      emoji: '📱'
    };
  }
}
