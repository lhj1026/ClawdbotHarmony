/**
 * Full-screen log text viewer page.
 * Receives log text via router params and displays it in a scrollable view.
 */
import { router } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { I18n } from '../common/I18n';

@Entry
@Component
struct LogViewerPage {
  @State logText: string = '';
  @State fileName: string = '';

  aboutToAppear(): void {
    let params = router.getParams() as Record<string, string> | undefined;
    if (params) {
      this.logText = params['text'] ?? '';
      this.fileName = params['fileName'] ?? 'log.txt';
    }
  }

  build() {
    Column() {
      // Header
      Row() {
        Text('\u2190')
          .fontSize(22)
          .fontColor('#1A1A1A')
          .padding(8)
          .onClick(() => { router.back(); })

        Text(this.fileName)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1A1A1A')
          .layoutWeight(1)
          .margin({ left: 4 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(I18n.t('log.copy'))
          .fontSize(13)
          .fontColor('#1976D2')
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(8)
          .backgroundColor('#E3F2FD')
          .onClick(() => {
            let pasteData: pasteboard.PasteData =
              pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.logText);
            let sysBoard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
            sysBoard.setData(pasteData);
            promptAction.showToast({ message: I18n.t('log.copied'), duration: 2000 });
          })
      }
      .width('100%')
      .height(50)
      .padding({ left: 8, right: 16 })
      .backgroundColor(Color.White)
      .shadow({ radius: 2, color: '#00000008', offsetY: 1 })

      // Log content
      Scroll() {
        Text(this.logText)
          .fontSize(11)
          .fontColor('#333333')
          .fontFamily('monospace')
          .lineHeight(16)
          .width('100%')
          .padding(12)
          .copyOption(CopyOptions.LocalDevice)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .backgroundColor('#FAFAFA')
    }
    .width('100%')
    .height('100%')
  }
}
