/**
 * WearablePlugin — Collect wearable device sensor data
 *
 * Reads heart rate sensor data to detect physiological state:
 * - Resting (< 80 bpm)
 * - Active (80-120 bpm)
 * - Exercise (> 120 bpm)
 * - Stressed (elevated but not exercising)
 *
 * Combined with StepCounterPlugin data, provides rich activity context.
 *
 * Provides: heart_rate, heart_rate_status, wearing_state
 *
 * Permission: ohos.permission.READ_HEALTH_DATA (needs declaration)
 * API: @kit.SensorServiceKit — sensor.SensorId.HEART_RATE
 */
import { sensor } from '@kit.SensorServiceKit';
import { common } from '@kit.AbilityKit';
import { LogService } from '../../../common/LogService';
import { DigitalPlugin, DigitalSnapshot } from './DigitalPluginInterface';

const TAG = 'WearablePlugin';

export class WearablePlugin implements DigitalPlugin {
  name: string = 'wearable';
  private log: LogService = LogService.getInstance();
  private heartRate: number = 0;
  private lastHeartRateTime: number = 0;
  private heartRateSensorRegistered: boolean = false;

  async init(_context: common.UIAbilityContext): Promise<void> {
    this.subscribeHeartRate();
    this.log.info(TAG, 'Init: wearable sensors subscribed');
  }

  getSnapshot(): DigitalSnapshot {
    let status = this.getHeartRateStatus();
    let wearing = this.isWearing();

    let data: Record<string, string> = {
      'heart_rate': this.heartRate.toString(),
      'heart_rate_status': status,
      'wearing_state': wearing ? 'on_wrist' : 'off_wrist',
      'heart_rate_age_sec': this.getHeartRateAgeSec().toString()
    };

    return {
      pluginName: this.name,
      timestamp: Date.now(),
      data: data
    };
  }

  destroy(): void {
    this.unsubscribeAll();
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
    // If we got a heart rate reading in the last 2 minutes, device is on wrist
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

  private subscribeHeartRate(): void {
    try {
      sensor.on(sensor.SensorId.HEART_RATE, (data: sensor.HeartRateResponse) => {
        if (data && data.heartRate > 0) {
          this.heartRate = data.heartRate;
          this.lastHeartRateTime = Date.now();
        }
      }, { interval: 10000000000 }); // 10 second interval in nanoseconds
      this.heartRateSensorRegistered = true;
      this.log.info(TAG, 'Heart rate sensor subscribed');
    } catch (err) {
      this.log.warn(TAG, `Heart rate sensor unavailable: ${(err as Error).message}`);
      this.heartRateSensorRegistered = false;
    }
  }

  private unsubscribeAll(): void {
    if (this.heartRateSensorRegistered) {
      try {
        sensor.off(sensor.SensorId.HEART_RATE);
        this.heartRateSensorRegistered = false;
      } catch {
        // ignore
      }
    }
  }
}
