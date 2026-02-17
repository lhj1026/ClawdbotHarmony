import { MemoryPage } from './MemoryPage';
import { router } from '@kit.ArkUI';

@Entry
@Component
struct MemoryRoutePage {
  build() {
    Column() {
      // Header with back button
      Row() {
        Text('\u2190')
          .fontSize(22)
          .fontColor('#1A1A1A')
          .padding(8)
          .onClick(() => { router.back(); })

        Text('')
          .layoutWeight(1)
      }
      .width('100%')
      .height(44)
      .padding({ left: 8, right: 16 })
      .backgroundColor(Color.White)

      MemoryPage({ isActive: true })
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }
}
