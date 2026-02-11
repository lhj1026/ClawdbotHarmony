import { preferences } from '@kit.ArkData';
import { common, abilityAccessCtrl } from '@kit.AbilityKit';
import { MessageBubble } from '../components/MessageBubble';
import { ChatMessage, SettingsData, MemoryItem } from '../model/Models';
import { AIService, AIResult } from '../service/AIService';
import { MemoryService } from '../service/MemoryService';
import { getEnabledToolSchemas, getSkillSystemPrompt, getDefaultSkills } from '../service/SkillData';
import { Constants } from '../common/Constants';
import { NodeRuntime } from '../service/gateway/NodeRuntime';
import { ConnectionState, GatewayChatEvent } from '../service/gateway/GatewayModels';
import { NotificationInfo } from '../service/gateway/NotificationCapability';
import { LogService } from '../common/LogService';
import { I18n } from '../common/I18n';
import { speechRecognizer } from '@kit.CoreSpeechKit';
import { audio } from '@kit.AudioKit';

@Component
export struct ChatPage {
  @State messages: ChatMessage[] = [];
  @State inputText: string = '';
  @State isLoading: boolean = false;
  @State gwConnected: boolean = false;
  @State @Watch('onLangChange') lang: string = 'zh';
  @State ttsAutoRead: boolean = false;
  @State dotPhase: number = 0;
  @State isRecording: boolean = false;
  private dotTimer: number = -1;
  private asrEngine: speechRecognizer.SpeechRecognitionEngine | undefined = undefined;
  private asrSessionId: string = '';
  private asrBaseText: string = '';
  private audioCapturer: audio.AudioCapturer | undefined = undefined;
  private asrReading: boolean = false;

  private scroller: Scroller = new Scroller();
  private ai: AIService = AIService.getInstance();
  private memSvc: MemoryService = MemoryService.getInstance();
  private log: LogService = LogService.getInstance();
  private gwListener: ((state: ConnectionState, text: string) => void) | undefined = undefined;
  private chatListener: ((event: GatewayChatEvent) => void) | undefined = undefined;
  private notifListener: ((info: NotificationInfo) => void) | undefined = undefined;
  private langListener: (() => void) | undefined = undefined;
  private mediaListener: ((type: string, path: string) => void) | undefined = undefined;
  // Track the current gateway chat run
  private gwRunId: string = '';
  private gwAssistantMsgId: string = '';
  private gwChatResolve: (() => void) | undefined = undefined;
  private gwEarlyFinish: boolean = false;
  private gwIdleTimer: number = -1; // auto-finish after no events for N seconds
  private gwReceivedDelta: boolean = false; // whether we got at least one delta with text
  private gwAccumulatedText: string = ''; // accumulated text from delta events

  aboutToAppear(): void {
    this.loadHistory();
    this.loadTtsAutoReadSetting();
    this.gwConnected = NodeRuntime.getInstance().isConnected;
    this.gwListener = (state: ConnectionState, _text: string) => {
      let wasConnected = this.gwConnected;
      this.gwConnected = (state === ConnectionState.Connected);
      // When gateway first connects, sync memories from server
      if (!wasConnected && this.gwConnected) {
        this.syncMemoriesFromServer().catch(() => { /* ignore */ });
      }
    };
    NodeRuntime.getInstance().addStateListener(this.gwListener);
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
    this.lang = I18n.lang;
    this.langListener = () => { this.lang = I18n.lang; };
    I18n.addListener(this.langListener);
  }

  aboutToDisappear(): void {
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
    if (this.langListener) {
      I18n.removeListener(this.langListener);
      this.langListener = undefined;
    }
    this.stopDotAnimation();
    this.asrReading = false;
    this.cleanupAsr();
  }

  onLangChange(): void {
    // triggers re-render
  }

  build() {
    Column() {
      // -- header --
      Row() {
        Text('C')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .textAlign(TextAlign.Center)
          .width(34)
          .height(34)
          .borderRadius(17)
          .backgroundColor('#D2691E')
          .margin({ right: 10 })
        Column() {
          Text(I18n.t('chat.title'))
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A1A')
          Row({ space: 6 }) {
            Text(this.isLoading ? I18n.t('chat.thinking') : I18n.t('chat.online'))
              .fontSize(12)
              .fontColor(this.isLoading ? '#FF9800' : '#4CAF50')
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
            }
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

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

      // -- message list --
      if (this.messages.length === 0) {
        this.EmptyState()
      } else {
        List({ scroller: this.scroller }) {
          ForEach(this.messages, (msg: ChatMessage) => {
            ListItem() {
              MessageBubble({ message: msg })
            }
          }, (msg: ChatMessage): string => msg.id)

          // loading indicator — animated dots while waiting for response
          if (this.isLoading) {
            ListItem() {
              Row() {
                Text('C')
                  .fontSize(13)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Color.White)
                  .textAlign(TextAlign.Center)
                  .width(30)
                  .height(30)
                  .borderRadius(15)
                  .backgroundColor('#D2691E')
                  .margin({ right: 8 })
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
      Row({ space: 8 }) {
        // Mic button for voice input
        Button() {
          Text('\uD83C\uDFA4').fontSize(18)
        }
        .width(42)
        .height(42)
        .borderRadius(21)
        .backgroundColor(this.isRecording ? '#F44336' : '#F0F0F0')
        .onClick(() => { this.toggleRecording(); })

        TextInput({ text: this.inputText,
          placeholder: this.isRecording ? I18n.t('chat.recording') : I18n.t('chat.placeholder') })
          .layoutWeight(1)
          .height(42)
          .borderRadius(21)
          .backgroundColor('#F0F0F0')
          .padding({ left: 16, right: 16 })
          .fontSize(15)
          .onChange((v: string) => { this.inputText = v; })
          .onSubmit(() => { this.send(); })

        Button() {
          Text('\u27A4').fontSize(18).fontColor(Color.White)
        }
        .width(42)
        .height(42)
        .borderRadius(21)
        .backgroundColor(this.inputText.trim().length > 0 && !this.isLoading ? '#D2691E' : '#CCCCCC')
        .enabled(this.inputText.trim().length > 0 && !this.isLoading)
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
  }

  @Builder
  EmptyState() {
    Column({ space: 16 }) {
      Text('C')
        .fontSize(44)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .textAlign(TextAlign.Center)
        .width(88)
        .height(88)
        .borderRadius(44)
        .backgroundColor('#D2691E')

      Text('ClawdBot')
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

  private async send(): Promise<void> {
    let text = this.inputText.trim();
    if (text.length === 0 || this.isLoading) return;
    this.inputText = '';

    // user message
    let userMsg = new ChatMessage('user', text);
    this.messages.push(userMsg);
    this.scrollToEnd();

    this.isLoading = true;
    this.startDotAnimation();

    if (this.gwConnected) {
      // ---- Gateway path: send via operator session ----
      await this.sendViaGateway(text);
    } else {
      // ---- Local AI path: direct HTTP API ----
      await this.sendViaLocalAI(text);
    }

    this.scrollToEnd();
    this.saveHistory();
  }

  /** Send message through the gateway operator session (chat.send RPC). */
  private async sendViaGateway(text: string): Promise<void> {
    try {
      this.log.info('ChatPage', `Sending via gateway: ${text.substring(0, 100)}`);

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
      let runId = await runtime.sendChatMessage(text);
      this.log.info('ChatPage', `chat.send returned runId=${runId}, current gwRunId=${this.gwRunId}`);

      // Only set gwRunId from RPC if events haven't already set it
      if (this.gwRunId.length === 0) {
        this.gwRunId = runId;
        this.log.info('ChatPage', `Set gwRunId from RPC response: ${runId}`);
      } else {
        this.log.info('ChatPage', `gwRunId already adopted from events: ${this.gwRunId} (RPC returned: ${runId})`);
      }

      // Check if we already received a final/error event while awaiting the RPC
      if (this.gwEarlyFinish) {
        this.log.info('ChatPage', `Early finish detected for runId=${this.gwRunId}`);
        this.gwEarlyFinish = false;
        this.isLoading = false;
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

  /** Handle incoming gateway chat events (delta / final / error / aborted). */
  private handleGatewayChatEvent(event: GatewayChatEvent): void {
    // Extract text from content blocks
    let text = '';
    if (event.message && event.message.content) {
      for (let block of event.message.content) {
        if (block.type === 'text' && block.text) {
          text += block.text;
        }
      }
    }

    this.log.info('ChatPage', `gwChatEvent: state=${event.state} runId=${event.runId} myRunId=${this.gwRunId} msgId=${this.gwAssistantMsgId} textLen=${text.length} text(80)="${text.substring(0, 80)}"`);

    // Accept events if:
    // 1. We have a pending assistant message (gwAssistantMsgId is set)
    // 2. AND either: runId matches, OR we haven't locked to a runId yet, OR
    //    the event carries actual text (agent events may use a different server-generated runId)
    let isWaiting = this.gwAssistantMsgId.length > 0;
    let runIdMatch = this.gwRunId.length === 0 || event.runId === this.gwRunId;

    if (!isWaiting) {
      // Not waiting for any response — ignore
      this.log.info('ChatPage', `Ignoring chat event: not waiting for response`);
      return;
    }

    if (!runIdMatch) {
      // RunId doesn't match — but if we got an empty final from chat.send's runId,
      // the real response comes via a different server-side runId (agent stream).
      // Accept it if we have no accumulated text yet (the real response hasn't started).
      if (this.gwAccumulatedText.length === 0 && text.length > 0) {
        this.log.info('ChatPage', `Accepting agent event with different runId (no text yet): event.runId=${event.runId} gwRunId=${this.gwRunId}`);
        this.gwRunId = event.runId; // Switch to tracking this runId
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
      // Final message: if final event has text, it might be:
      // 1. The complete accumulated text (use it directly)
      // 2. A last delta chunk (accumulate it)
      // We check: if final text is longer than our accumulated text, use it directly.
      // Otherwise, accumulate it and use the accumulated text.
      if (text.length > 0) {
        if (text.length > this.gwAccumulatedText.length) {
          // Final text is likely the complete response
          this.gwAccumulatedText = text;
        } else {
          // Final text is a last chunk — accumulate
          this.gwAccumulatedText += text;
        }
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
            this.messages[idx].content = 'No response received';
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

    this.doCleanupGatewayChat();
  }

  /** Actually reset all gateway chat state */
  private doCleanupGatewayChat(): void {
    this.isLoading = false;
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
      let memItems = await this.memSvc.loadAll(ctx);
      let skills = getDefaultSkills();

      let systemPrompt = this.buildSystemPrompt(memItems, skills);
      let tools = getEnabledToolSchemas(skills);

      let result: AIResult = await this.ai.chat(this.messages, settings, systemPrompt, tools, ctx);

      if (result.error.length > 0) {
        this.messages.push(new ChatMessage('assistant', result.error));
      } else {
        for (let msg of result.messages) {
          this.messages.push(msg);
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
    this.stopDotAnimation();
  }

  // ---- Voice input (speech-to-text) ----

  private toggleRecording(): void {
    if (this.isRecording) {
      this.stopRecording();
    } else {
      this.startRecording();
    }
  }

  private asrDebug(text: string): void {
    this.messages.push(new ChatMessage('assistant', '[ASR] ' + text));
    this.scrollToEnd();
  }

  private async startRecording(): Promise<void> {
    this.asrBaseText = this.inputText;
    this.asrDebug('Starting...');

    try {
      // Clean up previous
      await this.cleanupAsr();

      // 1. Request microphone permission at runtime
      let ctx = getContext(this) as common.UIAbilityContext;
      let atManager = abilityAccessCtrl.createAtManager();
      let permResult = await atManager.requestPermissionsFromUser(ctx, ['ohos.permission.MICROPHONE']);
      if (permResult.authResults[0] !== 0) {
        this.asrDebug('Mic permission denied');
        this.isRecording = false;
        return;
      }

      // 2. Create AudioCapturer FIRST (before ASR grabs mic)
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
      this.asrDebug('Mic captured');

      // 2. Create ASR engine
      let initParams: speechRecognizer.CreateEngineParams = {
        language: 'zh-CN',
        online: 1,
        extraParams: { locate: 'CN', recognizerMode: 'short' }
      };

      try {
        this.asrEngine = await speechRecognizer.createEngine(initParams);
      } catch (onlineErr) {
        this.asrDebug('Online failed, trying offline...');
        let offlineParams: speechRecognizer.CreateEngineParams = {
          language: 'zh-CN',
          online: 0,
          extraParams: { locate: 'CN', recognizerMode: 'short' }
        };
        this.asrEngine = await speechRecognizer.createEngine(offlineParams);
      }

      this.asrSessionId = 'asr_' + Date.now().toString();
      this.setupAsrListener();

      // 3. Start ASR listening (write mode — we feed audio from capturer)
      let recognizerParams: speechRecognizer.StartParams = {
        sessionId: this.asrSessionId,
        audioInfo: {
          audioType: 'pcm',
          sampleRate: 16000,
          soundChannel: 1,
          sampleBit: 16
        },
        extraParams: { locate: 'CN', recognizerMode: 'short' }
      };
      this.asrEngine.startListening(recognizerParams);

      this.isRecording = true;
      this.asrReading = true;
      this.asrDebug('Recording...');

      // 4. Read audio data loop and feed to ASR engine
      this.readAudioLoop();

    } catch (err) {
      let msg = (err as Error).message ?? String(err);
      this.asrDebug('FAILED: ' + msg);
      this.isRecording = false;
      await this.cleanupAsr();
    }
  }

  private async readAudioLoop(): Promise<void> {
    if (!this.audioCapturer || !this.asrEngine) return;
    try {
      let bufSize = await this.audioCapturer.getBufferSize();
      while (this.asrReading && this.audioCapturer && this.asrEngine) {
        let buf: ArrayBuffer = await this.audioCapturer.read(bufSize, true);
        if (buf.byteLength > 0 && this.asrEngine && this.asrSessionId.length > 0) {
          let uint8 = new Uint8Array(buf);
          this.asrEngine.writeAudio(this.asrSessionId, uint8);
        }
      }
    } catch (err) {
      // Reading stopped (expected when stopRecording is called)
      this.asrDebug('Audio read ended: ' + ((err as Error).message ?? ''));
    }
  }

  private setupAsrListener(): void {
    if (!this.asrEngine) return;
    let page = this;
    let listener: speechRecognizer.RecognitionListener = {
      onStart(sessionId: string, eventMessage: string): void {
        page.asrDebug('onStart: ' + eventMessage);
      },
      onEvent(sessionId: string, eventCode: number, eventMessage: string): void {
        page.asrDebug('onEvent: code=' + eventCode);
      },
      onResult(sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void {
        page.asrDebug('text="' + result.result + '" final=' + result.isFinal);
        if (result.result.length > 0) {
          page.inputText = page.asrBaseText + result.result;
        }
      },
      onComplete(sessionId: string, eventMessage: string): void {
        page.asrDebug('onComplete');
        page.isRecording = false;
        page.asrReading = false;
        page.cleanupAsr();
      },
      onError(sessionId: string, errorCode: number, errorMessage: string): void {
        page.asrDebug('onError: code=' + errorCode + ' ' + errorMessage);
        page.isRecording = false;
        page.asrReading = false;
        page.cleanupAsr();
      }
    };
    this.asrEngine.setListener(listener);
  }

  private async stopRecording(): Promise<void> {
    this.asrDebug('Stopping...');
    this.asrReading = false;
    if (this.asrEngine && this.asrSessionId.length > 0) {
      try {
        this.asrEngine.finish(this.asrSessionId);
      } catch { /* ignore */ }
    }
    this.isRecording = false;
    // Give engine a moment to process final results before cleanup
    setTimeout((): void => {
      this.cleanupAsr();
    }, 500);
  }

  private async cleanupAsr(): Promise<void> {
    if (this.audioCapturer) {
      try { await this.audioCapturer.stop(); } catch { /* ignore */ }
      try { await this.audioCapturer.release(); } catch { /* ignore */ }
      this.audioCapturer = undefined;
    }
    if (this.asrEngine) {
      try { this.asrEngine.shutdown(); } catch { /* ignore */ }
      this.asrEngine = undefined;
    }
  }

  private buildSystemPrompt(memItems: MemoryItem[], skills: import('../model/Models').SkillItem[]): string {
    let now = new Date().toISOString();
    let base = `You are ClawdBot, a personal AI assistant running on HarmonyOS.
You are helpful, proactive, and capable of performing real actions through tools.
Current time: ${now}
Platform: HarmonyOS
`;
    let memBlock = this.memSvc.buildPromptBlock(memItems);
    let skillBlock = getSkillSystemPrompt(skills);
    return base + (memBlock ? '\n' + memBlock + '\n' : '') + (skillBlock ? '\n' + skillBlock : '');
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
        : provider === 'openai' ? Constants.DEFAULT_MODEL_OPENAI : 'llama3';
    let model = (await store.get(modelPref, defaultModel)) as string;
    // Use built-in keys as fallback
    if (apiKey.length === 0 && provider === 'openrouter' && Constants.OPENROUTER_DEFAULT_KEY.length > 0) {
      apiKey = Constants.OPENROUTER_DEFAULT_KEY;
    }
    if (apiKey.length === 0 && provider === 'openai' && Constants.SILICONFLOW_DEFAULT_KEY.length > 0) {
      apiKey = Constants.SILICONFLOW_DEFAULT_KEY;
    }
    return {
      provider: provider,
      apiKey: apiKey,
      model: model,
      baseUrl: baseUrl,
      temperature: (await store.get('temperature', 0.7)) as number,
    };
  }

  private scrollToEnd(): void {
    setTimeout(() => {
      this.scroller.scrollToIndex(Math.max(0, this.messages.length - 1));
    }, 100);
  }

  // ---- persistence (simple JSON in preferences) ----
  private async saveHistory(): Promise<void> {
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
    this.messages = [];
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

  /**
   * Auto-read the AI response text using local TTS.
   * Called after the gateway or local AI response is finalized.
   * Strips MEDIA: references and other non-text content before reading.
   */
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
    runtime.speakLocal(speakParams).then(() => {
      this.log.info('ChatPage', 'TTS auto-read completed');
    }).catch((err: Error) => {
      this.log.warn('ChatPage', `TTS auto-read failed: ${err.message ?? ''}`);
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
