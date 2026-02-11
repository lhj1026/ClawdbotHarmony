/**
 * Handles mic.record commands from the gateway.
 * Records audio from the device microphone using AVRecorder.
 * Returns the recorded audio as base64-encoded data.
 */
import { media } from '@kit.MediaKit';
import { fileIo } from '@kit.CoreFileKit';
import { buffer } from '@kit.ArkTS';
import { LogService } from '../../common/LogService';

const TAG = 'MicCap';

export class MicrophoneCapability {
  private log: LogService = LogService.getInstance();
  private filesDir: string = '';

  setContext(ctx: Context): void {
    this.filesDir = ctx.filesDir;
  }

  async execute(paramsJson: string | undefined): Promise<string> {
    this.log.info(TAG, `execute: params=${paramsJson ?? 'none'}`);

    let durationMs: number = 5000;
    let format: string = 'm4a'; // default: AAC in M4A container

    if (paramsJson && paramsJson.length > 0) {
      try {
        let p = JSON.parse(paramsJson) as Record<string, Object>;
        if (p['durationMs'] !== undefined) {
          durationMs = Math.max(1000, Math.min(120000, p['durationMs'] as number));
        }
        if (p['duration'] !== undefined) {
          let durationSec: number = Math.max(1, Math.min(120, p['duration'] as number));
          durationMs = durationSec * 1000;
        }
        if (p['format'] !== undefined) {
          let fmt = String(p['format']).toLowerCase();
          if (fmt === 'wav' || fmt === 'mp3' || fmt === 'm4a' || fmt === 'aac') {
            format = fmt;
          }
        }
      } catch {
        this.log.warn(TAG, 'Failed to parse params, using defaults');
      }
    }

    this.log.info(TAG, `Recording audio: durationMs=${durationMs} format=${format}`);

    let ext = format === 'wav' ? 'wav' : 'm4a';
    let filePath: string = `${this.filesDir}/mic_recording_${Date.now()}.${ext}`;
    this.log.info(TAG, `Output file: ${filePath}`);

    let file = fileIo.openSync(filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);

    try {
      let recorder: media.AVRecorder = await media.createAVRecorder();

      let config: media.AVRecorderConfig = {
        audioSourceType: media.AudioSourceType.AUDIO_SOURCE_TYPE_MIC,
        profile: {
          audioBitrate: 128000,
          audioChannels: 1,
          audioCodec: format === 'wav'
            ? media.CodecMimeType.AUDIO_AAC  // will use AAC even for wav fallback
            : media.CodecMimeType.AUDIO_AAC,
          audioSampleRate: 44100,
          fileFormat: format === 'wav'
            ? media.ContainerFormatType.CFT_MPEG_4  // fallback to m4a
            : media.ContainerFormatType.CFT_MPEG_4,
        },
        url: `fd://${file.fd}`,
      };

      this.log.info(TAG, 'Preparing recorder...');
      await recorder.prepare(config);

      this.log.info(TAG, 'Starting recording...');
      await recorder.start();

      // Record for specified duration
      this.log.info(TAG, `Recording for ${durationMs}ms...`);
      await this.delay(durationMs);

      this.log.info(TAG, 'Stopping recording...');
      await recorder.stop();
      await recorder.release();
      this.log.info(TAG, 'Recorder released');

      // Close and read the file
      fileIo.closeSync(file);

      let stat = fileIo.statSync(filePath);
      let fileSize: number = stat.size;
      this.log.info(TAG, `Audio file size: ${fileSize} bytes`);

      if (fileSize === 0) {
        throw new Error('Audio recording produced empty file');
      }

      // Read file to base64
      let readFile = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
      let buf = new ArrayBuffer(fileSize);
      fileIo.readSync(readFile.fd, buf);
      fileIo.closeSync(readFile);

      let base64: string = buffer.from(buf).toString('base64');
      this.log.info(TAG, `Audio base64 length: ${base64.length}`);

      // Keep the file for local playback (ChatPage can show a play button)
      return `{"format":"m4a","base64":${JSON.stringify(base64)},"durationMs":${durationMs},"size":${fileSize},"filePath":${JSON.stringify(filePath)}}`;

    } catch (err) {
      try { fileIo.closeSync(file); } catch (ignored) { /* ignore */ }
      throw err as Error;
    }
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => { resolve(); }, ms);
    });
  }
}
