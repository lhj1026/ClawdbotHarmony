// Silent mode conversations page: list + detail view
import { SilentConversationItem, SilentConversationRecord, SilentConversationEntry } from '../model/Models';
import { I18n, t } from '../common/I18n';
import { ConversationStore } from '../service/ConversationStore';
import { SilentModeService } from '../service/SilentModeService';
import { VoiceprintService } from '../service/VoiceprintService';
import { ConversationCard } from '../components/ConversationCard';
import { MarkdownText } from '../components/MarkdownText';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';

@Component
export struct ConversationsPage {
  @State conversations: SilentConversationItem[] = [];
  @State isRecording: boolean = false;
  @State viewMode: string = 'list';  // 'list' | 'detail'
  @State detailRecord: SilentConversationRecord | undefined = undefined;
  @State lang: string = I18n.lang;
  @State editingSpeakerId: string = '';
  @State editingSpeakerName: string = '';
  @State showEditDialog: boolean = false;
  @State refreshCounter: number = 0;  // Force UI refresh
  private langListener: () => void = () => { this.lang = I18n.lang; };
  private stateListener: (state: string) => void = (state: string) => {
    this.isRecording = state !== 'idle';
  };
  private refreshTimer: number = -1;

  aboutToAppear(): void {
    I18n.addListener(this.langListener);
    SilentModeService.getInstance().addStateListener(this.stateListener);
    this.isRecording = SilentModeService.getInstance().isActive();
    this.loadConversations();

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

  private async toggleRecording(): Promise<void> {
    let ctx = getContext(this) as common.UIAbilityContext;
    let service = SilentModeService.getInstance();
    if (service.isActive()) {
      await service.stop();
      this.isRecording = false;
      this.loadConversations();
    } else {
      let ok = await service.start(ctx);
      this.isRecording = ok;
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
      
      // Register voiceprint with the new name if we have embeddings
      if (embeddings.length > 0) {
        try {
          let ctx = getContext(this) as common.UIAbilityContext;
          let vpService = VoiceprintService.getInstance();
          await vpService.init(ctx);  // Ensure initialized
          let success = await vpService.enrollSpeaker(newName, embeddings, 16000);
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
      // Title + record button
      Row() {
        Text(t('silent.title'))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1A1A1A')

        Blank()

        Button(this.isRecording ? t('silent.stop') : t('silent.start'))
          .fontSize(14)
          .fontColor(Color.White)
          .backgroundColor(this.isRecording ? '#FF3B30' : '#34C759')
          .borderRadius(20)
          .height(36)
          .padding({ left: 16, right: 16 })
          .onClick(() => { this.toggleRecording(); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 12 })

      // Recording indicator
      if (this.isRecording) {
        Row() {
          Text('🔴')
            .fontSize(12)
            .margin({ right: 6 })
          Text(t('silent.recording'))
            .fontSize(13)
            .fontColor('#FF3B30')
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
              ConversationCard({
                item: item,
                onTap: () => { this.openDetail(item.id); },
                onDelete: () => { this.deleteConversation(item.id); }
              })
            }
            .padding({ left: 16, right: 16 })
          }, (item: SilentConversationItem) => item.id + '_' + item.entryCount + '_' + item.status)
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

            // Entries timeline
            ForEach(this.detailRecord.entries, (entry: SilentConversationEntry, index: number) => {
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
