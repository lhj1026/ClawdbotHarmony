/**
 * Handles canvas.* commands from the gateway.
 * Manages a WebView via CanvasPage for presenting web content,
 * evaluating JavaScript, and taking snapshots.
 */
import { webview } from '@kit.ArkWeb';
import { image } from '@kit.ImageKit';
import { buffer } from '@kit.ArkTS';
import { router } from '@kit.ArkUI';
import { componentSnapshot } from '@kit.ArkUI';
import { LogService } from '../../common/LogService';
import { Command } from './GatewayProtocol';

const TAG = 'CanvasCap';

export class CanvasCapability {
  private log: LogService = LogService.getInstance();
  private controller: webview.WebviewController | undefined = undefined;
  private _isPresented: boolean = false;

  /** Called by CanvasPage when it appears, to register its controller */
  registerController(ctrl: webview.WebviewController): void {
    this.controller = ctrl;
    this.log.info(TAG, 'WebviewController registered');
  }

  /** Called by CanvasPage when it disappears */
  unregisterController(): void {
    this.controller = undefined;
    this._isPresented = false;
    this.log.info(TAG, 'WebviewController unregistered');
  }

  get isPresented(): boolean {
    return this._isPresented;
  }

  async execute(command: string, paramsJson: string | undefined): Promise<string> {
    this.log.info(TAG, `execute: command=${command} params=${paramsJson ?? 'none'}`);

    switch (command) {
      case Command.CANVAS_PRESENT:
        return await this.present(paramsJson);
      case Command.CANVAS_HIDE:
        return await this.hide();
      case Command.CANVAS_NAVIGATE:
        return await this.navigate(paramsJson);
      case Command.CANVAS_EVAL:
        return await this.evalJS(paramsJson);
      case Command.CANVAS_SNAPSHOT:
        return await this.snapshot(paramsJson);
      default:
        throw new Error(`Unsupported canvas command: ${command}`);
    }
  }

  // ---- canvas.present: Show WebView with URL ----

  private async present(paramsJson: string | undefined): Promise<string> {
    let url: string = 'about:blank';

    if (paramsJson && paramsJson.length > 0) {
      try {
        let p = JSON.parse(paramsJson) as Record<string, string>;
        if (p['url'] !== undefined) url = p['url'];
      } catch { /* use default */ }
    }

    this.log.info(TAG, `present: url=${url}`);

    if (this._isPresented && this.controller) {
      // Already showing, just navigate to new URL
      this.controller.loadUrl(url);
      return `{"ok":true,"action":"navigated","url":${JSON.stringify(url)}}`;
    }

    // Navigate to CanvasPage
    // Store the URL so CanvasPage can pick it up
    CanvasCapability._pendingUrl = url;
    this._isPresented = true;

    try {
      await router.pushUrl({
        url: 'pages/CanvasPage',
      });
    } catch (err) {
      this._isPresented = false;
      throw new Error(`Failed to open CanvasPage: ${(err as Error).message ?? 'unknown'}`);
    }

    // Wait a bit for the page to initialize and register the controller
    await this.waitForController(5000);

    return `{"ok":true,"action":"presented","url":${JSON.stringify(url)}}`;
  }

  // ---- canvas.hide: Close the WebView page ----

  private async hide(): Promise<string> {
    this.log.info(TAG, 'hide');

    if (!this._isPresented) {
      return '{"ok":true,"action":"already_hidden"}';
    }

    try {
      router.back();
    } catch (err) {
      this.log.warn(TAG, `router.back failed: ${(err as Error).message ?? ''}`);
    }

    this._isPresented = false;
    this.controller = undefined;
    return '{"ok":true,"action":"hidden"}';
  }

  // ---- canvas.navigate: Load a new URL ----

  private async navigate(paramsJson: string | undefined): Promise<string> {
    if (!this.controller) {
      throw new Error('Canvas not presented. Call canvas.present first.');
    }

    let url: string = '';
    if (paramsJson && paramsJson.length > 0) {
      try {
        let p = JSON.parse(paramsJson) as Record<string, string>;
        if (p['url'] !== undefined) url = p['url'];
      } catch {
        throw new Error('Invalid params for canvas.navigate');
      }
    }

    if (url.length === 0) {
      throw new Error('canvas.navigate requires "url" param');
    }

    this.log.info(TAG, `navigate: url=${url}`);
    this.controller.loadUrl(url);
    return `{"ok":true,"url":${JSON.stringify(url)}}`;
  }

  // ---- canvas.eval: Execute JavaScript in the WebView ----

  private async evalJS(paramsJson: string | undefined): Promise<string> {
    if (!this.controller) {
      throw new Error('Canvas not presented. Call canvas.present first.');
    }

    let javaScript: string = '';
    if (paramsJson && paramsJson.length > 0) {
      try {
        let p = JSON.parse(paramsJson) as Record<string, string>;
        if (p['javaScript'] !== undefined) javaScript = p['javaScript'];
        if (p['javascript'] !== undefined) javaScript = p['javascript'];
        if (p['js'] !== undefined) javaScript = p['js'];
      } catch {
        throw new Error('Invalid params for canvas.eval');
      }
    }

    if (javaScript.length === 0) {
      throw new Error('canvas.eval requires "javaScript" param');
    }

    this.log.info(TAG, `eval: js=${javaScript.substring(0, 200)}`);

    let result: string = await this.controller.runJavaScript(javaScript);
    this.log.info(TAG, `eval result: ${result.substring(0, 200)}`);

    return `{"ok":true,"result":${JSON.stringify(result)}}`;
  }

  // ---- canvas.snapshot: Take a screenshot of the WebView ----

  private async snapshot(paramsJson: string | undefined): Promise<string> {
    if (!this.controller) {
      throw new Error('Canvas not presented. Call canvas.present first.');
    }

    let quality: number = 80;
    if (paramsJson && paramsJson.length > 0) {
      try {
        let p = JSON.parse(paramsJson) as Record<string, Object>;
        if (p['quality'] !== undefined) {
          let q: number = p['quality'] as number;
          quality = q <= 1 ? Math.round(q * 100) : Math.round(q);
        }
      } catch { /* use defaults */ }
    }

    this.log.info(TAG, `snapshot: quality=${quality}`);

    // Use componentSnapshot to capture the Web component by its ID
    let pixelMap: image.PixelMap = await componentSnapshot.get('canvasWebView');

    let imageInfo: image.ImageInfo = await pixelMap.getImageInfo();
    let width: number = imageInfo.size.width;
    let height: number = imageInfo.size.height;
    this.log.info(TAG, `snapshot pixelMap: ${width}x${height}`);

    // Pack into image using ImagePacker
    let packer: image.ImagePacker = image.createImagePacker();
    let packOpts: image.PackingOption = {
      format: 'image/jpeg',
      quality: quality,
    };
    let jpegData: ArrayBuffer = await packer.packing(pixelMap, packOpts);
    packer.release();
    pixelMap.release();

    let base64Str: string = buffer.from(jpegData).toString('base64');
    this.log.info(TAG, `snapshot: ${jpegData.byteLength} bytes, base64=${base64Str.length}`);

    return `{"format":"jpg","base64":${JSON.stringify(base64Str)},"width":${width},"height":${height}}`;
  }

  // ---- Helpers ----

  /** Pending URL for CanvasPage to load on init */
  static _pendingUrl: string = 'about:blank';

  private waitForController(timeoutMs: number): Promise<void> {
    return new Promise<void>((resolve) => {
      let elapsed: number = 0;
      let interval: number = 100;
      let check = (): void => {
        if (this.controller || elapsed >= timeoutMs) {
          resolve();
          return;
        }
        elapsed += interval;
        setTimeout(check, interval);
      };
      setTimeout(check, interval);
    });
  }
}
