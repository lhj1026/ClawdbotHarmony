import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { MessageBubble } from '../components/MessageBubble';
import { ChatMessage, SettingsData, MemoryItem } from '../model/Models';
import { AIService, AIResult } from '../service/AIService';
import { MemoryService } from '../service/MemoryService';
import { getEnabledToolSchemas, getSkillSystemPrompt, getDefaultSkills } from '../service/SkillData';
import { Constants } from '../common/Constants';
import { NodeRuntime } from '../service/gateway/NodeRuntime';
import { ConnectionState, GatewayChatEvent } from '../service/gateway/GatewayModels';
import { LogService } from '../common/LogService';
import { I18n } from '../common/I18n';

@Component
export struct ChatPage {
  @State messages: ChatMessage[] = [];
  @State inputText: string = '';
  @State isLoading: boolean = false;
  @State gwConnected: boolean = false;
  @State @Watch('onLangChange') lang: string = 'zh';

  private scroller: Scroller = new Scroller();
  private ai: AIService = AIService.getInstance();
  private memSvc: MemoryService = MemoryService.getInstance();
  private log: LogService = LogService.getInstance();
  private gwListener: ((state: ConnectionState, text: string) => void) | undefined = undefined;
  private chatListener: ((event: GatewayChatEvent) => void) | undefined = undefined;
  private langListener: (() => void) | undefined = undefined;
  // Track the current gateway chat run
  private gwRunId: string = '';
  private gwAssistantMsgId: string = '';
  private gwChatResolve: (() => void) | undefined = undefined;
  private gwEarlyFinish: boolean = false;

  aboutToAppear(): void {
    this.loadHistory();
    this.gwConnected = NodeRuntime.getInstance().isConnected;
    this.gwListener = (state: ConnectionState, _text: string) => {
      this.gwConnected = (state === ConnectionState.Connected);
    };
    NodeRuntime.getInstance().addStateListener(this.gwListener);
    // Register chat event listener for gateway mode
    this.chatListener = (event: GatewayChatEvent) => {
      this.handleGatewayChatEvent(event);
    };
    NodeRuntime.getInstance().addChatListener(this.chatListener);
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
    if (this.langListener) {
      I18n.removeListener(this.langListener);
      this.langListener = undefined;
    }
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
                Text('GW')
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

          // loading indicator
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
                Text('...')
                  .fontSize(24)
                  .fontColor('#999999')
                  .padding({ left: 12, right: 12, top: 4, bottom: 4 })
                  .backgroundColor('#F0F0F0')
                  .borderRadius(16)
              }
              .padding({ left: 12, right: 12, top: 4, bottom: 4 })
            }
          }
        }
        .layoutWeight(1)
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
      }

      // -- input bar --
      Row({ space: 8 }) {
        TextInput({ text: this.inputText, placeholder: I18n.t('chat.placeholder') })
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

      // Create placeholder assistant message BEFORE sending RPC
      // to avoid race condition where events arrive before gwRunId is set
      let assistantMsg = new ChatMessage('assistant', '');
      this.gwAssistantMsgId = assistantMsg.id;
      this.messages.push(assistantMsg);
      this.scrollToEnd();

      // sendChatMessage returns the idempotencyKey which is also the runId
      // used in chat events. Set gwRunId ASAP so events aren't missed.
      let runtime = NodeRuntime.getInstance();
      let runId = await runtime.sendChatMessage(text);
      this.gwRunId = runId;
      this.log.info('ChatPage', `Gateway chat started: runId=${runId}`);

      // Check if we already received a final/error event while awaiting
      // (unlikely but possible if server responds + errors instantly)
      if (this.gwEarlyFinish) {
        this.log.info('ChatPage', `Early finish detected for runId=${runId}`);
        this.gwEarlyFinish = false;
        this.isLoading = false;
        return;
      }

      // Wait for final/error event (up to 120 seconds)
      await this.waitForGatewayChatComplete(runId, 120000);

    } catch (e) {
      let errMsg = (e as Error).message ?? String(e);
      this.log.error('ChatPage', `Gateway chat error: ${errMsg}`);
      // Update placeholder or add new error message
      let idx = this.findGwAssistantIndex();
      if (idx >= 0) {
        let updated = new ChatMessage('assistant', `Gateway error: ${errMsg}`);
        updated.id = this.gwAssistantMsgId;
        this.messages[idx] = updated;
        this.messages = [...this.messages];
      } else {
        this.messages.push(new ChatMessage('assistant', `Gateway error: ${errMsg}`));
      }
      this.isLoading = false;
      this.gwRunId = '';
      this.gwAssistantMsgId = '';
    }
  }

  /** Wait for the gateway chat run to complete (final/error/aborted). */
  private waitForGatewayChatComplete(runId: string, timeoutMs: number): Promise<void> {
    return new Promise<void>((resolve) => {
      let timer = setTimeout(() => {
        this.log.warn('ChatPage', `Gateway chat timeout for runId=${runId}`);
        // If we still have an empty message, show timeout
        let idx = this.findGwAssistantIndex();
        if (idx >= 0 && this.messages[idx].content.length === 0) {
          this.messages[idx] = new ChatMessage('assistant', 'Gateway response timeout');
          this.messages = [...this.messages]; // force re-render
        }
        this.isLoading = false;
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
    this.log.info('ChatPage', `handleGatewayChatEvent: state=${event.state} runId=${event.runId} myRunId=${this.gwRunId} hasMsg=${event.message ? 'yes' : 'no'}`);
    // Only handle events for our current run
    if (event.runId !== this.gwRunId) {
      this.log.warn('ChatPage', `Ignoring chat event: event.runId=${event.runId} !== gwRunId=${this.gwRunId}`);
      return;
    }

    // Extract text from content blocks
    let text = '';
    if (event.message && event.message.content) {
      for (let block of event.message.content) {
        if (block.type === 'text' && block.text) {
          text += block.text;
        }
      }
    }

    if (event.state === 'delta') {
      // Streaming: update the placeholder assistant message
      let idx = this.findGwAssistantIndex();
      if (idx >= 0 && text.length > 0) {
        let updated = new ChatMessage('assistant', text);
        updated.id = this.gwAssistantMsgId;
        updated.timestamp = this.messages[idx].timestamp;
        this.messages[idx] = updated;
        this.messages = [...this.messages]; // trigger re-render
        this.scrollToEnd();
      }
    } else if (event.state === 'final') {
      // Final message: update with complete text
      let idx = this.findGwAssistantIndex();
      if (idx >= 0 && text.length > 0) {
        let updated = new ChatMessage('assistant', text);
        updated.id = this.gwAssistantMsgId;
        updated.timestamp = this.messages[idx].timestamp;
        this.messages[idx] = updated;
        this.messages = [...this.messages];
      }
      this.log.info('ChatPage', `Gateway chat final: textLen=${text.length} text=${text.substring(0, 200)}`);
      this.isLoading = false;
      this.gwRunId = '';
      this.gwAssistantMsgId = '';
      if (this.gwChatResolve) {
        this.gwChatResolve();
        this.gwChatResolve = undefined;
      } else {
        this.gwEarlyFinish = true;
      }
    } else if (event.state === 'error' || event.state === 'aborted') {
      let errText = event.errorMessage ?? (event.state === 'aborted' ? 'Response aborted' : 'Unknown error');
      let idx = this.findGwAssistantIndex();
      if (idx >= 0) {
        let updated = new ChatMessage('assistant', `Gateway: ${errText}`);
        updated.id = this.gwAssistantMsgId;
        this.messages[idx] = updated;
        this.messages = [...this.messages];
      }
      this.log.error('ChatPage', `Gateway chat ${event.state}: ${errText}`);
      this.isLoading = false;
      this.gwRunId = '';
      this.gwAssistantMsgId = '';
      if (this.gwChatResolve) {
        this.gwChatResolve();
        this.gwChatResolve = undefined;
      } else {
        this.gwEarlyFinish = true;
      }
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

      let result: AIResult = await this.ai.chat(this.messages, settings, systemPrompt, tools);

      if (result.error.length > 0) {
        this.messages.push(new ChatMessage('assistant', result.error));
      } else {
        for (let msg of result.messages) {
          this.messages.push(msg);
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
    return {
      provider: (await store.get('provider', 'anthropic')) as string,
      apiKey: (await store.get('apiKey', '')) as string,
      model: (await store.get('model', Constants.DEFAULT_MODEL_ANTHROPIC)) as string,
      baseUrl: (await store.get('baseUrl', '')) as string,
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
          toolOutput: m.toolOutput
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
        this.messages.push(msg);
      }
      this.scrollToEnd();
    } catch { /* first launch */ }
  }

  private clearMessages(): void {
    this.messages = [];
    this.saveHistory();
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
}
