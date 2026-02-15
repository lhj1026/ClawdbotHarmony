import { ChatMessage, InlineButton } from '../model/Models';
import { I18n } from '../common/I18n';
import { MarkdownText } from './MarkdownText';
import { media } from '@kit.MediaKit';
import { fileIo } from '@kit.CoreFileKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { LogService } from '../common/LogService';

@Component
export struct MessageBubble {
  @ObjectLink message: ChatMessage;
  @Prop assistantAvatar: string = '';
  @Prop assistantName: string = '';
  onImageClick: (path: string) => void = () => {};
  onFeedback: (msgId: string, type: string) => void = () => {};
  onButtonClick: (action: string) => void = () => {};
  @State audioPlaying: boolean = false;
  private avPlayer: media.AVPlayer | undefined = undefined;
  private log: LogService = LogService.getInstance();

  build() {
    if (this.message.role === 'user') {
      this.UserBubble()
    } else if (this.message.isToolCall) {
      // Hide tool call JSON bubbles — they clutter the chat
    } else if (this.message.role === 'tool') {
      // Only show tool results that have media content (photo/audio/video)
      if (this.message.imagePath.length > 0 || this.message.audioPath.length > 0 || this.message.videoPath.length > 0) {
        this.ToolResultBubble()
      }
      // else: hide plain JSON tool results
    } else if (this.message.content.length > 0) {
      this.AssistantBubble()
    }
  }

  @Builder
  UserBubble() {
    Column() {
      Text(this.formatTime(this.message.timestamp))
        .fontSize(10)
        .fontColor('#BBBBBB')
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ bottom: 4 })

      Row() {
        Blank()
        Column() {
          // User attached image
          if (this.message.userImagePath.length > 0) {
            Image(this.message.userImagePath.startsWith('file://') ? this.message.userImagePath : 'file://' + this.message.userImagePath)
              .constraintSize({ maxWidth: '100%', maxHeight: 240 })
              .objectFit(ImageFit.Contain)
              .borderRadius(8)
              .margin({ top: 8, bottom: 4 })
              .onClick(() => { this.onImageClick(this.message.userImagePath); })
          }

          // File attachment indicator
          if (this.message.attachmentName.length > 0) {
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
          if (this.message.audioPath.length > 0) {
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
          if (this.message.content.length > 0) {
            Text(this.message.content)
              .fontSize(15)
              .fontColor(Color.White)
              .lineHeight(22)
              .padding(this.message.audioPath.length > 0
                ? { left: 12, right: 12, top: 2, bottom: 12 }
                : 12)
          }
        }
        .backgroundColor('#D2691E')
        .borderRadius({
          topLeft: 16, topRight: 4, bottomLeft: 16, bottomRight: 16
        })
        .constraintSize({ maxWidth: '82%' })
        .gesture(
          GestureGroup(GestureMode.Exclusive,
            LongPressGesture().onAction(() => {
              this.copyToClipboard(this.message.content);
            }),
            TapGesture().onAction(() => {
              if (this.message.audioPath.length > 0) {
                this.toggleAudioPlayback();
              }
            })
          )
        )
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 20, top: 4, bottom: 4 })
  }

  @Builder
  AssistantAvatarIcon(size: number) {
    if (this.assistantAvatar.length > 0) {
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
      Text(this.formatTime(this.message.timestamp))
        .fontSize(10)
        .fontColor('#BBBBBB')
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ bottom: 4 })

      Row() {
        Column() {
          this.AssistantAvatarIcon(30)
        }
        .margin({ right: 8, top: 2 })

        Column() {
          MarkdownText({
            content: this.message.imagePath.length > 0 ? this.stripImagePaths(this.message.content) : this.message.content,
            textColor: '#1A1A1A',
            baseFontSize: 15
          })

          if (this.message.imagePath.length > 0) {
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
          if (this.message.videoPath.length > 0) {
            Video({ src: this.message.videoPath })
              .width('100%')
              .constraintSize({ maxHeight: 280 })
              .objectFit(ImageFit.Contain)
              .borderRadius(8)
              .margin({ top: 6 })
              .autoPlay(false)
              .controls(true)
          }

          // Inline buttons
          if (this.message.buttons.length > 0) {
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

          // Feedback row (thumbs up/down)
          Row({ space: 16 }) {
            Text('\uD83D\uDC4D')
              .fontSize(16)
              .opacity(this.message.feedback === 'up' ? 1.0 : 0.3)
              .onClick(() => {
                let newFb = this.message.feedback === 'up' ? '' : 'up';
                this.message.feedback = newFb;
                this.onFeedback(this.message.id, newFb);
              })
            Text('\uD83D\uDC4E')
              .fontSize(16)
              .opacity(this.message.feedback === 'down' ? 1.0 : 0.3)
              .onClick(() => {
                let newFb = this.message.feedback === 'down' ? '' : 'down';
                this.message.feedback = newFb;
                this.onFeedback(this.message.id, newFb);
              })
          }
          .margin({ top: 4 })
          .justifyContent(FlexAlign.End)
          .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 14, right: 14, top: 12, bottom: 8 })
        .backgroundColor('#F0F0F0')
        .borderRadius({
          topLeft: 4, topRight: 16, bottomLeft: 16, bottomRight: 16
        })
        .layoutWeight(1)
        .gesture(LongPressGesture().onAction(() => {
          this.copyToClipboard(this.message.content);
        }))

        Blank()
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
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

        if (this.message.toolInput.length > 0) {
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

        if (this.message.videoPath.length > 0) {
          // Display recorded video
          Video({ src: this.message.videoPath })
            .width('100%')
            .constraintSize({ maxHeight: 280 })
            .objectFit(ImageFit.Contain)
            .borderRadius(8)
            .margin({ top: 6 })
            .autoPlay(false)
            .controls(true)
        } else if (this.message.imagePath.length > 0) {
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
        } else if (this.message.audioPath.length > 0) {
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

  private getAssistantInitial(): string {
    if (this.assistantName.length > 0) {
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
