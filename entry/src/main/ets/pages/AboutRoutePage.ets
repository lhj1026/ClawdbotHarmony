// About route page wrapper
import { router } from '@kit.ArkUI';
import { I18n, t } from '../common/I18n';

@Entry
@Component
struct AboutRoutePage {
  @State lang: string = I18n.currentLang;

  @Builder
  InfoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontColor('#666666')
      Blank()
      Text(value)
        .fontSize(14)
        .fontColor('#333333')
    }
    .width('100%')
    .padding({ top: 14, bottom: 14 })
  }

  build() {
    Column() {
      // Header
      Row() {
        Image($r('app.media.ic_back'))
          .width(24)
          .height(24)
          .fillColor('#333333')
          .onClick(() => {
            router.back();
          })

        Text(t('settings.about'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#333333')
          .margin({ left: 16 })

        Blank()
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .backgroundColor('#FFFFFF')

      // Content
      Scroll() {
        Column() {
          // App icon and name
          Column() {
            Image($r('app.media.app_icon'))
              .width(80)
              .height(80)
              .borderRadius(16)
              .margin({ top: 32, bottom: 16 })

            Text('ClawdBot')
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .fontColor('#333333')

            Text(t('settings.appValue'))
              .fontSize(14)
              .fontColor('#999999')
              .margin({ top: 4, bottom: 32 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)

          // Info card
          Column() {
            this.InfoRow(t('settings.version'), '2.18.11')
            Divider().color('#F0F0F0')
            this.InfoRow(t('settings.basedOn'), 'OpenClaw / ClawdBot')
            Divider().color('#F0F0F0')
            this.InfoRow(t('settings.platform'), 'HarmonyOS NEXT')
          }
          .padding(16)
          .margin({ left: 16, right: 16 })
          .backgroundColor(Color.White)
          .borderRadius(12)

          // Links
          Column() {
            Row() {
              Text('🔗')
                .fontSize(16)
                .margin({ right: 12 })
              Text('GitHub')
                .fontSize(14)
                .fontColor('#007AFF')
              Blank()
              Text('→')
                .fontSize(14)
                .fontColor('#CCCCCC')
            }
            .width('100%')
            .padding({ top: 14, bottom: 14 })

            Divider().color('#F0F0F0')

            Row() {
              Text('📖')
                .fontSize(16)
                .margin({ right: 12 })
              Text(t('settings.docs') || 'Documentation')
                .fontSize(14)
                .fontColor('#007AFF')
              Blank()
              Text('→')
                .fontSize(14)
                .fontColor('#CCCCCC')
            }
            .width('100%')
            .padding({ top: 14, bottom: 14 })

            Divider().color('#F0F0F0')

            Row() {
              Text('💬')
                .fontSize(16)
                .margin({ right: 12 })
              Text('Discord')
                .fontSize(14)
                .fontColor('#007AFF')
              Blank()
              Text('→')
                .fontSize(14)
                .fontColor('#CCCCCC')
            }
            .width('100%')
            .padding({ top: 14, bottom: 14 })
          }
          .padding({ left: 16, right: 16 })
          .margin({ left: 16, right: 16, top: 16 })
          .backgroundColor(Color.White)
          .borderRadius(12)

          // Footer
          Text('© 2026 OpenClaw')
            .fontSize(12)
            .fontColor('#CCCCCC')
            .margin({ top: 32, bottom: 32 })
        }
        .width('100%')
      }
      .layoutWeight(1)
      .backgroundColor('#F5F5F5')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }
}
