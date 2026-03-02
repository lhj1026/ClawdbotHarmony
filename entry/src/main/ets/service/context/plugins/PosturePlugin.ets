/**
 * PosturePlugin — Detect phone posture via low-power sensors
 *
 * Uses proximity sensor + ambient light sensor to determine:
 * - in_use: screen-facing user (proximity far, good light, phone tilted)
 * - on_desk: phone lying flat on desk (proximity far, light, phone flat)
 * - in_pocket: proximity near + dark
 * - face_down: proximity near + not dark (face-down on surface)
 * - unknown: can't determine
 *
 * Low power: no camera needed, uses hardware sensors only.
 *
 * Provides: phone_posture, ambient_brightness, proximity
 */
import { sensor } from '@kit.SensorServiceKit';
import { common } from '@kit.AbilityKit';
import { LogService } from '../../../common/LogService';
import { DigitalPlugin, DigitalSnapshot } from './DigitalPluginInterface';

const TAG = 'PosturePlugin';

export class PosturePlugin implements DigitalPlugin {
  name: string = 'posture';
  private log: LogService = LogService.getInstance();
  private posture: string = 'unknown';
  private proximityNear: boolean = false;
  private ambientLux: number = -1;
  private proxRegistered: boolean = false;
  private lightRegistered: boolean = false;

  async init(_context: common.UIAbilityContext): Promise<void> {
    this.subscribeProximity();
    this.subscribeLight();
    this.log.info(TAG, `Init: proximity=${this.proxRegistered}, light=${this.lightRegistered}`);
  }

  getSnapshot(): DigitalSnapshot {
    this.classifyPosture();

    let data: Record<string, string> = {
      'phone_posture': this.posture,
      'ambient_brightness': this.ambientLux >= 0 ? this.ambientLux.toFixed(0) : 'unknown',
      'proximity': this.proximityNear ? 'near' : 'far'
    };

    return {
      pluginName: this.name,
      timestamp: Date.now(),
      data: data
    };
  }

  destroy(): void {
    if (this.proxRegistered) {
      try { sensor.off(sensor.SensorId.PROXIMITY); } catch { /* ignore */ }
    }
    if (this.lightRegistered) {
      try { sensor.off(sensor.SensorId.AMBIENT_LIGHT); } catch { /* ignore */ }
    }
    this.log.info(TAG, 'Destroyed');
  }

  private classifyPosture(): void {
    if (this.ambientLux < 0) {
      this.posture = 'unknown';
      return;
    }

    if (this.proximityNear) {
      // Something close to the screen
      if (this.ambientLux < 5) {
        this.posture = 'in_pocket';    // dark + near = pocket
      } else {
        this.posture = 'face_down';    // near + some light = face down on surface
      }
    } else {
      // Screen exposed (no proximity)
      if (this.ambientLux < 10) {
        // 暗环境：可能在口袋或桌上
        // 桌上通常有微弱光线(1-10 lux)，完全黑暗(<1)更可能是口袋
        if (this.ambientLux < 1) {
          this.posture = 'in_pocket';  // 完全黑暗 = 口袋
        } else {
          this.posture = 'on_desk';    // 微光 = 桌上(暗室)
        }
      } else if (this.ambientLux < 50) {
        this.posture = 'on_desk';      // dim environment, phone idle
      } else {
        this.posture = 'in_use';       // bright, screen facing up/user
      }
    }
  }

  private subscribeProximity(): void {
    try {
      sensor.on(sensor.SensorId.PROXIMITY, (data: sensor.ProximityResponse) => {
        this.proximityNear = data.distance === 0;
      }, { interval: 10000000000 }); // 10s
      this.proxRegistered = true;
    } catch (err) {
      this.log.warn(TAG, `Proximity sensor unavailable: ${(err as Error).message}`);
    }
  }

  private subscribeLight(): void {
    try {
      sensor.on(sensor.SensorId.AMBIENT_LIGHT, (data: sensor.LightResponse) => {
        this.ambientLux = data.intensity;
      }, { interval: 10000000000 }); // 10s
      this.lightRegistered = true;
    } catch (err) {
      this.log.warn(TAG, `Light sensor unavailable: ${(err as Error).message}`);
    }
  }
}
