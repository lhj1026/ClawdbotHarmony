/**
 * DigitalWorldService — Plugin Manager for digital world perception
 *
 * Registers all available digital plugins, periodically polls for snapshots,
 * and provides merged digital data for the context engine.
 *
 * Privacy design:
 * - Each plugin has a privacy level and default enabled state
 * - High/critical privacy plugins are DISABLED by default
 * - User can toggle individual plugins via preferences
 * - All data stays local (never sent to cloud without user action)
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { LogService } from '../../common/LogService';
import { DigitalPlugin, DigitalSnapshot, PluginRegistration } from './plugins/DigitalPluginInterface';
import { CalendarPlugin } from './plugins/CalendarPlugin';
import { ScreenStatePlugin } from './plugins/ScreenStatePlugin';
import { MediaStatePlugin } from './plugins/MediaStatePlugin';
import { NotificationPlugin } from './plugins/NotificationPlugin';
import { AppUsagePlugin } from './plugins/AppUsagePlugin';

const TAG = 'DigitalWorld';
const PREFS_NAME = 'digital_world_settings';
const POLL_INTERVAL_MS = 30 * 1000;  // 30 seconds

export class DigitalWorldService {
  private static instance: DigitalWorldService;
  private log: LogService = LogService.getInstance();

  private registrations: PluginRegistration[] = [];
  private enabledPlugins: Map<string, boolean> = new Map();
  private prefsStore: preferences.Preferences | undefined;
  private pollTimer: number = -1;
  private lastSnapshots: Map<string, DigitalSnapshot> = new Map();
  private initialized: boolean = false;
  private context: common.UIAbilityContext | undefined;

  private constructor() {}

  static getInstance(): DigitalWorldService {
    if (!DigitalWorldService.instance) {
      DigitalWorldService.instance = new DigitalWorldService();
    }
    return DigitalWorldService.instance;
  }

  /**
   * Initialize the service and all registered plugins.
   * Call once during app startup after ContextAwarenessService.init().
   */
  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.initialized) return;
    this.context = context;

    // Load user preferences for plugin toggles
    try {
      this.prefsStore = await preferences.getPreferences(context, PREFS_NAME);
    } catch (err) {
      this.log.warn(TAG, `Prefs init failed: ${(err as Error).message}`);
    }

    // Register all plugins
    this.registerPlugins();

    // Load user's enabled/disabled preferences
    await this.loadPluginPreferences();

    // Initialize enabled plugins
    for (let i = 0; i < this.registrations.length; i++) {
      let reg = this.registrations[i];
      let enabled = this.enabledPlugins.get(reg.plugin.name) ?? reg.enabledByDefault;
      if (enabled) {
        try {
          await reg.plugin.init(context);
          this.log.info(TAG, `Plugin initialized: ${reg.plugin.name}`);
        } catch (err) {
          this.log.warn(TAG, `Plugin init failed: ${reg.plugin.name}: ${(err as Error).message}`);
          this.enabledPlugins.set(reg.plugin.name, false);
        }
      }
    }

    this.initialized = true;
    this.log.info(TAG, `DigitalWorldService initialized, plugins: ${this.getEnabledCount()}/${this.registrations.length}`);
  }

  /**
   * Start periodic polling of all enabled plugins.
   */
  start(): void {
    if (this.pollTimer !== -1) return;

    // Take initial snapshot
    this.pollAllPlugins();

    this.pollTimer = setInterval(() => {
      this.pollAllPlugins();
    }, POLL_INTERVAL_MS);

    this.log.info(TAG, 'Started periodic polling');
  }

  /**
   * Stop polling and destroy all plugins.
   */
  stop(): void {
    if (this.pollTimer !== -1) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }

    for (let i = 0; i < this.registrations.length; i++) {
      let reg = this.registrations[i];
      let enabled = this.enabledPlugins.get(reg.plugin.name) ?? false;
      if (enabled) {
        try {
          reg.plugin.destroy();
        } catch {
          // ignore
        }
      }
    }

    this.log.info(TAG, 'Stopped');
  }

  /**
   * Get merged digital snapshot data as key-value pairs.
   * This is the main interface for ContextAwarenessService to consume.
   */
  getDigitalData(): Record<string, string> {
    let merged: Record<string, string> = {};

    this.lastSnapshots.forEach((snapshot: DigitalSnapshot) => {
      let keys = Object.keys(snapshot.data);
      for (let i = 0; i < keys.length; i++) {
        merged[keys[i]] = snapshot.data[keys[i]];
      }
    });

    return merged;
  }

  /**
   * Get a single plugin's latest snapshot.
   */
  getPluginSnapshot(pluginName: string): DigitalSnapshot | undefined {
    return this.lastSnapshots.get(pluginName);
  }

  /**
   * Toggle a plugin on or off. Persists to preferences.
   */
  async setPluginEnabled(pluginName: string, enabled: boolean): Promise<void> {
    this.enabledPlugins.set(pluginName, enabled);

    // Initialize or destroy the plugin
    let reg = this.registrations.find((r: PluginRegistration): boolean =>
      r.plugin.name === pluginName
    );
    if (reg && this.context) {
      if (enabled) {
        try {
          await reg.plugin.init(this.context);
          this.log.info(TAG, `Plugin enabled: ${pluginName}`);
        } catch (err) {
          this.log.warn(TAG, `Plugin enable failed: ${pluginName}: ${(err as Error).message}`);
          this.enabledPlugins.set(pluginName, false);
        }
      } else {
        reg.plugin.destroy();
        this.lastSnapshots.delete(pluginName);
        this.log.info(TAG, `Plugin disabled: ${pluginName}`);
      }
    }

    // Persist preference
    await this.savePluginPreference(pluginName, enabled);
  }

  /**
   * Get the list of all registered plugins with their status.
   */
  getPluginStatus(): PluginStatusInfo[] {
    let result: PluginStatusInfo[] = [];
    for (let i = 0; i < this.registrations.length; i++) {
      let reg = this.registrations[i];
      let enabled = this.enabledPlugins.get(reg.plugin.name) ?? reg.enabledByDefault;
      result.push({
        name: reg.plugin.name,
        description: reg.description,
        privacyLevel: reg.privacyLevel,
        enabled: enabled,
        hasData: this.lastSnapshots.has(reg.plugin.name)
      });
    }
    return result;
  }

  /**
   * Get the NotificationPlugin instance for external tracking hooks.
   */
  getNotificationPlugin(): NotificationPlugin | undefined {
    let reg = this.registrations.find((r: PluginRegistration): boolean =>
      r.plugin.name === 'notification'
    );
    if (reg) {
      return reg.plugin as NotificationPlugin;
    }
    return undefined;
  }

  /**
   * Get the AppUsagePlugin instance for foreground/background tracking.
   */
  getAppUsagePlugin(): AppUsagePlugin | undefined {
    let reg = this.registrations.find((r: PluginRegistration): boolean =>
      r.plugin.name === 'appUsage'
    );
    if (reg) {
      return reg.plugin as AppUsagePlugin;
    }
    return undefined;
  }

  // ==================== Private ====================

  private registerPlugins(): void {
    this.registrations = [
      {
        plugin: new CalendarPlugin(),
        privacyLevel: 'medium',
        enabledByDefault: true,
        description: '读取日历事件，了解用户日程安排'
      },
      {
        plugin: new ScreenStatePlugin(),
        privacyLevel: 'low',
        enabledByDefault: true,
        description: '检测屏幕状态（开/关/锁屏）'
      },
      {
        plugin: new MediaStatePlugin(),
        privacyLevel: 'low',
        enabledByDefault: true,
        description: '检测音频场景（通话/媒体/耳机）'
      },
      {
        plugin: new NotificationPlugin(),
        privacyLevel: 'low',
        enabledByDefault: true,
        description: '追踪本应用发送的通知'
      },
      {
        plugin: new AppUsagePlugin(),
        privacyLevel: 'low',
        enabledByDefault: true,
        description: '追踪本应用使用时长和会话数'
      }
    ];
  }

  private pollAllPlugins(): void {
    for (let i = 0; i < this.registrations.length; i++) {
      let reg = this.registrations[i];
      let enabled = this.enabledPlugins.get(reg.plugin.name) ?? reg.enabledByDefault;
      if (!enabled) continue;

      try {
        let snapshot = reg.plugin.getSnapshot();
        this.lastSnapshots.set(reg.plugin.name, snapshot);
      } catch (err) {
        this.log.warn(TAG, `Plugin poll failed: ${reg.plugin.name}: ${(err as Error).message}`);
      }
    }
  }

  private async loadPluginPreferences(): Promise<void> {
    if (!this.prefsStore) return;

    for (let i = 0; i < this.registrations.length; i++) {
      let reg = this.registrations[i];
      let key = `plugin_${reg.plugin.name}_enabled`;
      try {
        let stored = await this.prefsStore.get(key, reg.enabledByDefault);
        this.enabledPlugins.set(reg.plugin.name, stored as boolean);
      } catch {
        this.enabledPlugins.set(reg.plugin.name, reg.enabledByDefault);
      }
    }
  }

  private async savePluginPreference(pluginName: string, enabled: boolean): Promise<void> {
    if (!this.prefsStore) return;
    let key = `plugin_${pluginName}_enabled`;
    try {
      await this.prefsStore.put(key, enabled);
      await this.prefsStore.flush();
    } catch {
      // ignore
    }
  }

  private getEnabledCount(): number {
    let count = 0;
    this.enabledPlugins.forEach((enabled: boolean) => {
      if (enabled) count++;
    });
    return count;
  }
}

/** Status info for UI display */
export interface PluginStatusInfo {
  name: string;
  description: string;
  privacyLevel: string;
  enabled: boolean;
  hasData: boolean;
}
