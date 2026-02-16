# Silent Mode (静默模式) 技术方案

> 版本: 1.0 | 日期: 2026-02-16 | 作者: ClawdBot Team

## 1. 功能概述

静默模式 (Silent Mode) 让 ClawdBot 在后台持续监听用户与他人的对话，但**不主动回应**。它在幕后完成：

1. **持续语音监听** — 麦克风保持开启，实时采集音频
2. **实时语音转文字** — 将环境对话转为文本
3. **智能摘要** — 定期总结对话内容，提取关键信息
4. **唤醒词响应** — 当用户说出唤醒词（如 "ClawdBot"）时，开始录制问题并回答
5. **记忆整合** — 将对话中的重要信息自动写入 MemoryService

### 与现有 Talk Mode 的区别

| 特性 | Talk Mode | Silent Mode |
|------|-----------|-------------|
| 交互方式 | 每轮录音→ASR→AI→TTS | 持续监听，仅唤醒时响应 |
| 录音触发 | 用户操作/语音检测后自动轮次 | 持续后台录音 |
| AI 调用频率 | 每句话都发 AI | 定期摘要 + 唤醒时才发 |
| 后台运行 | 否（页面级） | 是（后台服务） |
| 电量消耗 | 高（频繁 AI 调用） | 中（本地 ASR + 定时摘要） |

---

## 2. 系统架构

```
┌─────────────────────────────────────────────────────┐
│                    ChatPage (UI)                     │
│  ┌──────────┐  ┌──────────────┐  ┌───────────────┐  │
│  │ 静默模式  │  │  摘要卡片    │  │  唤醒对话     │  │
│  │ 开关/指示 │  │  定时展示    │  │  气泡展示     │  │
│  └──────────┘  └──────────────┘  └───────────────┘  │
└───────────────────────┬─────────────────────────────┘
                        │ Events / State
┌───────────────────────┴─────────────────────────────┐
│              SilentModeService (核心服务)              │
│  ┌─────────────┐  ┌──────────┐  ┌────────────────┐  │
│  │ AudioPipeline│  │ WakeWord │  │ SummarizeEngine│  │
│  │ (持续录音)   │  │ Detector │  │ (摘要引擎)     │  │
│  └──────┬──────┘  └────┬─────┘  └───────┬────────┘  │
│         │              │                │            │
│  ┌──────▼──────┐  ┌────▼─────┐  ┌───────▼────────┐  │
│  │ StreamingASR │  │ 唤醒词   │  │ AI摘要API调用  │  │
│  │ (流式转写)   │  │ 检测模型 │  │ (定时/阈值)    │  │
│  └─────────────┘  └──────────┘  └────────────────┘  │
└───────────────────────┬─────────────────────────────┘
                        │
        ┌───────────────┼───────────────┐
        ▼               ▼               ▼
  ┌──────────┐   ┌──────────┐   ┌──────────────┐
  │ LocalASR │   │ MemoryS. │   │ AIService    │
  │ Service  │   │          │   │ (摘要/问答)  │
  └──────────┘   └──────────┘   └──────────────┘
```

---

## 3. 技术方案详细设计

### 3.1 后台持续语音监听

#### 3.1.1 HarmonyOS 后台服务方案

HarmonyOS 对后台任务有严格限制。静默模式需要**长时任务 (ContinuousTask)** 来保活后台音频采集。

**方案: ServiceExtensionAbility + ContinuousTask**

```typescript
// 新建 SilentModeServiceAbility (ServiceExtensionAbility)
import { ServiceExtensionAbility, Want } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';

export default class SilentModeServiceAbility extends ServiceExtensionAbility {
  onCreate(want: Want): void {
    // 申请长时任务 - AUDIO_RECORDING 类型
    let context = this.context;
    backgroundTaskManager.startBackgroundRunning(context,
      backgroundTaskManager.BackgroundMode.AUDIO_RECORDING);
  }
}
```

**module.json5 配置:**

```json5
{
  "extensionAbilities": [
    {
      "name": "SilentModeServiceAbility",
      "srcEntry": "./ets/service/SilentModeServiceAbility.ets",
      "type": "service",
      "backgroundModes": ["audioRecording"]
    }
  ]
}
```

**需要新增的权限:**

```json5
{
  "name": "ohos.permission.KEEP_BACKGROUND_RUNNING",
  "reason": "$string:background_running_reason",
  "usedScene": {
    "abilities": ["SilentModeServiceAbility"],
    "when": "always"
  }
}
```

#### 3.1.2 音频采集管线 (AudioPipeline)

复用现有的 `audio.AudioCapturer` 模式（ChatPage 中已有成熟实现），但改为**长时间流式采集**：

```typescript
class AudioPipeline {
  private capturer: audio.AudioCapturer | undefined;
  private running: boolean = false;

  async start(): Promise<void> {
    let options: audio.AudioCapturerOptions = {
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

    this.capturer = await audio.createAudioCapturer(options);
    await this.capturer.start();
    this.running = true;
    this.readLoop();
  }

  private async readLoop(): Promise<void> {
    let bufSize = await this.capturer!.getBufferSize();
    while (this.running && this.capturer) {
      let buf = await this.capturer.read(bufSize, true);
      // 分发给: WakeWordDetector + StreamingASR + VAD
      this.onAudioChunk(buf);
    }
  }
}
```

#### 3.1.3 电量优化策略

| 策略 | 说明 |
|------|------|
| **VAD 门控** | 仅在检测到人声时才送 ASR，静音时跳过 |
| **ASR 切换** | 默认使用本地离线 ASR (CoreSpeechKit offline)，降低网络开销 |
| **分段摘要** | 每 5 分钟或 500 字累积后才调用一次 AI 摘要 |
| **低优先级线程** | 音频处理在 Worker 中执行，不阻塞 UI |
| **自动暂停** | 长时间静音（>3分钟）自动降低采样率或暂停采集 |
| **夜间免扰** | 可配置时间段自动关闭静默模式 |

---

### 3.2 唤醒词检测

#### 3.2.1 方案选型

| 方案 | 优势 | 劣势 | 推荐 |
|------|------|------|------|
| **CoreSpeechKit 流式识别 + 关键词匹配** | 无需额外模型，复用现有引擎 | 功耗较高（完整 ASR 始终运行） | 短期方案 |
| **sherpa-onnx KWS (Keyword Spotting)** | 超低功耗，专用模型，支持自定义唤醒词 | 需集成 ONNX Runtime，包体积增加 | 长期方案 |
| **简单能量检测 + ASR 确认** | 最简单实现 | 误唤醒率高 | 不推荐 |

#### 3.2.2 短期方案: ASR 流式识别 + 关键词匹配

利用已有的 `LocalAsrService` 和 `CoreSpeechKit`，在流式 ASR 输出中检测唤醒词：

```typescript
class WakeWordDetector {
  private wakeWords: string[] = ['clawdbot', '小克', '助手'];
  private customWakeWord: string = ''; // 用户自定义

  // 在 ASR 实时结果中检测唤醒词
  checkWakeWord(partialText: string): WakeWordResult {
    let lower = partialText.toLowerCase();
    for (let word of this.getAllWakeWords()) {
      let idx = lower.indexOf(word.toLowerCase());
      if (idx >= 0) {
        // 提取唤醒词后面的内容作为指令
        let afterWake = partialText.substring(idx + word.length).trim();
        return { detected: true, wakeWord: word, followUpText: afterWake };
      }
    }
    return { detected: false, wakeWord: '', followUpText: '' };
  }

  private getAllWakeWords(): string[] {
    let words = [...this.wakeWords];
    if (this.customWakeWord.length > 0) {
      words.unshift(this.customWakeWord);
    }
    return words;
  }
}

interface WakeWordResult {
  detected: boolean;
  wakeWord: string;
  followUpText: string;
}
```

#### 3.2.3 长期方案: sherpa-onnx 本地唤醒词检测

sherpa-onnx 提供了 HarmonyOS NEXT 的 NAPI 绑定（C++ 层），可以实现：

- 极低功耗的关键词检测（<5% CPU）
- 自定义唤醒词支持
- 不依赖完整 ASR 引擎

**集成路径:**

```
1. 引入 sherpa-onnx HarmonyOS 预编译库 (.so + .d.ts)
2. 加载 KWS 模型 (sherpa-onnx-kws-zipformer, ~5MB)
3. 将 AudioPipeline 的 PCM 数据先送 KWS
4. KWS 检测到唤醒词后，再启动完整 ASR 录制用户指令
```

**模型选择:**

```
推荐: sherpa-onnx-kws-zipformer-wenetspeech-3.3M (中文)
备选: sherpa-onnx-kws-zipformer-gigaspeech-3.3M (英文)
自定义: 支持用户录制唤醒词样本，fine-tune 检测模型
```

> 注意: sherpa-onnx 的 HarmonyOS 支持目前在积极开发中。
> 短期先用 ASR 关键词匹配，中期迁移到 sherpa-onnx KWS。

---

### 3.3 语音转文字 (实时 ASR)

#### 3.3.1 流式 ASR 架构

静默模式的 ASR 与现有 Talk Mode 不同，需要**长时间流式识别**而非单句识别：

```typescript
class StreamingAsrEngine {
  private engine: speechRecognizer.SpeechRecognitionEngine | undefined;
  private currentTranscript: string = '';
  private segmentBuffer: string[] = []; // 累积的对话段落

  async startContinuousRecognition(): Promise<void> {
    // 使用 'long' recognizerMode 代替 'short'
    let params: speechRecognizer.CreateEngineParams = {
      language: 'zh-CN',
      online: 0, // 优先离线
      extraParams: {
        'locate': 'CN',
        'recognizerMode': 'long',  // 长时语音识别模式
        'maxAudioDuration': 600000, // 10分钟
      }
    };
    this.engine = await speechRecognizer.createEngine(params);

    let listener: speechRecognizer.RecognitionListener = {
      onResult: (sessionId, result) => {
        this.currentTranscript = result.result;
        if (result.isLast) {
          // 一段话结束，存入 buffer
          if (this.currentTranscript.length > 0) {
            this.segmentBuffer.push(this.currentTranscript);
            this.onSegmentComplete(this.currentTranscript);
          }
          this.currentTranscript = '';
        }
      },
      onStart: () => {},
      onEvent: () => {},
      onComplete: () => {
        // 引擎超时，需要重启
        this.restartRecognition();
      },
      onError: (_, code, msg) => {
        // 错误恢复
        this.restartRecognition();
      }
    };

    this.engine.setListener(listener);
    // ... start listening
  }

  // 获取并清空累积的对话文本
  flushSegments(): string[] {
    let segments = [...this.segmentBuffer];
    this.segmentBuffer = [];
    return segments;
  }
}
```

#### 3.3.2 ASR 模式切换

与现有设置一致，复用 `asrMode` 配置:

| 模式 | 静默模式行为 |
|------|-------------|
| `local` | 仅使用 CoreSpeechKit 离线引擎（推荐，省电） |
| `cloud` | 使用 SiliconFlow SenseVoice API（高精度，费流量） |
| `auto` | 本地优先，静音时不切云端 |

---

### 3.4 对话摘要和关键信息提取

#### 3.4.1 摘要触发策略

```typescript
class SummarizeEngine {
  private pendingText: string = '';
  private lastSummaryTime: number = 0;
  private summaryInterval: number = 5 * 60 * 1000; // 5分钟
  private textThreshold: number = 500; // 500字

  onNewSegment(text: string): void {
    this.pendingText += text + '\n';

    let now = Date.now();
    let shouldSummarize =
      // 条件1: 超过时间间隔
      (now - this.lastSummaryTime > this.summaryInterval && this.pendingText.length > 50)
      // 条件2: 累积文本超过阈值
      || this.pendingText.length >= this.textThreshold;

    if (shouldSummarize) {
      this.triggerSummary();
    }
  }

  private async triggerSummary(): Promise<void> {
    let textToSummarize = this.pendingText;
    this.pendingText = '';
    this.lastSummaryTime = Date.now();

    let summary = await this.callSummaryApi(textToSummarize);
    // 通知 UI 展示摘要卡片
    this.onSummaryReady(summary);
    // 提取关键信息写入记忆
    await this.extractAndSaveMemories(textToSummarize, summary);
  }
}
```

#### 3.4.2 AI 摘要 Prompt 设计

```typescript
private buildSummaryPrompt(conversationText: string): string {
  return `你是一个对话分析助手。以下是用户周围环境中的对话内容（由语音识别转写）。
请完成以下任务：

1. **对话摘要**: 用 2-3 句话总结对话的主要内容
2. **关键信息**: 提取对话中的关键事实（人名、地点、时间、数字、决定等）
3. **待办事项**: 如果对话中提到了需要做的事情，列出来
4. **情感氛围**: 简单描述对话的整体氛围

对话内容:
"""
${conversationText}
"""

请以 JSON 格式返回:
{
  "summary": "...",
  "keyFacts": ["...", "..."],
  "todos": ["...", "..."],
  "mood": "..."
}`;
}
```

#### 3.4.3 关键信息自动写入记忆

复用现有的 `MemoryService`：

```typescript
private async extractAndSaveMemories(
  text: string, summary: SilentModeSummary
): Promise<void> {
  let memSvc = MemoryService.getInstance();
  let context = this.appContext;

  // 写入关键事实
  for (let fact of summary.keyFacts) {
    await memSvc.addIfNew(context, 'fact',
      `[静默模式] ${fact}`, 0.6);
  }

  // 写入待办事项
  for (let todo of summary.todos) {
    await memSvc.addIfNew(context, 'instruction',
      `[静默模式-待办] ${todo}`, 0.8);
  }
}
```

---

### 3.5 唤醒后的交互流程

```
用户: "...今天下午3点开会..." (环境对话，静默模式记录中)
用户: "小克，刚才说的会议几点？"
         │
         ▼
  ┌──────────────┐
  │ 唤醒词检测到  │
  │ wake="小克"   │
  │ follow="刚才  │
  │ 说的会议几点？"│
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐
  │ 构建上下文:   │
  │ - 最近的对话  │
  │   转写文本    │
  │ - 摘要历史    │
  │ - 记忆条目    │
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐
  │ 发送 AI 请求  │
  │ (附带上下文)  │
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐
  │ AI 回答:      │
  │ "根据刚才的   │
  │  对话，会议   │
  │  在下午3点"   │
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐
  │ TTS 朗读回答  │
  │ 恢复静默模式  │
  └──────────────┘
```

**上下文构建:**

```typescript
private buildWakeContext(): string {
  let parts: string[] = [];

  // 最近 N 分钟的对话转写
  let recentTranscript = this.streamingAsr.getRecentText(10); // 最近10分钟
  if (recentTranscript.length > 0) {
    parts.push(`<recent_conversation>\n${recentTranscript}\n</recent_conversation>`);
  }

  // 最近的摘要
  let recentSummaries = this.summarizeEngine.getRecentSummaries(3);
  if (recentSummaries.length > 0) {
    let summaryText = recentSummaries
      .map(s => `[${s.time}] ${s.summary}`)
      .join('\n');
    parts.push(`<conversation_summaries>\n${summaryText}\n</conversation_summaries>`);
  }

  return parts.join('\n\n');
}
```

---

## 4. 核心服务设计: SilentModeService

### 4.1 类结构

```typescript
// entry/src/main/ets/service/SilentModeService.ets

export enum SilentModeState {
  Off = 'off',
  Listening = 'listening',    // 正在监听
  Summarizing = 'summarizing', // 正在生成摘要
  Responding = 'responding',   // 唤醒后正在回答
  Paused = 'paused'           // 暂停（如静音超时）
}

export interface SilentModeSummary {
  id: string;
  timestamp: number;
  summary: string;
  keyFacts: string[];
  todos: string[];
  mood: string;
  rawTextLength: number;   // 原始对话文本长度
  durationMinutes: number; // 覆盖时间范围
}

export interface SilentModeConfig {
  enabled: boolean;
  wakeWords: string[];        // 唤醒词列表
  summaryIntervalMin: number; // 摘要间隔(分钟), 默认 5
  textThreshold: number;      // 文本累积阈值, 默认 500
  autoMemory: boolean;        // 自动写入记忆, 默认 true
  silenceTimeoutMin: number;  // 静音暂停阈值(分钟), 默认 3
  nightModeStart: string;     // 夜间免扰开始, 如 "23:00"
  nightModeEnd: string;       // 夜间免扰结束, 如 "07:00"
}

export class SilentModeService {
  private static instance: SilentModeService | undefined;

  // 状态
  private state: SilentModeState = SilentModeState.Off;
  private config: SilentModeConfig;

  // 子组件
  private audioPipeline: AudioPipeline;
  private wakeWordDetector: WakeWordDetector;
  private streamingAsr: StreamingAsrEngine;
  private summarizeEngine: SummarizeEngine;

  // 数据
  private summaryHistory: SilentModeSummary[] = [];
  private recentTranscriptBuffer: TranscriptSegment[] = [];

  // 监听器
  private stateListeners: ((state: SilentModeState) => void)[] = [];
  private summaryListeners: ((summary: SilentModeSummary) => void)[] = [];
  private wakeListeners: ((question: string) => void)[] = [];

  // --- Lifecycle ---
  async start(context: Context): Promise<void>;
  async stop(): Promise<void>;
  async pause(): Promise<void>;
  async resume(): Promise<void>;

  // --- State ---
  getState(): SilentModeState;
  addStateListener(listener: (state: SilentModeState) => void): void;
  removeStateListener(listener: (state: SilentModeState) => void): void;

  // --- Summaries ---
  getSummaryHistory(): SilentModeSummary[];
  addSummaryListener(listener: (summary: SilentModeSummary) => void): void;

  // --- Wake ---
  addWakeListener(listener: (question: string) => void): void;

  // --- Config ---
  updateConfig(config: Partial<SilentModeConfig>): void;
  getConfig(): SilentModeConfig;
}
```

### 4.2 状态机

```
     ┌─── start() ──────────────────┐
     ▼                               │
   [Off] ◄── stop() ── [Listening] ──┤
                           │    ▲     │
                  静音超时  │    │ resume()
                           ▼    │     │
                        [Paused]──┘    │
                                       │
               [Listening] ──唤醒词──▶ [Responding]
                    ▲                    │
                    └── 回答完成 ────────┘

               [Listening] ──定时/阈值──▶ [Summarizing]
                    ▲                      │
                    └── 摘要完成 ──────────┘
```

---

## 5. UI/UX 设计

### 5.1 静默模式入口

**位置: ChatPage 顶部栏**

在现有的 header 区域（显示 "ClawdBot" / "在线" 状态的位置），添加静默模式按钮：

```
┌──────────────────────────────────────┐
│ ☰  ClawdBot        🔇 ▶ 静默模式    │  ← 新增
│     在线                              │
└──────────────────────────────────────┘
```

- 图标: `🔇` (关闭) / `👁` (开启-监听中) / `✨` (开启-有新摘要)
- 长按: 打开静默模式设置面板
- 点击: 快速开关

### 5.2 状态指示器

静默模式开启时，在 ChatPage 顶部显示一个细长的状态条：

```
┌──────────────────────────────────────┐
│ 👁 静默模式 · 已监听 23分钟 · 3条摘要  │  ← 状态条
├──────────────────────────────────────┤
│                                      │
│          正常对话区域                  │
│                                      │
```

状态条颜色/样式:
- 监听中: 绿色脉动点 `●` + "静默监听中"
- 已暂停: 灰色 `○` + "已暂停（静音）"
- 摘要中: 蓝色旋转 `◉` + "正在总结..."
- 响应中: 橙色 `●` + "正在回答..."

### 5.3 摘要展示

摘要以**特殊样式的消息卡片**展示在聊天流中：

```
┌──────────────────────────────────────┐
│  👁 静默模式摘要  14:23               │
│  ────────────────────────────────    │
│  对话讨论了下午3点的产品评审会议，     │
│  参与者包括小张和小李。决定了...       │
│                                      │
│  📌 关键信息:                         │
│  · 产品评审会: 下午3点, 3楼会议室     │
│  · 小张负责准备演示文稿               │
│                                      │
│  ✅ 待办:                             │
│  · 提前准备会议材料                   │
│                                      │
│  💬 氛围: 轻松, 讨论效率高             │
└──────────────────────────────────────┘
```

**实现方式:**

复用现有的 `ChatMessage` 模型，增加新的 role 或使用特殊标记：

```typescript
// 方案: 使用 assistant role + 特殊前缀标记
let summaryMsg = new ChatMessage('assistant', '');
summaryMsg.content = this.formatSummaryContent(summary);
// 通过内容前缀 "[SILENT_SUMMARY]" 让 MessageBubble 识别并使用特殊样式
```

### 5.4 唤醒后的对话展示

唤醒后的问答在正常聊天流中展示，带有上下文标记：

```
┌──────────────────────────────────────┐
│  🎤 (唤醒) 你                  14:25  │
│  刚才说的会议几点？                   │
├──────────────────────────────────────┤
│  根据刚才的对话，产品评审会议         │
│  定在今天下午3点，地点是3楼会议室。   │
│  小张负责准备演示文稿。     ClawdBot  │
└──────────────────────────────────────┘
```

### 5.5 设置面板

在 SettingsPage 中新增 "静默模式" 配置区域：

```
┌──────────────────────────────────────┐
│  静默模式设置                         │
│  ────────────────────────────────    │
│  启用静默模式          [开关]         │
│                                      │
│  唤醒词                              │
│  ┌──────────────────────────────┐    │
│  │ 小克, ClawdBot              │    │
│  └──────────────────────────────┘    │
│  + 添加自定义唤醒词                   │
│                                      │
│  摘要间隔        [5分钟 ▾]           │
│  自动记忆        [开关: 开]           │
│  夜间免扰        [23:00 - 07:00]     │
│                                      │
│  数据管理                             │
│  · 清除所有静默模式数据               │
│  · 导出对话转写记录                   │
└──────────────────────────────────────┘
```

---

## 6. 数据模型

### 6.1 新增 Model 类

```typescript
// 添加到 model/Models.ets

@Observed
export class SilentModeSummaryItem {
  id: string;
  timestamp: number;
  summary: string;
  keyFacts: string[];
  todos: string[];
  mood: string;
  rawTextLength: number;
  durationMinutes: number;

  constructor(summary: string) {
    this.id = `sms_${Date.now()}_${Math.floor(Math.random() * 100000)}`;
    this.timestamp = Date.now();
    this.summary = summary;
    this.keyFacts = [];
    this.todos = [];
    this.mood = '';
    this.rawTextLength = 0;
    this.durationMinutes = 0;
  }
}

@Observed
export class TranscriptSegment {
  timestamp: number;
  text: string;
  speakerId: string; // 未来: 说话人识别

  constructor(text: string) {
    this.timestamp = Date.now();
    this.text = text;
    this.speakerId = '';
  }
}
```

### 6.2 持久化存储

```typescript
// Constants.ets 新增
static readonly PREFS_SILENT_MODE: string = 'clawdbot_silent_mode';
```

存储结构:

| Key | 类型 | 说明 |
|-----|------|------|
| `config` | JSON string | SilentModeConfig |
| `summary_history` | JSON string | SilentModeSummary[] (最近50条) |
| `transcript_cache` | JSON string | 最近30分钟的转写文本 |
| `total_listening_time` | number | 累计监听时长(ms) |

---

## 7. 隐私和安全设计

### 7.1 用户授权流程

```
首次开启静默模式:
┌──────────────────────────────────────┐
│         ⚠️ 静默模式权限说明            │
│                                      │
│  静默模式将持续使用麦克风监听          │
│  环境对话。                           │
│                                      │
│  · 麦克风将在后台持续运行             │
│  · 对话内容将被转写为文字             │
│  · AI 将定期生成对话摘要              │
│  · 关键信息可能被自动记忆             │
│                                      │
│  数据安全:                            │
│  · 原始音频不存储，仅保留文字         │
│  · 转写文本最多保留30分钟             │
│  · 可随时清除所有数据                 │
│                                      │
│  [取消]              [我已了解，开启]  │
└──────────────────────────────────────┘
```

### 7.2 数据安全策略

| 策略 | 实现 |
|------|------|
| **不存储原始音频** | PCM 数据仅在内存中流转，ASR 后立即丢弃 |
| **转写文本自动清理** | 超过 30 分钟的转写文本自动删除 |
| **摘要历史限制** | 最多保留 50 条摘要，FIFO 淘汰 |
| **加密存储** | 使用 HarmonyOS preferences 加密存储（系统级加密） |
| **状态栏提示** | 系统状态栏显示麦克风使用图标（HarmonyOS 强制要求） |
| **快速关闭** | 任何时候一键关闭，立即停止录音并清理缓存 |

### 7.3 合规注意事项

1. **录音告知义务**: 在周围有他人时，用户应告知对方正在使用录音功能
2. **隐私声明**: App 隐私政策需更新，明确说明静默模式的数据处理方式
3. **数据不上传**: 原始音频和转写文本不上传服务器（除非使用云端 ASR）
4. **区域合规**: 部分地区可能禁止未经同意录音，需在设置中提醒用户

---

## 8. I18n 国际化

### 8.1 新增翻译键

```typescript
// I18n.ets 新增

// 中文
m.set('silent.title', '静默模式');
m.set('silent.on', '静默模式已开启');
m.set('silent.off', '静默模式已关闭');
m.set('silent.listening', '静默监听中');
m.set('silent.paused', '已暂停');
m.set('silent.summarizing', '正在总结...');
m.set('silent.responding', '正在回答...');
m.set('silent.statusBar', '已监听 {0}分钟 · {1}条摘要');
m.set('silent.summaryCard', '静默模式摘要');
m.set('silent.keyFacts', '关键信息');
m.set('silent.todos', '待办');
m.set('silent.mood', '氛围');
m.set('silent.wakeDetected', '唤醒词检测到');
m.set('silent.settings', '静默模式设置');
m.set('silent.wakeWords', '唤醒词');
m.set('silent.addWakeWord', '添加自定义唤醒词');
m.set('silent.summaryInterval', '摘要间隔');
m.set('silent.autoMemory', '自动记忆');
m.set('silent.nightMode', '夜间免扰');
m.set('silent.clearData', '清除静默模式数据');
m.set('silent.exportTranscript', '导出转写记录');
m.set('silent.permissionTitle', '静默模式权限说明');
m.set('silent.permissionDesc', '静默模式将持续使用麦克风监听环境对话。');
m.set('silent.permissionConfirm', '我已了解，开启');
m.set('silent.privacyNote', '原始音频不存储，转写文本最多保留30分钟');

// 英文
m.set('silent.title', 'Silent Mode');
m.set('silent.on', 'Silent Mode enabled');
m.set('silent.off', 'Silent Mode disabled');
m.set('silent.listening', 'Listening silently');
m.set('silent.paused', 'Paused');
m.set('silent.summarizing', 'Summarizing...');
m.set('silent.responding', 'Responding...');
m.set('silent.statusBar', 'Listening {0}min · {1} summaries');
// ... (同上)
```

---

## 9. 文件结构变更

```
entry/src/main/ets/
├── service/
│   ├── SilentModeService.ets        ← 新增: 核心服务
│   ├── AudioPipeline.ets            ← 新增: 持续音频采集
│   ├── StreamingAsrEngine.ets       ← 新增: 流式 ASR 引擎
│   ├── WakeWordDetector.ets         ← 新增: 唤醒词检测
│   ├── SummarizeEngine.ets          ← 新增: 摘要引擎
│   ├── LocalAsrService.ets          ← 现有: 可复用
│   ├── AIService.ets                ← 现有: 摘要调用复用
│   ├── MemoryService.ets            ← 现有: 记忆写入复用
│   └── ...
├── model/
│   └── Models.ets                   ← 修改: 新增数据模型
├── common/
│   ├── Constants.ets                ← 修改: 新增常量
│   └── I18n.ets                     ← 修改: 新增翻译
├── components/
│   ├── SilentModeStatusBar.ets      ← 新增: 状态条组件
│   ├── SilentModeSummaryCard.ets    ← 新增: 摘要卡片组件
│   └── MessageBubble.ets            ← 修改: 支持摘要样式
├── pages/
│   ├── ChatPage.ets                 ← 修改: 集成静默模式
│   └── SettingsPage.ets             ← 修改: 新增设置区域
└── entryability/
    └── EntryAbility.ets             ← 修改: 后台任务注册

entry/src/main/
└── module.json5                     ← 修改: 新增权限和服务声明
```

---

## 10. 实现计划

### Phase 1: 基础框架 (1-2周)

- [ ] `SilentModeService` 核心骨架 + 状态机
- [ ] `AudioPipeline` 持续录音（复用现有 AudioCapturer 代码）
- [ ] `StreamingAsrEngine` 流式 ASR（基于 LocalAsrService 改造）
- [ ] UI: 静默模式开关 + 状态指示器
- [ ] 基本的权限授权流程

### Phase 2: 摘要系统 (1周)

- [ ] `SummarizeEngine` 定时/阈值触发摘要
- [ ] AI 摘要 Prompt 设计和调优
- [ ] 摘要卡片 UI 组件
- [ ] 摘要历史持久化

### Phase 3: 唤醒词系统 (1周)

- [ ] `WakeWordDetector` ASR 关键词匹配方案
- [ ] 唤醒后的上下文构建 + AI 问答
- [ ] 唤醒词自定义设置 UI
- [ ] TTS 回答播报

### Phase 4: 记忆整合 + 优化 (1周)

- [ ] 关键信息自动写入 MemoryService
- [ ] 电量优化（VAD 门控、静音暂停）
- [ ] 数据清理策略实现
- [ ] 完善隐私授权流程

### Phase 5: 后台保活 + 高级功能 (1-2周)

- [ ] ServiceExtensionAbility + ContinuousTask 后台保活
- [ ] module.json5 权限配置
- [ ] 夜间免扰模式
- [ ] 导出转写记录功能
- [ ] sherpa-onnx KWS 集成调研

---

## 11. 风险和挑战

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| HarmonyOS 后台录音限制 | 系统可能杀死后台服务 | ContinuousTask + 前台通知 |
| CoreSpeechKit 长时间运行不稳定 | ASR 引擎超时/崩溃 | 自动重启机制 + 错误恢复 |
| 电量消耗过高 | 用户体验差 | VAD 门控 + 分级策略 |
| ASR 噪声环境识别率低 | 摘要质量差 | 云端 ASR 降级 + 置信度过滤 |
| 唤醒词误触发 | 意外打断 | 多词组合 + 确认音效 |
| 隐私合规风险 | 法律风险 | 明确告知 + 数据最小化 |
| sherpa-onnx HarmonyOS 兼容性 | 无法使用低功耗 KWS | 保持 ASR 关键词匹配方案 |

---

## 12. 参考资源

- HarmonyOS ContinuousTask 文档: `@kit.BackgroundTasksKit`
- HarmonyOS AudioCapturer 文档: `@kit.AudioKit` - `audio.AudioCapturer`
- HarmonyOS CoreSpeechKit: `@kit.CoreSpeechKit` - `speechRecognizer`
- sherpa-onnx HarmonyOS: https://github.com/k2-fsa/sherpa-onnx (HarmonyOS NEXT support)
- 现有代码参考:
  - `ChatPage.ets` talkCycle() — 现有的持续对话模式
  - `LocalAsrService.ets` — 本地 ASR 引擎管理
  - `MicrophoneCapability.ets` — 麦克风录音
  - `SpeakerCapability.ets` — TTS 播报
  - `MemoryService.ets` — 记忆存储和检索
