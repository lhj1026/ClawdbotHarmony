import { ChatMessage } from '../model/Models';
import { I18n } from '../common/I18n';

@Component
export struct MessageBubble {
  @ObjectLink message: ChatMessage;

  build() {
    if (this.message.role === 'user') {
      this.UserBubble()
    } else if (this.message.isToolCall) {
      this.ToolCallBubble()
    } else if (this.message.role === 'tool') {
      this.ToolResultBubble()
    } else {
      this.AssistantBubble()
    }
  }

  @Builder
  UserBubble() {
    Row() {
      Blank()
      Text(this.message.content)
        .fontSize(15)
        .fontColor(Color.White)
        .lineHeight(22)
        .padding(12)
        .backgroundColor('#D2691E')
        .borderRadius({
          topLeft: 16, topRight: 4, bottomLeft: 16, bottomRight: 16
        })
        .constraintSize({ maxWidth: '75%' })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 4, bottom: 4 })
  }

  @Builder
  AssistantBubble() {
    Row() {
      Text('C')
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .textAlign(TextAlign.Center)
        .width(30)
        .height(30)
        .borderRadius(15)
        .backgroundColor('#D2691E')
        .margin({ right: 8, top: 2 })

      Text(this.message.content)
        .fontSize(15)
        .fontColor('#1A1A1A')
        .lineHeight(22)
        .padding(12)
        .backgroundColor('#F0F0F0')
        .borderRadius({
          topLeft: 4, topRight: 16, bottomLeft: 16, bottomRight: 16
        })
        .constraintSize({ maxWidth: '72%' })

      Blank()
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 4, bottom: 4 })
  }

  @Builder
  ToolCallBubble() {
    Row() {
      Blank().width(38)
      Column() {
        Row({ space: 6 }) {
          Text('\u2699')
            .fontSize(13)
          Text(this.message.toolName)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#795548')
        }

        if (this.message.toolInput.length > 0) {
          Text(this.formatJson(this.message.toolInput))
            .fontSize(11)
            .fontColor('#EEFFFF')
            .fontFamily('monospace')
            .padding(8)
            .backgroundColor('#263238')
            .borderRadius(6)
            .margin({ top: 4 })
            .constraintSize({ maxHeight: 80 })
        }
      }
      .padding(10)
      .backgroundColor('#FFF8E1')
      .borderRadius(10)
      .constraintSize({ maxWidth: '72%' })

      Blank()
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 2, bottom: 2 })
  }

  @Builder
  ToolResultBubble() {
    Row() {
      Blank().width(38)
      Column() {
        Row({ space: 4 }) {
          Text('\u2713')
            .fontSize(13)
            .fontColor('#388E3C')
          Text(this.message.toolName + ' ' + I18n.t('chat.toolResult'))
            .fontSize(12)
            .fontColor('#666666')
        }

        Text(this.formatJson(this.message.toolOutput))
          .fontSize(11)
          .fontColor('#EEFFFF')
          .fontFamily('monospace')
          .padding(8)
          .backgroundColor('#263238')
          .borderRadius(6)
          .margin({ top: 4 })
          .constraintSize({ maxHeight: 80 })
      }
      .padding(10)
      .backgroundColor('#F5F5F5')
      .borderRadius(10)
      .borderWidth(1)
      .borderColor('#E0E0E0')
      .constraintSize({ maxWidth: '72%' })

      Blank()
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 2, bottom: 2 })
  }

  private formatJson(s: string): string {
    try {
      return JSON.stringify(JSON.parse(s), null, 2);
    } catch {
      return s;
    }
  }
}
