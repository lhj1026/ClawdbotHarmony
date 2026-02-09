/**
 * Handles notification commands from the gateway.
 * Displays system notifications on the HarmonyOS device.
 */
import { notificationManager } from '@kit.NotificationKit';
import { LogService } from '../../common/LogService';

const TAG = 'NotifCap';

export class NotificationCapability {
  private nextNotifId: number = 1000;
  private log: LogService = LogService.getInstance();

  async execute(paramsJson: string | undefined): Promise<string> {
    this.log.info(TAG, `execute: params=${paramsJson ?? 'none'}`);

    let title = 'OpenClaw';
    let body = '';
    if (paramsJson && paramsJson.length > 0) {
      try {
        let p = JSON.parse(paramsJson) as Record<string, string>;
        if (p['title']) {
          title = p['title'];
        }
        if (p['body']) {
          body = p['body'];
        } else if (p['content']) {
          body = p['content'];
        } else if (p['message']) {
          body = p['message'];
        }
      } catch {
        this.log.warn(TAG, 'Failed to parse notification params');
      }
    }

    let notifId = this.nextNotifId++;
    this.log.info(TAG, `Publishing notification #${notifId}: title="${title}" body="${body.substring(0, 50)}${body.length > 50 ? '...' : ''}"`);

    let request: notificationManager.NotificationRequest = {
      id: notifId,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: body,
        },
      },
    };

    await notificationManager.publish(request);
    this.log.info(TAG, `Notification #${notifId} published successfully`);
    return `{"ok":true,"notificationId":${notifId}}`;
  }
}
