/**
 * PhysicalStateBuilder.ets — 从 DataTray 构建 7-Tuple 物理状态
 *
 * 读取传感器数据，分类为 7 个离散维度:
 *   (time, location, motion, phone, light, sound, dayType)
 */
import DataTray, { DataTray as SensorDataTray } from './DataTray';
import {
  PhysicalState,
  TimeSlot,
  LocationCategory,
  MotionCategory,
  PhoneCategory,
  LightCategory,
  SoundCategory,
  DayType,
} from './ContextModels';
import { LogService } from '../../common/LogService';

const TAG = 'PhysicalStateBuilder';
const log = LogService.getInstance();

export class PhysicalStateBuilder {
  private static instance: PhysicalStateBuilder | null = null;
  private tray: SensorDataTray = DataTray;

  static getInstance(): PhysicalStateBuilder {
    if (!PhysicalStateBuilder.instance) {
      PhysicalStateBuilder.instance = new PhysicalStateBuilder();
    }
    return PhysicalStateBuilder.instance;
  }

  /**
   * 从 DataTray 构建 PhysicalState 7-tuple
   */
  build(): PhysicalState {
    let now = Date.now();
    return {
      time: this.classifyTime(),
      location: this.classifyLocation(),
      motion: this.classifyMotion(),
      phone: this.classifyPhone(),
      light: this.classifyLight(),
      sound: this.classifySound(),
      dayType: this.classifyDayType(),
      timestamp: now,
    };
  }

  // ==================== Dim 1: Time ====================

  private classifyTime(): TimeSlot {
    let hourStr = this.trayValue('hour');
    let hour = hourStr.length > 0 ? parseInt(hourStr) : new Date().getHours();
    let minute = new Date().getMinutes();
    let timeInMinutes = hour * 60 + minute;

    if (timeInMinutes < 300) return 'sleeping';         // 0:00-5:00
    if (timeInMinutes < 420) return 'dawn';             // 5:00-7:00
    if (timeInMinutes < 540) return 'morning';          // 7:00-9:00
    if (timeInMinutes < 690) return 'forenoon';         // 9:00-11:30
    if (timeInMinutes < 810) return 'lunch';            // 11:30-13:30
    if (timeInMinutes < 1020) return 'afternoon';       // 13:30-17:00
    if (timeInMinutes < 1170) return 'evening';         // 17:00-19:30
    if (timeInMinutes < 1320) return 'night';           // 19:30-22:00
    return 'late_night';                                 // 22:00-0:00
  }

  // ==================== Dim 2: Location ====================

  private classifyLocation(): LocationCategory {
    let wifiGeofence = this.trayValue('wifiGeofence');
    let motionState = this.trayValue('motionState');

    // WiFi geofence 直接映射
    if (wifiGeofence.length > 0) {
      switch (wifiGeofence) {
        case 'home': return 'home';
        case 'work': return 'work';
        case 'restaurant': return 'restaurant';
        case 'gym': return 'gym';
        case 'transit': return 'transit_hub';
        case 'shopping': return 'shopping';
        case 'cafe': return 'cafe';
        default: break;
      }
    }

    // 无围栏但在移动 → 通勤
    if (motionState === 'driving' || motionState === 'transit') {
      return 'commute';
    }
    if (motionState === 'walking' || motionState === 'cycling') {
      // 步行/骑车且无围栏 → 可能是通勤或户外
      let wifiSsid = this.trayValue('wifiSsid');
      if (wifiSsid.length === 0) {
        return 'outdoor';
      }
      return 'commute';
    }

    // 无 WiFi + 有 GPS → 户外
    let wifiSsid = this.trayValue('wifiSsid');
    let lat = this.trayValue('latitude');
    if (wifiSsid.length === 0 && lat.length > 0) {
      return 'outdoor';
    }

    return 'unknown';
  }

  // ==================== Dim 3: Motion ====================

  private classifyMotion(): MotionCategory {
    let motionState = this.trayValue('motionState');
    let transportMode = this.trayValue('transportMode');

    // transportMode 优先（如果有更精确的分类）
    if (transportMode === 'cycling') return 'cycling';

    switch (motionState) {
      case 'stationary': return 'stationary';
      case 'walking': return 'walking';
      case 'running': return 'running';
      case 'cycling': return 'cycling';
      case 'driving': return 'driving';
      case 'transit': return 'transit';
      default: return 'unknown';
    }
  }

  // ==================== Dim 4: Phone ====================

  private classifyPhone(): PhoneCategory {
    // 充电优先
    let isCharging = this.trayValue('isCharging');
    if (isCharging === 'true') return 'charging';

    // 方式 1: PosturePlugin 的 phone_posture 直接映射 (主要来源)
    // PosturePlugin 已通过 proximity + ambient_brightness + 倾斜角度分类
    let posture = this.trayValue('phone_posture');
    if (posture.length > 0 && posture !== 'unknown') {
      switch (posture) {
        case 'in_use': return 'in_use';
        case 'on_desk': return 'on_desk';
        case 'in_pocket': return 'in_pocket';
        case 'face_down': return 'face_down';
        case 'flat': return 'on_desk';
        case 'face_up': return 'on_desk';
        default: break;
      }
    }

    // 方式 2: 从 proximity + ambient_brightness 推断 (备用)
    let proximity = this.trayValue('proximity');
    let ambientLight = this.trayValueNum('ambient_brightness', -1);

    // 口袋必须 proximity=near；仅凭黑暗不能判断为口袋（可能是暗室躺着看手机）
    if (proximity === 'near' && ambientLight >= 0 && ambientLight < 5) return 'in_pocket';
    if (proximity === 'near' && ambientLight > 5) return 'face_down';
    if (ambientLight >= 0 && ambientLight < 10) return 'face_up'; // 暗室，屏幕朝上

    return 'unknown';
  }

  // ==================== Dim 5: Light ====================

  private classifyLight(): LightCategory {
    let ambientLight = this.trayValueNum('ambient_brightness', -1);
    if (ambientLight < 0) {
      // 无传感器数据时根据时间推断
      let time = this.classifyTime();
      if (time === 'sleeping' || time === 'late_night') return 'dark';
      if (time === 'dawn') return 'dim';
      return 'normal';
    }

    if (ambientLight < 5) return 'dark';
    if (ambientLight < 50) return 'dim';
    if (ambientLight < 500) return 'normal';
    return 'bright';
  }

  // ==================== Dim 6: Sound ====================

  private classifySound(): SoundCategory {
    // 方式 1: AmbientSoundPlugin 写入的 noise_level (字符串: quiet/normal/noisy)
    let noiseLevelStr = this.trayValue('noise_level');
    if (noiseLevelStr.length > 0 && noiseLevelStr !== 'unknown') {
      switch (noiseLevelStr) {
        case 'quiet': return 'quiet';
        case 'normal': return 'normal';
        case 'noisy': return 'noisy';
        default: break;
      }
    }

    // 方式 2: volume_db (数值 dB)
    let volumeDb = this.trayValueNum('volume_db', -1);
    if (volumeDb >= 0) {
      if (volumeDb < 25) return 'silent';
      if (volumeDb < 40) return 'quiet';
      if (volumeDb < 55) return 'normal';
      return 'noisy';
    }

    // 方式 3: sound_scene → 映射
    let soundScene = this.trayValue('sound_scene');
    if (soundScene.length > 0 && soundScene !== 'unknown') {
      switch (soundScene) {
        case 'silent': return 'silent';
        case 'office': return 'quiet';
        case 'outdoor': return 'normal';
        case 'traffic':
        case 'crowd': return 'noisy';
        default: break;
      }
    }

    return 'unknown';
  }

  // ==================== Dim 7: DayType ====================

  private classifyDayType(): DayType {
    let dayOfWeekStr = this.trayValue('dayOfWeek');
    let dayOfWeek = dayOfWeekStr.length > 0 ? parseInt(dayOfWeekStr) : new Date().getDay();

    // 检查日历中的假日标记
    let calHoliday = this.trayValue('cal_isHoliday');
    if (calHoliday === 'true') return 'holiday';

    // 周末
    if (dayOfWeek === 0 || dayOfWeek === 6) return 'weekend';

    return 'workday';
  }

  // ==================== Helper ====================

  private trayValue(key: string): string {
    let result = this.tray.get(key);
    if (result && result.value !== null && result.fresh) {
      return result.value;
    }
    // 即使不新鲜也返回值（某些慢更新的数据）
    if (result && result.value !== null) {
      return result.value;
    }
    return '';
  }

  private trayValueNum(key: string, defaultVal: number): number {
    let str = this.trayValue(key);
    if (str.length === 0) return defaultVal;
    let num = parseFloat(str);
    if (isNaN(num)) return defaultVal;
    return num;
  }

  /**
   * 将 PhysicalState 序列化为简短字符串 (用于日志/指纹)
   */
  static fingerprint(ps: PhysicalState): string {
    return `${ps.time}|${ps.location}|${ps.motion}|${ps.phone}|${ps.light}|${ps.sound}|${ps.dayType}`;
  }

  /**
   * 判断两个 PhysicalState 是否相同 (所有维度)
   */
  static equals(a: PhysicalState, b: PhysicalState): boolean {
    return a.time === b.time &&
      a.location === b.location &&
      a.motion === b.motion &&
      a.phone === b.phone &&
      a.light === b.light &&
      a.sound === b.sound &&
      a.dayType === b.dayType;
  }
}
