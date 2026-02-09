/**
 * Handles screen.record commands from the gateway.
 * Records the device screen as MP4 video using AVScreenCaptureRecorder.
 */
import { media } from '@kit.MediaKit';
import { fileIo } from '@kit.CoreFileKit';
import { buffer } from '@kit.ArkTS';
import { LogService } from '../../common/LogService';

const TAG = 'ScreenCap';

export class ScreenCapability {
  private log: LogService = LogService.getInstance();
  private context: object | undefined = undefined;

  setContext(ctx: object): void {
    this.context = ctx;
  }

  async execute(paramsJson: string | undefined): Promise<string> {
    this.log.info(TAG, `execute: params=${paramsJson ?? 'none'}`);

    let durationMs: number = 3000;
    let includeAudio: boolean = false;

    if (paramsJson && paramsJson.length > 0) {
      try {
        let p = JSON.parse(paramsJson) as Record<string, Object>;
        if (p['durationMs'] !== undefined) {
          durationMs = Math.max(1000, Math.min(60000, p['durationMs'] as number));
        }
        if (p['duration'] !== undefined) {
          // Support 'duration' in seconds as well
          let durationSec: number = Math.max(1, Math.min(60, p['duration'] as number));
          durationMs = durationSec * 1000;
        }
        if (p['includeAudio'] !== undefined) {
          includeAudio = p['includeAudio'] as boolean;
        }
      } catch {
        this.log.warn(TAG, 'Failed to parse params, using defaults');
      }
    }

    this.log.info(TAG, `Recording screen: durationMs=${durationMs} includeAudio=${includeAudio}`);

    // Create temp file
    let ctx = this.context as Record<string, string>;
    let filesDir: string = ctx['filesDir'] ?? '/data/storage/el2/base/haps/entry/files';
    let filePath: string = `${filesDir}/screen_recording_${Date.now()}.mp4`;
    this.log.info(TAG, `Output file: ${filePath}`);

    let file = fileIo.openSync(filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);

    try {
      // Create recorder
      let recorder: media.AVScreenCaptureRecorder = await media.createAVScreenCaptureRecorder();

      let config: media.AVScreenCaptureRecordConfig = {
        fd: file.fd,
        frameWidth: 720,
        frameHeight: 1280,
        videoBitrate: 4000000,
        audioSampleRate: includeAudio ? 48000 : 48000,
        audioChannelCount: includeAudio ? 2 : 1,
        audioBitrate: includeAudio ? 128000 : 64000,
        preset: media.AVScreenCaptureRecordPreset.SCREEN_RECORD_PRESET_H264_AAC_MP4,
      };

      this.log.info(TAG, 'Initializing recorder...');
      await recorder.init(config);

      this.log.info(TAG, 'Starting recording...');
      await recorder.startRecording();

      // Wait for duration
      this.log.info(TAG, `Recording for ${durationMs}ms...`);
      await this.delay(durationMs);

      this.log.info(TAG, 'Stopping recording...');
      await recorder.stopRecording();
      await recorder.release();
      this.log.info(TAG, 'Recorder released');

      // Close and read the file
      fileIo.closeSync(file);

      let stat = fileIo.statSync(filePath);
      let fileSize: number = stat.size;
      this.log.info(TAG, `Recording file size: ${fileSize} bytes`);

      if (fileSize === 0) {
        throw new Error('Screen recording produced empty file');
      }

      // Read file to base64
      let readFile = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
      let buf = new ArrayBuffer(fileSize);
      fileIo.readSync(readFile.fd, buf);
      fileIo.closeSync(readFile);

      let base64: string = buffer.from(buf).toString('base64');
      this.log.info(TAG, `Recording base64 length: ${base64.length}`);

      // Clean up temp file
      try { fileIo.unlinkSync(filePath); } catch { /* best effort */ }

      return `{"format":"mp4","base64":${JSON.stringify(base64)},"durationMs":${durationMs}}`;

    } catch (err) {
      // Ensure file is closed
      try { fileIo.closeSync(file); } catch { /* ignore */ }
      try { fileIo.unlinkSync(filePath); } catch { /* ignore */ }
      throw err;
    }
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => { resolve(); }, ms);
    });
  }
}
