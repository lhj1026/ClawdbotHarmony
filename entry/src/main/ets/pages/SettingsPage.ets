import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { Constants } from '../common/Constants';
import { NodeRuntime } from '../service/gateway/NodeRuntime';
import { ConnectionState, GatewayEndpoint } from '../service/gateway/GatewayModels';
import { I18n, LangCode } from '../common/I18n';

@Component
export struct SettingsPage {
  @State provider: string = 'anthropic';
  @State apiKey: string = '';
  @State model: string = Constants.DEFAULT_MODEL_ANTHROPIC;
  @State baseUrl: string = '';
  @State temperature: number = 0.7;
  @State showKey: boolean = false;
  @State @Watch('onLangChange') lang: string = 'zh';

  // Gateway / Node Mode
  @State gwEnabled: boolean = false;
  @State gwHost: string = '192.168.1.68';
  @State gwPort: string = '18789';
  @State gwUseTls: boolean = false;
  @State gwToken: string = 'd71a61ab10ca57779f52838835aaf688c7ba0a1e4c680489';
  @State gwPassword: string = '';
  @State gwStatusText: string = 'Offline';
  @State gwState: ConnectionState = ConnectionState.Disconnected;

  private gwListener: ((state: ConnectionState, text: string) => void) | undefined = undefined;
  private langListener: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    this.load();
    this.loadGateway();
    this.lang = I18n.lang;
    this.langListener = () => { this.lang = I18n.lang; };
    I18n.addListener(this.langListener);
    this.gwListener = (state: ConnectionState, text: string) => {
      this.gwState = state;
      this.gwStatusText = text;
    };
    NodeRuntime.getInstance().addStateListener(this.gwListener);
    // Sync current state
    this.gwState = NodeRuntime.getInstance().connectionState;
    this.gwStatusText = NodeRuntime.getInstance().statusText;
  }

  aboutToDisappear(): void {
    if (this.gwListener) {
      NodeRuntime.getInstance().removeStateListener(this.gwListener);
      this.gwListener = undefined;
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
    Scroll() {
      Column() {
        Text(I18n.t('settings.title'))
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1A1A1A')
          .width('100%')
          .padding({ left: 20, top: 16, bottom: 16 })

        // ---- Language ----
        this.SectionTitle(I18n.t('settings.language'))
        Column() {
          Row() {
            Column({ space: 2 }) {
              Text(I18n.t('settings.language'))
                .fontSize(14)
                .fontColor('#1A1A1A')
              Text(I18n.t('settings.languageDesc'))
                .fontSize(11)
                .fontColor('#999999')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .margin({ bottom: 10 })

          Row({ space: 8 }) {
            Text(I18n.t('settings.langZh'))
              .fontSize(13)
              .fontColor(this.lang === 'zh' ? Color.White : '#666666')
              .backgroundColor(this.lang === 'zh' ? '#D2691E' : '#F0F0F0')
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .borderRadius(8)
              .onClick(() => { this.switchLang('zh'); })
            Text(I18n.t('settings.langEn'))
              .fontSize(13)
              .fontColor(this.lang === 'en' ? Color.White : '#666666')
              .backgroundColor(this.lang === 'en' ? '#D2691E' : '#F0F0F0')
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .borderRadius(8)
              .onClick(() => { this.switchLang('en'); })
          }
        }
        .width('100%')
        .padding(16)
        .margin({ left: 16, right: 16 })
        .backgroundColor(Color.White)
        .borderRadius(12)

        // ---- AI Provider ----
        this.SectionTitle(I18n.t('settings.aiProvider'))
        Column() {
          // provider selector
          Text(I18n.t('settings.provider'))
            .fontSize(14)
            .fontColor('#666666')
            .margin({ bottom: 8 })
            .width('100%')
          Row({ space: 8 }) {
            ForEach(['anthropic', 'openai', 'local'] as string[], (p: string) => {
              Text(this.providerLabel(p))
                .fontSize(13)
                .fontColor(this.provider === p ? Color.White : '#666666')
                .backgroundColor(this.provider === p ? '#D2691E' : '#F0F0F0')
                .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                .borderRadius(8)
                .onClick(() => {
                  this.provider = p;
                  if (p === 'anthropic') this.model = Constants.DEFAULT_MODEL_ANTHROPIC;
                  else if (p === 'openai') this.model = Constants.DEFAULT_MODEL_OPENAI;
                  else this.model = 'llama3';
                })
            }, (p: string): string => p)
          }

          Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')

          // API key
          Text(I18n.t('settings.apiKey'))
            .fontSize(14)
            .fontColor('#1A1A1A')
            .width('100%')
          Row() {
            TextInput({
              text: this.apiKey,
              placeholder: this.provider === 'local' ? I18n.t('settings.apiKeyNotRequired') : I18n.t('settings.apiKeyPlaceholder')
            })
              .layoutWeight(1)
              .height(40)
              .backgroundColor('#F5F5F5')
              .borderRadius(8)
              .type(this.showKey ? InputType.Normal : InputType.Password)
              .onChange((v: string) => { this.apiKey = v; })

            Button(this.showKey ? I18n.t('settings.hide') : I18n.t('settings.show'))
              .fontSize(12)
              .height(34)
              .backgroundColor('#F0F0F0')
              .fontColor('#666666')
              .borderRadius(8)
              .margin({ left: 8 })
              .onClick(() => { this.showKey = !this.showKey; })
          }
          .margin({ top: 6 })
          .width('100%')

          Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')

          // Model
          Text(I18n.t('settings.model'))
            .fontSize(14)
            .fontColor('#1A1A1A')
            .width('100%')
          TextInput({ text: this.model, placeholder: I18n.t('settings.modelPlaceholder') })
            .height(40)
            .backgroundColor('#F5F5F5')
            .borderRadius(8)
            .margin({ top: 6 })
            .onChange((v: string) => { this.model = v; })

          // Base URL (all providers — allows proxy / custom endpoints)
          Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')
          Text(I18n.t('settings.baseUrl'))
            .fontSize(14)
            .fontColor('#1A1A1A')
            .width('100%')
          Text(I18n.t('settings.baseUrlDesc'))
            .fontSize(11)
            .fontColor('#999999')
            .width('100%')
            .margin({ top: 2 })
          TextInput({
            text: this.baseUrl,
            placeholder: this.provider === 'anthropic'
              ? 'https://api.anthropic.com/v1/messages'
              : this.provider === 'openai'
                ? 'https://api.openai.com/v1/chat/completions'
                : 'http://localhost:11434/api/chat'
          })
            .height(40)
            .backgroundColor('#F5F5F5')
            .borderRadius(8)
            .margin({ top: 6 })
            .onChange((v: string) => { this.baseUrl = v; })
        }
        .width('100%')
        .padding(16)
        .margin({ left: 16, right: 16 })
        .backgroundColor(Color.White)
        .borderRadius(12)

        // ---- Generation ----
        this.SectionTitle(I18n.t('settings.generation'))
        Column() {
          Row() {
            Text(I18n.t('settings.temperature'))
              .fontSize(14)
              .fontColor('#1A1A1A')
              .layoutWeight(1)
            Text(this.temperature.toFixed(1))
              .fontSize(14)
              .fontColor('#D2691E')
              .fontWeight(FontWeight.Medium)
          }
          .width('100%')

          Slider({ value: this.temperature * 10, min: 0, max: 10, step: 1 })
            .selectedColor('#D2691E')
            .onChange((v: number) => { this.temperature = v / 10; })
            .width('100%')
        }
        .padding(16)
        .margin({ left: 16, right: 16 })
        .backgroundColor(Color.White)
        .borderRadius(12)

        // ---- Gateway / Node Mode ----
        this.SectionTitle(I18n.t('settings.gateway'))
        Column() {
          // Enable toggle
          Row() {
            Column({ space: 2 }) {
              Text(I18n.t('settings.nodeMode'))
                .fontSize(14)
                .fontColor('#1A1A1A')
              Text(I18n.t('settings.nodeModeDesc'))
                .fontSize(11)
                .fontColor('#999999')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.gwEnabled })
              .selectedColor('#D2691E')
              .onChange((isOn: boolean) => {
                this.gwEnabled = isOn;
                if (!isOn) {
                  NodeRuntime.getInstance().disconnect();
                }
              })
          }
          .width('100%')

          if (this.gwEnabled) {
            Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')

            // Gateway Host
            Text(I18n.t('settings.gatewayHost'))
              .fontSize(14)
              .fontColor('#1A1A1A')
              .width('100%')
            TextInput({ text: this.gwHost, placeholder: I18n.t('settings.gatewayHostPlaceholder') })
              .height(40)
              .backgroundColor('#F5F5F5')
              .borderRadius(8)
              .margin({ top: 6 })
              .onChange((v: string) => { this.gwHost = v; })

            Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')

            // Port
            Row() {
              Text(I18n.t('settings.port'))
                .fontSize(14)
                .fontColor('#1A1A1A')
                .layoutWeight(1)
              TextInput({ text: this.gwPort, placeholder: '9315' })
                .width(100)
                .height(40)
                .backgroundColor('#F5F5F5')
                .borderRadius(8)
                .type(InputType.Number)
                .onChange((v: string) => { this.gwPort = v; })
            }
            .width('100%')

            Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')

            // TLS toggle
            Row() {
              Text(I18n.t('settings.useTls'))
                .fontSize(14)
                .fontColor('#1A1A1A')
                .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.gwUseTls })
                .selectedColor('#D2691E')
                .onChange((isOn: boolean) => { this.gwUseTls = isOn; })
            }
            .width('100%')

            Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')

            // Shared Token
            Text(I18n.t('settings.token'))
              .fontSize(14)
              .fontColor('#1A1A1A')
              .width('100%')
            Text(I18n.t('settings.tokenDesc'))
              .fontSize(11)
              .fontColor('#999999')
              .width('100%')
              .margin({ top: 2 })
            TextInput({ text: this.gwToken, placeholder: I18n.t('settings.tokenPlaceholder') })
              .height(40)
              .backgroundColor('#F5F5F5')
              .borderRadius(8)
              .type(InputType.Password)
              .margin({ top: 6 })
              .onChange((v: string) => { this.gwToken = v; })

            Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')

            // Password (alternative auth)
            Text(I18n.t('settings.password'))
              .fontSize(14)
              .fontColor('#666666')
              .width('100%')
            TextInput({ text: this.gwPassword, placeholder: I18n.t('settings.passwordPlaceholder') })
              .height(40)
              .backgroundColor('#F5F5F5')
              .borderRadius(8)
              .type(InputType.Password)
              .margin({ top: 6 })
              .onChange((v: string) => { this.gwPassword = v; })

            Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')

            // Connection status
            Row() {
              Text(I18n.t('settings.status'))
                .fontSize(14)
                .fontColor('#1A1A1A')
                .layoutWeight(1)
              Circle({ width: 10, height: 10 })
                .fill(this.gwStateColor())
                .margin({ right: 6 })
              Text(this.gwStatusText)
                .fontSize(13)
                .fontColor(this.gwStateColor())
                .fontWeight(FontWeight.Medium)
            }
            .width('100%')
            .height(40)

            // Connect / Disconnect button
            Button(this.gwIsConnected() ? I18n.t('settings.disconnect') : I18n.t('settings.connect'))
              .width('100%')
              .height(44)
              .backgroundColor(this.gwIsConnected() ? '#D32F2F' : '#4CAF50')
              .fontColor(Color.White)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .borderRadius(10)
              .margin({ top: 8 })
              .onClick(() => { this.toggleGateway(); })

            // Capabilities info
            Column({ space: 4 }) {
              Text(I18n.t('settings.caps'))
                .fontSize(11)
                .fontColor('#999999')
                .width('100%')
              Text(I18n.t('settings.capsDetail'))
                .fontSize(11)
                .fontColor('#999999')
                .width('100%')
            }
            .margin({ top: 12 })
          }
        }
        .width('100%')
        .padding(16)
        .margin({ left: 16, right: 16 })
        .backgroundColor(Color.White)
        .borderRadius(12)

        // ---- About ----
        this.SectionTitle(I18n.t('settings.about'))
        Column() {
          this.InfoRow(I18n.t('settings.app'), I18n.t('settings.appValue'))
          Divider().color('#F0F0F0')
          this.InfoRow(I18n.t('settings.version'), '1.0.0')
          Divider().color('#F0F0F0')
          this.InfoRow(I18n.t('settings.basedOn'), 'OpenClaw / ClawdBot')
          Divider().color('#F0F0F0')
          this.InfoRow(I18n.t('settings.platform'), 'HarmonyOS NEXT')
        }
        .padding(16)
        .margin({ left: 16, right: 16 })
        .backgroundColor(Color.White)
        .borderRadius(12)

        // Save
        Button(I18n.t('settings.save'))
          .width('90%')
          .height(48)
          .backgroundColor('#D2691E')
          .fontColor(Color.White)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .borderRadius(12)
          .margin({ top: 24, bottom: 40 })
          .onClick(() => { this.save(); })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  SectionTitle(title: string) {
    Text(title)
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor('#999999')
      .letterSpacing(1)
      .padding({ left: 20, top: 20, bottom: 8 })
      .width('100%')
  }

  @Builder
  InfoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontColor('#1A1A1A')
        .layoutWeight(1)
      Text(value)
        .fontSize(14)
        .fontColor('#666666')
    }
    .width('100%')
    .height(46)
  }

  // ============ logic ============

  private providerLabel(p: string): string {
    if (p === 'anthropic') return 'Anthropic';
    if (p === 'openai') return 'OpenAI';
    return 'Local (Ollama)';
  }

  private gwStateColor(): string {
    if (this.gwState === ConnectionState.Connected) return '#4CAF50';
    if (this.gwState === ConnectionState.Connecting) return '#FF9800';
    if (this.gwState === ConnectionState.Reconnecting) return '#FF9800';
    if (this.gwState === ConnectionState.Error) return '#D32F2F';
    return '#999999';
  }

  private gwIsConnected(): boolean {
    return this.gwState === ConnectionState.Connected;
  }

  private switchLang(lang: LangCode): void {
    I18n.setLang(lang);
    this.lang = lang;
    this.saveLang();
  }

  private async saveLang(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let store = await preferences.getPreferences(ctx, 'clawdbot_settings');
      await store.put('language', this.lang);
      await store.flush();
    } catch { /* ignore */ }
  }

  private toggleGateway(): void {
    if (this.gwIsConnected()) {
      NodeRuntime.getInstance().disconnect();
      return;
    }
    let host = this.gwHost.trim();
    if (host.length === 0) {
      promptAction.showToast({ message: I18n.t('settings.enterHost'), duration: 1500 });
      return;
    }
    let port = parseInt(this.gwPort) || Constants.DEFAULT_GATEWAY_PORT;
    let endpoint: GatewayEndpoint = {
      host: host,
      port: port,
      useTls: this.gwUseTls,
    };
    let ctx = getContext(this) as common.UIAbilityContext;
    let token = this.gwToken.trim().length > 0 ? this.gwToken.trim() : undefined;
    let password = this.gwPassword.trim().length > 0 ? this.gwPassword.trim() : undefined;
    NodeRuntime.getInstance().connect(ctx, endpoint, token, password);
  }

  private async load(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let store = await preferences.getPreferences(ctx, Constants.PREFS_SETTINGS);
      this.provider = (await store.get('provider', 'anthropic')) as string;
      this.apiKey = (await store.get('apiKey', '')) as string;
      this.model = (await store.get('model', Constants.DEFAULT_MODEL_ANTHROPIC)) as string;
      this.baseUrl = (await store.get('baseUrl', '')) as string;
      this.temperature = (await store.get('temperature', 0.7)) as number;
    } catch { /* first launch defaults */ }
  }

  private async loadGateway(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let store = await preferences.getPreferences(ctx, Constants.PREFS_GATEWAY);
      let savedHost = (await store.get('host', '')) as string;
      let savedPort = (await store.get('port', '')) as string;
      let savedToken = (await store.get('token', '')) as string;
      let savedPassword = (await store.get('password', '')) as string;
      this.gwEnabled = (await store.get('enabled', false)) as boolean;
      // Only override defaults if saved values exist
      if (savedHost.length > 0) this.gwHost = savedHost;
      if (savedPort.length > 0) this.gwPort = savedPort;
      this.gwUseTls = (await store.get('useTls', false)) as boolean;
      if (savedToken.length > 0) this.gwToken = savedToken;
      if (savedPassword.length > 0) this.gwPassword = savedPassword;
    } catch { /* first launch defaults */ }
  }

  private async save(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      // Save AI settings
      let store = await preferences.getPreferences(ctx, Constants.PREFS_SETTINGS);
      await store.put('provider', this.provider);
      await store.put('apiKey', this.apiKey);
      await store.put('model', this.model);
      await store.put('baseUrl', this.baseUrl);
      await store.put('temperature', this.temperature);
      await store.flush();

      // Save gateway settings
      let gwStore = await preferences.getPreferences(ctx, Constants.PREFS_GATEWAY);
      await gwStore.put('enabled', this.gwEnabled);
      await gwStore.put('host', this.gwHost);
      await gwStore.put('port', this.gwPort);
      await gwStore.put('useTls', this.gwUseTls);
      await gwStore.put('token', this.gwToken);
      await gwStore.put('password', this.gwPassword);
      await gwStore.flush();

      // Save language
      await this.saveLang();

      promptAction.showToast({ message: I18n.t('settings.saved'), duration: 1500 });
    } catch (e) {
      promptAction.showToast({ message: I18n.t('settings.saveFailed') + String(e), duration: 2000 });
    }
  }
}
