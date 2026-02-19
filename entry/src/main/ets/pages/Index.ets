import { ChatPage } from './ChatPage';
import { I18n, LangCode } from '../common/I18n';
import { LogService } from '../common/LogService';
import { Constants } from '../common/Constants';
import { NodeRuntime } from '../service/gateway/NodeRuntime';
import { GatewayEndpoint } from '../service/gateway/GatewayModels';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

@Entry
@Component
struct Index {
  @State @Watch('onLangChange') lang: string = 'zh';
  @StorageLink('share_timestamp') shareTs: number = 0;
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

  /** Auto-connect to Gateway on startup using saved settings */
  private async autoConnectGateway(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let store = await preferences.getPreferences(ctx, Constants.PREFS_GATEWAY);
      let nodeEnabled = (await store.get('enabled', false)) as boolean;
      let operatorEnabled = (await store.get('operatorEnabled', false)) as boolean;

      // Need at least one session type enabled
      if (!nodeEnabled && !operatorEnabled) return;

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
      await runtime.loadDisplayName(ctx);
      runtime.connect(ctx, endpoint,
        token.length > 0 ? token : undefined,
        password.length > 0 ? password : undefined,
        operatorEnabled,
        nodeEnabled);

      LogService.getInstance().info('App', `Auto-connecting gateway: ${host}:${port} operator=${operatorEnabled} node=${nodeEnabled}`);
    } catch {
      LogService.getInstance().warn('App', 'Failed to auto-connect gateway');
    }
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
      ChatPage()
      // Hidden version tag for pre-commit consistency check
      Text('v2.33.0').fontSize(0).opacity(0).height(0)
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
  }
}
