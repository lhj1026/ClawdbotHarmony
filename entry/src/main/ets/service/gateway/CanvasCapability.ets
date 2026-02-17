/**
 * Handles canvas.* commands from the gateway.
 * Manages a WebView via CanvasPage for presenting web content,
 * evaluating JavaScript, and taking snapshots.
 */
import { webview } from '@kit.ArkWeb';
import { image } from '@kit.ImageKit';
import { buffer } from '@kit.ArkTS';
import { router, window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { LogService } from '../../common/LogService';
import { Command } from './GatewayProtocol';

const TAG = 'CanvasCap';

export class CanvasCapability {
  private static instance: CanvasCapability | undefined = undefined;

  static getInstance(): CanvasCapability {
    if (!CanvasCapability.instance) {
      CanvasCapability.instance = new CanvasCapability();
    }
    return CanvasCapability.instance;
  }

  private log: LogService = LogService.getInstance();
  private controller: webview.WebviewController | undefined = undefined;
  private context: common.UIAbilityContext | undefined = undefined;
  private _isPresented: boolean = false;
  private _a2uiMode: boolean = false;
  private _a2uiReady: boolean = false;
  private _pendingA2UIContent: string[] = [];
  private _controllerResolve: (() => void) | undefined = undefined;
  private _pageLoadResolve: (() => void) | undefined = undefined;

  /** Callback for A2UI action events from WebView */
  onA2UIAction: ((actionJson: string) => void) | undefined = undefined;

  /** Set context for window.snapshot() */
  setContext(ctx: common.UIAbilityContext): void {
    this.context = ctx;
  }

  /** Called by CanvasPage when it appears, to register its controller */
  registerController(ctrl: webview.WebviewController): void {
    this.controller = ctrl;
    this.log.info(TAG, 'WebviewController registered');
    if (this._controllerResolve) {
      this._controllerResolve();
      this._controllerResolve = undefined;
    }
  }

  /** Called by CanvasPage when page finishes loading */
  notifyPageLoaded(): void {
    this.log.info(TAG, 'Page loaded');
    if (this._a2uiMode) {
      this._a2uiReady = true;
      // Flush any pending A2UI content
      this.flushPendingA2UI();
    }
    if (this._pageLoadResolve) {
      this._pageLoadResolve();
      this._pageLoadResolve = undefined;
    }
  }

  /** Called by CanvasPage when it disappears */
  unregisterController(): void {
    this.controller = undefined;
    this._isPresented = false;
    this._a2uiMode = false;
    this._a2uiReady = false;
    this._pendingA2UIContent = [];
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
      case Command.CANVAS_A2UI_PUSH:
      case Command.CANVAS_A2UI_PUSH_JSONL:
        return await this.pushA2UI(paramsJson);
      case Command.CANVAS_A2UI_RESET:
        return await this.resetA2UI();
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

    // Use window.snapshot() to capture WebView content (componentSnapshot cannot capture WebView)
    let pixelMap: image.PixelMap | undefined = undefined;

    if (this.context) {
      try {
        let windowInstance = await window.getLastWindow(this.context);
        pixelMap = await windowInstance.snapshot();
        this.log.info(TAG, 'window.snapshot() succeeded');
      } catch (err) {
        this.log.error(TAG, `window.snapshot() failed: ${(err as Error).message ?? String(err)}`);
      }
    }

    if (!pixelMap) {
      throw new Error('Snapshot failed. Context may not be set or window unavailable.');
    }

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

  // ---- canvas.a2ui.push: Push A2UI JSONL content ----

  private async pushA2UI(paramsJson: string | undefined): Promise<string> {
    // Extract JSONL content from params first
    let jsonlContent: string = this.extractA2UIContent(paramsJson);
    if (jsonlContent.length === 0) {
      return '{"ok":true,"action":"no_content"}';
    }

    this.log.info(TAG, `pushA2UI: ${jsonlContent.length} chars, ready=${this._a2uiReady}`);

    // Auto-present with local A2UI renderer if not already shown
    if (!this._isPresented || !this.controller) {
      this._a2uiMode = true;
      this._a2uiReady = false;
      // Queue content - will be flushed when page loads
      this._pendingA2UIContent.push(jsonlContent);

      let a2uiUrl: string = 'resource://rawfile/a2ui/index.html';
      CanvasCapability._pendingUrl = a2uiUrl;
      this._isPresented = true;

      try {
        await router.pushUrl({ url: 'pages/CanvasPage' });
      } catch (err) {
        this._isPresented = false;
        this._a2uiMode = false;
        this._pendingA2UIContent = [];
        throw new Error(`Failed to open CanvasPage: ${(err as Error).message ?? 'unknown'}`);
      }

      // Wait for controller + page load (notifyPageLoaded will flush queue)
      await this.waitForReady(5000);
      return '{"ok":true}';
    }

    if (!this._a2uiMode) {
      // Canvas is showing a regular URL, switch to A2UI
      this._a2uiMode = true;
      this._a2uiReady = false;
      this._pendingA2UIContent.push(jsonlContent);
      this.controller.loadUrl('resource://rawfile/a2ui/index.html');
      await this.waitForReady(3000);
      return '{"ok":true}';
    }

    // Already ready - inject directly
    if (this._a2uiReady && this.controller) {
      this.injectA2UI(jsonlContent);
    } else {
      // Still loading, queue it
      this._pendingA2UIContent.push(jsonlContent);
    }

    return '{"ok":true}';
  }

  private extractA2UIContent(paramsJson: string | undefined): string {
    if (!paramsJson || paramsJson.length === 0) return '';
    try {
      let p = JSON.parse(paramsJson) as Record<string, Object>;
      if (p['lines'] !== undefined) return p['lines'] as string;
      if (p['content'] !== undefined) return p['content'] as string;
      if (p['jsonl'] !== undefined) return p['jsonl'] as string;
      return paramsJson;
    } catch {
      return paramsJson;
    }
  }

  private injectA2UI(content: string): void {
    if (!this.controller) return;
    let escaped: string = content.replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/\n/g, '\\n');
    this.controller.runJavaScript(`window.a2ui.push('${escaped}')`);
  }

  private flushPendingA2UI(): void {
    if (this._pendingA2UIContent.length === 0 || !this.controller) return;
    this.log.info(TAG, `Flushing ${this._pendingA2UIContent.length} pending A2UI messages`);
    let all: string = this._pendingA2UIContent.join('\n');
    this._pendingA2UIContent = [];
    this.injectA2UI(all);
  }

  private waitForReady(timeoutMs: number): Promise<void> {
    if (this._a2uiReady) return Promise.resolve();
    return new Promise<void>((resolve) => {
      this._pageLoadResolve = resolve;
      setTimeout(() => {
        if (this._pageLoadResolve === resolve) {
          this._pageLoadResolve = undefined;
          this.log.warn(TAG, 'waitForReady timed out');
          // Force flush anyway
          if (this.controller && this._pendingA2UIContent.length > 0) {
            this._a2uiReady = true;
            this.flushPendingA2UI();
          }
          resolve();
        }
      }, timeoutMs);
    });
  }

  // ---- canvas.a2ui.reset: Clear A2UI state ----

  private async resetA2UI(): Promise<string> {
    this.log.info(TAG, 'resetA2UI');

    if (this._isPresented && this.controller && this._a2uiMode) {
      await this.controller.runJavaScript('window.a2ui.reset()');
    }

    return '{"ok":true}';
  }

  /** Called by CanvasPage when A2UI action event is received from WebView */
  handleA2UIAction(actionJson: string): void {
    this.log.info(TAG, `A2UI action received: ${actionJson.substring(0, 200)}`);
    if (this.onA2UIAction) {
      this.log.info(TAG, `Calling onA2UIAction callback...`);
      this.onA2UIAction(actionJson);
    } else {
      this.log.warn(TAG, `A2UI action DROPPED - no callback registered!`);
    }
  }

  // ---- Helpers ----

  /** Pending URL for CanvasPage to load on init */
  static _pendingUrl: string = 'about:blank';

  private waitForController(timeoutMs: number): Promise<void> {
    if (this.controller) return Promise.resolve();
    return new Promise<void>((resolve) => {
      this._controllerResolve = resolve;
      setTimeout(() => {
        if (this._controllerResolve === resolve) {
          this._controllerResolve = undefined;
          this.log.warn(TAG, 'waitForController timed out');
          resolve();
        }
      }, timeoutMs);
    });
  }
}
