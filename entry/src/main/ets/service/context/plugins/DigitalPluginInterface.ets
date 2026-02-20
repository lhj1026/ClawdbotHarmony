/**
 * Digital World Plugin Interface
 *
 * All digital perception plugins implement this interface.
 * Each plugin provides a snapshot of digital-world state
 * that gets merged into the ContextSnapshot for the engine.
 */
import { common } from '@kit.AbilityKit';

/** Snapshot produced by a digital plugin */
export interface DigitalSnapshot {
  pluginName: string;
  timestamp: number;
  data: Record<string, string>;  // key-value pairs to merge into ContextSnapshot
}

/** Base interface for all digital world plugins */
export interface DigitalPlugin {
  /** Human-readable name for logging */
  name: string;

  /** Initialize the plugin with UIAbility context */
  init(context: common.UIAbilityContext): Promise<void>;

  /** Get a snapshot of current digital state */
  getSnapshot(): DigitalSnapshot;

  /** Cleanup resources */
  destroy(): void;
}

/** Privacy level for categorizing plugin sensitivity */
export type PrivacyLevel = 'low' | 'medium' | 'high' | 'critical';

/** Plugin registration metadata */
export interface PluginRegistration {
  plugin: DigitalPlugin;
  privacyLevel: PrivacyLevel;
  enabledByDefault: boolean;
  description: string;
}
