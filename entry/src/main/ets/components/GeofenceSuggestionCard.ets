/**
 * GeofenceSuggestionCard — 围栏建议卡片
 *
 * 当 LocationDiscoveryService 发现用户经常去某个位置时，
 * 显示此卡片建议添加围栏。
 *
 * 操作：
 *   - "添加围栏" → 展开编辑区域（可修改名称/类别）→ 确认添加
 *   - "忽略" → 永不再建议此位置
 *   - "以后再说" → 7 天后可能再次建议
 */
import { I18n } from '../common/I18n';

@Component
export struct GeofenceSuggestionCard {
  /** 建议数据 */
  @Prop suggestionId: string = '';
  @Prop name: string = '';
  @Prop category: string = '';
  @Prop reason: string = '';
  @Prop confidence: number = 0;
  @Prop latitude: number = 0;
  @Prop longitude: number = 0;
  @Prop radiusMeters: number = 0;

  /** 回调 */
  onAccept: (id: string, name: string, category: string) => void = () => {};
  onIgnore: (id: string) => void = () => {};
  onDefer: (id: string) => void = () => {};

  /** 内部状态 */
  @State editing: boolean = false;
  @State editName: string = '';
  @State selectedCatIndex: number = 5;
  @State dismissed: boolean = false;

  private catIds: string[] = ['home', 'work', 'gym', 'restaurant', 'shopping', 'custom'];
  @State catLabels: string[] = ['🏠 家', '🏢 公司', '💪 健身房', '🍜 餐厅', '🛒 购物', '📍 其他'];

  private static readonly catIcons: string[] = ['🏠', '🏢', '💪', '🍜', '🛒', '📍'];

  aboutToAppear(): void {
    // 用 I18n 初始化分类标签
    let labels: string[] = [];
    for (let i = 0; i < this.catIds.length; i++) {
      labels.push(GeofenceSuggestionCard.catIcons[i] + ' ' + I18n.t('place.category.' + this.catIds[i]));
    }
    this.catLabels = labels;
    this.editName = this.name;
    let idx = this.catIds.indexOf(this.category);
    this.selectedCatIndex = idx >= 0 ? idx : 5;
  }

  build() {
    Column() {
      // Header
      Row() {
        Text('📍')
          .fontSize(16)
        Text('发现你经常去这里')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#007AFF')
          .margin({ left: 6 })
        Blank()
        if (this.confidence > 0) {
          Text(Math.round(this.confidence * 100).toString() + '% 置信')
            .fontSize(11)
            .fontColor('#999999')
        }
      }
      .width('100%')

      // 建议信息
      Row() {
        Text(this.getCatIcon())
          .fontSize(28)
          .margin({ right: 12 })
        Column({ space: 4 }) {
          Text(this.name)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A1A')
          Text(this.reason)
            .fontSize(13)
            .fontColor('#666666')
            .maxLines(2)
          Text(this.latitude.toFixed(4) + ', ' + this.longitude.toFixed(4) +
            '  r=' + this.radiusMeters.toString() + 'm')
            .fontSize(11)
            .fontColor('#BBBBBB')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .margin({ top: 12 })

      if (this.editing) {
        // 编辑模式
        Column({ space: 10 }) {
          Divider().color('#F0F0F0').margin({ top: 12 })

          TextInput({ text: this.editName, placeholder: '围栏名称' })
            .onChange((val: string) => { this.editName = val; })
            .width('100%')
            .height(40)

          Text('选择类别')
            .fontSize(13)
            .fontColor('#666666')
            .width('100%')

          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.catLabels, (label: string) => {
              Text(label)
                .fontSize(12)
                .fontColor(this.selectedCatIndex === this.catLabels.indexOf(label) ? Color.White : '#1A1A1A')
                .backgroundColor(this.selectedCatIndex === this.catLabels.indexOf(label) ? '#007AFF' : '#F0F0F0')
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .borderRadius(14)
                .margin(3)
                .onClick(() => { this.selectedCatIndex = this.catLabels.indexOf(label); })
            }, (label: string) => label)
          }
          .width('100%')

          Row({ space: 12 }) {
            Button('取消')
              .fontSize(13)
              .backgroundColor('#F0F0F0')
              .fontColor('#666666')
              .layoutWeight(1)
              .height(36)
              .onClick(() => { this.editing = false; })
            Button('确认添加')
              .fontSize(13)
              .backgroundColor('#007AFF')
              .fontColor(Color.White)
              .layoutWeight(1)
              .height(36)
              .onClick(() => { this.confirmAdd(); })
          }
          .width('100%')
          .margin({ top: 4 })
        }
      } else {
        // 操作按钮
        Row({ space: 10 }) {
          Button('添加围栏')
            .fontSize(13)
            .backgroundColor('#007AFF')
            .fontColor(Color.White)
            .layoutWeight(1)
            .height(36)
            .onClick(() => { this.editing = true; })
          Button('忽略')
            .fontSize(13)
            .backgroundColor('#F0F0F0')
            .fontColor('#FF3B30')
            .layoutWeight(1)
            .height(36)
            .onClick(() => {
              this.onIgnore(this.suggestionId);
              this.dismissed = true;
            })
          Button('以后再说')
            .fontSize(13)
            .backgroundColor('#F0F0F0')
            .fontColor('#666666')
            .layoutWeight(1)
            .height(36)
            .onClick(() => {
              this.onDefer(this.suggestionId);
              this.dismissed = true;
            })
        }
        .width('100%')
        .margin({ top: 14 })
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(Color.White)
    .borderRadius(12)
    .shadow({ radius: 4, color: '#0000000D', offsetX: 0, offsetY: 2 })
    .visibility(this.dismissed ? Visibility.None : Visibility.Visible)
  }

  private getCatIcon(): string {
    if (this.category === 'home') return '🏠';
    if (this.category === 'work') return '🏢';
    if (this.category === 'gym') return '💪';
    if (this.category === 'restaurant') return '🍜';
    if (this.category === 'shopping') return '🛒';
    return '📍';
  }

  private confirmAdd(): void {
    let finalName = this.editName.length > 0 ? this.editName : this.name;
    let finalCategory = this.catIds[this.selectedCatIndex];
    this.onAccept(this.suggestionId, finalName, finalCategory);
    this.dismissed = true;
  }
}
