/**
 * StepCounterPlugin — Read pedometer sensor data
 *
 * Uses @kit.SensorServiceKit (sensor) to subscribe to pedometer events
 * and track today's step count. Detects if user is actively walking
 * based on step count changes between polls.
 *
 * The pedometer sensor returns cumulative steps since boot.
 * We persist a daily baseline in preferences to calculate today's steps
 * even across app restarts.
 *
 * Provides: step_count_today, is_active
 *
 * Permission: ohos.permission.ACTIVITY_MOTION, ohos.permission.ACCELEROMETER (already declared)
 * API: @kit.SensorServiceKit — sensor
 */
import { sensor } from '@kit.SensorServiceKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { LogService } from '../../../common/LogService';
import { DigitalPlugin, DigitalSnapshot } from './DigitalPluginInterface';

const TAG = 'StepCounterPlugin';
const PREFS_NAME = 'step_counter_prefs';

export class StepCounterPlugin implements DigitalPlugin {
  name: string = 'stepCounter';
  private log: LogService = LogService.getInstance();
  private rawSteps: number = 0;           // cumulative since boot
  private baselineSteps: number = -1;     // baseline for today
  private baselineDate: string = '';       // YYYY-MM-DD of baseline
  private lastSnapshotSteps: number = 0;
  private isActive: boolean = false;
  private sensorRegistered: boolean = false;
  private sensorCallback: ((data: sensor.PedometerResponse) => void) | undefined;
  private prefs: preferences.Preferences | undefined;

  async init(context: common.UIAbilityContext): Promise<void> {
    // Load persisted baseline
    try {
      this.prefs = await preferences.getPreferences(context, PREFS_NAME);
      this.baselineDate = await this.prefs.get('baselineDate', '') as string;
      this.baselineSteps = await this.prefs.get('baselineSteps', -1) as number;
      this.log.info(TAG, `Loaded baseline: date=${this.baselineDate}, steps=${this.baselineSteps}`);
    } catch (err) {
      this.log.warn(TAG, `Prefs load failed: ${(err as Error).message}`);
    }

    this.subscribeSensor();
    this.log.info(TAG, 'Init: pedometer sensor subscribed');
  }

  getSnapshot(): DigitalSnapshot {
    let todaySteps = this.getDailySteps();
    this.isActive = (todaySteps > this.lastSnapshotSteps);
    this.lastSnapshotSteps = todaySteps;

    let data: Record<string, string> = {
      'step_count_today': todaySteps.toString(),
      'is_active': this.isActive ? 'true' : 'false'
    };

    if (!this.sensorRegistered) {
      this.log.warn(TAG, 'Pedometer sensor not registered, step_count_today=0');
    } else if (this.baselineSteps < 0) {
      this.log.debug(TAG, 'Pedometer registered but no data yet (baseline not set)');
    }

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

  private getDailySteps(): number {
    if (this.baselineSteps < 0) return 0;
    let daily = this.rawSteps - this.baselineSteps;
    // If rawSteps < baseline, phone rebooted — reset baseline
    if (daily < 0) {
      this.baselineSteps = this.rawSteps;
      this.saveBaseline();
      return 0;
    }
    return daily;
  }

  private getTodayStr(): string {
    let d = new Date();
    let y = d.getFullYear().toString();
    let m = (d.getMonth() + 1).toString().padStart(2, '0');
    let day = d.getDate().toString().padStart(2, '0');
    return y + '-' + m + '-' + day;
  }

  private saveBaseline(): void {
    if (!this.prefs) return;
    try {
      this.prefs.putSync('baselineDate', this.baselineDate);
      this.prefs.putSync('baselineSteps', this.baselineSteps);
      this.prefs.flush().then(() => {
        this.log.debug(TAG, `Baseline saved: date=${this.baselineDate}, steps=${this.baselineSteps}`);
      }).catch((err: Error) => {
        this.log.warn(TAG, `Baseline flush failed: ${err.message}`);
      });
    } catch (err) {
      this.log.warn(TAG, `Baseline save failed: ${(err as Error).message}`);
    }
  }

  private subscribeSensor(): void {
    try {
      this.sensorCallback = (data: sensor.PedometerResponse) => {
        if (data && data.steps >= 0) {
          this.rawSteps = data.steps;

          let today = this.getTodayStr();
          if (this.baselineDate !== today) {
            // New day: reset baseline to current cumulative steps
            this.baselineSteps = data.steps;
            this.baselineDate = today;
            this.saveBaseline();
            this.log.info(TAG, `New day baseline: ${data.steps} steps (${today})`);
          } else if (this.baselineSteps < 0) {
            // First ever reading, no saved baseline
            this.baselineSteps = data.steps;
            this.saveBaseline();
            this.log.info(TAG, `Initial baseline: ${data.steps} steps`);
          }
        }
      };
      sensor.on(sensor.SensorId.PEDOMETER, this.sensorCallback, { interval: 5000000000 });
      this.sensorRegistered = true;
    } catch (err) {
      this.log.warn(TAG, `Pedometer sensor unavailable: ${(err as Error).message}`);
      this.sensorRegistered = false;
    }
  }

  private unsubscribeSensor(): void {
    if (!this.sensorRegistered) return;
    try {
      if (this.sensorCallback) {
        sensor.off(sensor.SensorId.PEDOMETER, this.sensorCallback);
      } else {
        sensor.off(sensor.SensorId.PEDOMETER);
      }
      this.sensorRegistered = false;
    } catch {
      // ignore
    }
  }
}
