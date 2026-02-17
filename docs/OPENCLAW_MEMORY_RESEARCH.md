# OpenClaw 记忆系统研究报告

## 1. 研究概述

本报告深入研究了 OpenClaw 的记忆系统设计，对比了 ClawdBot 当前的 MemoryService 实现，并提出了具体的改进方案。

---

## 2. OpenClaw 记忆架构

### 2.1 核心设计哲学

| 原则 | 说明 |
|------|------|
| **Markdown 为源** | 所有记忆以 Markdown 文件存储，人类可读、Git 友好 |
| **混合搜索** | BM25 关键词 + 向量语义搜索，双信号融合 |
| **离线优先** | 本地 SQLite + 可选本地嵌入模型，无需云服务 |
| **异步非阻塞** | 索引和嵌入生成在后台运行，不阻塞对话 |
| **隐私分域** | 记忆按会话类型隔离（私聊 vs 群组） |
| **优雅降级** | 嵌入失败退回关键词搜索，向量不可用退回纯文本 |

### 2.2 文件结构

```
~/.openclaw/workspace/
├── MEMORY.md                    # 核心长期记忆（精炼、持久）
├── memory/
│   ├── YYYY-MM-DD.md           # 每日日记（仅追加）
│   └── YYYY-MM-DD-slug.md     # 会话快照（/new 触发）
└── .memory/
    └── index.sqlite            # 派生索引（可重建）
```

### 2.3 两层记忆策略

**第一层: MEMORY.md (精炼长期记忆)**
- 核心事实、用户偏好、关键决策
- 保持小巧高效
- 会话开始时自动加载

**第二层: memory/YYYY-MM-DD.md (每日日记)**
- 日常笔记、对话片段、决策记录
- 仅追加，系统不会破坏性编辑
- 会话开始时加载今天 + 昨天的日记

### 2.4 记忆工具

**memory_search(query, maxResults?)**
- 语义搜索所有索引的 Markdown
- 返回: path, startLine, endLine, score, snippet, source
- 片段最大约 700 字符

**memory_get(relPath, from?, lines?)**
- 精确读取指定文件内容
- 用于在 search 找到命中后读取完整上下文

### 2.5 混合搜索算法

```
finalScore = vectorWeight × vectorScore + textWeight × textScore
```

- 默认权重: 70% 向量 + 30% 关键词
- 向量擅长: 同义词、改写、语义相似
- BM25 擅长: 精确 ID、代码符号、错误信息
- 候选放大倍数: 4x (每侧取 maxResults × 4 候选)

### 2.6 Pre-Compaction Memory Flush

当会话上下文接近压缩阈值时:
1. 系统注入静默提示: "Session nearing compaction. Store durable memories now."
2. 模型决定是否需要保存记忆
3. 如无需保存，回复 `NO_REPLY`（用户不可见）
4. 每个压缩周期仅触发一次

### 2.7 记忆分类体系

| 类别 | 说明 | 示例 |
|------|------|------|
| fact | 客观事实 | "生日是 11月27日" |
| preference | 偏好 | "喜欢简洁回复" |
| instruction | 指令 | "永远用 ISO 8601 日期格式" |
| decision | 决策 | "将使用 Stripe 支付" |
| entity | 实体 | 联系人信息 |

### 2.8 来源引用 (Source Citation)

搜索结果包含:
```typescript
{
  path: "memory/2026-01-16.md",
  startLine: 12,
  endLine: 18,
  score: 0.85,
  snippet: "...",
  citation: "Source: memory/2026-01-16.md#L12-L18"
}
```

---

## 3. ClawdBot 当前实现 vs OpenClaw

### 3.1 对比表

| 功能 | OpenClaw | ClawdBot 当前 | 差距 |
|------|---------|-------------|------|
| 存储格式 | Markdown 文件 (MEMORY.md + 每日日记) | Preferences JSON + memory.md 摘要 | 中 |
| 搜索方式 | 混合 BM25+向量 (加权融合) | 向量优先，失败退回关键词 | 高 |
| 每日日记 | memory/YYYY-MM-DD.md 自动记录 | 无 | 高 |
| 记忆分类 | fact/preference/instruction/decision/entity | fact/preference/instruction | 低 |
| 来源引用 | Source: path#line (可配置) | 无 | 高 |
| 自动提取 | 正则 + AI 分析 + 插件钩子 | 正则 + AI 分析 | 低 |
| 发消息自动检索 | 自动嵌入查询注入上下文 | 有 (searchRelevantMemories) | 低 |
| Pre-compaction flush | 有 (静默提示保存记忆) | 无 | 中 |
| 记忆去重 | 精确匹配 + 语义相似度 (0.95) | 精确匹配 | 中 |
| 嵌入缓存 | SQLite 缓存，避免重复嵌入 | 无 | 中 |
| 本地嵌入 | node-llama-cpp (可用) | MiniLM-L6-v2 (已禁用) | 中 |

### 3.2 ClawdBot 的优势

- **移动优化**: 专为 HarmonyOS 设计，Preferences 存储适合移动端
- **网关同步**: 可通过 gateway 服务端同步记忆
- **双语支持**: 中英文正则提取模式
- **即时可用**: 无需额外安装组件

### 3.3 主要差距

1. **无混合搜索**: 当前是"向量优先，失败退回关键词"，不是加权融合
2. **无每日日记**: 缺少时间维度的记忆组织
3. **无来源引用**: AI 回答时无法引用记忆来源
4. **去重不够智能**: 仅精确匹配，语义相似的记忆会重复保存
5. **搜索结果无评分**: 无法让 AI 知道记忆的相关度

---

## 4. 改进方案

### 4.1 改进记忆存储格式

**新增**: 每日日记文件 `memory/YYYY-MM-DD.md`

```markdown
# 2026-02-16

## 10:30 - 对话记录
- 用户询问了天气情况
- 用户提到下周要出差去上海

## 14:00 - 新记忆
- [fact] 用户下周要去上海出差
```

**改进**: `buildPromptBlock()` 格式增加来源标注

### 4.2 混合搜索实现

```typescript
hybridSearch(query, items, vectors): ScoredMemory[] {
  // 1. 向量搜索候选 (topK × 4)
  vectorCandidates = vectorSearch(query, topK * 4)

  // 2. 关键词搜索候选 (topK × 4)
  keywordCandidates = keywordSearch(query, topK * 4)

  // 3. 按 ID 合并，计算加权分数
  finalScore = 0.7 * vectorScore + 0.3 * keywordScore

  // 4. 排序返回 topK
  return sorted.slice(0, topK)
}
```

### 4.3 来源引用机制

搜索结果新增字段:
```typescript
interface MemorySearchResult {
  item: MemoryItem;
  score: number;
  method: 'hybrid' | 'vector' | 'keyword';
  source?: string;  // "memory:mem_xxx" 或 "diary:2026-02-16"
}
```

### 4.4 语义去重

在 `addIfNew()` 中增加语义相似度检查:
- 精确匹配 → 跳过
- 余弦相似度 > 0.92 → 跳过（语义重复）

### 4.5 实现步骤

1. **MemoryService** - 添加混合搜索、每日日记、来源引用
2. **Models** - 新增 `MemorySearchResult` 和 `DiaryEntry` 类型
3. **ChatPage** - 更新 `buildPromptBlock` 格式、搜索结果展示
4. **AIService** - 更新 `search_memory` 工具返回带评分和来源的结果
5. **SkillData** - 更新工具描述

---

## 5. 不适用于移动端的 OpenClaw 特性

以下特性因移动端限制暂不实现:

| 特性 | 原因 |
|------|------|
| SQLite FTS5 索引 | HarmonyOS ArkData 不直接暴露 FTS5 |
| QMD 后端 | 需要独立进程，移动端不适用 |
| 文件系统监听 | 移动端无需监听文件变化 |
| Pre-compaction flush | ClawdBot 无上下文压缩机制 |
| node-llama-cpp 本地嵌入 | 已有 MiniLM 但 ANR 问题待解 |

---

## 6. 结论

OpenClaw 的记忆系统设计精良，核心思想可以适配到移动端:
- **混合搜索**是最大的改进点，显著提升检索质量
- **每日日记**为记忆增加时间维度
- **来源引用**让 AI 回答更可追溯
- **语义去重**避免记忆膨胀

通过这些改进，ClawdBot 的记忆系统将从"基础可用"提升到"智能高效"。
