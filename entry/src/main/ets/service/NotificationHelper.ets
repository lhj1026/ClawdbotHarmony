/**
 * NotificationHelper — lightweight utility for sending local notifications.
 * Used for alerting the user about new messages when the app is in the background.
 *
 * This is independent from NotificationCapability (gateway-triggered notifications).
 */
import { notificationManager } from '@kit.NotificationKit';
import { wantAgent, Want } from '@kit.AbilityKit';
import { LogService } from '../common/LogService';

const TAG = 'NotifHelper';

export class NotificationHelper {
  private static instance: NotificationHelper | undefined = undefined;
  private log: LogService = LogService.getInstance();
  private nextId: number = 2000; // offset from NotificationCapability (1000+)
  private permissionGranted: boolean = false;
  private permissionChecked: boolean = false;
  private cachedWantAgent: object | undefined = undefined;
  private bundleName: string = '';

  private constructor() {
  }

  static getInstance(): NotificationHelper {
    if (!NotificationHelper.instance) {
      NotificationHelper.instance = new NotificationHelper();
    }
    return NotificationHelper.instance;
  }

  /** Call once with the app's bundle name so click-to-open works */
  init(bundleName: string): void {
    this.bundleName = bundleName;
    this.log.info(TAG, `Initialized with bundle: ${bundleName}`);
  }

  /**
   * Request notification permission early (fire-and-forget).
   * Call this during app startup so permission is ready when needed.
   */
  requestPermission(): void {
    this.ensurePermission().then(() => {
      this.log.info(TAG, `Permission check done: granted=${this.permissionGranted}`);
    }).catch(() => {
      this.log.warn(TAG, 'Permission request failed (ignored)');
    });
  }

  /**
   * Send a simple text notification.
   * @param title - notification title
   * @param text - notification body text
   * @returns notification id, or -1 on failure
   */
  async send(title: string, text: string): Promise<number> {
    if (!this.permissionGranted) {
      await this.ensurePermission();
    }
    if (!this.permissionGranted) {
      this.log.warn(TAG, 'Cannot send: permission not granted');
      return -1;
    }

    let id = this.nextId++;

    let request: notificationManager.NotificationRequest = {
      id: id,
      notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: text,
        },
      },
    };

    // Attach click-to-open action
    let agent = await this.getOrCreateWantAgent();
    if (agent) {
      request.wantAgent = agent;
    }

    try {
      await notificationManager.publish(request);
      this.log.info(TAG, `Sent #${id}: "${title}"`);
      return id;
    } catch (err) {
      this.log.error(TAG, `Failed to send #${id}: ${(err as Error).message ?? ''}`);
      return -1;
    }
  }

  /** Cancel a previously sent notification */
  async cancel(id: number): Promise<void> {
    try {
      await notificationManager.cancel(id);
      this.log.info(TAG, `Cancelled #${id}`);
    } catch (err) {
      this.log.warn(TAG, `Cancel #${id} failed: ${(err as Error).message ?? ''}`);
    }
  }

  /** Cancel all notifications from this app */
  async cancelAll(): Promise<void> {
    try {
      await notificationManager.cancelAll();
      this.log.info(TAG, 'Cancelled all notifications');
    } catch (err) {
      this.log.warn(TAG, `CancelAll failed: ${(err as Error).message ?? ''}`);
    }
  }

  private async getOrCreateWantAgent(): Promise<object | undefined> {
    if (this.cachedWantAgent) {
      return this.cachedWantAgent;
    }
    if (!this.bundleName) {
      return undefined;
    }

    try {
      let want: Want = {
        bundleName: this.bundleName,
        abilityName: 'EntryAbility',
      };
      let info: wantAgent.WantAgentInfo = {
        wants: [want],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
      };
      this.cachedWantAgent = await wantAgent.getWantAgent(info);
      return this.cachedWantAgent;
    } catch (err) {
      this.log.warn(TAG, `WantAgent creation failed: ${(err as Error).message ?? ''}`);
      return undefined;
    }
  }

  private async ensurePermission(): Promise<void> {
    if (this.permissionChecked) {
      return;
    }
    try {
      let enabled = await notificationManager.isNotificationEnabled();
      if (enabled) {
        this.permissionGranted = true;
        this.permissionChecked = true;
        return;
      }
      try {
        await notificationManager.requestEnableNotification();
        this.permissionGranted = true;
      } catch (err) {
        let code = (err as Record<string, number>)['code'] ?? 0;
        if (code === 1600004) {
          this.permissionGranted = true;
        } else {
          this.log.warn(TAG, `Permission denied: code=${code}`);
          this.permissionGranted = false;
        }
      }
      this.permissionChecked = true;
    } catch (err) {
      this.log.error(TAG, `Permission check error: ${(err as Error).message ?? ''}`);
      this.permissionGranted = true; // optimistic fallback
      this.permissionChecked = true;
    }
  }
}
