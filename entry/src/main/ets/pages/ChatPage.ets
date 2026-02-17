import { preferences } from '@kit.ArkData';
import { common, abilityAccessCtrl } from '@kit.AbilityKit';
import { MessageBubble } from '../components/MessageBubble';
import { ChatMessage, InlineButton, SettingsData, MemoryItem, CronTask, ChatSession, QueuedMessage } from '../model/Models';
import { SessionService } from '../service/SessionService';
import { SessionDrawer } from '../components/SessionDrawer';
import { AIService, AIResult } from '../service/AIService';
import { MemoryService } from '../service/MemoryService';
import { getEnabledToolSchemas, getSkillSystemPrompt, getDefaultSkills, getToolSchemasForSkills, getSkillSystemPromptForIds } from '../service/SkillData';
import { classifyIntent } from '../service/IntentClassifier';
import { CustomSkillService } from '../service/CustomSkillService';
import { CustomSkillDef } from '../model/Models';
import { Constants } from '../common/Constants';
import { NodeRuntime } from '../service/gateway/NodeRuntime';
import { ConnectionState, GatewayChatEvent, ExecApprovalRequest, AgentIdentity } from '../service/gateway/GatewayModels';
import { NotificationInfo } from '../service/gateway/NotificationCapability';
import { LogService } from '../common/LogService';
import { I18n } from '../common/I18n';
import { ConversationLogger } from '../service/ConversationLogger';
import { promptAction, router } from '@kit.ArkUI';
import { audio } from '@kit.AudioKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { buffer } from '@kit.ArkTS';
import { geoLocationManager } from '@kit.LocationKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { webview } from '@kit.ArkWeb';
import { FeishuBotService } from '../service/FeishuBotService';
import { LocalAsrService } from '../service/LocalAsrService';
import { detectMood, MoodResult } from '../service/MoodDetector';

@Component
export struct ChatPage {
  @State messages: ChatMessage[] = [];
  @State inputText: string = '';
  @State isLoading: boolean = false;
  @State loadingSessionId: string = '';  // tracks which session isLoading belongs to
  @State gwConnected: boolean = false;
  @State @Watch('onLangChange') lang: string = 'zh';
  @State ttsAutoRead: boolean = false;
  @State autoMemoryInject: boolean = Constants.DEFAULT_AUTO_MEMORY_INJECT;
  @State dotPhase: number = 0;
  @State isRecording: boolean = false;
  @State assistantName: string = '';
  @State assistantAvatar: string = '';
  @State gwAgentName: string = '';
  @State gwAgentEmoji: string = '';
  @State gwAgentAvatar: string = '';
  @State gwAgentTheme: string = '';
  @State isTalkMode: boolean = false;
  @State talkStatus: string = '';
  @State previewImagePath: string = '';
  @State showWaveform: boolean = false;
  @State waveBars: number[] = [0, 0, 0, 0, 0, 0, 0];
  @State gwRecordingTimer: number = -1;
  @State pendingImagePath: string = '';   // user-selected image ready to send (single)
  @State pendingImagePaths: string[] = [];  // multiple images ready to send
  @State pendingFileName: string = '';    // user-selected file name
  @State replyingToMessage: ChatMessage | null = null;  // message being replied to
  @State showReplyPreview: boolean = false;  // controls reply preview visibility
  @State currentMood: string = '';  // mood emoji + label displayed in talk mode
  @State highlightMessageId: string = '';  // briefly highlight a message after scroll-to-quote
  @State showSessionDrawer: boolean = false;  // session list drawer visibility
  @State sessions: ChatSession[] = [];  // all sessions
  @State currentSessionId: string = 'default';  // current active session ID
  @State currentSessionTitle: string = '';  // current session title for header display
  @State queuedMessages: QueuedMessage[] = [];  // persisted message queue
  private pendingFileContent: string = '';  // file text content to attach
  private sessionSvc: SessionService = SessionService.getInstance();
  @StorageLink('share_timestamp') @Watch('onShareReceived') shareTimestamp: number = 0;
  private lastConsumedShareTs: number = 0;
  private gwRecordingInterval: number = -1;
  private gwRecordingDuration: number = 0;
  private dotTimer: number = -1;
  private audioCapturer: audio.AudioCapturer | undefined = undefined;
  private asrReading: boolean = false;
  private pcmBuffers: ArrayBuffer[] = [];
  private lastPcmBuffers: ArrayBuffer[] = [];
  private cronTimer: number = -1;
  private talkModeActive: boolean = false;
  private ttsCompletionResolve: (() => void) | undefined = undefined;
  private ttsPlaying: boolean = false;

  private scroller: Scroller = new Scroller();
  private ai: AIService = AIService.getInstance();
  private memSvc: MemoryService = MemoryService.getInstance();
  private log: LogService = LogService.getInstance();
  private gwListener: ((state: ConnectionState, text: string) => void) | undefined = undefined;
  private chatListener: ((event: GatewayChatEvent) => void) | undefined = undefined;
  private notifListener: ((info: NotificationInfo) => void) | undefined = undefined;
  private langListener: (() => void) | undefined = undefined;
  private mediaListener: ((type: string, path: string) => void) | undefined = undefined;
  private invokeListener: ((command: string, params: string, result: string, isError: boolean) => void) | undefined = undefined;
  private recordingListener: ((recording: boolean, durationSec: number) => void) | undefined = undefined;
  private approvalListener: ((req: ExecApprovalRequest) => void) | undefined = undefined;
  private identityListener: ((identity: AgentIdentity | undefined) => void) | undefined = undefined;
  private a2uiListener: ((type: string, content: string) => void) | undefined = undefined;
  private a2uiInjectFn: ((content: string) => void) | undefined = undefined;
  private canvasControllerFn: ((url: string) => void) | undefined = undefined;
  private approvalTimers: Map<string, number> = new Map();
  private feishuConnected: boolean = false;
  private feishuSettings: SettingsData | undefined = undefined;
  private feishuHistory: ChatMessage[] = []; // Separate conversation history for Feishu
  // Track unsolicited agent events (from other channels like WhatsApp)
  private unsolicitedRuns: Map<string, string> = new Map<string, string>(); // runId → msgId
  private unsolicitedTexts: Map<string, string> = new Map<string, string>(); // runId → accumulated text
  // Track cross-session responses (replies for a session different from the current one)
  private crossSessionTexts: Map<string, string> = new Map<string, string>(); // runId → accumulated text
  private crossSessionMsgIds: Map<string, string> = new Map<string, string>(); // runId → assistantMsgId
  private soulText: string = Constants.DEFAULT_SOUL;
  // Track the current gateway chat run
  private gwRunId: string = '';
  private gwAssistantMsgId: string = '';
  private gwChatResolve: (() => void) | undefined = undefined;
  private gwEarlyFinish: boolean = false;
  private gwIdleTimer: number = -1; // auto-finish after no events for N seconds
  private gwReceivedDelta: boolean = false; // whether we got at least one delta with text
  private gwAccumulatedText: string = ''; // accumulated text from delta events
  private idleCheckTimer: number = -1; // timer for auto-closing idle sessions

  aboutToAppear(): void {
    // Mark chat page as visible for unread message notifications
    NodeRuntime.getInstance().setChatPageVisible(true);
    this.initializeSessions();
    this.loadTtsAutoReadSetting();
    this.loadAutoMemoryInjectSetting();
    this.loadAssistantSettings();
    this.gwConnected = NodeRuntime.getInstance().isConnected;
    this.memSvc.setNodeMode(this.gwConnected);
    this.gwListener = (state: ConnectionState, _text: string) => {
      let wasConnected = this.gwConnected;
      this.gwConnected = (state === ConnectionState.Connected);
      this.memSvc.setNodeMode(this.gwConnected);
      // When gateway first connects, sync memories from server
      if (!wasConnected && this.gwConnected) {
        this.syncMemoriesFromServer().catch(() => { /* ignore */ });
      }
    };
    NodeRuntime.getInstance().addStateListener(this.gwListener);
    // Register identity listener for gateway agent identity
    this.identityListener = (identity: AgentIdentity | undefined) => {
      if (identity) {
        this.gwAgentName = identity.name;
        this.gwAgentEmoji = identity.emoji;
        this.gwAgentTheme = identity.theme;
        this.gwAgentAvatar = NodeRuntime.getInstance().resolveAgentAvatarUrl() ?? '';
        this.log.info('ChatPage', `Gateway identity received: name="${identity.name}" emoji="${identity.emoji}" avatar="${identity.avatar}" resolvedAvatar="${this.gwAgentAvatar}"`);
      } else {
        this.gwAgentName = '';
        this.gwAgentEmoji = '';
        this.gwAgentTheme = '';
        this.gwAgentAvatar = '';
      }
    };
    NodeRuntime.getInstance().addIdentityListener(this.identityListener);
    // Hydrate from existing identity if already connected
    let existingIdentity = NodeRuntime.getInstance().agentIdentity;
    if (existingIdentity && this.gwConnected) {
      this.gwAgentName = existingIdentity.name;
      this.gwAgentEmoji = existingIdentity.emoji;
      this.gwAgentTheme = existingIdentity.theme;
      this.gwAgentAvatar = NodeRuntime.getInstance().resolveAgentAvatarUrl() ?? '';
    }
    // Register chat event listener for gateway mode
    this.chatListener = (event: GatewayChatEvent) => {
      this.handleGatewayChatEvent(event);
    };
    NodeRuntime.getInstance().addChatListener(this.chatListener);
    // Register notification listener to display gateway notifications in chat
    this.notifListener = (info: NotificationInfo) => {
      this.handleNotificationInChat(info);
    };
    NodeRuntime.getInstance().addNotificationListener(this.notifListener);
    // Register media listener for audio/photo captured via gateway
    this.mediaListener = (type: string, path: string) => {
      this.handleMediaCaptured(type, path);
    };
    NodeRuntime.getInstance().addMediaListener(this.mediaListener);
    // Register invoke listener to show gateway tool calls in chat
    this.invokeListener = (command: string, params: string, result: string, isError: boolean) => {
      this.handleInvokeInChat(command, params, result, isError);
    };
    NodeRuntime.getInstance().addInvokeListener(this.invokeListener);
    // Register approval listener for exec approval requests
    this.approvalListener = (req: ExecApprovalRequest) => {
      this.handleApprovalRequest(req);
    };
    NodeRuntime.getInstance().addApprovalListener(this.approvalListener);
    // Register A2UI listener for inline rendering in chat
    this.a2uiListener = (type: string, content: string) => {
      this.handleA2UIEvent(type, content);
    };
    NodeRuntime.getInstance().addA2UIListener(this.a2uiListener);
    // Register recording listener for AIService local record_audio tool
    this.recordingListener = (recording: boolean, durationSec: number) => {
      this.handleRecordingState(recording, durationSec);
    };
    this.ai.addRecordingListener(this.recordingListener);
    this.lang = I18n.lang;
    this.langListener = () => { this.lang = I18n.lang; this.loadAssistantSettings(); };
    I18n.addListener(this.langListener);
    // Check for pending share data (cold-start via share intent)
    if (this.shareTimestamp > 0) {
      // Delay slightly to ensure UI is ready
      setTimeout(() => { this.onShareReceived(); }, 300);
    }
    this.startCronTimer();
    this.initFeishuBot();
    this.startIdleSessionCheck();
  }

  aboutToDisappear(): void {
    // Mark chat page as not visible
    NodeRuntime.getInstance().setChatPageVisible(false);
    // Auto-save conversation if there are enough messages
    if (this.messages.length > 2) {
      let msgCopy = this.messages.slice();
      ConversationLogger.getInstance()
        .saveConversation(getContext(this), msgCopy)
        .catch(() => { /* ignore */ });
      // Auto-extract memories from conversation (fire-and-forget)
      this.autoExtractMemoriesFromMessages(msgCopy);
    }
    if (this.gwListener) {
      NodeRuntime.getInstance().removeStateListener(this.gwListener);
      this.gwListener = undefined;
    }
    if (this.chatListener) {
      NodeRuntime.getInstance().removeChatListener(this.chatListener);
      this.chatListener = undefined;
    }
    if (this.notifListener) {
      NodeRuntime.getInstance().removeNotificationListener(this.notifListener);
      this.notifListener = undefined;
    }
    if (this.mediaListener) {
      NodeRuntime.getInstance().removeMediaListener(this.mediaListener);
      this.mediaListener = undefined;
    }
    if (this.invokeListener) {
      NodeRuntime.getInstance().removeInvokeListener(this.invokeListener);
      this.invokeListener = undefined;
    }
    if (this.approvalListener) {
      NodeRuntime.getInstance().removeApprovalListener(this.approvalListener);
      this.approvalListener = undefined;
    }
    if (this.a2uiListener) {
      NodeRuntime.getInstance().removeA2UIListener(this.a2uiListener);
      this.a2uiListener = undefined;
    }
    this.a2uiInjectFn = undefined;
    if (this.identityListener) {
      NodeRuntime.getInstance().removeIdentityListener(this.identityListener);
      this.identityListener = undefined;
    }
    // Clear all approval expiration timers
    this.approvalTimers.forEach((timerId: number) => {
      clearTimeout(timerId);
    });
    this.approvalTimers.clear();
    if (this.recordingListener) {
      this.ai.removeRecordingListener(this.recordingListener);
      this.recordingListener = undefined;
    }
    if (this.langListener) {
      I18n.removeListener(this.langListener);
      this.langListener = undefined;
    }
    this.stopDotAnimation();
    this.asrReading = false;
    this.cleanupAsr();
    this.stopTalkMode();
    // Disconnect feishu bot
    if (this.feishuConnected) {
      FeishuBotService.getInstance().onMessageReceived = undefined;
      FeishuBotService.getInstance().disconnect();
      this.feishuConnected = false;
    }
    if (this.cronTimer !== -1) {
      clearInterval(this.cronTimer);
      this.cronTimer = -1;
    }
    if (this.idleCheckTimer !== -1) {
      clearInterval(this.idleCheckTimer);
      this.idleCheckTimer = -1;
    }
  }

  onLangChange(): void {
    // triggers re-render
  }

  build() {
    Stack() {
    Column() {
      // -- header --
      Row() {
          // Session menu button (hamburger)
          Text('☰')
            .fontSize(22)
            .fontColor('#333333')
            .padding(6)
            .margin({ right: 6 })
            .onClick(() => {
              this.showSessionDrawer = true;
            })
          
          // Normal chat header — avatar
          if (this.gwConnected && this.gwAgentAvatar.length > 0) {
            Image(this.gwAgentAvatar.startsWith('http') || this.gwAgentAvatar.startsWith('data:')
              ? this.gwAgentAvatar : 'file://' + this.gwAgentAvatar)
              .width(34)
              .height(34)
              .borderRadius(17)
              .objectFit(ImageFit.Cover)
              .margin({ right: 10 })
          } else if (this.assistantAvatar.length > 0) {
            Image('file://' + this.assistantAvatar)
              .width(34)
              .height(34)
              .borderRadius(17)
              .objectFit(ImageFit.Cover)
              .margin({ right: 10 })
          } else {
            Text(this.getAssistantInitial())
              .fontSize(this.gwConnected && this.gwAgentEmoji.length > 0 ? 20 : 16)
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
              .textAlign(TextAlign.Center)
              .width(34)
              .height(34)
              .borderRadius(17)
              .backgroundColor('#D2691E')
              .margin({ right: 10 })
          }
          Column() {
            Text(this.currentSessionTitle.length > 0 ? this.currentSessionTitle : I18n.t('session.newChat'))
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor('#1A1A1A')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Row({ space: 6 }) {
              if (this.isLoading && this.loadingSessionId === this.currentSessionId) {
                Text(I18n.t('chat.thinking'))
                  .fontSize(12)
                  .fontColor('#FF9800')
              } else {
                Text(this.getAssistantDisplayName())
                  .fontSize(12)
                  .fontColor('#888888')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              if (this.gwConnected) {
                Row({ space: 3 }) {
                  Circle({ width: 6, height: 6 })
                    .fill('#4CAF50')
                  Text(I18n.t('chat.gatewayMode'))
                    .fontSize(10)
                    .fontColor('#4CAF50')
                    .fontWeight(FontWeight.Medium)
                }
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(8)
                .backgroundColor('#E8F5E9')
                .flexShrink(0)
              }
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .clip(true)

          // New conversation button
          Text('+')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .padding(8)
            .onClick(() => { this.createNewSession(); })

          // TTS auto-read quick toggle
          Text(this.ttsAutoRead ? '\uD83D\uDD0A' : '\uD83D\uDD07')
            .fontSize(20)
            .padding(8)
            .onClick(() => {
              this.ttsAutoRead = !this.ttsAutoRead;
              this.saveTtsAutoReadSetting();
              this.log.info('ChatPage', `TTS auto-read toggled: ${this.ttsAutoRead}`);
              // Immediately stop any in-progress TTS/audio when muting
              if (!this.ttsAutoRead) {
                NodeRuntime.getInstance().stopSpeaker().catch(() => { /* ignore */ });
              }
            })

          // clear button
          Text('\uD83D\uDDD1')
            .fontSize(20)
            .padding(8)
            .onClick(() => { this.clearMessages(); })
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 12 })
      .backgroundColor(Color.White)
      .shadow({ radius: 2, color: '#00000008', offsetY: 1 })

      // -- queued messages banner --
      if (this.queuedMessages.length > 0 && !this.isLoading) {
        Column({ space: 0 }) {
          // Banner header with count and bulk actions
          Row() {
            Text(`\u23F3 ${I18n.t('queue.banner').replace('{0}', this.queuedMessages.length.toString())}`)
              .fontSize(13)
              .fontColor('#E65100')
              .layoutWeight(1)
            Text(I18n.t('queue.resendAll'))
              .fontSize(12)
              .fontColor(Color.White)
              .backgroundColor('#D2691E')
              .borderRadius(12)
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .onClick(() => { this.resendAllQueued(); })
            Text(I18n.t('queue.clearAll'))
              .fontSize(12)
              .fontColor('#999999')
              .margin({ left: 8 })
              .onClick(() => { this.clearAllQueued(); })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 6 })

          // Individual queued items
          ForEach(this.queuedMessages, (q: QueuedMessage) => {
            Row() {
              Column() {
                Text(q.text)
                  .fontSize(13)
                  .fontColor('#333333')
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(q.status === 'failed' ? I18n.t('queue.failed') : I18n.t('queue.pending'))
                  .fontSize(11)
                  .fontColor(q.status === 'failed' ? '#D32F2F' : '#FF9800')
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Text(I18n.t('queue.resend'))
                .fontSize(12)
                .fontColor('#D2691E')
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .borderRadius(10)
                .borderWidth(1)
                .borderColor('#D2691E')
                .onClick(() => { this.resendQueuedItem(q); })
              Text(I18n.t('queue.delete'))
                .fontSize(12)
                .fontColor('#999999')
                .margin({ left: 6 })
                .onClick(() => { this.deleteQueuedItem(q.id); })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 6, bottom: 6 })
          }, (q: QueuedMessage): string => q.id)
        }
        .width('100%')
        .backgroundColor('#FFF8E1')
        .borderRadius(0)
      }

      // -- message list --
      if (this.messages.length === 0) {
        this.EmptyState()
      } else {
        List({ scroller: this.scroller }) {
          ForEach(this.messages, (msg: ChatMessage) => {
            ListItem() {
              MessageBubble({
                message: msg,
                assistantAvatar: this.getEffectiveAvatar(),
                assistantName: this.getAssistantDisplayName(),
                onImageClick: (path: string): void => { this.previewImagePath = path; },
                onButtonClick: (action: string): void => { this.handleButtonAction(action); },
                onA2UIReady: (inject: (content: string) => void): void => { this.a2uiInjectFn = inject; },
                onA2UIAction: (json: string): void => { NodeRuntime.getInstance().sendA2UIAction(json); },
                onCanvasReady: (ctrl: webview.WebviewController): void => { NodeRuntime.getInstance().setInlineCanvasController(ctrl); },
                onCanvasAction: (_json: string): void => { /* future use */ },
                onReply: (message: ChatMessage): void => {
                  this.replyingToMessage = message;
                  this.showReplyPreview = true;
                },
                onNewSession: (message: ChatMessage): void => { this.createNewSession(message); },
                onQuoteClick: (replyToId: string): void => { this.scrollToMessage(replyToId); }
              })
            }
            .backgroundColor(this.highlightMessageId === msg.id ? '#FFF3E0' : Color.Transparent)
            .animation({ duration: 500 })
          }, (msg: ChatMessage): string => msg.id)

          // loading indicator — animated dots while waiting for response (only for current session)
          if (this.isLoading && this.loadingSessionId === this.currentSessionId) {
            ListItem() {
              Row() {
                if (this.getEffectiveAvatar().length > 0) {
                  Image(this.getEffectiveAvatar().startsWith('http') || this.getEffectiveAvatar().startsWith('data:')
                    ? this.getEffectiveAvatar() : 'file://' + this.getEffectiveAvatar())
                    .width(30)
                    .height(30)
                    .borderRadius(15)
                    .objectFit(ImageFit.Cover)
                    .margin({ right: 8 })
                } else {
                  Text(this.getAssistantInitial())
                    .fontSize(13)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(Color.White)
                    .textAlign(TextAlign.Center)
                    .width(30)
                    .height(30)
                    .borderRadius(15)
                    .backgroundColor('#D2691E')
                    .margin({ right: 8 })
                }
                Row({ space: 6 }) {
                  Circle({ width: 8, height: 8 })
                    .fill(this.dotPhase === 0 ? '#D2691E' : '#CCCCCC')
                    .animation({ duration: 300 })
                  Circle({ width: 8, height: 8 })
                    .fill(this.dotPhase === 1 ? '#D2691E' : '#CCCCCC')
                    .animation({ duration: 300 })
                  Circle({ width: 8, height: 8 })
                    .fill(this.dotPhase === 2 ? '#D2691E' : '#CCCCCC')
                    .animation({ duration: 300 })
                }
                .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                .backgroundColor('#F0F0F0')
                .borderRadius(16)
              }
              .padding({ left: 16, right: 20, top: 4, bottom: 4 })
            }
          }
        }
        .layoutWeight(1)
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
      }

      // -- input bar --
      // Reply preview (微信风格 - 显示在输入框上方)
      if (this.showReplyPreview && this.replyingToMessage !== null) {
        Row() {
          // 左侧彩色竖条
          Column()
            .width(3)
            .height(36)
            .backgroundColor(this.replyingToMessage.role === 'user' ? '#007AFF' : '#D2691E')
            .borderRadius(2)
          
          // 引用内容
          Column() {
            Text(this.replyingToMessage.role === 'user' ? I18n.t('chat.you') : this.getAssistantDisplayName())
              .fontSize(12)
              .fontColor(this.replyingToMessage.role === 'user' ? '#007AFF' : '#D2691E')
              .fontWeight(FontWeight.Medium)
            Text(this.replyingToMessage.content)
              .fontSize(13)
              .fontColor('#666666')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .margin({ left: 8 })
          
          // 关闭按钮
          Text('✕')
            .fontSize(18)
            .fontColor('#999999')
            .padding(8)
            .onClick(() => { 
              this.replyingToMessage = null; 
              this.showReplyPreview = false;
            })
        }
        .width('100%')
        .height(52)
        .padding({ left: 12, right: 8 })
        .backgroundColor('#F5F5F5')
        .alignItems(VerticalAlign.Center)
        .borderRadius({ topLeft: 8, topRight: 8 })
      }

      // Attachment preview (image or file)
      if (this.pendingImagePath.length > 0 || this.pendingImagePaths.length > 0 || this.pendingFileName.length > 0) {
        Row() {
          if (this.pendingImagePaths.length > 0) {
            // Multiple images preview
            Row({ space: 6 }) {
              ForEach(this.pendingImagePaths.slice(0, 4), (imgPath: string, idx?: number) => {
                Image(imgPath.startsWith('file://') ? imgPath : 'file://' + imgPath)
                  .width(60)
                  .height(60)
                  .objectFit(ImageFit.Cover)
                  .borderRadius(6)
                  .onClick(() => { this.previewImagePath = imgPath; })
              }, (imgPath: string, idx?: number) => imgPath)
              if (this.pendingImagePaths.length > 4) {
                Text(`+${this.pendingImagePaths.length - 4}`)
                  .fontSize(14)
                  .fontColor('#666666')
              }
              Text('\u2715')
                .fontSize(14)
                .fontColor(Color.White)
                .width(20)
                .height(20)
                .textAlign(TextAlign.Center)
                .borderRadius(10)
                .backgroundColor('rgba(0,0,0,0.5)')
                .onClick(() => { this.pendingImagePaths = []; })
            }
          } else if (this.pendingImagePath.length > 0) {
            Stack({ alignContent: Alignment.TopEnd }) {
              Image(this.pendingImagePath.startsWith('file://') ? this.pendingImagePath : 'file://' + this.pendingImagePath)
                .constraintSize({ maxWidth: 200, maxHeight: 160 })
                .objectFit(ImageFit.Contain)
                .borderRadius(8)
                .onClick(() => { this.previewImagePath = this.pendingImagePath; })
              Text('\u2715')
                .fontSize(14)
                .fontColor(Color.White)
                .width(20)
                .height(20)
                .textAlign(TextAlign.Center)
                .borderRadius(10)
                .backgroundColor('rgba(0,0,0,0.5)')
                .onClick(() => { this.pendingImagePath = ''; })
            }
          }
          if (this.pendingFileName.length > 0) {
            Row({ space: 6 }) {
              Text('\uD83D\uDCC4').fontSize(16)
              Text(this.pendingFileName)
                .fontSize(13)
                .fontColor('#333333')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: 200 })
              Text('\u2715')
                .fontSize(14)
                .fontColor('#999999')
                .onClick(() => { this.pendingFileName = ''; this.pendingFileContent = ''; })
            }
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor('#F0F0F0')
            .borderRadius(8)
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 4 })
        .backgroundColor(Color.White)
      }
      Row({ space: 8 }) {
        // Attachment button (image / file picker)
        Column() {
          Text('\uD83D\uDCCE').fontSize(20)
        }
        .width(36)
        .height(44)
        .justifyContent(FlexAlign.Center)
        .onClick(() => { this.showAttachmentMenu(); })

        // Mic button: tap = toggle Talk Mode (phone call style), long press = single voice input
        Column() {
          Image(this.isTalkMode ? $r('app.media.ic_hangup') : $r('app.media.ic_talk_mode'))
            .width(28)
            .height(28)
            .objectFit(ImageFit.Contain)
        }
        .width(36)
        .height(44)
        .justifyContent(FlexAlign.Center)
        .gesture(
          GestureGroup(GestureMode.Exclusive,
            LongPressGesture({ repeat: false, duration: 500 })
              .onAction(() => {
                if (this.isTalkMode) {
                  this.stopTalkMode();
                  return;
                }
                this.startRecording();
              })
              .onActionEnd(() => {
                if (this.isRecording) {
                  this.stopRecording();
                }
              }),
            TapGesture({ count: 1 })
              .onAction(() => {
                if (this.isTalkMode) {
                  // Hang up: always exit talk mode immediately, regardless of state
                  // Stop TTS if playing
                  if (this.ttsPlaying) {
                    NodeRuntime.getInstance().stopSpeaker().catch(() => { /* ignore */ });
                    this.ttsPlaying = false;
                    if (this.ttsCompletionResolve) {
                      this.ttsCompletionResolve();
                      this.ttsCompletionResolve = undefined;
                    }
                  }
                  this.stopTalkMode();
                  return;
                }
                if (this.isRecording) return;
                this.startTalkMode();
              })
          )
        )

        if (this.gwRecordingTimer >= 0) {
          Row({ space: 8 }) {
            Circle({ width: 10, height: 10 })
              .fill('#FF3B30')
            Text(`${this.lang === 'zh' ? '\u5F55\u97F3\u4E2D' : 'Recording'} ${this.formatTimer(this.gwRecordingTimer)} / ${this.formatTimer(this.gwRecordingDuration)}`)
              .fontSize(14)
              .fontColor('#FF3B30')
              .fontWeight(FontWeight.Medium)
          }
          .layoutWeight(1)
          .height(42)
          .borderRadius(21)
          .backgroundColor('#FFF0F0')
          .padding({ left: 16, right: 16 })
          .justifyContent(FlexAlign.Center)
        } else if (this.showWaveform && this.isTalkMode) {
          Row({ space: 8 }) {
            this.WaveformBar()
            Text(this.talkStatus)
              .fontSize(13)
              .fontColor('#4CAF50')
            if (this.currentMood.length > 0) {
              Text(this.currentMood)
                .fontSize(13)
                .fontColor('#FF9800')
            }
          }
          .layoutWeight(1)
          .height(42)
          .borderRadius(21)
          .backgroundColor('#F0F0F0')
          .padding({ left: 16, right: 16 })
          .justifyContent(FlexAlign.Center)
        } else {
          TextInput({ text: this.inputText,
            placeholder: this.isTalkMode ? this.talkStatus : (this.isRecording ? I18n.t('chat.recording') : this.getInputPlaceholder()) })
            .layoutWeight(1)
            .height(42)
            .borderRadius(21)
            .backgroundColor('#F0F0F0')
            .padding({ left: 16, right: 16 })
            .fontSize(15)
            .onChange((v: string) => { this.inputText = v; })
            .onSubmit(() => { this.send(); })
        }

        Button() {
          Text('\u27A4').fontSize(18).fontColor(Color.White)
        }
        .width(42)
        .height(42)
        .borderRadius(21)
        .backgroundColor((this.inputText.trim().length > 0 || this.pendingImagePath.length > 0 || this.pendingImagePaths.length > 0 || this.pendingFileName.length > 0) ? '#D2691E' : '#CCCCCC')
        .enabled(this.inputText.trim().length > 0 || this.pendingImagePath.length > 0 || this.pendingImagePaths.length > 0 || this.pendingFileName.length > 0)
        .onClick(() => { this.send(); })
      }
      .width('100%')
      .padding(10)
      .backgroundColor(Color.White)
      .shadow({ radius: 4, color: '#00000008', offsetY: -1 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
    .id('appRoot')

    // Full-screen image preview overlay
    if (this.previewImagePath.length > 0) {
      Column() {
        Image(this.previewImagePath.startsWith('file://') ? this.previewImagePath : 'file://' + this.previewImagePath)
          .objectFit(ImageFit.Contain)
          .width('100%')
          .height('100%')
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#000000')
      .onClick(() => {
        this.previewImagePath = '';
      })
    }

    // Session drawer overlay
    if (this.showSessionDrawer) {
      Row() {
        // Semi-transparent backdrop
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#00000066')
          .onClick(() => {
            this.showSessionDrawer = false;
          })
      }
      .width('100%')
      .height('100%')
      .position({ x: 0, y: 0 })

      // Session drawer panel
      Column() {
        SessionDrawer({
          sessions: $sessions,
          currentSessionId: $currentSessionId,
          lang: this.lang,
          onSessionSelect: (sessionId: string) => {
            this.switchToSession(sessionId);
          },
          onSessionCreate: () => {
            this.createNewSession();
          },
          onSessionClose: (sessionId: string) => {
            this.closeSession(sessionId);
          },
          onSessionRename: (sessionId: string, newName: string) => {
            this.renameSession(sessionId, newName);
          },
          onSessionPin: (sessionId: string) => {
            this.togglePinSession(sessionId);
          },
          onSessionClear: (sessionId: string) => {
            this.clearSessionMessages(sessionId);
          },
          onOpenSkills: () => {
            this.showSessionDrawer = false;
            router.pushUrl({ url: 'pages/SkillsRoutePage' });
          },
          onOpenMemory: () => {
            this.showSessionDrawer = false;
            router.pushUrl({ url: 'pages/MemoryRoutePage' });
          },
          onOpenConversations: () => {
            this.showSessionDrawer = false;
            router.pushUrl({ url: 'pages/ConversationsRoutePage' });
          },
          onOpenSettings: () => {
            this.showSessionDrawer = false;
            router.pushUrl({ url: 'pages/SettingsRoutePage' });
          },
          onOpenLogs: () => {
            this.showSessionDrawer = false;
            router.pushUrl({ url: 'pages/LogRoutePage' });
          },
          onOpenAbout: () => {
            this.showSessionDrawer = false;
            router.pushUrl({ url: 'pages/AboutRoutePage' });
          },
          onClose: () => {
            this.showSessionDrawer = false;
          }
        })
      }
      .width('80%')
      .height('100%')
      .position({ x: 0, y: 0 })
      .backgroundColor('#FFFFFF')
      .shadow({ radius: 8, color: '#00000033', offsetX: 4 })
      .transition(TransitionEffect.translate({ x: -300 }).animation({ duration: 200 }))
    }
    } // end Stack
  }

  @Builder
  WaveformBar() {
    Row({ space: 4 }) {
      ForEach(this.waveBars, (level: number, _index: number) => {
        Column()
          .width(4)
          .height(8 + level * 24)
          .borderRadius(2)
          .backgroundColor('#4CAF50')
          .animation({ duration: 150, curve: Curve.EaseInOut })
      })
    }
    .height(40)
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  EmptyState() {
    Column({ space: 16 }) {
      if (this.getEffectiveAvatar().length > 0) {
        Image(this.getEffectiveAvatar().startsWith('http') || this.getEffectiveAvatar().startsWith('data:')
          ? this.getEffectiveAvatar() : 'file://' + this.getEffectiveAvatar())
          .width(88)
          .height(88)
          .borderRadius(44)
          .objectFit(ImageFit.Cover)
      } else {
        Text(this.getAssistantInitial())
          .fontSize(this.gwConnected && this.gwAgentEmoji.length > 0 ? 52 : 44)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .textAlign(TextAlign.Center)
          .width(88)
          .height(88)
          .borderRadius(44)
          .backgroundColor('#D2691E')
      }

      Text(this.getAssistantDisplayName())
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor('#1A1A1A')

      Text(I18n.t('chat.empty.subtitle'))
        .fontSize(14)
        .fontColor('#666666')
        .textAlign(TextAlign.Center)
        .lineHeight(22)

      // quick actions
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
        ForEach(
          [I18n.t('chat.quick.whatCanYouDo'), I18n.t('chat.quick.setReminder'), I18n.t('chat.quick.searchWeb'), I18n.t('chat.quick.smartHome')],
          (s: string) => {
            Text(s)
              .fontSize(13)
              .fontColor('#D2691E')
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
              .borderRadius(16)
              .borderWidth(1)
              .borderColor('#D2691E')
              .margin(4)
              .onClick(() => {
                this.inputText = s;
                this.send();
              })
          },
          (s: string): string => s
        )
      }
      .width('85%')
    }
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  // ============ logic ============

  private getAssistantInitial(): string {
    if (this.gwConnected && this.gwAgentEmoji.length > 0) {
      return this.gwAgentEmoji;
    }
    if (this.gwConnected && this.gwAgentName.length > 0) {
      return this.gwAgentName.charAt(0).toUpperCase();
    }
    if (this.assistantName.length > 0) {
      return this.assistantName.charAt(0).toUpperCase();
    }
    return 'C';
  }

  private getAssistantDisplayName(): string {
    if (this.gwConnected && this.gwAgentName.length > 0) {
      return this.gwAgentName;
    }
    if (this.assistantName.length > 0) {
      return this.assistantName;
    }
    return 'ClawdBot';
  }

  private getInputPlaceholder(): string {
    let name = this.getAssistantDisplayName();
    if (I18n.lang === 'zh') {
      return `向 ${name} 提问...`;
    }
    return `Ask ${name} anything...`;
  }

  private getEffectiveAvatar(): string {
    if (this.gwConnected && this.gwAgentAvatar.length > 0) {
      return this.gwAgentAvatar;
    }
    return this.assistantAvatar;
  }

  /**
   * Auto-extract memories from a conversation using AI.
   * Called automatically when a conversation is saved (fire-and-forget).
   * Builds conversation text from messages, sends to AI for analysis,
   * and saves any extracted memories via MemoryService.
   */
  private autoExtractMemoriesFromMessages(messages: ChatMessage[]): void {
    // Filter to user + assistant text messages, skip tool calls
    let lines: string[] = [];
    for (let msg of messages) {
      if (msg.role === 'user') {
        lines.push(`User: ${msg.content}`);
      } else if (msg.role === 'assistant' && !msg.isToolCall && msg.content.length > 0) {
        lines.push(`Assistant: ${msg.content}`);
      }
    }
    if (lines.length < 2) return; // too short to extract from

    let conversationText = lines.join('\n');
    // Truncate if too long
    if (conversationText.length > 8000) {
      conversationText = conversationText.substring(0, 4000) + '\n...\n' + conversationText.substring(conversationText.length - 4000);
    }

    let ctx: common.UIAbilityContext;
    try {
      ctx = getContext(this) as common.UIAbilityContext;
    } catch { return; }

    this.loadSettings(ctx).then((settings: SettingsData) => {
      let systemPrompt = `You are a memory extraction assistant. Analyze the conversation and extract important facts, preferences, and instructions worth remembering across sessions.

Return ONLY a JSON array of objects with:
- "type": "fact" | "preference" | "instruction"
- "content": the memory text (concise, 1 sentence)

Extract:
- Personal facts: name, birthday, job, family, location, hobbies
- Preferences: likes, dislikes, communication style, favorite things
- Instructions: "always do X", "never do Y", recurring requests

Do NOT extract:
- Trivial or temporary info (weather, one-time queries, greetings)
- Tool call details or errors
- Things the AI said (only extract user-revealed info)

If nothing worth saving, return: []
Respond ONLY with the JSON array.`;

      this.ai.simpleChat(systemPrompt, conversationText, settings).then((result: string) => {
        let jsonMatch = /\[[\s\S]*\]/.exec(result);
        if (!jsonMatch) {
          this.log.info('ChatPage', 'autoExtractMemories: no memories found');
          return;
        }
        let memories = JSON.parse(jsonMatch[0]) as MemoryExtractItem[];
        let addedCount = 0;
        let chain = Promise.resolve();
        for (let mem of memories) {
          if (mem.content && mem.content.length > 0) {
            let memType = mem.type ?? 'fact';
            let content = mem.content;
            chain = chain.then(() => {
              return this.memSvc.addIfNew(ctx, memType, content, 0.8).then((item) => {
                if (item !== null) addedCount++;
              });
            });
          }
        }
        chain.then(() => {
          this.log.info('ChatPage', `autoExtractMemories: AI found ${memories.length}, added ${addedCount} new`);
          if (addedCount > 0) {
            promptAction.showToast({
              message: I18n.t('chat.memoryExtracted').replace('{0}', addedCount.toString()),
              duration: 2000
            });
          }
        });
      }).catch((e: Error) => {
        this.log.warn('ChatPage', `autoExtractMemories failed: ${e.message ?? ''}`);
      });
    }).catch(() => { /* ignore settings load error */ });
  }

  private async loadAssistantSettings(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let store = await preferences.getPreferences(ctx, Constants.PREFS_SETTINGS);
      this.assistantName = (await store.get('assistant_name', '')) as string;
      this.assistantAvatar = (await store.get('assistant_avatar', '')) as string;
    } catch { /* defaults */ }
  }

  // ========== Session Management ==========
  
  private async initializeSessions(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      await this.sessionSvc.initialize(ctx);
      this.sessions = this.sessionSvc.getSessions();
      this.currentSessionId = this.sessionSvc.getCurrentSessionId();
      this.currentSessionTitle = this.getCurrentSessionTitle();
      // Load messages and queue for current session
      await this.loadSessionMessages();
      await this.loadSessionQueue();
      this.log.info('ChatPage', `Sessions initialized: ${this.sessions.length} sessions, current: ${this.currentSessionId}, queue: ${this.queuedMessages.length}`);
    } catch (err) {
      this.log.error('ChatPage', `Failed to initialize sessions: ${err}`);
      // Fallback: load history the old way
      this.loadHistory();
    }
  }

  private async loadSessionMessages(): Promise<void> {
    try {
      this.messages = await this.sessionSvc.loadMessages(this.currentSessionId);
      this.log.info('ChatPage', `Loaded ${this.messages.length} messages for session ${this.currentSessionId}`);
      this.scrollToEnd();
    } catch (err) {
      this.log.error('ChatPage', `Failed to load session messages: ${err}`);
      this.messages = [];
    }
  }

  private async saveSessionMessages(): Promise<void> {
    try {
      await this.sessionSvc.saveMessages(this.currentSessionId, this.messages);
      // Refresh session list to update metadata (lastMessage, messageCount)
      this.sessions = this.sessionSvc.getSessions();
    } catch (err) {
      this.log.error('ChatPage', `Failed to save session messages: ${err}`);
    }
  }

  private async loadSessionQueue(): Promise<void> {
    try {
      let loaded = await this.sessionSvc.loadMessageQueue(this.currentSessionId);
      // Mark any 'sending' items back to 'pending' on reload (app was interrupted)
      for (let item of loaded) {
        if (item.status === 'sending') {
          item.status = 'pending';
        }
      }
      this.queuedMessages = loaded;
      this.log.info('ChatPage', `Loaded ${loaded.length} queued messages for session ${this.currentSessionId}`);
    } catch (err) {
      this.log.error('ChatPage', `Failed to load session queue: ${err}`);
      this.queuedMessages = [];
    }
  }

  private async saveSessionQueue(): Promise<void> {
    try {
      await this.sessionSvc.saveMessageQueue(this.currentSessionId, this.queuedMessages);
    } catch (err) {
      this.log.error('ChatPage', `Failed to save session queue: ${err}`);
    }
  }

  /** Resend all queued messages (resets to pending and starts processing). */
  private async resendAllQueued(): Promise<void> {
    if (this.queuedMessages.length === 0 || this.isLoading) return;
    for (let item of this.queuedMessages) {
      item.status = 'pending';
    }
    this.queuedMessages = [...this.queuedMessages];
    await this.saveSessionQueue();
    await this.processQueue();
  }

  /** Clear all queued messages. */
  private async clearAllQueued(): Promise<void> {
    this.queuedMessages = [];
    await this.saveSessionQueue();
  }

  /** Resend a single queued item — moves it to front and starts processing. */
  private async resendQueuedItem(item: QueuedMessage): Promise<void> {
    if (this.isLoading) return;
    item.status = 'pending';
    // Move to front of queue
    let rest = this.queuedMessages.filter(q => q.id !== item.id);
    this.queuedMessages = [item, ...rest];
    await this.saveSessionQueue();
    await this.processQueue();
  }

  /** Delete a single queued item. */
  private async deleteQueuedItem(itemId: string): Promise<void> {
    this.queuedMessages = this.queuedMessages.filter(q => q.id !== itemId);
    await this.saveSessionQueue();
  }

  private async switchToSession(sessionId: string): Promise<void> {
    if (sessionId === this.currentSessionId) {
      this.showSessionDrawer = false;
      return;
    }

    // Capture old session info before switching
    const oldSessionId = this.currentSessionId;
    const oldMessages = [...this.messages];

    // Save current session first
    await this.saveSessionMessages();
    await this.saveSessionQueue();

    // Switch to new session
    await this.sessionSvc.setCurrentSession(sessionId);
    this.currentSessionId = sessionId;
    this.currentSessionTitle = this.getCurrentSessionTitle();

    // Load new session's messages and queue
    await this.loadSessionMessages();
    await this.loadSessionQueue();

    // Refresh session list and close drawer
    this.sessions = this.sessionSvc.getSessions();
    this.showSessionDrawer = false;

    this.log.info('ChatPage', `Switched to session: ${sessionId}`);

    // Generate title and extract memories for old session in background
    this.tryGenerateTitleOnLeave(oldSessionId, oldMessages);
    this.tryExtractMemoryOnLeave(oldSessionId, oldMessages);
  }

  private async createNewSession(sourceMessage?: ChatMessage): Promise<void> {
    // Capture old session info before switching
    const oldSessionId = this.currentSessionId;
    const oldMessages = [...this.messages];

    // Save current session first
    await this.saveSessionMessages();
    await this.saveSessionQueue();

    // Create new session
    const newSession = await this.sessionSvc.createSession(this.assistantName);

    // Switch to new session
    await this.sessionSvc.setCurrentSession(newSession.id);
    this.currentSessionId = newSession.id;
    this.currentSessionTitle = newSession.title;
    this.messages = [];
    this.queuedMessages = [];

    // If a source message was provided, copy it as the first message in the new session
    if (sourceMessage) {
      const copiedMsg = new ChatMessage(sourceMessage.role, sourceMessage.content);
      copiedMsg.timestamp = sourceMessage.timestamp;
      copiedMsg.imagePath = sourceMessage.imagePath;
      copiedMsg.audioPath = sourceMessage.audioPath;
      copiedMsg.userImagePath = sourceMessage.userImagePath;
      copiedMsg.userImagePaths = sourceMessage.userImagePaths;
      copiedMsg.videoPath = sourceMessage.videoPath;
      copiedMsg.attachmentName = sourceMessage.attachmentName;
      this.messages.push(copiedMsg);
      await this.saveSessionMessages();
    }

    // Refresh session list
    this.sessions = this.sessionSvc.getSessions();
    this.showSessionDrawer = false;

    this.log.info('ChatPage', `Created new session: ${newSession.id}`);

    // Generate title and extract memories for old session in background
    this.tryGenerateTitleOnLeave(oldSessionId, oldMessages);
    this.tryExtractMemoryOnLeave(oldSessionId, oldMessages);
  }

  /** Check if a session needs title generation and trigger it in background. */
  private tryGenerateTitleOnLeave(sessionId: string, messages: ChatMessage[]): void {
    if (messages.length === 0) return;
    const session = this.sessionSvc.getSessions().find(s => s.id === sessionId);
    if (!session) return;
    if (session.title !== '新对话' && session.title !== '默认对话') return;
    this.generateSessionTitle(sessionId, messages);
  }

  /** Generate a session title by summarizing the entire conversation. */
  private async generateSessionTitle(sessionId: string, messages: ChatMessage[]): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let settings = await this.loadSettings(ctx);

      // Build conversation summary from RECENT messages (last 4 messages only)
      let recentMessages = messages.slice(-4);
      let summary = '';
      for (let msg of recentMessages) {
        let role = msg.role === 'user' ? 'Q' : 'A';
        // Clean content: remove markdown, code blocks, file prefixes
        let content = msg.content
          .replace(/```[\s\S]*?```/g, '[代码]')
          .replace(/\[File:.*?\]/g, '')
          .replace(/\n+/g, ' ')
          .trim()
          .substring(0, 100);
        summary += `${role}: ${content}\n`;
      }

      // Only attempt AI title generation when we have a valid API key
      if (settings.apiKey && settings.apiKey.length > 0) {
        const systemPrompt = '为这段对话生成一个简短标题（5-12字）。要求：1.概括最新讨论的具体内容 2.使用关键词而非泛泛描述 3.只输出标题文字';
        const title = await this.ai.simpleChat(systemPrompt, summary, settings);
        // Clean up: remove quotes, punctuation, extra spaces
        const trimmedTitle = title.trim()
          .replace(/^["'「『《]|["'」』》]$/g, '')
          .replace(/[。！？，、；：]/g, '')
          .substring(0, 15);
        if (trimmedTitle.length > 0) {
          await this.sessionSvc.renameSession(sessionId, trimmedTitle);
          this.sessions = this.sessionSvc.getSessions();
          if (sessionId === this.currentSessionId) {
            this.currentSessionTitle = trimmedTitle;
          }
          this.log.info('ChatPage', `AI-generated title for session ${sessionId}: ${trimmedTitle}`);
          return;
        }
      }

      // Fallback: extract a meaningful title from the conversation
      this.log.info('ChatPage', `Using heuristic title for session ${sessionId} (no API key or empty AI result)`);
      await this.applyHeuristicTitle(sessionId, messages);
    } catch (err) {
      this.log.error('ChatPage', `AI title generation failed: ${err}, using heuristic`);
      try {
        await this.applyHeuristicTitle(sessionId, messages);
      } catch { /* ignore */ }
    }
  }

  /** Generate a session title heuristically from conversation messages. */
  private async applyHeuristicTitle(sessionId: string, messages: ChatMessage[]): Promise<void> {
    // Use the last user message for more relevant title
    let userMessages = messages.filter(m => m.role === 'user');
    let lastUserMsg = userMessages.length > 0 ? userMessages[userMessages.length - 1] : null;
    if (!lastUserMsg) return;

    // Clean up user content (remove file/reply prefixes)
    let cleaned = lastUserMsg.content
      .replace(/^\[File:.*?\]\n[\s\S]*?\n\n/g, '')
      .replace(/^\[Replying to:.*?\]\n/g, '')
      .replace(/^\[.*?张.*?图片\]$/g, '')
      .trim();

    if (cleaned.length === 0) return;

    let title = cleaned.substring(0, 15).replace(/\n/g, ' ').trim();
    if (title.length > 0) {
      if (cleaned.length > 15) {
        title += '...';
      }
      await this.sessionSvc.renameSession(sessionId, title);
      this.sessions = this.sessionSvc.getSessions();
      if (sessionId === this.currentSessionId) {
        this.currentSessionTitle = title;
      }
    }
  }

  /**
   * Auto-update session title based on recent conversation.
   * Called after each gateway chat response completes.
   * Uses the most recent user message to update the title dynamically.
   */
  private tryAutoUpdateSessionTitle(): void {
    // Need at least 2 messages to generate a meaningful title
    if (this.messages.length < 2) return;

    const session = this.sessionSvc.getCurrentSession();
    if (!session) return;

    // Find the most recent user message (looking at last 6 messages)
    let recentUserMsg: ChatMessage | undefined;
    const startIdx = Math.max(0, this.messages.length - 6);
    for (let i = this.messages.length - 1; i >= startIdx; i--) {
      if (this.messages[i].role === 'user' && this.messages[i].content.length > 0) {
        recentUserMsg = this.messages[i];
        break;
      }
    }

    if (!recentUserMsg) return;

    // Clean up user content (remove file/reply prefixes)
    let cleaned = recentUserMsg.content
      .replace(/^\[File:.*?\]\n[\s\S]*?\n\n/g, '')
      .replace(/^\[Replying to:.*?\]\n/g, '')
      .replace(/^\[.*?张.*?图片\]$/g, '')
      .trim();

    if (cleaned.length === 0) return;

    // Generate title from recent topic (max 12 chars + ellipsis)
    let newTitle = cleaned.substring(0, 12).replace(/\n/g, ' ').trim();
    if (newTitle.length === 0) return;

    if (cleaned.length > 12) {
      newTitle += '...';
    }

    // Only update if title actually changed
    if (session.title === newTitle) return;

    // Update title asynchronously
    const sessionId = this.currentSessionId;
    this.sessionSvc.renameSession(sessionId, newTitle).then(() => {
      this.sessions = this.sessionSvc.getSessions();
      if (sessionId === this.currentSessionId) {
        this.currentSessionTitle = newTitle;
      }
      this.log.info('ChatPage', `Auto-updated session title: "${newTitle}"`);
    }).catch((err: Error) => {
      this.log.error('ChatPage', `Failed to auto-update title: ${err.message}`);
    });
  }

  /** Extract memorable info from session messages when leaving. */
  private tryExtractMemoryOnLeave(sessionId: string, messages: ChatMessage[]): void {
    // Only extract if there are enough messages
    if (messages.length < 3) return;
    
    // Run extraction in background
    this.extractMemoryFromSession(sessionId, messages);
  }

  /** Extract facts, preferences, and instructions from conversation. */
  private async extractMemoryFromSession(sessionId: string, messages: ChatMessage[]): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let settings = await this.loadSettings(ctx);
      
      // Skip if no API key
      if (!settings.apiKey || settings.apiKey.length === 0) {
        this.log.info('ChatPage', `Skipping memory extraction for ${sessionId}: no API key`);
        return;
      }

      // Build conversation text
      let lines: string[] = [];
      for (let msg of messages) {
        if (msg.role === 'user') {
          lines.push(`User: ${msg.content}`);
        } else if (msg.role === 'assistant' && !msg.isToolCall) {
          lines.push(`Assistant: ${msg.content}`);
        }
      }
      let conversationText = lines.join('\n');
      
      // Skip if too short
      if (conversationText.length < 50) return;
      
      // Truncate if too long
      if (conversationText.length > 4000) {
        conversationText = conversationText.substring(conversationText.length - 4000);
      }

      const systemPrompt = `You are a memory extraction assistant. Analyze the conversation and extract important facts, preferences, and instructions worth remembering across sessions.

Return ONLY a JSON array of objects with:
- "type": "fact" | "preference" | "instruction"
- "content": the memory text (concise, 1 sentence)

If nothing worth remembering, return [].
Respond ONLY with the JSON array.`;

      let result = await this.ai.simpleChat(systemPrompt, conversationText, settings);
      let jsonMatch = /\[[\s\S]*\]/.exec(result);
      if (!jsonMatch) {
        this.log.info('ChatPage', `No memories extracted from session ${sessionId}`);
        return;
      }

      interface MemoryExtractItem { type: string; content: string; }
      let memories = JSON.parse(jsonMatch[0]) as MemoryExtractItem[];
      let addedCount = 0;
      
      for (let mem of memories) {
        if (mem.content && mem.content.length > 0) {
          let memType = mem.type ?? 'fact';
          let item = await this.memSvc.addIfNew(ctx, memType, mem.content, 0.8);
          if (item) {
            addedCount++;
          }
        }
      }

      this.log.info('ChatPage', `Memory extraction for session ${sessionId}: found ${memories.length}, added ${addedCount} new`);
    } catch (err) {
      this.log.warn('ChatPage', `Memory extraction failed for session ${sessionId}: ${(err as Error).message ?? ''}`);
    }
  }

  private async closeSession(sessionId: string): Promise<void> {
    const success = await this.sessionSvc.closeSession(sessionId);
    if (success) {
      // If current session was closed, switch to the new current session
      if (sessionId === this.currentSessionId) {
        this.currentSessionId = this.sessionSvc.getCurrentSessionId();
        this.currentSessionTitle = this.getCurrentSessionTitle();
        await this.loadSessionMessages();
      }
      this.sessions = this.sessionSvc.getSessions();
      promptAction.showToast({ message: I18n.t('session.closed') });
    }
  }

  private async renameSession(sessionId: string, newName: string): Promise<void> {
    await this.sessionSvc.renameSession(sessionId, newName);
    this.sessions = this.sessionSvc.getSessions();
    if (sessionId === this.currentSessionId) {
      this.currentSessionTitle = newName;
    }
  }

  private async togglePinSession(sessionId: string): Promise<void> {
    await this.sessionSvc.togglePinSession(sessionId);
    this.sessions = this.sessionSvc.getSessions();
  }

  private async clearSessionMessages(sessionId: string): Promise<void> {
    await this.sessionSvc.clearMessages(sessionId);
    if (sessionId === this.currentSessionId) {
      this.messages = [];
    }
    this.sessions = this.sessionSvc.getSessions();
  }

  private getCurrentSessionTitle(): string {
    const session = this.sessions.find(s => s.id === this.currentSessionId);
    return session?.title || I18n.t('session.default');
  }

  // ========== End Session Management ==========

  private async send(): Promise<void> {
    let text = this.inputText.trim();
    let hasImage = this.pendingImagePath.length > 0 || this.pendingImagePaths.length > 0;
    let hasAttachment = hasImage || this.pendingFileName.length > 0;
    if (text.length === 0 && !hasAttachment) return;
    this.inputText = '';

    // Capture pending attachments before clearing
    let imagePath = this.pendingImagePath;
    let imagePaths = this.pendingImagePaths.slice(); // copy array
    let fileName = this.pendingFileName;
    let fileContent = this.pendingFileContent;
    this.pendingImagePath = '';
    this.pendingImagePaths = [];
    this.pendingFileName = '';
    this.pendingFileContent = '';

    // Merge single and multi image paths
    let allImagePaths: string[] = [];
    if (imagePaths.length > 0) {
      allImagePaths = imagePaths;
    } else if (imagePath.length > 0) {
      allImagePaths = [imagePath];
    }

    // user message
    let hasImages = allImagePaths.length > 0;
    let defaultText = hasImages
      ? (allImagePaths.length > 1 ? `[${allImagePaths.length} ${I18n.t('chat.sentImage')}]` : I18n.t('chat.sentImage'))
      : fileName;
    let userMsg = new ChatMessage('user', text.length > 0 ? text : defaultText);
    if (allImagePaths.length > 0) {
      userMsg.userImagePath = allImagePaths[0]; // primary image for API
      userMsg.userImagePaths = allImagePaths;   // all images for display
    }
    if (fileName.length > 0) {
      userMsg.attachmentName = fileName;
      if (fileContent.length > 0) {
        let prefix = `[File: ${fileName}]\n${fileContent}\n\n`;
        text = prefix + text;
      }
    }
    // Handle reply
    if (this.replyingToMessage !== null) {
      userMsg.replyToId = this.replyingToMessage.id;
      userMsg.replyToRole = this.replyingToMessage.role;
      // Truncate reply preview
      let previewContent = this.replyingToMessage.content;
      userMsg.replyToContent = previewContent.length > 100 ? previewContent.substring(0, 100) + '...' : previewContent;
      // Prepend reply context to the message text for AI context
      let replyPrefix = `[Replying to: "${userMsg.replyToContent}"]\n`;
      text = replyPrefix + text;
      this.replyingToMessage = null;
      this.showReplyPreview = false;
    }
    this.messages.push(userMsg);
    this.scrollToEnd();

    // Determine the text to send to AI
    let textForAI = text.length > 0 ? text : (hasImages ? I18n.t('chat.describeImage') : '');

    // If AI is busy, queue the message for later processing
    if (this.isLoading) {
      let qItem: QueuedMessage = {
        id: `q_${Date.now()}_${Math.floor(Math.random() * 100000)}`,
        text: textForAI,
        status: 'pending',
        timestamp: Date.now(),
        sessionId: this.currentSessionId
      };
      this.queuedMessages = [...this.queuedMessages, qItem];
      this.saveSessionQueue();
      this.scrollToEnd();
      this.saveHistory();
      return;
    }

    this.isLoading = true;
    this.loadingSessionId = this.currentSessionId;
    this.startDotAnimation();

    // Auto-enrich with location for weather queries
    let enrichedText = await this.enrichWithLocation(textForAI);

    if (this.gwConnected) {
      await this.sendViaGateway(enrichedText);
    } else {
      await this.sendViaLocalAI(enrichedText);
    }

    this.scrollToEnd();
    this.saveHistory();

    // Process queued messages
    await this.processQueue();
  }

  /** Process the next message in the queue after AI finishes responding. */
  private async processQueue(): Promise<void> {
    while (this.queuedMessages.length > 0) {
      let item = this.queuedMessages[0];
      // Mark as sending
      item.status = 'sending';
      this.queuedMessages = [...this.queuedMessages];
      await this.saveSessionQueue();

      this.isLoading = true;
      this.loadingSessionId = this.currentSessionId;
      this.startDotAnimation();

      let enrichedText = await this.enrichWithLocation(item.text);

      try {
        if (this.gwConnected) {
          await this.sendViaGateway(enrichedText);
        } else {
          await this.sendViaLocalAI(enrichedText);
        }
        // Success — remove from queue
        this.queuedMessages = this.queuedMessages.filter(q => q.id !== item.id);
      } catch (err) {
        // Mark as failed and stop processing
        item.status = 'failed';
        this.queuedMessages = [...this.queuedMessages];
        this.log.error('ChatPage', `Queue item failed: ${err}`);
        await this.saveSessionQueue();
        break;
      }

      this.scrollToEnd();
      this.saveHistory();
      await this.saveSessionQueue();
    }
  }


  /** Send message through the gateway operator session (chat.send RPC). */
  private async sendViaGateway(text: string): Promise<void> {
    try {
      this.log.info('ChatPage', `Sending via gateway: ${text.substring(0, 100)}`);

      // Note: In node mode, embedding/memory is handled entirely by the Gateway server.
      // No local memory injection needed here.

      // Mark current session as active (processing)
      this.setSessionActive(this.currentSessionId, true);

      // Reset state flags
      this.gwEarlyFinish = false;
      this.gwReceivedDelta = false;
      this.gwAccumulatedText = '';
      if (this.gwIdleTimer >= 0) {
        clearTimeout(this.gwIdleTimer);
        this.gwIdleTimer = -1;
      }

      // Create placeholder assistant message BEFORE sending RPC
      // to avoid race condition where events arrive before gwRunId is set.
      // The handleGatewayChatEvent will adopt any runId it receives while gwRunId is empty.
      let assistantMsg = new ChatMessage('assistant', '');
      this.gwAssistantMsgId = assistantMsg.id;
      this.gwRunId = ''; // will be set from RPC response or adopted from events
      this.messages.push(assistantMsg);
      this.scrollToEnd();

      let runtime = NodeRuntime.getInstance();
      let runId = await runtime.sendChatMessage(text, this.currentSessionId);
      this.log.info('ChatPage', `chat.send returned runId=${runId}, current gwRunId=${this.gwRunId} session=${this.currentSessionId}`);

      // Only set gwRunId from RPC if events haven't already set it
      if (this.gwRunId.length === 0) {
        this.gwRunId = runId;
        this.log.info('ChatPage', `Set gwRunId from RPC response: ${runId}`);
      } else {
        this.log.info('ChatPage', `gwRunId already adopted from events: ${this.gwRunId} (RPC returned: ${runId})`);
      }

      // Register cross-session assistant message ID for routing if user switches sessions
      let effectiveRunId = this.gwRunId.length > 0 ? this.gwRunId : runId;
      this.crossSessionMsgIds.set(effectiveRunId, this.gwAssistantMsgId);

      // Check if we already received a final/error event while awaiting the RPC
      if (this.gwEarlyFinish) {
        this.log.info('ChatPage', `Early finish detected for runId=${this.gwRunId}`);
        this.gwEarlyFinish = false;
        this.isLoading = false;
        this.loadingSessionId = '';
    this.stopDotAnimation();
        return;
      }

      // Wait for final/error event (up to 120 seconds)
      await this.waitForGatewayChatComplete(this.gwRunId, 120000);

    } catch (e) {
      let errMsg = (e as Error).message ?? String(e);
      this.log.error('ChatPage', `Gateway chat error: ${errMsg}`);
      // Update placeholder or add new error message
      let idx = this.findGwAssistantIndex();
      if (idx >= 0) {
        this.messages[idx].content = `Gateway error: ${errMsg}`;
      } else {
        this.messages.push(new ChatMessage('assistant', `Gateway error: ${errMsg}`));
      }
      this.isLoading = false;
      this.loadingSessionId = '';
    this.stopDotAnimation();
      this.gwRunId = '';
      this.gwAssistantMsgId = '';
      this.gwReceivedDelta = false;
      this.gwAccumulatedText = '';
      if (this.gwIdleTimer >= 0) {
        clearTimeout(this.gwIdleTimer);
        this.gwIdleTimer = -1;
      }
    }
  }

  /** Wait for the gateway chat run to complete (final/error/aborted). */
  private waitForGatewayChatComplete(runId: string, timeoutMs: number): Promise<void> {
    return new Promise<void>((resolve) => {
      let timer = setTimeout(() => {
        this.log.warn('ChatPage', `Gateway chat timeout for runId=${runId}`);
        let idx = this.findGwAssistantIndex();
        if (idx >= 0) {
          let existingText = this.messages[idx].content;
          if (existingText.length === 0 || existingText.length === 0) {
            // No text received at all — show timeout error
            this.messages[idx].content = 'Gateway response timeout';
          } else {
            // We have partial text from deltas — keep it (treat as final)
            this.log.info('ChatPage', `Timeout but have text (${existingText.length} chars), keeping it`);
          }
        }
        this.isLoading = false;
        this.loadingSessionId = '';
    this.stopDotAnimation();
        this.gwRunId = '';
        this.gwAssistantMsgId = '';
        resolve();
      }, timeoutMs);

      // Store resolve + timer so handleGatewayChatEvent can call them
      this.gwChatResolve = () => {
        clearTimeout(timer);
        resolve();
      };
    });
  }

  /** Find the index of the current gateway assistant message. */
  private findGwAssistantIndex(): number {
    let targetId = this.gwAssistantMsgId;
    for (let i = this.messages.length - 1; i >= 0; i--) {
      if (this.messages[i].id === targetId) {
        return i;
      }
    }
    return -1;
  }

  /** Handle A2UI / inline canvas events for inline rendering in chat. */
  private handleA2UIEvent(type: string, content: string): void {
    this.log.info('ChatPage', `A2UI event: type=${type} contentLen=${content.length}`);
    if (type === 'push') {
      // A2UI JSONL push
      let idx = this.findGwAssistantIndex();
      if (idx < 0) {
        let msg = new ChatMessage('assistant', '');
        this.messages.push(msg);
        idx = this.messages.length - 1;
        this.gwAssistantMsgId = msg.id;
      }
      let msg = this.messages[idx];
      msg.a2uiContent = msg.a2uiContent.length > 0 ? msg.a2uiContent + '\n' + content : content;
      if (this.a2uiInjectFn) {
        this.a2uiInjectFn(content);
      }
      this.scrollToEnd();
    } else if (type === 'reset') {
      let idx = this.findGwAssistantIndex();
      if (idx >= 0) {
        this.messages[idx].a2uiContent = '';
      }
      this.a2uiInjectFn = undefined;
    } else if (type === 'canvas.present') {
      // Inline canvas: prepare a slot in the current assistant message
      let idx = this.findGwAssistantIndex();
      if (idx < 0) {
        let msg = new ChatMessage('assistant', '');
        this.messages.push(msg);
        idx = this.messages.length - 1;
        this.gwAssistantMsgId = msg.id;
      }
      // Set canvasUrl to 'about:blank' to trigger WebView creation
      this.messages[idx].canvasUrl = 'about:blank';
      this.canvasControllerFn = undefined;
      this.scrollToEnd();
    } else if (type === 'canvas.navigate') {
      // Inline canvas: update URL
      let idx = this.findGwAssistantIndex();
      if (idx >= 0) {
        this.messages[idx].canvasUrl = content;
      }
    } else if (type === 'canvas.hide') {
      // Inline canvas: keep the rendered content visible (don't remove)
      this.canvasControllerFn = undefined;
    }
  }

  /** Handle incoming gateway chat events (delta / final / error / aborted). */
  private handleGatewayChatEvent(event: GatewayChatEvent): void {
    // Extract text from content blocks (separate consecutive text blocks with blank line)
    let text = '';
    if (event.message && event.message.content) {
      for (let block of event.message.content) {
        if (block.type === 'text' && block.text) {
          if (text.length > 0) {
            text += '\n\n';
          }
          text += block.text;
        }
      }
    }

    this.log.info('ChatPage', `gwChatEvent: state=${event.state} runId=${event.runId} myRunId=${this.gwRunId} msgId=${this.gwAssistantMsgId} session=${event.chatSessionId ?? 'none'} current=${this.currentSessionId} textLen=${text.length} text(80)="${text.substring(0, 80)}"`);

    // Multi-session routing: if the event has a chatSessionId that differs from
    // the current session, route it to the correct background session.
    if (event.chatSessionId && event.chatSessionId.length > 0 && event.chatSessionId !== this.currentSessionId) {
      this.log.info('ChatPage', `Cross-session event: routing to session ${event.chatSessionId} (current: ${this.currentSessionId})`);
      this.handleCrossSessionEvent(event, text);
      return;
    }

    // Accept events if:
    // 1. We have a pending assistant message (gwAssistantMsgId is set)
    // 2. AND either: runId matches, OR we haven't locked to a runId yet, OR
    //    the event carries actual text (agent events may use a different server-generated runId)
    let isWaiting = this.gwAssistantMsgId.length > 0;
    let runIdMatch = this.gwRunId.length === 0 || event.runId === this.gwRunId;

    if (!isWaiting) {
      // Not waiting for a local response — this is an unsolicited event
      // (e.g. AI response to WhatsApp or other channel). Show it in chat.
      if (text.length > 0 && event.state !== 'error') {
        this.log.info('ChatPage', `Unsolicited agent event: runId=${event.runId} state=${event.state} textLen=${text.length}`);
        this.handleUnsolicitedAgentEvent(event, text);
      } else {
        this.log.info('ChatPage', `Ignoring unsolicited event: no text or error state`);
      }
      return;
    }

    if (!runIdMatch) {
      // RunId doesn't match — but if we got an empty final from chat.send's runId,
      // the real response comes via a different server-side runId (agent stream).
      // Accept it if we have no accumulated text yet (the real response hasn't started).
      if (this.gwAccumulatedText.length === 0 && text.length > 0) {
        this.log.info('ChatPage', `Accepting agent event with different runId (no text yet): event.runId=${event.runId} gwRunId=${this.gwRunId}`);
        this.gwRunId = event.runId; // Switch to tracking this runId
        // Register session mapping for the newly adopted runId
        NodeRuntime.getInstance().registerRunSession(event.runId, this.currentSessionId);
      } else if (this.gwAccumulatedText.length === 0 && event.state === 'final') {
        // Empty final for a different runId — might be a lifecycle end, skip it
        this.log.info('ChatPage', `Ignoring empty final from different runId: ${event.runId}`);
        return;
      } else {
        this.log.info('ChatPage', `Ignoring chat event: runId mismatch event=${event.runId} my=${this.gwRunId}`);
        return;
      }
    }

    // If we haven't set gwRunId yet, adopt this event's runId
    if (this.gwRunId.length === 0 && event.runId.length > 0) {
      this.log.info('ChatPage', `Adopting runId from event: ${event.runId}`);
      this.gwRunId = event.runId;
      // Register session mapping for the adopted runId
      NodeRuntime.getInstance().registerRunSession(event.runId, this.currentSessionId);
    }

    if (event.state === 'delta') {
      // Streaming: accumulate text and update the placeholder assistant message
      if (text.length > 0) {
        this.gwAccumulatedText += text;
      }
      let idx = this.findGwAssistantIndex();
      if (idx >= 0 && this.gwAccumulatedText.length > 0) {
        // Mutate the @Observed object directly so @ObjectLink in MessageBubble detects the change
        this.messages[idx].content = this.gwAccumulatedText;
        this.scrollToEnd();
        this.gwReceivedDelta = true;
        this.log.info('ChatPage', `Updated msg idx=${idx} chunkLen=${text.length} totalLen=${this.gwAccumulatedText.length}`);
      } else {
        this.log.warn('ChatPage', `Delta but no update: idx=${idx} chunkLen=${text.length} accLen=${this.gwAccumulatedText.length}`);
      }

      // Reset idle timer: if no new events for 15 seconds after receiving text, treat as final
      if (this.gwIdleTimer >= 0) {
        clearTimeout(this.gwIdleTimer);
      }
      if (this.gwReceivedDelta) {
        this.gwIdleTimer = setTimeout(() => {
          if (this.gwAssistantMsgId.length > 0) {
            this.log.info('ChatPage', 'Idle timeout — treating accumulated text as final');
            this.finishGatewayChat();
          }
        }, 15000);
      }
    } else if (event.state === 'final') {
      // Final message: use the longest text available.
      // The final event may carry the complete accumulated text (from data.text)
      // or just a last delta chunk. Always keep the longer version.
      if (text.length > 0) {
        if (text.length >= this.gwAccumulatedText.length) {
          // Final text is the complete response (or at least as long as accumulated)
          this.gwAccumulatedText = text;
        }
        // If final text is shorter, ignore it — our accumulated deltas are more complete
      }
      let idx = this.findGwAssistantIndex();
      if (idx >= 0) {
        let finalText = this.gwAccumulatedText.length > 0 ? this.gwAccumulatedText : text;
        if (finalText.length > 0) {
          // Mutate the @Observed object directly for proper re-render
          this.messages[idx].content = finalText;
        }
        // If final event has no text and no accumulated text, keep placeholder "..."
      }

      // Update session token usage if available
      if (event.usage) {
        this.updateSessionTokenUsage(event.usage.inputTokens, event.usage.outputTokens);
      }

      this.log.info('ChatPage', `Gateway chat FINAL: chunkLen=${text.length} accLen=${this.gwAccumulatedText.length} text(200)="${this.gwAccumulatedText.substring(0, 200)}"`);
      this.finishGatewayChat();
    } else if (event.state === 'error' || event.state === 'aborted') {
      let errText = event.errorMessage ?? (event.state === 'aborted' ? 'Response aborted' : 'Unknown error');
      let idx = this.findGwAssistantIndex();
      if (idx >= 0) {
        // If we already have text from deltas, keep it; otherwise show error
        if (this.messages[idx].content.length === 0 || this.messages[idx].content.length === 0) {
          this.messages[idx].content = `Gateway: ${errText}`;
        }
      }
      this.log.error('ChatPage', `Gateway chat ${event.state}: ${errText}`);
      this.finishGatewayChat();
    }
  }

  /** Clean up state after a gateway chat run completes. */
  private finishGatewayChat(): void {
    this.log.info('ChatPage', `finishGatewayChat: gwRunId=${this.gwRunId} hadDelta=${this.gwReceivedDelta} accLen=${this.gwAccumulatedText.length}`);

    let accText = this.gwAccumulatedText;

    // If we received an empty final (no accumulated text and no deltas),
    // the real response may arrive via a separate agent event stream with a different runId.
    // Don't clean up yet — wait for agent events to arrive.
    if (accText.length === 0 && !this.gwReceivedDelta) {
      this.log.info('ChatPage', 'Empty final received — waiting for agent events (up to 30s)');
      // Reset gwRunId so we can accept agent events with any runId
      this.gwRunId = '';
      // Set a timeout to eventually clean up if nothing arrives
      if (this.gwIdleTimer >= 0) {
        clearTimeout(this.gwIdleTimer);
      }
      this.gwIdleTimer = setTimeout(() => {
        if (this.gwAssistantMsgId.length > 0) {
          this.log.info('ChatPage', 'Timeout waiting for agent events after empty final');
          let idx = this.findGwAssistantIndex();
          if (idx >= 0 && (this.messages[idx].content.length === 0 || this.messages[idx].content.length === 0)) {
            this.messages[idx].content = '网关正在加紧处理中...';
          }
          this.doCleanupGatewayChat();
        }
      }, 30000);
      // Resolve the wait promise but keep gwAssistantMsgId active
      if (this.gwChatResolve) {
        this.gwChatResolve();
        this.gwChatResolve = undefined;
      } else {
        this.gwEarlyFinish = true;
      }
      return;
    }

    // Check if the response contains an image file path (from camera.snap or screen.capture)
    let imgMatch = /(\/data\/storage[^\s\n"'）》]+\.(?:jpg|jpeg|png))/i.exec(accText);
    if (imgMatch && imgMatch[1]) {
      let imgFilePath = imgMatch[1];
      this.log.info('ChatPage', `Detected image path in gateway response: ${imgFilePath}`);
      let idx = this.findGwAssistantIndex();
      if (idx >= 0) {
        this.messages[idx].imagePath = imgFilePath;
      }
    }

    // Check if the response contains a MEDIA: reference (server-side TTS audio)
    // The text may contain additional text like "MEDIA:/tmp/tts-xxx/voice.mp3\n\n其他文字"
    // Use regex to extract the MEDIA path
    let mediaMatch = /MEDIA:(\/[^\s\n]+\.(?:mp3|m4a|wav|aac|ogg))/i.exec(accText);
    if (mediaMatch && mediaMatch[1]) {
      let mediaPath = `MEDIA:${mediaMatch[1]}`;
      // Extract remaining text (anything after the MEDIA path)
      let remainingText = accText.replace(mediaMatch[0], '').trim();
      this.log.info('ChatPage', `Detected MEDIA audio: path=${mediaPath} remaining="${remainingText.substring(0, 100)}"`);
      this.handleMediaPlayback(mediaPath, remainingText);
    } else {
      // Auto-extract memory from both user text and assistant's response in gateway mode
      if (accText.length > 0) {
        this.autoExtractMemoryFromGatewayChat(accText);
      }
      // Auto-read the response aloud if TTS auto-read is enabled
      if (accText.length > 0) {
        this.autoReadAloud(accText);
      }
    }

    // Auto-update session title based on recent conversation
    this.tryAutoUpdateSessionTitle();

    // Fetch token usage from Gateway (async, don't block cleanup)
    this.fetchAndUpdateTokenUsage();

    this.doCleanupGatewayChat();
  }

  /** Fetch token usage from Gateway and update current session */
  private async fetchAndUpdateTokenUsage(): Promise<void> {
    try {
      let runtime = NodeRuntime.getInstance();
      let usage = await runtime.getSessionTokenUsage(this.currentSessionId);
      if (usage && (usage.inputTokens > 0 || usage.outputTokens > 0)) {
        // Replace (not add) because Gateway returns cumulative totals
        let sessionIdx = this.sessions.findIndex(s => s.id === this.currentSessionId);
        if (sessionIdx >= 0) {
          let session = this.sessions[sessionIdx];
          session.inputTokens = usage.inputTokens;
          session.outputTokens = usage.outputTokens;
          session.totalTokens = usage.totalTokens;
          this.log.info('ChatPage', `Token usage from Gateway: session=${this.currentSessionId} input=${usage.inputTokens} output=${usage.outputTokens} total=${usage.totalTokens}`);
          this.sessionSvc.updateSession(session);
        }
      }
    } catch (err) {
      this.log.warn('ChatPage', `Failed to fetch token usage: ${(err as Error).message ?? ''}`);
    }
  }

  /** Update current session's token usage (called from agent event) */
  private updateSessionTokenUsage(inputTokens: number, outputTokens: number): void {
    let sessionIdx = this.sessions.findIndex(s => s.id === this.currentSessionId);
    if (sessionIdx >= 0) {
      let session = this.sessions[sessionIdx];
      session.inputTokens += inputTokens;
      session.outputTokens += outputTokens;
      session.totalTokens = session.inputTokens + session.outputTokens;
      this.log.info('ChatPage', `Token usage updated: session=${this.currentSessionId} input=${session.inputTokens} output=${session.outputTokens} total=${session.totalTokens}`);
      // Persist session data
      this.sessionSvc.updateSession(session);
    }
  }

  /** Set session active state (shows pulsing indicator when processing) */
  private setSessionActive(sessionId: string, active: boolean): void {
    let sessionIdx = this.sessions.findIndex(s => s.id === sessionId);
    if (sessionIdx >= 0) {
      this.sessions[sessionIdx].isActive = active;
    }
  }

  /** Actually reset all gateway chat state */
  private doCleanupGatewayChat(): void {
    // Clean up cross-session tracking for this run
    if (this.gwRunId.length > 0) {
      this.crossSessionMsgIds.delete(this.gwRunId);
      this.crossSessionTexts.delete(this.gwRunId);
    }
    // Mark session as inactive
    this.setSessionActive(this.currentSessionId, false);
    this.isLoading = false;
    this.loadingSessionId = '';
    this.stopDotAnimation();
    this.gwRunId = '';
    this.gwAssistantMsgId = '';
    this.gwReceivedDelta = false;
    this.gwAccumulatedText = '';
    if (this.gwIdleTimer >= 0) {
      clearTimeout(this.gwIdleTimer);
      this.gwIdleTimer = -1;
    }
    if (this.gwChatResolve) {
      this.gwChatResolve();
      this.gwChatResolve = undefined;
    } else {
      this.gwEarlyFinish = true;
    }
    this.saveHistory();
  }

  /**
   * Handle unsolicited agent events (from WhatsApp/other channels).
   * Creates or updates an assistant message for the remote conversation.
   */
  private handleUnsolicitedAgentEvent(event: GatewayChatEvent, text: string): void {
    let runId = event.runId;
    if (runId.length === 0) {
      runId = `unsolicited_${Date.now()}`;
    }

    let existingMsgId = this.unsolicitedRuns.get(runId);

    if (event.state === 'delta') {
      if (existingMsgId) {
        // Accumulate text for existing message
        let accText = (this.unsolicitedTexts.get(runId) ?? '') + text;
        this.unsolicitedTexts.set(runId, accText);
        // Update the message
        for (let i = this.messages.length - 1; i >= 0; i--) {
          if (this.messages[i].id === existingMsgId) {
            this.messages[i].content = '\uD83C\uDF10 ' + accText;  // 🌐 prefix for remote events
            break;
          }
        }
      } else {
        // First delta for this runId — create new message
        let msg = new ChatMessage('assistant', '\uD83C\uDF10 ' + text);
        this.unsolicitedRuns.set(runId, msg.id);
        this.unsolicitedTexts.set(runId, text);
        this.messages.push(msg);
      }
      this.scrollToEnd();
    } else if (event.state === 'final') {
      if (existingMsgId) {
        // Final with text — update existing message
        let accText = this.unsolicitedTexts.get(runId) ?? '';
        if (text.length >= accText.length) {
          accText = text; // final has complete text
        }
        // If final text is shorter, keep accumulated — our deltas are more complete
        for (let i = this.messages.length - 1; i >= 0; i--) {
          if (this.messages[i].id === existingMsgId) {
            this.messages[i].content = '\uD83C\uDF10 ' + accText;
            break;
          }
        }
      } else if (text.length > 0) {
        // Single final event with text — create message directly
        let msg = new ChatMessage('assistant', '\uD83C\uDF10 ' + text);
        this.messages.push(msg);
      }
      // Cleanup tracking for this runId
      this.unsolicitedRuns.delete(runId);
      this.unsolicitedTexts.delete(runId);
      this.scrollToEnd();
      this.saveHistory();
    }
  }

  /**
   * Handle a gateway chat event that belongs to a different session (cross-session routing).
   * Accumulates text and saves to the correct session's storage in background.
   */
  private handleCrossSessionEvent(event: GatewayChatEvent, text: string): void {
    let targetSessionId = event.chatSessionId!;
    let runId = event.runId;

    if (event.state === 'delta') {
      // Accumulate text
      let acc = (this.crossSessionTexts.get(runId) ?? '') + text;
      this.crossSessionTexts.set(runId, acc);
      this.log.info('ChatPage', `Cross-session delta: runId=${runId} session=${targetSessionId} accLen=${acc.length}`);
    } else if (event.state === 'final') {
      // Use final text or accumulated deltas (whichever is longer)
      let accText = this.crossSessionTexts.get(runId) ?? '';
      if (text.length >= accText.length) {
        accText = text;
      }
      this.log.info('ChatPage', `Cross-session final: runId=${runId} session=${targetSessionId} textLen=${accText.length}`);

      // Save the response to the target session in the background
      if (accText.length > 0) {
        this.saveCrossSessionResponse(targetSessionId, runId, accText);
      }

      // Cleanup tracking
      this.crossSessionTexts.delete(runId);
      this.crossSessionMsgIds.delete(runId);

      // If this was our active gateway chat (user switched sessions mid-response), clean up state
      if (this.gwAssistantMsgId.length > 0 && this.gwRunId === runId) {
        this.doCleanupGatewayChat();
      }
    } else if (event.state === 'error' || event.state === 'aborted') {
      let errText = event.errorMessage ?? event.state;
      let accText = this.crossSessionTexts.get(runId) ?? '';
      // If we have accumulated text, save it; otherwise save error
      let finalText = accText.length > 0 ? accText : `Gateway: ${errText}`;
      this.saveCrossSessionResponse(targetSessionId, runId, finalText);

      // Cleanup
      this.crossSessionTexts.delete(runId);
      this.crossSessionMsgIds.delete(runId);

      if (this.gwAssistantMsgId.length > 0 && this.gwRunId === runId) {
        this.doCleanupGatewayChat();
      }
    }
  }

  /**
   * Save a cross-session response to the correct session's message store.
   * Loads that session's messages, appends the assistant response, and saves.
   */
  private async saveCrossSessionResponse(sessionId: string, runId: string, text: string): Promise<void> {
    try {
      // Load the target session's messages
      let messages = await this.sessionSvc.loadMessages(sessionId);

      // Find the existing placeholder message (created when we sent the request)
      let msgId = this.crossSessionMsgIds.get(runId);
      let found = false;
      if (msgId) {
        for (let i = messages.length - 1; i >= 0; i--) {
          if (messages[i].id === msgId) {
            messages[i].content = text;
            found = true;
            break;
          }
        }
      }
      // If no placeholder found, check for the last empty assistant message
      if (!found) {
        for (let i = messages.length - 1; i >= 0; i--) {
          if (messages[i].role === 'assistant' && messages[i].content.length === 0) {
            messages[i].content = text;
            found = true;
            break;
          }
        }
      }
      // If still not found, append a new assistant message
      if (!found) {
        let msg = new ChatMessage('assistant', text);
        messages.push(msg);
      }

      // Save back to session storage
      await this.sessionSvc.saveMessages(sessionId, messages);
      this.sessions = this.sessionSvc.getSessions();
      this.log.info('ChatPage', `Cross-session response saved: session=${sessionId} textLen=${text.length}`);
    } catch (err) {
      this.log.error('ChatPage', `Failed to save cross-session response: ${err}`);
    }
  }

  /**
   * Handle a MEDIA: reference from gateway response.
   * Downloads the audio from the gateway server and plays it.
   * Updates the chat message to show a friendly audio indicator.
   */
  private handleMediaPlayback(mediaPath: string, remainingText: string): void {
    let runtime = NodeRuntime.getInstance();

    // Find the assistant message and update its display text
    let idx = this.findGwAssistantIndex();
    let prefix = remainingText.length > 0 ? remainingText + '\n' : '';
    if (idx >= 0) {
      this.messages[idx].content = prefix + '\uD83D\uDD0A ' + I18n.t('chat.playingAudio');  // 🔊 正在播放音频...
    }

    // Play the audio from gateway URL (fire-and-forget)
    runtime.playMediaUrl(mediaPath).then(() => {
      this.log.info('ChatPage', 'Media playback completed');
      if (idx >= 0 && idx < this.messages.length) {
        this.messages[idx].content = prefix + '\uD83D\uDD0A ' + I18n.t('chat.audioPlayed');  // 🔊 音频已播放
        this.saveHistory();
      }
    }).catch((err: Error) => {
      this.log.warn('ChatPage', `Media playback failed: ${err.message ?? ''}, trying local TTS fallback`);
      // Fallback: try local TTS with the user's last message context
      this.fallbackLocalTts(idx, prefix);
    });
  }

  /**
   * Fallback: if gateway media download fails, use local TTS to speak
   * a simple acknowledgment or the user's last question.
   */
  private fallbackLocalTts(msgIdx: number, displayPrefix: string): void {
    // Find the last user message to determine what to speak
    let lastUserText = '';
    for (let i = this.messages.length - 1; i >= 0; i--) {
      if (this.messages[i].role === 'user') {
        lastUserText = this.messages[i].content;
        break;
      }
    }

    let runtime = NodeRuntime.getInstance();
    // Speak a brief response using local TTS
    let textToSpeak = lastUserText.length > 0
      ? lastUserText.substring(0, 200)
      : '\u4ECA\u5929\u5E94\u8BE5\u662F\u4E2A\u597D\u5929\u6C14'; // 今天应该是个好天气

    let speakParams = `{"text":${JSON.stringify(textToSpeak)},"lang":"zh-CN"}`;
    runtime.speakLocal(speakParams).then(() => {
      this.log.info('ChatPage', 'Local TTS fallback completed');
      if (msgIdx >= 0 && msgIdx < this.messages.length) {
        this.messages[msgIdx].content = displayPrefix + '\uD83D\uDD0A ' + I18n.t('chat.audioPlayed');
        this.saveHistory();
      }
    }).catch((err: Error) => {
      this.log.error('ChatPage', `Local TTS fallback also failed: ${err.message ?? ''}`);
      if (msgIdx >= 0 && msgIdx < this.messages.length) {
        this.messages[msgIdx].content = displayPrefix + I18n.t('chat.audioFailed');
        this.saveHistory();
      }
    });
  }

  /** Handle a gateway notification and display it as a chat message. */
  /** Handle media files captured via gateway (audio recordings, photos). */
  private handleMediaCaptured(type: string, path: string): void {
    this.log.info('ChatPage', `Media captured: type=${type} path=${path}`);

    if (type === 'recording_start') {
      let durationMs = parseInt(path) || 5000;
      this.gwRecordingDuration = Math.ceil(durationMs / 1000);
      this.gwRecordingTimer = 0;
      if (this.gwRecordingInterval >= 0) {
        clearInterval(this.gwRecordingInterval);
      }
      this.gwRecordingInterval = setInterval(() => {
        if (this.gwRecordingTimer >= 0) {
          this.gwRecordingTimer++;
        }
      }, 1000);
      return;
    }
    if (type === 'recording_stop') {
      if (this.gwRecordingInterval >= 0) {
        clearInterval(this.gwRecordingInterval);
        this.gwRecordingInterval = -1;
      }
      this.gwRecordingTimer = -1;
      return;
    }

    // Insert a tool-result message with the media file for playback/display
    let msg = new ChatMessage('tool', `{"note":"${type} captured","path":"${path}"}`);
    msg.toolName = type === 'audio' ? 'record_audio' : 'capture_photo';
    msg.toolOutput = msg.content;
    if (type === 'audio') {
      msg.audioPath = path;
    } else if (type === 'photo') {
      msg.imagePath = path;
    }
    this.messages.push(msg);
    this.scrollToEnd();
    this.saveHistory();
  }

  /** Handle AIService recording start/stop for timer UI. */
  private handleRecordingState(recording: boolean, durationSec: number): void {
    if (recording) {
      this.gwRecordingDuration = durationSec;
      this.gwRecordingTimer = 0;
      if (this.gwRecordingInterval >= 0) {
        clearInterval(this.gwRecordingInterval);
      }
      this.gwRecordingInterval = setInterval(() => {
        if (this.gwRecordingTimer >= 0) {
          this.gwRecordingTimer++;
        }
      }, 1000);
    } else {
      if (this.gwRecordingInterval >= 0) {
        clearInterval(this.gwRecordingInterval);
        this.gwRecordingInterval = -1;
      }
      this.gwRecordingTimer = -1;
    }
  }

  /** Handle gateway invoke requests: show them as tool call messages in chat. */
  private handleInvokeInChat(command: string, params: string, result: string, isError: boolean): void {
    this.log.info('ChatPage', `Invoke in chat: command=${command} isError=${isError} resultLen=${result.length}`);

    // Create a tool call message
    let msg = new ChatMessage('tool', '');
    msg.isToolCall = true;
    msg.toolName = command;
    // Show a short version of params (strip base64 data)
    let shortParams = params.length > 300 ? params.substring(0, 300) + '...' : params;
    msg.toolInput = shortParams;
    // Show result (truncate very large results like base64 images)
    let shortResult = result.length > 500 ? result.substring(0, 500) + '...' : result;
    msg.toolOutput = isError ? `Error: ${shortResult}` : shortResult;

    // Extract image/audio from result for display
    if (!isError) {
      try {
        let parsed = JSON.parse(result) as Record<string, Object>;
        let fp = parsed['filePath'] as string;
        if (fp && fp.length > 0) {
          if (command === 'mic.record') {
            msg.audioPath = fp;
          } else if (command === 'camera.snap' || command === 'screen.capture') {
            msg.imagePath = fp;
          }
        }
      } catch { /* ignore */ }
    }

    this.messages.push(msg);
    this.scrollToEnd();
    this.saveHistory();
  }

  private handleNotificationInChat(info: NotificationInfo): void {
    this.log.info('ChatPage', `Notification received: title="${info.title}" sender="${info.sender}" body="${info.body.substring(0, 80)}"`);

    // Build a display message with sender and notification content
    let parts: string[] = [];
    parts.push(`\uD83D\uDD14 ${I18n.t('chat.notificationReceived')}`);  // 🔔
    if (info.sender.length > 0) {
      parts.push(`${I18n.t('chat.notificationFrom')}: ${info.sender}`);
    }
    if (info.title.length > 0 && info.title !== 'OpenClaw') {
      parts.push(`${info.title}`);
    }
    if (info.body.length > 0) {
      parts.push(info.body);
    }

    let displayText = parts.join('\n');
    let msg = new ChatMessage('assistant', displayText);
    this.messages.push(msg);
    this.messages = [...this.messages]; // trigger re-render
    this.scrollToEnd();
    this.saveHistory();
  }

  private startDotAnimation(): void {
    this.dotPhase = 0;
    this.dotTimer = setInterval(() => {
      this.dotPhase = (this.dotPhase + 1) % 3;
    }, 400);
  }

  private stopDotAnimation(): void {
    if (this.dotTimer !== -1) {
      clearInterval(this.dotTimer);
      this.dotTimer = -1;
    }
  }

  /** Send message through local AI service (direct HTTP API). */
  private async sendViaLocalAI(text: string): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let settings = await this.loadSettings(ctx);
      let memItems: MemoryItem[];
      if (this.autoMemoryInject) {
        memItems = await this.searchRelevantMemoriesWithTimeout(ctx, text);
      } else {
        memItems = await this.memSvc.loadAll(ctx);
      }
      let skills = getDefaultSkills();
      let customSkills = await CustomSkillService.getInstance().loadAll(ctx);

      // Classify intent to select only relevant tools/prompts
      let hasMedia = this.messages.length > 0 &&
        this.messages[this.messages.length - 1].role === 'user' &&
        ((this.messages[this.messages.length - 1].userImagePath?.length ?? 0) > 0 ||
         (this.messages[this.messages.length - 1].attachmentName?.length ?? 0) > 0);
      let intent = classifyIntent(text, hasMedia);
      this.log.info('ChatPage', `Intent: ${intent.type} skills=[${intent.skillIds.join(',')}]`);

      let systemPrompt: string;
      let tools: import('../model/Models').ToolSchema[];
      if (intent.type === 'general') {
        systemPrompt = this.buildSystemPrompt(memItems, skills, settings.model, customSkills);
        tools = getEnabledToolSchemas(skills);
      } else if (intent.type === 'chitchat') {
        systemPrompt = this.buildSystemPrompt(memItems, skills, settings.model, customSkills);
        tools = getToolSchemasForSkills([]); // memory only
      } else {
        systemPrompt = this.buildSystemPromptFiltered(memItems, skills, settings.model, intent.skillIds, customSkills);
        tools = getToolSchemasForSkills(intent.skillIds);
      }

      // Create placeholder assistant message for streaming
      let streamMsg = new ChatMessage('assistant', '');
      this.messages.push(streamMsg);
      let streamIdx = this.messages.length - 1;

      let onDelta = (deltaText: string): void => {
        if (streamIdx >= 0 && streamIdx < this.messages.length) {
          this.messages[streamIdx].content += deltaText;
          this.scrollToEnd();
        }
      };

      let result: AIResult = await this.ai.chat(this.messages.slice(0, streamIdx), settings, systemPrompt, tools, ctx, onDelta);

      if (result.error.length > 0) {
        // Replace placeholder with error
        this.messages[streamIdx].content = result.error;
      } else {
        // The first assistant message was streamed into placeholder.
        // Replace/update with final messages from result.
        let firstAssistantSet = false;
        for (let msg of result.messages) {
          if (msg.role === 'assistant' && !msg.isToolCall && !firstAssistantSet) {
            // Update the streaming placeholder with final content (may have buttons/images)
            this.messages[streamIdx].content = msg.content;
            this.messages[streamIdx].imagePath = msg.imagePath;
            this.messages[streamIdx].buttons = msg.buttons;
            firstAssistantSet = true;
          } else {
            this.messages.push(msg);
          }
        }
        // If no assistant message in result but we streamed text, keep it
        if (!firstAssistantSet && this.messages[streamIdx].content.length === 0) {
          // Remove empty placeholder
          this.messages.splice(streamIdx, 1);
        }

        // Auto-read the last assistant message if TTS auto-read is enabled
        if (result.messages.length > 0) {
          let lastMsg = result.messages[result.messages.length - 1];
          if (lastMsg.role === 'assistant' && lastMsg.content.length > 0) {
            this.autoReadAloud(lastMsg.content);
          }
        }
      }

      // handle save_memory tool results
      for (let msg of result.messages) {
        if (msg.role === 'tool' && msg.toolName === 'save_memory') {
          try {
            let parsed = JSON.parse(msg.toolOutput) as Record<string, string>;
            if (parsed['saved'] === 'true' || parsed['saved']) {
              await this.memSvc.add(ctx, parsed['type'] ?? 'fact', parsed['content'] ?? '');
            }
          } catch { /* ignore */ }
        }
      }

      // auto-extract memory from user text
      await this.memSvc.autoExtract(ctx, text);

    } catch (e) {
      this.messages.push(new ChatMessage('assistant',
        'Error: ' + ((e as Error).message ?? String(e))));
    }

    this.isLoading = false;
    this.loadingSessionId = '';
    this.stopDotAnimation();
  }

  // ---- Voice input (press-and-hold, ASR via API) ----

  // ---- Attachment picker (image / file) ----

  /** Handle inline button action — send as user message or resolve approval */
  private handleButtonAction(action: string): void {
    if (action.startsWith('__approval__:')) {
      // Parse: __approval__:<decision>:<approvalId>
      let parts = action.substring('__approval__:'.length);
      let colonIdx = parts.indexOf(':');
      if (colonIdx > 0) {
        let decision = parts.substring(0, colonIdx);
        let approvalId = parts.substring(colonIdx + 1);
        this.resolveApprovalAction(approvalId, decision);
      }
      return;
    }
    this.inputText = action;
    this.send();
  }

  /** Handle exec approval request from gateway */
  private handleApprovalRequest(req: ExecApprovalRequest): void {
    let now = Date.now();
    if (req.expiresAt > 0 && req.expiresAt <= now) {
      // Already expired, skip
      return;
    }

    let cmdDisplay = req.command.length > 200 ? req.command.substring(0, 200) + '...' : req.command;
    let content = `${I18n.t('chat.approval.title')}\n` +
      `${I18n.t('chat.approval.command')}: ${cmdDisplay}\n` +
      `${I18n.t('chat.approval.host')}: ${req.host}\n` +
      `${I18n.t('chat.approval.agent')}: ${req.agentId}`;

    let msg = new ChatMessage('assistant', content);
    msg.buttons = [
      new InlineButton(I18n.t('chat.approval.allowOnce'), `__approval__:allow-once:${req.id}`),
      new InlineButton(I18n.t('chat.approval.allowAlways'), `__approval__:allow-always:${req.id}`),
      new InlineButton(I18n.t('chat.approval.deny'), `__approval__:deny:${req.id}`),
    ];
    this.messages.push(msg);
    this.scrollToEnd();

    // Set expiration timer
    if (req.expiresAt > 0) {
      let remainMs = req.expiresAt - now;
      let timerId = setTimeout(() => {
        this.approvalTimers.delete(req.id);
        // Find the message and mark as expired
        for (let i = this.messages.length - 1; i >= 0; i--) {
          let m = this.messages[i];
          if (m.buttons.length > 0 && m.buttons[0].action.endsWith(req.id)) {
            m.content = `${I18n.t('chat.approval.title')}\n${I18n.t('chat.approval.command')}: ${cmdDisplay}\n\n${I18n.t('chat.approval.expired')}`;
            m.buttons = [];
            break;
          }
        }
      }, remainMs);
      this.approvalTimers.set(req.id, timerId);
    }
  }

  /** Resolve an exec approval via gateway RPC */
  private resolveApprovalAction(approvalId: string, decision: string): void {
    // Clear expiration timer
    let timerId = this.approvalTimers.get(approvalId);
    if (timerId !== undefined) {
      clearTimeout(timerId);
      this.approvalTimers.delete(approvalId);
    }

    // Update message UI — find the approval message and update it
    let resultLabel = decision === 'deny' ? I18n.t('chat.approval.denied') : I18n.t('chat.approval.approved');
    for (let i = this.messages.length - 1; i >= 0; i--) {
      let m = this.messages[i];
      if (m.buttons.length > 0 && m.buttons[0].action.endsWith(approvalId)) {
        m.content = m.content.split('\n').slice(0, 3).join('\n') + `\n\n${resultLabel} (${decision})`;
        m.buttons = [];
        break;
      }
    }

    // Send RPC to gateway
    NodeRuntime.getInstance().resolveApproval(approvalId, decision).catch((err: Error) => {
      // Show error in chat if RPC fails
      let errMsg = new ChatMessage('assistant', `Approval error: ${err.message}`);
      this.messages.push(errMsg);
      this.scrollToEnd();
    });
  }

  /** Called reactively when share_timestamp changes in AppStorage */
  private onShareReceived(): void {
    if (this.shareTimestamp <= 0 || this.shareTimestamp === this.lastConsumedShareTs) {
      return;
    }
    this.lastConsumedShareTs = this.shareTimestamp;
    this.consumeShareData();
  }

  private consumeShareData(): void {
    let shareText = AppStorage.get<string>('share_text') ?? '';
    let shareUri = AppStorage.get<string>('share_uri') ?? '';
    let shareUrisJson = AppStorage.get<string>('share_uris') ?? '';
    let shareType = AppStorage.get<string>('share_type') ?? '';

    // Parse multiple URIs
    let shareUris: string[] = [];
    if (shareUrisJson.length > 0) {
      try {
        shareUris = JSON.parse(shareUrisJson) as string[];
      } catch { /* ignore */ }
    }
    if (shareUris.length === 0 && shareUri.length > 0) {
      shareUris = [shareUri];
    }

    this.log.info('ChatPage', `consumeShareData: type=${shareType} textLen=${shareText.length} uris=${shareUris.length}`);

    // Clear AppStorage
    AppStorage.setOrCreate<number>('share_timestamp', 0);
    AppStorage.setOrCreate<string>('share_text', '');
    AppStorage.setOrCreate<string>('share_uri', '');
    AppStorage.setOrCreate<string>('share_uris', '');
    AppStorage.setOrCreate<string>('share_type', '');

    if (shareType === 'text' && shareText.length > 0) {
      this.inputText = shareText;
      this.scrollToEnd();
    } else if (shareType === 'image' && shareUris.length > 0) {
      this.handleSharedImages(shareUris);
    } else if (shareType === 'file' && shareUri.length > 0) {
      this.handleSharedFile(shareUri);
    } else if (shareText.length > 0) {
      this.inputText = shareText;
      this.scrollToEnd();
    }
  }

  private async handleSharedImages(uris: string[]): Promise<void> {
    this.log.info('ChatPage', `handleSharedImages: ${uris.length} URIs`);
    let processedPaths: string[] = [];
    for (let uri of uris) {
      let path = await this.processSharedImageUri(uri);
      if (path.length > 0) {
        processedPaths.push(path);
      }
    }
    this.log.info('ChatPage', `handleSharedImages: ${processedPaths.length} processed`);
    if (processedPaths.length === 1) {
      this.pendingImagePath = processedPaths[0];
    } else if (processedPaths.length > 1) {
      this.pendingImagePaths = processedPaths;
    }
  }

  /** Process a single shared image URI: copy to sandbox + compress. Returns sandbox path or fallback URI. */
  private async processSharedImageUri(uri: string): Promise<string> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let imgDir = ctx.filesDir + '/user_images';
      try { fileIo.mkdirSync(imgDir); } catch { /* exists */ }
      let destPath = `${imgDir}/share_${Date.now()}_${Math.floor(Math.random() * 1000)}.jpg`;

      let fsPath = uri;
      if (fsPath.startsWith('file://')) {
        fsPath = fsPath.substring(7);
      }

      let rawPath = `${imgDir}/share_raw_${Date.now()}_${Math.floor(Math.random() * 1000)}`;
      let srcFile = fileIo.openSync(fsPath, fileIo.OpenMode.READ_ONLY);
      let stat = fileIo.statSync(srcFile.fd);
      let rawBuf = new ArrayBuffer(stat.size);
      fileIo.readSync(srcFile.fd, rawBuf);
      fileIo.closeSync(srcFile);

      let rawFile = fileIo.openSync(rawPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(rawFile.fd, rawBuf);
      fileIo.closeSync(rawFile);

      let imgSource = image.createImageSource(rawPath);
      let info = await imgSource.getImageInfo();
      let scale = 1.0;
      let maxDim = 1280;
      if (info.size.width > maxDim || info.size.height > maxDim) {
        scale = maxDim / Math.max(info.size.width, info.size.height);
      }
      let decodingOpts: image.DecodingOptions = {
        desiredSize: { width: Math.round(info.size.width * scale), height: Math.round(info.size.height * scale) }
      };
      let pixelMap = await imgSource.createPixelMap(decodingOpts);
      let packer = image.createImagePacker();
      let packOpts: image.PackingOption = { format: 'image/jpeg', quality: 80 };
      let packed: ArrayBuffer = await packer.packing(pixelMap, packOpts);
      await pixelMap.release();
      imgSource.release();
      packer.release();

      let destFile = fileIo.openSync(destPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(destFile.fd, packed);
      fileIo.closeSync(destFile);
      try { fileIo.unlinkSync(rawPath); } catch { /* ignore */ }

      this.log.info('ChatPage', `Shared image compressed: ${packed.byteLength} bytes -> ${destPath}`);
      return destPath;
    } catch (e) {
      this.log.error('ChatPage', `processSharedImageUri error: ${(e as Error).message ?? ''}`);
      return uri; // fallback: use original URI
    }
  }

  private async handleSharedImage(uri: string): Promise<void> {
    this.log.info('ChatPage', `handleSharedImage: uri=${uri}`);
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let imgDir = ctx.filesDir + '/user_images';
      try { fileIo.mkdirSync(imgDir); } catch { /* exists */ }
      let destPath = `${imgDir}/share_${Date.now()}.jpg`;

      // Strip file:// prefix for fileIo operations (fileIo needs filesystem path)
      let fsPath = uri;
      if (fsPath.startsWith('file://')) {
        fsPath = fsPath.substring(7); // Remove 'file://'
      }
      this.log.info('ChatPage', `handleSharedImage: fsPath=${fsPath}`);

      // First, copy the shared file to sandbox (shared URIs have temporary read permission)
      let rawPath = `${imgDir}/share_raw_${Date.now()}`;
      let srcFile = fileIo.openSync(fsPath, fileIo.OpenMode.READ_ONLY);
      let stat = fileIo.statSync(srcFile.fd);
      this.log.info('ChatPage', `Shared image opened: fd=${srcFile.fd} size=${stat.size}`);
      let rawBuf = new ArrayBuffer(stat.size);
      fileIo.readSync(srcFile.fd, rawBuf);
      fileIo.closeSync(srcFile);

      // Save raw copy to sandbox first
      let rawFile = fileIo.openSync(rawPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(rawFile.fd, rawBuf);
      fileIo.closeSync(rawFile);

      // Compress from the sandbox copy
      let imgSource = image.createImageSource(rawPath);
      let info = await imgSource.getImageInfo();
      let origW = info.size.width;
      let origH = info.size.height;
      let scale = 1.0;
      let maxDim = 1280;
      if (origW > maxDim || origH > maxDim) {
        scale = maxDim / Math.max(origW, origH);
      }
      let targetW = Math.round(origW * scale);
      let targetH = Math.round(origH * scale);
      let decodingOpts: image.DecodingOptions = { desiredSize: { width: targetW, height: targetH } };
      let pixelMap = await imgSource.createPixelMap(decodingOpts);
      let packer = image.createImagePacker();
      let packOpts: image.PackingOption = { format: 'image/jpeg', quality: 80 };
      let packed: ArrayBuffer = await packer.packing(pixelMap, packOpts);
      await pixelMap.release();
      imgSource.release();
      packer.release();

      let destFile = fileIo.openSync(destPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(destFile.fd, packed);
      fileIo.closeSync(destFile);

      // Clean up raw copy
      try { fileIo.unlinkSync(rawPath); } catch { /* ignore */ }

      this.log.info('ChatPage', `Shared image compressed: ${origW}x${origH} -> ${targetW}x${targetH}, ${packed.byteLength} bytes`);
      this.pendingImagePath = destPath;
    } catch (e) {
      this.log.error('ChatPage', `handleSharedImage error: ${(e as Error).message ?? ''}`);
      // Fallback: use URI directly — Image component can render file:// URIs
      this.pendingImagePath = uri;
    }
  }

  private async handleSharedFile(uri: string): Promise<void> {
    try {
      let srcFile = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      let stat = fileIo.statSync(srcFile.fd);
      let size = stat.size;
      if (size > 512 * 1024) {
        // Too large — show truncated
        this.log.warn('ChatPage', `Shared file too large: ${size} bytes, truncating`);
        size = 512 * 1024;
      }
      let buf = new ArrayBuffer(size);
      fileIo.readSync(srcFile.fd, buf);
      fileIo.closeSync(srcFile);

      let decoder = util.TextDecoder.create('utf-8');
      let text = decoder.decodeToString(new Uint8Array(buf));

      // Extract filename from URI
      let parts = uri.split('/');
      let fileName = parts[parts.length - 1] || 'shared_file.txt';

      this.pendingFileName = fileName;
      this.pendingFileContent = text;
      this.log.info('ChatPage', `Shared file loaded: ${fileName}, ${text.length} chars`);
    } catch (e) {
      this.log.error('ChatPage', `handleSharedFile error: ${(e as Error).message ?? ''}`);
      // Fallback: put URI in input
      this.inputText = uri;
    }
  }

  private showAttachmentMenu(): void {
    promptAction.showActionMenu({
      title: I18n.t('chat.attachTitle'),
      buttons: [
        { text: I18n.t('chat.attachPhoto'), color: '#D2691E' },
        { text: I18n.t('chat.attachFile'), color: '#D2691E' },
      ]
    }).then((result) => {
      if (result.index === 0) {
        this.pickPhoto();
      } else if (result.index === 1) {
        this.pickFile();
      }
    }).catch(() => { /* cancelled */ });
  }

  private async pickPhoto(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let photoPicker = new picker.PhotoViewPicker(ctx);
      let options = new picker.PhotoSelectOptions();
      options.MIMEType = picker.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      let result = await photoPicker.select(options);
      if (result.photoUris.length === 0) return;
      let srcUri = result.photoUris[0];

      // Compress and save to app sandbox
      let imgDir = ctx.filesDir + '/user_images';
      try { fileIo.mkdirSync(imgDir); } catch { /* exists */ }
      let destPath = `${imgDir}/img_${Date.now()}.jpg`;

      // Read source and compress
      let srcFile = fileIo.openSync(srcUri, fileIo.OpenMode.READ_ONLY);
      let imgSource = image.createImageSource(srcFile.fd);
      let info = await imgSource.getImageInfo();
      let origW = info.size.width;
      let origH = info.size.height;
      let scale = 1.0;
      let maxDim = 1280;
      if (origW > maxDim || origH > maxDim) {
        scale = maxDim / Math.max(origW, origH);
      }
      let targetW = Math.round(origW * scale);
      let targetH = Math.round(origH * scale);
      let decodingOpts: image.DecodingOptions = { desiredSize: { width: targetW, height: targetH } };
      let pixelMap = await imgSource.createPixelMap(decodingOpts);
      let packer = image.createImagePacker();
      let packOpts: image.PackingOption = { format: 'image/jpeg', quality: 80 };
      let packed: ArrayBuffer = await packer.packing(pixelMap, packOpts);
      await pixelMap.release();
      imgSource.release();
      packer.release();
      fileIo.closeSync(srcFile);

      let destFile = fileIo.openSync(destPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(destFile.fd, packed);
      fileIo.closeSync(destFile);

      this.log.info('ChatPage', `Photo compressed: ${origW}x${origH} -> ${targetW}x${targetH}, ${packed.byteLength} bytes`);
      this.pendingImagePath = destPath;
    } catch (e) {
      this.log.error('ChatPage', `pickPhoto error: ${(e as Error).message ?? ''}`);
    }
  }

  private async pickFile(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let options = new picker.DocumentSelectOptions();
      let docPicker = new picker.DocumentViewPicker(ctx);
      let uris = await docPicker.select(options);
      if (uris.length === 0) return;
      let uri = uris[0];

      let file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      let stat = fileIo.statSync(file.fd);
      if (stat.size > 512 * 1024) {
        fileIo.closeSync(file);
        promptAction.showToast({ message: I18n.t('chat.fileTooLarge'), duration: 2000 });
        return;
      }
      let buf = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buf);
      fileIo.closeSync(file);
      let decoder = util.TextDecoder.create('utf-8');
      let text = decoder.decodeWithStream(new Uint8Array(buf));

      // Extract filename from URI
      let parts = uri.split('/');
      let fileName = parts[parts.length - 1] || 'file';

      this.pendingFileName = fileName;
      this.pendingFileContent = text;
    } catch (e) {
      this.log.error('ChatPage', `pickFile error: ${(e as Error).message ?? ''}`);
    }
  }

  private asrDebug(text: string): void {
    this.log.info('ASR', text);
  }

  private async startRecording(): Promise<void> {
    this.pcmBuffers = [];
    this.asrDebug('Starting...');

    try {
      await this.cleanupAsr();

      let ctx = getContext(this) as common.UIAbilityContext;
      let atManager = abilityAccessCtrl.createAtManager();
      let permResult = await atManager.requestPermissionsFromUser(ctx, ['ohos.permission.MICROPHONE']);
      if (permResult.authResults[0] !== 0) {
        this.asrDebug('Mic permission denied');
        this.isRecording = false;
        return;
      }

      let capturerOptions: audio.AudioCapturerOptions = {
        streamInfo: {
          samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
          channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
        },
        capturerInfo: {
          source: audio.SourceType.SOURCE_TYPE_VOICE_RECOGNITION,
          capturerFlags: 0
        }
      };
      this.audioCapturer = await audio.createAudioCapturer(capturerOptions);
      await this.audioCapturer.start();

      this.isRecording = true;
      this.asrReading = true;
      this.asrDebug('Recording...');
      this.readAudioLoop();

    } catch (err) {
      this.asrDebug('FAILED: ' + ((err as Error).message ?? String(err)));
      this.isRecording = false;
      await this.cleanupAsr();
    }
  }

  private async readAudioLoop(): Promise<void> {
    if (!this.audioCapturer) return;
    try {
      let bufSize = await this.audioCapturer.getBufferSize();
      while (this.asrReading && this.audioCapturer) {
        let buf: ArrayBuffer = await this.audioCapturer.read(bufSize, true);
        if (buf.byteLength > 0) {
          this.pcmBuffers.push(buf.slice(0));
        }
      }
    } catch (err) {
      this.asrDebug('Audio read ended: ' + ((err as Error).message ?? ''));
    }
  }

  private async stopRecording(): Promise<void> {
    this.asrDebug('Stopping...');
    this.asrReading = false;
    this.isRecording = false;

    if (this.audioCapturer) {
      try { await this.audioCapturer.stop(); } catch { /* ignore */ }
    }

    let savedPcmBuffers = this.pcmBuffers.slice();
    let wavPath = this.saveWavFile(this.pcmBuffers);
    this.pcmBuffers = [];

    if (wavPath.length === 0) {
      this.asrDebug('No audio data');
      await this.cleanupAsr();
      return;
    }

    try {
      let stat = fileIo.statSync(wavPath);
      if (stat.size < 16044) {
        this.asrDebug('Too short, discarding');
        try { fileIo.unlinkSync(wavPath); } catch { /* ignore */ }
        await this.cleanupAsr();
        return;
      }
    } catch { /* ignore */ }

    await this.cleanupAsr();

    // Call ASR (hybrid: local + cloud based on mode setting)
    let recognizedText = await this.recognizeSpeech(wavPath, savedPcmBuffers);

    let displayText = recognizedText.length > 0 ? recognizedText : I18n.t('chat.voiceNoText');
    let userMsg = new ChatMessage('user', displayText);
    userMsg.audioPath = wavPath;
    this.messages.push(userMsg);
    this.scrollToEnd();
    this.saveHistory();

    if (recognizedText.length > 0) {
      this.sendVoiceText(recognizedText);
    }
  }

  /** Call configured ASR API (Whisper-compatible multipart upload) */
  private async callAsrApi(wavPath: string): Promise<string> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let store = await preferences.getPreferences(ctx, Constants.PREFS_SETTINGS);
      let asrUrl = (await store.get('asr_url', '')) as string;
      let asrKey = (await store.get('asr_key', '')) as string;
      let asrModel = (await store.get('asr_model', '')) as string;

      if (asrUrl.length === 0 || asrKey.length === 0) {
        this.asrDebug('ASR API not configured');
        return '';
      }

      // Read WAV file
      let file = fileIo.openSync(wavPath, fileIo.OpenMode.READ_ONLY);
      let stat = fileIo.statSync(wavPath);
      let wavData = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, wavData);
      fileIo.closeSync(file);

      this.asrDebug(`Sending WAV (${stat.size} bytes) to ${asrUrl}`);

      // Build multipart/form-data
      let boundary = '----AsrBoundary' + Date.now().toString();
      let filePart = `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="voice.wav"\r\nContent-Type: audio/wav\r\n\r\n`;
      let modelPart = asrModel.length > 0
        ? `\r\n--${boundary}\r\nContent-Disposition: form-data; name="model"\r\n\r\n${asrModel}`
        : '';
      let endPart = `\r\n--${boundary}--\r\n`;

      let te = new util.TextEncoder();
      let filePartBuf = te.encodeInto(filePart);
      let modelPartBuf = te.encodeInto(modelPart);
      let endPartBuf = te.encodeInto(endPart);

      let totalLen = filePartBuf.byteLength + wavData.byteLength + modelPartBuf.byteLength + endPartBuf.byteLength;
      let body = new ArrayBuffer(totalLen);
      let bodyView = new Uint8Array(body);
      let pos = 0;
      bodyView.set(new Uint8Array(filePartBuf.buffer), pos); pos += filePartBuf.byteLength;
      bodyView.set(new Uint8Array(wavData), pos); pos += wavData.byteLength;
      bodyView.set(new Uint8Array(modelPartBuf.buffer), pos); pos += modelPartBuf.byteLength;
      bodyView.set(new Uint8Array(endPartBuf.buffer), pos);

      let httpRequest = http.createHttp();
      let response = await httpRequest.request(asrUrl, {
        method: http.RequestMethod.POST,
        header: {
          'Authorization': `Bearer ${asrKey}`,
          'Content-Type': `multipart/form-data; boundary=${boundary}`
        },
        extraData: body,
        connectTimeout: 15000,
        readTimeout: 30000
      });
      httpRequest.destroy();

      if (response.responseCode === 200) {
        let respStr = response.result as string;
        this.asrDebug('ASR result: ' + respStr.substring(0, 300));
        let parsed = JSON.parse(respStr) as Record<string, Object>;
        let text = (parsed['text'] as string) ?? '';
        return text.trim();
      } else {
        this.asrDebug(`ASR error: ${response.responseCode} ${String(response.result).substring(0, 200)}`);
        return '';
      }
    } catch (err) {
      this.asrDebug('ASR failed: ' + ((err as Error).message ?? String(err)));
      return '';
    }
  }

  /** Hybrid ASR: cloud Whisper (accurate) + local speechRecognizer (offline fallback) */
  private async recognizeSpeech(wavPath: string, pcmBuffers: ArrayBuffer[]): Promise<string> {
    let ctx = getContext(this) as common.UIAbilityContext;
    let store = await preferences.getPreferences(ctx, Constants.PREFS_SETTINGS);
    let asrMode = (await store.get('asr_mode', 'auto')) as string;

    this.asrDebug(`recognizeSpeech: mode=${asrMode} gwConnected=${this.gwConnected}`);

    if (asrMode === 'local') {
      // Local only mode
      this.updateAsrStatus('local');
      return await this.callLocalAsr(pcmBuffers);
    }

    if (asrMode === 'cloud') {
      this.updateAsrStatus('cloud');
      return await this.callAsrApi(wavPath);
    }

    // Auto mode: try cloud first (better accuracy), fall back to local
    this.updateAsrStatus('cloud');
    let cloudResult = await this.callAsrApi(wavPath);
    if (cloudResult.length > 0) {
      return cloudResult;
    }

    // Cloud failed or not configured, fall back to local
    this.asrDebug('Cloud ASR empty, falling back to local');
    this.updateAsrStatus('local');
    return await this.callLocalAsr(pcmBuffers);
  }

  /** Update talkStatus to show which ASR model is being used */
  private updateAsrStatus(source: string): void {
    if (!this.isTalkMode) return;
    let label = source === 'local' ? I18n.t('settings.asrModeLocal') : I18n.t('settings.asrModeCloud');
    this.talkStatus = I18n.t('chat.talkRecognizing') + ` (${label})...`;
  }

  /** Call local speechRecognizer */
  private async callLocalAsr(pcmBuffers: ArrayBuffer[]): Promise<string> {
    try {
      let localAsr = LocalAsrService.getInstance();
      let result = await localAsr.recognizeFromPcm(pcmBuffers);
      this.asrDebug(`Local ASR result: "${result}"`);
      return result;
    } catch (err) {
      this.asrDebug(`Local ASR error: ${(err as Error).message}`);
      return '';
    }
  }

  /** Send ASR-recognized text to AI without creating a user message bubble. */
  private async sendVoiceText(text: string): Promise<void> {
    if (text.length === 0 || this.isLoading) return;

    this.isLoading = true;
    this.loadingSessionId = this.currentSessionId;
    this.startDotAnimation();

    try {
      let enrichedText = await this.enrichWithLocation(text);
      if (this.gwConnected) {
        await this.sendViaGateway(enrichedText);
      } else {
        await this.sendViaLocalAI(enrichedText);
      }
    } catch (e) {
      this.messages.push(new ChatMessage('assistant',
        'Error: ' + ((e as Error).message ?? String(e))));
    }

    this.isLoading = false;
    this.loadingSessionId = '';
    this.stopDotAnimation();
    this.scrollToEnd();
    this.saveHistory();

    // Process queued messages
    await this.processQueue();
  }

  private saveWavFile(buffers: ArrayBuffer[]): string {
    // Calculate total PCM data length
    let totalPcmLen = 0;
    for (let b of buffers) {
      totalPcmLen += b.byteLength;
    }
    if (totalPcmLen === 0) return '';

    let sampleRate = 16000;
    let numChannels = 1;
    let bitsPerSample = 16;
    let byteRate = sampleRate * numChannels * bitsPerSample / 8;
    let blockAlign = numChannels * bitsPerSample / 8;
    let headerSize = 44;
    let fileSize = headerSize + totalPcmLen;

    let wavBuffer = new ArrayBuffer(fileSize);
    let view = new DataView(wavBuffer);

    // RIFF header
    view.setUint8(0, 0x52);  // R
    view.setUint8(1, 0x49);  // I
    view.setUint8(2, 0x46);  // F
    view.setUint8(3, 0x46);  // F
    view.setUint32(4, fileSize - 8, true);
    view.setUint8(8, 0x57);  // W
    view.setUint8(9, 0x41);  // A
    view.setUint8(10, 0x56); // V
    view.setUint8(11, 0x45); // E

    // fmt sub-chunk
    view.setUint8(12, 0x66); // f
    view.setUint8(13, 0x6D); // m
    view.setUint8(14, 0x74); // t
    view.setUint8(15, 0x20); // (space)
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true);
    view.setUint16(22, numChannels, true);
    view.setUint32(24, sampleRate, true);
    view.setUint32(28, byteRate, true);
    view.setUint16(32, blockAlign, true);
    view.setUint16(34, bitsPerSample, true);

    // data sub-chunk
    view.setUint8(36, 0x64); // d
    view.setUint8(37, 0x61); // a
    view.setUint8(38, 0x74); // t
    view.setUint8(39, 0x61); // a
    view.setUint32(40, totalPcmLen, true);

    // Copy PCM data after header
    let dst = new Uint8Array(wavBuffer, headerSize);
    let offset = 0;
    for (let b of buffers) {
      let src = new Uint8Array(b);
      dst.set(src, offset);
      offset += src.byteLength;
    }

    // Write to file
    let ctx = getContext(this) as common.UIAbilityContext;
    let voiceDir = ctx.filesDir + '/voice_messages';
    try { fileIo.mkdirSync(voiceDir); } catch { /* may already exist */ }
    let filePath = `${voiceDir}/voice_${Date.now()}.wav`;
    let file = fileIo.openSync(filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
    fileIo.writeSync(file.fd, wavBuffer);
    fileIo.closeSync(file);

    this.asrDebug(`WAV saved: ${filePath} (${fileSize} bytes, ${(totalPcmLen / byteRate).toFixed(1)}s)`);
    return filePath;
  }

  private async cleanupAsr(): Promise<void> {
    if (this.audioCapturer) {
      try { await this.audioCapturer.stop(); } catch { /* ignore */ }
      try { await this.audioCapturer.release(); } catch { /* ignore */ }
      this.audioCapturer = undefined;
    }
  }

  private buildSystemPrompt(memItems: MemoryItem[], skills: import('../model/Models').SkillItem[], modelName?: string, customSkills?: CustomSkillDef[]): string {
    let d = new Date();
    let tz = -(d.getTimezoneOffset() / 60);
    let tzStr = `UTC${tz >= 0 ? '+' : ''}${tz}`;
    let now = `${d.getFullYear()}-${(d.getMonth()+1).toString().padStart(2,'0')}-${d.getDate().toString().padStart(2,'0')} ${d.getHours().toString().padStart(2,'0')}:${d.getMinutes().toString().padStart(2,'0')}:${d.getSeconds().toString().padStart(2,'0')} ${tzStr}`;
    let base = `You are ClawdBot, a personal AI assistant running on HarmonyOS.

## Soul
${this.soulText}

## Response Style
- ULTRA SHORT responses. 1-2 sentences max. No filler words.
- 极简回复。直接给关键信息，一两句话搞定。
- 禁止"好的"、"当然可以"、"没问题"、"请稍等"等废话开头。
- 禁止重复用户的问题或要求。
- For tool results, give the answer in one line. NEVER repeat raw JSON.
- 不要用 markdown 格式（不要用 **加粗**、- 列表等），用纯文本回复。

## Capabilities
You are capable of performing real actions through tools.
IMPORTANT: When the user asks you to do something, ALWAYS use the appropriate tool to perform the action. Never refuse or guess the outcome — try it first.
CRITICAL: Do NOT announce tool usage. Never say "好的，我来查询..." or "请稍等..." before calling a tool. Just call the tool silently and present the results directly. The user should only see the final answer, not intermediate steps.
Current time: ${now}
Timezone: ${tzStr}
Platform: HarmonyOS
Work mode: ${this.gwConnected ? 'Online (connected to OpenClaw Gateway server)' : 'Local AI (direct API call, no gateway)'}
AI Model: ${modelName && modelName.length > 0 ? modelName : 'unknown (server-controlled)'}

## Available Features
- 📍 Location: Get GPS coordinates (auto-included for weather queries)
- 🌤 Weather: Ask about weather (location auto-detected)
- 📸 Camera: Take photos (front/back)
- 📱 Screenshot: Capture app screen
- 🔍 Web search: Search the internet
- 🌐 Browser: Open and interact with web pages
- 📅 Calendar: Create events and reminders
- ⏰ Scheduler: Recurring/one-shot scheduled tasks
- 📝 Memory: Persistent memory across conversations
- 📧 Email: Read inbox via IMAP
- 📂 Files: Read/write/search sandbox files
- 🔊 TTS: Auto-read responses aloud (if enabled)
- 🎙 Voice input: Speech-to-text via ASR
- 🏠 Smart Home: Control IoT devices
When user asks what you can do, briefly list these features.

## Memory System
You have persistent memory that survives across conversations. Use it proactively:

### When to SAVE memory (use save_memory tool):
- User shares personal facts: name, birthday, job, family, hobbies, location
- User states preferences: language, communication style, favorite things
- User gives instructions: "always do X", "never do Y", "from now on..."
- Important context worth remembering for future conversations

### When to SEARCH memory (use search_memory tool):
- Before answering questions that might relate to previously saved information
- When the user references something from a past conversation
- When you need to recall user preferences or facts

### Guidelines:
- Be proactive: if the user says "我叫小明" or "I live in Shanghai", save it without being asked
- Don't save trivial or temporary information (weather queries, one-time calculations)
- Categories: fact (personal info), preference (likes/dislikes), instruction (rules)
- Also include [已记住: <content>] in your response text when saving memory
`;
    // Add mood detection instructions when in talk mode
    if (this.isTalkMode) {
      base += `
## Voice Mood Detection
The user is in voice conversation mode. Their detected mood/emotion may be included as [用户当前语气/情绪: ...] in their message.
Adjust your tone accordingly:
- Happy/excited: be upbeat and match their energy
- Sad/tired: be gentle and empathetic
- Angry: be calm and understanding
- Humming: they are relaxed, keep it light
`;
    }
    let memBlock = this.memSvc.buildPromptBlock(memItems);
    let skillBlock = getSkillSystemPrompt(skills, customSkills);
    return base + (memBlock ? '\n' + memBlock + '\n' : '') + (skillBlock ? '\n' + skillBlock : '');
  }

  private buildSystemPromptFiltered(memItems: MemoryItem[], skills: import('../model/Models').SkillItem[], modelName?: string, skillIds?: string[], customSkills?: CustomSkillDef[]): string {
    let base = this.buildSystemPrompt(memItems, skills, modelName);
    let skillBlock = getSkillSystemPromptForIds(skills, skillIds ?? [], customSkills);
    return skillBlock.length > 0 ? base + '\n' + skillBlock : base;
  }

  private async loadSettings(ctx: common.UIAbilityContext): Promise<SettingsData> {
    let store = await preferences.getPreferences(ctx, Constants.PREFS_SETTINGS);
    let provider = (await store.get('provider', 'openrouter')) as string;
    // Load per-provider apiKey and baseUrl
    let keyPref = 'key_' + provider;
    let urlPref = 'url_' + provider;
    let modelPref = 'model_' + provider;
    let apiKey = (await store.get(keyPref, '')) as string;
    let baseUrl = (await store.get(urlPref, '')) as string;
    // Safety: ignore stale cross-provider URLs (e.g. SiliconFlow URL leaking to OpenRouter)
    if (provider === 'openrouter' && baseUrl.length > 0 && !baseUrl.includes('openrouter')) {
      baseUrl = '';
    }
    let defaultModel = provider === 'openrouter' ? Constants.DEFAULT_MODEL_OPENROUTER
      : provider === 'anthropic' ? Constants.DEFAULT_MODEL_ANTHROPIC
        : provider === 'openai' ? Constants.DEFAULT_MODEL_OPENAI
          : provider === 'siliconflow' ? Constants.DEFAULT_MODEL_SILICONFLOW
            : provider === 'custom' ? '' : 'llama3';
    let model = (await store.get(modelPref, defaultModel)) as string;
    // Use built-in keys as fallback
    if (apiKey.length === 0 && provider === 'openrouter' && Constants.OPENROUTER_DEFAULT_KEY.length > 0) {
      apiKey = Constants.OPENROUTER_DEFAULT_KEY;
    }
    if (apiKey.length === 0 && (provider === 'openai' || provider === 'siliconflow') && Constants.SILICONFLOW_DEFAULT_KEY.length > 0) {
      apiKey = Constants.SILICONFLOW_DEFAULT_KEY;
    }
    // Load soul
    this.soulText = (await store.get('soul', Constants.DEFAULT_SOUL)) as string;
    return {
      provider: provider,
      apiKey: apiKey,
      model: model,
      baseUrl: baseUrl,
      temperature: (await store.get('temperature', 0.7)) as number,
    };
  }

  // ---- Feishu Bot integration ----

  private async initFeishuBot(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let store = await preferences.getPreferences(ctx, Constants.PREFS_FEISHU);
      let enabled = (await store.get('enabled', false)) as boolean;
      if (!enabled) return;
      let appId = (await store.get('appId', '')) as string;
      let appSecret = (await store.get('appSecret', '')) as string;
      if (appId.length === 0 || appSecret.length === 0) return;

      this.log.info('Feishu', 'Initializing Feishu bot...');
      // Pre-cache settings for fast Feishu message handling
      this.feishuSettings = await this.loadSettings(ctx);
      let feishu = FeishuBotService.getInstance();
      feishu.onMessageReceived = (sender: string, text: string, messageId: string, chatId: string) => {
        this.handleFeishuMessage(sender, text, messageId, chatId);
      };
      feishu.onStateChanged = (state: string) => {
        this.log.info('Feishu', `State: ${state}`);
      };
      await feishu.connect(appId, appSecret);
      this.feishuConnected = true;
    } catch (e) {
      this.log.error('Feishu', `Init failed: ${(e as Error).message ?? String(e)}`);
    }
  }

  private handleFeishuMessage(sender: string, text: string, messageId: string, _chatId: string): void {
    let tStart = Date.now();
    this.log.info('Feishu', `[TIMING] handleFeishuMessage start at ${tStart}, from ${sender}: ${text.substring(0, 100)}`);

    // Add user message to chat
    let userMsg = new ChatMessage('user', `[${I18n.t('chat.feishuMessage')}] ${text}`);
    this.messages.push(userMsg);
    this.scrollToEnd();

    let ctx: common.UIAbilityContext;
    try {
      ctx = getContext(this) as common.UIAbilityContext;
    } catch { return; }

    // Use cached settings (fall back to loading if not cached)
    let settingsPromise: Promise<SettingsData>;
    if (this.feishuSettings) {
      settingsPromise = Promise.resolve(this.feishuSettings);
    } else {
      settingsPromise = this.loadSettings(ctx);
    }

    settingsPromise.then(async (settings: SettingsData) => {
      this.log.info('Feishu', `[TIMING] AI call start, settingsLoad=${Date.now() - tStart}ms`);

      // Use full AI chat with tools (so Feishu can trigger camera, screen, etc.)
      let memItems = await this.memSvc.loadAll(ctx);
      let skills = getDefaultSkills();
      let customSkills = await CustomSkillService.getInstance().loadAll(ctx);
      let systemPrompt = this.buildSystemPrompt(memItems, skills, settings.model, customSkills);
      let tools = getEnabledToolSchemas(skills);

      // Maintain separate Feishu conversation history for multi-turn context
      this.feishuHistory.push(new ChatMessage('user', text));
      // Trim to last 20 messages to prevent token overflow
      while (this.feishuHistory.length > 20) {
        this.feishuHistory.splice(0, 1);
      }

      let result: AIResult = await this.ai.chat(this.feishuHistory, settings, systemPrompt, tools, ctx);
      let tAiDone = Date.now();
      this.log.info('Feishu', `[TIMING] AI done in ${tAiDone - tStart}ms, sending reply...`);

      // Collect reply text and image paths from result messages
      let replyText = '';
      let replyImagePath = '';
      if (result.error.length > 0) {
        this.messages.push(new ChatMessage('assistant', `[${I18n.t('chat.feishuReply')}] ${result.error}`));
        this.feishuHistory.push(new ChatMessage('assistant', result.error));
        replyText = result.error;
      } else {
        for (let msg of result.messages) {
          // Collect image path from tool results (screenshot/photo)
          if (msg.imagePath && msg.imagePath.length > 0) {
            replyImagePath = msg.imagePath;
          }
          // Add assistant text to Feishu history (without prefix)
          if (msg.role === 'assistant' && !msg.isToolCall && msg.content.length > 0) {
            replyText = msg.content;
            this.feishuHistory.push(new ChatMessage('assistant', msg.content));
            // Prefix for display in main chat
            msg.content = `[${I18n.t('chat.feishuReply')}] ${msg.content}`;
          }
          this.messages.push(msg);
        }
      }
      this.scrollToEnd();
      this.saveHistory();

      // Send reply back to Feishu (image + text)
      let feishu = FeishuBotService.getInstance();
      if (replyImagePath.length > 0) {
        // Upload image to Feishu and reply with image
        feishu.replyWithImage(messageId, replyImagePath, replyText).then(() => {
          this.log.info('Feishu', `[TIMING] Image reply sent, total=${Date.now() - tStart}ms`);
        }).catch((e: Error) => {
          this.log.error('Feishu', `Feishu image reply failed: ${e.message ?? ''}`);
          // Fallback to text reply
          if (replyText.length > 0) {
            feishu.replyMessage(messageId, replyText);
          }
        });
      } else if (replyText.length > 0) {
        feishu.replyMessage(messageId, replyText).then(() => {
          this.log.info('Feishu', `[TIMING] Reply sent, total=${Date.now() - tStart}ms`);
        }).catch((e: Error) => {
          this.log.error('Feishu', `Feishu reply send failed: ${e.message ?? ''}`);
        });
      }
    }).catch((e: Error) => {
      this.log.error('Feishu', `Reply failed: ${e.message ?? String(e)}`);
      let errMsg = new ChatMessage('assistant', `[${I18n.t('chat.feishuReply')}] Error: ${e.message ?? ''}`);
      this.messages.push(errMsg);
      this.scrollToEnd();
    });
  }

  private formatTimer(seconds: number): string {
    let m = Math.floor(seconds / 60);
    let s = seconds % 60;
    return `${m}:${s < 10 ? '0' : ''}${s}`;
  }

  private scrollToEnd(): void {
    setTimeout(() => {
      this.scroller.scrollToIndex(Math.max(0, this.messages.length - 1));
    }, 100);
  }

  private scrollToMessage(messageId: string): void {
    let idx = this.messages.findIndex((m: ChatMessage) => m.id === messageId);
    if (idx < 0) return;
    this.scroller.scrollToIndex(idx);
    // Brief highlight effect
    setTimeout(() => {
      this.highlightMessageId = messageId;
      setTimeout(() => {
        this.highlightMessageId = '';
      }, 1500);
    }, 200);
  }

  // ---- persistence (simple JSON in preferences) ----
  private async saveHistory(): Promise<void> {
    // Save to session service (new multi-session storage)
    await this.saveSessionMessages();
    
    // Also save to legacy preferences for backward compatibility
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let store = await preferences.getPreferences(ctx, Constants.PREFS_MESSAGES);
      let data = this.messages.slice(-Constants.MAX_HISTORY).map((m): SavedMsg => {
        let saved: SavedMsg = {
          role: m.role,
          content: m.content,
          timestamp: m.timestamp,
          isToolCall: m.isToolCall,
          toolName: m.toolName,
          toolInput: m.toolInput,
          toolOutput: m.toolOutput,
          imagePath: m.imagePath,
          audioPath: m.audioPath
        };
        return saved;
      });
      await store.put('history', JSON.stringify(data));
      await store.flush();
    } catch { /* best-effort */ }
  }

  private async loadHistory(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let store = await preferences.getPreferences(ctx, Constants.PREFS_MESSAGES);
      let raw = (await store.get('history', '[]')) as string;
      let arr = JSON.parse(raw) as SavedMsg[];
      for (let d of arr) {
        let msg = new ChatMessage(d.role, d.content);
        msg.timestamp = d.timestamp;
        msg.isToolCall = d.isToolCall;
        msg.toolName = d.toolName ?? '';
        msg.toolInput = d.toolInput ?? '';
        msg.toolOutput = d.toolOutput ?? '';
        msg.imagePath = d.imagePath ?? '';
        msg.audioPath = d.audioPath ?? '';
        this.messages.push(msg);
      }
      this.scrollToEnd();
    } catch { /* first launch */ }
  }

  private clearMessages(): void {
    if (this.messages.length > 0) {
      let msgCopy = this.messages.slice();
      // Save conversation log before clearing
      ConversationLogger.getInstance()
        .saveConversation(getContext(this), msgCopy)
        .then((path: string) => {
          if (path.length > 0) {
            this.log.info('ChatPage', `Conversation saved: ${path}`);
          }
        })
        .catch(() => { /* ignore */ });
      // Auto-extract memories from conversation (fire-and-forget)
      this.autoExtractMemoriesFromMessages(msgCopy);
    }
    this.messages = [];
    this.queuedMessages = [];
    this.saveSessionQueue();
    this.saveHistory();
  }

  // ---- TTS Auto-read ----

  /** Load the TTS auto-read preference from gateway settings. */
  private async loadTtsAutoReadSetting(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let store = await preferences.getPreferences(ctx, Constants.PREFS_GATEWAY);
      this.ttsAutoRead = (await store.get('ttsAutoRead', false)) as boolean;
      this.log.info('ChatPage', `TTS auto-read loaded: ${this.ttsAutoRead}`);
    } catch {
      this.ttsAutoRead = false;
    }
  }

  /** Save the TTS auto-read preference (called when toggled from chat header). */
  private async saveTtsAutoReadSetting(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let store = await preferences.getPreferences(ctx, Constants.PREFS_GATEWAY);
      await store.put('ttsAutoRead', this.ttsAutoRead);
      await store.flush();
    } catch { /* ignore */ }
  }

  // ---- Auto Memory Inject ----

  private async loadAutoMemoryInjectSetting(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let store = await preferences.getPreferences(ctx, Constants.PREFS_GATEWAY);
      this.autoMemoryInject = (await store.get(Constants.KEY_AUTO_MEMORY_INJECT, Constants.DEFAULT_AUTO_MEMORY_INJECT)) as boolean;
      this.log.info('ChatPage', `Auto memory inject loaded: ${this.autoMemoryInject}`);
    } catch {
      this.autoMemoryInject = Constants.DEFAULT_AUTO_MEMORY_INJECT;
    }
  }

  /**
   * Search for relevant memories using vector search with keyword fallback.
   * Returns relevant memories for the given query, or all memories as final fallback.
   */
  private async searchRelevantMemories(ctx: common.UIAbilityContext, query: string): Promise<MemoryItem[]> {
    try {
      let apiKey = await this.memSvc.getEmbeddingApiKey(ctx);
      let results = await this.memSvc.vectorSearch(ctx, query, apiKey);
      if (results.length > 0) {
        this.log.info('ChatPage', `Auto-memory: vector search found ${results.length} relevant memories`);
        return results;
      }
      // Fallback to keyword search
      let kwResults = await this.memSvc.search(ctx, query);
      if (kwResults.length > 0) {
        let sliced = kwResults.slice(0, Constants.VECTOR_SEARCH_TOP_K);
        this.log.info('ChatPage', `Auto-memory: keyword fallback found ${sliced.length} relevant memories`);
        return sliced;
      }
    } catch (e) {
      this.log.warn('ChatPage', `Auto-memory search failed: ${(e as Error).message ?? String(e)}`);
    }
    // Final fallback: all memories
    this.log.info('ChatPage', 'Auto-memory: falling back to all memories');
    return await this.memSvc.loadAll(ctx);
  }

  /**
   * Search relevant memories with a timeout.
   * If the search takes too long, falls back to loading all memories.
   */
  private searchRelevantMemoriesWithTimeout(ctx: common.UIAbilityContext, query: string): Promise<MemoryItem[]> {
    return new Promise<MemoryItem[]>((resolve) => {
      let resolved = false;
      let timer = setTimeout(() => {
        if (!resolved) {
          resolved = true;
          this.log.info('ChatPage', 'Auto-memory: search timed out, using all memories');
          this.memSvc.loadAll(ctx).then((items: MemoryItem[]) => { resolve(items); }).catch(() => { resolve([]); });
        }
      }, Constants.AUTO_MEMORY_SEARCH_TIMEOUT_MS);

      this.searchRelevantMemories(ctx, query).then((items: MemoryItem[]) => {
        if (!resolved) {
          resolved = true;
          clearTimeout(timer);
          resolve(items);
        }
      }).catch(() => {
        if (!resolved) {
          resolved = true;
          clearTimeout(timer);
          this.memSvc.loadAll(ctx).then((items: MemoryItem[]) => { resolve(items); }).catch(() => { resolve([]); });
        }
      });
    });
  }

  /**
   * Auto-read the AI response text using local TTS.
   * Called after the gateway or local AI response is finalized.
   * Strips MEDIA: references and other non-text content before reading.
   */
  // ---- Auto-enrich: append GPS location for weather/location queries ----

  private async enrichWithLocation(text: string): Promise<string> {
    let lower = text.toLowerCase();
    let weatherKw = ['天气', '气温', '温度', '下雨', '下雪', '刮风', '空气质量', 'weather', 'temperature', 'forecast', 'rain', 'snow'];
    let needsLocation = false;
    for (let kw of weatherKw) {
      if (lower.includes(kw)) {
        needsLocation = true;
        break;
      }
    }
    if (!needsLocation) return text;

    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let atManager = abilityAccessCtrl.createAtManager();
      await atManager.requestPermissionsFromUser(ctx, [
        'ohos.permission.APPROXIMATELY_LOCATION',
        'ohos.permission.LOCATION'
      ]);
      let locRequest: geoLocationManager.SingleLocationRequest = {
        locatingPriority: geoLocationManager.LocatingPriority.PRIORITY_LOCATING_SPEED,
        locatingTimeoutMs: 5000,
      };
      let loc = await geoLocationManager.getCurrentLocation(locRequest);
      let locInfo = `(User location: lat=${loc.latitude.toFixed(4)}, lon=${loc.longitude.toFixed(4)})`;
      this.log.info('ChatPage', `enrichWithLocation: ${locInfo}`);
      return text + ' ' + locInfo;
    } catch (e) {
      this.log.warn('ChatPage', `enrichWithLocation failed: ${(e as Error).message ?? ''}`);
      return text;
    }
  }

  private autoReadAloud(text: string): void {
    if (!this.ttsAutoRead) return;
    if (text.length === 0) return;

    // Reload setting in case user changed it mid-session
    this.loadTtsAutoReadSetting();

    // Strip MEDIA: references, emoji indicators, and very short error messages
    let cleanText = text
      .replace(/MEDIA:\/[^\s\n]+/gi, '')
      .replace(/[\uD83D\uDD0A\uD83D\uDD14]\s*/g, '') // strip 🔊 🔔
      .replace(/Gateway error:.*/gi, '')
      .replace(/Gateway:.*/gi, '')
      .trim();

    // Strip punctuation, markdown, and symbols so TTS doesn't read them aloud
    cleanText = cleanText
      .replace(/[*#_~`>|]/g, '')                        // markdown formatting
      .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')          // [text](url) → text
      .replace(/https?:\/\/\S+/g, '')                    // URLs
      .replace(/[，。！？、；：""''（）【】《》…—·•\-\.\!\?\,\;\:\"\'\(\)\[\]\{\}\/\\@\$%\^&\+=<>~`]/g, ' ')
      .replace(/\n+/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();

    if (cleanText.length < 3) return; // too short to read

    // Limit text length for TTS (avoid very long reads)
    let maxLen = 500;
    if (cleanText.length > maxLen) {
      cleanText = cleanText.substring(0, maxLen) + '...';
    }

    // Detect language for TTS
    let lang = 'zh-CN';
    // Simple heuristic: if more than 60% ASCII, use English
    let asciiCount = 0;
    for (let i = 0; i < Math.min(cleanText.length, 100); i++) {
      if (cleanText.charCodeAt(i) < 128) {
        asciiCount++;
      }
    }
    if (asciiCount > Math.min(cleanText.length, 100) * 0.6) {
      lang = 'en-US';
    }

    this.log.info('ChatPage', `autoReadAloud: lang=${lang} textLen=${cleanText.length} text="${cleanText.substring(0, 80)}"`);

    let runtime = NodeRuntime.getInstance();
    let speakParams = `{"text":${JSON.stringify(cleanText)},"lang":"${lang}"}`;
    this.ttsPlaying = true;
    runtime.speakLocal(speakParams).then(() => {
      this.log.info('ChatPage', 'TTS auto-read completed');
      this.ttsPlaying = false;
      if (this.ttsCompletionResolve) {
        this.ttsCompletionResolve();
        this.ttsCompletionResolve = undefined;
      }
    }).catch((err: Error) => {
      this.log.warn('ChatPage', `TTS auto-read failed: ${err.message ?? ''}`);
      this.ttsPlaying = false;
      if (this.ttsCompletionResolve) {
        this.ttsCompletionResolve();
        this.ttsCompletionResolve = undefined;
      }
    });
  }

  // ---- Gateway memory integration ----

  /**
   * Auto-extract memory from gateway chat.
   * Extracts from the user's last message + looks for memory-save instructions
   * in the assistant's response. Also tries to sync to OpenClaw server.
   */
  private autoExtractMemoryFromGatewayChat(assistantText: string): void {
    // Find last user message
    let lastUserText = '';
    for (let i = this.messages.length - 1; i >= 0; i--) {
      if (this.messages[i].role === 'user') {
        lastUserText = this.messages[i].content;
        break;
      }
    }

    // Fire-and-forget: extract memories in background
    let ctx: common.UIAbilityContext;
    try {
      ctx = getContext(this) as common.UIAbilityContext;
    } catch {
      return;
    }

    // Auto-extract from user text (same as local AI mode)
    if (lastUserText.length > 0) {
      this.memSvc.autoExtract(ctx, lastUserText).catch(() => { /* ignore */ });
    }

    // Check if assistant response contains memory-save patterns
    // e.g., "I'll remember that...", "[Memory saved: ...]", etc.
    this.extractMemoryFromAssistantResponse(ctx, assistantText, lastUserText);
  }

  /**
   * Parse assistant response for memory-worthy content.
   * Detects patterns like:
   * - "[Memory saved: ...]" or "[已记住: ...]"
   * - "I'll remember that..." / "好的，我记住了..."
   * - Save_memory tool call results embedded in text
   */
  private extractMemoryFromAssistantResponse(ctx: common.UIAbilityContext, assistantText: string, userText: string): void {
    let memoryPatterns: RegExp[] = [
      /\[Memory saved:\s*(.{5,}?)\]/gi,
      /\[\u5df2\u8bb0\u4f4f:\s*(.{3,}?)\]/gi,    // [已记住: ...]
      /\[\u8bb0\u5fc6\u5df2\u4fdd\u5b58:\s*(.{3,}?)\]/gi, // [记忆已保存: ...]
    ];

    for (let re of memoryPatterns) {
      let match = re.exec(assistantText);
      while (match !== null && match[1]) {
        let content = match[1].trim();
        this.log.info('ChatPage', `Memory extracted from assistant: "${content.substring(0, 60)}"`);
        this.memSvc.add(ctx, 'fact', content, 0.8).then(() => {
          // Also try to sync to server if connected
          this.syncMemoryToServer('fact', content);
        }).catch(() => { /* ignore */ });
        match = re.exec(assistantText);
      }
    }

    // If the user explicitly asked to remember something, check the assistant acknowledged
    let rememberPatterns: RegExp[] = [
      /(?:\u8bb0\u4f4f|\u8bb0\u4e0b|\u5907\u5fd8)(.{3,80})/i,  // 记住/记下/备忘 + content
      /(?:remember|note down)\s+(?:that\s+)?(.{5,80})/i,
    ];
    let ackPatterns: RegExp[] = [
      /\u597d\u7684|\u5df2\u8bb0\u4f4f|\u6211\u8bb0\u4e0b\u4e86|\u8bb0\u5fc6\u5df2\u4fdd\u5b58/i, // 好的/已记住/我记下了/记忆已保存
      /i'?ll remember|noted|saved|got it/i,
    ];

    let shouldSave = false;
    for (let ackRe of ackPatterns) {
      if (ackRe.test(assistantText)) {
        shouldSave = true;
        break;
      }
    }

    if (shouldSave && userText.length > 0) {
      for (let re of rememberPatterns) {
        let match = re.exec(userText);
        if (match && match[1]) {
          let content = match[1].trim();
          if (content.length > 2) {
            this.log.info('ChatPage', `Memory extracted from user request: "${content.substring(0, 60)}"`);
            this.memSvc.add(ctx, 'fact', content, 0.9).then(() => {
              this.syncMemoryToServer('fact', content);
            }).catch(() => { /* ignore */ });
          }
        }
      }
    }
  }

  /** Try to sync a memory item to the OpenClaw server (fire-and-forget). */
  private syncMemoryToServer(memType: string, content: string): void {
    let runtime = NodeRuntime.getInstance();
    if (!runtime.isConnected) return;

    runtime.saveMemoryToServer(memType, content, 0.8).then((res) => {
      this.log.info('ChatPage', `Memory synced to server: ${res.substring(0, 100)}`);
    }).catch((err: Error) => {
      this.log.warn('ChatPage', `Memory sync to server failed: ${err.message ?? ''}`);
    });
  }

  /**
   * Fetch memories from the OpenClaw server and merge with local memory store.
   * Called when gateway connects or manually from UI.
   */
  async syncMemoriesFromServer(): Promise<void> {
    let runtime = NodeRuntime.getInstance();
    if (!runtime.isConnected) {
      this.log.warn('ChatPage', 'Cannot sync memories: gateway not connected');
      return;
    }

    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let resJson = await runtime.fetchMemories();
      if (resJson.length === 0) return;

      let res = JSON.parse(resJson) as Record<string, Object>;
      let items = res['items'] as Object[] | undefined;
      if (!items || !Array.isArray(items) || items.length === 0) {
        this.log.info('ChatPage', 'No memories from server');
        return;
      }

      let localItems = await this.memSvc.loadAll(ctx);
      let localContents = new Set<string>();
      for (let li of localItems) {
        localContents.add(li.content.toLowerCase().trim());
      }

      let addedCount = 0;
      for (let item of items) {
        let serverItem = item as Record<string, Object>;
        let content = String(serverItem['content'] ?? '');
        let memType = String(serverItem['type'] ?? serverItem['memType'] ?? 'fact');
        let importance = (serverItem['importance'] as number) ?? 0.5;

        if (content.length > 0 && !localContents.has(content.toLowerCase().trim())) {
          await this.memSvc.add(ctx, memType, content, importance);
          localContents.add(content.toLowerCase().trim());
          addedCount++;
        }
      }

      this.log.info('ChatPage', `Memory sync from server: ${items.length} server items, ${addedCount} new items merged`);
    } catch (err) {
      this.log.warn('ChatPage', `Memory sync from server failed: ${(err as Error).message ?? ''}`);
    }
  }

  // ---- Cron scheduled tasks ----

  private startCronTimer(): void {
    if (this.cronTimer !== -1) return;
    this.cronTimer = setInterval(() => {
      this.checkCronTasks();
    }, Constants.CRON_POLL_INTERVAL_MS);
    this.log.info('ChatPage', 'Cron timer started');
  }

  private startIdleSessionCheck(): void {
    if (this.idleCheckTimer !== -1) return;
    // Run immediately on start, then periodically
    this.closeIdleSessions();
    this.idleCheckTimer = setInterval(() => {
      this.closeIdleSessions();
    }, Constants.SESSION_IDLE_CHECK_INTERVAL_MS);
    this.log.info('ChatPage', `Idle session check timer started (interval: ${Constants.SESSION_IDLE_CHECK_INTERVAL_MS / 60000}min)`);
  }

  private async closeIdleSessions(): Promise<void> {
    try {
      // Read user-configured idle timeout
      let ctx = getContext(this) as common.UIAbilityContext;
      let store = await preferences.getPreferences(ctx, Constants.PREFS_GATEWAY);
      let idleMinutes = (await store.get(Constants.KEY_IDLE_TIMEOUT_MINUTES, Constants.DEFAULT_IDLE_TIMEOUT_MINUTES)) as number;
      let idleTimeoutMs = idleMinutes * 60 * 1000;

      const closedCount = await this.sessionSvc.closeIdleSessions(this.currentSessionId, idleTimeoutMs);
      if (closedCount > 0) {
        this.sessions = this.sessionSvc.getSessions();
        this.log.info('ChatPage', `Auto-closed ${closedCount} idle sessions (timeout: ${idleMinutes}min)`);
      }
    } catch (err) {
      this.log.error('ChatPage', `Failed to close idle sessions: ${(err as Error).message ?? ''}`);
    }
  }

  private async checkCronTasks(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let store = await preferences.getPreferences(ctx, Constants.PREFS_CRON);
      let raw = (await store.get('tasks', '[]')) as string;
      let tasks = JSON.parse(raw) as CronTask[];
      let now = Date.now();
      let modified = false;

      for (let task of tasks) {
        if (!task.enabled) continue;
        if (task.nextRunTime <= now) {
          this.log.info('ChatPage', `Cron task due: id=${task.id} prompt="${task.prompt.substring(0, 60)}"`);
          await this.executeCronTask(task);
          task.lastRunTime = now;
          if (task.oneShot) {
            task.enabled = false;
          } else {
            task.nextRunTime = now + task.intervalMs;
          }
          modified = true;
        }
      }

      if (modified) {
        await store.put('tasks', JSON.stringify(tasks));
        await store.flush();
      }
    } catch (e) {
      this.log.error('ChatPage', `checkCronTasks error: ${(e as Error).message ?? ''}`);
    }
  }

  private async executeCronTask(task: CronTask): Promise<void> {
    // Add system message showing the cron task is executing
    let sysMsg = new ChatMessage('assistant', `\u23F0 ${I18n.t('cron.executing')}\n> ${task.prompt}`);
    this.messages.push(sysMsg);
    this.scrollToEnd();

    // Execute the prompt as if user typed it
    let userMsg = new ChatMessage('user', task.prompt);
    this.messages.push(userMsg);
    this.scrollToEnd();

    this.isLoading = true;
    this.loadingSessionId = this.currentSessionId;
    this.startDotAnimation();

    if (this.gwConnected) {
      await this.sendViaGateway(task.prompt);
    } else {
      await this.sendViaLocalAI(task.prompt);
    }

    this.scrollToEnd();
    this.saveHistory();

    // Process queued messages
    await this.processQueue();
  }

  // ---- Talk Mode (continuous conversation) ----

  private async startTalkMode(): Promise<void> {
    if (this.talkModeActive) return;
    this.isTalkMode = true;
    this.talkModeActive = true;
    this.talkStatus = I18n.t('chat.talkModeOn');
    this.log.info('ChatPage', 'Talk mode started');

    let sysMsg = new ChatMessage('assistant', '\uD83D\uDDE3 ' + I18n.t('chat.talkModeOn'));
    this.messages.push(sysMsg);
    this.scrollToEnd();

    await this.talkCycle();
  }

  private updateWaveBars(level: number): void {
    let bars: number[] = [0, 0, 0, 0, 0, 0, 0];
    bars[3] = level;
    bars[2] = level * 0.7 + this.waveBars[3] * 0.3;
    bars[4] = level * 0.7 + this.waveBars[3] * 0.3;
    bars[1] = level * 0.4 + this.waveBars[2] * 0.3;
    bars[5] = level * 0.4 + this.waveBars[4] * 0.3;
    bars[0] = level * 0.2 + this.waveBars[1] * 0.3;
    bars[6] = level * 0.2 + this.waveBars[5] * 0.3;
    this.waveBars = bars;
  }

  private stopTalkMode(): void {
    if (!this.talkModeActive && !this.isTalkMode) return;
    this.talkModeActive = false;
    this.isTalkMode = false;
    this.talkStatus = '';
    this.currentMood = '';
    this.asrReading = false;
    this.showWaveform = false;
    this.waveBars = [0, 0, 0, 0, 0, 0, 0];
    this.ttsPlaying = false;

    // Stop any in-progress TTS
    NodeRuntime.getInstance().stopSpeaker().catch(() => { /* ignore */ });

    // Resolve any pending TTS completion
    if (this.ttsCompletionResolve) {
      this.ttsCompletionResolve();
      this.ttsCompletionResolve = undefined;
    }

    // Cleanup audio resources
    this.cleanupAsr().catch(() => { /* ignore */ });

    this.log.info('ChatPage', 'Talk mode stopped');
  }

  private async talkCycle(): Promise<void> {
    let pendingWav = '';
    while (this.talkModeActive) {
      // Step 1: Record (or use audio from TTS interruption)
      let wavPath: string;
      if (pendingWav.length > 0) {
        wavPath = pendingWav;
        pendingWav = '';
      } else {
        this.talkStatus = I18n.t('chat.talkListening');
        wavPath = await this.talkRecord();
      }

      if (!this.talkModeActive) break;

      if (wavPath.length === 0) {
        continue;
      }

      // Step 2: ASR (hybrid: local + cloud based on mode setting)
      // talkStatus is updated inside recognizeSpeech → updateAsrStatus to show ASR source
      let recognizedText = await this.recognizeSpeech(wavPath, this.lastPcmBuffers);

      // Clean up the WAV file after ASR
      try { fileIo.unlinkSync(wavPath); } catch { /* ignore */ }

      if (!this.talkModeActive) break;

      if (recognizedText.length === 0) {
        // ASR returned empty — check for humming (sustained audio + no text)
        let hummingCheck = detectMood(this.lastPcmBuffers, '');
        if (hummingCheck.mood === 'humming') {
          this.currentMood = hummingCheck.emoji + ' ' + hummingCheck.label;
          this.log.info('ChatPage', `Mood detected (no text): ${hummingCheck.mood}`);
        }
        continue;
      }

      // Step 2.5: Detect mood from voice + text
      let moodResult: MoodResult = detectMood(this.lastPcmBuffers, recognizedText);
      this.currentMood = moodResult.emoji + ' ' + moodResult.label;
      this.log.info('ChatPage', `Mood detected: ${moodResult.mood} (${moodResult.confidence.toFixed(2)})`);

      // Step 3: Add user message + send to AI
      let userMsg = new ChatMessage('user', recognizedText);
      userMsg.audioPath = wavPath;
      this.messages.push(userMsg);
      this.scrollToEnd();

      this.talkStatus = I18n.t('chat.talkThinking');
      this.isLoading = true;
      this.loadingSessionId = this.currentSessionId;
      this.startDotAnimation();

      let enrichedText = await this.enrichWithLocation(recognizedText);
      // Append mood context for LLM
      if (moodResult.mood !== 'neutral') {
        enrichedText = enrichedText + '\n[' + '\u7528\u6237\u5F53\u524D\u8BED\u6C14/\u60C5\u7EEA: ' + moodResult.label + ']';
      }
      if (this.gwConnected) {
        await this.sendViaGateway(enrichedText);
      } else {
        await this.sendViaLocalAI(enrichedText);
      }

      this.scrollToEnd();
      this.saveHistory();

      // Process queued messages before continuing talk mode
      await this.processQueue();

      if (!this.talkModeActive) break;

      // Step 4: TTS with voice-interrupt detection
      if (this.ttsAutoRead) {
        // Wait briefly for TTS to start (autoReadAloud is async)
        if (!this.ttsPlaying) {
          await new Promise<void>((r) => { setTimeout(r, 300); });
        }
        if (this.ttsPlaying) {
          this.talkStatus = I18n.t('chat.talkSpeaking');
          let interruptWav = await this.listenDuringTts();
          if (!this.talkModeActive) break;
          if (interruptWav.length > 0) {
            pendingWav = interruptWav;
            continue; // skip pause, go directly to ASR
          }
        } else {
          // TTS didn't start — wait for completion in case it's delayed
          await this.waitForTtsCompletion();
        }
      }

      if (!this.talkModeActive) break;

      // Pause before next recording to let speaker audio die down (avoid mic picking up TTS echo)
      await new Promise<void>((resolve) => { setTimeout(resolve, 1000); });
    }
  }

  /**
   * Record audio with silence detection for Talk Mode.
   * Returns WAV path if speech detected, empty string if silence timeout.
   * - RMS > 1500 = speech detected (higher threshold to avoid noise)
   * - After speech: 1.5s silence stops recording
   * - No speech for 8s: returns empty (silence timeout)
   */
  private async talkRecord(): Promise<string> {
    this.pcmBuffers = [];

    try {
      await this.cleanupAsr();

      let ctx = getContext(this) as common.UIAbilityContext;
      let atManager = abilityAccessCtrl.createAtManager();
      let permResult = await atManager.requestPermissionsFromUser(ctx, ['ohos.permission.MICROPHONE']);
      if (permResult.authResults[0] !== 0) {
        this.log.warn('ChatPage', 'Talk mode: mic permission denied');
        return '';
      }

      let capturerOptions: audio.AudioCapturerOptions = {
        streamInfo: {
          samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
          channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
        },
        capturerInfo: {
          source: audio.SourceType.SOURCE_TYPE_VOICE_RECOGNITION,
          capturerFlags: 0
        }
      };
      this.audioCapturer = await audio.createAudioCapturer(capturerOptions);
      await this.audioCapturer.start();
      this.isRecording = true;
      this.showWaveform = true;

      let bufSize = await this.audioCapturer.getBufferSize();
      let speechDetected = false;
      let silenceStart = 0;
      let recordStart = Date.now();
      let rmsThreshold = 1500;
      let silenceTimeoutMs = 1500;  // 1.5s silence after speech

      while (this.talkModeActive && this.audioCapturer) {
        let buf: ArrayBuffer;
        try {
          buf = await this.audioCapturer.read(bufSize, true);
        } catch {
          break;
        }
        if (buf.byteLength === 0) continue;
        this.pcmBuffers.push(buf.slice(0));

        // Calculate RMS energy
        let samples = new Int16Array(buf);
        let sumSq = 0;
        for (let i = 0; i < samples.length; i++) {
          sumSq += samples[i] * samples[i];
        }
        let rms = Math.sqrt(sumSq / samples.length);

        // Update waveform visualization
        let normalized = Math.min(1.0, rms / 8000);
        this.updateWaveBars(normalized);

        if (rms > rmsThreshold) {
          speechDetected = true;
          silenceStart = 0; // reset silence timer
        } else if (speechDetected) {
          // Silence after speech
          if (silenceStart === 0) {
            silenceStart = Date.now();
          } else if (Date.now() - silenceStart > silenceTimeoutMs) {
            this.log.info('ChatPage', 'Talk mode: silence after speech, stopping');
            break;
          }
        }

        // No speech: just keep listening (phone call mode — no timeout)
        // Recording continues until user taps hang-up
      }

      this.isRecording = false;
      this.showWaveform = false;
      this.waveBars = [0, 0, 0, 0, 0, 0, 0];
      if (this.audioCapturer) {
        try { await this.audioCapturer.stop(); } catch { /* ignore */ }
      }

      this.lastPcmBuffers = this.pcmBuffers.slice();
      let wavPath = this.saveWavFile(this.pcmBuffers);
      this.pcmBuffers = [];
      await this.cleanupAsr();

      if (wavPath.length === 0) return '';

      // Check minimum size — need at least ~1.5s of audio (48044 bytes at 16kHz 16bit mono)
      try {
        let stat = fileIo.statSync(wavPath);
        if (stat.size < 48044) {
          this.log.info('ChatPage', `Talk mode: WAV too short (${stat.size} bytes), discarding`);
          try { fileIo.unlinkSync(wavPath); } catch { /* ignore */ }
          return '';
        }
      } catch { /* ignore */ }

      return wavPath;

    } catch (err) {
      this.log.error('ChatPage', `talkRecord error: ${(err as Error).message ?? ''}`);
      this.isRecording = false;
      this.showWaveform = false;
      this.waveBars = [0, 0, 0, 0, 0, 0, 0];
      await this.cleanupAsr();
      return '';
    }
  }

  /**
   * Listen on mic during TTS playback. If user speaks (voice interrupt),
   * stop TTS, continue recording until silence, return WAV path.
   * If TTS finishes naturally, return empty string.
   * Uses higher RMS threshold (3000) to filter out TTS speaker echo.
   */
  private async listenDuringTts(): Promise<string> {
    try {
      await this.cleanupAsr();

      let ctx = getContext(this) as common.UIAbilityContext;
      let atManager = abilityAccessCtrl.createAtManager();
      let permResult = await atManager.requestPermissionsFromUser(ctx, ['ohos.permission.MICROPHONE']);
      if (permResult.authResults[0] !== 0) return '';

      let capturerOptions: audio.AudioCapturerOptions = {
        streamInfo: {
          samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
          channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
        },
        capturerInfo: {
          source: audio.SourceType.SOURCE_TYPE_VOICE_RECOGNITION,
          capturerFlags: 0
        }
      };
      this.audioCapturer = await audio.createAudioCapturer(capturerOptions);
      await this.audioCapturer.start();

      let bufSize = await this.audioCapturer.getBufferSize();
      let speechDetected = false;
      let silenceStart = 0;
      let interruptThreshold = 3000; // higher than normal (1500) to filter TTS echo
      let silenceTimeoutMs = 1500;
      this.pcmBuffers = [];

      // Phase 1: Monitor for voice while TTS plays
      while (this.talkModeActive && this.audioCapturer) {
        let buf: ArrayBuffer;
        try {
          buf = await this.audioCapturer.read(bufSize, true);
        } catch { break; }
        if (buf.byteLength === 0) continue;

        let samples = new Int16Array(buf);
        let sumSq = 0;
        for (let i = 0; i < samples.length; i++) {
          sumSq += samples[i] * samples[i];
        }
        let rms = Math.sqrt(sumSq / samples.length);

        if (!speechDetected && rms > interruptThreshold) {
          // Voice interrupt detected — stop TTS
          this.log.info('ChatPage', `TTS interrupted by voice (RMS=${rms.toFixed(0)})`);
          speechDetected = true;
          NodeRuntime.getInstance().stopSpeaker().catch(() => {});
          this.ttsPlaying = false;
          if (this.ttsCompletionResolve) {
            this.ttsCompletionResolve();
            this.ttsCompletionResolve = undefined;
          }
          this.talkStatus = I18n.t('chat.talkListening');
          this.showWaveform = true;
        }

        if (speechDetected) {
          // Recording phase — collect audio until silence
          this.pcmBuffers.push(buf.slice(0));
          let normalized = Math.min(1.0, rms / 8000);
          this.updateWaveBars(normalized);

          if (rms > 1500) {
            silenceStart = 0;
          } else {
            if (silenceStart === 0) {
              silenceStart = Date.now();
            } else if (Date.now() - silenceStart > silenceTimeoutMs) {
              this.log.info('ChatPage', 'TTS interrupt: silence after speech, stopping');
              break;
            }
          }
        }

        // TTS finished naturally — no interrupt
        if (!speechDetected && !this.ttsPlaying) {
          this.log.info('ChatPage', 'TTS finished, no voice interrupt');
          break;
        }
      }

      // Cleanup mic
      this.showWaveform = false;
      this.waveBars = [0, 0, 0, 0, 0, 0, 0];
      if (this.audioCapturer) {
        try { await this.audioCapturer.stop(); } catch {}
      }

      if (!speechDetected || this.pcmBuffers.length === 0) {
        this.pcmBuffers = [];
        await this.cleanupAsr();
        return '';
      }

      // Save interrupt audio
      this.lastPcmBuffers = this.pcmBuffers.slice();
      let wavPath = this.saveWavFile(this.pcmBuffers);
      this.pcmBuffers = [];
      await this.cleanupAsr();

      if (wavPath.length === 0) return '';

      // Check minimum size
      try {
        let stat = fileIo.statSync(wavPath);
        if (stat.size < 48044) {
          try { fileIo.unlinkSync(wavPath); } catch {}
          return '';
        }
      } catch {}

      return wavPath;

    } catch (err) {
      this.log.error('ChatPage', `listenDuringTts error: ${(err as Error).message ?? ''}`);
      this.showWaveform = false;
      this.waveBars = [0, 0, 0, 0, 0, 0, 0];
      await this.cleanupAsr();
      return '';
    }
  }

  /**
   * Wait for TTS playback to complete.
   * The autoReadAloud method resolves ttsCompletionResolve when done.
   * Times out after 30 seconds.
   */
  private waitForTtsCompletion(): Promise<void> {
    return new Promise<void>((resolve) => {
      this.ttsCompletionResolve = resolve;
      // Timeout safety
      setTimeout(() => {
        if (this.ttsCompletionResolve === resolve) {
          this.ttsCompletionResolve = undefined;
          resolve();
        }
      }, 30000);
    });
  }
}

interface MemoryExtractItem {
  type: string;
  content: string;
}

interface SavedMsg {
  role: string;
  content: string;
  timestamp: number;
  isToolCall: boolean;
  toolName?: string;
  toolInput?: string;
  toolOutput?: string;
  imagePath?: string;
  audioPath?: string;
}
