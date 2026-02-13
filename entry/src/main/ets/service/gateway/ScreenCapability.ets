/**
 * Handles screen.capture and screen.record commands from the gateway.
 * - screen.capture: Takes a snapshot of the app's UI via componentSnapshot or window.snapshot()
 *   (No system permission needed — captures current app window only.)
 * - screen.record: Not available for regular apps (requires CAPTURE_SCREEN permission).
 */
import { window, componentSnapshot } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { buffer } from '@kit.ArkTS';
import { LogService } from '../../common/LogService';
import { Command } from './GatewayProtocol';

const TAG = 'ScreenCap';

export class ScreenCapability {
  private static _instance: ScreenCapability | undefined = undefined;
  private log: LogService = LogService.getInstance();
  private context: Context | undefined = undefined;
  private filesDir: string = '';

  static getInstance(): ScreenCapability {
    if (!ScreenCapability._instance) {
      ScreenCapability._instance = new ScreenCapability();
    }
    return ScreenCapability._instance;
  }

  setContext(ctx: Context): void {
    this.context = ctx;
    this.filesDir = ctx.filesDir;
  }

  async execute(command: string, paramsJson: string | undefined): Promise<string> {
    this.log.info(TAG, `execute: command=${command} params=${paramsJson ?? 'none'}`);

    if (command === Command.SCREEN_CAPTURE) {
      return await this.capture();
    } else if (command === Command.SCREEN_RECORD) {
      throw new Error('Screen recording requires system permission (CAPTURE_SCREEN). Use screen.capture for screenshots.');
    }
    throw new Error(`Unsupported screen command: ${command}`);
  }

  // ---- screen.capture: App window snapshot ----

  private async capture(): Promise<string> {
    this.log.info(TAG, 'Taking app snapshot...');

    let pixelMap: image.PixelMap | undefined = undefined;

    // Method 1: componentSnapshot (captures the root UI component)
    try {
      pixelMap = await componentSnapshot.get('appRoot');
      this.log.info(TAG, 'componentSnapshot.get(appRoot) succeeded');
    } catch (err) {
      this.log.warn(TAG, `componentSnapshot failed: ${(err as Error).message ?? String(err)}`);
    }

    // Method 2: window.snapshot() fallback
    if (!pixelMap && this.context) {
      try {
        let windowInstance = await window.getLastWindow(this.context);
        pixelMap = await windowInstance.snapshot();
        this.log.info(TAG, 'window.snapshot() succeeded');
      } catch (err) {
        this.log.error(TAG, `window.snapshot() failed: ${(err as Error).message ?? String(err)}`);
      }
    }

    if (!pixelMap) {
      throw new Error('All screenshot methods failed. Check logs for details.');
    }

    let info = await pixelMap.getImageInfo();
    let width = info.size.width;
    let height = info.size.height;
    this.log.info(TAG, `Snapshot: ${width}x${height}`);

    // Compress to JPEG
    let packer = image.createImagePacker();
    let packOpts: image.PackingOption = {
      format: 'image/jpeg',
      quality: 75,
    };
    let jpegData: ArrayBuffer = await packer.packing(pixelMap, packOpts);
    packer.release();
    pixelMap.release();

    let base64: string = buffer.from(jpegData).toString('base64');
    this.log.info(TAG, `Screenshot JPEG: ${jpegData.byteLength} bytes, base64 len=${base64.length}`);

    // Save screenshot to persistent storage for display in chat
    let screenshotsDir = `${this.filesDir}/screenshots`;
    try { fileIo.mkdirSync(screenshotsDir); } catch { /* already exists */ }
    let persistPath = `${screenshotsDir}/screen_${Date.now()}.jpg`;
    let sf: fileIo.File = fileIo.openSync(persistPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
    fileIo.writeSync(sf.fd, jpegData);
    fileIo.closeSync(sf);
    this.log.info(TAG, `Screenshot saved to: ${persistPath}`);

    return `{"format":"jpeg","width":${width},"height":${height},"base64":${JSON.stringify(base64)},"size":${jpegData.byteLength},"filePath":${JSON.stringify(persistPath)}}`;
  }
}
