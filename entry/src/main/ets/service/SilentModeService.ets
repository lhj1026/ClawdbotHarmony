// Silent mode service: continuous background recording with VAD, speaker identification, and ASR
import { audio } from '@kit.AudioKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { SilentConversationRecord, SilentConversationEntry, SettingsData } from '../model/Models';
import { Constants } from '../common/Constants';
import { LogService } from '../common/LogService';
import { VoiceprintService } from './VoiceprintService';
import { LocalAsrService } from './LocalAsrService';
import { AIService } from './AIService';
import { ConversationStore } from './ConversationStore';

type StateListener = (state: string) => void;

export class SilentModeService {
  private static instance: SilentModeService;
  private log: LogService = LogService.getInstance();
  private readonly TAG = 'SilentMode';

  // State: 'idle' | 'listening' | 'processing'
  private state: string = 'idle';
  private stateListeners: StateListener[] = [];

  // Audio capture
  private audioCapturer: audio.AudioCapturer | undefined;
  private reading: boolean = false;

  // Current recording
  private currentRecord: SilentConversationRecord | undefined;
  private segmentBuffers: ArrayBuffer[] = [];
  private segmentStartTime: number = 0;
  private speechDetected: boolean = false;
  private silenceStartMs: number = 0;
  private lastSpeechMs: number = 0;

  // Ring buffer: keep max 5 minutes of audio (16kHz * 2 bytes * 300s = ~9.6MB)
  private static readonly MAX_RING_BYTES = 16000 * 2 * 300;
  private totalBufferBytes: number = 0;

  // Context
  private context: common.UIAbilityContext | undefined;

  private constructor() {}

  static getInstance(): SilentModeService {
    if (!SilentModeService.instance) {
      SilentModeService.instance = new SilentModeService();
    }
    return SilentModeService.instance;
  }

  getState(): string {
    return this.state;
  }

  isActive(): boolean {
    return this.state !== 'idle';
  }

  addStateListener(listener: StateListener): void {
    this.stateListeners.push(listener);
  }

  removeStateListener(listener: StateListener): void {
    let idx = this.stateListeners.indexOf(listener);
    if (idx >= 0) this.stateListeners.splice(idx, 1);
  }

  private setState(newState: string): void {
    this.state = newState;
    for (let listener of this.stateListeners) {
      try { listener(newState); } catch { /* ignore */ }
    }
  }

  async start(context: common.UIAbilityContext): Promise<boolean> {
    if (this.state !== 'idle') return false;

    this.context = context;

    // Request mic permission
    try {
      let atManager = abilityAccessCtrl.createAtManager();
      let permResult = await atManager.requestPermissionsFromUser(context, ['ohos.permission.MICROPHONE']);
      if (permResult.authResults[0] !== 0) {
        this.log.error(this.TAG, 'Mic permission denied');
        return false;
      }
    } catch (err) {
      this.log.error(this.TAG, `Permission error: ${(err as Error).message ?? ''}`);
      return false;
    }

    // Init store
    await ConversationStore.getInstance().init(context);

    // Init VoiceprintService
    try {
      await VoiceprintService.getInstance().init(context);
    } catch (err) {
      this.log.warn(this.TAG, `VoiceprintService init warning: ${err}`);
    }

    // Create conversation record
    let recordId = `silent_${Date.now()}_${Math.floor(Math.random() * 100000)}`;
    this.currentRecord = {
      id: recordId,
      startTime: Date.now(),
      endTime: 0,
      entries: [],
      summary: '',
      status: 'recording',
      participants: []
    };

    // Save initial record
    await ConversationStore.getInstance().saveRecord(this.currentRecord);

    // Create audio capturer (same config as ChatPage)
    try {
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
    } catch (err) {
      this.log.error(this.TAG, `AudioCapturer create failed: ${(err as Error).message ?? ''}`);
      this.currentRecord = undefined;
      return false;
    }

    // Reset segment state
    this.segmentBuffers = [];
    this.segmentStartTime = 0;
    this.speechDetected = false;
    this.silenceStartMs = 0;
    this.lastSpeechMs = Date.now();
    this.totalBufferBytes = 0;

    this.setState('listening');
    this.reading = true;
    this.audioReadLoop();

    this.log.info(this.TAG, `Started recording, record=${recordId}`);
    return true;
  }

  async stop(): Promise<void> {
    if (this.state === 'idle') return;

    this.reading = false;

    // Process remaining segment if any
    if (this.speechDetected && this.segmentBuffers.length > 0) {
      await this.processSegment();
    }

    // Stop capturer
    try {
      if (this.audioCapturer) {
        await this.audioCapturer.stop();
        await this.audioCapturer.release();
        this.audioCapturer = undefined;
      }
    } catch (err) {
      this.log.warn(this.TAG, `Capturer cleanup: ${(err as Error).message ?? ''}`);
    }

    // End conversation
    await this.endConversation();

    this.setState('idle');
    this.log.info(this.TAG, 'Stopped');
  }

  private async audioReadLoop(): Promise<void> {
    if (!this.audioCapturer) return;

    try {
      let bufSize = await this.audioCapturer.getBufferSize();

      while (this.reading && this.audioCapturer) {
        let buf: ArrayBuffer = await this.audioCapturer.read(bufSize, true);
        if (buf.byteLength === 0) continue;

        // Calculate RMS energy for VAD
        let rms = this.calculateRms(buf);
        let now = Date.now();

        if (rms > Constants.SILENT_MODE_VAD_THRESHOLD) {
          // Speech detected
          if (!this.speechDetected) {
            this.speechDetected = true;
            this.segmentStartTime = now;
            this.segmentBuffers = [];
            this.totalBufferBytes = 0;
          }
          this.silenceStartMs = 0;
          this.lastSpeechMs = now;
          this.addToSegmentBuffer(buf);
        } else if (this.speechDetected) {
          // Silence after speech
          this.addToSegmentBuffer(buf);
          if (this.silenceStartMs === 0) {
            this.silenceStartMs = now;
          } else if (now - this.silenceStartMs >= Constants.SILENT_MODE_SILENCE_END_MS) {
            // End of speech segment
            let segmentDuration = now - this.segmentStartTime;
            if (segmentDuration >= Constants.SILENT_MODE_MIN_SEGMENT_MS) {
              // Process segment async - don't block the read loop
              let buffers = this.segmentBuffers.slice();
              this.processSegment(buffers);
            }
            // Reset for next segment
            this.speechDetected = false;
            this.segmentBuffers = [];
            this.totalBufferBytes = 0;
            this.silenceStartMs = 0;
          }
        } else {
          // Silence, no speech detected - check conversation end timeout
          if (this.currentRecord && this.currentRecord.entries.length > 0 &&
            now - this.lastSpeechMs >= Constants.SILENT_MODE_CONVERSATION_END_MS) {
            // Long silence after conversation - end and start new record
            this.log.info(this.TAG, 'Conversation timeout, ending and starting new record');
            await this.endConversation();
            await this.startNewRecord();
            this.lastSpeechMs = now;
          }
        }
      }
    } catch (err) {
      this.log.error(this.TAG, `Audio read loop error: ${(err as Error).message ?? ''}`);
    }
  }

  private addToSegmentBuffer(buf: ArrayBuffer): void {
    // Ring buffer: drop oldest if exceeding max
    while (this.totalBufferBytes + buf.byteLength > SilentModeService.MAX_RING_BYTES && this.segmentBuffers.length > 0) {
      let removed = this.segmentBuffers.shift();
      if (removed) this.totalBufferBytes -= removed.byteLength;
    }
    this.segmentBuffers.push(buf.slice(0));
    this.totalBufferBytes += buf.byteLength;
  }

  private calculateRms(buf: ArrayBuffer): number {
    let int16 = new Int16Array(buf);
    let sum = 0;
    for (let i = 0; i < int16.length; i++) {
      sum += int16[i] * int16[i];
    }
    return Math.sqrt(sum / int16.length);
  }

  private chunksToFloat32(buffers: ArrayBuffer[]): Float32Array {
    // Calculate total Int16 samples
    let totalBytes = 0;
    for (let b of buffers) totalBytes += b.byteLength;
    let totalSamples = totalBytes / 2;

    // Merge into single Int16Array
    let merged = new Int16Array(totalSamples);
    let offset = 0;
    for (let b of buffers) {
      let chunk = new Int16Array(b);
      merged.set(chunk, offset);
      offset += chunk.length;
    }

    // Convert to Float32 normalized [-1.0, 1.0]
    let float32 = new Float32Array(totalSamples);
    for (let i = 0; i < totalSamples; i++) {
      float32[i] = merged[i] / 32768.0;
    }
    return float32;
  }

  private async processSegment(buffers?: ArrayBuffer[]): Promise<void> {
    let bufs = buffers || this.segmentBuffers;
    if (bufs.length === 0) return;

    this.setState('processing');

    try {
      // Convert to Float32 for voiceprint
      let float32 = this.chunksToFloat32(bufs);

      // Speaker identification
      let speaker = 'Unknown';
      let confidence = 0;
      try {
        let vpService = VoiceprintService.getInstance();
        let result = vpService.identify(float32, 16000);
        if (result.speaker && result.speaker !== 'unknown') {
          speaker = result.speaker;
          confidence = result.score;
        }
      } catch (err) {
        this.log.warn(this.TAG, `Speaker ID error: ${err}`);
      }

      // Speech-to-text via LocalAsrService
      let text = '';
      try {
        let asrService = LocalAsrService.getInstance();
        text = await asrService.recognizeFromPcm(bufs);
      } catch (err) {
        this.log.warn(this.TAG, `ASR error: ${err}`);
      }

      if (text.trim().length > 0 && this.currentRecord) {
        let entry: SilentConversationEntry = {
          timestamp: Date.now(),
          speaker: speaker,
          text: text.trim(),
          confidence: confidence
        };
        this.currentRecord.entries.push(entry);

        // Update participants
        if (!this.currentRecord.participants.includes(speaker)) {
          this.currentRecord.participants.push(speaker);
        }

        // Persist
        await ConversationStore.getInstance().saveRecord(this.currentRecord);
        this.log.info(this.TAG, `Entry: [${speaker}] ${text.trim().substring(0, 50)}`);
      }
    } catch (err) {
      this.log.error(this.TAG, `processSegment error: ${(err as Error).message ?? ''}`);
    }

    if (this.reading) {
      this.setState('listening');
    }
  }

  private async endConversation(): Promise<void> {
    if (!this.currentRecord) return;

    this.currentRecord.endTime = Date.now();

    if (this.currentRecord.entries.length === 0) {
      // No entries - just mark completed
      this.currentRecord.status = 'completed';
      await ConversationStore.getInstance().saveRecord(this.currentRecord);
      return;
    }

    // Generate summary via AI
    this.currentRecord.status = 'summarizing';
    await ConversationStore.getInstance().saveRecord(this.currentRecord);

    try {
      let summary = await this.generateSummary(this.currentRecord);
      this.currentRecord.summary = summary;
      this.currentRecord.status = 'completed';
    } catch (err) {
      this.log.error(this.TAG, `Summary generation failed: ${err}`);
      this.currentRecord.status = this.currentRecord.entries.length > 0 ? 'completed' : 'error';
    }

    await ConversationStore.getInstance().saveRecord(this.currentRecord);

    // Export markdown
    if (this.context) {
      await ConversationStore.getInstance().saveAsMarkdown(this.context, this.currentRecord);
    }
  }

  private async generateSummary(record: SilentConversationRecord): Promise<string> {
    if (!this.context) return '';

    // Build transcript text
    let transcript = '';
    for (let entry of record.entries) {
      let t = new Date(entry.timestamp);
      let ts = `${String(t.getHours()).padStart(2, '0')}:${String(t.getMinutes()).padStart(2, '0')}`;
      transcript += `[${ts}] ${entry.speaker}: ${entry.text}\n`;
    }

    let systemPrompt = '你是一个对话摘要助手。请用简洁的中文总结以下对话的主要内容、关键决定和待办事项。如果对话是英文的，用英文总结。';
    let userMessage = `请总结以下对话：\n\n${transcript}`;

    // Load settings for AI call
    try {
      let store = await preferences.getPreferences(this.context, Constants.PREFS_SETTINGS);
      let provider = (await store.get('provider', 'openrouter')) as string;
      let keyPref = 'key_' + provider;
      let modelPref = 'model_' + provider;
      let apiKey = (await store.get(keyPref, '')) as string;
      let baseUrl = (await store.get('url_' + provider, '')) as string;
      if (provider === 'openrouter' && baseUrl.length > 0 && !baseUrl.includes('openrouter')) {
        baseUrl = '';
      }
      let defaultModel = provider === 'openrouter' ? Constants.DEFAULT_MODEL_OPENROUTER
        : provider === 'anthropic' ? Constants.DEFAULT_MODEL_ANTHROPIC
          : provider === 'openai' ? Constants.DEFAULT_MODEL_OPENAI
            : provider === 'siliconflow' ? Constants.DEFAULT_MODEL_SILICONFLOW
              : '';
      let model = (await store.get(modelPref, defaultModel)) as string;
      if (apiKey.length === 0 && provider === 'openrouter' && Constants.OPENROUTER_DEFAULT_KEY.length > 0) {
        apiKey = Constants.OPENROUTER_DEFAULT_KEY;
      }
      if (apiKey.length === 0 && (provider === 'openai' || provider === 'siliconflow') && Constants.SILICONFLOW_DEFAULT_KEY.length > 0) {
        apiKey = Constants.SILICONFLOW_DEFAULT_KEY;
      }

      let settings: SettingsData = {
        provider: provider,
        apiKey: apiKey,
        model: model,
        baseUrl: baseUrl,
        temperature: 0.3
      };

      let aiService = AIService.getInstance();
      return await aiService.simpleChat(systemPrompt, userMessage, settings);
    } catch (err) {
      this.log.error(this.TAG, `Summary AI call failed: ${err}`);
      return '';
    }
  }

  private async startNewRecord(): Promise<void> {
    let recordId = `silent_${Date.now()}_${Math.floor(Math.random() * 100000)}`;
    this.currentRecord = {
      id: recordId,
      startTime: Date.now(),
      endTime: 0,
      entries: [],
      summary: '',
      status: 'recording',
      participants: []
    };
    await ConversationStore.getInstance().saveRecord(this.currentRecord);
  }

  getCurrentRecord(): SilentConversationRecord | undefined {
    return this.currentRecord;
  }
}
