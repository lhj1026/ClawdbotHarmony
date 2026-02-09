/**
 * Handles speaker.speak (TTS) and speaker.play (audio playback) commands from the gateway.
 * - speaker.speak: Uses textToSpeech engine to read text aloud.
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

  // ---- speaker.speak: Text-to-Speech ----

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

    if (params['speed'] !== undefined) {
      speed = Math.max(0.5, Math.min(3.0, params['speed'] as number));
    }
    if (params['volume'] !== undefined) {
      volume = Math.max(0.0, Math.min(1.0, params['volume'] as number));
    }

    this.log.info(TAG, `speak: textLen=${text.length} lang=${lang} speed=${speed} volume=${volume}`);

    // Recreate TTS engine each time to ensure clean state and correct language
    if (this.ttsEngine) {
      try { this.ttsEngine.shutdown(); } catch { /* ignore */ }
      this.ttsEngine = undefined;
    }

    let initParams: textToSpeech.CreateEngineParams = {
      language: lang.startsWith('zh') ? 'zh-CN' : 'zh-CN', // HarmonyOS TTS only supports zh-CN for now
      person: 0,
      online: 1, // Use online TTS (offline may not be available on all devices)
      extraParams: { style: 'interaction-broadcast', locate: 'CN', name: 'EngineName' },
    };

    try {
      this.ttsEngine = await textToSpeech.createEngine(initParams);
      this.log.info(TAG, 'TTS engine created (online mode)');
    } catch (err) {
      this.log.warn(TAG, `Online TTS failed, trying offline: ${(err as Error).message}`);
      // Fallback to offline mode
      initParams.online = 0;
      this.ttsEngine = await textToSpeech.createEngine(initParams);
      this.log.info(TAG, 'TTS engine created (offline mode)');
    }

    // Speak the text
    let speakParams: textToSpeech.SpeakParams = {
      requestId: `tts_${Date.now()}`,
      extraParams: {
        speed: String(Math.round(speed * 100)),
        volume: String(Math.round(volume * 100)),
        voiceType: lang.startsWith('zh') ? 'zh' : 'en',
      },
    };

    // Use promise wrapper for speak callback
    let speakPromise = new Promise<void>((resolve, reject) => {
      let listener: textToSpeech.SpeakListener = {
        onStart: (requestId: string, _response: textToSpeech.StartResponse) => {
          this.log.info(TAG, `TTS started: requestId=${requestId}`);
        },
        onComplete: (requestId: string, _response: textToSpeech.CompleteResponse) => {
          this.log.info(TAG, `TTS completed: requestId=${requestId}`);
          resolve();
        },
        onStop: (requestId: string, _response: textToSpeech.StopResponse) => {
          this.log.info(TAG, `TTS stopped: requestId=${requestId}`);
          resolve();
        },
        onError: (requestId: string, errorCode: number, errorMessage: string) => {
          this.log.error(TAG, `TTS error: requestId=${requestId} code=${errorCode} msg=${errorMessage}`);
          reject(new Error(`TTS error: ${errorMessage} (code=${errorCode})`));
        },
        onData: (_requestId: string, _audio: ArrayBuffer, _response: textToSpeech.SynthesisResponse) => {
          // streaming audio data callback - TTS engine plays audio internally
        },
      };
      this.ttsEngine!.setListener(listener);
      this.ttsEngine!.speak(text, speakParams);
    });

    // Wait for TTS with timeout
    let timeoutMs = Math.max(15000, text.length * 300); // generous estimate
    await Promise.race([
      speakPromise,
      this.delay(timeoutMs).then(() => {
        this.log.warn(TAG, 'TTS timeout, stopping...');
        try { this.ttsEngine!.stop(); } catch { /* ignore */ }
      }),
    ]);

    return `{"ok":true,"textLength":${text.length},"lang":"${lang}"}`;
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

    if (this.ttsEngine) {
      try { this.ttsEngine.stop(); } catch { /* ignore */ }
    }
    await this.releasePlayer();

    return `{"ok":true,"stopped":true}`;
  }

  /** Release resources when disconnecting */
  async release(): Promise<void> {
    if (this.ttsEngine) {
      try { this.ttsEngine.shutdown(); } catch { /* ignore */ }
      this.ttsEngine = undefined;
    }
    await this.releasePlayer();
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => { resolve(); }, ms);
    });
  }
}
