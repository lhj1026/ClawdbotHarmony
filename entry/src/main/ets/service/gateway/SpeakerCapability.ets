/**
 * Handles speaker.speak (TTS) and speaker.play (audio playback) commands from the gateway.
 * - speaker.speak: Uses textToSpeech engine to read text aloud via AudioRenderer (manual PCM playback).
 * - speaker.play: Plays audio from a URL or base64 data using AVPlayer.
 * - speaker.stop: Stops all audio playback.
 */
import { textToSpeech } from '@kit.CoreSpeechKit';
import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { fileIo } from '@kit.CoreFileKit';
import { buffer } from '@kit.ArkTS';
import { LogService } from '../../common/LogService';
import { Command } from './GatewayProtocol';

const TAG = 'SpeakerCap';

export class SpeakerCapability {
  private log: LogService = LogService.getInstance();
  private filesDir: string = '';
  private ttsEngine: textToSpeech.TextToSpeechEngine | undefined = undefined;
  private ttsRenderer: audio.AudioRenderer | undefined = undefined;
  private player: media.AVPlayer | undefined = undefined;
  private playFdFile: fileIo.File | undefined = undefined;

  setContext(ctx: Context): void {
    this.filesDir = ctx.filesDir;
  }

  async execute(command: string, paramsJson: string | undefined): Promise<string> {
    this.log.info(TAG, `execute: command=${command} params=${paramsJson ?? 'none'}`);

    if (command === Command.SPEAKER_SPEAK) {
      return await this.speak(paramsJson);
    } else if (command === Command.SPEAKER_PLAY) {
      return await this.play(paramsJson);
    } else if (command === Command.SPEAKER_STOP) {
      return await this.stop();
    }
    throw new Error(`Unsupported speaker command: ${command}`);
  }

  // ---- speaker.speak: Text-to-Speech with AudioRenderer ----

  private async speak(paramsJson: string | undefined): Promise<string> {
    if (!paramsJson || paramsJson.length === 0) {
      throw new Error('speaker.speak requires params with "text"');
    }

    let params: Record<string, Object>;
    try {
      params = JSON.parse(paramsJson) as Record<string, Object>;
    } catch {
      throw new Error('Invalid JSON params for speaker.speak');
    }

    let text: string = String(params['text'] ?? '');
    let lang: string = String(params['lang'] ?? 'zh-CN');
    let speed: number = 1.0;
    let volume: number = 1.0;

    if (text.length === 0) {
      throw new Error('speaker.speak: "text" is required');
    }

    // Normalize text for better TTS pronunciation
    text = this.normalizeTextForTts(text);

    if (params['speed'] !== undefined) {
      speed = Math.max(0.5, Math.min(3.0, params['speed'] as number));
    }
    if (params['volume'] !== undefined) {
      volume = Math.max(0.0, Math.min(1.0, params['volume'] as number));
    }

    this.log.info(TAG, `speak: textLen=${text.length} lang=${lang} speed=${speed} volume=${volume}`);

    // Stop any previous TTS
    await this.stopTts();

    let ttsLang = lang.startsWith('en') ? 'en-US' : 'zh-CN';
    let initParams: textToSpeech.CreateEngineParams = {
      language: ttsLang,
      person: 0,
      online: 0,
      extraParams: { style: 'interaction-broadcast', locate: 'CN', name: 'EngineName' },
    };

    let isOnline = false;
    try {
      this.ttsEngine = await textToSpeech.createEngine(initParams);
      this.log.info(TAG, `TTS engine created (offline, lang=${ttsLang})`);
    } catch (err) {
      this.log.warn(TAG, `Offline TTS failed, trying online: ${(err as Error).message}`);
      initParams.online = 1;
      this.ttsEngine = await textToSpeech.createEngine(initParams);
      this.log.info(TAG, `TTS engine created (online, lang=${ttsLang})`);
      isOnline = true;
    }

    // Online engine doesn't output PCM via onData — use engine-internal playback instead
    if (isOnline) {
      this.log.info(TAG, 'Online engine: using internal playback (no PCM output)');
      return await this.speakFallback(text, lang, speed, volume);
    }

    // Create AudioRenderer for manual PCM playback — gives us full volume control
    let rendererOptions: audio.AudioRendererOptions = {
      streamInfo: {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
      },
      rendererInfo: {
        usage: audio.StreamUsage.STREAM_USAGE_VOICE_ASSISTANT,
        rendererFlags: 0,
      },
    };

    try {
      this.ttsRenderer = await audio.createAudioRenderer(rendererOptions);
      // Set interrupt mode to INDEPENDENT so our stream is not ducked
      this.ttsRenderer.setInterruptMode(audio.InterruptMode.INDEPENDENT_MODE);
      // Set volume (0.0-1.0)
      await this.ttsRenderer.setVolume(volume);
      await this.ttsRenderer.start();
      this.log.info(TAG, `AudioRenderer created and started (volume=${volume})`);
    } catch (err) {
      this.log.error(TAG, `AudioRenderer creation failed: ${(err as Error).message}, falling back to engine playback`);
      // Fall back to engine-internal playback
      return await this.speakFallback(text, lang, speed, volume);
    }

    // Speak with PCM output via onData callback
    let speakParams: textToSpeech.SpeakParams = {
      requestId: `tts_${Date.now()}`,
      extraParams: {
        queueMode: 0,
        speed: speed,
        volume: 2,
        pitch: 1,
        languageContext: lang,
        audioType: 'pcm',
        soundChannel: 1,
        playType: 1,
      },
    };

    let renderer = this.ttsRenderer;
    // Chain async writes so all PCM data reaches the AudioRenderer buffer before we drain
    let writeQueue: Promise<void> = Promise.resolve();
    let totalPcmBytes: number = 0;
    let speakPromise = new Promise<void>((resolve, reject) => {
      let listener: textToSpeech.SpeakListener = {
        onStart: (requestId: string, _response: textToSpeech.StartResponse) => {
          this.log.info(TAG, `TTS started: requestId=${requestId}`);
        },
        onComplete: (requestId: string, _response: textToSpeech.CompleteResponse) => {
          this.log.info(TAG, `TTS synthesis done: requestId=${requestId} totalPcmBytes=${totalPcmBytes}`);
          // Wait for all pending PCM writes to finish before resolving
          writeQueue.then((): void => {
            this.log.info(TAG, `All PCM writes flushed, resolving speak promise`);
            resolve();
          }).catch((): void => { resolve(); });
        },
        onStop: (requestId: string, _response: textToSpeech.StopResponse) => {
          this.log.info(TAG, `TTS stopped: requestId=${requestId}`);
          writeQueue.then((): void => { resolve(); }).catch((): void => { resolve(); });
        },
        onError: (requestId: string, errorCode: number, errorMessage: string) => {
          this.log.error(TAG, `TTS error: requestId=${requestId} code=${errorCode} msg=${errorMessage}`);
          reject(new Error(`TTS error: ${errorMessage} (code=${errorCode})`));
        },
        onData: (_requestId: string, pcmAudio: ArrayBuffer, _response: textToSpeech.SynthesisResponse) => {
          // Chain PCM writes to ensure ordered, complete playback
          if (renderer && pcmAudio.byteLength > 0) {
            totalPcmBytes += pcmAudio.byteLength;
            writeQueue = writeQueue.then((): Promise<number> => {
              return renderer.write(pcmAudio);
            }).then((): void => {}).catch((): void => {});
          }
        },
      };
      this.ttsEngine!.setListener(listener);
      this.ttsEngine!.speak(text, speakParams);
    });

    // Wait for TTS with timeout
    let timeoutMs = Math.max(15000, text.length * 300);
    try {
      await Promise.race([
        speakPromise,
        this.delay(timeoutMs).then(() => {
          this.log.warn(TAG, 'TTS timeout, stopping...');
          try { this.ttsEngine!.stop(); } catch { /* ignore */ }
        }),
      ]);
    } catch (err) {
      this.log.error(TAG, `TTS speak error: ${(err as Error).message}`);
    }

    // Drain and release the renderer
    await this.stopTtsRenderer();

    return `{"ok":true,"textLength":${text.length},"lang":"${lang}"}`;
  }

  /** Fallback: let the TTS engine play audio internally (original behavior) */
  private async speakFallback(text: string, lang: string, speed: number, volume: number): Promise<string> {
    this.log.info(TAG, `Using fallback engine-internal playback, textLen=${text.length} text="${text.substring(0, 60)}"`);

    let speakParams: textToSpeech.SpeakParams = {
      requestId: `tts_${Date.now()}`,
      extraParams: {
        queueMode: 0,
        speed: speed,
        volume: volume * 2,
        pitch: 1,
        languageContext: lang,
        playType: 1,
      },
    };

    let speakPromise = new Promise<void>((resolve, reject) => {
      let listener: textToSpeech.SpeakListener = {
        onStart: (requestId: string, _response: textToSpeech.StartResponse) => {
          this.log.info(TAG, `TTS(fb) started: requestId=${requestId}`);
        },
        onComplete: (requestId: string, _response: textToSpeech.CompleteResponse) => {
          this.log.info(TAG, `TTS(fb) completed: requestId=${requestId}`);
          resolve();
        },
        onStop: (requestId: string, _response: textToSpeech.StopResponse) => {
          this.log.info(TAG, `TTS(fb) stopped: requestId=${requestId}`);
          resolve();
        },
        onError: (requestId: string, errorCode: number, errorMessage: string) => {
          this.log.error(TAG, `TTS(fb) error: code=${errorCode} msg=${errorMessage}`);
          reject(new Error(`TTS error: ${errorMessage} (code=${errorCode})`));
        },
        onData: (_requestId: string, _audio: ArrayBuffer, _response: textToSpeech.SynthesisResponse) => {
          // engine plays internally
        },
      };
      this.ttsEngine!.setListener(listener);
      this.ttsEngine!.speak(text, speakParams);
    });

    // Online engine's onComplete fires when synthesis is done, not when playback finishes.
    // Wait for BOTH synthesis completion AND estimated playback duration.
    let estimatedPlayMs = Math.max(2000, Math.round(text.length * 200 / speed));
    let timeoutMs = Math.max(10000, text.length * 250);
    this.log.info(TAG, `TTS(fb) waiting: estimatedPlay=${estimatedPlayMs}ms timeout=${timeoutMs}ms`);
    let startedOk = false;
    await Promise.race([
      speakPromise.then(() => {
        startedOk = true;
        this.log.info(TAG, `TTS(fb) speakPromise resolved, waiting estimatedPlay=${estimatedPlayMs}ms`);
        return this.delay(estimatedPlayMs);
      }),
      this.delay(timeoutMs).then(() => {
        if (!startedOk) {
          this.log.warn(TAG, `TTS(fb) timeout (engine never completed in ${timeoutMs}ms)`);
        } else {
          this.log.info(TAG, 'TTS(fb) playback wait timeout (normal)');
        }
        try { this.ttsEngine!.stop(); } catch { /* ignore */ }
      }),
    ]);

    return `{"ok":true,"textLength":${text.length},"lang":"${lang}"}`;
  }

  /** Stop TTS engine and AudioRenderer */
  private async stopTts(): Promise<void> {
    if (this.ttsEngine) {
      try { this.ttsEngine.stop(); } catch { /* ignore */ }
      try { this.ttsEngine.shutdown(); } catch { /* ignore */ }
      this.ttsEngine = undefined;
    }
    await this.stopTtsRenderer();
  }

  /** Stop and release the TTS AudioRenderer */
  private async stopTtsRenderer(): Promise<void> {
    if (this.ttsRenderer) {
      try { await this.ttsRenderer.drain(); } catch { /* ignore */ }
      try { await this.ttsRenderer.stop(); } catch { /* ignore */ }
      try { await this.ttsRenderer.release(); } catch { /* ignore */ }
      this.ttsRenderer = undefined;
    }
  }

  // ---- speaker.play: Play audio from URL or base64 ----

  private async play(paramsJson: string | undefined): Promise<string> {
    if (!paramsJson || paramsJson.length === 0) {
      throw new Error('speaker.play requires params with "url" or "base64"');
    }

    let params: Record<string, Object>;
    try {
      params = JSON.parse(paramsJson) as Record<string, Object>;
    } catch {
      throw new Error('Invalid JSON params for speaker.play');
    }

    let url: string = String(params['url'] ?? '');
    let base64Data: string = String(params['base64'] ?? '');

    if (url.length === 0 && base64Data.length === 0) {
      throw new Error('speaker.play: "url" or "base64" is required');
    }

    // Stop any existing playback
    await this.releasePlayer();

    this.player = await media.createAVPlayer();
    this.log.info(TAG, 'AVPlayer created');

    let tempFile: string = '';
    let useUrl: boolean = url.length > 0;

    if (base64Data.length > 0) {
      // Write base64 data to temp file
      let format: string = String(params['format'] ?? 'mp3');
      tempFile = `${this.filesDir}/speaker_play_${Date.now()}.${format}`;
      let decoded = buffer.from(base64Data, 'base64');
      let writeFile = fileIo.openSync(tempFile, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
      fileIo.writeSync(writeFile.fd, decoded.buffer);
      fileIo.closeSync(writeFile);
      this.log.info(TAG, `Wrote base64 audio to tempFile=${tempFile} size=${decoded.length}`);

      // Open for reading and set as fdSrc
      this.playFdFile = fileIo.openSync(tempFile, fileIo.OpenMode.READ_ONLY);
      let stat = fileIo.statSync(tempFile);
      this.log.info(TAG, `Opening fd=${this.playFdFile.fd} fileSize=${stat.size}`);
    } else {
      this.log.info(TAG, `Playing audio from URL: ${url}`);
    }

    // Set up state machine and play with promise
    let playPromise = new Promise<void>((resolve) => {
      let resolved = false;
      let doResolve = () => {
        if (!resolved) {
          resolved = true;
          resolve();
        }
      };

      this.player!.on('stateChange', (state: string) => {
        this.log.info(TAG, `AVPlayer state: ${state}`);
        switch (state) {
          case 'initialized':
            // Set audio renderer info for speaker output, then prepare
            this.player!.audioRendererInfo = {
              usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
              rendererFlags: 0,
            };
            this.log.info(TAG, 'AVPlayer: calling prepare()...');
            this.player!.prepare();
            break;
          case 'prepared':
            this.log.info(TAG, 'AVPlayer: calling play()...');
            this.player!.play();
            break;
          case 'playing':
            this.log.info(TAG, 'AVPlayer: audio is now playing');
            break;
          case 'completed':
            this.log.info(TAG, 'AVPlayer: playback completed');
            doResolve();
            break;
          case 'stopped':
            this.log.info(TAG, 'AVPlayer: playback stopped');
            doResolve();
            break;
          case 'error':
            this.log.error(TAG, 'AVPlayer: entered error state');
            doResolve();
            break;
          default:
            break;
        }
      });

      this.player!.on('error', (err: Error) => {
        this.log.error(TAG, `AVPlayer error event: ${err.message ?? 'unknown'}`);
        doResolve();
      });
    });

    // Set the source to trigger the state machine
    if (useUrl) {
      this.player.url = url;
    } else {
      // Use fdSrc for local file playback
      let stat = fileIo.statSync(tempFile);
      this.player.fdSrc = {
        fd: this.playFdFile!.fd,
        offset: 0,
        length: stat.size,
      };
    }

    // Wait for playback to complete (timeout 5 minutes)
    await Promise.race([
      playPromise,
      this.delay(300000).then(() => {
        this.log.warn(TAG, 'AVPlayer timeout after 5 min');
      }),
    ]);

    // Clean up
    await this.releasePlayer();

    if (tempFile.length > 0) {
      try { fileIo.unlinkSync(tempFile); } catch { /* best effort */ }
    }

    return `{"ok":true,"source":"${useUrl ? 'url' : 'base64'}"}`;
  }

  /** Release AVPlayer and close any open fd */
  private async releasePlayer(): Promise<void> {
    if (this.player) {
      try { await this.player.stop(); } catch { /* ignore */ }
      try { await this.player.release(); } catch { /* ignore */ }
      this.player = undefined;
    }
    if (this.playFdFile) {
      try { fileIo.closeSync(this.playFdFile); } catch { /* ignore */ }
      this.playFdFile = undefined;
    }
  }

  // ---- speaker.stop: Stop any playback ----

  private async stop(): Promise<string> {
    this.log.info(TAG, 'Stopping all audio...');

    await this.stopTts();
    await this.releasePlayer();

    return `{"ok":true,"stopped":true}`;
  }

  /** Release resources when disconnecting */
  async release(): Promise<void> {
    await this.stopTts();
    await this.releasePlayer();
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => { resolve(); }, ms);
    });
  }

  /**
   * Normalize text for better TTS pronunciation.
   * - ~ → 到 (range indicator)
   * - Numbers with k/K → 千 (e.g., 1.0k → 1点0千)
   * - + at end of numbers → 加 (e.g., 100+ → 100加)
   * - . in numbers → 点 (e.g., 1.5 → 1点5)
   */
  private normalizeTextForTts(text: string): string {
    let result = text;

    // Replace ~ with 到 (range indicator, e.g., "1~3度" → "1到3度")
    result = result.replace(/(\d)\s*[~～]\s*(\d)/g, '$1到$2');

    // Replace k/K suffix with 千 (e.g., "1.0k" → "1.0千", "2K" → "2千")
    result = result.replace(/(\d)([kK])\b/g, '$1千');

    // Replace + at end of numbers with 加 (e.g., "100+" → "100加", "1.0k+" already handled → "1.0千加")
    result = result.replace(/(\d千?)\+/g, '$1加');

    // Replace decimal point with 点 for numbers (e.g., "1.5" → "1点5")
    // But preserve URLs and other contexts - only process standalone numbers
    result = result.replace(/(\d)\.(\d)/g, '$1点$2');

    return result;
  }
}
