/**
 * MediaStatePlugin — Detect current audio scene and output device
 *
 * Uses audio.getAudioManager() to check the audio scene (default, ringing,
 * phone call, voice chat) and audio routing (speaker, headphones, bluetooth).
 * Does NOT require system permissions — only reads audio scene info.
 *
 * Provides: audioScene, audioDevice, inCall, mediaActive
 *
 * Permission: None required
 * API: @kit.AudioKit — audio
 */
import { audio } from '@kit.AudioKit';
import { common } from '@kit.AbilityKit';
import { LogService } from '../../../common/LogService';
import { DigitalPlugin, DigitalSnapshot } from './DigitalPluginInterface';

const TAG = 'MediaStatePlugin';

export class MediaStatePlugin implements DigitalPlugin {
  name: string = 'mediaState';
  private log: LogService = LogService.getInstance();
  private audioManager: audio.AudioManager | undefined;
  private lastScene: string = 'default';
  private lastDevice: string = 'speaker';

  async init(_context: common.UIAbilityContext): Promise<void> {
    try {
      this.audioManager = audio.getAudioManager();
      await this.refreshState();
      this.log.info(TAG, `Init: scene=${this.lastScene}, device=${this.lastDevice}`);
    } catch (err) {
      this.log.warn(TAG, `Init failed: ${(err as Error).message}`);
    }
  }

  getSnapshot(): DigitalSnapshot {
    // Refresh state synchronously if possible
    this.refreshStateSync();

    let inCall = this.lastScene === 'phone_call' || this.lastScene === 'voice_chat';
    let isRinging = this.lastScene === 'ringing';

    let data: Record<string, string> = {
      'audio_scene': this.lastScene,
      'audio_device': this.lastDevice,
      'audio_inCall': inCall ? 'true' : 'false',
      'audio_ringing': isRinging ? 'true' : 'false',
      'audio_headphones': this.isHeadphonesConnected() ? 'true' : 'false'
    };

    return {
      pluginName: this.name,
      timestamp: Date.now(),
      data: data
    };
  }

  destroy(): void {
    this.audioManager = undefined;
    this.log.info(TAG, 'Destroyed');
  }

  private async refreshState(): Promise<void> {
    if (!this.audioManager) return;
    try {
      let scene = await this.audioManager.getAudioScene();
      this.lastScene = this.sceneToString(scene);
    } catch {
      this.lastScene = 'default';
    }
    this.refreshDevice();
  }

  private refreshStateSync(): void {
    // Audio scene requires async call; use cached value + fire refresh
    if (this.audioManager) {
      this.refreshState(); // fire-and-forget
    }
    this.refreshDevice();
  }

  private refreshDevice(): void {
    if (!this.audioManager) return;
    try {
      let routingManager = this.audioManager.getRoutingManager();
      let devices = routingManager.getDevicesSync(audio.DeviceFlag.OUTPUT_DEVICES_FLAG);
      if (devices.length > 0) {
        this.lastDevice = this.deviceToString(devices[0].deviceType);
      }
    } catch {
      this.lastDevice = 'speaker';
    }
  }

  private isHeadphonesConnected(): boolean {
    return this.lastDevice === 'wired_headset' ||
      this.lastDevice === 'wired_headphones' ||
      this.lastDevice === 'bluetooth_a2dp' ||
      this.lastDevice === 'bluetooth_sco' ||
      this.lastDevice === 'usb_headset';
  }

  private sceneToString(scene: audio.AudioScene): string {
    switch (scene) {
      case audio.AudioScene.AUDIO_SCENE_DEFAULT:
        return 'default';
      case audio.AudioScene.AUDIO_SCENE_RINGING:
        return 'ringing';
      case audio.AudioScene.AUDIO_SCENE_PHONE_CALL:
        return 'phone_call';
      case audio.AudioScene.AUDIO_SCENE_VOICE_CHAT:
        return 'voice_chat';
      default:
        return 'default';
    }
  }

  private deviceToString(deviceType: audio.DeviceType): string {
    switch (deviceType) {
      case audio.DeviceType.SPEAKER:
        return 'speaker';
      case audio.DeviceType.WIRED_HEADSET:
        return 'wired_headset';
      case audio.DeviceType.WIRED_HEADPHONES:
        return 'wired_headphones';
      case audio.DeviceType.BLUETOOTH_A2DP:
        return 'bluetooth_a2dp';
      case audio.DeviceType.BLUETOOTH_SCO:
        return 'bluetooth_sco';
      case audio.DeviceType.USB_HEADSET:
        return 'usb_headset';
      case audio.DeviceType.EARPIECE:
        return 'earpiece';
      default:
        return 'speaker';
    }
  }
}
