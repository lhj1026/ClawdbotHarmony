/**
 * WearablePlugin — Collect wearable device health data
 *
 * Uses HarmonyOS Health Kit to read heart rate and step count data
 * synced from connected wearables (Huawei Watch/Band) via "运动健康" app.
 *
 * Falls back to sensor API if Health Kit is unavailable.
 *
 * Reads heart rate data to detect physiological state:
 * - Resting (< 80 bpm)
 * - Active (80-120 bpm)
 * - Exercise (> 120 bpm)
 *
 * Provides: heart_rate, heart_rate_status, wearing_state, device_connected, step_count
 *
 * Permission: ohos.permission.READ_HEALTH_DATA
 * API: @kit.HealthServiceKit — healthStore
 */
import { healthStore } from '@kit.HealthServiceKit';
import { sensor } from '@kit.SensorServiceKit';
import { common, abilityAccessCtrl } from '@kit.AbilityKit';
import { LogService } from '../../../common/LogService';
import { DigitalPlugin, DigitalSnapshot } from './DigitalPluginInterface';

const TAG = 'WearablePlugin';

export class WearablePlugin implements DigitalPlugin {
  name: string = 'wearable';
  private log: LogService = LogService.getInstance();
  private heartRate: number = 0;
  private lastHeartRateTime: number = 0;
  private stepCount: number = 0;
  private lastStepCountTime: number = 0;
  private wearableDeviceConnected: boolean = false;
  private deviceName: string = '';
  private initError: string = '';
  private context: common.UIAbilityContext | undefined;
  private useHealthKit: boolean = false;
  private healthKitTimer: number = -1;
  private static readonly HEALTH_KIT_POLL_MS = 30 * 1000; // 30s polling

  async init(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    this.log.info(TAG, 'Init: requesting health data permission...');

    let granted = await this.requestHealthPermission();
    if (granted) {
      // Try Health Kit (reads wearable data from 运动健康 app)
      let healthKitAvailable = await this.tryInitHealthKit();
      if (healthKitAvailable) {
        this.useHealthKit = true;
        this.startHealthKitPolling();
        this.log.info(TAG, 'Using Health Kit for wearable data');
        return;
      }
      this.log.info(TAG, 'Health Kit unavailable, falling back to sensor API');
    } else {
      // READ_HEALTH_DATA requires system_basic APL — normal签名不支持
      // 回退到手机内置心率传感器（只需 MOTION_SENSORS 权限）
      this.log.warn(TAG, 'Health Kit permission denied (APL insufficient), falling back to sensor API');
      this.initError = '';
    }

    // 传感器回退：手机自身的心率传感器
    this.subscribeHeartRateSensor();
    this.log.info(TAG, `Init complete: healthKit=${this.useHealthKit}, sensor fallback active`);
  }

  getSnapshot(): DigitalSnapshot {
    let status = this.getHeartRateStatus();
    let wearing = this.isWearing();

    let data: Record<string, string> = {
      'heart_rate': this.heartRate.toString(),
      'heart_rate_status': status,
      'wearing_state': wearing ? 'on_wrist' : 'off_wrist',
      'heart_rate_age_sec': this.getHeartRateAgeSec().toString(),
      'device_connected': this.wearableDeviceConnected ? 'true' : 'false',
      'device_name': this.deviceName,
      'step_count': this.stepCount.toString(),
      'data_source': this.useHealthKit ? 'health_kit' : 'sensor',
      'init_error': this.initError
    };

    return {
      pluginName: this.name,
      timestamp: Date.now(),
      data: data
    };
  }

  destroy(): void {
    if (this.healthKitTimer !== -1) {
      clearInterval(this.healthKitTimer);
      this.healthKitTimer = -1;
    }
    this.unsubscribeSensor();
    this.log.info(TAG, 'Destroyed');
  }

  private getHeartRateStatus(): string {
    if (this.heartRate <= 0) {
      return 'unknown';
    }
    if (this.heartRate < 60) {
      return 'low';
    }
    if (this.heartRate < 80) {
      return 'resting';
    }
    if (this.heartRate < 120) {
      return 'active';
    }
    return 'exercise';
  }

  private isWearing(): boolean {
    if (this.heartRate <= 0) {
      return false;
    }
    let ageSec = this.getHeartRateAgeSec();
    return ageSec < 120;
  }

  private getHeartRateAgeSec(): number {
    if (this.lastHeartRateTime <= 0) {
      return 9999;
    }
    return Math.floor((Date.now() - this.lastHeartRateTime) / 1000);
  }

  private async requestHealthPermission(): Promise<boolean> {
    if (!this.context) {
      this.log.warn(TAG, 'No context available for permission request');
      return false;
    }

    try {
      let atManager = abilityAccessCtrl.createAtManager();
      let result = await atManager.requestPermissionsFromUser(this.context, ['ohos.permission.READ_HEALTH_DATA']);
      let granted = result.authResults[0] === 0;
      this.log.info(TAG, `READ_HEALTH_DATA permission: ${granted ? 'granted' : 'denied'}`);
      return granted;
    } catch (err) {
      this.log.error(TAG, `Permission request error: ${(err as Error).message}`);
      return false;
    }
  }

  /**
   * Try to initialize Health Kit. Returns true if available.
   */
  private async tryInitHealthKit(): Promise<boolean> {
    try {
      let endTime = Date.now();
      let startTime = endTime - 60 * 1000;
      await healthStore.readData({
        samplePointDataType: healthStore.healthDataTypes.HEART_RATE,
        startTime: startTime,
        endTime: endTime
      });
      return true;
    } catch (err) {
      this.log.warn(TAG, `Health Kit init check failed: ${(err as Error).message}`);
      return false;
    }
  }

  /**
   * Poll Health Kit for latest heart rate and step count data.
   */
  private startHealthKitPolling(): void {
    this.readHealthKitData();

    this.healthKitTimer = setInterval(() => {
      this.readHealthKitData();
    }, WearablePlugin.HEALTH_KIT_POLL_MS);
  }

  private async readHealthKitData(): Promise<void> {
    let endTime = Date.now();
    let startTime = endTime - 5 * 60 * 1000; // last 5 minutes

    // Read heart rate
    try {
      let samples = await healthStore.readData({
        samplePointDataType: healthStore.healthDataTypes.HEART_RATE,
        startTime: startTime,
        endTime: endTime
      });
      if (samples && samples.length > 0) {
        let latest = samples[samples.length - 1];
        let hr = latest.fields?.['heartRate'] as number;
        if (hr && hr > 0) {
          this.heartRate = hr;
          this.lastHeartRateTime = latest.endTime ?? Date.now();
          if (!this.wearableDeviceConnected) {
            this.wearableDeviceConnected = true;
            this.deviceName = 'health_kit_wearable';
            this.log.info(TAG, `Health Kit heart rate: ${this.heartRate} bpm, wearable detected`);
          }
        }
      }
    } catch (err) {
      this.log.debug(TAG, `Health Kit HR read: ${(err as Error).message}`);
    }

    // Read step count (from DAILY_ACTIVITIES)
    try {
      let samples = await healthStore.readData({
        samplePointDataType: healthStore.healthDataTypes.DAILY_ACTIVITIES,
        startTime: startTime,
        endTime: endTime
      });
      if (samples && samples.length > 0) {
        let latest = samples[samples.length - 1];
        let steps = latest.fields?.['steps'] as number;
        if (steps && steps > 0) {
          this.stepCount = steps;
          this.lastStepCountTime = latest.endTime ?? Date.now();
        }
      }
    } catch (err) {
      this.log.debug(TAG, `Health Kit steps read: ${(err as Error).message}`);
    }
  }

  /**
   * Fallback: subscribe to phone's built-in heart rate sensor.
   */
  private subscribeHeartRateSensor(): void {
    try {
      sensor.on(sensor.SensorId.HEART_RATE, (data: sensor.HeartRateResponse) => {
        if (data && data.heartRate > 0) {
          this.heartRate = data.heartRate;
          this.lastHeartRateTime = Date.now();
          if (!this.wearableDeviceConnected) {
            this.wearableDeviceConnected = true;
            this.deviceName = 'phone_sensor';
            this.log.info(TAG, `Sensor heart rate: ${this.heartRate} bpm`);
          }
        }
      }, { interval: 10000000000 });
      this.log.info(TAG, 'Heart rate sensor subscribed (fallback)');
    } catch (err) {
      let errMsg = (err as Error).message;
      this.log.warn(TAG, `Heart rate sensor subscription failed: ${errMsg}`);
      this.initError = errMsg;
    }
  }

  private unsubscribeSensor(): void {
    try {
      sensor.off(sensor.SensorId.HEART_RATE);
    } catch {
      // ignore
    }
  }
}
