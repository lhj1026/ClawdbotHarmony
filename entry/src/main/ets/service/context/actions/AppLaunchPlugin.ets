/**
 * AppLaunchPlugin — 打开应用动作
 *
 * 处理: open_app
 * 通过 bundleName 或 deeplink 启动目标应用。
 */
import { UserAction, ActionType } from '../ContextModels';
import { ActionPlugin, ActionResult, ActionDisplayInfo } from './ActionPlugin';
import { LogService } from '../../../common/LogService';
import { common, Want } from '@kit.AbilityKit';

const TAG = 'AppLaunchPlugin';

export class AppLaunchPlugin implements ActionPlugin {
  readonly name = 'AppLaunchPlugin';
  readonly supportedTypes: ActionType[] = ['open_app'];
  private context: common.UIAbilityContext | undefined;

  setContext(context: common.UIAbilityContext): void {
    this.context = context;
  }

  canHandle(action: UserAction): boolean {
    return action.type === 'open_app';
  }

  async execute(action: UserAction): Promise<ActionResult> {
    let target = action.target ?? '';
    let log = LogService.getInstance();

    if (!this.context) {
      log.warn(TAG, 'UIAbilityContext not set');
      return { success: false, message: '⚠️ 无法打开应用（上下文未初始化）', actionType: 'open_app' };
    }

    if (target.length === 0) {
      return { success: false, message: '⚠️ 未指定目标应用', actionType: 'open_app' };
    }

    log.info(TAG, `打开应用: ${target}`);

    try {
      // 常用应用 bundleName 映射
      let bundleMap: Record<string, string> = {
        'weather': 'com.huawei.hmos.weather',
        'calendar': 'com.huawei.hmos.calendar',
        'clock': 'com.huawei.hmos.clock',
        'settings': 'com.huawei.hmos.settings',
        'music': 'com.huawei.hmos.music',
        'camera': 'com.huawei.hmos.camera',
        'maps': 'com.huawei.hmos.maps',
        'health': 'com.huawei.hmos.health',
      };

      let bundleName = bundleMap[target.toLowerCase()] ?? target;

      let want: Want = {
        bundleName: bundleName,
        action: 'ohos.want.action.home',
      };
      await this.context.startAbility(want);

      let displayName = Object.keys(bundleMap).find((k: string) => bundleMap[k] === bundleName) ?? target;
      return {
        success: true,
        message: `🚀 已打开 ${displayName}`,
        actionType: 'open_app'
      };
    } catch (err) {
      log.warn(TAG, `打开应用失败: ${(err as Error).message}`);
      return {
        success: false,
        message: `⚠️ 无法打开 ${target}: ${(err as Error).message}`,
        actionType: 'open_app'
      };
    }
  }

  getDisplayInfo(action: UserAction): ActionDisplayInfo {
    let target = action.target ?? '应用';
    let nameMap: Record<string, string> = {
      'weather': '天气', 'calendar': '日历', 'clock': '时钟',
      'music': '音乐', 'maps': '地图', 'health': '运动健康'
    };
    let name = nameMap[target.toLowerCase()] ?? target;
    return { title: `打开${name}`, emoji: '🚀' };
  }
}
