# Embedding 模型调研报告

> 日期: 2026-02-16

## 1. 现状分析

### 1.1 当前架构

```
用户输入 → MemoryService.embed()
            ├── 本地模式: LocalEmbedding (MiniLM-L6-v2, 384维) ← 已禁用
            └── 云端模式: SiliconFlow API (bge-m3, 1024维)    ← 当前唯一可用
```

**LocalEmbedding** (`service/embedding/LocalEmbedding.ets`):
- 模型: all-MiniLM-L6-v2 (6层 Transformer, 30522 词汇量)
- 输出: 384 维向量, L2 归一化
- 权重格式: Float16 二进制文件, 分层存储 (~15MB 总计)
- 状态: **`isReady()` 硬编码返回 `false`**, 永远回退到云端 API

**云端回退** (`MemoryService.ets`):
- 端点: `https://api.siliconflow.cn/v1/embeddings`
- 模型: BAAI/bge-m3
- 输出: 1024 维向量
- 需要 API Key, 有网络延迟

### 1.2 ANR 问题根源

`LocalTransformer.ets` 实现了完整的 6 层 Transformer 推理, 全部在 **主线程** 上运行:

1. **Embedding 层**: 词嵌入 + 位置嵌入 + TokenType嵌入 + LayerNorm
2. **6 层 Transformer**: 每层包含 12头自注意力 + FFN (384→1536→384)
3. **Pooling**: Mean pooling + L2 归一化

尽管 `forwardAsync()` 在每层之间插入了 `setTimeout(0)` 让出事件循环, 但:
- HarmonyOS ANR 阈值为 **3 秒**
- 单层 Transformer 的矩阵运算 (纯 JS/ArkTS) 耗时已接近或超过阈值
- 6 层总计算量远超 3 秒
- `setTimeout(0)` 不能真正并行计算, 只是分时复用主线程

### 1.3 sherpa-onnx 现状

sherpa-onnx HAR (v1.12.21) 已集成用于声纹识别:

| 功能 | 是否支持 |
|------|----------|
| 语音识别 (ASR) | ✅ |
| 文本转语音 (TTS) | ✅ |
| 说话人嵌入提取 | ✅ (192维, 音频→向量) |
| 说话人识别/验证 | ✅ |
| 语音活动检测 (VAD) | ✅ |
| **文本嵌入 (Text Embedding)** | ❌ **不支持** |
| 通用 ONNX 模型加载 | ❌ 不暴露此 API |

关键发现: sherpa-onnx 是专门的语音处理库, **不提供文本 embedding API**, 也**不暴露底层 ONNX Runtime** 供加载任意模型。

---

## 2. 可选方案

### 方案 A: Worker 线程运行现有 MiniLM-L6

**思路**: 将现有 `LocalTransformer` 的推理逻辑移到 Worker 线程, 避免阻塞主线程。

**HarmonyOS 并发选项**:

| 特性 | Worker | TaskPool |
|------|--------|----------|
| 线程生命周期 | 手动管理, 可长期存在 | 系统管理, >3分钟自动回收 |
| 数据传输 | 序列化/Transferable | 序列化/@Concurrent |
| NAPI 调用 | ✅ 支持 | ✅ 支持 |
| 适用场景 | 长时间运行的后台任务 | 短时间离散任务 |

**实现方式**: 使用 **Worker** (非 TaskPool, 因推理可能>3分钟首次加载):

```
主线程                          Worker 线程
  │                                │
  ├── postMessage({text}) ──────→  │
  │                                ├── tokenize(text)
  │                                ├── transformer.forward() // 耗时计算
  │                                ├── pooling + normalize
  │   ←── postMessage({vector}) ── │
  │                                │
```

**优点**:
- 复用现有模型文件和代码, 改动最小
- 完全离线, 无网络依赖
- 384维向量已够用

**缺点**:
- ArkTS Worker 对类型序列化有严格要求, 需重构数据传输
- 模型权重需在 Worker 线程重新加载 (Worker 无法共享主线程内存中的对象)
- 纯 JS/ArkTS 实现的矩阵运算效率低 (无 SIMD, 无 GPU 加速)
- MiniLM-L6 对中文支持一般

**复杂度**: 中

---

### 方案 B: 自建 NAPI C++ 模块加载 ONNX 模型

**思路**: 编写 C++ NAPI 模块, 直接使用 ONNX Runtime C API 加载文本 embedding 模型。

**实现方式**:
1. 引入 ONNX Runtime 预编译库 (HarmonyOS ARM64)
2. 编写 C++ NAPI 包装层 (`text_embedding_napi.cpp`)
3. 加载 ONNX 格式的 embedding 模型 (如 bge-small-zh-v1.5)
4. 在 C++ 层完成 tokenize + inference + pooling

**可选模型**:

| 模型 | 参数量 | 维度 | 大小 | 中文 | 速度 |
|------|--------|------|------|------|------|
| all-MiniLM-L6-v2 | 22M | 384 | ~22MB | 一般 | 快 |
| bge-small-zh-v1.5 | 24M | 512 | ~24MB | ✅ 好 | 快 |
| bge-small-en-v1.5 | 33M | 384 | ~33MB | ❌ | 快 |
| EmbeddingGemma-300M | 308M | 768 | ~200MB | ✅ | 中 |

**优点**:
- C++ 推理速度比 ArkTS 快 10-50x (SIMD, 内存优化)
- 可用 INT8 量化进一步加速 (速度 2-4x, 精度损失 <1%)
- 可选择更好的中文模型 (bge-small-zh)
- 天然在 native 线程运行, 不阻塞 JS 主线程

**缺点**:
- 需要编译 ONNX Runtime for HarmonyOS (可能已有 sherpa-onnx 的依赖可复用)
- 需要实现 tokenizer (C++ 版 WordPiece/BPE)
- 开发量大, 需要 C++ 能力
- 模型文件增加 app 体积

**复杂度**: 高

---

### 方案 C: 仅用云端 API

**思路**: 放弃本地 embedding, 完全依赖云端 API。

**当前已实现**: SiliconFlow bge-m3 (1024维)

**其他可选 API**:

| 服务商 | 模型 | 维度 | 价格 | 特点 |
|--------|------|------|------|------|
| SiliconFlow | bge-m3 | 1024 | 免费额度 | 当前使用, 中文好 |
| OpenAI | text-embedding-3-small | 1536 | $0.02/1M tokens | 英文最佳 |
| 智谱 | embedding-3 | 2048 | 免费额度 | 中文好 |
| Cohere | embed-multilingual-v3 | 1024 | 免费额度 | 多语言 |

**优点**:
- 零开发量 (已实现)
- 模型质量最好 (大模型, 高维度)
- 不增加 app 体积
- 无 ANR 风险

**缺点**:
- 需要网络, 离线不可用
- 网络延迟 (100-500ms per call)
- 依赖第三方服务可用性
- 隐私: 用户记忆文本发送到云端
- API Key 管理

**复杂度**: 低 (已实现)

---

### 方案 D: Worker + 现有模型 + 云端回退 (混合方案)

**思路**: 方案 A + 方案 C 的混合, 分阶段实现。

**Phase 1** (短期): 保持现有云端 API, 优化体验
- 维持 SiliconFlow bge-m3 作为主要方案
- 添加嵌入结果缓存, 避免重复计算
- 离线时暂存待嵌入文本, 联网后批量处理

**Phase 2** (中期): Worker 线程本地推理
- 将 LocalTransformer 移到 Worker 线程
- Worker 启动时加载模型, 常驻后台
- 主线程通过 postMessage 发送文本, 接收向量
- 保留云端作为回退

**Phase 3** (长期, 可选): NAPI 加速
- 如果 Worker 方案中 ArkTS 推理仍然太慢 (>5s/次)
- 将矩阵运算核心函数用 C++ NAPI 实现
- 或等待 sherpa-onnx 官方支持文本 embedding

**优点**:
- 渐进式改进, 风险低
- 每个阶段都有可用产品
- 在线/离线都能工作

**缺点**:
- 总开发量较大
- 本地和云端使用不同模型/维度, 需要模型迁移逻辑 (已有)

**复杂度**: 低→中→高 (分阶段)

---

## 3. 方案对比总结

| 维度 | A: Worker线程 | B: NAPI C++ | C: 纯云端 | D: 混合方案 |
|------|:---:|:---:|:---:|:---:|
| 开发量 | 中 | 高 | ✅ 零 | 低→高 |
| 离线可用 | ✅ | ✅ | ❌ | ✅ |
| 推理速度 | 慢 (3-10s) | ✅ 快 (<500ms) | 中 (网络) | 看阶段 |
| 中文质量 | 一般 | ✅ 可选好模型 | ✅ 好 | ✅ |
| ANR 风险 | ✅ 无 | ✅ 无 | ✅ 无 | ✅ 无 |
| 隐私 | ✅ 本地 | ✅ 本地 | ❌ 云端 | ✅ 可选 |
| 包体积 | 已含 | +20-200MB | ✅ 无增加 | 已含 |
| 维护成本 | 低 | 高 | ✅ 低 | 中 |

---

## 4. 推荐方案

### 推荐: 方案 D (混合方案), 优先实现 Phase 1 + Phase 2

**理由**:
1. **Phase 1 零成本**: 云端 API 已实现, 只需加缓存和离线队列
2. **Phase 2 解决核心问题**: Worker 线程是 HarmonyOS 推荐的重计算方案, 且可复用现有 90% 代码
3. **渐进式风险管理**: 每阶段可独立交付, 不影响现有功能
4. **Phase 3 可观望**: 等 sherpa-onnx 是否添加文本 embedding 支持, 或 HarmonyOS 是否提供系统级 embedding API

### 不推荐方案 B 的理由:
- sherpa-onnx 不暴露通用 ONNX Runtime API, 无法复用
- 自建 ONNX Runtime NAPI 开发量大, 收益不确定
- HarmonyOS ARM64 的 ONNX Runtime 预编译库可获取性未知

---

## 5. 实现步骤 (Phase 1 + Phase 2)

### Phase 1: 云端优化 (预计 1-2 天)

1. **嵌入缓存**: 在 `MemoryService` 中添加 LRU 缓存, key=hash(text+model), value=vector
2. **离线队列**: 离线时将 `{id, text}` 存入队列, 联网后批量调 API
3. **批量嵌入**: 修改 `embed()` 支持批量输入, 减少 API 调用次数

### Phase 2: Worker 线程本地推理 (预计 3-5 天)

1. **创建 Worker 文件**: `entry/src/main/ets/workers/EmbeddingWorker.ets`
   ```
   // Worker 线程入口
   - 接收: {type: 'init', context} | {type: 'embed', text, requestId}
   - 发送: {type: 'ready'} | {type: 'result', vector, requestId}
   ```

2. **迁移推理逻辑**:
   - 将 `LocalTokenizer` 和 `LocalTransformer` 的核心逻辑复制到 Worker 可访问的模块
   - Worker 中加载模型权重 (通过 rawfile 路径)
   - 使用同步 `forward()` (Worker 线程中无需异步让出)

3. **修改 LocalEmbedding**:
   - `init()`: 创建 Worker, 等待 `ready` 消息
   - `embed()`: postMessage 发送文本, 返回 Promise 等待结果
   - `isReady()`: 恢复为 `return this.loaded`

4. **数据序列化处理**:
   - 模型权重: Worker 自行从 rawfile 加载 (不传输)
   - 输入: 传字符串 (轻量)
   - 输出: 传 `number[]` (384 个数字, 约 3KB, 序列化开销可忽略)

5. **错误处理与回退**:
   - Worker 创建失败 → 回退云端
   - Worker 推理超时 (>30s) → 终止并回退云端
   - Worker 崩溃 → 自动重启

---

## 附录: 参考资源

- [sherpa-onnx GitHub](https://github.com/k2-fsa/sherpa-onnx) - 语音处理 (不支持文本 embedding)
- [HarmonyOS TaskPool 文档](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/taskpool-introduction)
- [HarmonyOS Worker vs TaskPool 对比](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/taskpool-vs-worker-V5)
- [EmbeddingGemma-300M](https://huggingface.co/onnx-community/embeddinggemma-300m-ONNX) - Google 轻量 embedding 模型
- [FastEmbed ONNX](https://johal.in/fastembed-onnx-lightweight-embedding-inference-2025/) - 轻量 embedding 推理框架
- [bge-small-zh-v1.5](https://huggingface.co/BAAI/bge-small-zh-v1.5) - 中文 embedding 模型
