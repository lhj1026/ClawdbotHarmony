import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { Constants } from '../common/Constants';
import { NodeRuntime } from '../service/gateway/NodeRuntime';
import { ConnectionState, GatewayEndpoint } from '../service/gateway/GatewayModels';
import { I18n, LangCode } from '../common/I18n';

@Component
export struct SettingsPage {
  @State provider: string = 'openrouter';
  @State apiKey: string = '';
  @State model: string = Constants.DEFAULT_MODEL_OPENROUTER;
  @State baseUrl: string = '';
  @State temperature: number = 0.7;

  // Per-provider saved settings
  private savedModels: Record<string, string> = {
    'openrouter': Constants.DEFAULT_MODEL_OPENROUTER,
    'anthropic': Constants.DEFAULT_MODEL_ANTHROPIC,
    'openai': Constants.DEFAULT_MODEL_OPENAI,
    'local': 'llama3'
  };
  private savedKeys: Record<string, string> = {
    'openrouter': '', 'anthropic': '', 'openai': '', 'local': ''
  };
  private savedUrls: Record<string, string> = {
    'openrouter': '', 'anthropic': '', 'openai': '', 'local': ''
  };
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

  // Capability toggles
  @State capLocation: boolean = true;
  @State capCamera: boolean = true;
  @State capCanvas: boolean = true;
  @State capScreen: boolean = true;
  @State capNotification: boolean = true;
  @State capMicrophone: boolean = true;
  @State capSpeaker: boolean = true;
  @State capEmail: boolean = true;
  @State ttsAutoRead: boolean = false;

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
          Scroll() {
            Row({ space: 8 }) {
            ForEach(['openrouter', 'anthropic', 'openai', 'local'] as string[], (p: string) => {
              Text(this.providerLabel(p))
                .fontSize(13)
                .fontColor(this.provider === p ? Color.White : '#666666')
                .backgroundColor(this.provider === p ? '#D2691E' : '#F0F0F0')
                .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                .borderRadius(8)
                .onClick(() => {
                  // Save current settings for current provider before switching
                  this.savedModels[this.provider] = this.model;
                  this.savedKeys[this.provider] = this.apiKey;
                  this.savedUrls[this.provider] = this.baseUrl;
                  this.provider = p;
                  // Restore saved settings for the new provider
                  this.model = this.savedModels[p] ?? this.defaultModelFor(p);
                  this.apiKey = this.savedKeys[p] ?? '';
                  this.baseUrl = this.savedUrls[p] ?? '';
                })
            }, (p: string): string => p)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')

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
            placeholder: this.provider === 'openrouter'
              ? 'https://openrouter.ai/api/v1/chat/completions'
              : this.provider === 'anthropic'
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

            // Capabilities toggles
            Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')
            Text(I18n.t('settings.caps'))
              .fontSize(14)
              .fontColor('#1A1A1A')
              .fontWeight(FontWeight.Medium)
              .width('100%')
              .margin({ bottom: 10 })

            this.CapToggle(I18n.t('settings.capLocation'), this.capLocation, (v: boolean) => { this.capLocation = v; })
            this.CapToggle(I18n.t('settings.capCamera'), this.capCamera, (v: boolean) => { this.capCamera = v; })
            this.CapToggle(I18n.t('settings.capCanvas'), this.capCanvas, (v: boolean) => { this.capCanvas = v; })
            this.CapToggle(I18n.t('settings.capScreen'), this.capScreen, (v: boolean) => { this.capScreen = v; })
            this.CapToggle(I18n.t('settings.capNotification'), this.capNotification, (v: boolean) => { this.capNotification = v; })
            this.CapToggle(I18n.t('settings.capMicrophone'), this.capMicrophone, (v: boolean) => { this.capMicrophone = v; })
            this.CapToggle(I18n.t('settings.capSpeaker'), this.capSpeaker, (v: boolean) => { this.capSpeaker = v; })
            this.CapToggle(I18n.t('settings.capEmail'), this.capEmail, (v: boolean) => { this.capEmail = v; })

            // TTS auto-read
            Divider().margin({ top: 10, bottom: 10 }).color('#F0F0F0')
            Row() {
              Column({ space: 2 }) {
                Text(I18n.t('settings.ttsAutoRead'))
                  .fontSize(13)
                  .fontColor('#1A1A1A')
                Text(I18n.t('settings.ttsAutoReadDesc'))
                  .fontSize(11)
                  .fontColor('#999999')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              Toggle({ type: ToggleType.Switch, isOn: this.ttsAutoRead })
                .selectedColor('#D2691E')
                .onChange((v: boolean) => { this.ttsAutoRead = v; })
            }
            .width('100%')
            .height(50)
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
          .margin({ top: 24 })
          .onClick(() => { this.save(); })

        // ---- Logout ----
        Column({ space: 8 }) {
          // Show connected gateway address
          if (this.gwHost.length > 0) {
            Text(`${I18n.t('settings.gatewayAddress')}: ${this.gwHost}:${this.gwPort}`)
              .fontSize(12)
              .fontColor('#999999')
          }

          Button(I18n.t('settings.logout'))
            .width('90%')
            .height(44)
            .backgroundColor('#D32F2F')
            .fontColor(Color.White)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .borderRadius(12)
            .onClick(() => { this.confirmLogout(); })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .margin({ top: 16, bottom: 40 })
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
  CapToggle(label: string, isOn: boolean, onChange: (v: boolean) => void) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor('#1A1A1A')
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor('#D2691E')
        .onChange((v: boolean) => { onChange(v); })
    }
    .width('100%')
    .height(40)
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

  private defaultModelFor(p: string): string {
    if (p === 'openrouter') return Constants.DEFAULT_MODEL_OPENROUTER;
    if (p === 'anthropic') return Constants.DEFAULT_MODEL_ANTHROPIC;
    if (p === 'openai') return Constants.DEFAULT_MODEL_OPENAI;
    return 'llama3';
  }

  private providerLabel(p: string): string {
    if (p === 'openrouter') return 'OpenRouter';
    if (p === 'anthropic') return 'Anthropic';
    if (p === 'openai') return 'OpenAI';
    return 'Ollama';
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
    // Apply capability config before connecting
    NodeRuntime.getInstance().updateCapabilities(
      this.capLocation, this.capCamera, this.capCanvas,
      this.capScreen, this.capNotification, undefined,
      this.capMicrophone, this.capSpeaker, this.capEmail
    );
    NodeRuntime.getInstance().connect(ctx, endpoint, token, password);
  }

  private async load(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let store = await preferences.getPreferences(ctx, Constants.PREFS_SETTINGS);
      this.provider = (await store.get('provider', 'openrouter')) as string;
      this.temperature = (await store.get('temperature', 0.7)) as number;
      // Load per-provider settings
      this.savedModels['openrouter'] = (await store.get('model_openrouter', Constants.DEFAULT_MODEL_OPENROUTER)) as string;
      this.savedModels['anthropic'] = (await store.get('model_anthropic', Constants.DEFAULT_MODEL_ANTHROPIC)) as string;
      this.savedModels['openai'] = (await store.get('model_openai', Constants.DEFAULT_MODEL_OPENAI)) as string;
      this.savedModels['local'] = (await store.get('model_local', 'llama3')) as string;
      let orKey = (await store.get('key_openrouter', '')) as string;
      if (orKey.length === 0 && Constants.OPENROUTER_DEFAULT_KEY.length > 0) {
        orKey = Constants.OPENROUTER_DEFAULT_KEY;
      }
      this.savedKeys['openrouter'] = orKey;
      this.savedKeys['anthropic'] = (await store.get('key_anthropic', '')) as string;
      this.savedKeys['openai'] = (await store.get('key_openai', '')) as string;
      this.savedKeys['local'] = (await store.get('key_local', '')) as string;
      this.savedUrls['openrouter'] = (await store.get('url_openrouter', '')) as string;
      this.savedUrls['anthropic'] = (await store.get('url_anthropic', '')) as string;
      this.savedUrls['openai'] = (await store.get('url_openai', '')) as string;
      this.savedUrls['local'] = (await store.get('url_local', '')) as string;
      // Set current values from active provider
      this.model = this.savedModels[this.provider] ?? this.defaultModelFor(this.provider);
      this.apiKey = this.savedKeys[this.provider] ?? '';
      this.baseUrl = this.savedUrls[this.provider] ?? '';
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
      // Capability toggles (default all true)
      this.capLocation = (await store.get('capLocation', true)) as boolean;
      this.capCamera = (await store.get('capCamera', true)) as boolean;
      this.capCanvas = (await store.get('capCanvas', true)) as boolean;
      this.capScreen = (await store.get('capScreen', true)) as boolean;
      this.capNotification = (await store.get('capNotification', true)) as boolean;
      this.capMicrophone = (await store.get('capMicrophone', true)) as boolean;
      this.capSpeaker = (await store.get('capSpeaker', true)) as boolean;
      this.capEmail = (await store.get('capEmail', true)) as boolean;
      this.ttsAutoRead = (await store.get('ttsAutoRead', false)) as boolean;
    } catch { /* first launch defaults */ }
  }

  private async save(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      // Save AI settings
      let store = await preferences.getPreferences(ctx, Constants.PREFS_SETTINGS);
      await store.put('provider', this.provider);
      await store.put('temperature', this.temperature);
      // Save per-provider settings
      this.savedModels[this.provider] = this.model;
      this.savedKeys[this.provider] = this.apiKey;
      this.savedUrls[this.provider] = this.baseUrl;
      await store.put('model_openrouter', this.savedModels['openrouter'] ?? Constants.DEFAULT_MODEL_OPENROUTER);
      await store.put('model_anthropic', this.savedModels['anthropic'] ?? Constants.DEFAULT_MODEL_ANTHROPIC);
      await store.put('model_openai', this.savedModels['openai'] ?? Constants.DEFAULT_MODEL_OPENAI);
      await store.put('model_local', this.savedModels['local'] ?? 'llama3');
      await store.put('key_openrouter', this.savedKeys['openrouter'] ?? '');
      await store.put('key_anthropic', this.savedKeys['anthropic'] ?? '');
      await store.put('key_openai', this.savedKeys['openai'] ?? '');
      await store.put('key_local', this.savedKeys['local'] ?? '');
      await store.put('url_openrouter', this.savedUrls['openrouter'] ?? '');
      await store.put('url_anthropic', this.savedUrls['anthropic'] ?? '');
      await store.put('url_openai', this.savedUrls['openai'] ?? '');
      await store.put('url_local', this.savedUrls['local'] ?? '');
      await store.flush();

      // Save gateway settings
      let gwStore = await preferences.getPreferences(ctx, Constants.PREFS_GATEWAY);
      await gwStore.put('enabled', this.gwEnabled);
      await gwStore.put('host', this.gwHost);
      await gwStore.put('port', this.gwPort);
      await gwStore.put('useTls', this.gwUseTls);
      await gwStore.put('token', this.gwToken);
      await gwStore.put('password', this.gwPassword);
      // Save capability toggles
      await gwStore.put('capLocation', this.capLocation);
      await gwStore.put('capCamera', this.capCamera);
      await gwStore.put('capCanvas', this.capCanvas);
      await gwStore.put('capScreen', this.capScreen);
      await gwStore.put('capNotification', this.capNotification);
      await gwStore.put('capMicrophone', this.capMicrophone);
      await gwStore.put('capSpeaker', this.capSpeaker);
      await gwStore.put('capEmail', this.capEmail);
      await gwStore.put('ttsAutoRead', this.ttsAutoRead);
      await gwStore.flush();

      // Update NodeRuntime capability config
      NodeRuntime.getInstance().updateCapabilities(
        this.capLocation, this.capCamera, this.capCanvas,
        this.capScreen, this.capNotification, undefined,
        this.capMicrophone, this.capSpeaker
      );

      // Save language
      await this.saveLang();

      promptAction.showToast({ message: I18n.t('settings.saved'), duration: 1500 });
    } catch (e) {
      promptAction.showToast({ message: I18n.t('settings.saveFailed') + String(e), duration: 2000 });
    }
  }

  private confirmLogout(): void {
    AlertDialog.show({
      title: I18n.t('settings.logoutConfirmTitle'),
      message: I18n.t('settings.logoutConfirmMessage'),
      primaryButton: {
        value: I18n.t('settings.cancel'),
        action: () => {}
      },
      secondaryButton: {
        value: I18n.t('settings.confirm'),
        fontColor: '#D32F2F',
        action: () => { this.doLogout(); }
      }
    });
  }

  private async doLogout(): Promise<void> {
    try {
      // Disconnect gateway
      NodeRuntime.getInstance().disconnect();

      let ctx = getContext(this) as common.UIAbilityContext;

      // Clear login state
      let loginStore = await preferences.getPreferences(ctx, Constants.PREFS_LOGIN);
      await loginStore.put('loggedIn', false);
      await loginStore.flush();

      // Clear gateway enabled flag (keep address for convenience)
      let gwStore = await preferences.getPreferences(ctx, Constants.PREFS_GATEWAY);
      await gwStore.put('enabled', false);
      await gwStore.put('password', '');
      await gwStore.flush();

      // Navigate to login page
      router.replaceUrl({ url: 'pages/LoginPage' });
    } catch (e) {
      promptAction.showToast({ message: 'Logout failed: ' + String(e), duration: 2000 });
    }
  }
}
