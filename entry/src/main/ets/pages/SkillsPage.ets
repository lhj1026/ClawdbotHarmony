import { SkillCard } from '../components/SkillCard';
import { SkillItem } from '../model/Models';
import { getDefaultSkills } from '../service/SkillData';
import { I18n } from '../common/I18n';

@Component
export struct SkillsPage {
  @State skills: SkillItem[] = [];
  @State filterCategory: string = 'all';
  @State @Watch('onLangChange') lang: string = 'zh';

  private categories: string[] = ['all', 'automation', 'productivity', 'smart_home', 'media'];
  private langListener: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    this.skills = getDefaultSkills();
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
      Text(I18n.t('skills.title'))
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor('#1A1A1A')
        .width('100%')
        .padding({ left: 20, top: 16, bottom: 8 })

      Text(I18n.t('skills.subtitle'))
        .fontSize(13)
        .fontColor('#666666')
        .padding({ left: 20, right: 20, bottom: 12 })
        .width('100%')

      // filter chips
      Scroll() {
        Row({ space: 8 }) {
          ForEach(this.categories, (cat: string) => {
            Text(cat === 'all' ? I18n.t('skills.all') : this.catLabel(cat))
              .fontSize(13)
              .fontColor(this.filterCategory === cat ? Color.White : '#666666')
              .backgroundColor(this.filterCategory === cat ? '#D2691E' : Color.White)
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .borderRadius(16)
              .borderWidth(this.filterCategory === cat ? 0 : 1)
              .borderColor('#E0E0E0')
              .onClick(() => { this.filterCategory = cat; })
          }, (cat: string): string => cat)
        }
        .padding({ left: 20, right: 20 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .margin({ bottom: 12 })

      // stats
      Row({ space: 12 }) {
        this.StatBadge(this.skills.length + I18n.t('skills.countSkills'))
        this.StatBadge(this.skills.filter((s): boolean => s.enabled).length + I18n.t('skills.countEnabled'))
        this.StatBadge(this.skills.reduce((s, sk): number => s + sk.toolCount, 0) + I18n.t('skills.countTools'))
      }
      .padding({ left: 20, bottom: 12 })

      // list
      List({ space: 10 }) {
        ForEach(this.filteredSkills(), (skill: SkillItem) => {
          ListItem() {
            SkillCard({
              skill: skill,
              onToggle: (id: string, on: boolean): void => {
                this.toggleSkill(id, on);
              }
            })
          }
          .padding({ left: 16, right: 16 })
        }, (skill: SkillItem): string => skill.id)
      }
      .layoutWeight(1)
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }

  @Builder
  StatBadge(text: string) {
    Text(text)
      .fontSize(12)
      .fontColor('#666666')
      .backgroundColor(Color.White)
      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      .borderRadius(10)
  }

  private filteredSkills(): SkillItem[] {
    if (this.filterCategory === 'all') return this.skills;
    return this.skills.filter((s): boolean => s.category === this.filterCategory);
  }

  private toggleSkill(id: string, on: boolean): void {
    for (let skill of this.skills) {
      if (skill.id === id) {
        skill.enabled = on;
        break;
      }
    }
  }

  private catLabel(cat: string): string {
    if (cat === 'automation') return I18n.t('skills.automation');
    if (cat === 'productivity') return I18n.t('skills.productivity');
    if (cat === 'smart_home') return I18n.t('skills.smartHome');
    if (cat === 'media') return I18n.t('skills.media');
    return cat;
  }
}
