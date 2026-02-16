import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { promptAction } from '@kit.ArkUI';
import { MemoryItem, SettingsData, ChatSession, ChatMessage } from '../model/Models';
import { MemoryService } from '../service/MemoryService';
import { AIService } from '../service/AIService';
import { SessionService } from '../service/SessionService';
import { NodeRuntime } from '../service/gateway/NodeRuntime';
import { Constants } from '../common/Constants';
import { LogService } from '../common/LogService';
import { I18n } from '../common/I18n';

interface MemoryExtractItem {
  type: string;
  content: string;
}

@Component
export struct MemoryPage {
  @Prop @Watch('onTabChange') isActive: boolean = false;
  @State entries: MemoryItem[] = [];
  @State filterType: string = 'all';
  @State showAddPanel: boolean = false;
  @State newContent: string = '';
  @State newType: string = 'fact';
  @State @Watch('onLangChange') lang: string = 'zh';
  @State isExtracting: boolean = false;
  @State isSyncing: boolean = false;
  // Chat history states
  @State viewMode: string = 'memory'; // 'memory' | 'history'
  @State allSessions: ChatSession[] = [];
  @State viewingSessionId: string = '';
  @State viewingMessages: ChatMessage[] = [];
  @State viewingSessionTitle: string = '';

  private memSvc: MemoryService = MemoryService.getInstance();
  private ai: AIService = AIService.getInstance();
  private sessionSvc: SessionService = SessionService.getInstance();
  private log: LogService = LogService.getInstance();
  private typeFilters: string[] = ['all', 'fact', 'preference', 'instruction'];
  private langListener: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    this.reload();
    this.lang = I18n.lang;
    this.langListener = () => { this.lang = I18n.lang; };
    I18n.addListener(this.langListener);
  }

  onTabChange(): void {
    if (this.isActive) {
      this.reload();
      if (this.viewMode === 'history') {
        this.loadSessions();
      }
    }
  }

  aboutToDisappear(): void {
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
      // Segmented tab control
      Row() {
        Text(I18n.t('memory.tabMemory'))
          .fontSize(15)
          .fontWeight(this.viewMode === 'memory' ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(this.viewMode === 'memory' ? Color.White : '#666666')
          .backgroundColor(this.viewMode === 'memory' ? '#D2691E' : Color.White)
          .padding({ left: 20, right: 20, top: 8, bottom: 8 })
          .borderRadius(20)
          .onClick(() => {
            this.viewMode = 'memory';
          })

        Text(I18n.t('memory.tabHistory'))
          .fontSize(15)
          .fontWeight(this.viewMode === 'history' ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(this.viewMode === 'history' ? Color.White : '#666666')
          .backgroundColor(this.viewMode === 'history' ? '#D2691E' : Color.White)
          .padding({ left: 20, right: 20, top: 8, bottom: 8 })
          .borderRadius(20)
          .onClick(() => {
            this.viewMode = 'history';
            this.loadSessions();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 12, bottom: 8 })
      .backgroundColor('#F5F5F5')

      if (this.viewMode === 'memory') {
        this.MemoryView()
      } else if (this.viewingSessionId.length > 0) {
        this.SessionDetailView()
      } else {
        this.HistoryListView()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }

  // ============ Memory View (original) ============
  @Builder
  MemoryView() {
    Column() {
      // header
      Row() {
        Text(I18n.t('memory.title'))
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1A1A1A')
          .layoutWeight(1)

        Button(I18n.t('memory.add'))
          .fontSize(13)
          .height(32)
          .backgroundColor('#D2691E')
          .fontColor(Color.White)
          .borderRadius(16)
          .onClick(() => { this.showAddPanel = !this.showAddPanel; })

        Text('\uD83D\uDDD1')
          .fontSize(18)
          .margin({ left: 12 })
          .onClick(() => { this.confirmClear(); })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 8, bottom: 8 })

      Text(I18n.t('memory.subtitle'))
        .fontSize(13)
        .fontColor('#666666')
        .padding({ left: 20, right: 20, bottom: 12 })
        .width('100%')

      // Action button: Sync from server (memory extraction now happens automatically on session switch)
      if (NodeRuntime.getInstance().isConnected) {
        Row({ space: 8 }) {
          Button(this.isSyncing ? I18n.t('memory.syncing') : I18n.t('memory.syncFromServer'))
            .fontSize(12)
            .height(32)
            .backgroundColor(this.isSyncing ? '#999999' : '#4CAF50')
            .fontColor(Color.White)
            .borderRadius(16)
            .enabled(!this.isSyncing)
            .onClick(() => { this.syncFromServer(); })
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 10 })
      }

      // add panel
      if (this.showAddPanel) {
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            ForEach(['fact', 'preference', 'instruction'], (t: string) => {
              Text(this.typeLabel(t))
                .fontSize(12)
                .fontColor(this.newType === t ? Color.White : '#666666')
                .backgroundColor(this.newType === t ? this.typeColor(t) : '#F0F0F0')
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .borderRadius(12)
                .onClick(() => { this.newType = t; })
            }, (t: string): string => t)
          }

          TextArea({ placeholder: I18n.t('memory.placeholder'), text: this.newContent })
            .height(80)
            .borderRadius(8)
            .backgroundColor('#F5F5F5')
            .fontSize(14)
            .onChange((v: string) => { this.newContent = v; })

          Button(I18n.t('memory.save'))
            .width('100%')
            .height(38)
            .backgroundColor('#D2691E')
            .fontColor(Color.White)
            .borderRadius(8)
            .onClick(() => { this.addEntry(); })
        }
        .padding(16)
        .margin({ left: 16, right: 16, bottom: 8 })
        .backgroundColor(Color.White)
        .borderRadius(12)
      }

      // filter
      Row({ space: 8 }) {
        ForEach(this.typeFilters, (t: string) => {
          Text(t === 'all' ? I18n.t('memory.all') : this.typeLabel(t))
            .fontSize(12)
            .fontColor(this.filterType === t ? Color.White : '#666666')
            .backgroundColor(this.filterType === t ? '#D2691E' : Color.White)
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .borderRadius(14)
            .borderWidth(this.filterType === t ? 0 : 1)
            .borderColor('#E0E0E0')
            .onClick(() => { this.filterType = t; })
        }, (t: string): string => 'f_' + t)
      }
      .padding({ left: 20, right: 20, bottom: 10 })

      Text(this.filtered().length + I18n.t('memory.entries'))
        .fontSize(12)
        .fontColor('#999999')
        .padding({ left: 20, bottom: 6 })
        .width('100%')

      // entries list
      if (this.filtered().length === 0) {
        Column({ space: 10 }) {
          Text('\uD83E\uDDE0').fontSize(48)
          Text(I18n.t('memory.empty')).fontSize(16).fontColor('#999999')
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .width('100%')
      } else {
        List({ space: 8 }) {
          ForEach(this.filtered(), (item: MemoryItem) => {
            ListItem() {
              this.EntryCard(item)
            }
            .padding({ left: 16, right: 16 })
          }, (item: MemoryItem): string => item.id)
        }
        .layoutWeight(1)
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  // ============ History List View ============
  @Builder
  HistoryListView() {
    Column() {
      Row() {
        Text(I18n.t('memory.tabHistory'))
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1A1A1A')
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 8, bottom: 8 })

      Text(this.allSessions.length + I18n.t('memory.entries'))
        .fontSize(12)
        .fontColor('#999999')
        .padding({ left: 20, bottom: 8 })
        .width('100%')

      if (this.allSessions.length === 0) {
        Column({ space: 10 }) {
          Text('\uD83D\uDCAC').fontSize(48)
          Text(I18n.t('memory.noSessions')).fontSize(16).fontColor('#999999')
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .width('100%')
      } else {
        List({ space: 8 }) {
          ForEach(this.allSessions, (session: ChatSession) => {
            ListItem() {
              this.SessionCard(session)
            }
            .padding({ left: 16, right: 16 })
          }, (session: ChatSession): string => session.id)
        }
        .layoutWeight(1)
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  SessionCard(session: ChatSession) {
    Column({ space: 6 }) {
      Row() {
        if (session.isPinned) {
          Text('\uD83D\uDCCC')
            .fontSize(13)
            .margin({ right: 6 })
        }
        if (session.isClosed) {
          Text(I18n.t('session.closedTag'))
            .fontSize(10)
            .fontColor('#999999')
            .backgroundColor('#F0F0F0')
            .borderRadius(4)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .margin({ right: 6 })
        }
        Text(session.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1A1A1A')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Text(session.messageCount.toString() + I18n.t('memory.messages'))
          .fontSize(11)
          .fontColor('#FFFFFF')
          .backgroundColor('#D2691E')
          .borderRadius(10)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })

        Text('\uD83D\uDDD1')
          .fontSize(16)
          .fontColor('#CC0000')
          .margin({ left: 10 })
          .onClick(() => {
            this.confirmDeleteSession(session);
          })
      }
      .width('100%')

      if (session.lastMessage.length > 0) {
        Text(session.lastMessage)
          .fontSize(13)
          .fontColor('#888888')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(18)
          .width('100%')
      }

      Text(this.formatTime(session.updatedAt))
        .fontSize(11)
        .fontColor('#BBBBBB')
    }
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(12)
    .shadow({ radius: 4, color: '#0000000A', offsetX: 0, offsetY: 2 })
    .width('100%')
    .onClick(() => {
      this.openSession(session);
    })
  }

  // ============ Session Detail View ============
  @Builder
  SessionDetailView() {
    Column() {
      // Detail header with back button
      Row() {
        Text('\u2190')
          .fontSize(22)
          .fontColor('#D2691E')
          .margin({ right: 12 })
          .onClick(() => {
            this.viewingSessionId = '';
            this.viewingMessages = [];
            this.viewingSessionTitle = '';
          })

        Text(this.viewingSessionTitle)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1A1A1A')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Text(this.viewingMessages.length + I18n.t('memory.messages'))
          .fontSize(12)
          .fontColor('#999999')
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 8, bottom: 8 })

      Divider().color('#E0E0E0').width('100%')

      if (this.viewingMessages.length === 0) {
        Column({ space: 10 }) {
          Text('\uD83D\uDCAC').fontSize(48)
          Text(I18n.t('chat.historyEmpty')).fontSize(16).fontColor('#999999')
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .width('100%')
      } else {
        List({ space: 4 }) {
          ForEach(this.viewingMessages, (msg: ChatMessage) => {
            ListItem() {
              this.MessageRow(msg)
            }
            .padding({ left: 16, right: 16 })
          }, (msg: ChatMessage): string => msg.id)
        }
        .layoutWeight(1)
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  MessageRow(msg: ChatMessage) {
    if (msg.isToolCall) {
      // Tool call: compact display
      Row() {
        Text('\uD83D\uDD27')
          .fontSize(12)
          .margin({ right: 4 })
        Text(msg.toolName.length > 0 ? msg.toolName : 'tool')
          .fontSize(12)
          .fontColor('#999999')
          .fontStyle(FontStyle.Italic)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
    } else {
      Column({ space: 4 }) {
        Row() {
          Text(msg.role === 'user' ? '\uD83D\uDC64' : '\uD83E\uDD16')
            .fontSize(13)
            .margin({ right: 6 })
          Text(msg.role === 'user' ? I18n.t('chat.you') : 'AI')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(msg.role === 'user' ? '#D2691E' : '#1976D2')
          Blank()
          Text(this.formatTime(msg.timestamp))
            .fontSize(10)
            .fontColor('#CCCCCC')
        }
        .width('100%')

        Text(msg.content)
          .fontSize(14)
          .fontColor('#333333')
          .lineHeight(20)
          .width('100%')
          .maxLines(20)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor(msg.role === 'user' ? '#FFF8F0' : Color.White)
      .borderRadius(10)
      .width('100%')
    }
  }

  @Builder
  EntryCard(item: MemoryItem) {
    Column({ space: 6 }) {
      Row() {
        Text(this.typeIcon(item.memType))
          .fontSize(14)
          .margin({ right: 6 })
        Text(this.typeLabel(item.memType))
          .fontSize(11)
          .fontColor(Color.White)
          .backgroundColor(this.typeColor(item.memType))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(4)
        Blank()
        Text('\u2716')
          .fontSize(14)
          .fontColor('#CCCCCC')
          .onClick(() => { this.removeEntry(item.id); })
      }
      .width('100%')

      Text(item.content)
        .fontSize(14)
        .fontColor('#1A1A1A')
        .lineHeight(20)
        .width('100%')

      Text(new Date(item.createdAt).toLocaleDateString())
        .fontSize(11)
        .fontColor('#BBBBBB')
    }
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(12)
    .shadow({ radius: 4, color: '#0000000A', offsetX: 0, offsetY: 2 })
    .width('100%')
  }

  // ============ logic ============

  private async reload(): Promise<void> {
    let ctx = getContext(this) as common.UIAbilityContext;
    this.entries = await this.memSvc.loadAll(ctx);
  }

  private async loadSessions(): Promise<void> {
    this.allSessions = this.sessionSvc.getAllSessions();
  }

  private confirmDeleteSession(session: ChatSession): void {
    promptAction.showDialog({
      title: I18n.t('memory.deleteSession'),
      message: I18n.t('memory.deleteSessionConfirm'),
      buttons: [
        { text: I18n.t('memory.cancel'), color: '#999999' },
        { text: I18n.t('session.delete'), color: '#FF3B30' }
      ]
    }).then(async (result) => {
      if (result.index === 1) {
        await this.sessionSvc.deleteSessionPermanently(session.id);
        this.allSessions = this.allSessions.filter((s): boolean => s.id !== session.id);
        promptAction.showToast({ message: I18n.t('session.deleted') });
      }
    });
  }

  private async openSession(session: ChatSession): Promise<void> {
    this.viewingSessionId = session.id;
    this.viewingSessionTitle = session.title;
    this.viewingMessages = [];
    let messages = await this.sessionSvc.loadMessages(session.id);
    // Filter out empty messages
    this.viewingMessages = messages.filter((m): boolean => m.content.length > 0 || m.isToolCall);
  }

  private formatTime(ts: number): string {
    if (ts <= 0) return '';
    let d = new Date(ts);
    let now = new Date();
    let pad = (n: number): string => n < 10 ? '0' + n.toString() : n.toString();
    let time = pad(d.getHours()) + ':' + pad(d.getMinutes());
    if (d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth() && d.getDate() === now.getDate()) {
      return time;
    }
    return (d.getMonth() + 1).toString() + '/' + d.getDate().toString() + ' ' + time;
  }

  private filtered(): MemoryItem[] {
    if (this.filterType === 'all') return this.entries;
    return this.entries.filter((e): boolean => e.memType === this.filterType);
  }

  private async addEntry(): Promise<void> {
    if (this.newContent.trim().length === 0) return;
    let ctx = getContext(this) as common.UIAbilityContext;
    let item = await this.memSvc.add(ctx, this.newType, this.newContent.trim(), 0.8);
    this.entries.push(item);
    this.newContent = '';
    this.showAddPanel = false;
  }

  private async removeEntry(id: string): Promise<void> {
    let ctx = getContext(this) as common.UIAbilityContext;
    await this.memSvc.remove(ctx, id);
    this.entries = this.entries.filter((e): boolean => e.id !== id);
  }

  private confirmClear(): void {
    promptAction.showDialog({
      title: I18n.t('memory.clearTitle'),
      message: I18n.t('memory.clearMessage'),
      buttons: [
        { text: I18n.t('memory.cancel'), color: '#666666' },
        { text: I18n.t('memory.clear'), color: '#D32F2F' }
      ]
    }).then(async (result) => {
      if (result.index === 1) {
        let ctx = getContext(this) as common.UIAbilityContext;
        await this.memSvc.clearAll(ctx);
        this.entries = [];
      }
    });
  }

  // ============ Extract Memory from Chat ============

  private async extractFromChat(): Promise<void> {
    if (this.isExtracting) return;
    this.isExtracting = true;

    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      
      // Ensure SessionService is initialized
      await this.sessionSvc.initialize(ctx);
      
      let sessionId = this.sessionSvc.getCurrentSessionId();
      if (!sessionId || sessionId.length === 0) {
        promptAction.showToast({ message: I18n.t('memory.noMessages'), duration: 1500 });
        this.isExtracting = false;
        return;
      }
      
      let messages = await this.sessionSvc.loadMessages(sessionId);

      if (messages.length === 0) {
        promptAction.showToast({ message: I18n.t('memory.noMessages'), duration: 1500 });
        this.isExtracting = false;
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
      if (conversationText.length < 20) {
        promptAction.showToast({ message: I18n.t('memory.noMessages'), duration: 1500 });
        this.isExtracting = false;
        return;
      }
      // Truncate if too long
      if (conversationText.length > 4000) {
        conversationText = conversationText.substring(conversationText.length - 4000);
      }

      let settings = await this.loadSettings(ctx);

      let systemPrompt = `You are a memory extraction assistant. Analyze the conversation and extract important facts, preferences, and instructions worth remembering across sessions.

Return ONLY a JSON array of objects with:
- "type": "fact" | "preference" | "instruction"
- "content": the memory text (concise, 1 sentence)

If nothing worth remembering, return [].
Respond ONLY with the JSON array.`;

      let result = await this.ai.simpleChat(systemPrompt, conversationText, settings);
      let jsonMatch = /\[[\s\S]*\]/.exec(result);
      if (!jsonMatch) {
        promptAction.showToast({ message: I18n.t('chat.noNewMemory'), duration: 1500 });
        this.isExtracting = false;
        return;
      }

      let memories = JSON.parse(jsonMatch[0]) as MemoryExtractItem[];
      let addedCount = 0;
      for (let mem of memories) {
        if (mem.content && mem.content.length > 0) {
          let memType = mem.type ?? 'fact';
          let item = await this.memSvc.addIfNew(ctx, memType, mem.content, 0.8);
          if (item) {
            this.entries.push(item);
            addedCount++;
          }
        }
      }

      if (addedCount > 0) {
        promptAction.showToast({
          message: I18n.t('chat.memoryExtracted').replace('{0}', addedCount.toString()),
          duration: 2000
        });
      } else {
        promptAction.showToast({ message: I18n.t('chat.noNewMemory'), duration: 1500 });
      }
      this.log.info('MemoryPage', `Extract from chat: AI found ${memories.length}, added ${addedCount} new`);
    } catch (e) {
      this.log.warn('MemoryPage', `Extract from chat failed: ${(e as Error).message ?? ''}`);
      promptAction.showToast({ message: I18n.t('chat.extractFailed'), duration: 1500 });
    } finally {
      this.isExtracting = false;
    }
  }

  // ============ Sync from Server ============

  private async syncFromServer(): Promise<void> {
    if (this.isSyncing) return;
    this.isSyncing = true;

    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let runtime = NodeRuntime.getInstance();
      if (!runtime.isConnected) {
        promptAction.showToast({ message: I18n.t('memory.syncFailed'), duration: 1500 });
        this.isSyncing = false;
        return;
      }

      let resJson = await runtime.fetchMemories();
      if (resJson.length === 0) {
        promptAction.showToast({ message: I18n.t('chat.noNewMemory'), duration: 1500 });
        this.isSyncing = false;
        return;
      }

      let res = JSON.parse(resJson) as Record<string, Object>;
      let items = res['items'] as Object[] | undefined;
      if (!items || !Array.isArray(items) || items.length === 0) {
        promptAction.showToast({ message: I18n.t('chat.noNewMemory'), duration: 1500 });
        this.isSyncing = false;
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
          let newItem = await this.memSvc.add(ctx, memType, content, importance);
          this.entries.push(newItem);
          localContents.add(content.toLowerCase().trim());
          addedCount++;
        }
      }

      promptAction.showToast({
        message: I18n.t('memory.syncDone').replace('{0}', addedCount.toString()),
        duration: 2000
      });
      this.log.info('MemoryPage', `Sync from server: ${items.length} server items, ${addedCount} new merged`);
    } catch (e) {
      this.log.warn('MemoryPage', `Sync from server failed: ${(e as Error).message ?? ''}`);
      promptAction.showToast({ message: I18n.t('memory.syncFailed'), duration: 1500 });
    } finally {
      this.isSyncing = false;
    }
  }

  // ============ Settings ============

  private async loadSettings(ctx: common.UIAbilityContext): Promise<SettingsData> {
    let store = await preferences.getPreferences(ctx, Constants.PREFS_SETTINGS);
    let provider = (await store.get('provider', 'openrouter')) as string;
    let keyPref = 'key_' + provider;
    let urlPref = 'url_' + provider;
    let modelPref = 'model_' + provider;
    let apiKey = (await store.get(keyPref, '')) as string;
    let baseUrl = (await store.get(urlPref, '')) as string;
    if (provider === 'openrouter' && baseUrl.length > 0 && !baseUrl.includes('openrouter')) {
      baseUrl = '';
    }
    let defaultModel = provider === 'openrouter' ? Constants.DEFAULT_MODEL_OPENROUTER
      : provider === 'anthropic' ? Constants.DEFAULT_MODEL_ANTHROPIC
        : provider === 'openai' ? Constants.DEFAULT_MODEL_OPENAI
          : provider === 'siliconflow' ? Constants.DEFAULT_MODEL_SILICONFLOW
            : provider === 'custom' ? '' : 'llama3';
    let model = (await store.get(modelPref, defaultModel)) as string;
    if (apiKey.length === 0 && provider === 'openrouter' && Constants.OPENROUTER_DEFAULT_KEY.length > 0) {
      apiKey = Constants.OPENROUTER_DEFAULT_KEY;
    }
    if (apiKey.length === 0 && (provider === 'openai' || provider === 'siliconflow') && Constants.SILICONFLOW_DEFAULT_KEY.length > 0) {
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

  // ============ Helpers ============

  private typeLabel(t: string): string {
    if (t === 'fact') return I18n.t('memory.fact');
    if (t === 'preference') return I18n.t('memory.preference');
    if (t === 'instruction') return I18n.t('memory.instruction');
    return t;
  }

  private typeIcon(t: string): string {
    if (t === 'fact') return '\uD83D\uDCCC';
    if (t === 'preference') return '\u2764\uFE0F';
    if (t === 'instruction') return '\uD83D\uDCDD';
    return '\uD83D\uDCBE';
  }

  private typeColor(t: string): string {
    if (t === 'fact') return '#1976D2';
    if (t === 'preference') return '#E91E63';
    if (t === 'instruction') return '#FF9800';
    return '#607D8B';
  }
}
