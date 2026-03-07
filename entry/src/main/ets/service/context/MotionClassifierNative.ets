/**
 * MotionClassifierNative.ets — C++ Motion Classifier NAPI 包装
 *
 * 调用 C++ 侧的高效运动状态分类和地点推断
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'MotionClassifierNative';

// ============================================================
// NAPI 声明
// ============================================================

declare class MotionClassifierBinding {
  // Z 轴特征提取
  static createZAxisExtractor(): object;
  static addZAxisSample(extractor: object, z: number, timestamp: number): void;
  static computeZAxisFeatures(extractor: object): ZAxisFeaturesResult;
  static classifyByZAxis(features: ZAxisFeaturesResult): string;
  
  // 地点推断
  static isTransitHub(geofenceId: string): boolean;
  static inferDrivingVsTransit(motionState: string, context: TransitInferenceContextResult): string;
}

interface ZAxisFeaturesResult {
  amplitude: number;
  frequency: number;
  variance: number;
  isValid: boolean;
}

interface TransitInferenceContextResult {
  prevGeofence: string;
  currentGeofence: string;
  geofenceDepartureTime: number;
  gpsSpeed: number;
}

// ============================================================
// Z 轴特征提取器包装
// ============================================================

export class ZAxisFeatureExtractor {
  private extractor: object;
  private log = hilog.isLoggable(0, TAG, hilog.LogLevel.INFO) ? hilog : null;
  
  constructor() {
    try {
      this.extractor = MotionClassifierBinding.createZAxisExtractor();
      this.log?.info(0, TAG, 'Z轴提取器创建成功');
    } catch (err) {
      this.log?.warn(0, TAG, `创建Z轴提取器失败: ${err}`);
      throw err;
    }
  }
  
  /**
   * 添加 Z 轴样本
   */
  addSample(z: number, timestamp: number): void {
    try {
      MotionClassifierBinding.addZAxisSample(this.extractor, z, timestamp);
    } catch (err) {
      this.log?.error(0, TAG, `addSample失败: ${err}`);
    }
  }
  
  /**
   * 计算特征（调用 C++ 侧）
   */
  computeFeatures(): ZAxisFeaturesResult {
    try {
      let result = MotionClassifierBinding.computeZAxisFeatures(this.extractor);
      return result;
    } catch (err) {
      this.log?.error(0, TAG, `computeFeatures失败: ${err}`);
      return {
        amplitude: 0,
        frequency: 0,
        variance: 0,
        isValid: false
      };
    }
  }
  
  /**
   * 根据特征分类（调用 C++ 侧）
   */
  static classifyByZAxis(features: ZAxisFeaturesResult): string {
    try {
      return MotionClassifierBinding.classifyByZAxis(features);
    } catch (err) {
      hilog.warn(0, TAG, `分类失败: ${err}`);
      return 'unknown';
    }
  }
}

// ============================================================
// 地点推断包装
// ============================================================

export class TransitInferenceWrapper {
  private log = hilog.isLoggable(0, TAG, hilog.LogLevel.INFO) ? hilog : null;
  
  /**
   * 判断地点是否是交通枢纽（调用 C++ 侧）
   */
  static isTransitHub(geofenceId: string): boolean {
    try {
      return MotionClassifierBinding.isTransitHub(geofenceId);
    } catch (err) {
      hilog.error(0, TAG, `isTransitHub失败: ${err}`);
      return false;
    }
  }
  
  /**
   * 推断驾驶 vs 乘车（调用 C++ 侧）
   */
  static inferDrivingVsTransit(
    motionState: string,
    context: TransitInferenceContextResult
  ): string {
    try {
      return MotionClassifierBinding.inferDrivingVsTransit(motionState, context);
    } catch (err) {
      hilog.error(0, TAG, `inferDrivingVsTransit失败: ${err}`);
      return motionState;  // 失败时返回原状态
    }
  }
}

// ============================================================
// 集成化的分类器
// ============================================================

export class MotionClassifierCpp {
  private zAxisExtractor: ZAxisFeatureExtractor | null = null;
  private log = hilog.isLoggable(0, TAG, hilog.LogLevel.INFO) ? hilog : null;
  
  /**
   * 初始化分类器
   */
  async init(): Promise<boolean> {
    try {
      this.zAxisExtractor = new ZAxisFeatureExtractor();
      return true;
    } catch (err) {
      this.log?.error(0, TAG, `初始化失败: ${err}`);
      return false;
    }
  }
  
  /**
   * 处理加速度样本
   */
  onAccelerometerSample(x: number, y: number, z: number, timestamp: number): void {
    if (!this.zAxisExtractor) {
      return;
    }
    this.zAxisExtractor.addSample(z, timestamp);
  }
  
  /**
   * 获取 Z 轴特征（每2秒调用一次）
   */
  getZAxisFeatures(): ZAxisFeaturesResult {
    if (!this.zAxisExtractor) {
      return {
        amplitude: 0,
        frequency: 0,
        variance: 0,
        isValid: false
      };
    }
    return this.zAxisExtractor.computeFeatures();
  }
  
  /**
   * 根据 Z 轴特征判定运动状态
   */
  classifyMotionByZAxis(features: ZAxisFeaturesResult): string {
    return ZAxisFeatureExtractor.classifyByZAxis(features);
  }
  
  /**
   * 根据地点推断驾驶 vs 乘车
   */
  inferTransit(
    motionState: string,
    prevGeofence: string,
    currentGeofence: string,
    geofenceDepartureTime: number,
    gpsSpeed: number
  ): string {
    let context: TransitInferenceContextResult = {
      prevGeofence: prevGeofence,
      currentGeofence: currentGeofence,
      geofenceDepartureTime: geofenceDepartureTime,
      gpsSpeed: gpsSpeed
    };
    
    return TransitInferenceWrapper.inferDrivingVsTransit(motionState, context);
  }
}

// ============================================================
// 全局单例
// ============================================================

let gMotionClassifier: MotionClassifierCpp | null = null;

export async function getMotionClassifier(): Promise<MotionClassifierCpp> {
  if (!gMotionClassifier) {
    gMotionClassifier = new MotionClassifierCpp();
    await gMotionClassifier.init();
  }
  return gMotionClassifier;
}
