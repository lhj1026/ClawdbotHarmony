import { router } from '@kit.ArkUI';
import { NetworkDiagPage } from './NetworkDiagPage';

@Entry
@Component
struct NetworkDiagRoutePage {
  build() {
    Column() {
      // Header with back button
      Row() {
        Text('←')
          .fontSize(22)
          .fontColor('#1A1A1A')
          .padding(8)
          .onClick(() => { router.back(); })

        Text('🔧 网络诊断')
          .fontSize(17)
          .fontColor('#1A1A1A')
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
      }
      .width('100%')
      .height(44)
      .padding({ left: 8, right: 16 })
      .backgroundColor(Color.White)

      NetworkDiagPage()
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }
}
