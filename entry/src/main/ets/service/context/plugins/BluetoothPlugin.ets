/**
 * BluetoothPlugin — Detect Bluetooth state and connected devices
 *
 * Uses @kit.ConnectivityKit (ble, access) to check Bluetooth on/off,
 * connected device count, and whether an audio device (headphones/speaker)
 * is connected via Bluetooth.
 *
 * Provides: bt_enabled, bt_connected_count, bt_audio_connected, bt_device_names
 *
 * Permission: ohos.permission.ACCESS_BLUETOOTH
 * API: @kit.ConnectivityKit — access, ble, connection
 */
import { access, connection } from '@kit.ConnectivityKit';
import { common } from '@kit.AbilityKit';
import { LogService } from '../../../common/LogService';
import { DigitalPlugin, DigitalSnapshot } from './DigitalPluginInterface';

const TAG = 'BluetoothPlugin';

/** Major device class values for audio devices */
const MAJOR_AUDIO_VIDEO = 0x0400;

export class BluetoothPlugin implements DigitalPlugin {
  name: string = 'bluetooth';
  private log: LogService = LogService.getInstance();
  private btEnabled: boolean = false;
  private connectedCount: number = 0;
  private audioConnected: boolean = false;
  private deviceNames: string[] = [];
  private stateChangeRegistered: boolean = false;

  async init(_context: common.UIAbilityContext): Promise<void> {
    this.refreshState();
    this.registerStateListener();
    this.log.info(TAG, `Init: enabled=${this.btEnabled}, connected=${this.connectedCount}`);
  }

  getSnapshot(): DigitalSnapshot {
    // Refresh on each poll for up-to-date data
    this.refreshState();

    let names = '';
    for (let i = 0; i < this.deviceNames.length; i++) {
      if (i > 0) names += ', ';
      names += this.deviceNames[i];
    }

    let data: Record<string, string> = {
      'bt_enabled': this.btEnabled ? 'true' : 'false',
      'bt_connected_count': this.connectedCount.toString(),
      'bt_audio_connected': this.audioConnected ? 'true' : 'false',
      'bt_device_names': names
    };

    return {
      pluginName: this.name,
      timestamp: Date.now(),
      data: data
    };
  }

  destroy(): void {
    this.unregisterStateListener();
    this.log.info(TAG, 'Destroyed');
  }

  private refreshState(): void {
    // Check if Bluetooth is enabled
    try {
      let state = access.getState();
      this.btEnabled = (state === access.BluetoothState.STATE_ON ||
        state === access.BluetoothState.STATE_TURNING_ON);
    } catch {
      this.btEnabled = false;
    }

    if (!this.btEnabled) {
      this.connectedCount = 0;
      this.audioConnected = false;
      this.deviceNames = [];
      return;
    }

    // Get paired (bonded) devices and check which are connected
    this.refreshConnectedDevices();
  }

  private refreshConnectedDevices(): void {
    let names: string[] = [];
    let audioFound = false;
    let count = 0;

    try {
      // Get paired devices — profiles like A2DP show connected state
      let pairedDevices = connection.getPairedDevices();
      for (let i = 0; i < pairedDevices.length; i++) {
        let addr = pairedDevices[i];
        try {
          let remoteDevice = connection.getRemoteDeviceClass(addr);
          let deviceName = connection.getRemoteDeviceName(addr);

          // Check if device has audio major class
          if (remoteDevice && remoteDevice.majorClass === MAJOR_AUDIO_VIDEO) {
            audioFound = true;
          }

          if (deviceName && deviceName.length > 0) {
            names.push(deviceName);
          }
          count++;
        } catch {
          // Device info unavailable, skip
          count++;
        }
      }
    } catch {
      // getPairedDevices failed, leave defaults
    }

    this.connectedCount = count;
    this.audioConnected = audioFound;
    this.deviceNames = names;
  }

  private registerStateListener(): void {
    try {
      access.on('stateChange', (data: access.BluetoothState) => {
        this.btEnabled = (data === access.BluetoothState.STATE_ON);
        if (!this.btEnabled) {
          this.connectedCount = 0;
          this.audioConnected = false;
          this.deviceNames = [];
        }
      });
      this.stateChangeRegistered = true;
    } catch (err) {
      this.log.warn(TAG, `Failed to register BT state listener: ${(err as Error).message}`);
    }
  }

  private unregisterStateListener(): void {
    if (!this.stateChangeRegistered) return;
    try {
      access.off('stateChange');
      this.stateChangeRegistered = false;
    } catch {
      // ignore
    }
  }
}
