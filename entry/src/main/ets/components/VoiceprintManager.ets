/**
 * VoiceprintManager - UI component for managing voiceprint enrollment and speakers.
 *
 * Provides:
 * - Speaker list with enrollment info
 * - Enrollment flow (record 3 audio samples, extract embeddings, register)
 * - Speaker removal
 */
import { promptAction } from '@kit.ArkUI';
import { audio } from '@kit.AudioKit';
import { common } from '@kit.AbilityKit';
import { I18n } from '../common/I18n';
import { VoiceprintService, VoiceprintProfile } from '../service/VoiceprintService';

const ENROLLMENT_PROMPTS_ZH: string[] = [
  '今天天气真不错，我们一起出去散步吧',
  '最近工作很忙，不过周末可以好好休息',
  '我喜欢在安静的环境里读书和思考',
];

const ENROLLMENT_PROMPTS_EN: string[] = [
  'The weather is great today, let\'s go for a walk together',
  'Work has been busy lately, but I can rest well on weekends',
  'I enjoy reading and thinking in a quiet environment',
];

const SAMPLE_RATE = 16000;
const RECORD_DURATION_MS = 5000;
const REQUIRED_SAMPLES = 3;

@Component
export struct VoiceprintManager {
  @State speakers: VoiceprintProfile[] = [];
  @State isEnrolling: boolean = false;
  @State enrollStep: number = 0; // 0=name, 1..3=recording samples
  @State enrollName: string = '';
  @State isRecording: boolean = false;
  @State recordProgress: number = 0;
  @State enrolledSamples: Float32Array[] = [];
  @State enrollStatus: string = '';
  @State @Watch('onLangChange') lang: string = 'zh';
  @State showDeleteConfirm: boolean = false;
  @State deleteSpeakerName: string = '';

  private vpService: VoiceprintService = VoiceprintService.getInstance();
  private capturer: audio.AudioCapturer | null = null;
  private recordChunks: ArrayBuffer[] = [];
  private progressTimer: number = -1;
  private langListener: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    this.lang = I18n.lang;
    this.langListener = () => { this.lang = I18n.lang; };
    I18n.addListener(this.langListener);
    this.initService();
  }

  async initService(): Promise<void> {
    if (!this.vpService.isInitialized()) {
      const ctx = getContext(this) as common.UIAbilityContext;
      const ok = await this.vpService.init(ctx);
      if (!ok) {
        console.error('[VoiceprintManager]', 'Failed to initialize voiceprint service');
      }
    }
    this.loadSpeakers();
  }

  aboutToDisappear(): void {
    if (this.langListener) {
      I18n.removeListener(this.langListener);
      this.langListener = undefined;
    }
    this.stopRecording();
  }

  onLangChange(): void {
    // triggers re-render
  }

  loadSpeakers(): void {
    this.speakers = this.vpService.listSpeakers();
  }

  build() {
    Column() {
      // Header
      Row() {
        Text(I18n.t('voiceprint.title'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1A1A1A')
          .layoutWeight(1)
        Text(`${this.speakers.length} ${I18n.t('voiceprint.speakerCount')}`)
          .fontSize(12)
          .fontColor('#999999')
      }
      .width('100%')
      .padding({ bottom: 12 })

      if (this.isEnrolling) {
        this.EnrollmentFlow()
      } else {
        this.SpeakerList()
      }
    }
    .width('100%')
  }

  @Builder
  SpeakerList() {
    Column() {
      if (this.speakers.length === 0) {
        Column() {
          Text(I18n.t('voiceprint.empty'))
            .fontSize(14)
            .fontColor('#999999')
            .textAlign(TextAlign.Center)
            .padding({ top: 24, bottom: 24 })
        }
        .width('100%')
      } else {
        ForEach(this.speakers, (sp: VoiceprintProfile) => {
          Row() {
            Column() {
              Text(sp.name)
                .fontSize(15)
                .fontColor('#1A1A1A')
                .fontWeight(FontWeight.Medium)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(`${sp.sampleCount} ${I18n.t('voiceprint.samples')} | ${new Date(sp.enrolledAt).toLocaleDateString()}`)
                .fontSize(11)
                .fontColor('#999999')
                .margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Text(I18n.t('voiceprint.remove'))
              .fontSize(12)
              .fontColor('#D32F2F')
              .borderWidth(1)
              .borderColor('#D32F2F')
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .borderRadius(6)
              .onClick(() => {
                this.deleteSpeakerName = sp.name;
                this.showDeleteConfirm = true;
              })
          }
          .width('100%')
          .padding({ top: 10, bottom: 10 })

          Divider().color('#F0F0F0')
        })
      }

      // Add speaker button
      Button(I18n.t('voiceprint.enroll'))
        .width('100%')
        .height(44)
        .backgroundColor('#D2691E')
        .fontColor(Color.White)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .borderRadius(10)
        .margin({ top: 16 })
        .onClick(() => {
          this.startEnrollment();
        })

      // Delete confirmation dialog
      if (this.showDeleteConfirm) {
        this.DeleteConfirmDialog()
      }
    }
    .width('100%')
  }

  @Builder
  DeleteConfirmDialog() {
    Column() {
      Text(I18n.t('voiceprint.deleteConfirm').replace('{0}', this.deleteSpeakerName))
        .fontSize(14)
        .fontColor('#1A1A1A')
        .textAlign(TextAlign.Center)
        .padding(16)
        .width('100%')

      Row({ space: 12 }) {
        Button(I18n.t('voiceprint.cancel'))
          .layoutWeight(1)
          .height(38)
          .backgroundColor('#F0F0F0')
          .fontColor('#666666')
          .fontSize(14)
          .borderRadius(8)
          .onClick(() => {
            this.showDeleteConfirm = false;
            this.deleteSpeakerName = '';
          })

        Button(I18n.t('voiceprint.confirmDelete'))
          .layoutWeight(1)
          .height(38)
          .backgroundColor('#D32F2F')
          .fontColor(Color.White)
          .fontSize(14)
          .borderRadius(8)
          .onClick(async () => {
            await this.vpService.removeSpeaker(this.deleteSpeakerName);
            this.showDeleteConfirm = false;
            this.deleteSpeakerName = '';
            this.loadSpeakers();
            promptAction.showToast({ message: I18n.t('voiceprint.removed') });
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 16 })
    }
    .width('100%')
    .backgroundColor('#FFF3E0')
    .borderRadius(10)
    .margin({ top: 12 })
  }

  @Builder
  EnrollmentFlow() {
    Column() {
      if (this.enrollStep === 0) {
        // Step 0: Enter name
        Text(I18n.t('voiceprint.enterName'))
          .fontSize(14)
          .fontColor('#1A1A1A')
          .width('100%')

        TextInput({ text: this.enrollName, placeholder: I18n.t('voiceprint.namePlaceholder') })
          .height(40)
          .backgroundColor('#F5F5F5')
          .borderRadius(8)
          .margin({ top: 8 })
          .onChange((v: string) => { this.enrollName = v; })

        Row({ space: 12 }) {
          Button(I18n.t('voiceprint.cancel'))
            .layoutWeight(1)
            .height(40)
            .backgroundColor('#F0F0F0')
            .fontColor('#666666')
            .fontSize(14)
            .borderRadius(8)
            .onClick(() => { this.cancelEnrollment(); })

          Button(I18n.t('voiceprint.next'))
            .layoutWeight(1)
            .height(40)
            .backgroundColor(this.enrollName.trim().length > 0 ? '#D2691E' : '#CCCCCC')
            .fontColor(Color.White)
            .fontSize(14)
            .borderRadius(8)
            .enabled(this.enrollName.trim().length > 0)
            .onClick(() => {
              if (this.vpService.containsSpeaker(this.enrollName.trim())) {
                promptAction.showToast({ message: I18n.t('voiceprint.nameExists') });
                return;
              }
              this.enrollStep = 1;
            })
        }
        .width('100%')
        .margin({ top: 16 })
      } else if (this.enrollStep <= REQUIRED_SAMPLES) {
        // Step 1-3: Record samples
        Text(`${I18n.t('voiceprint.recordStep')} (${this.enrollStep}/${REQUIRED_SAMPLES})`)
          .fontSize(14)
          .fontColor('#1A1A1A')
          .fontWeight(FontWeight.Medium)
          .width('100%')

        Text(I18n.t('voiceprint.readAloud'))
          .fontSize(12)
          .fontColor('#999999')
          .margin({ top: 4 })
          .width('100%')

        Text(`"${(I18n.lang === 'zh' ? ENROLLMENT_PROMPTS_ZH : ENROLLMENT_PROMPTS_EN)[(this.enrollStep - 1) % (I18n.lang === 'zh' ? ENROLLMENT_PROMPTS_ZH : ENROLLMENT_PROMPTS_EN).length]}"`)

          .fontSize(15)
          .fontColor('#D2691E')
          .fontStyle(FontStyle.Italic)
          .margin({ top: 12 })
          .padding(12)
          .width('100%')
          .backgroundColor('#FFF3E0')
          .borderRadius(8)
          .textAlign(TextAlign.Center)

        // Progress bar
        if (this.isRecording) {
          Column() {
            Progress({ value: this.recordProgress, total: 100 })
              .width('100%')
              .color('#D2691E')
              .margin({ top: 16 })

            Text(`${I18n.t('voiceprint.recording')} ${Math.round(this.recordProgress)}%`)
              .fontSize(12)
              .fontColor('#D2691E')
              .margin({ top: 4 })
          }
          .width('100%')
        }

        if (this.enrollStatus.length > 0) {
          Text(this.enrollStatus)
            .fontSize(12)
            .fontColor('#4CAF50')
            .margin({ top: 8 })
            .width('100%')
            .textAlign(TextAlign.Center)
        }

        Row({ space: 12 }) {
          Button(I18n.t('voiceprint.cancel'))
            .layoutWeight(1)
            .height(40)
            .backgroundColor('#F0F0F0')
            .fontColor('#666666')
            .fontSize(14)
            .borderRadius(8)
            .onClick(() => { this.cancelEnrollment(); })

          Button(this.isRecording ? I18n.t('voiceprint.recording') : I18n.t('voiceprint.startRecord'))
            .layoutWeight(1)
            .height(40)
            .backgroundColor(this.isRecording ? '#999999' : '#4CAF50')
            .fontColor(Color.White)
            .fontSize(14)
            .borderRadius(8)
            .enabled(!this.isRecording)
            .onClick(() => { this.recordSample(); })
        }
        .width('100%')
        .margin({ top: 16 })
      } else {
        // Step 4: Processing & result
        Column() {
          Text(I18n.t('voiceprint.processing'))
            .fontSize(15)
            .fontColor('#1A1A1A')
            .fontWeight(FontWeight.Medium)

          if (this.enrollStatus.length > 0) {
            Text(this.enrollStatus)
              .fontSize(13)
              .fontColor(this.enrollStatus.includes(I18n.t('voiceprint.success'))
                ? '#4CAF50' : '#D32F2F')
              .margin({ top: 12 })
              .textAlign(TextAlign.Center)
          }

          Button(I18n.t('voiceprint.done'))
            .width('100%')
            .height(40)
            .backgroundColor('#D2691E')
            .fontColor(Color.White)
            .fontSize(14)
            .borderRadius(8)
            .margin({ top: 16 })
            .onClick(() => {
              this.isEnrolling = false;
              this.loadSpeakers();
            })
        }
        .width('100%')
        .padding({ top: 16 })
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
  }

  // ---- Enrollment logic ----

  startEnrollment(): void {
    this.isEnrolling = true;
    this.enrollStep = 0;
    this.enrollName = '';
    this.enrolledSamples = [];
    this.enrollStatus = '';
    this.isRecording = false;
    this.recordProgress = 0;
  }

  cancelEnrollment(): void {
    this.stopRecording();
    this.isEnrolling = false;
    this.enrollStep = 0;
    this.enrollName = '';
    this.enrolledSamples = [];
    this.enrollStatus = '';
  }

  async recordSample(): Promise<void> {
    if (this.isRecording) return;

    try {
      this.isRecording = true;
      this.recordProgress = 0;
      this.enrollStatus = '';
      this.recordChunks = [];

      const audioStreamInfo: audio.AudioStreamInfo = {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
      };

      const capturerInfo: audio.AudioCapturerInfo = {
        source: audio.SourceType.SOURCE_TYPE_MIC,
        capturerFlags: 0,
      };

      this.capturer = await audio.createAudioCapturer({
        streamInfo: audioStreamInfo,
        capturerInfo: capturerInfo,
      });

      this.capturer.on('readData', (buffer: ArrayBuffer) => {
        this.recordChunks.push(buffer.slice(0));
      });

      await this.capturer.start();

      // Progress timer
      const startTime = Date.now();
      this.progressTimer = setInterval(() => {
        const elapsed = Date.now() - startTime;
        this.recordProgress = Math.min(100, (elapsed / RECORD_DURATION_MS) * 100);
      }, 100) as number;

      // Wait for recording duration
      await new Promise<void>((resolve) => setTimeout(resolve, RECORD_DURATION_MS));

      // Stop recording
      await this.stopRecording();

      // Process recorded audio
      const pcm = this.chunksToFloat32();
      if (pcm.length < SAMPLE_RATE) {
        this.enrollStatus = I18n.t('voiceprint.tooShort');
        this.isRecording = false;
        return;
      }

      this.enrolledSamples.push(pcm);
      this.enrollStatus = I18n.t('voiceprint.sampleOk');

      // Move to next step
      if (this.enrolledSamples.length >= REQUIRED_SAMPLES) {
        this.enrollStep = REQUIRED_SAMPLES + 1;
        this.finishEnrollment();
      } else {
        this.enrollStep = this.enrolledSamples.length + 1;
      }

      this.isRecording = false;
    } catch (e) {
      console.error('[VoiceprintManager]', 'Recording error:', JSON.stringify(e));
      this.isRecording = false;
      this.enrollStatus = I18n.t('voiceprint.recordFailed');
    }
  }

  async stopRecording(): Promise<void> {
    if (this.progressTimer >= 0) {
      clearInterval(this.progressTimer);
      this.progressTimer = -1;
    }
    if (this.capturer) {
      try {
        await this.capturer.stop();
        await this.capturer.release();
      } catch { /* ignore */ }
      this.capturer = null;
    }
  }

  async finishEnrollment(): Promise<void> {
    this.enrollStatus = I18n.t('voiceprint.processing');

    const ok = await this.vpService.enrollSpeaker(this.enrollName.trim(), this.enrolledSamples);
    if (ok) {
      this.enrollStatus = `${I18n.t('voiceprint.success')} - ${this.enrollName}`;
    } else {
      this.enrollStatus = I18n.t('voiceprint.enrollFailed');
    }
  }

  private chunksToFloat32(): Float32Array {
    // Merge Int16 chunks and normalize to Float32 [-1, 1]
    let totalLen = 0;
    for (const chunk of this.recordChunks) {
      totalLen += chunk.byteLength;
    }

    const merged = new Int16Array(totalLen / 2);
    let offset = 0;
    for (const chunk of this.recordChunks) {
      const view = new Int16Array(chunk);
      merged.set(view, offset);
      offset += view.length;
    }

    const float32 = new Float32Array(merged.length);
    for (let i = 0; i < merged.length; i++) {
      float32[i] = merged[i] / 32768.0;
    }
    return float32;
  }
}
