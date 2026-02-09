import { ChatPage } from './ChatPage';
import { SkillsPage } from './SkillsPage';
import { MemoryPage } from './MemoryPage';
import { SettingsPage } from './SettingsPage';
import { LogPage } from './LogPage';
import { I18n, LangCode } from '../common/I18n';
import { LogService } from '../common/LogService';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

@Entry
@Component
struct Index {
  @State currentTab: number = 0;
  @State @Watch('onLangChange') lang: string = 'zh';
  private controller: TabsController = new TabsController();
  private langListener: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    LogService.getInstance().info('App', 'ClawdBot started');
    this.loadLang();
    this.langListener = () => {
      this.lang = I18n.lang;
    };
    I18n.addListener(this.langListener);
  }

  aboutToDisappear(): void {
    if (this.langListener) {
      I18n.removeListener(this.langListener);
      this.langListener = undefined;
    }
  }

  onLangChange(): void {
    // triggers UI re-render
  }

  private async loadLang(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let store = await preferences.getPreferences(ctx, 'clawdbot_settings');
      let saved = (await store.get('language', 'zh')) as string;
      let lang: LangCode = (saved === 'en') ? 'en' : 'zh';
      I18n.init(lang);
      this.lang = lang;
      LogService.getInstance().info('App', `Language loaded: ${lang}`);
    } catch {
      I18n.init('zh');
      this.lang = 'zh';
    }
  }

  build() {
    Tabs({ barPosition: BarPosition.End, controller: this.controller }) {
      TabContent() {
        ChatPage()
      }
      .tabBar(this.TabItem(0, '\uD83D\uDCAC', I18n.t('tab.chat')))

      TabContent() {
        SkillsPage()
      }
      .tabBar(this.TabItem(1, '\uD83D\uDD27', I18n.t('tab.skills')))

      TabContent() {
        MemoryPage()
      }
      .tabBar(this.TabItem(2, '\uD83E\uDDE0', I18n.t('tab.memory')))

      TabContent() {
        SettingsPage()
      }
      .tabBar(this.TabItem(3, '\u2699\uFE0F', I18n.t('tab.settings')))

      TabContent() {
        LogPage()
      }
      .tabBar(this.TabItem(4, '\uD83D\uDCDD', I18n.t('tab.logs')))
    }
    .scrollable(false)
    .barHeight(56)
    .barBackgroundColor(Color.White)
    .animationDuration(200)
    .onChange((index: number) => { this.currentTab = index; })
  }

  @Builder
  TabItem(index: number, icon: string, label: string) {
    Column({ space: 3 }) {
      Text(icon)
        .fontSize(20)
      Text(label)
        .fontSize(11)
        .fontColor(this.currentTab === index ? '#D2691E' : '#999999')
        .fontWeight(this.currentTab === index ? FontWeight.Medium : FontWeight.Normal)
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
  }
}
