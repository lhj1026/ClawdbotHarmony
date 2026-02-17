import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { MemoryItem, MemoryData, VectorData, VectorStore, MemorySearchResult, DiaryEntry } from '../model/Models';
import { Constants } from '../common/Constants';
import { LogService } from '../common/LogService';
import { LocalEmbedding } from './embedding/LocalEmbedding';

interface ScoredMemory {
  item: MemoryItem;
  score: number;
}

interface EmbeddingResponse {
  data: EmbeddingDataItem[];
}

interface EmbeddingDataItem {
  embedding: number[];
}

/**
 * Persistent memory service with hybrid search, daily diary, and source citations.
 *
 * Inspired by OpenClaw's memory architecture:
 * - Hybrid BM25 + vector search (weighted score fusion)
 * - Daily diary files (memory/YYYY-MM-DD.md)
 * - Source citations on search results
 * - Semantic deduplication
 * - Human-readable MEMORY.md summary
 */
export class MemoryService {
  private static instance: MemoryService | undefined = undefined;
  private log: LogService = LogService.getInstance();
  private readonly TAG = 'MemoryService';
  private localEmb: LocalEmbedding = LocalEmbedding.getInstance();
  private migrationDone: boolean = false;
  private _nodeMode: boolean = false;

  // Hybrid search weights (OpenClaw default: 0.7 vector, 0.3 keyword)
  private readonly VECTOR_WEIGHT: number = 0.7;
  private readonly KEYWORD_WEIGHT: number = 0.3;
  private readonly CANDIDATE_MULTIPLIER: number = 4;

  // Semantic dedup threshold — skip if cosine sim > this
  private readonly SEMANTIC_DEDUP_THRESHOLD: number = 0.92;

  /** Set node mode flag. In node mode, cloud embedding API is not called
   *  because cloud processing is handled by the gateway server. */
  setNodeMode(nodeMode: boolean): void {
    this._nodeMode = nodeMode;
    this.log.info(this.TAG, `nodeMode=${nodeMode}`);
  }

  static getInstance(): MemoryService {
    if (!MemoryService.instance) {
      MemoryService.instance = new MemoryService();
    }
    return MemoryService.instance;
  }

  // ==================== Public API ====================

  async loadAll(context: Context): Promise<MemoryItem[]> {
    let store = await preferences.getPreferences(context, Constants.PREFS_MEMORY);
    let raw = await store.get('entries', '[]') as string;
    let arr: MemoryData[] = JSON.parse(raw) as MemoryData[];
    let items: MemoryItem[] = [];
    for (let d of arr) {
      let item = new MemoryItem(d.memType, d.content, d.importance);
      item.id = d.id;
      item.createdAt = d.createdAt;
      items.push(item);
    }
    return items;
  }

  async save(context: Context, items: MemoryItem[]): Promise<void> {
    let store = await preferences.getPreferences(context, Constants.PREFS_MEMORY);
    let arr: MemoryData[] = items.map((m): MemoryData => ({
      id: m.id,
      memType: m.memType,
      content: m.content,
      importance: m.importance,
      createdAt: m.createdAt
    }));
    await store.put('entries', JSON.stringify(arr));
    await store.flush();
  }

  async add(context: Context, memType: string, content: string,
    importance: number = 0.5): Promise<MemoryItem> {
    let items = await this.loadAll(context);
    let item = new MemoryItem(memType, content, importance);
    items.push(item);
    await this.save(context, items);
    // Async: embed vector + regenerate memory.md + append diary (fire-and-forget)
    this.embedAndStore(context, item).catch(() => { /* ignore */ });
    this.generateMemoryMd(context).catch(() => { /* ignore */ });
    this.appendDiaryEntry(context, { time: this.nowTimeStr(), memType: memType, content: content, memoryId: item.id }).catch(() => { /* ignore */ });
    return item;
  }

  async remove(context: Context, id: string): Promise<void> {
    let items = await this.loadAll(context);
    let filtered = items.filter((m): boolean => m.id !== id);
    await this.save(context, filtered);
    // Remove vector for this id
    this.removeVector(context, id).catch(() => { /* ignore */ });
    this.generateMemoryMd(context).catch(() => { /* ignore */ });
  }

  async clearAll(context: Context): Promise<void> {
    await this.save(context, []);
    // Clear all vectors
    let emptyStore: VectorStore = { model: Constants.EMBEDDING_MODEL, vectors: [] };
    await this.saveVectors(context, emptyStore);
    this.generateMemoryMd(context).catch(() => { /* ignore */ });
  }

  /**
   * Keyword search across memories.
   * Splits query into keywords, scores each memory by how many keywords match.
   * Returns results sorted by relevance (most keywords matched first).
   */
  async search(context: Context, query: string, filterType: string = ''): Promise<MemoryItem[]> {
    let items = await this.loadAll(context);
    if (filterType.length > 0) {
      items = items.filter((m): boolean => m.memType === filterType);
    }
    let keywords = query.toLowerCase().split(/\s+/).filter((k): boolean => k.length > 0);
    if (keywords.length === 0) return items;

    let scored: ScoredMemory[] = [];
    for (let item of items) {
      let lower = item.content.toLowerCase();
      let hits = 0;
      for (let kw of keywords) {
        if (lower.includes(kw)) hits++;
      }
      if (hits > 0) {
        scored.push({ item: item, score: hits });
      }
    }
    scored.sort((a: ScoredMemory, b: ScoredMemory): number => b.score - a.score);
    return scored.map((s: ScoredMemory): MemoryItem => s.item);
  }

  /**
   * Check if a memory with similar content already exists (dedup).
   */
  async exists(context: Context, content: string): Promise<boolean> {
    let items = await this.loadAll(context);
    let lower = content.toLowerCase().trim();
    for (let item of items) {
      if (item.content.toLowerCase().trim() === lower) return true;
    }
    return false;
  }

  /**
   * Add memory only if it doesn't already exist.
   * Uses both exact match and semantic similarity dedup (OpenClaw-inspired).
   */
  async addIfNew(context: Context, memType: string, content: string, importance: number = 0.5): Promise<MemoryItem | null> {
    // Exact match dedup
    let isDup = await this.exists(context, content);
    if (isDup) return null;

    // Semantic dedup: check if very similar memory exists via vector similarity
    let semanticDup = await this.isSemanticDuplicate(context, content);
    if (semanticDup) {
      this.log.info(this.TAG, `Semantic dedup: skipping "${content.substring(0, 60)}"`);
      return null;
    }

    return await this.add(context, memType, content, importance);
  }

  /**
   * Build the memory block injected into the system prompt.
   * Includes source citations for traceability (OpenClaw-inspired).
   */
  buildPromptBlock(items: MemoryItem[]): string {
    if (items.length === 0) return '';
    let facts = items.filter((m): boolean => m.memType === 'fact');
    let prefs = items.filter((m): boolean => m.memType === 'preference');
    let instr = items.filter((m): boolean => m.memType === 'instruction');
    let parts: string[] = [];
    if (facts.length > 0) {
      parts.push('## Facts\n' + facts.map((f): string => `- ${f.content} [${f.id}]`).join('\n'));
    }
    if (prefs.length > 0) {
      parts.push('## Preferences\n' + prefs.map((p): string => `- ${p.content} [${p.id}]`).join('\n'));
    }
    if (instr.length > 0) {
      parts.push('## Instructions\n' + instr.map((i): string => `- ${i.content} [${i.id}]`).join('\n'));
    }
    return '<memory>\n' + parts.join('\n\n') + '\n</memory>';
  }

  /**
   * Build prompt block for hybrid search results with relevance scores and citations.
   * Used when auto-memory inject retrieves specific relevant memories.
   */
  buildSearchResultsBlock(results: MemorySearchResult[]): string {
    if (results.length === 0) return '';
    let lines: string[] = ['<relevant-memories>'];
    for (let r of results) {
      let scoreStr = (r.score * 100).toFixed(0);
      lines.push(`- [${r.item.memType}] ${r.item.content} (relevance: ${scoreStr}%, source: ${r.citation})`);
    }
    lines.push('</relevant-memories>');
    return lines.join('\n');
  }

  /**
   * Auto-detect memorable info from user text via regex patterns.
   */
  async autoExtract(context: Context, userText: string): Promise<void> {
    let lower = userText.toLowerCase();
    let regexes: RegExp[] = [
      // English patterns
      /(?:remember|note)\s+(?:that\s+)?(.{5,})/i,
      /(?:i prefer|i like|i always)\s+(.{5,})/i,
      /(?:always|never|make sure)\s+(.{5,})/i,
      /(?:my name is|i'm called)\s+(\S.{1,40})/i,
      // Chinese patterns
      /(?:\u8BB0\u4F4F|\u8BB0\u4E0B|\u5907\u5FD8|\u8BF7\u8BB0\u4F4F)[\uFF1A\uFF0C,:\s]*(.{3,})/i,  // 记住/记下/备忘/请记住
      /(?:\u6211\u559C\u6B22|\u6211\u504F\u597D|\u6211\u60F3\u8981)(.{3,})/i,  // 我喜欢/我偏好/我想要
      /(?:\u6211\u53EB|\u6211\u7684\u540D\u5B57\u662F|\u6211\u59D3)(.{1,20})/i,  // 我叫/我的名字是/我姓
      /(?:\u4EE5\u540E|\u4ECE\u73B0\u5728\u8D77|\u6BCF\u6B21\u90FD\u8981)(.{3,})/i,  // 以后/从现在起/每次都要
    ];
    let types: string[] = [
      'fact', 'preference', 'instruction', 'fact',
      'fact', 'preference', 'fact', 'instruction'
    ];
    for (let i = 0; i < regexes.length; i++) {
      let re: RegExp = regexes[i];
      let type: string = types[i];
      let match = lower.match(re);
      if (match && match[1]) {
        this.log.info(this.TAG, `autoExtract: type=${type} content="${match[1].trim().substring(0, 80)}"`);
        await this.addIfNew(context, type, match[1].trim(), 0.8);
      }
    }
  }

  // ==================== Hybrid Search (OpenClaw-inspired) ====================

  /**
   * Hybrid search combining BM25 keyword scores with vector cosine similarity.
   *
   * Algorithm (from OpenClaw):
   * 1. Get vector candidates (topK × candidateMultiplier)
   * 2. Get keyword candidates (topK × candidateMultiplier)
   * 3. Union by ID, compute: finalScore = vectorWeight × vecScore + keywordWeight × kwScore
   * 4. Sort by finalScore, return topK with citations
   */
  async hybridSearch(context: Context, query: string, apiKey: string,
    topK: number = Constants.VECTOR_SEARCH_TOP_K,
    filterType: string = ''): Promise<MemorySearchResult[]> {
    let items = await this.loadAll(context);
    if (filterType.length > 0) {
      items = items.filter((m): boolean => m.memType === filterType);
    }
    if (items.length === 0) return [];

    let candidateK = topK * this.CANDIDATE_MULTIPLIER;

    // --- Vector scores ---
    let vectorScores = new Map<string, number>();
    let mode = await this.getEmbeddingMode(context);
    // Lazy-init local model
    if (!this.localEmb.isReady()) {
      await this.localEmb.init(context);
    }
    let queryVec = await this.embed(query, apiKey, mode);
    if (queryVec.length > 0) {
      let vecStore = await this.loadVectors(context);
      let vecScored: ScoredMemory[] = [];
      for (let vd of vecStore.vectors) {
        let sim = this.cosineSimilarity(queryVec, vd.vector);
        if (sim > 0) {
          vecScored.push({ item: new MemoryItem('', ''), score: sim });
          // Store using id as key
          vectorScores.set(vd.id, sim);
        }
      }
    }

    // --- Keyword scores (BM25-like) ---
    let keywordScores = new Map<string, number>();
    let keywords = query.toLowerCase().split(/\s+/).filter((k): boolean => k.length > 0);
    if (keywords.length > 0) {
      for (let item of items) {
        let lower = item.content.toLowerCase();
        let hits = 0;
        for (let kw of keywords) {
          if (lower.includes(kw)) hits++;
        }
        if (hits > 0) {
          // Normalize: hits/totalKeywords gives 0-1 range
          let kwScore = hits / keywords.length;
          keywordScores.set(item.id, kwScore);
        }
      }
    }

    // --- Merge scores ---
    let itemMap = new Map<string, MemoryItem>();
    for (let item of items) {
      itemMap.set(item.id, item);
    }

    let merged: MemorySearchResult[] = [];
    let seenIds = new Set<string>();

    // Collect all candidate IDs from both signals
    for (let item of items) {
      let id = item.id;
      if (seenIds.has(id)) continue;
      seenIds.add(id);

      let vecScore = vectorScores.get(id) ?? 0;
      let kwScore = keywordScores.get(id) ?? 0;

      // Skip if no signal from either side
      if (vecScore === 0 && kwScore === 0) continue;

      let finalScore = this.VECTOR_WEIGHT * vecScore + this.KEYWORD_WEIGHT * kwScore;
      let method: string;
      if (vecScore > 0 && kwScore > 0) {
        method = 'hybrid';
      } else if (vecScore > 0) {
        method = 'vector';
      } else {
        method = 'keyword';
      }

      let citation = `memory:${id}`;
      let created = new Date(item.createdAt);
      let dateStr = `${created.getFullYear()}-${(created.getMonth()+1).toString().padStart(2,'0')}-${created.getDate().toString().padStart(2,'0')}`;
      citation = `memory:${item.memType}:${dateStr}`;

      merged.push({
        item: item,
        score: finalScore,
        method: method,
        vectorScore: vecScore,
        keywordScore: kwScore,
        citation: citation,
      });
    }

    // Sort by final score descending
    merged.sort((a: MemorySearchResult, b: MemorySearchResult): number => b.score - a.score);
    let results = merged.slice(0, topK);
    this.log.info(this.TAG, `hybridSearch: query="${query.substring(0, 50)}" candidates=${merged.length} returned=${results.length}`);
    return results;
  }

  /**
   * Semantic vector search across memories (legacy API, kept for backward compat).
   * Now delegates to hybridSearch internally and extracts items.
   */
  async vectorSearch(context: Context, query: string, apiKey: string,
    topK: number = Constants.VECTOR_SEARCH_TOP_K,
    filterType: string = ''): Promise<MemoryItem[]> {
    let results = await this.hybridSearch(context, query, apiKey, topK, filterType);
    if (results.length > 0) {
      return results.map((r: MemorySearchResult): MemoryItem => r.item);
    }
    // If hybrid search returned nothing, fall back to plain keyword search
    this.log.info(this.TAG, 'vectorSearch: hybrid returned 0 results, falling back to keyword');
    return [];
  }

  // ==================== Semantic Deduplication ====================

  /**
   * Check if a semantically similar memory already exists.
   * Uses vector cosine similarity with a high threshold (0.92).
   */
  private async isSemanticDuplicate(context: Context, content: string): Promise<boolean> {
    try {
      let apiKey = await this.getEmbeddingApiKey(context);
      let mode = await this.getEmbeddingMode(context);
      let queryVec = await this.embed(content, apiKey, mode);
      if (queryVec.length === 0) return false;

      let store = await this.loadVectors(context);
      for (let vd of store.vectors) {
        let sim = this.cosineSimilarity(queryVec, vd.vector);
        if (sim >= this.SEMANTIC_DEDUP_THRESHOLD) {
          this.log.info(this.TAG, `Semantic duplicate found: sim=${sim.toFixed(3)} id=${vd.id}`);
          return true;
        }
      }
      return false;
    } catch {
      return false; // On error, allow adding
    }
  }

  // ==================== Daily Diary (OpenClaw-inspired) ====================

  /**
   * Append an entry to today's diary file: memory/YYYY-MM-DD.md
   * Modeled after OpenClaw's daily journal pattern.
   */
  async appendDiaryEntry(context: Context, entry: DiaryEntry): Promise<void> {
    let now = new Date();
    let dateStr = `${now.getFullYear()}-${(now.getMonth()+1).toString().padStart(2,'0')}-${now.getDate().toString().padStart(2,'0')}`;
    let dirPath = context.filesDir + '/memory';
    let filePath = dirPath + '/' + dateStr + '.md';

    // Ensure directory exists
    try {
      fileIo.mkdirSync(dirPath);
    } catch {
      // Directory may already exist
    }

    let typeIcon = entry.memType === 'fact' ? 'fact' : entry.memType === 'preference' ? 'pref' : entry.memType === 'instruction' ? 'inst' : entry.memType;
    let line = `- ${entry.time} [${typeIcon}] ${entry.content}`;
    if (entry.memoryId) {
      line += ` (${entry.memoryId})`;
    }
    line += '\n';

    // Check if file exists, if not create with header
    let needsHeader = false;
    try {
      fileIo.statSync(filePath);
    } catch {
      needsHeader = true;
    }

    let encoder = new util.TextEncoder();
    if (needsHeader) {
      let header = `# ${dateStr}\n\n`;
      let content = header + line;
      let encoded = encoder.encodeInto(content);
      let file = fileIo.openSync(filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
      fileIo.writeSync(file.fd, encoded.buffer);
      fileIo.closeSync(file);
    } else {
      let encoded = encoder.encodeInto(line);
      let file = fileIo.openSync(filePath, fileIo.OpenMode.APPEND | fileIo.OpenMode.WRITE_ONLY);
      fileIo.writeSync(file.fd, encoded.buffer);
      fileIo.closeSync(file);
    }
    this.log.info(this.TAG, `Diary entry appended to ${dateStr}.md`);
  }

  /**
   * Append a conversation summary to today's diary.
   * Called after significant conversations are saved.
   */
  async appendConversationDiary(context: Context, summary: string): Promise<void> {
    let entry: DiaryEntry = {
      time: this.nowTimeStr(),
      memType: 'conversation',
      content: summary,
    };
    await this.appendDiaryEntry(context, entry);
  }

  /**
   * Read today's diary file content (if exists).
   */
  async readTodayDiary(context: Context): Promise<string> {
    let now = new Date();
    let dateStr = `${now.getFullYear()}-${(now.getMonth()+1).toString().padStart(2,'0')}-${now.getDate().toString().padStart(2,'0')}`;
    return await this.readDiaryFile(context, dateStr);
  }

  /**
   * Read yesterday's diary file content (if exists).
   */
  async readYesterdayDiary(context: Context): Promise<string> {
    let yesterday = new Date(Date.now() - 86400000);
    let dateStr = `${yesterday.getFullYear()}-${(yesterday.getMonth()+1).toString().padStart(2,'0')}-${yesterday.getDate().toString().padStart(2,'0')}`;
    return await this.readDiaryFile(context, dateStr);
  }

  /**
   * Read a diary file by date string YYYY-MM-DD.
   */
  private async readDiaryFile(context: Context, dateStr: string): Promise<string> {
    let filePath = context.filesDir + '/memory/' + dateStr + '.md';
    try {
      let stat = fileIo.statSync(filePath);
      if (!stat.isFile()) return '';
      let file = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
      let buf = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buf);
      fileIo.closeSync(file);
      let decoder = util.TextDecoder.create('utf-8');
      return decoder.decodeWithStream(new Uint8Array(buf));
    } catch {
      return '';
    }
  }

  /**
   * List available diary files (dates).
   */
  async listDiaryDates(context: Context): Promise<string[]> {
    let dirPath = context.filesDir + '/memory';
    try {
      let entries = fileIo.listFileSync(dirPath);
      let dates: string[] = [];
      for (let name of entries) {
        if (name.endsWith('.md')) {
          dates.push(name.replace('.md', ''));
        }
      }
      dates.sort();
      return dates;
    } catch {
      return [];
    }
  }

  // ==================== Vector Embedding ====================

  /**
   * Call embedding API to generate a vector for the given text.
   * Returns empty array on failure.
   */
  async embed(text: string, apiKey: string, mode: string = 'auto'): Promise<number[]> {
    if (text.length === 0) return [];
    // In node mode, cloud embedding is handled by the gateway server — only local runs on-device
    if (this._nodeMode && mode !== 'local') {
      mode = 'local';
    }
    // Local embedding (for 'auto' or 'local' modes)
    if (mode !== 'cloud' && this.localEmb.isReady()) {
      let vec = await this.localEmb.embed(text);
      if (vec.length > 0) {
        return vec;
      }
      if (mode === 'local') return []; // local-only, don't fall back
    }
    if (mode === 'local') return []; // local mode but model not ready
    // Cloud API (for 'auto' or 'cloud' modes)
    if (apiKey.length === 0) return [];
    try {
      let bodyStr = JSON.stringify({ model: Constants.EMBEDDING_MODEL, input: text });
      let req = http.createHttp();
      let resp = await req.request(Constants.EMBEDDING_URL, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${apiKey}`
        } as Record<string, string>,
        extraData: bodyStr,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 30000
      });
      req.destroy();
      if (resp.responseCode !== 200) {
        this.log.warn(this.TAG, `embed API error: HTTP ${resp.responseCode}`);
        return [];
      }
      let data = JSON.parse(resp.result as string) as EmbeddingResponse;
      if (data.data && data.data.length > 0 && data.data[0].embedding) {
        this.log.info(this.TAG, `embed OK: dim=${data.data[0].embedding.length} textLen=${text.length}`);
        return data.data[0].embedding;
      }
      return [];
    } catch (e) {
      this.log.warn(this.TAG, `embed failed: ${(e as Error).message ?? String(e)}`);
      return [];
    }
  }

  /**
   * Load vector store from file.
   */
  async loadVectors(context: Context): Promise<VectorStore> {
    let filePath = context.filesDir + '/memory_vectors.json';
    try {
      let stat = fileIo.statSync(filePath);
      if (!stat.isFile()) {
        return { model: Constants.EMBEDDING_MODEL, vectors: [] };
      }
      let file = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
      let buf = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buf);
      fileIo.closeSync(file);
      let decoder = util.TextDecoder.create('utf-8');
      let text = decoder.decodeWithStream(new Uint8Array(buf));
      return JSON.parse(text) as VectorStore;
    } catch {
      return { model: Constants.EMBEDDING_MODEL, vectors: [] };
    }
  }

  /**
   * Save vector store to file.
   */
  async saveVectors(context: Context, store: VectorStore): Promise<void> {
    let filePath = context.filesDir + '/memory_vectors.json';
    let json = JSON.stringify(store);
    let encoder = new util.TextEncoder();
    let encoded = encoder.encodeInto(json);
    let file = fileIo.openSync(filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(file.fd, encoded.buffer);
    fileIo.closeSync(file);
  }

  /**
   * Embed a memory item and store its vector.
   */
  private async embedAndStore(context: Context, item: MemoryItem): Promise<void> {
    // Lazy-init local embedding model
    if (!this.localEmb.isReady()) {
      await this.localEmb.init(context);
    }
    // Check for model migration (dimension change)
    if (!this.migrationDone) {
      await this.checkModelMigration(context);
      this.migrationDone = true;
    }
    let mode = await this.getEmbeddingMode(context);
    let apiKey = mode !== 'local' ? await this.getEmbeddingApiKey(context) : '';
    if (!this.localEmb.isReady() && apiKey.length === 0) {
      this.log.info(this.TAG, 'No local model or API key, skipping embed');
      return;
    }
    let vector = await this.embed(item.content, apiKey, mode);
    if (vector.length === 0) return;

    let store = await this.loadVectors(context);
    // Replace if exists, otherwise add
    let found = false;
    for (let i = 0; i < store.vectors.length; i++) {
      if (store.vectors[i].id === item.id) {
        store.vectors[i].vector = vector;
        found = true;
        break;
      }
    }
    if (!found) {
      let vd: VectorData = { id: item.id, vector: vector };
      store.vectors.push(vd);
    }
    await this.saveVectors(context, store);
    this.log.info(this.TAG, `Vector stored for ${item.id}, total vectors: ${store.vectors.length}`);
  }

  /**
   * Remove a vector by memory id.
   */
  private async removeVector(context: Context, id: string): Promise<void> {
    let store = await this.loadVectors(context);
    store.vectors = store.vectors.filter((v): boolean => v.id !== id);
    await this.saveVectors(context, store);
  }

  /**
   * Cosine similarity between two vectors.
   */
  cosineSimilarity(a: number[], b: number[]): number {
    if (a.length !== b.length || a.length === 0) return 0;
    let dot = 0;
    let normA = 0;
    let normB = 0;
    for (let i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    let denom = Math.sqrt(normA) * Math.sqrt(normB);
    if (denom === 0) return 0;
    return dot / denom;
  }

  /**
   * Get the embedding API key from settings.
   * Reuses the ASR key (both are SiliconFlow).
   */
  async getEmbeddingApiKey(context: Context): Promise<string> {
    try {
      let store = await preferences.getPreferences(context, Constants.PREFS_SETTINGS);
      // Try dedicated embedding key first, then fall back to ASR key
      let embKey = (await store.get('embedding_key', '')) as string;
      if (embKey.length > 0) return embKey;
      let asrKey = (await store.get('asr_key', '')) as string;
      if (asrKey.length > 0) return asrKey;
      // Fall back to OpenAI provider key (if using SiliconFlow)
      let provider = (await store.get('provider', '')) as string;
      if (provider === 'openai') {
        let apiKey = (await store.get('key_openai', '')) as string;
        if (apiKey.length > 0) return apiKey;
      }
      return '';
    } catch {
      return '';
    }
  }

  async getEmbeddingMode(context: Context): Promise<string> {
    try {
      let store = await preferences.getPreferences(context, Constants.PREFS_SETTINGS);
      return (await store.get('embedding_mode', 'auto')) as string;
    } catch {
      return 'auto';
    }
  }

  // ==================== Model Migration ====================

  private async checkModelMigration(context: Context): Promise<void> {
    let store = await this.loadVectors(context);
    let currentModel = this.localEmb.isReady()
      ? this.localEmb.getModelName()
      : Constants.EMBEDDING_MODEL;
    if (store.vectors.length > 0 && store.model !== currentModel) {
      this.log.info(this.TAG, `Model changed: ${store.model} -> ${currentModel}, clearing vectors`);
      store.model = currentModel;
      store.vectors = [];
      await this.saveVectors(context, store);
      this.reembedAll(context).catch((): void => {});
    }
  }

  private async reembedAll(context: Context): Promise<void> {
    let items = await this.loadAll(context);
    this.log.info(this.TAG, `Re-embedding ${items.length} memories with local model...`);
    let count = 0;
    for (let item of items) {
      await this.embedAndStore(context, item);
      count++;
      if (count < items.length) {
        await new Promise<void>((resolve): void => {
          setTimeout((): void => resolve(), 100);
        });
      }
    }
    this.log.info(this.TAG, `Re-embedding complete: ${count} items`);
  }

  // ==================== memory.md generation ====================

  /**
   * Generate a human-readable memory.md summary file (OpenClaw MEMORY.md style).
   * Called automatically after memory changes.
   */
  async generateMemoryMd(context: Context): Promise<string> {
    let items = await this.loadAll(context);
    let now = new Date();
    let dateStr = `${now.getFullYear()}-${(now.getMonth()+1).toString().padStart(2,'0')}-${now.getDate().toString().padStart(2,'0')} ${now.getHours().toString().padStart(2,'0')}:${now.getMinutes().toString().padStart(2,'0')}`;

    let lines: string[] = [];
    lines.push('# ClawdBot Memory');
    lines.push(`Last updated: ${dateStr}`);
    lines.push(`Total: ${items.length} items`);
    lines.push('');

    // Group by type, sorted by importance desc
    let facts = items.filter((m): boolean => m.memType === 'fact')
      .sort((a: MemoryItem, b: MemoryItem): number => b.importance - a.importance);
    let prefs = items.filter((m): boolean => m.memType === 'preference')
      .sort((a: MemoryItem, b: MemoryItem): number => b.importance - a.importance);
    let instr = items.filter((m): boolean => m.memType === 'instruction')
      .sort((a: MemoryItem, b: MemoryItem): number => b.importance - a.importance);

    if (facts.length > 0) {
      lines.push('## Facts');
      for (let f of facts) {
        let created = new Date(f.createdAt);
        let cDate = `${created.getFullYear()}-${(created.getMonth()+1).toString().padStart(2,'0')}-${created.getDate().toString().padStart(2,'0')}`;
        lines.push(`- ${f.content} (added: ${cDate})`);
      }
      lines.push('');
    }
    if (prefs.length > 0) {
      lines.push('## Preferences');
      for (let p of prefs) {
        let created = new Date(p.createdAt);
        let cDate = `${created.getFullYear()}-${(created.getMonth()+1).toString().padStart(2,'0')}-${created.getDate().toString().padStart(2,'0')}`;
        lines.push(`- ${p.content} (added: ${cDate})`);
      }
      lines.push('');
    }
    if (instr.length > 0) {
      lines.push('## Instructions');
      for (let ins of instr) {
        let created = new Date(ins.createdAt);
        let cDate = `${created.getFullYear()}-${(created.getMonth()+1).toString().padStart(2,'0')}-${created.getDate().toString().padStart(2,'0')}`;
        lines.push(`- ${ins.content} (added: ${cDate})`);
      }
      lines.push('');
    }

    // Add diary summary section
    let todayDiary = await this.readTodayDiary(context);
    if (todayDiary.length > 0) {
      lines.push('## Today\'s Diary');
      lines.push(todayDiary);
      lines.push('');
    }

    let content = lines.join('\n');
    let filePath = context.filesDir + '/memory.md';
    let encoder = new util.TextEncoder();
    let encoded = encoder.encodeInto(content);
    let file = fileIo.openSync(filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(file.fd, encoded.buffer);
    fileIo.closeSync(file);
    this.log.info(this.TAG, `memory.md generated: ${items.length} items, ${content.length} bytes`);
    return filePath;
  }

  // ==================== Helpers ====================

  private nowTimeStr(): string {
    let now = new Date();
    return `${now.getHours().toString().padStart(2,'0')}:${now.getMinutes().toString().padStart(2,'0')}`;
  }
}
