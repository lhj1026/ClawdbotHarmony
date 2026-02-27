// Silent mode conversations page: list + detail view
import { SilentConversationItem, SilentConversationRecord, SilentConversationEntry, ActionItem } from '../model/Models';
import { I18n, t } from '../common/I18n';
import { ConversationStore } from '../service/ConversationStore';
import { SilentModeService } from '../service/SilentModeService';
import { VoiceprintService } from '../service/VoiceprintService';
import { ConversationCard } from '../components/ConversationCard';
import { MarkdownText } from '../components/MarkdownText';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { promptAction } from '@kit.ArkUI';
import { Constants } from '../common/Constants';

@Component
export struct ConversationsPage {
  @State conversations: SilentConversationItem[] = [];
  @State isRecording: boolean = false;
  @State silentState: string = 'idle';  // idle | monitoring | listening | processing
  @State viewMode: string = 'list';  // 'list' | 'detail'
  @State detailRecord: SilentConversationRecord | undefined = undefined;
  @State lang: string = I18n.lang;
  @State editingSpeakerId: string = '';
  @State editingSpeakerName: string = '';
  @State showEditDialog: boolean = false;
  @State refreshCounter: number = 0;  // Force UI refresh
  @State selectMode: boolean = false;           // Multi-select mode
  @State selectedIds: string[] = [];            // Selected record IDs
  private isToggling: boolean = false;          // Guard against re-entrant toggle
  private suppressToggleEvent: boolean = false; // Suppress onChange from programmatic Toggle update
  private langListener: () => void = () => { this.lang = I18n.lang; };
  private stateListener: (state: string) => void = (state: string) => {
    this.isRecording = state !== 'idle';
    this.silentState = state;
  };
  private refreshTimer: number = -1;

  aboutToAppear(): void {
    I18n.addListener(this.langListener);
    SilentModeService.getInstance().addStateListener(this.stateListener);
    this.isRecording = SilentModeService.getInstance().isActive();
    this.silentState = SilentModeService.getInstance().getState();
    this.loadConversations();

    // Restore toggle state from preferences — auto-resume recording if was ON
    this.restoreToggleState();

    // Auto-refresh while recording
    this.refreshTimer = setInterval(() => {
      if (this.isRecording) {
        this.loadConversations();
      }
    }, 5000);
  }

  aboutToDisappear(): void {
    I18n.removeListener(this.langListener);
    SilentModeService.getInstance().removeStateListener(this.stateListener);
    if (this.refreshTimer >= 0) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = -1;
    }
  }

  private async loadConversations(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      await ConversationStore.getInstance().init(ctx);
      let records = await ConversationStore.getInstance().listRecords();
      this.conversations = records.map((r: SilentConversationRecord) => new SilentConversationItem(r));
    } catch (err) {
      // ignore
    }
  }

  private async restoreToggleState(): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let prefs = await preferences.getPreferences(ctx, Constants.PREFS_SETTINGS);
      let autoSilent = (await prefs.get('silent_mode_toggle', false)) as boolean;
      if (autoSilent && !SilentModeService.getInstance().isActive()) {
        this.suppressToggleEvent = true;
        let ok = await SilentModeService.getInstance().start(ctx);
        this.isRecording = ok;
        // Allow the Toggle onChange to settle before unsuppressing
        setTimeout(() => { this.suppressToggleEvent = false; }, 300);
      }
    } catch { /* ignore */ }
  }

  private async toggleRecording(): Promise<void> {
    // Guard: skip if suppressed (programmatic update) or already toggling
    if (this.suppressToggleEvent || this.isToggling) return;
    this.isToggling = true;

    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let service = SilentModeService.getInstance();
      let willBeActive = !service.isActive();

      this.suppressToggleEvent = true;
      if (service.isActive()) {
        await service.stop();
        this.isRecording = false;
        willBeActive = false;
        this.loadConversations();
      } else {
        let ok = await service.start(ctx);
        this.isRecording = ok;
        willBeActive = ok;
      }

      // Persist toggle state
      try {
        let prefs = await preferences.getPreferences(ctx, Constants.PREFS_SETTINGS);
        await prefs.put('silent_mode_toggle', willBeActive);
        await prefs.flush();
      } catch { /* ignore */ }

      // Let Toggle onChange settle
      setTimeout(() => { this.suppressToggleEvent = false; }, 300);
    } finally {
      this.isToggling = false;
    }
  }

  private async openDetail(id: string): Promise<void> {
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      await ConversationStore.getInstance().init(ctx);
      let record = await ConversationStore.getInstance().getRecord(id);
      if (record) {
        this.detailRecord = record;
        this.viewMode = 'detail';
      }
    } catch { /* ignore */ }
  }

  private async deleteConversation(id: string): Promise<void> {
    promptAction.showDialog({
      title: '',
      message: t('silent.deleteConfirm'),
      buttons: [
        { text: t('memory.cancel'), color: '#999999' },
        { text: t('session.delete'), color: '#FF3B30' }
      ]
    }).then(async (result) => {
      if (result.index === 1) {
        await ConversationStore.getInstance().deleteRecord(id);
        promptAction.showToast({ message: t('silent.deleted') });
        this.loadConversations();
        if (this.detailRecord && this.detailRecord.id === id) {
          this.viewMode = 'list';
          this.detailRecord = undefined;
        }
      }
    });
  }

  private toggleSelectMode(): void {
    this.selectMode = !this.selectMode;
    if (!this.selectMode) {
      this.selectedIds = [];
    }
  }

  private toggleSelection(id: string): void {
    let idx = this.selectedIds.indexOf(id);
    if (idx >= 0) {
      this.selectedIds = this.selectedIds.filter((s: string) => s !== id);
    } else {
      this.selectedIds = [...this.selectedIds, id];
    }
  }

  private selectAll(): void {
    if (this.selectedIds.length === this.conversations.length) {
      this.selectedIds = [];
    } else {
      this.selectedIds = this.conversations.map((c: SilentConversationItem) => c.id);
    }
  }

  private async deleteSelected(): Promise<void> {
    if (this.selectedIds.length === 0) return;
    let count = this.selectedIds.length;
    promptAction.showDialog({
      title: '',
      message: `${t('silent.deleteConfirm')} (${count})`,
      buttons: [
        { text: t('memory.cancel'), color: '#999999' },
        { text: t('session.delete'), color: '#FF3B30' }
      ]
    }).then(async (result) => {
      if (result.index === 1) {
        for (let id of this.selectedIds) {
          await ConversationStore.getInstance().deleteRecord(id);
        }
        promptAction.showToast({ message: `${t('silent.deleted')} (${count})` });
        this.selectedIds = [];
        this.selectMode = false;
        this.loadConversations();
      }
    });
  }

  private formatTime(ts: number): string {
    let d = new Date(ts);
    return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}:${String(d.getSeconds()).padStart(2, '0')}`;
  }

  private formatDate(ts: number): string {
    let d = new Date(ts);
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')} ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
  }

  private formatDuration(startTime: number, endTime: number): string {
    let endMs = endTime > 0 ? endTime : Date.now();
    let sec = Math.floor((endMs - startTime) / 1000);
    if (sec < 60) return `${sec}s`;
    let min = Math.floor(sec / 60);
    sec = sec % 60;
    if (min < 60) return `${min}m ${sec}s`;
    let hr = Math.floor(min / 60);
    min = min % 60;
    return `${hr}h ${min}m`;
  }

  private formatActionItemTime(ts: number): string {
    let d = new Date(ts);
    let month = String(d.getMonth() + 1).padStart(2, '0');
    let day = String(d.getDate()).padStart(2, '0');
    let hours = String(d.getHours()).padStart(2, '0');
    let minutes = String(d.getMinutes()).padStart(2, '0');
    return `${month}-${day} ${hours}:${minutes}`;
  }

  private getSpeakerDisplayName(speakerId: string): string {
    if (!this.detailRecord || !this.detailRecord.speakerAliases) {
      return speakerId;
    }
    return this.detailRecord.speakerAliases[speakerId] || speakerId;
  }

  private editSpeakerName(speakerId: string): void {
    if (!this.detailRecord) return;
    this.editingSpeakerId = speakerId;
    this.editingSpeakerName = this.getSpeakerDisplayName(speakerId);
    this.showEditDialog = true;
  }

  private async confirmEditSpeaker(): Promise<void> {
    if (this.editingSpeakerId && this.editingSpeakerName.trim() && this.detailRecord) {
      let newName = this.editingSpeakerName.trim();
      let oldSpeakerId = this.editingSpeakerId;
      
      // Find entries with this speaker to get embeddings
      let embeddings: Float32Array[] = [];
      for (let entry of this.detailRecord.entries) {
        if (entry.speaker === oldSpeakerId && entry.embedding && entry.embedding.length > 0) {
          embeddings.push(new Float32Array(entry.embedding));
        }
      }
      
      // Register voiceprint with the new name from stored embeddings
      if (embeddings.length > 0) {
        try {
          let ctx = getContext(this) as common.UIAbilityContext;
          let vpService = VoiceprintService.getInstance();
          await vpService.init(ctx);  // Ensure initialized
          let success = await vpService.enrollFromEmbeddings(newName, embeddings);
          if (success) {
            promptAction.showToast({ message: `已注册声纹: ${newName}` });
          }
        } catch (err) {
          console.warn('Voiceprint enrollment failed:', (err as Error).message ?? String(err));
        }
      }
      
      // Update alias and refresh
      await this.updateSpeakerAlias(oldSpeakerId, newName);
      promptAction.showToast({ message: '已更新说话人名称' });
    }
    this.showEditDialog = false;
    this.editingSpeakerId = '';
    this.editingSpeakerName = '';
  }

  private cancelEditSpeaker(): void {
    this.showEditDialog = false;
    this.editingSpeakerId = '';
    this.editingSpeakerName = '';
  }

  private async updateSpeakerAlias(speakerId: string, newName: string): Promise<void> {
    if (!this.detailRecord) return;
    
    // Initialize speakerAliases if needed
    if (!this.detailRecord.speakerAliases) {
      this.detailRecord.speakerAliases = {};
    }
    
    // Update alias in the record
    this.detailRecord.speakerAliases[speakerId] = newName;
    
    // Also update participants display if needed
    let idx = this.detailRecord.participants.indexOf(speakerId);
    if (idx >= 0) {
      this.detailRecord.participants[idx] = newName;
    }
    
    // Save to store
    await ConversationStore.getInstance().saveRecord(this.detailRecord);
    
    // Refresh from store to ensure consistency and trigger re-render
    let recordId = this.detailRecord.id;
    let refreshed = await ConversationStore.getInstance().getRecord(recordId);
    if (refreshed) {
      this.detailRecord = refreshed;
    }
    
    // Increment counter to force ForEach re-render
    this.refreshCounter++;
  }

  build() {
    Column() {
      if (this.viewMode === 'list') {
        this.ListView()
      } else {
        this.DetailView()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }

  @Builder
  ListView() {
    Column() {
      // Title + Toggle switch
      Row() {
        Text(t('silent.title'))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1A1A1A')

        Blank()

        Toggle({ type: ToggleType.Switch, isOn: this.isRecording })
          .selectedColor('#34C759')
          .switchPointColor(Color.White)
          .onChange((isOn: boolean) => {
            this.toggleRecording();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 12 })

      // State indicator bar
      if (this.isRecording) {
        Row() {
          Circle({ width: 8, height: 8 })
            .fill(this.silentState === 'monitoring' ? '#34C759'
              : this.silentState === 'listening' ? '#FF9500'
                : this.silentState === 'processing' ? '#FF3B30' : '#999999')
            .margin({ right: 8 })
          Text(this.silentState === 'monitoring' ? t('silent.monitoring')
            : this.silentState === 'listening' ? t('silent.listening')
              : this.silentState === 'processing' ? t('silent.processing') : t('silent.recording'))
            .fontSize(13)
            .fontColor(this.silentState === 'monitoring' ? '#34C759'
              : this.silentState === 'listening' ? '#FF9500'
                : this.silentState === 'processing' ? '#FF3B30' : '#999999')
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })
      }

      // Select mode toolbar
      if (this.conversations.length > 0) {
        Row() {
          if (this.selectMode) {
            // Select all
            Text(this.selectedIds.length === this.conversations.length ? t('silent.deselectAll') : t('silent.selectAll'))
              .fontSize(13)
              .fontColor('#007AFF')
              .onClick(() => { this.selectAll(); })

            Blank()

            // Delete selected
            Text(`${t('session.delete')} (${this.selectedIds.length})`)
              .fontSize(13)
              .fontColor(this.selectedIds.length > 0 ? '#FF3B30' : '#CCCCCC')
              .onClick(() => {
                if (this.selectedIds.length > 0) this.deleteSelected();
              })

            Text('  |  ')
              .fontSize(13)
              .fontColor('#CCCCCC')

            Text(t('memory.cancel'))
              .fontSize(13)
              .fontColor('#007AFF')
              .onClick(() => { this.toggleSelectMode(); })
          } else {
            Blank()

            Text(t('silent.select'))
              .fontSize(13)
              .fontColor('#007AFF')
              .onClick(() => { this.toggleSelectMode(); })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })
      }

      // Conversation list
      if (this.conversations.length === 0) {
        Column() {
          Text(t('silent.empty'))
            .fontSize(15)
            .fontColor('#999999')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.conversations, (item: SilentConversationItem) => {
            ListItem() {
              Row() {
                // Selection indicator in select mode (visual only — no Checkbox to avoid onChange loop)
                if (this.selectMode) {
                  Stack() {
                    Circle({ width: 22, height: 22 })
                      .fill(this.selectedIds.includes(item.id) ? '#007AFF' : '#FFFFFF')
                      .stroke(this.selectedIds.includes(item.id) ? '#007AFF' : '#CCCCCC')
                      .strokeWidth(1.5)
                    if (this.selectedIds.includes(item.id)) {
                      Text('\u2713')
                        .fontSize(14)
                        .fontWeight(FontWeight.Bold)
                        .fontColor('#FFFFFF')
                    }
                  }
                  .width(22)
                  .height(22)
                  .margin({ right: 10 })
                  .onClick(() => {
                    this.toggleSelection(item.id);
                  })
                }

                ConversationCard({
                  item: item,
                  onTap: () => {
                    if (this.selectMode) {
                      this.toggleSelection(item.id);
                    } else {
                      this.openDetail(item.id);
                    }
                  },
                  onDelete: () => {
                    if (!this.selectMode) {
                      this.deleteConversation(item.id);
                    }
                  }
                })
                  .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
            }
            .padding({ left: 16, right: 16 })
          }, (item: SilentConversationItem) => item.id + '_' + item.entryCount + '_' + item.status + '_' + this.selectMode + '_' + this.selectedIds.includes(item.id))
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ bottom: 16 })
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  DetailView() {
    Column() {
      // Back button + header
      Row() {
        Text('\u2190')
          .fontSize(22)
          .fontColor('#1A1A1A')
          .padding(8)
          .onClick(() => {
            this.viewMode = 'list';
            this.detailRecord = undefined;
            this.loadConversations();
          })

        Text(t('silent.transcript'))
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1A1A1A')
          .margin({ left: 8 })

        Blank()
      }
      .width('100%')
      .padding({ left: 8, right: 16, top: 8, bottom: 8 })

      if (this.detailRecord) {
        Scroll() {
          Column() {
            // Header info card
            Column() {
              // Date + duration
              Row() {
                Text(this.formatDate(this.detailRecord.startTime))
                  .fontSize(14)
                  .fontColor('#333333')

                Blank()

                Text(this.formatDuration(this.detailRecord.startTime, this.detailRecord.endTime))
                  .fontSize(12)
                  .fontColor('#666666')
                  .backgroundColor('#F0F0F0')
                  .borderRadius(8)
                  .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              }
              .width('100%')

              // Participants
              if (this.detailRecord.participants.length > 0) {
                Row() {
                  Text(`${t('silent.participants')}: `)
                    .fontSize(13)
                    .fontColor('#999999')
                  Text(this.detailRecord.participants.join(', '))
                    .fontSize(13)
                    .fontColor('#007AFF')
                }
                .width('100%')
                .margin({ top: 8 })
              }

              // Summary
              if (this.detailRecord.summary.length > 0) {
                Column() {
                  Text(t('silent.summary'))
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#333333')
                    .margin({ bottom: 4 })
                  MarkdownText({ content: this.detailRecord.summary, baseFontSize: 13 })
                    .width('100%')
                }
                .width('100%')
                .margin({ top: 10 })
                .padding(10)
                .backgroundColor('#F8F8FF')
                .borderRadius(8)
              }
            }
            .width('100%')
            .padding(14)
            .backgroundColor(Color.White)
            .borderRadius(10)
            .margin({ left: 16, right: 16, top: 8, bottom: 8 })

            // Action items section
            if (this.detailRecord.actionItems && this.detailRecord.actionItems.length > 0) {
              Column() {
                Text(t('silent.actionItems'))
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#333333')
                  .margin({ bottom: 8 })

                ForEach(this.detailRecord.actionItems, (ai: ActionItem, aiIdx: number) => {
                  Row() {
                    Text(ai.created ? '\u{1F4C5}' : '\u26A0\uFE0F')
                      .fontSize(16)
                      .margin({ right: 8 })

                    Column() {
                      Text(ai.title)
                        .fontSize(14)
                        .fontWeight(FontWeight.Medium)
                        .fontColor('#333333')
                      Row() {
                        Text(this.formatActionItemTime(ai.startTime))
                          .fontSize(12)
                          .fontColor('#666666')
                        if (ai.location.length > 0) {
                          Text(` · ${ai.location}`)
                            .fontSize(12)
                            .fontColor('#666666')
                        }
                      }
                      Text(ai.created ? t('silent.addedToCalendar') : t('silent.failedToAdd'))
                        .fontSize(11)
                        .fontColor(ai.created ? '#34C759' : '#FF9500')
                        .margin({ top: 2 })
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                  }
                  .width('100%')
                  .padding(8)
                }, (ai: ActionItem, aiIdx: number) => `ai_${aiIdx}_${ai.title}`)
              }
              .width('100%')
              .padding(14)
              .backgroundColor(Color.White)
              .borderRadius(10)
              .margin({ left: 16, right: 16, bottom: 8 })
            }

            // Entries timeline (hide [...] entries when no local ASR)
            ForEach(this.detailRecord.entries.filter((e: SilentConversationEntry) => e.text !== '[...]'), (entry: SilentConversationEntry, index: number) => {
              Row() {
                // Time column
                Column() {
                  Text(this.formatTime(entry.timestamp))
                    .fontSize(11)
                    .fontColor('#999999')
                }
                .width(60)
                .alignItems(HorizontalAlign.End)
                .margin({ right: 10 })

                // Timeline dot
                Column() {
                  Circle({ width: 8, height: 8 })
                    .fill('#007AFF')
                }
                .width(8)
                .margin({ right: 10, top: 4 })

                // Content
                Column() {
                  Text(this.getSpeakerDisplayName(entry.speaker))
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#007AFF')
                    .onClick(() => {
                      this.editSpeakerName(entry.speaker);
                    })
                    .decoration({ type: TextDecorationType.Underline })
                  Text(entry.text)
                    .fontSize(14)
                    .fontColor('#333333')
                    .margin({ top: 4 })
                    .width('100%')
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .alignItems(VerticalAlign.Top)
            }, (entry: SilentConversationEntry, index: number) => `${index}_${entry.timestamp}_${this.refreshCounter}`)
          }
          .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
        .scrollable(ScrollDirection.Vertical)
      }
    }
    .width('100%')
    .height('100%')

    // Edit speaker name dialog
    if (this.showEditDialog) {
      Column() {
        Column() {
          Text('编辑说话人名称')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor('#333333')
            .margin({ bottom: 16 })

          TextInput({ text: this.editingSpeakerName, placeholder: '请输入名称' })
            .width('100%')
            .height(44)
            .fontSize(16)
            .onChange((value: string) => {
              this.editingSpeakerName = value;
            })
            .margin({ bottom: 20 })

          Row() {
            Button('取消')
              .fontSize(16)
              .fontColor('#666666')
              .backgroundColor('#F0F0F0')
              .width('45%')
              .height(44)
              .onClick(() => {
                this.cancelEditSpeaker();
              })

            Button('确定')
              .fontSize(16)
              .fontColor(Color.White)
              .backgroundColor('#007AFF')
              .width('45%')
              .height(44)
              .onClick(() => {
                this.confirmEditSpeaker();
              })
          }
          .width('100%')
          .justifyContent(FlexAlign.SpaceBetween)
        }
        .width('85%')
        .padding(20)
        .backgroundColor(Color.White)
        .borderRadius(12)
      }
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.5)')
      .justifyContent(FlexAlign.Center)
      .position({ x: 0, y: 0 })
    }
  }
}
