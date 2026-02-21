/**
 * AmbientSoundPlugin — Ambient sound analysis for scene detection
 *
 * Records short audio samples (3 seconds) and analyzes:
 * - noise_level: quiet / normal / noisy
 * - sound_scene: silent / office / outdoor / traffic / crowd
 * - has_voice: whether human voice is detected (VAD)
 * - volume_db: estimated volume in dB
 *
 * Privacy (CRITICAL level):
 * - enabledByDefault: false (user must opt in)
 * - Raw audio is NEVER saved or transmitted
 * - Only extracted features (dB level, spectral stats) are kept
 * - Sampling: one 3-second capture every 60 seconds max
 *
 * Permission: ohos.permission.MICROPHONE (already declared)
 */
import { audio } from '@kit.AudioKit';
import { common } from '@kit.AbilityKit';
import { LogService } from '../../../common/LogService';
import { DigitalPlugin, DigitalSnapshot } from './DigitalPluginInterface';

const TAG = 'AmbientSoundPlugin';

export class AmbientSoundPlugin implements DigitalPlugin {
  name: string = 'ambientSound';
  private log: LogService = LogService.getInstance();
  private noiseLevel: string = 'unknown';
  private soundScene: string = 'unknown';
  private hasVoice: boolean = false;
  private volumeDb: number = -1;
  private lastCaptureTime: number = 0;
  private isCapturing: boolean = false;

  async init(_context: common.UIAbilityContext): Promise<void> {
    this.log.info(TAG, 'Init: ambient sound plugin ready (captures on demand)');
  }

  getSnapshot(): DigitalSnapshot {
    // Trigger async capture if stale (>60s) and not currently capturing
    let age = Date.now() - this.lastCaptureTime;
    if (age > 60000 && !this.isCapturing) {
      this.captureAndAnalyze();
    }

    let data: Record<string, string> = {
      'noise_level': this.noiseLevel,
      'sound_scene': this.soundScene,
      'has_voice': this.hasVoice ? 'true' : 'false',
      'volume_db': this.volumeDb >= 0 ? this.volumeDb.toFixed(1) : 'unknown'
    };

    return {
      pluginName: this.name,
      timestamp: Date.now(),
      data: data
    };
  }

  destroy(): void {
    this.isCapturing = false;
    this.log.info(TAG, 'Destroyed');
  }

  private async captureAndAnalyze(): Promise<void> {
    if (this.isCapturing) return;
    this.isCapturing = true;

    try {
      // Configure audio capturer for short ambient sample
      let audioStreamInfo: audio.AudioStreamInfo = {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
      };

      let capturerInfo: audio.AudioCapturerInfo = {
        source: audio.SourceType.SOURCE_TYPE_MIC,
        capturerFlags: 0
      };

      let capturerOptions: audio.AudioCapturerOptions = {
        streamInfo: audioStreamInfo,
        capturerInfo: capturerInfo
      };

      let capturer = await audio.createAudioCapturer(capturerOptions);
      await capturer.start();

      // Capture 3 seconds of audio: 16000 Hz * 2 bytes * 3 sec = 96000 bytes
      let totalBytes = 96000;
      let allSamples: number[] = [];
      let bytesRead = 0;

      while (bytesRead < totalBytes) {
        let readSize = Math.min(4096, totalBytes - bytesRead);
        let buffer = await capturer.read(readSize, true);
        if (buffer.byteLength === 0) break;

        // Extract int16 samples for analysis
        let view = new DataView(buffer);
        for (let i = 0; i + 1 < buffer.byteLength; i += 2) {
          allSamples.push(view.getInt16(i, true));
        }
        bytesRead += buffer.byteLength;
      }

      await capturer.stop();
      await capturer.release();

      // Analyze the samples
      this.analyzeAudio(allSamples);
      this.lastCaptureTime = Date.now();

    } catch (err) {
      this.log.debug(TAG, `Capture failed: ${(err as Error).message}`);
    } finally {
      this.isCapturing = false;
    }
  }

  private analyzeAudio(samples: number[]): void {
    if (samples.length === 0) return;

    // Calculate RMS volume
    let sumSquares = 0;
    for (let i = 0; i < samples.length; i++) {
      let normalized = samples[i] / 32768.0;
      sumSquares += normalized * normalized;
    }
    let rms = Math.sqrt(sumSquares / samples.length);

    // Convert to dB (approximate SPL)
    // Reference: -60dB RMS = silence, 0dB = full scale
    let dbFS = rms > 0 ? 20 * Math.log10(rms) : -80;
    // Map to approximate SPL (rough calibration: -60 dbFS ≈ 30 dB SPL, 0 dbFS ≈ 90 dB SPL)
    this.volumeDb = Math.max(0, Math.round(dbFS + 90));

    // Classify noise level
    if (this.volumeDb < 30) {
      this.noiseLevel = 'quiet';
    } else if (this.volumeDb < 55) {
      this.noiseLevel = 'normal';
    } else {
      this.noiseLevel = 'noisy';
    }

    // Simple voice activity detection (VAD)
    // Check for zero-crossing rate — voice has moderate ZCR (50-300 Hz range)
    let zeroCrossings = 0;
    for (let i = 1; i < samples.length; i++) {
      if ((samples[i] >= 0 && samples[i - 1] < 0) || (samples[i] < 0 && samples[i - 1] >= 0)) {
        zeroCrossings++;
      }
    }
    let durationSec = samples.length / 16000;
    let zcr = zeroCrossings / durationSec;
    // Voice typically has ZCR between 50-300
    this.hasVoice = zcr > 50 && zcr < 500 && this.volumeDb > 35;

    // Scene classification based on volume + ZCR + energy patterns
    if (this.volumeDb < 25) {
      this.soundScene = 'silent';
    } else if (this.hasVoice && this.volumeDb < 50) {
      this.soundScene = 'office';
    } else if (this.hasVoice && this.volumeDb >= 50) {
      this.soundScene = 'crowd';
    } else if (this.volumeDb >= 60) {
      this.soundScene = 'traffic';
    } else {
      this.soundScene = 'outdoor';
    }

    this.log.debug(TAG, `Audio: vol=${this.volumeDb}dB noise=${this.noiseLevel} scene=${this.soundScene} voice=${this.hasVoice} zcr=${zcr.toFixed(0)}`);
  }
}
