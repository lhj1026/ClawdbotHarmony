import { preferences } from '@kit.ArkData';
import { common, Want } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { fileIo, picker } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { bundleManager } from '@kit.AbilityKit';
import { request } from '@kit.BasicServicesKit';
import { execCmd } from 'libexec.so';
import { Constants } from '../common/Constants';
import { NodeRuntime } from '../service/gateway/NodeRuntime';
import { ConnectionState, GatewayEndpoint, AgentIdentity } from '../service/gateway/GatewayModels';
import { I18n, LangCode } from '../common/I18n';
import { SettingsProfile } from '../model/Models';
import { ImapService } from '../service/ImapService';
import { FeishuBotService } from '../service/FeishuBotService';
import { VoiceprintManager } from '../components/VoiceprintManager';
import { ExperienceStorage } from '../service/ExperienceStorage';
import socket from '@ohos.net.socket';
import { util } from '@kit.ArkTS';
import { Monitor, ModuleStat } from '../service/ModuleMonitor';

interface BmExecResult {
  exitCode: number;
  stdout: string;
  stderr: string;
}

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
    'siliconflow': Constants.DEFAULT_MODEL_SILICONFLOW,
    'local': 'llama3',
    'custom': ''
  };
  private savedKeys: Record<string, string> = {
    'openrouter': '', 'anthropic': '', 'openai': '', 'siliconflow': '', 'local': '', 'custom': ''
  };
  private savedUrls: Record<string, string> = {
    'openrouter': '', 'anthropic': '', 'openai': '', 'siliconflow': '', 'local': '', 'custom': ''
  };
  @State asrMode: string = 'cloud'; // 'auto' | 'local' | 'cloud'
  @State embeddingMode: string = 'auto'; // 'auto' | 'local' | 'cloud'
  @State intentMode: string = 'auto'; // 'auto' | 'local' | 'cloud'
  @State showKey: boolean = false;
  @State @Watch('onLangChange') lang: string = 'zh';
  @State settingsTab: string = Constants.DEFAULT_MODE; // 'operator' | 'node' | 'service'

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

  // Embedding (cloud) settings
  @State embeddingApiKey: string = '';
  @State showEmbeddingKey: boolean = false;

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
  @State gwEnabled: boolean = false;  // Node access toggle
  @State operatorEnabled: boolean = false;  // Gateway connect toggle
  @State gwHost: string = '192.168.1.68';
  @State gwPort: string = '18789';
  @State gwUseTls: boolean = false;
  @State gwToken: string = 'd71a61ab10ca57779f52838835aaf688c7ba0a1e4c680489';
  @State gwPassword: string = '';
  @State gwStatusText: string = 'Offline';
  @State gwState: ConnectionState = ConnectionState.Disconnected;
  @State operatorState: ConnectionState = ConnectionState.Disconnected;
  @State nodeState: ConnectionState = ConnectionState.Disconnected;

  // Capability toggles
  @State capLocation: boolean = true;
  @State capCamera: boolean = true;
  @State capCanvas: boolean = true;
  @State capScreen: boolean = true;
  @State capNotification: boolean = true;
  @State capMicrophone: boolean = true;
  @State capSpeaker: boolean = true;
  @State capEmail: boolean = true;
  @State aiEngineEnabled: boolean = false;  // AI Engine toggle (ASR/Embedding/Intent)
  @State unreadNotification: boolean = true;
  @State ttsAutoRead: boolean = false;
  @State autoMemoryInject: boolean = Constants.DEFAULT_AUTO_MEMORY_INJECT;
  // Session management
  @State parallelSessions: boolean = true;
  @State idleTimeoutMinutes: number = 30;

  // Profiles
  @State profiles: SettingsProfile[] = [];
  @State profileNameInput: string = '';
  @State showProfileSave: boolean = false;

  // Gateway agent identity (fetched from gateway when connected in node mode)
  @State gwAgentName: string = '';
  @State gwAgentAvatar: string = '';
  @State gwAgentEmoji: string = '';
  @State gwAgentSoul: string = '';
  // Gateway parallel sessions setting
  @State gwMaxConcurrent: number = 4;

  // Update functionality
  @State updateChecking: boolean = false;
  @State updateDownloading: boolean = false;
  @State updateProgress: number = 0;
  @State latestVersion: string = '';
  @State updateAvailable: boolean = false;

  // Experience Pack
  @State expCount: number = 0;
  @State expSkillsCount: number = 0;
  @State expMemoryCount: number = 0;
  @State expSyncedAt: number = 0;
  @State expLoaded: boolean = false;

  // Module Monitor
  @State moduleStats: ModuleStat[] = [];
  @State showModuleMonitor: boolean = false;
  // Context Awareness
  @State contextAwarenessEnabled: boolean = false;

  private gwListener: ((state: ConnectionState, text: string) => void) | undefined = undefined;
  private langListener: (() => void) | undefined = undefined;
  private identityListener: ((identity: AgentIdentity | undefined) => void) | undefined = undefined;

  aboutToAppear(): void {
    this.load();
    this.loadContextAwareness();
    this.loadGateway();
    this.loadEmail();
    this.loadFeishu();
    this.loadProfiles();
    this.loadExperienceSummary();
    this.loadModuleStats();
    this.lang = I18n.lang;
    this.langListener = () => { this.lang = I18n.lang; };
    I18n.addListener(this.langListener);
    this.gwListener = (state: ConnectionState, text: string) => {
      let wasConnected = this.gwState === ConnectionState.Connected;
      this.gwState = state;
      this.gwStatusText = text;
      // Update individual session states
      this.operatorState = NodeRuntime.getInstance().operatorConnectionState;
      this.nodeState = NodeRuntime.getInstance().nodeConnectionState;
      // Load maxConcurrent when newly connected
      if (!wasConnected && state === ConnectionState.Connected) {
        this.loadMaxConcurrent();
      }
    };
    NodeRuntime.getInstance().addStateListener(this.gwListener);
    // Identity listener for gateway agent info
    this.identityListener = (identity: AgentIdentity | undefined) => {
      if (identity) {
        this.gwAgentName = identity.name;
        this.gwAgentEmoji = identity.emoji;
        // Resolve avatar URL
        let avatarUrl = NodeRuntime.getInstance().resolveAgentAvatarUrl();
        this.gwAgentAvatar = avatarUrl ?? '';
      } else {
        this.gwAgentName = '';
        this.gwAgentAvatar = '';
        this.gwAgentEmoji = '';
        this.gwAgentSoul = '';
      }
    };
    NodeRuntime.getInstance().addIdentityListener(this.identityListener);
    // Sync current state
    this.gwState = NodeRuntime.getInstance().connectionState;
    this.gwStatusText = NodeRuntime.getInstance().statusText;
    this.operatorState = NodeRuntime.getInstance().operatorConnectionState;
    this.nodeState = NodeRuntime.getInstance().nodeConnectionState;
    // Sync current identity if already connected
    let currentIdentity = NodeRuntime.getInstance().agentIdentity;
    if (currentIdentity) {
      this.gwAgentName = currentIdentity.name;
      this.gwAgentEmoji = currentIdentity.emoji;
      let avatarUrl = NodeRuntime.getInstance().resolveAgentAvatarUrl();
      this.gwAgentAvatar = avatarUrl ?? '';
    }
    // Load maxConcurrent if already connected
    if (this.gwState === ConnectionState.Connected) {
      this.loadMaxConcurrent();
    }
  }

  aboutToDisappear(): void {
    if (this.gwListener) {
      NodeRuntime.getInstance().removeStateListener(this.gwListener);
      this.gwListener = undefined;
    }
    if (this.identityListener) {
      NodeRuntime.getInstance().removeIdentityListener(this.identityListener);
      this.identityListener = undefined;
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
      if (this.lang === 'zh') {
        this.SettingsBody()
      } else {
        this.SettingsBody()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  SettingsBody() {
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

            // Parallel sessions setting (only show when connected)
            if (this.gwIsConnected()) {
              Divider().margin({ top: 16, bottom: 12 }).color('#E0E0E0')

              Column({ space: 4 }) {
                Row() {
                  Text(I18n.t('settings.parallelSessions'))
                    .fontSize(14)
                    .fontColor('#1A1A1A')
                    .layoutWeight(1)
                  Text(`${this.gwMaxConcurrent}`)
                    .fontSize(14)
                    .fontColor('#D2691E')
                    .fontWeight(FontWeight.Medium)
                }
                .width('100%')

                Text(I18n.t('settings.parallelSessionsDesc'))
                  .fontSize(11)
                  .fontColor('#FF6B00')
                  .width('100%')

                Slider({
                  value: this.gwMaxConcurrent,
                  min: 1,
                  max: 16,
                  step: 1
                })
                  .width('100%')
                  .blockColor('#D2691E')
                  .trackColor('#E0E0E0')
                  .selectedColor('#D2691E')
                  .onChange((value: number) => {
                    this.gwMaxConcurrent = Math.round(value);
                    this.saveMaxConcurrent();
                  })
              }
              .width('100%')
            }
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
        // In node mode when connected, show gateway bot info (read-only)
        // In standalone mode or when not connected, show editable local settings
        if (this.isNodeModeConnected()) {
          // Gateway bot info (read-only)
          this.SectionTitle(I18n.t('settings.assistant'))
          Column() {
            Column({ space: 8 }) {
              if (this.gwAgentAvatar.length > 0) {
                Image(this.gwAgentAvatar.startsWith('http') || this.gwAgentAvatar.startsWith('data:')
                  ? this.gwAgentAvatar : 'file://' + this.gwAgentAvatar)
                  .width(72)
                  .height(72)
                  .borderRadius(36)
                  .objectFit(ImageFit.Cover)
              } else {
                Text(this.gwAgentEmoji.length > 0 ? this.gwAgentEmoji : this.getGwAgentInitial())
                  .fontSize(this.gwAgentEmoji.length > 0 ? 36 : 28)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Color.White)
                  .textAlign(TextAlign.Center)
                  .width(72)
                  .height(72)
                  .borderRadius(36)
                  .backgroundColor('#4CAF50')
              }
              Text(this.gwAgentName.length > 0 ? this.gwAgentName : 'OpenClaw Bot')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor('#1A1A1A')
                .margin({ top: 4 })
              Row({ space: 4 }) {
                Circle({ width: 8, height: 8 })
                  .fill('#4CAF50')
                Text(I18n.t('chat.online') + ' · ' + I18n.t('chat.gatewayMode'))
                  .fontSize(11)
                  .fontColor('#4CAF50')
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .padding({ top: 8, bottom: 8 })

            Divider().margin({ top: 8, bottom: 14 }).color('#F0F0F0')

            Row() {
              Text(I18n.t('settings.assistantName'))
                .fontSize(14)
                .fontColor('#1A1A1A')
                .layoutWeight(1)
              Text(this.gwAgentName.length > 0 ? this.gwAgentName : 'OpenClaw Bot')
                .fontSize(14)
                .fontColor('#666666')
                .fontWeight(FontWeight.Medium)
            }
            .width('100%')
            .height(40)

          }
          .width('100%')
          .padding(16)
          .margin({ left: 16, right: 16 })
          .backgroundColor(Color.White)
          .borderRadius(12)
        } else if (this.settingsTab === 'operator' || !this.modesInclude('node')) {
          // Local assistant settings (editable) - only in standalone mode
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
        }

        // =============== Tab Bar (only when multiple modes enabled) ===============
        if (this.showTabs()) {
          Row({ space: 0 }) {
            if (this.modesInclude('operator')) {
              Text(I18n.t('settings.tabOperator'))
                .fontSize(14)
                .fontWeight(this.settingsTab === 'operator' ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(this.settingsTab === 'operator' ? '#D2691E' : '#999999')
                .layoutWeight(1)
                .textAlign(TextAlign.Center)
                .padding({ top: 12, bottom: 12 })
                .borderWidth({ bottom: this.settingsTab === 'operator' ? 2 : 0 })
                .borderColor('#D2691E')
                .onClick(() => { this.settingsTab = 'operator'; })
            }
            // Node tab removed - gateway access is now part of standalone/AI助理
            // if (this.modesInclude('node')) {
            //   Text(I18n.t('settings.tabNode'))
            //     ...
            // }
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
          if (this.settingsTab === 'operator' && this.modesInclude('operator')) {
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
        if (this.settingsTab === 'operator' && this.modesInclude('operator')) {
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
              ForEach(['openrouter', 'anthropic', 'openai', 'siliconflow', 'local', 'custom'] as string[], (p: string) => {
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
                .onChange((v: string) => {
                  this.apiKey = v;
                  this.savedKeys[this.provider] = v;  // Sync to savedKeys immediately
                })

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
              .onChange((v: string) => {
                this.model = v;
                this.savedModels[this.provider] = v;  // Sync immediately
              })

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
                    : this.provider === 'siliconflow'
                      ? 'https://api.siliconflow.cn/v1/chat/completions'
                      : this.provider === 'custom'
                        ? 'https://your-api.com/v1/chat/completions'
                        : 'http://localhost:11434/api/chat'
            })
              .height(40)
              .backgroundColor('#F5F5F5')
              .borderRadius(8)
              .margin({ top: 6 })
              .onChange((v: string) => {
                this.baseUrl = v;
                this.savedUrls[this.provider] = v;  // Sync immediately
              })

            // ---- AI Engine Toggle ----
            Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')
            Row() {
              Column({ space: 2 }) {
                Text(I18n.t('settings.aiEngine'))
                  .fontSize(14)
                  .fontColor('#1A1A1A')
                Text(I18n.t('settings.aiEngineDesc'))
                  .fontSize(11)
                  .fontColor('#999999')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Toggle({ type: ToggleType.Switch, isOn: this.aiEngineEnabled })
                .selectedColor('#D2691E')
                .onChange((isOn: boolean) => { this.aiEngineEnabled = isOn; })
            }
            .width('100%')

            // AI Engine config (when enabled)
            if (this.aiEngineEnabled) {
              // Hint: if gateway connected, use gateway models
              if (this.operatorEnabled) {
                Row() {
                  Text('💡')
                    .fontSize(14)
                  Text(I18n.t('settings.aiEngineGatewayHint'))
                    .fontSize(12)
                    .fontColor('#666666')
                    .margin({ left: 6 })
                }
                .width('100%')
                .padding(10)
                .backgroundColor('#FFF8E1')
                .borderRadius(8)
                .margin({ top: 12 })
              }

              // --- ASR ---
              Divider().margin({ top: 12, bottom: 12 }).color('#F0F0F0')
              Text(I18n.t('settings.asrMode'))
                .fontSize(13).fontColor('#1A1A1A').fontWeight(FontWeight.Medium).width('100%')

              Row({ space: 0 }) {
                ForEach(['auto', 'local', 'cloud'], (mode: string) => {
                  Text(mode === 'auto' ? I18n.t('settings.asrModeAuto') :
                    mode === 'local' ? I18n.t('settings.asrModeLocal') : I18n.t('settings.asrModeCloud'))
                    .fontSize(11)
                    .fontColor(this.asrMode === mode ? Color.White : '#666666')
                    .backgroundColor(this.asrMode === mode ? '#D2691E' : '#F0F0F0')
                    .borderRadius(6)
                    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                    .layoutWeight(1).textAlign(TextAlign.Center)
                    .onClick(() => { this.asrMode = mode; })
                })
              }.width('100%').margin({ top: 6 })

              Text(this.asrMode === 'auto' ? I18n.t('settings.asrModeAutoDesc') :
                this.asrMode === 'local' ? I18n.t('settings.asrModeLocalDesc') : I18n.t('settings.asrModeCloudDesc'))
                .fontSize(10).fontColor('#999999').margin({ top: 4 }).width('100%')

              // ASR model (when cloud mode - available even with gateway for non-multimodal models)
              if (this.asrMode === 'auto' || this.asrMode === 'cloud') {
                Text(I18n.t('settings.asrModel'))
                  .fontSize(11).fontColor('#666666').margin({ top: 8 }).width('100%')
                TextInput({ text: this.asrModel, placeholder: I18n.t('settings.asrModelPlaceholder') })
                  .height(32).fontSize(12).backgroundColor('#F5F5F5').borderRadius(6).margin({ top: 4 })
                  .onChange((v: string) => { this.asrModel = v; })
                Text(I18n.t('settings.asrModelHint'))
                  .fontSize(10).fontColor('#999999').margin({ top: 2 }).width('100%')
              }

              // --- Embedding ---
              Divider().margin({ top: 12, bottom: 12 }).color('#F0F0F0')
              Text(I18n.t('settings.embeddingMode'))
                .fontSize(13).fontColor('#1A1A1A').fontWeight(FontWeight.Medium).width('100%')

              Row({ space: 0 }) {
                ForEach(['auto', 'local', 'cloud'], (mode: string) => {
                  Text(mode === 'auto' ? I18n.t('settings.embeddingModeAuto') :
                    mode === 'local' ? I18n.t('settings.embeddingModeLocal') : I18n.t('settings.embeddingModeCloud'))
                    .fontSize(11)
                    .fontColor(this.embeddingMode === mode ? Color.White : '#666666')
                    .backgroundColor(this.embeddingMode === mode ? '#D2691E' : '#F0F0F0')
                    .borderRadius(6)
                    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                    .layoutWeight(1).textAlign(TextAlign.Center)
                    .onClick(() => { this.embeddingMode = mode; })
                })
              }.width('100%').margin({ top: 6 })

              Text(this.embeddingMode === 'auto' ? I18n.t('settings.embeddingModeAutoDesc') :
                this.embeddingMode === 'local' ? I18n.t('settings.embeddingModeLocalDesc') : I18n.t('settings.embeddingModeCloudDesc'))
                .fontSize(10).fontColor('#999999').margin({ top: 4 }).width('100%')

              // --- Intent ---
              Divider().margin({ top: 12, bottom: 12 }).color('#F0F0F0')
              Text(I18n.t('settings.intentMode'))
                .fontSize(13).fontColor('#1A1A1A').fontWeight(FontWeight.Medium).width('100%')

              Row({ space: 0 }) {
                ForEach(['auto', 'local', 'cloud'], (mode: string) => {
                  Text(mode === 'auto' ? I18n.t('settings.intentModeAuto') :
                    mode === 'local' ? I18n.t('settings.intentModeLocal') : I18n.t('settings.intentModeCloud'))
                    .fontSize(11)
                    .fontColor(this.intentMode === mode ? Color.White : '#666666')
                    .backgroundColor(this.intentMode === mode ? '#D2691E' : '#F0F0F0')
                    .borderRadius(6)
                    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                    .layoutWeight(1).textAlign(TextAlign.Center)
                    .onClick(() => { this.intentMode = mode; })
                })
              }.width('100%').margin({ top: 6 })

              Text(this.intentMode === 'auto' ? I18n.t('settings.intentModeAutoDesc') :
                this.intentMode === 'local' ? I18n.t('settings.intentModeLocalDesc') : I18n.t('settings.intentModeCloudDesc'))
                .fontSize(10).fontColor('#999999').margin({ top: 4 }).width('100%')
            }
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
        }

        // =============== Gateway Connection (接入网关) ===============
        if (this.settingsTab === 'operator' || !this.showTabs()) {
          // ---- Gateway Connection ----
          this.SectionTitle(I18n.t('settings.gatewayConnect'))
          Column() {
            Row() {
              Column({ space: 2 }) {
                Text(I18n.t('settings.gatewayConnect'))
                  .fontSize(14)
                  .fontColor('#1A1A1A')
                Text(I18n.t('settings.gatewayConnectDesc'))
                  .fontSize(11)
                  .fontColor('#999999')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Toggle({ type: ToggleType.Switch, isOn: this.operatorEnabled })
                .selectedColor('#D2691E')
                .onChange((isOn: boolean) => {
                  this.operatorEnabled = isOn;
                  if (!isOn) {
                    NodeRuntime.getInstance().disconnectOperator();
                  }
                })
            }
            .width('100%')

            if (this.operatorEnabled) {
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
                  .fill(this.operatorStateColor())
                  .margin({ right: 6 })
                Text(this.operatorStateText())
                  .fontSize(13)
                  .fontColor(this.operatorStateColor())
                  .fontWeight(FontWeight.Medium)
              }
              .width('100%')
              .height(40)

              Button(this.operatorIsConnected() ? I18n.t('settings.disconnect') : I18n.t('settings.connect'))
                .width('100%')
                .height(44)
                .backgroundColor(this.operatorIsConnected() ? '#D32F2F' : '#4CAF50')
                .fontColor(Color.White)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .borderRadius(10)
                .margin({ top: 8 })
                .onClick(() => { this.toggleOperatorConnection(); })
            }
          }
          .width('100%')
          .padding(16)
          .margin({ left: 16, right: 16 })
          .backgroundColor(Color.White)
          .borderRadius(12)

          // ---- Node Access / 节点接入 (separate section) ----
          this.SectionTitle(I18n.t('settings.nodeMode'))
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
                    NodeRuntime.getInstance().disconnectNode();
                  }
                })
            }
            .width('100%')

            // Capabilities (shown when node access enabled)
            if (this.gwEnabled) {
              Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')
              Text(I18n.t('settings.caps'))
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor('#1A1A1A')
                .width('100%')
                .margin({ bottom: 10 })

              this.CapToggle(I18n.t('settings.capLocation'), this.capLocation, (v: boolean) => { this.capLocation = v; })
              this.CapToggle(I18n.t('settings.capCamera'), this.capCamera, (v: boolean) => { this.capCamera = v; })
              this.CapToggle(I18n.t('settings.capCanvas'), this.capCanvas, (v: boolean) => { this.capCanvas = v; })
              this.CapToggle(I18n.t('settings.capScreen'), this.capScreen, (v: boolean) => { this.capScreen = v; })
              this.CapToggle(I18n.t('settings.capNotification'), this.capNotification, (v: boolean) => { this.capNotification = v; })
              this.CapToggle(I18n.t('settings.capMicrophone'), this.capMicrophone, (v: boolean) => { this.capMicrophone = v; })
              this.CapToggle(I18n.t('settings.capSpeaker'), this.capSpeaker, (v: boolean) => { this.capSpeaker = v; })
              // Email capability with inline config
              Row() {
                Column({ space: 2 }) {
                  Text(I18n.t('settings.capEmail'))
                    .fontSize(13)
                    .fontColor('#1A1A1A')
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Toggle({ type: ToggleType.Switch, isOn: this.capEmail })
                  .selectedColor('#D2691E')
                  .onChange((v: boolean) => { this.capEmail = v; })
              }
              .width('100%')
              .height(40)

              // Email config (shown when capEmail enabled)
              if (this.capEmail) {
                Divider().margin({ top: 10, bottom: 10 }).color('#F0F0F0')
                Text(I18n.t('settings.imapHost'))
                  .fontSize(12)
                  .fontColor('#666666')
                  .width('100%')
                TextInput({ text: this.imapHost, placeholder: 'imap.gmail.com' })
                  .height(36)
                  .backgroundColor('#F5F5F5')
                  .borderRadius(6)
                  .fontSize(13)
                  .margin({ top: 4 })
                  .onChange((v: string) => { this.imapHost = v; })

                Row() {
                  Text(I18n.t('settings.imapPort'))
                    .fontSize(12)
                    .fontColor('#666666')
                    .layoutWeight(1)
                  TextInput({ text: this.imapPort, placeholder: '993' })
                    .width(80)
                    .height(36)
                    .backgroundColor('#F5F5F5')
                    .borderRadius(6)
                    .fontSize(13)
                    .type(InputType.Number)
                    .onChange((v: string) => { this.imapPort = v; })
                }
                .width('100%')
                .margin({ top: 8 })

                Text(I18n.t('settings.smtpHost'))
                  .fontSize(12)
                  .fontColor('#666666')
                  .width('100%')
                  .margin({ top: 8 })
                TextInput({ text: this.smtpHost, placeholder: 'smtp.gmail.com' })
                  .height(36)
                  .backgroundColor('#F5F5F5')
                  .borderRadius(6)
                  .fontSize(13)
                  .margin({ top: 4 })
                  .onChange((v: string) => { this.smtpHost = v; })

                Row() {
                  Text(I18n.t('settings.smtpPort'))
                    .fontSize(12)
                    .fontColor('#666666')
                    .layoutWeight(1)
                  TextInput({ text: this.smtpPort, placeholder: '465' })
                    .width(80)
                    .height(36)
                    .backgroundColor('#F5F5F5')
                    .borderRadius(6)
                    .fontSize(13)
                    .type(InputType.Number)
                    .onChange((v: string) => { this.smtpPort = v; })
                }
                .width('100%')
                .margin({ top: 8 })

                Text(I18n.t('settings.imapUser'))
                  .fontSize(12)
                  .fontColor('#666666')
                  .width('100%')
                  .margin({ top: 8 })
                TextInput({ text: this.imapUser, placeholder: 'user@gmail.com' })
                  .height(36)
                  .backgroundColor('#F5F5F5')
                  .borderRadius(6)
                  .fontSize(13)
                  .margin({ top: 4 })
                  .onChange((v: string) => { this.imapUser = v; })

                Text(I18n.t('settings.imapPass'))
                  .fontSize(12)
                  .fontColor('#666666')
                  .width('100%')
                  .margin({ top: 8 })
                TextInput({ text: this.imapPass, placeholder: '••••••••' })
                  .height(36)
                  .backgroundColor('#F5F5F5')
                  .borderRadius(6)
                  .fontSize(13)
                  .type(InputType.Password)
                  .margin({ top: 4 })
                  .onChange((v: string) => { this.imapPass = v; })
              }

              // Node status indicator
              Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')
              Row() {
                Text(I18n.t('settings.status'))
                  .fontSize(14)
                  .fontColor('#1A1A1A')
                  .layoutWeight(1)
                Circle({ width: 10, height: 10 })
                  .fill(this.nodeStateColor())
                  .margin({ right: 6 })
                Text(this.nodeStateText())
                  .fontSize(13)
                  .fontColor(this.nodeStateColor())
                  .fontWeight(FontWeight.Medium)
              }
              .width('100%')
              .height(40)

              // Node connection button
              Button(this.nodeIsConnected() ? I18n.t('settings.disconnect') : I18n.t('settings.connect'))
                .width('100%')
                .height(44)
                .backgroundColor(this.nodeIsConnected() ? '#D32F2F' : '#4CAF50')
                .fontColor(Color.White)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .borderRadius(10)
                .margin({ top: 8 })
                .onClick(() => { this.toggleNodeConnection(); })
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

        // ---- Session Management ----
        this.SectionTitle(I18n.t('settings.sessionManagement'))
        Column() {
          // Parallel Sessions Toggle
          Row() {
            Column({ space: 2 }) {
              Text(I18n.t('settings.parallelSessions'))
                .fontSize(14)
                .fontColor('#1A1A1A')
              Text(I18n.t('settings.parallelSessionsDesc'))
                .fontSize(11)
                .fontColor('#999999')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.parallelSessions })
              .selectedColor('#D2691E')
              .onChange((v: boolean) => {
                this.parallelSessions = v;
                this.saveSessionSettings();
              })
          }
          .width('100%')

          Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')

          // Idle Timeout Slider
          Column({ space: 8 }) {
            Row() {
              Text(I18n.t('settings.idleTimeout'))
                .fontSize(14)
                .fontColor('#1A1A1A')
              Blank()
              Text(`${this.idleTimeoutMinutes} ${I18n.t('settings.minutes')}`)
                .fontSize(14)
                .fontColor('#D2691E')
            }
            .width('100%')

            Text(I18n.t('settings.idleTimeoutDesc'))
              .fontSize(11)
              .fontColor('#999999')
              .width('100%')

            Slider({
              value: this.idleTimeoutMinutes,
              min: 5,
              max: 120,
              step: 5
            })
              .blockColor('#D2691E')
              .trackColor('#E0E0E0')
              .selectedColor('#D2691E')
              .onChange((value: number) => {
                this.idleTimeoutMinutes = value;
                this.saveSessionSettings();
              })
          }
          .width('100%')
        }
        .width('100%')
        .padding(16)
        .margin({ left: 16, right: 16 })
        .backgroundColor(Color.White)
        .borderRadius(12)

        // ---- Voiceprint ----
        this.SectionTitle(I18n.t('settings.voiceprint'))
        Column() {
          Row() {
            Column({ space: 2 }) {
              Text(I18n.t('settings.voiceprint'))
                .fontSize(14)
                .fontColor('#1A1A1A')
              Text(I18n.t('settings.voiceprintDesc'))
                .fontSize(11)
                .fontColor('#999999')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')

          Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')

          VoiceprintManager()
        }
        .width('100%')
        .padding(16)
        .margin({ left: 16, right: 16 })
        .backgroundColor(Color.White)
        .borderRadius(12)

        // =============== Silent Mode ===============
        this.SectionTitle(I18n.t('settings.silentMode'))
        Column() {
          Row() {
            Column({ space: 2 }) {
              Text(I18n.t('settings.silentMode'))
                .fontSize(14)
                .fontColor('#1A1A1A')
              Text(I18n.t('settings.silentModeDesc'))
                .fontSize(11)
                .fontColor('#999999')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Text('\u203A')
              .fontSize(20)
              .fontColor('#CCCCCC')
          }
          .width('100%')
          .onClick(() => {
            router.pushUrl({ url: 'pages/ConversationsRoutePage' });
          })
        }
        .width('100%')
        .padding(16)
        .margin({ left: 16, right: 16 })
        .backgroundColor(Color.White)
        .borderRadius(12)

        // =============== Context Awareness ===============
        this.SectionTitle('情景智能')
        Column() {
          Row() {
            Column({ space: 2 }) {
              Text('情景智能')
                .fontSize(14)
                .fontColor('#1A1A1A')
              Text('传感器+定位持续采集，耗电较高')
                .fontSize(11)
                .fontColor('#999999')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.contextAwarenessEnabled })
              .selectedColor('#007AFF')
              .onChange((isOn: boolean) => {
                this.contextAwarenessEnabled = isOn;
                NodeRuntime.getInstance().setContextAwarenessEnabled(isOn);
              })
          }
          .width('100%')
        }
        .width('100%')
        .padding(16)
        .margin({ left: 16, right: 16 })
        .backgroundColor(Color.White)
        .borderRadius(12)

        // =============== About ===============
        this.SectionTitle(I18n.t('settings.about'))
        Column() {
          this.InfoRow(I18n.t('settings.appName'), 'ClawdBot')
          Divider().margin({ top: 8, bottom: 8 }).color('#F0F0F0')
          this.InfoRow(I18n.t('settings.version'), '2.35.1')
          Divider().margin({ top: 8, bottom: 8 }).color('#F0F0F0')
          this.InfoRow(I18n.t('settings.developer'), 'OpenClaw')
          Divider().margin({ top: 8, bottom: 8 }).color('#F0F0F0')

          // Check for updates button
          Row() {
            Text('检查更新')
              .fontSize(14)
              .fontColor('#1A1A1A')
              .layoutWeight(1)

            if (this.updateChecking) {
              LoadingProgress().width(20).height(20).color('#D2691E')
            } else if (this.updateDownloading) {
              Row({ space: 8 }) {
                Progress({ value: this.updateProgress, total: 100, type: ProgressType.Linear })
                  .width(80)
                  .height(4)
                Text(`${this.updateProgress}%`)
                  .fontSize(12)
                  .fontColor('#999999')
              }
            } else if (this.updateAvailable) {
              Text(`新版本 ${this.latestVersion}`)
                .fontSize(12)
                .fontColor('#D2691E')
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .backgroundColor('#FFF3E0')
                .borderRadius(4)
                .onClick(() => { this.downloadAndInstallUpdate(); })
            } else {
              Text('>')
                .fontSize(14)
                .fontColor('#CCCCCC')
            }
          }
          .width('100%')
          .height(44)
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            if (!this.updateChecking && !this.updateDownloading) {
              this.checkForUpdates();
            }
          })
        }
        .width('100%')
        .padding(16)
        .margin({ left: 16, right: 16 })
        .backgroundColor(Color.White)
        .borderRadius(12)

        // =============== Experience Pack ===============
        this.SectionTitle('经验包')
        Column() {
          // Summary: experience = skills + memory
          this.InfoRow('经验', `${this.expCount} 条`)
          Divider().margin({ top: 8, bottom: 8 }).color('#F0F0F0')
          this.InfoRow('├ 技能', `${this.expSkillsCount} 个`)
          Divider().margin({ top: 8, bottom: 8 }).color('#F0F0F0')
          this.InfoRow('└ 记忆', `${this.expMemoryCount} 条`)
          Divider().margin({ top: 8, bottom: 8 }).color('#F0F0F0')
          this.InfoRow('上次同步', this.expSyncedAt > 0 ? new Date(this.expSyncedAt).toLocaleString() : '从未同步')

          Divider().margin({ top: 14, bottom: 14 }).color('#F0F0F0')

          // Export
          Row() {
            Text('导出经验包')
              .fontSize(14)
              .fontColor('#1A1A1A')
              .layoutWeight(1)
            Text('>')
              .fontSize(14)
              .fontColor('#CCCCCC')
          }
          .width('100%')
          .height(44)
          .alignItems(VerticalAlign.Center)
          .onClick(() => { this.exportExperience(); })

          Divider().margin({ top: 8, bottom: 8 }).color('#F0F0F0')

          // Import
          Row() {
            Text('导入经验包')
              .fontSize(14)
              .fontColor('#1A1A1A')
              .layoutWeight(1)
            Text('>')
              .fontSize(14)
              .fontColor('#CCCCCC')
          }
          .width('100%')
          .height(44)
          .alignItems(VerticalAlign.Center)
          .onClick(() => { this.importExperience(); })

          Divider().margin({ top: 8, bottom: 8 }).color('#F0F0F0')

          // Sync to server
          Row() {
            Text('同步到服务端')
              .fontSize(14)
              .fontColor('#007AFF')
              .layoutWeight(1)
            Text('>')
              .fontSize(14)
              .fontColor('#CCCCCC')
          }
          .width('100%')
          .height(44)
          .alignItems(VerticalAlign.Center)
          .onClick(() => { this.syncExperienceToServer(); })

          Divider().margin({ top: 8, bottom: 8 }).color('#F0F0F0')

          // Pull from server
          Row() {
            Text('从服务端拉取')
              .fontSize(14)
              .fontColor('#007AFF')
              .layoutWeight(1)
            Text('>')
              .fontSize(14)
              .fontColor('#CCCCCC')
          }
          .width('100%')
          .height(44)
          .alignItems(VerticalAlign.Center)
          .onClick(() => { this.pullExperienceFromServer(); })

          Divider().margin({ top: 8, bottom: 8 }).color('#F0F0F0')

          // Clear
          Row() {
            Text('清除经验')
              .fontSize(14)
              .fontColor('#D32F2F')
              .layoutWeight(1)
          }
          .width('100%')
          .height(44)
          .alignItems(VerticalAlign.Center)
          .onClick(() => { this.clearExperience(); })
        }
        .width('100%')
        .padding(16)
        .margin({ left: 16, right: 16 })
        .backgroundColor(Color.White)
        .borderRadius(12)

        // =============== Profiles ===============
        this.SectionTitle(I18n.t('settings.profiles'))
        Column() {
          // Saved profiles list
          if (this.profiles.length === 0) {
            Text(I18n.t('settings.profileEmpty'))
              .fontSize(13)
              .fontColor('#999999')
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 8, bottom: 8 })
          } else {
            ForEach(this.profiles,
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

        // =============== Module Monitor ===============
        this.SectionTitle('模块监控')
        Column() {
          Row() {
            Text('显示模块状态')
              .fontSize(14)
              .fontColor('#1A1A1A')
              .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.showModuleMonitor })
              .onChange((isOn: boolean) => {
                this.showModuleMonitor = isOn;
                if (isOn) {
                  this.loadModuleStats();
                }
              })
          }
          .width('100%')
          .height(44)
          .alignItems(VerticalAlign.Center)

          if (this.showModuleMonitor) {
            Divider().margin({ top: 8, bottom: 8 }).color('#F0F0F0')

            ForEach(this.moduleStats, (stat: ModuleStat) => {
              Column() {
                Row() {
                  Circle({ width: 8, height: 8 })
                    .fill(stat.isActive ? Color.Green : Color.Gray)
                    .margin({ right: 8 })
                  Text(stat.name)
                    .fontSize(14)
                    .fontColor('#1A1A1A')
                    .layoutWeight(1)
                  Text(Monitor.formatRuntime(stat.cumulativeRuntimeMs))
                    .fontSize(12)
                    .fontColor('#666666')
                }
                .width('100%')
                .height(32)
                .alignItems(VerticalAlign.Center)

                Row() {
                  Text(`调用: ${stat.callCount}次`)
                    .fontSize(11)
                    .fontColor('#999999')
                    .margin({ left: 16 })
                    .layoutWeight(1)
                  Text(`最后活跃: ${Monitor.formatLastActive(stat.lastActiveTime)}`)
                    .fontSize(11)
                    .fontColor('#999999')
                }
                .width('100%')
                .height(20)
                .alignItems(VerticalAlign.Center)
              }
            }, (stat: ModuleStat) => stat.name)

            Divider().margin({ top: 8, bottom: 8 }).color('#F0F0F0')
            Row() {
              Text('🔄 刷新状态')
                .fontSize(14)
                .fontColor('#007AFF')
            }
            .width('100%')
            .height(36)
            .alignItems(VerticalAlign.Center)
            .justifyContent(FlexAlign.Center)
            .onClick(() => {
              this.loadModuleStats();
              promptAction.showToast({ message: '已刷新', duration: 800 });
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

        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .margin({ top: 16, bottom: 40 })
      }
      .width('100%')
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
    if (p === 'siliconflow') return Constants.DEFAULT_MODEL_SILICONFLOW;
    if (p === 'custom') return '';
    return 'llama3';
  }

  private providerLabel(p: string): string {
    if (p === 'openrouter') return 'OpenRouter';
    if (p === 'anthropic') return 'Anthropic';
    if (p === 'openai') return 'OpenAI';
    if (p === 'siliconflow') return 'SiliconFlow';
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

  private operatorStateColor(): string {
    if (this.operatorState === ConnectionState.Connected) return '#4CAF50';
    if (this.operatorState === ConnectionState.Connecting) return '#FF9800';
    if (this.operatorState === ConnectionState.Reconnecting) return '#FF9800';
    if (this.operatorState === ConnectionState.Error) return '#D32F2F';
    return '#999999';
  }

  private nodeStateColor(): string {
    if (this.nodeState === ConnectionState.Connected) return '#4CAF50';
    if (this.nodeState === ConnectionState.Connecting) return '#FF9800';
    if (this.nodeState === ConnectionState.Reconnecting) return '#FF9800';
    if (this.nodeState === ConnectionState.Error) return '#D32F2F';
    return '#999999';
  }

  private operatorStateText(): string {
    if (this.operatorState === ConnectionState.Connected) return I18n.t('settings.connected');
    if (this.operatorState === ConnectionState.Connecting) return I18n.t('settings.connecting');
    if (this.operatorState === ConnectionState.Reconnecting) return I18n.t('settings.reconnecting');
    if (this.operatorState === ConnectionState.Error) return I18n.t('settings.connectionError');
    return I18n.t('settings.disconnected');
  }

  private nodeStateText(): string {
    if (this.nodeState === ConnectionState.Connected) return I18n.t('settings.connected');
    if (this.nodeState === ConnectionState.Connecting) return I18n.t('settings.connecting');
    if (this.nodeState === ConnectionState.Reconnecting) {
      // Check if waiting for pairing approval
      if (NodeRuntime.getInstance().isNodePairingPending) {
        return I18n.t('settings.pairingPending');
      }
      return I18n.t('settings.reconnecting');
    }
    if (this.nodeState === ConnectionState.Error) return I18n.t('settings.connectionError');
    return I18n.t('settings.disconnected');
  }

  private gwIsConnected(): boolean {
    return this.gwState !== ConnectionState.Disconnected;
  }

  private operatorIsConnected(): boolean {
    return this.operatorState === ConnectionState.Connected;
  }

  private nodeIsConnected(): boolean {
    return this.nodeState === ConnectionState.Connected;
  }

  private getAssistantInitial(): string {
    if (this.assistantName.length > 0) {
      return this.assistantName.charAt(0).toUpperCase();
    }
    return 'C';
  }

  private getGwAgentInitial(): string {
    if (this.gwAgentName.length > 0) {
      return this.gwAgentName.charAt(0).toUpperCase();
    }
    return 'B';
  }

  private isNodeModeConnected(): boolean {
    // Check if we're in node mode (either single mode or selected tab) and connected to gateway
    let isNodeMode = this.settingsTab === 'node' || (!this.showTabs() && this.modesInclude('node'));
    return isNodeMode && this.gwIsConnected();
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

  /** Legacy method - connects both operator and node */
  private async toggleGateway(): Promise<void> {
    if (this.gwIsConnected()) {
      NodeRuntime.getInstance().disconnect();
      return;
    }
    await this.connectToGateway(true, true);
  }

  /** Connect operator session only (for AI chat) */
  private async toggleOperatorConnection(): Promise<void> {
    if (this.operatorIsConnected()) {
      NodeRuntime.getInstance().disconnectOperator();
      return;
    }
    await this.connectToGateway(true, false);
  }

  /** Connect node session only (for capabilities) */
  private async toggleNodeConnection(): Promise<void> {
    if (this.nodeIsConnected()) {
      NodeRuntime.getInstance().disconnectNode();
      return;
    }
    await this.connectToGateway(false, true);
  }

  /** Helper: connect to gateway with specified sessions */
  private async connectToGateway(connectOperator: boolean, connectNode: boolean): Promise<void> {
    let hostTrimmed = this.gwHost.trim();
    let host = hostTrimmed.endsWith('/') ? hostTrimmed.slice(0, hostTrimmed.lastIndexOf('/')) : hostTrimmed;
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
    if (connectOperator && connectNode) {
      runtime.connect(ctx, endpoint, token, password);
    } else if (connectOperator) {
      runtime.connectOperator(ctx, endpoint, token, password);
    } else if (connectNode) {
      runtime.connectNode(ctx, endpoint, token, password);
    }
  }

  private saveMaxConcurrent(): void {
    if (!this.gwIsConnected()) return;
    // Send config patch to gateway - build JSON manually to avoid ArkTS typing issues
    let paramsJson = `{"agents":{"defaults":{"maxConcurrent":${this.gwMaxConcurrent}}}}`;
    NodeRuntime.getInstance().configPatch(paramsJson).then(() => {
      console.info(`[SettingsPage] maxConcurrent updated to ${this.gwMaxConcurrent}`);
    }).catch((err: Error) => {
      console.error(`[SettingsPage] Failed to update maxConcurrent: ${err.message ?? ''}`);
    });
  }

  private async loadMaxConcurrent(): Promise<void> {
    if (!this.gwIsConnected()) return;
    try {
      let configJson = await NodeRuntime.getInstance().configGet();
      if (configJson && configJson.length > 0) {
        let config = JSON.parse(configJson) as Record<string, Object>;
        let agents = config['agents'] as Record<string, Object> | undefined;
        if (agents) {
          let defaults = agents['defaults'] as Record<string, Object> | undefined;
          if (defaults && typeof defaults['maxConcurrent'] === 'number') {
            this.gwMaxConcurrent = defaults['maxConcurrent'] as number;
            console.info(`[SettingsPage] Loaded maxConcurrent: ${this.gwMaxConcurrent}`);
          }
        }
      }
    } catch (err) {
      console.error(`[SettingsPage] Failed to load maxConcurrent: ${(err as Error).message ?? ''}`);
    }
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
      this.savedModels['siliconflow'] = (await store.get('model_siliconflow', Constants.DEFAULT_MODEL_SILICONFLOW)) as string;
      this.savedModels['local'] = (await store.get('model_local', 'llama3')) as string;
      let orKey = (await store.get('key_openrouter', '')) as string;
      if (orKey.length === 0 && Constants.OPENROUTER_DEFAULT_KEY.length > 0) {
        orKey = Constants.OPENROUTER_DEFAULT_KEY;
      }
      this.savedKeys['openrouter'] = orKey;
      this.savedKeys['anthropic'] = (await store.get('key_anthropic', '')) as string;
      this.savedKeys['openai'] = (await store.get('key_openai', '')) as string;
      this.savedKeys['siliconflow'] = (await store.get('key_siliconflow', '')) as string;
      this.savedKeys['local'] = (await store.get('key_local', '')) as string;
      this.savedKeys['custom'] = (await store.get('key_custom', '')) as string;
      this.savedUrls['openrouter'] = (await store.get('url_openrouter', '')) as string;
      this.savedUrls['anthropic'] = (await store.get('url_anthropic', '')) as string;
      this.savedUrls['openai'] = (await store.get('url_openai', '')) as string;
      this.savedUrls['siliconflow'] = (await store.get('url_siliconflow', '')) as string;
      this.savedUrls['local'] = (await store.get('url_local', '')) as string;
      this.savedUrls['custom'] = (await store.get('url_custom', '')) as string;
      this.savedModels['custom'] = (await store.get('model_custom', '')) as string;
      // Set current values from active provider
      this.model = this.savedModels[this.provider] ?? this.defaultModelFor(this.provider);
      this.apiKey = this.savedKeys[this.provider] ?? '';
      this.baseUrl = this.savedUrls[this.provider] ?? '';
      // AI Engine toggle
      this.aiEngineEnabled = (await store.get('ai_engine_enabled', false)) as boolean;
      // ASR settings
      // Backward compat: migrate asr_enabled boolean to asr_mode string
      let storedAsrMode = (await store.get('asr_mode', '')) as string;
      if (storedAsrMode.length > 0) {
        this.asrMode = storedAsrMode;
      } else {
        let oldEnabled = (await store.get('asr_enabled', false)) as boolean;
        this.asrMode = oldEnabled ? 'cloud' : 'cloud';
      }
      this.asrApiUrl = (await store.get('asr_url', 'https://api.siliconflow.cn/v1/audio/transcriptions')) as string;
      this.asrApiKey = (await store.get('asr_key', '')) as string;
      this.asrModel = (await store.get('asr_model', 'FunAudioLLM/SenseVoiceSmall')) as string;
      // Embedding & Intent modes
      this.embeddingMode = (await store.get('embedding_mode', 'auto')) as string;
      this.embeddingApiKey = (await store.get('embedding_key', '')) as string;
      this.intentMode = (await store.get('intent_mode', 'auto')) as string;
      // Soul
      this.soul = (await store.get('soul', Constants.DEFAULT_SOUL)) as string;
      // Assistant customization
      this.assistantName = (await store.get('assistant_name', '')) as string;
      this.assistantAvatar = (await store.get('assistant_avatar', '')) as string;
    } catch { /* first launch defaults */ }
  }

  private async loadContextAwareness(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let store = await preferences.getPreferences(ctx, 'chat_prefs');
      this.contextAwarenessEnabled = (await store.get('contextAwarenessEnabled', false)) as boolean;
    } catch { /* default false */ }
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
      this.operatorEnabled = (await store.get('operatorEnabled', false)) as boolean;
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
      this.unreadNotification = (await store.get('unreadNotification', true)) as boolean;
      NodeRuntime.getInstance().setUnreadNotificationEnabled(this.unreadNotification);
      this.ttsAutoRead = (await store.get('ttsAutoRead', false)) as boolean;
      this.autoMemoryInject = (await store.get(Constants.KEY_AUTO_MEMORY_INJECT, Constants.DEFAULT_AUTO_MEMORY_INJECT)) as boolean;
      // Session management settings
      this.parallelSessions = (await store.get(Constants.KEY_PARALLEL_SESSIONS, Constants.DEFAULT_PARALLEL_SESSIONS)) as boolean;
      this.idleTimeoutMinutes = (await store.get(Constants.KEY_IDLE_TIMEOUT_MINUTES, Constants.DEFAULT_IDLE_TIMEOUT_MINUTES)) as number;
    } catch { /* first launch defaults */ }
  }

  private async saveSessionSettings(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let store = await preferences.getPreferences(ctx, Constants.PREFS_GATEWAY);
      await store.put(Constants.KEY_PARALLEL_SESSIONS, this.parallelSessions);
      await store.put(Constants.KEY_IDLE_TIMEOUT_MINUTES, this.idleTimeoutMinutes);
      await store.flush();
    } catch { /* ignore */ }
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
      await store.put('model_siliconflow', this.savedModels['siliconflow'] ?? Constants.DEFAULT_MODEL_SILICONFLOW);
      await store.put('model_local', this.savedModels['local'] ?? 'llama3');
      await store.put('model_custom', this.savedModels['custom'] ?? '');
      await store.put('key_openrouter', this.savedKeys['openrouter'] ?? '');
      await store.put('key_anthropic', this.savedKeys['anthropic'] ?? '');
      await store.put('key_openai', this.savedKeys['openai'] ?? '');
      await store.put('key_siliconflow', this.savedKeys['siliconflow'] ?? '');
      await store.put('key_local', this.savedKeys['local'] ?? '');
      await store.put('key_custom', this.savedKeys['custom'] ?? '');
      await store.put('url_openrouter', this.savedUrls['openrouter'] ?? '');
      await store.put('url_anthropic', this.savedUrls['anthropic'] ?? '');
      await store.put('url_openai', this.savedUrls['openai'] ?? '');
      await store.put('url_siliconflow', this.savedUrls['siliconflow'] ?? '');
      await store.put('url_local', this.savedUrls['local'] ?? '');
      await store.put('url_custom', this.savedUrls['custom'] ?? '');
      // AI Engine toggle
      await store.put('ai_engine_enabled', this.aiEngineEnabled);
      // ASR settings
      await store.put('asr_mode', this.asrMode);
      await store.put('asr_url', this.asrApiUrl);
      await store.put('asr_key', this.asrApiKey);
      await store.put('asr_model', this.asrModel);
      // Embedding & Intent modes
      await store.put('embedding_mode', this.embeddingMode);
      await store.put('embedding_key', this.embeddingApiKey);
      await store.put('intent_mode', this.intentMode);
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
      await gwStore.put('operatorEnabled', this.operatorEnabled);
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
      await gwStore.put('unreadNotification', this.unreadNotification);
      await gwStore.put('ttsAutoRead', this.ttsAutoRead);
      await gwStore.put(Constants.KEY_AUTO_MEMORY_INJECT, this.autoMemoryInject);
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
    // Save ALL settings in one profile
    // Operator settings
    this.savedModels[this.provider] = this.model;
    this.savedKeys[this.provider] = this.apiKey;
    this.savedUrls[this.provider] = this.baseUrl;
    data['provider'] = this.provider;
    data['temperature'] = this.temperature;
    data['model'] = this.model;
    data['apiKey'] = this.apiKey;
    data['baseUrl'] = this.baseUrl;
    data['asrMode'] = this.asrMode;
    data['asrApiUrl'] = this.asrApiUrl;
    data['asrApiKey'] = this.asrApiKey;
    data['asrModel'] = this.asrModel;
    data['embeddingApiKey'] = this.embeddingApiKey;
    data['soul'] = this.soul;
    data['assistantName'] = this.assistantName;
    data['assistantAvatar'] = this.assistantAvatar;
    // Gateway/Node settings
    data['gwEnabled'] = this.gwEnabled;
    data['operatorEnabled'] = this.operatorEnabled;
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
    data['unreadNotification'] = this.unreadNotification;
    data['ttsAutoRead'] = this.ttsAutoRead;
    data['autoMemoryInject'] = this.autoMemoryInject;

    let mode = 'all';

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

  private async loadProfile(profile: SettingsProfile): Promise<void> {
    try {
      let data: Record<string, string | number | boolean> = JSON.parse(profile.data) as Record<string, string | number | boolean>;
      let keys = Object.keys(data);
      // Load ALL settings from profile
      // Operator settings
      if (data['provider'] !== undefined) this.provider = data['provider'] as string;
      if (data['temperature'] !== undefined) this.temperature = data['temperature'] as number;
      if (data['model'] !== undefined) this.model = data['model'] as string;
      if (data['apiKey'] !== undefined) this.apiKey = data['apiKey'] as string;
      if (data['baseUrl'] !== undefined) this.baseUrl = data['baseUrl'] as string;
      if (data['asrMode'] !== undefined) this.asrMode = data['asrMode'] as string;
      if (data['asrApiUrl'] !== undefined) this.asrApiUrl = data['asrApiUrl'] as string;
      if (data['asrApiKey'] !== undefined) this.asrApiKey = data['asrApiKey'] as string;
      if (data['asrModel'] !== undefined) this.asrModel = data['asrModel'] as string;
      if (data['embeddingApiKey'] !== undefined) this.embeddingApiKey = data['embeddingApiKey'] as string;
      if (data['soul'] !== undefined) this.soul = data['soul'] as string;
      if (data['assistantName'] !== undefined) this.assistantName = data['assistantName'] as string;
      if (data['assistantAvatar'] !== undefined) this.assistantAvatar = data['assistantAvatar'] as string;
      // Update per-provider maps
      this.savedModels[this.provider] = this.model;
      this.savedKeys[this.provider] = this.apiKey;
      this.savedUrls[this.provider] = this.baseUrl;
      // Gateway/Node settings
      if (data['gwEnabled'] !== undefined) this.gwEnabled = data['gwEnabled'] as boolean;
      if (data['operatorEnabled'] !== undefined) this.operatorEnabled = data['operatorEnabled'] as boolean;
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
      if (data['unreadNotification'] !== undefined) {
        this.unreadNotification = data['unreadNotification'] as boolean;
        NodeRuntime.getInstance().setUnreadNotificationEnabled(this.unreadNotification);
      }
      if (data['ttsAutoRead'] !== undefined) this.ttsAutoRead = data['ttsAutoRead'] as boolean;
      if (data['autoMemoryInject'] !== undefined) this.autoMemoryInject = data['autoMemoryInject'] as boolean;
      // Persist loaded values to preferences so they survive restarts
      await this.save();

      // Auto-connect gateway if enabled in profile
      if (this.gwEnabled) {
        let ctx = getContext(this) as common.UIAbilityContext;
        let nr = NodeRuntime.getInstance();
        nr.disconnect();
        let endpoint: GatewayEndpoint = {
          host: this.gwHost,
          port: parseInt(this.gwPort) || 18788,
          useTls: this.gwUseTls,
        };
        let token = this.gwToken.length > 0 ? this.gwToken : undefined;
        let password = this.gwPassword.length > 0 ? this.gwPassword : undefined;
        nr.connect(ctx, endpoint, token, password, this.operatorEnabled, true);
      }

      promptAction.showToast({ message: `✅ 配置「${profile.name}」已加载并连接`, duration: 2000 });
    } catch (e) {
      promptAction.showToast({ message: `加载失败: ${(e as Error).message ?? String(e)}`, duration: 3000 });
    }
  }

  private async deleteProfile(profile: SettingsProfile): Promise<void> {
    this.profiles = this.profiles.filter((p: SettingsProfile) => p.createdAt !== profile.createdAt || p.name !== profile.name);
    await this.persistProfiles();
    promptAction.showToast({ message: I18n.t('settings.profileDeleted'), duration: 1500 });
  }

  // =============== Update Functionality ===============

  private async checkForUpdates(): Promise<void> {
    this.updateChecking = true;
    this.updateAvailable = false;

    try {
      // Fetch latest release info from GitHub API
      let httpRequest = http.createHttp();
      let response = await httpRequest.request(
        'https://api.github.com/repos/lhj1026/ClawdbotHarmony/releases/latest',
        { method: http.RequestMethod.GET, header: { 'Accept': 'application/vnd.github.v3+json' } }
      );

      if (response.responseCode === 200 && response.result) {
        let data = JSON.parse(response.result as string) as Record<string, Object>;
        let tagName = data['tag_name'] as string; // e.g., "v2.21.12"
        this.latestVersion = tagName.startsWith('v') ? tagName.substring(1) : tagName;

        // Compare with current version
        let currentVersion = '2.21.12';
        if (this.compareVersions(this.latestVersion, currentVersion) > 0) {
          this.updateAvailable = true;
          promptAction.showToast({ message: `发现新版本 ${this.latestVersion}`, duration: 2000 });
        } else {
          promptAction.showToast({ message: '已是最新版本', duration: 1500 });
        }
      }
      httpRequest.destroy();
    } catch (e) {
      console.error(`[SettingsPage] Check update failed: ${(e as Error).message ?? ''}`);
      promptAction.showToast({ message: '检查更新失败', duration: 1500 });
    }

    this.updateChecking = false;
  }

  private compareVersions(v1: string, v2: string): number {
    let parts1 = v1.split('.').map((s: string) => parseInt(s) || 0);
    let parts2 = v2.split('.').map((s: string) => parseInt(s) || 0);
    let maxLen = Math.max(parts1.length, parts2.length);
    for (let i = 0; i < maxLen; i++) {
      let p1 = i < parts1.length ? parts1[i] : 0;
      let p2 = i < parts2.length ? parts2[i] : 0;
      if (p1 > p2) return 1;
      if (p1 < p2) return -1;
    }
    return 0;
  }

  private async downloadAndInstallUpdate(): Promise<void> {
    this.updateDownloading = true;
    this.updateProgress = 0;

    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      // Use cacheDir for temporary downloads
      let cacheDir = ctx.cacheDir;
      let fileName = `ClawdBot-${this.latestVersion}.hap`;
      let hapPath = `${cacheDir}/${fileName}`;

      // Get download URL from GitHub release
      let httpRequest = http.createHttp();
      let response = await httpRequest.request(
        'https://api.github.com/repos/lhj1026/ClawdbotHarmony/releases/latest',
        { method: http.RequestMethod.GET, header: { 'Accept': 'application/vnd.github.v3+json' } }
      );

      let downloadUrl = '';
      if (response.responseCode === 200 && response.result) {
        let data = JSON.parse(response.result as string) as Record<string, Object>;
        let assets = data['assets'] as Object[];
        if (assets && assets.length > 0) {
          let asset = assets[0] as Record<string, Object>;
          downloadUrl = asset['browser_download_url'] as string;
        }
      }
      httpRequest.destroy();

      if (downloadUrl.length === 0) {
        promptAction.showToast({ message: '未找到下载链接', duration: 1500 });
        this.updateDownloading = false;
        return;
      }

      // Delete old file if exists
      try { fileIo.unlinkSync(hapPath); } catch { /* ignore */ }

      // Use system download API for large files
      promptAction.showToast({ message: '开始下载...', duration: 1500 });
      console.info(`[SettingsPage] Downloading from: ${downloadUrl} to ${hapPath}`);

      let downloadConfig: request.DownloadConfig = {
        url: downloadUrl,
        filePath: hapPath,
        enableMetered: true,
        enableRoaming: true,
        title: 'ClawdBot 更新',
        description: `下载版本 ${this.latestVersion}`
      };

      let downloadTask = await request.downloadFile(ctx, downloadConfig);

      downloadTask.on('progress', (receivedSize: number, totalSize: number) => {
        if (totalSize > 0) {
          this.updateProgress = Math.floor(receivedSize * 100 / totalSize);
        }
        console.info(`[SettingsPage] Download progress: ${receivedSize}/${totalSize}`);
      });

      downloadTask.on('complete', () => {
        console.info(`[SettingsPage] Download complete: ${hapPath}`);
        this.updateProgress = 100;
        this.updateDownloading = false;
        promptAction.showToast({ message: '下载完成，正在安装...', duration: 2000 });
        setTimeout(() => {
          this.installHap(hapPath);
        }, 500);
      });

      downloadTask.on('fail', (err: number) => {
        console.error(`[SettingsPage] Download failed with error code: ${err}`);
        this.updateDownloading = false;
        promptAction.showToast({ message: `下载失败 (错误码: ${err})`, duration: 2000 });
      });

    } catch (e) {
      console.error(`[SettingsPage] Download update failed: ${(e as Error).message ?? ''}`);
      promptAction.showToast({ message: `下载失败: ${(e as Error).message ?? ''}`, duration: 2000 });
      this.updateDownloading = false;
    }
  }

  private installHap(hapPath: string): void {
    try {
      console.info(`[SettingsPage] Attempting bm install: ${hapPath}`);
      let result: BmExecResult = execCmd(`bm install -r -p ${hapPath}`) as BmExecResult;
      console.info(`[SettingsPage] bm install result: exitCode=${result.exitCode} stdout=${result.stdout} stderr=${result.stderr}`);

      if (result.exitCode === 0 && result.stdout.indexOf('successfully') >= 0) {
        AlertDialog.show({
          title: '更新成功',
          message: '新版本已安装，请手动重启应用。',
          confirm: { value: '确定', action: () => {} }
        });
        return;
      }

      // bm install failed - try copying to /data/local/tmp/ first
      let tmpPath = `/data/local/tmp/ClawdBot-${this.latestVersion}.hap`;
      execCmd(`cp ${hapPath} ${tmpPath}`);
      let result2: BmExecResult = execCmd(`bm install -r -p ${tmpPath}`) as BmExecResult;
      console.info(`[SettingsPage] bm install (tmp) result: exitCode=${result2.exitCode} stdout=${result2.stdout}`);

      if (result2.exitCode === 0 && result2.stdout.indexOf('successfully') >= 0) {
        execCmd(`rm ${tmpPath}`);
        AlertDialog.show({
          title: '更新成功',
          message: '新版本已安装，请手动重启应用。',
          confirm: { value: '确定', action: () => {} }
        });
        return;
      }

      // Both failed - show manual instructions
      let errMsg: string = result2.stderr.length > 0 ? result2.stderr : result.stderr;
      AlertDialog.show({
        title: '需要手动安装',
        message: `自动安装失败: ${errMsg.substring(0, 100)}\n\nHAP已下载，请连接电脑执行:\nhdc shell bm install -r -p ${hapPath}`,
        confirm: { value: '确定', action: () => {} }
      });
    } catch (e) {
      console.error(`[SettingsPage] Install error: ${(e as Error).message ?? ''}`);
      promptAction.showToast({ message: `安装出错: ${(e as Error).message ?? ''}`, duration: 2000 });
    }
  }

  // ============ Experience Pack ============

  private async loadExperienceSummary(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let storage = ExperienceStorage.getInstance();
      let pack = await storage.load(ctx);
      if (pack) {
        this.expCount = storage.getExperiencesCount();
        this.expSkillsCount = storage.getTotalSkillsCount();
        this.expMemoryCount = storage.getTotalMemoryCount();
        this.expSyncedAt = pack.syncedAt;
        this.expLoaded = true;
      }
    } catch { /* ignore */ }
  }

  private loadModuleStats(): void {
    this.moduleStats = Monitor.getModuleStats();
  }

  private async exportExperience(): Promise<void> {
    try {
      let storage = ExperienceStorage.getInstance();
      let json = storage.exportToJson();
      if (json === '{}') {
        promptAction.showToast({ message: '没有经验数据可导出', duration: 1500 });
        return;
      }
      let ctx = getContext(this) as common.UIAbilityContext;
      let filePath = `${ctx.filesDir}/experience_pack.json`;
      let fd = fileIo.openSync(filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(fd.fd, json);
      fileIo.closeSync(fd.fd);
      promptAction.showToast({ message: `已导出到: experience_pack.json`, duration: 2000 });
    } catch (e) {
      promptAction.showToast({ message: `导出失败: ${(e as Error).message ?? ''}`, duration: 2000 });
    }
  }

  private async importExperience(): Promise<void> {
    try {
      let docPicker = new picker.DocumentViewPicker();
      let result = await docPicker.select({ maxSelectNumber: 1 });
      if (!result || result.length === 0) return;

      let uri = result[0];
      let fd = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      let stat = fileIo.statSync(fd.fd);
      let buf = new ArrayBuffer(stat.size);
      fileIo.readSync(fd.fd, buf);
      fileIo.closeSync(fd.fd);

      let decoder = new util.TextDecoder('utf-8');
      let json = decoder.decodeToString(new Uint8Array(buf));

      let ctx = getContext(this) as common.UIAbilityContext;
      let storage = ExperienceStorage.getInstance();
      let success = await storage.importFromJson(ctx, json);
      if (success) {
        promptAction.showToast({ message: '经验包导入成功', duration: 1500 });
        await this.loadExperienceSummary();
      } else {
        promptAction.showToast({ message: '导入失败: 数据格式无效', duration: 2000 });
      }
    } catch (e) {
      promptAction.showToast({ message: `导入失败: ${(e as Error).message ?? ''}`, duration: 2000 });
    }
  }

  private async clearExperience(): Promise<void> {
    AlertDialog.show({
      title: '确认清除',
      message: '清除所有经验数据？此操作不可恢复。',
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '清除',
        fontColor: '#D32F2F',
        action: async () => {
          try {
            let ctx = getContext(this) as common.UIAbilityContext;
            let storage = ExperienceStorage.getInstance();
            await storage.clear(ctx);
            this.expCount = 0;
            this.expSkillsCount = 0;
            this.expMemoryCount = 0;
            this.expSyncedAt = 0;
            this.expLoaded = false;
            promptAction.showToast({ message: '经验已清除', duration: 1500 });
          } catch (e) {
            promptAction.showToast({ message: `清除失败: ${(e as Error).message ?? ''}`, duration: 2000 });
          }
        }
      }
    });
  }

  private async syncExperienceToServer(): Promise<void> {
    let nr = NodeRuntime.getInstance();
    if (nr.connectionState !== ConnectionState.Connected) {
      promptAction.showToast({ message: '未连接 Gateway，无法同步', duration: 2000 });
      return;
    }
    promptAction.showToast({ message: '正在同步到服务端...', duration: 1500 });
    try {
      await nr.syncExperiencePack();
      await this.loadExperienceSummary();
      promptAction.showToast({ message: '✅ 经验包已推送到服务端', duration: 2000 });
    } catch (e) {
      promptAction.showToast({ message: `同步失败: ${(e as Error).message ?? ''}`, duration: 2000 });
    }
  }

  private async pullExperienceFromServer(): Promise<void> {
    let nr = NodeRuntime.getInstance();
    if (nr.connectionState !== ConnectionState.Connected) {
      promptAction.showToast({ message: '未连接 Gateway，无法拉取', duration: 2000 });
      return;
    }
    promptAction.showToast({ message: '正在从服务端拉取...', duration: 1500 });
    try {
      let result = await nr.pullServerExperienceWithCallback();
      let success = result[0] > 0;
      let count = result[1];
      if (success) {
        await this.loadExperienceSummary();
        promptAction.showToast({ message: `✅ 已拉取 ${count} 条经验`, duration: 2000 });
      } else {
        promptAction.showToast({ message: '拉取超时或失败', duration: 2000 });
      }
    } catch (e) {
      promptAction.showToast({ message: `拉取失败: ${(e as Error).message ?? ''}`, duration: 2000 });
    }
  }
}
