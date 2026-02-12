import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { MemoryItem, MemoryData, VectorData, VectorStore } from '../model/Models';
import { Constants } from '../common/Constants';
import { LogService } from '../common/LogService';

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
 * Persistent memory service with vector embedding support.
 * Stores facts, preferences, and instructions across sessions.
 * Memory is injected into the system prompt for personalisation.
 * Supports semantic search via embedding API (SiliconFlow bge-m3).
 */
export class MemoryService {
  private static instance: MemoryService | undefined = undefined;
  private log: LogService = LogService.getInstance();
  private readonly TAG = 'MemoryService';

  static getInstance(): MemoryService {
    if (!MemoryService.instance) {
      MemoryService.instance = new MemoryService();
    }
    return MemoryService.instance;
  }

  // ---------- public API ----------

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
    // Async: embed vector + regenerate memory.md (fire-and-forget)
    this.embedAndStore(context, item).catch(() => { /* ignore */ });
    this.generateMemoryMd(context).catch(() => { /* ignore */ });
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
   * Add memory only if it doesn't already exist (dedup).
   */
  async addIfNew(context: Context, memType: string, content: string, importance: number = 0.5): Promise<MemoryItem | null> {
    let isDup = await this.exists(context, content);
    if (isDup) return null;
    return await this.add(context, memType, content, importance);
  }

  /**
   * Build the memory block that gets injected into the system prompt.
   */
  buildPromptBlock(items: MemoryItem[]): string {
    if (items.length === 0) return '';
    let facts = items.filter((m): boolean => m.memType === 'fact');
    let prefs = items.filter((m): boolean => m.memType === 'preference');
    let instr = items.filter((m): boolean => m.memType === 'instruction');
    let parts: string[] = [];
    if (facts.length > 0) {
      parts.push('## Facts\n' + facts.map((f): string => '- ' + f.content).join('\n'));
    }
    if (prefs.length > 0) {
      parts.push('## Preferences\n' + prefs.map((p): string => '- ' + p.content).join('\n'));
    }
    if (instr.length > 0) {
      parts.push('## Instructions\n' + instr.map((i): string => '- ' + i.content).join('\n'));
    }
    return '<memory>\n' + parts.join('\n\n') + '\n</memory>';
  }

  /**
   * Auto-detect memorable info from user text.
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
        await this.addIfNew(context, type, match[1].trim(), 0.8);
      }
    }
  }

  // ==================== Vector Embedding ====================

  /**
   * Call embedding API to generate a vector for the given text.
   * Returns empty array on failure.
   */
  async embed(text: string, apiKey: string): Promise<number[]> {
    if (apiKey.length === 0 || text.length === 0) return [];
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
    let apiKey = await this.getEmbeddingApiKey(context);
    if (apiKey.length === 0) {
      this.log.info(this.TAG, 'No embedding API key configured, skipping embed');
      return;
    }
    let vector = await this.embed(item.content, apiKey);
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
   * Semantic vector search across memories.
   * Falls back to keyword search if embedding fails.
   */
  async vectorSearch(context: Context, query: string, apiKey: string,
    topK: number = Constants.VECTOR_SEARCH_TOP_K,
    filterType: string = ''): Promise<MemoryItem[]> {
    // Get query embedding
    let queryVec = await this.embed(query, apiKey);
    if (queryVec.length === 0) {
      this.log.info(this.TAG, 'vectorSearch: embed failed, falling back to keyword search');
      return [];
    }

    let store = await this.loadVectors(context);
    if (store.vectors.length === 0) {
      this.log.info(this.TAG, 'vectorSearch: no vectors stored');
      return [];
    }

    let items = await this.loadAll(context);
    // Build id -> item map
    let itemMap = new Map<string, MemoryItem>();
    for (let item of items) {
      if (filterType.length === 0 || item.memType === filterType) {
        itemMap.set(item.id, item);
      }
    }

    // Score each vector
    let scored: ScoredMemory[] = [];
    for (let vd of store.vectors) {
      let item = itemMap.get(vd.id);
      if (!item) continue;
      let sim = this.cosineSimilarity(queryVec, vd.vector);
      if (sim >= Constants.VECTOR_SEARCH_THRESHOLD) {
        scored.push({ item: item, score: sim });
      }
    }

    scored.sort((a: ScoredMemory, b: ScoredMemory): number => b.score - a.score);
    let results = scored.slice(0, topK).map((s: ScoredMemory): MemoryItem => s.item);
    this.log.info(this.TAG, `vectorSearch: query="${query.substring(0, 50)}" found=${scored.length} returned=${results.length}`);
    return results;
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

  // ==================== memory.md generation ====================

  /**
   * Generate a human-readable memory.md summary file.
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
        lines.push(`- ${f.content} (importance: ${f.importance})`);
      }
      lines.push('');
    }
    if (prefs.length > 0) {
      lines.push('## Preferences');
      for (let p of prefs) {
        lines.push(`- ${p.content} (importance: ${p.importance})`);
      }
      lines.push('');
    }
    if (instr.length > 0) {
      lines.push('## Instructions');
      for (let ins of instr) {
        lines.push(`- ${ins.content} (importance: ${ins.importance})`);
      }
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
}
