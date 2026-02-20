/**
 * AppUsagePlugin — Track app usage patterns (self-only)
 *
 * HarmonyOS does NOT allow third-party apps to read app usage statistics
 * (requires system_basic permission: ohos.permission.BUNDLE_ACTIVE_INFO).
 *
 * This plugin instead tracks:
 * - OUR app's foreground/background transitions
 * - Session duration (how long user has been in ClawdBot)
 * - Session count today
 *
 * Provides: app_sessionMinutes, app_sessionsToday, app_isForeground
 *
 * Permission: None (self-tracking only)
 *
 * NOTE: Reading OTHER apps' usage stats is NOT possible for third-party apps.
 * See docs/digital_world_api_research.md for details.
 */
import { common } from '@kit.AbilityKit';
import { LogService } from '../../../common/LogService';
import { DigitalPlugin, DigitalSnapshot } from './DigitalPluginInterface';

const TAG = 'AppUsagePlugin';

export class AppUsagePlugin implements DigitalPlugin {
  name: string = 'appUsage';
  private log: LogService = LogService.getInstance();
  private isForeground: boolean = true;
  private sessionStartTime: number = 0;
  private sessionsToday: number = 0;
  private todayDate: string = '';

  async init(_context: common.UIAbilityContext): Promise<void> {
    this.sessionStartTime = Date.now();
    this.sessionsToday = 1;
    this.todayDate = this.getDateString();
    this.isForeground = true;
    this.log.info(TAG, 'Init: tracking self-usage only');
  }

  getSnapshot(): DigitalSnapshot {
    // Reset daily count if date changed
    let today = this.getDateString();
    if (today !== this.todayDate) {
      this.sessionsToday = this.isForeground ? 1 : 0;
      this.todayDate = today;
    }

    let now = Date.now();
    let sessionMinutes = Math.round((now - this.sessionStartTime) / 60000);

    let data: Record<string, string> = {
      'app_isForeground': this.isForeground ? 'true' : 'false',
      'app_sessionMinutes': sessionMinutes.toString(),
      'app_sessionsToday': this.sessionsToday.toString(),
      'app_canReadOthers': 'false'  // always false for third-party apps
    };

    return {
      pluginName: this.name,
      timestamp: now,
      data: data
    };
  }

  destroy(): void {
    this.log.info(TAG, 'Destroyed');
  }

  /** Call from UIAbility.onForeground() */
  onAppForeground(): void {
    if (!this.isForeground) {
      this.isForeground = true;
      this.sessionStartTime = Date.now();
      this.sessionsToday++;
      this.log.debug(TAG, `Foreground, sessions today: ${this.sessionsToday}`);
    }
  }

  /** Call from UIAbility.onBackground() */
  onAppBackground(): void {
    this.isForeground = false;
    this.log.debug(TAG, 'Background');
  }

  private getDateString(): string {
    let d = new Date();
    let y = d.getFullYear().toString();
    let m = (d.getMonth() + 1).toString().padStart(2, '0');
    let day = d.getDate().toString().padStart(2, '0');
    return `${y}-${m}-${day}`;
  }
}
