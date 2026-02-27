/**
 * BluetoothPlugin — Detect Bluetooth state, connected devices, and classify them
 *
 * Uses @kit.ConnectivityKit (ble, access) to check Bluetooth on/off,
 * connected device count, and whether an audio device (headphones/speaker)
 * is connected via Bluetooth.
 *
 * Device classification:
 *   - fixed:    speakers, soundbars, set-top boxes → associate with geofence
 *   - portable: headphones, wearables → skip geofence association
 *   - vehicle:  car audio, handsfree → set inVehicle flag
 *
 * Provides: bt_enabled, bt_connected_count, bt_audio_connected, bt_device_names,
 *           bt_fixed_devices, bt_portable_devices, bt_vehicle_devices, bt_in_vehicle
 *
 * Permission: ohos.permission.ACCESS_BLUETOOTH
 * API: @kit.ConnectivityKit — access, ble, connection
 */
import { access, connection } from '@kit.ConnectivityKit';
import { common } from '@kit.AbilityKit';
import { LogService } from '../../../common/LogService';
import { DigitalPlugin, DigitalSnapshot } from './DigitalPluginInterface';
import { DeviceMobility, BT_MINOR_CLASS } from '../../context/ContextModels';

const TAG = 'BluetoothPlugin';

/** Major device class values */
const MAJOR_AUDIO_VIDEO = 0x0400;
const MAJOR_WEARABLE = 0x0700;

/** Fixed device minor classes (speakers, soundbars, set-top boxes) */
const FIXED_MINOR_CLASSES: number[] = [
  BT_MINOR_CLASS['LOUDSPEAKER'],
  BT_MINOR_CLASS['HIFI_AUDIO'],
  BT_MINOR_CLASS['SET_TOP_BOX'],
  BT_MINOR_CLASS['VIDEO_DISPLAY_LOUDSPEAKER'],
];

/** Portable device minor classes (headphones, wearables) */
const PORTABLE_MINOR_CLASSES: number[] = [
  BT_MINOR_CLASS['WEARABLE_HEADSET'],
  BT_MINOR_CLASS['HEADPHONES'],
  BT_MINOR_CLASS['PORTABLE_AUDIO'],
];

/** Vehicle device minor classes (car audio, handsfree) */
const VEHICLE_MINOR_CLASSES: number[] = [
  BT_MINOR_CLASS['CAR_AUDIO'],
  BT_MINOR_CLASS['HANDSFREE'],
];

export class BluetoothPlugin implements DigitalPlugin {
  name: string = 'bluetooth';
  private log: LogService = LogService.getInstance();
  private btEnabled: boolean = false;
  private connectedCount: number = 0;
  private audioConnected: boolean = false;
  private deviceNames: string[] = [];
  private stateChangeRegistered: boolean = false;

  // Device classification arrays
  private fixedDeviceNames: string[] = [];
  private portableDeviceNames: string[] = [];
  private vehicleDeviceNames: string[] = [];
  private inVehicle: boolean = false;

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

    let fixedStr = '';
    for (let i = 0; i < this.fixedDeviceNames.length; i++) {
      if (i > 0) fixedStr += ', ';
      fixedStr += this.fixedDeviceNames[i];
    }

    let portableStr = '';
    for (let i = 0; i < this.portableDeviceNames.length; i++) {
      if (i > 0) portableStr += ', ';
      portableStr += this.portableDeviceNames[i];
    }

    let vehicleStr = '';
    for (let i = 0; i < this.vehicleDeviceNames.length; i++) {
      if (i > 0) vehicleStr += ', ';
      vehicleStr += this.vehicleDeviceNames[i];
    }

    let data: Record<string, string> = {
      'bt_enabled': this.btEnabled ? 'true' : 'false',
      'bt_connected_count': this.connectedCount.toString(),
      'bt_audio_connected': this.audioConnected ? 'true' : 'false',
      'bt_device_names': names,
      'bt_fixed_devices': fixedStr,
      'bt_portable_devices': portableStr,
      'bt_vehicle_devices': vehicleStr,
      'bt_in_vehicle': this.inVehicle ? 'true' : 'false',
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

  /**
   * Classify a BT device by its majorMinorClass code.
   * majorClass = top bits (e.g. 0x0400=Audio/Video, 0x0700=Wearable)
   * majorMinorClass combines major + minor in one value.
   */
  classifyDevice(majorMinorClass: number): DeviceMobility {
    // Check major class first: wearable major → portable
    let majorClass = majorMinorClass & 0x1F00;
    if (majorClass === MAJOR_WEARABLE) {
      return 'portable';
    }

    // Check against known minor class tables
    for (let i = 0; i < VEHICLE_MINOR_CLASSES.length; i++) {
      if (majorMinorClass === VEHICLE_MINOR_CLASSES[i]) return 'vehicle';
    }
    for (let i = 0; i < FIXED_MINOR_CLASSES.length; i++) {
      if (majorMinorClass === FIXED_MINOR_CLASSES[i]) return 'fixed';
    }
    for (let i = 0; i < PORTABLE_MINOR_CLASSES.length; i++) {
      if (majorMinorClass === PORTABLE_MINOR_CLASSES[i]) return 'portable';
    }

    return 'unknown';
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
      this.fixedDeviceNames = [];
      this.portableDeviceNames = [];
      this.vehicleDeviceNames = [];
      this.inVehicle = false;
      return;
    }

    // Get paired (bonded) devices and check which are connected
    this.refreshConnectedDevices();
  }

  private refreshConnectedDevices(): void {
    let names: string[] = [];
    let audioFound = false;
    let count = 0;
    let fixed: string[] = [];
    let portable: string[] = [];
    let vehicle: string[] = [];
    let hasVehicle = false;

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

          let devName = (deviceName && deviceName.length > 0) ? deviceName : addr;
          names.push(devName);

          // Classify device
          if (remoteDevice) {
            let mobility = this.classifyDevice(remoteDevice.majorMinorClass);
            switch (mobility) {
              case 'fixed':
                fixed.push(devName);
                break;
              case 'portable':
                portable.push(devName);
                break;
              case 'vehicle':
                vehicle.push(devName);
                hasVehicle = true;
                break;
              default:
                // unknown — don't classify
                break;
            }
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
    this.fixedDeviceNames = fixed;
    this.portableDeviceNames = portable;
    this.vehicleDeviceNames = vehicle;
    this.inVehicle = hasVehicle;

    if (fixed.length > 0 || vehicle.length > 0) {
      this.log.info(TAG, `BT classified: fixed=[${fixed.join(',')}] vehicle=[${vehicle.join(',')}] portable=[${portable.join(',')}]`);
    }
  }

  private registerStateListener(): void {
    try {
      access.on('stateChange', (data: access.BluetoothState) => {
        this.btEnabled = (data === access.BluetoothState.STATE_ON);
        if (!this.btEnabled) {
          this.connectedCount = 0;
          this.audioConnected = false;
          this.deviceNames = [];
          this.fixedDeviceNames = [];
          this.portableDeviceNames = [];
          this.vehicleDeviceNames = [];
          this.inVehicle = false;
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
