// Conversation card component for silent mode conversation list
import { SilentConversationItem } from '../model/Models';
import { t } from '../common/I18n';

@Component
export struct ConversationCard {
  @ObjectLink item: SilentConversationItem;
  onTap: () => void = () => {};
  onDelete: () => void = () => {};

  private statusIcon(): string {
    if (this.item.status === 'recording') return '🔴';
    if (this.item.status === 'summarizing') return '⏳';
    if (this.item.status === 'error') return '⚠️';
    return '✅';
  }

  private formatDuration(): string {
    let endMs = this.item.endTime > 0 ? this.item.endTime : Date.now();
    let sec = Math.floor((endMs - this.item.startTime) / 1000);
    if (sec < 60) return `${sec}s`;
    let min = Math.floor(sec / 60);
    sec = sec % 60;
    if (min < 60) return `${min}m ${sec}s`;
    let hr = Math.floor(min / 60);
    min = min % 60;
    return `${hr}h ${min}m`;
  }

  private formatDate(): string {
    let d = new Date(this.item.startTime);
    let month = String(d.getMonth() + 1).padStart(2, '0');
    let day = String(d.getDate()).padStart(2, '0');
    let hours = String(d.getHours()).padStart(2, '0');
    let minutes = String(d.getMinutes()).padStart(2, '0');
    return `${month}-${day} ${hours}:${minutes}`;
  }

  build() {
    Column() {
      // Title line (if available) or fallback to date
      if (this.item.title.length > 0) {
        Text(this.item.title)
          .fontSize(14)
          .fontColor('#1A1A1A')
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      // Top row: status icon + date + duration badge
      Row() {
        Text(this.statusIcon())
          .fontSize(14)
          .margin({ right: 6 })

        Text(this.formatDate())
          .fontSize(this.item.title.length > 0 ? 12 : 14)
          .fontColor(this.item.title.length > 0 ? '#999999' : '#333333')
          .fontWeight(this.item.title.length > 0 ? FontWeight.Normal : FontWeight.Medium)

        Blank()

        Text(this.formatDuration())
          .fontSize(11)
          .fontColor('#666666')
          .backgroundColor('#F0F0F0')
          .borderRadius(8)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
      }
      .width('100%')
      .margin({ top: this.item.title.length > 0 ? 4 : 0 })

      // Summary snippet (2-line max)
      if (this.item.summary.length > 0) {
        Text(this.item.summary)
          .fontSize(13)
          .fontColor('#666666')
          .margin({ top: 6 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      // Entry count + action item badge
      Row() {
        Text(`${this.item.entryCount} ${t('silent.entries')}`)
          .fontSize(11)
          .fontColor('#999999')

        if (this.item.actionItemCount > 0) {
          Text(`${this.item.actionItemCount} ${t('silent.actionItemBadge')}`)
            .fontSize(11)
            .fontColor('#007AFF')
            .backgroundColor('#E8F0FE')
            .borderRadius(8)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .margin({ left: 8 })
        }
      }
      .width('100%')
      .margin({ top: 6 })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(10)
    .shadow({ radius: 2, color: '#0000000D', offsetY: 1 })
    .onClick(() => {
      this.onTap();
    })
    .gesture(
      LongPressGesture()
        .onAction(() => {
          this.onDelete();
        })
    )
  }
}
