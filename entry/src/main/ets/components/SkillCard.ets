import { SkillItem } from '../model/Models';
import { I18n } from '../common/I18n';

@Component
export struct SkillCard {
  @ObjectLink skill: SkillItem;
  onToggle: (id: string, on: boolean) => void = () => {};

  build() {
    Row() {
      // icon
      Text(this.iconFor(this.skill.category))
        .fontSize(22)
        .width(42)
        .height(42)
        .textAlign(TextAlign.Center)
        .borderRadius(10)
        .backgroundColor(this.skill.enabled ? '#D2691E15' : '#F5F5F5')

      // info
      Column() {
        Row({ space: 6 }) {
          Text(this.skill.name)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.skill.enabled ? '#1A1A1A' : '#999999')
          if (this.skill.isBuiltin) {
            Text(I18n.t('skills.builtin'))
              .fontSize(9)
              .fontColor(Color.White)
              .backgroundColor('#B0BEC5')
              .borderRadius(4)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          }
        }

        Text(this.skill.description)
          .fontSize(12)
          .fontColor('#666666')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })

        Text(this.skill.toolCount + ' ' + I18n.t('skills.countTools'))
          .fontSize(11)
          .fontColor('#999999')
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })

      // toggle
      Toggle({ type: ToggleType.Switch, isOn: this.skill.enabled })
        .selectedColor('#D2691E')
        .onChange((isOn: boolean) => {
          this.onToggle(this.skill.id, isOn);
        })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(12)
    .shadow({ radius: 4, color: '#0000000A', offsetX: 0, offsetY: 2 })
  }

  private iconFor(cat: string): string {
    if (cat === 'automation') return '\u2699\uFE0F';
    if (cat === 'productivity') return '\uD83D\uDCCB';
    if (cat === 'smart_home') return '\uD83C\uDFE0';
    if (cat === 'media') return '\uD83C\uDFA5';
    return '\uD83D\uDD27';
  }
}
