/**
 * ScreenStatePlugin — Detect screen on/off and locked/unlocked state
 *
 * Uses multiple APIs for robust detection:
 * - screenLock.isLocked() — lock state (no permission required)
 * - display.getDefaultDisplaySync().state — screen on/off (no permission required)
 *
 * Note: Event-based listening via screenLock.onSystemEvent() requires system_core
 * permission, so we poll instead. However, commonEventManager can subscribe to
 * COMMON_EVENT_SCREEN_ON/OFF/LOCKED/UNLOCKED — available to third-party apps.
 * The DigitalWorldService polls every 30s which is sufficient for context awareness.
 *
 * Provides: screen_locked, screen_on, user_active
 *
 * Permission: None required
 * API: @kit.BasicServicesKit (screenLock), @kit.ArkUI (display)
 */
import { screenLock } from '@kit.BasicServicesKit';
import { display } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { LogService } from '../../../common/LogService';
import { DigitalPlugin, DigitalSnapshot } from './DigitalPluginInterface';

const TAG = 'ScreenStatePlugin';

export class ScreenStatePlugin implements DigitalPlugin {
  name: string = 'screenState';
  private log: LogService = LogService.getInstance();
  private isLocked: boolean = false;
  private isScreenOn: boolean = true;

  async init(_context: common.UIAbilityContext): Promise<void> {
    this.refreshState();
    this.log.info(TAG, `Init: locked=${this.isLocked}, screenOn=${this.isScreenOn}`);
  }

  getSnapshot(): DigitalSnapshot {
    this.refreshState();

    let data: Record<string, string> = {
      'screen_locked': this.isLocked ? 'true' : 'false',
      'screen_on': this.isScreenOn ? 'true' : 'false',
      'user_active': (!this.isLocked && this.isScreenOn) ? 'true' : 'false'
    };

    return {
      pluginName: this.name,
      timestamp: Date.now(),
      data: data
    };
  }

  destroy(): void {
    this.log.info(TAG, 'Destroyed');
  }

  private refreshState(): void {
    // Check lock state via screenLock API
    try {
      this.isLocked = screenLock.isLocked();
    } catch {
      this.isLocked = false;
    }

    // Check screen on/off via display API (more reliable than screenLock)
    try {
      let defaultDisplay = display.getDefaultDisplaySync();
      this.isScreenOn = defaultDisplay.state === display.DisplayState.STATE_ON;
    } catch {
      // Fallback: if display API unavailable, infer from lock state
      this.isScreenOn = !this.isLocked;
    }
  }
}
