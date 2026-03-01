/**
 * ClawdBotAccessibilityExtension — 无障碍扩展入口
 *
 * 继承 AccessibilityExtensionAbility，初始化 AccessibilityService 单例，
 * 使 NodeRuntime 可以通过 AccessibilityService 读取和操控其他应用界面。
 */
import AccessibilityExtensionAbility, { AccessibilityEvent } from '@ohos.application.AccessibilityExtensionAbility';
import { AccessibilityService } from '../service/accessibility/AccessibilityService';
import { LogService } from '../common/LogService';

const TAG = 'A11yExtension';

export default class ClawdBotAccessibilityExtension extends AccessibilityExtensionAbility {
  private log: LogService = LogService.getInstance();

  onConnect(): void {
    this.log.info(TAG, 'onConnect: accessibility extension connected');
    try {
      AccessibilityService.getInstance().init(this.context);
      this.log.info(TAG, 'onConnect: AccessibilityService initialized');
    } catch (err) {
      this.log.error(TAG, `onConnect error: ${(err as Error).message ?? String(err)}`);
    }
  }

  onDisconnect(): void {
    this.log.info(TAG, 'onDisconnect: accessibility extension disconnected');
    try {
      AccessibilityService.getInstance().destroy();
    } catch (err) {
      this.log.warn(TAG, `onDisconnect error: ${(err as Error).message ?? String(err)}`);
    }
  }

  onAccessibilityEvent(event: AccessibilityEvent): void {
    this.log.info(TAG, `onAccessibilityEvent: type=${event.eventType}`);
  }
}
