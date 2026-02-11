import { ChatPage } from './ChatPage';
import { SkillsPage } from './SkillsPage';
import { MemoryPage } from './MemoryPage';
import { SettingsPage } from './SettingsPage';
import { LogPage } from './LogPage';
import { I18n, LangCode } from '../common/I18n';
import { LogService } from '../common/LogService';
import { Constants } from '../common/Constants';
import { NodeRuntime } from '../service/gateway/NodeRuntime';
import { ConnectionState, GatewayEndpoint } from '../service/gateway/GatewayModels';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';

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
    this.autoConnectGateway();
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

  /** Auto-connect to Gateway if Node Mode is enabled in settings */
  private async autoConnectGateway(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let store = await preferences.getPreferences(ctx, Constants.PREFS_GATEWAY);
      let enabled = (await store.get('enabled', false)) as boolean;
      if (!enabled) return;

      let host = (await store.get('host', '')) as string;
      if (host.length === 0) return;

      let port = parseInt((await store.get('port', '9999')) as string) || 9999;
      let useTls = (await store.get('useTls', false)) as boolean;
      let token = (await store.get('token', '')) as string;
      let password = (await store.get('password', '')) as string;

      // Load capability toggles
      let capLocation = (await store.get('capLocation', true)) as boolean;
      let capCamera = (await store.get('capCamera', true)) as boolean;
      let capCanvas = (await store.get('capCanvas', true)) as boolean;
      let capScreen = (await store.get('capScreen', true)) as boolean;
      let capNotification = (await store.get('capNotification', true)) as boolean;
      let capMicrophone = (await store.get('capMicrophone', true)) as boolean;
      let capSpeaker = (await store.get('capSpeaker', true)) as boolean;

      let endpoint: GatewayEndpoint = { host: host, port: port, useTls: useTls };
      let runtime = NodeRuntime.getInstance();
      runtime.updateCapabilities(capLocation, capCamera, capCanvas, capScreen, capNotification, undefined, capMicrophone, capSpeaker);
      // Listen for auth failures during auto-reconnect
      let authFailListener = (state: ConnectionState, text: string) => {
        if (state === ConnectionState.Error) {
          let lower = text.toLowerCase();
          if (lower.includes('auth') || lower.includes('unauthorized') || lower.includes('forbidden') || lower.includes('password')) {
            LogService.getInstance().warn('App', `Auth failure detected: ${text}, redirecting to login`);
            runtime.removeStateListener(authFailListener);
            runtime.disconnect();
            this.clearLoginState();
          }
        }
      };
      runtime.addStateListener(authFailListener);

      runtime.connect(ctx, endpoint,
        token.length > 0 ? token : undefined,
        password.length > 0 ? password : undefined);

      LogService.getInstance().info('App', `Auto-connecting gateway: ${host}:${port}`);
    } catch {
      LogService.getInstance().warn('App', 'Failed to auto-connect gateway');
    }
  }

  private async clearLoginState(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let loginStore = await preferences.getPreferences(ctx, Constants.PREFS_LOGIN);
      await loginStore.put('loggedIn', false);
      await loginStore.flush();
    } catch { /* ignore */ }
    router.replaceUrl({ url: 'pages/LoginPage' });
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
    Column() {
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
          MemoryPage({ isActive: this.currentTab === 2 })
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
      .layoutWeight(1)
      .scrollable(false)
      .barHeight(56)
      .barBackgroundColor(Color.White)
      .animationDuration(200)
      .onChange((index: number) => { this.currentTab = index; })
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
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
