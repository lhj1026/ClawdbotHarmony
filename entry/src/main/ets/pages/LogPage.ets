import { LogService, LogEntry } from '../common/LogService';
import { I18n } from '../common/I18n';

@Component
export struct LogPage {
  @State logs: LogEntry[] = [];
  @State filterLevel: string = 'ALL';
  @State autoScroll: boolean = true;
  @State @Watch('onLangChange') lang: string = 'zh';

  private logSvc: LogService = LogService.getInstance();
  private logListener: (() => void) | undefined = undefined;
  private langListener: (() => void) | undefined = undefined;
  private scroller: Scroller = new Scroller();
  private levels: string[] = ['ALL', 'DEBUG', 'INFO', 'WARN', 'ERROR'];

  aboutToAppear(): void {
    this.logs = this.logSvc.getAll();
    this.logListener = () => {
      this.logs = this.logSvc.getFiltered(this.filterLevel);
      if (this.autoScroll) {
        setTimeout(() => {
          try { this.scroller.scrollEdge(Edge.Bottom); } catch { /* ignore */ }
        }, 50);
      }
    };
    this.logSvc.addListener(this.logListener);
    this.lang = I18n.lang;
    this.langListener = () => { this.lang = I18n.lang; };
    I18n.addListener(this.langListener);
  }

  aboutToDisappear(): void {
    if (this.logListener) {
      this.logSvc.removeListener(this.logListener);
      this.logListener = undefined;
    }
    if (this.langListener) {
      I18n.removeListener(this.langListener);
      this.langListener = undefined;
    }
  }

  onLangChange(): void {
    // triggers re-render
  }

  build() {
    Column() {
      // header
      Row() {
        Text(I18n.t('log.title'))
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1A1A1A')
          .layoutWeight(1)

        Text(I18n.t('log.clear'))
          .fontSize(13)
          .fontColor('#D32F2F')
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .borderRadius(8)
          .backgroundColor('#FFEBEE')
          .onClick(() => {
            this.logSvc.clear();
            this.logs = [];
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 8 })

      // filter chips
      Row({ space: 6 }) {
        ForEach(this.levels, (level: string) => {
          Text(level)
            .fontSize(11)
            .fontColor(this.filterLevel === level ? Color.White : '#666666')
            .backgroundColor(this.filterLevel === level ? this.levelColor(level) : '#F0F0F0')
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(12)
            .onClick(() => {
              this.filterLevel = level;
              this.logs = this.logSvc.getFiltered(level);
            })
        }, (level: string): string => level)

        Blank()

        Text(this.logs.length.toString() + ' ' + I18n.t('log.entries'))
          .fontSize(11)
          .fontColor('#999999')
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 8 })

      // log list
      if (this.logs.length === 0) {
        Column({ space: 10 }) {
          Text('\uD83D\uDCDD').fontSize(48)
          Text(I18n.t('log.empty')).fontSize(16).fontColor('#999999')
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .width('100%')
      } else {
        List({ space: 2, scroller: this.scroller }) {
          ForEach(this.logs, (entry: LogEntry, index: number) => {
            ListItem() {
              Column({ space: 2 }) {
                Row({ space: 6 }) {
                  Text(this.formatTime(entry.timestamp))
                    .fontSize(10)
                    .fontColor('#999999')
                    .fontFamily('monospace')
                  Text(entry.level)
                    .fontSize(9)
                    .fontColor(Color.White)
                    .fontWeight(FontWeight.Bold)
                    .backgroundColor(this.levelColor(entry.level))
                    .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                    .borderRadius(3)
                  Text(entry.tag)
                    .fontSize(10)
                    .fontColor('#1976D2')
                    .fontWeight(FontWeight.Medium)
                }
                .width('100%')
                .justifyContent(FlexAlign.Start)

                Text(entry.message)
                  .fontSize(12)
                  .fontColor(entry.level === 'ERROR' ? '#D32F2F' : entry.level === 'WARN' ? '#F57C00' : '#333333')
                  .lineHeight(16)
                  .width('100%')
                  .maxLines(5)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .padding({ left: 12, right: 12, top: 4, bottom: 4 })
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .backgroundColor(entry.level === 'ERROR' ? '#FFF5F5' : entry.level === 'WARN' ? '#FFFBF0' : Color.White)
            }
          }, (_entry: LogEntry, index: number): string => index.toString())
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }

  private formatTime(ts: number): string {
    let d = new Date(ts);
    let h = d.getHours().toString().padStart(2, '0');
    let m = d.getMinutes().toString().padStart(2, '0');
    let s = d.getSeconds().toString().padStart(2, '0');
    let ms = d.getMilliseconds().toString().padStart(3, '0');
    return `${h}:${m}:${s}.${ms}`;
  }

  private levelColor(level: string): string {
    if (level === 'ERROR') return '#D32F2F';
    if (level === 'WARN') return '#F57C00';
    if (level === 'INFO') return '#1976D2';
    if (level === 'DEBUG') return '#607D8B';
    return '#D2691E';
  }

  private levelIcon(level: string): string {
    if (level === 'ERROR') return '\u274C';
    if (level === 'WARN') return '\u26A0\uFE0F';
    if (level === 'INFO') return '\u2139\uFE0F';
    if (level === 'DEBUG') return '\uD83D\uDD0D';
    return '\uD83D\uDCDD';
  }
}
