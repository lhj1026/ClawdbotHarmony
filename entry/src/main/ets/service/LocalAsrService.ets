/**
 * Local ASR (Automatic Speech Recognition) service using HarmonyOS speechRecognizer.
 * Wraps @kit.CoreSpeechKit speechRecognizer with offline-first engine creation.
 * Supports recognizing PCM audio buffers (16kHz/16bit/mono) captured by AudioCapturer.
 */
import { speechRecognizer } from '@kit.CoreSpeechKit';
import { LogService } from '../common/LogService';

const TAG = 'LocalASR';
const CHUNK_SIZE = 1280; // 1280 bytes = 40ms at 16kHz/16bit/mono
const CHUNK_INTERVAL_MS = 10; // Write pace: 10ms per chunk ≈ 4x real-time (good accuracy + speed balance)

export class LocalAsrService {
  private static instance: LocalAsrService | undefined;
  private log: LogService = LogService.getInstance();
  private engine: speechRecognizer.SpeechRecognitionEngine | undefined = undefined;
  private sessionId: string = '';

  static getInstance(): LocalAsrService {
    if (!LocalAsrService.instance) {
      LocalAsrService.instance = new LocalAsrService();
    }
    return LocalAsrService.instance;
  }

  /**
   * Recognize speech from PCM audio buffers.
   * Creates engine on demand, feeds audio, waits for result.
   */
  async recognizeFromPcm(pcmBuffers: ArrayBuffer[]): Promise<string> {
    if (pcmBuffers.length === 0) {
      this.log.info(TAG, 'No PCM data to recognize');
      return '';
    }

    let totalBytes = 0;
    for (let buf of pcmBuffers) {
      totalBytes += buf.byteLength;
    }
    this.log.info(TAG, `recognizeFromPcm: ${pcmBuffers.length} buffers, ${totalBytes} bytes`);

    // Reuse engine if available, only create when needed
    if (!this.engine) {
      try {
        await this.createEngine();
      } catch (err) {
        this.log.error(TAG, `Failed to create engine: ${(err as Error).message}`);
        return '';
      }
    }

    if (!this.engine) {
      return '';
    }

    this.sessionId = `asr_${Date.now()}`;

    // Merge all PCM buffers into one continuous Uint8Array
    let merged = new Uint8Array(totalBytes);
    let offset = 0;
    for (let buf of pcmBuffers) {
      merged.set(new Uint8Array(buf), offset);
      offset += buf.byteLength;
    }

    let resultText = '';
    try {
      resultText = await new Promise<string>((resolve) => {
        let collectedText = '';
        let resolved = false;
        let doResolve = (text: string): void => {
          if (!resolved) {
            resolved = true;
            resolve(text);
          }
        };

        let listener: speechRecognizer.RecognitionListener = {
          onStart: (sessionId: string, _eventMessage: string): void => {
            this.log.info(TAG, `onStart: sessionId=${sessionId}`);
            // Feed audio with pacing after engine signals it's ready
            this.feedAudioPaced(merged, totalBytes, doResolve);
          },
          onEvent: (sessionId: string, eventCode: number, _eventMessage: string): void => {
            this.log.info(TAG, `onEvent: sessionId=${sessionId} code=${eventCode}`);
          },
          onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void => {
            this.log.info(TAG, `onResult: sessionId=${sessionId} isLast=${result.isLast} result="${result.result}"`);
            if (result.result && result.result.length > 0) {
              collectedText = result.result;
            }
            if (result.isLast) {
              doResolve(collectedText);
            }
          },
          onComplete: (sessionId: string, _eventMessage: string): void => {
            this.log.info(TAG, `onComplete: sessionId=${sessionId} text="${collectedText}"`);
            doResolve(collectedText);
          },
          onError: (sessionId: string, errorCode: number, errorMessage: string): void => {
            this.log.error(TAG, `onError: sessionId=${sessionId} code=${errorCode} msg=${errorMessage}`);
            doResolve('');
          },
        };

        this.engine!.setListener(listener);

        // Start listening
        let startParams: speechRecognizer.StartParams = {
          sessionId: this.sessionId,
          audioInfo: {
            audioType: 'pcm',
            sampleRate: 16000,
            soundChannel: 1,
            sampleBit: 16,
          },
          extraParams: {
            'vadEnd': 3000,
            'addPunc': true,
          },
        };
        this.engine!.startListening(startParams);

        // Timeout fallback
        setTimeout((): void => {
          this.log.warn(TAG, 'Recognition timeout (30s)');
          doResolve(collectedText);
        }, 30000);
      });
    } catch (err) {
      this.log.error(TAG, `Recognition error: ${(err as Error).message}`);
      resultText = '';
    }

    // Keep engine alive for reuse — only destroy on error
    if (resultText.length === 0) {
      try { this.engine.shutdown(); } catch { /* ignore */ }
      this.engine = undefined;
    }

    this.log.info(TAG, `Final result: "${resultText}"`);
    return resultText.trim();
  }

  /**
   * Feed PCM audio data to the engine with real-time pacing.
   * Every chunk is fed via setTimeout to give the engine time to process.
   * Uses CHUNK_INTERVAL_MS per chunk (~4x real-time) for good accuracy.
   */
  private feedAudioPaced(merged: Uint8Array, totalLen: number,
    doResolve: (text: string) => void): void {
    let chunksWritten = 0;
    let chunkIndex = 0;

    let feedNextChunk = (): void => {
      let byteOffset = chunkIndex * CHUNK_SIZE;
      if (byteOffset >= totalLen) {
        // All chunks sent — delay before finish() to let engine process last data
        this.log.info(TAG, `Fed ${totalLen} bytes in ${chunksWritten} chunks, calling finish()`);
        setTimeout((): void => {
          try {
            this.engine!.finish(this.sessionId);
          } catch (e) {
            this.log.warn(TAG, `finish() error: ${(e as Error).message}`);
          }
        }, 100);
        return;
      }

      let end = Math.min(byteOffset + CHUNK_SIZE, totalLen);
      let chunk = merged.slice(byteOffset, end);
      try {
        this.engine!.writeAudio(this.sessionId, chunk);
        chunksWritten++;
      } catch (err) {
        this.log.warn(TAG, `writeAudio error at chunk ${chunkIndex}: ${(err as Error).message}`);
        return;
      }

      chunkIndex++;
      // Always use setTimeout for every chunk — never feed synchronously
      setTimeout(feedNextChunk, CHUNK_INTERVAL_MS);
    };

    feedNextChunk();
  }

  /** Create speech recognition engine (offline first, online fallback) */
  private async createEngine(): Promise<void> {
    // Always release old engine first
    if (this.engine) {
      try { this.engine.cancel(this.sessionId); } catch { /* ignore */ }
      try { this.engine.shutdown(); } catch { /* ignore */ }
      this.engine = undefined;
    }

    // Try offline first (may not be available on all devices)
    let offlineParams: speechRecognizer.CreateEngineParams = {
      language: 'zh-CN',
      online: 0,
      extraParams: {
        'locate': 'CN',
        'recognizerMode': 'short',
        'maxAudioDuration': 60000,
      },
    };

    try {
      this.engine = await speechRecognizer.createEngine(offlineParams);
      this.log.info(TAG, 'Engine created (offline)');
      return;
    } catch (err) {
      this.log.warn(TAG, `Offline engine failed: ${(err as Error).message}, trying online`);
    }

    // Fallback to online
    let onlineParams: speechRecognizer.CreateEngineParams = {
      language: 'zh-CN',
      online: 1,
      extraParams: {
        'locate': 'CN',
        'recognizerMode': 'short',
        'maxAudioDuration': 60000,
      },
    };
    this.engine = await speechRecognizer.createEngine(onlineParams);
    this.log.info(TAG, 'Engine created (online)');
  }

  /** Release engine resources */
  async release(): Promise<void> {
    if (this.engine) {
      try { this.engine.cancel(this.sessionId); } catch { /* ignore */ }
      try { this.engine.shutdown(); } catch { /* ignore */ }
      this.engine = undefined;
      this.log.info(TAG, 'Engine released');
    }
  }
}
