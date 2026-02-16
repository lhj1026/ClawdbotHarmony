# 声纹识别 (Voiceprint Recognition) 技术方案

## 1. 概述

基于 sherpa-onnx 实现本地声纹识别功能，支持说话人注册、身份验证和说话人识别。所有处理在设备端完成，无需网络连接，保护用户隐私。

### 1.1 核心能力

| 能力 | 说明 |
|------|------|
| 声纹注册 (Enrollment) | 采集用户语音样本，提取并存储声纹特征向量 |
| 声纹验证 (Verification) | 1:1 比对，验证"你是否是你声称的人" |
| 说话人识别 (Identification) | 1:N 比对，在已注册声纹库中识别说话人 |

### 1.2 现有基础

项目已搭建部分基础设施：

| 组件 | 状态 | 位置 |
|------|------|------|
| NAPI C++ 框架 | Stub 实现 | `entry/src/main/cpp/voiceprint/voiceprint_napi.cpp` |
| TypeScript 类型声明 | 已完成 | `entry/src/main/cpp/types/libvoiceprint/index.d.ts` |
| CMake 构建配置 | 已就绪（需取消注释） | `entry/src/main/cpp/voiceprint/CMakeLists.txt` |
| 3D-Speaker 模型文件 | 已下载 | `entry/src/main/resources/rawfile/voiceprint/*.onnx` |
| 模型下载脚本 | 已完成 | `scripts/download_sherpa_onnx.sh` |
| 麦克风采集 | 已实现 (44100Hz AAC) | `service/gateway/MicrophoneCapability.ets` |
| 余弦相似度计算 | 已实现 | `voiceprint_napi.cpp:ComputeSimilarity()` |

---

## 2. 模型选型

### 2.1 选定模型

**3dspeaker_speech_eres2net_base_200k_sv_zh-cn_16k-common.onnx**

| 参数 | 值 |
|------|-----|
| 架构 | ERes2Net (base) |
| 嵌入维度 | 192 |
| 采样率 | 16000 Hz |
| 语言 | 中文 (zh-CN) |
| 文件大小 | ~38 MB |
| 来源 | 3D-Speaker / ModelScope |

选择理由：
- 中文优化，适合主要用户群体
- 模型体积适中，适合移动端
- 192 维嵌入向量，计算和存储开销小
- 项目已集成此模型

### 2.2 备选模型

| 模型 | 维度 | 大小 | 语言 | 适用场景 |
|------|------|------|------|----------|
| `wespeaker_en_voxceleb_resnet34_LM` | 256 | ~26MB | 英文 | 英文场景、更高精度 |
| `3dspeaker_speech_campplus_sv_zh-cn_16k-common` | 512 | ~28MB | 中文 | 更高精度、更大存储 |
| `nemo_en_titanet_large` | 192 | ~85MB | 英文 | 最高精度、体积较大 |

---

## 3. sherpa-onnx C API 参考

### 3.1 核心数据结构

```c
// 模型配置
typedef struct SherpaOnnxSpeakerEmbeddingExtractorConfig {
  const char *model;       // ONNX 模型文件路径
  int32_t num_threads;     // 推理线程数 (建议: 2)
  int32_t debug;           // 调试日志 (0 或 1)
  const char *provider;    // "cpu"
} SherpaOnnxSpeakerEmbeddingExtractorConfig;

// 说话人匹配结果
typedef struct SherpaOnnxSpeakerEmbeddingManagerSpeakerMatch {
  float score;             // 余弦相似度分数
  const char *name;        // 说话人名称
} SherpaOnnxSpeakerEmbeddingManagerSpeakerMatch;
```

### 3.2 Extractor API（特征提取）

```c
// 创建 / 销毁
const SherpaOnnxSpeakerEmbeddingExtractor *
SherpaOnnxCreateSpeakerEmbeddingExtractor(config);

// HarmonyOS 专用版本 — 支持 rawfile 资源加载
const SherpaOnnxSpeakerEmbeddingExtractor *
SherpaOnnxCreateSpeakerEmbeddingExtractorOHOS(config, NativeResourceManager *mgr);

void SherpaOnnxDestroySpeakerEmbeddingExtractor(extractor);

// 获取嵌入维度
int32_t SherpaOnnxSpeakerEmbeddingExtractorDim(extractor);  // 返回 192

// 创建音频流并提取特征
const SherpaOnnxOnlineStream *
SherpaOnnxSpeakerEmbeddingExtractorCreateStream(extractor);

// 向流中送入音频数据
SherpaOnnxOnlineStreamAcceptWaveform(stream, sampleRate, samples, n);
SherpaOnnxOnlineStreamInputFinished(stream);

// 检查是否有足够数据计算嵌入
int32_t SherpaOnnxSpeakerEmbeddingExtractorIsReady(extractor, stream);

// 计算嵌入向量
const float *
SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(extractor, stream);

void SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(embedding);
```

### 3.3 Manager API（声纹管理）

```c
// 创建 / 销毁管理器
const SherpaOnnxSpeakerEmbeddingManager *
SherpaOnnxCreateSpeakerEmbeddingManager(int32_t dim);  // dim = 192

void SherpaOnnxDestroySpeakerEmbeddingManager(manager);

// 注册说话人（单个嵌入）
int32_t SherpaOnnxSpeakerEmbeddingManagerAdd(manager, name, embedding);

// 注册说话人（多个嵌入，内部取平均）
int32_t SherpaOnnxSpeakerEmbeddingManagerAddListFlattened(
    manager, name, embeddings_flat, count);

// 搜索最匹配的说话人
const char *SherpaOnnxSpeakerEmbeddingManagerSearch(
    manager, embedding, threshold);  // 返回名称或空串

// 获取 Top-N 匹配
const SherpaOnnxSpeakerEmbeddingManagerBestMatchesResult *
SherpaOnnxSpeakerEmbeddingManagerGetBestMatches(
    manager, embedding, threshold, n);

// 验证特定说话人
int32_t SherpaOnnxSpeakerEmbeddingManagerVerify(
    manager, name, embedding, threshold);  // 1=匹配, 0=不匹配

// 管理操作
int32_t SherpaOnnxSpeakerEmbeddingManagerContains(manager, name);
int32_t SherpaOnnxSpeakerEmbeddingManagerRemove(manager, name);
int32_t SherpaOnnxSpeakerEmbeddingManagerNumSpeakers(manager);
const char *const *SherpaOnnxSpeakerEmbeddingManagerGetAllSpeakers(manager);
```

---

## 4. 架构设计

### 4.1 分层架构

```
┌─────────────────────────────────────────────────────┐
│                   UI 层 (ArkTS)                     │
│  VoiceprintPage.ets  │  声纹设置  │  ChatPage 集成   │
├─────────────────────────────────────────────────────┤
│                 Service 层 (ETS)                     │
│          VoiceprintService.ets                       │
│  ┌──────────┐ ┌──────────────┐ ┌──────────────────┐ │
│  │ 注册管理  │ │  身份验证     │ │  声纹模板存储     │ │
│  └──────────┘ └──────────────┘ └──────────────────┘ │
├─────────────────────────────────────────────────────┤
│              Native 层 (C++ NAPI)                    │
│          voiceprint_napi.cpp                         │
│  ┌──────────────────┐  ┌─────────────────────────┐  │
│  │ SpeakerEmbedding │  │ SpeakerEmbedding        │  │
│  │ Extractor        │  │ Manager                 │  │
│  └──────────────────┘  └─────────────────────────┘  │
├─────────────────────────────────────────────────────┤
│           sherpa-onnx C Library                      │
│  libsherpa-onnx-c-api.so  │  libonnxruntime.so      │
├─────────────────────────────────────────────────────┤
│           3D-Speaker ONNX Model                      │
│  rawfile/voiceprint/*.onnx                           │
└─────────────────────────────────────────────────────┘
```

### 4.2 数据流

#### 声纹注册流程

```
用户点击"注册声纹"
    │
    ▼
录制 3~5 段语音 (每段 3~10 秒)
    │
    ▼
PCM 预处理: 44100Hz AAC → 16000Hz Float32 PCM
    │
    ▼
NAPI: extractEmbedding(pcmData, 16000)
    │ (对每段语音分别提取)
    ▼
NAPI: registerSpeaker(name, embeddings[])
    │ (Manager 内部取平均)
    ▼
持久化存储: 声纹模板 → Preferences / 文件系统
    │
    ▼
注册完成 ✓
```

#### 声纹验证流程

```
用户语音输入 (对话 / 解锁)
    │
    ▼
PCM 预处理: 44100Hz → 16000Hz Float32
    │
    ▼
NAPI: extractEmbedding(pcmData, 16000)
    │
    ▼
NAPI: identifySpeaker(embedding, threshold)
    │ (Manager.Search 或 Manager.GetBestMatches)
    ▼
返回: { speakerName, score } 或 "unknown"
    │
    ▼
应用层处理: 切换用户上下文 / 权限控制
```

---

## 5. C++ NAPI 接口设计

### 5.1 扩展现有接口

在现有 `voiceprint_napi.cpp` 基础上扩展，新增 Manager 相关的 NAPI 函数：

```cpp
// ===== 现有接口 (保留) =====
initModel(modelDir: string): boolean
extractEmbedding(pcmData: Float32Array, sampleRate: number): Float32Array
computeSimilarity(emb1: Float32Array, emb2: Float32Array): number
getEmbeddingDim(): number
isModelLoaded(): boolean

// ===== 新增接口 =====
// 使用 HarmonyOS rawfile 资源管理器初始化
initModelFromRawFile(resourceManager: object): boolean

// 说话人管理
registerSpeaker(name: string, embeddings: Float32Array[]): boolean
removeSpeaker(name: string): boolean
getAllSpeakers(): string[]
getNumSpeakers(): number
containsSpeaker(name: string): boolean

// 说话人识别
identifySpeaker(embedding: Float32Array, threshold: number): object
  // 返回: { name: string, score: number } | { name: "", score: 0 }

getBestMatches(embedding: Float32Array, threshold: number, topN: number): object[]
  // 返回: [{ name: string, score: number }, ...]

// 说话人验证
verifySpeaker(name: string, embedding: Float32Array, threshold: number): boolean

// 导入/导出声纹数据 (用于持久化)
exportSpeakerEmbedding(name: string): Float32Array | null
importSpeakerEmbedding(name: string, embedding: Float32Array): boolean
```

### 5.2 C++ 实现要点

```cpp
#include "sherpa-onnx/c-api/c-api.h"

static constexpr int EMBEDDING_DIM = 192;
static bool g_initialized = false;
static const SherpaOnnxSpeakerEmbeddingExtractor *g_extractor = nullptr;
static const SherpaOnnxSpeakerEmbeddingManager *g_manager = nullptr;

// ---- InitModel (修改现有实现) ----
static napi_value InitModel(napi_env env, napi_callback_info info) {
    // 1. 解析 modelDir 参数
    // 2. 构建配置
    SherpaOnnxSpeakerEmbeddingExtractorConfig config;
    memset(&config, 0, sizeof(config));
    config.model = modelPath.c_str();
    config.num_threads = 2;
    config.provider = "cpu";

    // 3. 创建 extractor
    g_extractor = SherpaOnnxCreateSpeakerEmbeddingExtractor(&config);
    if (!g_extractor) return false;

    // 4. 创建 manager
    int dim = SherpaOnnxSpeakerEmbeddingExtractorDim(g_extractor);
    g_manager = SherpaOnnxCreateSpeakerEmbeddingManager(dim);

    g_initialized = true;
    return true;
}

// ---- ExtractEmbedding (修改现有实现) ----
static napi_value ExtractEmbedding(napi_env env, napi_callback_info info) {
    // 1. 解析 Float32Array pcmData 和 sampleRate
    // 2. 创建 stream 并送入音频
    const SherpaOnnxOnlineStream *stream =
        SherpaOnnxSpeakerEmbeddingExtractorCreateStream(g_extractor);
    SherpaOnnxOnlineStreamAcceptWaveform(stream, sampleRate, pcmSamples, length);
    SherpaOnnxOnlineStreamInputFinished(stream);

    // 3. 检查就绪状态
    if (!SherpaOnnxSpeakerEmbeddingExtractorIsReady(g_extractor, stream)) {
        // 音频太短，返回 null
        SherpaOnnxDestroyOnlineStream(stream);
        return nullptr;
    }

    // 4. 计算嵌入
    const float *embedding =
        SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(g_extractor, stream);

    // 5. 复制到 Float32Array 返回
    // ... (同现有代码)

    // 6. 释放资源
    SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(embedding);
    SherpaOnnxDestroyOnlineStream(stream);
    return resultArray;
}

// ---- RegisterSpeaker (新增) ----
static napi_value RegisterSpeaker(napi_env env, napi_callback_info info) {
    // 1. 解析 name (string) 和 embeddings (Float32Array[])
    // 2. 将多个嵌入展平为连续数组
    // 3. 调用 SherpaOnnxSpeakerEmbeddingManagerAddListFlattened(
    //        g_manager, name, flattenedData, count)
    // 4. 返回 boolean 结果
}

// ---- IdentifySpeaker (新增) ----
static napi_value IdentifySpeaker(napi_env env, napi_callback_info info) {
    // 1. 解析 embedding (Float32Array) 和 threshold (number)
    // 2. 调用 SherpaOnnxSpeakerEmbeddingManagerSearch(
    //        g_manager, embData, threshold)
    // 3. 构建返回对象 { name, score }
}
```

### 5.3 更新 TypeScript 声明

```typescript
// entry/src/main/cpp/types/libvoiceprint/index.d.ts

// 现有
export const initModel: (modelDir: string) => boolean;
export const extractEmbedding: (pcmData: Float32Array, sampleRate: number) => Float32Array;
export const computeSimilarity: (embedding1: Float32Array, embedding2: Float32Array) => number;
export const getEmbeddingDim: () => number;
export const isModelLoaded: () => boolean;

// 新增
export const registerSpeaker: (name: string, embeddings: Float32Array[]) => boolean;
export const removeSpeaker: (name: string) => boolean;
export const getAllSpeakers: () => string[];
export const getNumSpeakers: () => number;
export const containsSpeaker: (name: string) => boolean;

export interface SpeakerMatch {
  name: string;
  score: number;
}

export const identifySpeaker: (
  embedding: Float32Array, threshold: number
) => SpeakerMatch;

export const getBestMatches: (
  embedding: Float32Array, threshold: number, topN: number
) => SpeakerMatch[];

export const verifySpeaker: (
  name: string, embedding: Float32Array, threshold: number
) => boolean;

export const exportSpeakerEmbedding: (name: string) => Float32Array | null;
export const importSpeakerEmbedding: (name: string, embedding: Float32Array) => boolean;
```

---

## 6. ETS Service 层设计

### 6.1 VoiceprintService.ets

```typescript
// entry/src/main/ets/service/VoiceprintService.ets

import voiceprint from 'libvoiceprint.so';
import { preferences } from '@kit.ArkData';

interface VoiceprintProfile {
  name: string;           // 说话人名称
  enrolledAt: number;     // 注册时间戳
  sampleCount: number;    // 注册时使用的语音样本数
  embedding: number[];    // 平均嵌入向量 (192 维)
}

interface IdentifyResult {
  speaker: string;        // 说话人名称，"" 表示未识别
  score: number;          // 相似度分数 [0, 1]
  confidence: 'high' | 'medium' | 'low' | 'unknown';
}

class VoiceprintService {
  private static instance: VoiceprintService;
  private initialized: boolean = false;
  private store: preferences.Preferences | null = null;

  // 阈值配置
  private readonly VERIFY_THRESHOLD = 0.6;    // 验证阈值
  private readonly IDENTIFY_THRESHOLD = 0.5;  // 识别阈值
  private readonly HIGH_CONFIDENCE = 0.75;    // 高置信度
  private readonly MEDIUM_CONFIDENCE = 0.6;   // 中置信度
  private readonly MIN_AUDIO_DURATION_MS = 2000; // 最短语音时长

  static getInstance(): VoiceprintService { ... }

  // ---- 初始化 ----
  async init(context: Context): Promise<boolean> {
    // 1. 加载 Preferences 存储
    this.store = await preferences.getPreferences(context, 'voiceprint_db');

    // 2. 初始化 NAPI 模型
    const modelDir = 'voiceprint'; // rawfile 目录
    this.initialized = voiceprint.initModel(modelDir);

    // 3. 从持久化存储恢复已注册声纹到 Manager
    await this.restoreProfiles();

    return this.initialized;
  }

  // ---- 声纹注册 ----
  async enrollSpeaker(name: string, audioSamples: Float32Array[]): Promise<boolean> {
    // 1. 验证每段音频长度 >= MIN_AUDIO_DURATION_MS
    // 2. 提取每段音频的嵌入向量
    const embeddings: Float32Array[] = [];
    for (const pcm of audioSamples) {
      const emb = voiceprint.extractEmbedding(pcm, 16000);
      embeddings.push(emb);
    }

    // 3. 注册到 Manager
    const ok = voiceprint.registerSpeaker(name, embeddings);

    // 4. 计算平均嵌入并持久化
    if (ok) {
      const avgEmbedding = this.averageEmbeddings(embeddings);
      const profile: VoiceprintProfile = {
        name, enrolledAt: Date.now(),
        sampleCount: audioSamples.length,
        embedding: Array.from(avgEmbedding)
      };
      await this.saveProfile(profile);
    }

    return ok;
  }

  // ---- 说话人识别 ----
  async identify(pcmData: Float32Array): Promise<IdentifyResult> {
    const embedding = voiceprint.extractEmbedding(pcmData, 16000);
    const match = voiceprint.identifySpeaker(embedding, this.IDENTIFY_THRESHOLD);

    let confidence: 'high' | 'medium' | 'low' | 'unknown';
    if (match.name === '') {
      confidence = 'unknown';
    } else if (match.score >= this.HIGH_CONFIDENCE) {
      confidence = 'high';
    } else if (match.score >= this.MEDIUM_CONFIDENCE) {
      confidence = 'medium';
    } else {
      confidence = 'low';
    }

    return { speaker: match.name, score: match.score, confidence };
  }

  // ---- 说话人验证 ----
  async verify(name: string, pcmData: Float32Array): Promise<boolean> {
    const embedding = voiceprint.extractEmbedding(pcmData, 16000);
    return voiceprint.verifySpeaker(name, embedding, this.VERIFY_THRESHOLD);
  }

  // ---- 管理 ----
  async removeSpeaker(name: string): Promise<boolean> { ... }
  async listSpeakers(): Promise<VoiceprintProfile[]> { ... }

  // ---- 持久化 ----
  private async saveProfile(profile: VoiceprintProfile): Promise<void> {
    // Preferences: key="vp_{name}", value=JSON.stringify(profile)
  }

  private async restoreProfiles(): Promise<void> {
    // 1. 从 Preferences 读取所有 vp_* 键
    // 2. 解析 VoiceprintProfile
    // 3. 调用 voiceprint.importSpeakerEmbedding() 恢复到 Manager
  }

  private averageEmbeddings(embeddings: Float32Array[]): Float32Array {
    const dim = voiceprint.getEmbeddingDim();
    const avg = new Float32Array(dim);
    for (const emb of embeddings) {
      for (let i = 0; i < dim; i++) avg[i] += emb[i];
    }
    for (let i = 0; i < dim; i++) avg[i] /= embeddings.length;
    return avg;
  }
}
```

### 6.2 音频预处理

现有 `MicrophoneCapability.ets` 录制 44100Hz AAC 格式，需要转换为 16000Hz Float32 PCM：

```typescript
// entry/src/main/ets/service/AudioProcessor.ets

class AudioProcessor {
  /**
   * 将 44100Hz PCM Int16 转为 16000Hz Float32
   * 使用线性插值降采样
   */
  static resample44100to16000(input: Int16Array): Float32Array {
    const ratio = 44100 / 16000;
    const outputLen = Math.floor(input.length / ratio);
    const output = new Float32Array(outputLen);

    for (let i = 0; i < outputLen; i++) {
      const srcIdx = i * ratio;
      const idx0 = Math.floor(srcIdx);
      const idx1 = Math.min(idx0 + 1, input.length - 1);
      const frac = srcIdx - idx0;

      // 线性插值 + 归一化到 [-1, 1]
      const sample = input[idx0] * (1 - frac) + input[idx1] * frac;
      output[i] = sample / 32768.0;
    }

    return output;
  }

  /**
   * 直接采集 16000Hz PCM (用于声纹专用录音)
   * 使用 AudioCapturer 替代 AVRecorder，获取原始 PCM 数据
   */
  static async capturePCM16k(durationMs: number): Promise<Float32Array> {
    // 使用 @kit.AudioKit AudioCapturer
    // 配置: 16000Hz, mono, Int16
    // 返回归一化 Float32Array
  }
}
```

**推荐方案：声纹录音时直接使用 AudioCapturer 采集 16kHz PCM**

```typescript
import { audio } from '@kit.AudioKit';

async function captureForVoiceprint(durationMs: number): Promise<Float32Array> {
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

  const capturer = await audio.createAudioCapturer({
    streamInfo: audioStreamInfo,
    capturerInfo: capturerInfo,
  });

  const chunks: ArrayBuffer[] = [];
  capturer.on('readData', (buffer: ArrayBuffer) => {
    chunks.push(buffer.slice(0));
  });

  await capturer.start();
  await delay(durationMs);
  await capturer.stop();
  await capturer.release();

  // 合并 chunks 并转为 Float32Array
  const totalLen = chunks.reduce((s, c) => s + c.byteLength, 0);
  const merged = new Int16Array(totalLen / 2);
  let offset = 0;
  for (const chunk of chunks) {
    const view = new Int16Array(chunk);
    merged.set(view, offset);
    offset += view.length;
  }

  // 归一化
  const float32 = new Float32Array(merged.length);
  for (let i = 0; i < merged.length; i++) {
    float32[i] = merged[i] / 32768.0;
  }
  return float32;
}
```

---

## 7. 声纹注册 UX 流程

### 7.1 注册步骤

```
Step 1: 输入说话人名称
  ┌─────────────────────────┐
  │  请输入您的名称          │
  │  [___________________]  │
  │            [下一步 →]   │
  └─────────────────────────┘

Step 2: 录制语音样本 (重复 3 次)
  ┌─────────────────────────┐
  │  请朗读以下文字 (1/3):   │
  │                         │
  │  "今天天气真不错，       │
  │   我们一起出去散步吧"    │
  │                         │
  │   🎤 [开始录音]         │
  │                         │
  │  录音时长: 0:00 / 0:05  │
  │  ████████░░ 80%         │
  └─────────────────────────┘

Step 3: 注册确认
  ┌─────────────────────────┐
  │  声纹注册成功!           │
  │                         │
  │  说话人: 小明            │
  │  样本数: 3              │
  │  质量评估: 优秀          │
  │                         │
  │         [完成]          │
  └─────────────────────────┘
```

### 7.2 注册引导文本（多样性）

为确保声纹覆盖不同发音模式，提供多组引导文本：

```typescript
const ENROLLMENT_PROMPTS: string[][] = [
  [
    "今天天气真不错，我们一起出去散步吧",
    "最近工作很忙，不过周末可以好好休息",
    "我喜欢在安静的环境里读书和思考",
  ],
  [
    "科技的发展日新月异，人工智能改变了我们的生活",
    "春天来了，花园里的花朵开得特别美丽",
    "这家餐厅的菜品很丰富，味道也非常好",
  ],
];
```

### 7.3 质量检查

注册时对每段录音进行质量评估：

| 检查项 | 条件 | 处理 |
|--------|------|------|
| 时长充足 | >= 3 秒有效语音 | 不足则提示重录 |
| 信噪比 | PCM 幅值方差 > 阈值 | 太安静则提示 |
| 嵌入有效 | extractEmbedding 非零 | 失败则重试 |
| 一致性 | 多段录音间相似度 > 0.5 | 差异大则提示 |

---

## 8. 声纹存储方案

### 8.1 存储结构

使用 HarmonyOS Preferences (轻量级 KV 存储):

```
Key: "voiceprint_profiles"
Value: JSON 字符串

{
  "speakers": [
    {
      "name": "小明",
      "enrolledAt": 1708012800000,
      "sampleCount": 3,
      "embedding": [0.123, -0.456, 0.789, ...]  // 192 个 float
    },
    {
      "name": "小红",
      "enrolledAt": 1708099200000,
      "sampleCount": 3,
      "embedding": [0.234, -0.567, 0.890, ...]
    }
  ],
  "version": 1
}
```

### 8.2 存储大小估算

| 项目 | 大小 |
|------|------|
| 单个嵌入向量 (192 × float32) | 768 字节 |
| JSON 序列化后 (含精度) | ~2 KB |
| 10 个说话人 | ~20 KB |
| 100 个说话人 | ~200 KB |

存储开销极小，Preferences 完全满足需求。

### 8.3 应用启动时恢复

```
App 启动
    │
    ▼
VoiceprintService.init()
    │
    ├── 1. 加载 ONNX 模型 → g_extractor
    ├── 2. 创建 Manager → g_manager
    ├── 3. 读取 Preferences
    │       │
    │       ▼
    │   遍历 profiles:
    │     importSpeakerEmbedding(name, embedding)
    │       │
    │       ▼
    │   Manager 内存中恢复声纹库
    │
    ▼
  就绪，可进行声纹识别
```

---

## 9. 相似度阈值策略

### 9.1 推荐阈值

| 场景 | 阈值 | FAR (误接受) | FRR (误拒绝) | 说明 |
|------|------|-------------|-------------|------|
| 宽松识别 | 0.45 | 较高 | 低 | 用户体验优先 |
| 标准识别 | 0.55 | 中等 | 中等 | 日常使用推荐 |
| 严格验证 | 0.65 | 低 | 较高 | 安全场景 |
| 高安全 | 0.75 | 极低 | 高 | 支付/解锁 |

### 9.2 置信度映射

```typescript
function getConfidence(score: number): string {
  if (score >= 0.75) return 'high';      // 高置信度，几乎确定
  if (score >= 0.60) return 'medium';    // 中等置信度，可信
  if (score >= 0.45) return 'low';       // 低置信度，需确认
  return 'unknown';                       // 未识别
}
```

### 9.3 自适应阈值（可选增强）

根据注册样本数量动态调整阈值：

- 1 个样本: threshold × 0.9（放宽，因为模板不够鲁棒）
- 3 个样本: threshold × 1.0（标准）
- 5+ 个样本: threshold × 1.05（收紧，模板更可靠）

---

## 10. CMake 构建集成

### 10.1 取消注释并完善 CMakeLists.txt

```cmake
# entry/src/main/cpp/voiceprint/CMakeLists.txt

cmake_minimum_required(VERSION 3.5.0)
project(voiceprint)

set(SHERPA_ONNX_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../sherpa_onnx)

add_library(voiceprint SHARED voiceprint_napi.cpp)
target_link_libraries(voiceprint PUBLIC libace_napi.z.so)

# sherpa-onnx 集成
if(EXISTS "${SHERPA_ONNX_DIR}/lib/${OHOS_ARCH}/libsherpa-onnx-c-api.so")
    target_include_directories(voiceprint PRIVATE ${SHERPA_ONNX_DIR}/include)
    target_link_directories(voiceprint PRIVATE ${SHERPA_ONNX_DIR}/lib/${OHOS_ARCH})
    target_link_libraries(voiceprint PRIVATE
        sherpa-onnx-c-api
        sherpa-onnx-core
        onnxruntime
    )
    target_compile_definitions(voiceprint PRIVATE SHERPA_ONNX_AVAILABLE=1)
    message(STATUS "sherpa-onnx found at ${SHERPA_ONNX_DIR}")
else()
    message(WARNING "sherpa-onnx not found. Using stub implementations.")
endif()
```

### 10.2 ohpm 依赖（备选方案）

如果使用 ohpm 包而非手动下载：

```json5
// entry/oh-package.json5
{
  "dependencies": {
    "sherpa_onnx": "1.12.1"
  }
}
```

ohpm 包会自动处理 native 库的链接，CMakeLists.txt 中通过 `find_package` 或直接链接 ohpm 提供的库路径。

---

## 11. 与现有功能的集成

### 11.1 对话中自动识别说话人

在 ChatPage 中，当用户通过麦克风录入语音时，同步进行声纹识别：

```
用户按住"语音输入"
    │
    ├── ASR: 语音转文字 (LocalAsrService)
    │
    └── 声纹识别: 识别说话人 (VoiceprintService)
         │
         ▼
    消息元数据中附带说话人信息:
    {
      text: "今天天气怎么样",
      speaker: "小明",
      speakerScore: 0.82
    }
```

### 11.2 Gateway 能力扩展

在 NodeRuntime 中添加声纹相关命令：

```typescript
// 新增 Command
enum Command {
  // ... 现有命令
  VOICEPRINT_ENROLL = 'voiceprint.enroll',
  VOICEPRINT_IDENTIFY = 'voiceprint.identify',
  VOICEPRINT_VERIFY = 'voiceprint.verify',
  VOICEPRINT_LIST = 'voiceprint.list',
  VOICEPRINT_REMOVE = 'voiceprint.remove',
}
```

### 11.3 多用户会话隔离

声纹识别可用于自动切换用户上下文：

```
识别到 "小明" → 加载小明的会话历史和偏好设置
识别到 "小红" → 加载小红的会话历史和偏好设置
未识别         → 使用默认/访客会话
```

---

## 12. 实施计划

### Phase 1: 核心功能（声纹提取和比对）

**目标**：完成 C++ NAPI 层的 sherpa-onnx 集成

1. 取消注释 CMakeLists.txt 中的 sherpa-onnx 链接
2. 修改 `voiceprint_napi.cpp`：
   - `InitModel()` — 调用 `SherpaOnnxCreateSpeakerEmbeddingExtractor`
   - `ExtractEmbedding()` — 调用实际 sherpa-onnx API
   - 确保资源正确释放
3. 验证嵌入提取功能正确性

### Phase 2: 说话人管理

**目标**：完成注册/识别/验证完整流程

1. 在 C++ 层添加 Manager 相关 NAPI 函数
2. 实现 `VoiceprintService.ets`
3. 实现 `AudioProcessor.ets`（PCM 采集和预处理）
4. 实现 Preferences 持久化存储

### Phase 3: UI 和集成

**目标**：用户可见的声纹功能

1. 实现 `VoiceprintPage.ets`（注册引导 UI）
2. 在 SettingsPage 添加声纹管理入口
3. 在 ChatPage 集成实时声纹识别
4. 在 NodeRuntime 添加 Gateway 命令

### Phase 4: 优化和增强

**目标**：提升准确度和用户体验

1. 阈值调优（基于实际测试数据）
2. 增量注册（追加更多样本提升准确度）
3. 录音质量检测和提示
4. 降噪预处理（可选）

---

## 13. 风险和注意事项

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| 模型推理耗时导致 ANR | 用户界面卡顿 | 在 Worker 线程中执行，参考 LocalEmbedding 经验 |
| 环境噪声影响准确度 | 识别率下降 | 提示用户在安静环境注册，录音质量检测 |
| 44100→16000 重采样误差 | 嵌入质量下降 | 直接用 AudioCapturer 采集 16kHz |
| 声纹随时间变化（感冒、年龄）| 验证失败率升高 | 支持重新注册、多次注册取平均 |
| 双胞胎/相似声纹 | 误识别 | 在安全敏感场景需结合其他验证方式 |
| sherpa-onnx 库体积 | 包大小增加 ~15-20MB | 可接受，本地化处理的必要开销 |
| HarmonyOS 麦克风权限 | 首次使用需授权 | 在 module.json5 声明 ohos.permission.MICROPHONE |

---

## 14. 性能预估

| 指标 | 预估值 | 说明 |
|------|--------|------|
| 模型加载时间 | 500ms ~ 1s | 首次初始化，后续复用 |
| 嵌入提取时间 | 50ms ~ 200ms | 取决于音频长度和设备性能 |
| 相似度计算 | < 1ms | 纯向量运算 |
| 说话人搜索 (10人) | < 5ms | Manager 内部比对 |
| 内存占用 | ~50MB | 模型 + 运行时 |
| 最短有效音频 | 1~2 秒 | 短于此嵌入不稳定 |
| 推荐注册音频 | 3~5 秒 × 3 段 | 更多样本更鲁棒 |
