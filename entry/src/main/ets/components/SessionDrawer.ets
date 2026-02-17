// Session list drawer component for multi-conversation support
import { ChatSession } from '../model/Models';
import { I18n, t } from '../common/I18n';
import { promptAction } from '@kit.ArkUI';

@Component
export struct SessionDrawer {
  @Link sessions: ChatSession[];
  @Link currentSessionId: string;
  @Prop lang: string = 'zh';
  @State isRenameDialogVisible: boolean = false;
  @State renameSessionId: string = '';
  @State renameText: string = '';
  onSessionSelect: (sessionId: string) => void = () => {};
  onSessionCreate: () => void = () => {};
  onSessionClose: (sessionId: string) => void = () => {};
  onSessionRename: (sessionId: string, newName: string) => void = () => {};
  onSessionPin: (sessionId: string) => void = () => {};
  onSessionClear: (sessionId: string) => void = () => {};
  onOpenSkills: () => void = () => {};
  onOpenMemory: () => void = () => {};
  onOpenSettings: () => void = () => {};
  onOpenLogs: () => void = () => {};
  onOpenAbout: () => void = () => {};
  onClose: () => void = () => {};

  @Builder
  SwipeCloseButton(session: ChatSession) {
    Row() {
      Text(t('session.close'))
        .fontSize(14)
        .fontColor('#FFFFFF')
        .fontWeight(FontWeight.Medium)
    }
    .width(72)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#FF9500')
    .onClick(() => {
      this.confirmClose(session);
    })
  }

  // Format token count for display (e.g., 1234 -> "1.2k", 12345 -> "12k")
  private formatTokens(count: number): string {
    if (count < 1000) {
      return `${count}`;
    } else if (count < 10000) {
      return `${(count / 1000).toFixed(1)}k`;
    } else if (count < 1000000) {
      return `${Math.round(count / 1000)}k`;
    } else {
      return `${(count / 1000000).toFixed(1)}M`;
    }
  }

  @Builder
  SessionItem(session: ChatSession) {
    Row() {
      // Pin indicator
      if (session.isPinned) {
        Text('📌')
          .fontSize(12)
          .margin({ right: 6 })
      }

      Column() {
        Row() {
          Text(session.title)
            .fontSize(15)
            .fontColor(session.id === this.currentSessionId ? '#007AFF' : '#333333')
            .fontWeight(session.id === this.currentSessionId ? FontWeight.Medium : FontWeight.Normal)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          // Active indicator (pulsing dot)
          if (session.isActive) {
            Text('●')
              .fontSize(10)
              .fontColor('#34C759')
              .margin({ left: 6 })
          }
        }
        .width('100%')

        // Last message preview
        if (session.lastMessage) {
          Text(session.lastMessage)
            .fontSize(12)
            .fontColor('#999999')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 4 })
        }

        // Token usage display
        if (session.totalTokens > 0) {
          Row() {
            Text('🎯')
              .fontSize(10)
            Text(`${this.formatTokens(session.totalTokens)}`)
              .fontSize(10)
              .fontColor('#999999')
              .margin({ left: 2 })

            // Show input/output breakdown on hover or when selected
            if (session.id === this.currentSessionId) {
              Text(`(↑${this.formatTokens(session.inputTokens)} ↓${this.formatTokens(session.outputTokens)})`)
                .fontSize(9)
                .fontColor('#BBBBBB')
                .margin({ left: 4 })
            }
          }
          .margin({ top: 4 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // Message count badge
      if (session.messageCount > 0) {
        Text(`${session.messageCount}`)
          .fontSize(11)
          .fontColor('#FFFFFF')
          .backgroundColor('#CCCCCC')
          .borderRadius(10)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor(session.id === this.currentSessionId ? '#F0F7FF' : Color.Transparent)
    .borderRadius(8)
    .onClick(() => {
      this.onSessionSelect(session.id);
    })
    .gesture(
      LongPressGesture()
        .onAction(() => {
          this.showSessionMenu(session);
        })
    )
  }

  private showSessionMenu(session: ChatSession): void {
    promptAction.showActionMenu({
      title: session.title,
      buttons: [
        { text: t('session.rename'), color: '#007AFF' },
        { text: session.isPinned ? t('session.unpin') : t('session.pin'), color: '#007AFF' },
        { text: t('session.clear'), color: '#FF9500' },
        { text: t('session.close'), color: '#FF9500' }
      ]
    }).then((result) => {
      switch (result.index) {
        case 0: // Rename
          this.showRenameDialog(session);
          break;
        case 1: // Pin/Unpin
          this.onSessionPin(session.id);
          break;
        case 2: // Clear
          this.confirmClear(session);
          break;
        case 3: // Close
          this.confirmClose(session);
          break;
      }
    }).catch(() => {
      // User cancelled
    });
  }

  private showRenameDialog(session: ChatSession): void {
    this.renameSessionId = session.id;
    this.renameText = session.title;
    this.isRenameDialogVisible = true;
  }

  private confirmRename(): void {
    if (this.renameText.trim().length > 0) {
      this.onSessionRename(this.renameSessionId, this.renameText.trim());
    }
    this.isRenameDialogVisible = false;
    this.renameSessionId = '';
    this.renameText = '';
  }

  private cancelRename(): void {
    this.isRenameDialogVisible = false;
    this.renameSessionId = '';
    this.renameText = '';
  }

  private confirmClear(session: ChatSession): void {
    promptAction.showDialog({
      title: t('session.clear'),
      message: t('session.clearConfirm'),
      buttons: [
        { text: t('memory.cancel'), color: '#999999' },
        { text: t('session.clear'), color: '#FF9500' }
      ]
    }).then((result) => {
      if (result.index === 1) {
        this.onSessionClear(session.id);
        promptAction.showToast({ message: t('session.cleared') });
      }
    });
  }

  private confirmClose(session: ChatSession): void {
    // Direct close without confirmation
    this.onSessionClose(session.id);
  }

  build() {
    Stack() {
      Column() {
        // Header
        Row() {
          Text(t('session.title'))
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#333333')
          
          Blank()
          
          // New session button
          Button({ type: ButtonType.Circle }) {
            Text('+')
              .fontSize(24)
              .fontColor('#007AFF')
              .fontWeight(FontWeight.Medium)
          }
          .width(36)
          .height(36)
          .backgroundColor('#F0F7FF')
          .onClick(() => {
            this.onSessionCreate();
          })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16, bottom: 12 })

        // Divider
        Divider()
          .color('#EEEEEE')
          .width('100%')

        // Session list
        if (this.sessions.length === 0) {
          Column() {
            Text(t('chat.historyEmpty'))
              .fontSize(14)
              .fontColor('#999999')
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List() {
            ForEach(this.sessions, (session: ChatSession) => {
              ListItem() {
                this.SessionItem(session)
              }
              .swipeAction({ end: this.SwipeCloseButton(session) })
            }, (session: ChatSession) => session.id)
          }
          .width('100%')
          .layoutWeight(1)
          .divider({ strokeWidth: 0.5, color: '#F0F0F0', startMargin: 16, endMargin: 16 })
        }

        // Bottom menu entries
        Divider()
          .color('#EEEEEE')
          .width('100%')

        Row() {
          Text('\uD83D\uDD27')
            .fontSize(16)
            .margin({ right: 8 })
          Text(t('tab.skills'))
            .fontSize(14)
            .fontColor('#666666')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 6 })
        .onClick(() => {
          this.onOpenSkills();
        })

        Row() {
          Text('\uD83E\uDDE0')
            .fontSize(16)
            .margin({ right: 8 })
          Text(t('tab.memory'))
            .fontSize(14)
            .fontColor('#666666')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 6, bottom: 6 })
        .onClick(() => {
          this.onOpenMemory();
        })

        Row() {
          Text('\u2699\uFE0F')
            .fontSize(16)
            .margin({ right: 8 })
          Text(t('tab.settings'))
            .fontSize(14)
            .fontColor('#666666')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 6, bottom: 6 })
        .onClick(() => {
          this.onOpenSettings();
        })

        Row() {
          Text('\uD83D\uDCDD')
            .fontSize(16)
            .margin({ right: 8 })
          Text(t('tab.logs'))
            .fontSize(14)
            .fontColor('#666666')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 6, bottom: 6 })
        .onClick(() => {
          this.onOpenLogs();
        })

        Row() {
          Text('ℹ️')
            .fontSize(16)
            .margin({ right: 8 })
          Text(t('settings.about'))
            .fontSize(14)
            .fontColor('#666666')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 6, bottom: 12 })
        .onClick(() => {
          this.onOpenAbout();
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#FFFFFF')

      // Rename dialog overlay
      if (this.isRenameDialogVisible) {
        Column() {
          // Backdrop
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#00000066')
            .onClick(() => {
              this.cancelRename();
            })
        }
        .width('100%')
        .height('100%')

        // Dialog box
        Column() {
          Text(t('session.renameTitle'))
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor('#333333')
            .margin({ bottom: 16 })
          
          TextInput({ text: this.renameText, placeholder: t('session.renamePlaceholder') })
            .width('100%')
            .height(44)
            .fontSize(15)
            .borderRadius(8)
            .backgroundColor('#F5F5F5')
            .padding({ left: 12, right: 12 })
            .onChange((value: string) => {
              this.renameText = value;
            })
          
          Row({ space: 12 }) {
            Button(t('memory.cancel'))
              .fontColor('#999999')
              .backgroundColor('#F0F0F0')
              .layoutWeight(1)
              .height(40)
              .onClick(() => {
                this.cancelRename();
              })
            
            Button(t('memory.save'))
              .fontColor('#FFFFFF')
              .backgroundColor('#007AFF')
              .layoutWeight(1)
              .height(40)
              .onClick(() => {
                this.confirmRename();
              })
          }
          .width('100%')
          .margin({ top: 20 })
        }
        .width('80%')
        .padding(20)
        .borderRadius(12)
        .backgroundColor('#FFFFFF')
        .shadow({ radius: 8, color: '#00000033' })
      }
    }
    .width('100%')
    .height('100%')
  }
}
