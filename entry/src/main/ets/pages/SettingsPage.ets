import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { fileIo, picker } from '@kit.CoreFileKit';
import { Constants } from '../common/Constants';
import { NodeRuntime } from '../service/gateway/NodeRuntime';
import { ConnectionState, GatewayEndpoint } from '../service/gateway/GatewayModels';
import { I18n, LangCode } from '../common/I18n';
import { SettingsProfile } from '../model/Models';
import { ImapService } from '../service/ImapService';
import { FeishuBotService } from '../service/FeishuBotService';
import socket from '@ohos.net.socket';

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
    'local': 'llama3',
    'custom': ''
  };
  private savedKeys: Record<string, string> = {
    'openrouter': '', 'anthropic': '', 'openai': '', 'local': '', 'custom': ''
  };
  private savedUrls: Record<string, string> = {
    'openrouter': '', 'anthropic': '', 'openai': '', 'local': '', 'custom': ''
  };
  @State asrEnabled: boolean = false;
  @State showKey: boolean = false;
  @State @Watch('onLangChange') lang: string = 'zh';
  @State settingsTab: string = Constants.DEFAULT_MODE; // 'standalone' | 'node' | 'service'

  // Assistant customization
  @State assistantName: string = '';
  @State assistantAvatar: string = '';

  // Soul (personality)
  @State soul: string = Constants.DEFAULT_SOUL;

  // ASR (Speech-to-Text) settings
  @State asrApiUrl: string = 'https://api.siliconflow.cn/v1/audio/transcriptions';
  @State asrApiKey: string = '';
  @State asrModel: string = 'FunAudioLLM/SenseVoiceSmall';
  @State showAsrKey: boolean = false;

  // Feishu Bot
  @State feishuEnabled: boolean = false;
  @State feishuAppId: string = '';
  @State feishuAppSecret: string = '';
  @State showFeishuSecret: boolean = false;
  @State feishuTestStatus: string = '';

  // Email / IMAP & SMTP
  @State emailEnabled: boolean = false;
  @State imapHost: string = 'imap.gmail.com';
  @State imapPort: string = '993';
  @State smtpHost: string = 'smtp.gmail.com';
  @State smtpPort: string = '465';
  @State imapUser: string = '';
  @State imapPass: string = '';
  @State showImapPass: boolean = false;
  @State emailTestStatus: string = '';

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

  // Profiles
  @State profiles: SettingsProfile[] = [];
  @State profileNameInput: string = '';
  @State showProfileSave: boolean = false;

  private gwListener: ((state: ConnectionState, text: string) => void) | undefined = undefined;
  private langListener: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    this.load();
    this.loadGateway();
    this.loadEmail();
    this.loadFeishu();
    this.loadProfiles();
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

        // =============== Gateway Connection (top section in node mode) ===============
        if (this.modesInclude('node') && !this.showTabs()) {
          this.SectionTitle(I18n.t('settings.gateway'))
          Column() {
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
          }
          .width('100%')
          .padding(16)
          .margin({ left: 16, right: 16 })
          .backgroundColor(Color.White)
          .borderRadius(12)
        }

        // =============== Common Settings ===============

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

        // ---- AI Assistant ----
        this.SectionTitle(I18n.t('settings.assistant'))
        Column() {
          Column({ space: 8 }) {
            if (this.assistantAvatar.length > 0) {
              Image('file://' + this.assistantAvatar)
                .width(72)
                .height(72)
                .borderRadius(36)
                .objectFit(ImageFit.Cover)
            } else {
              Text(this.getAssistantInitial())
                .fontSize(28)
                .fontWeight(FontWeight.Bold)
                .fontColor(Color.White)
                .textAlign(TextAlign.Center)
                .width(72)
                .height(72)
                .borderRadius(36)
                .backgroundColor('#D2691E')
            }
            Text(I18n.t('settings.assistantAvatarChange'))
              .fontSize(12)
              .fontColor('#D2691E')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ top: 8, bottom: 8 })
          .onClick(() => { this.pickAvatar(); })

          Divider().margin({ top: 8, bottom: 14 }).color('#F0F0F0')

          Text(I18n.t('settings.assistantName'))
            .fontSize(14)
            .fontColor('#1A1A1A')
            .width('100%')
          TextInput({ text: this.assistantName, placeholder: I18n.t('settings.assistantNamePlaceholder') })
            .height(40)
            .backgroundColor('#F5F5F5')
            .borderRadius(8)
            .margin({ top: 6 })
            .onChange((v: string) => { this.assistantName = v; })
        }
        .width('100%')
        .padding(16)
        .margin({ left: 16, right: 16 })
        .backgroundColor(Color.White)
        .borderRadius(12)

        // ---- Capabilities ----
        this.SectionTitle(I18n.t('settings.caps'))
        Column() {
          this.CapToggle(I18n.t('settings.capLocation'), this.capLocation, (v: boolean) => { this.capLocation = v; })
          this.CapToggle(I18n.t('settings.capCamera'), this.capCamera, (v: boolean) => { this.capCamera = v; })
          this.CapToggle(I18n.t('settings.capCanvas'), this.capCanvas, (v: boolean) => { this.capCanvas = v; })
          this.CapToggle(I18n.t('settings.capScreen'), this.capScreen, (v: boolean) => { this.capScreen = v; })
          this.CapToggle(I18n.t('settings.capNotification'), this.capNotification, (v: boolean) => { this.capNotification = v; })
          this.CapToggle(I18n.t('settings.capMicrophone'), this.capMicrophone, (v: boolean) => { this.capMicrophone = v; })
          this.CapToggle(I18n.t('settings.capSpeaker'), this.capSpeaker, (v: boolean) => { this.capSpeaker = v; })
          this.CapToggle(I18n.t('settings.capEmail'), this.capEmail, (v: boolean) => { this.capEmail = v; })

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
        .width('100%')
        .padding(16)
        .margin({ left: 16, right: 16 })
        .backgroundColor(Color.White)
        .borderRadius(12)

        // ---- Email / IMAP ----
        this.SectionTitle(I18n.t('settings.email'))
        Column() {
          Row() {
            Column({ space: 2 }) {
              Text(I18n.t('settings.emailEnabled'))
                .fontSize(14)
                .fontColor('#1A1A1A')
              Text(I18n.t('settings.emailEnabledDesc'))
                .fontSize(11)
                .fontColor('#999999')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.emailEnabled })
              .selectedColor('#D2691E')
              .onChange((isOn: boolean) => { this.emailEnabled = isOn; })
          }
          .width('100%')

          if (this.emailEnabled) {
            Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')

            Text(I18n.t('settings.imapHost'))
              .fontSize(14)
              .fontColor('#1A1A1A')
              .width('100%')
            TextInput({ text: this.imapHost, placeholder: 'imap.gmail.com' })
              .height(40)
              .backgroundColor('#F5F5F5')
              .borderRadius(8)
              .margin({ top: 6 })
              .onChange((v: string) => { this.imapHost = v; })

            Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')

            Row() {
              Text(I18n.t('settings.imapPort'))
                .fontSize(14)
                .fontColor('#1A1A1A')
                .layoutWeight(1)
              TextInput({ text: this.imapPort, placeholder: '993' })
                .width(100)
                .height(40)
                .backgroundColor('#F5F5F5')
                .borderRadius(8)
                .type(InputType.Number)
                .onChange((v: string) => { this.imapPort = v; })
            }
            .width('100%')

            Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')

            Text(I18n.t('settings.smtpHost'))
              .fontSize(14)
              .fontColor('#1A1A1A')
              .width('100%')
            TextInput({ text: this.smtpHost, placeholder: 'smtp.gmail.com' })
              .height(40)
              .backgroundColor('#F5F5F5')
              .borderRadius(8)
              .margin({ top: 6 })
              .onChange((v: string) => { this.smtpHost = v; })

            Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')

            Row() {
              Text(I18n.t('settings.smtpPort'))
                .fontSize(14)
                .fontColor('#1A1A1A')
                .layoutWeight(1)
              TextInput({ text: this.smtpPort, placeholder: '465' })
                .width(100)
                .height(40)
                .backgroundColor('#F5F5F5')
                .borderRadius(8)
                .type(InputType.Number)
                .onChange((v: string) => { this.smtpPort = v; })
            }
            .width('100%')

            Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')

            Text(I18n.t('settings.imapUser'))
              .fontSize(14)
              .fontColor('#1A1A1A')
              .width('100%')
            TextInput({ text: this.imapUser, placeholder: 'user@gmail.com' })
              .height(40)
              .backgroundColor('#F5F5F5')
              .borderRadius(8)
              .margin({ top: 6 })
              .onChange((v: string) => { this.imapUser = v; })

            Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')

            Text(I18n.t('settings.imapPass'))
              .fontSize(14)
              .fontColor('#1A1A1A')
              .width('100%')
            Row() {
              TextInput({ text: this.imapPass, placeholder: '••••••••' })
                .layoutWeight(1)
                .height(40)
                .backgroundColor('#F5F5F5')
                .borderRadius(8)
                .type(this.showImapPass ? InputType.Normal : InputType.Password)
                .onChange((v: string) => { this.imapPass = v; })
              Button(this.showImapPass ? I18n.t('settings.hide') : I18n.t('settings.show'))
                .fontSize(12)
                .height(34)
                .backgroundColor('#F0F0F0')
                .fontColor('#666666')
                .borderRadius(8)
                .margin({ left: 8 })
                .onClick(() => { this.showImapPass = !this.showImapPass; })
            }
            .margin({ top: 6 })
            .width('100%')

            Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')

            Button(this.emailTestStatus === I18n.t('settings.emailTesting')
              ? I18n.t('settings.emailTesting')
              : I18n.t('settings.emailTest'))
              .width('100%')
              .height(44)
              .backgroundColor('#4CAF50')
              .fontColor(Color.White)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .borderRadius(10)
              .onClick(() => { this.testEmailConnection(); })

            if (this.emailTestStatus.length > 0) {
              Text(this.emailTestStatus)
                .fontSize(12)
                .fontColor(this.emailTestStatus.includes(I18n.t('settings.emailTestOk')) ? '#4CAF50' : '#D32F2F')
                .margin({ top: 8 })
                .width('100%')
            }
          }
        }
        .width('100%')
        .padding(16)
        .margin({ left: 16, right: 16 })
        .backgroundColor(Color.White)
        .borderRadius(12)

        // =============== Tab Bar (only when multiple modes enabled) ===============
        if (this.showTabs()) {
          Row({ space: 0 }) {
            if (this.modesInclude('standalone')) {
              Text(I18n.t('settings.tabStandalone'))
                .fontSize(14)
                .fontWeight(this.settingsTab === 'standalone' ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(this.settingsTab === 'standalone' ? '#D2691E' : '#999999')
                .layoutWeight(1)
                .textAlign(TextAlign.Center)
                .padding({ top: 12, bottom: 12 })
                .borderWidth({ bottom: this.settingsTab === 'standalone' ? 2 : 0 })
                .borderColor('#D2691E')
                .onClick(() => { this.settingsTab = 'standalone'; })
            }
            if (this.modesInclude('node')) {
              Text(I18n.t('settings.tabNode'))
                .fontSize(14)
                .fontWeight(this.settingsTab === 'node' ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(this.settingsTab === 'node' ? '#D2691E' : '#999999')
                .layoutWeight(1)
                .textAlign(TextAlign.Center)
                .padding({ top: 12, bottom: 12 })
                .borderWidth({ bottom: this.settingsTab === 'node' ? 2 : 0 })
                .borderColor('#D2691E')
                .onClick(() => { this.settingsTab = 'node'; })
            }
            if (this.modesInclude('service')) {
              Text(I18n.t('settings.tabService'))
                .fontSize(14)
                .fontWeight(this.settingsTab === 'service' ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(this.settingsTab === 'service' ? '#D2691E' : '#999999')
                .layoutWeight(1)
                .textAlign(TextAlign.Center)
                .padding({ top: 12, bottom: 12 })
                .borderWidth({ bottom: this.settingsTab === 'service' ? 2 : 0 })
                .borderColor('#D2691E')
                .onClick(() => { this.settingsTab = 'service'; })
            }
          }
          .width('100%')
          .margin({ left: 16, right: 16, top: 20 })
          .backgroundColor(Color.White)
          .borderRadius({ topLeft: 12, topRight: 12 })

          // ---- Soul / Personality (standalone tab only, multi-mode) ----
          if (this.settingsTab === 'standalone' && this.modesInclude('standalone')) {
            this.SectionTitle(I18n.t('settings.soul'))
            Column() {
              Text(I18n.t('settings.soulDesc'))
                .fontSize(11)
                .fontColor('#999999')
                .width('100%')
                .margin({ bottom: 10 })

              TextArea({ text: this.soul, placeholder: 'Enter soul / personality...' })
                .width('100%')
                .height(200)
                .backgroundColor('#F5F5F5')
                .borderRadius(8)
                .fontSize(13)
                .onChange((v: string) => { this.soul = v; })

              Row() {
                Blank()
                Text(I18n.t('settings.soulReset'))
                  .fontSize(12)
                  .fontColor('#D2691E')
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .borderRadius(6)
                  .borderWidth(1)
                  .borderColor('#D2691E')
                  .margin({ top: 10 })
                  .onClick(() => {
                    this.soul = Constants.DEFAULT_SOUL;
                    promptAction.showToast({ message: I18n.t('settings.soulResetDone'), duration: 1500 });
                  })
              }
              .width('100%')
            }
            .width('100%')
            .padding(16)
            .margin({ left: 16, right: 16 })
            .backgroundColor(Color.White)
            .borderRadius(12)
          }
        }

        // =============== Standalone Tab — AI Provider, Generation, ASR ===============
        if (this.settingsTab === 'standalone' && this.modesInclude('standalone')) {
          // ---- AI Provider ----
          this.SectionTitle(I18n.t('settings.aiProvider'))
          Column() {
            Text(I18n.t('settings.provider'))
              .fontSize(14)
              .fontColor('#666666')
              .margin({ bottom: 8 })
              .width('100%')
            Scroll() {
              Row({ space: 8 }) {
              ForEach(['openrouter', 'anthropic', 'openai', 'local', 'custom'] as string[], (p: string) => {
                Text(this.providerLabel(p))
                  .fontSize(13)
                  .fontColor(this.provider === p ? Color.White : '#666666')
                  .backgroundColor(this.provider === p ? '#D2691E' : '#F0F0F0')
                  .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                  .borderRadius(8)
                  .onClick(() => {
                    this.savedModels[this.provider] = this.model;
                    this.savedKeys[this.provider] = this.apiKey;
                    this.savedUrls[this.provider] = this.baseUrl;
                    this.provider = p;
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
                    : this.provider === 'custom'
                      ? 'https://your-api.com/v1/chat/completions'
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

          // ---- ASR (Speech-to-Text) with toggle ----
          if (this.provider !== 'anthropic') {
            this.SectionTitle('ASR')
            Column() {
              Row() {
                Column({ space: 2 }) {
                  Text(I18n.t('settings.asrEnabled'))
                    .fontSize(14)
                    .fontColor('#1A1A1A')
                  Text(I18n.t('settings.asrEnabledDesc'))
                    .fontSize(11)
                    .fontColor('#999999')
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Toggle({ type: ToggleType.Switch, isOn: this.asrEnabled })
                  .selectedColor('#D2691E')
                  .onChange((isOn: boolean) => { this.asrEnabled = isOn; })
              }
              .width('100%')

              if (this.asrEnabled) {
                Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')

                Text('API URL')
                  .fontSize(14)
                  .fontColor('#1A1A1A')
                  .width('100%')
                TextInput({ text: this.asrApiUrl, placeholder: 'https://api.openai.com/v1/audio/transcriptions' })
                  .height(40)
                  .backgroundColor('#F5F5F5')
                  .borderRadius(8)
                  .margin({ top: 6 })
                  .onChange((v: string) => { this.asrApiUrl = v; })

                Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')

                Text('API Key')
                  .fontSize(14)
                  .fontColor('#1A1A1A')
                  .width('100%')
                Row() {
                  TextInput({ text: this.asrApiKey, placeholder: 'sk-...' })
                    .layoutWeight(1)
                    .height(40)
                    .backgroundColor('#F5F5F5')
                    .borderRadius(8)
                    .type(this.showAsrKey ? InputType.Normal : InputType.Password)
                    .onChange((v: string) => { this.asrApiKey = v; })
                  Button(this.showAsrKey ? I18n.t('settings.hide') : I18n.t('settings.show'))
                    .fontSize(12)
                    .height(34)
                    .backgroundColor('#F0F0F0')
                    .fontColor('#666666')
                    .borderRadius(8)
                    .margin({ left: 8 })
                    .onClick(() => { this.showAsrKey = !this.showAsrKey; })
                }
                .margin({ top: 6 })
                .width('100%')

                Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')

                Text('Model')
                  .fontSize(14)
                  .fontColor('#1A1A1A')
                  .width('100%')
                TextInput({ text: this.asrModel, placeholder: 'whisper-1' })
                  .height(40)
                  .backgroundColor('#F5F5F5')
                  .borderRadius(8)
                  .margin({ top: 6 })
                  .onChange((v: string) => { this.asrModel = v; })
              }
            }
            .width('100%')
            .padding(16)
            .margin({ left: 16, right: 16 })
            .backgroundColor(Color.White)
            .borderRadius(12)
          }

        }

        // =============== Node Tab (multi-mode only, gateway with enable toggle) ===============
        if (this.settingsTab === 'node' && this.showTabs()) {
          // ---- Gateway / Node Mode ----
          this.SectionTitle(I18n.t('settings.gateway'))
          Column() {
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
            }
          }
          .width('100%')
          .padding(16)
          .margin({ left: 16, right: 16 })
          .backgroundColor(Color.White)
          .borderRadius(12)
        }

        // =============== Service Tab ===============
        if (this.settingsTab === 'service' && this.modesInclude('service')) {
          // ---- Feishu Bot ----
          this.SectionTitle(I18n.t('settings.feishu'))
          Column() {
            Row() {
              Column({ space: 2 }) {
                Text(I18n.t('settings.feishuEnabled'))
                  .fontSize(14)
                  .fontColor('#1A1A1A')
                Text(I18n.t('settings.feishuEnabledDesc'))
                  .fontSize(11)
                  .fontColor('#999999')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Toggle({ type: ToggleType.Switch, isOn: this.feishuEnabled })
                .selectedColor('#D2691E')
                .onChange((isOn: boolean) => { this.feishuEnabled = isOn; })
            }
            .width('100%')

            if (this.feishuEnabled) {
              Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')

              Text(I18n.t('settings.feishuAppId'))
                .fontSize(14)
                .fontColor('#1A1A1A')
                .width('100%')
              TextInput({ text: this.feishuAppId, placeholder: 'cli_xxxxxxxx' })
                .height(40)
                .backgroundColor('#F5F5F5')
                .borderRadius(8)
                .margin({ top: 6 })
                .onChange((v: string) => { this.feishuAppId = v; })

              Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')

              Text(I18n.t('settings.feishuAppSecret'))
                .fontSize(14)
                .fontColor('#1A1A1A')
                .width('100%')
              Row() {
                TextInput({ text: this.feishuAppSecret, placeholder: '••••••••' })
                  .layoutWeight(1)
                  .height(40)
                  .backgroundColor('#F5F5F5')
                  .borderRadius(8)
                  .type(this.showFeishuSecret ? InputType.Normal : InputType.Password)
                  .onChange((v: string) => { this.feishuAppSecret = v; })
                Button(this.showFeishuSecret ? I18n.t('settings.hide') : I18n.t('settings.show'))
                  .fontSize(12)
                  .height(34)
                  .backgroundColor('#F0F0F0')
                  .fontColor('#666666')
                  .borderRadius(8)
                  .margin({ left: 8 })
                  .onClick(() => { this.showFeishuSecret = !this.showFeishuSecret; })
              }
              .margin({ top: 6 })
              .width('100%')

              Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')

              Button(this.feishuTestStatus === I18n.t('settings.feishuTesting')
                ? I18n.t('settings.feishuTesting')
                : I18n.t('settings.feishuTest'))
                .width('100%')
                .height(44)
                .backgroundColor('#4CAF50')
                .fontColor(Color.White)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .borderRadius(10)
                .onClick(() => { this.testFeishuConnection(); })

              if (this.feishuTestStatus.length > 0) {
                Text(this.feishuTestStatus)
                  .fontSize(12)
                  .fontColor(this.feishuTestStatus.includes(I18n.t('settings.feishuTestOk')) ? '#4CAF50' : '#D32F2F')
                  .margin({ top: 8 })
                  .width('100%')
              }
            }
          }
          .width('100%')
          .padding(16)
          .margin({ left: 16, right: 16 })
          .backgroundColor(Color.White)
          .borderRadius(12)
        }

        // =============== Bottom (always visible) ===============

        // ---- About ----
        this.SectionTitle(I18n.t('settings.about'))
        Column() {
          this.InfoRow(I18n.t('settings.app'), I18n.t('settings.appValue'))
          Divider().color('#F0F0F0')
          this.InfoRow(I18n.t('settings.version'), '2.9.3')
          Divider().color('#F0F0F0')
          this.InfoRow(I18n.t('settings.basedOn'), 'OpenClaw / ClawdBot')
          Divider().color('#F0F0F0')
          this.InfoRow(I18n.t('settings.platform'), 'HarmonyOS NEXT')
        }
        .padding(16)
        .margin({ left: 16, right: 16 })
        .backgroundColor(Color.White)
        .borderRadius(12)

        // =============== Profiles ===============
        this.SectionTitle(I18n.t('settings.profiles'))
        Column() {
          // Saved profiles list
          if (this.profiles.filter((p: SettingsProfile) => p.mode === this.settingsTab).length === 0) {
            Text(I18n.t('settings.profileEmpty'))
              .fontSize(13)
              .fontColor('#999999')
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 8, bottom: 8 })
          } else {
            ForEach(this.profiles.filter((p: SettingsProfile) => p.mode === this.settingsTab),
              (profile: SettingsProfile) => {
                Row() {
                  Column() {
                    Text(profile.name)
                      .fontSize(14)
                      .fontColor('#1A1A1A')
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(new Date(profile.createdAt).toLocaleDateString())
                      .fontSize(11)
                      .fontColor('#999999')
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  Text(I18n.t('settings.profileLoad'))
                    .fontSize(12)
                    .fontColor(Color.White)
                    .backgroundColor('#D2691E')
                    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                    .borderRadius(6)
                    .margin({ right: 8 })
                    .onClick(() => { this.loadProfile(profile); })

                  Text(I18n.t('settings.profileDelete'))
                    .fontSize(12)
                    .fontColor('#D32F2F')
                    .borderWidth(1)
                    .borderColor('#D32F2F')
                    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                    .borderRadius(6)
                    .onClick(() => { this.deleteProfile(profile); })
                }
                .width('100%')
                .padding({ top: 8, bottom: 8 })

                Divider().color('#F0F0F0')
              })
          }

          // Save as profile
          if (this.showProfileSave) {
            Row() {
              TextInput({ text: this.profileNameInput, placeholder: I18n.t('settings.profileNamePlaceholder') })
                .layoutWeight(1)
                .height(36)
                .backgroundColor('#F5F5F5')
                .borderRadius(8)
                .fontSize(13)
                .onChange((v: string) => { this.profileNameInput = v; })

              Text('\u2714')
                .fontSize(18)
                .fontColor('#4CAF50')
                .padding({ left: 12, right: 6 })
                .onClick(() => { this.saveProfile(); })

              Text('\u2716')
                .fontSize(18)
                .fontColor('#D32F2F')
                .padding({ left: 6, right: 4 })
                .onClick(() => {
                  this.showProfileSave = false;
                  this.profileNameInput = '';
                })
            }
            .width('100%')
            .margin({ top: 8 })
          } else {
            Text(I18n.t('settings.profileSave'))
              .fontSize(13)
              .fontColor('#D2691E')
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 10, bottom: 4 })
              .onClick(() => {
                this.showProfileSave = true;
                this.profileNameInput = '';
              })
          }
        }
        .width('100%')
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
    if (p === 'custom') return '';
    return 'llama3';
  }

  private providerLabel(p: string): string {
    if (p === 'openrouter') return 'OpenRouter';
    if (p === 'anthropic') return 'Anthropic';
    if (p === 'openai') return 'OpenAI';
    if (p === 'custom') return I18n.t('settings.customProvider');
    return 'Ollama';
  }

  private showTabs(): boolean {
    return Constants.ENABLED_MODES.length > 1;
  }

  private modesInclude(mode: string): boolean {
    return Constants.ENABLED_MODES.indexOf(mode) >= 0;
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

  private getAssistantInitial(): string {
    if (this.assistantName.length > 0) {
      return this.assistantName.charAt(0).toUpperCase();
    }
    return 'C';
  }

  private async pickAvatar(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let photoPicker = new picker.PhotoViewPicker(ctx);
      let options = new picker.PhotoSelectOptions();
      options.MIMEType = picker.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      let result = await photoPicker.select(options);
      if (result.photoUris.length === 0) return;
      let srcUri = result.photoUris[0];

      // Delete old avatar file
      if (this.assistantAvatar.length > 0) {
        try { fileIo.unlinkSync(this.assistantAvatar); } catch { /* ignore */ }
      }

      let destPath = ctx.filesDir + `/assistant_avatar_${Date.now()}.jpg`;

      // Copy from picker URI to app sandbox
      let srcFile = fileIo.openSync(srcUri, fileIo.OpenMode.READ_ONLY);
      let destFile = fileIo.openSync(destPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      let buf = new ArrayBuffer(4096);
      let bytesRead = fileIo.readSync(srcFile.fd, buf);
      while (bytesRead > 0) {
        fileIo.writeSync(destFile.fd, buf, { length: bytesRead });
        bytesRead = fileIo.readSync(srcFile.fd, buf);
      }
      fileIo.closeSync(srcFile);
      fileIo.closeSync(destFile);

      this.assistantAvatar = destPath;
      // Notify other pages (ChatPage) to reload avatar
      I18n.setLang(I18n.lang);
    } catch { /* user cancelled or error */ }
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

  private async toggleGateway(): Promise<void> {
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
    let runtime = NodeRuntime.getInstance();
    runtime.updateCapabilities(
      this.capLocation, this.capCamera, this.capCanvas,
      this.capScreen, this.capNotification, undefined,
      this.capMicrophone, this.capSpeaker, this.capEmail
    );
    await runtime.loadDisplayName(ctx);
    runtime.connect(ctx, endpoint, token, password);
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
      this.savedKeys['custom'] = (await store.get('key_custom', '')) as string;
      this.savedUrls['openrouter'] = (await store.get('url_openrouter', '')) as string;
      this.savedUrls['anthropic'] = (await store.get('url_anthropic', '')) as string;
      this.savedUrls['openai'] = (await store.get('url_openai', '')) as string;
      this.savedUrls['local'] = (await store.get('url_local', '')) as string;
      this.savedUrls['custom'] = (await store.get('url_custom', '')) as string;
      this.savedModels['custom'] = (await store.get('model_custom', '')) as string;
      // Set current values from active provider
      this.model = this.savedModels[this.provider] ?? this.defaultModelFor(this.provider);
      this.apiKey = this.savedKeys[this.provider] ?? '';
      this.baseUrl = this.savedUrls[this.provider] ?? '';
      // ASR settings
      this.asrEnabled = (await store.get('asr_enabled', false)) as boolean;
      this.asrApiUrl = (await store.get('asr_url', 'https://api.siliconflow.cn/v1/audio/transcriptions')) as string;
      this.asrApiKey = (await store.get('asr_key', '')) as string;
      this.asrModel = (await store.get('asr_model', 'FunAudioLLM/SenseVoiceSmall')) as string;
      // Soul
      this.soul = (await store.get('soul', Constants.DEFAULT_SOUL)) as string;
      // Assistant customization
      this.assistantName = (await store.get('assistant_name', '')) as string;
      this.assistantAvatar = (await store.get('assistant_avatar', '')) as string;
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

  private async loadEmail(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let store = await preferences.getPreferences(ctx, Constants.PREFS_EMAIL);
      this.emailEnabled = (await store.get('enabled', false)) as boolean;
      let savedHost = (await store.get('imapHost', '')) as string;
      if (savedHost.length > 0) this.imapHost = savedHost;
      let savedPort = (await store.get('imapPort', '')) as string;
      if (savedPort.length > 0) this.imapPort = savedPort;
      let savedSmtpHost = (await store.get('smtpHost', '')) as string;
      if (savedSmtpHost.length > 0) this.smtpHost = savedSmtpHost;
      let savedSmtpPort = (await store.get('smtpPort', '')) as string;
      if (savedSmtpPort.length > 0) this.smtpPort = savedSmtpPort;
      this.imapUser = (await store.get('imapUser', '')) as string;
      this.imapPass = (await store.get('imapPass', '')) as string;
    } catch { /* first launch defaults */ }
  }

  private async loadFeishu(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let store = await preferences.getPreferences(ctx, Constants.PREFS_FEISHU);
      this.feishuEnabled = (await store.get('enabled', false)) as boolean;
      this.feishuAppId = (await store.get('appId', '')) as string;
      this.feishuAppSecret = (await store.get('appSecret', '')) as string;
    } catch { /* first launch defaults */ }
  }

  private async testFeishuConnection(): Promise<void> {
    this.feishuTestStatus = I18n.t('settings.feishuTesting');
    try {
      let wssUrl = await FeishuBotService.getInstance().testConnection(
        this.feishuAppId.trim(), this.feishuAppSecret.trim()
      );
      this.feishuTestStatus = `${I18n.t('settings.feishuTestOk')} (${wssUrl.substring(0, 40)}...)`;
    } catch (e) {
      this.feishuTestStatus = I18n.t('settings.feishuTestFail') + (e as Error).message;
    }
  }

  private async testEmailConnection(): Promise<void> {
    this.emailTestStatus = I18n.t('settings.emailTesting');

    // Test IMAP
    let imapResult = '';
    let imap = new ImapService();
    try {
      let port = parseInt(this.imapPort) || 993;
      await imap.connect(this.imapHost.trim(), port);
      await imap.login(this.imapUser.trim(), this.imapPass);
      let count = await imap.selectMailbox('INBOX');
      await imap.logout();
      imapResult = `IMAP OK (${count})`;
    } catch (e) {
      imapResult = `IMAP FAIL: ${(e as Error).message}`;
      try { await imap.logout(); } catch { /* ignore */ }
    }

    // Test SMTP
    let smtpResult = '';
    try {
      let smtpPort = parseInt(this.smtpPort) || 465;
      let tlsSocket = socket.constructTLSSocketInstance();
      let smtpBuf = '';
      let smtpQueue: string[] = [];
      let smtpResolve: ((line: string) => void) | null = null;

      // Set up persistent message handler with queue (avoids race condition)
      tlsSocket.on('message', (value: socket.SocketMessageInfo) => {
        let view = new Uint8Array(value.message);
        for (let i = 0; i < view.length; i++) {
          smtpBuf += String.fromCharCode(view[i]);
        }
        let nlIdx = smtpBuf.indexOf('\r\n');
        while (nlIdx >= 0) {
          let line = smtpBuf.substring(0, nlIdx);
          smtpBuf = smtpBuf.substring(nlIdx + 2);
          if (line.length >= 4 && line[3] === '-') {
            nlIdx = smtpBuf.indexOf('\r\n');
            continue;
          }
          if (smtpResolve) {
            let resolve = smtpResolve;
            smtpResolve = null;
            resolve(line);
          } else {
            smtpQueue.push(line);
          }
          nlIdx = smtpBuf.indexOf('\r\n');
        }
      });

      let smtpWait = (timeoutMs: number): Promise<string> => {
        return new Promise<string>((resolve, reject) => {
          if (smtpQueue.length > 0) {
            resolve(smtpQueue.shift() as string);
            return;
          }
          smtpResolve = resolve;
          let timer = setTimeout(() => {
            if (smtpResolve) {
              smtpResolve = null;
              reject(new Error('SMTP timeout'));
            }
          }, timeoutMs);
          let origResolve = smtpResolve;
          smtpResolve = (line: string) => {
            clearTimeout(timer);
            origResolve(line);
          };
        });
      };

      let smtpExpect = async (expected: string, cmd?: string): Promise<string> => {
        if (cmd) {
          await tlsSocket.send(this.strToBuf(cmd));
        }
        let line = await smtpWait(10000);
        if (!line.startsWith(expected)) {
          throw new Error(`expected ${expected}, got: ${line}`);
        }
        return line;
      };

      await tlsSocket.bind({ address: '0.0.0.0' });
      let tlsOptions: socket.TLSConnectOptions = {
        address: { address: this.smtpHost.trim(), port: smtpPort, family: 1 },
        secureOptions: { protocols: [socket.Protocol.TLSv12] },
      };
      let connectTimeout = new Promise<void>((_r, reject) => {
        setTimeout(() => { reject(new Error('SMTP connect timeout')); }, 15000);
      });
      await Promise.race([tlsSocket.connect(tlsOptions), connectTimeout]);

      // 220 greeting (may already be in queue)
      await smtpExpect('220');
      await smtpExpect('250', 'EHLO clawdbot\r\n');
      await smtpExpect('334', 'AUTH LOGIN\r\n');
      await smtpExpect('334', this.simpleBase64(this.imapUser.trim()) + '\r\n');
      await smtpExpect('235', this.simpleBase64(this.imapPass) + '\r\n');

      smtpResult = 'SMTP OK';

      try { await tlsSocket.send(this.strToBuf('QUIT\r\n')); } catch { /* ignore */ }
      try { await tlsSocket.close(); } catch { /* ignore */ }
    } catch (e) {
      smtpResult = `SMTP FAIL: ${(e as Error).message}`;
    }

    // Combine results
    let allOk = imapResult.startsWith('IMAP OK') && smtpResult.startsWith('SMTP OK');
    this.emailTestStatus = allOk
      ? `${I18n.t('settings.emailTestOk')} — ${imapResult}, ${smtpResult}`
      : `${imapResult} | ${smtpResult}`;
  }

  private simpleBase64(input: string): string {
    let chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    let bytes: number[] = [];
    for (let i = 0; i < input.length; i++) {
      let code = input.charCodeAt(i);
      if (code < 0x80) {
        bytes.push(code);
      } else if (code < 0x800) {
        bytes.push(0xC0 | (code >> 6));
        bytes.push(0x80 | (code & 0x3F));
      } else {
        bytes.push(0xE0 | (code >> 12));
        bytes.push(0x80 | ((code >> 6) & 0x3F));
        bytes.push(0x80 | (code & 0x3F));
      }
    }
    let result = '';
    for (let i = 0; i < bytes.length; i += 3) {
      let b1 = bytes[i];
      let b2 = i + 1 < bytes.length ? bytes[i + 1] : 0;
      let b3 = i + 2 < bytes.length ? bytes[i + 2] : 0;
      result += chars[(b1 >> 2) & 0x3F];
      result += chars[((b1 & 3) << 4) | ((b2 >> 4) & 0xF)];
      result += i + 1 < bytes.length ? chars[((b2 & 0xF) << 2) | ((b3 >> 6) & 3)] : '=';
      result += i + 2 < bytes.length ? chars[b3 & 0x3F] : '=';
    }
    return result;
  }

  private strToBuf(str: string): ArrayBuffer {
    let buf = new ArrayBuffer(str.length);
    let view = new Uint8Array(buf);
    for (let i = 0; i < str.length; i++) {
      view[i] = str.charCodeAt(i) & 0xFF;
    }
    return buf;
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
      await store.put('model_custom', this.savedModels['custom'] ?? '');
      await store.put('key_openrouter', this.savedKeys['openrouter'] ?? '');
      await store.put('key_anthropic', this.savedKeys['anthropic'] ?? '');
      await store.put('key_openai', this.savedKeys['openai'] ?? '');
      await store.put('key_local', this.savedKeys['local'] ?? '');
      await store.put('key_custom', this.savedKeys['custom'] ?? '');
      await store.put('url_openrouter', this.savedUrls['openrouter'] ?? '');
      await store.put('url_anthropic', this.savedUrls['anthropic'] ?? '');
      await store.put('url_openai', this.savedUrls['openai'] ?? '');
      await store.put('url_local', this.savedUrls['local'] ?? '');
      await store.put('url_custom', this.savedUrls['custom'] ?? '');
      // ASR settings
      await store.put('asr_enabled', this.asrEnabled);
      await store.put('asr_url', this.asrApiUrl);
      await store.put('asr_key', this.asrApiKey);
      await store.put('asr_model', this.asrModel);
      // Soul
      await store.put('soul', this.soul);
      // Assistant customization
      await store.put('assistant_name', this.assistantName);
      await store.put('assistant_avatar', this.assistantAvatar);
      await store.flush();

      // Save gateway settings
      let gwStore = await preferences.getPreferences(ctx, Constants.PREFS_GATEWAY);
      // In single node mode, gateway is always enabled
      let gwEnabledValue = !this.showTabs() && this.modesInclude('node') ? true : this.gwEnabled;
      await gwStore.put('enabled', gwEnabledValue);
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

      // Save feishu settings
      let feishuStore = await preferences.getPreferences(ctx, Constants.PREFS_FEISHU);
      await feishuStore.put('enabled', this.feishuEnabled);
      await feishuStore.put('appId', this.feishuAppId);
      await feishuStore.put('appSecret', this.feishuAppSecret);
      await feishuStore.flush();

      // Save email settings
      let emailStore = await preferences.getPreferences(ctx, Constants.PREFS_EMAIL);
      await emailStore.put('enabled', this.emailEnabled);
      await emailStore.put('imapHost', this.imapHost);
      await emailStore.put('imapPort', this.imapPort);
      await emailStore.put('smtpHost', this.smtpHost);
      await emailStore.put('smtpPort', this.smtpPort);
      await emailStore.put('imapUser', this.imapUser);
      await emailStore.put('imapPass', this.imapPass);
      await emailStore.flush();

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

  // ============ Profiles ============

  private async loadProfiles(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let store = await preferences.getPreferences(ctx, 'clawdbot_profiles');
      let json = (await store.get('profiles', '[]')) as string;
      let arr: SettingsProfile[] = JSON.parse(json) as SettingsProfile[];
      this.profiles = arr;
    } catch { /* ignore */ }
  }

  private async persistProfiles(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let store = await preferences.getPreferences(ctx, 'clawdbot_profiles');
      await store.put('profiles', JSON.stringify(this.profiles));
      await store.flush();
    } catch { /* ignore */ }
  }

  private async saveProfile(): Promise<void> {
    let name = this.profileNameInput.trim();
    if (name.length === 0) return;

    let data: Record<string, string | number | boolean> = {};
    if (this.settingsTab === 'standalone' || (!this.showTabs() && this.modesInclude('standalone'))) {
      // Standalone mode settings
      this.savedModels[this.provider] = this.model;
      this.savedKeys[this.provider] = this.apiKey;
      this.savedUrls[this.provider] = this.baseUrl;
      data['provider'] = this.provider;
      data['temperature'] = this.temperature;
      data['model'] = this.model;
      data['apiKey'] = this.apiKey;
      data['baseUrl'] = this.baseUrl;
      data['asrEnabled'] = this.asrEnabled;
      data['asrApiUrl'] = this.asrApiUrl;
      data['asrApiKey'] = this.asrApiKey;
      data['asrModel'] = this.asrModel;
      data['soul'] = this.soul;
    } else {
      // Node mode settings
      data['gwHost'] = this.gwHost;
      data['gwPort'] = this.gwPort;
      data['gwUseTls'] = this.gwUseTls;
      data['gwToken'] = this.gwToken;
      data['gwPassword'] = this.gwPassword;
      data['capLocation'] = this.capLocation;
      data['capCamera'] = this.capCamera;
      data['capCanvas'] = this.capCanvas;
      data['capScreen'] = this.capScreen;
      data['capNotification'] = this.capNotification;
      data['capMicrophone'] = this.capMicrophone;
      data['capSpeaker'] = this.capSpeaker;
      data['capEmail'] = this.capEmail;
      data['ttsAutoRead'] = this.ttsAutoRead;
    }

    let mode = (this.settingsTab === 'node' || (!this.showTabs() && this.modesInclude('node') && !this.modesInclude('standalone')))
      ? 'node' : 'standalone';

    let profile: SettingsProfile = {
      name: name,
      mode: mode,
      data: JSON.stringify(data),
      createdAt: Date.now()
    };

    this.profiles.push(profile);
    await this.persistProfiles();
    this.showProfileSave = false;
    this.profileNameInput = '';
    promptAction.showToast({ message: I18n.t('settings.profileSaved'), duration: 1500 });
  }

  private loadProfile(profile: SettingsProfile): void {
    try {
      let data: Record<string, string | number | boolean> = JSON.parse(profile.data) as Record<string, string | number | boolean>;
      if (profile.mode === 'standalone') {
        if (data['provider'] !== undefined) this.provider = data['provider'] as string;
        if (data['temperature'] !== undefined) this.temperature = data['temperature'] as number;
        if (data['model'] !== undefined) this.model = data['model'] as string;
        if (data['apiKey'] !== undefined) this.apiKey = data['apiKey'] as string;
        if (data['baseUrl'] !== undefined) this.baseUrl = data['baseUrl'] as string;
        if (data['asrEnabled'] !== undefined) this.asrEnabled = data['asrEnabled'] as boolean;
        if (data['asrApiUrl'] !== undefined) this.asrApiUrl = data['asrApiUrl'] as string;
        if (data['asrApiKey'] !== undefined) this.asrApiKey = data['asrApiKey'] as string;
        if (data['asrModel'] !== undefined) this.asrModel = data['asrModel'] as string;
        if (data['soul'] !== undefined) this.soul = data['soul'] as string;
        // Update per-provider maps
        this.savedModels[this.provider] = this.model;
        this.savedKeys[this.provider] = this.apiKey;
        this.savedUrls[this.provider] = this.baseUrl;
      } else {
        if (data['gwHost'] !== undefined) this.gwHost = data['gwHost'] as string;
        if (data['gwPort'] !== undefined) this.gwPort = data['gwPort'] as string;
        if (data['gwUseTls'] !== undefined) this.gwUseTls = data['gwUseTls'] as boolean;
        if (data['gwToken'] !== undefined) this.gwToken = data['gwToken'] as string;
        if (data['gwPassword'] !== undefined) this.gwPassword = data['gwPassword'] as string;
        if (data['capLocation'] !== undefined) this.capLocation = data['capLocation'] as boolean;
        if (data['capCamera'] !== undefined) this.capCamera = data['capCamera'] as boolean;
        if (data['capCanvas'] !== undefined) this.capCanvas = data['capCanvas'] as boolean;
        if (data['capScreen'] !== undefined) this.capScreen = data['capScreen'] as boolean;
        if (data['capNotification'] !== undefined) this.capNotification = data['capNotification'] as boolean;
        if (data['capMicrophone'] !== undefined) this.capMicrophone = data['capMicrophone'] as boolean;
        if (data['capSpeaker'] !== undefined) this.capSpeaker = data['capSpeaker'] as boolean;
        if (data['capEmail'] !== undefined) this.capEmail = data['capEmail'] as boolean;
        if (data['ttsAutoRead'] !== undefined) this.ttsAutoRead = data['ttsAutoRead'] as boolean;
      }
      promptAction.showToast({ message: I18n.t('settings.profileLoaded'), duration: 1500 });
    } catch { /* ignore */ }
  }

  private async deleteProfile(profile: SettingsProfile): Promise<void> {
    this.profiles = this.profiles.filter((p: SettingsProfile) => p.createdAt !== profile.createdAt || p.name !== profile.name);
    await this.persistProfiles();
    promptAction.showToast({ message: I18n.t('settings.profileDeleted'), duration: 1500 });
  }
}
