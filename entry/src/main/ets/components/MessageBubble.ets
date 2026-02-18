import { ChatMessage, InlineButton } from '../model/Models';
import { I18n } from '../common/I18n';
import { MarkdownText } from './MarkdownText';
import { media } from '@kit.MediaKit';
import { fileIo } from '@kit.CoreFileKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { LogService } from '../common/LogService';
import { request } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';

@Component
export struct MessageBubble {
  @ObjectLink message: ChatMessage;
  @Prop assistantAvatar: string = '';
  @Prop assistantName: string = '';
  @Prop showTimestamp: boolean = true;
  onImageClick: (path: string) => void = () => {};
  onButtonClick: (action: string) => void = () => {};
  onA2UIReady: (inject: (content: string) => void) => void = () => {};
  onA2UIAction: (json: string) => void = () => {};
  onCanvasReady: (ctrl: webview.WebviewController) => void = () => {};
  onCanvasAction: (json: string) => void = () => {};
  onReply: (message: ChatMessage) => void = () => {};
  onNewSession: (message: ChatMessage) => void = () => {};
  onQuoteClick: (replyToId: string) => void = () => {};
  onFileDownload: (message: ChatMessage) => void = () => {};
  onFileOpen: (filePath: string) => void = () => {};
  onFilePathClick: (filePath: string) => void = () => {};
  @State audioPlaying: boolean = false;
  @State showMenu: boolean = false;
  @State a2uiHeight: number = 280;
  @State canvasHeight: number = 400;
  private avPlayer: media.AVPlayer | undefined = undefined;
  private a2uiController: webview.WebviewController | undefined = undefined;
  private canvasController: webview.WebviewController | undefined = undefined;
  private log: LogService = LogService.getInstance();

  build() {
    if (this.message.role === 'user') {
      this.UserBubble()
    } else if (this.message.isToolCall) {
      // Hide tool call JSON bubbles — they clutter the chat
    } else if (this.message.role === 'tool') {
      // Only show tool results that have media content (photo/audio/video)
      if (this.sLen(this.message.imagePath) > 0 || this.sLen(this.message.audioPath) > 0 || this.sLen(this.message.videoPath) > 0) {
        this.ToolResultBubble()
      }
      // else: hide plain JSON tool results
    } else if (this.sLen(this.message.content) > 0 || this.sLen(this.message.a2uiContent) > 0 || this.sLen(this.message.canvasUrl) > 0 || this.sLen(this.message.fileName) > 0) {
      this.AssistantBubble()
    }
  }

  @Builder
  UserBubble() {
    Column() {
      if (this.showTimestamp) {
        Text(this.formatTime(this.message.timestamp))
          .fontSize(10)
          .fontColor('#BBBBBB')
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ bottom: 4 })
      }

      Row() {
        Blank()
        Column() {
          // User attached images
          if (this.aLen(this.message.userImagePaths) > 1) {
            // Multiple images — 2-column grid using nested Rows
            Column({ space: 4 }) {
              ForEach(this.getImageRows(), (row: string[]) => {
                Row({ space: 4 }) {
                  ForEach(row, (imgPath: string) => {
                    Image(imgPath.startsWith('file://') ? imgPath : 'file://' + imgPath)
                      .layoutWeight(1)
                      .height(120)
                      .objectFit(ImageFit.Cover)
                      .borderRadius(6)
                      .onClick(() => { this.onImageClick(imgPath); })
                  }, (imgPath: string) => imgPath)
                }
                .width('100%')
              }, (row: string[], idx?: number) => `row_${idx}`)
            }
            .padding(6)
          } else if (this.aLen(this.message.userImagePaths) === 1 || this.sLen(this.message.userImagePath) > 0) {
            // Single image
            Image(this.getSingleImageSrc())
              .constraintSize({ maxHeight: 240 })
              .objectFit(ImageFit.Contain)
              .borderRadius(8)
              .margin({ top: 8, bottom: 4 })
              .onClick(() => {
                let paths = this.safePaths();
                let p = paths.length > 0 ? paths[0] : this.message.userImagePath;
                this.onImageClick(p);
              })
          }

          // File attachment indicator
          if (this.sLen(this.message.attachmentName) > 0) {
            Row({ space: 6 }) {
              Text('\uD83D\uDCC4').fontSize(14)
              Text(this.message.attachmentName)
                .fontSize(12)
                .fontColor('rgba(255,255,255,0.8)')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .padding({ left: 12, right: 12, top: 8, bottom: 4 })
          }

          // Voice message: audio indicator + label (tap entire bubble to play)
          if (this.sLen(this.message.audioPath) > 0) {
            Row({ space: 8 }) {
              // Audio indicator bars
              Row({ space: 3 }) {
                ForEach([1, 2, 3, 4, 5], (i: number) => {
                  Column()
                    .width(3)
                    .height(this.audioPlaying ? (8 + (i % 3) * 6) : 10)
                    .borderRadius(1.5)
                    .backgroundColor('rgba(255,255,255,0.7)')
                }, (i: number): string => i.toString())
              }
              .height(24)
              .alignItems(VerticalAlign.Center)

              Text(this.audioPlaying ? I18n.t('chat.audioPlaying') : I18n.t('chat.voiceMessage'))
                .fontSize(12)
                .fontColor('rgba(255,255,255,0.8)')
            }
            .padding({ left: 12, right: 12, top: 10, bottom: 2 })
          }

          // Text content (or ASR transcription below voice indicator)
          if (this.sLen(this.message.content) > 0) {
            Text(this.message.content)
              .fontSize(15)
              .fontColor(Color.White)
              .lineHeight(22)
              .padding(this.sLen(this.message.audioPath) > 0
                ? { left: 12, right: 12, top: 2, bottom: 12 }
                : 12)
          }

        }
        .backgroundColor('#D2691E')
        .borderRadius({
          topLeft: 16, topRight: 4, bottomLeft: 16, bottomRight: 16
        })
        .constraintSize({ maxWidth: '82%' })
        .clip(true)
        .gesture(
          GestureGroup(GestureMode.Exclusive,
            LongPressGesture().onAction(() => {
              this.showMenu = true;
            }),
            TapGesture().onAction(() => {
              if (this.sLen(this.message.audioPath) > 0) {
                this.toggleAudioPlayback();
              }
            })
          )
        )
        .bindPopup(this.showMenu, {
          builder: this.MessageMenuPopup,
          placement: Placement.Top,
          popupColor: Color.White,
          onStateChange: (e) => {
            if (!e.isVisible) this.showMenu = false;
          }
        })
      }
      .width('100%')

      // Reply quote bar (below bubble)
      if (this.sLen(this.message.replyToId) > 0) {
        Row() {
          Blank()
          Row({ space: 6 }) {
            Column()
              .width(2)
              .height(14)
              .backgroundColor('#CCCCCC')
              .borderRadius(1)
            Text((this.message.replyToRole === 'user' ? I18n.t('chat.you') : this.assistantName || 'Assistant') + ': ' + this.message.replyToContent)
              .fontSize(11)
              .fontColor('#999999')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor('#F0F0F0')
          .borderRadius(8)
          .constraintSize({ maxWidth: '75%' })
          .alignItems(VerticalAlign.Center)
          .onClick(() => { this.onQuoteClick(this.message.replyToId); })
        }
        .width('100%')
        .margin({ top: 2 })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 20, top: 4, bottom: 4 })
  }

  @Builder
  MessageMenuPopup() {
    Row({ space: 0 }) {
      Text(I18n.t('chat.copy'))
        .fontSize(14)
        .fontColor('#333333')
        .padding({ left: 20, right: 16, top: 10, bottom: 10 })
        .onClick(() => {
          this.showMenu = false;
          this.copyToClipboard(this.message.content);
          promptAction.showToast({ message: '已复制' });
        })
      Divider()
        .vertical(true)
        .height(16)
        .color('#E0E0E0')
      Text(I18n.t('chat.reply'))
        .fontSize(14)
        .fontColor('#007AFF')
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
        .onClick(() => {
          this.showMenu = false;
          this.onReply(this.message);
        })
      Divider()
        .vertical(true)
        .height(16)
        .color('#E0E0E0')
      Text(I18n.t('chat.newSession'))
        .fontSize(14)
        .fontColor('#34C759')
        .padding({ left: 16, right: 20, top: 10, bottom: 10 })
        .onClick(() => {
          this.showMenu = false;
          this.onNewSession(this.message);
        })
    }
  }

  @Builder
  AssistantAvatarIcon(size: number) {
    if (this.sLen(this.assistantAvatar) > 0) {
      Image(this.assistantAvatar.startsWith('http') || this.assistantAvatar.startsWith('data:')
        ? this.assistantAvatar : 'file://' + this.assistantAvatar)
        .width(size)
        .height(size)
        .borderRadius(size / 2)
        .objectFit(ImageFit.Cover)
    } else {
      Text(this.getAssistantInitial())
        .fontSize(size * 0.43)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .textAlign(TextAlign.Center)
        .width(size)
        .height(size)
        .borderRadius(size / 2)
        .backgroundColor('#D2691E')
    }
  }

  @Builder
  AssistantBubble() {
    Column() {
      if (this.showTimestamp) {
        Text(this.formatTime(this.message.timestamp))
          .fontSize(10)
          .fontColor('#BBBBBB')
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ bottom: 4 })
      }

      Row() {
        Column() {
          this.AssistantAvatarIcon(30)
        }
        .margin({ right: 8, top: 2 })

        Column() {
          MarkdownText({
            content: this.getDisplayContent(),
            textColor: '#1A1A1A',
            baseFontSize: 15,
            onFilePathClick: (fp: string): void => { this.onFilePathClick(fp); }
          })

          if (this.sLen(this.message.imagePath) > 0) {
            Image(this.message.imagePath.startsWith('file://') ? this.message.imagePath : 'file://' + this.message.imagePath)
              .width('100%')
              .constraintSize({ maxHeight: 280 })
              .objectFit(ImageFit.Contain)
              .borderRadius(8)
              .margin({ top: 6 })
              .onClick(() => {
                this.onImageClick(this.message.imagePath);
              })
          }

          // Video display
          if (this.sLen(this.message.videoPath) > 0) {
            Video({ src: this.message.videoPath })
              .width('100%')
              .constraintSize({ maxHeight: 280 })
              .objectFit(ImageFit.Contain)
              .borderRadius(8)
              .margin({ top: 6 })
              .autoPlay(false)
              .controls(true)
          }

          // File attachment display
          if (this.sLen(this.message.fileName) > 0) {
            this.FileAttachmentView()
          }

          // Inline A2UI rendering
          if (this.sLen(this.message.a2uiContent) > 0) {
            this.A2UIView()
          }

          // Inline canvas rendering (canvas.present + canvas.navigate)
          if (this.sLen(this.message.canvasUrl) > 0) {
            this.CanvasView()
          }

          // Inline buttons
          if (this.aLen(this.message.buttons) > 0) {
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.message.buttons, (btn: InlineButton) => {
                Text(btn.label)
                  .fontSize(13)
                  .fontColor('#D2691E')
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .borderRadius(14)
                  .borderWidth(1)
                  .borderColor('#D2691E')
                  .margin(3)
                  .onClick(() => { this.onButtonClick(btn.action); })
              }, (btn: InlineButton): string => btn.label)
            }
            .margin({ top: 8 })
          }

        }
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 14, right: 14, top: 12, bottom: 8 })
        .backgroundColor('#F0F0F0')
        .borderRadius({
          topLeft: 4, topRight: 16, bottomLeft: 16, bottomRight: 16
        })
        .layoutWeight(1)
        .gesture(LongPressGesture().onAction(() => {
          this.showMenu = true;
        }))
        .bindPopup(this.showMenu, {
          builder: this.MessageMenuPopup,
          placement: Placement.Top,
          popupColor: Color.White,
          onStateChange: (e) => {
            if (!e.isVisible) this.showMenu = false;
          }
        })

        Blank()
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // Reply quote bar (below bubble)
      if (this.sLen(this.message.replyToId) > 0) {
        Row() {
          Blank().width(38)
          Row({ space: 6 }) {
            Column()
              .width(2)
              .height(14)
              .backgroundColor('#CCCCCC')
              .borderRadius(1)
            Text((this.message.replyToRole === 'user' ? I18n.t('chat.you') : this.assistantName || 'Assistant') + ': ' + this.message.replyToContent)
              .fontSize(11)
              .fontColor('#999999')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor('#E8E8E8')
          .borderRadius(8)
          .alignItems(VerticalAlign.Center)
          .onClick(() => { this.onQuoteClick(this.message.replyToId); })
          Blank()
        }
        .width('100%')
        .margin({ top: 2 })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 20, top: 4, bottom: 4 })
  }

  @Builder
  ToolCallBubble() {
    Row() {
      Blank().width(38)
      Column() {
        Row({ space: 6 }) {
          Text('\u2699')
            .fontSize(13)
          Text(this.message.toolName)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#795548')
        }

        if (this.sLen(this.message.toolInput) > 0) {
          Text(this.formatJson(this.message.toolInput))
            .fontSize(11)
            .fontColor('#EEFFFF')
            .fontFamily('monospace')
            .padding(8)
            .backgroundColor('#263238')
            .borderRadius(6)
            .margin({ top: 4 })
            .constraintSize({ maxHeight: 80 })
            .copyOption(CopyOptions.LocalDevice)
        }
      }
      .padding(10)
      .backgroundColor('#FFF8E1')
      .borderRadius(10)
      .constraintSize({ maxWidth: '80%' })

      Blank()
    }
    .width('100%')
    .padding({ left: 16, right: 20, top: 2, bottom: 2 })
  }

  private getA2UIController(): webview.WebviewController {
    if (!this.a2uiController) {
      this.a2uiController = new webview.WebviewController();
    }
    return this.a2uiController;
  }

  @Builder
  A2UIView() {
    Web({ src: 'resource://rawfile/a2ui/index.html', controller: this.getA2UIController() })
      .width('100%')
      .height(this.a2uiHeight)
      .borderRadius(8)
      .margin({ top: 6 })
      .backgroundColor('#0F0F1A')
      .javaScriptAccess(true)
      .domStorageAccess(true)
      .onPageEnd(() => {
        let ctrl = this.a2uiController;
        if (!ctrl) return;
        // Set inline mode styles
        ctrl.runJavaScript(
          "document.getElementById('a2ui-root').style.minHeight='auto';" +
          "document.getElementById('a2ui-root').style.padding='8px';" +
          "var emp=document.querySelector('.a2ui-empty');if(emp)emp.style.display='none';"
        );
        // Inject accumulated A2UI content
        let escaped = this.escapeForJS(this.message.a2uiContent);
        ctrl.runJavaScript(`window.a2ui.push('${escaped}')`);
        // Provide injection function to ChatPage for live updates
        this.onA2UIReady((content: string) => {
          let c = this.a2uiController;
          if (!c) return;
          let esc = this.escapeForJS(content);
          c.runJavaScript(`window.a2ui.push('${esc}')`);
        });
      })
      .onConsole((event) => {
        if (event && event.message) {
          let msg: string = event.message.getMessage();
          console.info('[A2UI-Console] ' + msg.substring(0, 200));
          if (msg.startsWith('A2UI_HEIGHT:')) {
            let h: number = parseInt(msg.substring(12));
            if (h > 0) {
              this.a2uiHeight = Math.min(h + 24, 600);
            }
          } else if (msg.startsWith('A2UI_ACTION:')) {
            console.info('[A2UI-Console] Detected action, calling callback...');
            this.onA2UIAction(msg.substring(12));
          }
        }
        return false;
      })
  }

  private getCanvasController(): webview.WebviewController {
    if (!this.canvasController) {
      this.canvasController = new webview.WebviewController();
    }
    return this.canvasController;
  }

  @Builder
  CanvasView() {
    Web({ src: this.message.canvasUrl, controller: this.getCanvasController() })
      .id('inlineCanvasWebView')
      .width('100%')
      .height(this.canvasHeight)
      .borderRadius(8)
      .margin({ top: 6 })
      .backgroundColor('#FFFFFF')
      .javaScriptAccess(true)
      .domStorageAccess(true)
      .onPageEnd(() => {
        let ctrl = this.canvasController;
        if (ctrl) {
          this.onCanvasReady(ctrl);
        }
      })
      .onConsole((event) => {
        if (event && event.message) {
          let msg: string = event.message.getMessage();
          if (msg.startsWith('A2UI_ACTION:')) {
            this.onA2UIAction(msg.substring(12));
          }
        }
        return false;
      })
  }

  @Builder
  FileAttachmentView() {
    Row({ space: 12 }) {
      // File icon based on mime type
      Column() {
        Text(this.getFileIcon())
          .fontSize(28)
      }
      .width(48)
      .height(48)
      .backgroundColor('#E8F4FD')
      .borderRadius(8)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)

      // File info
      Column({ space: 4 }) {
        Text(this.message.fileName)
          .fontSize(14)
          .fontColor('#333333')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontWeight(FontWeight.Medium)

        Text(this.formatFileSize(this.message.fileSize))
          .fontSize(12)
          .fontColor('#999999')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // Download/Open button
      if (this.message.fileDownloading) {
        LoadingProgress()
          .width(24)
          .height(24)
          .color('#007AFF')
      } else if (this.message.fileDownloaded && this.sLen(this.message.filePath) > 0) {
        Text('📂')
          .fontSize(24)
          .onClick(() => {
            this.onFileOpen(this.message.filePath);
          })
      } else {
        Text('⬇️')
          .fontSize(24)
          .onClick(() => {
            this.onFileDownload(this.message);
          })
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#FFFFFF')
    .borderRadius(10)
    .borderWidth(1)
    .borderColor('#E0E0E0')
    .margin({ top: 8 })
  }

  /** Get file icon emoji based on mime type */
  private getFileIcon(): string {
    let mime = this.message.fileMimeType.toLowerCase();
    let name = this.message.fileName.toLowerCase();

    if (mime.startsWith('image/')) return '🖼️';
    if (mime.startsWith('video/')) return '🎬';
    if (mime.startsWith('audio/')) return '🎵';
    if (mime === 'application/pdf' || name.endsWith('.pdf')) return '📕';
    if (mime.includes('word') || name.endsWith('.doc') || name.endsWith('.docx')) return '📘';
    if (mime.includes('excel') || mime.includes('spreadsheet') || name.endsWith('.xls') || name.endsWith('.xlsx')) return '📗';
    if (mime.includes('powerpoint') || mime.includes('presentation') || name.endsWith('.ppt') || name.endsWith('.pptx')) return '📙';
    if (mime.includes('zip') || mime.includes('rar') || mime.includes('tar') || mime.includes('7z')) return '📦';
    if (mime.startsWith('text/') || name.endsWith('.txt') || name.endsWith('.md')) return '📄';
    if (mime.includes('json') || name.endsWith('.json')) return '📋';
    return '📎';
  }

  /** Format file size for display */
  private formatFileSize(bytes: number): string {
    if (bytes <= 0) return '';
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
    return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
  }

  @Builder
  ToolResultBubble() {
    Row() {
      Blank().width(38)
      Column() {
        Row({ space: 4 }) {
          Text('\u2713')
            .fontSize(13)
            .fontColor('#388E3C')
          Text(this.message.toolName + ' ' + I18n.t('chat.toolResult'))
            .fontSize(12)
            .fontColor('#666666')
        }

        if (this.sLen(this.message.videoPath) > 0) {
          // Display recorded video
          Video({ src: this.message.videoPath })
            .width('100%')
            .constraintSize({ maxHeight: 280 })
            .objectFit(ImageFit.Contain)
            .borderRadius(8)
            .margin({ top: 6 })
            .autoPlay(false)
            .controls(true)
        } else if (this.sLen(this.message.imagePath) > 0) {
          // Display captured photo
          Image(this.message.imagePath.startsWith('file://') ? this.message.imagePath : 'file://' + this.message.imagePath)
            .width('100%')
            .constraintSize({ maxHeight: 280 })
            .objectFit(ImageFit.Contain)
            .borderRadius(8)
            .margin({ top: 6 })
            .onClick(() => {
              this.onImageClick(this.message.imagePath);
            })
        } else if (this.sLen(this.message.audioPath) > 0) {
          // Audio playback control
          Row({ space: 10 }) {
            Text(this.audioPlaying ? '\u23F9' : '\u25B6\uFE0F')
              .fontSize(22)
              .width(36)
              .height(36)
              .textAlign(TextAlign.Center)
              .borderRadius(18)
              .backgroundColor(this.audioPlaying ? '#FFCDD2' : '#E8F5E9')
              .onClick(() => {
                this.toggleAudioPlayback();
              })
            Column({ space: 2 }) {
              Text(this.audioPlaying ? I18n.t('chat.audioPlaying') : I18n.t('chat.audioReady'))
                .fontSize(12)
                .fontColor('#333333')
              Text(this.message.audioPath.split('/').pop() ?? '')
                .fontSize(10)
                .fontColor('#999999')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')
          .padding({ top: 6, bottom: 2 })
        } else {
          Text(this.formatJson(this.message.toolOutput))
            .fontSize(11)
            .fontColor('#EEFFFF')
            .fontFamily('monospace')
            .padding(8)
            .backgroundColor('#263238')
            .borderRadius(6)
            .margin({ top: 4 })
            .constraintSize({ maxHeight: 80 })
            .copyOption(CopyOptions.LocalDevice)
        }
      }
      .padding(10)
      .backgroundColor('#F5F5F5')
      .borderRadius(10)
      .borderWidth(1)
      .borderColor('#E0E0E0')
      .constraintSize({ maxWidth: '80%' })

      Blank()
    }
    .width('100%')
    .padding({ left: 16, right: 20, top: 2, bottom: 2 })
  }

  private async toggleAudioPlayback(): Promise<void> {
    this.log.info('AudioPlay', `toggleAudioPlayback called, playing=${this.audioPlaying}, path=${this.message.audioPath}`);
    if (this.audioPlaying) {
      // Stop
      try {
        if (this.avPlayer) {
          await this.avPlayer.stop();
          await this.avPlayer.release();
          this.avPlayer = undefined;
        }
      } catch { /* ignore */ }
      this.audioPlaying = false;
    } else {
      // Play using fdSrc (HarmonyOS AVPlayer requires fd:// for local files)
      try {
        let filePath = this.message.audioPath;
        let stat = fileIo.statSync(filePath);
        let file = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
        this.log.info('AudioPlay', `File opened: fd=${file.fd}, size=${stat.size}`);

        let player = await media.createAVPlayer();
        this.avPlayer = player;
        this.log.info('AudioPlay', 'AVPlayer created');

        player.on('stateChange', (state: string) => {
          this.log.info('AudioPlay', `stateChange: ${state}`);
          switch (state) {
            case 'initialized':
              player.prepare();
              break;
            case 'prepared':
              player.play();
              break;
            case 'completed':
            case 'stopped':
            case 'error':
              this.audioPlaying = false;
              try { player.release(); } catch { /* ignore */ }
              try { fileIo.closeSync(file); } catch { /* ignore */ }
              this.avPlayer = undefined;
              break;
          }
        });
        player.on('error', (err: Error) => {
          this.log.error('AudioPlay', `error event: ${err.message ?? 'unknown'}`);
          this.audioPlaying = false;
          try { player.release(); } catch { /* ignore */ }
          try { fileIo.closeSync(file); } catch { /* ignore */ }
          this.avPlayer = undefined;
        });

        // Use fdSrc to trigger state machine
        player.fdSrc = { fd: file.fd, offset: 0, length: stat.size };
        this.audioPlaying = true;
      } catch (e) {
        this.log.error('AudioPlay', `Exception: ${(e as Error).message ?? String(e)}`);
        this.audioPlaying = false;
      }
    }
  }

  /** Get display content for assistant bubble, replacing HEARTBEAT_OK with friendly greeting. */
  private getDisplayContent(): string {
    let content = this.sLen(this.message.imagePath) > 0
      ? this.stripImagePaths(this.message.content)
      : this.message.content;
    let greeting = I18n.getHeartbeatGreeting(content);
    if (greeting.length > 0) {
      return greeting;
    }
    return content;
  }

  private getAssistantInitial(): string {
    if (this.sLen(this.assistantName) > 0) {
      return this.assistantName.charAt(0).toUpperCase();
    }
    return 'C';
  }

  private stripImagePaths(text: string): string {
    // Strip markdown image links: ![...](file:///data/...)
    let cleaned = text.replace(/!\[[^\]]*\]\([^)]*\/(?:screenshots|photos|camera_photos)\/[^)]+\)/g, '');
    // Strip raw file paths: /data/storage/.../xxx.jpg or /data/app/.../photos/xxx.jpg
    cleaned = cleaned.replace(/\/data\/[^\s\n"'）》]*\.(?:jpg|jpeg|png)/gi, '');
    // Strip "文件路径[：:]..." pattern (Chinese)
    cleaned = cleaned.replace(/文件路径[：:][^\n]*/g, '');
    // Strip "照片/自拍/截图已保存[！!]?" with optional file size info
    cleaned = cleaned.replace(/(?:照片|自拍|截图|图片)已保存[！!]?\s*(?:大小[^\n。]*)?[。.]?\s*/g, '');
    // Strip standalone "大小X.XXMB" / "文件大小..." patterns
    cleaned = cleaned.replace(/(?:文件)?大小[：:]?\s*\d+\.?\d*\s*[KMG]?B[。.]?\s*/gi, '');
    // Strip "这是截图的链接：" and similar phrases
    cleaned = cleaned.replace(/这是[^。]*链接[：:]\s*/g, '');
    cleaned = cleaned.replace(/你可以查看[：:]\s*/g, '');
    // Strip "File path:" pattern (English)
    cleaned = cleaned.replace(/[Ff]ile\s*[Pp]ath[：:][^\n]*/g, '');
    // Strip "Photo saved!" / "Screenshot saved!"
    cleaned = cleaned.replace(/(?:Photo|Screenshot|Image)\s*saved[!！]?\s*/gi, '');
    return cleaned.replace(/\n{3,}/g, '\n\n').trim();
  }

  /** Safe string length — handles undefined/null from deserialization */
  private sLen(s: string): number {
    if (s === undefined || s === null) return 0;
    return s.length;
  }

  /** Safe array length — handles undefined/null from deserialization */
  private aLen(a: Object[]): number {
    if (a === undefined || a === null) return 0;
    return a.length;
  }

  /** Safe userImagePaths accessor — always returns string[] */
  private safePaths(): string[] {
    let p = this.message.userImagePaths;
    if (p === undefined || p === null) return [];
    return p;
  }

  /** Split image paths into rows of 2 for grid display */
  private getImageRows(): string[][] {
    let paths = this.safePaths();
    let rows: string[][] = [];
    for (let i = 0; i < paths.length; i += 2) {
      if (i + 1 < paths.length) {
        rows.push([paths[i], paths[i + 1]]);
      } else {
        rows.push([paths[i]]);
      }
    }
    return rows;
  }

  /** Get image source string for single image display */
  private getSingleImageSrc(): string {
    let paths = this.safePaths();
    let p = paths.length > 0 ? paths[0] : (this.message.userImagePath ?? '');
    if (p.length === 0) return '';
    return p.startsWith('file://') ? p : 'file://' + p;
  }

  private escapeForJS(s: string): string {
    return s.replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/\n/g, '\\n');
  }

  private copyToClipboard(text: string): void {
    let pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    let systemPasteboard = pasteboard.getSystemPasteboard();
    systemPasteboard.setData(pasteData).then(() => {
      promptAction.showToast({ message: '已复制' });
    }).catch(() => {
      promptAction.showToast({ message: '复制失败' });
    });
  }

  private formatJson(s: string): string {
    try {
      return JSON.stringify(JSON.parse(s), null, 2);
    } catch {
      return s;
    }
  }

  private formatTime(ts: number): string {
    let d = new Date(ts);
    let h = d.getHours().toString().padStart(2, '0');
    let m = d.getMinutes().toString().padStart(2, '0');
    return `${h}:${m}`;
  }
}
