/**
 * NotificationPlugin — Track notifications sent by OUR app
 *
 * HarmonyOS does NOT allow third-party apps to read notifications from
 * other apps (requires system_core permission: ohos.permission.NOTIFICATION_CONTROLLER).
 *
 * This plugin instead tracks:
 * - Notifications sent by ClawdBot itself (count, last sent time)
 * - Notification permission state
 * - Acts as a stub for future system-level integration
 *
 * Provides: notif_selfCount, notif_enabled, notif_lastSentMinutes
 *
 * Permission: None (self-tracking only)
 * API: @kit.NotificationKit — notificationManager (publish-side only)
 *
 * NOTE: Reading OTHER apps' notifications is NOT possible for third-party apps.
 * See docs/digital_world_api_research.md for details.
 */
import { notificationManager } from '@kit.NotificationKit';
import { common } from '@kit.AbilityKit';
import { LogService } from '../../../common/LogService';
import { DigitalPlugin, DigitalSnapshot } from './DigitalPluginInterface';

const TAG = 'NotificationPlugin';

export class NotificationPlugin implements DigitalPlugin {
  name: string = 'notification';
  private log: LogService = LogService.getInstance();
  private notifEnabled: boolean = false;
  private selfNotifCount: number = 0;
  private lastSentTimestamp: number = 0;

  async init(_context: common.UIAbilityContext): Promise<void> {
    try {
      this.notifEnabled = await notificationManager.isNotificationEnabled();
    } catch {
      this.notifEnabled = false;
    }
    this.log.info(TAG, `Init: notifEnabled=${this.notifEnabled}`);
  }

  getSnapshot(): DigitalSnapshot {
    let now = Date.now();
    let data: Record<string, string> = {
      'notif_enabled': this.notifEnabled ? 'true' : 'false',
      'notif_selfCount': this.selfNotifCount.toString(),
      'notif_canReadOthers': 'false'  // always false for third-party apps
    };

    if (this.lastSentTimestamp > 0) {
      let minutesAgo = Math.round((now - this.lastSentTimestamp) / 60000);
      data['notif_lastSentMinutes'] = minutesAgo.toString();
    }

    return {
      pluginName: this.name,
      timestamp: now,
      data: data
    };
  }

  destroy(): void {
    this.log.info(TAG, 'Destroyed');
  }

  /** Call this when our app sends a notification (external tracking hook) */
  onSelfNotificationSent(): void {
    this.selfNotifCount++;
    this.lastSentTimestamp = Date.now();
  }
}
