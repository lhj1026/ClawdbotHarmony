import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { MemoryItem } from '../model/Models';
import { MemoryService } from '../service/MemoryService';
import { I18n } from '../common/I18n';

@Component
export struct MemoryPage {
  @State entries: MemoryItem[] = [];
  @State filterType: string = 'all';
  @State showAddPanel: boolean = false;
  @State newContent: string = '';
  @State newType: string = 'fact';
  @State @Watch('onLangChange') lang: string = 'zh';

  private memSvc: MemoryService = MemoryService.getInstance();
  private typeFilters: string[] = ['all', 'fact', 'preference', 'instruction'];
  private langListener: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    this.reload();
    this.lang = I18n.lang;
    this.langListener = () => { this.lang = I18n.lang; };
    I18n.addListener(this.langListener);
  }

  aboutToDisappear(): void {
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
        Text(I18n.t('memory.title'))
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1A1A1A')
          .layoutWeight(1)

        Button(I18n.t('memory.add'))
          .fontSize(13)
          .height(32)
          .backgroundColor('#D2691E')
          .fontColor(Color.White)
          .borderRadius(16)
          .onClick(() => { this.showAddPanel = !this.showAddPanel; })

        Text('\uD83D\uDDD1')
          .fontSize(18)
          .margin({ left: 12 })
          .onClick(() => { this.confirmClear(); })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 8 })

      Text(I18n.t('memory.subtitle'))
        .fontSize(13)
        .fontColor('#666666')
        .padding({ left: 20, right: 20, bottom: 12 })
        .width('100%')

      // add panel
      if (this.showAddPanel) {
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            ForEach(['fact', 'preference', 'instruction'], (t: string) => {
              Text(this.typeLabel(t))
                .fontSize(12)
                .fontColor(this.newType === t ? Color.White : '#666666')
                .backgroundColor(this.newType === t ? this.typeColor(t) : '#F0F0F0')
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .borderRadius(12)
                .onClick(() => { this.newType = t; })
            }, (t: string): string => t)
          }

          TextArea({ placeholder: I18n.t('memory.placeholder'), text: this.newContent })
            .height(80)
            .borderRadius(8)
            .backgroundColor('#F5F5F5')
            .fontSize(14)
            .onChange((v: string) => { this.newContent = v; })

          Button(I18n.t('memory.save'))
            .width('100%')
            .height(38)
            .backgroundColor('#D2691E')
            .fontColor(Color.White)
            .borderRadius(8)
            .onClick(() => { this.addEntry(); })
        }
        .padding(16)
        .margin({ left: 16, right: 16, bottom: 8 })
        .backgroundColor(Color.White)
        .borderRadius(12)
      }

      // filter
      Row({ space: 8 }) {
        ForEach(this.typeFilters, (t: string) => {
          Text(t === 'all' ? I18n.t('memory.all') : this.typeLabel(t))
            .fontSize(12)
            .fontColor(this.filterType === t ? Color.White : '#666666')
            .backgroundColor(this.filterType === t ? '#D2691E' : Color.White)
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .borderRadius(14)
            .borderWidth(this.filterType === t ? 0 : 1)
            .borderColor('#E0E0E0')
            .onClick(() => { this.filterType = t; })
        }, (t: string): string => 'f_' + t)
      }
      .padding({ left: 20, right: 20, bottom: 10 })

      Text(this.filtered().length + I18n.t('memory.entries'))
        .fontSize(12)
        .fontColor('#999999')
        .padding({ left: 20, bottom: 6 })
        .width('100%')

      // entries list
      if (this.filtered().length === 0) {
        Column({ space: 10 }) {
          Text('\uD83E\uDDE0').fontSize(48)
          Text(I18n.t('memory.empty')).fontSize(16).fontColor('#999999')
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .width('100%')
      } else {
        List({ space: 8 }) {
          ForEach(this.filtered(), (item: MemoryItem) => {
            ListItem() {
              this.EntryCard(item)
            }
            .padding({ left: 16, right: 16 })
          }, (item: MemoryItem): string => item.id)
        }
        .layoutWeight(1)
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }

  @Builder
  EntryCard(item: MemoryItem) {
    Column({ space: 6 }) {
      Row() {
        Text(this.typeIcon(item.memType))
          .fontSize(14)
          .margin({ right: 6 })
        Text(this.typeLabel(item.memType))
          .fontSize(11)
          .fontColor(Color.White)
          .backgroundColor(this.typeColor(item.memType))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(4)
        Blank()
        Text('\u2716')
          .fontSize(14)
          .fontColor('#CCCCCC')
          .onClick(() => { this.removeEntry(item.id); })
      }
      .width('100%')

      Text(item.content)
        .fontSize(14)
        .fontColor('#1A1A1A')
        .lineHeight(20)
        .width('100%')

      Text(new Date(item.createdAt).toLocaleDateString())
        .fontSize(11)
        .fontColor('#BBBBBB')
    }
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(12)
    .shadow({ radius: 4, color: '#0000000A', offsetX: 0, offsetY: 2 })
    .width('100%')
  }

  // ============ logic ============

  private async reload(): Promise<void> {
    let ctx = getContext(this) as common.UIAbilityContext;
    this.entries = await this.memSvc.loadAll(ctx);
  }

  private filtered(): MemoryItem[] {
    if (this.filterType === 'all') return this.entries;
    return this.entries.filter((e): boolean => e.memType === this.filterType);
  }

  private async addEntry(): Promise<void> {
    if (this.newContent.trim().length === 0) return;
    let ctx = getContext(this) as common.UIAbilityContext;
    let item = await this.memSvc.add(ctx, this.newType, this.newContent.trim(), 0.8);
    this.entries.push(item);
    this.newContent = '';
    this.showAddPanel = false;
  }

  private async removeEntry(id: string): Promise<void> {
    let ctx = getContext(this) as common.UIAbilityContext;
    await this.memSvc.remove(ctx, id);
    this.entries = this.entries.filter((e): boolean => e.id !== id);
  }

  private confirmClear(): void {
    promptAction.showDialog({
      title: I18n.t('memory.clearTitle'),
      message: I18n.t('memory.clearMessage'),
      buttons: [
        { text: I18n.t('memory.cancel'), color: '#666666' },
        { text: I18n.t('memory.clear'), color: '#D32F2F' }
      ]
    }).then(async (result) => {
      if (result.index === 1) {
        let ctx = getContext(this) as common.UIAbilityContext;
        await this.memSvc.clearAll(ctx);
        this.entries = [];
      }
    });
  }

  private typeLabel(t: string): string {
    if (t === 'fact') return I18n.t('memory.fact');
    if (t === 'preference') return I18n.t('memory.preference');
    if (t === 'instruction') return I18n.t('memory.instruction');
    return t;
  }

  private typeIcon(t: string): string {
    if (t === 'fact') return '\uD83D\uDCCC';
    if (t === 'preference') return '\u2764\uFE0F';
    if (t === 'instruction') return '\uD83D\uDCDD';
    return '\uD83D\uDCBE';
  }

  private typeColor(t: string): string {
    if (t === 'fact') return '#1976D2';
    if (t === 'preference') return '#E91E63';
    if (t === 'instruction') return '#FF9800';
    return '#607D8B';
  }
}
