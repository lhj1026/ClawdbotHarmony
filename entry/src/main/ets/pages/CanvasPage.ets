/**
 * Full-screen WebView page for the Canvas capability.
 * Presented by CanvasCapability when canvas.present is invoked.
 */
import { webview } from '@kit.ArkWeb';
import { router } from '@kit.ArkUI';
import { LogService } from '../common/LogService';
import { CanvasCapability } from '../service/gateway/CanvasCapability';
import { NodeRuntime } from '../service/gateway/NodeRuntime';

const TAG = 'CanvasPage';

@Entry
@Component
struct CanvasPage {
  private log: LogService = LogService.getInstance();
  private controller: webview.WebviewController = new webview.WebviewController();
  @State title: string = 'Canvas';
  @State url: string = '';
  @State loading: boolean = true;

  aboutToAppear(): void {
    this.url = CanvasCapability._pendingUrl;
    this.log.info(TAG, `aboutToAppear: url=${this.url}`);

    // Register controller with the CanvasCapability in NodeRuntime
    let runtime = NodeRuntime.getInstance();
    let canvasCap = runtime.getCanvasCapability();
    if (canvasCap) {
      canvasCap.registerController(this.controller);
    }
  }

  aboutToDisappear(): void {
    this.log.info(TAG, 'aboutToDisappear');
    let runtime = NodeRuntime.getInstance();
    let canvasCap = runtime.getCanvasCapability();
    if (canvasCap) {
      canvasCap.unregisterController();
    }
  }

  build() {
    Column() {
      // Header bar with back button and title
      Row() {
        Button() {
          Text('<')
            .fontSize(20)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Bold)
        }
        .width(40)
        .height(40)
        .backgroundColor('#00000000')
        .onClick(() => {
          router.back();
        })

        Text(this.title)
          .fontSize(16)
          .fontColor('#FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .margin({ left: 8 })

        if (this.loading) {
          LoadingProgress()
            .width(24)
            .height(24)
            .color('#FFFFFF')
        }
      }
      .width('100%')
      .height(48)
      .backgroundColor('#1A1A2E')
      .padding({ left: 12, right: 12 })
      .alignItems(VerticalAlign.Center)

      // WebView
      Web({ src: this.url, controller: this.controller })
        .id('canvasWebView')
        .width('100%')
        .layoutWeight(1)
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(true)
        .mixedMode(MixedMode.All)
        .onTitleReceive((event: OnTitleReceiveEvent) => {
          this.title = event.title;
        })
        .onPageBegin((event: OnPageBeginEvent) => {
          this.loading = true;
        })
        .onPageEnd((event: OnPageEndEvent) => {
          this.loading = false;
        })
        .onErrorReceive((event: OnErrorReceiveEvent) => {
          this.log.error(TAG, `Web error: code=${event.error.getErrorCode()} msg=${event.error.getErrorInfo()}`);
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }
}
