/**
 * PosturePlugin — Detect phone posture via low-power sensors
 *
 * Uses proximity sensor + ambient light sensor + accelerometer to determine:
 * - in_use: screen-facing user (phone tilted, good light)
 * - on_desk: phone lying flat on desk (phone flat, light)
 * - in_pocket: proximity near + dark
 * - face_down: proximity near + not dark (face-down on surface)
 * - face_up: phone flat + dark/low light
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
  private accelZ: number = 0;
  private tiltAngle: number = 0;  // 倾斜角度（0°=平放，90°=垂直）
  private proxRegistered: boolean = false;
  private lightRegistered: boolean = false;
  private accelRegistered: boolean = false;

  async init(_context: common.UIAbilityContext): Promise<void> {
    this.subscribeProximity();
    this.subscribeLight();
    this.subscribeAccelerometer();
    this.log.info(TAG, `Init: proximity=${this.proxRegistered}, light=${this.lightRegistered}, accel=${this.accelRegistered}`);
  }

  getSnapshot(): DigitalSnapshot {
    this.classifyPosture();

    let data: Record<string, string> = {
      'phone_posture': this.posture,
      'ambient_brightness': this.ambientLux >= 0 ? this.ambientLux.toFixed(0) : 'unknown',
      'proximity': this.proximityNear ? 'near' : 'far',
      'tilt_angle': this.tiltAngle.toFixed(1),
      'is_flat': this.isPhoneFlat() ? 'true' : 'false'
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
    if (this.accelRegistered) {
      try { sensor.off(sensor.SensorId.ACCELEROMETER); } catch { /* ignore */ }
    }
    this.log.info(TAG, 'Destroyed');
  }

  /**
   * 判断手机是否平放
   * 平放：|z| 接近 9.8 m/s²（重力），允许 ±2 误差
   */
  private isPhoneFlat(): boolean {
    return Math.abs(Math.abs(this.accelZ) - 9.8) < 2.0;
  }

  private classifyPosture(): void {
    if (this.ambientLux < 0) {
      this.posture = 'unknown';
      return;
    }

    let isFlat = this.isPhoneFlat();

    if (this.proximityNear) {
      // Something close to the screen
      if (this.ambientLux < 5) {
        this.posture = 'in_pocket';    // dark + near = pocket
      } else {
        this.posture = 'face_down';    // near + some light = face down on surface
      }
    } else {
      // Screen exposed (proximity=far) — 不可能是口袋
      // 口袋必须 proximity=near，仅凭黑暗不能判断为口袋

      if (isFlat) {
        // 手机平放
        if (this.ambientLux < 10) {
          this.posture = 'face_up';    // 暗室 + 平放
        } else {
          this.posture = 'on_desk';    // 有光 + 平放
        }
      } else {
        // 手机倾斜（手握）
        if (this.ambientLux < 10) {
          // 暗室 + 手握 → 可能在床上躺着看手机
          this.posture = 'in_use';     // 仍在使用中
        } else {
          this.posture = 'in_use';     // 正常光线 + 手握 = 使用中
        }
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

  private subscribeAccelerometer(): void {
    try {
      sensor.on(sensor.SensorId.ACCELEROMETER, (data: sensor.AccelerometerResponse) => {
        this.accelZ = data.z;
        // 计算倾斜角度：atan2(z, sqrt(x²+y²)) * 180/π
        let magnitude = Math.sqrt(data.x * data.x + data.y * data.y + data.z * data.z);
        this.tiltAngle = Math.atan2(data.z, Math.sqrt(data.x * data.x + data.y * data.y)) * 180 / Math.PI;
      }, { interval: 1000000000 }); // 1s，低频采样节省电量
      this.accelRegistered = true;
    } catch (err) {
      this.log.warn(TAG, `Accelerometer unavailable: ${(err as Error).message}`);
    }
  }
}
