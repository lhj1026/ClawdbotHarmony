/**
 * Markdown document viewer page.
 * Receives content or file path via router params.
 * Renders markdown with full formatting support.
 */
import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { MarkdownText } from '../components/MarkdownText';

@Entry
@Component
struct DocViewerPage {
  @State content: string = '';
  @State title: string = '文档';
  @State loading: boolean = false;

  aboutToAppear(): void {
    let params = router.getParams() as Record<string, string> | undefined;
    if (params) {
      this.content = params['content'] ?? '';
      this.title = params['title'] ?? '文档';
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

        Text(this.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1A1A1A')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text('📋')
          .fontSize(18)
          .padding(8)
          .onClick(() => { this.copyContent(); })
      }
      .width('100%')
      .height(48)
      .padding({ left: 8, right: 8 })
      .backgroundColor(Color.White)

      // Divider
      Divider().color('#F0F0F0')

      // Content
      if (this.content.length === 0) {
        Column() {
          Text(this.loading ? '加载中...' : '无内容')
            .fontSize(14)
            .fontColor('#999999')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            MarkdownText({
              content: this.content,
              textColor: '#1A1A1A',
              baseFontSize: 15,
            })
          }
          .width('100%')
          .padding(16)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }

  private copyContent(): void {
    let data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.content);
    let board = pasteboard.getSystemPasteboard();
    board.setData(data);
    promptAction.showToast({ message: '已复制', duration: 1500 });
  }
}
