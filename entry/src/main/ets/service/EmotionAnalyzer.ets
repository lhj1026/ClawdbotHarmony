// Emotion and Mood Detection Service
// Analyzes audio features for tone, singing detection, and stress level

import { EmotionAnalysis, AudioFeatures, EmotionType } from '../model/Models';
import { LogService } from '../common/LogService';

// 内部接口定义
interface PitchResult {
  mean: number;
  std: number;
}

export class EmotionAnalyzer {
  private static instance: EmotionAnalyzer;
  private log: LogService = LogService.getInstance();
  private readonly TAG = 'EmotionAnalyzer';

  private readonly SAMPLE_RATE = 16000;
  
  private constructor() {}

  static getInstance(): EmotionAnalyzer {
    if (!EmotionAnalyzer.instance) {
      EmotionAnalyzer.instance = new EmotionAnalyzer();
    }
    return EmotionAnalyzer.instance;
  }

  analyzeAudio(pcmData: Int16Array): EmotionAnalysis {
    // Truncate to first 2s — pitch autocorrelation is O(n²), 15s audio takes minutes
    let maxSamples = this.SAMPLE_RATE * 2;
    let data = pcmData.length > maxSamples ? pcmData.slice(0, maxSamples) : pcmData;

    let result: EmotionAnalysis = {
      timestamp: Date.now(),
      emotion: 'neutral',
      confidence: 0.5,
      features: { rms: 0, zeroCrossingRate: 0, spectralCentroid: 0, pitch: 0, pitchStd: 0, duration: pcmData.length / this.SAMPLE_RATE },
      stressLevel: 0.5,
      isSinging: false,
      pitchVariation: 0,
      energyLevel: 0.5,
      speakingRate: 0
    };

    if (data.length < this.SAMPLE_RATE * 0.5) {
      return result;
    }

    let features = this.extractAudioFeatures(data);
    features.duration = pcmData.length / this.SAMPLE_RATE; // Use full duration for display
    result.features = features;

    // Reuse pitch from features — no duplicate estimatePitch call
    result.pitchVariation = features.pitchStd / (features.pitch || 1);
    result.energyLevel = this.calculateEnergyLevel(data);
    result.speakingRate = this.estimateSpeakingRate(data);
    result.isSinging = this.detectSinging(data, features);
    result.stressLevel = this.calculateStressLevel(features, result.energyLevel, result.speakingRate);

    result.emotion = this.classifyEmotion(features, result.stressLevel, result.isSinging);
    result.confidence = this.calculateConfidence(features);

    return result;
  }

  extractAudioFeatures(pcmData: Int16Array): AudioFeatures {
    let features: AudioFeatures = {
      rms: 0,
      zeroCrossingRate: 0,
      spectralCentroid: 0,
      pitch: 0,
      pitchStd: 0,
      duration: pcmData.length / this.SAMPLE_RATE
    };

    if (pcmData.length === 0) return features;

    features.rms = this.calculateRms(pcmData);
    features.zeroCrossingRate = this.calculateZeroCrossingRate(pcmData);
    
    let pitchResult = this.estimatePitch(pcmData);
    features.pitch = pitchResult.mean;
    features.pitchStd = pitchResult.std;
    
    features.spectralCentroid = this.estimateSpectralCentroid(pcmData);

    return features;
  }

  private calculateRms(data: Int16Array): number {
    let sum = 0;
    for (let i = 0; i < data.length; i++) {
      sum += data[i] * data[i];
    }
    return Math.sqrt(sum / data.length) / 32768.0;
  }

  private calculateZeroCrossingRate(data: Int16Array): number {
    let crossings = 0;
    for (let i = 1; i < data.length; i++) {
      if ((data[i] >= 0 && data[i - 1] < 0) || (data[i] < 0 && data[i - 1] >= 0)) {
        crossings++;
      }
    }
    return crossings / data.length;
  }

  private estimatePitch(data: Int16Array): PitchResult {
    let pitches: number[] = [];
    let frameSize = 512;
    let hopSize = 256;

    for (let i = 0; i < data.length - frameSize; i += hopSize) {
      let frame = data.slice(i, i + frameSize);
      let pitch = this.autocorrelationPitch(frame);
      if (pitch > 50 && pitch < 500) {
        pitches.push(pitch);
      }
    }

    if (pitches.length === 0) {
      let emptyResult: PitchResult = { mean: 0, std: 0 };
      return emptyResult;
    }

    let mean = pitches.reduce((a, b) => a + b, 0) / pitches.length;
    let variance = pitches.reduce((sum, p) => sum + (p - mean) ** 2, 0) / pitches.length;
    let std = Math.sqrt(variance);

    let result: PitchResult = { mean: mean, std: std };
    return result;
  }

  private autocorrelationPitch(frame: Int16Array): number {
    let maxLag = Math.floor(this.SAMPLE_RATE / 50);
    let minLag = Math.floor(this.SAMPLE_RATE / 500);
    
    let maxCorr = 0;
    let bestLag = 0;

    for (let lag = minLag; lag < maxLag && lag < frame.length; lag++) {
      let corr = 0;
      for (let i = 0; i < frame.length - lag; i++) {
        corr += frame[i] * frame[i + lag];
      }
      if (corr > maxCorr) {
        maxCorr = corr;
        bestLag = lag;
      }
    }

    if (bestLag === 0) return 0;
    return this.SAMPLE_RATE / bestLag;
  }

  private estimateSpectralCentroid(data: Int16Array): number {
    let frameSize = 1024;
    let sum = 0;
    let weightedSum = 0;

    for (let i = 0; i < frameSize && i < data.length; i++) {
      let magnitude = Math.abs(data[i]);
      sum += magnitude;
      weightedSum += i * magnitude;
    }

    return sum > 0 ? weightedSum / sum : 0;
  }

  private calculatePitchVariation(data: Int16Array): number {
    let pitchResult = this.estimatePitch(data);
    return pitchResult.std / (pitchResult.mean || 1);
  }

  private calculateEnergyLevel(data: Int16Array): number {
    let rms = this.calculateRms(data);
    return Math.min(1.0, rms * 5);
  }

  private estimateSpeakingRate(data: Int16Array): number {
    let frameSize = 1600;
    let threshold = 0.02;
    let speechFrames = 0;
    let totalFrames = Math.floor(data.length / frameSize);

    for (let i = 0; i < totalFrames; i++) {
      let start = i * frameSize;
      let frame = data.slice(start, start + frameSize);
      let rms = this.calculateRms(frame);
      if (rms > threshold) {
        speechFrames++;
      }
    }

    let speechRatio = totalFrames > 0 ? speechFrames / totalFrames : 0;
    let duration = data.length / this.SAMPLE_RATE;
    return speechRatio / (duration || 1);
  }

  private detectSinging(data: Int16Array, features: AudioFeatures): boolean {
    let pitchVar = features.pitchStd / (features.pitch || 1);
    let zcrThreshold = 0.1;
    
    let isHighPitchVariance = pitchVar > 0.15;
    let isStableEnergy = features.rms > 0.05 && features.rms < 0.5;
    let isModerateZCR = features.zeroCrossingRate > zcrThreshold;
    
    let pitchInSingingRange = features.pitch > 100 && features.pitch < 400;

    return isHighPitchVariance && isStableEnergy && isModerateZCR && pitchInSingingRange;
  }

  private calculateStressLevel(features: AudioFeatures, energy: number, rate: number): number {
    let stressScore = 0;

    if (features.pitch > 0) {
      let pitchStress = Math.min(1.0, Math.abs(features.pitch - 150) / 150);
      stressScore += pitchStress * 0.3;
    }

    let energyStress = Math.min(1.0, energy * 1.5);
    stressScore += energyStress * 0.25;

    let rateStress = Math.min(1.0, rate * 2);
    stressScore += rateStress * 0.25;

    let zcrStress = Math.min(1.0, features.zeroCrossingRate * 3);
    stressScore += zcrStress * 0.2;

    return Math.min(1.0, Math.max(0.0, stressScore));
  }

  private classifyEmotion(features: AudioFeatures, stressLevel: number, isSinging: boolean): EmotionType {
    if (isSinging) {
      return 'happy';
    }

    if (stressLevel > 0.7) {
      return 'stressed';
    }

    if (features.pitch > 200 && features.rms > 0.1) {
      return 'excited';
    }

    if (features.pitch < 100 || (features.rms < 0.03 && features.pitchStd < 20)) {
      return 'calm';
    }

    if (stressLevel > 0.4) {
      return 'anxious';
    }

    if (features.rms < 0.05 && features.pitchStd < 30) {
      return 'sad';
    }

    return 'neutral';
  }

  private calculateConfidence(features: AudioFeatures): number {
    let conf = 0.5;

    if (features.rms > 0.01 && features.rms < 0.8) {
      conf += 0.1;
    }
    if (features.pitch > 50 && features.pitch < 500) {
      conf += 0.15;
    }
    if (features.pitchStd > 5 && features.pitchStd < 200) {
      conf += 0.1;
    }
    if (features.duration > 0.5) {
      conf += 0.15;
    }

    return Math.min(0.95, Math.max(0.3, conf));
  }

  analyzeFromFloat32(float32Data: Float32Array): EmotionAnalysis {
    let int16Data = new Int16Array(float32Data.length);
    for (let i = 0; i < float32Data.length; i++) {
      let sample = Math.max(-1, Math.min(1, float32Data[i]));
      int16Data[i] = sample < 0 ? sample * 32768 : sample * 32767;
    }
    return this.analyzeAudio(int16Data);
  }

  getEmotionLabel(emotion: EmotionType): string {
    const labels: Record<EmotionType, string> = {
      'neutral': '平静',
      'happy': '开心',
      'sad': '低落',
      'angry': '生气',
      'anxious': '焦虑',
      'stressed': '压力',
      'calm': '放松',
      'excited': '兴奋'
    };
    return labels[emotion] || '未知';
  }

  getStressLabel(level: number): string {
    if (level < 0.3) return '低';
    if (level < 0.6) return '中';
    return '高';
  }
}
