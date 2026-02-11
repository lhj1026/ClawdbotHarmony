import { preferences } from '@kit.ArkData';
import { MemoryItem, MemoryData } from '../model/Models';
import { Constants } from '../common/Constants';

interface ScoredMemory {
  item: MemoryItem;
  score: number;
}

/**
 * Persistent memory service.
 * Stores facts, preferences, and instructions across sessions.
 * Memory is injected into the system prompt for personalisation.
 */
export class MemoryService {
  private static instance: MemoryService | undefined = undefined;

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
    return item;
  }

  async remove(context: Context, id: string): Promise<void> {
    let items = await this.loadAll(context);
    let filtered = items.filter((m): boolean => m.id !== id);
    await this.save(context, filtered);
  }

  async clearAll(context: Context): Promise<void> {
    await this.save(context, []);
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
}
