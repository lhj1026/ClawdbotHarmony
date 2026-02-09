/**
 * Handles camera.snap and camera.clip commands from the gateway.
 * Uses HarmonyOS cameraPicker (system camera UI) for reliable photo/video capture.
 * Falls back to system camera picker instead of raw CameraKit pipeline
 * which is unstable in headless (no-preview) mode on many devices.
 */
import { camera } from '@kit.CameraKit';
import { cameraPicker } from '@kit.CameraKit';
import { fileIo } from '@kit.CoreFileKit';
import { buffer } from '@kit.ArkTS';
import { LogService } from '../../common/LogService';
import { Command } from './GatewayProtocol';

const TAG = 'CameraCap';

export class CameraCapability {
  private log: LogService = LogService.getInstance();
  private appContext: Context | undefined = undefined;
  private filesDir: string = '';

  setContext(ctx: Context): void {
    this.appContext = ctx;
    this.filesDir = ctx.filesDir;
  }

  async execute(command: string, paramsJson: string | undefined): Promise<string> {
    this.log.info(TAG, `execute: command=${command} params=${paramsJson ?? 'none'}`);

    if (command === Command.CAMERA_SNAP) {
      return await this.snap(paramsJson);
    } else if (command === Command.CAMERA_CLIP) {
      return await this.clip(paramsJson);
    }
    throw new Error(`Unsupported camera command: ${command}`);
  }

  // ---- camera.snap: Take a still photo via system camera picker ----

  private async snap(paramsJson: string | undefined): Promise<string> {
    if (!this.appContext) {
      throw new Error('Context not set, call setContext first');
    }

    let facing: string = 'back';
    if (paramsJson && paramsJson.length > 0) {
      try {
        let p = JSON.parse(paramsJson) as Record<string, Object>;
        if (p['facing'] !== undefined) facing = p['facing'] as string;
      } catch { /* use defaults */ }
    }

    this.log.info(TAG, `snap: facing=${facing}, using cameraPicker`);

    // Save photo to app sandbox
    let savePath: string = `${this.filesDir}/camera_snap_${Date.now()}.jpg`;
    let saveUri: string = `file://${savePath}`;

    let pickerProfile: cameraPicker.PickerProfile = new cameraPicker.PickerProfile();
    pickerProfile.cameraPosition = facing === 'front'
      ? camera.CameraPosition.CAMERA_POSITION_FRONT
      : camera.CameraPosition.CAMERA_POSITION_BACK;
    pickerProfile.saveUri = saveUri;

    let mediaTypes: cameraPicker.PickerMediaType[] = [cameraPicker.PickerMediaType.PHOTO];

    this.log.info(TAG, `Launching camera picker for photo, saveUri=${saveUri}`);
    let result: cameraPicker.PickerResult =
      await cameraPicker.pick(this.appContext, mediaTypes, pickerProfile);

    this.log.info(TAG, `Picker result: code=${result.resultCode} uri=${result.resultUri} type=${result.mediaType}`);

    if (result.resultCode !== 0) {
      throw new Error(`Camera picker cancelled or failed (code=${result.resultCode})`);
    }

    // Read the saved photo file
    let resultPath: string = result.resultUri;
    // Strip file:// prefix if present
    if (resultPath.startsWith('file://')) {
      resultPath = resultPath.substring(7);
    }

    let stat = fileIo.statSync(resultPath);
    this.log.info(TAG, `Photo file size: ${stat.size} bytes`);

    let file = fileIo.openSync(resultPath, fileIo.OpenMode.READ_ONLY);
    let buf = new ArrayBuffer(stat.size);
    fileIo.readSync(file.fd, buf);
    fileIo.closeSync(file);

    let base64Str: string = buffer.from(buf).toString('base64');
    this.log.info(TAG, `Photo base64 length: ${base64Str.length}`);

    // Clean up temp file
    try { fileIo.unlinkSync(resultPath); } catch { /* best effort */ }

    return `{"format":"jpg","base64":${JSON.stringify(base64Str)},"size":${stat.size}}`;
  }

  // ---- camera.clip: Record a short video via system camera picker ----

  private async clip(paramsJson: string | undefined): Promise<string> {
    if (!this.appContext) {
      throw new Error('Context not set, call setContext first');
    }

    let facing: string = 'back';
    let durationMs: number = 15000;

    if (paramsJson && paramsJson.length > 0) {
      try {
        let p = JSON.parse(paramsJson) as Record<string, Object>;
        if (p['facing'] !== undefined) facing = p['facing'] as string;
        if (p['durationMs'] !== undefined) durationMs = Math.max(1000, Math.min(60000, p['durationMs'] as number));
      } catch { /* use defaults */ }
    }

    this.log.info(TAG, `clip: facing=${facing} maxDuration=${durationMs}ms, using cameraPicker`);

    let savePath: string = `${this.filesDir}/camera_clip_${Date.now()}.mp4`;
    let saveUri: string = `file://${savePath}`;

    let pickerProfile: cameraPicker.PickerProfile = new cameraPicker.PickerProfile();
    pickerProfile.cameraPosition = facing === 'front'
      ? camera.CameraPosition.CAMERA_POSITION_FRONT
      : camera.CameraPosition.CAMERA_POSITION_BACK;
    pickerProfile.saveUri = saveUri;
    pickerProfile.videoDuration = Math.round(durationMs / 1000);

    let mediaTypes: cameraPicker.PickerMediaType[] = [cameraPicker.PickerMediaType.VIDEO];

    this.log.info(TAG, `Launching camera picker for video, saveUri=${saveUri}`);
    let result: cameraPicker.PickerResult =
      await cameraPicker.pick(this.appContext, mediaTypes, pickerProfile);

    this.log.info(TAG, `Picker result: code=${result.resultCode} uri=${result.resultUri} type=${result.mediaType}`);

    if (result.resultCode !== 0) {
      throw new Error(`Camera picker cancelled or failed (code=${result.resultCode})`);
    }

    // Read the saved video file
    let resultPath: string = result.resultUri;
    if (resultPath.startsWith('file://')) {
      resultPath = resultPath.substring(7);
    }

    let stat = fileIo.statSync(resultPath);
    this.log.info(TAG, `Video file size: ${stat.size} bytes`);

    let file = fileIo.openSync(resultPath, fileIo.OpenMode.READ_ONLY);
    let buf = new ArrayBuffer(stat.size);
    fileIo.readSync(file.fd, buf);
    fileIo.closeSync(file);

    let base64Str: string = buffer.from(buf).toString('base64');
    this.log.info(TAG, `Video base64 length: ${base64Str.length}`);

    // Clean up temp file
    try { fileIo.unlinkSync(resultPath); } catch { /* best effort */ }

    return `{"format":"mp4","base64":${JSON.stringify(base64Str)},"size":${stat.size}}`;
  }
}
