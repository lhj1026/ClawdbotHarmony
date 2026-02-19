// VadService: Silero VAD-based voice activity detection
// Replaces simple RMS energy threshold detection with neural network-based VAD

import { Vad, VadConfig, SileroVadConfig, TenVadConfig } from 'sherpa_onnx';
import { common } from '@kit.AbilityKit';
import { LogService } from '../common/LogService';

const TAG = '[VadService]';
const VAD_MODEL = 'vad/silero_vad.onnx';

export class VadService {
  private static instance: VadService | null = null;
  private log: LogService = LogService.getInstance();
  private vad: Vad | null = null;
  private initialized: boolean = false;

  private constructor() {}

  static getInstance(): VadService {
    if (!VadService.instance) {
      VadService.instance = new VadService();
    }
    return VadService.instance;
  }

  /**
   * Initialize the Silero VAD model.
   * Must be called once before using acceptWaveform/isDetected.
   * @param context UIAbilityContext for accessing rawfile resources
   * @returns true if initialization successful
   */
  async init(context: common.UIAbilityContext): Promise<boolean> {
    if (this.initialized) {
      this.log.info(TAG, 'Already initialized');
      return true;
    }

    try {
      // Silero VAD configuration
      const sileroConfig = new SileroVadConfig(
        VAD_MODEL,
        0.5,      // threshold - detection sensitivity (0.0-1.0)
        0.25,     // minSpeechDuration - minimum speech duration in seconds
        0.5,      // minSilenceDuration - minimum silence to end speech segment
        512,      // windowSize - samples per processing window (must be 512 for Silero)
        20        // maxSpeechDuration - maximum speech segment duration in seconds
      );

      // TenVad not used - pass empty config
      const tenConfig = new TenVadConfig('', 0, 0, 0, 0, 0);

      const vadConfig = new VadConfig(
        sileroConfig,
        tenConfig,
        16000,    // sampleRate - must match audio input
        false,    // debug - verbose logging
        2         // numThreads - parallel processing threads
      );

      // Create VAD with 30 second buffer and resource manager
      this.vad = new Vad(vadConfig, 30, context.resourceManager);
      this.initialized = true;
      this.log.info(TAG, 'Silero VAD initialized successfully');
      return true;
    } catch (e) {
      const err = e as Error;
      this.log.error(TAG, `Failed to initialize VAD: ${err.message ?? String(e)}`);
      return false;
    }
  }

  /**
   * Check if VAD is initialized and ready.
   */
  isInitialized(): boolean {
    return this.initialized;
  }

  /**
   * Feed audio samples to VAD for processing.
   * @param samples Float32Array of audio samples (16kHz, normalized to [-1.0, 1.0])
   */
  acceptWaveform(samples: Float32Array): void {
    if (!this.vad) {
      this.log.warn(TAG, 'VAD not initialized, call init() first');
      return;
    }
    this.vad.acceptWaveform(samples);
  }

  /**
   * Check if speech is currently detected.
   * Call this after acceptWaveform() to check detection status.
   * @returns true if speech activity is detected
   */
  isDetected(): boolean {
    return this.vad?.isDetected() ?? false;
  }

  /**
   * Check if the VAD buffer is empty (no pending speech segments).
   */
  isEmpty(): boolean {
    return this.vad?.isEmpty() ?? true;
  }

  /**
   * Reset VAD state for a new audio stream.
   * Call this when starting a new recording session.
   */
  reset(): void {
    this.vad?.reset();
  }

  /**
   * Clear any pending speech segments without resetting the model.
   */
  clear(): void {
    this.vad?.clear();
  }

  /**
   * Flush any remaining audio through the VAD.
   * Call this at the end of a recording to process final samples.
   */
  flush(): void {
    this.vad?.flush();
  }

  /**
   * Convert Int16 PCM buffer to Float32Array for VAD processing.
   * @param pcmBuffer ArrayBuffer containing Int16 PCM samples
   * @returns Float32Array normalized to [-1.0, 1.0]
   */
  static pcmToFloat32(pcmBuffer: ArrayBuffer): Float32Array {
    const int16 = new Int16Array(pcmBuffer);
    const float32 = new Float32Array(int16.length);
    for (let i = 0; i < int16.length; i++) {
      float32[i] = int16[i] / 32768.0;
    }
    return float32;
  }

  /**
   * Convert multiple Int16 PCM buffers to a single Float32Array.
   * @param pcmBuffers Array of ArrayBuffers containing Int16 PCM samples
   * @returns Float32Array normalized to [-1.0, 1.0]
   */
  static pcmBuffersToFloat32(pcmBuffers: ArrayBuffer[]): Float32Array {
    let totalSamples = 0;
    for (const buf of pcmBuffers) {
      totalSamples += buf.byteLength / 2; // Int16 = 2 bytes per sample
    }

    const float32 = new Float32Array(totalSamples);
    let offset = 0;
    for (const buf of pcmBuffers) {
      const int16 = new Int16Array(buf);
      for (let i = 0; i < int16.length; i++) {
        float32[offset++] = int16[i] / 32768.0;
      }
    }
    return float32;
  }
}
