/**
 * StepCounterPlugin — Read pedometer sensor data
 *
 * Uses @kit.SensorServiceKit (sensor) to subscribe to pedometer events
 * and track today's step count. Detects if user is actively walking
 * based on step count changes between polls.
 *
 * Provides: step_count_today, is_active
 *
 * Permission: ohos.permission.ACTIVITY_MOTION, ohos.permission.ACCELEROMETER (already declared)
 * API: @kit.SensorServiceKit — sensor
 */
import { sensor } from '@kit.SensorServiceKit';
import { common } from '@kit.AbilityKit';
import { LogService } from '../../../common/LogService';
import { DigitalPlugin, DigitalSnapshot } from './DigitalPluginInterface';

const TAG = 'StepCounterPlugin';

export class StepCounterPlugin implements DigitalPlugin {
  name: string = 'stepCounter';
  private log: LogService = LogService.getInstance();
  private stepCount: number = 0;
  private lastStepCount: number = 0;
  private isActive: boolean = false;
  private sensorRegistered: boolean = false;

  async init(_context: common.UIAbilityContext): Promise<void> {
    this.subscribeSensor();
    this.log.info(TAG, 'Init: pedometer sensor subscribed');
  }

  getSnapshot(): DigitalSnapshot {
    // Determine activity: steps changed since last snapshot
    this.isActive = (this.stepCount > this.lastStepCount);
    this.lastStepCount = this.stepCount;

    let data: Record<string, string> = {
      'step_count_today': this.stepCount.toString(),
      'is_active': this.isActive ? 'true' : 'false'
    };

    return {
      pluginName: this.name,
      timestamp: Date.now(),
      data: data
    };
  }

  destroy(): void {
    this.unsubscribeSensor();
    this.log.info(TAG, 'Destroyed');
  }

  private subscribeSensor(): void {
    try {
      sensor.on(sensor.SensorId.PEDOMETER, (data: sensor.PedometerResponse) => {
        if (data && data.steps >= 0) {
          this.stepCount = data.steps;
        }
      }, { interval: 5000000000 }); // 5 second interval in nanoseconds
      this.sensorRegistered = true;
    } catch (err) {
      this.log.warn(TAG, `Pedometer sensor unavailable: ${(err as Error).message}`);
      this.sensorRegistered = false;
    }
  }

  private unsubscribeSensor(): void {
    if (!this.sensorRegistered) return;
    try {
      sensor.off(sensor.SensorId.PEDOMETER);
      this.sensorRegistered = false;
    } catch {
      // ignore
    }
  }
}
