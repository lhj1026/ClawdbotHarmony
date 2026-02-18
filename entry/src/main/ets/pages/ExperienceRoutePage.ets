// Experience page - unified view for experiences, skills, and memory
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ExperienceStorage } from '../service/ExperienceStorage';
import { Experience, Skill, Memory, ShareLevel, getShareLevelIcon } from '../model/ExperiencePack';
import { SkillsPage } from './SkillsPage';
import { MemoryPage } from './MemoryPage';
import { I18n } from '../common/I18n';

@Entry
@Component
struct ExperienceRoutePage {
  @State currentTab: number = 0;
  @State experiences: Experience[] = [];
  @State selectedExp: Experience | null = null;
  @State isLoading: boolean = true;
  @State lastSync: string = '从未';
  @State @Watch('onLangChange') lang: string = 'zh';
  private storage: ExperienceStorage = ExperienceStorage.getInstance();
  private langListener: (() => void) | undefined = undefined;
  private tabTitles: string[] = ['经验包', '技能', '记忆'];

  aboutToAppear(): void {
    this.loadExperiences();
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
    // Update tab titles on language change
    this.tabTitles = [
      I18n.t('experience.tabExperience'),
      I18n.t('experience.tabSkills'),
      I18n.t('experience.tabMemory')
    ];
  }

  private async loadExperiences(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let pack = await this.storage.load(ctx);
      if (pack) {
        this.experiences = pack.experiences;
        this.lastSync = this.storage.getLastSyncTime();
      }
    } catch (e) {
      console.error('Load experiences failed:', (e as Error).message);
    }
    this.isLoading = false;
  }

  build() {
    Navigation() {
      if (this.selectedExp) {
        // Experience detail view
        this.ExperienceDetail(this.selectedExp)
      } else {
        // Tab view
        Tabs({ barPosition: BarPosition.Start, index: this.currentTab }) {
          TabContent() {
            this.ExperienceTab()
          }
          .tabBar(this.TabBarItem(0, '📚', this.tabTitles[0]))

          TabContent() {
            SkillsPage()
          }
          .tabBar(this.TabBarItem(1, '⚡', this.tabTitles[1]))

          TabContent() {
            MemoryPage({ isActive: this.currentTab === 2 })
          }
          .tabBar(this.TabBarItem(2, '🧠', this.tabTitles[2]))
        }
        .barMode(BarMode.Fixed)
        .barWidth('100%')
        .barHeight(56)
        .onChange((index: number) => {
          this.currentTab = index;
        })
      }
    }
    .title(this.selectedExp ? this.selectedExp.name : I18n.t('experience.title'))
    .titleMode(NavigationTitleMode.Mini)
    .navBarPosition(NavBarPosition.Start)
    .mode(NavigationMode.Stack)
    .backButtonIcon($r('sys.media.ohos_ic_public_arrow_left'))
    .onNavBarStateChange((isVisible: boolean) => {
      if (!isVisible && this.selectedExp) {
        this.selectedExp = null;
      }
    })
  }

  @Builder
  TabBarItem(index: number, icon: string, title: string) {
    Column() {
      Text(icon)
        .fontSize(20)
      Text(title)
        .fontSize(12)
        .fontColor(this.currentTab === index ? '#D2691E' : '#999999')
        .margin({ top: 2 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  ExperienceTab() {
    if (this.isLoading) {
      Column() {
        LoadingProgress()
          .width(48)
          .height(48)
        Text(I18n.t('common.loading'))
          .fontSize(14)
          .fontColor('#999999')
          .margin({ top: 16 })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    } else {
      this.ExperienceList()
    }
  }

  @Builder
  ExperienceList() {
    Column() {
      // Statistics
      Row() {
        Column() {
          Text(`${this.experiences.length}`)
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A1A')
          Text(I18n.t('experience.countExp'))
            .fontSize(12)
            .fontColor('#999999')
        }
        .layoutWeight(1)

        Column() {
          Text(`${this.storage.getTotalSkillsCount()}`)
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A1A')
          Text(I18n.t('experience.countSkill'))
            .fontSize(12)
            .fontColor('#999999')
        }
        .layoutWeight(1)

        Column() {
          Text(`${this.storage.getTotalMemoryCount()}`)
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A1A')
          Text(I18n.t('experience.countMemory'))
            .fontSize(12)
            .fontColor('#999999')
        }
        .layoutWeight(1)
      }
      .width('100%')
      .padding(16)
      .backgroundColor('#F8F8F8')
      .borderRadius(12)
      .margin({ left: 16, right: 16, top: 16 })

      // Last sync time
      Text(`${I18n.t('experience.lastSync')}: ${this.lastSync}`)
        .fontSize(12)
        .fontColor('#999999')
        .margin({ top: 8 })

      // Share level legend
      Row() {
        Text('🟢' + I18n.t('experience.levelPublic'))
          .fontSize(11)
          .fontColor('#666666')
        Text('🟡' + I18n.t('experience.levelSummary'))
          .fontSize(11)
          .fontColor('#666666')
          .margin({ left: 12 })
        Text('🔴' + I18n.t('experience.levelPrivate'))
          .fontSize(11)
          .fontColor('#666666')
          .margin({ left: 12 })
      }
      .margin({ top: 4, bottom: 16 })

      // Experience list
      if (this.experiences.length === 0) {
        Column() {
          Text('📚')
            .fontSize(48)
          Text(I18n.t('experience.empty'))
            .fontSize(16)
            .fontColor('#999999')
            .margin({ top: 12 })
          Text(I18n.t('experience.emptyHint'))
            .fontSize(12)
            .fontColor('#CCCCCC')
            .margin({ top: 4 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.experiences, (exp: Experience) => {
            ListItem() {
              this.ExperienceCard(exp)
            }
          })
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16 })
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  ExperienceCard(exp: Experience) {
    Column() {
      Row() {
        Text(exp.name)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1A1A1A')
          .layoutWeight(1)
        Text('>')
          .fontSize(14)
          .fontColor('#CCCCCC')
      }
      .width('100%')

      if (exp.description.length > 0) {
        Text(exp.description)
          .fontSize(13)
          .fontColor('#666666')
          .margin({ top: 4 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      Row() {
        Text(`${exp.skills.length} ${I18n.t('experience.skills')}`)
          .fontSize(12)
          .fontColor('#999999')
        Text('·')
          .fontSize(12)
          .fontColor('#CCCCCC')
          .margin({ left: 8, right: 8 })
        Text(`${exp.memory.length} ${I18n.t('experience.memories')}`)
          .fontSize(12)
          .fontColor('#999999')
        Blank()
        Text(this.formatTime(exp.updatedAt))
          .fontSize(11)
          .fontColor('#CCCCCC')
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
    .margin({ bottom: 12 })
    .shadow({ radius: 4, color: '#0000000A', offsetY: 2 })
    .onClick(() => {
      this.selectedExp = exp;
    })
  }

  @Builder
  ExperienceDetail(exp: Experience) {
    Scroll() {
      Column() {
        // Description
        if (exp.description.length > 0) {
          Text(exp.description)
            .fontSize(14)
            .fontColor('#666666')
            .width('100%')
            .padding(16)
        }

        // Skills section
        this.SectionTitle(I18n.t('experience.skills'), exp.skills.length)
        if (exp.skills.length === 0) {
          Text(I18n.t('experience.noSkills'))
            .fontSize(13)
            .fontColor('#999999')
            .padding(16)
        } else {
          ForEach(exp.skills, (skill: Skill) => {
            this.SkillCard(skill)
          })
        }

        // Memory section
        this.SectionTitle(I18n.t('experience.memories'), exp.memory.length)
        if (exp.memory.length === 0) {
          Text(I18n.t('experience.noMemory'))
            .fontSize(13)
            .fontColor('#999999')
            .padding(16)
        } else {
          Column() {
            ForEach(exp.memory, (mem: Memory) => {
              this.MemoryRow(mem)
            })
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .backgroundColor('#FFFFFF')
          .borderRadius(12)
          .margin({ left: 16, right: 16 })
        }

        // Time info
        Column() {
          Text(`${I18n.t('experience.createdAt')}: ${this.formatTime(exp.createdAt)}`)
            .fontSize(12)
            .fontColor('#999999')
          Text(`${I18n.t('experience.updatedAt')}: ${this.formatTime(exp.updatedAt)}`)
            .fontSize(12)
            .fontColor('#999999')
            .margin({ top: 4 })
        }
        .width('100%')
        .padding(16)
        .margin({ top: 16 })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  SectionTitle(title: string, count: number) {
    Row() {
      Text(title)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor('#1A1A1A')
      Text(` (${count})`)
        .fontSize(14)
        .fontColor('#999999')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 8 })
  }

  @Builder
  SkillCard(skill: Skill) {
    Column() {
      Row() {
        Text(getShareLevelIcon(skill.shareLevel))
          .fontSize(12)
          .margin({ right: 6 })
        Text(skill.name)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1A1A1A')
          .layoutWeight(1)
      }
      .width('100%')

      if (skill.description.length > 0) {
        Text(skill.description)
          .fontSize(12)
          .fontColor('#666666')
          .margin({ top: 4 })
          .width('100%')
      }

      if (skill.instructions.length > 0) {
        Text(skill.instructions)
          .fontSize(12)
          .fontColor('#888888')
          .fontFamily('monospace')
          .margin({ top: 8 })
          .padding(8)
          .backgroundColor('#F5F5F5')
          .borderRadius(6)
          .width('100%')
          .maxLines(10)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#FFFFFF')
    .borderRadius(10)
    .margin({ left: 16, right: 16, bottom: 8 })
  }

  @Builder
  MemoryRow(mem: Memory) {
    Row() {
      Text(getShareLevelIcon(mem.shareLevel))
        .fontSize(12)
        .margin({ right: 6 })
      Text(mem.key)
        .fontSize(13)
        .fontColor('#666666')
        .width(80)
      Text(mem.value)
        .fontSize(13)
        .fontColor('#1A1A1A')
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .border({ width: { bottom: 1 }, color: '#F0F0F0' })
  }

  private formatTime(ts: number): string {
    if (ts === 0) return '-';
    let d = new Date(ts);
    return `${d.getMonth() + 1}/${d.getDate()} ${d.getHours()}:${d.getMinutes().toString().padStart(2, '0')}`;
  }
}
