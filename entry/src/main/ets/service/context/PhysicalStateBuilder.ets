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

  // ── 主导状态算法：保留最近 6 次采样，50% 多数即确认 ──────────
  // 降低窗口大小+阈值，让走路状态更快被确认，减少 unknown 过渡
  private motionHistory: string[] = [];
  private lastConfirmedMotion: string = 'stationary'; // unknown 时回退到上次确认状态
  private static readonly MOTION_HISTORY_SIZE: number = 6;
  private static readonly MOTION_DOMINANT_RATIO: number = 0.5;

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

    // 无围栏但在移动 → 在途
    if (motionState === 'driving' || motionState === 'transit') {
      return 'en_route';
    }
    if (motionState === 'walking' || motionState === 'cycling') {
      // 步行/骑车且无围栏 → 可能在途或户外
      let wifiSsid = this.trayValue('wifiSsid');
      if (wifiSsid.length === 0) {
        return 'outdoor';
      }
      return 'en_route';
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
    let rawMotion: MotionCategory;
    if (transportMode === 'cycling') {
      rawMotion = 'cycling';
    } else {
      switch (motionState) {
        case 'stationary': rawMotion = 'stationary'; break;
        case 'walking':    rawMotion = 'walking';    break;
        case 'running':    rawMotion = 'running';    break;
        case 'cycling':    rawMotion = 'cycling';    break;
        case 'driving':    rawMotion = 'driving';    break;
        case 'transit':    rawMotion = 'transit';    break;
        default:           rawMotion = 'unknown';    break;
      }
    }

    // ── 主导状态算法：10 次采样 × 60% 多数才确认 ──────────────
    // 将原始分类加入历史窗口
    this.motionHistory.push(rawMotion);
    if (this.motionHistory.length > PhysicalStateBuilder.MOTION_HISTORY_SIZE) {
      this.motionHistory.shift();
    }

    let totalSamples = this.motionHistory.length;
    // 历史不足 3 帧时直接返回原始值（启动暖机阶段）
    if (totalSamples < 3) {
      return rawMotion;
    }

    // 统计每种状态出现次数
    let counts: Record<string, number> = {};
    for (let s of this.motionHistory) {
      counts[s] = (counts[s] ?? 0) + 1;
    }

    // 超过 50% 才确认为主导状态（'unknown' 不参与主导竞争，留作兜底）
    let candidates: MotionCategory[] = ['stationary', 'walking', 'running', 'cycling', 'driving', 'transit'];
    for (let s of candidates) {
      let cnt = counts[s] ?? 0;
      if (cnt / totalSamples >= PhysicalStateBuilder.MOTION_DOMINANT_RATIO) {
        this.lastConfirmedMotion = s;
        return s;
      }
    }

    // 无主导状态 → 回退到上次已知状态（避免显示"未知"抖动）
    return this.lastConfirmedMotion as MotionCategory;
  }

  // ==================== Dim 4: Phone ====================

  private classifyPhone(): PhoneCategory {
    // 充电优先
    let isCharging = this.trayValue('isCharging');
    if (isCharging === 'true') return 'charging';

    // 加速度计的躺卧/握持状态 (高可信度)
    let isLyingDown = this.trayValue('isLyingDown') === 'true';
    let isHolding = this.trayValue('isHolding') === 'true';

    // 运动中(走路/跑步/开车/公交)时人不可能躺着 → isLyingDown 实际是口袋倾斜
    let motionState = this.trayValue('motionState');
    let isMoving = motionState === 'walking' || motionState === 'running'
      || motionState === 'driving' || motionState === 'transit'
      || motionState === 'cycling';

    // proximity 提前声明（方式1和方式2都需要）
    let proximity = this.trayValue('proximity');
    let ambientLight = this.trayValueNum('ambient_brightness', -1);

    // 方式 1: PosturePlugin 的 phone_posture 直接映射 (主要来源)
    let posture = this.trayValue('phone_posture');
    if (posture.length > 0 && posture !== 'unknown') {
      // 关键规则：运动中(走路/跑步/开车)时，手机不可能平放在桌上
      // 如果运动状态非静止，且 PosturePlugin 判断为平放 → 纠正为携带状态
      if (isMoving && (posture === 'on_desk' || posture === 'flat' || posture === 'face_up')) {
        // 运动 + 平放判断 → 实际在口袋或手中
        if (proximity === 'near') return 'in_pocket';
        return 'in_use';  // 手中握持使用
      }

      switch (posture) {
        case 'in_use':
          // 运动中 + isLyingDown → 口袋（不是躺卧）
          if (isLyingDown && isMoving) return 'in_pocket';
          if (isLyingDown) return 'holding_lying';
          // PosturePlugin 仅凭光线判断 in_use，需交叉验证加速度计
          // isHolding=false 表示手机平放 → 实际在桌上，非手握使用
          if (!isHolding) return 'on_desk';
          return 'in_use';
        case 'on_desk':
        case 'flat':
          // 交叉验证：PosturePlugin 凭暗光判断在桌上，但加速度计显示手握 → 实际在使用
          if (isHolding) return 'in_use';
          return 'on_desk';
        case 'in_pocket': return 'in_pocket';
        case 'face_down': return 'face_down';
        case 'face_up':
          // 暗室 + 手握 + 躺卧 + 非运动 → 手握躺卧（暗室看手机）
          if (isLyingDown && isHolding && !isMoving) return 'holding_lying';
          // 运动中 + 暗 → 口袋
          if (isMoving) return 'in_pocket';
          return 'face_up';
        default: break;
      }
    }

    // 方式 2: 从 proximity + ambient_brightness 推断 (备用)

    // 运动中 + proximity=near → 口袋（放宽亮度要求）
    if (proximity === 'near' && isMoving) return 'in_pocket';

    // 口袋必须 proximity=near；仅凭黑暗不能判断为口袋（可能是暗室躺着看手机）
    if (proximity === 'near' && ambientLight >= 0 && ambientLight < 5) return 'in_pocket';
    if (proximity === 'near' && ambientLight > 5) return 'face_down';
    if (ambientLight >= 0 && ambientLight < 10) {
      // 暗室 + 运动中 → 口袋
      if (isMoving) return 'in_pocket';
      // 暗室：区分手握躺卧 vs 平放
      if (isLyingDown && isHolding) return 'holding_lying';
      return 'face_up';
    }

    // 运动中 + isLyingDown → 口袋（加速度计倾斜被误判为躺卧）
    if (isMoving && isLyingDown) return 'in_pocket';

    // 加速度计兜底：即使 PosturePlugin 未知，若能确定躺卧+握持也给出状态
    if (isLyingDown && isHolding) return 'holding_lying';

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
